import Foundation
import CryptoKit
import Darwin

struct AgentWorktreeOrigin: Codable { var root: String; var metadata: String; var path: String }
struct AgentWorktreeEntry: Codable {
    static let tools = ["git_worktrees", "git_prepare_worktree_recycle", "git_recycle_worktree", "git_restore_worktree"]
    var path: String; var head: String?; var branch: String?; var locked: String?; var prunable: String?
    var bare = false; var owned = false; var taskIDs: [String] = []; var unavailable: String?
}
struct AgentWorktreeBackup: Codable {
    var id: String; var origin: AgentWorktreeOrigin; var head: String; var branch: String?
    var treeHash: String; var indexHash: String; var created = Date(); var tasks: [String: Bool]
    var state = "prepared"; var restoredBranch: String?
    var objectRefs: [String]?; var indexTree: String?
}
struct AgentWorktreeRecycleReview: Codable {
    static let processID = UUID().uuidString
    var taskID: String; var processID = Self.processID; var path: String; var hash: String
    var fingerprint: String; var head: String; var branch: String?; var files: Int; var bytes: UInt64
    var taskIDs: [String]; var created = Date()
}

enum AgentWorktreeSnapshot {
    struct Item: Codable { var path: String; var kind: String; var mode: UInt16; var hash: String }
    struct Value { var hash: String; var count: Int; var bytes: UInt64; var modified: Date }
    static func read(_ root: URL) throws -> Value {
        let fm = FileManager.default
        guard let resolved = realpath(root.path, nil) else { throw PetError("工作树目录不可用") }
        let physicalPath = String(cString: resolved); free(resolved)
        let physicalRoot = URL(fileURLWithPath: physicalPath, isDirectory: true)
        var enumerationError: Error?
        guard let walk = fm.enumerator(at: physicalRoot, includingPropertiesForKeys: nil, errorHandler: { _, error in enumerationError = error; return false }) else { throw PetError("不能读取工作树") }
        var items: [Item] = [], bytes: UInt64 = 0
        var modified = (try fm.attributesOfItem(atPath: physicalRoot.path)[.modificationDate] as? Date) ?? .distantPast
        for case let file as URL in walk {
            try Task.checkCancellation()
            guard file.path.hasPrefix(physicalPath + "/") else { throw PetError("工作树目录枚举越界") }
            let path = String(file.path.dropFirst(physicalPath.count + 1))
            if path == ".git" { walk.skipDescendants(); continue }
            guard file.lastPathComponent != ".git" else { throw PetError("工作树包含子仓库，请先在本地 Git 处理：" + path) }
            let attributes = try fm.attributesOfItem(atPath: file.path), type = attributes[.type] as? FileAttributeType
            modified = max(modified, attributes[.modificationDate] as? Date ?? .distantPast)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            let kind: String, digest: String
            if type == .typeSymbolicLink { kind = "link"; digest = try fm.destinationOfSymbolicLink(atPath: file.path) }
            else if type == .typeDirectory { kind = "directory"; digest = "" }
            else if type == .typeRegular {
                kind = "file"; let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var sha = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); sha.update(data: data); bytes += UInt64(data.count) }
                digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
            } else { throw PetError("不能备份特殊文件，工作树未回收：" + path) }
            items.append(Item(path: path, kind: kind, mode: mode, hash: digest))
        }
        if let enumerationError { throw enumerationError }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Value(hash: AgentFiles.hash(try encoder.encode(items.sorted { $0.path < $1.path })), count: items.count, bytes: bytes, modified: modified)
    }
}

@MainActor extension AgentGit {
    private var worktreeReviewName: String { "review-" + taskID + (worktreeEligibilityCheck == nil ? "" : "-automatic") + ".json" }
    private func validateWorktreeEligibility(_ entry: AgentWorktreeEntry, tree: AgentWorktreeSnapshot.Value, metadata: URL) throws {
        if let check = worktreeEligibilityCheck {
            let indexModified = try FileManager.default.attributesOfItem(atPath: metadata.appendingPathComponent("index").path)[.modificationDate] as? Date ?? .distantPast
            try check(entry, max(tree.modified, indexModified))
        }
    }
    private var worktreeStorage: URL { store.directory.appendingPathComponent("worktrees", isDirectory: true) }
    private func worktreeFile(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: worktreeStorage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try AgentFiles(workspace: worktreeStorage.path).resolve(name)
    }
    private func saveWorktree<T: Encodable>(_ value: T, _ file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    func worktrees() async throws -> [AgentWorktreeEntry] {
        try validateWorkspace()
        let raw = try await output(["worktree", "list", "--porcelain", "-z"])
        var entries: [AgentWorktreeEntry] = [], item: AgentWorktreeEntry?
        for field in raw.components(separatedBy: "\0") {
            if field.isEmpty { if let value = item { entries.append(value); item = nil }; continue }
            let pair = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false), key = String(pair[0]), value = pair.count == 2 ? String(pair[1]) : ""
            if key == "worktree" { guard item == nil else { throw PetError("工作树列表格式无效") }; item = AgentWorktreeEntry(path: value) }
            else if key == "HEAD" { item?.head = value }
            else if key == "branch" { item?.branch = value }
            else if key == "locked" { item?.locked = value }
            else if key == "prunable" { item?.prunable = value }
            else if key == "bare" { item?.bare = true }
        }
        if let value = item { entries.append(value) }
        let archivedPaths = try worktreeBackups().map { canonical($0.origin.path) }
        let knownOrigins = store.tasks.compactMap { $0.worktreeOrigin.map { canonical($0.path) } }
        let registeredPaths = entries.map { canonical($0.path) } + knownOrigins + archivedPaths
        for i in entries.indices {
            let path = canonical(entries[i].path)
            entries[i].path = path
            let related = store.tasks.filter { task in
                guard let workspace = task.workspace.map(canonical), workspace == path || workspace.hasPrefix(path + "/") else { return false }
                return !registeredPaths.contains { other in other != path && other.hasPrefix(path + "/") && (workspace == other || workspace.hasPrefix(other + "/")) }
            }
            entries[i].taskIDs = related.map(\.id).sorted()
            entries[i].owned = store.tasks.contains { task in
                if let origin = task.worktreeOrigin { return canonical(origin.root) == files.root.path && canonical(origin.metadata) == canonical(directory.path) && canonical(origin.path) == path }
                // Earlier releases recorded native creation in the task history.
                guard task.parentID != nil, canonical(task.gitDirectory ?? "") == canonical(directory.path), path.hasPrefix(files.root.path + "/.bluefatfish/worktrees/"), UUID(uuidString: URL(fileURLWithPath: path).lastPathComponent) != nil else { return false }
                return store.task(task.id)?.events.contains { $0.kind == "git" && $0.title == "已创建工作树" && $0.detail.hasSuffix("\n" + path) } == true
            }
            if path == files.root.path { entries[i].unavailable = "当前工作树" }
            else if !entries[i].owned { entries[i].unavailable = "外部工作树" }
            else if entries[i].locked != nil { entries[i].unavailable = "工作树已锁定" }
            else if entries[i].prunable != nil || !FileManager.default.fileExists(atPath: path) { entries[i].unavailable = "路径不可用，请先在本地 Git 修复" }
            else if related.contains(where: { [.running, .waiting].contains($0.status) || store.hooks.isRunning($0.id) }) { entries[i].unavailable = "关联任务正在运行或等待处理" }
        }
        return entries
    }
    private func recyclable(_ requested: String) async throws -> AgentWorktreeEntry {
        try validateWorkspace()
        let path = canonical(requested)
        guard let entry = try await worktrees().first(where: { $0.path == path }), entry.unavailable == nil, let head = entry.head, !head.isEmpty else { throw PetError("工作树不可回收，请刷新并处理关联任务或锁定状态") }
        let relative = String(path.dropFirst(files.root.path.count + 1)), lexical = files.root.appendingPathComponent(relative).standardizedFileURL
        guard path.hasPrefix(files.root.path + "/.bluefatfish/worktrees/"), UUID(uuidString: lexical.lastPathComponent) != nil, try files.resolve(relative).path == lexical.path else { throw PetError("工作树路径已变化或包含符号链接") }
        guard canonical(try Self.metadata(workspace: path).path) == canonical(directory.path) else { throw PetError("工作树不再属于当前仓库") }
        let result = try await run(["-C", path, "rev-parse", "--absolute-git-dir"])
        guard !result.failed, let metadata = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), canonical(metadata).hasPrefix(canonical(directory.path) + "/worktrees/") else { throw PetError("工作树元数据不匹配") }
        let actual = URL(fileURLWithPath: canonical(metadata))
        for name in ["index.lock", "HEAD.lock", "locked", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
            guard !FileManager.default.fileExists(atPath: actual.appendingPathComponent(name).path) else { throw PetError("工作树正在执行 Git 操作或已锁定：" + name) }
        }
        return entry
    }
    private func worktreeMetadata(_ path: String) async throws -> URL {
        URL(fileURLWithPath: try await output(["-C", path, "rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.resolvingSymlinksInPath()
    }
    private func worktreeIndex(_ metadata: URL) throws -> Data {
        let scope = try AgentFiles(workspace: metadata.path)
        return try Data(contentsOf: scope.resolve("index"))
    }
    private func worktreeSnapshot(_ path: String) async throws -> AgentWorktreeSnapshot.Value {
        let job = Task.detached { try AgentWorktreeSnapshot.read(URL(fileURLWithPath: path)) }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    private func fingerprint(_ entry: AgentWorktreeEntry, tree: String, index: Data) -> String {
        AgentFiles.hash(Data(([entry.path, entry.head ?? "", entry.branch ?? "", tree, AgentFiles.hash(index)] + entry.taskIDs).joined(separator: "\0").utf8))
    }
    func prepareWorktreeRecycle(path: String) async throws -> AgentWorktreeRecycleReview {
        let entry = try await recyclable(path), metadata = try await worktreeMetadata(path), tree = try await worktreeSnapshot(path)
        try validateWorktreeEligibility(entry, tree: tree, metadata: metadata)
        let index = try worktreeIndex(metadata), fingerprint = fingerprint(entry, tree: tree.hash, index: index)
        let review = AgentWorktreeRecycleReview(taskID: taskID, path: entry.path, hash: UUID().uuidString, fingerprint: fingerprint, head: entry.head!, branch: entry.branch, files: tree.count, bytes: tree.bytes, taskIDs: entry.taskIDs)
        try saveWorktree(review, worktreeFile(worktreeReviewName)); return review
    }
    func storedWorktreeReview(hash: String) throws -> AgentWorktreeRecycleReview {
        let value = try JSONDecoder().decode(AgentWorktreeRecycleReview.self, from: Data(contentsOf: worktreeFile(worktreeReviewName)))
        guard value.taskID == taskID, value.processID == AgentWorktreeRecycleReview.processID, value.hash == hash, Date().timeIntervalSince(value.created) < 900 else { throw PetError("工作树审阅已失效，请重新检查") }; return value
    }
    func worktreeBackups() throws -> [AgentWorktreeBackup] {
        guard FileManager.default.fileExists(atPath: worktreeStorage.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: worktreeStorage, includingPropertiesForKeys: nil).compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil, let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")), let value = try? JSONDecoder().decode(AgentWorktreeBackup.self, from: data), value.id == folder.lastPathComponent, canonical(value.origin.root) == files.root.path, canonical(value.origin.metadata) == canonical(directory.path) else { return nil }; return value
        }.sorted { $0.created > $1.created }
    }
    func worktreeBackup(_ id: String) throws -> AgentWorktreeBackup {
        guard UUID(uuidString: id) != nil, let value = try worktreeBackups().first(where: { $0.id == id }) else { throw PetError("没有当前项目的回收记录") }; return value
    }
    private func retainWorktreeObjects(_ backup: inout AgentWorktreeBackup, index: Data) async throws {
        // A raw index only names staged blobs; Git may prune those blobs after
        // the checkout disappears. Pin both HEAD and the index tree, without
        // creating a commit or changing any user branch or source index.
        let temporaryIndex = scratch.appendingPathComponent("backup-index-" + backup.id), input = scratch.appendingPathComponent("backup-refs-" + backup.id)
        defer { try? FileManager.default.removeItem(at: temporaryIndex); try? FileManager.default.removeItem(at: input) }
        try await validateHooks()
        try index.write(to: temporaryIndex, options: .atomic)
        let tree = try await run(["-C", backup.origin.path, "write-tree"], write: true, environment: ["GIT_INDEX_FILE": temporaryIndex.path])
        guard !tree.failed, let oid = tree.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), [40, 64].contains(oid.count), oid.allSatisfy({ $0.isHexDigit }) else { throw PetError("暂存对象备份未完成，工作树保留：" + tree.text) }
        let prefix = "refs/bluefatfish/worktree-backups/" + backup.id.lowercased(), headRef = prefix + "/head", indexRef = prefix + "/index"
        try Data("start\ncreate \(headRef) \(backup.head)\ncreate \(indexRef) \(oid)\nprepare\ncommit\n".utf8).write(to: input)
        let saved = try await run(["update-ref", "--stdin"], write: true, inputFile: input)
        guard !saved.failed else { throw PetError("Git 快照引用未保存，工作树保留：" + saved.text) }
        backup.objectRefs = [headRef, indexRef]; backup.indexTree = oid
    }
    func recycleWorktree(reviewHash: String) async throws -> AgentWorktreeBackup {
        let review = try storedWorktreeReview(hash: reviewHash), entry = try await recyclable(review.path)
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-recycle", name: "git_recycle_worktree", arguments: "{}"), task: task, store: store) }
        let metadata = try await worktreeMetadata(entry.path), index = try worktreeIndex(metadata), tree = try await worktreeSnapshot(entry.path)
        try validateWorktreeEligibility(entry, tree: tree, metadata: metadata)
        guard fingerprint(entry, tree: tree.hash, index: index) == review.fingerprint else { throw PetError("工作树内容、分支或关联任务已变化，请重新审阅") }
        let id = UUID().uuidString, folder = try worktreeFile(id), copy = folder.appendingPathComponent("files"), meta = folder.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = AgentCommand(); worktreeCopy = process; defer { worktreeCopy = nil }
        let result = try await process.run(command: "/usr/bin/ditto", workspace: files.root, scratch: folder, network: false, timeout: 1800, readOnly: true, gitDirectory: directory, protectedData: store.directory.deletingLastPathComponent(), arguments: [entry.path, copy.path])
        guard !result.failed else { throw PetError("备份未完成，工作树未回收：" + result.text) }
        for file in try FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil) where file.lastPathComponent == "index" || file.lastPathComponent == "config.worktree" || file.lastPathComponent.hasPrefix("sharedindex.") {
            _ = try AgentFiles(workspace: metadata.path).resolve(file.lastPathComponent)
            guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw PetError("Git 元数据包含特殊文件，请先在本地 Git 处理") }
            try FileManager.default.copyItem(at: file, to: meta.appendingPathComponent(file.lastPathComponent))
        }
        guard try await worktreeSnapshot(copy.path).hash == tree.hash, try Data(contentsOf: meta.appendingPathComponent("index")) == index else { throw PetError("备份与审阅内容不一致，工作树未回收") }
        var backup = AgentWorktreeBackup(id: id, origin: AgentWorktreeOrigin(root: files.root.path, metadata: directory.path, path: entry.path), head: entry.head!, branch: entry.branch, treeHash: tree.hash, indexHash: AgentFiles.hash(index), tasks: Dictionary(uniqueKeysWithValues: entry.taskIDs.compactMap { id in store.task(id).map { (id, $0.archived) } }))
        try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        let current = try await recyclable(entry.path), finalTree = try await worktreeSnapshot(entry.path), finalIndex = try worktreeIndex(metadata)
        try validateWorktreeEligibility(current, tree: finalTree, metadata: metadata)
        guard fingerprint(current, tree: finalTree.hash, index: finalIndex) == review.fingerprint else { throw PetError("备份期间工作树已变化，原工作树保留，请重新审阅") }
        try Task.checkCancellation(); try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-recycle", name: "git_recycle_worktree", arguments: "{}"), task: task, store: store) }
        try await retainWorktreeObjects(&backup, index: index)
        try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        let pinned = try await recyclable(entry.path), pinnedTree = try await worktreeSnapshot(entry.path), pinnedIndex = try worktreeIndex(metadata)
        try validateWorktreeEligibility(pinned, tree: pinnedTree, metadata: metadata)
        guard fingerprint(pinned, tree: pinnedTree.hash, index: pinnedIndex) == review.fingerprint else { throw PetError("保存快照期间工作树已变化，原工作树保留") }
        try Task.checkCancellation(); try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-recycle", name: "git_recycle_worktree", arguments: "{}"), task: task, store: store) }
        try FileManager.default.removeItem(at: worktreeFile(worktreeReviewName))
        let removed = try await run(["worktree", "remove", "--force", "--", entry.path], write: true)
        guard !removed.failed else { throw PetError("Git 未完成回收，备份已保留（" + id + "）：" + removed.text) }
        backup.state = "recycled"; try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        for id in entry.taskIDs { store.update(id) { $0.archived = true; $0.gitReview = nil; $0.gitPushReview = nil; $0.events.append(AgentEvent(kind: "git", title: "工作树已回收", detail: entry.path + "\n备份：" + backup.id, status: "completed")) } }
        if entry.taskIDs.contains(store.selectedID ?? "") { store.selectedID = taskID }
        if let error = store.writeError { throw PetError("工作树已回收，关联任务保存失败；备份：" + id + "\n" + error) }
        return backup
    }
    func restoreWorktree(backupID: String) async throws -> AgentWorktreeBackup {
        try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-restore", name: "git_restore_worktree", arguments: "{}"), task: task, store: store) }
        var backup = try worktreeBackup(backupID)
        guard ["prepared", "recycled"].contains(backup.state) else { throw PetError("该回收记录已处理或需要手动核对") }
        let destination = try files.resolve(String(backup.origin.path.dropFirst(files.root.path.count + 1)))
        guard destination.path == backup.origin.path, destination.path.hasPrefix(files.root.path + "/.bluefatfish/worktrees/"), (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil, try await worktrees().allSatisfy({ canonical($0.path) != destination.path }) else { throw PetError("原路径或工作树登记已存在，未覆盖任何文件") }
        let folder = try worktreeFile(backup.id), copy = folder.appendingPathComponent("files"), index = try Data(contentsOf: folder.appendingPathComponent("metadata/index"))
        guard try await worktreeSnapshot(copy.path).hash == backup.treeHash, AgentFiles.hash(index) == backup.indexHash else { throw PetError("回收备份已变化，未恢复") }
        let existing = try await worktrees(), branch: String?
        if let old = backup.branch {
            let current = try await run(["rev-parse", "--verify", old])
            branch = !current.failed && current.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == backup.head && !existing.contains(where: { $0.branch == old }) ? old : "refs/heads/recovered/" + backup.id.lowercased()
        } else { branch = nil }
        try Task.checkCancellation(); try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-restore", name: "git_restore_worktree", arguments: "{}"), task: task, store: store) }
        try await validateHooks()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        backup.state = "restoring"; try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        let args: [String]
        if let branch, branch != backup.branch { args = ["worktree", "add", "--no-checkout", "-b", String(branch.dropFirst("refs/heads/".count)), destination.path, backup.head] }
        else { args = ["worktree", "add", "--no-checkout"] + (branch == nil ? ["--detach"] : []) + [destination.path, branch.map { String($0.dropFirst("refs/heads/".count)) } ?? backup.head] }
        let added = try await run(args, write: true)
        guard !added.failed else { throw PetError("恢复未完成，备份保留，请核对实际 Git 状态：" + added.text) }
        let restoredMetadata = try await worktreeMetadata(destination.path)
        // Copy saved bytes without touching the new .git backlink.
        let job = Task.detached {
            let fm = FileManager.default
            for file in try fm.contentsOfDirectory(at: copy, includingPropertiesForKeys: nil) where file.lastPathComponent != ".git" { try Task.checkCancellation(); try fm.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent)) }
            for file in try fm.contentsOfDirectory(at: folder.appendingPathComponent("metadata"), includingPropertiesForKeys: nil) { try Data(contentsOf: file).write(to: restoredMetadata.appendingPathComponent(file.lastPathComponent), options: .atomic) }
        }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        guard try await worktreeSnapshot(destination.path).hash == backup.treeHash, try Data(contentsOf: restoredMetadata.appendingPathComponent("index")) == index else { throw PetError("恢复结果不一致，备份保留，请核对实际目录") }
        let readable = try await run(["-C", destination.path, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--numstat", backup.head, "--"], maximumOutput: 1024)
        guard !readable.failed else { throw PetError("恢复的暂存内容无法读取，文件与备份保留，请核对 Git 状态：" + readable.text) }
        let actualHead = try await output(["-C", destination.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let actualRef = try await run(["-C", destination.path, "symbolic-ref", "--quiet", "HEAD"])
        let restoredBranch = actualRef.exitCode == 0 ? actualRef.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        guard actualHead == backup.head, restoredBranch == branch, actualRef.exitCode == (branch == nil ? 1 : 0) else { throw PetError("恢复后的实际分支或提交不一致，备份保留，请核对 Git 状态") }
        backup.state = "restored"; backup.restoredBranch = restoredBranch; try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        for (id, archived) in backup.tasks where store.task(id)?.workspace.map({ canonical($0) == destination.path || canonical($0).hasPrefix(destination.path + "/") }) == true {
            store.update(id) { $0.archived = archived; $0.gitReview = nil; $0.gitPushReview = nil; $0.events.append(AgentEvent(kind: "git", title: "工作树已恢复", detail: destination.path + "\n" + (branch ?? "分离状态"), status: "completed")) }
        }
        if let error = store.writeError { throw PetError("文件已恢复，关联任务保存失败：" + error) }; return backup
    }
}
