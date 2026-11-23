import AppKit

@MainActor extension AppDelegate {
    private struct ComposerFixture: Codable {
        let first: String, other: String, changed: String, mainWindow: String, secondWindow: String
        let main: AgentTextViewport, second: AgentTextViewport, standalone: AgentTextViewport
    }
    func runComposerRecoveryCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            ensureAgent()
            guard usesAgent, let tasks = agentStore, let runtime = agentRuntime, let host = control.window else { throw PetError("任务输入区不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("草稿续写验收禁止模型请求") }
            let storage = AgentWorkspaceRecovery(profile: store.directory), workspace = output.appendingPathComponent("workspace").path
            let fixtureFile = output.appendingPathComponent("composer-fixture.json")
            let inputs = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: output.appendingPathComponent("composer-inputs.json")))
            func input(_ key: String) throws -> String {
                guard let value = inputs[key] else { throw PetError("缺少公开草稿样例 " + key) }
                return value
            }
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            func composer(_ window: NSWindow) throws -> ComposerView {
                window.contentView?.layoutSubtreeIfNeeded()
                guard let content = window.contentView,
                      let text = views(content).compactMap({ $0 as? ComposerView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else {
                    throw PetError("原窗口输入区不可见")
                }
                return text
            }
            func select(_ phrase: String, in window: NSWindow) throws -> NSRange {
                let text = try composer(window), range = (text.string as NSString).range(of: phrase)
                guard range.location != NSNotFound, window.makeFirstResponder(text) else { throw PetError("公开草稿选区不可用") }
                text.setSelectedRange(range)
                text.scrollRangeToVisible(range)
                return range
            }
            func matches(_ expected: AgentTextViewport, in window: NSWindow) throws -> Bool {
                let actual = try AgentTextViewport(composer(window))
                return actual.hash == expected.hash && actual.selections == expected.selections && abs(actual.y - expected.y) < 3
            }
            func screenshot(_ window: NSWindow, _ name: String) throws {
                guard let view = window.contentView, window.isVisible, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw PetError("无法读取任务输入窗口")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("任务窗口无法绘制") }
                try png.write(to: output.appendingPathComponent(name + ".png"))
            }
            let firstPhrase = "公开文档第一处 中文😀", secondPhrase = "另一扇窗读到这里 🐋", otherPhrase = "无工作区问答 原选区🧭"
            let fixture: ComposerFixture
            control.show(tab: "chat")
            host.appearance = NSAppearance(named: .darkAqua)
            if CommandLine.arguments.last == "seed" {
                let first = tasks.create(title: "接着编辑项目说明", workspace: workspace)
                let other = tasks.create(title: "无工作区问答草稿", mode: .ask, workMode: .general)
                let changed = tasks.create(title: "已从别处更新的草稿", workspace: workspace)
                let firstInput = try input("first"), otherInput = try input("other"), changedInput = try input("beforeChange")
                tasks.update(first) { $0.draft = firstInput }
                tasks.update(other) { $0.draft = otherInput }
                tasks.update(changed) { $0.draft = changedInput }
                host.setContentSize(NSSize(width: 780, height: 540))
                control.showAgentTask(first)
                guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id else { throw PetError("主窗口尚未保存") }
                let range = try select(firstPhrase, in: host)
                var selectionAutosaved = false
                for _ in 0..<30 {
                    if let value = try storage.loadDraftViewports(windowID: mainID)?.value.tasks[first],
                       value.selections.first?.range == range, value.y > 100 { selectionAutosaved = true; break }
                    await wait(0.05)
                }
                checks["selectionAndScrollAloneCheckpointWithoutEditingText"] = selectionAutosaved && tasks.task(first)?.draft == firstInput
                let original = try AgentTextViewport(composer(host))
                control.checkTaskMonitor("toggle")
                let monitoringHidesInput = (try? composer(host)) == nil
                control.checkTaskMonitor("toggle")
                checks["fullWidthMonitorReturnsToOriginalInputState"] = try monitoringHidesInput && matches(original, in: host)
                guard control.showSettingsCategory("general") else { throw PetError("设置入口不可用") }
                control.show(tab: "chat")
                checks["settingsReturnKeepsOriginalSelectionAndScroll"] = try matches(original, in: host)
                control.showAgentTask(other)
                _ = try select(otherPhrase, in: host)
                control.showAgentTask(changed)
                _ = try select("原来的选区", in: host)
                control.showAgentTask(first)
                checks["switchingBackRestoresExactUTF16SelectionAndScroll"] = try matches(original, in: host)
                try screenshot(host, "composer-narrow-before")
                openTaskWindow(first, from: control)
                guard let second = additionalTaskWindows.last, let secondWindow = second.window else { throw PetError("第二个任务窗口未打开") }
                secondWindow.appearance = NSAppearance(named: .aqua)
                secondWindow.setContentSize(NSSize(width: 1320, height: 800))
                let otherRange = try select(secondPhrase, in: secondWindow)
                guard await flushWorkspaceWindows(), let secondID = second.workspaceSession?.id,
                      let mainPositions = try storage.loadDraftViewports(windowID: mainID)?.value.tasks,
                      let primary = mainPositions[first], let standalone = mainPositions[other], mainPositions[changed] != nil,
                      let another = try storage.loadDraftViewports(windowID: secondID)?.value.tasks[first] else {
                    throw PetError("两扇窗口的草稿位置没有完整保存")
                }
                checks["sameDraftUsesIndependentWindowSelections"] = primary.selections.first?.range == range &&
                    another.selections.first?.range == otherRange && primary.hash == another.hash && another.y > primary.y
                fixture = .init(first: first, other: other, changed: changed, mainWindow: mainID, secondWindow: secondID,
                                main: primary, second: another, standalone: standalone)
                try JSONEncoder().encode(fixture).write(to: fixtureFile, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(ComposerFixture.self, from: Data(contentsOf: fixtureFile))
                restoreAdditionalWorkspaceWindows()
                guard let second = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.secondWindow }), let secondWindow = second.window,
                      control.workspaceSession?.id == fixture.mainWindow, control.agentTaskID == fixture.first, second.agentTaskID == fixture.first else {
                    throw PetError("原草稿窗口没有恢复")
                }
                secondWindow.appearance = NSAppearance(named: .aqua)
                checks["separateWindowsReopenAtTheirOwnPriorSelections"] = try matches(fixture.main, in: host) && matches(fixture.second, in: secondWindow)
                try screenshot(secondWindow, "composer-wide-reopened")
                control.showAgentTask(fixture.other)
                checks["askWithoutWorkspaceRestoresTheOriginalSelection"] = try matches(fixture.standalone, in: host) &&
                    tasks.task(fixture.other)?.workspace == nil && tasks.task(fixture.other)?.mode == .ask
                let updated = try input("afterChange")
                tasks.update(fixture.changed) { $0.draft = updated }
                control.showAgentTask(fixture.changed)
                let changed = try composer(host)
                checks["changedDraftUsesCurrentTextAndNeverAppliesTheOldSelection"] = changed.string == updated &&
                    changed.selectedRange() == NSRange(location: (updated as NSString).length, length: 0)
                control.showAgentTask(fixture.first)
                host.makeKeyAndOrderFront(nil)
                let text = try composer(host)
                checks["originalWindowIsReadyToTypeAtTheRestoredSelection"] = try matches(fixture.main, in: host) && host.firstResponder === text
                try screenshot(host, "composer-narrow-reopened")
                let replacement = try input("replacement"), expected = try input("expected")
                text.insertText(replacement, replacementRange: text.selectedRange())
                let edited = try AgentTextViewport(text)
                control.checkTaskMonitor("toggle")
                control.checkTaskMonitor("toggle")
                checks["immediateOverlayReturnKeepsTheNewEditAndItsPosition"] = try matches(edited, in: host) && tasks.task(fixture.first)?.draft == expected
                checks["actualEditReplacesOnlyTheRestoredSelectionAndSharesTheNewText"] = try composer(secondWindow).string == expected
                try screenshot(host, "composer-narrow-continued")
            }
            checks["draftRecoverySendsNothing"] = [fixture.first, fixture.other, fixture.changed].allSatisfy {
                tasks.task($0)?.messages.isEmpty == true && (tasks.task($0)?.modelReceipts ?? []).isEmpty
            }
            checks["newInputAndPositionsCheckpointed"] = persistTaskDrafts()
            checks["windowPositionsCheckpointed"] = await flushWorkspaceWindows()
        } catch { report["error"] = error.localizedDescription }
        report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["modelRequests"] = requests; report["checks"] = checks
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && requests == 0
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("composer-report.json"))
    }

    struct WorkspaceRecoveryFixture: Codable {
        var first: String, second: String, standalone: String
        var guide: String, plain: String, mainWindow: String, childWindow: String
        var guideHash: String, plainHash: String
        var firstDraft: String, secondDraft: String, childDraft: String, memoryDraft: String, globalDraft: String
        var mode = 0
    }
    func runWorkspaceRecoveryLifecycleCheck(_ output: URL, interactive: Bool = false) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("恢复验收禁止模型请求") }
            let fixtureURL = output.appendingPathComponent("workspace-recovery-fixture.json")
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            func editor(_ window: ControlWindow) throws -> AgentRecordWindow {
                guard let record = window.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("文本编辑器未进入实际工作区") }; return record
            }
            let fixture: WorkspaceRecoveryFixture
            if stage == "seed" {
                let project = output.appendingPathComponent("public-recovery-project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let files = try AgentFiles(workspace: project.path), guide = try files.resolve("公开文档.md"), plain = try files.resolve("original-utf16.txt")
                let guideBytes = Data([0xEF, 0xBB, 0xBF]) + Data("# 公开恢复文档\r\n\r\nORIGINAL_GUIDE_PUBLIC_138\r\n".utf8)
                let plainBytes = try AgentTextFormat(encoding: .utf16LE, bom: true).encode("ORIGINAL_UTF16_PUBLIC_295\r\n")
                try files.writeData(guideBytes, to: guide); try files.writeData(plainBytes, to: plain)
                let first = tasks.create(title: "恢复验收 · 第一任务", workspace: project.path), second = tasks.create(title: "恢复验收 · 第二任务", workspace: project.path), standalone = tasks.create(title: "恢复验收 · 无工作区问答", mode: .ask, workMode: .general)
                for id in [first, second, standalone] { tasks.update(id) { $0.draft = "保留原任务输入 PUBLIC_482" } }
                control.showAgentTask(first); control.show(tab: "chat"); control.showTaskDocument(guide.path)
                let firstDraft = "# 恢复的 Markdown\r\n\r\nFIRST_UNSAVED_PUBLIC_937\r\n", secondDraft = "SECOND_UNSAVED_UTF16_PUBLIC_624\r\n", childDraft = "CHILD_WINDOW_UNSAVED_PUBLIC_853\r\n"
                let memoryDraft = "PROJECT_MEMORY_UNSAVED_PUBLIC_176\n", globalDraft = "GLOBAL_MEMORY_UNSAVED_PUBLIC_943\n"
                await (try editor(control)).checkTaskDocument(text: firstDraft)
                control.presentAgentRecords(section: 5); let memory = try editor(control); memory.selectItem(section: 5, value: AgentMemoryScope.project.rawValue); await memory.checkTaskDocument(text: memoryDraft)
                control.showAgentTask(second); control.showTaskDocument(plain.path); await (try editor(control)).checkTaskDocument(text: secondDraft)
                control.showAgentTask(standalone); control.presentAgentRecords(section: 5); let global = try editor(control); global.selectItem(section: 5, value: AgentMemoryScope.global.rawValue); await global.checkTaskDocument(text: globalDraft)
                control.showAgentTask(first); control.taskWorkspace.checkSelect(.document(guide.path))
                openTaskWindow(first, from: control)
                guard let child = additionalTaskWindows.last else { throw PetError("独立任务窗口未创建") }
                child.showTaskDocument(plain.path); await (try editor(child)).checkTaskDocument(text: childDraft)
                child.taskWorkspace.checkExpand()
                await (try editor(control)).checkTaskDocument(action: "preview")
                guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let childID = child.workspaceSession?.id else { throw PetError("实际工作区未保存") }
                fixture = .init(first: first, second: second, standalone: standalone, guide: guide.path, plain: plain.path, mainWindow: mainID, childWindow: childID,
                    guideHash: AgentFiles.hash(guideBytes), plainHash: AgentFiles.hash(plainBytes), firstDraft: firstDraft, secondDraft: secondDraft, childDraft: childDraft, memoryDraft: memoryDraft, globalDraft: globalDraft)
                let encoded = try JSONEncoder().encode(fixture); try encoded.write(to: fixtureURL, options: .atomic)
                checks["multipleTasksKeepIndependentPrivateDrafts"] = control.taskWorkspace.recoveryLayouts.count == 3 && child.taskWorkspace.recoveryLayouts.count == 1
                checks["multipleWindowsUseDistinctPersistentIdentity"] = mainID != childID
                checks["originalMarkdownAndUTF16BytesRemainExact"] = try files.fileHash(guide) == fixture.guideHash && files.fileHash(plain) == fixture.plainHash
                checks["memoryAutosaveDoesNotWriteProjectOrGlobalMemory"] = !FileManager.default.fileExists(atPath: project.appendingPathComponent(".bluefatfish/memory.md").path) && !FileManager.default.fileExists(atPath: tasks.directory.appendingPathComponent("memory.md").path)
                checks["actualRootRecordsEligibleForHotExit"] = control.workspaceSession?.preservedEditors.count == 4 && child.workspaceSession?.preservedEditors.count == 1
                let journal = AgentWorkspaceRecovery(profile: store.directory), saved = try journal.loadWindow(mainID)
                checks["layoutPersistsSelectionAndCachedTaskTabs"] = saved?.value.tasks.first(where: { $0.taskID == first })?.selected == "document:" + guide.path && saved?.value.closed == false
                checks["childExpandedStatePersists"] = try journal.loadWindow(childID)?.value.tasks.first?.expanded == true
                if let tab = saved?.value.tasks.first(where: { $0.taskID == first })?.tabs.first(where: { $0.root == "document:" + guide.path }), let page = try journal.loadPage(windowID: mainID, pageID: tab.id, taskID: first) {
                    checks["previewModeChangePersistsWithoutAnotherTextEdit"] = try AgentRecordWindow.recoveryState(page.saved.value).mode == 0
                } else { checks["previewModeChangePersistsWithoutAnotherTextEdit"] = false }
            } else {
                fixture = try JSONDecoder().decode(WorkspaceRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(), let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.childWindow }) else { throw PetError("持久窗口未恢复") }
                checks["sameMainAndChildWindowIdentitiesRestore"] = control.workspaceSession?.id == fixture.mainWindow && child.taskWindowNumber == 2
                checks["coldRecordDirtyMarkerRestoresWithoutMemoryEditor"] = (control.taskWorkspace.checkState()["tabLabels"] as? [String])?.contains("• 记录") == true && control.taskWorkspace.recoveryController(taskID: fixture.first, root: .records) == nil
                let firstPage = try await editor(control).captureWorkspaceRecovery(), firstState = try AgentRecordWindow.recoveryState(firstPage)
                let childState = try AgentRecordWindow.recoveryState(await editor(child).captureWorkspaceRecovery())
                checks["selectedMarkdownRestoresWithUnsavedText"] = firstPage.dirty && firstState.text == fixture.firstDraft
                checks["sourceVersionAndBOMCRLFRetained"] = firstState.openedHash == fixture.guideHash && firstState.bom
                checks["previewModeRestoresAcrossProcessRestart"] = firstState.mode == fixture.mode
                checks["childWindowRestoresItsOwnDraftAndExpansion"] = childState.text == fixture.childDraft && child.taskWorkspace.expanded
                control.showAgentTask(fixture.second); control.show(tab: "chat"); guard await flushWorkspaceWindows() else { throw PetError("第二任务恢复失败") }
                var value = try AgentRecordWindow.recoveryState(await editor(control).captureWorkspaceRecovery())
                checks["secondTaskRestoresUTF16DraftAndOriginalVersion"] = value.text == fixture.secondDraft && value.encoding == AgentTextEncoding.utf16LE.rawValue && value.bom && value.openedHash == fixture.plainHash
                control.showAgentTask(fixture.standalone); control.show(tab: "chat"); guard await flushWorkspaceWindows() else { throw PetError("无工作区草稿恢复失败") }
                value = try AgentRecordWindow.recoveryState(await editor(control).captureWorkspaceRecovery())
                checks["noWorkspaceAskRestoresGlobalMemoryDraft"] = value.text == fixture.globalDraft && value.section == 5 && value.selection == AgentMemoryScope.global.rawValue
                control.showAgentTask(fixture.first); control.show(tab: "chat"); control.taskWorkspace.checkSelect(.records); guard await flushWorkspaceWindows() else { throw PetError("项目记忆草稿恢复失败") }
                value = try AgentRecordWindow.recoveryState(await editor(control).captureWorkspaceRecovery())
                checks["projectMemoryRestoresOriginalSourceAndDraft"] = value.text == fixture.memoryDraft && value.memoryWorkspace == URL(fileURLWithPath: fixture.guide).deletingLastPathComponent().path && value.openedHash == AgentFiles.hash(Data())
                control.taskWorkspace.checkSelect(.document(fixture.guide)); guard await flushWorkspaceWindows() else { throw PetError("文件标签恢复失败") }
                let original = try editor(control), layout = store.directory.appendingPathComponent("workspace-recovery/" + fixture.mainWindow + "/layout.json")
                if !interactive {
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: layout.path)
                    await original.checkTaskDocument(text: fixture.firstDraft + "LATEST_EDIT_PUBLIC_529\r\n")
                    checks["readOnlyRecoveryLayoutRejectsCloseCheckpoint"] = !(await control.flushWorkspaceRecovery())
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.path)
                    checks["partialPageWriteCanRetryAfterLayoutPermissionRestores"] = await control.flushWorkspaceRecovery()
                    await original.checkTaskDocument(text: fixture.firstDraft); guard await flushWorkspaceWindows() else { throw PetError("最后编辑未保存到恢复区") }
                    let file = URL(fileURLWithPath: fixture.guide), files = try AgentFiles(workspace: file.deletingLastPathComponent().path), before = try files.readData(file)
                    let external = Data("EXTERNAL_CHANGE_PUBLIC_740\n".utf8); try files.writeData(external, to: file)
                    await original.checkTaskDocument(action: "save")
                    let originalState = try AgentRecordWindow.recoveryState(await original.captureWorkspaceRecovery())
                    checks["restoredOldVersionCannotOverwriteExternalFileChange"] = try files.readData(file) == external && control.taskWorkspace.currentController is AgentFileConflictWindow && originalState.openedHash == fixture.guideHash
                    control.taskWorkspace.checkBack(); try files.writeData(before, to: file)
                    await original.checkTaskDocument(action: "preview")
                }
                checks["taskComposerDraftsRemainExact"] = [fixture.first, fixture.second, fixture.standalone].allSatisfy { tasks.task($0)?.draft == "保留原任务输入 PUBLIC_482" }
                let files = try AgentFiles(workspace: URL(fileURLWithPath: fixture.guide).deletingLastPathComponent().path)
                checks["sourceFilesRemainExactAfterRestartAndConflict"] = try files.fileHash(URL(fileURLWithPath: fixture.guide)) == fixture.guideHash && files.fileHash(URL(fileURLWithPath: fixture.plain)) == fixture.plainHash
            }
            report["stage"] = stage; report["fixture"] = fixtureURL.path
            report["mainWorkspace"] = control.taskWorkspace.checkState()
            checks["modelRuntimeMakesNoRequest"] = requests == 0
            checks["allWorkspaceSnapshotsCurrent"] = await flushWorkspaceWindows()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["scope"] = "Window/tab layouts and Record text/Markdown/memory drafts; Office, Canvas selection, browser/annotation, MCP parameters and detached editors remain in the full recovery scope."
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "workspace-recovery-ui-ready.json" : "workspace-recovery-lifecycle-report.json"))
    }
}
