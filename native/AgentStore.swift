import Foundation

@MainActor final class AgentStore {
    let directory: URL
    private(set) var tasks: [AgentTaskRecord] = []
    private var cache: [String: AgentTaskRecord] = [:]
    private(set) var writeError: String?
    var selectedID: String? { didSet { do { try saveIndex() } catch { writeError = error.localizedDescription } } }
    var selected: AgentTaskRecord? { selectedID.flatMap(task) }
    private struct Index: Codable { var selectedID: String?; var tasks: [AgentTaskRecord] }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()

    init(directory: URL, legacy: [ChatMessage]) {
        self.directory = directory.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var previousSelection: String?
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("index.json")), let index = try? JSONDecoder().decode(Index.self, from: data) {
            tasks = index.tasks.filter { UUID(uuidString: $0.id) != nil }; previousSelection = index.selectedID
            for i in tasks.indices where tasks[i].status == .running { tasks[i].status = .stopped }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
        let indexedIDs = Set(tasks.map(\.id))
        for file in files where file.pathExtension == "json" && !indexedIDs.contains(file.deletingPathExtension().lastPathComponent) {
            guard let data = try? Data(contentsOf: file), let task = try? JSONDecoder().decode(AgentTaskRecord.self, from: data),
                  UUID(uuidString: task.id) != nil, file.deletingPathExtension().lastPathComponent == task.id else { continue }
            var recovered = task
            if recovered.status == .running { recovered.status = .stopped; recovered.events.append(AgentEvent(kind: "state", title: "应用重启，任务可继续", status: "stopped")) }
            tasks.append(Self.metadata(recovered))
        }
        tasks.sort { $0.updated > $1.updated }
        if tasks.isEmpty {
            var task = AgentTaskRecord(title: legacy.isEmpty ? "新的任务" : "之前的对话", mode: .ask)
            task.kind = "companion"
            task.messages = legacy.map { AgentMessage(role: $0.role, content: $0.content) }
            tasks.append(Self.metadata(task)); cache[task.id] = task
            do { try save(task.id) } catch { writeError = error.localizedDescription }
        }
        selectedID = tasks.first(where: { $0.id == previousSelection && !$0.archived })?.id ?? tasks.first(where: { !$0.archived })?.id ?? tasks.first?.id
    }
    @discardableResult func create(title: String = "新的任务", workspace: String? = nil, mode: AgentMode = .agent) -> String {
        let task = AgentTaskRecord(title: title, workspace: workspace, mode: mode)
        tasks.insert(Self.metadata(task), at: 0); cache[task.id] = task; selectedID = task.id
        do { try save(task.id) } catch { writeError = error.localizedDescription }
        trimCache(keeping: task.id); return task.id
    }
    private static func metadata(_ task: AgentTaskRecord) -> AgentTaskRecord {
        var value = task
        value.messages = []; value.events = []; value.plan = []; value.changes = []; value.approvals = []; value.pendingCalls = []
        value.artifacts = []; value.sources = []; value.queuedInputs = nil; value.draft = nil; value.summary = String(value.summary.prefix(240))
        return value
    }
    func task(_ id: String) -> AgentTaskRecord? {
        if let cached = cache[id] { return cached }
        guard UUID(uuidString: id) != nil, let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".json")),
              var task = try? JSONDecoder().decode(AgentTaskRecord.self, from: data), task.id == id else { return nil }
        if task.status == .running { task.status = .stopped; task.events.append(AgentEvent(kind: "state", title: "应用重启，任务可继续", status: "stopped")) }
        cache[id] = task
        trimCache(keeping: id)
        return task
    }
    private func trimCache(keeping id: String) {
        while cache.count > 4, let old = cache.keys.first(where: { $0 != id && $0 != selectedID && cache[$0]?.status != .running }) { cache[old] = nil }
    }
    func update(_ id: String, persist: Bool = true, _ body: (inout AgentTaskRecord) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), var value = task(id) else { return }
        body(&value); value.updated = Date(); cache[id] = value; tasks[index] = Self.metadata(value)
        if persist {
            do { try save(id) } catch { writeError = error.localizedDescription; tasks[index].status = .failed }
        }
    }
    func save(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw PetError("任务标识无效") }
        guard let task = task(id) else { return }
        let file = directory.appendingPathComponent(id + ".json")
        try encoder.encode(task).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try saveIndex(); writeError = nil
    }
    private func saveIndex() throws {
        let file = directory.appendingPathComponent("index.json")
        try encoder.encode(Index(selectedID: selectedID, tasks: tasks)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    @discardableResult func fork(_ id: String) -> String? {
        guard var original = task(id), original.status != .running else { return nil }
        original.parentID = id; original.id = UUID().uuidString; original.title += " · 分支"
        for call in original.pendingCalls { original.messages.append(AgentMessage(role: "tool", content: "原任务在此处中断，分支尚未执行该操作。", toolCallID: call.id)) }
        original.pendingCalls = []; original.approvals = []; original.status = .ready; original.archived = false
        original.changes = []; original.summary = ""; original.goalAccepted = nil; original.completionEvidence = nil; original.queuedInputs = nil; original.kind = nil
        original.created = Date(); original.updated = Date(); tasks.insert(Self.metadata(original), at: 0); cache[original.id] = original; selectedID = original.id
        do { try save(original.id) } catch { writeError = error.localizedDescription }
        trimCache(keeping: original.id); return original.id
    }
    func backupDirectory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw PetError("任务标识无效") }
        let url = directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return url
    }
}
