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
            host.checkBack(); inspect("project-search"); host.checkBack()
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
            checks["allOriginalConversationDraftsRetained"] = tasks.task(fixture.taskID)?.draft == "项目任务未发送的草稿。" && tasks.task(fixture.standaloneID)?.draft == "无工作区任务未发送的草稿。"
            checks["manualDocumentsDoNotInventModelGeneration"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.kind != "wiki" && $0.kind != AgentKnowledgeCards.kind && !$0.messages.contains { $0.role == "assistant" } && ($0.modelReceipts ?? []).isEmpty }
            report["geometry"] = geometry; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        report["checks"] = checks; report["blockedModelAttempts"] = attempts; report["modelTransmissions"] = 0; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("knowledge-page-report.json"))
    }
}
