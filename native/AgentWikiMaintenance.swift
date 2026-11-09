import Foundation

struct AgentWikiMaintenanceOptions: Codable {
    var autoUpdate = false, autoExport = false
    var sourceTaskID: String?, rootIdentity: String?
}

@MainActor extension AgentWiki {
    static func maintenance(store: AgentStore, workspace: String, language: String) throws -> (options: AgentWikiMaintenanceOptions, signature: String, workspace: String) {
        guard ["zh", "en"].contains(language) else { throw PetError("请选择当前 Wiki 语言") }
        let root = try AgentFiles(workspace: workspace).root.path, (value, signature) = try citationSettings(store)
        return (value.maintenance?[root]?[language] ?? AgentWikiMaintenanceOptions(), signature, root)
    }
    static func setMaintenance(store: AgentStore, sourceID: String, language: String, options: AgentWikiMaintenanceOptions, expected: String) throws {
        guard ["zh", "en"].contains(language), let source = store.task(sourceID), !source.archived, source.kind != "hook", try !store.agents.limits(source, store: store).readOnly else { throw PetError("请选择可写项目任务") }
        let root = try AgentFiles(workspace: source.workspace).root.path, directory = try citationDirectory(store)
        var saved = options
        if saved.autoUpdate { _ = try updateGit(store: store, taskID: sourceID); saved.sourceTaskID = sourceID; saved.rootIdentity = try AgentKnowledgeCards.identity(root) }
        try store.knowledgeCards.locked(directory, label: "Wiki 自动维护设置") {
            var (value, signature) = try citationSettings(store); guard signature == expected else { throw PetError("Wiki 设置已变化，请刷新后重试") }
            var projects = value.maintenance ?? [:], languages = projects[root] ?? [:]; languages[language] = saved; projects[root] = languages; value.maintenance = projects
            guard Set(value.projects.keys).union(projects.keys).count <= 500 else { throw PetError("Wiki 工作区设置已达上限") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; let data = try encoder.encode(value)
            guard data.count <= 1_000_000 else { throw PetError("Wiki 设置超过1MB") }
            try AgentFiles(workspace: directory.path).writeData(data, to: directory.appendingPathComponent("settings.json"), permissions: 0o600)
        }
        store.wikiMaintenance.activate(workspace: root)
    }
}

@MainActor final class AgentWikiMaintenance {
    private weak var store: AgentStore?
    weak var runtime: AgentRuntime?
    var onChange: ((String) -> Void)?
    private var watchers: [String: AgentKnowledgeCardWatcher] = [:]
    private var updates: [String: Task<Void, Never>] = [:]
    private var lastAttempt: [String: String] = [:]
    private var exporting = Set<String>()
    private(set) var notices: [String: String] = [:]
    init(store: AgentStore) { self.store = store }
    func resume() {
        guard let store, let settings = try? AgentWiki.citationSettings(store).0 else { return }
        for (root, languages) in settings.maintenance ?? [:] where languages.values.contains(where: \.autoUpdate) { activate(workspace: root) }
    }
    func stop() { for update in updates.values { update.cancel() }; updates.removeAll(); watchers.removeAll() }
    func activate(workspace: String) {
        do {
            guard let store, runtime != nil else { return }
            let root = try AgentFiles(workspace: workspace).root.path, settings = try AgentWiki.citationSettings(store).0
            guard settings.maintenance?[root]?.values.contains(where: \.autoUpdate) == true else { updates[root]?.cancel(); updates[root] = nil; watchers[root] = nil; notices = notices.filter { $0.key != root && !$0.key.hasPrefix(root + "\n") }; onChange?(root); return }
            let files = try AgentFiles(workspace: root), entry = try files.resolve(".git"); var paths = [root]
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                let text = String(decoding: try files.readData(entry, maximum: 8192), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("gitdir: ") else { throw PetError("Git 工作树元数据无效") }
                paths.append(URL(fileURLWithPath: String(text.dropFirst(8)), relativeTo: files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path)
            }
            if watchers[root]?.paths != paths { watchers[root] = try AgentKnowledgeCardWatcher(paths: paths) { [weak self] in Task { @MainActor in self?.changed(workspace: root) } } }
            changed(workspace: root)
        } catch { watchers[workspace] = nil; notices[workspace] = error.localizedDescription; onChange?(workspace) }
    }
    func changed(workspace: String) {
        updates[workspace]?.cancel()
        updates[workspace] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000); try Task.checkCancellation(); await self?.updateIfNeeded(workspace: workspace) } catch { }
        }
    }
    func updateIfNeeded(workspace: String) async {
        guard let store, let runtime else { return }
        do {
            let settings = try AgentWiki.citationSettings(store).0
            for (language, options) in settings.maintenance?[workspace] ?? [:] where options.autoUpdate {
                let noticeKey = workspace + "\n" + language
                do {
                try Task.checkCancellation()
                guard let sourceID = options.sourceTaskID, let source = store.task(sourceID), !source.archived, try AgentFiles(workspace: source.workspace).root.path == workspace,
                      try AgentKnowledgeCards.identity(workspace) == options.rootIdentity, try !store.agents.limits(source, store: store).readOnly else { throw PetError("项目或任务范围已变化，请重新启用自动更新") }
                let state = try AgentWiki.generationState(store: store, runtime: runtime, sourceID: sourceID, language: language)
                if ["pause", "publishing"].contains(state.action) { continue }
                guard let published = try AgentWiki.plannedManifest(store: store, taskID: sourceID, language: language), published.sourceCommit != nil else { notices[noticeKey] = "请先生成此语言 Wiki，建立 Git 提交基线"; continue }
                let head = try await AgentWiki.cleanCommit(store: store, taskID: sourceID), scope = try store.knowledgeCards.scope(source), key = workspace + "\n" + scope.branch + "\n" + language
                if head == published.sourceCommit { notices[noticeKey] = nil; continue }
                if store.tasks.contains(where: { $0.kind == "wiki" && $0.workspace == workspace && $0.wikiJob?.branch == scope.branch && $0.wikiJob?.language == language && $0.wikiJob?.update?.commit == head && [.stopped, .failed].contains($0.status) && !$0.archived }) { notices[noticeKey] = "此提交的更新已暂停或失败，请在原任务中检查后继续"; continue }
                if lastAttempt[key] == head { continue }
                if try AgentWiki.status(store: store, taskID: sourceID, language: language) == "已编辑" { notices[noticeKey] = "Wiki 包含人工修改，请审阅后手动增量更新"; continue }
                lastAttempt[key] = head
                let preview = try await AgentWiki.previewUpdate(store: store, runtime: runtime, sourceID: sourceID, language: language)
                try Task.checkCancellation()
                let current = try AgentWiki.maintenance(store: store, workspace: workspace, language: language).options
                guard current.autoUpdate, current.sourceTaskID == sourceID, current.rootIdentity == options.rootIdentity else { continue }
                _ = try await AgentWiki.startUpdate(preview, store: store, runtime: runtime, sourceID: sourceID); notices[noticeKey] = "已开始自动增量更新"
                } catch { if Task.isCancelled { return }; notices[noticeKey] = error.localizedDescription }
            }
        } catch { if !Task.isCancelled { notices[workspace] = error.localizedDescription } }
        if !Task.isCancelled { onChange?(workspace) }
    }
    func published(taskID: String, language: String, expectedID: String) async {
        guard let store, let task = store.task(taskID), let root = task.workspace else { return }
        let key = root + "\n" + language
        guard exporting.insert(key).inserted else { return }; defer { exporting.remove(key) }
        do {
            guard try AgentWiki.maintenance(store: store, workspace: root, language: language).options.autoExport else { changed(workspace: root); return }
            guard try AgentWiki.plannedManifest(store: store, taskID: taskID, language: language)?.taskID == expectedID else { throw PetError("Wiki 发布版本已变化，未自动导出") }
            let count = try await AgentWiki.exportWiki(store: store, taskID: taskID, language: language)
            notices[key] = "已自动导出 \(count) 页 Wiki"; store.update(taskID) { $0.events.append(AgentEvent(kind: "wiki", title: "Wiki 已自动导出", detail: "\(count) 页 · \(language)", status: "completed")) }
        } catch { notices[key] = "Wiki 已发布，自动导出未完成：" + error.localizedDescription; store.update(taskID) { $0.events.append(AgentEvent(kind: "wiki", title: "自动导出未完成", detail: error.localizedDescription, status: "failed")) } }
        onChange?(root); changed(workspace: root)
    }
    func notice(workspace: String, language: String) -> String { notices[workspace + "\n" + language] ?? notices[workspace] ?? "" }
    var checkState: [String: Any] { guard CommandLine.arguments.contains("--wiki-updates-check") else { return [:] }; return ["watching": watchers.keys.sorted(), "lastAttempt": lastAttempt, "notices": notices] }
}
