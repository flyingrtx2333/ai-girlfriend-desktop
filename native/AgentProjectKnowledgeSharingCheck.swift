import AppKit

@MainActor extension AppDelegate {
    func runAgentProjectKnowledgeSharingCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Actual files, Git branches, version pointers, import/export, rollback and native windows. Inputs are repository documents and manual source excerpts, not model-generated knowledge."]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("知识传递检查不得调用模型") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            var blocked = 0; runtime.modelRequestCheck = { blocked += 1; throw PetError("知识传递验收禁止发送模型请求") }
            let fm = FileManager.default, workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path)
            let owner = tasks.create(title: "项目知识传递", workspace: workspace.path, mode: .agent), other = tasks.create(title: "保留的另一个任务", workspace: workspace.path, mode: .ask)
            tasks.update(owner) { $0.draft = "保留的项目知识草稿" }; tasks.update(other) { $0.draft = "另一个原草稿" }
            let task = tasks.task(owner)!, cards = tasks.knowledgeCards, index = try AgentProjectIndex(workspace: workspace.path, storage: tasks.directory), indexed = try await index.run(paths: nil)
            let source = try files.readData(files.resolve("source/README.md")), excerpt = String(decoding: source, as: UTF8.self).components(separatedBy: "\n").prefix(4).joined(separator: "\n")
            let originalBook = AgentKnowledgeCardBook(workspace: workspace.path, branch: try cards.scope(task).branch, language: "zh", sourceRevision: indexed.index.revision, cards: [.init(title: "README 原文", kind: .architecture, body: excerpt, sources: [.init(path: "source/README.md", line: 1, endLine: 4, sha256: AgentFiles.hash(source))], manual: true)])
            try cards.publish(originalBook, task: task, expected: AgentFiles.hash(Data()))
            let shared = try AgentWiki.sharingPath("zh"), cardShared = try cards.sharingPath(language: "zh"), meta = shared + "/" + AgentWiki.transferMetadata, cardMeta = cardShared + "/knowledge.json", cardFile = cardShared + "/" + originalBook.cards[0].id + ".md"
            let legacyIndex = try files.readData(files.resolve(".bluefatfish/wiki/index.md")), count = try await AgentProjectKnowledgeSharing.export(store: tasks, taskID: owner, language: "zh")
            let wikiBytes = try files.readData(files.resolve(meta)), cardBytes = try files.readData(files.resolve(cardMeta)), wikiMetadata = try JSONDecoder().decode(AgentWikiTransfer.self, from: wikiBytes)
            checks["combinedExportUsesExistingV1FormatsAndActualResources"] = try count.pages == wikiMetadata.documents.count && count.cards == 1 && wikiMetadata.format == "bluefatfish.repo-wiki" && (wikiMetadata.resources?.count ?? 0) > 0 && JSONDecoder().decode(AgentKnowledgeCardTransfer.self, from: cardBytes).version == 1
            let unicodeGuide = try files.readData(files.resolve(shared + "/content/project/docs/AGENT-READING.md"))
            checks["actualUTF16BOMCRLFAndResourceBytesPreserved"] = try unicodeGuide.prefix(2) == Data([255, 254]) && AgentTextFile.decode(unicodeGuide).text.contains("\r\n") && (wikiMetadata.resources ?? []).allSatisfy { (try? files.fileHash(files.resolve(shared + "/content/" + $0.file))) == $0.sha256 }
            _ = try await AgentProjectKnowledgeSharing.export(store: tasks, taskID: owner, language: "zh")
            checks["unchangedCombinedExportIsIdempotent"] = try files.readData(files.resolve(meta)) == wikiBytes && files.readData(files.resolve(cardMeta)) == cardBytes
            let exportedCard = try files.readData(files.resolve(cardFile)), changedCard = exportedCard + Data("\n外部卡片编辑\n".utf8)
            try files.writeData(changedCard, to: files.resolve(cardFile))
            do { _ = try await AgentProjectKnowledgeSharing.export(store: tasks, taskID: owner, language: "zh"); checks["cardConflictPreventsAnyWikiExportWrite"] = false } catch { checks["cardConflictPreventsAnyWikiExportWrite"] = try files.readData(files.resolve(meta)) == wikiBytes && files.readData(files.resolve(cardFile)) == changedCard }
            func preview() async throws -> AgentProjectKnowledgeImport { try await AgentProjectKnowledgeSharing.previewImport(store: tasks, taskID: owner, language: "zh") }
            func reject(_ value: AgentProjectKnowledgeImport, _ name: String) async throws {
                let priorCard = try cards.book(task, language: "zh").1, priorWiki = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID
                do { try await AgentProjectKnowledgeSharing.apply(value, store: tasks, taskID: owner); checks[name] = false } catch { checks[name] = try cards.book(task, language: "zh").1 == priorCard && AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID == priorWiki }
            }
            let currentCardPreview = try await preview(), prior = try cards.book(task, language: "zh")
            var changed = originalBook; changed.id = UUID().uuidString; changed.cards[0].body += "\n当前卡片的人工修改"; try cards.publish(changed, task: task, expected: prior.1)
            try await reject(currentCardPreview, "currentCardEditInvalidatesWholeImport")
            let currentWikiPreview = try await preview(); try files.writeData(legacyIndex + Data("\n当前 Wiki 的人工修改\n".utf8), to: files.resolve(".bluefatfish/wiki/index.md"))
            try await reject(currentWikiPreview, "currentWikiEditInvalidatesWholeImport"); try files.writeData(legacyIndex, to: files.resolve(".bluefatfish/wiki/index.md"))
            for (path, name) in [(cardFile, "incomingCardEditInvalidatesWholeImport"), (shared + "/content/index.md", "incomingWikiEditInvalidatesWholeImport")] {
                let pending = try await preview(), old = try files.readData(files.resolve(path)); try files.writeData(old + Data("\n预览后的外部修改\n".utf8), to: files.resolve(path))
                try await reject(pending, name); try files.writeData(old, to: files.resolve(path))
            }
            let branchPreview = try await preview(), git = try AgentWiki.updateGit(store: tasks, taskID: owner)
            _ = try await git.run(["checkout", "--quiet", "sharing-other"], write: true); try await reject(branchPreview, "realBranchChangeRejectsWholeImport")
            checks["historyIsFilteredByActualBranch"] = try AgentProjectKnowledgeSharing.history(store: tasks, taskID: owner, language: "zh").isEmpty
            _ = try await git.run(["checkout", "--quiet", "knowledge-sharing"], write: true)
            let identityPreview = try await preview(), heldWorkspace = output.appendingPathComponent("held-workspace"), copiedWorkspace = output.appendingPathComponent("copied-workspace")
            try fm.moveItem(at: workspace, to: heldWorkspace); try fm.copyItem(at: heldWorkspace, to: workspace)
            try await reject(identityPreview, "samePathDirectoryReplacementRejectsWholeImport")
            try fm.moveItem(at: workspace, to: copiedWorkspace); try fm.moveItem(at: heldWorkspace, to: workspace)
            let cardDirectory = try files.resolve(cardShared), heldCards = output.appendingPathComponent("held-cards")
            try fm.moveItem(at: cardDirectory, to: heldCards); try fm.createSymbolicLink(at: cardDirectory, withDestinationURL: heldCards)
            do { _ = try await preview(); checks["sharedParentSymlinkRejected"] = false } catch { checks["sharedParentSymlinkRejected"] = true }
            try fm.removeItem(at: cardDirectory); try fm.moveItem(at: heldCards, to: cardDirectory)
            let metadataURL = try files.resolve(cardMeta), heldMetadata = workspace.appendingPathComponent("held-card-metadata.json")
            try fm.moveItem(at: metadataURL, to: heldMetadata); try fm.createSymbolicLink(at: metadataURL, withDestinationURL: heldMetadata)
            do { _ = try cards.previewImport(task, language: "zh"); checks["singleCardReaderRejectsMetadataSymlink"] = false } catch { checks["singleCardReaderRejectsMetadataSymlink"] = true }
            try fm.removeItem(at: metadataURL); try fm.moveItem(at: heldMetadata, to: metadataURL)
            var wrongBranch = wikiMetadata; wrongBranch.branch = "refs/heads/sharing-other"; try files.writeData(JSONEncoder().encode(wrongBranch), to: files.resolve(meta))
            do { _ = try await preview(); checks["combinedImportRejectsWrongSourceBranch"] = false } catch { checks["combinedImportRejectsWrongSourceBranch"] = true }; try files.writeData(wikiBytes, to: files.resolve(meta))
            let imported = try await preview(); try await AgentProjectKnowledgeSharing.apply(imported, store: tasks, taskID: owner)
            let published = try AgentWiki.view(store: tasks, taskID: owner, language: "zh"), publishedCards = try cards.book(task, language: "zh")
            checks["oneImportPublishesBothAndRetainsManualOrigin"] = published.manifest?.origin == "import" && published.pages.count == count.pages && publishedCards.0?.cards[0].body.contains("外部卡片编辑") == true && publishedCards.0?.cards[0].manual == true && publishedCards.0?.taskID == nil
            let firstHistory = try AgentProjectKnowledgeSharing.history(store: tasks, taskID: owner, language: "zh").first!
            checks["pairedHistoryContainsActualPreviousWikiAndCardEdits"] = firstHistory.wiki?.originalRoot == ".bluefatfish/wiki" && firstHistory.cards?.cards[0].body.contains("当前卡片的人工修改") == true
            let rollback = output.appendingPathComponent("rollback"), locked = rollback.appendingPathComponent("locked"); try fm.createDirectory(at: locked, withIntermediateDirectories: true)
            let rollbackFiles = try AgentFiles(workspace: rollback.path), oldWiki = try JSONEncoder().encode(published.manifest!), oldCards = try JSONEncoder().encode(publishedCards.0!)
            try rollbackFiles.writeData(oldWiki, to: rollbackFiles.resolve("wiki.json")); try rollbackFiles.writeData(oldCards, to: rollbackFiles.resolve("cards.json"))
            let writes = [try AgentKnowledgeFileWrite(files: rollbackFiles, path: "wiki.json", data: wikiBytes), try AgentKnowledgeFileWrite(files: rollbackFiles, path: "cards.json", data: cardBytes), try AgentKnowledgeFileWrite(files: rollbackFiles, path: "locked/final.json", data: wikiBytes)]
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            do { try AgentKnowledgeFileBatch.commit(writes, backup: rollback.appendingPathComponent("backup")) {}; checks["actualMidWritePermissionFailureRestoresBothFiles"] = false } catch { checks["actualMidWritePermissionFailureRestoresBothFiles"] = try rollbackFiles.readData(rollbackFiles.resolve("wiki.json")) == oldWiki && rollbackFiles.readData(rollbackFiles.resolve("cards.json")) == oldCards && String(decoding: rollbackFiles.readData(rollbackFiles.resolve("backup/outcome.json")), as: UTF8.self).contains("rolled-back") }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            let cancelled = Task { @MainActor in try AgentKnowledgeFileBatch.commit([try AgentKnowledgeFileWrite(files: rollbackFiles, path: "wiki.json", data: wikiBytes)], backup: rollback.appendingPathComponent("cancelled")) {} }; cancelled.cancel()
            do { try await cancelled.value; checks["cancelledTransferLeavesActualBytesUntouched"] = false } catch { checks["cancelledTransferLeavesActualBytesUntouched"] = try rollbackFiles.readData(rollbackFiles.resolve("wiki.json")) == oldWiki }
            let restore = try await AgentProjectKnowledgeSharing.previewRestore(firstHistory, store: tasks, taskID: owner, language: "zh"); try await AgentProjectKnowledgeSharing.apply(restore, store: tasks, taskID: owner)
            checks["pairedRestoreRecoversBothPreviousContents"] = try AgentWiki.view(store: tasks, taskID: owner, language: "zh").manifest?.origin == "restore" && cards.book(task, language: "zh").0?.cards[0].body == changed.cards[0].body
            try fm.moveItem(at: cardDirectory, to: heldCards)
            let withoutCards = try await preview(), beforeMissing = try cards.book(task, language: "zh").1
            try fm.moveItem(at: heldCards, to: cardDirectory); try await reject(withoutCards, "newlyAppearingComponentInvalidatesPreview"); try fm.moveItem(at: cardDirectory, to: heldCards)
            try await AgentProjectKnowledgeSharing.apply(try await preview(), store: tasks, taskID: owner)
            checks["wikiOnlyIncomingPreservesCurrentCards"] = try cards.book(task, language: "zh").1 == beforeMissing; try fm.moveItem(at: heldCards, to: cardDirectory)
            let wikiDirectory = try files.resolve(shared), heldWiki = output.appendingPathComponent("held-wiki"); try fm.moveItem(at: wikiDirectory, to: heldWiki)
            let beforeWikiOnly = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")!.taskID
            try await AgentProjectKnowledgeSharing.apply(try await preview(), store: tasks, taskID: owner)
            checks["cardsOnlyIncomingPreservesCurrentWiki"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID == beforeWikiOnly; try fm.moveItem(at: heldWiki, to: wikiDirectory)
            let zhPointer = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")!.taskID, zhCards = try cards.book(task, language: "zh").1, enShared = try AgentWiki.sharingPath("en"), enCards = try cards.sharingPath(language: "en")
            try fm.copyItem(at: wikiDirectory, to: files.resolve(enShared)); try fm.copyItem(at: cardDirectory, to: files.resolve(enCards))
            var enWiki = try JSONDecoder().decode(AgentWikiTransfer.self, from: files.readData(files.resolve(enShared + "/" + AgentWiki.transferMetadata))); enWiki.language = "en"; try files.writeData(JSONEncoder().encode(enWiki), to: files.resolve(enShared + "/" + AgentWiki.transferMetadata))
            var enBook = try JSONDecoder().decode(AgentKnowledgeCardTransfer.self, from: files.readData(files.resolve(enCards + "/knowledge.json"))); enBook.language = "en"; try files.writeData(JSONEncoder().encode(enBook), to: files.resolve(enCards + "/knowledge.json"))
            try await AgentProjectKnowledgeSharing.apply(try await AgentProjectKnowledgeSharing.previewImport(store: tasks, taskID: owner, language: "en"), store: tasks, taskID: owner)
            let enHistory = try AgentProjectKnowledgeSharing.history(store: tasks, taskID: owner, language: "en").first!
            checks["englishImportIsSeparateAndRecordsPreviouslyAbsentParts"] = try enHistory.wiki == nil && enHistory.cards == nil && cards.book(task, language: "en").0 != nil && AgentWiki.view(store: tasks, taskID: owner, language: "en").manifest != nil
            try await AgentProjectKnowledgeSharing.apply(try await AgentProjectKnowledgeSharing.previewRestore(enHistory, store: tasks, taskID: owner, language: "en"), store: tasks, taskID: owner)
            checks["pairedRestoreRecoversAbsentEnglishPointersAndRetainsVersions"] = try cards.book(task, language: "en").0 == nil && AgentWiki.view(store: tasks, taskID: owner, language: "en").pages.isEmpty && !cards.history(task, language: "en").isEmpty && !AgentProjectKnowledgeSharing.history(store: tasks, taskID: owner, language: "en").isEmpty
            checks["englishTransfersLeaveChineseKnowledgeUnchanged"] = try cards.book(task, language: "zh").1 == zhCards && AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID == zhPointer
            var options = try AgentWiki.maintenance(store: tasks, workspace: workspace.path, language: "zh"); options.options.autoExport = true
            try AgentWiki.setMaintenance(store: tasks, sourceID: owner, language: "zh", options: options.options, expected: options.signature)
            await tasks.wikiMaintenance.published(taskID: owner, language: "zh", expectedID: zhPointer)
            checks["automaticExportIncludesActualWikiAndCards"] = try tasks.wikiMaintenance.notice(workspace: workspace.path, language: "zh").contains("张卡片") && cards.previewImport(task, language: "zh").book.cards.count == 1
            options = try AgentWiki.maintenance(store: tasks, workspace: workspace.path, language: "zh"); options.options.autoExport = false; try AgentWiki.setMaintenance(store: tasks, sourceID: owner, language: "zh", options: options.options, expected: options.signature); tasks.wikiMaintenance.stop()
            let singleWiki = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh")
            checks["singleComponentReadersRemainCompatible"] = try cards.previewImport(task, language: "zh").book.cards.count == 1 && singleWiki.metadata.documents.count == count.pages
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("项目知识传递前置检查未通过") }
            let current = try AgentWiki.view(store: tasks, taskID: owner, language: "zh")
            guard let records = control.prepareMarkdownCheck(taskID: owner, section: 6, value: current.root + "/index.md") else { throw PetError("项目知识窗口未打开") }
            records.enableWikiGeneration { language in try? write(["language": language], "unexpected-generation.json") }; control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": binaryHash, "taskID": owner, "workspace": workspace.path, "checks": checks, "modelsCalled": false, "shared": shared, "cardFile": cardFile], "knowledge-sharing-ui-ready.json")
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-knowledge-sharing-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-knowledge-sharing-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var state = await records.markdownEditingReadback(); let language = (state["tree"] as? [String: Any])?["language"] as? String ?? "zh", book = try cards.book(task, language: language)
                    state["appPID"] = getpid(); state["cardHash"] = book.1; state["cardBodies"] = book.0?.cards.map(\.body) ?? []; state["wikiID"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: language)?.taskID ?? ""; state["pairedHistory"] = try AgentProjectKnowledgeSharing.history(store: tasks, taskID: owner, language: language).count; try write(state, "native-knowledge-sharing-" + name + ".json")
                }; await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("knowledge-sharing-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ui = observed["checks"] as? [String: Bool] { report["uiValidated"] = observed["appPID"] as? Int == Int(getpid()) && observed["binaryHash"] as? String == binaryHash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = observed }
            checks["bothOriginalComposerDraftsUnchanged"] = tasks.task(owner)?.draft == "保留的项目知识草稿" && tasks.task(other)?.draft == "另一个原草稿"
            checks["noModelMessagesReceiptsOrUnexpectedGeneration"] = blocked == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty } && !fm.fileExists(atPath: output.appendingPathComponent("unexpected-generation.json").path)
            report["appPID"] = getpid(); report["binaryHash"] = binaryHash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "knowledge-sharing-report.json")
    }
}
