import AppKit
import Darwin

enum AgentAutomationFrequency: String, Codable, CaseIterable {
    case once, daily, weekly, interval
    var title: String { self == .once ? "仅一次" : self == .daily ? "每天" : self == .weekly ? "每周" : "固定间隔" }
}
enum AgentAutomationOutput: String, Codable, CaseIterable {
    case independent, merged
    var title: String { self == .independent ? "独立任务" : "合并到同一任务" }
}
struct AgentAutomationSchedule: Codable {
    var frequency = AgentAutomationFrequency.daily
    var timeZone = TimeZone.current.identifier
    var date = Date().addingTimeInterval(3600)
    var hour = 9, minute = 0, weekdays = [2], intervalMinutes = 60
    var expiration: Date?
    func next(after now: Date) -> Date? {
        guard let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let value: Date?
        switch frequency {
        case .once: value = date > now ? date : nil
        case .interval:
            let seconds = Double(intervalMinutes) * 60
            guard seconds > 0 else { return nil }
            value = date > now ? date : date.addingTimeInterval((floor(now.timeIntervalSince(date) / seconds) + 1) * seconds)
        case .daily, .weekly:
            var match: Date?
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)), frequency == .daily || weekdays.contains(calendar.component(.weekday, from: day)),
                      let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first), candidate > now else { continue }
                match = candidate; break
            }
            value = match
        }
        return value.flatMap { expiration == nil || frequency == .once || $0 <= expiration! ? $0 : nil }
    }
}
enum AgentAutomationRunStatus: String, Codable, CaseIterable {
    case starting, running, waiting, completed, failed, stopped, missed, skipped
    var terminal: Bool { ![.starting, .running, .waiting].contains(self) }
    var title: String { switch self {
    case .starting: return "排队中"; case .running: return "执行中"; case .waiting: return "需要我"; case .completed: return "已完成"
    case .failed: return "失败"; case .stopped: return "已停止"; case .missed: return "错过时段"; case .skipped: return "已跳过"
    } }
}
struct AgentAutomationRun: Codable, Identifiable {
    var id = UUID().uuidString
    var automationID: String
    var name: String
    var scheduled: Date
    var trigger: String
    var taskID: String?
    var status = AgentAutomationRunStatus.starting
    var detail = ""
    var created = Date(), finished: Date?
    var unread = false
    var fileName: String { String(format: "%016.0f", created.timeIntervalSince1970 * 1000) + "-" + id + ".json" }
}
struct AgentAutomation: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var prompt: String
    var workspace: String
    var workMode: AgentWorkMode?
    var schedule = AgentAutomationSchedule()
    var output = AgentAutomationOutput.independent
    var executor = "default"
    var model = ""
    var permission = AgentPermissionMode.review
    var readOnly = true, network = false, notify = true
    var enabled = false, archived = false
    var nextRun: Date?
    var mergedTaskID: String?
    var current: AgentAutomationRun?
}
struct AgentAutomationAssignment: Codable {
    var automationID: String, runID: String, name: String, workspace: String
    var permission: AgentPermissionMode
    var readOnly: Bool, network: Bool
}

@MainActor final class AgentAutomations {
    static let changed = Notification.Name("BlueFatFishAutomationsChanged")
    let directory: URL
    private(set) var values: [AgentAutomation] = []
    private(set) var error: String?
    private(set) var keepAwake = false
    private(set) var unreadCount = 0
    private(set) var isStarted = false
    var onNotice: ((AgentAutomationRun) -> Void)?
    private weak var store: AgentStore?
    private weak var runtime: AgentRuntime?
    private var timer: Timer?, ownerFD: Int32 = -1, activity: NSObjectProtocol?
    private var firing = false
    private var revision: String?
    private struct Document: Codable { var version = 1; var keepAwake = false; var automations: [AgentAutomation] }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }()
    init(profile: URL) { directory = profile.appendingPathComponent("automations", isDirectory: true) }
    deinit { timer?.invalidate(); if ownerFD >= 0 { close(ownerFD) }; if let activity { ProcessInfo.processInfo.endActivity(activity) } }
    private var config: URL { directory.appendingPathComponent("definitions.json") }
    private var runsDirectory: URL { directory.appendingPathComponent("runs", isDirectory: true) }
    func start(store: AgentStore, runtime: AgentRuntime) {
        guard !isStarted else { return }; self.store = store; self.runtime = runtime
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try AgentFiles(workspace: directory.deletingLastPathComponent().path).resolve("automations").path == directory.path else { throw PetError("自动化目录不能指向应用数据目录之外") }
            ownerFD = open(directory.appendingPathComponent("scheduler.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard ownerFD >= 0, flock(ownerFD, LOCK_EX | LOCK_NB) == 0 else { if ownerFD >= 0 { close(ownerFD); ownerFD = -1 }; throw PetError("另一应用实例正在管理此目录的自动化") }
            try load(); isStarted = true
            for value in values where value.current != nil { recover(value.id) }
            unreadCount = (try history(limit: Int.max).runs).filter(\.unread).count
            tick()
        } catch { self.error = error.localizedDescription; changed() }
    }
    func stop() { timer?.invalidate(); timer = nil; isStarted = false; if ownerFD >= 0 { close(ownerFD); ownerFD = -1 }; if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil } }
    private func changed() { NotificationCenter.default.post(name: Self.changed, object: self) }
    private func load() throws {
        guard FileManager.default.fileExists(atPath: config.path) else { values = []; revision = nil; return }
        let data = try AgentFiles(workspace: directory.path).readData(config, maximum: 2_000_000)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "keepAwake", "automations"],
              let entries = raw["automations"] as? [[String: Any]], entries.allSatisfy({ Set($0.keys).isSubset(of: ["id", "name", "prompt", "workspace", "schedule", "output", "executor", "model", "permission", "readOnly", "network", "notify", "enabled", "archived", "nextRun", "mergedTaskID", "current"]) }) else { throw PetError("自动化配置包含不支持的字段") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.automations.count <= 64, Set(document.automations.map(\.id)).count == document.automations.count else { throw PetError("自动化配置版本或数量无效") }
        for value in document.automations { try validate(value, runnable: false) }
        values = document.automations; keepAwake = document.keepAwake; revision = AgentFiles.hash(data)
    }
    private func persist() throws {
        let current = FileManager.default.fileExists(atPath: config.path) ? try AgentFiles.hash(Data(contentsOf: config)) : nil
        guard current == revision else { throw PetError("自动化配置已被其他程序更改，请重启应用重新读取") }
        let data = try encoder.encode(Document(keepAwake: keepAwake, automations: values))
        try data.write(to: config, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        revision = AgentFiles.hash(data); error = nil
    }
    func validate(_ value: AgentAutomation, runnable: Bool) throws {
        guard UUID(uuidString: value.id) != nil, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.name.count <= 80,
              !value.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.prompt.utf8.count <= 40_000,
              value.workspace.hasPrefix("/"), value.workspace.utf8.count <= 4096, value.model.count <= 200,
              TimeZone(identifier: value.schedule.timeZone) != nil, (0...23).contains(value.schedule.hour), (0...59).contains(value.schedule.minute),
              (1...525_600).contains(value.schedule.intervalMinutes), value.schedule.weekdays.allSatisfy({ (1...7).contains($0) }), Set(value.schedule.weekdays).count == value.schedule.weekdays.count,
              value.schedule.frequency != .weekly || !value.schedule.weekdays.isEmpty,
              value.executor == "default" || ((value.executor.hasPrefix("agent:") || value.executor.hasPrefix("team:")) && value.executor.split(separator: ":").count == 2 && UUID(uuidString: String(value.executor.split(separator: ":").last ?? "")) != nil) else { throw PetError("请填写有效名称、任务、项目目录、执行者与时间计划") }
        if runnable {
            let files = try AgentFiles(workspace: value.workspace)
            guard files.root.path == value.workspace else { throw PetError("项目目录已改变，请重新选择") }
            if value.executor.hasPrefix("agent:"), let store { _ = try store.agents.profile(String(value.executor.dropFirst(6))) }
            if value.executor.hasPrefix("team:"), let store { _ = try store.teams.team(String(value.executor.dropFirst(5)), store: store) }
        }
    }
    func save(_ value: AgentAutomation, expected: AgentAutomation?) throws {
        guard isStarted else { throw PetError(error ?? "自动化调度未启动") }
        try validate(value, runnable: value.enabled && !value.archived)
        let index = values.firstIndex { $0.id == value.id }, old = index.map { values[$0] }
        guard try editableHash(old) == editableHash(expected) else { throw PetError("此自动化已改变，请重新读取后保存") }
        guard !values.contains(where: { $0.id != value.id && !$0.archived && $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) else { throw PetError("自动化名称重复") }
        guard index != nil || values.count < 64 else { throw PetError("最多保存64个自动化") }
        var next = value; next.current = old?.current; next.mergedTaskID = old?.mergedTaskID
        if let old, old.workspace != value.workspace || old.executor != value.executor || old.output != value.output { next.mergedTaskID = nil }
        if next.schedule.frequency == .interval, old?.schedule.frequency != .interval || old?.schedule.intervalMinutes != next.schedule.intervalMinutes { next.schedule.date = Date() }
        next.nextRun = next.enabled && !next.archived ? next.schedule.next(after: Date()) : nil
        if next.enabled, !next.archived, next.nextRun == nil { throw PetError("计划已过期，或到期时间早于下一次运行") }
        let previous = values
        if let index { values[index] = next } else { values.append(next) }
        do { try persist() } catch { values = previous; throw error }
        if let old, old.workspace != next.workspace || old.executor != next.executor || old.permission != next.permission || old.readOnly != next.readOnly || old.network != next.network {
            if let task = old.current?.taskID { runtime?.cancel(task) }
        }
        scheduleTimer(); changed()
    }
    private func editableHash(_ value: AgentAutomation?) throws -> String? {
        guard var value else { return nil }; value.current = nil; value.nextRun = nil; value.mergedTaskID = nil
        return try AgentFiles.hash(encoder.encode(value))
    }
    func setPaused(_ id: String, paused: Bool) throws {
        guard let value = values.first(where: { $0.id == id }) else { throw PetError("自动化不存在") }
        var next = value; next.enabled = !paused; try save(next, expected: value)
    }
    func setKeepAwake(_ enabled: Bool) throws { guard isStarted else { throw PetError(error ?? "调度未启动") }; let old = keepAwake; keepAwake = enabled; do { try persist() } catch { keepAwake = old; throw error }; scheduleTimer(); changed() }
    private func scheduleTimer() {
        timer?.invalidate(); timer = nil
        guard isStarted else { return }
        let next = values.filter { $0.enabled && !$0.archived }.compactMap(\.nextRun).min()
        if let next { let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in Task { @MainActor in self?.tick() } }; timer.tolerance = 0.25; self.timer = timer; RunLoop.main.add(timer, forMode: .common) }
        if keepAwake, activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "BlueFatFish scheduled automations") }
        if !keepAwake, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    var hasSleepActivity: Bool { activity != nil }
    func wake() { if isStarted { tick() } }
    private func tick() {
        guard isStarted, !firing else { return }; firing = true; defer { firing = false; scheduleTimer() }
        let now = Date(), due = values.filter { $0.enabled && !$0.archived && ($0.nextRun ?? .distantFuture) <= now }.map(\.id)
        for id in due {
            guard let i = values.firstIndex(where: { $0.id == id }), let date = values[i].nextRun else { continue }
            let old = values[i]
            values[i].nextRun = values[i].schedule.next(after: now)
            if values[i].nextRun == nil { values[i].enabled = false }
            do {
                if now.timeIntervalSince(date) > 60 { var run = AgentAutomationRun(automationID: id, name: old.name, scheduled: date, trigger: "schedule"); run.status = .missed; run.detail = "应用未能在计划时段运行，未补跑。"; run.finished = now; try persist(); try record(run, notify: old.notify) }
                else { try launch(id, scheduled: date, trigger: "schedule") }
            } catch { self.error = error.localizedDescription; changed() }
        }
    }
    func runNow(_ id: String) throws { guard isStarted else { throw PetError(error ?? "自动化调度未启动") }; try launch(id, scheduled: Date(), trigger: "manual"); scheduleTimer() }
    private func launch(_ id: String, scheduled: Date, trigger: String) throws {
        guard let store, let runtime, let i = values.firstIndex(where: { $0.id == id && !$0.archived }) else { throw PetError("自动化不可用") }
        let value = values[i]
        var run = AgentAutomationRun(automationID: id, name: value.name, scheduled: scheduled, trigger: trigger)
        if value.current != nil || value.mergedTaskID.map({ runtime.isRunning($0) || store.task($0)?.status == .waiting }) == true {
            run.status = .skipped; run.detail = "上一轮或合并任务仍在执行或等待处理。"; run.finished = Date(); try persist(); try record(run, notify: false); return
        }
        values[i].current = run
        do { try persist() } catch { values[i].current = nil; throw error }
        do {
            try writeRun(run); try validate(value, runnable: true)
            let selected = store.selectedID; defer { store.selectedID = selected }
            let taskID: String
            if value.output == .merged, let existing = value.mergedTaskID, let task = store.task(existing), !task.archived {
                guard task.workspace == value.workspace, task.agent?.ownerID == nil, task.automation?.automationID == id else { throw PetError("合并任务范围已改变，请新建自动化") }
                taskID = existing
                try store.agents.refreshAutomationRole(taskID, executor: value.executor, store: store)
            } else if value.executor.hasPrefix("agent:") { taskID = try store.agents.createTask(String(value.executor.dropFirst(6)), store: store, workspace: value.workspace, workMode: value.workMode) }
            else if value.executor.hasPrefix("team:") { taskID = try store.teams.createTask(String(value.executor.dropFirst(5)), store: store, workspace: value.workspace, workMode: value.workMode) }
            else { taskID = store.create(workspace: value.workspace, workMode: value.workMode) }
            run.taskID = taskID
            store.update(taskID) { task in
                task.automation = AgentAutomationAssignment(automationID: id, runID: run.id, name: value.name, workspace: value.workspace, permission: value.permission, readOnly: value.readOnly, network: value.network)
                task.modelOverride = nil
                task.permission = AgentProfiles.tighter(task.agent?.profile.permission ?? value.permission, value.permission)
                if task.agent == nil { task.model = value.model; task.toolGroups = ["files"] }
                task.title = value.name; task.status = .ready; task.mode = .agent
                task.events.append(AgentEvent(kind: "automation", title: trigger == "schedule" ? "按计划运行" : "手动运行", detail: "\(value.name) · \(Self.dateText(scheduled, zone: value.schedule.timeZone))", status: "completed"))
            }
            if let error = store.writeError { throw PetError("自动化任务未保存：" + error) }
            values[i].current = run; if value.output == .merged { values[i].mergedTaskID = taskID }; try persist(); try writeRun(run)
            guard runtime.submit(value.prompt, taskID: taskID) else { throw PetError(runtime.submissionError ?? "自动化任务未开始") }
            changed()
        } catch {
            if let taskID = run.taskID { runtime.cancel(taskID) }
            run.status = .failed; run.detail = error.localizedDescription; run.finished = Date(); values[i].current = nil; try persist(); try record(run, notify: value.notify)
        }
    }
    private func recover(_ id: String) {
        guard let i = values.firstIndex(where: { $0.id == id }), var run = values[i].current else { return }
        do {
            if let task = run.taskID.flatMap({ store?.task($0) }), task.status == .waiting { run.status = .waiting; values[i].current = run; try writeRun(run); try persist(); return }
            if let task = run.taskID.flatMap({ store?.task($0) }), task.status == .completed { run.status = .completed; run.detail = task.summary }
            else { run.status = .stopped; run.detail = "应用中断，未自动重放。继续前检查实际任务。" }
            run.finished = Date(); values[i].current = nil; try persist(); try record(run, notify: false)
        } catch { self.error = error.localizedDescription }
    }
    func taskChanged(_ id: String, inspectChildren: Bool = false) {
        guard isStarted, let task = store?.task(id), let binding = task.automation, let i = values.firstIndex(where: { $0.id == binding.automationID }), var run = values[i].current, run.id == binding.runID, run.taskID == id else { return }
        let review = inspectChildren || run.status == .waiting ? runtime?.pendingReview(id) : nil
        let state: AgentAutomationRunStatus = review != nil || task.status == .waiting ? .waiting : task.status == .ready ? .starting : task.status == .running ? .running : task.status == .completed ? .completed : task.status == .failed ? .failed : .stopped
        guard run.status != state else { return }
        run.status = state; run.detail = task.status == .completed ? task.summary : state == .waiting ? (review ?? task).approvals.last?.reason ?? "等待处理" : task.events.last(where: { $0.status == "failed" || $0.status == "stopped" })?.detail ?? ""
        if state.terminal { run.finished = Date() }
        do {
            try record(run, notify: values[i].notify && (state.terminal || state == .waiting))
            values[i].current = state.terminal ? nil : run; try persist(); changed()
        } catch { self.error = error.localizedDescription; changed() }
    }
    private func writeRun(_ run: AgentAutomationRun) throws {
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = runsDirectory.appendingPathComponent(run.fileName); try encoder.encode(run).write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func record(_ value: AgentAutomationRun, notify: Bool) throws {
        var run = value; run.detail = String(run.detail.prefix(2000))
        if notify { run.unread = true }
        let old = try? JSONDecoder().decode(AgentAutomationRun.self, from: Data(contentsOf: runsDirectory.appendingPathComponent(run.fileName)))
        if old?.unread == true { run.unread = true }
        try writeRun(run)
        if run.unread && old?.unread != true { unreadCount += 1 }
        changed(); if notify { onNotice?(run) }
    }
    func history(automationID: String? = nil, status: AgentAutomationRunStatus? = nil, offset: Int = 0, limit: Int = 50) throws -> (runs: [AgentAutomationRun], total: Int) {
        guard FileManager.default.fileExists(atPath: runsDirectory.path) else { return ([], 0) }
        let files = try FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var matched = 0, result: [AgentAutomationRun] = []
        for file in files {
            let data = try AgentFiles(workspace: directory.path).readData(file, maximum: 24_000), run = try JSONDecoder().decode(AgentAutomationRun.self, from: data)
            guard UUID(uuidString: run.id) != nil, file.lastPathComponent == run.fileName else { throw PetError("运行记录无效：" + file.lastPathComponent) }
            if (automationID == nil || run.automationID == automationID) && (status == nil || run.status == status) { if matched >= max(0, offset), result.count < max(0, limit) { result.append(run) }; matched += 1 }
        }
        return (result, matched)
    }
    func markRead(_ value: AgentAutomationRun) throws {
        let file = runsDirectory.appendingPathComponent(value.fileName); var run = try JSONDecoder().decode(AgentAutomationRun.self, from: Data(contentsOf: file))
        if run.unread { run.unread = false; try writeRun(run); unreadCount = max(0, unreadCount - 1); changed() }
    }
    func permission(_ task: AgentTaskRecord) -> AgentPermissionMode {
        guard let binding = task.automation else { return .automatic }
        return AgentProfiles.tighter(binding.permission, values.first(where: { $0.id == binding.automationID })?.permission ?? binding.permission)
    }
    func limits(_ task: AgentTaskRecord) -> (readOnly: Bool, network: Bool) {
        guard let binding = task.automation else { return (false, true) }
        let live = values.first { $0.id == binding.automationID }
        return (binding.readOnly || live?.readOnly == true, binding.network && live?.network != false)
    }
    func check(_ call: AgentToolCall, task: AgentTaskRecord, owner: AgentTaskRecord) throws {
        guard let binding = owner.automation else { return }
        let live = values.first { $0.id == binding.automationID }
        guard task.workspace == binding.workspace, live == nil || live?.workspace == binding.workspace else { throw PetError("自动化项目范围已改变，请重新发起任务") }
        let limits = limits(owner)
        if limits.readOnly, AgentProfiles.mutating.contains(call.name) || AgentMCP.externalOperations.contains(call.name) || (call.name == "browser_action" && ["click", "fill", "select"].contains(call.object["action"] as? String ?? "")) { throw PetError("此自动化只读，不能修改项目或操作外部服务／应用") }
        if !limits.network, (["web_search", "fetch_url", "browser_open", "browser_action"] + AgentMCP.externalOperations + AgentGit.externalTools + AgentDesktop.externalTools).contains(call.name) || (call.name == "run_command" && call.object["network"] as? Bool == true) { throw PetError("此自动化未允许联网与外部连接") }
    }
    static func dateText(_ date: Date, zone: String) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"; return formatter.string(from: date) }
}
