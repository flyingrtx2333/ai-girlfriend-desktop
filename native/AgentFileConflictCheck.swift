import AppKit

@MainActor extension AppDelegate {
    func runAgentFileConflictCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false]
        do {
            guard !CommandLine.arguments.contains("--live-agent"), let index = CommandLine.arguments.firstIndex(of: "--file-conflict-source"), CommandLine.arguments.indices.contains(index + 1) else { throw PetError("文件冲突检查只使用实际本地文档，不调用模型") }
            let source = try AgentFiles(workspace: CommandLine.arguments[index + 1]), fm = FileManager.default
            let workspace = output.appendingPathComponent("workspace"); try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            let files = try AgentFiles(workspace: workspace.path), guide = try files.resolve("docs/AGENT-READING.md")
            var originals: [String: String] = [:]
            for name in ["README.md", "docs/DEVELOPMENT.md", "docs/AGENT-READING.md"] { let data = try source.readData(source.resolve(name)); originals[name] = AgentFiles.hash(data); try files.writeData(data, to: files.resolve(name)) }
            let text = try String(contentsOf: guide, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            guard let before = text.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("任务记录的 Markdown") }), text.components(separatedBy: before).count == 2 else { throw PetError("实际项目文档已变化，请更新编辑位置") }
            let overwriteParagraph = "任务记录的 Markdown 产物和 Wiki 可在原生窗口编辑；这份草稿用于实际保存冲突比较。"
            let adoptParagraph = "任务记录的 Markdown 产物和 Wiki 有另一份尚未保存的正文；采用磁盘版本前必须确认。"
            let bom = Data([0xEF, 0xBB, 0xBF]), initial = bom + Data(text.utf8), overwrittenText = text.replacingOccurrences(of: before, with: overwriteParagraph), overwritten = bom + Data(overwrittenText.utf8)
            let external1 = initial + Data("\r\n<!-- 外部操作一：保留当前磁盘文字 -->\r\n".utf8), external2 = external1 + Data("\r\n<!-- 外部操作二：比较后文件再次变化 -->\r\n".utf8)
            let final = Data((overwrittenText.replacingOccurrences(of: "\r\n", with: "\n") + "\n<!-- 外部操作三：采用这份磁盘版本 -->\n").utf8)
            let secondDraft = bom + Data(overwrittenText.replacingOccurrences(of: overwriteParagraph, with: adoptParagraph).utf8)
            try files.writeData(initial, to: guide)
            for (name, value) in [("initial.md", initial), ("expected-overwrite.md", overwritten), ("external-1.md", external1), ("external-2.md", external2), ("final-disk.md", final), ("second-draft.md", secondDraft)] { try value.write(to: output.appendingPathComponent(name)) }
            let plan: [String: Any] = ["file": guide.path, "paragraphBefore": before, "overwriteParagraph": overwriteParagraph, "adoptParagraph": adoptParagraph, "initialHash": AgentFiles.hash(initial), "overwriteHash": AgentFiles.hash(overwritten), "external1Hash": AgentFiles.hash(external1), "external2Hash": AgentFiles.hash(external2), "finalDiskHash": AgentFiles.hash(final), "secondDraftHash": AgentFiles.hash(secondDraft)]
            try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("file-conflict-plan.json"))

            let guardFile = try files.resolve("guard/actual-guide.md"); try files.writeData(initial, to: guardFile)
            let captured = try AgentFileConflictSnapshot.read(file: guardFile, workspace: workspace.path, draft: String(decoding: overwritten, as: UTF8.self), allowsOverwrite: true)
            checks["snapshotKeepsExactBOMCRLFAndUnicodeBytes"] = captured.disk == initial && captured.draft == overwritten
            checks["formatDistinguishesActualBOMCRLFAndPlainLFVersions"] = AgentFileConflictSnapshot.format(initial) == "UTF-8 BOM · CRLF" && AgentFileConflictSnapshot.format(final) == "UTF-8 · LF"
            let patch = try await captured.patch(protectedData: output.appendingPathComponent("profile"))
            checks["actualGitDiffContainsBothProjectParagraphs"] = patch.contains(before) && patch.contains(overwriteParagraph) && patch.contains("@@") && patch.contains("actual-guide.md")
            let rows = AgentGitDiffRows.parse(patch), paragraphRow = rows.first { $0.old.text == before + "\r" }
            checks["actualCRLFDiffKeepsSeparateAlignedChangedLines"] = paragraphRow?.old.number == 3 && paragraphRow?.new.number == 3 && paragraphRow?.old.kind == .removed && paragraphRow?.new.kind == .added && paragraphRow?.new.text == overwriteParagraph + "\r" && rows.allSatisfy { !$0.old.text.contains("\n") && !$0.new.text.contains("\n") }
            try files.writeData(external1, to: guardFile)
            let changed = try AgentFileConflictSnapshot.read(file: guardFile, workspace: workspace.path, draft: String(decoding: overwritten, as: UTF8.self), allowsOverwrite: true)
            do { try captured.requireUnchanged(changed); checks["changedDiskInvalidatesReviewedSnapshot"] = false } catch { checks["changedDiskInvalidatesReviewedSnapshot"] = try files.readData(guardFile) == external1 }
            try files.writeData(initial, to: guardFile)
            let changedDraft = try AgentFileConflictSnapshot.read(file: guardFile, workspace: workspace.path, draft: String(decoding: secondDraft, as: UTF8.self), allowsOverwrite: true)
            do { try captured.requireUnchanged(changedDraft); checks["changedDraftInvalidatesReviewedSnapshot"] = false } catch { checks["changedDraftInvalidatesReviewedSnapshot"] = true }
            let differentScalars = AgentFileConflictSnapshot(file: captured.file, disk: captured.disk, draft: captured.draft + Data("e\u{301}".utf8), allowsOverwrite: true)
            let composed = AgentFileConflictSnapshot(file: captured.file, disk: captured.disk, draft: captured.draft + Data("é".utf8), allowsOverwrite: true)
            do { try differentScalars.requireUnchanged(composed); checks["canonicallyEquivalentDifferentBytesRequireNewReview"] = false } catch { checks["canonicallyEquivalentDifferentBytesRequireNewReview"] = true }
            let outside = output.appendingPathComponent("outside-guide.md"); try initial.write(to: outside)
            let link = try files.resolve("guard/outside.md"); try fm.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
            do { _ = try AgentFileConflictSnapshot.read(file: link, workspace: workspace.path, draft: text, allowsOverwrite: true); checks["outsideSymlinkCannotBeCompared"] = false } catch { checks["outsideSymlinkCannotBeCompared"] = true }
            let sensitive = try files.resolve(".env"); try files.writeData(initial, to: sensitive)
            do { _ = try AgentFileConflictSnapshot.read(file: sensitive, workspace: workspace.path, draft: text, allowsOverwrite: true); checks["protectedFileCannotBeCompared"] = false } catch { checks["protectedFileCannotBeCompared"] = true }
            for (name, bytes) in [("invalid-utf8", Data([0xFF])), ("nul", initial + Data([0])), ("oversize", Data(repeating: 65, count: 2_000_001))] {
                let path = try files.resolve("guard/" + name); try files.writeData(bytes, to: path)
                do { _ = try AgentFileConflictSnapshot.read(file: path, workspace: workspace.path, draft: text, allowsOverwrite: true); checks[name + "DiskIsRejected"] = false } catch { checks[name + "DiskIsRejected"] = true }
            }
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务存储未初始化") }; _ = control
            let id = tasks.create(title: "文件保存冲突", workspace: workspace.path, mode: .agent); tasks.update(id) { $0.artifacts = [guide.path]; $0.draft = "保留的A草稿" }
            let other = tasks.create(title: "另一个任务的原草稿", workspace: workspace.path, mode: .ask); tasks.update(other) { $0.draft = "保留的B草稿" }
            guard let records = control.prepareMarkdownCheck(taskID: id, section: 1, value: guide.path) else { throw PetError("实际记录窗口未打开") }
            let initialState = await records.markdownEditingReadback(), status = tasks.task(id)!.status
            checks["recordStartsWithExactFileAndWritableSnapshot"] = initialState["draftHash"] as? String == AgentFiles.hash(initial) && initialState["snapshotAllowsOverwrite"] as? Bool == true
            tasks.update(id) { $0.archived = true }; let archived = await records.markdownEditingReadback(); checks["archivedTaskSnapshotCannotOverwrite"] = archived["snapshotAllowsOverwrite"] as? Bool == false
            tasks.update(id) { $0.archived = false; $0.status = .running }; let running = await records.markdownEditingReadback(); checks["runningTaskSnapshotCannotOverwrite"] = running["snapshotAllowsOverwrite"] as? Bool == false
            tasks.update(id) { $0.status = status }; control.prepareExtensionCheckWindow(taskID: other, manager: false); records.window?.makeKeyAndOrderFront(nil)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]), binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            let ready: [String: Any] = ["appPID": ProcessInfo.processInfo.processIdentifier, "binaryHash": binaryHash, "taskID": id, "otherTaskID": other, "workspace": workspace.path, "file": guide.path, "checks": checks, "modelsCalled": false]
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("file-conflict-ui-ready.json"))
            let deadline = Date().addingTimeInterval(3600)
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-file-conflict-ui").path) { await wait(0.25) }
            if let data = try? Data(contentsOf: output.appendingPathComponent("file-conflict-ui-acceptance.json")), let observed = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ui = observed["checks"] as? [String: Bool] {
                report["uiValidated"] = observed["appPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && observed["binaryHash"] as? String == binaryHash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = observed
            }
            let current = await records.markdownEditingReadback()
            try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-conflict-readback.json"))
            checks["finalExternalDiskBytesPreservedAfterAdoption"] = try files.readData(guide) == final
            checks["adoptedEditorAndOpenedHashMatchDiskWithoutBOM"] = current["draftHash"] as? String == AgentFiles.hash(final) && current["openedHash"] as? String == AgentFiles.hash(final) && current["dirty"] as? Bool == false && current["utf8BOM"] as? Bool == false
            let changes = tasks.task(id)?.changes.filter { $0.path == guide.path } ?? []
            checks["onlyConfirmedOverwriteWasWrittenAndRecorded"] = changes.count == 1 && changes.first?.beforeHash == AgentFiles.hash(external2) && changes.first?.afterHash == AgentFiles.hash(overwritten)
            if let change = changes.first, let backup = change.backup { let backups = try AgentFiles(workspace: tasks.backupDirectory(id).path); checks["overwrittenExternalVersionRetainedInActualCheckpoint"] = try backups.readData(backups.literalURL(backup)) == external2 } else { checks["overwrittenExternalVersionRetainedInActualCheckpoint"] = false }
            checks["bothTaskComposerDraftsUnchanged"] = tasks.task(id)?.draft == "保留的A草稿" && tasks.task(other)?.draft == "保留的B草稿"
            let full = tasks.tasks.compactMap { tasks.task($0.id) }; checks["noModelsMessagesOrQueuedInputs"] = full.count == tasks.tasks.count && full.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.messages.isEmpty && $0.queuedCount == 0 }
            var unchanged = true; for (name, hash) in originals { let current = try source.fileHash(source.resolve(name)); unchanged = unchanged && current == hash }; checks["originalProjectDocumentsUnchanged"] = unchanged
            report["appPID"] = ProcessInfo.processInfo.processIdentifier; report["binaryHash"] = binaryHash; report["originalSourceHashes"] = originals
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("file-conflict-report.json"))
    }
}
