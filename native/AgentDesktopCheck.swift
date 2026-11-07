import AppKit

@MainActor extension AppDelegate {
    func runAgentDesktopCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        let fm = FileManager.default, nativeReport = output.appendingPathComponent("desktop-native-report.json")
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时不可用") }
            try write(["appPID": getpid(), "arguments": CommandLine.arguments], "desktop-process.json")
            if fm.fileExists(atPath: nativeReport.path) {
                let prior = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeReport)) as! [String: Any]
                guard prior["success"] as? Bool == true, let values = prior["checks"] as? [String: Bool] else { throw PetError("原生权限入口检查未通过") }; checks = values
            } else {
                let id = tasks.create(title: "电脑操作权限边界"), tools = AgentTools(store: tasks, taskID: id), desktop = tasks.desktop
                checks["actualDefaultConfigurationIsDisabledAndAbsent"] = try !desktop.configuration().enabled && desktop.configuration().hash == nil
                let status = try await tools.execute(call("desktop_status"))
                let statusValues = try JSONSerialization.jsonObject(with: Data(status.text.utf8)) as? [String: Any]
                checks["actualStatusDoesNotRequestOperatingSystemAccess"] = !status.failed && statusValues?["enabled"] as? Bool == false
                do { _ = try tools.approvalReason(for: call("desktop_windows", ["query": "TextEdit"])); checks["disabledReadIsBlockedBeforeWindowEnumeration"] = false } catch { checks["disabledReadIsBlockedBeforeWindowEnumeration"] = error.localizedDescription.contains("启用此功能") }
                try desktop.configure(enabled: true, expectedHash: nil)
                checks["explicitPrivateConfigurationPersistsEnabledState"] = try desktop.configuration().enabled
                do { try desktop.configure(enabled: false, expectedHash: nil); checks["staleConfigurationCannotOverwriteCurrentState"] = false } catch { checks["staleConfigurationCannotOverwriteCurrentState"] = try desktop.configuration().enabled }
                let readOnly = AgentProfile(name: "只读桌面边界", description: "实际原生权限检查", instructions: "只读", tools: AgentDesktop.tools, readOnly: true, network: true, enabled: true)
                var isolated = readOnly; isolated.id = UUID().uuidString; isolated.name = "禁止外部应用边界"; isolated.readOnly = false; isolated.network = false
                let profileData = try JSONEncoder().encode([readOnly, isolated]), values = try JSONSerialization.jsonObject(with: profileData)
                try tasks.agents.save(String(decoding: try JSONSerialization.data(withJSONObject: ["agents": values]), as: UTF8.self), expectedHash: nil)
                let readOnlyID = try tasks.agents.createTask(readOnly.id, store: tasks, workspace: nil), isolatedID = try tasks.agents.createTask(isolated.id, store: tasks, workspace: nil)
                do { _ = try AgentTools(store: tasks, taskID: readOnlyID).approvalReason(for: call("desktop_action", ["action": "key", "revision": "unknown", "key": "cmd+s"])); checks["actualReadOnlyRoleRejectsDesktopMutationBeforeSystemAccess"] = false } catch { checks["actualReadOnlyRoleRejectsDesktopMutationBeforeSystemAccess"] = error.localizedDescription.contains("只读") }
                do { _ = try AgentTools(store: tasks, taskID: isolatedID).approvalReason(for: call("desktop_connect", ["target_id": "unknown"])); checks["actualIsolatedRoleRejectsExternalApplicationConnection"] = false } catch { checks["actualIsolatedRoleRejectsExternalApplicationConnection"] = error.localizedDescription.contains("外部应用连接") }
                for mode in [AgentMode.ask, .plan] {
                    tasks.update(id) { $0.mode = mode }
                    do { _ = try tools.approvalReason(for: call("desktop_action", ["action": "key", "key": "cmd+s", "revision": "unknown"])); checks[mode.rawValue + "ActuallyRejectsDesktopActions"] = false } catch { checks[mode.rawValue + "ActuallyRejectsDesktopActions"] = error.localizedDescription.contains("计划模式") }
                }
                tasks.update(id) { $0.mode = .agent; $0.kind = "hook"; $0.hookTools = ["read_file"] }
                do { _ = try await tools.execute(call("desktop_status")); checks["hookCannotExpandIntoDesktopTools"] = false } catch { checks["hookCannotExpandIntoDesktopTools"] = true }
                tasks.update(id) { $0.kind = nil }
                let defs = AgentTools.definitions(mode: .agent, groups: ["desktop"]), names = Set(defs.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
                checks["actualDesktopGroupExposesAllSevenTools"] = Set(AgentDesktop.tools).isSubset(of: names)
                checks["readOnlyAndWikiSchemasExcludeDesktopMutation"] = !AgentTools.definitions(mode: .ask, groups: ["desktop"]).contains { ($0["function"] as? [String: Any])?["name"] as? String == "desktop_action" } && !AgentTools.definitions(mode: .agent, kind: "wiki").contains { AgentDesktop.tools.contains(($0["function"] as? [String: Any])?["name"] as? String ?? "") }
                let config = try desktop.configuration(); try desktop.configure(enabled: false, expectedHash: config.hash)
                let permission = try fm.attributesOfItem(atPath: store.directory.appendingPathComponent("computer-use/settings.json").path)[.posixPermissions] as? Int
                checks["actualConfigurationIsPrivateAndDisabledAfterCheck"] = try permission == 0o600 && !AgentDesktop(profile: store.directory).configuration().enabled
                checks["noModelWasCalledForPermissionChecks"] = tasks.tasks.allSatisfy { (tasks.task($0.id)?.modelReceipts ?? []).isEmpty }
                try write(["success": checks.values.allSatisfy { $0 }, "checks": checks, "actualPermissions": desktop.status], nativeReport.lastPathComponent)
            }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("电脑操作权限入口检查未通过") }
            control.showDesktopSettings()
            try write(["appPID": getpid(), "actualPermissions": tasks.desktop.status, "nativeChecks": checks.count], "desktop-ui-ready.json")
            if CommandLine.arguments.contains("--live-agent") {
                let deadline = Date().addingTimeInterval(1800)
                while !fm.fileExists(atPath: output.appendingPathComponent("start-desktop-live").path), Date() < deadline {
                    if fm.fileExists(atPath: output.appendingPathComponent("stop-desktop-check").path) { throw PetError("验收已停止，未调用模型") }
                    await wait(0.25)
                }
                guard fm.fileExists(atPath: output.appendingPathComponent("start-desktop-live").path), tasks.desktop.status["enabled"] as? Bool == true, tasks.desktop.status["accessibility"] as? Bool == true, tasks.desktop.status["screen_recording"] as? Bool == true else { throw PetError("真实桌面验收等待用户启用并完成两项系统授权") }
                let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("public-document.json"))) as! [String: String]
                guard let name = fixture["name"], let expected = fixture["expected"], let path = fixture["path"] else { throw PetError("公开验收文档不存在") }
                var preferences = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
                preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
                let intent = "只通过电脑操作工具连接系统‘文本编辑’中名称为‘\(name)’的窗口。将‘审阅人：待填写’改成‘审阅人：海盐-7319’，保留其余内容，保存并回读确认。不要读取或操作其他窗口；不要用文件、终端、浏览器或 MCP 代替图形界面操作。"
                let owner = output.appendingPathComponent("desktop-live-task.json"), id: String
                if fm.fileExists(atPath: owner.path) {
                    let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as! [String: String]
                    guard let originalID = existing["taskID"], let original = tasks.task(originalID), original.messages.first(where: \.isHumanInput)?.content == intent else { throw PetError("原始真实桌面任务不存在或要求已变化，不能替换重跑") }
                    id = originalID
                    if original.status != .completed { runtime.start(id) }
                } else {
                    let role = AgentProfile(name: "实际桌面验收", description: "仅操作公开的文本编辑窗口", instructions: "只通过分配的电脑工具完成用户指定窗口操作，核对实际结果。", tools: AgentDesktop.tools, readOnly: false, network: true, enabled: true)
                    let (_, version) = try tasks.agents.document(), data = try JSONEncoder().encode(try tasks.agents.list() + [role]), values = try JSONSerialization.jsonObject(with: data)
                    try tasks.agents.save(String(decoding: try JSONSerialization.data(withJSONObject: ["agents": values]), as: UTF8.self), expectedHash: version)
                    id = try tasks.agents.createTask(role.id, store: tasks, workspace: output.path)
                    tasks.update(id) { $0.title = "实际文本编辑窗口保存" }
                    guard runtime.submit(intent, taskID: id) else { throw PetError("真实模型任务未开始") }
                    try write(["taskID": id, "document": path, "originalInputID": tasks.task(id)?.messages.first(where: \.isHumanInput)?.id ?? ""], owner.lastPathComponent)
                }
                control.showAgentTask(id); control.show(tab: "chat")
                var approvals = 0, rejections = 0
                let finish = Date().addingTimeInterval(300)
                while Date() < finish {
                    if fm.fileExists(atPath: output.appendingPathComponent("stop-desktop-check").path) { runtime.cancel(id); throw PetError("真实桌面验收已停止，保留原任务与请求计量") }
                    guard let task = tasks.task(id) else { throw PetError("实际任务不存在") }
                    if task.status == .waiting, let action = task.pendingCalls.first {
                        var allowed = false
                        if action.name == "desktop_windows" { let query = action.object["query"] as? String ?? ""; allowed = ["textedit", "文本编辑", "com.apple.textedit"].contains(query.lowercased()) }
                        if action.name == "desktop_connect" { allowed = task.approvals.last(where: { $0.call.id == action.id })?.reason.contains(name) == true }
                        if action.name == "desktop_action" {
                            let kind = action.object["action"] as? String ?? ""
                            allowed = kind == "set_value" && action.object["value"] as? String == expected || kind == "type" && action.object["value"] as? String == expected || kind == "key" && ["cmd+a", "command+a", "super+a", "cmd+s", "command+s", "super+s"].contains((action.object["key"] as? String ?? "").lowercased())
                        }
                        guard approvals < 12, rejections < 3 else { throw PetError("真实任务超出限定操作次数") }
                        runtime.decide(taskID: id, callID: action.id, decision: allowed ? "allow" : "deny")
                        if allowed { approvals += 1 } else { rejections += 1 }
                    }
                    if task.status == .completed, !runtime.isExecuting(id) { break }
                    if [.failed, .stopped].contains(task.status), !runtime.isExecuting(id) { throw PetError("真实电脑操作任务未完成") }
                    await wait(0.05)
                }
                let task = tasks.task(id)!, actual = try String(contentsOfFile: path, encoding: .utf8)
                checks["actualTextEditSavedExactExpectedDocument"] = actual == expected
                checks["actualModelTaskCompleted"] = task.status == .completed && !runtime.isExecuting(id)
                let successful = task.events.filter { $0.kind == "tool" && $0.status == "completed" }
                checks["actualModelUsedApprovedDesktopConnectionAndAction"] = successful.contains { $0.title == "desktop_connect" } && successful.contains { $0.title == "desktop_action" }
                checks["actualModelDidNotBypassGraphicalApplication"] = task.messages.flatMap { $0.toolCalls ?? [] }.allSatisfy { (AgentDesktop.tools + ["load_tools", "read_task_history", "update_plan"]).contains($0.name) }
                report["live"] = ["taskID": id, "approvals": task.approvals.filter { $0.decision == "allow" }.count, "newApprovals": approvals, "rejections": task.approvals.filter { $0.decision == "deny" }.count, "newRejections": rejections, "model": preferences.model, "contextLimit": preferences.contextLimit, "outputLimit": preferences.outputLimit, "requests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "documentSHA256": AgentFiles.hash(Data(actual.utf8))]
            }
            report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks; report["actualPermissions"] = tasks.desktop.status
            try write(report, "desktop-report.json")
            if CommandLine.arguments.contains("--hold-ui") {
                let deadline = Date().addingTimeInterval(1200)
                while !fm.fileExists(atPath: output.appendingPathComponent("finish-desktop-ui").path), Date() < deadline { await wait(0.25) }
            }
            tasks.desktop.disconnectAll(); runtime.stopAll()
        } catch { report["success"] = false; report["error"] = error.localizedDescription; report["checks"] = checks; try? write(report, "desktop-report.json"); agentRuntime?.stopAll() }
    }
}
