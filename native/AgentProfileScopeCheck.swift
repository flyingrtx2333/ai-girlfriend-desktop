import AppKit

@MainActor extension AppDelegate {
    func runAgentProfileScopeCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:]
        var manager: AgentProfileWindow?
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        func call(_ name: String, _ value: [String: Any] = [:]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: try json(value)) }
        func denied(_ name: String, _ action: () async throws -> Void) async { do { try await action(); checks[name] = false } catch { checks[name] = true } }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            defer {
                runtime.stopAll(); tasks.mcp.disconnect(); manager?.close()
                for server in tasks.mcp.servers { try? tasks.mcp.remove(server.id, revision: server.revision) }
                try? Data("finished".utf8).write(to: output.appendingPathComponent("phase"))
            }
            let workspace = output.appendingPathComponent("workspace"), fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("fixtures.json"))) as? [String: String] ?? [:]
            guard let node = fixtures["node"], let entry = fixtures["serverEntry"] else { throw PetError("缺少实际官方 MCP 文件服务") }
            if let path = fixtures["factsSource"] {
                let recorded = try JSONDecoder().decode(AgentTaskRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                let window = AgentContext.window(recorded, archivedFactBudget: 900).map(\.content).joined(separator: "\n")
                let source = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("source.json"))) as? [String: Any] ?? [:]
                checks["realArchivedToolFactsKeepFullHashSizeAndProtocol"] = window.contains(source["outputSha256"] as? String ?? "missing-hash") && window.contains("1382966") && window.contains("scoped-skill-v1") && window.contains("历史工具原文摘录")
                report["historicalFactsSource"] = path
            }
            let server = try tasks.mcp.save(json(["name": "限定素材文件", "type": "stdio", "command": node, "args": [entry, workspace.path], "env": [:], "timeoutSeconds": 20]))
            let other = try tasks.mcp.save(json(["name": "未分配连接器", "type": "stdio", "command": node, "args": [entry, workspace.path], "env": [:], "timeoutSeconds": 20]))
            let skill = try tasks.extensions.create(.skill, name: "scoped-asset-audit", text: "---\nname: scoped-asset-audit\ndescription: 使用指定 MCP 读取真实素材并按协议交付报告。\ndisable-model-invocation: true\n---\n\n先用 read_skill_resource 读取本 Skill 的 schema.json。只通过已分配的 MCP 连接器“限定素材文件”完成：read_text_file 读取 source.json；get_file_info 获取 character.png 的实际字节；write_file 写 scoped-agent-report.json；read_text_file 回读报告。报告字段和 format 常量遵循 schema.json；edition、width、height、sha256 来自 source.json（sha256 取 outputSha256），imageBytes 来自实际文件大小。使用项目文件绝对路径。不要改动任何输入，不使用原生文件或终端替代 MCP，不调用 edit_file。最后简短交付实际结果。\n", project: false, workspace: workspace.path)
            try Data("{\"fields\":[\"edition\",\"width\",\"height\",\"sha256\",\"imageBytes\",\"format\"],\"format\":\"scoped-skill-v1\"}\n".utf8).write(to: skill.root.appendingPathComponent("schema.json"))
            let unselected = try tasks.extensions.create(.skill, name: "unassigned-flow", text: "---\nname: unassigned-flow\ndescription: 未分配流程\n---\n\nUNASSIGNED_SKILL_PUBLIC_7103\n", project: false, workspace: workspace.path)
            var auditor = AgentProfile(name: "素材协议员", description: "按选定 Skill 与 MCP 核对实际素材", instructions: "按已分配 Skill 完成明确任务，使用实际工具证据。只使用名为限定素材文件的 MCP；不自行改写协议字段，不调用其他连接器。")
            auditor.readOnly = false; auditor.network = true; auditor.permission = .automatic; auditor.enabled = true; auditor.tools = []
            auditor.skills = [skill.id]; auditor.mcpServers = [server.id]; auditor.toolPermissions = ["read_file": .deny, "write_file": .deny, "run_command": .deny, "read_skill_resource": .ask]
            auditor.mcpToolPermissions = [AgentMCPToolPermission(serverID: server.id, tool: "edit_file", permission: .deny)]
            var coordinator = AgentProfile(name: "权限协调员", description: "权限继承检查", instructions: "按明确要求完成只读检查。")
            coordinator.readOnly = false; coordinator.network = true; coordinator.permission = .automatic; coordinator.tools = ["read_file", "run_command", "delegate_task"]; coordinator.enabled = true; coordinator.toolPermissions = ["read_file": .ask, "run_command": .allow]
            var reader = AgentProfile(name: "文件复核员", description: "文件读取与终端检查", instructions: "读取明确文件并依据实际结果核对。")
            reader.readOnly = false; reader.permission = .review; reader.tools = ["read_file", "run_command"]; reader.enabled = true; reader.toolPermissions = ["read_file": .allow, "run_command": .allow]
            var defaultReader = AgentProfile(name: "默认审批复核员", description: "使用角色默认审批", instructions: "按实际工具结果核对文件。")
            defaultReader.readOnly = false; defaultReader.tools = ["run_command"]; defaultReader.enabled = true
            try tasks.agents.save(tasks.agents.encode([auditor, coordinator, reader, defaultReader]), expectedHash: nil)
            let old = try tasks.agents.decode("{\"agents\":[{\"name\":\"旧配置\",\"description\":\"兼容\",\"instructions\":\"核对文件\"}]}").first!
            checks["legacyConfigurationDefaultsToNoExternalScope"] = old.skills == nil && old.mcpServers == nil && old.toolPermissions == nil
            let document = try tasks.agents.document(), imported = try tasks.agents.decode(document.0, importing: true)
            checks["importPreservesScopesWithFreshDisabledIdentities"] = imported.first?.skills == auditor.skills && imported.first?.mcpToolPermissions == auditor.mcpToolPermissions && imported.allSatisfy { !$0.enabled && ![auditor.id, coordinator.id, reader.id, defaultReader.id].contains($0.id) }
            let id = try tasks.agents.createTask(auditor.id, store: tasks, workspace: workspace.path), tools = AgentTools(store: tasks, taskID: id)
            let context = try runtime.systemContext(tasks.task(id)!)
            checks["selectedManualSkillIsPreloadedWithOwnedSnapshot"] = tasks.task(id)?.activeSkills?.first?.id == skill.id && tasks.task(id)?.activeSkills?.first?.snapshot?.contains(id) == true && context.contains("schema.json") && !context.contains("UNASSIGNED_SKILL_PUBLIC_7103")
            let listed = try await tools.execute(call("list_skills"))
            checks["skillDiscoveryOnlyShowsAssignedSkill"] = listed.text.contains(skill.name) && !listed.text.contains(unselected.name)
            await denied("unassignedSkillCannotLoad") { _ = try await tools.execute(call("read_skill", ["id": unselected.id])) }
            checks["skillResourceUsesExplicitAskRule"] = try tools.approvalReason(for: call("read_skill_resource", ["id": skill.id, "path": "schema.json"])) != nil
            await denied("nativeToolDenyCheckedAtExecution") { _ = try await tools.execute(call("write_file", ["path": "blocked-native.json", "content": "blocked"])) }
            let servers = try await tools.execute(call("list_mcp_servers"))
            checks["mcpDiscoveryOnlyShowsAssignedServer"] = servers.text.contains(server.id) && !servers.text.contains(other.id)
            await denied("unassignedServerCannotStart") { _ = try await tools.execute(call("connect_mcp", ["server_id": other.id, "configuration": other.revision])) }
            checks["unassignedServerHasNoProcess"] = await tasks.mcp.processID(other.id, owner: id) == nil
            let connect = try call("connect_mcp", ["server_id": server.id, "configuration": server.revision])
            checks["selectedMCPStillRequiresConnectionApproval"] = try tools.approvalReason(for: connect) != nil
            _ = try await tools.execute(connect)
            guard let token = tasks.mcp.token(server.id, owner: id) else { throw PetError("实际 MCP 未连接") }
            let hidden = try await tools.execute(call("list_mcp_tools", ["server_id": server.id, "connection": token, "query": "edit_file"]))
            checks["deniedMCPToolHiddenFromCatalog"] = (try JSONSerialization.jsonObject(with: Data(hidden.text.utf8)) as? [String: Any])?["total"] as? Int == 0
            _ = try tasks.mcp.catalog(server.id, owner: id, token: token, offset: 0, query: "edit_file")
            let edit = try call("call_mcp_tool", ["server_id": server.id, "connection": token, "tool": "edit_file", "arguments": ["path": workspace.appendingPathComponent("source.json").path, "edits": [["oldText": "19", "newText": "999"]]]])
            await denied("deniedMCPWrapperCannotExecute") { _ = try await tools.execute(edit) }
            let raw = try tasks.mcp.modelDefinitions(owner: id, mode: .agent)
            let rawEdit = raw.first { (($0["function"] as? [String: Any])?["description"] as? String)?.contains(" / edit_file") == true }
            if let name = (rawEdit?["function"] as? [String: Any])?["name"] as? String {
                await denied("deniedDynamicMCPNameCannotExecute") { _ = try await tools.execute(call(name, ["path": workspace.appendingPathComponent("source.json").path, "edits": [["oldText": "19", "newText": "999"]]])) }
                checks["deniedMCPActualSchemaNotOfferedToModel"] = try tasks.agents.filterDefinitions(raw, task: tasks.task(id)!, store: tasks).isEmpty
            } else { throw PetError("官方服务未提供实际 edit_file schema") }
            var updated = try tasks.agents.decode(tasks.agents.document().0)
            updated[0].mcpToolPermissions?.append(AgentMCPToolPermission(serverID: server.id, tool: "read_text_file", permission: .allow))
            try tasks.agents.save(tasks.agents.encode(updated), expectedHash: tasks.agents.document().1)
            checks["scopeChangeDisconnectsExistingSession"] = tasks.mcp.token(server.id, owner: id) == nil
            _ = try await tools.execute(connect)
            guard let allowedToken = tasks.mcp.token(server.id, owner: id) else { throw PetError("范围更新后 MCP 未重新连接") }
            _ = try await tools.execute(call("list_mcp_tools", ["server_id": server.id, "connection": allowedToken, "query": "read_text_file"]))
            let allowedRead = try call("call_mcp_tool", ["server_id": server.id, "connection": allowedToken, "tool": "read_text_file", "arguments": ["path": workspace.appendingPathComponent("source.json").path]])
            checks["newAllowDoesNotExpandExistingTask"] = try tools.approvalReason(for: allowedRead) != nil
            let allowedID = try tasks.agents.createTask(auditor.id, store: tasks, workspace: workspace.path), allowedTools = AgentTools(store: tasks, taskID: allowedID)
            _ = try await allowedTools.execute(connect)
            guard let newToken = tasks.mcp.token(server.id, owner: allowedID) else { throw PetError("新允许规则任务 MCP 未连接") }
            _ = try await allowedTools.execute(call("list_mcp_tools", ["server_id": server.id, "connection": newToken, "query": "read_text_file"]))
            let newRead = try call("call_mcp_tool", ["server_id": server.id, "connection": newToken, "tool": "read_text_file", "arguments": ["path": workspace.appendingPathComponent("source.json").path]])
            checks["explicitMCPAllowSkipsDefaultCallApproval"] = try allowedTools.approvalReason(for: newRead) == nil
            let actualRead = try await allowedTools.execute(newRead)
            checks["explicitlyAllowedMCPReadsActualFile"] = actualRead.text.contains("1254") && !actualRead.failed
            updated[0].mcpToolPermissions?.removeAll { $0.tool == "read_text_file" }; try tasks.agents.save(tasks.agents.encode(updated), expectedHash: tasks.agents.document().1)
            _ = try await allowedTools.execute(connect)
            guard let revokedToken = tasks.mcp.token(server.id, owner: allowedID) else { throw PetError("撤销规则后 MCP 未重新连接") }
            _ = try await allowedTools.execute(call("list_mcp_tools", ["server_id": server.id, "connection": revokedToken, "query": "read_text_file"]))
            checks["removedAllowNoLongerBypassesApprovalOnResume"] = try allowedTools.approvalReason(for: call("call_mcp_tool", ["server_id": server.id, "connection": revokedToken, "tool": "read_text_file", "arguments": ["path": workspace.appendingPathComponent("source.json").path]])) != nil
            updated[0].mcpToolPermissions?.append(AgentMCPToolPermission(serverID: server.id, tool: "read_text_file", permission: .allow)); try tasks.agents.save(tasks.agents.encode(updated), expectedHash: tasks.agents.document().1)
            tasks.mcp.disconnect(owner: allowedID)
            tasks.mcp.disconnect(owner: id)
            let reviewOwner = tasks.create(title: "必须确认的所属任务", workspace: workspace.path); tasks.update(reviewOwner) { $0.permission = .review }
            let reviewChild = try tasks.agents.createTask(auditor.id, store: tasks, workspace: workspace.path, owner: tasks.task(reviewOwner)), reviewTools = AgentTools(store: tasks, taskID: reviewChild)
            _ = try await reviewTools.execute(connect)
            guard let reviewToken = tasks.mcp.token(server.id, owner: reviewChild) else { throw PetError("确认任务 MCP 未连接") }
            _ = try await reviewTools.execute(call("list_mcp_tools", ["server_id": server.id, "connection": reviewToken, "query": "read_text_file"]))
            checks["explicitMCPAllowCannotBypassParentReview"] = try reviewTools.approvalReason(for: call("call_mcp_tool", ["server_id": server.id, "connection": reviewToken, "tool": "read_text_file", "arguments": ["path": workspace.appendingPathComponent("source.json").path]])) != nil
            tasks.mcp.disconnect(owner: reviewChild)
            let ownReader = try tasks.agents.createTask(reader.id, store: tasks, workspace: workspace.path), ownTools = AgentTools(store: tasks, taskID: ownReader), readCommand = try call("run_command", ["command": "wc -c < character.png", "network": false])
            checks["explicitNativeAllowOverridesAgentDefaultReview"] = try ownTools.approvalReason(for: readCommand) == nil
            let actualCommand = try await ownTools.execute(readCommand)
            checks["explicitNativeAllowExecutesActualBoundedCommand"] = !actualCommand.failed && actualCommand.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "1382966"
            let parent = try tasks.agents.createTask(coordinator.id, store: tasks, workspace: workspace.path), child = try tasks.agents.createTask(reader.id, store: tasks, workspace: workspace.path, owner: tasks.task(parent)), childTools = AgentTools(store: tasks, taskID: child)
            let defaultChild = try tasks.agents.createTask(defaultReader.id, store: tasks, workspace: workspace.path, owner: tasks.task(parent))
            checks["ancestorAllowDoesNotGrantChildAutomation"] = try AgentTools(store: tasks, taskID: defaultChild).approvalReason(for: readCommand) != nil
            checks["ancestorAskCannotBeRelaxedByChild"] = try childTools.approvalReason(for: call("read_file", ["path": "source.json"])) != nil
            await denied("childCannotAddParentUnselectedMCP") { _ = try tasks.agents.createTask(auditor.id, store: tasks, workspace: workspace.path, owner: tasks.task(parent)) }
            var scoped = try tasks.agents.decode(tasks.agents.document().0); let index = scoped.firstIndex { $0.id == coordinator.id }!
            scoped[index].toolPermissions = ["read_file": .deny]; scoped[index].readOnly = true
            try tasks.agents.save(tasks.agents.encode(scoped), expectedHash: tasks.agents.document().1)
            await denied("liveAncestorDenyOverridesOldChildSnapshot") { _ = try await childTools.execute(call("read_file", ["path": "source.json"])) }
            let command = try await childTools.execute(call("run_command", ["command": "printf forbidden > ancestor-write-blocked.txt", "network": false]))
            checks["liveAncestorReadOnlyStillEnforcedByKernel"] = command.failed && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ancestor-write-blocked.txt").path)
            if CommandLine.arguments.contains("--live-agent") {
                let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: production).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.persona = ""; store.preferences = p
                let root = tasks.create(title: "真实角色扩展协议验收", workspace: workspace.path); tasks.update(root) { $0.permission = .review; $0.toolGroups = ["agents"] }
                guard runtime.submit("委派给已启用的“素材协议员”，请它按已分配的 Skill 完成当前项目素材核对，交付并回读协议要求的报告。明确给子任务当前项目绝对路径：\(workspace.path)。等待真实最终结果。不得使用其他连接器、原生文件或终端替代其流程，不修改输入。", taskID: root) else { throw PetError("真实委派未开始") }
                var approved = Set<String>(), childApproval = false; let deadline = Date().addingTimeInterval(240)
                while Date() < deadline, runtime.isRunning(root) || tasks.task(root)?.status == .waiting {
                    if let pending = runtime.pendingReview(root), let first = pending.pendingCalls.first, !approved.contains(first.id) {
                        let action = try tasks.mcp.routedCall(first, owner: pending.id) ?? first
                        if action.name == "read_skill_resource" { guard action.object["id"] as? String == skill.id, ["schema.json", "SKILL.md", ".", ""].contains(action.object["path"] as? String ?? "") else { throw PetError("验收出现额外 Skill 资源") } }
                        else {
                            guard ["connect_mcp", "call_mcp_tool"].contains(action.name), action.object["server_id"] as? String == server.id else { throw PetError("验收出现额外审批：" + action.name) }
                            if action.name == "call_mcp_tool" {
                                let name = action.object["tool"] as? String ?? "", args = action.object["arguments"] as? [String: Any] ?? [:], path = args["path"] as? String ?? ""
                                let url = URL(fileURLWithPath: path)
                                let file = ["read_text_file", "read_file", "get_file_info", "write_file"].contains(name) && ["source.json", "character.png", "scoped-agent-report.json"].contains(url.lastPathComponent) && url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath() && (name != "write_file" || url.lastPathComponent == "scoped-agent-report.json")
                                let roots = name == "list_allowed_directories" && args.isEmpty
                                let directory = name == "list_directory" && url.standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath()
                                let paths = args["paths"] as? [String] ?? []
                                let multiple = name == "read_multiple_files" && !paths.isEmpty && paths.count <= 2 && paths.allSatisfy { let item = URL(fileURLWithPath: $0); return ["source.json", "scoped-agent-report.json"].contains(item.lastPathComponent) && item.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath() }
                                guard file || roots || directory || multiple else { throw PetError("验收不批准额外 MCP 操作") }
                            }
                        }
                        guard approved.count < 16 else { throw PetError("审批次数超出验收范围") }
                        childApproval = childApproval || pending.id != root; approved.insert(first.id); runtime.decide(taskID: pending.id, callID: first.id, decision: "allow")
                    }
                    await wait(0.1)
                }
                guard !runtime.isRunning(root), let completed = tasks.task(root), completed.status == .completed,
                      let meta = tasks.tasks.first(where: { $0.agent?.ownerID == root && $0.agent?.profile.id == auditor.id }), let result = tasks.task(meta.id) else { throw PetError("真实角色扩展任务未完成：" + (tasks.task(root)?.events.last?.detail ?? "超时")) }
                checks["actualParentAndScopedChildComplete"] = result.status == .completed && result.inputTokens > 0 && result.outputTokens > 0
                checks["actualSelectedSkillResourceRead"] = result.events.contains { $0.title == "read_skill_resource" && $0.status == "completed" }
                if let written = result.events.lastIndex(where: { $0.status == "completed" && $0.title.contains("write_file") && $0.detail.contains("scoped-agent-report.json") }) {
                    checks["actualSelectedMCPWriteAndReadback"] = result.events.dropFirst(written + 1).contains { $0.status == "completed" && $0.title.contains("read_") && $0.detail.contains("scoped-agent-report.json") }
                } else { checks["actualSelectedMCPWriteAndReadback"] = false }
                checks["actualChildApprovalsAppearInParent"] = childApproval && approved.count >= 5
                checks["noNativeFileOrCommandBypass"] = !result.events.contains { ["read_file", "write_file", "edit_file", "run_command"].contains($0.title) && $0.status == "completed" }
                let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("scoped-agent-report.json"))) as? [String: Any] ?? [:]
                checks["actualReportFollowsSelectedSkillProtocol"] = actual["format"] as? String == "scoped-skill-v1" && Set(actual.keys) == ["edition", "width", "height", "sha256", "imageBytes", "format"]
                report["live"] = ["parentID": root, "childID": result.id, "model": p.model, "contextLimit": p.contextLimit, "outputLimit": p.outputLimit, "approvals": approved.count, "report": actual]; tasks.selectedID = root
            }
            manager = AgentProfileWindow(store: tasks, workspace: workspace.path)
            checks.merge(await manager!.checkScopeLayout(output)) { _, value in value }
            report["configurationAtAcceptance"] = try JSONSerialization.jsonObject(with: Data(tasks.agents.document().0.utf8))
            report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
            report["scope"] = "Actual installed Skill snapshots, live per-tool/ancestor restrictions and official filesystem MCP processes. Saved real model child workflow only with --live-agent; no simulated model replies. Node independently checks actual files."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("agent-scope-report.json"), options: .atomic)
            if CommandLine.arguments.contains("--custom-agent-ui-hold") {
                control.show(tab: "chat"); manager?.showWindow(nil); manager?.window?.makeKeyAndOrderFront(nil)
                try Data("ui-ready".utf8).write(to: output.appendingPathComponent("phase"))
                let deadline = Date().addingTimeInterval(1200)
                while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
        } catch {
            report["error"] = error.localizedDescription; report["checks"] = checks; report["success"] = false
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("agent-scope-report.json"), options: .atomic)
            try? Data("finished".utf8).write(to: output.appendingPathComponent("phase"))
        }
    }
}
