import AppKit

@MainActor extension AppDelegate {
    func runAgentWikiTreeCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false]
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("Wiki 文档树验收只读取实际本地文档，不调用模型") }
            let fm = FileManager.default, plan = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("wiki-tree-plan.json"))) as! [String: Any]
            let workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path), expected = plan["initialPages"] as! [String]
            let guide = plan["target"] as! String, imported = plan["imported"] as! [String: [String: String]], sample = try files.readData(files.resolve(".bluefatfish/wiki/项目/README.md"))
            try files.writeData(sample, to: files.resolve(".bluefatfish/wiki/.hidden.md")); try files.writeData(sample, to: files.resolve(".bluefatfish/wiki/.env.check/README.md"))
            try fm.createSymbolicLink(at: workspace.appendingPathComponent(".bluefatfish/wiki/inside-link.md"), withDestinationURL: files.resolve(guide))
            try fm.createSymbolicLink(at: workspace.appendingPathComponent(".bluefatfish/wiki/outside-link"), withDestinationURL: output.appendingPathComponent("source-snapshot"))
            let pages = try AgentWiki.pages(workspace: workspace.path), catalog = try AgentWiki.catalog(workspace: workspace.path)
            checks["recursiveCatalogIncludesEveryActualImportedDocumentBeyond40Pages"] = Set(pages) == Set(expected) && pages.count > 40 && catalog.count == pages.count
            checks["rootIndexRemainsFirstAndHiddenSensitiveSymlinkEntriesExcluded"] = pages.first == ".bluefatfish/wiki/index.md" && !pages.contains { $0.contains("link") || $0.contains(".env") || $0.contains(".hidden") }
            checks["UTF16BOMDocumentTitleUsesActualMarkdownHeading"] = catalog.first { $0.path == guide }?.title == "图表与选文" && catalog.first { $0.path.contains("编码 说明😀") }?.title == "图表与选文"
            checks["UppercaseMarkdownExtensionAndMarkdownNamedDirectoryWork"] = catalog.first { $0.path == ".bluefatfish/wiki/目录.md/开发说明.MARKDOWN" }?.title == "开发与版本管理"
            checks["actualReadmeHeadingBadgesBecomePlainTitles"] = catalog.first { $0.path == ".bluefatfish/wiki/依赖/clsx/README.md" }?.title.hasPrefix("clsx") == true && catalog.allSatisfy { !$0.title.contains("![") && !$0.title.contains("](https://") }
            let otherWorkspace = output.appendingPathComponent("link-root-workspace"); try fm.createDirectory(at: otherWorkspace.appendingPathComponent(".bluefatfish"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: otherWorkspace.appendingPathComponent(".bluefatfish/wiki"), withDestinationURL: workspace.appendingPathComponent(".bluefatfish/wiki"))
            do { _ = try AgentWiki.pages(workspace: otherWorkspace.path); checks["symbolicWikiRootRejected"] = false } catch { checks["symbolicWikiRootRejected"] = true }
            ensureAgent(); guard let tasks = agentStore else { throw PetError("Wiki 文档树任务未初始化") }; _ = control
            let id = tasks.create(title: "Wiki 文档树", workspace: workspace.path, mode: .agent); tasks.update(id) { $0.draft = "保留的A草稿" }
            let other = tasks.create(title: "另一个任务的原草稿", workspace: workspace.path, mode: .ask); tasks.update(other) { $0.draft = "保留的B草稿" }
            let tools = AgentTools(store: tasks, taskID: id)
            func call(_ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: "project_wiki", arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
            let first = try await tools.execute(call([:])), firstObject = try JSONSerialization.jsonObject(with: Data(first.text.utf8)) as! [String: Any]
            let next = firstObject["next_offset"] as! Int, second = try await tools.execute(call(["offset": next])), secondObject = try JSONSerialization.jsonObject(with: Data(second.text.utf8)) as! [String: Any]
            let paths = (firstObject["pages"] as! [String]) + (secondObject["pages"] as! [String])
            checks["projectWikiPaginationReturnsEveryPageOnce"] = paths.count == pages.count && Set(paths) == Set(pages) && (firstObject["pages"] as? [String])?.count == 50 && secondObject["next_offset"] is NSNull
            checks["projectWikiListsActualTitlesPathsAndParents"] = (firstObject["documents"] as? [[String: String]])?.contains { $0["path"] == ".bluefatfish/wiki/index.md" && $0["title"] == "项目文档" && $0["parent"] == ".bluefatfish/wiki" } == true
            let extreme = try await tools.execute(call(["offset": Int.max, "limit": Int.max])), extremeObject = try JSONSerialization.jsonObject(with: Data(extreme.text.utf8)) as! [String: Any]
            checks["paginationExtremeOffsetHasNoOverflowOrDuplicatePages"] = (extremeObject["pages"] as? [String])?.isEmpty == true && extremeObject["next_offset"] is NSNull
            let read = try await tools.execute(call(["path": guide, "offset": 1, "limit": 5]))
            checks["projectWikiReadsRealNestedUnicodeEncodedPage"] = read.text.contains("图表与选文") && read.sources.count == 1
            do { _ = try await tools.execute(call(["path": "source-snapshot/README.md"])); checks["projectWikiCannotReadAnUnlistedPage"] = false } catch { checks["projectWikiCannotReadAnUnlistedPage"] = true }
            guard let records = control.prepareMarkdownCheck(taskID: id, section: 6, value: ".bluefatfish/wiki/index.md") else { throw PetError("Wiki 实际记录窗口未打开") }
            let initial = await records.markdownEditingReadback(), tree = initial["tree"] as? [String: Any] ?? [:], visible = tree["visible"] as? [[String: Any]] ?? []
            checks["actualOutlineStartsAtIndexWithCollapsedFoldersAndAllPages"] = (tree["pages"] as? [[String: String]])?.count == expected.count && tree["selected"] as? String == ".bluefatfish/wiki/index.md" && visible.first?["path"] as? String == ".bluefatfish/wiki/index.md" && visible.allSatisfy { $0["level"] as? Int == 0 }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 文档树前置检查未通过") }
            control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            let ready: [String: Any] = ["appPID": ProcessInfo.processInfo.processIdentifier, "binaryHash": binaryHash, "taskID": id, "otherTaskID": other, "workspace": workspace.path, "checks": checks, "modelsCalled": false]
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-tree-ui-ready.json"))
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-wiki-tree-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-wiki-tree-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var state = await records.markdownEditingReadback(); state["appPID"] = ProcessInfo.processInfo.processIdentifier
                    try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-wiki-tree-" + name + ".json"))
                }
                await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("wiki-tree-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ui = observed["checks"] as? [String: Bool] {
                report["uiValidated"] = observed["appPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && observed["binaryHash"] as? String == binaryHash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = observed
            }
            let final = await records.markdownEditingReadback(); try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-wiki-tree-final.json"))
            checks["actualNestedWikiSaveMatchesIndependentUTF16Bytes"] = try files.readData(files.resolve(guide)) == Data(contentsOf: output.appendingPathComponent("wiki-tree-expected-saved.bin"))
            var unchanged = true
            for (path, value) in imported where path != guide && path != plan["removed"] as? String { unchanged = try unchanged && files.fileHash(files.resolve(path)) == value["sha256"] }
            checks["otherImportedDocumentBytesUnchanged"] = unchanged
            checks["bothComposerDraftsUnchanged"] = tasks.task(id)?.draft == "保留的A草稿" && tasks.task(other)?.draft == "保留的B草稿"
            let full = tasks.tasks.compactMap { tasks.task($0.id) }; checks["noModelRequestsMessagesOrQueuedInputs"] = full.count == tasks.tasks.count && full.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.messages.isEmpty && $0.queuedCount == 0 }
            report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["binaryHash"] = binaryHash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-tree-report.json"))
    }
}
