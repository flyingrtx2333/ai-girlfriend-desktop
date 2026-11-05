import Foundation
import SQLite3

struct AgentIndexStats: Codable, Sendable {
    var files: Int; var updatedFiles: Int; var skipped: Int; var partial: Bool; var revision: String; var updated: Date
}
struct AgentIndexHit: Codable, Sendable {
    var path: String; var line: Int; var text: String; var sha256: String; var source: String
}
struct AgentIndexResult: Codable, Sendable { var index: AgentIndexStats; var matches: [AgentIndexHit] }

// Connections are short-lived; no watcher, embedding service or resident cache.
struct AgentProjectIndex: Sendable {
    let files: AgentFiles, directory: URL, excluded: URL
    init(workspace: String?, storage: URL) throws {
        files = try AgentFiles(workspace: workspace); excluded = storage.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard files.root != excluded, !files.root.path.hasPrefix(excluded.path + "/") else { throw PetError("不能索引应用私有数据") }
        directory = storage.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(AgentFiles.hash(Data(files.root.path.utf8)), isDirectory: true)
    }
    private final class Database {
        var pointer: OpaquePointer?
        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                let detail = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "不可用"; sqlite3_close(pointer); pointer = nil; throw PetError("索引不可用：" + detail)
            }
            sqlite3_busy_timeout(pointer, 3000)
            sqlite3_progress_handler(pointer, 2000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            try script("""
            PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA temp_store=MEMORY;
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, modified TEXT NOT NULL, bytes INTEGER NOT NULL, hash TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(path, body, start_line UNINDEXED, hash UNINDEXED, tokenize='trigram');
            """)
        }
        deinit { sqlite3_close(pointer) }
        func script(_ sql: String) throws {
            guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else { throw PetError("索引操作失败：" + String(cString: sqlite3_errmsg(pointer))) }
        }
        func query(_ sql: String, _ values: [String] = []) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK else { throw PetError("索引查询失败：" + String(cString: sqlite3_errmsg(pointer))) }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            var rows: [[String]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { try Task.checkCancellation(); throw PetError("索引查询失败：" + String(cString: sqlite3_errmsg(pointer))) }
                rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
            }
        }
    }
    private func allowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        let ignored = Set(["node_modules", "build", "dist", "vendor", "target", "coverage", "__pycache__", "pods", "deriveddata"])
        guard !AgentFiles.sensitive(path), !parts.contains(where: { $0.hasPrefix(".") || ignored.contains($0) }),
              !["credentials.py", "credentials.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"].contains(parts.last ?? ""),
              !path.lowercased().contains(".min.") else { return false }
        guard (try? files.root.appendingPathComponent(path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let url = try? files.resolve(path), url.path != excluded.path, !url.path.hasPrefix(excluded.path + "/") else { return false }
        return true
    }
    private func candidates() throws -> (paths: [String], partial: Bool) {
        guard let iterator = FileManager.default.enumerator(at: files.root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw PetError("项目目录不可读") }
        var result: [String] = [], visited = 0
        while let url = iterator.nextObject() as? URL {
            try Task.checkCancellation(); visited += 1
            if visited > 30_000 { break }
            let path = files.relative(url)
            guard allowed(path) else { iterator.skipDescendants(); continue }
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { result.append(path) }
        }
        return (result.sorted(), visited > 30_000)
    }
    func snapshot() -> AgentIndexStats? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")) else { return nil }
        return try? JSONDecoder().decode(AgentIndexStats.self, from: data)
    }
    func contains(_ path: String) throws -> Bool {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite").path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK else { throw PetError("请先更新项目索引") }
        sqlite3_busy_timeout(database, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM files WHERE path=? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw PetError("索引不可读，请重建") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw PetError("索引正在更新，请稍后读取") }
        return status == SQLITE_ROW
    }
    func run(paths: [String]?, query: String? = nil, limit: Int = 12, rebuild: Bool = false) async throws -> AgentIndexResult {
        let job = Task.detached(priority: .utility) { try self.perform(paths: paths, query: query, limit: limit, rebuild: rebuild) }
        return try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
    }
    private func perform(paths: [String]?, query: String?, limit: Int, rebuild: Bool) throws -> AgentIndexResult {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let databaseURL = directory.appendingPathComponent("index.sqlite"), db = try Database(databaseURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        try db.script("BEGIN IMMEDIATE;"); var committed = false
        defer { if !committed { try? db.script("ROLLBACK;") } }
        if rebuild { try db.script("DELETE FROM chunks; DELETE FROM files;") }
        let old = Dictionary(uniqueKeysWithValues: try db.query("SELECT path,modified,bytes,hash FROM files").map { ($0[0], $0) })
        let discovered = try paths.map { (paths: $0, partial: false) } ?? candidates(), selected = discovered.paths.filter(allowed).sorted()
        var seen: Set<String> = [], hashes: [String] = [], bytes = 0, changed = 0, skipped = 0, partial = discovered.partial
        for path in selected {
            try Task.checkCancellation()
            if seen.count >= 5000 || bytes >= 16_000_000 { partial = true; break }
            let url = try files.resolve(path)
            guard fm.fileExists(atPath: url.path) else { continue }
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, let size = attributes.fileSize, size <= 512_000 else { skipped += 1; continue }
            let modified = String((attributes.contentModificationDate ?? .distantPast).timeIntervalSince1970), cached = old[path]
            let hash: String
            if let cached, cached[1] == modified, Int(cached[2]) == size { hash = cached[3] }
            else {
                let data = try files.readData(url, maximum: 512_000)
                guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { skipped += 1; continue }
                hash = AgentFiles.hash(data)
                if cached?[3] != hash {
                    _ = try db.query("DELETE FROM chunks WHERE path=?", [path])
                    var body = "", start = 1
                    func insert() throws {
                        guard !body.isEmpty else { return }
                        _ = try db.query("INSERT INTO chunks(path,body,start_line,hash) VALUES(?,?,?,?)", [path, body, String(start), hash]); body = ""
                    }
                    for (index, line) in text.components(separatedBy: "\n").enumerated() {
                        if body.count > 6000 || index - start >= 80 { try insert(); start = index + 1 }
                        var rest = line[...]
                        while rest.count > 6000 { try insert(); start = index + 1; body = String(rest.prefix(6000)); try insert(); rest = rest.dropFirst(6000) }
                        body += rest + "\n"
                    }
                    try insert(); changed += 1
                }
                _ = try db.query("INSERT OR REPLACE INTO files(path,modified,bytes,hash) VALUES(?,?,?,?)", [path, modified, String(data.count), hash])
            }
            seen.insert(path); hashes.append(path + "\0" + hash); bytes += size
        }
        for path in old.keys where !seen.contains(path) { _ = try db.query("DELETE FROM chunks WHERE path=?", [path]); _ = try db.query("DELETE FROM files WHERE path=?", [path]) }
        let stats = AgentIndexStats(files: seen.count, updatedFiles: changed, skipped: skipped, partial: partial, revision: AgentFiles.hash(Data(hashes.joined(separator: "\0").utf8)), updated: Date())
        try db.script("COMMIT;"); committed = true
        let metadata = directory.appendingPathComponent("index.json")
        try JSONEncoder().encode(stats).write(to: metadata, options: .atomic); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return AgentIndexResult(index: stats, matches: []) }
        guard query.count <= 500, !query.contains("\0") else { throw PetError("检索内容无效或过长") }
        let terms = query.split(whereSeparator: \.isWhitespace).prefix(6).map(String.init), count = min(30, max(1, limit))
        let rows: [[String]]
        if terms.allSatisfy({ $0.count >= 3 }) {
            let expression = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
            rows = try db.query("SELECT path,body,start_line,hash FROM chunks WHERE chunks MATCH ? ORDER BY rank LIMIT ?", [expression, String(count * 3)])
        } else {
            let conditions = terms.map { _ in "(instr(lower(path),lower(?))>0 OR instr(lower(body),lower(?))>0)" }.joined(separator: " OR ")
            rows = try db.query("SELECT path,body,start_line,hash FROM chunks WHERE " + conditions + " LIMIT ?", terms.flatMap { [$0, $0] } + [String(count * 3)])
        }
        var matches: [AgentIndexHit] = [], verified: [String: String] = [:], tokens = 0
        for row in rows {
            try Task.checkCancellation(); let path = row[0], url = try files.resolve(path)
            if verified[path] == nil { verified[path] = AgentFiles.hash(try files.readData(url, maximum: 512_000)) }
            guard verified[path] == row[3] else { continue }
            let lines = row[1].components(separatedBy: "\n"), anchor = lines.firstIndex { line in terms.contains { line.localizedCaseInsensitiveContains($0) } } ?? 0
            let offset = max(0, anchor - 2), line = (Int(row[2]) ?? 1) + offset
            let snippet = lines.dropFirst(offset).prefix(12).enumerated().map { "\(line + $0.offset): " + String($0.element.prefix(800)) }.joined(separator: "\n")
            let text = String(snippet.prefix(1000)), cost = AgentContext.estimate(text) + AgentContext.estimate(path) * 2 + 100
            if tokens + cost > 4000 { break }; tokens += cost
            matches.append(AgentIndexHit(path: path, line: line, text: text, sha256: row[3], source: url.absoluteString + "#L\(line)"))
            if matches.count >= count { break }
        }
        return AgentIndexResult(index: stats, matches: matches)
    }
}
