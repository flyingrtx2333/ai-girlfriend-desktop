import Foundation

struct AgentKnowledgeFileWrite {
    let files: AgentFiles, url: URL, data: Data?, before: Data?, signature: String, permissions: Int, originalPermissions: Int
    private let label: String
    init(files: AgentFiles, path: String, data: Data?, expectedHash: String? = nil, missing: Bool = false, permissions: Int? = nil, label: String = "知识传递") throws {
        let url = try files.literalURL(path)
        let requested = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : files.root.appendingPathComponent(path)).standardizedFileURL
        guard try files.resolve(path) == url, requested == url else { throw PetError(label + "路径包含符号链接或位置已变化：" + path) }
        let entry = try files.entryMetadata(url)
        guard ["file", "missing"].contains(entry.kind), !missing || entry.kind == "missing", entry.kind != "file" || (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError(label + "目标已存在、只读或不是普通文件：" + path) }
        let before = entry.kind == "file" ? try files.readData(url, maximum: 20_000_000) : nil
        guard (data?.count ?? 0) <= 20_000_000, expectedHash == nil || AgentFiles.hash(before ?? Data()) == expectedHash else { throw PetError(label + "文件已变化或超过20MB，请重新打开后重试：" + path) }
        self.label = label
        self.files = files; self.url = url; self.data = data; self.before = before; signature = entry.signature
        self.permissions = permissions ?? entry.permissions ?? 0o644; originalPermissions = entry.permissions ?? self.permissions
    }
    func requireCurrent() throws {
        guard try files.resolve(url.path) == url, try files.entryMetadata(url).signature == signature else { throw PetError(label + "文件在检查后已变化：" + files.relative(url)) }
        if let before { guard try files.fileHash(url, maximum: 20_000_000) == AgentFiles.hash(before) else { throw PetError(label + "文件在检查后已变化：" + files.relative(url)) } }
    }
}

@MainActor enum AgentKnowledgeFileBatch {
    static func commit(_ writes: [AgentKnowledgeFileWrite], backup: URL, label: String = "知识传递", validate: () throws -> Void) throws {
        let keys = writes.map { $0.url.path.precomposedStringWithCanonicalMapping.lowercased() }
        guard writes.count <= 6000, Set(keys).count == writes.count, writes.reduce(0, { $0 + ($1.data?.count ?? 0) + ($1.before?.count ?? 0) }) <= 256_000_000 else { throw PetError(label + "文件重复或超过256MB") }
        try validate(); try writes.forEach { try $0.requireCurrent() }; try Task.checkCancellation()
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try AgentFiles(workspace: backup.path)
        for (i, entry) in writes.enumerated() { if let before = entry.before { try files.writeData(before, to: files.resolve("before/\(i).data"), permissions: 0o600) } }
        let journal: [[String: Any]] = writes.enumerated().map { i, entry in ["path": entry.url.path, "before": entry.before.map { AgentFiles.hash($0) as Any } ?? NSNull(), "after": entry.data.map { AgentFiles.hash($0) as Any } ?? NSNull(), "backup": entry.before == nil ? NSNull() : "before/\(i).data"] }
        try files.writeData(JSONSerialization.data(withJSONObject: ["version": 1, "entries": journal, "state": "prepared"], options: [.prettyPrinted, .sortedKeys]), to: files.resolve("transfer.json"), permissions: 0o600)
        try validate(); try writes.forEach { try $0.requireCurrent() }; try Task.checkCancellation()
        var changed: [(Int, String?)] = []
        do {
            for (i, entry) in writes.enumerated() {
                try Task.checkCancellation(); try entry.requireCurrent()
                if entry.data == entry.before && (entry.before == nil || entry.permissions == entry.originalPermissions) { continue }
                if let data = entry.data { try entry.files.writeData(data, to: entry.url, permissions: entry.permissions, expectedTarget: entry.signature) }
                else if entry.before != nil { try entry.files.remove(entry.url) }
                do { changed.append((i, try entry.files.entryMetadata(entry.url).signature)) }
                catch { changed.append((i, nil)); throw error }
            }
            try files.writeData(JSONSerialization.data(withJSONObject: ["state": "committed", "changed": changed.count], options: [.sortedKeys]), to: files.resolve("outcome.json"), permissions: 0o600)
        } catch {
            var retained: [String] = []
            for (i, signature) in changed.reversed() {
                let entry = writes[i]
                do {
                    guard let signature else { retained.append(entry.url.path); continue }
                    // Metadata includes inode, size, mode and nanosecond modification/change times.
                    // Avoid cancellable reads here: rollback must run even after cancellation.
                    guard try entry.files.resolve(entry.url.path) == entry.url, try entry.files.entryMetadata(entry.url).signature == signature else { retained.append(entry.url.path); continue }
                    if let before = entry.before { try entry.files.writeData(before, to: entry.url, permissions: entry.originalPermissions, expectedTarget: signature) }
                    else if entry.data != nil { try entry.files.remove(entry.url) }
                } catch { retained.append(entry.url.path) }
            }
            try? files.writeData(JSONSerialization.data(withJSONObject: ["state": retained.isEmpty ? "rolled-back" : "needs-review", "retained": retained, "error": error.localizedDescription], options: [.prettyPrinted, .sortedKeys]), to: files.resolve("outcome.json"), permissions: 0o600)
            throw PetError(label + "未完成：" + error.localizedDescription + (retained.isEmpty ? "；本次已写内容已恢复。" : "；部分文件有后续修改或无法恢复，已保留，请检查。") + "备份：" + backup.path)
        }
    }
}
