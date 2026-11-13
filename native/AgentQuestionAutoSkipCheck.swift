import AppKit

@MainActor extension AppDelegate {
    func runQuestionAutoSkipCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], blocked = 0
        do {
            let root = output.appendingPathComponent("question-core"), profile = root.appendingPathComponent("profile"), home = root.appendingPathComponent("shared-home"), workspace = root.appendingPathComponent("public-project")
            for directory in [profile, home, workspace] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            let source = workspace.appendingPathComponent("README.md"), bytes = Data("# 公开问答验收\n原文保留。\n".utf8); try bytes.write(to: source)
            let keychain = PetKeychain(service: "com.xjs.bluefatfish.question-check." + UUID().uuidString)
            let tasks = AgentStore(directory: profile, legacy: [], extensionHome: home, mcpKeychain: keychain, hookKeychain: keychain)
            var settings = AgentGeneralSettings.Settings(), preferences = PetPreferences(), time: TimeInterval = 0, front = Set<String>()
            preferences.endpoint = "https://native-check.invalid"; preferences.voiceEnabled = false
            let runtime = AgentRuntime(store: tasks, keychain: keychain) { preferences }
            runtime.taskSettings = { settings }; runtime.modelRequestCheck = { blocked += 1; throw PetError("问答控制检查禁止模型请求") }
            let policy = AgentQuestionAutoSkip(runtime: runtime, enabled: { settings.questionAutoSkip }, focused: { front.contains($0) }, interaction: { _ in [] }, now: { time })
            defer { policy.stop(); runtime.stopAll() }
            func seed(_ title: String, name: String = "ask_user", tail: Bool = false) -> String {
                let id = tasks.create(title: title, workspace: workspace.path, mode: .goal)
                let call = AgentToolCall(id: UUID().uuidString, name: name, arguments: name == "ask_user" ? "{\"question\":\"请选择公开资料的展示方式\"}" : "{\"path\":\"must-not-write.txt\",\"content\":\"不可自动写入\"}")
                let rest = tail ? [AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: "{\"path\":\"must-not-write.txt\",\"content\":\"未获答复的后续操作\"}")] : []
                tasks.update(id) { record in
                    record.messages = [AgentMessage(role: "user", content: "原生控制检查，无模型输出。"), AgentMessage(role: "assistant", content: "", toolCalls: [call] + rest, nativeContext: true)]
                    record.pendingCalls = [call] + rest; record.approvals = [AgentApproval(call: call, reason: "请选择公开资料的展示方式", workspace: workspace.path)]
                    record.goalExecution = AgentGoalExecution(maximumTurns: 5, usedTurns: 5); record.status = .waiting
                }
                return id
            }
            func settled(_ id: String) async {
                for _ in 0..<150 { if !runtime.isExecuting(id) { break }; await wait(0.02) }; policy.refresh()
            }
            let a = seed("前台阈值", tail: true)
            front = [a]; policy.refresh(); time = 1_000; policy.refresh()
            checks["DefaultOffDoesNotArmOrChangePendingQuestion"] = tasks.task(a)?.status == .waiting && policy.readback()["timerRunning"] as? Bool == false && policy.readback()["localMonitor"] as? Bool == false
            settings.questionAutoSkip = true; policy.refresh(); time += 149.999; policy.refresh()
            checks["ForegroundWaitsTheFull150Seconds"] = tasks.task(a)?.status == .waiting
            time += 0.001; policy.refresh(); await settled(a)
            let answered = tasks.task(a)!
            checks["ForegroundUsesActualRuntimeEmptyAnswerAndStopsAtExistingGoalLimit"] = answered.status == .stopped && answered.approvals.first?.decision == "skip" && answered.messages.contains { $0.role == "tool" && $0.content.contains("答案为空") && $0.content.contains("未收到用户答复或操作授权") } && answered.goalExecution?.usedTurns == 5 && blocked == 0
            checks["AutoSkipDoesNotFabricateHumanInputOrRunFollowingWrite"] = answered.messages.filter(\.isHumanInput).count == 1 && answered.pendingCalls.isEmpty && answered.messages.contains { $0.role == "tool" && $0.content.contains("后续操作需重新规划") } && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("must-not-write.txt").path)
            checks["QuestionHasExactlyOneSkippedDecisionAndToolResult"] = answered.approvals.count == 1 && answered.messages.filter { $0.toolCallID == answered.approvals.first?.call.id }.count == 1

            let b = seed("后台阈值"); front = []; policy.refresh(); time += 89.999; policy.refresh()
            checks["BackgroundWaitsTheFull90Seconds"] = tasks.task(b)?.status == .waiting
            time += 0.001; policy.refresh(); await settled(b)
            checks["BackgroundUsesSameActualRuntimeWithoutModelAttempt"] = tasks.task(b)?.approvals.first?.decision == "skip" && tasks.task(b)?.status == .stopped && blocked == 0

            let c = seed("前后台切换"); front = [c]; policy.refresh(); time += 149; policy.refresh(); front = []; policy.refresh(); time += 89; policy.refresh()
            checks["ChangingFocusStartsTheNewBackgroundWait"] = tasks.task(c)?.status == .waiting
            front = [c]; policy.refresh(); time += 149; policy.refresh()
            checks["ReturningToForegroundStartsItsOwn150SecondWait"] = tasks.task(c)?.status == .waiting
            policy.activity(interactingWith: []); time += 149; policy.refresh()
            checks["ForegroundActivityRestartsTheIdleWait"] = tasks.task(c)?.status == .waiting
            time += 1; policy.refresh(); await settled(c)
            checks["ForegroundCanSkipAfterTheRestartedWait"] = tasks.task(c)?.approvals.first?.decision == "skip"

            let d = seed("面板交互取消"); front = [d]; policy.refresh(); policy.activity(interactingWith: [d]); time += 1_000; front = []; policy.refresh()
            checks["PanelInteractionCancelsThisQuestionAcrossFocusChanges"] = tasks.task(d)?.status == .waiting && tasks.task(d)?.approvals.first?.autoSkipCancelled == true
            settings.questionAutoSkip = false; policy.refresh(); settings.questionAutoSkip = true; policy.refresh(); time += 1_000; policy.refresh()
            checks["TogglingPreferenceCannotReviveAnInteractedQuestion"] = tasks.task(d)?.status == .waiting && tasks.task(d)?.approvals.first?.decision == nil
            let restored = AgentStore(directory: profile, legacy: [], extensionHome: home, mcpKeychain: keychain, hookKeychain: keychain)
            checks["InteractionCancellationSurvivesReload"] = restored.task(d)?.approvals.first?.autoSkipCancelled == true && restored.task(d)?.status == .waiting

            let draft = seed("输入区原有草稿"); tasks.update(draft) { $0.draft = "尚未发送的答复" }
            let draftFile = tasks.directory.appendingPathComponent(draft + ".json"), draftBytes = try Data(contentsOf: draftFile)
            policy.refresh(); time += 150; policy.refresh()
            checks["ExistingComposerDraftIsNeverSkippedOrRewritten"] = try tasks.task(draft)?.status == .waiting && Data(contentsOf: draftFile) == draftBytes
            let inbox = seed("收件箱答复草稿"), inboxItem = AgentAttentionItem.project(tasks.task(inbox)!).first!
            try tasks.attention.saveReply(inboxItem, text: "保留需要我中的答复")
            checks["ExistingInboxReplyDraftBlocksAutoSkip"] = try !runtime.skipQuestion(AgentQuestionAutoSkip.request(tasks.task(inbox)!)!) && tasks.task(inbox)?.status == .waiting && tasks.attention.replyDraft(inboxItem) == "保留需要我中的答复"

            let approval = seed("审批边界", name: "write_file"), hook = seed("Hook 边界"), archived = seed("归档边界"), queued = seed("新输入边界")
            tasks.update(hook) { $0.kind = "hook" }; tasks.update(archived) { $0.archived = true }; tasks.update(queued) { $0.queuedMessages = [AgentMessage(role: "user", content: "新的要求")] }
            checks["ApprovalsHooksArchivedAndQueuedInputsAreExcluded"] = [approval, hook, archived, queued].allSatisfy { AgentQuestionAutoSkip.request(tasks.task($0)!) == nil }
            let stale = seed("过期请求"), old = AgentQuestionAutoSkip.request(tasks.task(stale)!)!
            tasks.update(stale) { $0.pendingCalls[0].arguments = "{\"question\":\"已更新的问题\"}" }
            checks["ChangedQuestionCannotUseAnEarlierTimerOrDecision"] = !runtime.skipQuestion(old) && tasks.task(stale)?.approvals.first?.decision == nil

            let readOnly = seed("只读记录"), request = AgentQuestionAutoSkip.request(tasks.task(readOnly)!)!, file = tasks.directory.appendingPathComponent(readOnly + ".json"), before = try Data(contentsOf: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            checks["FailedPersistenceLeavesQuestionWaitingWithoutRunning"] = try !runtime.skipQuestion(request) && tasks.task(readOnly)?.status == .waiting && tasks.task(readOnly)?.approvals.first?.decision == nil && !runtime.isExecuting(readOnly) && Data(contentsOf: file) == before
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); try tasks.save(readOnly)
            let conflict = seed("外部记录冲突"), conflictingRequest = AgentQuestionAutoSkip.request(tasks.task(conflict)!)!, conflictFile = tasks.directory.appendingPathComponent(conflict + ".json")
            let external = try Data(contentsOf: conflictFile) + Data("\n ".utf8); try external.write(to: conflictFile)
            checks["ExternalChangeIsPreservedAndCannotTriggerResume"] = try !runtime.skipQuestion(conflictingRequest) && Data(contentsOf: conflictFile) == external && tasks.task(conflict)?.status == .waiting && !runtime.isExecuting(conflict)
            settings.questionAutoSkip = false; policy.refresh()
            checks["DisableRemovesTimerAndLocalMonitorWithoutApprovingRequests"] = policy.readback()["timerRunning"] as? Bool == false && policy.readback()["localMonitor"] as? Bool == false && tasks.task(approval)?.approvals.first?.decision == nil
            checks["PublicFileAndNoModelUsageRemainExact"] = try Data(contentsOf: source) == bytes && blocked == 0 && tasks.tasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["success"] = checks.values.allSatisfy { $0 } && checks.count >= 20
            report["boundary"] = "Injected monotonic times exercise the production policy and actual pending-call runtime. Exhausted Goal fixtures drain the question and stop before any model attempt; tool-call records are native fixtures, not model outputs. Actual UI timing is verified separately."
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        report["checks"] = checks; report["appPID"] = getpid(); report["modelRequests"] = 0; report["blockedModelAttempts"] = blocked; report["keychainWrites"] = 0
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("question-auto-skip-report.json"))
    }
    func prepareQuestionAutoSkipUI(_ output: URL, seed: Bool) throws {
        guard let tasks = agentStore else { throw PetError("问答窗口资料未初始化") }
        let file = output.appendingPathComponent("question-ui-fixtures.json")
        let ids: [String: String]
        if seed {
            let workspace = output.appendingPathComponent("public-project"); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data("# 公开问答窗口验收\n不发送模型请求。\n".utf8).write(to: workspace.appendingPathComponent("README.md"))
            var values: [String: String] = [:]
            for (key, title) in [("foreground", "前台等待 150 秒"), ("background", "后台等待 90 秒"), ("interaction", "面板交互后保留"), ("approval", "审批不能自动跳过")] {
                let id = tasks.create(title: title, workspace: workspace.path, mode: .goal)
                let call = AgentToolCall(id: UUID().uuidString, name: key == "approval" ? "write_file" : "ask_user", arguments: key == "approval" ? "{\"path\":\"must-not-write.txt\",\"content\":\"不可自动写入\"}" : "{\"question\":\"是否显示公开 README 的目录？\"}")
                tasks.update(id) { record in
                    record.messages = [AgentMessage(role: "user", content: "原生窗口计时验收，不调用模型。"), AgentMessage(role: "assistant", content: "", toolCalls: [call], nativeContext: true)]
                    record.pendingCalls = [call]; record.approvals = [AgentApproval(call: call, reason: key == "approval" ? "写入公开项目文件，需明确审批" : "是否显示公开 README 的目录？", workspace: workspace.path)]
                    record.goalExecution = AgentGoalExecution(maximumTurns: 5, usedTurns: 5); record.status = .waiting
                }; values[key] = id
            }
            ids = values; try JSONSerialization.data(withJSONObject: ids, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        } else { ids = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: String] }
        guard let id = ids[seed ? "foreground" : "interaction"], tasks.task(id) != nil else { throw PetError("缺少问答原记录") }
        control.showAgentTask(id); NSApp.activate(ignoringOtherApps: true); control.window?.makeKeyAndOrderFront(nil); questionAutoSkip?.refresh()
    }
}
