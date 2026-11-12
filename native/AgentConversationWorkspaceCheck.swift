import AppKit

@MainActor extension AppDelegate {
    func prepareConversationWorkspaceUI(_ output: URL) async throws -> (taskID: String, messageID: String, generalID: String, generalMessageID: String, workspace: URL) {
        let destination = output.appendingPathComponent("conversation-workspace-fixtures.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PetError("对话操作验收资料已存在，请重开原目录") }
        let fixture = try await prepareRoundRollbackCheck(output, createdFile: true, name: "对话编辑与文件审阅")
        guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
        let general = tasks.create(title: "无工作区的原问题", mode: .ask, workMode: .general)
        guard runtime.submit("核对本机可读取的公开资料。", taskID: general, startImmediately: false), let message = tasks.task(general)?.messages.first else { throw PetError("无工作区问题未保存") }
        tasks.update(general) { $0.draft = "保留无工作区任务草稿。" }
        let value: [String: Any] = ["taskID": fixture.taskID, "messageID": fixture.second, "generalID": general, "generalMessageID": message.id, "workspace": fixture.workspace.path, "modelOutputsCreated": false]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: destination)
        control.showAgentTask(fixture.taskID); control.show(tab: "chat")
        return (fixture.taskID, fixture.second, general, message.id, fixture.workspace)
    }
    func reopenConversationWorkspaceUI(_ output: URL) throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("conversation-workspace-fixtures.json"))) as? [String: Any]
        guard let id = value?["taskID"] as? String, agentStore?.task(id) != nil else { throw PetError("原对话操作验收任务不可用") }
        control.showAgentTask(id); control.show(tab: "chat")
    }
    func runConversationWorkspaceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            checks["checkUsesAgentWorkbenchAndIsolatedExtensionHome"] = usesAgent && tasks.extensions.sharedHome?.standardizedFileURL.path == output.appendingPathComponent("shared-home").standardizedFileURL.path
            checks["modelGuardIsInstalledBeforePreparingAnyInput"] = runtime.modelRequestCheck != nil
            runtime.modelRequestCheck = { attempts += 1; throw PetError("对话工作区验收禁止模型请求") }
            let fixture = try await prepareConversationWorkspaceUI(output), host = control.taskWorkspace
            let original = tasks.task(fixture.taskID)!, encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let history = try encoder.encode(original.messages), originalA = try Data(contentsOf: fixture.workspace.appendingPathComponent("a.txt")), originalB = try Data(contentsOf: fixture.workspace.appendingPathComponent("b space.txt"))
            func unchanged() throws -> Bool { try Data(contentsOf: fixture.workspace.appendingPathComponent("a.txt")) == originalA && Data(contentsOf: fixture.workspace.appendingPathComponent("b space.txt")) == originalB && FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("created.txt").path) }
            func ready(_ review: AgentRoundRollbackWindow) async {
                for _ in 0..<100 { if (review.workspaceReadback()["patch"] as? String)?.contains("@@") == true { break }; await wait(0.03) }
            }
            control.presentRoundRollback(taskID: fixture.taskID, messageID: fixture.messageID)
            guard let rollback = host.currentController as? AgentRoundRollbackWindow else { throw PetError("文件撤回未进入任务工作区") }
            await ready(rollback)
            checks["rollbackUsesOwningTaskTabWithoutAuxiliaryWindow"] = rollback.presentingWindow === control.window && rollback.window?.isVisible == false && host.selectedRoot == .rollback(fixture.messageID)
            checks["rollbackDiffUsesActualSecondAndFirstFileBytes"] = (rollback.workspaceReadback()["patch"] as? String)?.contains("-alpha-two\n+alpha-one") == true
            var geometry: [String: Any] = [:]
            func inspect(_ name: String, page: AgentSettingsPageController, state: () -> [String: Any]) async {
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    control.window?.appearance = NSAppearance(named: appearance)
                    for (kind, size) in [("split", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                        control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                        let key = name + "-" + theme + "-" + kind, value = state(), workspace = host.checkState()
                        geometry[key] = ["workspace": workspace, "page": value]
                        for (item, pass) in workspace["checks"] as? [String: Bool] ?? [:] { checks[key + "-" + item] = pass }
                        for (item, pass) in value["checks"] as? [String: Bool] ?? [:] { checks[key + "-" + item] = pass }
                        checks[key + "-actualVisibleOwnerAndKeyboardFocus"] = page.isPageVisible && page.presentingWindow === control.window && (value["focusInPage"] as? Bool == true || value["editorFocused"] as? Bool == true)
                        checks[key + "-actualWindowSizeRemainsRequested"] = control.window?.contentView?.bounds.size == size
                    }
                }
            }
            func inspectHiddenSizing(_ name: String, page: AgentSettingsPageController, state: () -> [String: Any]) async throws {
                let size = NSSize(width: 800, height: 550), root = host.selectedRoot, before = state()
                guard control.showSettingsCategory("appearance") else { throw PetError("不能进入外观设置") }
                checks[name + "-hiddenCachedBodyDetachesFromWindow"] = host.currentController === page && page.pageContentView?.window == nil && page.presentingWindow === control.window
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    control.window?.appearance = NSAppearance(named: appearance); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.1)
                    report[name + "-settings-" + theme] = await control.taskWorkspaceReadback()
                    checks[name + "-settings-" + theme + "-doesNotGrowWindow"] = control.window?.contentView?.bounds.size == size
                }
                control.show(tab: "chat"); await wait(0.05)
                let returned = state(), valueKey = before["text"] == nil ? "patch" : "text"
                checks[name + "-settingsReturnRestoresSamePageInputAndFocus"] = host.currentController === page && page.isPageVisible && returned[valueKey] as? String == before[valueKey] as? String && (returned["focusInPage"] as? Bool == true || returned["editorFocused"] as? Bool == true) && control.window?.contentView?.bounds.size == size
                host.checkHide(); await wait(0.1)
                checks[name + "-hidePreservesPageWithoutConstrainingWindow"] = !host.requested && host.currentController === page && page.pageContentView?.window == nil && control.window?.contentView?.bounds.size == size
                host.show(taskID: fixture.taskID, root: root) { page }; await wait(0.05)
                checks[name + "-reopenRestoresCachedViewAndExactInput"] = host.currentController === page && page.pageContentView?.window === control.window && state()[valueKey] as? String == before[valueKey] as? String && control.window?.contentView?.bounds.size == size
            }
            await inspect("rollback", page: rollback, state: rollback.workspaceReadback)
            try await inspectHiddenSizing("rollback", page: rollback, state: rollback.workspaceReadback)
            rollback.checkAction("", row: 1); await ready(rollback)
            checks["fileSelectionLoadsItsActualComparison"] = (rollback.workspaceReadback()["patch"] as? String)?.contains("beta-two") == true
            rollback.checkAction("cancel"); await wait(0.05)
            checks["cancelClosesOnlyItsTabAndLeavesActualFilesAndHistory"] = try host.rootController(.rollback(fixture.messageID)) == nil && unchanged() && encoder.encode(tasks.task(fixture.taskID)!.messages) == history
            control.presentEditResend(taskID: fixture.taskID, messageID: fixture.messageID)
            guard let editor = host.currentController as? AgentEditResendWindow else { throw PetError("编辑并重发未进入任务工作区") }
            checks["editorStartsAtOriginalHumanInputWithoutSending"] = editor.workspaceReadback()["text"] as? String == original.messages.last?.content && editor.workspaceReadback()["sendEnabled"] as? Bool == false && editor.presentingWindow === control.window && editor.window?.isVisible == false
            let edited = "按修订后的第二轮要求核对文件，保留原对话。"
            editor.checkAction(text: edited)
            checks["unsentEditedRequirementIsMarkedInItsTab"] = editor.workspaceHasUnsavedChanges && (host.checkState()["tabLabels"] as? [String] ?? []).contains("• 编辑并重发")
            await inspect("edit", page: editor, state: editor.workspaceReadback)
            try await inspectHiddenSizing("edit", page: editor, state: editor.workspaceReadback)
            control.presentTaskContext(section: 0); control.presentEditResend(taskID: fixture.taskID, messageID: fixture.messageID)
            checks["anotherTabAndRepeatedEntryKeepSameUnsavedEditor"] = host.currentController === editor && editor.workspaceReadback()["text"] as? String == edited
            host.checkHide(); control.presentEditResend(taskID: fixture.taskID, messageID: fixture.messageID)
            checks["hideAndReopenKeepEditorAndTaskComposerIndependent"] = host.currentController === editor && editor.workspaceReadback()["text"] as? String == edited && control.gitWorkspaceReadback()["draft"] as? String == "保留这份未发送草稿"
            control.show(tab: "settings"); control.show(tab: "chat")
            checks["settingsRoundtripRetainsEditedRequirementAndFocus"] = host.currentController === editor && editor.workspaceReadback()["text"] as? String == edited && editor.workspaceReadback()["editorFocused"] as? Bool == true
            do { try requireTaskDeletionAllowed([fixture.taskID]); checks["unsentEditorProtectsItsTaskFromDeletionOrOtherRollback"] = false } catch { checks["unsentEditorProtectsItsTaskFromDeletionOrOtherRollback"] = true }
            try requireTaskDeletionAllowed([fixture.taskID], ignoring: editor)
            checks["ownReviewedActionCanPassItsExactEditorGuard"] = true
            control.showAgentTask(fixture.generalID); control.presentEditResend(taskID: fixture.generalID, messageID: fixture.generalMessageID)
            guard let general = host.currentController as? AgentEditResendWindow else { throw PetError("无工作区问题未进入编辑页") }
            let generalNotice = try AgentEditResend.review(taskID: fixture.generalID, messageID: fixture.generalMessageID, store: tasks).notice
            checks["askWithoutWorkspaceUsesItsOwnEditorAndClearNotice"] = general !== editor && general.workspaceReadback()["notice"] as? String == generalNotice && general.workspaceReadback()["sendTitle"] as? String == "重新发送"
            do { try requireTaskDeletionAllowed([fixture.taskID], ignoring: general); checks["ignoringAnotherEditorCannotBypassTaskProtection"] = false } catch { checks["ignoringAnotherEditorCannotBypassTaskProtection"] = true }
            general.checkAction(text: " \n"); checks["emptyEditedInputCannotSend"] = general.workspaceReadback()["sendEnabled"] as? Bool == false
            general.checkAction(text: "核对修订后的公开问题。"); general.checkAction("send"); await wait(0.1)
            guard let generalNext = tasks.selectedID, let generalRecord = tasks.task(generalNext) else { throw PetError("无工作区重发记录缺失") }
            checks["actualNoWorkspaceReplacementSelectsNewTaskAndClosesOldEditor"] = generalRecord.parentID == fixture.generalID && generalRecord.mode == .ask && generalRecord.workspace == nil && generalRecord.draft == "保留无工作区任务草稿。" && tasks.task(fixture.generalID)?.archived == true && control.gitWorkspaceReadback()["selectedTask"] as? String == generalNext && !host.controllers.contains { $0 === general }
            control.showAgentTask(fixture.taskID); control.presentEditResend(taskID: fixture.taskID, messageID: fixture.messageID)
            checks["taskSwitchRestoresOriginalEditedText"] = host.currentController === editor && editor.workspaceReadback()["text"] as? String == edited
            editor.checkAction("send")
            guard let review = host.currentController as? AgentRoundRollbackWindow else { throw PetError("重发的文件审阅未进入编辑标签页") }
            await ready(review)
            checks["resendReviewIsChildOfSameEditorAndSameWindow"] = host.selectedRoot == .editResend(fixture.messageID) && host.checkState()["depth"] as? Int == 2 && review.presentingWindow === control.window && review.window?.isVisible == false
            try Data("outside-edit\n".utf8).write(to: fixture.workspace.appendingPathComponent("b space.txt")); review.checkAction("apply")
            report["staleFileFailure"] = review.workspaceReadback()
            checks["staleActualFileRejectsWholeReplacementInsideReview"] = try host.currentController === review && review.workspaceReadback()["applyEnabled"] as? Bool == false && !(review.workspaceReadback()["status"] as? String ?? "").isEmpty && Data(contentsOf: fixture.workspace.appendingPathComponent("a.txt")) == originalA && tasks.task(fixture.taskID)?.archived == false && editor.workspaceReadback()["text"] as? String == edited
            try originalB.write(to: fixture.workspace.appendingPathComponent("b space.txt")); review.checkAction("refresh"); await ready(review)
            host.checkBack()
            checks["reviewBackKeepsExactEditedInputWithoutApplying"] = try host.currentController === editor && editor.workspaceReadback()["text"] as? String == edited && unchanged()
            editor.checkAction("send")
            guard let finalReview = host.currentController as? AgentRoundRollbackWindow else { throw PetError("重新审阅未进入子页") }
            await ready(finalReview); finalReview.checkAction("apply"); await wait(0.1)
            guard let nextID = tasks.selectedID, let next = tasks.task(nextID) else { throw PetError("重发后的真实任务缺失") }
            checks["actualReviewedReplacementSelectsContinuationAfterClosingBothPages"] = next.parentID == fixture.taskID && next.messages.last?.content == edited && next.draft == original.draft && control.gitWorkspaceReadback()["selectedTask"] as? String == nextID && !host.controllers.contains { $0 === editor || $0 === finalReview }
            checks["actualReviewedReplacementRestoresExactEarlierFiles"] = try Data(contentsOf: fixture.workspace.appendingPathComponent("a.txt")) == Data("alpha-one\n".utf8) && Data(contentsOf: fixture.workspace.appendingPathComponent("b space.txt")) == Data("beta-one\n".utf8) && !FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("created.txt").path)
            checks["archivedOriginalKeepsCompleteHumanHistoryAndComposerDraft"] = try tasks.task(fixture.taskID)?.archived == true && encoder.encode(tasks.task(fixture.taskID)!.messages) == history && tasks.task(fixture.taskID)?.draft == original.draft
            checks["noModelRequestReceiptsOrAssistantOutputsCreated"] = attempts == 0 && tasks.tasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 && !$0.messages.contains { $0.role == "assistant" } }
            report["geometry"] = geometry; report["taskID"] = fixture.taskID; report["continuationID"] = nextID; report["generalContinuationID"] = generalNext; report["workspace"] = fixture.workspace.path
            report["appPID"] = getpid(); report["binaryHash"] = try AgentFiles(workspace: Bundle.main.executableURL!.deletingLastPathComponent().path).fileHash(Bundle.main.executableURL!)
            report["modelRequests"] = attempts; report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }
            report["scope"] = "Actual native page routing, edited input, file checkpoints, stale-file rejection, archive and continuation persistence. Runtime start deliberately omitted by the check entry point; no model output is fabricated."
        } catch { report["error"] = error.localizedDescription; report["checks"] = checks; report["success"] = false; report["modelRequests"] = attempts; report["workspaceState"] = await control.taskWorkspaceReadback() }
        report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("conversation-workspace-report.json"))
    }
}
