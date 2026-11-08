import AppKit

@MainActor extension AppDelegate {
    func runAgentTextEncodingCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false]
        do {
            guard !CommandLine.arguments.contains("--live-agent"), let argument = CommandLine.arguments.firstIndex(of: "--text-encoding-source"), CommandLine.arguments.indices.contains(argument + 1) else { throw PetError("编码验收只使用实际文件与独立编码转换，不调用模型") }
            let source = try AgentFiles(workspace: CommandLine.arguments[argument + 1]), fm = FileManager.default
            let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("encoding-fixtures.json"))) as! [String: Any], vectors = fixtures["vectors"] as! [[String: Any]], workflow = fixtures["workflow"] as! [String: Any], expected = workflow["files"] as! [String: [String: String]]
            func data(_ name: String) throws -> Data { try Data(contentsOf: output.appendingPathComponent("encoding-fixtures/" + expected[name]!["name"]!)) }
            var vectorsOK = vectors.count == 15
            for item in vectors {
                let bytes = try Data(contentsOf: output.appendingPathComponent("encoding-fixtures/" + (item["name"] as! String))), encoding = AgentTextEncoding(rawValue: item["encoding"] as! String)!
                let doc = try AgentTextFile.decode(bytes, encoding: encoding), written = try doc.format.encode(doc.text)
                vectorsOK = vectorsOK && AgentFiles.hash(bytes) == item["sha256"] as? String && Data(doc.text.utf8) == Data((item["text"] as! String).utf8) && written == bytes && doc.format.bom == item["bom"] as? Bool
            }
            checks["tenEncodingsAndUnicodeMarkersMatchFifteenIndependentIconvVectors"] = vectorsOK
            report["independentConverter"] = fixtures["converter"]; report["vectorCount"] = vectors.count
            let workspace = output.appendingPathComponent("workspace"); try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            let files = try AgentFiles(workspace: workspace.path), gb = try files.resolve("docs/gb18030.md"), big5 = try files.resolve("docs/big5.txt"), unicode = try files.resolve("docs/utf16.md"), reference = try files.resolve("sources/legacy-guide.md")
            for (file, name) in [(gb,"gb-before"),(big5,"big5-before"),(unicode,"unicode-before"),(reference,"reference")] { try files.writeData(data(name), to: file) }
            var originals: [String: String] = [:]
            for name in ["README.md", "docs/DEVELOPMENT.md", "docs/AGENT-READING.md"] { originals[name] = try source.fileHash(source.resolve(name)) }
            let before = workflow["paragraphBefore"] as! String, gbAfter = workflow["gbParagraphAfter"] as! String
            let plan: [String: Any] = ["gbFile": gb.path, "big5File": big5.path, "unicodeFile": unicode.path, "referenceFile": reference.path, "paragraphBefore": before, "gbParagraphAfter": gbAfter, "unicodeParagraphAfter": workflow["unicodeParagraphAfter"]!, "big5Before": workflow["big5Before"]!, "big5After": workflow["big5After"]!, "gbBeforeHash": expected["gb-before"]!["sha256"]!, "gbExternalHash": expected["gb-external"]!["sha256"]!, "gbAfterHash": expected["gb-after"]!["sha256"]!, "big5BeforeHash": expected["big5-before"]!["sha256"]!, "big5AfterHash": expected["big5-after"]!["sha256"]!, "unicodeAfterHash": expected["unicode-after"]!["sha256"]!, "files": [(gb,"gb-after"),(big5,"big5-after"),(unicode,"unicode-after"),(reference,"reference")].map { ["path": $0.0.path, "expectedHash": expected[$0.1]!["sha256"]!] }]
            try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("text-encoding-plan.json"))
            ensureAgent(); guard let tasks = agentStore else { throw PetError("编码任务未初始化") }; _ = control
            let id = tasks.create(title: "文本编码重开", workspace: workspace.path, mode: .agent), tools = AgentTools(store: tasks, taskID: id)
            func call(_ name: String, _ values: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)) }
            let readGB = try await tools.execute(call("read_file", ["path": gb.path, "encoding": "gb18030", "offset": 1, "limit": 6]))
            let readUnicode = try await tools.execute(call("read_file", ["path": unicode.path, "offset": 1, "limit": 6]))
            checks["fileToolsReadExplicitGB18030AndAutomaticUTF16WithActualLineNumbers"] = readGB.text.contains("3: " + before) && readUnicode.text.contains("3: " + before)
            let guardGB = try files.resolve("guard/gb18030.md"), guardUnicode = try files.resolve("guard/utf16.md"), guardBig5 = try files.resolve("guard/big5.txt")
            for (file, name) in [(guardGB,"gb-before"),(guardUnicode,"unicode-before"),(guardBig5,"big5-before")] { try files.writeData(data(name), to: file) }
            _ = try await tools.execute(call("edit_file", ["path": guardGB.path, "encoding": "gb18030", "old_text": before, "new_text": gbAfter]))
            checks["preciseFileEditPreservesIndependentGB18030BytesAndCRLF"] = try files.readData(guardGB) == data("gb-after")
            _ = try await tools.execute(call("write_file", ["path": guardUnicode.path, "encoding": "utf-16le", "byte_order_mark": true, "expected_hash": expected["unicode-before"]!["sha256"]!, "content": expected["unicode-after"]!["text"]!]))
            checks["fileWritePreservesIndependentUTF16MarkerEmojiAndCRLF"] = try files.readData(guardUnicode) == data("unicode-after")
            _ = try await tools.execute(call("edit_file", ["path": guardUnicode.path, "old_text": workflow["unicodeParagraphAfter"]!, "new_text": before]))
            checks["preciseFileEditAutomaticallyKeepsUTF16OriginalFormat"] = try files.readData(guardUnicode) == data("unicode-before")
            let failureCases: [(String, [String: Any])] = [("unrepresentableBig5",["encoding":"big5","content":expected["big5-before"]!["text"]! + "😀"]),("invalidEncodingName",["encoding":"invalid-codec","content":"text"]),("invalidEncodingType",["encoding":123,"content":"text"]),("invalidMarkerType",["encoding":"big5","byte_order_mark":"true","content":"text"]),("unsupportedMarker",["encoding":"big5","byte_order_mark":true,"content":"text"])]
            for (name, parameters) in failureCases {
                do { _ = try await tools.execute(call("write_file", parameters.merging(["path":guardBig5.path]) { _, new in new })); checks[name + "DoesNotWrite"] = false }
                catch { checks[name + "DoesNotWrite"] = try files.readData(guardBig5) == data("big5-before") }
            }
            let legacy = try files.resolve("guard/default-utf8.md"), rawUTF8 = Data(("\u{FEFF}" + expected["gb-before"]!["text"]!).utf8)
            _ = try await tools.execute(call("write_file", ["path": legacy.path, "content": String(decoding: rawUTF8, as: UTF8.self)]))
            checks["existingWriteFileWithoutEncodingStillWritesExactUTF8Bytes"] = try files.readData(legacy) == rawUTF8
            let captured = try AgentFileConflictSnapshot.read(file: gb, workspace: workspace.path, draft: expected["gb-after"]!["text"]!, allowsOverwrite: true, format: AgentTextFormat(encoding: .gb18030))
            let patch = try await captured.patch(protectedData: output.appendingPathComponent("profile"))
            checks["legacyConflictDiffShowsDecodedChineseRatherThanBinary"] = patch.contains(before) && patch.contains(gbAfter) && !patch.contains("Binary files")
            let latin = try AgentTextFile.decode(data("gb-before"), encoding: .latin1), reinterpreted = try AgentFileConflictSnapshot.read(file: gb, workspace: workspace.path, draft: latin.text, allowsOverwrite: true, format: latin.format)
            let sameBytes = try AgentFileConflictSnapshot.read(file: gb, workspace: workspace.path, draft: expected["gb-before"]!["text"]!, allowsOverwrite: true, format: AgentTextFormat(encoding: .gb18030))
            guard sameBytes.disk == reinterpreted.disk, sameBytes.draft == reinterpreted.draft else { throw PetError("独立编码快照字节不一致") }
            do { try sameBytes.requireUnchanged(reinterpreted); checks["encodingChangeInvalidatesReviewedSnapshot"] = false } catch { checks["encodingChangeInvalidatesReviewedSnapshot"] = true }
            let sourceWindow = try AgentMarkdownSourceWindow(workspace: workspace.path, target: unicode), sourceState = sourceWindow.encodingCheckState
            checks["sourceWindowAutomaticallyDecodesUTF16AndRemainsReadOnly"] = sourceState["editable"] as? Bool == false && sourceState["encoding"] as? String == "utf-16le" && sourceState["byteOrderMark"] as? Bool == true && sourceState["textHash"] as? String == AgentFiles.hash(Data(expected["unicode-before"]!["text"]!.utf8)); sourceWindow.close()
            tasks.update(id) { $0.artifacts = [gb.path, big5.path, unicode.path]; $0.draft = "保留的A草稿" }
            let other = tasks.create(title: "另一个任务的原草稿", workspace: workspace.path, mode: .ask); tasks.update(other) { $0.draft = "保留的B草稿" }
            guard let records = control.prepareMarkdownCheck(taskID: id, section: 1, value: gb.path) else { throw PetError("编码检查窗口未打开") }
            let initial = await records.markdownEditingReadback()
            checks["undecodableFileOffersEncodingWithoutEnablingEditing"] = initial["sourceEditable"] as? Bool == false && initial["encodingMenuVisible"] as? Bool == true && (initial["state"] as? String)?.contains("编码重开") == true
            control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try JSONSerialization.data(withJSONObject: ["appPID":ProcessInfo.processInfo.processIdentifier,"binaryHash":binaryHash,"taskID":id,"otherTaskID":other,"workspace":workspace.path,"file":gb.path,"checks":checks,"modelsCalled":false], options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("text-encoding-ui-ready.json"))
            let deadline = Date().addingTimeInterval(3600)
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-text-encoding-ui").path) { await wait(0.25) }
            if let bytes = try? Data(contentsOf: output.appendingPathComponent("text-encoding-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let ui = observed["checks"] as? [String: Bool] {
                report["uiValidated"] = observed["appPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && observed["binaryHash"] as? String == binaryHash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = observed
            }
            let final = await records.markdownEditingReadback(); try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("native-encoding-readback.json"))
            var finalFiles = true; for (file,name) in [(gb,"gb-after"),(big5,"big5-after"),(unicode,"unicode-after"),(reference,"reference")] { let bytes = try files.readData(file); finalFiles = try finalFiles && bytes == data(name) }; checks["allFourActualFilesMatchIndependentExpectedBytes"] = finalFiles
            checks["editorAndSavedUTF16FileMatchExactBytesAndFormat"] = final["draftHash"] as? String == expected["unicode-after"]!["sha256"] && final["openedHash"] as? String == expected["unicode-after"]!["sha256"] && final["dirty"] as? Bool == false && final["encoding"] as? String == "utf-16le" && final["byteOrderMark"] as? Bool == true
            let changes = tasks.task(id)?.changes.filter { $0.path == gb.path } ?? []
            if let change = changes.first, let backup = change.backup { let backups = try AgentFiles(workspace: tasks.backupDirectory(id).path); checks["confirmedLegacyOverwriteRetainsActualEncodedCheckpoint"] = try changes.count == 1 && change.beforeHash == expected["gb-external"]!["sha256"] && change.afterHash == expected["gb-after"]!["sha256"] && backups.readData(backups.literalURL(backup)) == data("gb-external") } else { checks["confirmedLegacyOverwriteRetainsActualEncodedCheckpoint"] = false }
            checks["bothTaskComposerDraftsUnchanged"] = tasks.task(id)?.draft == "保留的A草稿" && tasks.task(other)?.draft == "保留的B草稿"
            let full = tasks.tasks.compactMap { tasks.task($0.id) }; checks["noModelsMessagesOrQueuedInputs"] = full.count == tasks.tasks.count && full.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.messages.isEmpty && $0.queuedCount == 0 }
            var unchanged = true; for (name, hash) in originals { let current = try source.fileHash(source.resolve(name)); unchanged = unchanged && current == hash }; checks["originalProjectDocumentsUnchanged"] = unchanged
            report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["binaryHash"] = binaryHash; report["originalSourceHashes"] = originals
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("text-encoding-report.json"))
    }
}
