import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentHookCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        var manager: AgentHookWindow?
        func phase(_ text: String) { try? Data(text.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        defer { agentRuntime?.stopAll(); manager?.close() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let service = tasks.hooks, workspace = output.appendingPathComponent("workspace"), script = workspace.appendingPathComponent(".bluefatfish/hooks/lifecycle.py")
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("config-fixtures.json").path) {
                checks.merge(try await checkAgentHookConfiguration(output)) { _, latest in latest }
                let document = try service.document(project: true, workspace: workspace.path)
                try service.save(document.0, project: true, workspace: workspace.path, expectedHash: document.1)
            }
            let id = tasks.create(title: "实际 Hook 命令检查", workspace: workspace.path)
            tasks.update(id) { $0.messages.append(AgentMessage(role: "user", content: "public-token-marker")) }
            phase("actual-command-hooks")
            let catalog = try service.catalog(workspace: workspace.path)
            checks["discoveredHooksAreDisabledByDefault"] = !catalog.isEmpty && catalog.allSatisfy { !service.enabled($0) }
            checks["globalAndProjectSourcesMerge"] = Set(catalog.map(\.scope)).isSuperset(of: ["全局", "项目", "共享项目"])
            for hook in catalog where hook.diagnostic == nil { try service.setEnabled(hook, true, workspace: workspace.path) }
            let cliDeny = try await service.fire(.permission, trigger: UUID().uuidString, store: tasks, taskID: id, value: "PermissionCLICheck")
            let ideDeny = try await service.fire(.permission, trigger: UUID().uuidString, store: tasks, taskID: id, value: "PermissionIDECheck")
            checks["cliPermissionDecisionDenyIsEnforced"] = cliDeny.deny == "CLI 规则拒绝"
            checks["idePermissionDecisionDenyIsEnforced"] = ideDeny.deny == "IDE 规则拒绝"
            do { _ = try await service.fire(.permission, trigger: UUID().uuidString, store: tasks, taskID: id, value: "PermissionRewriteCheck"); checks["unsupportedPermissionRewriteFailsClosed"] = false } catch { checks["unsupportedPermissionRewriteFailsClosed"] = true }
            let first = try await service.fire(.sessionStart, trigger: "actual-command-start", store: tasks, taskID: id, fields: ["marker": "public-token-marker"], secret: "public-token-marker")
            checks["commandReceivesActualJSONAndReturnsContext"] = first.context.contains("真实素材版本")
            let global = try String(contentsOf: workspace.appendingPathComponent("global-hook-ran.json"), encoding: .utf8)
            checks["globalScriptReadableButPrivateProfileDenied"] = global.contains("privateDenied") && global.contains("true")
            let auditFile = workspace.appendingPathComponent("hooks-audit.jsonl"), auditBefore = try Data(contentsOf: auditFile)
            _ = try await service.fire(.sessionStart, trigger: "actual-command-start", store: tasks, taskID: id, fields: ["marker": "public-token-marker"], secret: "public-token-marker")
            checks["sameTriggerDoesNotReplayHookCommands"] = try Data(contentsOf: auditFile) == auditBefore
            checks["payloadAndTranscriptRedactCredential"] = !String(decoding: auditBefore, as: UTF8.self).contains("public-token-marker") && String(decoding: auditBefore, as: UTF8.self).contains("tokenRedacted")
            do { try service.save("{\"hooks\":{}}", project: true, workspace: workspace.path, expectedHash: "outdated"); checks["configEditorRejectsConflictingSave"] = false } catch { checks["configEditorRejectsConflictingSave"] = true }
            let original = try Data(contentsOf: script)
            try (original + Data("\n# actual changed script\n".utf8)).write(to: script)
            do { _ = try await service.fire(.preTool, trigger: UUID().uuidString, store: tasks, taskID: id, value: "Write"); checks["changedScriptRevokesExecutionGrant"] = false } catch { checks["changedScriptRevokesExecutionGrant"] = true }
            try original.write(to: script)
            let link = script.deletingLastPathComponent().appendingPathComponent("linked-script.py")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
            checks["symlinkResourceCannotBeEnabled"] = try service.catalog(workspace: workspace.path).filter { $0.scope == "项目" }.allSatisfy { $0.diagnostic != nil && !service.trusted($0) }
            try FileManager.default.removeItem(at: link)

            let readOnly = output.appendingPathComponent("readonly-workspace"); try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
            let readOnlyID = tasks.create(title: "只读 Hook", workspace: readOnly.path, mode: .ask)
            _ = try await service.fire(.sessionStart, trigger: UUID().uuidString, store: tasks, taskID: readOnlyID)
            checks["askModeHookCannotWriteProject"] = !FileManager.default.fileExists(atPath: readOnly.appendingPathComponent("global-hook-ran.json").path) && tasks.task(readOnlyID)?.events.contains { $0.kind == "hook" && $0.status == "failed" } == true
            let network = try await service.fire(.preTool, trigger: UUID().uuidString, store: tasks, taskID: id, value: "NetworkCheck")
            checks["hookNetworkDisabledByKernel"] = network.context.contains("errno=1")
            let timed = Date(), timeout = try await service.fire(.preTool, trigger: UUID().uuidString, store: tasks, taskID: id, value: "TimeoutCheck")
            let pidFile = workspace.appendingPathComponent("hook-child.pid")
            var child = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            for _ in 0..<30 { if child.map({ kill($0, 0) != 0 }) == true { break }; await wait(0.05) }
            checks["timeoutStopsHookAndChildProcess"] = timeout.halt != nil && Date().timeIntervalSince(timed) < 4 && child.map { kill($0, 0) != 0 } == true
            try? FileManager.default.removeItem(at: pidFile)
            let cancelled = Task { try await service.fire(.preTool, trigger: UUID().uuidString, store: tasks, taskID: id, value: "CancelCheck") }
            for _ in 0..<40 { if FileManager.default.fileExists(atPath: pidFile.path) { break }; await wait(0.05) }
            child = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            let cancelStart = Date(); cancelled.cancel(); service.cancel(id)
            do { _ = try await cancelled.value; checks["cancelInterruptsActualHook"] = false } catch { checks["cancelInterruptsActualHook"] = Date().timeIntervalSince(cancelStart) < 2 }
            for _ in 0..<30 { if child.map({ kill($0, 0) != 0 }) == true { break }; await wait(0.05) }
            checks["cancelReapsHookChildProcess"] = child.map { kill($0, 0) != 0 } == true

            if CommandLine.arguments.contains("--live-agent") {
                let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: profile).preferences
                p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
                let rejectedID = tasks.create(title: "真实输入拦截", workspace: workspace.path)
                runtime.submit("HOOK_REJECT_PUBLIC_INPUT_9184", taskID: rejectedID)
                for _ in 0..<200 { if !runtime.isRunning(rejectedID) { break }; await wait(0.05) }
                guard let rejected = tasks.task(rejectedID) else { throw PetError("输入检查任务丢失") }
                checks["rejectedUserInputNeverReachesModel"] = rejected.messages.contains { $0.hookRejected == true } && rejected.inputTokens == 0 && !AgentContext.window(rejected).contains { $0.content.contains("HOOK_REJECT_PUBLIC_INPUT_9184") }
                let historyCall = AgentToolCall(id: UUID().uuidString, name: "read_task_history", arguments: "{\"offset\":0,\"limit\":10}")
                let history = try await AgentTools(store: tasks, taskID: rejectedID).execute(historyCall)
                checks["historyToolCannotRetrieveRejectedInput"] = !history.text.contains("HOOK_REJECT_PUBLIC_INPUT_9184")

                phase("saved-real-model")
                let liveID = tasks.create(title: "实际素材 Hooks 流程", workspace: workspace.path)
                tasks.update(liveID) { $0.permission = .review }
                runtime.submit("在当前项目生成素材报告。先用 write_file 尝试创建 blocked.md，内容为 hook-check；如果被 Hook 拦截，不重试该文件。读取 source.json，用 write_file 创建 report.json，内容为合法 JSON，字段 edition、width、height、sha256、imageBytes、reviewer：前三项来自 source.json，sha256 使用其中 outputSha256，imageBytes 使用 character.png 的真实字节数（可用 run_command 执行 wc -c < character.png），reviewer 必须通过 ask_user 向我询问审阅人，不要猜测。不要修改输入文件或 hooks 配置，不访问网络。写后用 read_file 回读工具返回的实际产物路径并核对。自动处理器可能补充字段，保留它们。完成后简短报告。", taskID: liveID)
                var approvals: [[String: Any]] = []
                var rejectedAnswer = false
                let deadline = Date().addingTimeInterval(240)
                while Date() < deadline, let task = tasks.task(liveID), [.ready, .running, .waiting].contains(task.status) {
                    if task.status == .waiting, let call = task.pendingCalls.first {
                        guard approvals.count < 12 else { throw PetError("真实 Hook 流程审批过多") }
                        if call.name == "ask_user" {
                            guard !rejectedAnswer else { throw PetError("审阅人已提供，模型再次提问") }
                            rejectedAnswer = true; let priorTokens = task.inputTokens
                            runtime.submit("HOOK_REJECT_PUBLIC_INPUT_9184", taskID: liveID)
                            for _ in 0..<200 { if !runtime.isRunning(liveID) { break }; await wait(0.05) }
                            let blocked = tasks.task(liveID)!
                            checks["rejectedAnswerKeepsQuestionOpenWithoutCallingModel"] = blocked.status == .waiting && blocked.inputTokens == priorTokens && blocked.hookRejectedAnswers?.contains { $0.content.contains("HOOK_REJECT_PUBLIC_INPUT_9184") } == true && !AgentContext.window(blocked).contains { $0.content.contains("HOOK_REJECT_PUBLIC_INPUT_9184") }
                            guard checks["rejectedAnswerKeepsQuestionOpenWithoutCallingModel"] == true else { throw PetError("被拦截的答复未正确保留问题状态") }
                            runtime.submit("海盐-7319", taskID: liveID)
                            approvals.append(["name": "ask_user", "rejectedThenAcceptedPublicAnswer": true]); continue
                        }
                        let files = try AgentFiles(workspace: workspace.path)
                        if ["write_file", "edit_file"].contains(call.name) {
                            guard let path = call.object["path"] as? String, try files.resolve(path) == files.resolve("checked-report.json") else { throw PetError("改写后的审批路径不符合素材任务范围") }
                            if call.name == "write_file", checks["rewrittenToolWaitsForApprovalBeforeWriting"] == nil { checks["rewrittenToolWaitsForApprovalBeforeWriting"] = !FileManager.default.fileExists(atPath: (try files.resolve("checked-report.json")).path) && call.originalArguments != nil }
                        } else if call.name == "run_command" {
                            let command = call.object["command"] as? String ?? ""
                            guard call.object["network"] as? Bool != true, command.trimmingCharacters(in: .whitespacesAndNewlines) == "wc -c < character.png" || command.trimmingCharacters(in: .whitespacesAndNewlines) == "wc -c character.png" else { throw PetError("模型提出了素材验收范围外的命令：" + command) }
                        } else { throw PetError("模型提出了预期外审批：" + call.name) }
                        approvals.append(["name": call.name, "arguments": call.object, "originalArguments": call.originalArguments ?? ""])
                        runtime.decide(taskID: liveID, callID: call.id, decision: "allow")
                    }; await wait(0.1)
                }
                guard let task = tasks.task(liveID) else { throw PetError("真实 Hook 任务丢失") }
                if runtime.isRunning(liveID) || task.status == .waiting { runtime.cancel(liveID) }
                let hooks = task.events.compactMap(\.hook)
                checks["realModelCompletesAfterActualHooks"] = task.status == .completed
                checks["preHookBlocksActualModelWrite"] = hooks.contains { $0.event == .preTool && $0.effect?.deny != nil } && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("blocked.md").path)
                checks["updatedInputUsedByActualTool"] = !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("report.json").path) && task.messages.flatMap { $0.toolCalls ?? [] }.contains { $0.originalArguments != nil && $0.object["path"] as? String == "checked-report.json" }
                let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("checked-report.json"))) as? [String: Any] ?? [:]
                checks["postHookFormatsActualOutput"] = actual["hookFormatted"] as? Bool == true && hooks.contains { $0.event == .postTool && $0.exitCode == 0 }
                checks["stopHookRequiresActualFollowupVerification"] = hooks.contains { $0.event == .stop && $0.effect?.deny != nil } && actual["verifiedByAgent"] as? Bool == true
                checks["approvalResumeDoesNotReplayPreHook"] = Dictionary(grouping: hooks.filter { $0.event == .preTool }, by: \.key).values.allSatisfy { $0.count == 1 }
                checks["lifecycleAndPermissionEventsReachRealCommands"] = Set(hooks.map(\.event)).isSuperset(of: [.sessionStart, .sessionEnd, .prompt, .preTool, .postTool, .toolFailure, .permission, .notification, .stop, .instructions, .file])
                checks["toolWireMessagesStayPaired"] = task.messages.enumerated().allSatisfy { index, message in
                    guard let calls = message.toolCalls, !calls.isEmpty else { return true }
                    return Set(task.messages.dropFirst(index + 1).prefix(calls.count).compactMap(\.toolCallID)) == Set(calls.map(\.id))
                }
                report["live"] = ["taskID": liveID, "status": task.status.rawValue, "model": p.model, "contextLimit": p.contextLimit, "outputLimit": p.outputLimit, "approvals": approvals, "summary": task.summary, "events": task.events.map { ["name": $0.title, "status": $0.status, "detail": $0.detail] }]
                tasks.selectedID = liveID; control.show(tab: "chat")
            }
            if CommandLine.arguments.contains("--hook-ui-hold") { manager = AgentHookWindow(service: service, workspace: workspace.path); manager?.showWindow(nil); manager?.window?.makeKeyAndOrderFront(nil) }
            phase("finished")
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["scope"] = "Actual sandboxed command Hooks, literal exec argv, Bash, environment/keychain configuration, real local HTTP hashes, process groups, file changes, native UI and optionally saved real model; independent profile and public repository assets. No simulated model responses. Full HTTP/model and async workflows retain their separate focused acceptance."
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("hook-report.json"))
        if CommandLine.arguments.contains("--hook-ui-hold") {
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
        }
    }
}
