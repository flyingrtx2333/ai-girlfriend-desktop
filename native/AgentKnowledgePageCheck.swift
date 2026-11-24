import AppKit

@MainActor extension AppDelegate {
    struct KnowledgePageFixture {
        let taskID: String, standaloneID: String, baseID: String, sourceID: String, workspace: URL, page: String
    }
    func prepareKnowledgePageUI(_ output: URL) async throws -> KnowledgePageFixture {
        guard !CommandLine.arguments.contains("--live-agent"), let argument = CommandLine.arguments.firstIndex(of: "--knowledge-page-source"), CommandLine.arguments.indices.contains(argument + 1) else { throw PetError("知识中心验收需要公开文档，不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("知识中心存储未初始化") }
        let source = URL(fileURLWithPath: CommandLine.arguments[argument + 1]), original = try Data(contentsOf: source)
        guard let originalText = String(data: original, encoding: .utf8), !originalText.isEmpty else { throw PetError("公开文档不是有效 UTF-8 文本") }
        let project = output.appendingPathComponent("public-project"), wiki = project.appendingPathComponent(".bluefatfish/wiki")
        try FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try original.write(to: project.appendingPathComponent("README.md"))
        let excerpt = originalText.components(separatedBy: "\n").prefix(8).joined(separator: "\n")
        for (name, title) in [("index.md", "项目文档"), ("sources.md", "公开来源")] {
            try Data(("# " + title + "\n\n" + excerpt + "\n\n[README 原文](../../README.md#L1-L8)\n").utf8).write(to: wiki.appendingPathComponent(name))
        }
        let id = tasks.create(title: "公开项目知识", workspace: project.path), standalone = tasks.create(title: "无工作区的资料阅读", mode: .ask, workMode: .general)
        tasks.update(id) { $0.draft = "项目任务未发送的草稿。" }; tasks.update(standalone) { $0.draft = "无工作区任务未发送的草稿。" }
        try tasks.organization.register(project.path, mode: .coding)
        let index = try AgentProjectIndex(workspace: project.path, storage: tasks.directory), indexed = try await index.run(paths: nil)
        _ = try await AgentWiki.exportWiki(store: tasks, taskID: id, language: "zh")
        let imported = try await AgentWiki.previewWikiImport(store: tasks, taskID: id, language: "zh"); try await AgentWiki.importWiki(imported, store: tasks, taskID: id)
        guard let task = tasks.task(id) else { throw PetError("公开项目任务未保存") }
        let scope = try tasks.knowledgeCards.scope(task), card = AgentKnowledgeCard(title: "README 原文", kind: .architecture, body: excerpt, sources: [AgentKnowledgeCardSource(path: "README.md", line: 1, endLine: 8, sha256: AgentFiles.hash(original))], manual: true)
        let book = AgentKnowledgeCardBook(workspace: scope.root, branch: scope.branch, language: "zh", sourceRevision: indexed.index.revision, cards: [card])
        try tasks.knowledgeCards.publish(book, task: task, expected: tasks.knowledgeCards.book(task, language: "zh").1)
        let base = try tasks.knowledge.create(name: "公开项目资料", workspace: nil), importedSource = try await tasks.knowledge.add(project.appendingPathComponent("README.md"), baseID: base.id)
        let view = try AgentWiki.view(store: tasks, taskID: id, language: "zh")
        guard view.manifest?.origin == "import", let page = view.pages.first?.path else { throw PetError("实际手工导入的 Wiki 未载入") }
        let fixture = KnowledgePageFixture(taskID: id, standaloneID: standalone, baseID: base.id, sourceID: importedSource.id, workspace: project, page: page)
        try JSONSerialization.data(withJSONObject: ["taskID": id, "standaloneID": standalone, "baseID": base.id, "sourceID": importedSource.id, "workspace": project.path, "wikiPage": page, "sourceSHA256": AgentFiles.hash(original), "cardOrigin": "manual public source excerpt", "wikiOrigin": "import", "modelTransmissions": 0], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("knowledge-page-fixtures.json"))
        control.showAgentTask(standalone); return fixture
    }

    func runKnowledgePageCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("知识中心页面验收禁止模型传输") }
            let fixture = try await prepareKnowledgePageUI(output), host = control.knowledgePageHost
            let sourceData = try Data(contentsOf: fixture.workspace.appendingPathComponent("README.md"))
            var geometry: [String: Any] = [:]
            func inspect(_ name: String) {
                for (sizeName, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                    control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); host.currentController?.pageDidLayout()
                    let value = host.checkState(); geometry[name + "-" + sizeName] = value
                    for (key, pass) in value["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + sizeName + "-" + key] = pass }
                }
            }
            control.showKnowledgeLibrary()
            guard let library = host.currentController as? AgentKnowledgeLibraryWindow else { throw PetError("知识库未进入主页面") }
            checks["libraryOpensWithoutWorkspace"] = control.agentTaskID == fixture.standaloneID && library.presentingWindow === control.window
            inspect("library-catalog")
            checks.merge(try library.checkNameOperations()) { _, new in new }
            checks["libraryDocumentUsesActualImportedBytes"] = await library.checkSelect(base: fixture.baseID, source: fixture.sourceID) && library.checkState()["preview"] as? String == String(data: sourceData, encoding: .utf8)
            checks["clickingAlreadySelectedImportedFileOpensPreview"] = await library.checkOpenAlreadySelectedSource()
            inspect("library-document")
            library.checkGoBack()
            checks["returningToFileListAllowsReselectingSameFile"] = await library.checkSelect(base: fixture.baseID, source: fixture.sourceID)
            control.showAgentKnowledge()
            guard let catalog = host.currentController as? AgentRepoWikiWindow else { throw PetError("Wiki 目录未进入主页面") }
            for _ in 0..<150 { if catalog.checkState["loading"] as? Bool == false { break }; await wait(0.05) }
            checks["wikiCatalogReadsActualImportedPublication"] = (catalog.checkState["rows"] as? [[String: Any]])?.contains { $0["workspace"] as? String == fixture.workspace.path && $0["pages"] as? Int == 2 && $0["published"] as? Bool == true } == true
            inspect("wiki-catalog")
            try catalog.checkOpen(workspace: fixture.workspace.path, action: "wiki")
            guard let reader = host.currentController as? AgentRecordWindow else { throw PetError("Wiki 正文未进入主页面") }
            reader.selectItem(section: 6, value: fixture.page); await wait(0.25)
            let files = try AgentFiles(workspace: fixture.workspace.path), pageFile = try files.resolve(fixture.page), originalPage = try String(contentsOf: pageFile, encoding: .utf8)
            checks["wikiReaderShowsActualPublishedFile"] = await reader.markdownEditingReadback()["draft"] as? String == originalPage
            inspect("wiki-reader")
            let edited = originalPage + "\n<!-- 本机页内保存检查 -->\n"
            await reader.checkEditKnowledgeDocument(edited)
            let savedReader = await reader.markdownEditingReadback()
            checks["wikiMainPageSavesWithExistingFileVersionGuard"] = try String(contentsOf: pageFile, encoding: .utf8) == edited && savedReader["dirty"] as? Bool == false
            reader.checkKnowledgeSource(fixture.workspace.appendingPathComponent("README.md"))
            checks["wikiSourceLinkUsesOwnerMainContent"] = host.currentController is AgentMarkdownSourceWindow && (host.currentController as? AgentMarkdownSourceWindow)?.encodingCheckState["textHash"] as? String == AgentFiles.hash(sourceData)
            inspect("wiki-source"); host.checkBack()
            checks["returnFromWikiSourceKeepsSameReader"] = host.currentController === reader
            reader.checkOpenKnowledgePlan()
            guard let plan = host.currentController as? AgentWikiPlanWindow else { throw PetError("Wiki 规划未进入主页面") }
            inspect("wiki-plan")
            let planText = AgentWikiPlan.initialYAML + "\n# 主页面真实保存\n"; plan.checkEdit(planText)
            let planURL = try files.literalURL(AgentWikiPlan.configurationPath)
            checks["wikiPlanSavesActualProjectConfiguration"] = try String(contentsOf: planURL, encoding: .utf8) == planText && !plan.hasUnsavedChanges
            let disk = planText + "# 实际外部变更\n"; try Data(disk.utf8).write(to: planURL, options: .atomic); plan.checkEdit(planText + "# 保留的规划草稿\n")
            checks["externalPlanChangePreservesDraftAndDisk"] = try plan.hasUnsavedChanges && String(contentsOf: planURL, encoding: .utf8) == disk && (plan.checkState["draft"] as? String)?.contains("保留的规划草稿") == true
            do { try control.requireTaskDeletionAllowed([fixture.taskID]); checks["dirtyInlinePlanBlocksTaskDeletion"] = false } catch { checks["dirtyInlinePlanBlocksTaskDeletion"] = true }
            try Data(planText.utf8).write(to: planURL, options: .atomic); plan.checkEdit(planText, save: false); host.checkBack(); host.checkBack()
            for _ in 0..<150 { if catalog.checkState["loading"] as? Bool == false { break }; await wait(0.05) }
            try catalog.checkOpen(workspace: fixture.workspace.path, action: "cards")
            guard let cards = host.currentController as? AgentKnowledgeCardWindow else { throw PetError("知识卡片未进入主页面") }
            inspect("knowledge-cards")
            cards.format.selectedSegment = 1; cards.formatChanged(); cards.preview.string += "\n\n本机手动编辑。"; cards.titleField.stringValue = "已保存的 README 卡片"; cards.textDidChange(Notification(name: NSText.didChangeNotification, object: cards.preview)); cards.saveCard()
            checks["cardEditsUseActualVersionedBook"] = try tasks.knowledgeCards.book(tasks.task(fixture.taskID)!).0?.cards.first?.title == "已保存的 README 卡片" && !cards.dirty
            cards.preview.string += "\n来源阅读期间保留的草稿。"; cards.textDidChange(Notification(name: NSText.didChangeNotification, object: cards.preview)); let draft = cards.preview.string
            cards.openSource()
            checks["cardSourceUsesOwnerMainContentWithoutDiscardingDraft"] = host.currentController is AgentKnowledgeSourcePage && cards.dirty && cards.preview.string == draft
            inspect("card-source"); host.checkBack()
            checks["returnFromCardSourceRetainsDraft"] = host.currentController === cards && cards.dirty && cards.preview.string == draft
            do { try control.requireTaskDeletionAllowed([fixture.taskID]); checks["dirtyCardBlocksTaskDeletion"] = false } catch { checks["dirtyCardBlocksTaskDeletion"] = true }
            cards.saveCard(); host.checkBack()
            for _ in 0..<150 { if catalog.checkState["loading"] as? Bool == false { break }; await wait(0.05) }
            try catalog.checkOpen(workspace: fixture.workspace.path, action: "search")
            guard let search = host.currentController as? AgentKnowledgeWindow else { throw PetError("项目检索未进入主页面") }
            checks["indexSearchReadsActualFilesAndOpensInlineSource"] = await search.checkSearchAndOpen("BlueFatFish") && host.currentController is AgentKnowledgeSourcePage
            host.checkBack(); inspect("project-search")
            try await checkProjectSearchPage(search, workspace: fixture.workspace, output: output, checks: &checks)
            host.checkBack()
            control.showKnowledgeLibrary()
            checks["rootSwitchRetainsLibraryControllerAndDocument"] = host.currentController === library && library.checkState()["sourceID"] as? String == fixture.sourceID
            control.show(tab: "settings"); control.showKnowledgeLibrary()
            checks["settingsRoundTripRetainsKnowledgePage"] = host.currentController === library
            openTaskWindow(fixture.standaloneID, from: control)
            guard let other = additionalTaskWindows.last else { throw PetError("独立任务窗口不可用") }
            other.showKnowledgeLibrary()
            checks["taskWindowsOwnIndependentKnowledgeControllers"] = other.knowledgePageHost.currentController !== library && other.knowledgePageHost.currentController?.presentingWindow === other.window && library.presentingWindow === control.window
            other.window?.performClose(nil)
            for _ in 0..<100 { if other.window?.isVisible != true { break }; await wait(0.02) }
            checks["closingOtherWindowKeepsMainKnowledgePage"] = library.isPageVisible && other.window?.isVisible != true
            try await checkProjectKnowledgeApproval(tasks: tasks, output: output, checks: &checks)
            checks["allOriginalConversationDraftsRetained"] = tasks.task(fixture.taskID)?.draft == "项目任务未发送的草稿。" && tasks.task(fixture.standaloneID)?.draft == "无工作区任务未发送的草稿。"
            checks["manualDocumentsDoNotInventModelGeneration"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.kind != "wiki" && $0.kind != AgentKnowledgeCards.kind && !$0.messages.contains { $0.role == "assistant" } && ($0.modelReceipts ?? []).isEmpty }
            report["geometry"] = geometry; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        report["checks"] = checks; report["blockedModelAttempts"] = attempts; report["modelTransmissions"] = 0; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("knowledge-page-report.json"))
    }

    private func checkProjectKnowledgeApproval(tasks: AgentStore, output: URL, checks: inout [String: Bool]) async throws {
        let fm = FileManager.default, host = control.knowledgePageHost
        let project = output.appendingPathComponent("public-approval-project", isDirectory: true)
        let metadata = output.appendingPathComponent("公开知识项目独立仓库元数据", isDirectory: true)
        let replacement = output.appendingPathComponent("replacement-git", isDirectory: true)
        let parked = output.appendingPathComponent("original-git", isDirectory: true)
        let source = project.appendingPathComponent("README.md"), query = "approvalmarker"
        let content = Data("# Public project\n\(query) original source\n".utf8), draft = "核对项目连接时保留的草稿。"
        try fm.createDirectory(at: project, withIntermediateDirectories: false)
        try content.write(to: source)
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", project.path, "-c", "user.name=Public Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false"] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw PetError("无法准备公开 Git 样例") }
        }
        try git(["init", "--initial-branch=main", "--separate-git-dir", metadata.path]); try git(["add", "README.md"]); try git(["commit", "-m", "Public test"])
        try fm.copyItem(at: metadata, to: replacement)
        let index = try AgentProjectIndex(workspace: project.path, storage: tasks.directory)
        let searchTask = tasks.create(title: "连接项目检索", workspace: project.path, mode: .ask, draft: draft)
        try tasks.organization.register(project.path, mode: .coding)
        control.showAgentTask(searchTask); control.showAgentKnowledge()
        guard let catalog = host.currentController as? AgentRepoWikiWindow else { throw PetError("项目知识目录未打开") }
        for _ in 0..<100 { if catalog.checkState["loading"] as? Bool == false { break }; await wait(0.025) }
        try catalog.checkOpen(workspace: project.path, action: "search")
        guard let search = host.currentController as? AgentKnowledgeWindow, search.taskID == searchTask else { throw PetError("未打开原项目检索") }
        search.search.stringValue = query
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func approval(for operation: String) async throws -> (AgentProjectKnowledgeApproval, NSButton, NSButton) {
            for _ in 0..<100 {
                if let page = host.currentController as? AgentProjectKnowledgeApproval, let body = page.pageContentView {
                    let children = views(body), buttons = children.compactMap { $0 as? NSButton }
                    let text = children.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "设置审阅正文" }?.string ?? ""
                    if page.isPageVisible, page.window?.title == operation, text.contains(project.path), text.contains(metadata.path),
                       let cancel = buttons.first(where: { $0.title == "取消" }), let connect = buttons.first(where: { $0.title == "连接" }) {
                        return (page, cancel, connect)
                    }
                }
                await wait(0.025)
            }
            throw PetError("未打开\(operation)的原项目连接审阅")
        }
        search.find.performClick(nil)
        let (initial, cancel, _) = try await approval(for: "检索项目")
        checks["knowledgeApprovalUsesOriginalWindowAndSafeFocus"] = initial.presentingWindow === control.window &&
            control.window?.hasBlockingDialog == false && control.window?.firstResponder === cancel
        let recovery = try await host.captureWorkspaceRecovery(active: true)
        checks["pendingApprovalDoesNotScanOrPersistAndKeepsRecovery"] = index.snapshot() == nil && tasks.task(searchTask)?.gitDirectory == nil && recovery?.active == true
        cancel.performClick(nil); await search.job?.value
        checks["cancelReturnsToSameQueryAndDoesNotConnect"] = host.currentController === search && search.search.stringValue == query &&
            search.submittedQuery == nil && index.snapshot() == nil && tasks.task(searchTask)?.gitDirectory == nil

        search.find.performClick(nil)
        let (stale, dismiss, connectStale) = try await approval(for: "检索项目")
        try fm.moveItem(at: metadata, to: parked); try fm.moveItem(at: replacement, to: metadata)
        connectStale.performClick(nil)
        checks["samePathReplacementDisablesOldKnowledgeApproval"] = host.currentController === stale && !connectStale.isEnabled && tasks.task(searchTask)?.gitDirectory == nil
        try fm.moveItem(at: metadata, to: replacement); try fm.moveItem(at: parked, to: metadata)
        dismiss.performClick(nil); await search.job?.value

        search.find.performClick(nil)
        let (_, _, connect) = try await approval(for: "检索项目")
        let record = tasks.directory.appendingPathComponent(searchTask + ".json"), original = try Data(contentsOf: record)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: record.path)
        connect.performClick(nil)
        checks["readOnlyRecordDoesNotConnectOrStartIndex"] = try connect.isEnabled && tasks.task(searchTask)?.gitDirectory == nil &&
            Data(contentsOf: record) == original && index.snapshot() == nil
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        connect.performClick(nil); await search.job?.value
        checks["approvalResumesExactSearchInSamePage"] = host.currentController === search && search.submittedQuery == query &&
            search.hits.contains { $0.path == "README.md" } && tasks.task(searchTask)?.gitDirectory == metadata.path
        host.checkBack()

        let cardTask = tasks.create(title: "连接知识卡片", workspace: project.path, mode: .ask, draft: draft)
        control.showKnowledgeCards(taskID: cardTask)
        guard let cards = host.currentController as? AgentKnowledgeCardWindow else { throw PetError("知识卡片未打开") }
        try Data("# Public second file\n".utf8).write(to: project.appendingPathComponent("second.md"))
        checks["unconnectedCardPageOffersConnectionBeforeGeneration"] = cards.generate.title == "连接项目知识" && cards.generate.isEnabled
        cards.generate.performClick(nil)
        let (_, _, connectCards) = try await approval(for: "刷新知识卡片")
        checks["cardTaskRequiresItsOwnConnection"] = try tasks.task(cardTask)?.gitDirectory == nil && !index.contains("second.md")
        connectCards.performClick(nil); await cards.job?.value
        checks["cardRefreshContinuesAfterItsApproval"] = try host.currentController === cards && index.contains("second.md") && tasks.task(cardTask)?.gitDirectory == metadata.path
        host.checkBack()

        let wikiTask = tasks.create(title: "连接 Wiki 导入", workspace: project.path, draft: draft)
        let wiki = project.appendingPathComponent(".bluefatfish/wiki", isDirectory: true)
        try fm.createDirectory(at: wiki, withIntermediateDirectories: true)
        try Data("# 公开 Wiki 页面\n\n本文引用公开样例。\n".utf8).write(to: wiki.appendingPathComponent("index.md"))
        let publisher = tasks.create(title: "公开 Wiki 出版样例", workspace: project.path)
        tasks.update(publisher) { $0.gitDirectory = metadata.path }
        _ = try await AgentWiki.exportWiki(store: tasks, taskID: publisher, language: "zh")
        control.presentAgentRecords(section: 6, taskID: wikiTask)
        guard let reader = host.currentController as? AgentRecordWindow, let body = reader.pageContentView,
              let wikiConnect = views(body).compactMap({ $0 as? NSButton }).first(where: { $0.title == "连接项目知识" && $0.isEnabled }) else {
            throw PetError("未连接 Wiki 的主操作未打开")
        }
        wikiConnect.performClick(nil)
        let (_, cancelWiki, _) = try await approval(for: "连接 Wiki")
        cancelWiki.performClick(nil)
        for _ in 0..<100 { if wikiConnect.isEnabled { break }; await wait(0.025) }
        checks["wikiMainActionCanConnectWithoutStartingGeneration"] = wikiConnect.isEnabled && host.currentController === reader && tasks.task(wikiTask)?.gitDirectory == nil
        let importPreview = Task { @MainActor in await reader.checkKnowledgeReview("import", language: "zh") }
        let (_, _, connectWiki) = try await approval(for: "预览导入 Wiki")
        connectWiki.performClick(nil)
        guard let review = await importPreview.value else { throw PetError("连接后未继续原 Wiki 导入") }
        await review.checkLoad()
        checks["wikiConnectionContinuesToActualImportPreview"] = host.currentController === review &&
            review.checkState["applyEnabled"] as? Bool == true && tasks.task(wikiTask)?.gitDirectory == metadata.path
        checks["connectionPreservesOriginalSourcesAndAllThreeDrafts"] = try Data(contentsOf: source) == content &&
            [searchTask, cardTask, wikiTask].allSatisfy { tasks.task($0)?.draft == draft }
        host.checkBack(); host.checkBack()
    }

    private func checkProjectSearchPage(_ page: AgentKnowledgeWindow, workspace: URL, output: URL, checks: inout [String: Bool]) async throws {
        let host = control.knowledgePageHost
        guard let window = control.window, let content = page.pageContentView else { throw PetError("项目检索页面不可用") }
        let files = try AgentFiles(workspace: workspace.path)
        let path = "docs/技术指南/公共参考资料与测试流程/设备/verify-release-procedure.md"
        let source = try files.literalURL(path)
        let original = "# BlueFatFish release\n" + (1...54).map { "Public fixture line \($0)" }.joined(separator: "\n") + "\n"
        try files.writeData(Data(original.utf8), to: source)
        page.update.performClick(nil); await page.job?.value
        guard let row = page.hits.firstIndex(where: { $0.path == path }) else { throw PetError("更新索引后找不到新文件") }
        page.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        page.table.scrollRowToVisible(row)
        let expected = try files.read(path, offset: max(1, page.hits[row].line - 4), limit: 100)
        checks["searchResultsShowNewIndexedFileWithoutResubmitting"] = page.submittedQuery == "BlueFatFish" && page.open.isEnabled &&
            page.preview.string == expected && page.find.prominent
        let oldAppearance = window.appearance, oldSize = window.frame
        defer { window.appearance = oldAppearance; window.setFrame(oldSize, display: true) }
        func capture(_ name: String) throws {
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw PetError("项目检索页面无法渲染") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PetError("项目检索图像无法导出") }
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
        for (name, appearance, size) in [("narrow-dark", NSAppearance.Name.darkAqua, NSSize(width: 780, height: 540)),
                                         ("wide-light", NSAppearance.Name.aqua, NSSize(width: 1320, height: 800))] {
            window.appearance = NSAppearance(named: appearance)
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            func visible(_ button: NSButton) -> Bool {
                button.visibleRect.width >= button.bounds.width - 1 && button.visibleRect.height >= button.bounds.height - 1
            }
            checks["projectSearchControlsVisible-" + name] = [page.find, page.update, page.open].allSatisfy(visible) &&
                page.search.visibleRect.width >= 210 && (page.table.enclosingScrollView?.bounds.width ?? 0) >= 140 &&
                (page.preview.enclosingScrollView?.bounds.width ?? 0) >= 200 && !page.search.hasAmbiguousLayout
            let cell = page.table.view(atColumn: 0, row: row, makeIfNecessary: true)
            checks["projectSearchShowsLongPathInResult-" + name] = cell?.toolTip?.hasPrefix(path + ":") == true &&
                cell?.accessibilityLabel()?.contains(path) == true
            let actionFrame = content.convert(page.open.bounds, from: page.open)
            let readingFrame = page.preview.enclosingScrollView.map { content.convert($0.bounds, from: $0) } ?? .zero
            checks["projectSearchOpenActionStaysTrailing-" + name] = (0...18).contains(readingFrame.maxX - actionFrame.maxX)
            try capture("project-search-" + name)
        }
        page.search.stringValue = "这是还未提交的查询"
        page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: page.search))
        let selection = NSRange(location: 22, length: 10)
        page.preview.setSelectedRange(selection)
        page.update.performClick(nil); await page.job?.value
        await wait(0.08)
        checks["refreshKeepsSubmittedQuerySelectionAndUnsentInput"] = page.submittedQuery == "BlueFatFish" &&
            page.search.stringValue == "这是还未提交的查询" && page.hits.indices.contains(page.table.selectedRow) &&
            page.hits[page.table.selectedRow].path == path &&
            page.preview.selectedRange() == selection
        let checkpoint = try page.captureWorkspaceRecovery()
        let savedQuery = try checkpoint.map(AgentKnowledgeWindow.recoveryState)
        checks["workspaceCheckpointKeepsBothQueriesAndSelectedFile"] = savedQuery?.submittedQuery == "BlueFatFish" &&
            savedQuery?.query == "这是还未提交的查询" &&
            savedQuery.map { $0.hits.indices.contains($0.selected) && $0.hits[$0.selected].path == path } == true
        if let checkpoint, var state = try JSONSerialization.jsonObject(with: checkpoint.state) as? [String: Any] {
            state.removeValue(forKey: "submittedQuery")
            let legacy = AgentWorkspaceRecovery.Page(taskID: checkpoint.taskID, kind: checkpoint.kind, state: try JSONSerialization.data(withJSONObject: state),
                                                       dirty: checkpoint.dirty, asset: checkpoint.asset)
            let restored = AgentKnowledgeWindow(store: page.store, taskID: page.taskID)
            defer { restored.close() }
            try restored.restoreWorkspaceRecovery(legacy)
            checks["legacyWorkspaceCheckpointRetainsOriginalResults"] = restored.search.stringValue == page.search.stringValue &&
                restored.hits.count == page.hits.count && restored.preview.string == page.preview.string
        }
        let revised = original.replacingOccurrences(of: "Public fixture line 2\n", with: "Source changed after search\n")
        try files.writeData(Data(revised.utf8), to: source)
        page.table.deselectAll(nil)
        if let row = page.hits.firstIndex(where: { $0.path == path }) { page.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        checks["staleSourceBlocksReadingUntilIndexRefresh"] = page.previewBlocked && !page.open.isEnabled && page.preview.string.isEmpty &&
            page.state.stringValue.contains("更新索引") && !page.state.isHidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 780, height: 540)), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        try capture("project-search-stale-dark")
        page.update.performClick(nil); await page.job?.value
        checks["refreshedSourceUsesExactUpdatedBytes"] = page.open.isEnabled && page.preview.string.contains("Source changed after search") &&
            page.selectedHash == AgentFiles.hash(Data(revised.utf8)) && page.search.stringValue == "这是还未提交的查询"
        page.open.performClick(nil)
        checks["updatedFileOpensInSameRightContent"] = host.currentController is AgentKnowledgeSourcePage &&
            host.currentController?.presentingWindow === window
        host.checkBack()
        checks["sourceBackKeepsOriginalQueryAndSelection"] = host.currentController === page && page.search.stringValue == "这是还未提交的查询" &&
            page.hits.indices.contains(page.table.selectedRow) && page.hits[page.table.selectedRow].path == path
        let profiles = page.store.agents
        let originalRole = page.store.task(page.taskID)?.agent
        let searchOnly = AgentProfile(name: "检索样例", description: "只检索测试文档", instructions: "读取公开样例。", tools: ["search_project"], enabled: true)
        let indexOnly = AgentProfile(name: "索引样例", description: "只更新测试索引", instructions: "读取公开样例。", tools: ["index_project"], enabled: true)
        let prior = try profiles.document()
        try profiles.save(profiles.encode(try profiles.decode(prior.0) + [searchOnly, indexOnly]), expectedHash: prior.1)
        page.store.update(page.taskID) { $0.agent = .init(profile: searchOnly, workspace: workspace.path) }
        let pending = try files.literalURL("permission-fixture.md")
        try files.writeData(Data("BlueFatFish approval fixture\n".utf8), to: pending)
        let index = try AgentProjectIndex(workspace: workspace.path, storage: page.store.directory)
        page.update.performClick(nil); await page.job?.value
        let indexedWithSearchRole = try index.contains("permission-fixture.md")
        checks["refreshStillRequiresIndexPermission"] = page.state.stringValue.contains("index_project") && !indexedWithSearchRole
        page.store.update(page.taskID) { $0.agent = .init(profile: indexOnly, workspace: workspace.path) }
        page.update.performClick(nil); await page.job?.value
        checks["refreshWithOnlyIndexPermissionKeepsCurrentResults"] = try index.contains("permission-fixture.md") &&
            page.hits.allSatisfy { $0.path != "permission-fixture.md" } && page.submittedQuery == "BlueFatFish"
        page.store.update(page.taskID) { $0.agent = originalRole }
        page.search.stringValue = "NO_MATCH_FIXTURE_2814"; page.find.performClick(nil); await page.job?.value
        checks["noMatchesDisablesSourceWithoutInventingPreview"] = page.hits.isEmpty && page.preview.string.isEmpty &&
            !page.open.isEnabled && page.submittedQuery == "NO_MATCH_FIXTURE_2814"
    }
}
