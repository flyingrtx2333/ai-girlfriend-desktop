import AppKit
import Darwin

@MainActor extension AppDelegate {
    func checkTaskExecutionPreferences(_ output: URL) async throws -> [String: Bool] {
        let root = output.appendingPathComponent("execution-preferences"), profile = root.appendingPathComponent("profile"), home = root.appendingPathComponent("shared-home"), workspace = root.appendingPathComponent("workspace")
        for directory in [profile, home, workspace] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let initializer = AgentCommand()
        let initialized = try await initializer.run(command: try AgentGit.executablePath(), workspace: workspace, scratch: root, network: false, timeout: 5, gitWrite: true, arguments: ["init", "--quiet"])
        guard !initialized.failed else { throw PetError("无法建立独立验收仓库：" + initialized.text) }
        let keychain = PetKeychain(service: "com.xjs.bluefatfish.native-input-check." + UUID().uuidString)
        let tasks = AgentStore(directory: profile, legacy: [], extensionHome: home, mcpKeychain: keychain, hookKeychain: keychain)
        var preferences = PetPreferences(); preferences.endpoint = "https://native-check.invalid"; preferences.voiceEnabled = false
        let runtime = AgentRuntime(store: tasks, keychain: keychain) { preferences }
        var settings = AgentGeneralSettings.Settings(), blocked = 0, completions: [String] = [], checks: [String: Bool] = [:], traces: [[String: Any]] = []
        runtime.taskSettings = { settings }
        runtime.modelRequestCheck = { blocked += 1; throw PetError("原生执行设置检查禁止模型请求") }
        runtime.onComplete = { id, _ in completions.append(id) }
        defer {
            runtime.stopAll()
            let report: [String: Any] = ["checks": checks, "traces": traces, "blockedModelAttempts": blocked, "modelRequests": 0, "keychainWrites": 0, "boundary": "Native pending-call fixtures and actual local command processes exercise controller behavior. Guarded attempts stop before AgentModel.turn. The final counter preflight has an empty isolated credential and fails before network access; no model response is simulated or claimed."]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"))
        }
        func until(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline { if condition() { return true }; await wait(0.02) }; return condition()
        }
        func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }
        func seed(_ name: String, mode: AgentMode = .agent) -> String {
            let id = tasks.create(title: name, workspace: workspace.path, mode: mode)
            tasks.update(id) { $0.permission = .automatic; $0.messages = [AgentMessage(role: "user", content: "原生控制流程检查：" + name)]; $0.draft = "尚未发送的中文草稿 🧭" }
            return id
        }
        func pending(_ id: String, call: AgentToolCall, waiting: Bool = false) {
            tasks.update(id) { record in
                record.messages.append(AgentMessage(role: "assistant", content: "", toolCalls: [call], nativeContext: true))
                record.pendingCalls = [call]
                var approval = AgentApproval(call: call, reason: "原生检查明确指定的本机命令", workspace: workspace.path)
                if !waiting { approval.decision = "allow"; approval.decidedAt = Date() }
                record.approvals.append(approval); record.status = waiting ? .waiting : .ready
            }
        }
        func command(_ name: String, _ text: String) -> AgentToolCall { AgentToolCall(id: name + "-" + UUID().uuidString, name: "run_command", arguments: String(decoding: try! JSONSerialization.data(withJSONObject: ["command": text, "network": false, "timeout_seconds": 35]), as: UTF8.self)) }
        func startSleeping(_ name: String) async throws -> (String, pid_t, AgentToolCall) {
            let id = seed(name), marker = workspace.appendingPathComponent(name + ".pid")
            let call = command(name, "printf '%s' $$ > " + name + ".pid\nexec /bin/sleep 30")
            pending(id, call: call); runtime.start(id)
            guard await until({ FileManager.default.fileExists(atPath: marker.path) }), let text = try? String(contentsOf: marker), let pid = pid_t(text), alive(pid) else { throw PetError("本机命令未开始：" + name + "；" + (tasks.task(id)?.events.last?.detail ?? "无事件")) }
            traces.append(["taskID": id, "processID": pid, "phase": name, "started": true]); return (id, pid, call)
        }
        let source = workspace.appendingPathComponent("公开附件.txt"); try Data("公开的附件正文，保留原始内容。".utf8).write(to: source)
        let (queuedID, queuedPID, queuedCall) = try await startSleeping("queue")
        let queuedAttachment = try await AgentAttachments.importFile(source, store: tasks, taskID: queuedID)
        checks["QueueAcceptsMessageWithActualAttachment"] = runtime.submit("下一轮补充", taskID: queuedID, attachmentIDs: [queuedAttachment.id])
        checks["QueueLeavesCurrentNativeProcessRunning"] = alive(queuedPID) && runtime.isExecuting(queuedID) && tasks.task(queuedID)?.pendingCalls.first?.id == queuedCall.id && tasks.task(queuedID)?.queuedCount == 1
        runtime.cancel(queuedID); _ = await until { !alive(queuedPID) }
        checks["ExplicitStopFlushesQueuedAttachmentExactlyOnce"] = !runtime.isExecuting(queuedID) && tasks.task(queuedID)?.status == .stopped && tasks.task(queuedID)?.messages.filter { $0.content == "下一轮补充" && $0.attachmentIDs == [queuedAttachment.id] }.count == 1 && tasks.task(queuedID)?.draftAttachmentIDs?.contains(queuedAttachment.id) != true

        settings.runningInput = .interrupt
        let (interruptID, interruptPID, interruptCall) = try await startSleeping("interrupt")
        let attachment = try await AgentAttachments.importFile(source, store: tasks, taskID: interruptID), before = blocked
        var overlap = false
        runtime.modelRequestCheck = { overlap = overlap || alive(interruptPID); blocked += 1; throw PetError("插话检查禁止模型请求") }
        checks["InterruptAcceptsAttachmentAndKeepsStoppingRunBusy"] = runtime.submit("立即插话一", taskID: interruptID, attachmentIDs: [attachment.id]) && runtime.isExecuting(interruptID)
        _ = runtime.submit("立即插话二", taskID: interruptID)
        _ = await until { !runtime.isExecuting(interruptID) }
        let interrupted = tasks.task(interruptID)!
        checks["RepeatedInterruptRestartsOnceAfterOldProcessExits"] = !alive(interruptPID) && !overlap && blocked == before + 1
        checks["InterruptedCallHasOneStoppedResultAndCannotResume"] = interrupted.pendingCalls.isEmpty && interrupted.messages.filter { $0.toolCallID == interruptCall.id }.count == 1 && interrupted.events.contains { $0.toolCallID == interruptCall.id && $0.status == "stopped" }
        checks["InterruptKeepsBothInputsAndActualAttachment"] = interrupted.messages.filter { $0.content == "立即插话一" && $0.attachmentIDs == [attachment.id] }.count == 1 && interrupted.messages.filter { $0.content == "立即插话二" }.count == 1 && interrupted.draft == "尚未发送的中文草稿 🧭" && interrupted.queuedCount == 0 && interrupted.messages.allSatisfy { $0.content != "继续完成原任务，保留之前的约束。" }
        let copied = try AgentAttachments.source(store: tasks, taskID: interruptID, id: attachment.id)
        checks["InterruptPreservesAttachmentBytes"] = try Data(contentsOf: copied) == Data(contentsOf: source)

        runtime.modelRequestCheck = { blocked += 1; throw PetError("原生设置检查禁止模型请求") }
        let (stoppedID, stoppedPID, _) = try await startSleeping("stop-after-interrupt"), stoppedBefore = blocked
        _ = runtime.submit("插话后停止", taskID: stoppedID); runtime.cancel(stoppedID)
        _ = await until { !alive(stoppedPID) }; await wait(0.1)
        checks["ExplicitStopDuringInterruptionCancelsAutomaticRestart"] = !runtime.isExecuting(stoppedID) && tasks.task(stoppedID)?.status == .stopped && blocked == stoppedBefore && tasks.task(stoppedID)?.messages.filter { $0.content == "插话后停止" }.count == 1

        settings.goalMaximumTurns = 5
        let goal = seed("最后一轮的实际工具授权", mode: .goal), call = command("last-goal-tool", "/usr/bin/uname")
        pending(goal, call: call, waiting: true); tasks.update(goal) { $0.goalExecution = AgentGoalExecution(maximumTurns: 5, usedTurns: 5) }
        let goalBefore = blocked; runtime.decide(taskID: goal, callID: call.id, decision: "allow")
        _ = await until { !runtime.isExecuting(goal) }
        checks["ApprovalDrainsLastToolWithoutResettingGoalBudget"] = tasks.task(goal)?.goalExecution?.usedTurns == 5 && tasks.task(goal)?.goalExecution?.maximumTurns == 5 && tasks.task(goal)?.events.contains { $0.toolCallID == call.id && $0.status == "completed" && $0.detail.contains("Darwin") } == true
        checks["GoalLimitStopsBeforeAnotherModelAttempt"] = tasks.task(goal)?.status == .stopped && tasks.task(goal)?.goalAccepted != true && blocked == goalBefore && tasks.task(goal)?.events.last?.title == "目标执行已达 5 轮，可继续"
        let restored = AgentStore(directory: profile, legacy: [], extensionHome: home, mcpKeychain: keychain, hookKeychain: keychain)
        checks["GoalBudgetSurvivesStoreReload"] = restored.task(goal)?.goalExecution?.usedTurns == 5 && restored.task(goal)?.goalExecution?.maximumTurns == 5

        let finish = AgentToolCall(id: UUID().uuidString, name: "finish_task", arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["summary": "原生工具已核对", "evidence": [call.id]]), as: UTF8.self))
        pending(goal, call: finish); tasks.update(goal) { $0.plan = [AgentPlanStep(title: "实际读取本机系统名称", status: "completed")] }
        runtime.start(goal, continuingGoal: true); _ = await until { !runtime.isExecuting(goal) }
        checks["ValidLastRoundFinishUsesActualToolEvidence"] = tasks.task(goal)?.status == .completed && tasks.task(goal)?.goalAccepted == true && tasks.task(goal)?.completionEvidence == [call.id] && completions == [goal] && blocked == goalBefore
        tasks.hooks.onAsyncResult?(goal, UUID().uuidString, tasks.task(goal)?.messages.last(where: \.isHumanInput)?.id, true)
        _ = await until { !runtime.isExecuting(goal) }
        checks["BackgroundHookWakeCannotRenewExhaustedGoalBudget"] = tasks.task(goal)?.status == .stopped && tasks.task(goal)?.goalExecution?.usedTurns == 5 && tasks.task(goal)?.goalExecution?.maximumTurns == 5 && completions == [goal] && blocked == goalBefore

        let hookJSON = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"name\":\"原生结束核对\",\"type\":\"command\",\"command\":\"/usr/bin/printf\",\"args\":[\"%s\",\"{\\\"decision\\\":\\\"block\\\",\\\"reason\\\":\\\"仍需核对\\\"}\"]}]}]}}"
        try tasks.hooks.save(hookJSON, project: false, workspace: workspace.path, expectedHash: nil)
        guard let stopHook = try tasks.hooks.catalog(workspace: workspace.path).first(where: { $0.name == "原生结束核对" }) else { throw PetError("缺少结束 Hook") }
        try tasks.hooks.setEnabled(stopHook, true, workspace: workspace.path)
        tasks.update(goal) { $0.status = .ready; $0.goalAccepted = true; $0.completionEvidence = [call.id] }; runtime.start(goal, continuingGoal: true); _ = await until { !runtime.isExecuting(goal) }
        checks["LastRoundCompletionStillHonorsStopHook"] = tasks.task(goal)?.status == .stopped && tasks.task(goal)?.goalAccepted != true && completions == [goal] && blocked == goalBefore && tasks.task(goal)?.events.contains { $0.hook?.effect?.deny == "仍需核对" } == true
        try tasks.hooks.setEnabled(stopHook, false, workspace: workspace.path)

        settings.goalMaximumTurns = 100
        runtime.start(goal); _ = await until { !runtime.isExecuting(goal) }
        checks["ManualContinuationStartsNewBudgetFromCurrentPreference"] = tasks.task(goal)?.goalExecution?.maximumTurns == 100 && tasks.task(goal)?.goalExecution?.usedTurns == 0 && blocked == goalBefore + 1
        let invalid = seed("无效轮次拒绝", mode: .goal)
        tasks.update(invalid) { $0.goalExecution = AgentGoalExecution(maximumTurns: 5, usedTurns: 6) }
        runtime.start(invalid, continuingGoal: true); _ = await until { !runtime.isExecuting(invalid) }
        checks["InvalidPersistedBudgetCannotRunOrResetSilently"] = tasks.task(invalid)?.status == .failed && tasks.task(invalid)?.goalExecution?.usedTurns == 6 && blocked == goalBefore + 1
        let ask = seed("问答不应用目标上限", mode: .ask)
        tasks.update(ask) { $0.workspace = nil }
        runtime.start(ask); _ = await until { !runtime.isExecuting(ask) }
        checks["QuestionModeKeepsExistingNonGoalBehavior"] = tasks.task(ask)?.goalExecution == nil && blocked == goalBefore + 2

        let counter = seed("计数先持久化，再开始请求", mode: .goal)
        runtime.modelRequestCheck = { /* Empty isolated credential fails AgentModel preflight before network access. */ }
        runtime.start(counter); _ = await until { !runtime.isExecuting(counter) }
        checks["GoalCounterPersistsBeforeModelPreflight"] = tasks.task(counter)?.goalExecution?.usedTurns == 1 && tasks.task(counter)?.status == .failed && (tasks.task(counter)?.modelReceipts ?? []).isEmpty && tasks.task(counter)?.events.last?.detail == "请先填写对话 Token"
        checks["RuntimeFixturesCreateNoModelRepliesOrUsage"] = tasks.tasks.allSatisfy { !$0.messages.contains(where: \.isReply) && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
        return checks
    }
}
