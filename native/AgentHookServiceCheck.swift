import AppKit

@MainActor extension AppDelegate {
    func runAgentHookServiceCheck(_ output: URL) async {
        if CommandLine.arguments.contains("--hook-service-cancel-only") {
            var result: [String: Any] = [:], checks: [String: Bool] = [:]
            do {
                ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
                let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: profile).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
                let key = try PetKeychain(service: "com.xjs.bluefatfish.credentials").read("chat")
                let workspace = output.appendingPathComponent("workspace"), id = tasks.create(title: "实际模型输出中停止校验", workspace: workspace.path)
                let document = try tasks.hooks.document(project: false, workspace: workspace.path)
                let object: [String: Any] = ["hooks": ["Notification": [["matcher": "^cancel_model$", "hooks": [["name": "实际流式校验停止", "type": "prompt", "prompt": "判断当前通知是否清楚。只返回 {ok, reason} JSON，reason 使用中文逐项解释通知字段、数据来源、是否能核对事实以及未知项，尽可能完整。", "timeout": 30]]]]]]
                let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                try tasks.hooks.save(text, project: false, workspace: workspace.path, expectedHash: document.1)
                guard let hook = try tasks.hooks.catalog(workspace: workspace.path).first(where: { $0.name == "实际流式校验停止" }) else { throw PetError("校验配置未载入") }
                try tasks.hooks.setEnabled(hook, true, workspace: workspace.path)
                var sawOutput = false, cancelAt: Date?, childID: String?
                do {
                    _ = try await tasks.hooks.fire(.notification, trigger: UUID().uuidString, store: tasks, taskID: id, value: "cancel_model", fields: ["message": "本机公开素材版本 19，核对请求来自一次实际 UI 停止验收。"], secret: key, preferences: p) {
                        guard !sawOutput, let child = tasks.task(id)?.events.last(where: { $0.hook?.childTaskID != nil })?.hook?.childTaskID, let record = tasks.task(child), record.messages.last?.role == "assistant", record.messages.last?.content.isEmpty == false else { return }
                        sawOutput = true; childID = child; cancelAt = Date(); runtime.cancel(child)
                    }
                    checks["actualStreamingModelCancelled"] = false
                } catch { checks["actualStreamingModelCancelled"] = sawOutput && cancelAt.map { Date().timeIntervalSince($0) < 3 } == true }
                checks["cancelledEvaluatorIsStopped"] = childID.flatMap { tasks.task($0) }?.status == .stopped
                checks["cancelLeavesNoActiveOwnerOrChild"] = !runtime.isRunning(id) && childID.map { !runtime.isRunning($0) } == true
                checks["parentHookShowsStoppedOutcome"] = tasks.task(id)?.events.last(where: { $0.hook != nil })?.status == "stopped"
                result["model"] = p.model; result["contextLimit"] = p.contextLimit; result["outputLimit"] = p.outputLimit; result["childTaskID"] = childID
                result["scope"] = "Saved real model emitted actual response text; the same runtime cancellation used by the managed-task Stop button then stopped the evaluator and owner hook. No simulated stream."
                try tasks.hooks.setEnabled(hook, false, workspace: workspace.path)
            } catch { result["error"] = error.localizedDescription }
            result["checks"] = checks; result["success"] = result["error"] == nil && checks.count == 4 && checks.values.allSatisfy { $0 }
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("hook-service-cancel-report.json"))
            agentRuntime?.stopAll(); return
        }
        if CommandLine.arguments.contains("--hook-service-ui-only") {
            ensureAgent()
            if let data = try? Data(contentsOf: output.appendingPathComponent("hook-service-report.json")), let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let live = report["live"] as? [String: Any], let id = live["taskID"] as? String, agentStore?.task(id)?.status == .completed {
                agentStore?.selectedID = id; control.show(tab: "chat")
                try? Data("ready".utf8).write(to: output.appendingPathComponent("ui-only-phase"))
                let deadline = Date().addingTimeInterval(600)
                while Date() < deadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui-verdict").path) { await wait(0.25) }
            }
            agentRuntime?.stopAll(); return
        }
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        var manager: AgentHookWindow?
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
        func state() -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("server-state.json")))) as? [String: Any]) ?? [:] }
        defer {
            agentRuntime?.stopAll(); manager?.close()
            if let service = agentStore?.hooks, let workspace = agentStore?.selected?.workspace { for hook in (try? service.catalog(workspace: workspace)) ?? [] where hook.type == "http" { try? service.clearCredentials(hook, workspace: workspace) } }
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let service = tasks.hooks, workspace = output.appendingPathComponent("workspace")
            let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("fixtures.json"))) as? [String: Any] ?? [:]
            guard let endpoint = fixtures["endpoint"] as? String, let authorization = fixtures["authorization"] as? String else { throw PetError("缺少实际 HTTP 服务配置") }
            let id = tasks.create(title: "实际 HTTP Hook 边界", workspace: workspace.path)
            phase("actual-http-hook-service")
            let cases: [(String, String, Int)] = [("echo", "/echo-credential", 10), ("redirect", "/redirect", 10), ("invalid", "/invalid", 10), ("timeout", "/slow", 1), ("disable", "/slow", 10)]
            let groups: [[String: Any]] = cases.map { name, route, timeout in ["matcher": "^" + name + "$", "hooks": [["name": name, "type": "http", "url": endpoint + route, "headers": ["X-Hook-Key": authorization], "timeout": timeout]]] }
            try service.save(json(["hooks": ["Notification": groups]]), project: false, workspace: workspace.path, expectedHash: nil)
            var catalog = try service.catalog(workspace: workspace.path)
            checks["httpHandlersDiscoveredDisabled"] = catalog.count == cases.count && catalog.allSatisfy { $0.type == "http" && $0.diagnostic == nil && !service.enabled($0) }
            let saved = try String(contentsOf: service.file(project: false, workspace: nil), encoding: .utf8), editor = try service.document(project: false, workspace: nil).0
            checks["literalHeadersMovedToKeychainAndEditorMasked"] = !saved.contains(authorization) && !editor.contains(authorization) && saved.contains(AgentHookHTTP.placeholder) && catalog.allSatisfy { service.credentials.available($0) }
            for hook in catalog { try service.setEnabled(hook, true, workspace: workspace.path) }
            let echoed = try await service.fire(.notification, trigger: UUID().uuidString, store: tasks, taskID: id, value: "echo")
            checks["actualHTTPReceivesAuthorizedJSONPost"] = (state()["requests"] as? [[String: Any]])?.contains { $0["path"] as? String == "/echo-credential" && $0["authorized"] as? Bool == true && $0["event"] as? String == "Notification" } == true
            checks["credentialEchoRedactedFromResultAndEvents"] = echoed.systemMessage?.contains("凭据已隐藏") == true && !(echoed.systemMessage ?? "").contains(authorization) && !(tasks.task(id)?.events.contains { $0.detail.contains(authorization) } ?? true)
            do { _ = try await service.fire(.notification, trigger: UUID().uuidString, store: tasks, taskID: id, value: "redirect"); checks["redirectNotFollowed"] = false } catch { checks["redirectNotFollowed"] = state()["captureCount"] as? Int == 0 }
            do { _ = try await service.fire(.notification, trigger: UUID().uuidString, store: tasks, taskID: id, value: "invalid"); checks["invalidHTTPOutputFailsClosed"] = false } catch { checks["invalidHTTPOutputFailsClosed"] = true }
            checks["httpFailureNotAutomaticallyReplayed"] = (state()["requests"] as? [[String: Any]])?.filter { $0["path"] as? String == "/invalid" }.count == 1
            let started = Date()
            do { _ = try await service.fire(.notification, trigger: UUID().uuidString, store: tasks, taskID: id, value: "timeout"); checks["httpTimeoutStopsRequest"] = false } catch { checks["httpTimeoutStopsRequest"] = Date().timeIntervalSince(started) < 3 }
            let active = Task { try await service.fire(.notification, trigger: UUID().uuidString, store: tasks, taskID: id, value: "disable") }
            for _ in 0..<40 { if ((state()["requests"] as? [[String: Any]])?.filter { $0["path"] as? String == "/slow" }.count ?? 0) >= 2 { break }; await wait(0.05) }
            guard let disable = catalog.first(where: { $0.name == "disable" }) else { throw PetError("未找到实际请求") }
            let cancelStart = Date(); try service.setEnabled(disable, false, workspace: workspace.path)
            do { _ = try await active.value; checks["disableCancelsActualHTTPRequest"] = false } catch { checks["disableCancelsActualHTTPRequest"] = Date().timeIntervalSince(cancelStart) < 2 }
            for _ in 0..<40 { if state()["closedSlowClients"] as? Int ?? 0 >= 2 { break }; await wait(0.05) }
            checks["cancelAndTimeoutCloseServerConnections"] = state()["closedSlowClients"] as? Int ?? 0 >= 2
            let document = try service.document(project: false, workspace: nil)
            do { try service.save(document.0.replacingOccurrences(of: "/echo-credential", with: "/different-destination"), project: false, workspace: workspace.path, expectedHash: document.1); checks["credentialCannotBeReboundToChangedDestination"] = false } catch { checks["credentialCannotBeReboundToChangedDestination"] = true }
            try service.save("{\"hooks\":{}}", project: false, workspace: workspace.path, expectedHash: document.1)
            checks["removingHTTPHandlersClearsTheirCredentials"] = catalog.allSatisfy { !service.credentials.available($0) }

            phase("actual-readonly-evaluator-boundaries")
            let readID = tasks.create(title: "校验工具边界", workspace: workspace.path)
            tasks.update(readID) { $0.kind = "hook"; $0.hookTools = ["read_file", "run_command"]; $0.hookNetwork = false; $0.permission = .automatic }
            let tools = AgentTools(store: tasks, taskID: readID)
            func call(_ name: String, _ object: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: try json(object)) }
            do { _ = try await tools.execute(call("write_file", ["path": "evaluator-write.txt", "content": "blocked"])); checks["evaluatorCannotUseWriteTool"] = false } catch { checks["evaluatorCannotUseWriteTool"] = !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("evaluator-write.txt").path) }
            let write = try await tools.execute(call("run_command", ["command": "printf blocked > evaluator-shell-write.txt", "timeout_seconds": 5]))
            checks["evaluatorShellIsActuallyReadonly"] = write.failed && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("evaluator-shell-write.txt").path)
            do { _ = try await tools.execute(call("run_command", ["command": "true", "network": true])); checks["evaluatorCannotAddNetworkPermission"] = false } catch { checks["evaluatorCannotAddNetworkPermission"] = true }
            do { _ = try await tools.execute(call("connect_mcp", [:])); checks["evaluatorCannotUseExternalConnector"] = false } catch { checks["evaluatorCannotUseExternalConnector"] = true }
            checks["managedEvaluatorCannotAcceptNewUserTask"] = !runtime.submit("更改校验任务", taskID: readID)
            _ = try await service.fire(.prompt, trigger: UUID().uuidString, store: tasks, taskID: readID, fields: ["prompt": "不递归"])
            checks["evaluatorsDoNotRecursivelyInvokeHooks"] = tasks.task(readID)?.events.isEmpty == true

            let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var p = PreferencesStore(directory: profile).preferences
            p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
            let config = try String(contentsOf: output.appendingPathComponent("service-hooks-import.json"), encoding: .utf8)
            try service.save(config, project: true, workspace: workspace.path, expectedHash: nil)
            catalog = try service.catalog(workspace: workspace.path)
            checks["allThreeServiceHandlerTypesLoad"] = Set(catalog.map(\.type)) == Set(["http", "prompt", "agent"]) && catalog.allSatisfy { $0.diagnostic == nil }
            for hook in catalog { try service.setEnabled(hook, true, workspace: workspace.path) }
            phase("real-model-with-http-prompt-agent-hooks")
            let liveID = tasks.create(title: "HTTP 与模型校验实际素材", workspace: workspace.path)
            tasks.update(liveID) { $0.permission = .review }
            runtime.submit("在当前项目完成素材报告。先分别用 write_file 尝试创建 http-forbidden.md（内容 # Header）和 model-blocked.md（内容 没有标题）。若被校验规则阻止，不重试对应文件，继续原任务。读取 source.json，使用 wc -c < character.png 获取实际字节数，用 write_file 创建 report.json，字段 edition、width、height 来自 source.json，sha256 使用其中 outputSha256，imageBytes 使用实际字节数。不要修改输入、配置或其他文件，不访问网络。回读 report.json 确认；如结束检查指出缺少字段，依据真实文件补齐并再次回读。最后简短报告。", taskID: liveID)
            var approvals = 0; let deadline = Date().addingTimeInterval(360)
            while Date() < deadline, let task = tasks.task(liveID), [.ready, .running, .waiting].contains(task.status) {
                if task.status == .waiting, let action = task.pendingCalls.first {
                    guard approvals < 12 else { throw PetError("模型提出了过多审批") }
                    if ["write_file", "edit_file"].contains(action.name) {
                        let files = try AgentFiles(workspace: workspace.path)
                        guard let path = action.object["path"] as? String, try files.resolve(path) == files.resolve("report.json") else { throw PetError("校验后的审批路径不属于报告") }
                    } else if action.name == "run_command" {
                        guard action.object["network"] as? Bool != true, ["wc -c < character.png", "wc -c character.png"].contains((action.object["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else { throw PetError("模型提出了实际素材任务以外的命令") }
                    } else { throw PetError("模型提出了预期外的审批：" + action.name) }
                    approvals += 1; runtime.decide(taskID: liveID, callID: action.id, decision: "allow")
                }; await wait(0.1)
            }
            guard let task = tasks.task(liveID) else { throw PetError("真实素材任务丢失") }
            if runtime.isRunning(liveID) || task.status == .waiting { runtime.cancel(liveID) }
            let hooks = task.events.compactMap(\.hook), children = tasks.tasks.filter { $0.parentID == liveID }.compactMap { tasks.task($0.id) }
            checks["realParentCompletesAfterAllThreeHandlers"] = task.status == .completed
            checks["actualHTTPRuleBlocksModelWrite"] = task.events.contains { $0.title == "HTTP 文件规则" && $0.hook?.effect?.deny != nil } && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("http-forbidden.md").path)
            checks["actualPromptModelBlocksUntitledDocument"] = task.events.contains { $0.title == "独立模型内容检查" && $0.hook?.effect?.deny != nil } && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("model-blocked.md").path)
            checks["HTTPStopReadsAndRejectsActualIncompleteReport"] = task.events.contains { $0.title == "HTTP 实际产物核对" && $0.hook?.effect?.deny != nil }
            checks["agentModelReadsActualFilesAndUsesStructuredOutput"] = children.contains { child in child.events.contains { $0.title == "read_file" && $0.status == "completed" && $0.detail.hasPrefix("source.json") } && child.events.contains { $0.title == "read_file" && $0.status == "completed" && $0.detail.hasPrefix("report.json") } && child.events.contains { $0.title == "StructuredOutput" && $0.status == "completed" } }
            checks["agentStopRequiresActualCorrection"] = task.events.contains { $0.title == "Agent 文件复核" && $0.hook?.effect?.deny != nil }
            checks["evaluationsHaveIndependentUsageAndTaskRecords"] = !children.isEmpty && children.allSatisfy { $0.kind == "hook" && $0.model == p.model && $0.inputTokens > 0 && $0.messages.first?.content.contains("hook_event_name") == true }
            checks["parentEventsLinkActualChildTasks"] = hooks.filter { $0.childTaskID != nil }.allSatisfy { value in children.contains { $0.id == value.childTaskID && $0.inputTokens == value.inputTokens && $0.outputTokens == value.outputTokens } }
            checks["approvalResumeDoesNotReplayServiceHandlers"] = Dictionary(grouping: hooks, by: \.key).values.allSatisfy { $0.count == 1 }
            checks["profilesAndLogsContainNoHTTPHeaderSecret"] = try FileManager.default.subpathsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".json") || $0.hasSuffix(".jsonl") }.allSatisfy { path in !String(decoding: (try? Data(contentsOf: store.directory.appendingPathComponent(path))) ?? Data(), as: UTF8.self).contains(authorization) }
            report["live"] = ["taskID": liveID, "status": task.status.rawValue, "model": p.model, "contextLimit": p.contextLimit, "outputLimit": p.outputLimit, "approvals": approvals, "summary": task.summary, "events": task.events.map { ["name": $0.title, "status": $0.status, "detail": $0.detail] }, "children": children.map { ["id": $0.id, "status": $0.status.rawValue, "inputTokens": $0.inputTokens, "outputTokens": $0.outputTokens, "summary": $0.summary, "events": $0.events.map { ["name": $0.title, "status": $0.status, "detail": $0.detail] }] }]
            tasks.selectedID = liveID; control.show(tab: "chat")
            if CommandLine.arguments.contains("--hook-service-ui-hold") { manager = AgentHookWindow(service: service, workspace: workspace.path); manager?.showWindow(nil); manager?.window?.makeKeyAndOrderFront(nil) }
            phase("finished")
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["scope"] = "Actual HTTP policy service independently reads repository assets and report; actual saved model performs parent task plus isolated prompt/agent evaluations. Native tool and network boundaries are real; no simulated model replies."
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("hook-service-report.json"))
        if CommandLine.arguments.contains("--hook-service-ui-hold") {
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
        }
    }
}
