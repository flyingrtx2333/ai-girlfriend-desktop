import AppKit

@MainActor extension AppDelegate {
    func prepareWikiLifecycleUI(_ output: URL) async throws {
        let original = try await prepareKnowledgePageUI(output)
        guard let tasks = agentStore, let source = tasks.task(original.taskID) else { throw PetError("Wiki 维护项目未初始化") }
        tasks.update(source.id) { $0.permission = .automatic }
        let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("source-input.json"))) as! [String: Any]
        let files = try AgentFiles(workspace: original.workspace.path), git = try AgentWiki.updateGit(store: tasks, taskID: source.id)
        let base = try await AgentWiki.cleanCommit(store: tasks, taskID: source.id)
        guard base == inputs["baseCommit"] as? String else { throw PetError("真实基线提交不一致") }
        _ = try await AgentWiki.exportWiki(store: tasks, taskID: source.id, language: "zh")
        let metadata = try AgentWiki.sharingPath("zh") + "/" + AgentWiki.transferMetadata
        var transfer = try JSONDecoder().decode(AgentWikiTransfer.self, from: files.readData(files.resolve(metadata), maximum: 4_000_000))
        transfer.sourceCommit = base
        try files.writeData(JSONEncoder().encode(transfer), to: files.resolve(metadata))
        try await AgentWiki.importWiki(AgentWiki.previewWikiImport(store: tasks, taskID: source.id, language: "zh"), store: tasks, taskID: source.id)
        for name in ["README.md", "docs/REPO-WIKI.md"] {
            let bytes = try Data(contentsOf: output.appendingPathComponent("next-snapshot/" + name))
            try files.writeData(bytes, to: files.resolve(name))
        }
        for args in [["add", "--", "README.md", "docs/REPO-WIKI.md"], ["commit", "--quiet", "-m", "Actual current public documentation"]] {
            let result = try await git.run(args, write: true); guard !result.failed else { throw PetError(result.text) }
        }
        let head = try await AgentWiki.cleanCommit(store: tasks, taskID: source.id)
        let preview = try await AgentWiki.previewUpdate(store: tasks, runtime: agentRuntime!, sourceID: source.id, language: "zh")
        guard preview.baseCommit == base, preview.commit == head, preview.changedPaths == ["README.md", "docs/REPO-WIKI.md"], preview.diff.count > 500 else { throw PetError("真实公开文档差异不符合验收范围") }
        try Data(preview.diff.utf8).write(to: output.appendingPathComponent("initial-actual-diff.patch"))
        let published = try AgentWiki.plannedManifest(store: tasks, taskID: source.id, language: "zh")!
        let value: [String: Any] = ["taskID": source.id, "standaloneID": original.standaloneID, "workspace": original.workspace.path, "baseCommit": base, "head": head, "publishedID": published.taskID, "initialDiffSHA256": AgentFiles.hash(Data(preview.diff.utf8)), "origin": "Actual historical and current public Git source snapshots; manually imported Wiki", "modelTransmissions": 0]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-lifecycle-fixtures.json"))
        control.showAgentTask(source.id)
    }
    func reopenWikiLifecycleUI(_ output: URL) throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("wiki-lifecycle-fixtures.json"))) as! [String: Any]
        guard let id = value["taskID"] as? String, agentStore?.task(id) != nil else { throw PetError("原 Wiki 维护任务不存在") }; control.showAgentTask(id)
    }
    func runWikiLifecycleCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], blocked = 0
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { blocked += 1; throw PetError("Wiki 页面验收禁止模型传输") }
            try await prepareWikiLifecycleUI(output)
            let f = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("wiki-lifecycle-fixtures.json"))) as! [String: Any]
            let id = f["taskID"] as! String, workspace = f["workspace"] as! String, files = try AgentFiles(workspace: workspace), host = control.knowledgePageHost
            let before = try await AgentWiki.snapshot(tasks, id, "zh"), originalDraft = tasks.task(id)?.draft
            guard let mainWindow = control.window else { throw PetError("缺少 Wiki 验收主窗口") }
            let narrow = NSSize(width: 780, height: 540)
            mainWindow.setContentSize(narrow)
            control.showAgentKnowledge(); guard let catalog = host.currentController as? AgentRepoWikiWindow else { throw PetError("知识目录未打开") }
            for _ in 0..<200 { if catalog.checkState["loading"] as? Bool == false { break }; await wait(0.02) }
            checks["catalogTakesKeyboardFocusFromTaskSidebar"] = host.checkState()["focusInPage"] as? Bool == true
            checks["catalogKeepsMinimumWindowSize"] = mainWindow.frame.size == narrow
            try catalog.checkOpen(workspace: workspace, action: "wiki")
            guard let reader = host.currentController as? AgentRecordWindow else { throw PetError("Wiki 正文未打开") }
            checks["readerTakesKeyboardFocusFromTaskSidebar"] = host.checkState()["focusInPage"] as? Bool == true
            await wait(0.15)
            mainWindow.contentView?.layoutSubtreeIfNeeded()
            checks["openingReaderKeepsMinimumWindowSize"] = mainWindow.frame.size == narrow
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let readerView = reader.pageContentView,
                  let compare = descendants(readerView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "比较" }) else {
                throw PetError("缺少 Wiki 比较入口")
            }
            compare.performClick(nil)
            guard let comparison = host.currentController as? AgentFileConflictWindow else { throw PetError("Wiki 比较未打开") }
            for _ in 0..<100 {
                if comparison.checkState["loading"] as? Bool == false { break }
                await wait(0.025)
            }
            let journal = try await host.captureWorkspaceRecovery(active: true)
            guard let page = journal?.readers.first, let path = try AgentRecordWindow.recoveryState(page).file else {
                throw PetError("Wiki 比较未写入阅读器状态")
            }
            var recovering = try AgentRecordWindow.recoveryState(page)
            checks["visibleWikiComparisonRestoresAsActiveReader"] = journal?.active == true && recovering.conflict?.file == path
            comparison.close()
            do {
                let file = URL(fileURLWithPath: path), held = output.appendingPathComponent("held-recovery-document.md")
                let draft = try AgentTextFile.decode(files.readData(file)).text + "\n\n保留的 Wiki 原稿。"
                recovering.dirty = true; recovering.text = draft; recovering.conflict = nil
                recovering.mode = 1; recovering.textViewport = nil; recovering.markdownViewport = nil
                let offline = AgentWorkspaceRecovery.Page(taskID: id, kind: "record", state: try JSONEncoder().encode(recovering), dirty: true, asset: nil)
                try FileManager.default.moveItem(at: file, to: held)
                defer { try? FileManager.default.moveItem(at: held, to: file) }
                let restored = AgentRecordWindow(store: tasks, taskID: id, section: 6, wikiOnly: true)
                try restored.restoreWorkspaceRecovery(offline)
                let snapshot = await restored.markdownEditingReadback()
                let retained = try AgentRecordWindow.recoveryState(await restored.captureWorkspaceRecovery())
                checks["missingWikiKeepsOriginalDraftInReadOnlyEditor"] = snapshot["draft"] as? String == draft &&
                    snapshot["sourceEditable"] as? Bool == false && retained.file == path && retained.dirty
                checks["missingWikiKeepsOriginalPublicationAndDocument"] = retained.wikiDirectory?.root == before.root &&
                    retained.wikiDirectory?.document == recovering.wikiDirectory?.document
            }
            var created: [String] = []
            reader.configureWikiRuntime(runtime) { next in created.append(next); runtime.cancel(next) }
            func inspect(_ name: String, _ review: AgentKnowledgeReviewWindow) {
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    control.window?.appearance = NSAppearance(named: appearance)
                    for (sizeName, size) in [("normal", NSSize(width: 1320, height: 800)), ("narrow", narrow)] {
                        control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); let value = host.checkState(); report[name + "-" + theme + "-" + sizeName] = value
                        checks[name + "-" + theme + "-" + sizeName + "-keepsWindowSize"] = mainWindow.frame.size == size
                        for (key, value) in value["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + theme + "-" + sizeName + "-" + key] = value }
                    }
                }
                checks[name + "-hostedWithoutFloatingWindow"] = review.window?.isVisible == false && review.presentingWindow === control.window
            }
            guard let update = await reader.checkKnowledgeReview("update") else { throw PetError("增量审阅页未打开") }
            checks["actualPreviewReadBlocksNavigationAndClose"] = update.hasPendingOperation && !host.prepareToLeave() && !reader.prepareWorkspaceNavigation()
            do { try control.requireTaskDeletionAllowed([id]); checks["actualPreviewReadProtectsTaskDeletion"] = false } catch { checks["actualPreviewReadProtectsTaskDeletion"] = true }
            update.close(); checks["closeDuringActualReadKeepsReview"] = host.currentController === update
            await update.checkLoad()
            let actualDiff = try String(contentsOf: output.appendingPathComponent("initial-actual-diff.patch"), encoding: .utf8)
            checks["coloredDiffShowsCompleteActualCommittedPatch"] = update.checkState["showingDiff"] as? Bool == true && update.checkState["text"] as? String == actualDiff
            checks["updateTakesKeyboardFocusFromTaskSidebar"] = update.checkState["focusInReview"] as? Bool == true
            checks["openingReviewKeepsMinimumWindowSize"] = mainWindow.frame.size == narrow
            let diffPosition = try update.captureVersionPosition()
            checks["incrementalDiffCapturesMatchingTextAndTarget"] = diffPosition?.itemID == "diff" &&
                diffPosition?.body?.hash == AgentFiles.hash(Data(actualDiff.utf8)) && diffPosition?.targetSignature != nil
            update.checkSelectItem(1)
            let updateJournal = try await host.captureWorkspaceRecovery(active: true)
            let updatePosition = try updateJournal?.readers.first.map(AgentRecordWindow.recoveryState)?.versionReview
            checks["activeIncrementalReviewSavesProjectAndSelectedFiles"] = updateJournal?.active == true &&
                updatePosition?.context.taskID == id && updatePosition?.context.workspace == workspace &&
                updatePosition?.context.kind == .wikiUpdate && updatePosition?.itemID == "files"
            mainWindow.performClose(nil)
            let closeDeadline = Date().addingTimeInterval(3)
            while mainWindow.isVisible, Date() < closeDeadline { await wait(0.02) }
            checks["closingMainWindowRetainsReviewWhileHidden"] = !mainWindow.isVisible && host.currentController === update
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            checks["applicationReopenShowsSameReviewAndSelectedItem"] = control.window === mainWindow && mainWindow.isVisible &&
                control.isShowingKnowledge && host.currentController === update && update.checkState["selectedItem"] as? Int == 1 &&
                (host.checkState()["checks"] as? [String: Bool])?["currentPageIsVisible"] == true
            update.checkSelectItem(0)
            checks["applicationReopenRetainsActualDiffAndTaskDraft"] = update.checkState["text"] as? String == actualDiff && tasks.task(id)?.draft == originalDraft
            control.show(tab: "chat")
            checks["hiddenReviewFailsVisibilityCheckWithoutLosingPreview"] = (host.checkState()["checks"] as? [String: Bool])?["currentPageIsVisible"] == false && host.currentController === update && update.checkState["text"] as? String == actualDiff
            control.showAgentKnowledge()
            checks["returnToRetainedReviewRestoresVisibilityAndFocus"] = (host.checkState()["checks"] as? [String: Bool])?["currentPageIsVisible"] == true && host.currentController === update && update.checkState["focusInReview"] as? Bool == true
            checks["updateNamesBothActualCommitIDs"] = (update.checkState["items"] as? [[String: Any]])?.first?["detail"] as? String == String((f["baseCommit"] as! String).prefix(8)) + " → " + String((f["head"] as! String).prefix(8))
            inspect("update", update); update.checkSelectItem(1)
            checks["fileListShowsExactCommittedPaths"] = update.checkState["text"] as? String == "README.md\ndocs/REPO-WIKI.md" && update.checkState["showingDiff"] as? Bool == false
            await update.checkReload()
            checks["repreviewRestoresCompleteFirstDiff"] = update.checkState["text"] as? String == actualDiff && update.checkState["showingDiff"] as? Bool == true
            update.checkFocusBody()
            checks["actualDiffBodyCanTakeKeyboardFocus"] = update.checkState["bodyFocused"] as? Bool == true
            await update.checkReload()
            checks["repreviewFromActualDiffBodyKeepsKeyboardFocus"] = update.checkState["focusInReview"] as? Bool == true && update.checkState["text"] as? String == actualDiff && (host.checkState()["checks"] as? [String: Bool])?["currentPageIsVisible"] == true
            update.close(); let canceled = await reader.markdownEditingReadback()
            checks["cancelLeavesPublicationAndOriginalInputUntouched"] = try await AgentWiki.snapshot(tasks, id, "zh").pointer == before.pointer && tasks.task(id)?.draft == originalDraft && created.isEmpty && (canceled["state"] as? String)?.hasPrefix("正在") == false
            checks["returningToReaderKeepsMinimumWindowSize"] = mainWindow.frame.size == narrow
            guard let stale = await reader.checkKnowledgeReview("update") else { throw PetError("过期审阅页未打开") }; await stale.checkLoad()
            let third = try Data(contentsOf: output.appendingPathComponent("third-snapshot/native/AgentWiki.swift")); try files.writeData(third, to: files.resolve("native/AgentWiki.swift"))
            let git = try AgentWiki.updateGit(store: tasks, taskID: id)
            for args in [["add", "--", "native/AgentWiki.swift"], ["commit", "--quiet", "-m", "Actual public Wiki implementation snapshot"]] {
                let result = try await git.run(args, write: true); guard !result.failed else { throw PetError(result.text) }
            }
            let count = tasks.tasks.count; await stale.checkApply()
            checks["newActualCommitRejectsStaleApplyWithoutCreatingTask"] = created.isEmpty && tasks.tasks.count == count && stale.checkState["applyEnabled"] as? Bool == false && stale.checkState["text"] as? String == ""
            await stale.checkReload(); let reviewedDiff = stale.checkState["text"] as? String
            stale.checkBeginApply()
            checks["actualApplyBlocksNavigationAndClose"] = stale.hasPendingOperation && !host.prepareToLeave() && !reader.prepareWorkspaceNavigation()
            do { try control.requireTaskDeletionAllowed([id]); checks["actualApplyProtectsTaskDeletion"] = false } catch { checks["actualApplyProtectsTaskDeletion"] = true }
            await stale.checkApply()
            let updated = created.last.flatMap(tasks.task)
            checks["applyCreatesActualFrozenUpdateAndReturnsToReader"] = updated?.wikiJob?.update?.diff == reviewedDiff && updated?.wikiJob?.update?.baseCommit == f["baseCommit"] as? String && host.currentController === reader
            checks["updateDraftDoesNotPublishOrReplaceOriginalWiki"] = try await AgentWiki.snapshot(tasks, id, "zh").pointer == before.pointer && updated?.wikiJob?.root != before.root
            guard let regenerate = await reader.checkKnowledgeReview("regenerate") else { throw PetError("重新生成审阅页未打开") }; await regenerate.checkLoad()
            checks["defaultRegenerationPreviewUsesActualDefaultPlan"] = regenerate.checkState["text"] as? String == AgentWikiPlan.initialYAML && (regenerate.checkState["impact"] as? String)?.contains("自动规划") == true
            checks["regenerationTakesKeyboardFocusFromTaskSidebar"] = regenerate.checkState["focusInReview"] as? Bool == true
            regenerate.close()
            let plan = "version: 1\nrepowiki:\n  template: architecture\n  documents:\n    - title: 项目文档\n      goal: 核对公开 README 的实际入口\n    - title: 公开来源\n      goal: 标明实际源码与阅读范围\nknowledgecard:\n  notes: []\n"
            let planURL = try files.literalURL(AgentWikiPlan.configurationPath); try files.writeData(Data(plan.utf8), to: planURL)
            guard let planned = await reader.checkKnowledgeReview("regenerate") else { throw PetError("明确规划的审阅页未打开") }; await planned.checkLoad()
            checks["regenerationShowsCompleteActualConfiguration"] = planned.checkState["text"] as? String == plan && (planned.checkState["impact"] as? String)?.contains("Wiki · 2 页") == true
            inspect("regenerate", planned); planned.checkSelectItem(1)
            checks["regenerationListsActualCurrentDocuments"] = (planned.checkState["text"] as? String)?.components(separatedBy: "\n").count == 2
            let planJournal = try await host.captureWorkspaceRecovery(active: true)
            let planPosition = try planJournal?.readers.first.map(AgentRecordWindow.recoveryState)?.versionReview
            checks["activeRegenerationReviewSavesLanguageAndSelectedDocuments"] = planJournal?.active == true &&
                planPosition?.context.kind == .wikiRegeneration && planPosition?.context.language == "zh" && planPosition?.itemID == "documents"
            let modified = plan + "# 实际确认后的规划变化\n"; try files.writeData(Data(modified.utf8), to: planURL); let beforeRegeneration = created.count
            await planned.checkApply()
            checks["changedConfigurationRejectsRegenerationBeforeNewTask"] = created.count == beforeRegeneration && planned.checkState["applyEnabled"] as? Bool == false && planned.checkState["text"] as? String == ""
            await planned.checkReload(); await planned.checkApply()
            let regenerated = created.last.flatMap(tasks.task)
            checks["regenerationCreatesActualFrozenPlanAndReturns"] = created.count == beforeRegeneration + 1 && regenerated?.wikiJob?.plan.documents?.count == 2 && regenerated?.wikiJob?.configurationHash == AgentFiles.hash(Data(modified.utf8)) && host.currentController === reader
            guard let english = await reader.checkKnowledgeReview("regenerate", language: "en") else { throw PetError("英文未发布审阅页未打开") }; await english.checkLoad()
            checks["unpublishedLanguageClearlyIncludesWikiAndCards"] = (english.checkState["scope"] as? String)?.hasSuffix("English") == true && (english.checkState["impact"] as? String)?.hasPrefix("Wiki 与卡片") == true
            english.close()
            checks["allOriginalWikiAndTaskInputsRemain"] = try await AgentWiki.snapshot(tasks, id, "zh").pointer == before.pointer && before.data.allSatisfy { try files.readData(files.resolve(before.root + "/" + $0.key), maximum: 20_000_000) == $0.value } && tasks.task(id)?.draft == originalDraft && tasks.task(f["standaloneID"] as! String)?.draft == "无工作区任务未发送的草稿。"
            checks["actualJobsHaveNoModelUsageOrPublishedCompletion"] = created.count == 2 && created.compactMap(tasks.task).allSatisfy { !$0.hasConfirmedWikiCompletion && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["createdTaskIDs"] = created; report["fixture"] = f; host.finish()
            let navigation = try await checkTaskWikiDirectory(output, taskID: id, window: mainWindow)
            checks.merge(navigation.checks) { _, value in value }
            report["taskWikiDirectory"] = navigation.scenes
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["blockedBeforeTransmission"] = blocked; report["modelTransmissions"] = 0; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-lifecycle-report.json"))
    }

    private func checkTaskWikiDirectory(_ output: URL, taskID: String, window: NSWindow) async throws -> (checks: [String: Bool], scenes: [String: [String: Any]]) {
        guard let tasks = agentStore, let task = tasks.task(taskID), let root = window.contentView else { throw PetError("缺少任务 Wiki 窗口") }
        let before = try await AgentWiki.snapshot(tasks, taskID, "zh")
        let originalAppearance = window.appearance, originalFrame = window.frame
        defer { window.appearance = originalAppearance; window.setFrame(originalFrame, display: true) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func visible(_ view: NSView) -> Bool { view.window === window && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty }
        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: root) }
        func resize(_ width: CGFloat, _ height: CGFloat, _ appearance: NSAppearance.Name) async {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: height))
            await wait(0.2); root.layoutSubtreeIfNeeded()
        }

        await resize(1200, 774, .darkAqua)
        control.showAgentTask(taskID); control.presentAgentRecords(section: 4)
        guard let sections = descendants(root).compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == 7 && $0.label(forSegment: 6) == "Wiki" }),
              let record = sections.target as? AgentRecordWindow, let page = record.pageContentView else { throw PetError("任务记录的 Wiki 标签未打开") }
        sections.selectedSegment = 6; _ = sections.sendAction(sections.action, to: record)
        await wait(0.2); root.layoutSubtreeIfNeeded()
        guard let directory = descendants(page).compactMap({ $0 as? AgentWikiTree }).first,
              let search = descendants(directory).compactMap({ $0 as? NSSearchField }).first,
              let outline = descendants(directory).compactMap({ $0 as? NSOutlineView }).first, let scroll = outline.enclosingScrollView,
              let language = descendants(directory).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "Wiki 语言" }),
              let more = descendants(directory).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "Wiki 更多操作" }),
              let plan = descendants(directory).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "Wiki 生成规划" }),
              let toggle = descendants(page).compactMap({ $0 as? NSButton }).first(where: { $0.title == "目录" }),
              let reader = descendants(page).compactMap({ $0 as? AgentMarkdownReader }).first else { throw PetError("Wiki 目录或正文控件未载入") }
        var checks: [String: Bool] = [:], scenes: [String: [String: Any]] = [:]
        func capture(_ name: String) throws {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw PetError("无法保存任务 Wiki 窗口截图") }
            bitmap.size = root.bounds.size; root.cacheDisplay(in: root.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("任务 Wiki 窗口截图无效") }
            try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
            scenes[name] = ["size": NSStringFromSize(window.frame.size), "directory": NSStringFromRect(rect(directory)), "reader": NSStringFromRect(rect(reader)),
                            "treeViewport": NSStringFromSize(scroll.contentSize), "rowHeight": outline.rowHeight, "rows": outline.numberOfRows,
                            "lastRowBottom": outline.numberOfRows == 0 ? 0 : outline.rect(ofRow: outline.numberOfRows - 1).maxY,
                            "columnWidth": outline.tableColumns.first?.width ?? 0, "tree": directory.checkState]
        }
        language.selectItem(withTitle: "简体中文"); _ = language.sendAction(language.action, to: language.target)
        await wait(0.15)
        try capture("task-wiki-split-dark")
        checks["taskWikiCompactPaneShowsBothPagesAndReader"] = visible(search) && visible(language) && visible(reader) && outline.numberOfRows == 2 &&
            scroll.contentSize.height >= outline.rect(ofRow: 1).maxY && scroll.contentSize.height <= 84 &&
            rect(directory).minY >= rect(reader).maxY && rect(reader).height >= 300
        let columnWidth = outline.tableColumns.first?.width ?? 0
        checks["taskWikiColumnUsesAvailableWidth"] = columnWidth >= scroll.contentSize.width - 32 && columnWidth > 300

        await resize(780, 540, .aqua)
        try capture("task-wiki-beside-light")
        checks["taskWikiAtMinimumWindowShowsDirectoryToLeftOfReadableContent"] = window.frame.size == NSSize(width: 780, height: 540) &&
            visible(outline) && visible(reader) && rect(directory).maxX < rect(reader).minX && rect(reader).width >= 300
        search.stringValue = "公开"; directory.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        if outline.numberOfRows == 1 { outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        await wait(0.1)
        let picked = directory.selectedDocument
        let selectedText = await record.markdownEditingReadback()["draft"] as? String
        let fileBytes = try picked.map { path in
            let files = try AgentFiles(workspace: task.workspace)
            return try files.readData(files.resolve(path))
        }
        checks["taskWikiSearchOpensTheActualMatchingPublication"] = picked?.hasSuffix("/sources.md") == true &&
            fileBytes.flatMap { String(data: $0, encoding: .utf8) } == selectedText && outline.selectedRow == 0
        let readerWidth = rect(reader).width
        toggle.performClick(nil); root.layoutSubtreeIfNeeded()
        let collapsed = directory.superview == nil && visible(reader) && rect(reader).width > readerWidth && toggle.accessibilityLabel() == "显示 Wiki 目录"
        toggle.performClick(nil); await wait(0.15)
        let reopenedText = await record.markdownEditingReadback()["draft"] as? String
        checks["taskWikiDirectoryCanCollapseAndRestoreItsFilterAndSelection"] = collapsed && visible(outline) && search.stringValue == "公开" &&
            directory.selectedDocument == picked && outline.selectedRow == 0 && reopenedText == selectedText
        search.stringValue = ""; directory.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))

        language.selectItem(withTitle: "English"); _ = language.sendAction(language.action, to: language.target)
        await resize(780, 540, .darkAqua)
        try capture("task-wiki-empty-dark")
        let importItem = more.menu?.items.first { $0.representedObject as? String == "import" }
        checks["emptyTaskWikiShowsLanguagePlanningAndImportWithoutADisabledPicker"] = directory.selectedLanguage == "en" && outline.numberOfRows == 0 &&
            directory.checkState["emptyVisible"] as? Bool == true && visible(language) && visible(plan) && visible(more) && plan.isEnabled && importItem?.isEnabled == true &&
            !visible(reader) && !visible(toggle) && rect(directory).width >= page.bounds.width - 34
        plan.performClick(nil); await wait(0.15); root.layoutSubtreeIfNeeded()
        let planText = descendants(root).compactMap({ $0 as? NSTextView }).first { $0.accessibilityLabel() == "Wiki 规划 YAML" && visible($0) }
        checks["emptyTaskWikiOpensPlanningInTheSameRecordTab"] = planText?.window === window && planText?.string.isEmpty == false && !window.hasBlockingDialog
        if let close = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == "关闭" && $0.target is AgentWikiPlanWindow && visible($0) }) {
            close.performClick(nil)
        }
        root.layoutSubtreeIfNeeded()
        checks["taskWikiReturnsFromPlanningToTheSameEmptyDirectory"] = visible(language) && directory.selectedLanguage == "en" && outline.numberOfRows == 0
        let missingSource: String
        do { _ = try await AgentWiki.previewWikiImport(store: tasks, taskID: taskID, language: "en"); missingSource = "" }
        catch { missingSource = error.localizedDescription }
        var importReadback: [String: Any] = ["expectedError": missingSource, "actionSent": false]
        checks["emptyTaskWikiCanOpenImportAndSeeTheActualMissingSource"] = false
        if let importItem, let action = importItem.action {
            importReadback["actionSent"] = NSApp.sendAction(action, to: importItem.target, from: importItem)
            var review: AgentKnowledgeReviewWindow?
            for _ in 0..<80 {
                review = descendants(root).compactMap { ($0 as? NSButton)?.target as? AgentKnowledgeReviewWindow }.first(where: \.isPageVisible)
                if review != nil { break }
                await wait(0.025)
            }
            if let review {
                await review.checkLoad()
                let state = review.checkState; importReadback["review"] = state
                checks["emptyTaskWikiCanOpenImportAndSeeTheActualMissingSource"] = review.presentingWindow === window && review.window?.isVisible == false &&
                    !window.hasBlockingDialog && state["applyEnabled"] as? Bool == false && missingSource.hasPrefix("缺少 Wiki 导入文件 .bluefatfish/repowiki/en/") &&
                    state["state"] as? String == missingSource
                review.close()
            }
        }
        let importData = try JSONSerialization.data(withJSONObject: importReadback, options: [.prettyPrinted, .sortedKeys])
        try importData.write(to: output.appendingPathComponent("task-wiki-import.json"), options: .atomic)
        language.selectItem(withTitle: "简体中文"); _ = language.sendAction(language.action, to: language.target)
        await resize(1320, 800, .aqua)
        try capture("task-wiki-beside-wide-light")
        let after = try await AgentWiki.snapshot(tasks, taskID, "zh")
        checks["taskWikiSwitchesBackToPublishedLanguageWithOriginalFilesAndDraft"] = directory.selectedLanguage == "zh" && outline.numberOfRows == 2 && visible(reader) &&
            before.pointer == after.pointer && before.data == after.data && tasks.task(taskID)?.draft == task.draft
        return (checks, scenes)
    }
}
