import Foundation

enum AgentToolPermission: String, Codable, CaseIterable {
    case inherit, allow, ask, deny
    var title: String { self == .inherit ? "跟随默认审批" : self == .allow ? "允许" : self == .ask ? "每次确认" : "禁止" }
    static func tighter(_ a: Self?, _ b: Self?) -> Self {
        if a == .deny || b == .deny { return .deny }; if a == .ask || b == .ask { return .ask }; if a == .allow || b == .allow { return .allow }; return .inherit
    }
    static func intersection(_ snapshot: Self?, _ current: Self?) -> Self {
        if snapshot == .deny || current == .deny { return .deny }
        if snapshot == .ask || current == .ask { return .ask }
        return snapshot == .allow && current == .allow ? .allow : .inherit
    }
}
struct AgentMCPToolPermission: Codable, Equatable {
    var serverID: String
    var tool: String
    var permission: AgentToolPermission
}

struct AgentProfile: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var description: String
    var instructions: String
    var model = ""
    var permission = AgentPermissionMode.review
    var tools = ["list_directory", "read_file", "search_files"]
    var readOnly = true
    var network = false
    var enabled = false
    var skills: [String]?
    var mcpServers: [String]?
    var toolPermissions: [String: AgentToolPermission]?
    var mcpToolPermissions: [AgentMCPToolPermission]?
    var pluginSource: AgentPluginAgentReference?
    var availableTools: Set<String> {
        Set(tools).union((skills ?? []).isEmpty ? [] : AgentProfiles.skillTools).union((mcpServers ?? []).isEmpty ? [] : AgentMCP.tools)
    }
}

struct AgentProfileAssignment: Codable {
    var profile: AgentProfile
    var ownerID: String?
    var permissionCeiling = AgentPermissionMode.automatic
    var modeCeiling = AgentMode.agent
    var readOnlyCeiling: Bool?
    var networkCeiling: Bool?
    var toolCeiling: [String]?
    var workspace: String?
    var mcpCeiling: [String]?
    var toolPermissionCeiling: [String: AgentToolPermission]?
    var mcpPermissionCeiling: [AgentMCPToolPermission]?
    var teamCeiling: AgentTeam?
    var readOnly: Bool { profile.readOnly || readOnlyCeiling == true }
    var network: Bool { profile.network && networkCeiling != false }
    var tools: Set<String> { profile.availableTools.intersection((toolCeiling.map(Set.init) ?? profile.availableTools).union(AgentProfiles.skillTools)) }
    var skills: Set<String> { Set(profile.skills ?? []) }
    var mcpServers: Set<String> { Set(profile.mcpServers ?? []).intersection(mcpCeiling.map(Set.init) ?? Set(profile.mcpServers ?? [])) }
    var toolPermissions: [String: AgentToolPermission] {
        (profile.toolPermissions ?? [:]).merging(toolPermissionCeiling ?? [:]) { AgentToolPermission.tighter($0, $1) }
    }
    var mcpToolPermissions: [AgentMCPToolPermission] { (profile.mcpToolPermissions ?? []) + (mcpPermissionCeiling ?? []) }
}

@MainActor final class AgentProfiles {
    let directory: URL
    let plugins: AgentPlugins
    var onDisable: ((String) -> Void)?
    var onPluginChange: ((String) -> Void)?
    private struct Document: Codable { var agents: [AgentProfile] }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }()
    static let toolNames = Set(AgentTools.names).subtracting(["finish_task"])
    static let mutating: Set<String> = ["write_file", "edit_file", "write_memory", "edit_project_knowledge", "git_init", "git_commit", "git_create_worktree", "git_push", "git_recycle_worktree", "git_restore_worktree", "desktop_action", "office_create", "office_edit"]
    nonisolated static let skillTools: Set<String> = ["list_skills", "read_skill", "read_skill_resource", "unload_skill"]
    static let unsupported = Set<String>()
    init(profile: URL, plugins: AgentPlugins? = nil) {
        directory = profile; self.plugins = plugins ?? AgentPlugins(profile: profile)
        _ = self.plugins.observeChanges { [weak self] name in self?.onPluginChange?(name) }
    }
    private func file() throws -> URL { try AgentFiles(workspace: directory.path).resolve("extensions/agents.json") }
    func document() throws -> (String, String?) {
        let url = try file()
        guard FileManager.default.fileExists(atPath: url.path) else { return ("{\n  \"agents\": []\n}", nil) }
        let data = try AgentFiles(workspace: directory.path).readData(url, maximum: 512_000)
        guard let text = String(data: data, encoding: .utf8) else { throw PetError("Agent 配置不是 UTF-8") }
        _ = try decode(text)
        return (text, AgentFiles.hash(data))
    }
    func list(enabledOnly: Bool = false) throws -> [AgentProfile] {
        let values = try decode(document().0) + packagedProfiles()
        guard Set(values.map(\.id)).count == values.count else { throw PetError("Agent 编号重复") }
        return enabledOnly ? values.filter(\.enabled) : values
    }
    func profile(_ id: String) throws -> AgentProfile {
        guard let value = try list().first(where: { $0.id == id }), value.enabled else { throw PetError("此 Agent 未启用或已不存在") }
        return value
    }
    func decode(_ text: String, importing: Bool = false) throws -> [AgentProfile] {
        guard text.utf8.count <= 512_000,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], Set(object.keys) == ["agents"],
              let entries = object["agents"] as? [[String: Any]], entries.count <= 64 else { throw PetError("配置需要 agents 数组，最多 64 项、512KB") }
        let keys: Set<String> = ["id", "name", "description", "instructions", "model", "permission", "tools", "readOnly", "network", "enabled", "skills", "mcpServers", "toolPermissions", "mcpToolPermissions"]
        var values: [AgentProfile] = [], names = Set<String>(), ids = Set<String>()
        for entry in entries {
            guard Set(entry.keys).isSubset(of: keys), let name = entry["name"] as? String,
                  let description = entry["description"] as? String, let instructions = entry["instructions"] as? String else { throw PetError("Agent 需要 name、description、instructions；不支持的字段不能忽略") }
            let template = AgentProfile(name: name, description: description, instructions: instructions)
            var merged = try JSONSerialization.jsonObject(with: encoder.encode(template)) as! [String: Any]
            merged.merge(entry) { _, new in new }
            if importing { merged["id"] = UUID().uuidString; merged["enabled"] = false }
            let value = try JSONDecoder().decode(AgentProfile.self, from: JSONSerialization.data(withJSONObject: merged))
            guard UUID(uuidString: value.id) != nil, ids.insert(value.id).inserted,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60,
                  names.insert(name.lowercased()).inserted, description.count <= 500,
                  !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instructions.utf8.count <= 24_000,
                  value.model.count <= 200, value.tools.count <= 64,
                  Set(value.tools).count == value.tools.count, Set(value.tools).isSubset(of: Self.toolNames),
                  !value.tools.contains(where: AgentMCP.isModelToolName),
                  (value.skills ?? []).count <= 16, Set(value.skills ?? []).count == (value.skills ?? []).count,
                  (value.skills ?? []).allSatisfy({ $0.count == 24 && $0.allSatisfy(\.isHexDigit) }),
                  (value.mcpServers ?? []).count <= 16, Set(value.mcpServers ?? []).count == (value.mcpServers ?? []).count,
                  (value.mcpServers ?? []).allSatisfy({ UUID(uuidString: $0) != nil }),
                  (value.toolPermissions ?? [:]).count <= 64, Set(value.toolPermissions?.keys.map { $0 } ?? []).isSubset(of: Self.toolNames),
                  (value.mcpToolPermissions ?? []).count <= 128 else { throw PetError("Agent 名称重复、字段超限或工具范围无效") }
            var mcpKeys = Set<String>()
            if let rules = entry["mcpToolPermissions"] as? [[String: Any]], rules.contains(where: { Set($0.keys) != ["serverID", "tool", "permission"] }) { throw PetError("MCP 工具规则包含不支持的字段") }
            for rule in value.mcpToolPermissions ?? [] {
                guard (value.mcpServers ?? []).contains(rule.serverID), !rule.tool.isEmpty, rule.tool.utf8.count <= 128,
                      !rule.tool.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      mcpKeys.insert(rule.serverID + "\0" + rule.tool).inserted else { throw PetError("MCP 工具规则需要已选连接器与唯一的工具名") }
            }
            if !(value.mcpServers ?? []).isEmpty, value.readOnly || !value.network { throw PetError("使用 MCP 前，请关闭只读项目并允许外部连接。") }
            values.append(value)
        }
        return values
    }
    func encode(_ agents: [AgentProfile]) throws -> String { String(decoding: try encoder.encode(Document(agents: agents.filter { $0.pluginSource == nil })), as: UTF8.self) }
    func save(_ text: String, expectedHash: String?) throws {
        let values = try decode(text), previous = try document()
        guard previous.1 == expectedHash else { throw PetError("Agent 配置已改变，请重新读取后保存") }
        let old = try decode(previous.0), data = Data(try encode(values).utf8), url = try file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for item in old where item.enabled {
            let next = values.first { $0.id == item.id && $0.enabled }
            if next == nil || next?.tools != item.tools || next?.permission != item.permission || next?.readOnly != item.readOnly || next?.network != item.network || next?.skills != item.skills || next?.mcpServers != item.mcpServers || next?.toolPermissions != item.toolPermissions || next?.mcpToolPermissions != item.mcpToolPermissions { onDisable?(item.id) }
        }
    }
    func setEnabled(_ id: String, _ enabled: Bool) throws {
        let (text, hash) = try document(); var values = try decode(text)
        guard let index = values.firstIndex(where: { $0.id == id }) else { throw PetError("Agent 不存在") }
        values[index].enabled = enabled; try save(encode(values), expectedHash: hash)
    }
    static func tighter(_ a: AgentPermissionMode, _ b: AgentPermissionMode) -> AgentPermissionMode {
        let order: [AgentPermissionMode] = [.review, .workspace, .automatic]
        return order[min(order.firstIndex(of: a)!, order.firstIndex(of: b)!)]
    }
    static func definitions(_ values: [[String: Any]], task: AgentTaskRecord) -> [[String: Any]] {
        let scoped = values.filter { value in
            let name = (value["function"] as? [String: Any])?["name"] as? String ?? ""
            if task.inheritedLimits?.readOnly == true, mutating.contains(name) || AgentMCP.externalOperations.contains(name) || AgentMCP.isModelToolName(name) { return false }
            if task.inheritedLimits?.network == false, (["web_search", "fetch_url", "browser_open", "browser_action"] + AgentMCP.externalOperations + AgentGit.externalTools + AgentDesktop.externalTools).contains(name) || AgentMCP.isModelToolName(name) { return false }
            return true
        }
        guard let binding = task.agent else { return scoped }
        let common: Set<String> = ["load_tools", "update_plan", "ask_user", "read_task_history", "finish_task"]
        return scoped.filter { value in
            let name = (value["function"] as? [String: Any])?["name"] as? String ?? ""
            return (binding.tools.contains(name) || common.contains(name)) && binding.toolPermissions[name] != .deny && (!binding.readOnly || !mutating.contains(name))
        }
    }
    func ancestors(_ task: AgentTaskRecord, store: AgentStore?) throws -> [AgentTaskRecord] {
        guard let store else { return [] }
        var result: [AgentTaskRecord] = [], next = task.agent?.ownerID, seen = Set([task.id])
        while let id = next {
            guard seen.insert(id).inserted, result.count < 4, let owner = store.task(id), !owner.archived else { throw PetError("所属任务不可用，请重新发起委派") }
            result.append(owner); next = owner.agent?.ownerID
        }
        return result
    }
    func executionPermission(_ task: AgentTaskRecord, store: AgentStore) throws -> AgentPermissionMode {
        guard let binding = task.agent else { return Self.tighter(Self.tighter(task.permission, store.automations.permission(task)), task.inheritedLimits?.permission ?? .automatic) }
        var result = Self.tighter(task.permission, binding.permissionCeiling)
        for record in [task] + (try ancestors(task, store: store)) {
            result = Self.tighter(result, store.automations.permission(record))
            result = Self.tighter(result, record.permission)
            result = Self.tighter(result, record.inheritedLimits?.permission ?? .automatic)
            if let agent = record.agent { result = Self.tighter(result, try currentProfile(agent.profile).permission) }
        }
        return result
    }
    func canAutoApprove(_ task: AgentTaskRecord, store: AgentStore) throws -> Bool {
        guard let binding = task.agent, binding.permissionCeiling == .automatic, store.automations.permission(task) == .automatic, (task.inheritedLimits?.permission ?? .automatic) == .automatic else { return false }
        return try ancestors(task, store: store).allSatisfy { record in
            guard record.permission == .automatic, store.automations.permission(record) == .automatic, (record.inheritedLimits?.permission ?? .automatic) == .automatic else { return false }
            return try record.agent.map { try currentProfile($0.profile).permission == .automatic } ?? true
        }
    }
    func limits(_ task: AgentTaskRecord, store: AgentStore? = nil) throws -> (readOnly: Bool, network: Bool) {
        var readOnly = [.ask, .plan].contains(task.mode), network = true
        for record in [task] + (try ancestors(task, store: store)) {
            readOnly = readOnly || [.ask, .plan].contains(record.mode)
            readOnly = readOnly || record.inheritedLimits?.readOnly == true; network = network && (record.inheritedLimits?.network != false)
            let automation = store?.automations.limits(record) ?? (readOnly: record.automation?.readOnly == true, network: record.automation?.network ?? true)
            readOnly = readOnly || automation.readOnly; network = network && automation.network
            guard let binding = record.agent else { continue }
            let current = try currentProfile(binding.profile)
            readOnly = readOnly || binding.readOnly || current.readOnly || [.ask, .plan].contains(binding.modeCeiling)
            network = network && binding.network && current.network
        }
        return (readOnly, network)
    }
    func permission(_ call: AgentToolCall, task: AgentTaskRecord, store: AgentStore? = nil) throws -> AgentToolPermission {
        guard let binding = task.agent else { return .inherit }
        let current = try currentProfile(binding.profile)
        var rule = AgentToolPermission.intersection(binding.profile.toolPermissions?[call.name], current.toolPermissions?[call.name])
        if let ceiling = binding.toolPermissionCeiling?[call.name], [.ask, .deny].contains(ceiling) { rule = .tighter(rule, ceiling) }
        if call.name == "call_mcp_tool", let id = call.object["server_id"] as? String, let name = call.object["tool"] as? String {
            let snapshot = binding.profile.mcpToolPermissions?.first { $0.serverID == id && $0.tool == name }?.permission
            let live = current.mcpToolPermissions?.first { $0.serverID == id && $0.tool == name }?.permission
            rule = .tighter(rule, .intersection(snapshot, live))
            for value in binding.mcpPermissionCeiling ?? [] where value.serverID == id && value.tool == name && [.ask, .deny].contains(value.permission) { rule = .tighter(rule, value.permission) }
        }
        for owner in try ancestors(task, store: store) where owner.agent != nil {
            let parent = try permission(call, task: owner)
            if [.ask, .deny].contains(parent) { rule = .tighter(rule, parent) }
        }
        return rule
    }
    func checkSkill(_ id: String, task: AgentTaskRecord) throws {
        guard let binding = task.agent else { return }
        let current = try currentProfile(binding.profile)
        guard binding.skills.contains(id), (current.skills ?? []).contains(id) else { throw PetError("此 Skill 未分配给当前 Agent") }
    }
    func filterDefinitions(_ values: [[String: Any]], task: AgentTaskRecord, store: AgentStore) throws -> [[String: Any]] {
        let native = Self.definitions(values, task: task)
        guard task.agent != nil else { return native }
        var allowed = Set(native.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        for value in values {
            guard let name = (value["function"] as? [String: Any])?["name"] as? String, AgentMCP.isModelToolName(name),
                  let call = try? store.mcp.routedCall(AgentToolCall(id: "schema", name: name, arguments: "{}"), owner: task.id) else { continue }
            if (try? check(call, task: task, store: store)) != nil { allowed.insert(name) }
        }
        return try values.filter { value in
            guard let name = (value["function"] as? [String: Any])?["name"] as? String, allowed.contains(name) else { return false }
            return try AgentMCP.isModelToolName(name) || permission(AgentToolCall(id: "schema", name: name, arguments: "{}"), task: task, store: store) != .deny
        }
    }
    func check(_ call: AgentToolCall, task: AgentTaskRecord, store: AgentStore? = nil) throws {
        if let store { try store.sideTasks.requireCanRun(task) }
        guard task.pendingFileRollback == nil else { throw PetError("文件撤回尚未完成，请先在原消息中恢复") }
        if let store, let workspace = task.workspace, store.hasFileRollback(in: workspace) { throw PetError("此项目有未完成的文件撤回，请先恢复") }
        if let store { try store.teams.check(task, store: store) }
        if let store { for record in [task] + (try ancestors(task, store: store)) { try store.automations.check(call, task: task, owner: record) } }
        for record in [task] + (try ancestors(task, store: store)) {
            if record.inheritedLimits?.readOnly == true, Self.mutating.contains(call.name) || AgentMCP.externalOperations.contains(call.name) || AgentMCP.isModelToolName(call.name) || call.name == "browser_action" && ["click", "fill", "select"].contains(call.object["action"] as? String ?? "") { throw PetError("分支保留原任务的只读范围") }
            if record.inheritedLimits?.network == false, (["web_search", "fetch_url", "browser_open", "browser_action"] + AgentMCP.externalOperations + AgentGit.externalTools + AgentDesktop.externalTools).contains(call.name) || AgentMCP.isModelToolName(call.name) || call.name == "run_command" && call.object["network"] as? Bool == true { throw PetError("分支保留原任务禁止外部连接的范围") }
        }
        guard let binding = task.agent else { return }
        let current = try currentProfile(binding.profile)
        let limits = try limits(task, store: store)
        if binding.ownerID != nil, task.workspace != binding.workspace { throw PetError("委派任务不能切换项目范围") }
        let routed = AgentMCP.isModelToolName(call.name) ? "外部连接器" : call.name
        guard !AgentMCP.isModelToolName(call.name), (binding.tools.contains(call.name) && current.availableTools.contains(call.name)) || ["load_tools", "update_plan", "ask_user", "read_task_history", "finish_task"].contains(call.name) else { throw PetError("\(binding.profile.name) 不允许工具：\(routed)") }
        guard try permission(call, task: task, store: store) != .deny else { throw PetError("Agent 已禁止工具：" + (call.object["tool"] as? String ?? call.name)) }
        if Self.skillTools.contains(call.name), call.name != "list_skills" { try checkSkill(call.object["id"] as? String ?? "", task: task) }
        if AgentMCP.tools.contains(call.name), call.name != "list_mcp_servers" {
            guard let id = call.object["server_id"] as? String, binding.mcpServers.contains(id), (current.mcpServers ?? []).contains(id) else { throw PetError("此 MCP 未分配给当前 Agent") }
            if AgentMCP.externalOperations.contains(call.name), binding.readOnly || current.readOnly || !binding.network || !current.network { throw PetError("只读或禁止外部连接的 Agent 不能执行未隔离的 MCP") }
        }
        if [.ask, .plan].contains(binding.modeCeiling), Self.mutating.contains(call.name) { throw PetError("委派不能扩大主任务的只读模式") }
        if limits.readOnly {
            guard !Self.mutating.contains(call.name), call.name != "browser_action" || !["click", "fill", "select"].contains(call.object["action"] as? String ?? "") else { throw PetError("此 Agent 只读，不能修改项目或操作外部应用") }
        }
        if !limits.network, (["web_search", "fetch_url", "browser_open", "browser_action"] + AgentGit.externalTools + AgentDesktop.externalTools).contains(call.name) || (call.name == "run_command" && call.object["network"] as? Bool == true) { throw PetError("此 Agent 未允许联网或外部应用连接") }
        for owner in try ancestors(task, store: store) {
            guard owner.workspace == task.workspace else { throw PetError("所属任务项目范围已改变，请重新发起委派") }
            if [.ask, .plan].contains(owner.mode), Self.mutating.contains(call.name) || AgentMCP.externalOperations.contains(call.name) { throw PetError("所属任务当前为只读模式") }
            guard let parent = owner.agent else { continue }
            let live = try profile(parent.profile.id)
            if !Self.skillTools.contains(call.name), !["load_tools", "update_plan", "ask_user", "read_task_history", "finish_task"].contains(call.name), !live.availableTools.contains(call.name) { throw PetError("所属 Agent 已收紧工具范围") }
            if parent.readOnly || live.readOnly, Self.mutating.contains(call.name) || AgentMCP.externalOperations.contains(call.name) { throw PetError("所属 Agent 为只读项目") }
            if !parent.network || !live.network, (["web_search", "fetch_url", "browser_open", "browser_action"] + AgentMCP.externalOperations + AgentGit.externalTools + AgentDesktop.externalTools).contains(call.name) || (call.name == "run_command" && call.object["network"] as? Bool == true) { throw PetError("所属 Agent 禁止外部连接") }
            if AgentMCP.tools.contains(call.name), call.name != "list_mcp_servers", let id = call.object["server_id"] as? String, !(live.mcpServers ?? []).contains(id) { throw PetError("所属 Agent 已移除此 MCP") }
        }
    }
    func detachForFork(_ task: inout AgentTaskRecord, store: AgentStore) throws {
        let original = task, owners = try ancestors(original, store: store)
        guard !owners.isEmpty || original.automation != nil else { return }
        let scope = try limits(original, store: store), permission = try executionPermission(original, store: store)
        task.inheritedLimits = AgentInheritedLimits(readOnly: scope.readOnly, network: scope.network, permission: permission)
        if var binding = original.agent {
            var tools = binding.tools, servers = binding.mcpServers, rules = binding.toolPermissionCeiling ?? [:]
            var mcpRules = binding.mcpPermissionCeiling ?? []
            for record in [original] + owners {
                guard let role = record.agent else { continue }; let live = try currentProfile(role.profile)
                let common = Self.skillTools.union(["load_tools", "update_plan", "ask_user", "read_task_history", "finish_task"])
                tools = tools.intersection(role.tools.union(common)).intersection(live.availableTools.union(common))
                if record.id == original.id { binding.profile.skills = binding.skills.intersection(live.skills ?? []).sorted() }
                servers.formIntersection(role.mcpServers); servers.formIntersection(live.mcpServers ?? [])
                for rule in (role.profile.mcpToolPermissions ?? []) + (live.mcpToolPermissions ?? []) + (role.mcpPermissionCeiling ?? []) {
                    let call = AgentToolCall(id: "fork-scope", name: "call_mcp_tool", arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["server_id": rule.serverID, "tool": rule.tool]), as: UTF8.self))
                    let value = try self.permission(call, task: original, store: store)
                    if [.ask, .deny].contains(value) { mcpRules.removeAll { $0.serverID == rule.serverID && $0.tool == rule.tool }; mcpRules.append(AgentMCPToolPermission(serverID: rule.serverID, tool: rule.tool, permission: value)) }
                }
            }
            for name in AgentTools.names {
                let value = try self.permission(AgentToolCall(id: "fork-scope", name: name, arguments: "{}"), task: original, store: store)
                if [.ask, .deny].contains(value) { rules[name] = .tighter(rules[name], value) }
            }
            binding.permissionCeiling = Self.tighter(binding.permissionCeiling, permission); binding.readOnlyCeiling = scope.readOnly; binding.networkCeiling = scope.network
            binding.toolCeiling = tools.sorted(); binding.mcpCeiling = servers.sorted(); binding.toolPermissionCeiling = rules; binding.mcpPermissionCeiling = mcpRules
            binding.teamCeiling = try store.teams.binding(original, store: store); binding.ownerID = nil; task.agent = binding
        }
        task.automation = nil
    }
    @discardableResult func createTask(_ id: String, store: AgentStore, workspace: String?, owner: AgentTaskRecord? = nil, workMode: AgentWorkMode? = nil) throws -> String {
        let value = try profile(id)
        if let owner { try store.teams.checkDelegate(id, owner: owner, store: store) }
        let selection = store.selectedID
        let mode: AgentMode = owner.map { task in
            if task.mode == .ask || task.agent?.modeCeiling == .ask { return .ask }
            return task.mode == .plan || task.agent?.modeCeiling == .plan ? .plan : .agent
        } ?? .agent
        let ceiling = owner.map { Self.tighter($0.permission, $0.agent?.permissionCeiling ?? .automatic) } ?? .automatic
        for id in value.skills ?? [] { guard try store.extensions.item(id, workspace: workspace).kind == .skill else { throw PetError("Agent 选择的 Skill 不可用") } }
        for id in value.mcpServers ?? [] {
            _ = try store.mcp.server(id)
            if let parent = owner?.agent { guard parent.mcpServers.contains(id), !parent.readOnly, parent.network else { throw PetError("MCP 委派不能扩大所属 Agent 的连接或权限范围") } }
        }
        let taskID = store.create(title: "新的任务", workspace: workspace, mode: mode, workMode: owner?.organizationMode ?? workMode)
        store.update(taskID) {
            $0.agent = AgentProfileAssignment(profile: value, ownerID: owner?.id, permissionCeiling: ceiling, modeCeiling: mode, readOnlyCeiling: owner?.agent?.readOnly, networkCeiling: owner?.agent?.network, toolCeiling: owner?.agent.map { Array($0.tools) }, workspace: workspace)
            $0.agent?.mcpCeiling = owner?.agent.map { Array($0.mcpServers) }
            $0.agent?.toolPermissionCeiling = owner?.agent?.toolPermissions.filter { [.ask, .deny].contains($0.value) }
            $0.agent?.mcpPermissionCeiling = owner?.agent?.mcpToolPermissions.filter { [.ask, .deny].contains($0.permission) }
            $0.permission = Self.tighter(value.permission, ceiling); $0.parentID = owner?.id
            $0.model = value.model.isEmpty ? owner?.model ?? "" : value.model
            $0.toolGroups = AgentTools.groups.keys.filter { group in AgentTools.groups[group]?.contains(where: value.availableTools.contains) == true }.sorted()
        }
        do {
            for skill in value.skills ?? [] {
                let (reference, _) = try store.extensions.activate(skill, store: store, taskID: taskID, explicit: true)
                store.update(taskID) { $0.activateExtensions(AgentMessage(role: "tool", content: "", extensionReferences: [reference])) }
            }
        } catch {
            store.update(taskID) { $0.status = .failed; $0.events.append(AgentEvent(kind: "error", title: "Agent 初始化失败", detail: error.localizedDescription, status: "failed")) }
            if owner != nil { store.selectedID = selection }; throw error
        }
        if owner != nil { store.selectedID = selection }
        if let error = store.writeError { throw PetError("Agent 任务未保存：" + error) }
        return taskID
    }
    func configureDraft(_ id: String?, taskID: String, store: AgentStore) throws {
        guard let original = store.task(taskID), original.canChooseExecutor else { throw PetError("执行者只能在发送前选择") }
        let value = try id.map(profile)
        for skill in value?.skills ?? [] { guard try store.extensions.item(skill, workspace: original.workspace).kind == .skill else { throw PetError("Agent 选择的 Skill 不可用") } }
        for server in value?.mcpServers ?? [] { _ = try store.mcp.server(server) }
        store.update(taskID) { record in
            record.agent = value.map { AgentProfileAssignment(profile: $0, workspace: original.workspace) }
            record.team = nil; record.activeSkills = nil
            record.model = value?.model ?? ""; record.permission = value?.permission ?? .workspace
            record.mode = .agent; record.kind = nil
            record.toolGroups = value.map { profile in AgentTools.groups.keys.filter { AgentTools.groups[$0]?.contains(where: profile.availableTools.contains) == true }.sorted() }
        }
        do {
            for skill in value?.skills ?? [] {
                let (reference, _) = try store.extensions.activate(skill, store: store, taskID: taskID, explicit: true)
                store.update(taskID) { $0.activateExtensions(AgentMessage(role: "tool", content: "", extensionReferences: [reference])) }
            }
            if let error = store.writeError { throw PetError("执行者未保存：" + error) }
        } catch { store.update(taskID) { $0 = original }; throw error }
    }
    func refreshAutomationRole(_ taskID: String, executor: String, store: AgentStore) throws {
        guard let original = store.task(taskID), original.automation != nil, original.agent?.ownerID == nil, ![.running, .waiting].contains(original.status) else { throw PetError("自动化任务当前不能更新执行者") }
        let team = try executor.hasPrefix("team:") ? store.teams.team(String(executor.dropFirst(5)), store: store) : nil
        let value = try team.map { try profile($0.leaderID) } ?? (executor.hasPrefix("agent:") ? profile(String(executor.dropFirst(6))) : nil)
        for id in value?.skills ?? [] { guard try store.extensions.item(id, workspace: original.workspace).kind == .skill else { throw PetError("Agent 选择的 Skill 不可用") } }
        for id in value?.mcpServers ?? [] { _ = try store.mcp.server(id) }
        store.update(taskID) { task in
            task.agent = value.map { AgentProfileAssignment(profile: $0, workspace: task.workspace) }; task.team = team.map { AgentTeamAssignment(team: $0) }; task.activeSkills = nil
            if let value { task.model = value.model; task.toolGroups = AgentTools.groups.keys.filter { AgentTools.groups[$0]?.contains(where: value.availableTools.contains) == true }.sorted() }
        }
        do {
            for skill in value?.skills ?? [] { let (reference, _) = try store.extensions.activate(skill, store: store, taskID: taskID, explicit: true); store.update(taskID) { $0.activateExtensions(AgentMessage(role: "tool", content: "", extensionReferences: [reference])) } }
            if let error = store.writeError { throw PetError("执行者未保存：" + error) }
        } catch { store.update(taskID) { $0 = original }; throw error }
    }
}
