import Foundation

enum AgentWorkMode: String, Codable, CaseIterable {
    case coding, general
    var title: String { self == .coding ? "编程" : "通用" }
    var directoryTitle: String { self == .coding ? "工作区" : "文件夹" }
}
enum AgentDirectorySort: String, Codable, CaseIterable {
    case recent, name, created
    var title: String { switch self { case .recent: return "最近更新"; case .name: return "名称"; case .created: return "创建时间" } }
}
struct AgentDirectoryEntry: Codable {
    var path: String
    var mode: AgentWorkMode
    var name: String?
    var pinned = false
    var created = Date()
    var title: String { name ?? URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor final class AgentOrganization {
    private struct Document: Codable {
        var directories: [AgentDirectoryEntry] = []
        var selected: [String: String] = [:]
        var sorting: [String: AgentDirectorySort] = [:]
    }
    private let file: URL
    private var document = Document(), loadIssue: String?
    private var openedSignature = "missing"
    private(set) var revision = 0
    init(profile: URL) {
        file = profile.appendingPathComponent("organization.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let files = try AgentFiles(workspace: profile.path)
            let before = try files.entryMetadata(file).signature
            let data = try files.readData(file, maximum: 1_000_000)
            guard try files.entryMetadata(file).signature == before else { throw PetError("任务组织记录正在变化，请重试") }
            document = try JSONDecoder().decode(Document.self, from: data)
            openedSignature = before
        } catch { loadIssue = "任务组织记录无法读取，原文件已保留：" + error.localizedDescription }
    }
    private func save(_ value: Document) throws {
        if let loadIssue { throw PetError(loadIssue) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 1_000_000 else { throw PetError("任务组织记录过大") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try AgentFiles(workspace: file.deletingLastPathComponent().path)
        do { try files.writeData(data, to: file, permissions: 0o600, expectedTarget: openedSignature) }
        catch { throw PetError("任务组织记录未保存，请重新打开应用后重试：" + error.localizedDescription) }
        openedSignature = try files.entryMetadata(file).signature
        document = value; revision += 1
    }
    func remember(_ task: AgentTaskRecord) throws {
        guard document.selected[task.organizationMode.rawValue] != task.id else { return }
        var next = document; next.selected[task.organizationMode.rawValue] = task.id; try save(next)
    }
    func lastTask(_ mode: AgentWorkMode, tasks: [AgentTaskRecord]) -> String? {
        let available = tasks.filter { $0.organizationMode == mode && !$0.archived }
        let regular = available.filter { $0.agent?.ownerID == nil && !["hook", "wiki"].contains($0.kind ?? "") }
        return available.first(where: { $0.id == document.selected[mode.rawValue] })?.id ?? (regular.isEmpty ? available : regular).max(by: { $0.updated < $1.updated })?.id
    }
    func register(_ path: String, mode: AgentWorkMode) throws {
        let canonical = try AgentFiles(workspace: path).root.path
        guard !document.directories.contains(where: { $0.path == canonical && $0.mode == mode }) else { return }
        var next = document; next.directories.append(AgentDirectoryEntry(path: canonical, mode: mode)); try save(next)
    }
    func directories(_ mode: AgentWorkMode, tasks: [AgentTaskRecord]) -> [AgentDirectoryEntry] {
        var values = document.directories.filter { $0.mode == mode }
        var activity: [String: Date] = [:], created: [String: Date] = [:]
        for task in tasks where task.organizationMode == mode {
            guard let path = task.workspace else { continue }
            activity[path] = max(activity[path] ?? task.updated, task.updated)
            created[path] = min(created[path] ?? task.created, task.created)
        }
        let stored = Set(values.map(\.path))
        for (path, date) in created where !stored.contains(path) { values.append(AgentDirectoryEntry(path: path, mode: mode, created: date)) }
        let sort = sorting(mode)
        return values.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let first = activity[a.path] ?? a.created, second = activity[b.path] ?? b.created
            if sort == .recent, first != second { return first > second }
            if sort == .created, a.created != b.created { return a.created > b.created }
            let order = a.title.localizedStandardCompare(b.title)
            return order != .orderedSame ? order == .orderedAscending : a.path < b.path
        }
    }
    func name(_ path: String?, mode: AgentWorkMode) -> String? {
        guard let path else { return nil }
        return document.directories.first(where: { $0.path == path && $0.mode == mode })?.title ?? URL(fileURLWithPath: path).lastPathComponent
    }
    func rename(_ path: String, mode: AgentWorkMode, name: String, tasks: [AgentTaskRecord]) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PetError("请输入不超过80字的名称") }
        try change(path, mode: mode, tasks: tasks) { $0.name = name }
    }
    func togglePinned(_ path: String, mode: AgentWorkMode, tasks: [AgentTaskRecord]) throws { try change(path, mode: mode, tasks: tasks) { $0.pinned.toggle() } }
    private func change(_ path: String, mode: AgentWorkMode, tasks: [AgentTaskRecord], body: (inout AgentDirectoryEntry) -> Void) throws {
        guard var entry = directories(mode, tasks: tasks).first(where: { $0.path == path }) else { throw PetError("此目录不在任务列表中") }
        body(&entry)
        var next = document; next.directories.removeAll { $0.path == path && $0.mode == mode }; next.directories.append(entry); try save(next)
    }
    func sorting(_ mode: AgentWorkMode) -> AgentDirectorySort { document.sorting[mode.rawValue] ?? .recent }
    func sort(_ value: AgentDirectorySort, mode: AgentWorkMode) throws { var next = document; next.sorting[mode.rawValue] = value; try save(next) }
}
