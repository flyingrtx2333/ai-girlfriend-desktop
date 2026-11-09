import AppKit

@MainActor extension AppDelegate {
    func runAgentWikiSharingCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "fixtures": "Actual repository documentation and images, manually arranged for import/export checks; not model-generated output"]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("Wiki 文件流转验收不调用模型") }
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }; _ = control
            let workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path), fm = FileManager.default
            let origin = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("wiki-sharing-origin.json"))) as! [String: Any], legacyHashes = origin["legacyHashes"] as! [String: String]
            let owner = tasks.create(title: "Wiki 导入导出", workspace: workspace.path, mode: .agent); tasks.update(owner) { $0.draft = "保留的项目草稿" }
            let other = tasks.create(title: "另一个保留任务", workspace: workspace.path, mode: .ask); tasks.update(other) { $0.draft = "另一个任务的原草稿" }
            let index = try AgentProjectIndex(workspace: workspace.path, storage: tasks.directory); _ = try await index.run(paths: nil)
            let expectedCount = try AgentWiki.pages(workspace: workspace.path).count, shared = try AgentWiki.sharingPath("zh"), metadataFile = try files.resolve(shared + "/" + AgentWiki.transferMetadata), guide = "project/docs/AGENT-READING.md"
            let count = try await AgentWiki.exportWiki(store: tasks, taskID: owner, language: "zh"), metadataData = try files.readData(metadataFile), metadata = try JSONDecoder().decode(AgentWikiTransfer.self, from: metadataData)
            checks["actualLegacyDocumentsAndReferencedImagesExported"] = count == expectedCount && metadata.documents.count == expectedCount && (metadata.resources?.count ?? 0) >= 5 && metadata.origin == "legacy"
            checks["exportedMarkdownAndResourceHashesMatchActualFiles"] = try metadata.documents.allSatisfy { try files.fileHash(files.resolve(shared + "/content/" + $0.file)) == $0.sha256 } && (metadata.resources ?? []).allSatisfy { try files.fileHash(files.resolve(shared + "/content/" + $0.file)) == $0.sha256 }
            let exportedGuide = try files.readData(files.resolve(shared + "/content/" + guide)), decodedGuide = try AgentTextFile.decode(exportedGuide)
            checks["UTF16BOMAndCRLFRemainInActualGuide"] = exportedGuide.prefix(2) == Data([255, 254]) && decodedGuide.format.encoding == .utf16LE && decodedGuide.text.contains("\r\n") && !decodedGuide.text.replacingOccurrences(of: "\r\n", with: "").contains("\n")
            let firstExportHashes = try Dictionary(uniqueKeysWithValues: (metadata.documents.map(\.file) + (metadata.resources ?? []).map(\.file)).map { ($0, try files.fileHash(files.resolve(shared + "/content/" + $0))) })
            _ = try await AgentWiki.exportWiki(store: tasks, taskID: owner, language: "zh")
            checks["unchangedExportIsByteIdenticalAndLeavesOtherLanguageEmpty"] = try files.readData(metadataFile) == metadataData && firstExportHashes.allSatisfy { try files.fileHash(files.resolve(shared + "/content/" + $0.key)) == $0.value } && !fm.fileExists(atPath: workspace.appendingPathComponent(".bluefatfish/repowiki/en").path)
            let originalIndex = try files.readData(files.resolve(shared + "/content/index.md")), originalIndexText = try AgentTextFile.decode(originalIndex)
            let externalIndex = try originalIndexText.format.encode(originalIndexText.text + "\n<!-- 共享目录中的真实外部编辑 -->\n")
            try files.writeData(externalIndex, to: files.resolve(shared + "/content/index.md"))
            do { _ = try await AgentWiki.exportWiki(store: tasks, taskID: owner, language: "zh"); checks["externalSharedEditCannotBeOverwritten"] = false } catch { checks["externalSharedEditCannotBeOverwritten"] = try files.readData(files.resolve(shared + "/content/index.md")) == externalIndex && files.readData(metadataFile) == metadataData }
            let preview = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh")
            let extra = "extra/README.md", extraData = try Data(contentsOf: output.appendingPathComponent("source-snapshot/node_modules/yaml/README.md")); try files.writeData(extraData, to: files.resolve(shared + "/content/" + extra))
            do { try await AgentWiki.importWiki(preview, store: tasks, taskID: owner); checks["newPageAfterPreviewRejectsImportWithoutPublishing"] = false } catch { checks["newPageAfterPreviewRejectsImportWithoutPublishing"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh") == nil }
            let fresh = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh")
            checks["manualExternalPageAndEditIncludedInFreshPreview"] = fresh.metadata.documents.contains { $0.file == extra } && fresh.manuallyChanged >= 2
            try await AgentWiki.importWiki(fresh, store: tasks, taskID: owner)
            let imported = try AgentWiki.view(store: tasks, taskID: owner, language: "zh"), importedGuide = try files.readData(files.resolve(imported.root + "/" + guide))
            checks["importPublishesSeparateVersionWithoutInventingGenerationTask"] = imported.manifest?.version == 3 && imported.manifest?.origin == "import" && imported.pages.count == expectedCount + 1 && tasks.task(imported.manifest!.taskID) == nil
            checks["importedImagesAndUnicodeGuideRemainExact"] = importedGuide == exportedGuide && (metadata.resources ?? []).allSatisfy { (try? files.fileHash(files.resolve(imported.root + "/" + $0.file))) == $0.sha256 }
            checks["unverifiedManualImportIsNotLabeledGenerated"] = try AgentWiki.status(store: tasks, taskID: owner, language: "zh") == "待核对"
            let staleCurrent = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh"), currentIndexPath = imported.root + "/index.md", currentData = try files.readData(files.resolve(currentIndexPath)), currentText = try AgentTextFile.decode(currentData)
            let edited = try currentText.format.encode(currentText.text + "\n<!-- 当前 Wiki 的人工修改，恢复时须保留 -->\n"); try files.writeData(edited, to: files.resolve(currentIndexPath))
            do { try await AgentWiki.importWiki(staleCurrent, store: tasks, taskID: owner); checks["currentWikiEditAfterPreviewCannotBeLost"] = false } catch { checks["currentWikiEditAfterPreviewCannotBeLost"] = try files.readData(files.resolve(currentIndexPath)) == edited && AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID == imported.manifest?.taskID }
            let replacement = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh"); try await AgentWiki.importWiki(replacement, store: tasks, taskID: owner)
            let history = try AgentWiki.wikiHistory(store: tasks, taskID: owner, language: "zh")
            guard let prior = history.first(where: { $0.originalRoot == imported.root }) else { throw PetError("人工修改的 Wiki 未保留历史") }
            let restore = try await AgentWiki.previewWikiRestore(prior, store: tasks, taskID: owner, language: "zh")
            checks["historyContainsActualEditedBytesAndOriginalAssets"] = restore.data["index.md"] == edited && (metadata.resources ?? []).allSatisfy { restore.data[$0.file].map(AgentFiles.hash) == $0.sha256 }
            try await AgentWiki.importWiki(restore, store: tasks, taskID: owner, restoring: true)
            let restored = try AgentWiki.view(store: tasks, taskID: owner, language: "zh")
            let restoredText = try AgentTextFile.decode(files.readData(files.resolve(restored.root + "/index.md"))).text
            checks["restorePublishesFreshVersionAndRetainsManualText"] = restored.manifest?.origin == "restore" && restored.root != imported.root && restoredText.contains("当前 Wiki 的人工修改")
            var changedHistory = prior; changedHistory.metadata.documents[0].title += "不同"
            do { _ = try await AgentWiki.previewWikiRestore(changedHistory, store: tasks, taskID: owner, language: "zh"); checks["changedHistoryMetadataCannotBypassPreview"] = false } catch { checks["changedHistoryMetadataCannotBypassPreview"] = true }
            let protectedPointer = restored.manifest!.taskID
            for (name, mutate) in [("wrongLanguageMetadataRejected", { (v: inout AgentWikiTransfer) in v.language = "en" }), ("unsupportedMetadataRejected", { (v: inout AgentWikiTransfer) in v.format = "unsupported" }), ("pathTraversalMetadataRejected", { (v: inout AgentWikiTransfer) in v.documents[0].file = "../outside.md" }), ("caseAliasMetadataRejected", { (v: inout AgentWikiTransfer) in var duplicate = v.documents[0]; duplicate.file = duplicate.file.uppercased(); v.documents.append(duplicate) }), ("sensitiveResourceMetadataRejected", { (v: inout AgentWikiTransfer) in v.resources = [.init(file: ".env", sha256: String(repeating: "0", count: 64))] })] {
                var invalid = metadata; mutate(&invalid); try files.writeData(JSONEncoder().encode(invalid), to: metadataFile)
                do { _ = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh"); checks[name] = false } catch { checks[name] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID == protectedPointer }
            }
            try files.writeData(metadataData, to: metadataFile)
            let beforeBranch = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh")
            func checkout(_ name: String) throws { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", workspace.path, "checkout", "--quiet", name]; try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw PetError("实际 Git 分支切换失败") } }
            try checkout("wiki-two")
            do { try await AgentWiki.importWiki(beforeBranch, store: tasks, taskID: owner); checks["branchChangeRejectsStaleImportAndFiltersHistory"] = false } catch { checks["branchChangeRejectsStaleImportAndFiltersHistory"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh") == nil && AgentWiki.wikiHistory(store: tasks, taskID: owner, language: "zh").isEmpty }
            try checkout("wiki-one")
            checks["returningBranchRetainsSameWikiVersion"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID == protectedPointer
            let resource = metadata.resources!.first!, resourcePath = shared + "/content/" + resource.file, resourceOriginal = try files.readData(files.resolve(resourcePath)), resourcePreview = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh")
            try files.writeData(resourceOriginal + Data("external image bytes".utf8), to: files.resolve(resourcePath))
            do { try await AgentWiki.importWiki(resourcePreview, store: tasks, taskID: owner); checks["externalResourceEditInvalidatesImportPreview"] = false } catch { checks["externalResourceEditInvalidatesImportPreview"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID == protectedPointer }; try files.writeData(resourceOriginal, to: files.resolve(resourcePath))
            let content = try files.resolve(shared + "/content"), held = workspace.appendingPathComponent("held-content"), unrelated = workspace.appendingPathComponent("unrelated"); try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
            try fm.moveItem(at: content, to: held); try fm.createSymbolicLink(at: content, withDestinationURL: unrelated)
            do { _ = try await AgentWiki.exportWiki(store: tasks, taskID: owner, language: "zh"); checks["sharedDirectorySymlinkCannotRedirectWrites"] = false } catch { checks["sharedDirectorySymlinkCannotRedirectWrites"] = try fm.contentsOfDirectory(atPath: unrelated.path).isEmpty }
            try fm.removeItem(at: content); try fm.moveItem(at: held, to: content)
            tasks.update(owner) { $0.archived = true }
            do { _ = try await AgentWiki.exportWiki(store: tasks, taskID: owner, language: "zh"); checks["archivedTaskCannotExport"] = false } catch { checks["archivedTaskCannotExport"] = true }; tasks.update(owner) { $0.archived = false }
            let v2 = try JSONDecoder().decode(AgentWikiManifest.self, from: Data(contentsOf: output.appendingPathComponent("actual-v2-manifest.json"))), scope = try tasks.knowledgeCards.scope(tasks.task(owner)!), wikiDirectory = scope.directory.deletingLastPathComponent().appendingPathComponent("wiki")
            let v2Pointer = wikiDirectory.appendingPathComponent(AgentFiles.hash(Data((scope.branch + "\nen").utf8)) + ".json"); try Data(contentsOf: output.appendingPathComponent("actual-v2-manifest.json")).write(to: v2Pointer, options: .atomic)
            checks["previousActualV2ManualFixtureRemainsReadable"] = try AgentWiki.view(store: tasks, taskID: owner, language: "en").manifest?.taskID == v2.taskID && AgentWiki.view(store: tasks, taskID: owner, language: "en").pages.count == 2
            checks["allLegacyDocumentAndImageBytesRemainUntouched"] = try legacyHashes.allSatisfy { try files.fileHash(files.resolve($0.key)) == $0.value }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 导入导出前置检查未通过") }
            guard let records = control.prepareMarkdownCheck(taskID: owner, section: 6, value: restored.root + "/index.md") else { throw PetError("Wiki 实际窗口未打开") }
            records.enableWikiGeneration { language in try? write(["unexpected": true, "language": language, "modelsCalled": false], "unexpected-generation.json") }
            control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": binaryHash, "taskID": owner, "workspace": workspace.path, "checks": checks, "modelsCalled": false, "initialRoot": restored.root, "guide": guide, "shared": shared], "wiki-sharing-ui-ready.json")
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-wiki-sharing-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-wiki-sharing-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var state = await records.markdownEditingReadback(); state["appPID"] = getpid(); state["manifest"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh").map { ["taskID": $0.taskID, "root": $0.root ?? "", "pages": $0.pages, "assets": $0.assets ?? [:]] as [String: Any] } ?? [:]; try write(state, "native-wiki-sharing-" + name + ".json")
                }; await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("wiki-sharing-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ui = observed["checks"] as? [String: Bool] { report["uiValidated"] = observed["appPID"] as? Int == Int(getpid()) && observed["binaryHash"] as? String == binaryHash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = observed }
            checks["bothOriginalComposerDraftsUnchanged"] = tasks.task(owner)?.draft == "保留的项目草稿" && tasks.task(other)?.draft == "另一个任务的原草稿"
            checks["noModelMessagesReceiptsOrUnexpectedGeneration"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty } && !fm.fileExists(atPath: output.appendingPathComponent("unexpected-generation.json").path)
            report["appPID"] = getpid(); report["binaryHash"] = binaryHash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "wiki-sharing-report.json")
    }
}
