import AppKit

@MainActor extension AppDelegate {
    func runAgentAttachmentDropCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], values: [String: Any] = [:], requests = 0, failure: String?
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            await tasks.sideTasks.waitForStartup(); runtime.modelRequestCheck = { requests += 1; throw PetError("附件拖入检查禁止模型请求") }
            let fm = FileManager.default, inputs = output.appendingPathComponent("inputs"), readme = inputs.appendingPathComponent("project-readme.md"), image = inputs.appendingPathComponent("character.png")
            let original = try Data(contentsOf: readme), imageBytes = try Data(contentsOf: image)
            let a = tasks.create(title: "附件归属检查", mode: .ask, workMode: .general), b = tasks.create(title: "另一份附件任务", mode: .ask, workMode: .general)
            tasks.update(a) { $0.draft = "保留附件任务的文字草稿" }; tasks.update(b) { $0.draft = "不要把文件加入这里" }
            control.showAgentTask(a); control.show(tab: "chat")
            func bytes(_ id: String) throws -> Data { try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) }
            let before = try bytes(a), unsupported = inputs.appendingPathComponent("unsupported.bin"), directory = inputs.appendingPathComponent("folder.md"), sensitive = inputs.appendingPathComponent(".env"), oversized = inputs.appendingPathComponent("oversized.txt")
            try Data("unsupported\n".utf8).write(to: unsupported); try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: sensitive, withDestinationURL: readme)
            fm.createFile(atPath: oversized.path, contents: nil); let handle = try FileHandle(forWritingTo: oversized); try handle.truncate(atOffset: 20_000_001); try handle.close()
            for (name, urls) in [("mixedUnsupportedBatchIsRejectedBeforeAnyCopy", [readme, unsupported]), ("directoriesCannotBecomeFileAttachments", [directory]), ("sensitiveAliasNameIsRejected", [sensitive]), ("oversizedFileIsRejectedBeforeAnyCopy", [oversized]), ("remoteURLIsNotReadAsALocalFile", [URL(string: "https://example.com/public.md")!]), ("sevenFilesAreRejectedAsOneBatch", Array(repeating: readme, count: 7))] {
                checks[name] = control.beginAttachmentImport(urls, store: tasks, taskID: a) == nil
            }
            checks["allRejectedBatchesKeepActualTaskRecordBytes"] = try bytes(a) == before && tasks.task(a)?.attachments?.isEmpty != false
            guard let input = control.window?.firstResponder as? ComposerView else { throw PetError("实际任务输入框未获得焦点") }
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            guard pasteboard.writeObjects([readme as NSURL, image as NSURL]) else { throw PetError("原生文件粘贴板未写入") }
            let otherBefore = try bytes(b), accepted = input.readSelection(from: pasteboard, type: .fileURL)
            checks["actualComposerAcceptsRealFileURLPasteboard"] = accepted
            checks["secondImportCannotReplaceTheActiveImportJob"] = control.beginAttachmentImport([readme], store: tasks, taskID: a) == nil
            control.showAgentTask(b)
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline, (tasks.task(a)?.attachments?.count ?? 0) < 2 { await wait(0.02) }
            guard let files = tasks.task(a)?.attachments, files.count == 2 else { throw PetError("实际附件未导入两份文件") }
            checks["taskSwitchKeepsImportedFilesBoundToOriginalTask"] = try bytes(b) == otherBefore && tasks.task(b)?.attachments?.isEmpty != false && control.agentTaskID == b
            checks["fileIngressPreservesBothActualTextDrafts"] = tasks.task(a)?.draft == "保留附件任务的文字草稿" && tasks.task(b)?.draft == "不要把文件加入这里"
            let attachedReadme = files.first { $0.name == readme.lastPathComponent }!, attachedImage = files.first { $0.name == image.lastPathComponent }!
            checks["copiedMarkdownAndImageMatchActualInputBytes"] = try Data(contentsOf: AgentAttachments.source(store: tasks, taskID: a, id: attachedReadme.id)) == original && Data(contentsOf: AgentAttachments.source(store: tasks, taskID: a, id: attachedImage.id)) == imageBytes && attachedReadme.sha256 == AgentFiles.hash(original) && attachedImage.sha256 == AgentFiles.hash(imageBytes)
            let content = try AgentAttachments.content(store: tasks, taskID: a, id: attachedReadme.id)
            checks["realDocumentExtractionContainsOriginalReadme"] = content.parts.contains { $0.text.contains("蓝色大肥鱼") || $0.text.contains("BlueFatFish") || $0.text.contains("小鲸") }
            let quota = tasks.create(title: "附件数量上限", mode: .ask, workMode: .general)
            for _ in 0..<6 { _ = try await AgentAttachments.importFile(readme, store: tasks, taskID: quota) }
            let quotaBefore = try bytes(quota)
            checks["fullDraftRejectsWholeIncomingBatchWithoutChangingRecord"] = try control.beginAttachmentImport([readme, image], store: tasks, taskID: quota) == nil && bytes(quota) == quotaBefore && tasks.task(quota)?.draftAttachmentIDs?.count == 6
            let readonly = tasks.create(title: "只读保存检查", mode: .ask, workMode: .general), readonlyBefore = try bytes(readonly), index = tasks.directory.appendingPathComponent("index.json")
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: index.path)
            do { _ = try await AgentAttachments.importFile(readme, store: tasks, taskID: readonly); checks["actualReadonlyIndexRejectsAttachmentSave"] = false } catch { checks["actualReadonlyIndexRejectsAttachmentSave"] = true }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
            let copied = tasks.directory.appendingPathComponent(readonly + "/attachments")
            checks["failedSaveKeepsExactRecordAndLeavesNoDanglingFileReference"] = try bytes(readonly) == readonlyBefore && tasks.task(readonly)?.attachments?.isEmpty != false && (try? fm.contentsOfDirectory(atPath: copied.path))?.isEmpty != false
            let archived = tasks.create(title: "导入期间归档检查", mode: .ask, workMode: .general)
            guard let job = control.beginAttachmentImport([readme], store: tasks, taskID: archived) else { throw PetError("生命周期检查未启动") }
            try tasks.setArchived([archived], archived: true); let archivedBefore = try bytes(archived); await job.value
            checks["queuedImportCannotAddFilesAfterTaskIsArchived"] = try bytes(archived) == archivedBefore && tasks.task(archived)?.attachments?.isEmpty != false
            let ui = tasks.create(title: "拖入附件验收", mode: .ask, workMode: .general); tasks.update(ui) { $0.draft = "保留拖入窗口的草稿" }
            tasks.selectedID = ui
            checks["noModelRequestReceiptOrAssistantOutputWasCreated"] = requests == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false && tasks.task($0.id)?.messages.contains { $0.role == "assistant" } != true }
            values = ["sourceTaskID": a, "otherTaskID": b, "quotaTaskID": quota, "uiTaskID": ui, "readmeHash": AgentFiles.hash(original), "imageHash": AgentFiles.hash(imageBytes), "nativeClipboardIsNotASystemDragProof": true]
        } catch { failure = error.localizedDescription }
        values["checks"] = checks; values["success"] = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; values["appPID"] = getpid(); values["blockedModelAttempts"] = requests
        if let failure { values["error"] = failure }
        if let binary = Bundle.main.executableURL { values["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("attachment-drop-result.json"), options: .atomic)
    }
}
