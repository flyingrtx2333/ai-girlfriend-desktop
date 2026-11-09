import Foundation
import Darwin

struct AgentTaskPurge: Codable, Sendable {
    var id: String
    var recordSignature: String
    var directorySignature: String?
    var directoryIdentity: String?
    var importSnapshot: String?
    var importHash: String?
}
struct AgentTaskDeletionPlan {
    var records: [AgentTaskPurge]
    var titles: [String]
    var workspaceIDs: [String]
    var workspaceTitles: [String]
    var indexHash: String?
    var organizationSignature: String
    var deletionSignature: String
    var ids: Set<String> { Set(records.map(\.id)) }
}

@MainActor final class AgentTaskDeletion {
    private struct Document: Codable {
        var version = 1
        var tasks: [String] = []
        var workspaces: [String] = []
        var pending: [AgentTaskPurge] = []
    }
    let directory: URL
    private var document = Document(), opened = "missing"
    private(set) var revision = 0, working = false
    private(set) var issue: String?
    private(set) var taskIDs = Set<String>(), workspaceIDs = Set<String>()
    var pendingCount: Int { document.pending.count }
    var signature: String { opened }
    init(directory: URL) { self.directory = directory; do { try refresh() } catch { issue = error.localizedDescription } }
    func refresh() throws {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("deleted-records.json"), entry = try files.entryMetadata(file)
            guard entry.signature != opened else { if let issue { throw PetError(issue) }; return }
            guard entry.kind == "file" else { throw PetError("永久删除记录不可用，请检查配置目录；任务已暂停") }
            let data = try files.readData(file, maximum: 16_000_000), value = try JSONDecoder().decode(Document.self, from: data)
            let ids = Set(value.tasks), archives = Set(value.workspaces)
            guard try files.entryMetadata(file).signature == entry.signature, value.version == 1,
                  value.tasks.allSatisfy({ UUID(uuidString: $0) != nil }), Set(value.tasks).count == value.tasks.count,
                  value.workspaces.allSatisfy({ UUID(uuidString: $0) != nil }), Set(value.workspaces).count == value.workspaces.count,
                  Set(value.pending.map(\.id)).count == value.pending.count, value.pending.allSatisfy({ ids.contains($0.id) && Self.valid($0) }) else { throw PetError("永久删除记录损坏或正在变化，请检查配置目录；任务已暂停") }
            document = value; taskIDs = ids; workspaceIDs = archives; opened = entry.signature; revision += 1; issue = nil
        } catch { issue = error.localizedDescription; throw error }
    }
    private static func valid(_ item: AgentTaskPurge) -> Bool {
        guard item.recordSignature.count <= 512, (item.directorySignature?.count ?? 0) <= 512, (item.directoryIdentity?.count ?? 0) <= 512 else { return false }
        guard let snapshot = item.importSnapshot else { return item.importHash == nil }
        return snapshot.range(of: "^[a-f0-9]{64}\\.jsonl$", options: .regularExpression) != nil && item.importHash?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    private func save(_ value: Document) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value); guard data.count <= 16_000_000 else { throw PetError("永久删除记录超过16MB，未执行删除") }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("deleted-records.json")
        let entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("永久删除记录只读或不可写，未执行删除") }
        try files.writeData(data, to: file, permissions: 0o600, expectedTarget: opened)
        document = value; taskIDs = Set(value.tasks); workspaceIDs = Set(value.workspaces); opened = try files.entryMetadata(file).signature; revision += 1; issue = nil
    }
    func commit(_ records: [AgentTaskPurge], workspaces: [String], expected: String) throws {
        guard !working else { throw PetError("正在清理删除记录，请稍候") }; try refresh()
        guard opened == expected, records.allSatisfy({ Self.valid($0) && UUID(uuidString: $0.id) != nil && !taskIDs.contains($0.id) }), Set(records.map(\.id)).count == records.count,
              workspaces.allSatisfy({ UUID(uuidString: $0) != nil && !workspaceIDs.contains($0) }), Set(workspaces).count == workspaces.count, !records.isEmpty || !workspaces.isEmpty else { throw PetError("删除范围已变化，请重新确认") }
        var next = document; next.tasks = Array(Set(next.tasks + records.map(\.id))).sorted(); next.workspaces = Array(Set(next.workspaces + workspaces)).sorted(); next.pending += records
        try save(next)
    }
    // The ledger is the deletion commit. A stale index or interrupted cache cleanup
    // cannot make a deleted record available again.
    func cleanup() async -> String? {
        guard !working else { return "正在清理删除记录，请稍候" }
        working = true; defer { working = false }
        do {
            try refresh(); let pending = document.pending, directory = directory, deleted = taskIDs
            let results = await Task.detached(priority: .utility) { pending.map { item in (item.id, Self.purge(item, directory: directory, deleted: deleted)) } }.value
            try refresh(); let finished = Set(results.filter { $0.1 == nil }.map(\.0))
            if !finished.isEmpty { var next = document; next.pending.removeAll { finished.contains($0.id) }; try save(next) }
            let errors = results.compactMap { $0.1 }
            if !errors.isEmpty { return "记录已永久删除；\(errors.count)项私有缓存未清理：" + errors.prefix(3).joined(separator: "；") }
            return nil
        } catch { return "记录已永久删除；清理未完成：" + error.localizedDescription }
    }
    nonisolated private static func purge(_ item: AgentTaskPurge, directory: URL, deleted: Set<String>) -> String? {
        do {
            let files = try AgentFiles(workspace: directory.path)
            try remove(files, name: item.id + ".json", expected: item.recordSignature)
            try remove(files, name: item.id, expected: item.directorySignature ?? "missing", identity: item.directoryIdentity)
            if let name = item.importSnapshot, let hash = item.importHash {
                let root = directory.deletingLastPathComponent().appendingPathComponent("imports/records")
                if FileManager.default.fileExists(atPath: root.path) {
                    let imports = try AgentFiles(workspace: root.path), file = try imports.literalURL(name), entry = try imports.entryMetadata(file)
                    let profile = try AgentFiles(workspace: directory.deletingLastPathComponent().path)
                    guard imports.root.path == profile.root.appendingPathComponent("imports/records").standardizedFileURL.path else { throw PetError("导入副本目录包含链接，未清理") }
                    let owner = try AgentFiles(workspace: root.deletingLastPathComponent().path), (parent, leaf) = try owner.parentDescriptor(owner.literalURL("import.lock"), create: false)
                    let lock = openat(parent, leaf, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600); close(parent)
                    guard lock >= 0 else { throw PetError("不能锁定导入副本，未清理") }; defer { flock(lock, LOCK_UN); close(lock) }
                    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw PetError("另一窗口正在导入，副本已保留") }
                    let index = try files.readData(files.literalURL("index.json"), maximum: 20_000_000)
                    guard let object = try JSONSerialization.jsonObject(with: index) as? [String: Any], let records = object["tasks"] as? [[String: Any]] else { throw PetError("任务索引不可读，导入副本已保留") }
                    if records.contains(where: { record in !deleted.contains(record["id"] as? String ?? "") && (record["importOrigin"] as? [String: Any])?["snapshot"] as? String == name }) { return nil }
                    if entry.kind != "missing" {
                        guard entry.kind == "file", try imports.fileHash(file, maximum: AgentImportReaders.maximumBytes) == hash else { throw PetError("导入副本已变化，原文件已保留") }
                        try remove(imports, name: name, expected: entry.signature)
                    }
                }
            }; return nil
        } catch { return item.id + "：" + error.localizedDescription }
    }
    nonisolated static func directoryIdentity(_ files: AgentFiles, name: String) throws -> String? {
        let (parent, leaf) = try files.parentDescriptor(files.literalURL(name), create: false); defer { close(parent) }
        var info = stat()
        guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { if errno == ENOENT { return nil }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info.st_mode & S_IFMT == S_IFDIR ? identity(info) : nil
    }
    nonisolated private static func identity(_ value: stat) -> String { "\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)" }
    nonisolated private static func remove(_ files: AgentFiles, name: String, expected: String, identity expectedIdentity: String? = nil) throws {
        let url = try files.literalURL(name), entry = try files.entryMetadata(url)
        if entry.kind == "missing" { return }
        if let expectedIdentity, entry.kind == "directory" {
            guard try directoryIdentity(files, name: name) == expectedIdentity else { throw PetError("私有缓存目录已替换，未删除：" + name) }
        } else { guard entry.signature == expected else { throw PetError("私有缓存已变化，未删除：" + name) } }
        let (parent, leaf) = try files.parentDescriptor(url, create: false); defer { close(parent) }
        try remove(parent: parent, name: leaf, expected: entry.signature, depth: 0)
    }
    nonisolated private static func remove(parent: Int32, name: String, expected: String?, depth: Int) throws {
        guard depth <= 1024 else { throw PetError("私有缓存目录过深") }
        var original = stat(); guard fstatat(parent, name, &original, AT_SYMLINK_NOFOLLOW) == 0 else { if errno == ENOENT { return }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard expected == nil || AgentFiles.signature(original) == expected else { throw PetError("私有缓存已变化，未删除") }
        if original.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; defer { close(fd) }
            var opened = stat(); guard fstat(fd, &opened) == 0, identity(original) == identity(opened) else { throw PetError("私有缓存目录已变化") }
            let copy = dup(fd); guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard let iterator = fdopendir(copy) else { close(copy); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; defer { closedir(iterator) }
            while let entry = readdir(iterator) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                if child == "." || child == ".." { continue }; try remove(parent: fd, name: child, expected: nil, depth: depth + 1)
            }
            var current = stat(); guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, identity(current) == identity(original) else { throw PetError("私有缓存目录位置已变化") }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else { guard unlinkat(parent, name, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) } }
    }
}
