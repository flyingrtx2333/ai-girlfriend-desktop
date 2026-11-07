import Foundation

@MainActor final class AgentStore {
    let directory: URL
    let browser = AgentBrowser()
    let extensions: AgentExtensions
    let mcp: AgentMCP
    let hooks: AgentHooks
    let agents: AgentProfiles
    let teams: AgentTeams
    let automations: AgentAutomations
    let models: AgentTaskModels
    private(set) var tasks: [AgentTaskRecord] = []
    private var cache: [String: AgentTaskRecord] = [:]
    private(set) var writeError: String?
    var onArchive: ((String) -> Void)?
    var selectedID: String? { didSet { do { try saveIndex() } catch { writeError = error.localizedDescription } } }
    var selected: AgentTaskRecord? { selectedID.flatMap(task) }
    private struct Index: Codable { var selectedID: String?; var tasks: [AgentTaskRecord] }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()

    init(directory: URL, legacy: [ChatMessage], extensionHome: URL? = FileManager.default.homeDirectoryForCurrentUser, mcpKeychain: PetKeychain? = nil, hookKeychain: PetKeychain? = nil) {
        self.directory = directory.appendingPathComponent("agent", isDirectory: true)
        extensions = AgentExtensions(profile: directory, sharedHome: extensionHome)
        mcp = AgentMCP(profile: directory, keychain: mcpKeychain)
        hooks = AgentHooks(profile: directory, sharedHome: extensionHome, keychain: hookKeychain)
        agents = AgentProfiles(profile: directory)
        teams = AgentTeams(profile: directory)
        automations = AgentAutomations(profile: directory)
        models = AgentTaskModels(profile: directory)
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
            var recovered = task; Self.recover(&recovered)
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
        value.artifacts = []; value.sources = []; value.queuedInputs = nil; value.queuedMessages = nil; value.draft = nil; value.contextSummary = nil; value.gitReview = nil; value.attachments = nil; value.draftAttachmentIDs = nil; value.summary = String(value.summary.prefix(240))
        value.hookContexts = nil; value.hookRejectedAnswers = nil
        value.hookPromptIDs = nil; value.hookContextIDs = nil
        value.modelReceipts = nil; value.contextSnapshot = nil; value.recap = nil; value.gitTurn = nil; value.gitPushReview = nil; value.gitPushReceipt = nil; value.gitRemoteSnapshot = nil
        value.agent?.profile.instructions = ""
        value.team?.team.instructions = ""
        return value
    }
    func task(_ id: String) -> AgentTaskRecord? {
        if let cached = cache[id] { return cached }
        guard UUID(uuidString: id) != nil, let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".json")),
              var task = try? JSONDecoder().decode(AgentTaskRecord.self, from: data), task.id == id else { return nil }
        let interrupted = !hooks.isRunning(id) && (task.status == .running || task.events.contains { $0.status == "running" && $0.hook?.asynchronous == true })
        if interrupted { Self.recover(&task) }
        cache[id] = task
        if interrupted {
            if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index] = Self.metadata(task) }
            do { try save(id) } catch { writeError = error.localizedDescription }
        }
        trimCache(keeping: id)
        return task
    }
    private static func recover(_ task: inout AgentTaskRecord) {
        for i in task.events.indices where task.events[i].status == "running" && task.events[i].hook?.asynchronous == true {
            task.events[i].status = "stopped"; task.events[i].hook?.delivery = "interrupted"
            task.events[i].detail += "\n应用中断，后台结果未确认；未自动重放"
        }
        guard task.status == .running else { return }
        task.status = .stopped; task.goalAccepted = nil; task.completionEvidence = nil
        task.hookSession = nil
        for call in task.pendingCalls {
            task.messages.append(AgentMessage(role: "tool", content: "应用中断，此操作的执行结果未知。继续前检查实际状态，不直接重放。", toolCallID: call.id))
            if !task.events.contains(where: { $0.toolCallID == call.id }) { task.events.append(AgentEvent(kind: "tool", title: call.name, detail: "应用中断，执行结果未知", status: "stopped", toolCallID: call.id)) }
        }
        task.pendingCalls = []
        task.flushQueuedInputs()
        task.messages.removeAll { $0.role == "assistant" && $0.content.isEmpty && ($0.toolCalls ?? []).isEmpty }
        for i in task.events.indices where task.events[i].status == "running" { task.events[i].status = "stopped" }
        task.events.append(AgentEvent(kind: "state", title: "应用中断，检查后可继续", detail: "未确认的操作不会自动重放。", status: "stopped"))
    }
    private func trimCache(keeping id: String) {
        while cache.count > 4, let old = cache.keys.first(where: { $0 != id && $0 != selectedID && cache[$0]?.status != .running && !hooks.isRunning($0) }) { cache[old] = nil }
    }
    func update(_ id: String, persist: Bool = true, _ body: (inout AgentTaskRecord) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), var value = task(id) else { return }
        let wasArchived = value.archived, previous = value
        body(&value); value.updated = Date(); cache[id] = value; tasks[index] = Self.metadata(value)
        let coreScopeChanged = previous.workspace != value.workspace || previous.mode != value.mode || previous.permission != value.permission
        let agentScopeChanged = previous.agent?.profile.id != value.agent?.profile.id || previous.agent?.ownerID != value.agent?.ownerID || previous.agent?.readOnly != value.agent?.readOnly || previous.agent?.network != value.agent?.network || previous.agent?.permissionCeiling != value.agent?.permissionCeiling
        let scheduleChanged = previous.automation?.runID != value.automation?.runID || previous.automation?.readOnly != value.automation?.readOnly || previous.automation?.network != value.automation?.network || previous.team?.team.id != value.team?.team.id
        if coreScopeChanged || agentScopeChanged || scheduleChanged { hooks.cancel(id) }
        if value.archived { browser.close(id); mcp.disconnect(owner: id); hooks.cancel(id) }
        if persist {
            do { try save(id) } catch { writeError = error.localizedDescription; tasks[index].status = .failed }
        }
        if value.archived && !wasArchived { onArchive?(id) }
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
        original.agent?.ownerID = nil
        do {
            try AgentAttachments.copyForFork(store: self, sourceID: id, targetID: original.id, files: original.attachments ?? [])
            try extensions.copyForFork(store: self, sourceID: id, task: &original)
        }
        catch { writeError = error.localizedDescription; return nil }
        for call in original.pendingCalls { original.messages.append(AgentMessage(role: "tool", content: "原任务在此处中断，分支尚未执行该操作。", toolCallID: call.id)) }
        original.flushQueuedInputs()
        original.pendingCalls = []; original.approvals = []; original.status = .ready; original.archived = false
        original.changes = []; original.summary = ""; original.goalAccepted = nil; original.completionEvidence = nil; original.queuedInputs = nil; original.queuedMessages = nil; original.kind = nil
        original.recap = nil; original.gitTurn = nil; original.gitPushReview = nil; original.gitPushReceipt = nil; original.gitRemoteSnapshot = nil
        original.hookSession = nil; original.hookContexts = nil; original.hookContextIDs = nil
        original.hookRewakePromptID = nil; original.hookRewakeCount = nil
        for i in original.events.indices where original.events[i].status == "running" && original.events[i].hook?.asynchronous == true {
            original.events[i].status = "stopped"; original.events[i].hook?.delivery = "fork-history"
            original.events[i].detail += "\n分支保留记录，不接管原任务的后台执行"
        }
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
