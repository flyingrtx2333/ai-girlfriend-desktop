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

        runtime.modelRequestCheck = { blocked += 1; throw PetError("并发位检查禁止模型请求") }
        let (slotA, pidA, _) = try await startSleeping("slot-a")
        let (slotB, pidB, _) = try await startSleeping("slot-b")
        let manual = seed("排队后手动续跑", mode: .goal)
        tasks.update(manual) { $0.status = .stopped; $0.goalExecution = AgentGoalExecution(maximumTurns: 5, usedTurns: 5) }
        runtime.start(manual)
        checks["SlotQueuePersistsManualContinuationIntent"] = tasks.task(manual)?.statusTitle == "排队中" &&
            tasks.task(manual)?.queuedRun?.previousStatus == .stopped && tasks.task(manual)?.queuedRun?.continuingGoal == false &&
            tasks.task(manual)?.goalExecution?.usedTurns == 5 && (try? tasks.recordIsPersisted(manual)) == true

        let reviewed = seed("排队的最后一轮授权", mode: .goal)
        let reviewedCall = command("queued-review", "/usr/bin/uname")
        pending(reviewed, call: reviewedCall, waiting: true)
        tasks.update(reviewed) { $0.goalExecution = AgentGoalExecution(maximumTurns: 5, usedTurns: 5) }
        runtime.decide(taskID: reviewed, callID: reviewedCall.id, decision: "allow")
        checks["SlotQueuePersistsApprovalContinuationIntent"] = tasks.task(reviewed)?.queuedRun?.continuingGoal == true &&
            tasks.task(reviewed)?.pendingCalls.first?.id == reviewedCall.id && (try? tasks.recordIsPersisted(reviewed)) == true

        let superseded = seed("排队的授权收到补充")
        let oldCall = command("queued-superseded", "/usr/bin/touch queued-superseded.txt")
        pending(superseded, call: oldCall, waiting: true)
        runtime.decide(taskID: superseded, callID: oldCall.id, decision: "allow")
        let accepted = runtime.submit("取消刚才的操作，按这条新要求继续", taskID: superseded)
        let supplement = tasks.task(superseded)?.queuedMessages?.first
        let recovery = root.appendingPathComponent("queued-record-recovery")
        let recoveryTasks = recovery.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: recoveryTasks, withIntermediateDirectories: true)
        let queuedFile = superseded + ".json"
        try FileManager.default.copyItem(at: tasks.directory.appendingPathComponent(queuedFile), to: recoveryTasks.appendingPathComponent(queuedFile))
        let recovered = AgentStore(directory: recovery, legacy: [], extensionHome: home, mcpKeychain: keychain, hookKeychain: keychain)
        let paused = recovered.task(superseded)
        checks["ColdQueueRecoveryKeepsOriginalSupplementID"] = accepted && supplement != nil &&
            paused?.status == .stopped && paused?.statusTitle == "排队已暂停" && paused?.queuedCount == 0 &&
            paused?.unansweredQueuedMessageID == supplement?.id && paused?.messages.last?.id == supplement?.id
        checks["ColdQueueRecoverySkipsSupersededApprovalBeforeFlushing"] = paused?.queuedRun?.continuingGoal == true &&
            paused?.pendingCalls.isEmpty == true && paused?.messages.filter { $0.toolCallID == oldCall.id }.count == 1 &&
            paused?.events.contains { $0.toolCallID == oldCall.id && $0.status == "stopped" } == true &&
            !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("queued-superseded.txt").path)
        runtime.cancel(superseded)
        checks["CancelClearsSlotQueueAndKeepsSupplement"] = !runtime.isExecuting(superseded) &&
            tasks.task(superseded)?.queuedRun == nil && tasks.task(superseded)?.messages.last?.id == supplement?.id

        let beforeSlot = blocked
        runtime.cancel(slotA)
        _ = await until { !runtime.isExecuting(manual) && !runtime.isExecuting(reviewed) }
        checks["SlotHandoffHonorsManualContinuationBudgetAndHistory"] = tasks.task(manual)?.goalExecution?.maximumTurns == 100 &&
            tasks.task(manual)?.goalExecution?.usedTurns == 0 && blocked == beforeSlot + 1 &&
            tasks.task(manual)?.queuedRun == nil && tasks.task(manual)?.messages.last?.content == "继续完成原任务，保留之前的约束。"
        checks["SlotHandoffHonorsApprovalBudgetAndRetainsToolResult"] = tasks.task(reviewed)?.goalExecution?.usedTurns == 5 &&
            tasks.task(reviewed)?.goalExecution?.maximumTurns == 5 && tasks.task(reviewed)?.status == .stopped &&
            tasks.task(reviewed)?.queuedRun == nil && tasks.task(reviewed)?.events.contains {
                $0.toolCallID == reviewedCall.id && $0.status == "completed" && $0.detail.contains("Darwin")
            } == true
        runtime.cancel(slotB)
        _ = await until { !alive(pidA) && !alive(pidB) }
        let offline = seed("最后一轮批准后源目录失联", mode: .goal)
        let offlineCall = command("offline-approved-goal", "printf 'checked\\n' >> offline-proof.txt\n/usr/bin/uname -s")
        let secondary = root.appendingPathComponent("原次源文件夹"), parked = root.appendingPathComponent("暂离次源文件夹")
        try FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: false)
        let scope = AgentWorkspaceScope(group: workspace.path, folders: [workspace.path, secondary.path], primary: workspace.path)
        pending(offline, call: offlineCall, waiting: true)
        tasks.update(offline) {
            $0.workspaceScope = scope; $0.approvals[0].workspaceScope = scope; $0.permission = .review
            $0.goalExecution = AgentGoalExecution(maximumTurns: 5, usedTurns: 5)
        }
        let beforeOffline = blocked
        let proof = workspace.appendingPathComponent("offline-proof.txt")
        try FileManager.default.moveItem(at: secondary, to: parked)
        runtime.decide(taskID: offline, callID: offlineCall.id, decision: "allow")
        let failure = tasks.task(offline)
        checks["OfflineApprovalRecordsActualSourceAndDoesNotStart"] = failure?.status == .failed &&
            failure?.events.last?.detail.contains(secondary.path) == true && failure?.pendingCalls.first?.id == offlineCall.id &&
            failure?.approvals.first?.decision == "allow" && blocked == beforeOffline && !FileManager.default.fileExists(atPath: proof.path)
        let coldStore = AgentStore(directory: profile, legacy: [], extensionHome: home, mcpKeychain: keychain, hookKeychain: keychain)
        let coldRuntime = AgentRuntime(store: coldStore, keychain: keychain) { preferences }
        coldRuntime.taskSettings = { settings }; coldRuntime.modelRequestCheck = { blocked += 1; throw PetError("续跑检查禁止模型请求") }
        defer { coldRuntime.stopAll() }
        let saved = coldStore.task(offline)
        checks["OfflineApprovalSurvivesReloadWithOriginalTurnAndScope"] = saved?.approvals.first?.id == failure?.approvals.first?.id &&
            saved?.workspaceScope == scope && saved?.goalExecution?.maximumTurns == 5 && saved?.goalExecution?.usedTurns == 5 &&
            saved?.pendingCalls.first?.id == offlineCall.id
        try FileManager.default.moveItem(at: parked, to: secondary)
        coldRuntime.start(offline)
        _ = await until { !coldRuntime.isExecuting(offline) }
        let continued = coldStore.task(offline)
        checks["ReconnectedApprovalExecutesOnceWithoutRenewingGoalOrAddingAnInput"] = continued?.status == .stopped &&
            continued?.goalExecution?.maximumTurns == 5 && continued?.goalExecution?.usedTurns == 5 && blocked == beforeOffline &&
            continued?.messages.filter { $0.toolCallID == offlineCall.id && $0.content.contains("Darwin") }.count == 1 &&
            continued?.messages.filter { $0.role == "user" }.count == 1 &&
            (try? String(contentsOf: proof, encoding: .utf8)) == "checked\n"
        checks["RuntimeFixturesCreateNoModelRepliesOrUsage"] = tasks.tasks.allSatisfy { !$0.messages.contains(where: \.isReply) && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
        return checks
    }
}
