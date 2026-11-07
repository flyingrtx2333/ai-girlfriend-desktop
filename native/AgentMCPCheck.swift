import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentMCPCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
        var manager: AgentMCPWindow?
        defer { agentRuntime?.stopAll(); if let library = agentStore?.mcp { library.disconnect(); for server in library.servers { try? library.remove(server.id, revision: server.revision) } } }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let library = tasks.mcp, workspace = output.appendingPathComponent("workspace")
            let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("fixtures.json"))) as? [String: String] ?? [:]
            guard let node = fixtures["node"], let entry = fixtures["serverEntry"] else { throw PetError("缺少实际官方文件服务") }
            let id = tasks.create(title: "MCP 原生验收", workspace: workspace.path)
            let tools = AgentTools(store: tasks, taskID: id)
            phase("official-filesystem-server")
            let config: [String: Any] = ["name": "公开素材文件", "type": "stdio", "command": node, "args": [entry, workspace.path], "env": ["BLUEFATFISH_MCP_CHECK": "public-mcp-check-value"], "timeoutSeconds": 20]
            var server = try library.save(json(config))
            let saved = try String(contentsOf: library.profile.appendingPathComponent("extensions/mcp.json"), encoding: .utf8), document = try library.document(server)
            checks["credentialsOnlyInKeychainAndEditorUsesPlaceholder"] = !saved.contains("public-mcp-check-value") && !document.contains("public-mcp-check-value") && document.contains(AgentMCP.placeholder)
            server = try library.save(document, id: server.id, expectedRevision: server.revision)
            do { _ = try library.save(document, id: server.id, expectedRevision: "outdated"); checks["configurationConflictRejected"] = false } catch { checks["configurationConflictRejected"] = true }
            tasks.update(id) { $0.permission = .automatic }
            let connect = try call("connect_mcp", ["server_id": server.id, "configuration": server.revision])
            checks["connectingRequiresApprovalEvenInAutomaticMode"] = try tools.approvalReason(for: connect) != nil
            let handshake = try await tools.execute(connect)
            report["stdioInitialize"] = handshake.text
            guard let token = library.token(server.id, owner: id), let pid = await library.processID(server.id, owner: id) else { throw PetError("实际文件服务未连接") }
            checks["officialServerHandshakeAndProcessAreReal"] = kill(pid, 0) == 0 && handshake.text.contains("tool_count")
            let directory = try library.catalog(server.id, owner: id, token: token, offset: 0)
            checks["directoryIsCompactAndDoesNotEagerlyLoadSchemas"] = try JSONSerialization.data(withJSONObject: directory).count < 6000 && (directory["tools"] as? [[String: Any]])?.allSatisfy { $0["inputSchema"] == nil } == true
            do { _ = try library.validateCall(server.id, owner: id, token: token, name: "write_file"); checks["actualSchemaRequiredBeforeCallingExternalTool"] = false } catch { checks["actualSchemaRequiredBeforeCallingExternalTool"] = true }
            let catalog = try library.catalog(server.id, owner: id, token: token, offset: 0, query: "read_text_file")
            checks["actualSchemaLoaded"] = (catalog["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "read_text_file" && $0["inputSchema"] is [String: Any] } == true
            _ = try await library.connect(server.id, revision: server.revision, owner: id, workspace: workspace.path)
            checks["redundantConnectPreservesSessionAndLoadedSchema"] = library.token(server.id, owner: id) == token && (try? library.validateCall(server.id, owner: id, token: token, name: "read_text_file")) != nil
            tasks.update(id) { $0.toolGroups = ["mcp"]; $0.contextSummary = "已整理的普通记录" }
            checks["currentConnectionSurvivesContextSummary"] = try runtime.systemContext(tasks.task(id)!).contains(token)
            let read = try call("call_mcp_tool", ["server_id": server.id, "connection": token, "tool": "read_text_file", "arguments": ["path": workspace.appendingPathComponent("source.json").path]])
            checks["externalReadStillRequiresApproval"] = try tools.approvalReason(for: read) != nil
            let actual = try await tools.execute(read)
            let source = try String(contentsOf: workspace.appendingPathComponent("source.json"), encoding: .utf8)
            checks["officialServerReadsActualSourceFile"] = !actual.failed && actual.text.contains(source.trimmingCharacters(in: .whitespacesAndNewlines))
            let other = tasks.create(title: "另一个 MCP 任务", workspace: workspace.path)
            do { _ = try library.catalog(server.id, owner: other, token: token, offset: 0); checks["connectionCannotCrossTasks"] = false } catch { checks["connectionCannotCrossTasks"] = true }
            tasks.update(other) { $0.mode = .ask }
            do { _ = try await AgentTools(store: tasks, taskID: other).execute(connect); checks["askModeCannotStartExternalProgram"] = false } catch { checks["askModeCannotStartExternalProgram"] = true }
            tasks.update(other) { $0.kind = "wiki"; $0.mode = .agent }
            do { _ = try await AgentTools(store: tasks, taskID: other).execute(call("list_mcp_servers", [:])); checks["wikiCannotUseExternalConnector"] = false } catch { checks["wikiCannotUseExternalConnector"] = true }
            let outside = try await library.call(server.id, owner: id, token: token, name: "read_text_file", arguments: ["path": output.appendingPathComponent("outside.txt").path])
            checks["officialFilesystemServerRejectsOutsideConfiguredRoot"] = outside.failed && !outside.text.contains("public-outside-marker")
            server = try library.save(document, id: server.id, expectedRevision: server.revision)
            do { _ = try library.validateCall(server.id, owner: id, token: token, name: "read_text_file"); checks["configurationChangeInvalidatesOldConnection"] = false } catch { checks["configurationChangeInvalidatesOldConnection"] = true }
            for _ in 0..<30 { if kill(pid, 0) != 0 { break }; await wait(0.1) }
            checks["disconnectTerminatesAndReapsLocalProcess"] = kill(pid, 0) != 0
            _ = try await library.connect(server.id, revision: server.revision, owner: id, workspace: workspace.path)
            let secondToken = library.token(server.id, owner: id)
            checks["reconnectHasNewConnectionToken"] = secondToken != nil && secondToken != token
            let oldRevision = server.revision; try library.setEnabled(server.id, false)
            checks["disabledConnectorClosesSession"] = library.token(server.id, owner: id) == nil
            try library.setEnabled(server.id, true); server = try library.server(server.id)
            checks["disableEnableInvalidatesPendingConfigurationApproval"] = oldRevision != server.revision

            phase("real-process-timeout-and-cancel")
            let sleeper = try library.save(json(["name": "实际超时进程", "type": "stdio", "command": "/bin/sleep", "args": ["30"], "env": [:], "timeoutSeconds": 5]))
            let timed = Task { try await library.connect(sleeper.id, revision: sleeper.revision, owner: id, workspace: workspace.path) }
            await wait(0.15); let timedPID = await library.processID(sleeper.id, owner: id), start = Date()
            do { _ = try await timed.value; checks["unresponsiveActualProcessTimesOut"] = false } catch { checks["unresponsiveActualProcessTimesOut"] = Date().timeIntervalSince(start) < 8 }
            await wait(0.15); checks["timeoutKillsActualProcess"] = timedPID.map { kill($0, 0) != 0 } == true
            let cancelled = Task { try await library.connect(sleeper.id, revision: sleeper.revision, owner: id, workspace: workspace.path) }
            await wait(0.15); let cancelPID = await library.processID(sleeper.id, owner: id), cancelStart = Date()
            cancelled.cancel(); library.disconnect(owner: id, serverID: sleeper.id)
            do { _ = try await cancelled.value; checks["cancelStopsHandshake"] = false } catch { checks["cancelStopsHandshake"] = Date().timeIntervalSince(cancelStart) < 2 }
            await wait(0.15); checks["cancelReapsActualProcess"] = cancelPID.map { kill($0, 0) != 0 } == true
            try library.remove(sleeper.id, revision: sleeper.revision)

            phase("public-streamable-http")
            let http = try library.save(json(["name": "DeepWiki 公开文档", "type": "http", "url": "https://mcp.deepwiki.com/mcp", "bearerToken": "", "timeoutSeconds": 30]))
            do {
                let connected = try await library.connect(http.id, revision: http.revision, owner: id, workspace: workspace.path)
                guard let connection = library.token(http.id, owner: id) else { throw PetError("HTTP 连接没有建立") }
                let schema = try library.catalog(http.id, owner: id, token: connection, offset: 0, query: "read_wiki_structure")
                checks["realHTTPHandshakeAndSchema"] = (schema["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "read_wiki_structure" } == true
                let result = try await library.call(http.id, owner: id, token: connection, name: "read_wiki_structure", arguments: ["repoName": "modelcontextprotocol/swift-sdk"])
                checks["realHTTPToolReturnsPublicRepositoryStructure"] = !result.failed && result.text.count > 100 && result.text.contains("swift-sdk")
                report["http"] = ["initialize": connected, "result": result.text, "endpoint": http.url ?? ""]
            } catch { checks["realHTTPHandshakeAndSchema"] = false; report["httpError"] = error.localizedDescription }
            try library.remove(http.id, revision: http.revision)

            if CommandLine.arguments.contains("--live-agent") {
                phase("real-model-mcp")
                let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: profile).preferences
                let savedOutputLimit = p.outputLimit
                if let flag = CommandLine.arguments.firstIndex(of: "--mcp-output-limit"), flag + 1 < CommandLine.arguments.count, let limit = Int(CommandLine.arguments[flag + 1]), (512...8192).contains(limit) { p.replyTokens = limit }
                p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
                let liveID = tasks.create(title: "实际 MCP 素材报告", workspace: workspace.path)
                tasks.update(liveID) { $0.permission = .automatic }
                runtime.submit("实际项目绝对路径：\(workspace.path)。已配置的 MCP 连接器“公开素材文件”仅允许此目录。仅通过 MCP 完成：读取此目录的 source.json，获取 character.png 的真实文件大小，写入 asset-report.json，字段 edition、width、height 来自 source.json，sha256 使用其中 outputSha256，imageBytes 使用 character.png 的实际字节数。写后通过 MCP 回读核对。不要改动 source.json 或图片，不使用文件/终端工具代替 MCP，不访问网络。每次按名称载入当前需要的工具，使用文件绝对路径。最后简短报告真实结果。", taskID: liveID)
                var approvals: [[String: Any]] = [], clarifications = 0; let deadline = Date().addingTimeInterval(240)
                while Date() < deadline, let task = tasks.task(liveID), [.ready, .running, .waiting].contains(task.status) {
                    if task.status == .waiting, let pending = task.pendingCalls.first {
                        if pending.name == "ask_user", let question = pending.object["question"] as? String, clarifications == 0,
                           question.contains("路径") || question.contains("根目录"), !["Token", "密码", "删除", "批准"].contains(where: { question.localizedCaseInsensitiveContains($0) }) {
                            clarifications += 1
                            runtime.decide(taskID: liveID, callID: pending.id, decision: "answer:项目绝对路径为 \(workspace.path)，source.json 和 character.png 均在此目录，连接器也仅允许此目录。继续原任务，仅用 MCP。")
                            continue
                        }
                        let action = try library.routedCall(pending, owner: liveID) ?? pending
                        guard approvals.count < 16, ["connect_mcp", "call_mcp_tool"].contains(action.name), action.object["server_id"] as? String == server.id else { throw PetError("真实 MCP 任务提出了预期外审批") }
                        if action.name == "call_mcp_tool" {
                            let name = action.object["tool"] as? String ?? "", args = action.object["arguments"] as? [String: Any] ?? [:], path = args["path"] as? String ?? ""
                            let fileCall = ["read_text_file", "read_file", "get_file_info", "write_file"].contains(name) && ["source.json", "character.png", "asset-report.json"].contains(URL(fileURLWithPath: path).lastPathComponent) && URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath() && (name != "write_file" || path.hasSuffix("/asset-report.json"))
                            let directoryCall = ["list_directory", "directory_tree", "list_directory_with_sizes", "search_files"].contains(name) && URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath()
                            let rootsCall = name == "list_allowed_directories" && args.isEmpty
                            let multi = args["paths"] as? [String] ?? []
                            let multiRead = name == "read_multiple_files" && !multi.isEmpty && multi.allSatisfy { ["source.json", "asset-report.json"].contains(URL(fileURLWithPath: $0).lastPathComponent) && URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == workspace.standardizedFileURL.resolvingSymlinksInPath() }
                            guard fileCall || rootsCall || directoryCall || multiRead else { throw PetError("MCP 动作超出公开素材验收范围：" + name) }
                            if name == "write_file", checks["realModelWriteWaitsForExplicitApproval"] == nil { checks["realModelWriteWaitsForExplicitApproval"] = !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("asset-report.json").path) }
                        }
                        approvals.append(["name": pending.name, "arguments": pending.object]); runtime.decide(taskID: liveID, callID: pending.id, decision: "allow")
                    }; await wait(0.1)
                }
                guard let task = tasks.task(liveID) else { throw PetError("真实 MCP 任务丢失") }
                if runtime.isRunning(liveID) || task.status == .waiting { runtime.cancel(liveID) }
                checks["realModelUsesMCPDiscoveryAndSchema"] = task.events.contains { $0.title == "connect_mcp" && $0.status == "completed" } && task.events.contains { $0.title == "list_mcp_tools" && $0.status == "completed" }
                checks["realModelCompletesViaActualMCPCalls"] = task.status == .completed && FileManager.default.fileExists(atPath: workspace.appendingPathComponent("asset-report.json").path)
                checks["realModelDoesNotBypassMCP"] = !task.events.contains { ["run_command", "read_file", "write_file"].contains($0.title) }
                checks["realModelCallsOriginalMCPParameterSchemas"] = task.messages.flatMap { $0.toolCalls ?? [] }.contains { AgentMCP.isModelToolName($0.name) }
                report["live"] = ["status": task.status.rawValue, "model": p.model, "contextLimit": p.contextLimit, "outputLimit": p.outputLimit, "savedOutputLimit": savedOutputLimit, "approvals": approvals, "knownProjectPathClarifications": clarifications, "summary": task.summary, "events": task.events.map { ["name": $0.title, "status": $0.status, "detail": $0.detail] }]
                tasks.selectedID = liveID; control.show(tab: "chat")
            }
            if CommandLine.arguments.contains("--mcp-ui-hold") { manager = AgentMCPWindow(service: library, workspace: workspace.path); manager?.showWindow(nil); manager?.window?.makeKeyAndOrderFront(nil) }
            phase("finished")
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["scope"] = "Actual official filesystem MCP server 2.2.0, public DeepWiki Streamable HTTP, real processes and optionally saved real model. Independent profile and public repository assets. No simulated MCP or model replies."
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mcp-report.json"))
        if CommandLine.arguments.contains("--mcp-ui-hold") {
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
        }
        manager?.close()
    }
}
