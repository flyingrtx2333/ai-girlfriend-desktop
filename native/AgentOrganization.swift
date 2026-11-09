import Foundation

enum AgentWorkMode: String, Codable, CaseIterable, Sendable {
    case coding, general
    var title: String { self == .coding ? "编程" : "通用" }
    var directoryTitle: String { self == .coding ? "工作区" : "文件夹" }
}
enum AgentDirectorySort: String, Codable, CaseIterable {
    case recent, manual, name, created
    var title: String { switch self { case .recent: return "最近更新"; case .manual: return "手动"; case .name: return "名称"; case .created: return "创建时间" } }
}
enum AgentTaskGrouping: String, Codable, CaseIterable {
    case workspace, custom, activity
    var title: String { switch self { case .workspace: return "工作区"; case .custom: return "自定义分组"; case .activity: return "活动时间" } }
}
enum AgentTaskActivityWindow: String, Codable, CaseIterable {
    case all, today, week, month
    var title: String { switch self { case .all: return "全部"; case .today: return "今天"; case .week: return "最近7天"; case .month: return "最近30天" } }
    func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        guard self != .all else { return nil }
        return calendar.date(byAdding: .day, value: self == .today ? 0 : self == .week ? -6 : -29, to: calendar.startOfDay(for: now))
    }
}
struct AgentTaskView: Codable, Equatable {
    var grouping = AgentTaskGrouping.workspace
    var workspace: String?
    var activity = AgentTaskActivityWindow.all
    func includes(_ task: AgentTaskRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if grouping == .workspace, let workspace, (task.workspace ?? "") != workspace { return false }
        return activity.cutoff(now: now, calendar: calendar).map { (task.activityAt ?? task.updated) >= $0 } ?? true
    }
}
struct AgentCustomTaskGroup: Codable, Identifiable {
    var id = UUID().uuidString, name: String
    var mode: AgentWorkMode
    var taskIDs: [String] = []
    var created = Date()
}
struct AgentDirectoryEntry: Codable {
    var path: String
    var mode: AgentWorkMode
    var name: String?
    var pinned = false
    var created = Date()
    var archiveID: String?
    var archivedAt: Date?
    var title: String { name ?? URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor final class AgentOrganization {
    private struct Document: Codable {
        var directories: [AgentDirectoryEntry] = []
        var selected: [String: String] = [:]
        var sorting: [String: AgentDirectorySort] = [:]
        var taskViews: [String: AgentTaskView]?
        var taskGroups: [AgentCustomTaskGroup]?
        var manualOrders: [String: [String]]?
        var unreadTasks: [String]?
    }
    private let file: URL
    private var document = Document(), loadIssue: String?
    private var openedSignature = "missing"
    private(set) var revision = 0
    private var unreadTasks = Set<String>()
    func isTaskUnread(_ id: String) -> Bool { unreadTasks.contains(id) }
    func setTaskUnread(_ id: String, _ unread: Bool) throws {
        guard UUID(uuidString: id) != nil else { throw PetError("任务编号无效") }
        guard unreadTasks.contains(id) != unread else { return }
        let entry = try AgentFiles(workspace: file.deletingLastPathComponent().path).entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("任务组织记录只读，未更改未读标记") }
        var ids = unreadTasks; if unread { ids.insert(id) } else { ids.remove(id) }
        var next = document; next.unreadTasks = ids.isEmpty ? nil : ids.sorted(); try save(next)
    }
    private var deletedArchives = Set<String>()
    func suppressDeletedArchives(_ values: Set<String>) { if deletedArchives != values { deletedArchives = values; revision += 1 } }
    func requireCurrentSignature() throws -> String {
        if let loadIssue { throw PetError(loadIssue) }
        guard try AgentFiles(workspace: file.deletingLastPathComponent().path).entryMetadata(file).signature == openedSignature else { throw PetError("任务组织记录已变化，请重新打开应用后重试") }
        return openedSignature
    }
    func forgetDeletedRecords(taskIDs: Set<String>, workspaceIDs: Set<String>, selected: AgentTaskRecord?) throws {
        var next = document
        next.directories.removeAll { $0.archiveID.map(workspaceIDs.contains) == true }
        next.selected = next.selected.filter { !taskIDs.contains($0.value) }
        next.unreadTasks?.removeAll { taskIDs.contains($0) }
        if let selected { next.selected[selected.organizationMode.rawValue] = selected.id }
        if next.taskGroups != nil { for i in next.taskGroups!.indices { next.taskGroups![i].taskIDs.removeAll { taskIDs.contains($0) } } }
        try save(next)
    }
    init(profile: URL) {
        file = profile.appendingPathComponent("organization.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let files = try AgentFiles(workspace: profile.path)
            let before = try files.entryMetadata(file).signature
            let data = try files.readData(file, maximum: 1_000_000)
            guard try files.entryMetadata(file).signature == before else { throw PetError("任务组织记录正在变化，请重试") }
            document = try JSONDecoder().decode(Document.self, from: data)
            guard (document.unreadTasks ?? []).allSatisfy({ UUID(uuidString: $0) != nil }) else { throw PetError("未读任务编号无效") }
            unreadTasks = Set(document.unreadTasks ?? [])
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
        document = value; unreadTasks = Set(value.unreadTasks ?? []); revision += 1
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
        if document.directories.contains(where: { $0.path == canonical && $0.mode == mode && $0.archiveID.map(deletedArchives.contains) == true }) {
            var next = document; next.directories.removeAll { $0.path == canonical && $0.mode == mode }; next.directories.append(AgentDirectoryEntry(path: canonical, mode: mode)); try save(next); return
        }
        guard archiveID(canonical, mode: mode) == nil else { throw PetError("此" + mode.directoryTitle + "已归档，请先在设置中恢复") }
        guard !document.directories.contains(where: { $0.path == canonical && $0.mode == mode }) else { return }
        var next = document; next.directories.append(AgentDirectoryEntry(path: canonical, mode: mode)); try save(next)
    }
    func archiveID(_ path: String?, mode: AgentWorkMode) -> String? { document.directories.first { $0.path == path && $0.mode == mode && $0.archiveID.map(deletedArchives.contains) != true }?.archiveID }
    func directories(_ mode: AgentWorkMode, tasks: [AgentTaskRecord], includingArchived: Bool = false) -> [AgentDirectoryEntry] {
        var values = document.directories.filter { $0.mode == mode && $0.archiveID.map(deletedArchives.contains) != true }
        var activity: [String: Date] = [:], created: [String: Date] = [:]
        for task in tasks where task.organizationMode == mode && (includingArchived || !task.archived) {
            guard let path = task.workspace else { continue }
            activity[path] = max(activity[path] ?? task.updated, task.updated)
            created[path] = min(created[path] ?? task.created, task.created)
        }
        let stored = Set(values.map(\.path))
        for (path, date) in created where !stored.contains(path) { values.append(AgentDirectoryEntry(path: path, mode: mode, created: date)) }
        let sort = sorting(mode)
        let order = manualOrder(mode, grouping: .workspace)
        return values.filter { includingArchived || $0.archiveID == nil }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if sort == .manual, order.firstIndex(of: a.path) != order.firstIndex(of: b.path) { return (order.firstIndex(of: a.path) ?? Int.max) < (order.firstIndex(of: b.path) ?? Int.max) }
            let first = activity[a.path] ?? a.created, second = activity[b.path] ?? b.created
            if sort == .recent, first != second { return first > second }
            if sort == .created, a.created != b.created { return a.created > b.created }
            let order = a.title.localizedStandardCompare(b.title)
            return order != .orderedSame ? order == .orderedAscending : a.path < b.path
        }
    }
    struct ArchiveChange {
        let write: AgentKnowledgeFileWrite
        let accept: () -> Void
    }
    func prepareArchive(_ changes: [AgentDirectoryEntry], tasks: [AgentTaskRecord], selected: AgentTaskRecord?) throws -> ArchiveChange? {
        guard !changes.isEmpty || selected.map({ document.selected[$0.organizationMode.rawValue] != $0.id }) == true else { return nil }
        if let loadIssue { throw PetError(loadIssue) }
        var next = document
        for entry in changes {
            guard directories(entry.mode, tasks: tasks, includingArchived: true).contains(where: { $0.path == entry.path }) else { throw PetError("工作区已变化，请刷新后重试") }
            next.directories.removeAll { $0.path == entry.path && $0.mode == entry.mode }; next.directories.append(entry)
            if entry.archiveID != nil, next.taskViews?[entry.mode.rawValue]?.workspace == entry.path { next.taskViews?[entry.mode.rawValue]?.workspace = nil }
        }
        if let selected { next.selected[selected.organizationMode.rawValue] = selected.id }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next); guard data.count <= 1_000_000 else { throw PetError("任务组织记录过大") }
        let files = try AgentFiles(workspace: file.deletingLastPathComponent().path)
        let write = try AgentKnowledgeFileWrite(files: files, path: file.path, data: data, permissions: 0o600, label: "归档")
        guard write.signature == openedSignature else { throw PetError("任务组织记录已变化，请重新打开应用后重试") }
        return ArchiveChange(write: write, accept: { [self] in
            document = next; revision += 1
            do { openedSignature = try files.entryMetadata(file).signature }
            catch { loadIssue = "任务组织记录已保存，无法重新读取；请重新打开应用：" + error.localizedDescription }
        })
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
    func taskView(_ mode: AgentWorkMode) -> AgentTaskView { document.taskViews?[mode.rawValue] ?? AgentTaskView() }
    func setTaskView(_ value: AgentTaskView, mode: AgentWorkMode) throws {
        guard value.workspace == nil || value.workspace!.isEmpty || value.workspace!.hasPrefix("/") && value.workspace!.utf8.count < 8192 && !value.workspace!.contains("\0") else { throw PetError("工作区筛选路径无效") }
        var next = document; var views = next.taskViews ?? [:]; views[mode.rawValue] = value; next.taskViews = views
        if value.grouping == .activity { next.sorting[mode.rawValue] = .recent }
        try save(next)
    }
    func resetTaskView(_ mode: AgentWorkMode) throws {
        var next = document; next.taskViews?[mode.rawValue] = nil; next.sorting[mode.rawValue] = .recent; try save(next)
    }
    func customGroups(_ mode: AgentWorkMode, tasks: [AgentTaskRecord]) -> [AgentCustomTaskGroup] {
        let order = manualOrder(mode, grouping: .custom), sorting = sorting(mode)
        let activity = Dictionary(tasks.map { ($0.id, $0.activityAt ?? $0.updated) }, uniquingKeysWith: max)
        return (document.taskGroups ?? []).filter { $0.mode == mode }.sorted { a, b in
            if sorting == .manual, order.firstIndex(of: a.id) != order.firstIndex(of: b.id) { return (order.firstIndex(of: a.id) ?? Int.max) < (order.firstIndex(of: b.id) ?? Int.max) }
            if sorting == .recent { let first = a.taskIDs.compactMap { activity[$0] }.max() ?? a.created, second = b.taskIDs.compactMap { activity[$0] }.max() ?? b.created; if first != second { return first > second } }
            if sorting == .created, a.created != b.created { return a.created > b.created }
            let result = a.name.localizedStandardCompare(b.name); return result == .orderedSame ? a.id < b.id : result == .orderedAscending
        }
    }
    @discardableResult func saveCustomGroup(_ id: String? = nil, name: String, mode: AgentWorkMode) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PetError("请输入不超过80字的分组名称") }
        var next = document, groups = next.taskGroups ?? []
        guard !groups.contains(where: { $0.mode == mode && $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw PetError("此分组名称已存在") }
        let savedID: String
        if let id { guard let index = groups.firstIndex(where: { $0.id == id && $0.mode == mode }) else { throw PetError("分组已变化，请刷新后重试") }; groups[index].name = name; savedID = id }
        else { guard groups.count < 100 else { throw PetError("自定义分组已达100个") }; let group = AgentCustomTaskGroup(name: name, mode: mode); groups.append(group); savedID = group.id }
        next.taskGroups = groups; try save(next); return savedID
    }
    func removeCustomGroup(_ id: String, mode: AgentWorkMode) throws {
        var next = document; guard next.taskGroups?.contains(where: { $0.id == id && $0.mode == mode }) == true else { throw PetError("分组已不存在") }
        next.taskGroups?.removeAll { $0.id == id && $0.mode == mode }; try save(next)
    }
    func assignTask(_ id: String, group: String?, mode: AgentWorkMode, tasks: [AgentTaskRecord]) throws {
        guard tasks.contains(where: { $0.id == id && $0.organizationMode == mode }) else { throw PetError("任务或工作模式已变化") }
        var next = document, groups = next.taskGroups ?? []
        guard group == nil || groups.contains(where: { $0.id == group && $0.mode == mode }) else { throw PetError("目标分组已变化") }
        for i in groups.indices where groups[i].mode == mode { groups[i].taskIDs.removeAll { $0 == id }; if groups[i].id == group { guard groups[i].taskIDs.count < 5000 else { throw PetError("此分组已达5000个任务") }; groups[i].taskIDs.append(id) } }
        next.taskGroups = groups; try save(next)
    }
    private func manualOrder(_ mode: AgentWorkMode, grouping: AgentTaskGrouping) -> [String] { document.manualOrders?[mode.rawValue + "\n" + grouping.rawValue] ?? [] }
    func reorder(_ id: String, before target: String?, mode: AgentWorkMode, grouping: AgentTaskGrouping, tasks: [AgentTaskRecord]) throws {
        let directories = directories(mode, tasks: tasks)
        var values = grouping == .workspace ? directories.map(\.path) : customGroups(mode, tasks: tasks).map(\.id)
        guard grouping != .activity, values.contains(id), target == nil || values.contains(target!), target != id else { throw PetError("分组位置已变化，请重新拖动") }
        if grouping == .workspace, let source = directories.first(where: { $0.path == id }) {
            let destination = directories.first { $0.path == target }, firstUnpinned = directories.first { !$0.pinned }
            guard !(source.pinned && firstUnpinned != nil && (target == nil || destination?.pinned == false && target != firstUnpinned?.path)), !(!source.pinned && destination?.pinned == true) else { throw PetError("置顶目录固定在前；请先调整置顶状态再拖动") }
        }
        values.removeAll { $0 == id }; values.insert(id, at: target.flatMap { values.firstIndex(of: $0) } ?? values.count)
        var next = document, orders = next.manualOrders ?? [:]; orders[mode.rawValue + "\n" + grouping.rawValue] = values; next.manualOrders = orders; next.sorting[mode.rawValue] = .manual; try save(next)
    }
}
