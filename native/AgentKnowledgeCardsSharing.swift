import Foundation

struct AgentKnowledgeCardTransfer: Codable {
    struct Item: Codable {
        var id: String; var title: String; var kind: AgentKnowledgeCardKind
        var sources: [AgentKnowledgeCardSource]; var file: String; var sha256: String; var manual: Bool?
    }
    var format = "bluefatfish.knowledge-cards"; var version = 1
    var branch: String; var language: String; var sourceRevision: String; var cards: [Item]
}
struct AgentKnowledgeCardExportState: Codable { var hashes: [String: String] }
struct AgentKnowledgeCardImport {
    var book: AgentKnowledgeCardBook; var hashes: [String: String]; var previousHash: String
}
struct AgentKnowledgeCardExport {
    var workspace: String, branch: String, language: String, bookHash: String
    var directory: URL, stateURL: URL
    var payloads: [String: Data]
    var count: Int
}

@MainActor extension AgentKnowledgeCards {
    func sharingPath(language: String) throws -> String {
        guard ["zh", "en"].contains(language) else { throw PetError("知识卡片语言无效") }
        return ".bluefatfish/repowiki/knowledge/" + language
    }
    func sharingState(_ task: AgentTaskRecord, language: String) throws -> URL {
        let scope = try scope(task)
        return scope.directory.appendingPathComponent("export-" + AgentFiles.hash(Data((scope.branch + "\n" + language).utf8)) + ".json")
    }
    func prepareExport(_ task: AgentTaskRecord, language: String) throws -> AgentKnowledgeCardExport {
        let scope = try scope(task), previous = try book(task, language: language)
        let bundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard scope.root != bundle, !scope.root.hasPrefix(bundle + "/"), let value = previous.0 else { throw PetError("当前分支和语言没有可导出的卡片") }
        var payloads: [String: Data] = [:], items: [AgentKnowledgeCardTransfer.Item] = []
        for card in value.cards {
            let name = card.id + ".md", data = Data(("# " + card.title + "\n\n" + card.body + "\n").utf8)
            payloads[name] = data; items.append(.init(id: card.id, title: card.title, kind: card.kind, sources: card.sources, file: name, sha256: AgentFiles.hash(data), manual: card.manual))
        }
        let metadata = AgentKnowledgeCardTransfer(branch: scope.branch, language: language, sourceRevision: value.sourceRevision, cards: items), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        payloads["knowledge.json"] = try encoder.encode(metadata)
        return AgentKnowledgeCardExport(workspace: scope.root, branch: scope.branch, language: language, bookHash: previous.1, directory: scope.directory, stateURL: try sharingState(task, language: language), payloads: payloads, count: value.cards.count)
    }
    func requireExport(_ prepared: AgentKnowledgeCardExport, task: AgentTaskRecord) throws {
        let scope = try scope(task)
        guard scope.root == prepared.workspace, scope.branch == prepared.branch, try book(task, language: prepared.language).1 == prepared.bookHash else { throw PetError("卡片或项目范围已变化，请重新导出") }
    }
    func exportWrites(_ prepared: AgentKnowledgeCardExport, task: AgentTaskRecord) throws -> [AgentKnowledgeFileWrite] {
        try requireExport(prepared, task: task)
        let files = try AgentFiles(workspace: prepared.workspace), stateFiles = try AgentFiles(workspace: prepared.directory.path), relative = try sharingPath(language: prepared.language)
        let previous = FileManager.default.fileExists(atPath: prepared.stateURL.path) ? try JSONDecoder().decode(AgentKnowledgeCardExportState.self, from: stateFiles.readData(prepared.stateURL, maximum: 100_000)) : AgentKnowledgeCardExportState(hashes: [:])
        let root = try files.literalURL(relative)
        guard try files.relative(files.resolve(relative)) == relative, ["directory", "missing"].contains(try files.entryMetadata(root).kind) else { throw PetError("卡片共享目录位置无效") }
        if FileManager.default.fileExists(atPath: root.path) {
            let actual = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ".DS_Store" }
            guard actual.count <= 100, actual.allSatisfy({ previous.hashes[$0.lastPathComponent] != nil && (try? files.entryMetadata($0).kind) == "file" }) else { throw PetError("卡片目录有未导入的内容，请先核对 knowledge.json 后导入") }
        }
        var writes: [AgentKnowledgeFileWrite] = []
        let names = Set(prepared.payloads.keys).union(previous.hashes.keys)
        for name in names.filter({ $0 != "knowledge.json" }).sorted() + ["knowledge.json"] {
            guard name == "knowledge.json" || name.hasSuffix(".md") && UUID(uuidString: String(name.dropLast(3))) != nil else { throw PetError("卡片导出记录路径无效") }
            let url = try files.literalURL(relative + "/" + name), entry = try files.entryMetadata(url)
            guard entry.kind == "missing" || previous.hashes[name] != nil else { throw PetError("卡片导出位置有未导入的内容：" + name) }
            writes.append(try AgentKnowledgeFileWrite(files: files, path: relative + "/" + name, data: prepared.payloads[name], expectedHash: entry.kind == "missing" ? nil : previous.hashes[name]))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        writes.append(try AgentKnowledgeFileWrite(files: stateFiles, path: stateFiles.relative(prepared.stateURL), data: encoder.encode(AgentKnowledgeCardExportState(hashes: prepared.payloads.mapValues(AgentFiles.hash))), permissions: 0o600))
        return writes
    }
    @discardableResult func exportBook(_ task: AgentTaskRecord, language: String) throws -> [String] {
        let prepared = try prepareExport(task, language: language)
        return try locked(prepared.directory) {
            let writes = try exportWrites(prepared, task: task)
            try AgentKnowledgeFileBatch.commit(writes, backup: prepared.directory.appendingPathComponent("export-backups/" + UUID().uuidString)) { try self.requireExport(prepared, task: task) }
            let relative = try sharingPath(language: language); return prepared.payloads.keys.sorted().map { relative + "/" + $0 }
        }
    }
    func previewImport(_ task: AgentTaskRecord, language: String) throws -> AgentKnowledgeCardImport {
        guard let store else { throw PetError("项目已关闭") }
        let scope = try scope(task), files = try AgentFiles(workspace: scope.root), relative = try sharingPath(language: language)
        guard try files.relative(files.resolve(relative + "/knowledge.json")) == relative + "/knowledge.json" else { throw PetError("卡片共享目录包含符号链接") }
        let data = try files.readData(files.resolve(relative + "/knowledge.json"), maximum: 300_000)
        let metadata = try JSONDecoder().decode(AgentKnowledgeCardTransfer.self, from: data)
        guard metadata.format == "bluefatfish.knowledge-cards", metadata.version == 1, metadata.language == language, metadata.branch == scope.branch, !metadata.cards.isEmpty, metadata.cards.count <= 30,
              Set(metadata.cards.compactMap { UUID(uuidString: $0.id)?.uuidString }).count == metadata.cards.count else { throw PetError("这不是当前语言支持的知识卡片格式") }
        let index = try AgentProjectIndex(workspace: scope.root, storage: store.directory)
        var hashes = ["knowledge.json": AgentFiles.hash(data)], cards: [AgentKnowledgeCard] = []
        for item in metadata.cards {
            guard UUID(uuidString: item.id) != nil, item.file == item.id + ".md", !item.sources.isEmpty, item.sources.count <= 12 else { throw PetError("导入卡片或文件名无效") }
            guard try files.relative(files.resolve(relative + "/" + item.file)) == relative + "/" + item.file else { throw PetError("卡片文件包含符号链接") }
            let raw = try files.readData(files.resolve(relative + "/" + item.file), maximum: 8000)
            guard let text = String(data: raw, encoding: .utf8), !text.contains("\0") else { throw PetError("卡片必须是UTF-8 Markdown") }
            let lines = text.components(separatedBy: "\n")
            let title = lines.first?.hasPrefix("# ") == true ? String(lines[0].dropFirst(2)) : item.title
            let body = (lines.first?.hasPrefix("# ") == true ? lines.dropFirst().joined(separator: "\n") : text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validTitle(title), !body.isEmpty, body.utf8.count <= 4000 else { throw PetError("导入卡片的标题或正文超限") }
            let sources = try item.sources.map { source -> AgentKnowledgeCardSource in
                guard !AgentFiles.sensitive(source.path), source.line > 0, source.endLine >= source.line, source.sha256.count == 64, source.sha256.allSatisfy(\.isHexDigit) else { throw PetError("导入来源引用无效") }
                let url = try files.resolve(source.path), path = files.relative(url)
                guard try index.contains(path) else { throw PetError("来源不在当前项目索引中：" + path) }
                return AgentKnowledgeCardSource(path: path, line: source.line, endLine: source.endLine, sha256: source.sha256)
            }
            let hash = AgentFiles.hash(raw); hashes[item.file] = hash
            cards.append(AgentKnowledgeCard(id: item.id, title: title, kind: item.kind, body: body, sources: sources, manual: item.manual == true || hash != item.sha256))
        }
        let book = AgentKnowledgeCardBook(workspace: scope.root, branch: scope.branch, language: language, sourceRevision: metadata.sourceRevision, cards: cards)
        return AgentKnowledgeCardImport(book: book, hashes: hashes, previousHash: try self.book(task, language: language).1)
    }
    func requireImport(_ preview: AgentKnowledgeCardImport, task: AgentTaskRecord) throws {
        let scope = try scope(task), files = try AgentFiles(workspace: scope.root), relative = try sharingPath(language: preview.book.language)
        guard preview.book.workspace == scope.root, preview.book.branch == scope.branch, try book(task, language: preview.book.language).1 == preview.previousHash else { throw PetError("导入预览的项目、分支或原卡片已变化") }
        guard try files.relative(files.resolve(relative)) == relative else { throw PetError("卡片共享目录包含符号链接") }
        for (name, hash) in preview.hashes {
            guard name == "knowledge.json" || name.hasSuffix(".md") && UUID(uuidString: String(name.dropLast(3))) != nil, try files.relative(files.resolve(relative + "/" + name)) == relative + "/" + name, try files.fileHash(files.resolve(relative + "/" + name), maximum: 300_000) == hash else { throw PetError("预览后卡片文件已变化，请重新预览") }
        }
    }
    func importWrites(_ preview: AgentKnowledgeCardImport, task: AgentTaskRecord, restoring: Bool = false) throws -> [AgentKnowledgeFileWrite] {
        if !restoring { try requireImport(preview, task: task) }
        let scope = try scope(task), files = try AgentFiles(workspace: scope.directory.path), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var writes = try publicationWrites(preview.book, task: task, expected: preview.previousHash)
        if !restoring { writes.append(try AgentKnowledgeFileWrite(files: files, path: files.relative(sharingState(task, language: preview.book.language)), data: encoder.encode(AgentKnowledgeCardExportState(hashes: preview.hashes)), permissions: 0o600)) }
        return writes
    }
    func importBook(_ preview: AgentKnowledgeCardImport, task: AgentTaskRecord) throws {
        let scope = try scope(task)
        try locked(scope.directory) {
            let writes = try importWrites(preview, task: task)
            try AgentKnowledgeFileBatch.commit(writes, backup: scope.directory.appendingPathComponent("import-backups/" + UUID().uuidString)) { try self.requireImport(preview, task: task) }
        }
        notices[scope.root] = "已导入 \(preview.book.cards.count) 张卡片"; onChange?(scope.root)
    }
    func history(_ task: AgentTaskRecord, language: String) throws -> [AgentKnowledgeCardBook] {
        let scope = try scope(task), root = scope.directory.appendingPathComponent("versions")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try AgentFiles(workspace: root.path)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }.compactMap { url in
            guard let data = try? files.readData(url, maximum: 2_000_000), let value = try? JSONDecoder().decode(AgentKnowledgeCardBook.self, from: data), value.workspace == scope.root, value.branch == scope.branch, value.language == language else { return nil }; return value
        }.sorted { $0.created > $1.created }
    }
    func restore(_ value: AgentKnowledgeCardBook, task: AgentTaskRecord, expected: String) throws {
        let scope = try scope(task)
        guard value.workspace == scope.root, value.branch == scope.branch else { throw PetError("不能恢复其他工作区或分支的版本") }
        var restored = value; restored.id = UUID().uuidString; restored.created = Date(); restored.taskID = nil
        for i in restored.cards.indices { restored.cards[i].manual = true }
        try publish(restored, task: task, expected: expected)
        notices[scope.root] = "已恢复；使用前请核对源码"; onChange?(scope.root)
        if try options(workspace: scope.root).autoExport {
            do { _ = try exportBook(task, language: value.language) }
            catch { notices[scope.root] = "已恢复，导出未完成：" + error.localizedDescription; onChange?(scope.root) }
        }
    }
}
