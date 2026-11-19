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
struct AgentWorktreeBackup: Codable {
    var id: String; var origin: AgentWorktreeOrigin; var head: String; var branch: String?
    var treeHash: String; var indexHash: String; var created = Date(); var tasks: [String: Bool]
    var state = "prepared"; var restoredBranch: String?
    var objectRefs: [String]?; var indexTree: String?
    var external: AgentExternalWorktreeIdentity? = nil
    var registration: AgentMissingWorktreeRegistration? = nil
}
struct AgentWorktreeRecycleReview: Codable {
    static let processID = UUID().uuidString
    var taskID: String; var processID = Self.processID; var path: String; var hash: String
    var fingerprint: String; var head: String; var branch: String?; var files: Int; var bytes: UInt64
    var taskIDs: [String]; var created = Date()
    var external: AgentExternalWorktreeIdentity? = nil
    var registration: AgentMissingWorktreeRegistration? = nil
}

private struct AgentWorktreeRecycleTarget {
    let entry: AgentWorktreeEntry
    let metadata: URL
    let external: AgentExternalWorktreeIdentity?
    var externalURL: URL? { external.map { _ in URL(fileURLWithPath: entry.path, isDirectory: true) } }
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
    private func directoryIdentity(_ url: URL) throws -> String {
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
        let archivedPaths = try allWorktreeBackups().map { canonical($0.origin.path) }
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
            entries[i].owned = store.tasks.contains { task in
                if !task.managedWorktreeOrigins.isEmpty { return task.managedWorktreeOrigins.contains { canonical($0.root) == files.root.path && canonical($0.metadata) == canonical(directory.path) && canonical($0.path) == path } }
                // Earlier releases recorded native creation in the task history.
                guard task.parentID != nil, canonical(task.gitDirectory ?? "") == canonical(directory.path), path.hasPrefix(files.root.path + "/.bluefatfish/worktrees/"), UUID(uuidString: URL(fileURLWithPath: path).lastPathComponent) != nil else { return false }
                return store.task(task.id)?.events.contains { $0.kind == "git" && $0.title == "已创建工作树" && $0.detail.hasSuffix("\n" + path) } == true
            }
            if path == files.root.path { entries[i].unavailable = "当前工作树" }
            else if i == 0 || entries[i].bare { entries[i].unavailable = "主工作树" }
            else if !entries[i].owned && !allowsExternalWorktrees { entries[i].unavailable = "外部工作树" }
            else if entries[i].locked != nil { entries[i].unavailable = "工作树已锁定" }
            else if related.contains(where: { [.running, .waiting].contains($0.status) || $0.pendingFileCapture != nil || $0.pendingFileRollback != nil || store.hooks.isRunning($0.id) }) { entries[i].unavailable = "关联任务正在运行或等待处理" }
            else if entries[i].prunable != nil, Self.isWorktreeObject(entries[i].head ?? ""), listed == path, (try? missingWorktreePath(path)) != nil { entries[i].missingRegistration = true }
            else if entries[i].prunable != nil || entries[i].head == nil || !FileManager.default.fileExists(atPath: path) { entries[i].unavailable = "路径不可用，请先在本地 Git 修复" }
            else if !entries[i].owned && (listed != path || (try? externalWorktreeURL(path)) == nil) { entries[i].unavailable = "外部路径已变化或不可回收" }
            else if !entries[i].owned && listedPaths.contains(where: { $0.hasPrefix(path + "/") }) { entries[i].unavailable = "包含其他工作树" }
        }
        return entries
    }
    private func recyclable(_ requested: String) async throws -> AgentWorktreeRecycleTarget {
        try validateWorkspace()
        let path = canonical(requested)
        guard let entry = try await worktrees().first(where: { $0.path == path }), entry.unavailable == nil, entry.missingRegistration != true, let head = entry.head, !head.isEmpty else { throw PetError("工作树不可回收，请刷新并处理关联任务或锁定状态") }
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
    private func checkWorktreeMetadataIdle(_ metadata: URL) throws {
        for name in ["index.lock", "HEAD.lock", "locked", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
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
    private func retainWorktreeObjects(_ backup: inout AgentWorktreeBackup, index: Data?, externalWorktree: URL? = nil, registration: URL? = nil) async throws {
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
            let tree = try await run(location + ["write-tree"], write: true, environment: ["GIT_INDEX_FILE": temporaryIndex.path], externalWorktree: externalWorktree, metadataOnly: registration != nil)
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
        let saved = try await run(["update-ref", "--stdin"], write: true, inputFile: input, externalWorktree: externalWorktree, metadataOnly: registration != nil)
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
        let worktrees = try protectedRegistrationPath(directory.appendingPathComponent("worktrees", isDirectory: true))
        let candidates = try FileManager.default.contentsOfDirectory(at: worktrees, includingPropertiesForKeys: nil).filter { url in
            (try? directoryIdentity(url)) != nil && (try? registeredCheckoutLink(url)) == path + "/.git"
        }
        guard candidates.count == 1, let metadata = candidates.first else { throw PetError("无法唯一确认这条 Git 登记") }
        try checkWorktreeMetadataIdle(metadata)
        let registration = try AgentMissingWorktreeRegistration(name: metadata.lastPathComponent, parent: directoryIdentity(checkout.deletingLastPathComponent()), metadata: directoryIdentity(metadata))
        return (entry, metadata, registration)
    }
    func prepareMissingWorktreeRecycle(path: String) async throws -> AgentWorktreeRecycleReview {
        let target = try await missingRegistrationTarget(path), snapshot = try await worktreeSnapshot(target.metadata.path)
        return AgentWorktreeRecycleReview(taskID: taskID, path: path, hash: UUID().uuidString,
            fingerprint: fingerprint(target.entry, tree: snapshot.hash, index: Data()), head: target.entry.head!, branch: target.entry.branch,
            files: snapshot.count, bytes: snapshot.bytes, taskIDs: target.entry.taskIDs, registration: target.registration)
    }
    private func moveWorktreeRegistration(_ from: URL, to: URL) throws {
        let scope = try AgentFiles(workspace: directory.path, followParentLinks: false)
        let (fromParent, fromName) = try scope.parentDescriptor(from, create: false); defer { close(fromParent) }
        let (toParent, toName) = try scope.parentDescriptor(to, create: false); defer { close(toParent) }
        var source = stat()
        guard fstatat(fromParent, fromName, &source, AT_SYMLINK_NOFOLLOW) == 0, source.st_mode & S_IFMT == S_IFDIR else { throw PetError("Git 登记目录已变化") }
        guard renameatx_np(fromParent, fromName, toParent, toName, UInt32(RENAME_EXCL)) == 0 else {
            let error = String(cString: strerror(errno)); throw PetError("Git 登记移动未完成：" + error)
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
        let review = try storedWorktreeReview(hash: reviewHash), target = try await recyclable(review.path), entry = target.entry
        guard target.external == review.external else { throw PetError("工作树目录身份已变化，请重新审阅") }
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-recycle", name: "git_recycle_worktree", arguments: "{}"), task: task, store: store) }
        let metadata = target.metadata, index = try worktreeIndex(metadata), tree = try await worktreeSnapshot(entry.path)
        try validateWorktreeEligibility(entry, tree: tree, metadata: metadata)
        guard fingerprint(entry, tree: tree.hash, index: index) == review.fingerprint else { throw PetError("工作树内容、分支或关联任务已变化，请重新审阅") }
        let id = UUID().uuidString, folder = try worktreeFile(id), copy = folder.appendingPathComponent("files"), meta = folder.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = AgentCommand(); worktreeCopy = process; defer { worktreeCopy = nil }
        let result = try await process.run(command: "/usr/bin/ditto", workspace: files.root, scratch: folder, network: false, timeout: 1800, readOnly: true, gitDirectory: directory, protectedData: store.directory.deletingLastPathComponent(), readRoots: target.externalURL.map { [$0] } ?? [], arguments: [entry.path, copy.path])
        guard !result.failed else { throw PetError("备份未完成，工作树未回收：" + result.text) }
        for file in try FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil) where file.lastPathComponent == "index" || file.lastPathComponent == "config.worktree" || file.lastPathComponent.hasPrefix("sharedindex.") {
            _ = try AgentFiles(workspace: metadata.path).resolve(file.lastPathComponent)
            guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw PetError("Git 元数据包含特殊文件，请先在本地 Git 处理") }
            try FileManager.default.copyItem(at: file, to: meta.appendingPathComponent(file.lastPathComponent))
        }
        guard try await worktreeSnapshot(copy.path).hash == tree.hash, try Data(contentsOf: meta.appendingPathComponent("index")) == index else { throw PetError("备份与审阅内容不一致，工作树未回收") }
        var backup = AgentWorktreeBackup(id: id, origin: AgentWorktreeOrigin(root: files.root.path, metadata: directory.path, path: entry.path), head: entry.head!, branch: entry.branch, treeHash: tree.hash, indexHash: AgentFiles.hash(index), tasks: Dictionary(uniqueKeysWithValues: entry.taskIDs.compactMap { id in store.task(id).map { (id, $0.archived) } }), external: target.external)
        try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        let current = try await recyclable(entry.path), finalTree = try await worktreeSnapshot(entry.path), finalIndex = try worktreeIndex(metadata)
        try validateWorktreeEligibility(current.entry, tree: finalTree, metadata: metadata)
        guard current.external == review.external, current.metadata == metadata, fingerprint(current.entry, tree: finalTree.hash, index: finalIndex) == review.fingerprint else { throw PetError("备份期间工作树已变化，原工作树保留，请重新审阅") }
        try Task.checkCancellation(); try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-recycle", name: "git_recycle_worktree", arguments: "{}"), task: task, store: store) }
        try await retainWorktreeObjects(&backup, index: index, externalWorktree: target.externalURL)
        try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        let pinned = try await recyclable(entry.path), pinnedTree = try await worktreeSnapshot(entry.path), pinnedIndex = try worktreeIndex(metadata)
        try validateWorktreeEligibility(pinned.entry, tree: pinnedTree, metadata: metadata)
        guard pinned.external == review.external, pinned.metadata == metadata, fingerprint(pinned.entry, tree: pinnedTree.hash, index: pinnedIndex) == review.fingerprint else { throw PetError("保存快照期间工作树已变化，原工作树保留") }
        try Task.checkCancellation(); try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-recycle", name: "git_recycle_worktree", arguments: "{}"), task: task, store: store) }
        try FileManager.default.removeItem(at: worktreeFile(worktreeReviewName))
        let removed = try await run(["worktree", "remove", "--force", "--", entry.path], write: true, externalWorktree: target.externalURL)
        guard !removed.failed else { throw PetError("Git 未完成回收，备份已保留（" + id + "）：" + removed.text) }
        backup.state = "recycled"; try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        for id in entry.taskIDs { store.update(id) {
            if $0.workspacePaths.count > 1, $0.worktreeRecycleArchived == nil { $0.worktreeRecycleArchived = $0.archived }
            $0.archived = true; $0.gitReview = nil; $0.gitPushReview = nil; $0.events.append(AgentEvent(kind: "git", title: "工作树已回收", detail: entry.path + "\n备份：" + backup.id, status: "completed"))
        } }
        if entry.taskIDs.contains(store.selectedID ?? "") { store.selectedID = taskID }
        if let error = store.writeError { throw PetError("工作树已回收，关联任务保存失败；备份：" + id + "\n" + error) }
        return backup
    }
    func restoreWorktree(backupID: String) async throws -> AgentWorktreeBackup {
        try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-restore", name: "git_restore_worktree", arguments: "{}"), task: task, store: store) }
        var backup = try worktreeBackup(backupID)
        guard ["prepared", "recycled"].contains(backup.state) else { throw PetError("该回收记录已处理或需要手动核对") }
        if let registration = backup.registration { return try await restoreWorktreeRegistration(backup, registration: registration) }
        let destination: URL
        if backup.external != nil {
            destination = try externalWorktreeURL(backup.origin.path)
        } else {
            destination = try files.resolve(String(backup.origin.path.dropFirst(files.root.path.count + 1)))
            guard destination.path == backup.origin.path, destination.path.hasPrefix(files.root.path + "/.bluefatfish/worktrees/") else { throw PetError("原工作树路径已变化") }
        }
        let externalWorktree = backup.external.map { _ in destination }
        let parent = destination.deletingLastPathComponent()
        let existing = try await worktrees()
        guard nonexistentWorktreePath(destination), existing.allSatisfy({ $0.path != destination.path }) else { throw PetError("原路径或工作树登记已存在，未覆盖任何文件") }
        if let external = backup.external, try directoryIdentity(parent) != external.parent { throw PetError("原上级目录已变化，请接回原目录后重试") }
        let folder = try worktreeFile(backup.id), copy = folder.appendingPathComponent("files"), index = try Data(contentsOf: folder.appendingPathComponent("metadata/index"))
        guard try await worktreeSnapshot(copy.path).hash == backup.treeHash, AgentFiles.hash(index) == backup.indexHash else { throw PetError("回收备份已变化，未恢复") }
        let branch: String?
        if let old = backup.branch {
            let current = try await run(["rev-parse", "--verify", old])
            branch = !current.failed && current.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == backup.head && !existing.contains(where: { $0.branch == old }) ? old : "refs/heads/recovered/" + backup.id.lowercased()
        } else { branch = nil }
        try Task.checkCancellation(); try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "worktree-restore", name: "git_restore_worktree", arguments: "{}"), task: task, store: store) }
        try await validateHooks()
        if let external = backup.external {
            guard try externalWorktreeURL(destination.path) == destination, try directoryIdentity(parent) == external.parent, nonexistentWorktreePath(destination) else { throw PetError("外部目标目录已变化，请重新检查") }
        } else { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let previousState = backup.state
        backup.state = "restoring"; try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        let args: [String]
        if let branch, branch != backup.branch { args = ["worktree", "add", "--no-checkout", "-b", String(branch.dropFirst("refs/heads/".count)), destination.path, backup.head] }
        else { args = ["worktree", "add", "--no-checkout"] + (branch == nil ? ["--detach"] : []) + [destination.path, branch.map { String($0.dropFirst("refs/heads/".count)) } ?? backup.head] }
        let added = try await run(args, write: true, externalWorktree: externalWorktree)
        if added.failed {
            if externalWorktree != nil, nonexistentWorktreePath(destination),
               let entries = try? await worktrees(), entries.allSatisfy({ $0.path != destination.path }) {
                backup.state = previousState; try saveWorktree(backup, folder.appendingPathComponent("record.json"))
            }
            throw PetError("恢复未完成，备份保留，请核对实际 Git 状态：" + added.text)
        }
        let restoredMetadata = try await worktreeMetadata(destination.path, externalWorktree: externalWorktree)
        if let external = backup.external {
            guard try externalWorktreeURL(destination.path) == destination, try directoryIdentity(parent) == external.parent else { throw PetError("恢复目录已变化，备份保留") }
        }
        // Copy saved bytes without touching the new .git backlink.
        let job = Task.detached {
            let fm = FileManager.default
            for file in try fm.contentsOfDirectory(at: copy, includingPropertiesForKeys: nil) where file.lastPathComponent != ".git" { try Task.checkCancellation(); try fm.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent)) }
            for file in try fm.contentsOfDirectory(at: folder.appendingPathComponent("metadata"), includingPropertiesForKeys: nil) { try Data(contentsOf: file).write(to: restoredMetadata.appendingPathComponent(file.lastPathComponent), options: .atomic) }
        }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        guard try await worktreeSnapshot(destination.path).hash == backup.treeHash, try Data(contentsOf: restoredMetadata.appendingPathComponent("index")) == index else { throw PetError("恢复结果不一致，备份保留，请核对实际目录") }
        let readable = try await run(["-C", destination.path, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--numstat", backup.head, "--"], maximumOutput: 1024, externalWorktree: externalWorktree)
        guard !readable.failed else { throw PetError("恢复的暂存内容无法读取，文件与备份保留，请核对 Git 状态：" + readable.text) }
        let currentHead = try await run(["-C", destination.path, "rev-parse", "HEAD"], externalWorktree: externalWorktree)
        let actualHead = currentHead.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actualRef = try await run(["-C", destination.path, "symbolic-ref", "--quiet", "HEAD"], externalWorktree: externalWorktree)
        let restoredBranch = actualRef.exitCode == 0 ? actualRef.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        guard !currentHead.failed, actualHead == backup.head, restoredBranch == branch, actualRef.exitCode == (branch == nil ? 1 : 0) else { throw PetError("恢复后的实际分支或提交不一致，备份保留，请核对 Git 状态") }
        backup.state = "restored"; backup.restoredBranch = restoredBranch; try saveWorktree(backup, folder.appendingPathComponent("record.json"))
        for (id, archived) in backup.tasks where store.task(id)?.workspacePaths.contains(where: { canonical($0) == destination.path || canonical($0).hasPrefix(destination.path + "/") }) == true {
            store.update(id) { task in
                let available = (try? AgentWorkspaceScope.roots(task)) != nil && task.managedWorktreeOrigins.allSatisfy { origin in
                    (try? AgentFiles(workspace: origin.path).root.path) == origin.path && (try? Self.metadata(workspace: origin.path).path) == origin.metadata
                }
                if available { task.archived = task.worktreeRecycleArchived ?? archived; task.worktreeRecycleArchived = nil }
                else { task.archived = true }
                task.gitReview = nil; task.gitPushReview = nil; task.events.append(AgentEvent(kind: "git", title: "工作树已恢复", detail: destination.path + "\n" + (branch ?? "分离状态") + (available ? "" : "\n仍有源文件夹待恢复，任务保持归档。"), status: "completed"))
            }
        }
        if let error = store.writeError { throw PetError("文件已恢复，关联任务保存失败：" + error) }; return backup
    }
}
