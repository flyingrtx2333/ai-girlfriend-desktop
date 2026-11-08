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

@MainActor extension AgentKnowledgeCards {
    func sharingPath(language: String) throws -> String {
        guard ["zh", "en"].contains(language) else { throw PetError("知识卡片语言无效") }
        return ".bluefatfish/repowiki/knowledge/" + language
    }
    private func sharingState(_ task: AgentTaskRecord, language: String) throws -> URL {
        let scope = try scope(task)
        return scope.directory.appendingPathComponent("export-" + AgentFiles.hash(Data((scope.branch + "\n" + language).utf8)) + ".json")
    }
    @discardableResult func exportBook(_ task: AgentTaskRecord, language: String) throws -> [String] {
        let scope = try scope(task), files = try AgentFiles(workspace: scope.root), relative = try sharingPath(language: language), stateURL = try sharingState(task, language: language)
        let bundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard scope.root != bundle, !scope.root.hasPrefix(bundle + "/"), let value = try book(task, language: language).0 else { throw PetError("当前分支和语言没有可导出的卡片") }
        return try locked(scope.directory) {
            var payloads: [String: Data] = [:], items: [AgentKnowledgeCardTransfer.Item] = []
            for card in value.cards {
                let name = card.id + ".md", data = Data(("# " + card.title + "\n\n" + card.body + "\n").utf8)
                payloads[name] = data
                items.append(.init(id: card.id, title: card.title, kind: card.kind, sources: card.sources, file: name, sha256: AgentFiles.hash(data), manual: card.manual))
            }
            let metadata = AgentKnowledgeCardTransfer(branch: scope.branch, language: language, sourceRevision: value.sourceRevision, cards: items)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            payloads["knowledge.json"] = try encoder.encode(metadata)
            let previous: AgentKnowledgeCardExportState
            if FileManager.default.fileExists(atPath: stateURL.path) {
                previous = try JSONDecoder().decode(AgentKnowledgeCardExportState.self, from: AgentFiles(workspace: scope.directory.path).readData(stateURL, maximum: 100_000))
            } else { previous = AgentKnowledgeCardExportState(hashes: [:]) }
            var before: [String: (signature: String, data: Data?)] = [:]
            for name in payloads.keys.sorted() {
                let url = try files.resolve(relative + "/" + name), entry = try files.entryMetadata(url)
                if entry.kind == "missing" { before[name] = (entry.signature, nil); continue }
                guard entry.kind == "file", let expected = previous.hashes[name] else { throw PetError("导出位置有未导入的同名内容，请先导入：" + name) }
                let data = try files.readData(url, maximum: 200_000)
                guard AgentFiles.hash(data) == expected else { throw PetError("导出文件有外部编辑，请先导入：" + name) }
                before[name] = (entry.signature, data)
            }
            let backup = scope.directory.appendingPathComponent("export-backups/" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, entry) in before {
                if let data = entry.data { try AgentFiles(workspace: backup.path).writeData(data, to: backup.appendingPathComponent(name), permissions: 0o600) }
            }
            var written: [(String, String)] = []
            do {
                // The manifest becomes visible only after all referenced Markdown.
                let names = payloads.keys.filter { $0 != "knowledge.json" }.sorted() + ["knowledge.json"]
                for name in names {
                    let url = try files.resolve(relative + "/" + name), data = payloads[name]!
                    try files.writeData(data, to: url, permissions: 0o644, expectedTarget: before[name]!.signature)
                    written.append((name, try files.entryMetadata(url).signature))
                }
                try write(AgentKnowledgeCardExportState(hashes: payloads.mapValues(AgentFiles.hash)), stateURL)
            } catch {
                for (name, signature) in written.reversed() {
                    guard let url = try? files.resolve(relative + "/" + name), (try? files.entryMetadata(url).signature) == signature,
                          (try? files.fileHash(url, maximum: 200_000)) == payloads[name].map(AgentFiles.hash) else { continue }
                    if let data = before[name]?.data { try? files.writeData(data, to: url, permissions: 0o644, expectedTarget: signature) }
                    else { try? files.remove(url) }
                }
                throw PetError("导出未完成：" + error.localizedDescription + "；原文件备份：" + backup.path)
            }
            return payloads.keys.sorted().map { relative + "/" + $0 }
        }
    }
    func previewImport(_ task: AgentTaskRecord, language: String) throws -> AgentKnowledgeCardImport {
        guard let store else { throw PetError("项目已关闭") }
        let scope = try scope(task), files = try AgentFiles(workspace: scope.root), relative = try sharingPath(language: language)
        let data = try files.readData(files.resolve(relative + "/knowledge.json"), maximum: 300_000)
        let metadata = try JSONDecoder().decode(AgentKnowledgeCardTransfer.self, from: data)
        guard metadata.format == "bluefatfish.knowledge-cards", metadata.version == 1, metadata.language == language, metadata.branch == scope.branch, !metadata.cards.isEmpty, metadata.cards.count <= 30,
              Set(metadata.cards.map(\.id)).count == metadata.cards.count else { throw PetError("这不是当前语言支持的知识卡片格式") }
        let index = try AgentProjectIndex(workspace: scope.root, storage: store.directory)
        var hashes = ["knowledge.json": AgentFiles.hash(data)], cards: [AgentKnowledgeCard] = []
        for item in metadata.cards {
            guard UUID(uuidString: item.id) != nil, item.file == item.id + ".md", !item.sources.isEmpty, item.sources.count <= 12 else { throw PetError("导入卡片或文件名无效") }
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
    func importBook(_ preview: AgentKnowledgeCardImport, task: AgentTaskRecord) throws {
        let scope = try scope(task), files = try AgentFiles(workspace: scope.root), relative = try sharingPath(language: preview.book.language)
        guard preview.book.workspace == scope.root, preview.book.branch == scope.branch else { throw PetError("导入预览的工作区或分支已变化") }
        for (name, hash) in preview.hashes {
            guard try files.fileHash(files.resolve(relative + "/" + name), maximum: 300_000) == hash else { throw PetError("预览之后导入文件已变化，请重新预览") }
        }
        try publish(preview.book, task: task, expected: preview.previousHash)
        try write(AgentKnowledgeCardExportState(hashes: preview.hashes), sharingState(task, language: preview.book.language))
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
