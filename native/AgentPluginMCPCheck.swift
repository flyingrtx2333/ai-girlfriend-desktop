import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentPluginMCPCheck(_ output: URL) async {
        let fm = FileManager.default
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        func write(_ value: [String: Any], _ name: String) throws { try Data(json(value).utf8).write(to: output.appendingPathComponent(name), options: .atomic) }
        func waitFor(_ name: String) async throws {
            let deadline = Date().addingTimeInterval(1200)
            while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent(name).path) { await wait(0.1) }
            guard fm.fileExists(atPath: output.appendingPathComponent(name).path) else { throw PetError("等待实际界面操作超时：" + name) }
        }
        func livePIDs(_ name: String) throws -> [Int32] {
            let url = output.appendingPathComponent(name); guard fm.fileExists(atPath: url.path) else { return [] }
            return Array(Set(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line -> Int32? in
                guard let data = String(line).data(using: .utf8), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = row["pid"] as? Int32, row["transport"] as? String == "stdio", kill(pid, 0) == 0 else { return nil }; return pid
            }))
        }
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时不可用") }
            let plugins = tasks.extensions.plugins, mcp = tasks.mcp, workspace = output.appendingPathComponent("repo")
            try write(["appPID": getpid(), "arguments": CommandLine.arguments], "plugin-mcp-process.json")
            let nativeReport = output.appendingPathComponent("plugin-mcp-native.json")
            if fm.fileExists(atPath: nativeReport.path) {
                let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeReport)) as! [String: Any]
                guard previous["success"] as? Bool == true, let values = previous["checks"] as? [String: Bool] else { throw PetError("原生检查未完成，不能跳过") }; checks = values
            } else {
                let package = try await plugins.inspect(output.appendingPathComponent("native-ledger.zip")), installed = try plugins.install(package)
                guard var server = mcp.servers.first(where: { $0.plugin?.name == installed.id }) else { throw PetError("插件 MCP 未出现在连接器目录") }
                checks["mcpOnlyPackageInstallsWithoutLaunchingOrSavingConfiguration"] = try installed.receipt.components.isEmpty && installed.mcpServers.count == 1 && server.configured == false && server.pluginEnabled == false && livePIDs("native-requests.jsonl").isEmpty
                do { _ = try mcp.server(server.id); checks["unconfiguredPluginCannotConnect"] = false } catch { checks["unconfiguredPluginCannotConnect"] = true }
                let template = try mcp.document(server)
                do { _ = try mcp.save(template, id: server.id, expectedRevision: server.revision); checks["requiredVariableCannotBeSilentlyDropped"] = false } catch { checks["requiredVariableCannotBeSilentlyDropped"] = true }
                var value = try JSONSerialization.jsonObject(with: Data(template.utf8)) as! [String: Any]; value["env"] = ["LEDGER_CSV": workspace.appendingPathComponent("sales.csv").path]
                server = try mcp.save(json(value), id: server.id, expectedRevision: server.revision)
                checks["configurationStartsDisabledAndRootVariableExpands"] = !server.enabled && server.args.first?.contains(installed.root.appendingPathComponent("payload").path) == true && server.timeoutSeconds == 20
                do { try mcp.setEnabled(server.id, true); checks["connectorCannotBypassDisabledParent"] = false } catch { checks["connectorCannotBypassDisabledParent"] = true }
                try plugins.setEnabled(plugins.installation(installed.id), true); try mcp.setEnabled(server.id, true); server = try mcp.server(server.id)
                let oldRevision = server.revision, firstOwner = "native-first", secondOwner = "native-second"
                _ = try await mcp.connect(server.id, revision: server.revision, owner: firstOwner, workspace: workspace.path)
                _ = try await mcp.connect(server.id, revision: server.revision, owner: secondOwner, workspace: workspace.path)
                guard let token = mcp.token(server.id, owner: firstOwner), let firstPID = await mcp.processID(server.id, owner: firstOwner), let secondPID = await mcp.processID(server.id, owner: secondOwner) else { throw PetError("真实本机连接未建立") }
                _ = try mcp.catalog(server.id, owner: firstOwner, token: token, offset: 0, query: "sum_sales")
                let result = try await mcp.call(server.id, owner: firstOwner, token: token, name: "sum_sales", arguments: [:])
                checks["bundledNodeConnectorReadsActualCsv"] = !result.failed && result.text.contains("43.65") && result.text.contains("sourceSha256") && kill(firstPID, 0) == 0 && kill(secondPID, 0) == 0
                try plugins.setEnabled(plugins.installation(installed.id), false)
                for _ in 0..<40 { if kill(firstPID, 0) != 0 && kill(secondPID, 0) != 0 { break }; await wait(0.1) }
                checks["parentDisableTerminatesAllOwnersActualProcesses"] = kill(firstPID, 0) != 0 && kill(secondPID, 0) != 0 && mcp.token(server.id, owner: firstOwner) == nil && mcp.token(server.id, owner: secondOwner) == nil
                try plugins.setEnabled(plugins.installation(installed.id), true); server = try mcp.server(server.id)
                checks["parentReenableRotatesApprovalWithoutAutoReconnect"] = try server.revision != oldRevision && livePIDs("native-requests.jsonl").isEmpty
                do { _ = try await mcp.connect(server.id, revision: oldRevision, owner: firstOwner, workspace: workspace.path); checks["oldConnectionApprovalCannotReviveAfterReenable"] = false } catch { checks["oldConnectionApprovalCannotReviveAfterReenable"] = true }
                do { _ = try mcp.validateCall(server.id, owner: firstOwner, token: token, name: "sum_sales"); checks["oldToolTokenCannotReviveAfterReenable"] = false } catch { checks["oldToolTokenCannotReviveAfterReenable"] = true }
                server = try mcp.save(mcp.document(server), id: server.id, expectedRevision: server.revision)
                _ = try await mcp.connect(server.id, revision: server.revision, owner: firstOwner, workspace: workspace.path)
                checks["keychainPlaceholderSurvivesParentAndConfigurationRevisionChanges"] = try mcp.token(server.id, owner: firstOwner) != nil && !String(contentsOf: mcp.profile.appendingPathComponent("extensions/mcp.json"), encoding: .utf8).contains(workspace.appendingPathComponent("sales.csv").path)
                let entry = installed.root.appendingPathComponent("payload/server.mjs"), bytes = try Data(contentsOf: entry)
                try Data("changed resource".utf8).write(to: entry, options: .atomic)
                do { _ = try mcp.catalog(server.id, owner: firstOwner, token: mcp.token(server.id, owner: firstOwner)!, offset: 0); checks["changedBundledCodeInvalidatesLiveCalls"] = false } catch { checks["changedBundledCodeInvalidatesLiveCalls"] = true }
                try bytes.write(to: entry, options: .atomic); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: entry.path)
                try plugins.setEnabled(plugins.installation(installed.id), false)
                let legacyPackage = try await plugins.inspect(output.appendingPathComponent("legacy-plugin.zip")), legacy = try plugins.install(legacyPackage), receiptURL = legacy.root.appendingPathComponent("receipt.json")
                var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]; receipt.removeValue(forKey: "installationID"); receipt.removeValue(forKey: "activationID"); try Data(json(receipt).utf8).write(to: receiptURL, options: .atomic)
                checks["existingSkillCommandReceiptsStillDecode"] = try plugins.installation(legacy.id).receipt.components.count == 1
                let custom = try mcp.save(json(["name": "原有独立连接器", "type": "stdio", "command": "/usr/bin/true", "args": [], "env": [:], "timeoutSeconds": 20]))
                checks["ordinaryMcpKeepsIndependentLifecycle"] = custom.plugin == nil && custom.enabled && mcp.servers.contains(where: { $0.id == server.id })
                for headers in [["Host": "invalid"], ["X-Test": "invalid\r\nInjected: true"], ["X-Test\n": "invalid"], ["X-Test": "a", "x-test": "b"]] {
                    do { try AgentMCP.validateHeaders(headers); throw PetError("无效请求头意外通过") } catch { guard error.localizedDescription != "无效请求头意外通过" else { throw error } }
                }
                checks["httpHeaderInjectionAndCaseAliasesAreRejected"] = true
                guard !checks.isEmpty, checks.values.allSatisfy({ $0 }) else { throw PetError("插件 MCP 原生检查未通过") }
                try write(["success": true, "checks": checks], nativeReport.lastPathComponent)
            }
            if CommandLine.arguments.contains("--live-agent") {
                var preferences = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
                preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
                let intent = "/skill:ledger-tools:reconcile 分别用插件的本机和 HTTP 连接器计算当前 sales.csv，核对结果一致后写入 reconciliation.json，包含 stdio 和 http 两份实际结果，再回读核对。保留输入文件。"
                let ownerURL = output.appendingPathComponent("plugin-mcp-live-task.json"), id: String
                if fm.fileExists(atPath: ownerURL.path) {
                    let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: ownerURL)) as! [String: String]
                    guard let previousID = previous["taskID"], let task = tasks.task(previousID), task.messages.isEmpty || task.messages.first(where: \.isHumanInput)?.content == intent else { throw PetError("原真实任务不存在或输入已变化") }; id = previousID
                } else {
                    let installID = tasks.create(title: "插件连接器安装验收", workspace: workspace.path, mode: .ask)
                    control.prepareExtensionCheckWindow(taskID: installID, manager: true)
                    try write(["phase": "install-and-configure", "appPID": getpid(), "archive": output.appendingPathComponent("ledger-tools.zip").path, "csv": workspace.appendingPathComponent("sales.csv").path], "plugin-mcp-ui-ready.json")
                    try await waitFor("start-plugin-mcp-workflow")
                    let installed = try plugins.installation("ledger-tools"), stdio = try mcp.server(mcp.servers.first(where: { $0.name == "ledger-tools:local" })!.id)
                    checks["actualUIImportsEnablesConfiguresAndConnectsPluginStdio"] = try installed.receipt.enabled && stdio.configured == true && !livePIDs("live-requests.jsonl").isEmpty
                    guard checks["actualUIImportsEnablesConfiguresAndConnectsPluginStdio"] == true, let http = mcp.servers.first(where: { $0.name == "ledger-tools:remote" }), let skill = try tasks.extensions.catalog(workspace: workspace.path).first(where: { $0.name == "ledger-tools:reconcile" }) else { throw PetError("真实插件界面配置未完成") }
                    var config = try JSONSerialization.jsonObject(with: Data(mcp.document(http).utf8)) as! [String: Any]
                    let key = try String(contentsOf: output.appendingPathComponent("private/http-key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    config["headers"] = ["X-Ledger-Key": key]; let saved = try mcp.save(json(config), id: http.id, expectedRevision: http.revision); try mcp.setEnabled(saved.id, true)
                    checks["httpHeaderCredentialIsAbsentFromConfigAndEditor"] = try !mcp.document(mcp.server(saved.id)).contains(key) && !String(contentsOf: mcp.profile.appendingPathComponent("extensions/mcp.json"), encoding: .utf8).contains(key)
                    let role = AgentProfile(name: "插件销售连接器", description: "使用已分配的两个实际销售连接器", instructions: "按选定 Skill 使用实际 MCP 工具完成核对。", tools: ["read_file", "write_file"], readOnly: false, network: true, enabled: true, skills: [skill.id], mcpServers: [stdio.id, saved.id])
                    try tasks.agents.save(tasks.agents.encode(tasks.agents.list() + [role]), expectedHash: tasks.agents.document().1)
                    id = try tasks.agents.createTask(role.id, store: tasks, workspace: workspace.path); try write(["taskID": id], ownerURL.lastPathComponent)
                    try write(checks, "plugin-mcp-live-checks.json")
                }
                if let data = try? Data(contentsOf: output.appendingPathComponent("plugin-mcp-live-checks.json")), let previous = try JSONSerialization.jsonObject(with: data) as? [String: Bool] { checks.merge(previous) { _, next in next } }
                control.prepareExtensionCheckWindow(taskID: id, manager: false)
                if tasks.task(id)?.messages.isEmpty == true { try write(["phase": "ready-to-send", "taskID": id, "appPID": getpid(), "intent": intent], "plugin-mcp-ui-ready.json") }
                else if tasks.task(id)?.status != .completed { runtime.start(id) }
                let deadline = Date().addingTimeInterval(1200); var approvals = 0
                while Date() < deadline {
                    guard let task = tasks.task(id) else { throw PetError("真实任务丢失") }
                    let receipts = task.modelReceipts ?? []
                    if receipts.count > 24 || receipts.filter({ $0.purpose == "conversation" }).count > 16 { runtime.cancel(id); throw PetError("真实任务超过16次对话／24次总请求上限，保留原任务") }
                    if task.status == .waiting, let pending = task.pendingCalls.first {
                        let action = try mcp.routedCall(pending, owner: id) ?? pending
                        let assigned = task.agent?.mcpServers ?? []
                        let connector = ["connect_mcp", "call_mcp_tool"].contains(action.name) && assigned.contains(action.object["server_id"] as? String ?? "") && (action.name != "call_mcp_tool" || action.object["tool"] as? String == "sum_sales" && (action.object["arguments"] as? [String: Any])?.isEmpty == true)
                        let writeResult = action.name == "write_file" && (try? AgentFiles(workspace: workspace.path).resolve(action.object["path"] as? String ?? "")) == workspace.appendingPathComponent("reconciliation.json")
                        guard approvals < 8, connector || writeResult else { throw PetError("真实插件连接器任务提出预期外审批") }
                        runtime.decide(taskID: id, callID: pending.id, decision: "allow"); approvals += 1
                    }
                    if task.status == .completed && !runtime.isExecuting(id) { break }
                    if [.failed, .stopped].contains(task.status), !runtime.isExecuting(id) { throw PetError("真实插件连接器任务失败：" + (task.events.last?.detail ?? "")) }; await wait(0.1)
                }
                guard let task = tasks.task(id), task.status == .completed, task.messages.first(where: \.isHumanInput)?.content == intent else { throw PetError("真实插件连接器任务未完成") }
                let calls = task.messages.flatMap { $0.toolCalls ?? [] }, writeIndex = calls.firstIndex { $0.name == "write_file" }
                checks["realModelReadsBackSavedReconciliation"] = writeIndex.map { calls.dropFirst($0 + 1).contains { $0.name == "read_file" && URL(fileURLWithPath: $0.object["path"] as? String ?? "").lastPathComponent == "reconciliation.json" } } == true
                control.showAgentTask(id); control.show(tab: "chat")
                try write(["phase": "model-completed", "taskID": id, "appPID": getpid(), "requests": task.modelReceipts?.count ?? 0], "plugin-mcp-ui-ready.json")
                try await waitFor("begin-plugin-mcp-lifecycle")
                let current = mcp.servers.filter { $0.plugin?.name == "ledger-tools" }, versions = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.revision) }), pids = try livePIDs("live-requests.jsonl")
                checks["managerStdioProcessIsActuallyAliveBeforeParentDisable"] = !pids.isEmpty
                control.showAgentTask(id); control.show(tab: "chat")
                try write(["phase": "completed", "taskID": id, "appPID": getpid(), "requests": task.modelReceipts?.count ?? 0, "liveStdioPIDs": pids], "plugin-mcp-ui-ready.json")
                try await waitFor("verify-plugin-mcp-disabled")
                for _ in 0..<40 { if pids.allSatisfy({ kill($0, 0) != 0 }) { break }; await wait(0.1) }
                checks["actualUIParentDisableTerminatesRemainingManagerProcesses"] = try !plugins.installation("ledger-tools").receipt.enabled && !pids.isEmpty && pids.allSatisfy { kill($0, 0) != 0 }
                for (serverID, revision) in versions { do { _ = try mcp.server(serverID, revision: revision); throw PetError("旧配置意外有效") } catch { guard error.localizedDescription != "旧配置意外有效" else { throw error } } }
                checks["actualUIDisableBlocksPreviouslyApprovedConfigurations"] = true
                try write(["success": true], "plugin-mcp-disabled-verified.json")
                try await waitFor("finish-plugin-mcp-ui")
                checks["actualUIReenableDoesNotReplayOldConnections"] = try plugins.installation("ledger-tools").receipt.enabled && mcp.servers.filter({ $0.plugin?.name == "ledger-tools" }).allSatisfy { $0.revision != versions[$0.id] } && livePIDs("live-requests.jsonl").isEmpty
                checks["actualUITrashRemovesOnlyOwnedFixturePlugin"] = !fm.fileExists(atPath: plugins.profile.appendingPathComponent("extensions/plugins/native-ledger").path) && fm.fileExists(atPath: plugins.profile.appendingPathComponent("extensions/plugins/ledger-tools").path)
                let final = tasks.task(id)!
                checks["uiLifecycleAddsNoRequestsOrMessages"] = final.messages.map(\.id) == task.messages.map(\.id) && final.modelReceipts?.count == task.modelReceipts?.count
                report["live"] = ["taskID": id, "model": preferences.model, "requests": final.modelReceipts?.count ?? 0, "inputTokens": final.inputTokens, "outputTokens": final.outputTokens, "approvals": final.approvals.filter { $0.decision == "allow" }.count, "context": preferences.contextLimit, "output": preferences.outputLimit]
            }
            report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }; try write(report, "plugin-mcp-report.json")
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? write(report, "plugin-mcp-report.json") }
    }
}
