import AppKit

@MainActor extension AppDelegate {
    func runAgentMarkdownEditingCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false]
        do {
            guard !CommandLine.arguments.contains("--live-agent"), let argument = CommandLine.arguments.firstIndex(of: "--markdown-edit-source"), CommandLine.arguments.indices.contains(argument + 1) else { throw PetError("预览编辑检查只使用实际本地文件，不调用模型") }
            let source = try AgentFiles(workspace: CommandLine.arguments[argument + 1]), fm = FileManager.default
            let workspace = output.appendingPathComponent("workspace"); try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            let files = try AgentFiles(workspace: workspace.path), guide = try files.resolve("docs/AGENT-READING.md")
            var originals: [String: String] = [:]
            for name in ["README.md", "docs/DEVELOPMENT.md", "docs/AGENT-READING.md"] {
                let data = try source.readData(source.resolve(name)); originals[name] = AgentFiles.hash(data); try files.writeData(data, to: files.resolve(name))
            }
            for image in try fm.contentsOfDirectory(at: source.resolve("docs/media"), includingPropertiesForKeys: nil) where AgentDocument.imageTypes.contains(image.pathExtension.lowercased()) {
                try files.writeData(source.readData(image, maximum: 20_000_000), to: files.resolve("docs/media/" + image.lastPathComponent))
            }
            let guideText = try String(contentsOf: guide, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            let bom = Data([0xEF, 0xBB, 0xBF]), initial = bom + Data(guideText.utf8)
            try files.writeData(initial, to: guide)
            let beforeParagraph = guideText.components(separatedBy: "\r\n").first { $0.hasPrefix("任务记录的 Markdown") }!
            let afterParagraph = "任务记录的 Markdown 产物和 Wiki 使用原生阅读器；正文、代码与单元格可就地修改，保存前保留为草稿。"
            let unsavedParagraph = "任务记录的 Markdown 产物和 Wiki 使用原生阅读器；外部文件已变化，这段未保存的修改应完整保留。"
            let beforeRow = "| 正文或代码块 | 当前块的 Markdown | 保存后写入 |"
            let cellValue = "正文 | 中文😀\n第二行", afterRow = "| 正文 \\| 中文😀<br>第二行 | 当前块的 Markdown | 保存后写入 |"
            guard guideText.components(separatedBy: beforeParagraph).count == 2, guideText.components(separatedBy: beforeRow).count == 2 else { throw PetError("实际项目文档已变化，请更新编辑目标") }
            let expectedText = guideText.replacingOccurrences(of: beforeParagraph, with: afterParagraph).replacingOccurrences(of: beforeRow, with: afterRow)
            let saved = bom + Data(expectedText.utf8), externalSuffix = "\r\n<!-- 外部写入：预览编辑验收 -->\r\n", external = saved + Data(externalSuffix.utf8)
            let expectedDraft = bom + Data(expectedText.replacingOccurrences(of: afterParagraph, with: unsavedParagraph).utf8)
            let plan: [String: Any] = ["file": guide.path, "initialHash": AgentFiles.hash(initial), "paragraphBefore": beforeParagraph, "paragraphAfter": afterParagraph, "paragraphUnsaved": unsavedParagraph, "cellBefore": "正文或代码块", "cellAfter": cellValue, "rowBefore": beforeRow, "rowAfter": afterRow, "savedHash": AgentFiles.hash(saved), "externalHash": AgentFiles.hash(external), "externalSuffix": externalSuffix, "draftHash": AgentFiles.hash(expectedDraft), "utf8BOM": true, "lineEndings": "CRLF"]
            try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("markdown-edit-plan.json"))
            try saved.write(to: output.appendingPathComponent("expected-saved.md")); try external.write(to: output.appendingPathComponent("expected-external.md")); try expectedDraft.write(to: output.appendingPathComponent("expected-unsaved.md"))

            let doc = AgentMarkdownDocument.render(guideText, document: guide, files: files, width: 600)
            checks["actualGuideHasEditableBlockAndCellSourceRanges"] = doc.regions.contains { !$0.isCell } && doc.regions.contains { $0.isCell } && doc.regions.allSatisfy { Range($0.source, in: guideText) != nil && NSMaxRange($0.display) <= doc.body.length }
            guard let cell = doc.regions.first(where: { $0.isCell && (try? AgentMarkdownEditing.value($0, in: guideText)) == "正文或代码块" }) else { throw PetError("未找到真实文档单元格") }
            let patched = try AgentMarkdownEditing.replacing(cell, in: guideText, with: cellValue)
            checks["cellPatchPreservesAllOtherSourceBytesAndCRLF"] = bom + Data(patched.utf8) == bom + Data(guideText.replacingOccurrences(of: beforeRow, with: afterRow).utf8)
            checks["enteringCellWithoutEditsDoesNotNormalizeMarkup"] = try AgentMarkdownEditing.replacing(cell, in: guideText, with: "正文或代码块") == guideText
            checks["escapedAndInlineCodePipesRemainSeparateCells"] = AgentMarkdownEditing.cells("| A\\|B | `C|D` | **加粗** |").map(\.text) == ["A|B", "`C|D`", "**加粗**"]
            let short = AgentMarkdownEditing.lines("| A |\r\n")[0], missing = AgentMarkdownEditing.missingCell(short, column: 2, existing: 1, display: NSRange(location: 0, length: 1), table: 0, row: 1)
            checks["missingCellInsertsRequiredSeparatorsOnly"] = try AgentMarkdownEditing.replacing(missing, in: "| A |\r\n", with: "中文😀") == "| A | | 中文😀 |\r\n"
            let single = AgentMarkdownDocument.render("| 一列 |\n| --- |\n| 中文 |", document: guide, files: files, width: 400)
            checks["singleColumnTableHasEditableNativeCells"] = single.regions.filter(\.isCell).count == 2
            let fenced = "# 标题😀\r\n\r\n````swift\r\nlet name = \"中文\"\r\n```\r\n````\r\n\r\n尾部\r\n"
            let fencedDoc = AgentMarkdownDocument.render(fenced, document: guide, files: files, width: 400)
            guard let code = fencedDoc.regions.first(where: { (try? AgentMarkdownEditing.value($0, in: fenced).hasPrefix("````swift")) == true }) else { throw PetError("代码块来源定位缺失") }
            let codeValue = try AgentMarkdownEditing.value(code, in: fenced)
            checks["fencedCodeEditKeepsFenceAndUnicodeOutsideBlock"] = try AgentMarkdownEditing.replacing(code, in: fenced, with: codeValue.replacingOccurrences(of: "中文", with: "文档😀")) == fenced.replacingOccurrences(of: "中文", with: "文档😀")
            do { _ = try AgentMarkdownEditing.replacing(cell, in: guideText, with: "invalid\0text"); checks["invalidTextRejectedWithoutChangingSource"] = false } catch { checks["invalidTextRejectedWithoutChangingSource"] = true }
            do { _ = try AgentMarkdownEditing.value(.init(source: NSRange(location: NSNotFound, length: 1), display: NSRange(location: 0, length: 0), kind: .block), in: guideText); checks["staleSourceRangeRejectedWithoutOverflow"] = false } catch { checks["staleSourceRangeRejectedWithoutOverflow"] = true }

            let readmeURL = try files.resolve("README.md"), readme = try String(contentsOf: readmeURL, encoding: .utf8)
            let firstImages = AgentMarkdownDocument.render(readme, document: readmeURL, files: files, width: 600)
            let keptImages = AgentMarkdownDocument.render(readme, document: readmeURL, files: files, width: 400, cachedImages: firstImages.images)
            checks["editReflowReusesDecodedLocalImageObjects"] = !firstImages.images.isEmpty && firstImages.images.count == keptImages.images.count && firstImages.images.allSatisfy { keptImages.images[$0.key] === $0.value }

            ensureAgent(); guard let tasks = agentStore else { throw PetError("编辑检查任务未初始化") }; _ = control
            let id = tasks.create(title: "Markdown 预览编辑", workspace: workspace.path, mode: .agent)
            tasks.update(id) { $0.artifacts = [guide.path]; $0.draft = "保留的A草稿" }
            let other = tasks.create(title: "另一个任务的原草稿", workspace: workspace.path, mode: .ask); tasks.update(other) { $0.draft = "保留的B草稿" }
            let guardFile = try files.resolve("guard/actual-guide.md"); try files.writeData(initial, to: guardFile)
            try files.writeData(external, to: guardFile)
            let tools = AgentTools(store: tasks, taskID: id)
            func call(_ expected: Any?, content: String) throws -> AgentToolCall {
                var args: [String: Any] = ["path": guardFile.path, "content": content]
                if let expected { args["expected_hash"] = expected }
                let data = try JSONSerialization.data(withJSONObject: args)
                return AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: data, as: UTF8.self))
            }
            do { _ = try await tools.execute(call(AgentFiles.hash(initial), content: "stale")); checks["writeFileExpectedHashRejectsStaleSnapshot"] = false }
            catch { let current = try files.readData(guardFile); checks["writeFileExpectedHashRejectsStaleSnapshot"] = error.localizedDescription.contains("哈希") && current == external }
            do { _ = try await tools.execute(call(123, content: "invalid hash")); checks["writeFileRejectsWrongHashType"] = false }
            catch { let current = try files.readData(guardFile); checks["writeFileRejectsWrongHashType"] = error.localizedDescription.contains("哈希") && current == external }
            _ = try await tools.execute(call(AgentFiles.hash(external), content: "\u{FEFF}" + expectedText))
            checks["writeFileValidHashWritesExactBOMAndCRLF"] = try files.readData(guardFile) == saved
            _ = try await tools.execute(call(nil, content: "\u{FEFF}" + guideText))
            checks["existingWriteFileCallsRemainCompatible"] = try files.readData(guardFile) == initial
            let editArgs: [String: Any] = ["path": guardFile.path, "old_text": beforeParagraph, "new_text": afterParagraph, "expected_hash": AgentFiles.hash(initial)]
            _ = try await tools.execute(AgentToolCall(id: UUID().uuidString, name: "edit_file", arguments: String(decoding: JSONSerialization.data(withJSONObject: editArgs), as: UTF8.self)))
            checks["editFileKeepsExistingBOMAndCRLF"] = try files.readData(guardFile) == bom + Data(guideText.replacingOccurrences(of: beforeParagraph, with: afterParagraph).utf8)
            let readonly = try files.resolve("readonly/actual-guide.md"); try files.writeData(initial, to: readonly)
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readonly.path)
            tasks.update(id) { $0.artifacts = [readonly.path] }
            let readonlyWindow = AgentRecordWindow(store: tasks, taskID: id, section: 1), readonlyState = await readonlyWindow.markdownEditingReadback()
            checks["readOnlyFileDisablesSourceAndPreviewEditing"] = readonlyState["sourceEditable"] as? Bool == false && (readonlyState["preview"] as? [String: Any])?["canEdit"] as? Bool == false
            readonlyWindow.close()
            tasks.update(id) { $0.artifacts = [guide.path] }
            guard let records = control.prepareMarkdownCheck(taskID: id, section: 1, value: guide.path) else { throw PetError("实际任务记录窗口未打开") }
            let initialState = await records.markdownEditingReadback()
            let initialImages = (initialState["preview"] as? [String: Any])?["diagramImages"] as? [String] ?? []
            checks["actualRecordStartsWithExactEncodedFileAndEditablePreview"] = initialState["draftHash"] as? String == AgentFiles.hash(initial) && initialState["utf8BOM"] as? Bool == true && initialState["dirty"] as? Bool == false && (initialState["preview"] as? [String: Any])?["canEdit"] as? Bool == true
            checks["threeActualDiagramsReadyBeforeEditing"] = initialImages.count == 3
            control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            let ready: [String: Any] = ["appPID": ProcessInfo.processInfo.processIdentifier, "binaryHash": binaryHash, "taskID": id, "otherTaskID": other, "workspace": workspace.path, "file": guide.path, "checks": checks, "modelsCalled": false]
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("markdown-edit-ui-ready.json"))
            let deadline = Date().addingTimeInterval(3600)
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-markdown-edit-ui").path) { await wait(0.25) }
            if let data = try? Data(contentsOf: output.appendingPathComponent("markdown-edit-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ui = observed["checks"] as? [String: Bool] {
                report["uiValidated"] = observed["appPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && observed["binaryHash"] as? String == binaryHash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = observed
            }
            let final = await records.markdownEditingReadback()
            try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-editing-readback.json"))
            if let retained = final["encodedDraft"] as? String { try Data(retained.utf8).write(to: output.appendingPathComponent("retained-unsaved-draft.md")) }
            checks["actualSavedAndConflictingExternalBytesPreserved"] = try files.readData(guide) == external
            checks["actualUnsavedDraftRetainedAfterConflict"] = final["draftHash"] as? String == AgentFiles.hash(expectedDraft) && final["dirty"] as? Bool == true && final["openedHash"] as? String == AgentFiles.hash(saved)
            checks["unchangedDiagramsReusedThroughPreviewEdits"] = (final["preview"] as? [String: Any])?["diagramImages"] as? [String] == initialImages
            checks["bothComposerDraftsUnchanged"] = tasks.task(id)?.draft == "保留的A草稿" && tasks.task(other)?.draft == "保留的B草稿"
            let full = tasks.tasks.compactMap { tasks.task($0.id) }
            checks["noModelRequestsMessagesOrQueuedInputs"] = full.count == tasks.tasks.count && full.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.messages.isEmpty && $0.queuedCount == 0 }
            var unchanged = true
            for (name, hash) in originals { let current = try source.fileHash(source.resolve(name)); unchanged = unchanged && current == hash }
            checks["originalProjectSourceFilesUnchanged"] = unchanged
            report["originalSourceHashes"] = originals; report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["binaryHash"] = binaryHash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("markdown-edit-report.json"))
    }
}
