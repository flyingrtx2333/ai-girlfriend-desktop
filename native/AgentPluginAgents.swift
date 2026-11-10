import Foundation

struct AgentPluginAgentReference: Codable, Equatable {
    var name: String, installationID: String, activationID: String, key: String, sha256: String
}

struct AgentPluginAgentDefinition {
    var key: String, path: String, profile: AgentProfile, skills: [String], servers: [String]
    var summary: String { profile.description + "\n" + profile.permission.title + (profile.readOnly ? " · 只读项目" : " · 可修改项目") + (profile.network ? " · 允许联网" : "") + "\n" + profile.tools.joined(separator: ", ") }
}

@MainActor extension AgentPlugins {
    static func validateAgentReferences(_ agents: [AgentPluginAgentDefinition], name: String, components: [AgentPluginComponent], servers: [AgentPluginMCPDefinition]) throws {
        func key(_ value: String) -> String { value.hasPrefix(name + ":") ? String(value.dropFirst(name.count + 1)) : value }
        for agent in agents {
            for skill in agent.skills where !components.contains(where: { $0.kind == .skill && $0.name == key(skill) }) { throw PetError("插件 Agent 引用的 Skill 不存在：" + skill) }
            for server in agent.servers where !servers.contains(where: { $0.key == key(server) }) { throw PetError("插件 Agent 引用的 MCP 不存在：" + server) }
        }
    }
    static func agentDefinitions(_ manifest: [String: Any], paths: Set<String>, read: (String) throws -> Data) throws -> [AgentPluginAgentDefinition] {
        let bases: [String]
        if let raw = manifest["agents"], !(raw is NSNull) {
            if let path = raw as? String { bases = [path] }
            else if let list = raw as? [String] { bases = list }
            else { throw PetError("插件 agents 需要相对路径或路径数组") }
        } else { bases = ["agents"] }
        var result: [AgentPluginAgentDefinition] = [], names = Set<String>(), selected = Set<String>()
        for raw in bases {
            var base = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            while base.hasSuffix("/") { base.removeLast() }
            guard AgentArchive.validPath(base), !base.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { throw PetError("插件 Agent 路径无效") }
            let matches = paths.contains(base) && base.hasSuffix(".md") ? [base] : paths.filter { $0.hasPrefix(base + "/") && $0.hasSuffix(".md") }.sorted()
            if manifest["agents"] != nil && matches.isEmpty { throw PetError("插件声明的 Agent 路径没有组件：" + base) }
            for path in matches {
                guard selected.insert(path).inserted else { throw PetError("插件 Agent 路径重复：" + path) }
                let data = try read(path)
                guard let text = String(data: data, encoding: .utf8) else { throw PetError("插件 Agent 需要 UTF-8 Markdown") }
                let value = try agentDefinition(text, path: path)
                guard names.insert(value.key.lowercased()).inserted else { throw PetError("插件 Agent 名称重复：" + value.key) }
                result.append(value)
            }
        }
        guard result.count <= 64 else { throw PetError("每个插件最多64项 Agent") }; return result
    }
    private static func agentDefinition(_ text: String, path: String) throws -> AgentPluginAgentDefinition {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n"), lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"), end < 200 else { throw PetError("插件 Agent 需要闭合的 frontmatter：" + path) }
        let document = try AgentExtensionDocument(normalized)
        let listKeys: Set<String> = ["tools", "disallowedTools", "skills", "mcpServers"]
        let allowed = listKeys.union(["name", "description", "model", "permissionMode", "readOnly", "network", "color"])
        var seen = Set<String>(), lists: [String: [String]] = [:], current = "", multiline = false
        func scalar(_ raw: String) throws -> String {
            var value = raw.trimmingCharacters(in: .whitespaces)
            if let first = value.first, first == "\"" || first == "'" {
                guard value.count >= 2, value.last == first else { throw PetError("插件 Agent 字段引号未闭合") }; value = String(value.dropFirst().dropLast())
            }
            guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PetError("插件 Agent 字段包含控制字符") }; return value
        }
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if listKeys.contains(current), trimmed.hasPrefix("- ") { lists[current, default: []].append(try scalar(String(trimmed.dropFirst(2)))); continue }
                guard multiline else { throw PetError("插件 Agent 字段格式不支持：" + path) }; continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw PetError("插件 Agent 字段格式无效：" + path) }
            current = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard allowed.contains(current), seen.insert(current).inserted else { throw PetError("插件 Agent 字段尚未支持或重复：" + current) }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            multiline = ["|", ">", "|-", ">-"].contains(value)
            if listKeys.contains(current) {
                if value.hasPrefix("[") { guard value.hasSuffix("]") else { throw PetError("插件 Agent 数组未闭合") }; value = String(value.dropFirst().dropLast()) }
                lists[current] = try value.isEmpty ? [] : value.split(separator: ",", omittingEmptySubsequences: false).map { try scalar(String($0)) }
            }
        }
        let fields = document.metadata, key = fields["name"] ?? "", description = fields["description"] ?? ""
        guard !key.isEmpty, key.count <= 64, AgentExtensions.validName(key), !key.contains(":"), !description.isEmpty, description.count <= 500, document.body.utf8.count <= 24_000 else { throw PetError("插件 Agent 需要有效的 name、description 和指令正文") }
        let aliases: [String: [String]] = ["Read": ["read_file"], "Grep": ["search_files"], "Glob": ["list_directory"], "Bash": ["run_command"], "Write": ["write_file"], "Edit": ["edit_file"], "WebFetch": ["fetch_url"], "WebSearch": ["web_search"], "Agent": ["list_agents", "delegate_task"]]
        func tools(_ names: [String]) throws -> Set<String> {
            var result = Set<String>()
            for name in names {
                if let mapped = aliases[name] { result.formUnion(mapped) }
                else if AgentProfiles.toolNames.contains(name) { result.insert(name) }
                else { throw PetError("插件 Agent 尚未支持工具：" + name) }
            }; return result
        }
        let denied = try tools(lists["disallowedTools"] ?? []), selected = try lists["tools"].map(tools) ?? AgentProfiles.toolNames
        let permissions: [String: AgentPermissionMode] = ["default": .review, "acceptEdits": .workspace, "bypassPermissions": .automatic]
        guard let permission = permissions[fields["permissionMode"] ?? "default"] else { throw PetError("插件 Agent permissionMode 尚未支持") }
        func boolean(_ key: String, fallback: Bool) throws -> Bool {
            guard let value = fields[key] else { return fallback }
            guard ["true", "false"].contains(value) else { throw PetError("插件 Agent \(key) 需要 true 或 false") }; return value == "true"
        }
        let skillNames = lists["skills"] ?? [], servers = lists["mcpServers"] ?? [], available = selected.subtracting(denied)
        guard skillNames.count <= 16, Set(skillNames).count == skillNames.count, servers.count <= 16, Set(servers).count == servers.count else { throw PetError("插件 Agent 的 Skills 或 MCP 超限或重复") }
        let external = available.intersection(Set(["run_command", "web_search", "fetch_url", "browser_open", "browser_action"]).union(AgentMCP.tools))
        let readOnly = try boolean("readOnly", fallback: available.isDisjoint(with: AgentProfiles.mutating) && servers.isEmpty)
        let network = try boolean("network", fallback: !external.isEmpty || !servers.isEmpty)
        guard servers.isEmpty || !readOnly && network else { throw PetError("插件 Agent 使用 MCP 需要允许外部连接并关闭只读项目") }
        let model = fields["model"] == "inherit" ? "" : fields["model"] ?? ""
        guard model.count <= 200, !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PetError("插件 Agent 模型无效") }
        let profile = AgentProfile(name: key, description: description, instructions: document.body, model: model, permission: permission, tools: available.sorted(), readOnly: readOnly, network: network, toolPermissions: denied.isEmpty ? nil : Dictionary(uniqueKeysWithValues: denied.map { ($0, .deny) }))
        return AgentPluginAgentDefinition(key: key, path: path, profile: profile, skills: skillNames, servers: servers)
    }
    func agentProfiles() throws -> [AgentProfile] {
        var result: [AgentProfile] = []
        for item in try catalog() {
            for definition in item.agents {
                var profile = definition.profile
                profile.id = Self.mcpUUID("agent:" + item.instanceID + ":" + definition.key)
                profile.name = item.id + ":" + definition.key; profile.enabled = item.receipt.enabled
                profile.pluginSource = AgentPluginAgentReference(name: item.id, installationID: item.instanceID, activationID: item.receipt.activationID ?? item.receiptHash, key: definition.key, sha256: item.receipt.hashes[definition.path]!)
                profile.skills = try definition.skills.map { name in
                    let key = name.hasPrefix(item.id + ":") ? String(name.dropFirst(item.id.count + 1)) : name
                    guard let skill = item.receipt.components.first(where: { $0.kind == .skill && $0.name == key }) else { throw PetError("插件 Agent 引用的 Skill 不存在：" + name) }
                    return Self.extensionID(skill.path, installation: item)
                }
                profile.mcpServers = try definition.servers.map { name in
                    let key = name.hasPrefix(item.id + ":") ? String(name.dropFirst(item.id.count + 1)) : name
                    guard item.mcpServers.contains(where: { $0.key == key }) else { throw PetError("插件 Agent 引用的 MCP 不存在：" + name) }
                    return Self.mcpUUID(item.instanceID + ":" + key)
                }
                result.append(profile)
            }
        }; return result
    }
    func validateAgent(_ reference: AgentPluginAgentReference) throws {
        let item = try installation(reference.name)
        guard item.receipt.enabled, item.instanceID == reference.installationID, (item.receipt.activationID ?? item.receiptHash) == reference.activationID, item.agents.contains(where: { $0.key == reference.key && item.receipt.hashes[$0.path] == reference.sha256 }) else { throw PetError("所属插件已停用、移除或更新，请重新选择 Agent") }
        for path in item.receipt.hashes.keys { _ = try content(path, installation: item) }
    }
}

@MainActor extension AgentProfiles {
    func currentProfile(_ snapshot: AgentProfile) throws -> AgentProfile {
        let current = try profile(snapshot.id)
        guard current.pluginSource == snapshot.pluginSource else { throw PetError("插件 Agent 已变化，请重新选择执行者") }
        if let source = snapshot.pluginSource { try plugins.validateAgent(source) }; return current
    }
    private func pluginModels() throws -> ([String: String], String?) {
        let files = try AgentFiles(workspace: directory.path), url = try files.literalURL("extensions/plugin-agent-models.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        let data = try files.readData(url, maximum: 65_536), values = try JSONDecoder().decode([String: String].self, from: data)
        guard values.count <= 128, values.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.count <= 200 && !$0.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw PetError("插件 Agent 模型设置无效") }; return (values, AgentFiles.hash(data))
    }
    func packagedProfiles() throws -> [AgentProfile] {
        let models = try pluginModels().0
        return try plugins.agentProfiles().map { var profile = $0; if let model = models[profile.id] { profile.model = model }; return profile }
    }
    func pluginModelVersion() throws -> String? { try pluginModels().1 }
    func savePluginModel(_ snapshot: AgentProfile, model: String, expectedHash: String?) throws {
        guard let live = try packagedProfiles().first(where: { $0.id == snapshot.id }), live.pluginSource == snapshot.pluginSource, model.count <= 200, !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PetError("插件 Agent 或模型已变化，请刷新") }
        var (values, hash) = try pluginModels(); guard hash == expectedHash else { throw PetError("插件 Agent 模型设置已变化，请重新读取") }
        values[snapshot.id] = model
        guard values.count <= 128 else { throw PetError("插件 Agent 模型设置最多128项") }
        let files = try AgentFiles(workspace: directory.path); try files.writeData(JSONEncoder().encode(values), to: files.literalURL("extensions/plugin-agent-models.json"), permissions: 0o600)
    }
}
