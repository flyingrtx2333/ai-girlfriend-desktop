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
    let worktreeRetention: AgentWorktreeRetention
    let desktop: AgentDesktop
    let organization: AgentOrganization
    let deletions: AgentTaskDeletion
    lazy var projectChanges = AgentProjectChanges(store: self)
    lazy var canvases = AgentCanvas(store: self)
    lazy var offices = AgentOffice(store: self)
    lazy var dataImport = AgentDataImport(store: self)
    lazy var knowledge = AgentKnowledgeLibrary(profile: directory.deletingLastPathComponent())
    lazy var knowledgeCards = AgentKnowledgeCards(store: self)
    lazy var wikiMaintenance = AgentWikiMaintenance(store: self)
    lazy var projectKnowledge = AgentProjectKnowledgeGeneration(store: self)
    private(set) var tasks: [AgentTaskRecord] = []
    private var cache: [String: AgentTaskRecord] = [:]
    private var taskHashes: [String: String] = [:]
    private var indexHash: String?
    private var applyingArchive = false
    private var deletionRevision = -1
    private(set) var selectionFallbackMode = AgentWorkMode.coding
    private(set) var writeError: String?
    var onArchive: ((String) -> Void)?
    var onChange: (() -> Void)?
    var archiveIsBusy: ((String) -> Bool)?
    var selectedID: String? { didSet {
        if !applyingArchive {
        do {
            try saveIndex()
            if oldValue != selectedID, let task = tasks.first(where: { $0.id == selectedID }) { try organization.remember(task) }
        } catch { writeError = error.localizedDescription }
        worktreeRetention.tasksChanged()
        }
    } }
    var selected: AgentTaskRecord? { selectedID.flatMap(task) }
    private struct Index: Codable { var selectedID: String?; var tasks: [AgentTaskRecord] }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()

    init(directory: URL, legacy: [ChatMessage], extensionHome: URL? = FileManager.default.homeDirectoryForCurrentUser, mcpKeychain: PetKeychain? = nil, hookKeychain: PetKeychain? = nil) {
        self.directory = directory.appendingPathComponent("agent", isDirectory: true)
        organization = AgentOrganization(profile: directory)
        extensions = AgentExtensions(profile: directory, sharedHome: extensionHome)
        mcp = AgentMCP(profile: directory, keychain: mcpKeychain, plugins: extensions.plugins)
        hooks = AgentHooks(profile: directory, sharedHome: extensionHome, keychain: hookKeychain)
        agents = AgentProfiles(profile: directory)
        teams = AgentTeams(profile: directory)
        automations = AgentAutomations(profile: directory)
        models = AgentTaskModels(profile: directory)
        worktreeRetention = AgentWorktreeRetention(profile: directory)
        desktop = AgentDesktop(profile: directory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        deletions = AgentTaskDeletion(directory: self.directory)
        organization.suppressDeletedArchives(deletions.workspaceIDs)
        var previousSelection: String?
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("index.json")), let index = try? JSONDecoder().decode(Index.self, from: data) {
            indexHash = AgentFiles.hash(data)
            tasks = index.tasks.filter { UUID(uuidString: $0.id) != nil }; previousSelection = index.selectedID
            for i in tasks.indices where tasks[i].status == .running { tasks[i].status = .stopped }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
        let indexedIDs = Set(tasks.map(\.id))
        for file in files where file.pathExtension == "json" && !indexedIDs.contains(file.deletingPathExtension().lastPathComponent) && !deletions.taskIDs.contains(file.deletingPathExtension().lastPathComponent) {
            guard let data = try? Data(contentsOf: file), let task = try? JSONDecoder().decode(AgentTaskRecord.self, from: data),
                  UUID(uuidString: task.id) != nil, file.deletingPathExtension().lastPathComponent == task.id else { continue }
            var recovered = task; Self.recover(&recovered)
            tasks.append(Self.metadata(recovered))
        }
        tasks.sort { $0.updated > $1.updated }
        tasks.removeAll { deletions.taskIDs.contains($0.id) }; deletionRevision = deletions.revision
        if tasks.isEmpty {
            var task = AgentTaskRecord(title: legacy.isEmpty ? "新的任务" : "之前的对话", mode: .ask)
            task.kind = "companion"
            task.messages = legacy.map { AgentMessage(role: $0.role, content: $0.content) }
            tasks.append(Self.metadata(task)); cache[task.id] = task
            do { try save(task.id) } catch { writeError = error.localizedDescription }
        }
        selectedID = tasks.first(where: { $0.id == previousSelection && !$0.archived })?.id ?? tasks.first(where: { !$0.archived })?.id ?? tasks.first?.id
    }
    @discardableResult func create(title: String = "新的任务", workspace: String? = nil, mode: AgentMode = .agent, workMode: AgentWorkMode? = nil) -> String {
        var task = AgentTaskRecord(title: title, workspace: workspace, mode: mode)
        task.workMode = workMode == .coding ? nil : workMode
        selectionFallbackMode = task.organizationMode
        if let token = organization.archiveID(workspace, mode: task.organizationMode) { task.archived = true; task.workspaceArchiveID = token }
        tasks.insert(Self.metadata(task), at: 0); cache[task.id] = task; selectedID = task.id
        do { try save(task.id); try organization.remember(task) } catch { writeError = error.localizedDescription }
        trimCache(keeping: task.id); return task.id
    }
    private static func metadata(_ task: AgentTaskRecord) -> AgentTaskRecord {
        var value = task
        value.activityAt = task.activityAt ?? task.events.map(\.created).max() ?? (task.messages.isEmpty ? task.created : task.updated)
        value.messages = []; value.events = []; value.plan = []; value.changes = []; value.approvals = []; value.pendingCalls = []; value.canvases = nil
        value.artifacts = []; value.sources = []; value.queuedInputs = nil; value.queuedMessages = nil; value.draft = nil; value.contextSummary = nil; value.gitReview = nil; value.attachments = nil; value.draftAttachmentIDs = nil; value.summary = String(value.summary.prefix(240))
        value.hookContexts = nil; value.hookRejectedAnswers = nil
        value.hookPromptIDs = nil; value.hookContextIDs = nil
        value.modelReceipts = nil; value.contextSnapshot = nil; value.recap = nil; value.gitTurn = nil; value.gitPushReview = nil; value.gitPushReceipt = nil; value.gitRemoteSnapshot = nil
        value.knowledgeReads = nil
        value.wikiEditReads = nil
        if var job = value.wikiJob { job.plan = AgentWikiPlan(); job.reviewed = nil; job.pageReads = nil; job.update?.diff = ""; job.update?.retained = [:]; job.update?.assets = [:]; job.update?.baseFiles = [:]; job.update?.changesRead = nil; value.wikiJob = job }
        value.knowledgeJob?.writingNotes = nil
        value.agent?.profile.instructions = ""
        value.team?.team.instructions = ""
        return value
    }
    func installImportedRecord(_ value: AgentTaskRecord) throws {
        guard refreshDeletedRecords(), !deletions.taskIDs.contains(value.id) else { throw PetError(deletions.issue ?? "此任务已永久删除，请重新导入为新任务") }
        var value = value
        guard UUID(uuidString: value.id) != nil, value.importOrigin != nil, ![.running, .waiting].contains(value.status), value.pendingCalls.isEmpty, value.approvals.isEmpty, value.automation == nil, value.agent == nil, value.team == nil else { throw PetError("导入任务包含不能继承的运行状态") }
        if let token = organization.archiveID(value.workspace, mode: value.organizationMode) { value.archived = true; value.workspaceArchiveID = token }
        let previousTasks = tasks, previousCache = cache[value.id]
        if let index = tasks.firstIndex(where: { $0.id == value.id }) { tasks[index] = Self.metadata(value) }
        else { tasks.append(Self.metadata(value)) }
        cache[value.id] = value
        do { try save(value.id) } catch { tasks = previousTasks; cache[value.id] = previousCache; writeError = error.localizedDescription; throw error }
        tasks.sort { $0.updated > $1.updated }; trimCache(keeping: value.id)
    }
    func task(_ id: String) -> AgentTaskRecord? {
        guard refreshDeletedRecords(), !deletions.taskIDs.contains(id) else { return nil }
        if let cached = cache[id] { return cached }
        guard UUID(uuidString: id) != nil, let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".json")),
              var task = try? JSONDecoder().decode(AgentTaskRecord.self, from: data), task.id == id else { return nil }
        if task.importOrigin != nil, task.importOrigin?.historyThroughID == nil {
            let boundary = try? AgentDataImport.historyBoundary(task, directory: directory); task.importOrigin?.historyThroughID = boundary
        }
        let interrupted = !hooks.isRunning(id) && (task.status == .running || task.pendingFileCapture != nil || task.events.contains { $0.status == "running" && $0.hook?.asynchronous == true })
        if interrupted { Self.recover(&task) }
        cache[id] = task
        taskHashes[id] = AgentFiles.hash(data)
        if interrupted {
            if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index] = Self.metadata(task) }
            do { try save(id) } catch { writeError = error.localizedDescription }
        }
        trimCache(keeping: id)
        return task
    }
    func taskViewMetadata() -> [AgentTaskRecord] {
        // Older indexes lack activity dates; load each missing entry once without rewriting its task file.
        _ = refreshDeletedRecords()
        for id in tasks.filter({ $0.activityAt == nil }).map(\.id) { if let value = task(id), let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i] = Self.metadata(value) } else if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].activityAt = tasks[i].updated } }
        return tasks
    }
    @discardableResult func refreshDeletedRecords() -> Bool {
        do {
            try deletions.refresh()
            if deletionRevision != deletions.revision {
                let mode = tasks.first(where: { $0.id == selectedID })?.organizationMode ?? selectionFallbackMode
                let ids = deletions.taskIDs; tasks.removeAll { ids.contains($0.id) }; cache = cache.filter { !ids.contains($0.key) }; taskHashes = taskHashes.filter { !ids.contains($0.key) }
                organization.suppressDeletedArchives(deletions.workspaceIDs); deletionRevision = deletions.revision
                if let selectedID, ids.contains(selectedID) { selectionFallbackMode = mode; applyingArchive = true; self.selectedID = tasks.first(where: { !$0.archived && $0.organizationMode == mode })?.id; applyingArchive = false }
            }; return true
        } catch { writeError = error.localizedDescription; return false }
    }
    private static func recover(_ task: inout AgentTaskRecord) {
        if let capture = task.pendingFileCapture {
            let warning = "执行中断，文件归属尚未确认；请先在“未提交”中核对实际内容。执行前快照已保留：" + capture.manifest
            task.events.append(AgentEvent(kind: "change", title: "变更记录中断", detail: warning, status: "stopped"))
            if task.gitTurn?.id == capture.turnID { task.gitTurn?.warning = warning }
            else { task.gitTurn = AgentGitTurn(id: capture.turnID, changes: [], warning: warning) }
            task.pendingFileCapture = nil
        }
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
        while cache.count > 4, let old = cache.keys.first(where: { $0 != id && $0 != selectedID && cache[$0]?.status != .running && cache[$0]?.pendingFileCapture == nil && !hooks.isRunning($0) }) { cache[old] = nil }
    }
    func update(_ id: String, persist: Bool = true, _ body: (inout AgentTaskRecord) -> Void) {
        guard var value = task(id) else { return }
        let wasArchived = value.archived, previous = value
        body(&value); value.updated = Date()
        guard refreshDeletedRecords(), let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let token = organization.archiveID(value.workspace, mode: value.organizationMode) { value.archived = true; value.workspaceArchiveID = token }
        let messagesChanged = value.messages.count != previous.messages.count || value.messages.last?.id != previous.messages.last?.id || value.messages.last?.content != previous.messages.last?.content || value.messages.last?.reasoning != previous.messages.last?.reasoning || value.messages.last?.toolCalls?.last?.arguments != previous.messages.last?.toolCalls?.last?.arguments
        let eventsChanged = !messagesChanged && (value.events.count != previous.events.count || zip(value.events, previous.events).contains { pair in pair.0.id != pair.1.id || pair.0.status != pair.1.status || pair.0.detail != pair.1.detail || pair.0.duration != pair.1.duration })
        value.activityAt = messagesChanged || eventsChanged ? value.updated : previous.activityAt ?? Self.metadata(previous).activityAt
        cache[id] = value; tasks[index] = Self.metadata(value)
        let coreScopeChanged = previous.workspace != value.workspace || previous.mode != value.mode || previous.permission != value.permission
        let agentScopeChanged = previous.agent?.profile.id != value.agent?.profile.id || previous.agent?.ownerID != value.agent?.ownerID || previous.agent?.readOnly != value.agent?.readOnly || previous.agent?.network != value.agent?.network || previous.agent?.permissionCeiling != value.agent?.permissionCeiling
        let scheduleChanged = previous.automation?.runID != value.automation?.runID || previous.automation?.readOnly != value.automation?.readOnly || previous.automation?.network != value.automation?.network || previous.team?.team.id != value.team?.team.id
        if coreScopeChanged || agentScopeChanged || scheduleChanged { hooks.cancel(id) }
        if value.archived { browser.close(id); canvases.close(id); desktop.disconnect(id); mcp.disconnect(owner: id); hooks.cancel(id) }
        if persist {
            do { try save(id) } catch { writeError = error.localizedDescription; tasks[index].status = .failed }
        }
        if value.archived && !wasArchived { onArchive?(id) }
        offices.changed(id)
        let hookChanged = (previous.events.last?.hook != nil || value.events.last?.hook != nil) && (previous.events.last?.id != value.events.last?.id || previous.events.last?.status != value.events.last?.status)
        if coreScopeChanged || previous.status != value.status || previous.pendingFileCapture?.id != value.pendingFileCapture?.id || previous.archived != value.archived || previous.pinned != value.pinned || previous.worktreeOrigin?.path != value.worktreeOrigin?.path || hookChanged { worktreeRetention.tasksChanged(id) }
    }
    func save(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw PetError("任务标识无效") }
        guard let task = task(id) else { return }
        let file = directory.appendingPathComponent(id + ".json")
        let data = try encoder.encode(task); try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        taskHashes[id] = AgentFiles.hash(data)
        try saveIndex(); writeError = nil
    }
    private func saveIndex() throws {
        guard refreshDeletedRecords() else { throw PetError(deletions.issue ?? "永久删除记录不可用") }
        let file = directory.appendingPathComponent("index.json")
        let data = try encoder.encode(Index(selectedID: selectedID, tasks: tasks)); try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        indexHash = AgentFiles.hash(data)
        onChange?()
    }
    func prepareDeletion(_ ids: [String], workspaceIDs: [String] = []) throws -> AgentTaskDeletionPlan {
        guard refreshDeletedRecords() else { throw PetError(deletions.issue ?? "永久删除记录不可用") }
        guard Set(ids).count == ids.count, Set(workspaceIDs).count == workspaceIDs.count, !ids.isEmpty || !workspaceIDs.isEmpty, !deletions.working, !dataImport.active else { throw PetError("删除范围无效或正在导入／清理任务，请稍候") }
        let files = try AgentFiles(workspace: directory.path), current = try files.entryMetadata(files.literalURL("index.json"))
        guard current.kind == "file", try files.fileHash(files.literalURL("index.json"), maximum: 20_000_000) == indexHash else { throw PetError("任务列表已变化，请重新打开应用后重试") }
        let entries = AgentWorkMode.allCases.flatMap { organization.directories($0, tasks: tasks, includingArchived: true) }.filter { $0.archiveID.map(workspaceIDs.contains) == true }
        guard entries.count == workspaceIDs.count else { throw PetError("工作区归档已变化，请刷新后重试") }
        var selected = Set(ids)
        for entry in entries { selected.formUnion(tasks.filter { $0.workspace == entry.path && $0.organizationMode == entry.mode }.map(\.id)) }
        guard selected.allSatisfy({ id in tasks.contains(where: { $0.id == id }) }) else { throw PetError("任务已不存在，请刷新后重试") }
        var previous = Set<String>()
        while previous != selected {
            previous = selected
            for task in tasks where task.agent?.ownerID.map(selected.contains) == true || task.kind == "hook" && task.parentID.map(selected.contains) == true { selected.insert(task.id) }
        }
        try offices.requireDeletionAllowed(selected)
        var records: [AgentTaskPurge] = [], titles: [String] = []
        for id in selected.sorted() {
            guard let metadata = tasks.first(where: { $0.id == id }) else { throw PetError("任务已变化") }
            let url = try files.literalURL(id + ".json"), entry = try files.entryMetadata(url)
            guard ["file", "missing"].contains(entry.kind) else { throw PetError("任务记录已变成链接或目录，未删除") }
            if entry.kind == "file", let hash = taskHashes[id], try files.fileHash(url, maximum: Int.max) != hash { throw PetError("任务记录已被另一实例修改，请重新打开应用后重试") }
            let task = cache[id] ?? metadata
            guard task.id == id else { throw PetError("任务记录编号不匹配，未删除") }
            try requireArchivable(cache[id] ?? task)
            guard !worktreeRetention.hasNativeOperation(task.workspace) else { throw PetError("此项目正在处理文件或 Git 操作，请完成后再删除任务") }
            let folder = try files.entryMetadata(files.literalURL(id))
            var record = AgentTaskPurge(id: id, recordSignature: entry.signature, directorySignature: folder.kind == "missing" ? nil : folder.signature, directoryIdentity: try AgentTaskDeletion.directoryIdentity(files, name: id))
            if let origin = task.importOrigin, !tasks.contains(where: { !selected.contains($0.id) && $0.importOrigin?.snapshot == origin.snapshot }) {
                let expected = AgentFiles.hash(Data((origin.key + ":" + origin.rawHash).utf8)) + ".jsonl"
                guard origin.snapshot == expected else { throw PetError("导入副本编号不匹配，未删除任务") }
                record.importSnapshot = expected; record.importHash = origin.rawHash
            }
            records.append(record); titles.append(task.title)
        }
        return AgentTaskDeletionPlan(records: records, titles: titles, workspaceIDs: workspaceIDs, workspaceTitles: entries.map { $0.title + " · " + $0.mode.title }, indexHash: indexHash, organizationSignature: try organization.requireCurrentSignature(), deletionSignature: deletions.signature)
    }
    func permanentlyDelete(_ plan: AgentTaskDeletionPlan) async throws -> String? {
        guard refreshDeletedRecords(), !deletions.working, !dataImport.active else { throw PetError(deletions.issue ?? "任务正在导入或清理，请稍候") }
        let current = try prepareDeletion(plan.records.map(\.id), workspaceIDs: plan.workspaceIDs)
        guard current.ids == plan.ids, current.indexHash == plan.indexHash, current.organizationSignature == plan.organizationSignature, current.deletionSignature == plan.deletionSignature,
              zip(current.records, plan.records).allSatisfy({ pair in pair.0.id == pair.1.id && pair.0.recordSignature == pair.1.recordSignature && pair.0.directorySignature == pair.1.directorySignature && pair.0.directoryIdentity == pair.1.directoryIdentity && pair.0.importSnapshot == pair.1.importSnapshot }) else { throw PetError("确认期间任务或删除范围已变化，请重新确认") }
        try deletions.commit(plan.records, workspaces: plan.workspaceIDs, expected: plan.deletionSignature)
        _ = refreshDeletedRecords()
        for id in plan.ids { browser.close(id); canvases.close(id); desktop.disconnect(id); mcp.disconnect(owner: id); hooks.cancel(id); onArchive?(id); offices.closeDeletedTask(id) }
        var warnings: [String] = []
        do { try organization.forgetDeletedRecords(taskIDs: deletions.taskIDs, workspaceIDs: deletions.workspaceIDs, selected: tasks.first { $0.id == selectedID }) } catch { warnings.append("组织记录尚未清理：" + error.localizedDescription) }
        do { try saveIndex() } catch { warnings.append("索引尚未更新：" + error.localizedDescription) }
        if let issue = await deletions.cleanup() { warnings.append(issue) }
        worktreeRetention.tasksChanged()
        return warnings.isEmpty ? nil : "任务记录已永久删除；" + warnings.joined(separator: "；")
    }
    func setTaskUnread(_ id: String, _ unread: Bool) throws {
        guard refreshDeletedRecords(), tasks.contains(where: { $0.id == id }) else { throw PetError(deletions.issue ?? "任务已不存在") }
        try organization.setTaskUnread(id, unread)
    }
    func importTargetID(_ base: String) throws -> String {
        guard refreshDeletedRecords() else { throw PetError(deletions.issue ?? "永久删除记录不可用") }
        var value = base, visited = Set<String>()
        while deletions.taskIDs.contains(value) {
            guard visited.insert(value).inserted else { throw PetError("导入编号冲突") }; value = AgentImportReaders.targetID("reimport:" + value)
        }; return value
    }
    func setArchived(_ ids: [String], archived: Bool) throws {
        let unique = Set(ids); guard !unique.isEmpty, unique.count == ids.count else { throw PetError("请选择任务") }
        var changed: [AgentTaskRecord] = [], directories: [AgentDirectoryEntry] = []
        for id in ids {
            guard var task = task(id), task.archived != archived else { throw PetError("所选任务已变化，请刷新后重试") }
            try requireArchivable(task)
            task.archived = archived; task.workspaceArchiveID = nil; changed.append(task)
            if !archived, let path = task.workspace, let entry = organization.directories(task.organizationMode, tasks: tasks, includingArchived: true).first(where: { $0.path == path && $0.archiveID != nil }), !directories.contains(where: { $0.path == path && $0.mode == task.organizationMode }) {
                var active = entry; active.archiveID = nil; active.archivedAt = nil; directories.append(active)
            }
        }
        try commitArchive(changed, directories: directories)
    }
    func setWorkspaceArchived(_ path: String, mode: AgentWorkMode, archived: Bool) throws {
        guard var entry = organization.directories(mode, tasks: tasks, includingArchived: true).first(where: { $0.path == path }), (entry.archiveID != nil) != archived else { throw PetError("工作区已变化，请刷新后重试") }
        let previousToken = entry.archiveID, token = UUID().uuidString
        var changed: [AgentTaskRecord] = []
        for metadata in tasks where metadata.workspace == path && metadata.organizationMode == mode {
            guard var task = task(metadata.id) else { throw PetError("任务无法读取，未归档工作区") }
            if archived && !task.archived || !archived && task.workspaceArchiveID == previousToken {
                try requireArchivable(task); task.archived = archived; task.workspaceArchiveID = archived ? token : nil; changed.append(task)
            }
        }
        entry.archiveID = archived ? token : nil; entry.archivedAt = archived ? Date() : nil
        try commitArchive(changed, directories: [entry])
    }
    private func requireArchivable(_ task: AgentTaskRecord) throws {
        guard task.status != .running, task.pendingFileCapture == nil, !hooks.isRunning(task.id), archiveIsBusy?(task.id) != true else { throw PetError("请先停止“" + task.title + "”的执行，再归档或恢复") }
    }
    private func commitArchive(_ changed: [AgentTaskRecord], directories: [AgentDirectoryEntry]) throws {
        let files = try AgentFiles(workspace: directory.path)
        var values = changed, next = tasks, writes: [AgentKnowledgeFileWrite] = []
        for i in values.indices {
            values[i].updated = Date(); let value = values[i]
            guard let index = next.firstIndex(where: { $0.id == value.id }), let hash = taskHashes[value.id] else { throw PetError("任务记录已变化，请重新打开应用后重试") }
            writes.append(try AgentKnowledgeFileWrite(files: files, path: value.id + ".json", data: encoder.encode(value), expectedHash: hash, permissions: 0o600, label: "归档")); next[index] = Self.metadata(value)
        }
        let previousMode = selected?.organizationMode
        let selection = next.first(where: { $0.id == selectedID && !$0.archived })?.id ?? next.first(where: { !$0.archived && $0.organizationMode == previousMode })?.id
        let indexWrite = try AgentKnowledgeFileWrite(files: files, path: "index.json", data: encoder.encode(Index(selectedID: selection, tasks: next)), expectedHash: indexHash, missing: indexHash == nil, permissions: 0o600, label: "归档")
        let organizationChange = try organization.prepareArchive(directories, tasks: tasks, selected: next.first { $0.id == selection })
        writes.append(indexWrite); if let organizationChange { writes.append(organizationChange.write) }
        let backup = directory.deletingLastPathComponent().appendingPathComponent("archive-transactions/" + UUID().uuidString)
        try AgentKnowledgeFileBatch.commit(writes, backup: backup, label: "归档操作") {
            for value in values { try self.requireArchivable(value) }
        }
        let newlyArchived = values.filter { value in value.archived && tasks.first(where: { $0.id == value.id })?.archived == false }.map(\.id)
        tasks = next
        for value in values { cache[value.id] = value; taskHashes[value.id] = AgentFiles.hash(try encoder.encode(value)) }
        indexHash = AgentFiles.hash(indexWrite.data!); organizationChange?.accept()
        applyingArchive = true; selectedID = selection; applyingArchive = false
        writeError = nil
        for id in newlyArchived { browser.close(id); canvases.close(id); desktop.disconnect(id); mcp.disconnect(owner: id); hooks.cancel(id); onArchive?(id) }
        for value in values { offices.changed(value.id) }; trimCache(keeping: selection ?? ""); worktreeRetention.tasksChanged()
    }
    @discardableResult func fork(_ id: String) -> String? {
        guard var original = task(id), original.status != .running, original.pendingFileCapture == nil else { return nil }
        guard organization.archiveID(original.workspace, mode: original.organizationMode) == nil else { writeError = "请先恢复此任务的工作区"; return nil }
        original.parentID = id; original.id = UUID().uuidString; original.title += " · 分支"
        original.agent?.ownerID = nil
        do {
            try AgentAttachments.copyForFork(store: self, sourceID: id, targetID: original.id, files: original.attachments ?? [])
            try canvases.copyForFork(sourceID: id, targetID: original.id, records: original.canvases ?? [])
            try extensions.copyForFork(store: self, sourceID: id, task: &original)
        }
        catch { writeError = error.localizedDescription; return nil }
        for call in original.pendingCalls { original.messages.append(AgentMessage(role: "tool", content: "原任务在此处中断，分支尚未执行该操作。", toolCallID: call.id)) }
        original.flushQueuedInputs()
        original.pendingCalls = []; original.approvals = []; original.status = .ready; original.archived = false
        original.workspaceArchiveID = nil
        original.changes = []; original.summary = ""; original.goalAccepted = nil; original.completionEvidence = nil; original.queuedInputs = nil; original.queuedMessages = nil; original.kind = nil
        original.recap = nil; original.gitTurn = nil; original.pendingFileCapture = nil; original.gitPushReview = nil; original.gitPushReceipt = nil; original.gitRemoteSnapshot = nil
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
