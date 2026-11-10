import Foundation

struct AgentAutomationDraft: Codable, Identifiable {
    var id = UUID().uuidString
    var taskID: String
    var callID: String
    var requestHash: String
    var automation: AgentAutomation
    var created = Date()
    var savedAt: Date?
}

@MainActor enum AgentAutomationDrafts {
    static var instructions: String {
        "用户要求创建本机自动化时，载入 automations 工具组，用 draft_automation 起草名称、任务指令和时间计划。当前时间：" + ISO8601DateFormatter().string(from: Date()) + "，本机时区：" + TimeZone.current.identifier + "。指令应写清输入、范围、约束、完成核对与输出；缺少必要信息时先询问。草稿不创建或启用计划，不立即运行。请用户在会话卡片继续配置，核对项目、时区、下次时间、模型和执行授权后保存，并自行选择是否启用。"
    }
    private static func encoded(_ value: AgentAutomation) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func checked(_ draft: AgentAutomationDraft, taskID: String, service: AgentAutomations) throws -> AgentAutomationDraft {
        let value = draft.automation
        var safe = AgentAutomation(id: value.id, name: value.name, prompt: value.prompt, workspace: value.workspace)
        safe.workMode = value.workMode; safe.schedule = value.schedule; safe.output = value.output
        guard draft.taskID == taskID, UUID(uuidString: draft.id) != nil,
              !draft.callID.isEmpty, draft.callID.utf8.count <= 200,
              !draft.callID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              draft.requestHash.count == 64, draft.requestHash.allSatisfy(\.isHexDigit),
              !value.prompt.contains("\0"), try encoded(value) == encoded(safe) else { throw PetError("自动化草稿来源或配置无效，请重新生成") }
        try service.validate(value, runnable: false, allowMissingWorkspace: true)
        return draft
    }
    static func load(_ id: String, taskID: String, store: AgentStore) throws -> AgentAutomationDraft {
        guard let task = store.task(taskID), !task.archived, let drafts = task.automationDrafts, drafts.count <= 8,
              Set(drafts.map(\.id)).count == drafts.count, Set(drafts.map(\.callID)).count == drafts.count,
              let draft = drafts.first(where: { $0.id == id }) else { throw PetError("自动化草稿不可用，请打开原任务") }
        return try checked(draft, taskID: taskID, service: store.automations)
    }
    private struct ScheduleInput: Decodable {
        var frequency: AgentAutomationFrequency
        var time_zone: String
        var at: String?
        var hour: Int?
        var minute: Int?
        var weekdays: [Int]?
        var interval_minutes: Int?
        var expires_at: String?
    }
    private static func date(_ text: String) throws -> Date {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil else { throw PetError("日期需要含时区的 ISO 8601 格式") }
        let formatter = ISO8601DateFormatter()
        var parsed = formatter.date(from: text)
        if parsed == nil { formatter.formatOptions.insert(.withFractionalSeconds); parsed = formatter.date(from: text) }
        let suffix = String(text.suffix(6)), parts = suffix.dropFirst().split(separator: ":")
        let offset: Int
        if text.hasSuffix("Z") { offset = 0 }
        else if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), hour <= 18, minute < 60 { offset = (hour * 3600 + minute * 60) * (suffix.first == "-" ? -1 : 1) }
        else { throw PetError("日期时区偏移无效") }
        guard let value = parsed, let zone = TimeZone(secondsFromGMT: offset) else { throw PetError("日期或时区无效") }
        formatter.timeZone = zone; formatter.formatOptions.remove(.withFractionalSeconds)
        guard formatter.string(from: value).prefix(19) == text.prefix(19) else { throw PetError("日期或时间不存在") }; return value
    }
    private static func schedule(_ object: [String: Any]) throws -> AgentAutomationSchedule {
        let input = try JSONDecoder().decode(ScheduleInput.self, from: JSONSerialization.data(withJSONObject: object))
        var required: Set<String> = ["frequency", "time_zone"], allowed = required
        switch input.frequency {
        case .once: required.insert("at"); allowed = required
        case .daily: required.formUnion(["hour", "minute"]); allowed = required.union(["expires_at"])
        case .weekly: required.formUnion(["hour", "minute", "weekdays"]); allowed = required.union(["expires_at"])
        case .interval: required.insert("interval_minutes"); allowed = required.union(["at", "expires_at"])
        }
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed) else { throw PetError("计划字段与所选频率不一致") }
        var value = AgentAutomationSchedule(); value.frequency = input.frequency; value.timeZone = input.time_zone
        if let at = input.at { value.date = try date(at) }
        if let hour = input.hour { value.hour = hour }; if let minute = input.minute { value.minute = minute }
        if let days = input.weekdays { value.weekdays = days }; if let interval = input.interval_minutes { value.intervalMinutes = interval }
        if let expires = input.expires_at { value.expiration = try date(expires) }
        return value
    }
    static func create(_ call: AgentToolCall, taskID: String, store: AgentStore) throws -> AgentToolResult {
        guard let task = store.task(taskID), !task.archived, task.kind != "hook", !task.isProjectDocumentation,
              task.agent?.ownerID == nil, task.automation == nil else { throw PetError("请在本机普通任务中起草自动化") }
        let args = call.object, keys = Set(args.keys)
        guard keys.isSubset(of: ["name", "prompt", "schedule", "output"]), Set(["name", "prompt", "schedule"]).isSubset(of: keys),
              let name = args["name"] as? String, let prompt = args["prompt"] as? String,
              let scheduleObject = args["schedule"] as? [String: Any] else { throw PetError("自动化草稿需要 name、prompt、schedule") }
        let requestHash = AgentFiles.hash(try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
        let draft: AgentAutomationDraft
        if let previous = task.automationDrafts?.first(where: { $0.callID == call.id }) {
            draft = try load(previous.id, taskID: taskID, store: store)
            guard draft.requestHash == requestHash else { throw PetError("此调用已有另一份自动化草稿，未覆盖") }
        } else {
            guard (task.automationDrafts ?? []).count < 8 else { throw PetError("当前任务已有8份自动化草稿，请先完成配置或在新任务继续") }
            var value = AgentAutomation(name: name, prompt: prompt, workspace: task.workspace ?? "")
            value.workMode = task.workMode; value.schedule = try schedule(scheduleObject)
            if let output = args["output"] { guard let raw = output as? String, let selection = AgentAutomationOutput(rawValue: raw) else { throw PetError("输出方式需要 independent 或 merged") }; value.output = selection }
            draft = try checked(AgentAutomationDraft(taskID: taskID, callID: call.id, requestHash: requestHash, automation: value), taskID: taskID, service: store.automations)
            guard value.schedule.next(after: Date()) != nil else { throw PetError("计划已过期，或到期时间早于下一次运行") }
            store.update(taskID) { if $0.automationDrafts == nil { $0.automationDrafts = [] }; $0.automationDrafts?.append(draft) }
            if let issue = store.writeError { throw PetError(issue) }
        }
        let value = draft.automation
        let result: [String: Any] = ["draft_id": draft.id, "name": value.name, "workspace": value.workspace, "time_zone": value.schedule.timeZone,
                                    "schedule": value.schedule.frequency.rawValue, "saved": draft.savedAt != nil,
                                    "next_action": "在本任务的自动化草稿卡片继续配置，核对项目、时区、下次运行、模型和执行授权，明确保存并选择是否启用。草稿没有创建、启用或运行计划。"]
        return AgentToolResult(text: String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    static func markSaved(_ id: String, taskID: String, automationID: String, store: AgentStore) throws {
        let draft = try load(id, taskID: taskID, store: store)
        guard draft.automation.id == automationID, store.automations.values.contains(where: { $0.id == automationID }) else { throw PetError("自动化尚未保存，草稿记录保留") }
        guard draft.savedAt == nil else { return }
        store.update(taskID) { value in if let index = value.automationDrafts?.firstIndex(where: { $0.id == id }) { value.automationDrafts?[index].savedAt = Date() } }
        if let issue = store.writeError { throw PetError("自动化已保存，任务记录暂未保存：" + issue) }
    }
    static func createConversation(store: AgentStore, sourceID: String?) throws -> String {
        let source = sourceID.flatMap(store.task)
        let id = store.create(title: "创建自动化", workspace: source?.workspace, workMode: source?.workMode)
        store.update(id) { $0.draft = "/automation "; $0.toolGroups = ["automations"] }
        if let issue = store.writeError { throw PetError(issue) }; return id
    }
}
