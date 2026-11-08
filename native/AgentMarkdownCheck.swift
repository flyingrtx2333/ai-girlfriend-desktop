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
            let names = ["README.md", "docs/DEVELOPMENT.md", "native/AgentWiki.swift"]
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
            readingWindow.close()
            let actualCode = try String(contentsOf: expectedSource, encoding: .utf8)
            if let range = AgentMarkdownDocument.lineRange("L7-L8", in: actualCode) { checks["sourceLineSelectionUsesActualUTF16Range"] = (actualCode as NSString).substring(with: range) == actualCode.components(separatedBy: "\n")[6...7].joined(separator: "\n") }
            else { checks["sourceLineSelectionUsesActualUTF16Range"] = false }
            let isolated = AgentStore(directory: output.appendingPathComponent("reader-profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let id = isolated.create(title: "项目文档阅读", workspace: workspace.path, mode: .agent)
            isolated.update(id) { $0.artifacts = [workspace.appendingPathComponent("README.md").path, workspace.appendingPathComponent("docs/DEVELOPMENT.md").path] }
            let records = AgentRecordWindow(store: isolated, taskID: id, section: 6)
            records.showWindow(nil); records.window?.makeKeyAndOrderFront(nil)
            checks.merge(records.checkMarkdown()) { _, new in new }
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            let ready: [String: Any] = ["appPID": ProcessInfo.processInfo.processIdentifier, "binaryHash": hash, "taskID": id, "workspace": workspace.path, "modelsCalled": false, "checks": checks]
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
            checks["readerMadeNoModelRequests"] = isolated.tasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty }
            report["originalSourceHashes"] = original; report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["binaryHash"] = hash
            records.close()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("markdown-report.json"))
    }
}
