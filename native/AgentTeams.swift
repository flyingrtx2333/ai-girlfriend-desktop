import Foundation

struct AgentTeam: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var description: String
    var instructions: String
    var leaderID: String
    var memberIDs: [String]
    var enabled = false
    var workspace: String?
    var roleSources: [String: AgentPluginAgentReference]?
}
struct AgentTeamAssignment: Codable { var team: AgentTeam }

@MainActor final class AgentTeams {
    let directory: URL
    var onChange: ((String) -> Void)?
    private struct Document: Codable { var teams: [AgentTeam] }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }()
    init(profile: URL) { directory = profile }
    private func file() throws -> URL {
        let files = try AgentFiles(workspace: directory.path), requested = files.root.appendingPathComponent("extensions/teams.json")
        guard try files.literalURL(requested.path) == requested else { throw PetError("团队配置目录不能是链接") }; return requested
    }
    func document() throws -> (String, String?) {
        let url = try file()
        let files = try AgentFiles(workspace: directory.path), entry = try files.entryMetadata(url)
        guard entry.kind != "missing" else { return ("{\"teams\":[]}", nil) }
        guard entry.kind == "file", try files.resolve(url.path) == url else { throw PetError("团队配置不能是链接或特殊文件") }
        let data = try files.readData(url, maximum: 512_000)
        guard let text = String(data: data, encoding: .utf8) else { throw PetError("团队配置不是 UTF-8") }
        _ = try decode(text); return (text, AgentFiles.hash(data))
    }
    func decode(_ text: String, draft: Bool = false) throws -> [AgentTeam] {
        guard text.utf8.count <= 512_000, let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["teams"], let entries = object["teams"] as? [[String: Any]], entries.count <= 32 else { throw PetError("配置需要 teams 数组，最多 32 项、512KB") }
        let keys: Set<String> = ["id", "name", "description", "instructions", "leaderID", "memberIDs", "enabled"]
        guard entries.allSatisfy({ keys.isSubset(of: Set($0.keys)) && Set($0.keys).isSubset(of: keys.union(["workspace", "roleSources"])) }) else { throw PetError("团队字段不完整或包含不支持的字段") }
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
            if let path = value.workspace { guard path.hasPrefix("/"), path.utf8.count <= 4000, !path.contains("\0"), URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw PetError("团队项目路径无效") } }
            let roles = Set([value.leaderID] + value.memberIDs)
            guard (value.roleSources?.count ?? 0) <= 5 else { throw PetError("团队成员来源超过五项") }
            let projects = try Set((value.roleSources ?? [:]).values.compactMap { try AgentPlugins.scope($0.name).workspace })
            for (id, source) in value.roleSources ?? [:] {
                guard UUID(uuidString: id) != nil, draft || roles.contains(id), UUID(uuidString: source.installationID) != nil, !source.activationID.isEmpty, source.activationID.utf8.count <= 256,
                      source.sha256.count == 64, source.sha256.allSatisfy(\.isHexDigit), AgentExtensions.validName(source.key), !source.key.contains(":"),
                      try AgentPlugins.scope(source.name).workspace.map({ $0 == value.workspace || value.workspace == nil && projects.count > 1 }) ?? true else { throw PetError("团队成员来源与项目不匹配") }
            }
        }
        return values
    }
    func encode(_ values: [AgentTeam]) throws -> String { String(decoding: try encoder.encode(Document(teams: values)), as: UTF8.self) }
    func list() throws -> [AgentTeam] { try decode(document().0) }
    func sourceWorkspaces(_ team: AgentTeam) throws -> Set<String> {
        var projects = try Set((team.roleSources ?? [:]).values.compactMap { try AgentPlugins.scope($0.name).workspace })
        if let workspace = team.workspace { projects.insert(workspace) }; return projects
    }
    private func requireSources(_ team: AgentTeam, workspace: String?, task: AgentTaskRecord?) throws {
        let required = try sourceWorkspaces(team)
        if let task {
            guard required.allSatisfy(task.includesWorkspaceRoot) else { throw PetError("此团队需要当前任务包含全部源文件夹") }
        } else if !required.isEmpty {
            guard required.count == 1, let workspace, try required.contains(AgentFiles(workspace: workspace).root.path) else { throw PetError("此团队不属于当前项目或需要多源工作区") }
        }
    }
    private func roles(_ team: AgentTeam, store: AgentStore, enabled: Bool, workspace: String? = nil, task: AgentTaskRecord? = nil, validateSources: Bool = true) throws -> [AgentProfile] {
        try requireSources(team, workspace: workspace, task: task)
        let agents: [AgentProfile]
        if let task { agents = try store.agents.list(task: task) } else { agents = try store.agents.list(workspace: workspace) }
        let values = try ([team.leaderID] + team.memberIDs).map { id -> AgentProfile in
            guard let role = agents.first(where: { $0.id == id }), !enabled || role.enabled else { throw PetError("团队成员已停用或不存在，请检查当前项目的 Agent 与插件") }
            if validateSources, let sources = team.roleSources, sources[id] != role.pluginSource { throw PetError("团队成员的插件来源或启用状态已变化，请重新审阅并保存团队") }; return role
        }
        guard let leader = values.first, leader.availableTools.isSuperset(of: ["list_agents", "delegate_task"]), leader.toolPermissions?["delegate_task"] != .deny, leader.toolPermissions?["list_agents"] != .deny else { throw PetError("负责人需要查找 Agent 与委派子任务权限") }
        return values
    }
    func team(_ id: String, store: AgentStore, workspace: String? = nil, task: AgentTaskRecord? = nil) throws -> AgentTeam {
        guard var value = try list().first(where: { $0.id == id && $0.enabled }) else { throw PetError("团队未启用或已不存在") }
        let profiles = try roles(value, store: store, enabled: true, workspace: workspace, task: task)
        if value.roleSources == nil { value.roleSources = sources(profiles) }; return value
    }
    private func sources(_ profiles: [AgentProfile]) -> [String: AgentPluginAgentReference]? {
        let values = Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in profile.pluginSource.map { (profile.id, $0) } }); return values.isEmpty ? nil : values
    }
    func save(_ text: String, expectedHash: String?, store: AgentStore, activating: String? = nil, workspace: String? = nil, task: AgentTaskRecord? = nil) throws {
        var values = try decode(text, draft: true); let previous = try document()
        guard previous.1 == expectedHash else { throw PetError("团队配置已改变，请重新读取后保存") }
        let previousTeams = try decode(previous.0)
        for i in values.indices {
            let old = previousTeams.first { $0.id == values[i].id }
            if old == values[i] && values[i].id != activating { continue }
            if var disabled = old { disabled.enabled = false; if values[i] == disabled { continue } }
            if let required = old?.workspace { guard let workspace, try AgentFiles(workspace: workspace).root.path == required else { throw PetError("请在原项目修改此团队：" + URL(fileURLWithPath: required).lastPathComponent) } }
            if let old { try requireSources(old, workspace: workspace, task: task) }
            let profiles = try roles(values[i], store: store, enabled: false, workspace: workspace, task: task, validateSources: false)
            if values[i].enabled, let unavailable = profiles.first(where: { $0.pluginSource != nil && !$0.enabled }) { throw PetError("请先在插件窗口审阅并启用：" + unavailable.name) }
            let projects = try Set(profiles.compactMap { try $0.pluginSource.flatMap { try AgentPlugins.scope($0.name).workspace } })
            guard projects.count <= 1 || task?.workspaceScope != nil && projects.allSatisfy({ task?.includesWorkspaceRoot($0) == true }) else { throw PetError("团队成员必须属于当前任务的源文件夹") }
            values[i].workspace = projects.count == 1 ? projects.first : nil; values[i].roleSources = sources(profiles)
        }
        let data = Data(try encode(values).utf8); _ = try decode(String(decoding: data, as: UTF8.self))
        let files = try AgentFiles(workspace: directory.path), write = try AgentKnowledgeFileWrite(files: files, path: try file().path, data: data, expectedHash: previous.1, missing: previous.1 == nil, permissions: 0o600, label: "团队配置")
        try write.requireCurrent()
        let agentsBefore = try store.agents.document(); var agents = try store.agents.decode(agentsBefore.0)
        let enabledIDs = Set(values.filter { value in value.enabled && (value.id == activating || previousTeams.first(where: { $0.id == value.id })?.enabled != true) }.flatMap { [$0.leaderID] + $0.memberIDs })
        for i in agents.indices where enabledIDs.contains(agents[i].id) { agents[i].enabled = true }
        let nextAgents = try store.agents.encode(agents), agentChanges = try nextAgents != store.agents.encode(store.agents.decode(agentsBefore.0))
        if agentChanges { try store.agents.save(nextAgents, expectedHash: agentsBefore.1) }
        do {
            try write.requireCurrent(); try write.files.writeData(data, to: write.url, permissions: write.permissions, expectedTarget: write.signature)
        } catch {
            if agentChanges { try? store.agents.save(agentsBefore.0, expectedHash: AgentFiles.hash(Data(nextAgents.utf8))) }; throw error
        }
        for old in try decode(previous.0) where old.enabled {
            let next = values.first { $0.id == old.id && $0.enabled }
            if next == nil || next?.leaderID != old.leaderID || next?.memberIDs != old.memberIDs || next?.instructions != old.instructions || next?.workspace != old.workspace || next?.roleSources != old.roleSources { onChange?(old.id) }
        }
    }
    func binding(_ task: AgentTaskRecord, store: AgentStore) throws -> AgentTeam? {
        var current = task, seen = Set<String>()
        while seen.insert(current.id).inserted, seen.count <= 5 {
            if let value = current.team?.team { return value }
            if let value = current.agent?.teamCeiling { return value }
            guard let owner = current.agent?.ownerID else { return nil }
            guard let parent = store.task(owner), !parent.archived else { throw PetError("团队所属任务不可用") }; current = parent
        }
        throw PetError("团队任务层级无效")
    }
    func check(_ task: AgentTaskRecord, store: AgentStore) throws {
        guard let saved = try binding(task, store: store) else { return }
        let live = try team(saved.id, store: store, task: task)
        guard live.leaderID == saved.leaderID, live.workspace == saved.workspace, let role = task.agent?.profile.id,
              (role == saved.leaderID && task.team != nil) || (saved.memberIDs.contains(role) && live.memberIDs.contains(role)) else { throw PetError("团队角色已改变，请重新发起任务") }
        for id in [saved.leaderID] + saved.memberIDs where saved.roleSources?[id] != live.roleSources?[id] { throw PetError("团队成员的插件来源已变化，请重新发起任务") }
    }
    func checkDelegate(_ id: String, owner: AgentTaskRecord, store: AgentStore) throws {
        try check(owner, store: store)
        guard let saved = try binding(owner, store: store) else { return }
        let live = try team(saved.id, store: store, task: owner)
        guard saved.memberIDs.contains(id), live.memberIDs.contains(id), id != owner.agent?.profile.id else { throw PetError("团队只可委派给本次任务中已配置的其他成员") }
    }
    func configureDraft(_ id: String, taskID: String, store: AgentStore) throws {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        let value = try team(id, store: store, task: task)
        try store.agents.configureDraft(value.leaderID, taskID: taskID, store: store)
        store.update(taskID) { $0.team = AgentTeamAssignment(team: value) }
        if let error = store.writeError { throw PetError("团队任务未保存：" + error) }
    }
    func createTask(_ id: String, store: AgentStore, workspace: String?, owner: AgentTaskRecord? = nil, workMode: AgentWorkMode? = nil, context: AgentTaskRecord? = nil) throws -> String {
        if let owner, try binding(owner, store: store) != nil { throw PetError("团队任务不能委派到另一个团队") }
        let value = try team(id, store: store, workspace: workspace, task: owner ?? context)
        let taskID = try store.agents.createTask(value.leaderID, store: store, workspace: workspace, owner: owner, workMode: workMode, context: context)
        store.update(taskID) { $0.team = AgentTeamAssignment(team: value) }
        return taskID
    }
}
