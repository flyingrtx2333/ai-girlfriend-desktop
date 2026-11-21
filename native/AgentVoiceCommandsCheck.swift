import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentVoiceCommandsCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], modelAttempts = 0
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少语音任务验收环境") }
            runtime.modelRequestCheck = { modelAttempts += 1; throw PetError("语音任务验收禁止调用模型") }
            defer { runtime.stopAll(); stopRecording() }
            let project = output.appendingPathComponent("公开项目", isDirectory: true)
            let readme = Data("# 公开语音任务样例\n".utf8)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            try readme.write(to: project.appendingPathComponent("README.md"))
            let primary = tasks.create(title: "运行中的项目任务", workspace: project.path, draft: "原项目草稿")
            let general = tasks.create(title: "等待中的无工作区问答", mode: .ask, workMode: .general, draft: "原问答草稿")
            let pending = AgentToolCall(id: UUID().uuidString, name: "ask_user", arguments: #"{"question":"选择检查范围"}"#)
            tasks.update(general) {
                $0.status = .waiting; $0.pendingCalls = [pending]
                $0.messages = [AgentMessage(role: "assistant", content: "", toolCalls: [pending], nativeContext: true)]
                $0.approvals = [AgentApproval(call: pending, reason: "等待用户选择", workspace: nil)]
            }
            let arguments = #"{"command":"printf '%s' $$ > .voice-check.pid\nexec /bin/sleep 60","network":false,"timeout_seconds":65}"#
            let shell = AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: arguments)
            tasks.update(primary) {
                $0.messages = [AgentMessage(role: "assistant", content: "", toolCalls: [shell], nativeContext: true)]
                $0.pendingCalls = [shell]
                var approval = AgentApproval(call: shell, reason: "公开本机进程验收", workspace: project.path)
                approval.decision = "allow"; approval.decidedAt = Date(); $0.approvals = [approval]
            }
            control.showAgentTask(primary); control.show(tab: "chat"); focusedTaskControl = control
            control.window?.setContentSize(NSSize(width: 780, height: 540))
            runtime.start(primary)
            let marker = project.appendingPathComponent(".voice-check.pid")
            for _ in 0..<100 {
                if (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int32.init) != nil { break }
                await wait(0.05)
            }
            guard let pid = (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int32.init), pid > 1 else { throw PetError("公开任务进程未启动") }
            func active() -> Bool { runtime.isRunning(primary) && kill(pid, 0) == 0 }
            func persisted(_ id: String) -> Bool { (try? tasks.recordIsPersisted(id)) == true }
            func turn() {
                store.preferences.wakeEnabled = true
                voiceEvent(.state("等待唤醒")); voiceEvent(.state("聆听中"))
            }
            func recognized(_ text: String) {
                voiceEvent(.state("回复中")); voiceEvent(.utterance(text))
            }
            checks["isolatedPublicProfile"] = tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            checks["realShellStartedInProject"] = active()
            checks["createSyntaxAndOriginalPunctuation"] = AgentVoiceCommand.parse("请创建一个新任务： 检查 README。") == .newTask(draft: "检查 README。") &&
                AgentVoiceCommand.parse("新建任务内容是检查 README。") == .newTask(draft: "检查 README。")
            checks["questionsAndNegationsAreNotTaskCommands"] = [
                "不要停止当前任务", "如何新建任务？", "停止任务？", "新建任务 是什么意思", "停止录音",
                "解释一下停止当前任务", "把新建任务按钮移到右侧"
            ].allSatisfy { AgentVoiceCommand.parse($0) == nil }

            store.preferences.wakeEnabled = true; voiceEvent(.state("等待唤醒")); listenNow()
            checks["manualListeningWhileRunningDoesNotCancelOrWaitForTask"] = active() && !pendingVoiceListen
            turn(); stopRecording()
            checks["stoppingRecordingLeavesRunningTaskAlone"] = active() && !store.preferences.wakeEnabled
            let before = tasks.tasks.count
            recognized("新建任务")
            checks["lateTranscriptAfterStopIsIgnored"] = tasks.tasks.count == before && active()
            turn(); voiceEvent(.partial("停止当前任务"))
            checks["partialStopHasNoEffect"] = active()
            recognized("请不要停止当前任务。")
            checks["ordinarySpeechWhileBusyAppendsToExistingDraft"] = active() &&
                tasks.task(primary)?.draft == "原项目草稿\n请不要停止当前任务。" && tasks.task(primary)?.messages.count == 1 &&
                persisted(primary)

            turn(); control.showAgentTask(general); recognized("停止当前任务")
            checks["aFocusChangeCannotStopEitherTask"] = active() && tasks.task(general)?.pendingCalls.first?.id == pending.id
            turn(); control.showAgentTask(primary); recognized("保留这条问答补充。")
            checks["dictationAfterSwitchAppendsToOriginalTask"] = tasks.task(general)?.draft == "原问答草稿\n保留这条问答补充。" &&
                tasks.task(primary)?.draft == "原项目草稿\n请不要停止当前任务。" && persisted(general)
            turn(); control.showAgentTask(general)
            voiceEvent(.stopped("录音超时，已停止", draft: "保留这条项目转写。"))
            checks["timeoutPreservesOriginalDraftWithoutStoppingTask"] = active() && !store.preferences.wakeEnabled &&
                tasks.task(primary)?.draft == "原项目草稿\n请不要停止当前任务。\n保留这条项目转写。" &&
                tasks.task(general)?.draft == "原问答草稿\n保留这条问答补充。"

            openTaskWindow(general, from: control)
            guard let second = additionalTaskWindows.last, second.agentTaskID == general else { throw PetError("无工作区样例任务窗口未打开") }
            focusedTaskControl = second; turn(); recognized("请停止当前任务。")
            checks["stopClearsOnlySecondWindowsPendingApproval"] = active() && tasks.task(general)?.status == .stopped &&
                tasks.task(general)?.pendingCalls.isEmpty == true && tasks.task(general)?.approvals.first?.decision != "allow"
            focusedTaskControl = control; control.showAgentTask(primary)
            turn(); recognized("新建任务内容是核对 README 的部署步骤。")
            guard let created = control.agentTaskID, created != primary, let task = tasks.task(created) else { throw PetError("语音没有创建项目任务") }
            checks["createUsesSameProjectAndLeavesDraftUnsent"] = active() && task.workspace == project.path &&
                task.status == .ready && task.messages.isEmpty && task.draft == "核对 README 的部署步骤。" &&
                control.settingsSourceReadback()["draft"] as? String == task.draft && persisted(created)
            if let view = control.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("voice-created-project-task.png"))
            }

            control.showAgentTask(primary); turn(); recognized("中断当前任务")
            for _ in 0..<100 {
                if kill(pid, 0) != 0 { break }
                await wait(0.05)
            }
            checks["explicitVoiceStopTerminatesRealTaskProcess"] = !runtime.isRunning(primary) && tasks.task(primary)?.status == .stopped && kill(pid, 0) != 0
            checks["interruptRetainsExistingProjectDraft"] = tasks.task(primary)?.draft == "原项目草稿\n请不要停止当前任务。\n保留这条项目转写。" &&
                persisted(primary)
            focusedTaskControl = second; turn(); recognized("创建任务")
            guard let standalone = second.agentTaskID, standalone != general, let standaloneTask = tasks.task(standalone) else {
                throw PetError("语音没有创建无工作区任务")
            }
            checks["createWithoutInstructionsOpensEmptyStandaloneTask"] = standaloneTask.workspace == nil && standaloneTask.organizationMode == .general &&
                standaloneTask.status == .ready && standaloneTask.messages.isEmpty && (standaloneTask.draft ?? "").isEmpty &&
                persisted(standalone)
            checks["existingDraftAndPublicSourceStayIntact"] = tasks.task(general)?.draft == "原问答草稿\n保留这条问答补充。" &&
                (try? Data(contentsOf: project.appendingPathComponent("README.md"))) == readme
            report["records"] = ["primary": primary, "general": general, "projectDraft": created, "standaloneDraft": standalone]
            report["commandProcessID"] = pid
        } catch { report["error"] = error.localizedDescription }
        checks["noModelRequests"] = modelAttempts == 0
        report["modelAttempts"] = modelAttempts
        report["checks"] = checks
        report["success"] = checks.count == 19 && checks.values.allSatisfy { $0 } && report["error"] == nil
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("agent-voice-commands-report.json"), options: .atomic)
        }
    }
}
