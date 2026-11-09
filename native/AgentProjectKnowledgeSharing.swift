import Foundation

struct AgentKnowledgeSharingScope: Codable, Equatable {
    var workspace: String, branch: String, language: String, identity: String
}
struct AgentProjectKnowledgeHistory: Codable {
    var id = UUID().uuidString, created = Date()
    var scope: AgentKnowledgeSharingScope
    var wiki: AgentWikiHistoryEntry?, cards: AgentKnowledgeCardBook?
}
struct AgentProjectKnowledgeImport {
    var scope: AgentKnowledgeSharingScope
    var wiki: AgentWikiImportPreview?, cards: AgentKnowledgeCardImport?
    var previousWiki: AgentWikiSnapshot, previousCardsHash: String
    var historyID: String?, historyHash: String?
    var sourcePresence: [String: Bool] = [:]
    var restoring = false
    var pageCount: Int { wiki?.metadata.documents.count ?? 0 }
    var cardCount: Int { cards?.book.cards.count ?? 0 }
}

@MainActor enum AgentProjectKnowledgeSharing {
    private static func scope(_ store: AgentStore, _ taskID: String, _ language: String) throws -> (value: AgentKnowledgeSharingScope, task: AgentTaskRecord, cards: URL, wiki: URL, directory: URL) {
        guard ["zh", "en"].contains(language), let task = store.task(taskID), !task.archived, task.kind != "hook", try !store.agents.limits(task, store: store).readOnly else { throw PetError("请选择可写的项目任务与知识语言") }
        let current = try store.knowledgeCards.scope(task), bundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard current.root != bundle, !current.root.hasPrefix(bundle + "/"), FileManager.default.isWritableFile(atPath: current.root) else { throw PetError("项目知识目录当前不可写") }
        return (.init(workspace: current.root, branch: current.branch, language: language, identity: try AgentKnowledgeCards.identity(current.root)), task, current.directory, current.directory.deletingLastPathComponent().appendingPathComponent("wiki"), current.directory.deletingLastPathComponent().appendingPathComponent("knowledge-sharing"))
    }
    private static func requireScope(_ expected: AgentKnowledgeSharingScope, store: AgentStore, taskID: String) throws {
        guard try scope(store, taskID, expected.language).value == expected else { throw PetError("知识传递的项目、分支、语言、目录身份或权限已变化，请重新预览") }
    }
    private static func requireNoGeneration(_ value: AgentKnowledgeSharingScope, store: AgentStore, taskID: String) throws {
        guard !store.projectKnowledge.isPreparing(sourceID: taskID, language: value.language), !store.tasks.contains(where: { task in
            guard task.workspace == value.workspace, task.isProjectDocumentation, !task.archived else { return false }
            let matches = task.kind == "wiki" ? (task.wikiJob == nil ? value.language == "zh" : task.wikiJob?.branch == value.branch && task.wikiJob?.language == value.language) : task.knowledgeJob?.branch == value.branch && task.knowledgeJob?.language == value.language
            return matches && ([.ready, .running, .waiting].contains(task.status) || AgentWiki.isFinalizing(task.id) || store.knowledgeCards.finalizing.contains(task.id))
        }) else { throw PetError("请先暂停当前分支与语言的 Wiki 和卡片生成，再导入或恢复") }
    }
    private static func locked<T>(_ store: AgentStore, _ value: (value: AgentKnowledgeSharingScope, task: AgentTaskRecord, cards: URL, wiki: URL, directory: URL), _ operation: () throws -> T) throws -> T {
        try store.knowledgeCards.locked(value.wiki, label: "Wiki") { try store.knowledgeCards.locked(value.cards) { try operation() } }
    }
    @discardableResult static func export(store: AgentStore, taskID: String, language: String) async throws -> (pages: Int, cards: Int) {
        let initial = try scope(store, taskID, language), beforeCards = try store.knowledgeCards.book(initial.task, language: language)
        let beforeWiki = try await AgentWiki.snapshot(store, taskID, language)
        let wiki = beforeWiki.metadata.documents.isEmpty ? nil : try await AgentWiki.prepareWikiExport(store: store, taskID: taskID, language: language)
        let cards = beforeCards.0 == nil ? nil : try store.knowledgeCards.prepareExport(initial.task, language: language)
        guard wiki != nil || cards != nil else { throw PetError("当前分支与语言没有可导出的知识") }
        try locked(store, initial) {
            var writes: [AgentKnowledgeFileWrite] = []
            if let wiki { writes += try AgentWiki.wikiExportWrites(wiki, store: store, taskID: taskID, language: language) }
            if let cards { writes += try store.knowledgeCards.exportWrites(cards, task: initial.task) }
            try AgentKnowledgeFileBatch.commit(writes, backup: initial.directory.appendingPathComponent("exports/" + UUID().uuidString)) {
                try requireScope(initial.value, store: store, taskID: taskID)
                try AgentWiki.requireSnapshot(beforeWiki, store: store, taskID: taskID, language: language)
                guard try store.knowledgeCards.book(initial.task, language: language).1 == beforeCards.1 else { throw PetError("导出期间卡片版本已变化，请重试") }
                if let wiki { try AgentWiki.requireSnapshot(wiki.snapshot, store: store, taskID: taskID, language: language) }
                if let cards { try store.knowledgeCards.requireExport(cards, task: initial.task) }
            }
        }
        return (wiki?.snapshot.metadata.documents.count ?? 0, cards?.count ?? 0)
    }
    static func previewImport(store: AgentStore, taskID: String, language: String) async throws -> AgentProjectKnowledgeImport {
        let current = try scope(store, taskID, language), files = try AgentFiles(workspace: current.value.workspace), wikiPath = try AgentWiki.sharingPath(language), cardPath = try store.knowledgeCards.sharingPath(language: language)
        try requireNoGeneration(current.value, store: store, taskID: taskID)
        let presence = try sourcePresence(files, language: language, store: store)
        let hasWiki = presence[wikiPath + "/" + AgentWiki.transferMetadata] == true, hasCards = presence[cardPath + "/knowledge.json"] == true
        if !hasWiki, !((try? AgentWiki.pages(workspace: files.root.path, root: wikiPath + "/content")) ?? []).isEmpty { throw PetError("Wiki 共享目录缺少元数据，请保留完整目录后导入") }
        if !hasCards, FileManager.default.fileExists(atPath: files.root.appendingPathComponent(cardPath).path), !(try FileManager.default.contentsOfDirectory(atPath: files.root.appendingPathComponent(cardPath).path)).filter({ $0 != ".DS_Store" }).isEmpty { throw PetError("卡片共享目录缺少 knowledge.json") }
        guard hasWiki || hasCards else { throw PetError("项目共享目录中没有当前语言的知识") }
        let wiki = hasWiki ? try await AgentWiki.previewWikiImport(store: store, taskID: taskID, language: language) : nil
        if let wiki { guard wiki.metadata.branch == current.value.branch else { throw PetError("Wiki 共享内容不是当前分支；原知识未修改") } }
        let cards = hasCards ? try store.knowledgeCards.previewImport(current.task, language: language) : nil
        let previousWiki: AgentWikiSnapshot
        if let wiki { previousWiki = wiki.previous } else { previousWiki = try await AgentWiki.snapshot(store, taskID, language) }
        let preview = AgentProjectKnowledgeImport(scope: current.value, wiki: wiki, cards: cards, previousWiki: previousWiki, previousCardsHash: try cards?.previousHash ?? store.knowledgeCards.book(current.task, language: language).1, sourcePresence: presence)
        try requirePreview(preview, store: store, taskID: taskID); return preview
    }
    private static func sourcePresence(_ files: AgentFiles, language: String, store: AgentStore) throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        for path in [try AgentWiki.sharingPath(language) + "/" + AgentWiki.transferMetadata, try store.knowledgeCards.sharingPath(language: language) + "/knowledge.json"] {
            let literal = try files.literalURL(path)
            guard try files.relative(files.resolve(path)) == path else { throw PetError("知识共享路径包含符号链接") }
            let kind = try files.entryMetadata(literal).kind
            guard ["file", "missing"].contains(kind) else { throw PetError("知识元数据不是普通文件") }; result[path] = kind == "file"
        }
        return result
    }
    private static func requirePreview(_ preview: AgentProjectKnowledgeImport, store: AgentStore, taskID: String) throws {
        try requireScope(preview.scope, store: store, taskID: taskID); try requireNoGeneration(preview.scope, store: store, taskID: taskID)
        try AgentWiki.requireSnapshot(preview.previousWiki, store: store, taskID: taskID, language: preview.scope.language)
        guard let task = store.task(taskID), try store.knowledgeCards.book(task, language: preview.scope.language).1 == preview.previousCardsHash else { throw PetError("预览后原卡片已变化，请重新预览") }
        if !preview.restoring, let cards = preview.cards { try store.knowledgeCards.requireImport(cards, task: task) }
        if !preview.restoring { guard try sourcePresence(AgentFiles(workspace: preview.scope.workspace), language: preview.scope.language, store: store) == preview.sourcePresence else { throw PetError("预览后共享内容的范围已变化，请重新预览") } }
        if let id = preview.historyID, let hash = preview.historyHash {
            let directory = try scope(store, taskID, preview.scope.language).directory, files = try AgentFiles(workspace: directory.path)
            guard UUID(uuidString: id) != nil, try files.fileHash(files.resolve("history/" + id + "/version.json"), maximum: 2_000_000) == hash else { throw PetError("恢复版本已变化，请重新预览") }
        }
    }
    static func apply(_ preview: AgentProjectKnowledgeImport, store: AgentStore, taskID: String) async throws {
        try requirePreview(preview, store: store, taskID: taskID)
        let initial = try scope(store, taskID, preview.scope.language), publication: AgentWikiPublication?
        if let wiki = preview.wiki { publication = try await AgentWiki.prepareWikiPublication(wiki, store: store, taskID: taskID, restoring: preview.restoring) }
        else if preview.restoring { publication = try AgentWiki.prepareAbsentWiki(preview.previousWiki, store: store, taskID: taskID, language: preview.scope.language) }
        else { publication = nil }
        try locked(store, initial) {
            try requirePreview(preview, store: store, taskID: taskID)
            let oldBook = try store.knowledgeCards.book(initial.task, language: preview.scope.language).0
            let archived = try AgentWiki.archive(preview.previousWiki, directory: initial.wiki)
            let history = AgentProjectKnowledgeHistory(scope: initial.value, wiki: archived, cards: oldBook), folder = initial.directory.appendingPathComponent("history/" + history.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); let historyFiles = try AgentFiles(workspace: folder.path)
            try historyFiles.writeData(JSONEncoder().encode(history), to: historyFiles.resolve("version.json"), permissions: 0o600)
            var writes: [AgentKnowledgeFileWrite] = []
            if let publication { writes += try AgentWiki.wikiPublicationWrites(publication, store: store, taskID: taskID) }
            if let cards = preview.cards { writes += try store.knowledgeCards.importWrites(cards, task: initial.task, restoring: preview.restoring) }
            else if preview.restoring { let files = try AgentFiles(workspace: initial.cards.path), cardScope = try store.knowledgeCards.scope(initial.task); writes.append(try AgentKnowledgeFileWrite(files: files, path: files.relative(store.knowledgeCards.pointer(cardScope, language: preview.scope.language)), data: nil, expectedHash: preview.previousCardsHash, permissions: 0o600)) }
            func rank(_ entry: AgentKnowledgeFileWrite) -> Int { if entry.files.root.path == initial.value.workspace { return 0 }; let path = entry.files.relative(entry.url); return path.hasPrefix("versions/") ? 1 : path.hasPrefix("export-") ? 2 : 3 }
            writes.sort { rank($0) == rank($1) ? $0.url.path < $1.url.path : rank($0) < rank($1) }
            try AgentKnowledgeFileBatch.commit(writes, backup: folder.appendingPathComponent("transfer")) {
                try requirePreview(preview, store: store, taskID: taskID)
                if let publication { try AgentWiki.requirePublication(publication, store: store, taskID: taskID) }
            }
        }
        store.knowledgeCards.onChange?(preview.scope.workspace)
        if let id = publication?.id { await store.wikiMaintenance.published(taskID: taskID, language: preview.scope.language, expectedID: id) }
        else if !preview.restoring { await store.wikiMaintenance.cardsPublished(taskID: taskID, language: preview.scope.language) }
    }
    static func history(store: AgentStore, taskID: String, language: String) throws -> [AgentProjectKnowledgeHistory] {
        let current = try scope(store, taskID, language), root = current.directory.appendingPathComponent("history")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }; let files = try AgentFiles(workspace: root.path)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { folder in
            guard let data = try? files.readData(folder.appendingPathComponent("version.json"), maximum: 2_000_000), let value = try? JSONDecoder().decode(AgentProjectKnowledgeHistory.self, from: data), value.id == folder.lastPathComponent, value.scope == current.value else { return nil }; return value
        }.sorted { $0.created > $1.created }
    }
    static func previewRestore(_ entry: AgentProjectKnowledgeHistory, store: AgentStore, taskID: String, language: String) async throws -> AgentProjectKnowledgeImport {
        let current = try scope(store, taskID, language)
        guard entry.scope == current.value, UUID(uuidString: entry.id) != nil else { throw PetError("此知识版本不属于当前项目、分支和语言") }
        let files = try AgentFiles(workspace: current.directory.path), metadata = try files.readData(files.resolve("history/" + entry.id + "/version.json"), maximum: 2_000_000), saved = try JSONDecoder().decode(AgentProjectKnowledgeHistory.self, from: metadata)
        guard saved.scope == entry.scope, saved.id == entry.id else { throw PetError("知识版本已变化") }
        let wikiPreview: AgentWikiImportPreview?
        if let wiki = saved.wiki { wikiPreview = try await AgentWiki.previewWikiRestore(wiki, store: store, taskID: taskID, language: language) } else { wikiPreview = nil }
        let previousWiki: AgentWikiSnapshot
        if let wikiPreview { previousWiki = wikiPreview.previous } else { previousWiki = try await AgentWiki.snapshot(store, taskID, language) }
        let previous = try store.knowledgeCards.book(current.task, language: language)
        var cards: AgentKnowledgeCardImport?
        if var value = saved.cards {
            guard value.workspace == current.value.workspace, value.branch == current.value.branch, value.language == language else { throw PetError("历史卡片范围无效") }
            value.id = UUID().uuidString; value.created = Date(); value.taskID = nil
            for i in value.cards.indices { value.cards[i].manual = true }
            cards = AgentKnowledgeCardImport(book: value, hashes: [:], previousHash: previous.1)
        }
        let preview = AgentProjectKnowledgeImport(scope: current.value, wiki: wikiPreview, cards: cards, previousWiki: previousWiki, previousCardsHash: previous.1, historyID: saved.id, historyHash: AgentFiles.hash(metadata), restoring: true)
        try requirePreview(preview, store: store, taskID: taskID); return preview
    }
}
