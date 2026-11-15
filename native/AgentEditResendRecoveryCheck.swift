import AppKit

@MainActor extension AppDelegate {
    struct EditResendRecoveryFixture: Codable {
        var projectTask: String, generalTask: String, firstMessage: String, secondMessage: String, generalMessage: String
        var mainWindow: String, childWindow: String, project: String
        var tabs: [String: String], texts: [String: String], history: [String: String]
        var selectionLocation: Int, selectionLength: Int, scrollY: Double
    }
    func runEditResendRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
        func editor(_ window: ControlWindow) throws -> AgentEditResendWindow {
            guard let editor = window.taskWorkspace.currentController as? AgentEditResendWindow else { throw PetError("修改要求未进入实际任务工作区") }; return editor
        }
        func rejected(_ name: String, _ action: () throws -> Void) {
            do { try action(); checks[name] = false } catch { checks[name] = true }
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            checks["modelGuardInstalledBeforeFixturePreparation"] = runtime.modelRequestCheck != nil
            runtime.modelRequestCheck = { requests += 1; throw PetError("编辑状态恢复验收禁止模型请求") }
            checks["isolatedExtensionHome"] = usesAgent && tasks.extensions.sharedHome?.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").resolvingSymlinksInPath()
            let journal = AgentWorkspaceRecovery(profile: store.directory), fixtureURL = output.appendingPathComponent("edit-recovery-fixture.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            func history(_ id: String) throws -> String { guard let task = tasks.task(id) else { throw PetError("任务已不可用") }; return AgentFiles.hash(try encoder.encode(task.messages)) }
            func tab(_ window: ControlWindow, task: String, message: String) throws -> String {
                guard let value = window.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "edit-resend:" + message }) else { throw PetError("编辑标签没有持久编号") }; return value.id
            }
            let fixture: EditResendRecoveryFixture
            if stage == "seed" {
                let source = try await prepareRoundRollbackCheck(output, createdFile: true, name: "恢复修订要求的公开项目")
                guard let firstMessage = tasks.task(source.taskID)?.messages.first(where: \.isHumanInput)?.id else { throw PetError("原始要求缺失") }
                let general = tasks.create(title: "恢复修订要求 · 无工作区问答", mode: .ask, workMode: .general)
                guard runtime.submit("原始公开问题 PUBLIC_EDIT_ORIGINAL_172", taskID: general, startImmediately: false), let generalMessage = tasks.task(general)?.messages.first?.id else { throw PetError("公开问题未保存") }
                for id in [source.taskID, general] { tasks.update(id) { $0.draft = "保留主输入 PUBLIC_EDIT_COMPOSER_294" } }
                let texts = ["a": "修订要求 🐳 PUBLIC_EDIT_MAIN_A_318\n" + (1...280).map { "第 \($0) 行公开修订内容 PUBLIC_EDIT_LINE_527\n" }.joined(),
                             "b": "修订第二条要求 PUBLIC_EDIT_MAIN_B_618", "c": "修订公开问题 PUBLIC_EDIT_GENERAL_C_719", "d": "独立窗口修订 PUBLIC_EDIT_CHILD_D_826"]
                control.showAgentTask(source.taskID); control.show(tab: "chat")
                control.window?.setFrame(NSRect(x: 40, y: 80, width: 1200, height: 774), display: true)
                control.presentEditResend(taskID: source.taskID, messageID: firstMessage)
                let a = try editor(control); a.checkAction(text: texts["a"]! + "第一笔 PUBLIC_EDIT_FIRST_427")
                guard await flushWorkspaceWindows() else { throw PetError("第一笔修改未持久保存") }
                a.checkAction(text: texts["a"]!)
                let selection = (texts["a"]! as NSString).range(of: "PUBLIC_EDIT_MAIN_A_318")
                a.checkRecoveryView(selection, scrollY: 320)
                let view = try AgentEditResendWindow.recoveryState(a.captureWorkspaceRecovery())
                checks["actualUtf16SelectionAndScrollCaptured"] = view.selectionLocation == selection.location && view.selectionLength == selection.length && view.scrollY > 0
                control.presentEditResend(taskID: source.taskID, messageID: source.second)
                let b = try editor(control); b.checkAction(text: texts["b"]!)
                let mainTabs = ["a": try tab(control, task: source.taskID, message: firstMessage), "b": try tab(control, task: source.taskID, message: source.second)]
                control.showAgentTask(general); control.presentEditResend(taskID: general, messageID: generalMessage)
                let c = try editor(control); c.checkAction(text: texts["c"]!)
                var tabs = mainTabs; tabs["c"] = try tab(control, task: general, message: generalMessage)
                control.showAgentTask(source.taskID); control.taskWorkspace.checkSelect(.editResend(firstMessage))
                openTaskWindow(source.taskID, from: control)
                guard let child = additionalTaskWindows.last else { throw PetError("独立任务窗口未创建") }
                child.presentEditResend(taskID: source.taskID, messageID: firstMessage)
                let d = try editor(child); d.checkAction(text: texts["d"]!); tabs["d"] = try tab(child, task: source.taskID, message: firstMessage)
                guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let childID = child.workspaceSession?.id else { throw PetError("编辑状态恢复记录未保存") }
                fixture = .init(projectTask: source.taskID, generalTask: general, firstMessage: firstMessage, secondMessage: source.second, generalMessage: generalMessage,
                    mainWindow: mainID, childWindow: childID, project: source.workspace.path, tabs: tabs, texts: texts,
                    history: ["project": try history(source.taskID), "general": try history(general)], selectionLocation: view.selectionLocation, selectionLength: view.selectionLength, scrollY: view.scrollY)
                checks["twoMessagesSameTaskRetainIndependentInputs"] = a.workspaceReadback()["text"] as? String == texts["a"] && b.workspaceReadback()["text"] as? String == texts["b"]
                checks["sameMessageInOtherWindowKeepsOwnInput"] = d !== a && d.workspaceReadback()["text"] as? String == texts["d"]
                checks["askWithoutWorkspaceHasIndependentEditedInput"] = tasks.task(general)?.workspace == nil && tasks.task(general)?.mode == .ask && c.workspaceReadback()["text"] as? String == texts["c"]
                checks["allFourEditorsEligibleForPreservedQuit"] = control.workspaceSession?.preservedEditors.count == 3 && child.workspaceSession?.preservedEditors.count == 1
                if !interactive {
                    let path = store.directory.appendingPathComponent("workspace-recovery/" + mainID + "/pages/" + tabs["b"]! + ".json"), before = try Data(contentsOf: path)
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
                    b.checkAction(text: texts["b"]! + " PUBLIC_EDIT_RETRY_935")
                    checks["readonlyPageRejectsCheckpointAndPreservedQuit"] = !(await control.flushWorkspaceRecovery()) && control.workspaceSession?.preservedEditors.isEmpty == true
                    checks["failedCheckpointKeepsStoredBytesAndLatestInput"] = try Data(contentsOf: path) == before && (b.workspaceReadback()["text"] as? String)?.hasSuffix("PUBLIC_EDIT_RETRY_935") == true
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                    checks["sameLatestInputRetriesAfterWritePermissionRestores"] = await control.flushWorkspaceRecovery()
                    let saved = try journal.loadPage(windowID: mainID, pageID: tabs["b"]!, taskID: source.taskID)!
                    checks["retriedCheckpointContainsActualLastInput"] = try AgentEditResendWindow.recoveryState(saved.saved.value).text == texts["b"]! + " PUBLIC_EDIT_RETRY_935"
                    b.checkAction(text: texts["b"]!)
                }
                guard await flushWorkspaceWindows() else { throw PetError("最后修改未保存") }
                try encoder.encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(EditResendRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(), let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.childWindow }) else { throw PetError("编辑窗口恢复未完成") }
                checks["sameTaskAndWindowIdentityRestores"] = control.workspaceSession?.id == fixture.mainWindow && child.agentTaskID == fixture.projectTask
                if stage == "after-send" {
                    let result = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("edit-recovery-applied.json"))) as? [String: String] ?? [:]
                    checks["closedAndCompletedEditorsDoNotReopen"] = taskControls.allSatisfy { $0.taskWorkspace.recoveryLayouts.allSatisfy { $0.tabs.allSatisfy { !$0.root.hasPrefix("edit-resend:") } } }
                    checks["archivedOriginalHistoriesRemainExactAfterAnotherProcess"] = try history(fixture.projectTask) == fixture.history["project"] && history(fixture.generalTask) == fixture.history["general"] && tasks.task(fixture.projectTask)?.archived == true && tasks.task(fixture.generalTask)?.archived == true
                    checks["actualContinuationsAndTaskComposersSurviveRestart"] = ["project": fixture.projectTask, "general": fixture.generalTask].allSatisfy { key, parent in result[key].flatMap(tasks.task).map { $0.parentID == parent && $0.draft == "保留主输入 PUBLIC_EDIT_COMPOSER_294" } == true }
                    checks["reviewedFileRollbackSurvivesRestart"] = try Data(contentsOf: URL(fileURLWithPath: fixture.project).appendingPathComponent("a.txt")) == Data("alpha-one\n".utf8) && Data(contentsOf: URL(fileURLWithPath: fixture.project).appendingPathComponent("b space.txt")) == Data("beta-one\n".utf8) && !FileManager.default.fileExists(atPath: URL(fileURLWithPath: fixture.project).appendingPathComponent("created.txt").path)
                } else {
                    let a = try editor(control), d = try editor(child)
                    var expectedA = fixture.texts["a"]!
                    let expectedFile = output.appendingPathComponent("ui-expected-edit.txt")
                    if interactive, FileManager.default.fileExists(atPath: expectedFile.path) { expectedA = try String(contentsOf: expectedFile, encoding: .utf8) }
                    checks["mainEditedTextRestoresBeforeAnyNewInput"] = a.workspaceReadback()["text"] as? String == expectedA
                    checks["otherWindowSameMessageRestoresOwnText"] = d.workspaceReadback()["text"] as? String == fixture.texts["d"]
                    if !interactive {
                        let view = a.workspaceReadback()
                        checks["selectionAndScrollRestoreAgainstActualText"] = view["selectionLocation"] as? Int == fixture.selectionLocation && view["selectionLength"] as? Int == fixture.selectionLength && abs((view["scrollY"] as? Double ?? -1000) - fixture.scrollY) < 1
                    }
                    checks["unselectedMessageRemainsColdAndDirty"] = try control.taskWorkspace.recoveryController(taskID: fixture.projectTask, root: .editResend(fixture.secondMessage)) == nil && journal.loadPage(windowID: fixture.mainWindow, pageID: fixture.tabs["b"]!, taskID: fixture.projectTask)?.saved.value.dirty == true
                    let prior = try journal.loadPage(windowID: fixture.mainWindow, pageID: fixture.tabs["c"]!, taskID: fixture.generalTask)!
                    control.showAgentTask(fixture.generalTask); control.taskWorkspace.checkSelect(.editResend(fixture.generalMessage))
                    guard await flushWorkspaceWindows() else { throw PetError("无工作区修订恢复未完成") }
                    if stage == "unavailable" {
                        checks["changedOriginalMessageKeepsColdEditorAndDirtyTab"] = control.taskWorkspace.currentController == nil && (control.taskWorkspace.checkState()["tabLabels"] as? [String])?.contains("• 编辑并重发") == true
                        checks["changedOriginalMessageKeepsExactStoredDraft"] = try journal.loadPage(windowID: fixture.mainWindow, pageID: fixture.tabs["c"]!, taskID: fixture.generalTask)?.saved.hash == prior.saved.hash
                    } else {
                        let c = try editor(control)
                        checks["generalAskInputRestoresWithoutWorkspace"] = c.workspaceReadback()["text"] as? String == fixture.texts["c"] && c.workspaceReadback()["sendEnabled"] as? Bool == true && tasks.task(fixture.generalTask)?.workspace == nil
                        if !interactive {
                            let original = try c.captureWorkspaceRecovery()
                            func altered(_ change: (inout [String: Any]) -> Void) throws -> AgentWorkspaceRecovery.Page {
                                var page = original, value = try JSONSerialization.jsonObject(with: page.state) as! [String: Any]
                                change(&value); page.state = try JSONSerialization.data(withJSONObject: value); return page
                            }
                            rejected("futureStateVersionRejected") { _ = try AgentEditResendWindow.recoveryState(altered { $0["version"] = 2 }) }
                            rejected("unknownStateFieldRejected") { _ = try AgentEditResendWindow.recoveryState(altered { $0["future"] = true }) }
                            rejected("invalidUtf16SelectionRejected") { _ = try AgentEditResendWindow.recoveryState(altered { $0["selectionLength"] = Int.max }) }
                            rejected("wrongTaskCannotTakeOverDraft") { var page = original; page.taskID = fixture.projectTask; try c.restoreWorkspaceRecovery(page) }
                            rejected("wrongMessageCannotTakeOverDraft") { try c.restoreWorkspaceRecovery(altered { $0["messageID"] = fixture.firstMessage }) }
                            rejected("changedOriginalHashCannotTakeOverDraft") { try c.restoreWorkspaceRecovery(altered { $0["originalHash"] = String(repeating: "0", count: 64) }) }
                            do {
                                let wrong = AgentWorkspaceRecovery.Tab(root: "edit-resend:" + fixture.firstMessage, title: "其他消息")
                                try await control.materializeRecoveryRoot(task: fixture.generalTask, tab: wrong, loaded: .init(saved: .init(value: original, hash: ""), asset: nil))
                                checks["anotherMessageTabCannotMaterializeStoredDraft"] = false
                            } catch { checks["anotherMessageTabCannotMaterializeStoredDraft"] = true }
                            checks["rejectedRestoreKeepsCurrentEditedInput"] = c.workspaceReadback()["text"] as? String == fixture.texts["c"]
                            c.checkAction("send"); await wait(0.05)
                            guard let generalNext = tasks.selectedID, tasks.task(generalNext)?.parentID == fixture.generalTask else { throw PetError("恢复的无工作区要求未真正重发") }
                            checks["restoredGeneralInputActuallyReplacesConversation"] = tasks.task(generalNext)?.messages.last?.content == fixture.texts["c"] && tasks.task(fixture.generalTask)?.archived == true && tasks.task(generalNext)?.draft == "保留主输入 PUBLIC_EDIT_COMPOSER_294"
                            control.showAgentTask(fixture.projectTask); control.taskWorkspace.checkSelect(.editResend(fixture.secondMessage))
                            guard await flushWorkspaceWindows() else { throw PetError("同任务第二条修订未恢复") }
                            let b = try editor(control)
                            checks["secondMessageRestoresOwnDraft"] = b.workspaceReadback()["text"] as? String == fixture.texts["b"]
                            b.checkAction("send")
                            checks["restoredCallbacksProtectOtherDirtyWindows"] = control.taskWorkspace.currentController === b && tasks.task(fixture.projectTask)?.archived == false && !(b.workspaceReadback()["status"] as? String ?? "").isEmpty
                            let file = URL(fileURLWithPath: fixture.project).appendingPathComponent("b space.txt"), before = try Data(contentsOf: file)
                            try Data("PUBLIC_EDIT_EXTERNAL_CONFLICT_763\n".utf8).write(to: file)
                            b.checkAction("refresh")
                            checks["freshFileReviewRejectsLaterExternalEdit"] = b.workspaceReadback()["sendEnabled"] as? Bool == false && b.workspaceReadback()["text"] as? String == fixture.texts["b"] && tasks.task(fixture.projectTask)?.archived == false
                            try before.write(to: file); b.checkAction("refresh")
                            a.checkAction(text: a.workspaceReadback()["original"] as? String); a.checkAction("cancel")
                            d.checkAction(text: d.workspaceReadback()["original"] as? String); d.checkAction("cancel"); await wait(0.05)
                            checks["explicitCloseRemovesOnlyRequestedEditorTabs"] = control.taskWorkspace.recoveryController(taskID: fixture.projectTask, root: .editResend(fixture.firstMessage)) == nil && child.taskWorkspace.recoveryController(taskID: fixture.projectTask, root: .editResend(fixture.firstMessage)) == nil && control.taskWorkspace.currentController === b
                            b.checkAction("send")
                            guard let review = control.taskWorkspace.currentController as? AgentRoundRollbackWindow else { throw PetError("恢复编辑后的新文件审阅未打开") }
                            checks["restoredEditorRequiresFreshReviewInSameTaskWindow"] = control.taskWorkspace.checkState()["depth"] as? Int == 2 && review.presentingWindow === control.window
                            review.checkAction("apply")
                            let deadline = Date().addingTimeInterval(15)
                            while review.hasPendingOperation && Date() < deadline { await wait(0.03) }
                            guard !review.hasPendingOperation else { throw PetError("恢复修订的文件操作未结束") }
                            guard let next = tasks.selectedID, tasks.task(next)?.parentID == fixture.projectTask else { throw PetError("恢复修订后的文件审阅未真正应用") }
                            checks["restoredReviewedInputActuallyCreatesContinuation"] = tasks.task(next)?.messages.last?.content == fixture.texts["b"] && tasks.task(fixture.projectTask)?.archived == true
                            try JSONSerialization.data(withJSONObject: ["project": next, "general": generalNext], options: [.sortedKeys]).write(to: output.appendingPathComponent("edit-recovery-applied.json"))
                        }
                    }
                    if interactive || stage == "unavailable" { control.showAgentTask(fixture.projectTask); control.taskWorkspace.checkSelect(.editResend(fixture.firstMessage)) }
                }
            }
            checks["originalComposerInputsRemainIndependent"] = [fixture.projectTask, fixture.generalTask].allSatisfy { tasks.task($0)?.draft == "保留主输入 PUBLIC_EDIT_COMPOSER_294" }
            checks["originalProjectHumanHistoryRemainsExact"] = try history(fixture.projectTask) == fixture.history["project"]
            if stage == "unavailable" {
                checks["onlyDeclaredGeneralMessageChangeIsObserved"] = tasks.task(fixture.generalTask)?.messages.first(where: { $0.id == fixture.generalMessage })?.content == "原消息已由外部修改 PUBLIC_EDIT_SOURCE_CHANGE_965"
            } else { checks["originalGeneralHumanHistoryRemainsExact"] = try history(fixture.generalTask) == fixture.history["general"] }
            checks["noModelRequestsReceiptsOrAssistantOutputs"] = requests == 0 && tasks.tasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 && !$0.messages.contains { $0.role == "assistant" } }
            checks["allRecoverySnapshotsCurrent"] = await flushWorkspaceWindows()
            report["fixture"] = fixtureURL.path; report["mainWorkspace"] = control.taskWorkspace.checkState()
            if interactive { control.window?.makeKeyAndOrderFront(nil) }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["modelRequests"] = requests; report["stage"] = stage; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "edit-recovery-ui-ready.json" : "edit-recovery-report.json"))
    }
}
