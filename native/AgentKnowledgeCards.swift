import Foundation
import Darwin

enum AgentKnowledgeCardKind: String, Codable, CaseIterable, Sendable {
    case architecture, spec, tech_stack
    var title: String { switch self { case .architecture: return "架构"; case .spec: return "代码规范"; case .tech_stack: return "技术栈" } }
}
struct AgentKnowledgeCardSource: Codable, Sendable, Equatable {
    var path: String; var line: Int; var endLine: Int; var sha256: String
}
struct AgentKnowledgeCard: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String; var kind: AgentKnowledgeCardKind; var body: String
    var sources: [AgentKnowledgeCardSource]
    var manual = false; var updated = Date()
    var hash: String { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return AgentFiles.hash((try? e.encode(self)) ?? Data()) }
}
struct AgentKnowledgeCardBook: Codable, Identifiable, Sendable {
    var version = 1; var id = UUID().uuidString
    var workspace: String; var branch: String; var language: String; var sourceRevision: String
    var taskID: String?; var cards: [AgentKnowledgeCard]; var created = Date()
    var focus: String?
}
struct AgentKnowledgeCardJob: Codable, Sendable {
    var workspace: String; var branch: String; var language: String; var baseHash: String
    var sourceTaskID: String; var sourceRevision: String?; var automatic = false
    var focus: String?
}
struct AgentKnowledgeCardRead: Codable, Sendable { var sha256: String; var ranges: [[Int]] }
struct AgentKnowledgeCardOptions: Codable, Sendable {
    var language = "zh"; var citation = true; var autoUpdate = false; var autoExport = false
    var sourceTaskID: String?; var rootIdentity: String?
}
struct AgentKnowledgeCardSettings: Codable { var version = 1; var projects: [String: AgentKnowledgeCardOptions] = [:] }

@MainActor final class AgentKnowledgeCards {
    static let kind = "knowledge-cards"
    static let tools = ["read_project_knowledge", "edit_project_knowledge", "save_knowledge_card"]
    static let generationTools: Set<String> = ["index_project", "search_project", "read_file", "read_project_knowledge", "save_knowledge_card", "update_plan", "finish_task"]
    weak var store: AgentStore?
    weak var runtime: AgentRuntime?
    var onChange: ((String) -> Void)?
    let directory: URL
    var watchers: [String: AgentKnowledgeCardWatcher] = [:]
    var updates: [String: Task<Void, Never>] = [:]
    var finalizing: Set<String> = []
    var notices: [String: String] = [:]
    var lastAttempt: [String: String] = [:]
    init(store: AgentStore) {
        self.store = store
        directory = store.directory.deletingLastPathComponent().appendingPathComponent("knowledge-cards", isDirectory: true)
    }
    nonisolated static func validTitle(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 100 && text.rangeOfCharacter(from: .controlCharacters) == nil
    }
    nonisolated static func valid(_ card: AgentKnowledgeCard) -> Bool {
        UUID(uuidString: card.id) != nil && validTitle(card.title) && !card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && card.body.utf8.count <= 4000 && !card.body.contains("\0") && !card.sources.isEmpty && card.sources.count <= 12 && card.sources.allSatisfy {
            !$0.path.isEmpty && $0.path.count <= 2000 && !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") && !AgentFiles.sensitive($0.path) && $0.line > 0 && $0.endLine >= $0.line && $0.endLine < 1_000_000 && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        }
    }
    func settings() throws -> (AgentKnowledgeCardSettings, String) {
        let url = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return (AgentKnowledgeCardSettings(), AgentFiles.hash(Data())) }
        let data = try AgentFiles(workspace: directory.path).readData(url, maximum: 1_000_000), value = try JSONDecoder().decode(AgentKnowledgeCardSettings.self, from: data)
        guard value.version == 1, value.projects.count <= 500 else { throw PetError("知识卡片设置无效") }
        return (value, AgentFiles.hash(data))
    }
    func options(workspace: String) throws -> AgentKnowledgeCardOptions { try settings().0.projects[AgentFiles(workspace: workspace).root.path] ?? AgentKnowledgeCardOptions() }
    func setOptions(_ options: AgentKnowledgeCardOptions, workspace: String, expected: String) throws {
        let root = try AgentFiles(workspace: workspace).root.path
        guard ["zh", "en"].contains(options.language) else { throw PetError("请选择简体中文或 English") }
        try locked(directory) {
            var (value, hash) = try settings(); guard hash == expected else { throw PetError("知识卡片设置已变化，请刷新后重试") }
            var saved = options
            if saved.autoUpdate { saved.rootIdentity = try Self.identity(root) }
            value.projects[root] = saved
            guard value.projects.count <= 500 else { throw PetError("工作区设置已达上限") }
            try write(value, directory.appendingPathComponent("settings.json"))
        }
        activate(workspace: root); onChange?(root)
    }
    nonisolated static func identity(_ root: String) throws -> String {
        var info = stat(); guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw PetError("工作区不可用") }
        return "\(info.st_dev):\(info.st_ino)"
    }
    func scope(_ task: AgentTaskRecord) throws -> (root: String, branch: String, directory: URL) {
        guard let store else { throw PetError("知识卡片存储已关闭") }
        let index = try AgentProjectIndex(workspace: task.workspace, storage: store.directory), root = index.files.root.path
        let entry = try index.files.resolve(".git")
        guard FileManager.default.fileExists(atPath: entry.path) else { return (root, "folder", index.directory.appendingPathComponent("knowledge-cards")) }
        let metadata = try AgentGit.metadata(workspace: root)
        guard metadata.path == root || metadata.path.hasPrefix(root + "/") || task.gitDirectory == metadata.path else { throw PetError("请先连接当前工作区的 Git 元数据") }
        let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
        let headDirectory: URL
        if values.isDirectory == true { headDirectory = entry }
        else {
            let data = try index.files.readData(entry, maximum: 8192)
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), text.hasPrefix("gitdir: ") else { throw PetError("工作树信息无效") }
            headDirectory = URL(fileURLWithPath: String(text.dropFirst(8)), relativeTo: index.files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
        }
        let gitFiles = try AgentFiles(workspace: metadata.path), head = try gitFiles.resolve(headDirectory.appendingPathComponent("HEAD").path)
        let data = try gitFiles.readData(head, maximum: 4096)
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count < 1024 else { throw PetError("无法核对当前分支") }
        return (root, text.hasPrefix("ref: ") ? String(text.dropFirst(5)) : "detached:" + text, index.directory.appendingPathComponent("knowledge-cards"))
    }
    private func pointer(_ scope: (root: String, branch: String, directory: URL), language: String) throws -> URL {
        guard ["zh", "en"].contains(language) else { throw PetError("知识卡片语言无效") }
        return scope.directory.appendingPathComponent(AgentFiles.hash(Data((scope.branch + "\n" + language).utf8)) + ".json")
    }
    func book(_ task: AgentTaskRecord, language: String? = nil) throws -> (AgentKnowledgeCardBook?, String) {
        let scope = try scope(task), language = try language ?? options(workspace: scope.root).language
        let url = try pointer(scope, language: language)
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, AgentFiles.hash(Data())) }
        let files = try AgentFiles(workspace: scope.directory.path), data = try files.readData(url, maximum: 2_000_000)
        let value = try JSONDecoder().decode(AgentKnowledgeCardBook.self, from: data)
        guard value.version == 1, value.workspace == scope.root, value.branch == scope.branch, value.language == language,
              UUID(uuidString: value.id) != nil, value.cards.count <= 30, Set(value.cards.map(\.id)).count == value.cards.count,
              value.cards.allSatisfy(Self.valid) else { throw PetError("知识卡片版本或范围不匹配") }
        return (value, AgentFiles.hash(data))
    }
    func publish(_ value: AgentKnowledgeCardBook, task: AgentTaskRecord, expected: String) throws {
        let scope = try scope(task)
        guard value.version == 1, UUID(uuidString: value.id) != nil, value.workspace == scope.root, value.branch == scope.branch, ["zh", "en"].contains(value.language), !value.cards.isEmpty, value.cards.count <= 30, Set(value.cards.map(\.id)).count == value.cards.count, value.cards.allSatisfy(Self.valid) else { throw PetError("卡片内容、工作区或分支无效，原版本保留") }
        try locked(scope.directory) {
            guard try book(task, language: value.language).1 == expected else { throw PetError("知识卡片已被其他操作修改，原版本保留") }
            let versions = scope.directory.appendingPathComponent("versions", isDirectory: true)
            try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try write(value, versions.appendingPathComponent(value.id + ".json"))
            try write(value, pointer(scope, language: value.language))
        }
        onChange?(scope.root)
    }
    func locked<T>(_ directory: URL, _ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try AgentFiles(workspace: directory.path), (parent, name) = try files.parentDescriptor(directory.appendingPathComponent("write.lock"), create: true)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PetError("知识卡片无法锁定") }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw PetError("另一窗口正在更新知识卡片") }; defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    func write<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value); guard data.count <= 2_000_000 else { throw PetError("知识卡片数据过大") }
        try AgentFiles(workspace: url.deletingLastPathComponent().path).writeData(data, to: url, permissions: 0o600)
    }
    func recordRead(taskID: String, path: String, sha256: String, text: String) throws {
        guard let store, let task = store.task(taskID), task.kind == Self.kind || task.toolGroups?.contains("knowledge") == true else { return }
        let lines = text.split(separator: "\n").compactMap { Int($0.split(separator: ":", maxSplits: 1).first ?? "") }
        guard let first = lines.first, let last = lines.last else { return }
        var reads = task.knowledgeReads ?? [:]
        var value = reads[path].flatMap { $0.sha256 == sha256 ? $0 : nil } ?? AgentKnowledgeCardRead(sha256: sha256, ranges: [])
        if !value.ranges.contains([first, last]) { value.ranges.append([first, last]) }
        reads[path] = value
        guard reads.count <= 100, value.ranges.count <= 100 else { throw PetError("知识来源过多，请缩小本轮分析范围") }
        store.update(taskID) { $0.knowledgeReads = reads }
        if let error = store.writeError { throw PetError("来源核对记录未保存：" + error) }
    }
    func sources(_ raw: Any?, task: AgentTaskRecord) throws -> [AgentKnowledgeCardSource] {
        guard let store, let values = raw as? [[String: Any]], !values.isEmpty, values.count <= 12 else { throw PetError("每张卡片需要1至12项实际源码引用") }
        let files = try AgentFiles(workspace: task.workspace), index = try AgentProjectIndex(workspace: task.workspace, storage: store.directory)
        return try values.map { value in
            guard let path = value["path"] as? String, !AgentFiles.sensitive(path), let line = value["line"] as? Int else { throw PetError("来源路径或行号无效") }
            let url = try files.resolve(path), relative = files.relative(url), end = value["end_line"] as? Int ?? line
            guard try index.contains(relative), let read = task.knowledgeReads?[relative], read.ranges.contains(where: { $0.count == 2 && $0[0] <= line && end <= $0[1] }), line > 0, end >= line,
                  try files.fileHash(url, maximum: 512_000) == read.sha256 else { throw PetError("请先用 read_file 核对当前源码及引用行号：" + relative) }
            return AgentKnowledgeCardSource(path: relative, line: line, endLine: end, sha256: read.sha256)
        }
    }
    func fresh(_ card: AgentKnowledgeCard, workspace: String) -> Bool {
        guard let files = try? AgentFiles(workspace: workspace) else { return false }
        guard Self.valid(card) else { return false }
        return card.sources.allSatisfy { source in
            guard let url = try? files.resolve(source.path), let data = try? files.readData(url, maximum: 512_000), AgentFiles.hash(data) == source.sha256,
                  let text = String(data: data, encoding: .utf8), source.endLine <= text.components(separatedBy: "\n").count else { return false }; return true
        }
    }
    func draftURL(_ task: AgentTaskRecord) throws -> URL {
        guard let store, task.kind == Self.kind, UUID(uuidString: task.id) != nil else { throw PetError("仅生成任务可保存卡片草稿") }
        let root = store.directory.appendingPathComponent(task.id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root.appendingPathComponent("knowledge-cards.json")
    }
    func drafts(_ task: AgentTaskRecord) throws -> [AgentKnowledgeCard] {
        let url = try draftURL(task)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try AgentFiles(workspace: url.deletingLastPathComponent().path).readData(url, maximum: 300_000)
        return try JSONDecoder().decode([AgentKnowledgeCard].self, from: data)
    }
    func saveDraft(_ call: AgentToolCall, task: AgentTaskRecord) throws -> AgentKnowledgeCard {
        guard let store, task.kind == Self.kind, let job = task.knowledgeJob, task.mode == .goal else { throw PetError("只有知识卡片生成任务可新建草稿") }
        let scope = try scope(task), args = call.object
        guard scope.root == job.workspace, scope.branch == job.branch, job.sourceRevision != nil else { throw PetError("请先更新索引；工作区或分支不可改变") }
        guard let title = args["title"] as? String, Self.validTitle(title), let raw = args["kind"] as? String, let kind = AgentKnowledgeCardKind(rawValue: raw),
              let body = args["body"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 4000 else { throw PetError("卡片标题、类型或正文无效，正文最多4KB") }
        let original = try book(task, language: job.language)
        guard original.1 == job.baseHash else { throw PetError("生成期间卡片已有修改，原版本保留") }
        let id = args["id"] as? String ?? UUID().uuidString
        guard UUID(uuidString: id) != nil else { throw PetError("卡片编号无效") }
        if let old = try drafts(task).first(where: { $0.id == id }) ?? original.0?.cards.first(where: { $0.id == id }) { guard args["expected_hash"] as? String == old.hash else { throw PetError("请先读取原卡片及其 hash") } }
        else { guard args["id"] == nil else { throw PetError("新卡片不要提供 id") } }
        guard !(original.0?.cards ?? []).contains(where: { $0.id != id && $0.kind == kind && $0.title == title }) else { throw PetError("已有同名卡片，请用其 id 和 hash 更新") }
        let card = AgentKnowledgeCard(id: id, title: title, kind: kind, body: body, sources: try sources(args["sources"], task: task))
        var saved = try drafts(task); saved.removeAll { $0.id == id }; saved.append(card)
        guard saved.count <= 30, saved.allSatisfy(Self.valid) else { throw PetError("本轮最多30张有效卡片") }
        try write(saved, draftURL(task))
        if let error = store.writeError { throw PetError(error) }
        return card
    }
    func validate(_ task: AgentTaskRecord) throws -> AgentKnowledgeCardBook {
        guard let store, let job = task.knowledgeJob, let revision = job.sourceRevision else { throw PetError("知识卡片缺少已核对的项目索引") }
        let scope = try scope(task), original = try book(task, language: job.language), pending = try drafts(task)
        guard scope.root == job.workspace, scope.branch == job.branch, original.1 == job.baseHash, !pending.isEmpty else { throw PetError("生成范围或原卡片已变化，不能替换") }
        var cards = original.0?.cards ?? []
        for card in pending { cards.removeAll { $0.id == card.id }; cards.append(card) }
        guard cards.count <= 30, Set(AgentKnowledgeCardKind.allCases).isSubset(of: Set(cards.map(\.kind))) else { throw PetError("需要架构、代码规范和技术栈三类卡片") }
        guard cards.allSatisfy({ fresh($0, workspace: scope.root) }), try AgentProjectIndex(workspace: scope.root, storage: store.directory).snapshot()?.revision == revision else { throw PetError("生成期间源码已变化，请核对后更新") }
        return AgentKnowledgeCardBook(workspace: scope.root, branch: scope.branch, language: job.language, sourceRevision: revision, taskID: task.id, cards: cards, focus: job.focus)
    }
}
