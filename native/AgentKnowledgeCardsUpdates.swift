import Foundation
import CoreServices

private final class AgentKnowledgeCardEventBox {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
}
final class AgentKnowledgeCardWatcher {
    let paths: [String]
    private var stream: FSEventStreamRef?
    init(paths: [String], callback: @escaping () -> Void) throws {
        self.paths = paths
        let info = Unmanaged.passRetained(AgentKnowledgeCardEventBox(callback)).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: { info in
            if let info { Unmanaged<AgentKnowledgeCardEventBox>.fromOpaque(info).release() }
        }, copyDescription: nil)
        guard let value = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }; Unmanaged<AgentKnowledgeCardEventBox>.fromOpaque(info).takeUnretainedValue().callback()
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else {
            Unmanaged<AgentKnowledgeCardEventBox>.fromOpaque(info).release(); throw PetError("无法观察工作区变化")
        }
        stream = value; FSEventStreamSetDispatchQueue(value, .main)
        guard FSEventStreamStart(value) else { FSEventStreamInvalidate(value); FSEventStreamRelease(value); stream = nil; throw PetError("工作区变化观察未启动") }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}

@MainActor extension AgentKnowledgeCards {
    func resume() {
        guard let value = try? settings().0 else { return }
        for (root, options) in value.projects where options.autoUpdate { activate(workspace: root) }
    }
    func stop() {
        for task in updates.values { task.cancel() }; updates.removeAll(); watchers.removeAll()
    }
    func activate(workspace: String) {
        do {
            let root = try AgentFiles(workspace: workspace).root.path, options = try options(workspace: root)
            guard runtime != nil, options.autoUpdate else { updates[root]?.cancel(); updates[root] = nil; watchers[root] = nil; return }
            guard let store, let sourceID = options.sourceTaskID, let source = store.task(sourceID), !source.archived,
                  source.workspace.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) == root else { throw PetError("请打开此工作区的任务后重新启用自动更新") }
            guard try Self.identity(root) == options.rootIdentity else { throw PetError("工作区目录已替换，请重新启用自动更新") }
            _ = try scope(source)
            var paths = [root]
            let files = try AgentFiles(workspace: root), entry = try files.resolve(".git")
            if FileManager.default.fileExists(atPath: entry.path), (try entry.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true {
                let text = String(decoding: try files.readData(entry, maximum: 8192), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("gitdir: ") { paths.append(URL(fileURLWithPath: String(text.dropFirst(8)), relativeTo: files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path) }
            }
            if watchers[root]?.paths != paths {
                watchers[root] = try AgentKnowledgeCardWatcher(paths: paths) { [weak self] in Task { @MainActor in self?.changed(workspace: root) } }
            }
            changed(workspace: root)
        } catch { notices[workspace] = error.localizedDescription; watchers[workspace] = nil; onChange?(workspace) }
    }
    func changed(workspace: String) {
        updates[workspace]?.cancel()
        updates[workspace] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000); try Task.checkCancellation(); await self?.updateIfNeeded(workspace) }
            catch { }
        }
    }
    private func updateIfNeeded(_ root: String) async {
        do {
            guard let store, runtime != nil else { return }
            let options = try options(workspace: root)
            guard options.autoUpdate, try Self.identity(root) == options.rootIdentity,
                  let id = options.sourceTaskID, let task = store.task(id), !task.archived else { return }
            let scope = try scope(task)
            guard !store.tasks.contains(where: { $0.kind == Self.kind && $0.workspace == task.workspace && $0.knowledgeJob?.branch == scope.branch && $0.knowledgeJob?.language == options.language && ( [.ready, .running, .waiting].contains($0.status) || finalizing.contains($0.id)) && !$0.archived }) else { return }
            let result = try await refreshIndex(task); try Task.checkCancellation()
            let previous = try book(task, language: options.language).0
            if let previous, previous.sourceRevision == result.index.revision, previous.cards.allSatisfy({ fresh($0, workspace: root) }) { return }
            let key = root + "\n" + scope.branch + "\n" + options.language
            guard lastAttempt[key] != result.index.revision else { return }
            if store.tasks.contains(where: { $0.kind == Self.kind && $0.workspace == root && $0.knowledgeJob?.branch == scope.branch && $0.knowledgeJob?.language == options.language && $0.knowledgeJob?.sourceRevision == result.index.revision && [.failed, .stopped].contains($0.status) }) { notices[root] = "上次生成未完成，请查看任务后手动重试"; onChange?(root); return }
            if previous?.cards.contains(where: \.manual) == true { notices[root] = "源码有变化；存在用户编辑，请审阅后重新生成"; onChange?(root); return }
            lastAttempt[key] = result.index.revision
            _ = try await generate(sourceID: id, language: options.language, focus: previous?.focus ?? "", automatic: true)
        } catch {
            if !Task.isCancelled { notices[root] = "自动更新未完成：" + error.localizedDescription; onChange?(root) }
        }
    }
}
