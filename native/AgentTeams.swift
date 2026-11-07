import Foundation

struct AgentTeam: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var description: String
    var instructions: String
    var leaderID: String
    var memberIDs: [String]
    var enabled = false
}
struct AgentTeamAssignment: Codable { var team: AgentTeam }

@MainActor final class AgentTeams {
    let directory: URL
    var onChange: ((String) -> Void)?
    private struct Document: Codable { var teams: [AgentTeam] }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }()
    init(profile: URL) { directory = profile }
    private func file() throws -> URL { try AgentFiles(workspace: directory.path).resolve("extensions/teams.json") }
    func document() throws -> (String, String?) {
        let url = try file()
        guard FileManager.default.fileExists(atPath: url.path) else { return ("{\"teams\":[]}", nil) }
        let data = try AgentFiles(workspace: directory.path).readData(url, maximum: 512_000)
        guard let text = String(data: data, encoding: .utf8) else { throw PetError("团队配置不是 UTF-8") }
        _ = try decode(text); return (text, AgentFiles.hash(data))
    }
    func decode(_ text: String) throws -> [AgentTeam] {
        guard text.utf8.count <= 512_000, let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["teams"], let entries = object["teams"] as? [[String: Any]], entries.count <= 32 else { throw PetError("配置需要 teams 数组，最多 32 项、512KB") }
        let keys: Set<String> = ["id", "name", "description", "instructions", "leaderID", "memberIDs", "enabled"]
        guard entries.allSatisfy({ Set($0.keys) == keys }) else { throw PetError("团队字段不完整或包含不支持的字段") }
        let values = try JSONDecoder().decode(Document.self, from: Data(text.utf8)).teams
        var names = Set<String>(), ids = Set<String>()
        for value in values {
            guard UUID(uuidString: value.id) != nil, ids.insert(value.id).inserted,
                  !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.name.count <= 60,
                  names.insert(value.name.lowercased()).inserted, value.description.count <= 500,
                  !value.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.instructions.utf8.count <= 24_000,
                  UUID(uuidString: value.leaderID) != nil, (1...4).contains(value.memberIDs.count),
                  Set(value.memberIDs).count == value.memberIDs.count, !value.memberIDs.contains(value.leaderID),
                  value.memberIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw PetError("团队需要唯一名称、指令、一名负责人及一到四名不同成员") }
        }
        return values
    }
    func encode(_ values: [AgentTeam]) throws -> String { String(decoding: try encoder.encode(Document(teams: values)), as: UTF8.self) }
    func list() throws -> [AgentTeam] { try decode(document().0) }
    private func roles(_ team: AgentTeam, store: AgentStore, enabled: Bool) throws -> [AgentProfile] {
        let agents = try store.agents.list()
        let values = try ([team.leaderID] + team.memberIDs).map { id -> AgentProfile in
            guard let role = agents.first(where: { $0.id == id }), !enabled || role.enabled else { throw PetError("团队成员已停用或不存在，请检查自定义 Agent") }; return role
        }
        guard let leader = values.first, leader.availableTools.isSuperset(of: ["list_agents", "delegate_task"]), leader.toolPermissions?["delegate_task"] != .deny, leader.toolPermissions?["list_agents"] != .deny else { throw PetError("负责人需要查找 Agent 与委派子任务权限") }
        return values
    }
    func team(_ id: String, store: AgentStore) throws -> AgentTeam {
        guard let value = try list().first(where: { $0.id == id && $0.enabled }) else { throw PetError("团队未启用或已不存在") }
        _ = try roles(value, store: store, enabled: true); return value
    }
    func save(_ text: String, expectedHash: String?, store: AgentStore, activating: String? = nil) throws {
        let values = try decode(text), previous = try document()
        guard previous.1 == expectedHash else { throw PetError("团队配置已改变，请重新读取后保存") }
        for value in values { _ = try roles(value, store: store, enabled: false) }
        let agentsBefore = try store.agents.document(); var agents = try store.agents.decode(agentsBefore.0)
        let previousTeams = try decode(previous.0)
        let enabledIDs = Set(values.filter { value in value.enabled && (value.id == activating || previousTeams.first(where: { $0.id == value.id })?.enabled != true) }.flatMap { [$0.leaderID] + $0.memberIDs })
        for i in agents.indices where enabledIDs.contains(agents[i].id) { agents[i].enabled = true }
        let agentChanges = try store.agents.encode(agents) != store.agents.encode(store.agents.decode(agentsBefore.0))
        if agentChanges { try store.agents.save(store.agents.encode(agents), expectedHash: agentsBefore.1) }
        do {
            let url = try file(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(try encode(values).utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            if agentChanges { try? store.agents.save(agentsBefore.0, expectedHash: store.agents.document().1) }; throw error
        }
        for old in try decode(previous.0) where old.enabled {
            let next = values.first { $0.id == old.id && $0.enabled }
            if next == nil || next?.leaderID != old.leaderID || next?.memberIDs != old.memberIDs || next?.instructions != old.instructions { onChange?(old.id) }
        }
    }
    func binding(_ task: AgentTaskRecord, store: AgentStore) throws -> AgentTeam? {
        var current = task, seen = Set<String>()
        while seen.insert(current.id).inserted, seen.count <= 5 {
            if let value = current.team?.team { return value }
            guard let owner = current.agent?.ownerID else { return nil }
            guard let parent = store.task(owner), !parent.archived else { throw PetError("团队所属任务不可用") }; current = parent
        }
        throw PetError("团队任务层级无效")
    }
    func check(_ task: AgentTaskRecord, store: AgentStore) throws {
        guard let saved = try binding(task, store: store) else { return }
        let live = try team(saved.id, store: store)
        guard live.leaderID == saved.leaderID, let role = task.agent?.profile.id,
              (role == saved.leaderID && task.team != nil) || (saved.memberIDs.contains(role) && live.memberIDs.contains(role)) else { throw PetError("团队角色已改变，请重新发起任务") }
    }
    func checkDelegate(_ id: String, owner: AgentTaskRecord, store: AgentStore) throws {
        try check(owner, store: store)
        guard let saved = try binding(owner, store: store) else { return }
        let live = try team(saved.id, store: store)
        guard saved.memberIDs.contains(id), live.memberIDs.contains(id), id != owner.agent?.profile.id else { throw PetError("团队只可委派给本次任务中已配置的其他成员") }
    }
    func configureDraft(_ id: String, taskID: String, store: AgentStore) throws {
        let value = try team(id, store: store)
        try store.agents.configureDraft(value.leaderID, taskID: taskID, store: store)
        store.update(taskID) { $0.team = AgentTeamAssignment(team: value) }
        if let error = store.writeError { throw PetError("团队任务未保存：" + error) }
    }
    func createTask(_ id: String, store: AgentStore, workspace: String?, owner: AgentTaskRecord? = nil) throws -> String {
        if let owner, try binding(owner, store: store) != nil { throw PetError("团队任务不能委派到另一个团队") }
        let value = try team(id, store: store)
        let taskID = try store.agents.createTask(value.leaderID, store: store, workspace: workspace, owner: owner)
        store.update(taskID) { $0.team = AgentTeamAssignment(team: value) }
        return taskID
    }
}
