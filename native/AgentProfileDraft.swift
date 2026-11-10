import Foundation

struct AgentProfileDraft: Codable, Identifiable {
    var id = UUID().uuidString
    var taskID: String
    var callID: String
    var profile: AgentProfile
    var created = Date()
    var savedAt: Date?
}

@MainActor enum AgentProfileDrafts {
    static func checked(_ draft: AgentProfileDraft, taskID: String, agents: AgentProfiles) throws -> AgentProfileDraft {
        let value = draft.profile
        let safe = AgentProfile(id: value.id, name: value.name, description: value.description, instructions: value.instructions)
        guard draft.taskID == taskID, UUID(uuidString: draft.id) != nil,
              !draft.callID.isEmpty, draft.callID.utf8.count <= 200,
              !draft.callID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [value.name, value.description].allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              !value.instructions.contains("\0"),
              try agents.encode([value]) == agents.encode([safe]) else { throw PetError("Agent 草稿来源或配置无效，请重新生成") }
        _ = try agents.decode(agents.encode([safe]))
        return draft
    }
    static func load(_ id: String, taskID: String, store: AgentStore) throws -> AgentProfileDraft {
        guard let task = store.task(taskID), !task.archived, (task.agentDrafts ?? []).count <= 8,
              let draft = task.agentDrafts?.first(where: { $0.id == id }) else { throw PetError("Agent 草稿不可用，请打开原任务") }
        return try checked(draft, taskID: taskID, agents: store.agents)
    }
    static func create(_ call: AgentToolCall, taskID: String, store: AgentStore) throws -> AgentToolResult {
        guard let task = store.task(taskID), !task.archived, task.kind != "hook", !task.isProjectDocumentation else { throw PetError("请在本机普通任务中生成 Agent 草稿") }
        let args = call.object
        guard Set(args.keys) == ["name", "description", "instructions"],
              let name = args["name"] as? String, let description = args["description"] as? String,
              let instructions = args["instructions"] as? String else { throw PetError("Agent 草稿需要 name、description、instructions") }
        let profile = AgentProfile(name: name, description: description, instructions: instructions)
        var draft = try checked(AgentProfileDraft(taskID: taskID, callID: call.id, profile: profile), taskID: taskID, agents: store.agents)
        if let previous = task.agentDrafts?.first(where: { $0.callID == call.id }) {
            draft = try checked(previous, taskID: taskID, agents: store.agents)
            guard draft.profile.name == name, draft.profile.description == description, draft.profile.instructions == instructions else { throw PetError("此工具调用已有另一份草稿，未覆盖") }
        } else {
            guard (task.agentDrafts ?? []).count < 8 else { throw PetError("当前任务已有8份 Agent 草稿，请先完成配置或在新任务继续") }
            store.update(taskID) { if $0.agentDrafts == nil { $0.agentDrafts = [] }; $0.agentDrafts?.append(draft) }
            if let issue = store.writeError { throw PetError(issue) }
        }
        let object: [String: Any] = ["draft_id": draft.id, "name": name, "description": description, "instructions": instructions, "saved": draft.savedAt != nil,
                                   "next_action": "在本任务的 Agent 草稿卡片选择“继续配置”，检查模型、权限和扩展后保存。草稿不会创建或启用 Agent；不能把生成草稿报告为创建完成。"]
        return AgentToolResult(text: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }
    static func markSaved(_ id: String, taskID: String, profileID: String, store: AgentStore) throws {
        let draft = try load(id, taskID: taskID, store: store)
        guard draft.profile.id == profileID, try store.agents.decode(store.agents.document().0).contains(where: { $0.id == profileID }) else { throw PetError("Agent 尚未保存，草稿记录保留") }
        guard draft.savedAt == nil else { return }
        store.update(taskID) { value in
            if let index = value.agentDrafts?.firstIndex(where: { $0.id == id }) { value.agentDrafts?[index].savedAt = Date() }
        }
        if let issue = store.writeError { throw PetError("Agent 已保存，任务记录暂未保存：" + issue) }
    }
}
