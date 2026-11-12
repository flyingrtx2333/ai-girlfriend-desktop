import AppKit

@MainActor extension AppDelegate {
    func prepareKnowledgeReviewUI(_ output: URL) async throws {
        let f = try await prepareKnowledgePageUI(output)
        guard let tasks = agentStore, let task = tasks.task(f.taskID) else { throw PetError("项目任务未初始化") }
        tasks.update(task.id) { $0.permission = .automatic }
        let files = try AgentFiles(workspace: f.workspace.path), original = try String(contentsOf: f.workspace.appendingPathComponent("README.md"), encoding: .utf8)
        let wikiA = "# 公开资料 · 版本一\n\n" + original + "\n<!-- version-a-end -->\n"
        let wikiB = "# 公开资料 · 版本二\n\n" + original + "\n<!-- version-b-end -->\n"
        let wikiC = "# 公开资料 · 待导入版本\n\n" + original + "\n<!-- imported-complete-document-end -->\n"
        let current = try await AgentWiki.view(store: tasks, taskID: task.id, language: "zh")
        guard let page = current.pages.first(where: { $0.path.hasSuffix("/index.md") }) else { throw PetError("真实项目 Wiki 缺少首页") }
        try files.writeData(Data(wikiA.utf8), to: files.resolve(page.path))
        guard let book = try tasks.knowledgeCards.book(task, language: "zh").0, let card = book.cards.first else { throw PetError("真实知识卡片不存在") }
        let cardA = card.body + "\n公开卡片版本一。", cardB = card.body + "\n公开卡片版本二。", cardC = card.body + "\n待导入的外部卡片。"
        _ = try tasks.knowledgeCards.replaceCard(task: task, id: card.id, body: cardA, title: card.title, expectedCard: card.hash, citations: nil, expectedBook: tasks.knowledgeCards.book(task, language: "zh").1)
        _ = try await AgentProjectKnowledgeSharing.export(store: tasks, taskID: task.id, language: "zh")
        try await AgentProjectKnowledgeSharing.apply(AgentProjectKnowledgeSharing.previewImport(store: tasks, taskID: task.id, language: "zh"), store: tasks, taskID: task.id)
        let versionA = try await AgentWiki.view(store: tasks, taskID: task.id, language: "zh")
        guard let nextPage = versionA.pages.first(where: { $0.path.hasSuffix("/index.md") }), let nextCard = try tasks.knowledgeCards.book(task, language: "zh").0?.cards.first else { throw PetError("导入版本未读取") }
        try files.writeData(Data(wikiB.utf8), to: files.resolve(nextPage.path))
        _ = try tasks.knowledgeCards.replaceCard(task: task, id: nextCard.id, body: cardB, title: nextCard.title, expectedCard: nextCard.hash, citations: nil, expectedBook: tasks.knowledgeCards.book(task, language: "zh").1)
        _ = try await AgentProjectKnowledgeSharing.export(store: tasks, taskID: task.id, language: "zh")
        try await AgentProjectKnowledgeSharing.apply(AgentProjectKnowledgeSharing.previewImport(store: tasks, taskID: task.id, language: "zh"), store: tasks, taskID: task.id)
        let shared = try AgentWiki.sharingPath("zh"), metadata = try JSONDecoder().decode(AgentWikiTransfer.self, from: files.readData(files.resolve(shared + "/" + AgentWiki.transferMetadata), maximum: 4_000_000))
        guard let first = metadata.documents.first(where: { $0.file.hasSuffix("index.md") }) else { throw PetError("导出文档缺少首页") }
        try files.writeData(Data(wikiC.utf8), to: files.resolve(shared + "/content/" + first.file))
        let cardPath = try tasks.knowledgeCards.sharingPath(language: "zh"), cardMetadata = try JSONDecoder().decode(AgentKnowledgeCardTransfer.self, from: files.readData(files.resolve(cardPath + "/knowledge.json"), maximum: 300_000))
        guard let exportedCard = cardMetadata.cards.first else { throw PetError("共享卡片为空") }
        try files.writeData(Data(("# " + exportedCard.title + "\n\n" + cardC + "\n").utf8), to: files.resolve(cardPath + "/" + exportedCard.file))
        let expected = output.appendingPathComponent("expected"); try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        for (name, text) in [("wiki-a.md", wikiA), ("wiki-b.md", wikiB), ("wiki-c.md", wikiC), ("card-a.md", cardA), ("card-b.md", cardB), ("card-c.md", cardC)] { try Data(text.utf8).write(to: expected.appendingPathComponent(name)) }
        let value: [String: Any] = ["taskID": task.id, "standaloneID": f.standaloneID, "workspace": f.workspace.path, "sourceSHA256": AgentFiles.hash(Data(original.utf8)), "wikiASHA256": AgentFiles.hash(Data(wikiA.utf8)), "wikiCSHA256": AgentFiles.hash(Data(wikiC.utf8)), "wikiASourceDirectory": try files.resolve(page.path).deletingLastPathComponent().path, "wikiCSourceDirectory": try files.resolve(shared + "/content/" + first.file).deletingLastPathComponent().path, "cardFile": cardPath + "/" + exportedCard.file, "origin": "manual public README, actual exports, imports and edits", "modelRequests": 0]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("knowledge-review-fixtures.json"))
        control.showAgentTask(task.id)
    }
    func reopenKnowledgeReviewUI(_ output: URL) throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("knowledge-review-fixtures.json"))) as? [String: Any]
        guard let id = value?["taskID"] as? String, agentStore?.task(id) != nil else { throw PetError("原知识验收任务不存在") }; control.showAgentTask(id)
    }
    func runKnowledgeReviewCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("知识预览验收禁止模型请求") }
            try await prepareKnowledgeReviewUI(output)
            let f = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("knowledge-review-fixtures.json"))) as! [String: Any]
            let id = f["taskID"] as! String, workspace = f["workspace"] as! String, files = try AgentFiles(workspace: workspace), host = control.knowledgePageHost
            func expected(_ name: String) throws -> String { try String(contentsOf: output.appendingPathComponent("expected/" + name + ".md"), encoding: .utf8) }
            func wikiText() async throws -> String {
                let view = try await AgentWiki.view(store: tasks, taskID: id, language: "zh")
                guard let page = view.pages.first(where: { $0.path.hasSuffix("/index.md") }) else { throw PetError("当前 Wiki 首页缺失") }
                return try AgentTextFile.decode(files.readData(files.resolve(page.path), maximum: 512_000)).text
            }
            func wikiMatches(_ version: String) async throws -> Bool {
                let view = try await AgentWiki.view(store: tasks, taskID: id, language: "zh")
                guard let page = view.pages.first(where: { $0.path.hasSuffix("/index.md") }), let source = f[version == "a" ? "wikiASourceDirectory" : "wikiCSourceDirectory"] as? String else { return false }
                let file = try files.resolve(page.path), body = try AgentTextFile.decode(files.readData(file, maximum: 512_000)).text, original = try expected("wiki-" + version)
                let destination = file.deletingLastPathComponent(), sourceURL = URL(fileURLWithPath: source).standardizedFileURL
                let from = sourceURL.pathComponents, to = destination.pathComponents; var common = 0
                while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
                let relative = (Array(repeating: "..", count: to.count - common) + Array(from.dropFirst(common))).joined(separator: "/")
                guard destination.appendingPathComponent(relative).standardizedFileURL.path == sourceURL.path else { return false }
                func replace(_ pattern: String, in value: String, with replacement: String) throws -> String {
                    try NSRegularExpression(pattern: pattern, options: .caseInsensitive).stringByReplacingMatches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value), withTemplate: replacement)
                }
                // Independently resolve the filesystem relocation; do not use the publisher's link rewriter as its oracle.
                let prefix = relative.isEmpty ? "" : relative + "/"
                guard prefix.isEmpty || !original.contains(prefix) else { throw PetError("验收正文与迁移前缀重叠") }
                let relocated = prefix.isEmpty ? body : try replace(#"(\]\(|(?:src|href)\s*=\s*["'])"# + NSRegularExpression.escapedPattern(for: prefix), in: body, with: "$1")
                let directoryLinks = #"\]\(((?![a-zA-Z][a-zA-Z0-9+.-]*:|/)[^)\s]+?)/\)"#
                let matches = try replace(directoryLinks, in: relocated, with: "]($1)") == replace(directoryLinks, in: original, with: "]($1)")
                var values = report["wikiLinkAndContentChecks"] as? [[String: Any]] ?? []
                values.append(["version": version, "path": page.path, "sourceDirectory": source, "relativePrefix": prefix, "publishedHash": AgentFiles.hash(Data(body.utf8)), "allTextAndLinkTargetsMatch": matches]); report["wikiLinkAndContentChecks"] = values
                return matches
            }
            func inspect(_ name: String, review: AgentKnowledgeReviewWindow) {
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    control.window?.appearance = NSAppearance(named: appearance)
                    for (sizeName, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                        control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded()
                        let value = host.checkState(); report[name + "-" + theme + "-" + sizeName] = value
                        for (key, pass) in value["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + theme + "-" + sizeName + "-" + key] = pass }
                    }
                }
                checks[name + "-noStandaloneWindow"] = review.window?.isVisible == false && review.presentingWindow === control.window
            }
            control.showAgentKnowledge(); guard let catalog = host.currentController as? AgentRepoWikiWindow else { throw PetError("项目目录未打开") }
            for _ in 0..<200 { if catalog.checkState["loading"] as? Bool == false { break }; await wait(0.02) }
            try catalog.checkOpen(workspace: workspace, action: "wiki")
            guard let reader = host.currentController as? AgentRecordWindow else { throw PetError("Wiki 未进入知识中心") }
            await wait(0.15)
            let before = try await AgentWiki.snapshot(tasks, id, "zh")
            guard let canceled = await reader.checkKnowledgeReview("import") else { throw PetError("Wiki 导入页未打开") }; await canceled.checkLoad()
            checks["importPageUsesCompleteOriginalDocument"] = (canceled.checkState["items"] as? [[String: Any]])?.contains { $0["textHash"] as? String == f["wikiCSHA256"] as? String } == true
            inspect("preview", review: canceled); canceled.close()
            let canceledReader = await reader.markdownEditingReadback()
            checks["cancelPreviewKeepsPublishedVersion"] = try await AgentWiki.snapshot(tasks, id, "zh").pointer == before.pointer && host.currentController === reader && (canceledReader["state"] as? String)?.hasPrefix("正在") == false
            guard let importing = await reader.checkKnowledgeReview("import") else { throw PetError("Wiki 导入页未重开") }; await importing.checkLoad()
            let current = try await AgentWiki.view(store: tasks, taskID: id, language: "zh"), currentPage = current.pages.first { $0.path.hasSuffix("/index.md") }!
            let outside = try await wikiText() + "\n外部修改必须保留。\n"; try files.writeData(Data(outside.utf8), to: files.resolve(currentPage.path))
            await importing.checkApply()
            let retainedOutside = try await wikiText()
            checks["stalePreviewRejectsOverwriteAndRequiresNewPreview"] = importing.checkState["closed"] as? Bool == false && importing.checkState["applyEnabled"] as? Bool == false && retainedOutside == outside
            await importing.checkReload(); await importing.checkApply()
            checks["actualWikiImportPublishesReviewedBytesAndReturns"] = try await wikiMatches("c") && host.currentController === reader
            let guarded = AgentKnowledgeReviewWindow(title: "导入 Wiki", action: "导入", scope: "实际项目", load: { _ in
                let value = try await AgentWiki.previewWikiImport(store: tasks, taskID: id, language: "zh")
                return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(value.branch, language: "zh"), impact: "替换当前语言，原版本保留。", items: try AgentKnowledgeReviewSnapshot.wikiItems(value)) {
                    try await AgentWiki.importWiki(value, store: tasks, taskID: id)
                    return "已导入"
                }
            }, onApplied: { _ in })
            reader.checkPresentKnowledgeReview(guarded)
            checks["actualPreviewLoadBlocksNavigationAndClose"] = guarded.hasPendingOperation && !host.prepareToLeave() && !reader.prepareWorkspaceNavigation()
            do { try control.requireTaskDeletionAllowed([id]); checks["previewReadProtectsTaskDeletion"] = false } catch { checks["previewReadProtectsTaskDeletion"] = true }
            guarded.close(); checks["closeDuringLoadKeepsActualReview"] = host.currentController === guarded
            await guarded.checkLoad(); guarded.checkBeginApply()
            checks["actualApplyBlocksNavigationAndClose"] = guarded.hasPendingOperation && !host.prepareToLeave() && !reader.prepareWorkspaceNavigation()
            do { try control.requireTaskDeletionAllowed([id]); checks["applyingProtectsTaskDeletion"] = false } catch { checks["applyingProtectsTaskDeletion"] = true }
            await guarded.checkApply()
            checks["guardedActualImportCompletesAndReturns"] = try await wikiMatches("c") && host.currentController === reader
            let wikiVersions = try AgentWiki.wikiHistory(store: tasks, taskID: id, language: "zh")
            guard let wikiIndex = wikiVersions.firstIndex(where: { $0.metadata.documents.contains { $0.sha256 == f["wikiASHA256"] as? String } }), let restoring = await reader.checkKnowledgeReview("restore") else { throw PetError("实际 Wiki 历史不存在") }
            inspect("versions", review: restoring)
            checks["historyStepHasNoWriteActionBeforePreview"] = restoring.checkState["phase"] as? String == "versions" && restoring.checkState["applyEnabled"] as? Bool == false
            await restoring.checkSelectVersion(0)
            let firstPreview = restoring.checkState, firstItemHash = (restoring.checkState["items"] as? [[String: Any]])?.first?["textHash"] as? String
            checks["firstVersionSelectionShowsCompleteFirstDocument"] = (firstPreview["text"] as? String).map { AgentFiles.hash(Data($0.utf8)) } == firstItemHash && firstItemHash != nil
            restoring.checkVersions()
            await restoring.checkSelectVersion(wikiIndex)
            checks["selectedVersionPreviewNamesActualHistory"] = restoring.checkState["versionID"] as? String == wikiVersions[wikiIndex].id
            await restoring.checkApply(); checks["actualWikiRestoreKeepsCompleteVersion"] = try await wikiMatches("a") && host.currentController === reader
            let beforeCombined = try await AgentWiki.snapshot(tasks, id, "zh"), beforeCombinedCards = try tasks.knowledgeCards.book(tasks.task(id)!, language: "zh").1
            guard let canceledCombined = await reader.checkKnowledgeReview("knowledge-import") else { throw PetError("项目知识取消预览未打开") }; await canceledCombined.checkLoad(); canceledCombined.close()
            let canceledProject = await reader.markdownEditingReadback()
            checks["combinedCancelKeepsPublicationAndClearsLoadingState"] = try await AgentWiki.snapshot(tasks, id, "zh").pointer == beforeCombined.pointer && tasks.knowledgeCards.book(tasks.task(id)!, language: "zh").1 == beforeCombinedCards && host.currentController === reader && (canceledProject["state"] as? String)?.hasPrefix("正在") == false
            guard let projectImport = await reader.checkKnowledgeReview("knowledge-import") else { throw PetError("项目知识导入页未打开") }; await projectImport.checkLoad()
            checks["combinedPreviewIncludesWikiAndCards"] = (projectImport.checkState["items"] as? [[String: Any]])?.count == 3
            await projectImport.checkApply(); guard let task = tasks.task(id) else { throw PetError("原任务丢失") }
            checks["combinedImportUsesActualWikiAndCardServices"] = try await wikiMatches("c") && tasks.knowledgeCards.book(task, language: "zh").0?.cards.first?.body == expected("card-c")
            let combined = try AgentProjectKnowledgeSharing.history(store: tasks, taskID: id, language: "zh")
            guard let index = combined.firstIndex(where: { $0.cards?.cards.first?.body == (try? expected("card-a")) && $0.wiki?.metadata.documents.contains { $0.sha256 == f["wikiASHA256"] as? String } == true }), let projectRestore = await reader.checkKnowledgeReview("knowledge-restore") else { throw PetError("整套知识历史不存在") }
            await projectRestore.checkSelectVersion(index); await projectRestore.checkApply()
            checks["combinedRestorePublishesBothReviewedVersions"] = try await wikiMatches("a") && tasks.knowledgeCards.book(task, language: "zh").0?.cards.first?.body == expected("card-a")
            host.checkBack(); guard let root = host.currentController as? AgentRepoWikiWindow else { throw PetError("项目目录未恢复") }
            for _ in 0..<200 { if root.checkState["loading"] as? Bool == false { break }; await wait(0.02) }; try root.checkOpen(workspace: workspace, action: "cards")
            guard let cards = host.currentController as? AgentKnowledgeCardWindow else { throw PetError("卡片页未打开") }
            cards.importCards(); await cards.job?.value; guard let cardImport = cards.reviewWindow else { throw PetError("卡片导入页未打开") }; await cardImport.checkLoad(); await cardImport.checkApply()
            checks["cardImportUsesActualReviewedBook"] = try tasks.knowledgeCards.book(task, language: "zh").0?.cards.first?.body == expected("card-c") && host.currentController === cards
            let cardVersions = try tasks.knowledgeCards.history(task, language: "zh").filter { $0.id != cards.value?.id }
            guard let cardIndex = cardVersions.firstIndex(where: { $0.cards.first?.body == (try? expected("card-a")) }) else { throw PetError("原卡片历史缺失") }
            cards.restoreVersion(); guard let cardRestore = cards.reviewWindow else { throw PetError("卡片恢复页未打开") }; await cardRestore.checkSelectVersion(cardIndex); await cardRestore.checkApply()
            checks["cardRestoreKeepsActualOriginalBody"] = try tasks.knowledgeCards.book(task, language: "zh").0?.cards.first?.body == expected("card-a") && host.currentController === cards
            let emptyRoot = output.appendingPathComponent("empty-project")
            try FileManager.default.createDirectory(at: emptyRoot.appendingPathComponent(".bluefatfish"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: files.root.appendingPathComponent("README.md"), to: emptyRoot.appendingPathComponent("README.md"))
            try FileManager.default.copyItem(at: files.root.appendingPathComponent(".bluefatfish/repowiki"), to: emptyRoot.appendingPathComponent(".bluefatfish/repowiki"))
            let emptyID = tasks.create(title: "未发布版本恢复", workspace: emptyRoot.path)
            tasks.update(emptyID) { $0.permission = .automatic }; try tasks.organization.register(emptyRoot.path, mode: .coding)
            _ = try await AgentProjectIndex(workspace: emptyRoot.path, storage: tasks.directory).run(paths: nil)
            let emptyImport = try await AgentProjectKnowledgeSharing.previewImport(store: tasks, taskID: emptyID, language: "zh")
            try await AgentProjectKnowledgeSharing.apply(emptyImport, store: tasks, taskID: emptyID)
            let emptyHistory = try AgentProjectKnowledgeSharing.history(store: tasks, taskID: emptyID, language: "zh")
            guard let emptyIndex = emptyHistory.firstIndex(where: { $0.wiki == nil && $0.cards == nil }) else { throw PetError("真实未发布历史缺失") }
            control.showAgentTask(emptyID); control.showAgentKnowledge()
            guard let emptyCatalog = host.currentController as? AgentRepoWikiWindow else { throw PetError("第二项目目录未打开") }
            for _ in 0..<200 { if emptyCatalog.checkState["loading"] as? Bool == false { break }; await wait(0.02) }
            try emptyCatalog.checkOpen(workspace: emptyRoot.path, action: "wiki")
            guard let emptyReader = host.currentController as? AgentRecordWindow, let emptyRestore = await emptyReader.checkKnowledgeReview("knowledge-restore") else { throw PetError("未发布恢复页未打开") }
            await emptyRestore.checkSelectVersion(emptyIndex)
            checks["emptyRestoreClearlyShowsBothUnpublishedTargets"] = (emptyRestore.checkState["impact"] as? String)?.contains("Wiki：恢复为未发布") == true && (emptyRestore.checkState["impact"] as? String)?.contains("卡片：恢复为未发布") == true && (emptyRestore.checkState["items"] as? [[String: Any]])?.isEmpty == true
            await emptyRestore.checkApply()
            let emptyView = try await AgentWiki.view(store: tasks, taskID: emptyID, language: "zh"), emptyTask = tasks.task(emptyID)!
            checks["actualEmptyRestoreClearsOnlyPublicationPointers"] = try emptyView.pages.isEmpty && tasks.knowledgeCards.book(emptyTask, language: "zh").0 == nil
            let retainedHistory = try AgentProjectKnowledgeSharing.history(store: tasks, taskID: emptyID, language: "zh")
            checks["emptyRestoreRetainsReversiblePublishedKnowledge"] = retainedHistory.contains { $0.wiki?.metadata.documents.isEmpty == false && $0.cards?.cards.isEmpty == false }
            let originalSourceHash = AgentFiles.hash(try Data(contentsOf: files.root.appendingPathComponent("README.md")))
            checks["allOriginalTaskDraftsAndPublicSourceRetained"] = tasks.task(id)?.draft == "项目任务未发送的草稿。" && tasks.task(f["standaloneID"] as! String)?.draft == "无工作区任务未发送的草稿。" && originalSourceHash == f["sourceSHA256"] as? String
            checks["noModelRequestsOrInventedGeneration"] = requests == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 && $0.kind != "wiki" && $0.kind != AgentKnowledgeCards.kind }
            report["fixture"] = f; host.finish()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("knowledge-review-report.json"))
    }
}
