import Foundation
import Darwin

@MainActor final class AgentSideTasks {
    struct Settings: Codable { var version = 1; var recoverable = false }
    private struct InUse: LocalizedError { var errorDescription: String? { "侧任务正在另一个应用实例中使用" } }
    final class Lease {
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    }
    static let sessionID = UUID().uuidString
    private static let leases = NSMapTable<NSString, Lease>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private weak var store: AgentStore?
    private var ownLease: Lease?, startup: Task<Void, Never>?
    private(set) var settings = Settings(), revision: String?, settingsIssue: String?, issue: String?
    private(set) var cleaning = false, ending = false
    var onChange: (() -> Void)?
    var beforeDiscard: ((Set<String>) throws -> Void)?
    init(store: AgentStore) { self.store = store; do { try refreshSettings() } catch { settingsIssue = error.localizedDescription } }
    private func files() throws -> AgentFiles {
        guard let store else { throw PetError("任务列表已关闭") }; return try AgentFiles(workspace: store.directory.deletingLastPathComponent().path)
    }
    func refreshSettings() throws {
        let files = try files(), url = try files.literalURL("side-tasks/settings.json"), state = try files.entryMetadata(url)
        if state.kind == "missing" { settings = Settings(); revision = nil; settingsIssue = nil; return }
        let data = try files.readData(url, maximum: 64_000), value = try JSONDecoder().decode(Settings.self, from: data)
        guard state.kind == "file", value.version == 1 else { throw PetError("侧任务设置版本不可用") }
        settings = value; revision = AgentFiles.hash(data); settingsIssue = nil
    }
    func saveSettings(recoverable: Bool, expectedRevision: String?) throws {
        try refreshSettings(); guard revision == expectedRevision else { throw PetError("侧任务设置已变化，请重新载入") }
        let files = try files(), value = Settings(recoverable: recoverable), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value), write = try AgentKnowledgeFileWrite(files: files, path: "side-tasks/settings.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "侧任务设置")
        try AgentKnowledgeFileBatch.commit([write], backup: files.root.appendingPathComponent("side-tasks/settings-transactions/" + UUID().uuidString), label: "侧任务设置") {
            let url = try files.literalURL("side-tasks/settings.json"), current = try files.entryMetadata(url)
            let hash = current.kind == "missing" ? nil : try files.fileHash(url, maximum: 64_000)
            guard hash == self.revision else { throw PetError("侧任务设置已变化，请重新载入") }
        }
        settings = value; revision = AgentFiles.hash(data); settingsIssue = nil; onChange?()
    }
    private func lease(_ id: String, create: Bool) throws -> Lease {
        guard UUID(uuidString: id) != nil else { throw PetError("侧任务会话编号无效，记录已保留") }
        let files = try files(), key = (files.root.path + "/" + id) as NSString
        if let existing = Self.leases.object(forKey: key) { return existing }
        let (parent, name) = try files.parentDescriptor(files.literalURL("side-tasks/sessions/" + id + ".lock"), create: create); defer { close(parent) }
        let descriptor = openat(parent, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var state = stat()
        guard fstat(descriptor, &state) == 0, state.st_mode & S_IFMT == S_IFREG, state.st_nlink == 1 else { close(descriptor); throw PetError("侧任务会话锁不可用，记录已保留") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { let code = errno; close(descriptor); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        let lease = Lease(descriptor); Self.leases.setObject(lease, forKey: key); return lease
    }
    private func ownSession() throws -> Lease {
        if let ownLease { return ownLease }; let value = try lease(Self.sessionID, create: true); ownLease = value; return value
    }
    func access(_ task: AgentTaskRecord) throws -> Lease? {
        guard let side = task.sideTask else { return nil }
        guard UUID(uuidString: side.parentID) != nil, side.parentID != task.id else { throw PetError("侧任务关联无效，记录已保留") }
        do { return try side.sessionID == Self.sessionID ? ownSession() : lease(side.sessionID, create: false) }
        catch let error as POSIXError where error.code == .EWOULDBLOCK || error.code == .EAGAIN { throw InUse() }
    }
    func requireOpen(_ task: AgentTaskRecord) throws {
        guard let side = task.sideTask else { return }
        guard side.sessionID == Self.sessionID else { throw PetError("请从主任务重新打开侧任务") }; _ = try ownSession()
    }
    func requireCanRun(_ task: AgentTaskRecord) throws {
        guard !ending, let store else { throw PetError("应用正在退出，请稍后重新打开任务") }
        for record in [task] + (try store.agents.ancestors(task, store: store)) { try requireOpen(record) }
    }
    func bindToSession(_ task: inout AgentTaskRecord) throws { _ = try ownSession(); task.sideTask?.sessionID = Self.sessionID }
    static func supported(_ task: AgentTaskRecord) -> Bool {
        !task.archived && !task.isProjectDocumentation && !["hook", "voice"].contains(task.kind ?? "") && task.automation == nil && task.agent?.ownerID == nil && task.sideTask == nil && task.pendingFileRollback == nil
    }
    @discardableResult func create(parentID: String) throws -> String {
        guard let store, !cleaning, !ending, !store.deletions.working, let parent = store.task(parentID), Self.supported(parent), store.organization.archiveID(parent.organizationWorkspace, mode: parent.organizationMode) == nil else { throw PetError("此任务暂时不能新建侧任务") }
        try refreshSettings(); let version = try store.recordVersion(parentID)
        if parent.workspacePaths.contains(where:{store.hasFileRollback(in:$0)}) { throw PetError("请先恢复此项目未完成的文件撤回") }
        var scope = parent; try store.agents.detachForFork(&scope, store: store)
        var task = AgentTaskRecord(title: "新的任务", workspace: parent.workspace, mode: parent.mode)
        AgentWorkspaceScope.copy(parent,to:&task)
        task.workMode = parent.workMode; task.parentID = parentID; task.permission = parent.permission; task.agent = scope.agent; task.team = scope.team; task.inheritedLimits = scope.inheritedLimits
        task.model = parent.model; task.modelOverride = parent.modelOverride; task.gitDirectory = parent.gitDirectory; task.worktreeOrigin = parent.worktreeOrigin
        task.sideTask = AgentSideTask(parentID: parentID, retained: settings.recoverable, sessionID: Self.sessionID); try bindToSession(&task)
        try store.installRelatedRecord(task, sourceID: parentID, expectedHash: version, label: "新建侧任务"); return task.id
    }
    func children(of parentID: String) -> [AgentTaskRecord] { (store?.tasks ?? []).filter { $0.sideTask?.parentID == parentID && !$0.archived }.sorted { $0.updated > $1.updated } }
    func sidebarVisible(_ task: AgentTaskRecord) -> Bool {
        guard let side = task.sideTask else { return true }; return store?.tasks.contains { $0.id == side.parentID && !$0.archived } != true
    }
    func open(_ id: String) throws {
        guard !cleaning, !ending, let store, var task = store.task(id), task.sideTask != nil else { throw PetError("侧任务暂不可用，请稍后重试") }
        let access = try self.access(task); defer { withExtendedLifetime(access) {} }
        if task.sideTask?.sessionID != Self.sessionID {
            let hash = try store.recordVersion(id); try bindToSession(&task)
            _ = try store.commitTaskRecord(task, expectedHash: hash, transaction: store.directory.deletingLastPathComponent().appendingPathComponent("side-tasks/open/" + UUID().uuidString), label: "打开侧任务")
        }
    }
    static func hasUnfinishedFiles(_ task: AgentTaskRecord) -> Bool {
        task.pendingFileRollback != nil || task.pendingFileCapture != nil || task.gitTurn?.warning != nil || task.sideTask?.needsReview == true || task.changeRounds?.contains { $0.warning != nil } == true
    }
    func keepAsTask(_ id: String) throws {
        guard let store, var task = store.task(id), task.sideTask != nil else { throw PetError("侧任务不可用") }
        let access = try self.access(task); defer { withExtendedLifetime(access) {} }
        let hash = try store.recordVersion(id); task.sideTask = nil
        task.events.append(AgentEvent(kind: "state", title: "已保留为独立任务", status: "completed"))
        _ = try store.commitTaskRecord(task, expectedHash: hash, transaction: store.directory.deletingLastPathComponent().appendingPathComponent("side-tasks/keep/" + UUID().uuidString), label: "保留侧任务")
    }
    func discard(_ id: String) async throws -> String? {
        guard let store, let task = store.task(id) else { return nil }; try requireOpen(task); return try await purge(task)
    }
    private func purge(_ task: AgentTaskRecord) async throws -> String? {
        guard let store, let side = task.sideTask, !side.retained, !Self.hasUnfinishedFiles(task) else { throw PetError("侧任务有未完成的文件记录，请先恢复或保留为独立任务") }
        let plan = try store.prepareDeletion([task.id]); try beforeDiscard?(plan.ids); return try await store.permanentlyDelete(plan)
    }
    func startSession() {
        guard startup == nil else { return }; startup = Task { [weak self] in await self?.cleanup(staleOnly: true) }
    }
    func waitForStartup() async { await startup?.value }
    func endSession() async { ending = true; await waitForStartup(); await cleanup(staleOnly: false) }
    private func cleanup(staleOnly: Bool) async {
        guard let store, !cleaning else { return }; cleaning = true; onChange?(); defer { cleaning = false; onChange?() }
        var problems: [String] = []
        let candidates = store.tasks.filter { $0.sideTask?.retained == false && ($0.sideTask?.sessionID != Self.sessionID) == staleOnly }
        for metadata in candidates {
            do {
                let access: Lease?
                do { access = try self.access(metadata) }
                catch is InUse { continue }
                defer { withExtendedLifetime(access) {} }
                guard let task = store.task(metadata.id), task.sideTask?.sessionID == metadata.sideTask?.sessionID else { throw PetError("侧任务记录已变化，未清理") }
                if let warning = try await purge(task) { problems.append(warning) }
            } catch { problems.append(metadata.title + "：" + error.localizedDescription) }
        }
        issue = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }
}
