import AppKit

@MainActor extension AppDelegate {
    func runAgentMarkdownCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false]
        do {
            guard !CommandLine.arguments.contains("--live-agent"), let sourceIndex = CommandLine.arguments.firstIndex(of: "--markdown-source"), CommandLine.arguments.indices.contains(sourceIndex + 1) else { throw PetError("阅读器检查只使用实际本地文件，不调用模型") }
            let source = try AgentFiles(workspace: CommandLine.arguments[sourceIndex + 1]), fm = FileManager.default
            let workspace = output.appendingPathComponent("workspace"), files: AgentFiles
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true); files = try AgentFiles(workspace: workspace.path)
            var original: [String: String] = [:]
            let names = ["README.md", "docs/DEVELOPMENT.md", "docs/AGENT-READING.md", "native/AgentWiki.swift"]
            for name in names {
                let data = try source.readData(source.resolve(name)); original[name] = AgentFiles.hash(data)
                try files.writeData(data, to: files.resolve(name))
            }
            let media = try source.resolve("docs/media")
            for url in try fm.contentsOfDirectory(at: media, includingPropertiesForKeys: nil) where AgentDocument.imageTypes.contains(url.pathExtension.lowercased()) {
                let name = "docs/media/" + url.lastPathComponent; try files.writeData(source.readData(url, maximum: 20_000_000), to: files.resolve(name))
            }
            let index = """
            # 项目文档

            [项目说明](../../README.md#原生任务工作台)

            [开发与版本管理](../../docs/DEVELOPMENT.md#目录)

            [Wiki 实现](../../native/AgentWiki.swift#L7)

            [图表与选文](../../docs/AGENT-READING.md#图表与选文)

            ## 阅读检查

            | 文件 | 位置 |
            | --- | --- |
            | 项目说明 | `README.md` |
            | 开发与版本管理 | `docs/DEVELOPMENT.md` |

            这些链接指向本次复制的真实项目文件；此页是阅读器检查目录，不是模型生成结果。
            """
            try files.writeData(Data(index.utf8), to: files.resolve(".bluefatfish/wiki/index.md"))
            let readme = try String(contentsOf: workspace.appendingPathComponent("README.md"), encoding: .utf8)
            let doc = AgentMarkdownDocument.render(readme, document: workspace.appendingPathComponent("README.md"), files: files, width: 600)
            checks["actualReadmeHasNavigableHeadings"] = doc.headings.contains { $0.anchor == "原生任务工作台" } && doc.headings.first?.title == "蓝色大肥鱼 · 小鲸 🐳"
            var tables = 0, images = 0, largestImage: CGFloat = 0
            doc.body.enumerateAttributes(in: NSRange(location: 0, length: doc.body.length)) { attrs, _, _ in
                if ((attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock) != nil { tables += 1 }
                if let image = attrs[.attachment] as? NSTextAttachment { images += 1; largestImage = max(largestImage, image.bounds.width) }
            }
            checks["actualReadmeTablesUseNativeCells"] = tables >= 4
            checks["actualLocalImagesFitReadingWidth"] = images > 0 && largestImage <= 564
            if let markup = readme.components(separatedBy: "\n").first(where: { $0.hasPrefix("<img") }) {
                let repeated = AgentMarkdownDocument.render(markup + "\n" + markup, document: workspace.appendingPathComponent("README.md"), files: files, width: 400)
                var pictures: [NSImage] = []
                repeated.body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: repeated.body.length)) { value, _, _ in if let image = (value as? NSTextAttachment)?.image { pictures.append(image) } }
                checks["repeatedImageUsesSameDecodedResource"] = pictures.count == 2 && pictures[0] === pictures[1]
            } else { checks["repeatedImageUsesSameDecodedResource"] = false }
            let imageFiles = try fm.contentsOfDirectory(at: workspace.appendingPathComponent("docs/media"), includingPropertiesForKeys: nil).filter { AgentDocument.imageTypes.contains($0.pathExtension.lowercased()) }
            if let actual = imageFiles.first {
                var bounded: [String] = []
                for i in 0..<33 { let name = "image-bound-\(i)." + actual.pathExtension; try fm.linkItem(at: actual, to: workspace.appendingPathComponent(name)); bounded.append("![\(i)](\(name))") }
                let boundedDoc = AgentMarkdownDocument.render(bounded.joined(separator: "\n"), document: workspace.appendingPathComponent("README.md"), files: files, width: 400)
                checks["manyLocalImagesHaveBoundedPreview"] = boundedDoc.body.string.contains("本页图片预览已达到上限")
            } else { checks["manyLocalImagesHaveBoundedPreview"] = false }
            let wiki = try files.resolve(".bluefatfish/wiki/index.md")
            let link = try AgentMarkdownDocument.target(URL(string: "../../native/AgentWiki.swift#L7")!, document: wiki, files: files)
            let expectedSource = try files.resolve("native/AgentWiki.swift")
            checks["sourceCitationResolvesActualFileAndLine"] = link.path == expectedSource.path && link.fragment == "L7"
            let encoded = try files.resolve("含 空格.md"); try files.writeData(Data("# 标题\n".utf8), to: encoded)
            checks["encodedWorkspacePathsDecodeOnce"] = try AgentMarkdownDocument.target(URL(string: "../../%E5%90%AB%20%E7%A9%BA%E6%A0%BC.md")!, document: wiki, files: files).path == encoded.path
            let forbidden = ["../../../../outside.md", "../../.env", "javascript:alert(1)", "//example.com/a", "file://remotehost/secret"]
            checks["unsafeLinksAreNotOpened"] = forbidden.allSatisfy { (try? AgentMarkdownDocument.target(URL(string: $0)!, document: wiki, files: files)) == nil }
            let outside = output.appendingPathComponent("outside.txt"); try Data("outside".utf8).write(to: outside)
            try fm.createSymbolicLink(at: files.resolve("escape"), withDestinationURL: output)
            checks["symlinkEscapeIsRejected"] = (try? AgentMarkdownDocument.target(URL(string: "../../escape/outside.txt")!, document: wiki, files: files)) == nil
            let code = AgentMarkdownDocument.render("````text\n# literal\n```\nkept\n````\n# 标题\n# 标题", document: wiki, files: files, width: 400)
            checks["fencesAndDuplicateAnchorsPreserveContent"] = code.body.string.contains("# literal\n```\nkept") && code.headings.map(\.anchor) == ["标题", "标题-1"]
            checks["escapedAndCodePipesStayInCells"] = AgentMarkdownDocument.cells("| A\\|B | `C|D` |") == ["A|B", "`C|D`"]
            let reader = AgentMarkdownReader(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); reader.show(readme, file: workspace.appendingPathComponent("README.md"), workspace: workspace.path)
            checks["readerNavigatesRealHeading"] = reader.navigate("原生任务工作台") && !reader.navigate("missing-heading")
            let encodedLink = try AgentMarkdownDocument.target(URL(string: "../../README.md#%E5%8E%9F%E7%94%9F%E4%BB%BB%E5%8A%A1%E5%B7%A5%E4%BD%9C%E5%8F%B0")!, document: wiki, files: files)
            checks["encodedCrossFileAnchorNavigatesActualHeading"] = reader.navigate(AgentMarkdownDocument.fragment(encodedLink))
            let readingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            readingWindow.isReleasedWhenClosed = false; readingWindow.contentView = reader; readingWindow.makeKeyAndOrderFront(nil)
            _ = reader.navigate(AgentMarkdownDocument.fragment(encodedLink)); await wait(0.1)
            checks["firstOpenAnchorIsWithinActualVisibleViewport"] = reader.checkHeadingVisible("原生任务工作台") && (reader.text.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0
            let diagramFile = try files.resolve("docs/AGENT-READING.md"), diagramSource = try String(contentsOf: diagramFile, encoding: .utf8)
            reader.show(diagramSource, file: diagramFile, workspace: workspace.path)
            let ranges = reader.document?.headings.map(\.range)
            await reader.waitForDiagrams()
            checks["actualArchitectureFlowSequenceAndMindmapRender"] = reader.drawings.count == 3 && reader.diagramErrors.isEmpty && reader.drawings.values.contains { $0.labels.contains("AgentRecordWindow") } && reader.drawings.values.contains { $0.labels.contains("ControlWindow") } && reader.drawings.values.contains { $0.labels.contains("工作区校验") }
            checks["asyncDiagramsKeepHeadingRangesAndFitWidth"] = reader.document?.headings.map(\.range) == ranges && reader.document?.diagrams.allSatisfy { $0.attachment.bounds.width <= 564 && $0.attachment.image != nil } == true
            let diagramOutput = output.appendingPathComponent("actual-diagrams"); try fm.createDirectory(at: diagramOutput, withIntermediateDirectories: true)
            for (position, drawing) in reader.drawings { try drawing.pdf.write(to: diagramOutput.appendingPathComponent("\(position).pdf")); try Data(drawing.svg.utf8).write(to: diagramOutput.appendingPathComponent("\(position).svg")) }
            let engine = AgentMarkdownDiagrams()
            do { _ = try await engine.render("flowchart LR\nA[unclosed", width: 600); checks["invalidMermaidReportsFailure"] = false } catch { checks["invalidMermaidReportsFailure"] = true }
            let strict = try await engine.render("%%{init: {\"securityLevel\":\"loose\",\"htmlLabels\":true}}%%\nflowchart LR\nA[Local] --> B[Only]\nclick A href \"https://example.invalid/\"", width: 600)
            try Data(strict.svg.utf8).write(to: diagramOutput.appendingPathComponent("strict-directive.svg")); try strict.pdf.write(to: diagramOutput.appendingPathComponent("strict-directive.pdf"))
            try JSONSerialization.data(withJSONObject: ["labels": strict.labels], options: [.prettyPrinted, .sortedKeys]).write(to: diagramOutput.appendingPathComponent("strict-directive-observation.json"))
            checks["diagramDirectivesCannotEnableRemoteLinks"] = strict.svg.range(of: "(?:xlink:)?href=[\"'](?:https?:|file:|javascript:)", options: .regularExpression) == nil && strict.labels.contains("Local")
            checks["actualWebKitPolicyBlocksNetwork"] = try await engine.checkOfflinePolicy(); engine.stop()
            let countBound = AgentMarkdownDocument.render(Array(repeating: "```mermaid\nflowchart LR\nA-->B\n```", count: 17).joined(separator: "\n"), document: diagramFile, files: files, width: 400)
            checks["diagramCountLimitKeepsSourceVisible"] = countBound.diagrams.count == 16 && countBound.body.string.contains("本页 16 张") && countBound.body.string.contains("A-->B")
            let quotedView = AgentMarkdownTextView(), quoteButton = NSButton(), quote = AgentMarkdownSelectionAction(text: quotedView, button: quoteButton) { (diagramFile, workspace.path) }
            quotedView.textStorage?.setAttributedString(reader.document!.body); quotedView.setSelectedRange(reader.document!.diagrams[0].range)
            let diagramSelection = try quote.selection()
            checks["selectedDiagramQuotesOriginalMermaid"] = diagramSelection.text == "```mermaid\n" + reader.document!.diagrams[0].source + "\n```" && diagramSelection.draftText.contains("> ```mermaid")
            quotedView.string = String(repeating: "中", count: 6000); quotedView.selectAll(nil)
            do { _ = try quote.selection(); checks["oversizedSelectionRejectedBeforeDraft"] = false } catch { checks["oversizedSelectionRejectedBeforeDraft"] = true }
            reader.show(diagramSource, file: diagramFile, workspace: workspace.path); reader.clear(); reader.show(readme, file: workspace.appendingPathComponent("README.md"), workspace: workspace.path); await wait(0.1)
            checks["replacedDocumentCannotReceiveStaleDiagram"] = reader.drawings.isEmpty && reader.document?.diagrams.isEmpty == true && reader.document?.headings.first?.title == "蓝色大肥鱼 · 小鲸 🐳"
            readingWindow.close()
            let actualCode = try String(contentsOf: expectedSource, encoding: .utf8)
            if let range = AgentMarkdownDocument.lineRange("L7-L8", in: actualCode) { checks["sourceLineSelectionUsesActualUTF16Range"] = (actualCode as NSString).substring(with: range) == actualCode.components(separatedBy: "\n")[6...7].joined(separator: "\n") }
            else { checks["sourceLineSelectionUsesActualUTF16Range"] = false }
            ensureAgent(); guard let isolated = agentStore else { throw PetError("检查任务未初始化") }
            // Initialize the composer before creating store-backed fixture drafts;
            // a late window initialization otherwise holds an empty A composer.
            _ = control
            let id = isolated.create(title: "项目文档阅读", workspace: workspace.path, mode: .agent)
            isolated.update(id) { $0.artifacts = [workspace.appendingPathComponent("README.md").path, workspace.appendingPathComponent("docs/DEVELOPMENT.md").path, diagramFile.path]; $0.draft = "保留的A草稿" }
            let other = isolated.create(title: "另一个文档草稿", workspace: workspace.path, mode: .ask)
            isolated.update(other) { $0.draft = "保留的B草稿" }
            control.prepareExtensionCheckWindow(taskID: other, manager: false)
            guard isolated.task(id)?.draft == "保留的A草稿", isolated.task(other)?.draft == "保留的B草稿" else { throw PetError("检查草稿初始化发生变化，保留当前记录") }
            let passage = diagramSource.components(separatedBy: "\n").first { $0.hasPrefix("选中文字后") }!
            let selection = AgentMarkdownSelection(file: diagramFile, workspace: workspace.path, text: passage)
            try control.checkAddDocumentSelection(selection, taskID: id)
            try JSONSerialization.data(withJSONObject: ["selectedID": isolated.selectedID ?? "none", "originalTaskID": id, "expectedDraft": "保留的A草稿\n\n" + selection.draftText, "actualDraft": isolated.task(id)?.draft ?? "nil", "otherDraft": isolated.task(other)?.draft ?? "nil", "messageCount": isolated.task(id)?.messages.count ?? -1], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("selection-append-observation.json"))
            checks["selectionAppendsToOriginalTaskAndKeepsOtherDraft"] = isolated.selectedID == id && isolated.task(id)?.draft == "保留的A草稿\n\n" + selection.draftText && isolated.task(other)?.draft == "保留的B草稿" && isolated.task(id)?.messages.isEmpty == true
            control.prepareExtensionCheckWindow(taskID: other, manager: false)
            isolated.update(id) { $0.draft = "保留的A草稿"; $0.archived = true }
            do { try control.checkAddDocumentSelection(selection, taskID: id); checks["archivedTaskRejectsSelectedText"] = false } catch { checks["archivedTaskRejectsSelectedText"] = isolated.task(id)?.draft == "保留的A草稿" && isolated.selectedID == other }
            isolated.update(id) { $0.archived = false; $0.kind = "wiki" }
            do { try control.checkAddDocumentSelection(selection, taskID: id); checks["managedDocumentationRejectsSelectedText"] = false } catch { checks["managedDocumentationRejectsSelectedText"] = true }
            isolated.update(id) { $0.kind = nil }
            let elsewhere = output.appendingPathComponent("other-workspace"); try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            do { try control.checkAddDocumentSelection(AgentMarkdownSelection(file: diagramFile, workspace: elsewhere.path, text: passage), taskID: id); checks["changedWorkspaceRejectsStaleSelection"] = false } catch { checks["changedWorkspaceRejectsStaleSelection"] = isolated.task(id)?.draft == "保留的A草稿" }
            do { try control.checkAddDocumentSelection(AgentMarkdownSelection(file: workspace.appendingPathComponent(".env"), workspace: workspace.path, text: passage), taskID: id); checks["sensitiveDocumentSelectionRejected"] = false } catch { checks["sensitiveDocumentSelectionRejected"] = true }
            isolated.update(id) { $0.draft = String(repeating: "A", count: 99_999) }
            do { try control.checkAddDocumentSelection(selection, taskID: id); checks["draftSizeLimitPreservesExistingText"] = false } catch { checks["draftSizeLimitPreservesExistingText"] = isolated.task(id)?.draft?.count == 99_999 }
            isolated.update(id) { $0.draft = "保留的A草稿" }
            guard let records = control.prepareMarkdownCheck(taskID: id) else { throw PetError("原生记录窗口未打开") }
            checks.merge(records.checkMarkdown()) { _, new in new }
            control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            let ready: [String: Any] = ["appPID": ProcessInfo.processInfo.processIdentifier, "binaryHash": hash, "taskID": id, "otherTaskID": other, "workspace": workspace.path, "modelsCalled": false, "checks": checks]
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("markdown-ui-ready.json"))
            let deadline = Date().addingTimeInterval(3600)
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-markdown-ui").path) { await wait(0.25) }
            if let data = try? Data(contentsOf: output.appendingPathComponent("markdown-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ui = observed["checks"] as? [String: Bool] {
                report["uiValidated"] = observed["appPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && observed["binaryHash"] as? String == hash && !ui.isEmpty && ui.values.allSatisfy { $0 }
                report["ui"] = observed
            }
            var unchanged = true
            for name in names { let current = try source.readData(source.resolve(name)); unchanged = unchanged && original[name] == AgentFiles.hash(current) }
            checks["originalRepositoryDocumentsUnchanged"] = unchanged
            let fullTasks = isolated.tasks.compactMap { isolated.task($0.id) }
            checks["readerMadeNoModelRequests"] = fullTasks.count == isolated.tasks.count && fullTasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty }
            checks["actualUISelectionStayedInUnsentOriginalDraft"] = isolated.selectedID == id && isolated.task(id)?.draft?.contains("[文件选文：docs/AGENT-READING.md]") == true && isolated.task(id)?.draft?.hasPrefix("保留的A草稿\n\n") == true && isolated.task(other)?.draft == "保留的B草稿" && fullTasks.allSatisfy { $0.messages.isEmpty && $0.queuedCount == 0 }
            report["originalSourceHashes"] = original; report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["binaryHash"] = hash
            records.close()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("markdown-report.json"))
    }
}
