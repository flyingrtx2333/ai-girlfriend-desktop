import Foundation
import BlueFatFishMCP

@MainActor enum AgentStandaloneRoleImport {
    static func profile(_ data: Data, source: AgentImportSource, file: URL, id: String,
                        workspace: String?, store: AgentStore) throws -> (AgentProfile, [String]) {
        var result: AgentProfile, warnings = ["导入后为停用状态", "使用本机确认方式"]
        switch source {
        case .qoder:
            guard let text = String(data: data, encoding: .utf8) else { throw PetError("智能体需要 UTF-8 Markdown") }
            let role = try AgentPlugins.agentDefinition(text, path: file.lastPathComponent, standalone: true)
            result = role.profile
            if !role.skills.isEmpty {
                let items = try store.extensions.catalog(workspace: workspace)
                result.skills = try role.skills.map { name in
                    let matches = items.filter { $0.kind == .skill && $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    guard matches.count == 1, let item = matches.first else { throw PetError("请先导入指定的 Skill：" + name) }
                    return item.id
                }
            }
            if !role.servers.isEmpty {
                let items = store.mcp.availableServers(workspace: workspace)
                result.mcpServers = try role.servers.map { name in
                    let matches = items.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    guard matches.count == 1, let item = matches.first else { throw PetError("请先导入指定的连接器：" + name) }
                    return item.id
                }
            }
        case .codex:
            let role: CodexAgentConfiguration
            do { role = try CodexAgentConfiguration.read(data) }
            catch { throw PetError("Codex 智能体需要有效的 name、description 和 developer_instructions") }
            let featureKeys: Set<String> = ["shell_tool", "apps", "plugins", "memories", "request_permissions_tool"]
            guard Set(role.features.keys).isSubset(of: featureKeys),
                  role.sandboxMode.map({ ["read-only", "workspace-write", "danger-full-access"].contains($0) }) != false else {
                throw PetError("来源包含无法保留的智能体权限设置")
            }
            let readOnly = role.sandboxMode == "read-only"
            var tools = ["list_directory", "read_file", "search_files", "list_agents", "delegate_task"]
            if !readOnly { tools += ["edit_file", "write_file"] }
            if role.features["shell_tool"] != false { tools.append("run_command") }
            result = AgentProfile(name: role.name, description: role.description, instructions: role.instructions,
                                  model: role.model ?? "", tools: tools, readOnly: readOnly)
            if !role.otherFields.isEmpty { warnings.append("在小鲸中核对模型参数与扩展") }
        }
        result.id = id
        result.enabled = false
        guard let checked = try store.agents.decode(store.agents.encode([result])).first else { throw PetError("智能体配置无效") }
        if !result.model.isEmpty { warnings.append("模型 · " + result.model) }
        if !(result.skills ?? []).isEmpty || !(result.mcpServers ?? []).isEmpty { warnings.append("使用前核对关联 Skills 和连接器") }
        return (checked, warnings)
    }

    static func install(_ value: AgentProfile, workspace: String?, store: AgentStore) throws {
        let (text, hash) = try store.agents.document(workspace: workspace)
        let prior = try store.agents.decode(text)
        if prior.contains(where: { $0.id == value.id }) { return }
        guard !prior.contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) else {
            throw PetError("同名智能体已存在，保留现有配置")
        }
        try store.agents.save(store.agents.encode(prior + [value]), expectedHash: hash, workspace: workspace)
    }
}
