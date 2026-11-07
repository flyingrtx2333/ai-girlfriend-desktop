import AppKit
import Darwin

struct AgentWorktreeRetentionPolicy: Codable, Equatable {
    var version = 1
    var enabled = false
    var idleSeconds: Double = 30 * 86400
    var archivedOnly = true
    func validate() throws {
        guard version == 1, idleSeconds.isFinite, (1...31_536_000).contains(idleSeconds) else { throw PetError("保留期需要在 1 秒至 365 天之间") }
    }
    var summary: String {
        (archivedOnly ? "仅已归档任务" : "全部闲置任务") + " · " + Self.duration(idleSeconds) + "后回收\n先完整备份文件与暂存状态，长期保留备份和分支。"
    }
    static func duration(_ seconds: Double) -> String {
        if seconds.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(seconds / 86400)) 天" }
        if seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600)) 小时" }
        return "\(Int(seconds)) 秒"
    }
}
struct AgentWorktreeRoot: Identifiable {
    var id: String; var taskID: String; var path: String; var metadata: String
    var title: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct AgentWorktreeRetentionReceipt: Codable, Identifiable {
    var id = UUID().uuidString
    var created = Date()
    var root: String; var path: String; var backupID: String?; var error: String?
}

@MainActor final class AgentWorktreeRetention {
    private static let policyChanged = Notification.Name("BlueFatFishWorktreePolicyChanged")
    let directory: URL
    private(set) var policy = AgentWorktreeRetentionPolicy(), revision: String?, error: String?
    private(set) var status = "自动回收未开启", nextCheck: Date?, isChecking = false
    var onChange: (() -> Void)?
    private weak var store: AgentStore?
    private var ownerFD: Int32 = -1, timer: Timer?, debounce: DispatchWorkItem?, job: Task<Void, Never>?, git: AgentGit?
    private var policyObserver: NSObjectProtocol?
    private var target: String?, rescan = false
    private var knownActivity: [String: Date] = [:], retryAfter: [String: Date] = [:]
    private var nativeOperations: [UUID: String] = [:]
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }()
    init(profile: URL) { directory = profile.appendingPathComponent("worktrees"); reload() }
    deinit { timer?.invalidate(); debounce?.cancel(); if ownerFD >= 0 { close(ownerFD) }; if let policyObserver { DistributedNotificationCenter.default().removeObserver(policyObserver) } }
    private func rawPolicy() throws -> Data? {
        let file = directory.appendingPathComponent("policy.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try AgentFiles(workspace: directory.path).readData(file, maximum: 16_000)
    }
    func reload() {
        let previous = revision
        do {
            let data = try rawPolicy(); revision = data.map(AgentFiles.hash)
            if let data {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["version", "enabled", "idleSeconds", "archivedOnly"] else { throw PetError("回收设置含缺失或不支持的字段") }
                let value = try JSONDecoder().decode(AgentWorktreeRetentionPolicy.self, from: data); try value.validate(); policy = value
            } else { policy = AgentWorktreeRetentionPolicy() }
            error = nil
        } catch { self.error = error.localizedDescription; policy.enabled = false }
        if previous != revision { cancelWork() }
        changed()
    }
    func save(_ value: AgentWorktreeRetentionPolicy, expectedRevision: String?, consent: Bool = false) throws {
        try value.validate()
        guard try rawPolicy().map(AgentFiles.hash) == expectedRevision else { throw PetError("回收设置已变化，请重新载入后保存") }
        guard !value.enabled || value == policy || consent else { throw PetError("请先确认自动回收的范围与保留期") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try encoder.encode(value)
        try AgentFiles(workspace: directory.path).writeData(data, to: directory.appendingPathComponent("policy.json"), permissions: 0o600)
        policy = value; revision = AgentFiles.hash(data); error = nil; retryAfter = [:]
        cancelWork(); changed()
        DistributedNotificationCenter.default().postNotificationName(Self.policyChanged, object: AgentFiles.hash(Data(directory.path.utf8)), userInfo: nil, deliverImmediately: true)
    }
    func start(store: AgentStore) {
        self.store = store
        if policyObserver == nil {
            policyObserver = DistributedNotificationCenter.default().addObserver(forName: Self.policyChanged, object: AgentFiles.hash(Data(directory.path.utf8)), queue: .main) { [weak self] _ in Task { @MainActor in self?.reload() } }
        }
        changed()
    }
    func stop() {
        cancelWork(); timer?.invalidate(); timer = nil; debounce?.cancel(); debounce = nil; releaseOwner(); store = nil
        if let policyObserver { DistributedNotificationCenter.default().removeObserver(policyObserver); self.policyObserver = nil }
    }
    private func releaseOwner() { if ownerFD >= 0 { close(ownerFD); ownerFD = -1 } }
    private func cancelWork() { job?.cancel(); git?.cancel(); timer?.invalidate(); timer = nil; nextCheck = nil }
    func tasksChanged(_ id: String? = nil) {
        if let target, let store {
            if let id, store.tasks.contains(where: { $0.id == id && $0.archived && $0.workspace.map { Self.within($0, target) } == true }), !FileManager.default.fileExists(atPath: target) { return }
            let affected = store.tasks.filter { $0.workspace.map { Self.within($0, target) } == true }
            if affected.contains(where: { [.running, .waiting].contains($0.status) || store.hooks.isRunning($0.id) }) || store.selected?.workspace.map({ Self.within($0, target) }) == true || nativeOperations.values.contains(where: { Self.within(target, $0) || Self.within($0, target) }) { job?.cancel(); git?.cancel() }
        }
        changed()
    }
    func setNativeOperation(_ owner: UUID, taskID: String, busy: Bool) {
        if busy, let workspace = store?.task(taskID)?.workspace { nativeOperations[owner] = workspace }
        else { nativeOperations[owner] = nil }
        tasksChanged()
    }
    private func changed() {
        debounce?.cancel(); timer?.invalidate(); timer = nil; nextCheck = nil
        guard store != nil, error == nil, policy.enabled else { cancelWork(); releaseOwner(); status = error.map { "回收设置：" + $0 } ?? "自动回收未开启"; onChange?(); return }
        let work = DispatchWorkItem { [weak self] in self?.beginCheck() }; debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        onChange?()
    }
    func checkNow() { retryAfter = [:]; debounce?.cancel(); timer?.invalidate(); timer = nil; beginCheck() }
    private func acquireOwner() throws {
        if ownerFD >= 0 { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = try AgentFiles(workspace: directory.path).resolve("scheduler.lock")
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PetError("不能打开回收调度锁") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw PetError("另一个应用实例正在管理自动回收") }
        ownerFD = fd
    }
    static func within(_ path: String, _ root: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }
    func roots() -> [AgentWorktreeRoot] {
        guard let store else { return [] }
        var result: [AgentWorktreeRoot] = [], seen = Set<String>()
        for task in store.tasks {
            guard let origin = task.worktreeOrigin else { continue }
            let root = URL(fileURLWithPath: origin.root).standardizedFileURL.resolvingSymlinksInPath().path
            let metadata = URL(fileURLWithPath: origin.metadata).standardizedFileURL.resolvingSymlinksInPath().path
            let key = root + "\0" + metadata
            guard seen.insert(key).inserted, let owner = store.tasks.first(where: { $0.workspace.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == root } == true }) else { continue }
            result.append(AgentWorktreeRoot(id: AgentFiles.hash(Data(key.utf8)), taskID: owner.id, path: root, metadata: metadata))
        }
        return result.sorted { $0.path < $1.path }
    }
    private func related(_ entry: AgentWorktreeEntry) throws -> [AgentTaskRecord] {
        guard let store else { throw PetError("应用正在退出") }
        let tasks = store.tasks.filter { $0.workspace.map { Self.within($0, entry.path) } == true }
        guard !tasks.isEmpty, Set(tasks.map(\.id)) == Set(entry.taskIDs) else { throw PetError("关联任务已变化，稍后重新检查") }
        return tasks
    }
    private func protectedReason(_ entry: AgentWorktreeEntry, tasks: [AgentTaskRecord]) -> String? {
        guard let store else { return "应用正在退出" }
        if let unavailable = entry.unavailable { return unavailable }
        if store.selected?.workspace.map({ Self.within($0, entry.path) }) == true { return "当前任务" }
        if tasks.contains(where: \.pinned) { return "已固定任务" }
        if policy.archivedOnly && tasks.contains(where: { !$0.archived }) { return "任务未归档" }
        var ancestors = tasks, seen = Set<String>()
        while let task = ancestors.popLast() {
            guard seen.insert(task.id).inserted else { continue }
            if [.running, .waiting].contains(task.status) || store.hooks.isRunning(task.id) { return "关联任务正在运行或等待处理" }
            if let workspace = task.workspace, nativeOperations.values.contains(where: { Self.within($0, workspace) && Self.within(workspace, $0) }) { return "Git 操作进行中" }
            if let id = task.parentID, let parent = store.tasks.first(where: { $0.id == id }) { ancestors.append(parent) }
        }
        return nil
    }
    private func authorize(_ entry: AgentWorktreeEntry, activity: Date, expected: String?) throws {
        try Task.checkCancellation()
        guard let store, ownerFD >= 0, policy.enabled, error == nil, try rawPolicy().map(AgentFiles.hash) == expected, store.writeError == nil else { throw PetError("回收设置、调度权或存储状态已变化") }
        let tasks = try related(entry)
        if let reason = protectedReason(entry, tasks: tasks) { throw PetError(reason) }
        knownActivity[entry.path] = max(knownActivity[entry.path] ?? .distantPast, activity)
        let latest = max(tasks.map(\.updated).max() ?? .distantFuture, activity)
        guard Date().timeIntervalSince(latest) >= policy.idleSeconds else { throw PetError("工作树近期仍有活动") }
    }
    private func beginCheck() {
        guard let store, policy.enabled, error == nil else { status = error ?? "自动回收未开启"; onChange?(); return }
        if job != nil { rescan = true; return }
        do { try acquireOwner() } catch { status = error.localizedDescription; onChange?(); return }
        isChecking = true; status = "正在检查工作树…"; onChange?()
        job = Task { [weak self, weak store] in
            guard let self, let store else { return }
            let revision = self.revision; var deadline: Date?, recycled = 0, protected = Set<String>(), failures = 0
            func later(_ value: Date) { deadline = min(deadline ?? value, value) }
            for root in roots() {
                if Task.isCancelled { break }
                do {
                    let helper = try AgentGit(store: store, taskID: root.taskID, directory: URL(fileURLWithPath: root.metadata), allowsArchivedWorktreeSource: true)
                    guard try AgentGit.metadata(workspace: root.path).path == root.metadata else { throw PetError("项目 Git 元数据已变化") }
                    git = helper
                    let entries = try await helper.worktrees()
                    for entry in entries where entry.owned && entry.path != root.path {
                        if Task.isCancelled { break }
                        let tasks = try related(entry)
                        if let reason = protectedReason(entry, tasks: tasks) { protected.insert(reason); later(Date().addingTimeInterval(600)); continue }
                        if let retry = retryAfter[entry.path], retry > Date() { later(retry); continue }
                        let latest = max(tasks.map(\.updated).max() ?? .distantFuture, knownActivity[entry.path] ?? .distantPast)
                        let due = latest.addingTimeInterval(policy.idleSeconds)
                        if due > Date() { later(due); continue }
                        target = entry.path
                        helper.worktreeEligibilityCheck = { [weak self] current, modified in guard let self else { throw CancellationError() }; try self.authorize(current, activity: modified, expected: revision) }
                        do {
                            let scan = Task.detached { try Self.fileActivity(URL(fileURLWithPath: entry.path)) }
                            let activity = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                            try authorize(entry, activity: activity, expected: revision)
                            let review = try await helper.prepareWorktreeRecycle(path: entry.path)
                            let backup = try await helper.recycleWorktree(reviewHash: review.hash)
                            try saveReceipt(AgentWorktreeRetentionReceipt(root: root.path, path: entry.path, backupID: backup.id)); recycled += 1
                        } catch {
                            if Task.isCancelled { break }
                            if let activity = knownActivity[entry.path], activity.addingTimeInterval(policy.idleSeconds) > Date() { later(activity.addingTimeInterval(policy.idleSeconds)) }
                            else { let retry = Date().addingTimeInterval(600); retryAfter[entry.path] = retry; later(retry); failures += 1; try? saveReceipt(AgentWorktreeRetentionReceipt(root: root.path, path: entry.path, error: error.localizedDescription)) }
                        }
                        target = nil; helper.worktreeEligibilityCheck = nil
                    }
                } catch { if !Task.isCancelled { failures += 1; later(Date().addingTimeInterval(600)) } }
            }
            target = nil; git = nil; isChecking = false; job = nil
            if !policy.enabled { status = "自动回收未开启" }
            else { status = "已检查 · 回收 \(recycled) 个" + (protected.isEmpty ? "" : " · 受保护：" + protected.sorted().prefix(2).joined(separator: "、")) + (failures == 0 ? "" : " · \(failures) 项未完成") }
            if policy.enabled, let deadline { nextCheck = max(deadline, Date().addingTimeInterval(1)); timer = Timer.scheduledTimer(withTimeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in Task { @MainActor in self?.beginCheck() } } }
            onChange?()
            if rescan { rescan = false; changed() }
        }
    }
    private func saveReceipt(_ receipt: AgentWorktreeRetentionReceipt) throws {
        let file = directory.appendingPathComponent("history.json")
        var values = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([AgentWorktreeRetentionReceipt].self, from: $0) } ?? []
        values.insert(receipt, at: 0)
        try AgentFiles(workspace: directory.path).writeData(try encoder.encode(Array(values.prefix(100))), to: file, permissions: 0o600)
    }
    func receipts() throws -> [AgentWorktreeRetentionReceipt] {
        let file = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([AgentWorktreeRetentionReceipt].self, from: AgentFiles(workspace: directory.path).readData(file, maximum: 1_000_000))
    }
    nonisolated private static func fileActivity(_ root: URL) throws -> Date {
        guard let raw = realpath(root.path, nil) else { throw PetError("工作树目录不可用") }
        let physical = URL(fileURLWithPath: String(cString: raw)); free(raw)
        let fm = FileManager.default; var error: Error?
        var latest = try fm.attributesOfItem(atPath: physical.path)[.modificationDate] as? Date ?? .distantPast
        guard let walk = fm.enumerator(at: physical, includingPropertiesForKeys: nil, errorHandler: { _, value in error = value; return false }) else { throw PetError("工作树不可读") }
        for case let file as URL in walk {
            try Task.checkCancellation()
            if file.path == physical.appendingPathComponent(".git").path { walk.skipDescendants(); continue }
            guard file.lastPathComponent != ".git" else { throw PetError("工作树含子仓库") }
            let attributes = try fm.attributesOfItem(atPath: file.path)
            latest = max(latest, attributes[.modificationDate] as? Date ?? .distantPast)
        }
        if let error { throw error }; return latest
    }
}
