import AppKit

@MainActor extension AppDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard usesAgent, !urls.isEmpty else { return }
        if checkDirectory != nil { fileOpenEvents.append(["urls": urls.map(\.absoluteString), "afterLaunch": applicationLaunched]) }
        pendingFileOpens.append(urls); importOpenedFiles()
    }
    func importOpenedFiles() {
        guard applicationLaunched, fileOpenJob == nil, !pendingFileOpens.isEmpty, !closing else { return }
        ensureAgent()
        guard let tasks = agentStore else { return }
        fileOpenJob = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { fileOpenJob = nil }
            while !pendingFileOpens.isEmpty, !closing, !Task.isCancelled {
                let urls = pendingFileOpens.removeFirst(), owner = control
                do {
                    try AgentAttachments.validateSources(urls)
                    guard !owner.isImportingAttachments, owner.window?.attachedSheet == nil else { throw PetError("请先完成当前对话框或附件导入，再重新打开文件") }
                    guard persistTaskDrafts() else { continue }
                    let title = urls[0].lastPathComponent + (urls.count == 1 ? "" : " 等 \(urls.count) 个文件")
                    let id = tasks.create(title: title, mode: .ask, workMode: .general)
                    if let error = tasks.writeError { throw PetError("任务未保存：" + error) }
                    owner.showAgentTask(id); owner.show(tab: "chat")
                    guard owner.agentTaskID == id else { throw PetError("未能切换到文件草稿，请重新打开文件") }
                    if let job = owner.beginAttachmentImport(urls, store: tasks, taskID: id) { await job.value }
                } catch { owner.show(tab: "chat"); owner.setStatus(error.localizedDescription, error: true) }
            }
        }
    }
}
