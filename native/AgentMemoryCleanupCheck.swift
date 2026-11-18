import AppKit

@MainActor extension AppDelegate {
    func runMemoryCleanupCheck(_ output: URL) {
        var checks: [String: Bool] = [:]
        var errorText: String?
        do { checks = try checkMemoryCleanup(output) }
        catch { errorText = error.localizedDescription }
        var report: [String: Any] = [
            "success": errorText == nil && !checks.isEmpty && checks.values.allSatisfy { $0 },
            "checks": checks, "modelRequests": 0, "appPID": getpid()
        ]
        report["error"] = errorText
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent("memory-cleanup-report.json"), options: .atomic)
    }

    private func checkMemoryCleanup(_ output: URL) throws -> [String: Bool] {
        let fm = FileManager.default, trash = output.appendingPathComponent("Fixture Trash")
        let profile = output.appendingPathComponent("profile"), shared = output.appendingPathComponent("shared-home")
        let tasks = AgentStore(directory: profile, legacy: [], extensionHome: shared)
        let alpha = output.appendingPathComponent("Alpha"), secondary = output.appendingPathComponent("Secondary")
        let beta = output.appendingPathComponent("Beta"), locked = output.appendingPathComponent("Locked")
        let external = output.appendingPathComponent("Outside scope"), redirected = output.appendingPathComponent("Redirected")
        for folder in [alpha, secondary, beta, locked, external, redirected, trash] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for folder in [beta, locked, redirected] { try tasks.organization.register(folder.path, mode: .coding) }
        let taskID = tasks.create(title: "原记忆任务", workspaceScope: AgentWorkspaceScope(group: alpha.path, folders: [alpha.path, secondary.path], primary: alpha.path))
        tasks.update(taskID) { $0.contextSummary = "公开任务摘要"; $0.draft = "原有输入" }
        let persistedTask = tasks.directory.appendingPathComponent(taskID + ".json")
        let taskBytes = try Data(contentsOf: persistedTask)
        func put(_ url: URL, _ text: String, mode: Int = 0o640) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        let main = alpha.appendingPathComponent(".bluefatfish/memory.md"), topic = alpha.appendingPathComponent(".bluefatfish/memory/约定.md")
        let second = secondary.appendingPathComponent(".bluefatfish/memory/主题.md")
        let global = tasks.directory.appendingPathComponent("memory.md"), globalTopic = tasks.directory.appendingPathComponent("memory/全局主题.md")
        let betaMain = beta.appendingPathComponent(".bluefatfish/memory.md"), betaTopic = beta.appendingPathComponent(".bluefatfish/memory/Beta.md")
        let readonly = locked.appendingPathComponent(".bluefatfish/memory.md"), outside = external.appendingPathComponent("memory.md")
        for file in [main, topic, second, global, globalTopic, betaMain, betaTopic, outside] { try put(file, "公开记忆 · " + file.lastPathComponent) }
        try put(readonly, "只读公开记忆", mode: 0o440)
        let keep = [alpha.appendingPathComponent("AGENTS.md"), alpha.appendingPathComponent(".bluefatfish/memory/resource.txt"),
                    tasks.directory.appendingPathComponent("memory-backups/prior.md"), shared.appendingPathComponent(".qoder/memory/source.md")]
        for file in keep { try put(file, "保留的公开资料") }
        let link = alpha.appendingPathComponent(".bluefatfish/memory/链接.md")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        try fm.createSymbolicLink(at: redirected.appendingPathComponent(".bluefatfish"), withDestinationURL: external)
        var moved: [URL: URL] = [:]
        func fixtureMove(_ source: URL) throws {
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try fm.moveItem(at: source, to: destination)
            moved[source] = destination
        }
        func locate<T: NSView>(_ view: NSView, _ id: String, as type: T.Type) -> T? {
            if let match = view as? T, view.identifier?.rawValue == id || view.accessibilityIdentifier() == id { return match }
            return view.subviews.lazy.compactMap { locate($0, id, as: type) }.first
        }
        func rejects(_ block: () throws -> Void) -> Bool {
            do { try block(); return false } catch { return true }
        }

        var checks: [String: Bool] = [:]
        let alphaPlan = try AgentMemoryCleanup.preview(workspace: alpha.path, store: tasks)
        checks["previewIncludesBothActiveMemoryPaths"] = alphaPlan.entries.map(\.path) == [".bluefatfish/memory.md", ".bluefatfish/memory/约定.md"]
        checks["readonlyAndRedirectedScopesAreNotSelectable"] = rejects { _ = try AgentMemoryCleanup.preview(workspace: locked.path, store: tasks) }
            && rejects { _ = try AgentMemoryCleanup.preview(workspace: redirected.path, store: tasks) }
        checks["unregisteredFolderCannotBeCleared"] = rejects { _ = try AgentMemoryCleanup.preview(workspace: external.path, store: tasks) }

        let settings = AgentMemorySettingsPage(store: tasks, taskID: taskID, workspace: alpha.path, service: AgentGeneralSettings(directory: profile))
        var child: AgentSettingsPageController?
        settings.onSettingsPush = { child = $0 }
        guard let settingsView = settings.pageContentView, let search = locate(settingsView, "memory-project-search", as: NSSearchField.self),
              let searchAction = search.action else { throw PetError("缺少项目记忆入口") }
        search.stringValue = "Secondary"; search.sendAction(searchAction, to: search.target)
        locate(settingsView, "memory-clear-projects", as: NSButton.self)?.performClick(nil)
        func table(in view: NSView) -> NSTableView? { (view as? NSTableView) ?? view.subviews.lazy.compactMap { table(in: $0) }.first }
        checks["cleanupEntryUsesOnlyVisibleProjectSearchResults"] = child is AgentMemoryCleanupPage && child?.pageContentView.flatMap { table(in: $0)?.numberOfRows } == 1
        child?.window?.close(); settings.window?.close()

        let sources = AgentMemory.projects(store: tasks, preferredTaskID: taskID).filter { [alpha.path, secondary.path, locked.path].contains($0.workspace) }
        var selectedRoots: [String] = []
        let page = AgentMemoryCleanupPage(store: tasks, projects: sources) { previews in
            selectedRoots = previews.compactMap(\.workspace)
            return try AgentMemoryCleanup.apply(previews, store: tasks, moveToTrash: fixtureMove)
        }
        guard let content = page.pageContentView, let select = locate(content, "memory-cleanup-select-all", as: NSButton.self),
              let confirm = locate(content, "memory-cleanup-trash", as: NSButton.self) else { throw PetError("缺少实际记忆清理控件") }
        checks["projectCleanupRequiresExplicitSelection"] = !confirm.isEnabled
        select.performClick(nil); confirm.performClick(nil)
        checks["actualReviewMovesOnlySelectedAvailableProjects"] = Set(selectedRoots) == [alpha.path, secondary.path] && moved.count == 3
            && [main, topic, second].allSatisfy { !fm.fileExists(atPath: $0.path) }
        checks["clearedProjectStopsPresentingMemoryAndTopics"] = try AgentMemory.catalog(.project, store: tasks, taskID: taskID, workspace: alpha.path).count == 0
            && AgentMemory.catalog(.project, store: tasks, taskID: taskID, workspace: secondary.path).count == 0
        checks["otherProjectGlobalAndReadonlyMemoryStillExist"] = [betaMain, global, globalTopic, readonly, outside].allSatisfy { fm.fileExists(atPath: $0.path) }
        checks["linksInstructionsBackupsAndTaskDataStayIntact"] = try keep.allSatisfy { String(decoding: try Data(contentsOf: $0), as: UTF8.self) == "保留的公开资料" }
            && fm.destinationOfSymbolicLink(atPath: link.path) == outside.path && Data(contentsOf: persistedTask) == taskBytes
        page.window?.close()

        let globalPage = AgentMemoryCleanupPage(store: tasks, projects: nil) {
            try AgentMemoryCleanup.apply($0, store: tasks, moveToTrash: fixtureMove)
        }
        guard let globalView = globalPage.pageContentView, let clear = locate(globalView, "memory-cleanup-trash", as: NSButton.self),
              let recheck = locate(globalView, "memory-cleanup-recheck", as: NSButton.self) else { throw PetError("缺少全局清理控件") }
        let added = tasks.directory.appendingPathComponent("memory/后来.md")
        try put(added, "预览后新增")
        clear.performClick(nil)
        checks["staleGlobalPreviewLeavesOriginalFilesAndOffersRecheck"] = !clear.isEnabled && !recheck.isHidden
            && [global, globalTopic, added].allSatisfy { fm.fileExists(atPath: $0.path) }
        recheck.performClick(nil); clear.performClick(nil)
        checks["recheckedGlobalCleanupIncludesMainAndAllTopics"] = moved.count == 6 && [global, globalTopic, added].allSatisfy { !fm.fileExists(atPath: $0.path) }
        globalPage.window?.close()

        let betaPlan = try AgentMemoryCleanup.preview(workspace: beta.path, store: tasks)
        let partial = try AgentMemoryCleanup.apply([betaPlan], store: tasks) { source in
            if source == betaMain { try fixtureMove(source); try put(betaTopic, "批处理中更新") }
            else { try fixtureMove(source) }
        }
        let changedTopic = try Data(contentsOf: betaTopic)
        checks["partialOutcomeRetainsFileChangedMidBatch"] = partial.moved == 1 && partial.failures.count == 1
            && String(decoding: changedTopic, as: UTF8.self) == "批处理中更新"
        guard let backup = moved[topic] else { throw PetError("样例废纸篓未保存原文件") }
        try fm.moveItem(at: backup, to: topic)
        let restored = try AgentMemory.snapshot(.project, store: tasks, taskID: taskID, workspace: alpha.path, topic: "约定.md")
        let permissions = try fm.attributesOfItem(atPath: topic.path)[.posixPermissions] as? NSNumber
        checks["restoredMemoryKeepsOriginalBytesAndMode"] = restored.content == "公开记忆 · 约定.md" && permissions?.intValue == 0o640
        return checks
    }
}
