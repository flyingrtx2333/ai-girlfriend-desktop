import Foundation

struct AgentFileCapture: Codable {
    var id: String; var workspace: String; var turnID: String; var origin: String; var manifest: String
    var roots:[String]?
    var workspaces:[String] { roots ?? [workspace] }
}
struct AgentFileState: Codable, Equatable, Sendable {
    var kind: String; var hash: String?; var permissions: Int?
    static let missing = AgentFileState(kind: "missing")
    func matches(_ value: AgentFileState) -> Bool {
        kind == value.kind && hash == value.hash && (permissions == nil || permissions == value.permissions)
    }
}
struct AgentCapturedFile: Codable, Sendable {
    var state: AgentFileState; var signature: String; var backup: String?
    static let missing = AgentCapturedFile(state: .missing, signature: "missing")
    static func read(_ path: String, files: AgentFiles, backups: AgentFiles?, cached: Self? = nil) throws -> Self {
        let url = try files.literalURL(path), metadata = try files.entryMetadata(url)
        if let cached, metadata.signature == cached.signature { return cached }
        var value = Self(state: AgentFileState(kind: metadata.kind, permissions: metadata.permissions), signature: metadata.signature)
        switch metadata.kind {
        case "file":
            if let backups {
                let temporary = backups.root.appendingPathComponent(UUID().uuidString)
                let hash = try backups.copyFile(url, from: files, to: temporary)
                let stored = backups.root.appendingPathComponent(hash)
                if FileManager.default.fileExists(atPath: stored.path) {
                    if (try? backups.fileHash(stored)) != hash { try backups.copyFile(temporary, from: backups, to: stored, expectedHash: hash) }
                    try backups.remove(temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: stored) }
                value.state.hash = hash; value.backup = stored.path
            } else { value.state.hash = try files.fileHash(url) }
        case "link":
            let data = Data(try files.symbolicLink(url).utf8), hash = AgentFiles.hash(data); value.state.hash = hash
            if let backups {
                let stored = backups.root.appendingPathComponent(hash)
                if (try? backups.fileHash(stored)) != hash { try backups.writeData(data, to: stored, permissions: 0o600) }
                value.backup = stored.path
            }
        case "missing", "directory": break
        default: throw PetError("特殊文件不能纳入检查点：" + path)
        }
        guard try files.entryMetadata(url).signature == metadata.signature else { throw PetError("读取期间文件已变化：" + path) }
        return value
    }
}
extension AgentChange {
    var beforeState: AgentFileState { AgentFileState(kind: beforeKind ?? (existed ? "file" : "missing"), hash: beforeHash, permissions: permissions) }
    var afterState: AgentFileState? { (afterKind != nil || afterHash != nil) ? AgentFileState(kind: afterKind ?? "file", hash: afterHash, permissions: afterPermissions) : nil }
    var changeStatus: String { beforeState.kind == "missing" ? "A" : afterState?.kind == "missing" ? "D" : beforeState.kind != afterState?.kind ? "T" : "M" }
}

@MainActor final class AgentProjectChanges {
    private weak var store: AgentStore?
    private final class Observation {
        var capture: AgentFileCapture; var taskID: String; var overlaps = false
        init(_ capture: AgentFileCapture, taskID: String) { self.capture = capture; self.taskID = taskID }
    }
    private var active: [String: Observation] = [:]
    private var cache: [String: [String: AgentCapturedFile]] = [:]
    private var cacheRoots: [String: String] = [:]
    var onChange: ((String) -> Void)?
    init(store: AgentStore) { self.store = store }
    func isObserving(_ workspace: String) -> Bool { active.values.contains { $0.capture.workspaces.contains { AgentWorktreeRetention.within($0,workspace) || AgentWorktreeRetention.within(workspace,$0) } } }

    func observe(taskID: String, origin: String, paths: [String]? = nil, requireCheckpoint: Bool = false, operation: () async throws -> AgentToolResult) async throws -> AgentToolResult {
        guard let store, let task = store.task(taskID), let workspace = task.workspace else { return try await operation() }
        let roots = try AgentWorkspaceScope.roots(task).map(\.root.path)
        guard !roots.contains(where:{store.hasFileRollback(in:$0)}) else { throw PetError("此项目有未完成的文件撤回，请先恢复") }
        guard task.pendingFileCapture == nil, !active.values.contains(where: { $0.taskID == taskID }) else { throw PetError("此任务正在记录文件变更，请稍后重试") }
        func perform() async throws -> AgentToolResult {
            guard let current = store.task(taskID), current.workspace == task.workspace, current.workspaceScope == task.workspaceScope, current.mode == task.mode, current.permission == task.permission, current.agent?.profile.id == task.agent?.profile.id, !current.archived else { throw PetError("任务项目或权限已变化，操作未执行") }
            if let error = store.writeError { throw PetError("任务记录未保存，操作未执行：" + error) }
            try Task.checkCancellation(); return try await operation()
        }
        let files = try AgentFiles(workspace: workspace), turnID = task.messages.last(where: \.isHumanInput)?.id ?? task.id
        let scopeKey = roots.joined(separator:"\n")
        if cacheRoots[taskID] != scopeKey { cache[taskID] = nil; cacheRoots[taskID] = scopeKey }
        let folder = try store.backupDirectory(taskID).appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let capture = AgentFileCapture(id: id, workspace: files.root.path, turnID: turnID, origin: origin, manifest: folder.appendingPathComponent(id + ".json").path, roots:task.workspaceScope == nil ? nil : roots)
        let observation = Observation(capture, taskID: taskID)
        for other in active.values where other.capture.workspaces.contains(where:{a in roots.contains { AgentWorktreeRetention.within(a,$0) || AgentWorktreeRetention.within($0,a) }}) {
            observation.overlaps = true; other.overlaps = true
        }
        active[id] = observation
        defer {
            active[id] = nil
            while cache.count > 4, let oldest = cache.keys.first(where: { key in !active.values.contains { $0.taskID == key } }) { cache[oldest] = nil; cacheRoots[oldest] = nil }
        }
        let before: [String: AgentCapturedFile]
        do {
            before = try await snapshot(task: task, paths: paths, previous: cache[taskID] ?? [:])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(before), manifests = try AgentFiles(workspace: folder.path)
            try manifests.writeData(data, to: URL(fileURLWithPath: capture.manifest), permissions: 0o600)
            guard store.task(taskID)?.workspace == task.workspace, store.task(taskID)?.workspaceScope == task.workspaceScope, store.task(taskID)?.pendingFileCapture == nil else { throw PetError("项目或变更记录状态已变化，请重试") }
            store.update(taskID) { $0.pendingFileCapture = capture }; onChange?(taskID)
            if let error = store.writeError { throw PetError("执行前快照未保存：" + error) }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if requireCheckpoint {
                let message = "未能建立保存前检查点，文件未修改：" + error.localizedDescription
                warn(message, taskID: taskID, turnID: turnID)
                throw PetError(message)
            }
            var result = try await perform()
            let warning = "未建立完整的执行前检查点：" + error.localizedDescription + "。请在“未提交”中核对实际内容。"
            warn(warning, taskID: taskID, turnID: turnID); result.text += "\n" + warning
            return result
        }
        let outcome: Result<AgentToolResult, Error>
        do { outcome = .success(try await perform()) } catch { outcome = .failure(error) }
        // An actual command may have written files before failing or being stopped.
        // Finish this readback even when the caller has been cancelled.
        let finishing = Task { @MainActor in
            do {
                let after = try await self.snapshot(task: task, paths: paths, previous: before)
                guard store.task(taskID)?.workspace == task.workspace, store.task(taskID)?.workspaceScope == task.workspaceScope, store.task(taskID)?.pendingFileCapture?.id == id else { throw PetError("原项目已变化，执行前快照仍保留") }
                var changes: [AgentChange] = []
                for path in Set(before.keys).union(after.keys).sorted() {
                    let old = before[path] ?? .missing, new = after[path] ?? .missing
                    guard old.state != new.state else { continue }
                    changes.append(AgentChange(path: path, existed: old.state.kind != "missing", backup: old.backup, beforeHash: old.state.hash, afterHash: new.state.hash, permissions: old.state.permissions, beforeKind: old.state.kind, afterKind: new.state.kind, afterPermissions: new.state.permissions, origin: origin, reviewOnly: observation.overlaps))
                }
                self.cache[taskID, default: [:]].merge(after) { _, current in current }
                AgentChanges.record(changes, taskID: taskID, turnID: turnID, store: store)
                store.update(taskID) {
                    $0.pendingFileCapture = nil
                    if !changes.isEmpty { $0.events.append(AgentEvent(kind: "change", title: "已记录 \(changes.count) 个文件变更", detail: origin + (observation.overlaps ? " · 同时有其他任务操作此项目，请审阅实际文件，不自动撤回。" : ""), status: "completed")) }
                }
                if let error = store.writeError { throw PetError("执行后的变更记录未保存：" + error) }
                self.onChange?(taskID)
                return changes.count
            } catch {
                self.warn("执行后的变更记录未完成：" + error.localizedDescription + "。请在“未提交”中核对实际内容。", taskID: taskID, turnID: turnID)
                return -1
            }
        }
        let count = await finishing.value
        switch outcome {
        case .success(var result):
            if count < 0 { result.text += "\n执行已结束，变更记录未完成；请查看任务日志并核对未提交修改。" }
            else if count > 0 { result.text += "\n已记录 \(count) 个实际文件变更，可在本轮修改中审阅。" }
            return result
        case .failure(let error): throw error
        }
    }
    private func warn(_ message: String, taskID: String, turnID: String) {
        store?.update(taskID) {
            AgentChanges.warn(message, turnID: turnID, record: &$0); $0.pendingFileCapture = nil
            $0.events.append(AgentEvent(kind: "change", title: "变更记录未完成", detail: message, status: "failed"))
        }
        onChange?(taskID)
    }
    private func snapshot(task: AgentTaskRecord, paths: [String]?, previous: [String: AgentCapturedFile]) async throws -> [String: AgentCapturedFile] {
        let locations = try paths?.map { try AgentWorkspaceScope.location(task,path:$0,literal:true) }
        var values:[String:AgentCapturedFile] = [:]
        for files in try AgentWorkspaceScope.roots(task) {
            let selected = locations.map { $0.filter{$0.0.root == files.root}.map{$0.1.path} }
            let cached = previous.filter { $0.key.hasPrefix(files.root.path + "/") }
            let snapshot = try await snapshotRoot(task:task,files:files,paths:selected,previous:cached)
            values.merge(snapshot) { _,new in new }
        }
        return values
    }
    private func snapshotRoot(task:AgentTaskRecord, files:AgentFiles, paths:[String]?, previous:[String:AgentCapturedFile]) async throws -> [String:AgentCapturedFile] {
        guard let store else { throw PetError("任务存储不可用") }
        let backupDirectory = try store.backupDirectory(task.id).appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backups = try AgentFiles(workspace: backupDirectory.path)
        var candidates = paths
        if paths == nil, files.root.path == task.workspace, let metadata = try? AgentGit.metadata(workspace: task.workspace) {
            guard AgentWorktreeRetention.within(metadata.path, files.root.path) || task.gitDirectory == metadata.path else { throw PetError("请先连接此项目的共享 Git 元数据") }
            candidates = try await AgentGit(store: store, taskID: task.id, directory: metadata).filePaths().map { try files.literalURL($0).path }
        }
        let privateRoot = store.directory.deletingLastPathComponent().path, bundle = Bundle.main.bundleURL.path
        let known = candidates.map { Set($0).union(paths == nil ? Array(previous.keys) : []) }
        let scan = Task.detached(priority: .utility) {
            var names = known ?? []
            if known == nil {
                let skip = Set([".git", "node_modules", ".build", "build", "dist", ".next", ".venv", "vendor"])
                var failure: Error?
                guard let walk = FileManager.default.enumerator(at: files.root, includingPropertiesForKeys: nil, errorHandler: { _, error in failure = error; return false }) else { throw PetError("项目目录不可读取") }
                while let url = walk.nextObject() as? URL {
                    try Task.checkCancellation()
                    let relative = String(url.path.dropFirst(files.root.path.count + 1))
                    if skip.contains(url.lastPathComponent) || AgentFiles.sensitive(relative) || url.path == privateRoot || url.path.hasPrefix(privateRoot + "/") || url.path == bundle || url.path.hasPrefix(bundle + "/") || relative.hasPrefix(".bluefatfish/worktrees/") { walk.skipDescendants(); continue }
                    let entry = try files.entryMetadata(files.literalURL(url.path))
                    if entry.kind != "directory" { names.insert(try files.literalURL(url.path).path) }
                }
                if let failure { throw failure }; names.formUnion(previous.keys)
            }
            var values: [String: AgentCapturedFile] = [:]
            for name in names.sorted() {
                try Task.checkCancellation()
                let url = try files.literalURL(name), relative = String(url.path.dropFirst(files.root.path.count + 1))
                if paths == nil && (AgentFiles.sensitive(relative) || url.path == privateRoot || url.path.hasPrefix(privateRoot + "/") || url.path == bundle || url.path.hasPrefix(bundle + "/") || relative.hasPrefix(".bluefatfish/worktrees/")) { continue }
                values[url.path] = try AgentCapturedFile.read(url.path, files: files, backups: backups, cached: previous[url.path])
            }
            return values
        }
        return try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    }
}
