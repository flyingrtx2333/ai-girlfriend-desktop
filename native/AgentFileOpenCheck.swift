import AppKit

@MainActor extension AppDelegate {
    func runAgentFileOpenCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0, failure: String?
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            await tasks.sideTasks.waitForStartup(); runtime.modelRequestCheck = { requests += 1; throw PetError("文件打开检查禁止模型请求") }
            let inputs = output.appendingPathComponent("inputs"), readme = inputs.appendingPathComponent("project-readme.md"), image = inputs.appendingPathComponent("character.png")
            let originals = try [readme, image].map { try Data(contentsOf: $0) }
            func bytes(_ id: String) throws -> Data { try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) }
            func ids() -> Set<String> { Set(tasks.tasks.map(\.id)) }
            func saved(_ id: String) throws -> AgentTaskRecord { try JSONDecoder().decode(AgentTaskRecord.self, from: bytes(id)) }
            let a = tasks.create(title: "保留原任务", mode: .ask, workMode: .general), b = tasks.create(title: "保留另一个窗口", workspace: inputs.path)
            control.showAgentTask(a); control.show(tab: "chat"); openTaskWindow(b, from: control)
            guard let other = additionalTaskWindows.last, let otherInput = other.window?.firstResponder as? ComposerView else { throw PetError("第二个任务窗口未打开") }
            otherInput.string = "另一个窗口尚未发送"; otherInput.didChangeText()
            control.show(tab: "chat")
            guard let input = control.window?.firstResponder as? ComposerView else { throw PetError("原任务输入框未获得焦点") }
            input.string = "原任务尚未发送"; input.didChangeText()
            let before = ids()
            application(NSApp, open: [readme, image]); await fileOpenJob?.value
            let created = ids().subtracting(before)
            guard created.count == 1, let id = created.first, let task = tasks.task(id), let files = task.attachments, files.count == 2 else { throw PetError("文件未进入独立草稿") }
            checks["localFilesCreateOneGeneralAskDraftWithoutWorkspace"] = task.organizationMode == .general && task.mode == .ask && task.workspace == nil && control.agentTaskID == id
            checks["allExistingWindowDraftsAreSavedBeforeSwitching"] = try saved(a).draft == "原任务尚未发送" && saved(b).draft == "另一个窗口尚未发送" && other.agentTaskID == b && otherInput.string == "另一个窗口尚未发送"
            checks["bothAttachmentsAreSavedAsUnsentDrafts"] = try Set(task.draftAttachmentIDs ?? []) == Set(files.map(\.id)) && saved(id).draftAttachmentIDs == task.draftAttachmentIDs && task.messages.isEmpty
            checks["actualCopiedFilesMatchOriginalBytesAndHashes"] = try zip([readme, image], originals).allSatisfy { source, data in
                guard let file = files.first(where: { $0.name == source.lastPathComponent }) else { return false }
                return try file.sha256 == AgentFiles.hash(data) && Data(contentsOf: AgentAttachments.source(store: tasks, taskID: id, id: file.id)) == data
            }
            guard let markdown = files.first(where: { $0.name == readme.lastPathComponent }) else { throw PetError("缺少文本附件") }
            checks["actualMarkdownExtractionRemainsReadable"] = try AgentAttachments.content(store: tasks, taskID: id, id: markdown.id).parts.contains { $0.text.contains("蓝色大肥鱼") || $0.text.contains("BlueFatFish") || $0.text.contains("小鲸") }
            let firstBytes = try bytes(id), previous = ids()
            application(NSApp, open: [readme]); application(NSApp, open: [image]); await fileOpenJob?.value
            let queued = ids().subtracting(previous), records = queued.compactMap { tasks.task($0) }
            checks["queuedOpenEventsPrepareSeparateDrafts"] = queued.count == 2 && records.allSatisfy { $0.attachments?.count == 1 && $0.draftAttachmentIDs?.count == 1 && $0.messages.isEmpty }
            checks["queuedFilesStayInTheirOwnDraftAndPreserveEarlierRecord"] = try Set(records.compactMap { $0.attachments?.first?.name }) == Set([readme.lastPathComponent, image.lastPathComponent]) && bytes(id) == firstBytes
            let beforeInvalid = ids(), savedBeforeInvalid = try Dictionary(uniqueKeysWithValues: beforeInvalid.map { ($0, try bytes($0)) })
            let unsupported = inputs.appendingPathComponent("unsupported.bin"); try Data("unsupported\n".utf8).write(to: unsupported)
            for (name, urls) in [("mixedUnsupportedBatchCreatesNoTaskOrPartialCopy", [readme, unsupported]), ("remoteURLCannotBecomeALocalFileTask", [URL(string: "https://example.com/public.md")!])] {
                application(NSApp, open: urls); await fileOpenJob?.value
                checks[name] = ids() == beforeInvalid && savedBeforeInvalid.allSatisfy { (try? bytes($0.key)) == $0.value }
            }
            let events = fileOpenEvents.count; application(NSApp, open: [])
            checks["emptyOpenEventIsIgnored"] = fileOpenEvents.count == events && fileOpenJob == nil && pendingFileOpens.isEmpty
            let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]], registration = types?.first
            checks["bundleRegistersExactlySupportedExtensionsAsAlternateViewer"] = Set(registration?["CFBundleTypeExtensions"] as? [String] ?? []) == AgentDocument.textTypes.union(AgentDocument.imageTypes).union(["pdf", "docx", "xlsx", "pptx"]) && registration?["CFBundleTypeRole"] as? String == "Viewer" && registration?["LSHandlerRank"] as? String == "Alternate"
            checks["noModelRequestMessageOrSourceFileWriteOccurred"] = try requests == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.messages.isEmpty == true && tasks.task($0.id)?.modelReceipts?.isEmpty != false } && zip([readme, image], originals).allSatisfy { try Data(contentsOf: $0.0) == $0.1 }
            report["firstTaskID"] = id; report["previousTaskIDs"] = [a, b]; report["queuedTaskIDs"] = queued.sorted(); report["fileOpenEvents"] = fileOpenEvents
        } catch { failure = error.localizedDescription }
        report["checks"] = checks; report["success"] = failure == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = getpid(); report["blockedModelAttempts"] = requests
        report["backgroundComponentCheck"] = usesBackgroundAttachmentCheck; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        report["visibleWindows"] = NSApp.windows.filter(\.isVisible).map { ["class": NSStringFromClass(type(of: $0)), "title": $0.title, "frame": NSStringFromRect($0.frame), "alpha": $0.alphaValue, "key": $0.isKeyWindow] as [String: Any] }
        report["screenFrames"] = NSScreen.screens.map { NSStringFromRect($0.frame) }
        report["onScreenWindowCount"] = NSApp.windows.filter { window in window.isVisible && window.alphaValue > 0 && NSScreen.screens.contains { $0.frame.intersects(window.frame) } }.count
        report["boundary"] = "Real native delegate, windows, files, parsing and durable records. Direct delegate calls do not prove Launch Services or Finder Open With delivery."
        if let failure { report["error"] = failure }
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("file-open-result.json"), options: .atomic)
    }
}
