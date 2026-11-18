import Foundation
import CoreFoundation

@MainActor enum AgentImportedPlugin {
    static let manifests = [".qoder-plugin/plugin.json", ".claude-plugin/plugin.json", ".codex-plugin/plugin.json", "plugin.json"]
    static let hiddenRoots: Set<String> = [".qoder-plugin", ".claude-plugin", ".codex-plugin", ".mcp.json", ".app.json"]
    private static let targetManifest = ".qoder-plugin/plugin.json"

    static func normalize(_ supplied: [String: Data], inferredName: String?) throws -> [String: Data] {
        var files = supplied
        let legacy = try manifests.dropLast().compactMap { name in try files[name].map { try object($0) } }
        let codex = files[".codex-plugin/plugin.json"] != nil
        let native = files[targetManifest] != nil || files[".claude-plugin/plugin.json"] != nil
        let schema = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
        let portable = try files["plugin.json"].map { bytes -> [String: Any]? in
            if native { return (try? object(bytes)).flatMap { ($0["$schema"] as? String) == schema ? $0 : nil } }
            return try object(bytes)
        } ?? nil
        var manifest: [String: Any]
        if let portable {
            guard portable["$schema"] == nil || portable["$schema"] as? String == schema else {
                throw PetError("暂不支持此 Agent Plugins 清单版本")
            }
            guard !native else { throw PetError("同时存在不同格式的主清单，请选择独立插件包") }
            manifest = try portableManifest(portable, fallback: legacy.first)
            if files["mcp.json"] == nil { manifest["mcpServers"] = [String: Any]() }
            else { manifest["mcpServers"] = "mcp.json" }
            files.removeValue(forKey: ".mcp.json")
        } else if let first = legacy.first {
            guard legacy.dropFirst().allSatisfy({ NSDictionary(dictionary: $0) == NSDictionary(dictionary: first) }) else {
                throw PetError("插件的多份清单内容不一致")
            }
            manifest = first
        } else {
            guard let inferredName, AgentPlugins.validName(inferredName) else { throw PetError("缺少插件清单或有效的目录名称") }
            manifest = ["name": inferredName]
        }

        if let appearance = manifest.removeValue(forKey: "interface") as? [String: Any] {
            if manifest["displayName"] == nil { manifest["displayName"] = appearance["displayName"] }
            if manifest["author"] == nil { manifest["author"] = appearance["developerName"] }
        }
        if let apps = manifest.removeValue(forKey: "apps") ?? (files[".app.json"] == nil ? nil : "./.app.json"), !(apps is NSNull) {
            let mappings: [String: Any]
            if let path = apps as? String { mappings = try object(resource(path, files: files)) }
            else if let value = apps as? [String: Any] { mappings = value }
            else { throw PetError("插件 App 配置格式无效") }
            guard mappings.isEmpty || Set(mappings.keys) == ["apps"] && (mappings["apps"] as? [String: Any])?.isEmpty == true else {
                throw PetError("插件依赖来源应用注册的连接器")
            }
        }
        files.removeValue(forKey: ".app.json")
        if codex || portable != nil {
            for key in ["app", "dependencies", "sdk", "permissions"] where manifest[key] != nil {
                if let empty = manifest[key] as? [String: Any], empty.isEmpty { continue }
                if let empty = manifest[key] as? [Any], empty.isEmpty { continue }
                guard manifest[key] is NSNull else { throw PetError("待支持的插件声明：" + key) }
            }
            try expandSkillDirectories(&manifest, files: files)
        }
        // Onboarding remains available as a Skill after the user enables the package.
        manifest.removeValue(forKey: "onboardingSkill")
        try rewrite("mcpServers", defaultPaths: [".mcp.json", "mcp.json"], manifest: &manifest, files: &files, transform: cleanMCP)
        try rewrite("hooks", defaultPaths: ["hooks/hooks.json"], manifest: &manifest, files: &files, transform: cleanHooks)

        for key in [".claude-plugin/plugin.json", ".codex-plugin/plugin.json"] { files.removeValue(forKey: key) }
        if portable != nil { files.removeValue(forKey: "plugin.json") }
        files[targetManifest] = try encode(manifest)
        return files
    }

    private static func portableManifest(_ value: [String: Any], fallback: [String: Any]?) throws -> [String: Any] {
        let extensions = value["extensions"] as? [String: Any] ?? [:]
        guard value["extensions"] == nil || value["extensions"] is [String: Any], Set(extensions.keys).isSubset(of: ["com.openai"]),
              extensions["com.openai"] == nil || extensions["com.openai"] is [String: Any] else {
            throw PetError("插件包含其他平台专属扩展")
        }
        let overlay = extensions["com.openai"] as? [String: Any] ?? fallback ?? [:]
        let portableKeys: Set<String> = ["name", "version", "description", "author", "homepage", "repository", "license", "keywords"]
        let runtimeKeys: Set<String> = ["hooks", "apps", "onboardingSkill", "interface", "permissions", "sdk", "dependencies"]
        var result = value.filter { portableKeys.contains($0.key) }
        for key in runtimeKeys { result[key] = overlay[key] }
        return result
    }

    private static func expandSkillDirectories(_ manifest: inout [String: Any], files: [String: Data]) throws {
        let raw = manifest["skills"]
        let paths: [String]
        if raw == nil { paths = ["skills"] }
        else if let path = raw as? String { paths = [path] }
        else if let list = raw as? [String] { paths = list }
        else { throw PetError("插件 skills 需要相对路径或路径数组") }
        var roots = Set<String>()
        for input in paths {
            let folder = try relative(input)
            let matches = files.keys.filter { $0.hasPrefix(folder + "/") && $0.hasSuffix("/SKILL.md") }.sorted()
            if raw != nil && matches.isEmpty { throw PetError("插件声明的 Skill 路径没有组件：" + folder) }
            for path in matches {
                let directory = String(path.dropLast("/SKILL.md".count))
                let parts = directory.split(separator: "/")
                let insideSkill = (folder.split(separator: "/").count..<parts.count).contains { depth in
                    files[parts.prefix(depth).joined(separator: "/") + "/SKILL.md"] != nil
                }
                if !insideSkill { roots.insert(directory) }
            }
        }
        manifest["skills"] = roots.sorted()
    }

    private static func rewrite(_ field: String, defaultPaths: [String], manifest: inout [String: Any], files: inout [String: Data],
                                transform: ([String: Any]) throws -> [String: Any]) throws {
        let paths: [String]
        if let inline = manifest[field] as? [String: Any] {
            manifest[field] = try transform(inline)
            paths = []
        } else if manifest[field] == nil || manifest[field] is NSNull {
            paths = Array(defaultPaths.filter { files[$0] != nil }.prefix(1))
        } else if let path = manifest[field] as? String { paths = [path] }
        else if let list = manifest[field] as? [String] { paths = list }
        else { throw PetError("插件 \(field) 声明格式无效") }
        let included = try Set(paths.map(relative))
        for path in included.union(defaultPaths.filter { files[$0] != nil }).sorted() {
            files[path] = try encode(transform(object(resource(path, files: files))))
        }
    }

    private static func cleanMCP(_ json: [String: Any]) throws -> [String: Any] {
        let map: [String: Any]
        if let raw = json["mcpServers"] {
            guard Set(json.keys).isSubset(of: ["$schema", "mcpServers"]), let values = raw as? [String: Any] else { throw PetError("插件 MCP 配置格式无效") }
            map = values
        } else { map = json }
        var result: [String: Any] = [:]
        for (name, entry) in map {
            guard var item = entry as? [String: Any] else { throw PetError("插件 MCP 配置需要对象") }
            if let raw = item.removeValue(forKey: "extensions") {
                guard let vendors = raw as? [String: Any], Set(vendors.keys).isSubset(of: ["com.openai"]),
                      let config = vendors["com.openai"] as? [String: Any], Set(config.keys).isSubset(of: ["auth"]),
                      let auth = config["auth"] as? [String: Any], auth["type"] as? String == "none" else {
                    throw PetError("插件 MCP 依赖来源应用的认证方式")
                }
            }
            var env = try stringValues(item, field: "env"), headers = try stringValues(item, field: "headers")
            headers.merge(try stringValues(item, field: "http_headers")) { current, _ in current }
            headers.merge(try stringValues(item, field: "env_http_headers")) { current, _ in current }
            if let raw = item.removeValue(forKey: "env_vars") {
                guard let names = raw as? [String] else { throw PetError("插件 MCP 环境变量名称格式无效") }
                for name in names { env[name] = "" }
            }
            let bearer = try ["bearerToken", "bearer_token_env_var"].map { field -> String in
                guard let raw = item.removeValue(forKey: field) else { return "" }
                guard let value = raw as? String else { throw PetError("插件 MCP Token 声明无效") }
                return value
            }.contains { !$0.isEmpty }
            if bearer {
                guard !headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) else {
                    throw PetError("插件 MCP 的两种认证声明冲突")
                }
                headers["Authorization"] = ""
            }
            item.removeValue(forKey: "http_headers"); item.removeValue(forKey: "env_http_headers")
            if item["env"] != nil || !env.isEmpty { item["env"] = env.mapValues { _ in AgentMCP.importPlaceholder } }
            if item["headers"] != nil || !headers.isEmpty { item["headers"] = headers.mapValues { _ in AgentMCP.importPlaceholder } }
            if let url = item["url"] as? String { item["url"] = try AgentMCPDataImport.configuredAddress(url) }
            if let command = item["command"] as? String, let args = item["args"] as? [String] {
                item["args"] = AgentMCPDataImport.scrubArguments(args, command: command)
            }
            if let raw = item.removeValue(forKey: "enabled") {
                guard CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID(), item["disabled"] == nil else { throw PetError("插件 MCP 启用字段无效") }
                item["disabled"] = !(raw as! Bool)
            }
            let timeFields = ["timeoutSeconds", "startup_timeout_sec", "tool_timeout_sec"]
            let timeouts = try timeFields.compactMap { key -> Double? in
                guard let raw = item.removeValue(forKey: key) else { return nil }
                guard let seconds = raw as? Double, seconds.isFinite, CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID() else {
                    throw PetError("插件 MCP 超时字段无效")
                }
                return seconds * 1000
            }
            if let duration = timeouts.first {
                guard item["timeout"] == nil, timeouts.allSatisfy({ $0 == duration }) else { throw PetError("插件 MCP 声明了不同的连接与调用超时") }
                item["timeout"] = duration
            }
            result[name] = item
        }
        return json["mcpServers"] == nil ? result : ["mcpServers": result]
    }

    static func cleanHooks(_ input: [String: Any]) throws -> [String: Any] {
        var object = input
        let wrapped = input["hooks"] != nil
        guard let raw = (wrapped ? input["hooks"] : input) as? [String: [[String: Any]]] else { throw PetError("插件 Hooks 需要事件与分组") }
        var events = raw
        for (event, groups) in raw {
            events[event] = try groups.map { group in
                var group = group
                guard let values = group["hooks"] as? [[String: Any]] else { throw PetError("插件 Hook 分组缺少处理器") }
                group["hooks"] = try values.map { handler in
                    var handler = handler
                    for field in ["env", "headers"] where handler[field] != nil {
                        handler[field] = try stringValues(handler, field: field).mapValues { _ in AgentHookCredentials.placeholder }
                    }
                    if let url = handler["url"] as? String, let parts = URLComponents(string: url),
                       parts.user != nil || parts.password != nil || parts.percentEncodedQuery != nil || parts.fragment != nil {
                        throw PetError("插件 Hook 地址包含嵌入参数，请先把认证迁到 Header")
                    }
                    if let command = handler["command"] as? String, let args = handler["args"] as? [String],
                       AgentMCPDataImport.scrubArguments(args, command: command) != args {
                        throw PetError("插件 Hook 参数含待填写的凭据，请先迁到 env")
                    }
                    return handler
                }
                return group
            }
        }
        if !wrapped { return events }
        object["hooks"] = events
        return object
    }

    private static func stringValues(_ item: [String: Any], field: String) throws -> [String: String] {
        guard let raw = item[field] else { return [:] }
        guard let keys = raw as? [String: String] else { throw PetError("插件字段 \(field) 需要字符串对象") }
        return keys
    }
    private static func relative(_ input: String) throws -> String {
        var value = input.hasPrefix("./") ? String(input.dropFirst(2)) : input
        while value.hasSuffix("/") { value.removeLast() }
        guard AgentArchive.validPath(value) else { throw PetError("插件资源路径无效") }
        return value
    }
    private static func resource(_ path: String, files: [String: Data]) throws -> Data {
        guard let data = try files[relative(path)] else { throw PetError("缺少声明的插件资源") }
        return data
    }
    private static func object(_ bytes: Data) throws -> [String: Any] { try AgentConfigurationJSON.object(bytes) }
    private static func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
