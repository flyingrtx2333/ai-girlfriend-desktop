import Foundation

struct AgentPluginMCPReference: Codable, Equatable {
    var name: String, installationID: String, key: String
}
struct AgentPluginMCPDefinition {
    var key: String, value: [String: Any]
    var destination: String { value["url"] as? String ?? ([value["command"] as? String ?? ""] + (value["args"] as? [String] ?? [])).map(AgentGit.quote).joined(separator: " ") }
    var fields: [String] { ["env", "headers"].flatMap { kind in (value[kind] as? [String: String] ?? [:]).keys.sorted().map { kind + "." + $0 } } }
}

extension AgentPluginInstallation {
    var instanceID: String {
        let original = receipt.installationID ?? AgentPlugins.mcpUUID(id + receipt.sourceHash + String(receipt.installedAt.timeIntervalSince1970))
        return workspace == nil ? original : AgentPlugins.mcpUUID(id + ":" + original)
    }
}

@MainActor extension AgentPlugins {
    nonisolated static func mcpUUID(_ text: String) -> String {
        let hash = Array(AgentFiles.hash(Data(text.utf8)).prefix(32))
        return [String(hash[0..<8]), String(hash[8..<12]), String(hash[12..<16]), String(hash[16..<20]), String(hash[20..<32])].joined(separator: "-").uppercased()
    }
    static func mcpDefinitions(_ manifest: [String: Any], paths: Set<String>, read: (String) throws -> Data) throws -> [AgentPluginMCPDefinition] {
        var maps: [[String: Any]] = []
        func load(_ raw: String) throws {
            let path = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            guard AgentArchive.validPath(path), path.hasSuffix(".json"), paths.contains(path) else { throw PetError("插件 MCP 配置路径无效或不存在：" + path) }
            let data = try read(path)
            guard data.count <= 65_536, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PetError("插件 MCP 配置需为64KB以内的 JSON 对象") }
            if let wrapped = json["mcpServers"] {
                guard json.count == 1, let map = wrapped as? [String: Any] else { throw PetError("MCP 配置的 mcpServers 必须是对象") }; maps.append(map)
            } else { maps.append(json) }
        }
        if let declared = manifest["mcpServers"], !(declared is NSNull) {
            if let path = declared as? String { try load(path) }
            else if let list = declared as? [String] { for path in list { try load(path) } }
            else if let map = declared as? [String: Any] { maps.append(map) }
            else { throw PetError("插件 mcpServers 须为对象、相对 JSON 路径或路径数组") }
        } else if paths.contains(".mcp.json") { try load(".mcp.json") }
        else if paths.contains("mcp.json") { try load("mcp.json") }
        var result: [AgentPluginMCPDefinition] = [], seen = Set<String>()
        for map in maps {
            for key in map.keys.sorted() {
                guard key.count <= 64, key.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil, seen.insert(key.lowercased()).inserted,
                      var value = map[key] as? [String: Any] else { throw PetError("插件 MCP 名称无效或重复：" + key) }
                let allowed: Set<String> = ["type", "command", "args", "env", "cwd", "url", "headers", "timeout", "description", "disabled"]
                guard Set(value.keys).isSubset(of: allowed) else { throw PetError("插件 MCP 尚未支持字段：" + Set(value.keys).subtracting(allowed).sorted().joined(separator: ", ")) }
                guard value["type"] == nil || value["type"] is String else { throw PetError("插件 MCP type 须为文字") }
                let rawType = value["type"] as? String ?? (value["url"] == nil ? "stdio" : "http"), type = rawType == "streamable-http" ? "http" : rawType
                guard ["stdio", "http"].contains(type) else { throw PetError("插件 MCP 目前支持 stdio 和 Streamable HTTP：" + key) }; value["type"] = type
                for field in ["description", "cwd"] where value[field] != nil { guard let text = value[field] as? String, text.utf8.count <= 4000, !text.contains("\0") else { throw PetError("插件 MCP 字段无效：" + field) } }
                if let disabled = value["disabled"] { guard CFGetTypeID(disabled as CFTypeRef) == CFBooleanGetTypeID() else { throw PetError("插件 MCP disabled 须为布尔值") } }
                if let raw = value["timeout"] { guard let timeout = raw as? Double, CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(), timeout.isFinite, (5000...600_000).contains(timeout) else { throw PetError("插件 MCP timeout 须为5000至600000毫秒") } }
                if type == "stdio" {
                    guard let command = value["command"] as? String, !command.isEmpty, command.utf8.count <= 4000, !command.contains("\0"),
                          value["url"] == nil, value["headers"] == nil else { throw PetError("插件本机 MCP 需要 command") }
                    let args = value["args"] ?? [String](), env = value["env"] ?? [String: String]()
                    guard let list = args as? [String], list.count <= 100, list.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4000 }),
                          let variables = env as? [String: String], variables.count <= 64,
                          variables.allSatisfy({ validEnvironmentKey($0.key) && !$0.value.contains("\0") && $0.value.utf8.count <= 16_000 }) else { throw PetError("插件 MCP args 或 env 无效") }
                    value["args"] = list; value["env"] = variables
                } else {
                    guard let address = value["url"] as? String, address.utf8.count <= 4000, !address.contains("\0"), value["command"] == nil, value["args"] == nil, value["env"] == nil, value["cwd"] == nil else { throw PetError("插件 HTTP MCP 需要 url") }
                    let rawHeaders = value["headers"] ?? [String: String]()
                    guard let headers = rawHeaders as? [String: String] else { throw PetError("插件 MCP headers 须为文字对象") }; try AgentMCP.validateHeaders(headers)
                    value["headers"] = headers
                }
                result.append(AgentPluginMCPDefinition(key: key, value: value))
            }
        }
        guard result.count <= 16 else { throw PetError("每个插件最多包含16个 MCP 连接器") }; return result
    }
    static func validEnvironmentKey(_ key: String) -> Bool {
        key.utf8.count <= 128 && key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && !key.hasPrefix("DYLD_") && !key.hasPrefix("LD_")
    }
    func mcpConfiguration(_ reference: AgentPluginMCPReference) throws -> [String: Any] {
        let item = try installation(reference.name)
        guard item.instanceID == reference.installationID, let definition = item.mcpServers.first(where: { $0.key == reference.key }) else { throw PetError("插件连接器已变化，请刷新") }
        let root = item.root.appendingPathComponent("payload").path
        func expand(_ text: String, credential: Bool = false) -> String {
            var text = text
            for token in ["${QODER_PLUGIN_ROOT}", "${CLAUDE_PLUGIN_ROOT}", "${PLUGIN_ROOT}"] { text = text.replacingOccurrences(of: token, with: root) }
            return credential && text.contains("${") ? "" : text
        }
        var value = definition.value
        value["name"] = item.metadata.name + ":" + definition.key; value["timeoutSeconds"] = (value.removeValue(forKey: "timeout") as? Double ?? 60_000) / 1000
        value.removeValue(forKey: "description"); value.removeValue(forKey: "disabled")
        for field in ["command", "url", "cwd"] { if let text = value[field] as? String { value[field] = expand(text) } }
        if let command = value["command"] as? String, !command.hasPrefix("/"), !command.contains("/") {
            value["command"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map { $0 + "/" + command }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? command
        }
        if let args = value["args"] as? [String] { value["args"] = args.map { expand($0) } }
        for field in ["env", "headers"] { if let variables = value[field] as? [String: String] { value[field] = variables.mapValues { expand($0, credential: true) } } }
        return value
    }
    func mcpServers(saved: [AgentMCPServer], workspace: String? = nil, onlyScope: Bool = false) throws -> [AgentMCPServer] {
        var result = saved.filter { $0.plugin == nil }
        for item in try catalog(workspace: workspace, onlyScope: onlyScope) {
            for definition in item.mcpServers {
                let reference = AgentPluginMCPReference(name: item.id, installationID: item.instanceID, key: definition.key), id = Self.mcpUUID(item.instanceID + ":" + definition.key)
                let existing = saved.first { $0.id == id && $0.plugin == reference }
                var server = existing ?? AgentMCPServer(name: item.metadata.name + ":" + definition.key, type: definition.value["type"] as? String ?? "stdio")
                if existing == nil {
                    let value = try mcpConfiguration(reference)
                    server.command = value["command"] as? String; server.args = value["args"] as? [String] ?? []; server.url = value["url"] as? String; server.workingDirectory = value["cwd"] as? String
                    server.environmentKeys = (value["env"] as? [String: String] ?? [:]).keys.sorted(); server.headerKeys = (value["headers"] as? [String: String] ?? [:]).keys.sorted(); server.timeoutSeconds = value["timeoutSeconds"] as? Double ?? 60
                }
                server.id = id; server.plugin = reference; server.configured = existing != nil; server.pluginEnabled = item.enabled
                server.credentialRevision = existing?.revision
                server.revision = Self.mcpUUID((existing?.revision ?? "unconfigured") + item.activationID + item.receipt.sourceHash)
                server.enabled = item.enabled && existing?.enabled == true
                result.append(server)
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func validateMCP(_ reference: AgentPluginMCPReference, workspace: String? = nil) throws {
        let item = try requireScope(reference.name, workspace: workspace)
        guard item.instanceID == reference.installationID, item.enabled, item.mcpServers.contains(where: { $0.key == reference.key }) else { throw PetError("所属插件已停用、移除或更新") }
        for path in item.receipt.hashes.keys { _ = try content(path, installation: item) }
    }
}
