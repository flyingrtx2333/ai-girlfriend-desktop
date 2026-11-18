import Foundation

struct AgentMemoryImportPlan: Codable {
    let workspace: String?
    var parts: [Part]

    struct Part: Codable {
        let name: String
        let hash: String
    }
}

enum AgentMemoryImport {
    private static let maximumBytes = 4_000_000
    private static let topicBytes = 24_000

    struct Preview {
        var record: AgentImportCandidate
        let hashes: [String]
    }

    private static func sourceFiles(_ root: URL) throws -> AgentFiles {
        let files = try AgentFiles(workspace: root.path, followParentLinks: false)
        guard files.root.path != "/", files.root.path == root.standardizedFileURL.path else {
            throw PetError("来源目录位置已变化，请重新选择")
        }
        return files
    }

    private static func directories(_ source: AgentImportSource, files: AgentFiles, workspace: String?) throws -> [(url: URL, consolidated: Bool)] {
        let children = source == .codex ? ["memories_v2", "memories"] : ["memory"]
        var result: [(URL, Bool)] = []
        for child in children {
            let url = try files.literalURL(child)
            if try files.entryMetadata(url).kind == "directory" { result.append((url, source == .codex)) }
        }
        if result.isEmpty {
            guard files.root.lastPathComponent != source.homeName else { throw PetError("未找到" + source.title + "记忆，请选择记忆文件夹") }
            result.append((files.root, source == .codex && children.contains(files.root.lastPathComponent)))
        }
        if source == .qoder, workspace == nil, result.contains(where: { value in
            value.0.lastPathComponent == "memory" && value.0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "projects"
        }) { throw PetError("请为 Qoder 项目记忆选择目标项目") }
        return result
    }

    private static func allowed(_ name: String, consolidated: Bool) -> Bool {
        let lower = name.lowercased()
        guard AgentMemoryDocument.validTopic(name), !["agents.md", "agents.local.md"].contains(lower) else { return false }
        return !consolidated || ["memory.md", "memory_summary.md"].contains(lower)
    }

    static func discover(_ source: AgentImportSource, root: URL, workspace: String?) throws -> [Preview] {
        let files = try sourceFiles(root), folders = try directories(source, files: files, workspace: workspace)
        var result: [Preview] = []
        for (folder, consolidated) in folders {
            for entry in try files.regularFiles(in: folder).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) where allowed(entry.name, consolidated: consolidated) {
                try Task.checkCancellation()
                guard result.count < 5000 else { throw PetError("来源超过5000份记忆文件，请选择较小的来源目录") }
                let url = folder.appendingPathComponent(entry.name)
                let sourceID = "memory:" + AgentFiles.hash(Data(url.path.utf8))
                var record = AgentImportCandidate(source: source, sourceID: sourceID, file: url.path, rawHash: "", sourceHash: "", title: entry.name, created: entry.modified, updated: entry.modified)
                record.memory = AgentMemoryImportPlan(workspace: workspace, parts: [])
                do {
                    let data = try read(url, files: files)
                    let hash = AgentFiles.hash(data)
                    record.sourceHash = hash; record.rawHash = hash
                    record.preview = String(String(decoding: data, as: UTF8.self).prefix(1000))
                    result.append(Preview(record: record, hashes: split(data).map(AgentFiles.hash)))
                } catch { record.issue = error.localizedDescription; result.append(Preview(record: record, hashes: [])) }
            }
        }
        return result
    }

    static func sourceURL(_ record: AgentImportCandidate, root: URL) throws -> URL {
        guard let plan = record.memory else { throw PetError("缺少记忆来源") }
        let files = try sourceFiles(root)
        let file = try files.literalURL(record.file)
        let folders = try directories(record.source, files: files, workspace: plan.workspace)
        guard folders.contains(where: { $0.url.path == file.deletingLastPathComponent().path && allowed(file.lastPathComponent, consolidated: $0.consolidated) }),
              try files.entryMetadata(file).kind == "file" else { throw PetError("来源记忆文件已移除或离开检测目录") }
        return file
    }

    static func read(_ record: AgentImportCandidate, root: URL) throws -> Data {
        try read(sourceURL(record, root: root), files: sourceFiles(root))
    }

    private static func read(_ file: URL, files: AgentFiles) throws -> Data {
        let before = try files.entryMetadata(file)
        guard before.kind == "file" else { throw PetError("记忆来源不是普通文件") }
        let data = try files.readData(file, maximum: maximumBytes)
        guard try files.entryMetadata(file).signature == before.signature else { throw PetError("来源正在变化，请重新检测") }
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw PetError("记忆源文件需要 UTF-8 Markdown") }
        return data
    }

    static func split(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [Data()] }
        var start = data.startIndex, result: [Data] = []
        while start < data.endIndex {
            var end = min(start + topicBytes, data.endIndex)
            if end < data.endIndex {
                while data[end] & 0xC0 == 0x80 { end -= 1 }
                if let newline = data[(start + topicBytes / 2)..<end].lastIndex(of: 10) { end = newline + 1 }
            }
            result.append(data.subdata(in: start..<end)); start = end
        }
        return result
    }

    private static func normalizedName(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    @MainActor static func plan(_ preview: Preview, destination: (files: AgentFiles, folder: URL), reserved: inout Set<String>) throws -> AgentImportCandidate {
        var record = preview.record
        guard record.issue == nil else { return record }
        let original = URL(fileURLWithPath: record.file).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: record.file).pathExtension
        var stem = ""
        for character in original {
            guard stem.utf8.count + String(character).utf8.count <= 108 else { break }
            stem.append(character)
        }
        if !AgentMemoryDocument.validTopic(stem + ".md") { stem = "记忆-" + String(record.rawHash.prefix(10)) }
        var parts: [AgentMemoryImportPlan.Part] = [], names = Set<String>(), writeNeeded = false
        for (offset, hash) in preview.hashes.enumerated() {
            let suffix = preview.hashes.count == 1 ? "" : String(format: "-%03d", offset + 1)
            let base = stem + suffix
            var resolved: AgentMemoryImportPlan.Part?
            for copy in 0..<100 {
                let alternate = copy == 0 ? "" : "（" + record.source.title + (copy == 1 ? "" : " " + String(copy)) + "）"
                let name = base + alternate + "." + ext
                let key = normalizedName(name)
                guard !reserved.contains(key), !names.contains(key) else { continue }
                let file = destination.folder.appendingPathComponent(name)
                let entry = try destination.files.entryMetadata(file)
                let absent = entry.kind == "missing"
                guard absent || entry.kind == "file" && (try? destination.files.fileHash(file, maximum: topicBytes)) == hash else { continue }
                resolved = .init(name: name, hash: hash); names.insert(key); writeNeeded = writeNeeded || absent
                break
            }
            guard let resolved else { throw PetError("同名文件过多，请调整目标目录后重新检测") }
            parts.append(resolved)
        }
        record.memory?.parts = parts; reserved.formUnion(names)
        if !writeNeeded { record.issue = "已经导入" }
        return record
    }

    @MainActor static func install(_ data: Data, record: AgentImportCandidate, store: AgentStore, backup: URL) throws {
        guard let plan = record.memory, record.rawHash == AgentFiles.hash(data) else { throw PetError("来源记忆已更新，请重新检测") }
        let chunks = split(data)
        guard plan.parts.count == chunks.count,
              Set(plan.parts.map { normalizedName($0.name) }).count == chunks.count else { throw PetError("记忆文件计划已变化，请重新检测") }
        let destination = try AgentMemory.importDestination(store: store, workspace: plan.workspace)
        var writes: [AgentKnowledgeFileWrite] = []
        for (part, bytes) in zip(plan.parts, chunks) {
            guard AgentMemoryDocument.validTopic(part.name), AgentFiles.hash(bytes) == part.hash else { throw PetError("记忆文件计划已变化，请重新检测") }
            let file = destination.folder.appendingPathComponent(part.name)
            let entry = try destination.files.entryMetadata(file)
            if entry.kind == "file", (try? destination.files.fileHash(file, maximum: topicBytes)) == part.hash { continue }
            guard entry.kind == "missing" else { throw PetError("目标“" + part.name + "”已变化，保留当前文件，请重新检测") }
            writes.append(try AgentKnowledgeFileWrite(files: destination.files, path: file.path, data: bytes, missing: true,
                permissions: plan.workspace == nil ? 0o600 : 0o644, label: "记忆导入"))
        }
        guard !writes.isEmpty else { return }
        try AgentKnowledgeFileBatch.commit(writes, backup: backup, label: "记忆导入") {
            let current = try AgentMemory.importDestination(store: store, workspace: plan.workspace)
            guard current.folder == destination.folder else { throw PetError("记忆目标已变化，请重新检测") }
        }
    }

    @MainActor static func destinationURLs(_ record: AgentImportCandidate, store: AgentStore) throws -> [URL] {
        guard let memory = record.memory else { throw PetError("缺少记忆目标") }
        let destination = try AgentMemory.importDestination(store: store, workspace: memory.workspace)
        return try memory.parts.compactMap { part in
            guard AgentMemoryDocument.validTopic(part.name) else { throw PetError("记忆文件名无效") }
            let url = destination.folder.appendingPathComponent(part.name)
            return try destination.files.entryMetadata(url).kind == "file" ? url : nil
        }
    }
}
