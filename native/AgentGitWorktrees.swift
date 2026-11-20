import Foundation
import CryptoKit
import Darwin

struct AgentWorktreeOrigin: Codable, Equatable { var root: String; var metadata: String; var path: String }
extension AgentTaskRecord {
    var managedWorktreeOrigins: [AgentWorktreeOrigin] { worktreeOrigins ?? worktreeOrigin.map { [$0] } ?? [] }
}
struct AgentWorktreeEntry: Codable {
    static let tools = ["git_worktrees", "git_prepare_worktree_recycle", "git_recycle_worktree", "git_restore_worktree"]
    var path: String; var head: String?; var branch: String?; var locked: String?; var prunable: String?
    var bare = false; var owned = false; var taskIDs: [String] = []; var unavailable: String?
    var missingRegistration: Bool? = nil
    var canRelink: Bool? = nil
}
struct AgentExternalWorktreeIdentity: Codable, Equatable {
    var parent: String
    var checkout: String
}
struct AgentMissingWorktreeRegistration: Codable, Equatable {
    let name: String
    let parent: String
    let metadata: String
}
private struct AgentWorktreeRecycleProgress: Codable {
    let checkout: String
    let checkoutLink: String
    let registration: AgentMissingWorktreeRegistration
    let metadataHashes: [String: String]
    var cleanupStarted = false
}
private struct AgentWorktreeRestore: Codable {
    struct Directory: Codable { var name: String; var identity: String }

    var id = UUID()
    var parent: String
    var branch: String?
    var savedMetadata: [String: String]
    var checkout: String?
    var metadata: String?
    var initialMetadata: [String: String]?
    var staging: Directory?
    var readyToUnlock = false
    var lockReason: String { "BlueFatFish restore " + id.uuidString }
    var stagingName: String { ".bluefatfish-restore-" + id.uuidString }
}
struct AgentWorktreeBackup: Codable {
    var id: String; var origin: AgentWorktreeOrigin; var head: String; var branch: String?
    var treeHash: String; var indexHash: String; var created = Date(); var tasks: [String: Bool]
    var state = "prepared"; var restoredBranch: String?
    var objectRefs: [String]?; var indexTree: String?
    var external: AgentExternalWorktreeIdentity? = nil
    var registration: AgentMissingWorktreeRegistration? = nil
    fileprivate var recycle: AgentWorktreeRecycleProgress? = nil
    fileprivate var restore: AgentWorktreeRestore? = nil
    var canRestore: Bool { ["prepared", "recycled"].contains(state) || (registration == nil && state == "restoring") }
}
struct AgentWorktreeRecycleReview: Codable {
    static let processID = UUID().uuidString
    var taskID: String; var processID = Self.processID; var path: String; var hash: String
    var fingerprint: String; var head: String; var branch: String?; var files: Int; var bytes: UInt64
    var taskIDs: [String]; var created = Date()
    var external: AgentExternalWorktreeIdentity? = nil
    var registration: AgentMissingWorktreeRegistration? = nil
}

struct AgentWorktreeRelinkReview {
    let taskID: String
    let source: String, destination: String, metadata: URL, folderIdentity: String, metadataIdentity: String
    let head: String?, branch: String?, versions: [String: AgentTaskRelinkVersion]
    let writes: [AgentKnowledgeFileWrite]
    let created = Date()
}
struct AgentTaskRelinkVersion: Equatable { let file: String; let value: String }

private struct AgentWorktreeRecycleTarget {
    let entry: AgentWorktreeEntry
    let metadata: URL
    let external: AgentExternalWorktreeIdentity?
    var externalURL: URL? { external.map { _ in URL(fileURLWithPath: entry.path, isDirectory: true) } }
}

enum AgentWorktreeSnapshot {
    struct Item: Codable, Equatable { var path: String; var kind: String; var mode: UInt16; var hash: String }
    struct Value {
        var hash: String; var items: [Item]; var bytes: UInt64; var modified: Date
        var count: Int { items.count }
        var topLevel: [String: [Item]] { Dictionary(grouping: items) { String($0.path.prefix { $0 != "/" }) } }
    }
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
        let sorted = items.sorted { $0.path < $1.path }
        return Value(hash: AgentFiles.hash(try encoder.encode(sorted)), items: sorted, bytes: bytes, modified: modified)
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
    private func externalWorktreeURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let protected = [directory, store.directory.deletingLastPathComponent(), Bundle.main.bundleURL, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)]
        guard allowsExternalWorktrees, path.hasPrefix("/"), path.utf8.count < 8192, !path.contains("\0"), path == canonical(path),
              path != "/", path != files.root.path, !files.root.path.hasPrefix(path + "/"),
              !protected.map({ canonical($0.path) }).contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else {
            throw PetError("外部工作树路径已变化、包含符号链接或超出可回收范围")
        }
        return url
    }
    private nonisolated func directoryIdentity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw PetError("外部工作树目录或上级目录不可用") }
        let volume = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? String(info.st_dev)
        return volume + ":" + String(info.st_ino)
    }
    private func nonexistentWorktreePath(_ url: URL) -> Bool {
        var info = stat(); return lstat(url.path, &info) == -1 && errno == ENOENT
    }
    private func missingWorktreePath(_ path: String) throws -> URL {
        let url = try externalWorktreeURL(path), parent = url.deletingLastPathComponent()
        guard !["/Volumes", "/Network", "/net"].contains(parent.path), nonexistentWorktreePath(url) else { throw PetError("原目录状态已变化，请刷新工作树") }
        _ = try directoryIdentity(parent)
        return url
    }
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
        let backups = try allWorktreeBackups()
        let archivedPaths = backups.map { canonical($0.origin.path) }
        let recyclingPaths = Set(backups.filter { $0.state == "recycling" }.map { canonical($0.origin.path) })
        let knownOrigins = store.tasks.flatMap { $0.managedWorktreeOrigins.map { canonical($0.path) } }
        let listedPaths = entries.map { canonical($0.path) }
        let registeredPaths = listedPaths + knownOrigins + archivedPaths
        for i in entries.indices {
            let listed = entries[i].path, path = listedPaths[i]
            entries[i].path = path
            let related = store.tasks.filter { task in
                task.workspacePaths.map(canonical).contains { workspace in
                    (workspace == path || workspace.hasPrefix(path + "/")) && !registeredPaths.contains { other in other != path && other.hasPrefix(path + "/") && (workspace == other || workspace.hasPrefix(other + "/")) }
                }
            }
            entries[i].taskIDs = related.map(\.id).sorted()
            let managedLocation = path.hasPrefix(files.root.path + "/.bluefatfish/worktrees/") && UUID(uuidString: URL(fileURLWithPath: path).lastPathComponent) != nil
            entries[i].owned = managedLocation && store.tasks.contains { task in
                if !task.managedWorktreeOrigins.isEmpty { return task.managedWorktreeOrigins.contains { canonical($0.root) == files.root.path && canonical($0.metadata) == canonical(directory.path) && canonical($0.path) == path } }
                // Earlier releases recorded native creation in the task history.
                guard task.parentID != nil, canonical(task.gitDirectory ?? "") == canonical(directory.path) else { return false }
                return store.task(task.id)?.events.contains { $0.kind == "git" && $0.title == "已创建工作树" && $0.detail.hasSuffix("\n" + path) } == true
            }
            let active = related.contains { [.running, .waiting].contains($0.status) || $0.pendingFileCapture != nil || $0.pendingFileRollback != nil || store.hooks.isRunning($0.id) }
            let interruptedHandoff = related.contains { record in
                guard !record.managedWorktreeOrigins.isEmpty else { return false }
                do { return try AgentWorktreeHandoff(store: store, taskID: record.id).pendingRecovery() != nil }
                catch { return true }
            }
            if allowsExternalWorktrees, i != 0, !entries[i].bare, !active, listed == path, (try? externalWorktreeURL(path)) != nil,
               nonexistentWorktreePath(URL(fileURLWithPath: path)) { entries[i].canRelink = true }
            if path == files.root.path { entries[i].unavailable = "当前工作树" }
            else if i == 0 || entries[i].bare { entries[i].unavailable = "主工作树" }
            else if !entries[i].owned && !allowsExternalWorktrees { entries[i].unavailable = "外部工作树" }
            else if recyclingPaths.contains(path) {
                entries[i].unavailable = "请在回收记录继续处理"; entries[i].canRelink = nil
            }
            else if entries[i].locked != nil { entries[i].unavailable = "工作树已锁定" }
            else if active { entries[i].unavailable = "关联任务正在运行或等待处理" }
            else if interruptedHandoff { entries[i].unavailable = "有中断的工作树移交" }
            else if entries[i].prunable != nil, Self.isWorktreeObject(entries[i].head ?? ""), listed == path, (try? missingWorktreePath(path)) != nil { entries[i].missingRegistration = true }
            else if entries[i].prunable != nil || entries[i].head == nil || !FileManager.default.fileExists(atPath: path) {
                entries[i].unavailable = entries[i].canRelink == true ? "原目录缺失 · 可重新关联" : "路径不可用，请先在本地 Git 修复"
            }
            else if !entries[i].owned && (listed != path || (try? externalWorktreeURL(path)) == nil) { entries[i].unavailable = "外部路径已变化或不可回收" }
            else if !entries[i].owned && listedPaths.contains(where: { $0.hasPrefix(path + "/") }) { entries[i].unavailable = "包含其他工作树" }
        }
        return entries
    }
    private func recyclable(_ requested: String) async throws -> AgentWorktreeRecycleTarget {
        try validateWorkspace()
        let path = canonical(requested)
        let inventory = try await worktrees()
        try worktreeInventoryCheck?(inventory)
        guard let entry = inventory.first(where: { $0.path == path }), entry.unavailable == nil, entry.missingRegistration != true, let head = entry.head, !head.isEmpty else { throw PetError("工作树不可回收，请刷新并处理关联任务或锁定状态") }
        let externalURL: URL?, external: AgentExternalWorktreeIdentity?
        if entry.owned {
            let relative = String(path.dropFirst(files.root.path.count + 1)), lexical = files.root.appendingPathComponent(relative).standardizedFileURL
            guard path.hasPrefix(files.root.path + "/.bluefatfish/worktrees/"), UUID(uuidString: lexical.lastPathComponent) != nil, try files.resolve(relative).path == lexical.path else { throw PetError("工作树路径已变化或包含符号链接") }
            externalURL = nil; external = nil
        } else {
            let url = try externalWorktreeURL(requested)
            externalURL = url
            external = try AgentExternalWorktreeIdentity(parent: directoryIdentity(url.deletingLastPathComponent()), checkout: directoryIdentity(url))
        }
        guard canonical(try Self.metadata(workspace: path).path) == canonical(directory.path) else { throw PetError("工作树不再属于当前仓库") }
        let actual = try await worktreeMetadata(path, externalWorktree: externalURL)
        try checkWorktreeMetadataIdle(actual)
        return AgentWorktreeRecycleTarget(entry: entry, metadata: actual, external: external)
    }
    private func checkWorktreeMetadataIdle(_ metadata: URL, allowingLocked: Bool = false, holdingIndex: Bool = false) throws {
        for name in ["index.lock", "HEAD.lock", "gitdir.lock", "locked", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
            if (name == "locked" && allowingLocked) || (name == "index.lock" && holdingIndex) { continue }
            guard nonexistentWorktreePath(metadata.appendingPathComponent(name)) else { throw PetError("工作树正在执行 Git 操作或已锁定：" + name) }
        }
    }
    private func registeredCheckoutLink(_ metadata: URL) throws -> String {
        let files = try AgentFiles(workspace: metadata.path), entry = try files.literalURL("gitdir")
        guard try files.resolve("gitdir").path == entry.path,
              let link = try String(data: files.readData(entry, maximum: 8192), encoding: .utf8), link.hasSuffix("\n") else { throw PetError("Git 工作树登记无效") }
        return URL(fileURLWithPath: String(link.dropLast()), relativeTo: metadata).standardizedFileURL.path
    }
    private func worktreeMetadata(_ path: String, externalWorktree: URL? = nil) async throws -> URL {
        let result = try await run(["-C", path, "rev-parse", "--absolute-git-dir"], externalWorktree: externalWorktree)
        guard !result.failed, result.truncated != true, let raw = result.stdout, raw.hasSuffix("\n"), raw.hasPrefix("/") else { throw PetError("工作树元数据无法读取") }
        let metadata = URL(fileURLWithPath: String(raw.dropLast()), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard metadata.deletingLastPathComponent().path == canonical(directory.path) + "/worktrees" else { throw PetError("工作树元数据不匹配") }
        if externalWorktree != nil, try registeredCheckoutLink(metadata) != path + "/.git" { throw PetError("Git 登记指向不同的外部目录，请刷新后重新审阅") }
        return metadata
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
        let target = try await recyclable(path), entry = target.entry, metadata = target.metadata
        let tree = try await worktreeSnapshot(entry.path)
        try validateWorktreeEligibility(entry, tree: tree, metadata: metadata)
        let index = try worktreeIndex(metadata), fingerprint = fingerprint(entry, tree: tree.hash, index: index)
        let review = AgentWorktreeRecycleReview(taskID: taskID, path: entry.path, hash: UUID().uuidString, fingerprint: fingerprint, head: entry.head!, branch: entry.branch, files: tree.count, bytes: tree.bytes, taskIDs: entry.taskIDs, external: target.external)
        try saveWorktree(review, worktreeFile(worktreeReviewName)); return review
    }
    func storedWorktreeReview(hash: String) throws -> AgentWorktreeRecycleReview {
        let value = try JSONDecoder().decode(AgentWorktreeRecycleReview.self, from: Data(contentsOf: worktreeFile(worktreeReviewName)))
        guard value.taskID == taskID, value.processID == AgentWorktreeRecycleReview.processID, value.hash == hash, Date().timeIntervalSince(value.created) < 900,
              value.external == nil || allowsExternalWorktrees else { throw PetError("工作树审阅已失效或需要在管理页操作") }; return value
    }
    private func allWorktreeBackups() throws -> [AgentWorktreeBackup] {
        guard FileManager.default.fileExists(atPath: worktreeStorage.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: worktreeStorage, includingPropertiesForKeys: nil).compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil, let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")), let value = try? JSONDecoder().decode(AgentWorktreeBackup.self, from: data), value.id == folder.lastPathComponent, canonical(value.origin.root) == files.root.path, canonical(value.origin.metadata) == canonical(directory.path) else { return nil }; return value
        }.sorted { $0.created > $1.created }
    }
    func worktreeBackups() throws -> [AgentWorktreeBackup] {
        try allWorktreeBackups().compactMap { saved in
            guard allowsExternalWorktrees || (saved.external == nil && saved.registration == nil) else { return nil }
            guard let registration = saved.registration, saved.state != "restored" else { return saved }
            var record = saved
            if !nonexistentWorktreePath(worktreeRegistrationBackupURL(saved.id)) {
                record.state = "recycled"
            } else if saved.state == "prepared" {
                return nil
            } else if let original = try? worktreeRegistrationOriginal(registration), (try? directoryIdentity(original)) == registration.metadata {
                record.state = "restored"; record.restoredBranch = saved.branch
            }
            return record
        }
    }
    func worktreeBackup(_ id: String) throws -> AgentWorktreeBackup {
        guard UUID(uuidString: id) != nil, let value = try worktreeBackups().first(where: { $0.id == id }) else { throw PetError("没有当前项目的回收记录") }; return value
    }
    private static func isWorktreeObject(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy(\.isHexDigit) && value.contains { $0 != "0" }
    }
    private func retainWorktreeObjects(_ backup: inout AgentWorktreeBackup, index: Data?, externalWorktree: URL? = nil, registration: URL? = nil, lease: AgentWorktreeLease? = nil) async throws {
        // A raw index only names staged blobs; Git may prune those blobs after
        // the checkout disappears. Pin both HEAD and the index tree, without
        // creating a commit or changing any user branch or source index.
        let temporaryIndex = scratch.appendingPathComponent("backup-index-" + backup.id), input = scratch.appendingPathComponent("backup-refs-" + backup.id)
        defer { try? FileManager.default.removeItem(at: temporaryIndex); try? FileManager.default.removeItem(at: input) }
        try await validateHooks()
        let prefix = "refs/bluefatfish/worktree-backups/" + backup.id.lowercased()
        var objects = [(name: prefix + "/head", oid: backup.head)]
        let location = registration.map { ["--git-dir=" + $0.path, "--work-tree=" + scratch.path] } ?? ["-C", backup.origin.path]
        if let index {
            try index.write(to: temporaryIndex, options: .atomic)
            let tree = try await run(location + ["write-tree"], write: true, environment: ["GIT_INDEX_FILE": temporaryIndex.path], externalWorktree: externalWorktree, metadataOnly: registration != nil, leaseDescriptor: lease?.descriptor)
            guard !tree.failed, let oid = tree.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), Self.isWorktreeObject(oid) else { throw PetError("暂存对象备份未完成，工作树保留：" + tree.text) }
            objects.append((prefix + "/index", oid)); backup.indexTree = oid
        }
        if registration != nil {
            let log = try await output(location + ["reflog", "show", "--format=%H", "HEAD"])
            let refs = try await output(location + ["for-each-ref", "--format=%(objectname)", "refs/worktree", "refs/rewritten", "refs/bisect"])
            let extra = Set((log + "\n" + refs).split(separator: "\n").map(String.init)).subtracting(objects.map(\.oid)).sorted()
            guard extra.allSatisfy(Self.isWorktreeObject) else { throw PetError("无法核对工作树历史对象，登记保留") }
            objects += extra.enumerated().map { (prefix + "/history/" + String($0.offset), $0.element) }
        }
        let transaction = ["start"] + objects.map { "create \($0.name) \($0.oid)" } + ["prepare", "commit", ""]
        try Data(transaction.joined(separator: "\n").utf8).write(to: input, options: .atomic)
        let saved = try await run(["update-ref", "--stdin"], write: true, inputFile: input, externalWorktree: externalWorktree, metadataOnly: registration != nil, leaseDescriptor: lease?.descriptor)
        guard !saved.failed else { throw PetError("Git 快照引用未保存，工作树保留：" + saved.text) }
        backup.objectRefs = objects.map(\.name)
    }

    func worktreeRegistrationBackupURL(_ id: String) -> URL {
        directory.appendingPathComponent("bluefatfish-worktree-registrations", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    private func protectedRegistrationPath(_ url: URL) throws -> URL {
        let scope = try AgentFiles(workspace: directory.path)
        guard try scope.resolve(url.path).path == url.path else { throw PetError("Git 登记路径包含符号链接") }
        return url
    }
    private func worktreeRegistrationOriginal(_ registration: AgentMissingWorktreeRegistration) throws -> URL {
        guard !registration.name.isEmpty, ![".", ".."].contains(registration.name), !registration.name.contains("/"), !registration.name.contains("\0") else { throw PetError("备份中的 Git 登记名称无效") }
        let worktrees = directory.appendingPathComponent("worktrees", isDirectory: true)
        return try protectedRegistrationPath(worktrees.appendingPathComponent(registration.name, isDirectory: true))
    }
    private func missingRegistrationTarget(_ path: String) async throws -> (entry: AgentWorktreeEntry, metadata: URL, registration: AgentMissingWorktreeRegistration) {
        try validateWorkspace()
        let matches = try await worktrees().filter { $0.path == path }
        guard matches.count == 1, let entry = matches.first, entry.missingRegistration == true else { throw PetError("工作树登记状态已变化，请刷新后重试") }
        let checkout = try missingWorktreePath(path)
        let metadata = try registrationMetadata(for: path)
        try checkWorktreeMetadataIdle(metadata)
        let registration = try AgentMissingWorktreeRegistration(name: metadata.lastPathComponent, parent: directoryIdentity(checkout.deletingLastPathComponent()), metadata: directoryIdentity(metadata))
        return (entry, metadata, registration)
    }
    private func registrationMetadata(for path: String) throws -> URL {
        let worktrees = try protectedRegistrationPath(directory.appendingPathComponent("worktrees", isDirectory: true))
        let matches = try FileManager.default.contentsOfDirectory(at: worktrees, includingPropertiesForKeys: nil).filter {
            (try? directoryIdentity($0)) != nil && (try? registeredCheckoutLink($0)) == path + "/.git"
        }
        guard matches.count == 1, let metadata = matches.first else { throw PetError("无法唯一确认这条 Git 登记") }
        return metadata
    }
    private func relinkFile(_ name: String, in files: AgentFiles, prefix: String = "") throws -> (String, Data) {
        let url = try files.literalURL(name)
        let data = try files.readData(url, maximum: 8192)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(prefix) else { throw PetError("工作树链接格式无效") }
        let path = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .newlines)
        guard !path.isEmpty, !path.contains("\0") else { throw PetError("工作树链接无效") }
        return (path, data)
    }
    private func updatedRelinkPath(to target: URL, from base: URL, previous: String) -> String {
        guard !previous.hasPrefix("/") else { return target.path }
        let baseParts = base.pathComponents, targetParts = target.pathComponents
        let shared = zip(baseParts, targetParts).prefix { $0.0 == $0.1 }.count
        return (Array(repeating: "..", count: baseParts.count - shared) + targetParts.dropFirst(shared)).joined(separator: "/")
    }
    func prepareWorktreeRelink(from source: String, to destination: String) async throws -> AgentWorktreeRelinkReview {
        try validateWorkspace()
        let original = try externalWorktreeURL(source), checkout = try externalWorktreeURL(destination)
        let entries = try await worktrees(), matches = entries.filter { $0.path == source }
        guard matches.count == 1, let entry = matches.first, entry.canRelink == true, nonexistentWorktreePath(original) else { throw PetError("原目录或工作树状态已变化，请刷新后重试") }
        guard !entries.contains(where: { $0.path == destination }), !entries.dropFirst().contains(where: {
            $0.path != source && ($0.path.hasPrefix(destination + "/") || destination.hasPrefix($0.path + "/"))
        }) else { throw PetError("新目录与另一条工作树登记重叠") }
        let metadata = try registrationMetadata(for: source)
        try checkWorktreeMetadataIdle(metadata, allowingLocked: true)
        let checkoutFiles = try AgentFiles(workspace: checkout.path, followParentLinks: false), admin = try AgentFiles(workspace: metadata.path, followParentLinks: false)
        let (pointer, pointerBytes) = try relinkFile(".git", in: checkoutFiles, prefix: "gitdir: ")
        let (backlink, backlinkBytes) = try relinkFile("gitdir", in: admin)
        let (common, _) = try relinkFile("commondir", in: admin)
        let locations: [String] = [original, checkout].map { URL(fileURLWithPath: pointer, relativeTo: $0).standardizedFileURL.path }
        guard locations.contains(metadata.path), URL(fileURLWithPath: common, relativeTo: metadata).standardizedFileURL.path == canonical(directory.path) else { throw PetError("所选目录的 Git 链接不属于这条工作树登记") }
        guard locations[1] == metadata.path || nonexistentWorktreePath(URL(fileURLWithPath: locations[1])) else { throw PetError("所选目录已关联到另一个 Git 目录") }
        let configured = try await run(["--git-dir=" + metadata.path, "config", "--path", "--get", "core.worktree"])
        if configured.exitCode != 1 {
            let path = (configured.stdout ?? "").trimmingCharacters(in: .newlines)
            guard !configured.failed, !path.isEmpty, URL(fileURLWithPath: path, relativeTo: metadata).standardizedFileURL.path == checkout.path else { throw PetError("此 Git 登记配置了其他工作目录，请先处理 core.worktree") }
        }
        let label = "重新关联工作树"
        let forward = "gitdir: " + updatedRelinkPath(to: metadata, from: checkout, previous: pointer) + "\n"
        let reverse = updatedRelinkPath(to: checkout.appendingPathComponent(".git"), from: metadata, previous: backlink) + "\n"
        let writes = [try AgentKnowledgeFileWrite(files: checkoutFiles, path: ".git", data: Data(forward.utf8), expectedHash: AgentFiles.hash(pointerBytes), label: label),
                      try AgentKnowledgeFileWrite(files: admin, path: "gitdir", data: Data(reverse.utf8), expectedHash: AgentFiles.hash(backlinkBytes), label: label)]
        var versions: [String: AgentTaskRelinkVersion] = [:]
        for id in entry.taskIDs {
            let current = try store.worktreeRelinkRecord(id)
            _ = try relinkedTask(current.task, from: source, to: destination)
            versions[id] = current.version
        }
        return try AgentWorktreeRelinkReview(taskID: taskID, source: source, destination: destination, metadata: metadata,
            folderIdentity: directoryIdentity(checkout), metadataIdentity: directoryIdentity(metadata), head: entry.head, branch: entry.branch, versions: versions, writes: writes)
    }
    private func relinkedTask(_ original: AgentTaskRecord, from source: String, to destination: String) throws -> AgentTaskRecord {
        func relocated(_ path: String) -> String {
            let actual = canonical(path)
            guard actual == source || actual.hasPrefix(source + "/") else { return path }
            return destination + String(actual.dropFirst(source.count))
        }
        var value = original
        value.workspace = value.workspace.map(relocated)
        if var scope = value.workspaceScope {
            scope.primary = relocated(scope.primary); scope.group = relocated(scope.group); scope.folders = scope.folders.map(relocated)
            let paths = scope.folders.map(canonical)
            guard scope.folders.contains(scope.primary), Set(paths).count == paths.count,
                  !paths.contains(where: { path in paths.contains { path.hasPrefix($0 + "/") } }) else { throw PetError("关联后任务的源文件夹会重叠，请先调整任务工作区") }
            value.workspaceScope = scope
        }
        for (before, after) in zip(original.workspacePaths, value.workspacePaths) where before != after {
            guard try AgentFiles(workspace: after).root.path == after else { throw PetError("新目录中的任务源文件夹不可用：" + after) }
        }
        func movedOrigin(_ origin: AgentWorktreeOrigin) -> AgentWorktreeOrigin {
            var value = origin; value.path = relocated(value.path); return value
        }
        value.worktreeOrigin = value.worktreeOrigin.map(movedOrigin); value.worktreeOrigins = value.worktreeOrigins?.map(movedOrigin)
        if var assignment = value.agent { assignment.workspace = assignment.workspace.map(relocated); value.agent = assignment }
        value.gitDirectory = nil; value.gitReview = nil; value.gitPushReview = nil; value.gitRemoteSnapshot = nil
        value.updated = Date()
        return value
    }
    func relinkWorktree(_ reviewed: AgentWorktreeRelinkReview) async throws {
        guard allowsExternalWorktrees, reviewed.taskID == taskID, Date().timeIntervalSince(reviewed.created) < 900 else { throw PetError("请在管理页重新审阅工作树链接") }
        let current = try await prepareWorktreeRelink(from: reviewed.source, to: reviewed.destination)
        guard current.metadata == reviewed.metadata, current.metadataIdentity == reviewed.metadataIdentity, current.folderIdentity == reviewed.folderIdentity,
              current.head == reviewed.head, current.branch == reviewed.branch, current.versions == reviewed.versions,
              current.writes.map(\.signature) == reviewed.writes.map(\.signature) else { throw PetError("Git 链接或关联任务已变化，请重新审阅") }
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-relink", name: "git_restore_worktree", arguments: "{}"), task: task, store: store) }
        let records = try reviewed.versions.keys.sorted().map { id in
            try relinkedTask(store.worktreeRelinkRecord(id).task, from: reviewed.source, to: reviewed.destination)
        }
        let target = URL(fileURLWithPath: reviewed.destination, isDirectory: true)
        try store.commitWorktreeRelink(records, versions: reviewed.versions, links: reviewed.writes) {
            try self.validateWorkspace(); try self.checkWorktreeMetadataIdle(reviewed.metadata, allowingLocked: true)
            guard self.nonexistentWorktreePath(URL(fileURLWithPath: reviewed.source)),
                  try self.directoryIdentity(target) == reviewed.folderIdentity,
                  try self.directoryIdentity(reviewed.metadata) == reviewed.metadataIdentity else { throw PetError("工作树目录已变化，请重新审阅") }
        }
        let check = try await run(["-C", target.path, "rev-parse", "--absolute-git-dir", "--show-toplevel"], externalWorktree: target)
        guard !check.failed, check.stdout == reviewed.metadata.path + "\n" + target.path + "\n" else { throw PetError("已保存工作树链接，请刷新并核对 Git 读取结果：" + check.text) }
    }
    func prepareMissingWorktreeRecycle(path: String) async throws -> AgentWorktreeRecycleReview {
        let target = try await missingRegistrationTarget(path), snapshot = try await worktreeSnapshot(target.metadata.path)
        return AgentWorktreeRecycleReview(taskID: taskID, path: path, hash: UUID().uuidString,
            fingerprint: fingerprint(target.entry, tree: snapshot.hash, index: Data()), head: target.entry.head!, branch: target.entry.branch,
            files: snapshot.count, bytes: snapshot.bytes, taskIDs: target.entry.taskIDs, registration: target.registration)
    }
    private func moveWorktreeRegistration(_ from: URL, to: URL) throws {
        try moveWorktreeDirectory(from, to: to, in: directory, identity: directoryIdentity(from))
    }
    private func moveWorktreeDirectory(_ from: URL, to: URL, in root: URL, identity: String) throws {
        let scope = try AgentFiles(workspace: root.path, followParentLinks: false)
        let (fromParent, fromName) = try scope.parentDescriptor(from, create: false); defer { close(fromParent) }
        let (toParent, toName) = try scope.parentDescriptor(to, create: false); defer { close(toParent) }
        var source = stat(), named = stat()
        guard try directoryIdentity(from) == identity, lstat(from.path, &named) == 0,
              fstatat(fromParent, fromName, &source, AT_SYMLINK_NOFOLLOW) == 0, source.st_dev == named.st_dev,
              source.st_ino == named.st_ino, source.st_mode & S_IFMT == S_IFDIR else { throw PetError("工作树目录或 Git 登记已变化") }
        guard renameatx_np(fromParent, fromName, toParent, toName, UInt32(RENAME_EXCL)) == 0 else {
            let error = String(cString: strerror(errno)); throw PetError("工作树或 Git 登记移动未完成：" + error)
        }
    }
    func recycleMissingWorktree(_ review: AgentWorktreeRecycleReview) async throws -> AgentWorktreeBackup {
        guard allowsExternalWorktrees, review.taskID == taskID, review.processID == AgentWorktreeRecycleReview.processID,
              let registration = review.registration, Date().timeIntervalSince(review.created) < 900 else { throw PetError("请在管理页重新审阅工作树登记") }
        let target = try await missingRegistrationTarget(review.path), snapshot = try await worktreeSnapshot(target.metadata.path)
        guard target.registration == registration, fingerprint(target.entry, tree: snapshot.hash, index: Data()) == review.fingerprint else { throw PetError("Git 登记或关联任务已变化，请重新审阅") }
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-recycle", name: "git_recycle_worktree", arguments: "{}"), task: task, store: store) }
        let index = nonexistentWorktreePath(target.metadata.appendingPathComponent("index")) ? nil : try worktreeIndex(target.metadata)
        let id = UUID().uuidString, archive = try protectedRegistrationPath(worktreeRegistrationBackupURL(id))
        let record = try worktreeFile(id).appendingPathComponent("record.json")
        for parent in [archive.deletingLastPathComponent(), record.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var backup = AgentWorktreeBackup(id: id, origin: AgentWorktreeOrigin(root: files.root.path, metadata: directory.path, path: review.path), head: review.head, branch: review.branch, treeHash: snapshot.hash, indexHash: AgentFiles.hash(index ?? Data()), tasks: Dictionary(uniqueKeysWithValues: review.taskIDs.compactMap { id in store.task(id).map { (id, $0.archived) } }), registration: registration)
        try await retainWorktreeObjects(&backup, index: index, registration: target.metadata)
        try saveWorktree(backup, record)
        let current = try await missingRegistrationTarget(review.path), checked = try await worktreeSnapshot(current.metadata.path)
        let checkout = try missingWorktreePath(review.path)
        guard current.registration == registration, current.metadata == target.metadata, fingerprint(current.entry, tree: checked.hash, index: Data()) == review.fingerprint,
              try directoryIdentity(checkout.deletingLastPathComponent()) == registration.parent,
              try directoryIdentity(target.metadata) == registration.metadata else { throw PetError("备份期间登记或原路径已变化，请重新审阅") }
        try checkWorktreeMetadataIdle(target.metadata)
        try Task.checkCancellation(); try validateWorkspace()
        try moveWorktreeRegistration(target.metadata, to: protectedRegistrationPath(archive))
        backup.state = "recycled"; try saveWorktree(backup, record)
        return backup
    }

    private func restoreWorktreeRegistration(_ saved: AgentWorktreeBackup, registration: AgentMissingWorktreeRegistration) async throws -> AgentWorktreeBackup {
        let archive = try protectedRegistrationPath(worktreeRegistrationBackupURL(saved.id)), checkout = try externalWorktreeURL(saved.origin.path)
        let destination = try worktreeRegistrationOriginal(registration)
        guard try directoryIdentity(archive) == registration.metadata, try await worktreeSnapshot(archive.path).hash == saved.treeHash else { throw PetError("Git 登记备份已变化") }
        if let branch = saved.branch {
            let ref = try await run(["rev-parse", "--verify", "--end-of-options", branch])
            guard !ref.failed, ref.stdout?.trimmingCharacters(in: .newlines) == saved.head else { throw PetError("原分支已变化，登记备份保留") }
        }
        let existing = try await worktrees()
        guard existing.allSatisfy({ item in item.path != checkout.path && (saved.branch == nil || item.branch != saved.branch) }),
              nonexistentWorktreePath(destination) else { throw PetError("原登记或分支已被占用，登记备份保留") }
        if nonexistentWorktreePath(checkout) {
            guard try directoryIdentity(checkout.deletingLastPathComponent()) == registration.parent else { throw PetError("原上级目录已变化，请接回工作目录后恢复登记") }
        } else {
            let scope = try AgentFiles(workspace: checkout.path), link = try scope.literalURL(".git")
            guard try scope.resolve(".git").path == link.path,
                  let pointer = try String(data: scope.readData(link, maximum: 8192), encoding: .utf8), pointer.hasPrefix("gitdir: "), pointer.hasSuffix("\n"),
                  URL(fileURLWithPath: String(pointer.dropFirst(8).dropLast()), relativeTo: checkout).standardizedFileURL.path == destination.path else { throw PetError("原目录指向其他 Git 登记，登记备份保留") }
        }
        try Task.checkCancellation(); try validateWorkspace()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = try worktreeFile(saved.id).appendingPathComponent("record.json")
        var restored = saved; restored.state = "restoring"; try saveWorktree(restored, record)
        try moveWorktreeRegistration(archive, to: protectedRegistrationPath(destination))
        restored.state = "restored"; restored.restoredBranch = saved.branch; try saveWorktree(restored, record)
        return restored
    }
    func recycleWorktree(reviewHash: String) async throws -> AgentWorktreeBackup {
        let review = try storedWorktreeReview(hash: reviewHash)
        let operation = try worktreeRecycleLease(review.path)
        defer { withExtendedLifetime(operation) {} }
        let target = try await recyclable(review.path), entry = target.entry
        guard target.external == review.external else { throw PetError("工作树目录身份已变化，请重新审阅") }
        try validateWorktreeRecyclePermission()
        let metadata = target.metadata, index = try worktreeIndex(metadata), tree = try await worktreeSnapshot(entry.path)
        try validateWorktreeEligibility(entry, tree: tree, metadata: metadata)
        guard fingerprint(entry, tree: tree.hash, index: index) == review.fingerprint else { throw PetError("工作树内容、分支或关联任务已变化，请重新审阅") }
        let id = UUID().uuidString, folder = try worktreeFile(id), copy = folder.appendingPathComponent("files"), meta = folder.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = AgentCommand(); worktreeCopy = process; defer { worktreeCopy = nil }
        let result = try await process.run(command: "/usr/bin/ditto", workspace: files.root, scratch: folder, network: false, timeout: 1800, readOnly: true, gitDirectory: directory, protectedData: store.directory.deletingLastPathComponent(), readRoots: target.externalURL.map { [$0] } ?? [], arguments: [entry.path, copy.path], leaseDescriptor: operation.descriptor)
        guard !result.failed else { throw PetError("备份未完成，工作树未回收：" + result.text) }
        for file in try FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil) where file.lastPathComponent == "index" || file.lastPathComponent == "config.worktree" || file.lastPathComponent.hasPrefix("sharedindex.") {
            _ = try AgentFiles(workspace: metadata.path).resolve(file.lastPathComponent)
            guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw PetError("Git 元数据包含特殊文件，请先在本地 Git 处理") }
            try FileManager.default.copyItem(at: file, to: meta.appendingPathComponent(file.lastPathComponent))
        }
        let copiedTree = try await worktreeSnapshot(copy.path)
        let savedMetadata = try worktreeMetadataFiles(meta).mapValues(AgentFiles.hash)
        guard copiedTree.hash == tree.hash, savedMetadata["index"] == AgentFiles.hash(index) else { throw PetError("备份与审阅内容不一致，工作树未回收") }
        var backup = AgentWorktreeBackup(id: id, origin: AgentWorktreeOrigin(root: files.root.path, metadata: directory.path, path: entry.path), head: entry.head!, branch: entry.branch, treeHash: tree.hash, indexHash: AgentFiles.hash(index), tasks: Dictionary(uniqueKeysWithValues: entry.taskIDs.compactMap { id in store.task(id).map { (id, $0.archived) } }), external: target.external)
        let record = folder.appendingPathComponent("record.json")
        try saveWorktree(backup, record)
        let current = try await recyclable(entry.path), finalTree = try await worktreeSnapshot(entry.path), finalIndex = try worktreeIndex(metadata)
        try validateWorktreeEligibility(current.entry, tree: finalTree, metadata: metadata)
        guard current.external == review.external, current.metadata == metadata, fingerprint(current.entry, tree: finalTree.hash, index: finalIndex) == review.fingerprint else { throw PetError("备份期间工作树已变化，原工作树保留，请重新审阅") }
        try validateWorktreeRecyclePermission()
        try await retainWorktreeObjects(&backup, index: index, externalWorktree: target.externalURL, lease: operation)
        let pinned = try await recyclable(entry.path)
        guard pinned.external == review.external, pinned.metadata == metadata else { throw PetError("保存快照期间工作树目录已变化，原工作树保留") }
        let checkout = URL(fileURLWithPath: entry.path, isDirectory: true)
        let parent = try directoryIdentity(checkout.deletingLastPathComponent())
        let registration = try AgentMissingWorktreeRegistration(name: metadata.lastPathComponent, parent: parent, metadata: directoryIdentity(metadata))
        backup.recycle = try AgentWorktreeRecycleProgress(checkout: directoryIdentity(checkout), checkoutLink: worktreeCheckoutLinkHash(checkout),
                                                          registration: registration, metadataHashes: savedMetadata)
        backup.state = "recycling"; try saveWorktree(backup, record)
        try FileManager.default.removeItem(at: worktreeFile(worktreeReviewName))
        return try await finishWorktreeRecycle(backup, folder: folder, checkout: checkout, savedTree: copiedTree)
    }

    func canResumeWorktreeRecycle(_ backup: AgentWorktreeBackup) -> Bool {
        guard allowsExternalWorktrees, backup.registration == nil else { return false }
        if backup.state == "recycling" { return backup.recycle != nil }
        // Older releases wrote the pinned backup before removing the checkout.
        guard backup.state == "prepared", backup.indexTree != nil, backup.objectRefs?.count == 2,
              let checkout = try? worktreeBackupCheckout(backup),
              let parent = try? directoryIdentity(checkout.deletingLastPathComponent()),
              nonexistentWorktreePath(checkout) else { return false }
        return backup.external == nil || backup.external?.parent == parent
    }

    func resumeWorktreeRecycle(backupID: String) async throws -> AgentWorktreeBackup {
        try validateWorktreeRecyclePermission()
        let original = try worktreeBackup(backupID)
        guard canResumeWorktreeRecycle(original) else { throw PetError("这条记录没有待继续的回收") }
        let operation = try worktreeRecycleLease(original.origin.path), folder = try worktreeFile(backupID)
        let backupLease = try AgentWorktreeLease(in: folder, label: "回收")
        defer { withExtendedLifetime((operation, backupLease)) {} }
        let backup = try worktreeBackup(backupID), checkout = try worktreeBackupCheckout(backup)
        guard canResumeWorktreeRecycle(backup) else { throw PetError("回收记录已变化，请刷新") }
        let tree = try await worktreeSnapshot(folder.appendingPathComponent("files").path)
        return try await finishWorktreeRecycle(backup, folder: folder, checkout: checkout, savedTree: tree)
    }

    private func worktreeRecycleLease(_ path: String) throws -> AgentWorktreeLease {
        let name = "recycle-" + AgentFiles.hash(Data(path.utf8)) + ".lock"
        let file = try worktreeFile(name)
        return try AgentWorktreeLease(in: file.deletingLastPathComponent(), label: "回收", name: name)
    }

    private func validateWorktreeRecyclePermission() throws {
        try Task.checkCancellation(); try validateWorkspace()
        if let task = store.task(taskID) {
            try store.agents.check(AgentToolCall(id: "worktree-recycle", name: "git_recycle_worktree", arguments: "{}"), task: task, store: store)
        }
    }

    private func worktreeBackupCheckout(_ backup: AgentWorktreeBackup) throws -> URL {
        if backup.external != nil { return try externalWorktreeURL(backup.origin.path) }
        let destination = try files.resolve(backup.origin.path)
        guard destination.path == backup.origin.path, destination.path.hasPrefix(files.root.path + "/.bluefatfish/worktrees/"),
              UUID(uuidString: destination.lastPathComponent) != nil else { throw PetError("原工作树路径已变化") }
        return destination
    }

    private func worktreeCheckoutLinkHash(_ checkout: URL) throws -> String {
        let scope = try AgentFiles(workspace: checkout.path, followParentLinks: false)
        return try scope.fileHash(scope.literalURL(".git"), maximum: 8192)
    }

    private func worktreeRecycleHoldingURL(_ checkout: URL, id: String) -> URL {
        checkout.deletingLastPathComponent().appendingPathComponent(".bluefatfish-recycle-" + id, isDirectory: true)
    }

    func heldWorktreeRecyclePath(_ backup: AgentWorktreeBackup) -> String? {
        guard backup.state == "recycling", let progress = backup.recycle, let checkout = try? worktreeBackupCheckout(backup) else { return nil }
        let held = worktreeRecycleHoldingURL(checkout, id: backup.id)
        return (try? directoryIdentity(held)) == progress.checkout ? held.path : nil
    }

    private func finishWorktreeRecycle(_ saved: AgentWorktreeBackup, folder: URL, checkout: URL, savedTree: AgentWorktreeSnapshot.Value) async throws -> AgentWorktreeBackup {
        var backup = saved
        let record = folder.appendingPathComponent("record.json")
        let backupMetadata = try worktreeMetadataFiles(folder.appendingPathComponent("metadata")).mapValues(AgentFiles.hash)
        let headRef = "refs/bluefatfish/worktree-backups/" + backup.id.lowercased() + "/head"
        let indexRef = "refs/bluefatfish/worktree-backups/" + backup.id.lowercased() + "/index"
        guard savedTree.hash == backup.treeHash, backupMetadata["index"] == backup.indexHash,
              let indexTree = backup.indexTree, backup.objectRefs == [headRef, indexRef],
              try await output(["rev-parse", headRef, indexRef]).split(whereSeparator: \.isNewline).map(String.init) == [backup.head, indexTree] else {
            throw PetError("回收备份或 Git 快照引用已变化，原有文件保留")
        }
        let entries = try await worktrees(), parent = checkout.deletingLastPathComponent()
        let matches = entries.filter { $0.path == checkout.path }
        try validateWorktreeRecyclePermission()
        if var progress = backup.recycle {
            guard backupMetadata == progress.metadataHashes, try directoryIdentity(parent) == progress.registration.parent else {
                throw PetError("备份或原上级目录已变化，现有文件保留")
            }
            let origin = try worktreeRegistrationOriginal(progress.registration)
            let holding = worktreeRecycleHoldingURL(checkout, id: backup.id)
            let archived = try protectedRegistrationPath(worktreeRegistrationBackupURL(backup.id))
            let lockReason = Data(("BlueFatFish recycle " + backup.id + "\n").utf8)
            if !nonexistentWorktreePath(origin) {
                guard try directoryIdentity(origin) == progress.registration.metadata, nonexistentWorktreePath(archived),
                      try registeredCheckoutLink(origin) == checkout.path + "/.git", matches.count == 1,
                      let entry = matches.first, entry.head == backup.head, entry.branch == backup.branch,
                      Set(entry.taskIDs) == Set(backup.tasks.keys) else { throw PetError("原 Git 登记、分支或关联任务已变化，现有文件保留") }
                try checkRecyclingTaskActivity(backup)
                let scope = try AgentFiles(workspace: origin.path, followParentLinks: false), lockFile = try scope.literalURL("locked")
                if try scope.entryMetadata(lockFile).kind == "missing" {
                    try scope.writeData(lockReason, to: lockFile, permissions: 0o600, expectedTarget: "missing")
                }
                guard try scope.readData(lockFile, maximum: 1024) == lockReason else { throw PetError("该工作树已被其他 Git 操作锁定") }
                defer {
                    if nonexistentWorktreePath(holding), (try? directoryIdentity(checkout)) == progress.checkout,
                       (try? directoryIdentity(origin)) == progress.registration.metadata,
                       (try? scope.readData(lockFile, maximum: 1024)) == lockReason { try? scope.remove(lockFile) }
                }
                guard let indexLock = try AgentWorktreeIndexLock(metadata: origin.path, operation: backup.id, mode: .recover, prefix: "recycle", label: "回收") else {
                    throw PetError("无法建立 Git 回收锁")
                }
                defer { try? indexLock.release() }
                try checkWorktreeMetadataIdle(origin, allowingLocked: true, holdingIndex: indexLock.holdsIndex)
                if nonexistentWorktreePath(holding) {
                    guard try directoryIdentity(checkout) == progress.checkout else { throw PetError("原工作树目录已变化，现有文件保留") }
                    let live = try await worktreeSnapshot(checkout.path)
                    var eligible = entry
                    eligible.unavailable = nil // The pending status is this operation's own claim.
                    try validateWorktreeEligibility(eligible, tree: live, metadata: origin)
                    let liveMetadata = try worktreeMetadataFiles(origin).mapValues(AgentFiles.hash)
                    if live.hash != savedTree.hash || liveMetadata != backupMetadata || (try? worktreeCheckoutLinkHash(checkout)) != progress.checkoutLink {
                        // The original checkout still exists. Release our claim so
                        // the user can review its new contents without losing the backup.
                        try validateWorktreeRecyclePermission()
                        guard try directoryIdentity(checkout) == progress.checkout, try directoryIdentity(origin) == progress.registration.metadata,
                              try scope.readData(lockFile, maximum: 1024) == lockReason else { throw PetError("工作树或 Git 锁已变化，现有文件保留") }
                        try scope.remove(lockFile)
                        backup.state = "prepared"; backup.recycle = nil; try saveWorktree(backup, record)
                        throw PetError("原文件或暂存状态已变化，请重新审阅")
                    }
                    try validateWorktreeRecyclePermission(); try checkRecyclingTaskActivity(backup)
                    guard try directoryIdentity(parent) == progress.registration.parent, indexLock.holdsIndex else {
                        throw PetError("原上级目录或暂存锁已变化，现有文件保留")
                    }
                    try moveWorktreeDirectory(checkout, to: holding, in: parent, identity: progress.checkout)
                }
                guard nonexistentWorktreePath(checkout), try directoryIdentity(holding) == progress.checkout else {
                    throw PetError("原路径已占用或回收目录已变化，现有文件保留")
                }
                let heldTree = try await worktreeSnapshot(holding.path)
                guard heldTree.hash == savedTree.hash, try worktreeCheckoutLinkHash(holding) == progress.checkoutLink,
                      try worktreeMetadataFiles(origin).mapValues(AgentFiles.hash) == backupMetadata else {
                    throw PetError("回收目录或暂存区有新改动，请先在访达中保留改动")
                }
                let current = try await worktrees()
                try validateWorktreeRecyclePermission(); try checkRecyclingTaskActivity(backup)
                guard indexLock.holdsIndex, nonexistentWorktreePath(checkout), try directoryIdentity(parent) == progress.registration.parent,
                      try scope.readData(lockFile, maximum: 1024) == lockReason,
                      current.contains(where: { $0.path == checkout.path && $0.head == backup.head && $0.branch == backup.branch && Set($0.taskIDs) == Set(backup.tasks.keys) }) else {
                    throw PetError("原路径、Git 登记或关联任务已变化，现有文件保留")
                }
                try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try moveWorktreeDirectory(origin, to: archived, in: directory, identity: progress.registration.metadata)
                try indexLock.release()
            } else {
                guard matches.isEmpty, try directoryIdentity(archived) == progress.registration.metadata else {
                    throw PetError("无法确认已移出的 Git 登记，现有文件保留")
                }
                let indexLock = try AgentWorktreeIndexLock(metadata: archived.path, operation: backup.id, mode: .cleanup, prefix: "recycle", label: "回收")
                try indexLock?.release()
            }
            guard nonexistentWorktreePath(checkout), try directoryIdentity(archived) == progress.registration.metadata else {
                throw PetError("原路径或回收的 Git 登记已变化，现有文件保留")
            }
            if !nonexistentWorktreePath(holding) {
                guard try directoryIdentity(holding) == progress.checkout else { throw PetError("回收目录已变化，现有文件保留") }
                async let recheckedBackup = worktreeSnapshot(folder.appendingPathComponent("files").path)
                let remaining = try await worktreeSnapshot(holding.path)
                let expected = Dictionary(uniqueKeysWithValues: savedTree.items.map { ($0.path, $0) })
                let link = holding.appendingPathComponent(".git")
                guard try await recheckedBackup.hash == backup.treeHash,
                      try worktreeMetadataFiles(folder.appendingPathComponent("metadata")).mapValues(AgentFiles.hash) == backupMetadata else {
                    throw PetError("回收备份已变化，现有文件保留")
                }
                guard (progress.cleanupStarted || remaining.hash == savedTree.hash),
                      remaining.items.allSatisfy({ expected[$0.path] == $0 }),
                      (progress.cleanupStarted && nonexistentWorktreePath(link)) || (try? worktreeCheckoutLinkHash(holding)) == progress.checkoutLink else {
                    throw PetError("回收目录有新改动，请先在访达中保留改动")
                }
                try validateWorktreeRecyclePermission(); try checkRecyclingTaskActivity(backup)
                guard nonexistentWorktreePath(checkout), try directoryIdentity(parent) == progress.registration.parent,
                      try directoryIdentity(holding) == progress.checkout, try directoryIdentity(archived) == progress.registration.metadata else {
                    throw PetError("回收目录已变化，现有文件保留")
                }
                progress.cleanupStarted = true; backup.recycle = progress; try saveWorktree(backup, record)
                let cleanup = Task.detached { try Task.checkCancellation(); try FileManager.default.removeItem(at: holding) }
                try await withTaskCancellationHandler { try await cleanup.value } onCancel: { cleanup.cancel() }
            } else if !progress.cleanupStarted {
                throw PetError("回收目录缺失，备份保留供核对")
            }
        } else {
            let originalParent = try directoryIdentity(parent)
            guard matches.isEmpty, nonexistentWorktreePath(checkout), backup.external == nil || backup.external?.parent == originalParent else {
                throw PetError("原目录或 Git 登记仍存在，备份与任务保留")
            }
        }
        try validateWorktreeRecyclePermission(); try checkRecyclingTaskActivity(backup)
        guard nonexistentWorktreePath(checkout) else { throw PetError("原路径已有其他内容，备份与任务保留") }
        try commitWorktreeRecycleTasks(backup, folder: folder)
        backup.state = "recycled"; try saveWorktree(backup, record)
        return backup
    }

    private func checkRecyclingTaskActivity(_ backup: AgentWorktreeBackup) throws {
        for id in backup.tasks.keys {
            guard let task = store.task(id) else { continue }
            if [.running, .waiting].contains(task.status) || task.pendingFileCapture != nil || task.pendingFileRollback != nil || store.hooks.isRunning(id) {
                throw PetError("关联任务正在运行，请结束后继续回收")
            }
            if !task.managedWorktreeOrigins.isEmpty, try AgentWorktreeHandoff(store: store, taskID: id).pendingRecovery() != nil {
                throw PetError("关联任务有中断的工作树移交，请先处理移交")
            }
        }
    }

    private func commitWorktreeRecycleTasks(_ backup: AgentWorktreeBackup, folder: URL) throws {
        let path = backup.origin.path
        var archived: Set<String> = []
        for id in backup.tasks.keys.sorted() {
            guard var task = store.task(id), task.workspacePaths.contains(where: { AgentWorktreeRetention.within(canonical($0), path) }) else { continue }
            let version = try store.recordVersion(id)
            archived.insert(id)
            guard !task.events.contains(where: { $0.id == backup.id }) else { continue }
            if task.workspacePaths.count > 1, task.worktreeRecycleArchived == nil { task.worktreeRecycleArchived = task.archived }
            task.archived = true; task.gitReview = nil; task.gitPushReview = nil; task.updated = Date()
            task.events.append(AgentEvent(id: backup.id, kind: "git", title: "工作树已回收", detail: path + "\n备份：" + backup.id, status: "completed"))
            try store.commitTaskRecord(task, expectedHash: version, transaction: folder.appendingPathComponent("task-" + UUID().uuidString), label: "回收工作树")
        }
        if let selection = store.selectedID, archived.contains(selection) { store.selectedID = taskID }
    }
    func restoreWorktree(backupID: String) async throws -> AgentWorktreeBackup {
        try validateWorktreeRestore()
        guard UUID(uuidString: backupID) != nil else { throw PetError("没有当前项目的回收记录") }
        _ = try worktreeBackup(backupID)
        let folder = try worktreeFile(backupID)
        let lease = try AgentWorktreeLease(in: folder, label: "恢复")
        defer { withExtendedLifetime(lease) {} }
        var backup = try worktreeBackup(backupID)
        guard backup.canRestore else { throw PetError("该回收记录已处理或需要手动核对") }
        if let registration = backup.registration { return try await restoreWorktreeRegistration(backup, registration: registration) }
        let record = folder.appendingPathComponent("record.json")
        let destination = try worktreeBackupCheckout(backup)
        let externalWorktree = backup.external.map { _ in destination }
        let parent = destination.deletingLastPathComponent()
        let fm = FileManager.default, copy = folder.appendingPathComponent("files")
        let backupMetadata = try worktreeMetadataFiles(folder.appendingPathComponent("metadata"))
        let hashes = backupMetadata.mapValues(AgentFiles.hash)
        let tree = try await worktreeSnapshot(copy.path)
        guard tree.hash == backup.treeHash, hashes["index"] == backup.indexHash,
              backup.restore?.savedMetadata == nil || backup.restore?.savedMetadata == hashes else { throw PetError("回收备份已变化，未恢复") }
        try await validateHooks()
        try validateWorktreeRestore()
        if let external = backup.external {
            guard try externalWorktreeURL(destination.path) == destination, try directoryIdentity(parent) == external.parent else { throw PetError("原上级目录已变化，请接回原目录后重试") }
        } else if backup.restore == nil {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let parentIdentity = try directoryIdentity(parent)
        var entries = try await worktrees()
        if backup.restore == nil {
            guard nonexistentWorktreePath(destination), entries.allSatisfy({ $0.path != destination.path }) else {
                throw PetError("原路径或工作树登记已存在，未覆盖任何文件")
            }
            let branch: String?
            if let old = backup.branch {
                let current = try await run(["rev-parse", "--verify", old])
                branch = !current.failed && current.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == backup.head && !entries.contains(where: { $0.branch == old })
                    ? old : "refs/heads/recovered/" + backup.id.lowercased()
            } else { branch = nil }
            backup.restore = AgentWorktreeRestore(parent: parentIdentity, branch: branch, savedMetadata: hashes)
            backup.state = "restoring"; try saveWorktree(backup, record)
        }
        guard var restore = backup.restore, restore.parent == parentIdentity else { throw PetError("原上级目录已变化，请接回原目录后重试") }
        var addedHere = false
        if nonexistentWorktreePath(destination), entries.allSatisfy({ $0.path != destination.path }), restore.checkout == nil {
            let args = try await worktreeRestoreArguments(restore, backup: backup)
            try validateWorktreeRestore()
            guard try directoryIdentity(parent) == restore.parent, nonexistentWorktreePath(destination) else { throw PetError("原目录已变化，备份保留") }
            let added = try await run(args, write: true, externalWorktree: externalWorktree, leaseDescriptor: lease.descriptor)
            guard !added.failed else { throw PetError("Git 未完成恢复登记，备份保留：" + added.text) }
            addedHere = true
            entries = try await worktrees()
        }
        guard let entry = entries.first(where: { $0.path == destination.path }),
              entry.locked == restore.lockReason || (restore.readyToUnlock && entry.locked == nil) else {
            throw PetError("无法核对这次恢复创建的 Git 登记。原目录与备份已保留。")
        }
        let metadata = try await worktreeMetadata(destination.path, externalWorktree: externalWorktree)
        let checkout = try directoryIdentity(destination), admin = try directoryIdentity(metadata)
        guard try directoryIdentity(parent) == restore.parent, try registeredCheckoutLink(metadata) == destination.path + "/.git",
              restore.checkout == nil || restore.checkout == checkout,
              restore.metadata == nil || restore.metadata == admin else { throw PetError("恢复目录或 Git 登记已变化，备份保留") }
        if !restore.readyToUnlock {
            guard entry.head == backup.head, entry.branch == restore.branch else { throw PetError("恢复目录的分支或提交已变化，备份保留") }
            try validateWorktreeRestore(entry: entry)
            guard let lock = try AgentWorktreeIndexLock(metadata: metadata.path, operation: restore.id.uuidString, mode: .recover, prefix: "restore", label: "恢复") else { throw PetError("无法建立 Git 恢复锁") }
            defer { try? lock.release() }
            try checkWorktreeMetadataIdle(metadata, allowingLocked: true, holdingIndex: lock.holdsIndex)
            let initial = try worktreeMetadataFiles(metadata).mapValues(AgentFiles.hash)
            if restore.checkout == nil {
                restore.checkout = checkout; restore.metadata = admin
                // Git may seed a per-worktree config while adding the checkout.
                // Only take it as a baseline in the attempt that created it.
                restore.initialMetadata = addedHere ? initial.filter { $0.key == "config.worktree" } : [:]
                backup.restore = restore; try saveWorktree(backup, record)
            }
            let current = try await worktreeSnapshot(destination.path)
            let groups = tree.topLevel, present = current.topLevel
            if let conflict = present.keys.sorted().first(where: { present[$0] != groups[$0] }) {
                throw PetError("目标已有变化：" + conflict + "。请保留这些改动后再继续恢复。")
            }
            try validateRestoreMetadata(initial, saved: hashes, initial: restore.initialMetadata ?? [:])
            let missing = groups.keys.filter { present[$0] == nil }.sorted()
            if let old = restore.staging {
                let directory = parent.appendingPathComponent(old.name)
                guard old.name.hasPrefix(restore.stagingName + "."),
                      UUID(uuidString: String(old.name.dropFirst(restore.stagingName.count + 1))) != nil,
                      try directoryIdentity(parent) == restore.parent else { throw PetError("恢复临时目录已变化，备份保留") }
                if !nonexistentWorktreePath(directory) {
                    guard try directoryIdentity(directory) == old.identity else { throw PetError("恢复临时目录已变化，备份保留") }
                    try fm.removeItem(at: directory)
                }
                restore.staging = nil
            }
            if !missing.isEmpty {
                let stage = parent.appendingPathComponent(restore.stagingName + "." + UUID().uuidString, isDirectory: true)
                guard try directoryIdentity(parent) == restore.parent, mkdir(stage.path, 0o700) == 0 else { throw PetError("无法建立恢复临时目录") }
                restore.staging = try AgentWorktreeRestore.Directory(name: stage.lastPathComponent, identity: directoryIdentity(stage))
                backup.restore = restore; try saveWorktree(backup, record)
                let job = Task.detached {
                    for name in missing {
                        try Task.checkCancellation()
                        try FileManager.default.copyItem(at: copy.appendingPathComponent(name), to: stage.appendingPathComponent(name))
                    }
                    return try AgentWorktreeSnapshot.read(stage).topLevel
                }
                let staged = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                guard staged == groups.filter({ present[$0.key] == nil }) else { throw PetError("恢复临时文件与备份不一致") }
                try validateWorktreeRestore(entry: entry)
                guard let staging = restore.staging, try directoryIdentity(parent) == restore.parent else { throw PetError("恢复上级目录已变化，备份保留") }
                try installWorktreeFiles(missing, from: stage, stageIdentity: staging.identity, to: destination, checkoutIdentity: checkout)
                guard try directoryIdentity(stage) == staging.identity else { throw PetError("恢复临时目录已变化，备份保留") }
                try fm.removeItem(at: stage); restore.staging = nil
            }
            guard try await worktreeSnapshot(destination.path).hash == backup.treeHash,
                  try directoryIdentity(parent) == restore.parent, try directoryIdentity(destination) == checkout,
                  try directoryIdentity(metadata) == admin, lock.holdsIndex else { throw PetError("恢复结果已变化，备份保留") }
            let currentMetadata = try worktreeMetadataFiles(metadata).mapValues(AgentFiles.hash)
            try validateRestoreMetadata(currentMetadata, saved: hashes, initial: restore.initialMetadata ?? [:])
            let scope = try AgentFiles(workspace: metadata.path, followParentLinks: false)
            // Install split-index dependencies before making the saved index visible.
            let names = backupMetadata.keys.sorted { ($0 == "index" ? 1 : 0, $0) < ($1 == "index" ? 1 : 0, $1) }
            for name in names where currentMetadata[name] != hashes[name] {
                let url = try scope.literalURL(name)
                let signature = try scope.entryMetadata(url).signature
                if signature != "missing" {
                    guard AgentFiles.hash(try scope.readPrefix(url, maximum: Int.max).data) == currentMetadata[name] else { throw PetError("Git 暂存状态已变化：" + name) }
                }
                try scope.writeData(backupMetadata[name]!, to: url, permissions: 0o600, expectedTarget: signature)
            }
            // A retry can reach this point with all files installed but tasks still archived.
            let expectedMetadata = (restore.initialMetadata ?? [:]).merging(hashes, uniquingKeysWith: { _, saved in saved })
            guard try worktreeMetadataFiles(metadata).mapValues(AgentFiles.hash) == expectedMetadata else {
                throw PetError("恢复后的 Git 暂存状态与备份不一致")
            }
            try await verifyRestoredWorktree(backup, restore: restore, destination: destination, externalWorktree: externalWorktree)
            try validateWorktreeRestore(entry: entry)
            try restoreWorktreeTasks(backup, restore: restore, destination: destination, folder: folder)
            restore.readyToUnlock = true; backup.restore = restore; try saveWorktree(backup, record)
            try lock.release()
        } else if entry.locked != nil,
                  let lock = try AgentWorktreeIndexLock(metadata: metadata.path, operation: restore.id.uuidString, mode: .cleanup, prefix: "restore", label: "恢复") {
            try lock.release()
        }
        if entry.locked != nil {
            let lockFile = metadata.appendingPathComponent("locked")
            let scope = try AgentFiles(workspace: metadata.path, followParentLinks: false)
            guard try directoryIdentity(metadata) == admin,
                  try scope.readData(lockFile, maximum: 1024) == Data((restore.lockReason + "\n").utf8) else {
                throw PetError("Git 锁已变化，备份保留")
            }
            let unlocked = try await run(["worktree", "unlock", "--", destination.path], write: true, externalWorktree: externalWorktree, leaseDescriptor: lease.descriptor)
            guard !unlocked.failed else { throw PetError("文件与任务已恢复，Git 锁尚未释放：" + unlocked.text) }
        }
        backup.state = "restored"; backup.restoredBranch = restore.branch; backup.restore = nil
        try saveWorktree(backup, record)
        return backup
    }

    private func validateWorktreeRestore(entry: AgentWorktreeEntry? = nil) throws {
        try Task.checkCancellation(); try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-restore", name: "git_restore_worktree", arguments: "{}"), task: task, store: store) }
        if let entry, entry.taskIDs.contains(where: { id in
            guard let task = store.task(id) else { return false }
            return [.running, .waiting].contains(task.status) || task.pendingFileCapture != nil || task.pendingFileRollback != nil || store.hooks.isRunning(id)
        }) { throw PetError("关联任务正在运行，请结束后继续恢复") }
    }

    private func worktreeRestoreArguments(_ restore: AgentWorktreeRestore, backup: AgentWorktreeBackup) async throws -> [String] {
        let args = ["worktree", "add", "--no-checkout", "--lock", "--reason", restore.lockReason]
        guard let branch = restore.branch else { return args + ["--detach", "--", backup.origin.path, backup.head] }
        guard branch.hasPrefix("refs/heads/") else { throw PetError("备份分支名称无效") }
        let name = String(branch.dropFirst("refs/heads/".count))
        let current = try await run(["rev-parse", "--verify", branch])
        if !current.failed {
            guard current.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == backup.head else { throw PetError("恢复分支已指向其他提交，备份保留") }
            return args + ["--", backup.origin.path, name]
        }
        guard branch != backup.branch else { throw PetError("原分支已变化，请核对备份与 Git 分支") }
        return args + ["-b", name, "--", backup.origin.path, backup.head]
    }

    private func worktreeMetadataFiles(_ directory: URL) throws -> [String: Data] {
        let files = try AgentFiles(workspace: directory.path, followParentLinks: false)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var result: [String: Data] = [:]
        for name in entries where name == "index" || name == "config.worktree" || name.hasPrefix("sharedindex.") {
            let url = try files.literalURL(name)
            guard try files.entryMetadata(url).kind == "file" else { throw PetError("Git 元数据包含特殊文件：" + name) }
            result[name] = try files.readPrefix(url, maximum: Int.max).data
        }
        return result
    }

    private func validateRestoreMetadata(_ current: [String: String], saved: [String: String], initial: [String: String]) throws {
        if let name = current.keys.sorted().first(where: { current[$0] != saved[$0] && current[$0] != initial[$0] }) {
            throw PetError("Git 暂存状态已变化：" + name + "。请先保留这些改动。")
        }
    }

    private func installWorktreeFiles(_ names: [String], from stage: URL, stageIdentity: String, to target: URL, checkoutIdentity: String) throws {
        let stageFD = open(stage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stageFD >= 0 else { throw PetError("恢复临时目录不可用") }
        defer { close(stageFD) }
        let targetFD = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard targetFD >= 0 else { throw PetError("原工作树目录不可用") }
        defer { close(targetFD) }
        func matches(_ fd: Int32, _ url: URL, _ identity: String) throws -> Bool {
            var opened = stat(), existing = stat()
            return try fstat(fd, &opened) == 0 && lstat(url.path, &existing) == 0 && opened.st_ino == existing.st_ino
                && opened.st_dev == existing.st_dev && directoryIdentity(url) == identity
        }
        for name in names {
            try Task.checkCancellation()
            guard try matches(stageFD, stage, stageIdentity), try matches(targetFD, target, checkoutIdentity) else { throw PetError("恢复目录已变化，备份保留") }
            guard renameatx_np(stageFD, name, targetFD, name, UInt32(RENAME_EXCL)) == 0 else {
                throw PetError("未能放入恢复文件：" + name + "。请检查目标是否已被占用。")
            }
        }
    }

    private func verifyRestoredWorktree(_ backup: AgentWorktreeBackup, restore: AgentWorktreeRestore, destination: URL, externalWorktree: URL?) async throws {
        let prefix = ["-C", destination.path]
        let readable = try await run(prefix + ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--numstat", backup.head, "--"], maximumOutput: 1024, externalWorktree: externalWorktree)
        guard !readable.failed else { throw PetError("恢复的暂存内容无法读取，备份保留：" + readable.text) }
        let head = try await run(prefix + ["rev-parse", "HEAD"], externalWorktree: externalWorktree)
        let branch = try await run(prefix + ["symbolic-ref", "--quiet", "HEAD"], externalWorktree: externalWorktree)
        guard !head.failed, head.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == backup.head,
              branch.exitCode == (restore.branch == nil ? 1 : 0),
              (branch.failed ? nil : branch.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)) == restore.branch else {
            throw PetError("恢复后的分支或提交已变化，备份保留")
        }
    }

    private func restoreWorktreeTasks(_ backup: AgentWorktreeBackup, restore: AgentWorktreeRestore, destination: URL, folder: URL) throws {
        for (id, archived) in backup.tasks where store.task(id)?.workspacePaths.contains(where: { canonical($0) == destination.path || canonical($0).hasPrefix(destination.path + "/") }) == true {
            guard var task = store.task(id) else { continue }
            let version = try store.recordVersion(id)
            guard !task.events.contains(where: { $0.id == restore.id.uuidString }) else { continue }
            let available = (try? AgentWorkspaceScope.roots(task)) != nil && task.managedWorktreeOrigins.allSatisfy { origin in
                (try? AgentFiles(workspace: origin.path).root.path) == origin.path && (try? Self.metadata(workspace: origin.path).path) == origin.metadata
            }
            if available { task.archived = task.worktreeRecycleArchived ?? archived; task.worktreeRecycleArchived = nil }
            else { task.archived = true }
            task.gitReview = nil; task.gitPushReview = nil; task.updated = Date()
            task.events.append(AgentEvent(id: restore.id.uuidString, kind: "git", title: "工作树已恢复", detail: destination.path + "\n" + (restore.branch ?? "分离状态") + (available ? "" : "\n仍有源文件夹待恢复，任务保持归档。"), status: "completed"))
            try store.commitTaskRecord(task, expectedHash: version, transaction: folder.appendingPathComponent("task-" + UUID().uuidString), label: "恢复工作树")
        }
    }
}
