import Foundation

struct AgentPluginHookReference: Codable, Equatable {
    var name: String, installationID: String, key: String
}
struct AgentPluginHookDefinition {
    var key: String, data: Data, preview: [AgentHookDefinition]
}

@MainActor extension AgentPlugins {
    static let hookRootVariables = ["QODER_PLUGIN_ROOT", "CLAUDE_PLUGIN_ROOT", "PLUGIN_ROOT"]
    static func hookDefinitions(_ manifest: [String: Any], paths: Set<String>, read: (String) throws -> Data) throws -> [AgentPluginHookDefinition] {
        var inputs: [(String, Any)] = []
        func load(_ raw: String) throws {
            let path = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            guard AgentArchive.validPath(path), path.hasSuffix(".json"), paths.contains(path) else { throw PetError("插件 Hooks 路径无效或不存在：" + path) }
            let data = try read(path); guard data.count <= 128_000 else { throw PetError("插件 Hooks 配置超过128KB") }
            inputs.append((path, try JSONSerialization.jsonObject(with: data)))
        }
        if let declared = manifest["hooks"], !(declared is NSNull) {
            if let path = declared as? String { try load(path) }
            else if let paths = declared as? [String] { for path in paths { try load(path) } }
            else if let value = declared as? [String: Any] { inputs.append(("manifest", value)) }
            else { throw PetError("插件 hooks 需要对象、相对JSON路径或路径数组") }
        } else if paths.contains("hooks/hooks.json") { try load("hooks/hooks.json") }
        if inputs.isEmpty, paths.contains(where: { $0.hasPrefix("hooks/") }) { throw PetError("插件 hooks 目录缺少 hooks.json 或声明路径") }
        var result: [AgentPluginHookDefinition] = [], seen = Set<String>()
        let inspector = AgentHooks(profile: FileManager.default.temporaryDirectory.appendingPathComponent(".plugin-hook-preview-" + UUID().uuidString), sharedHome: nil)
        for (key, raw) in inputs {
            guard seen.insert(key).inserted, let object = raw as? [String: Any] else { throw PetError("插件 Hooks 配置重复或不是对象") }
            let wrapped = object["hooks"] == nil ? ["hooks": object] : object
            guard Set(wrapped.keys).isSubset(of: ["hooks", "description"]), wrapped["description"] == nil || wrapped["description"] is String else { throw PetError("插件 Hooks 配置含尚未支持的字段") }
            try validateHookFields(wrapped)
            let data = try JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys, .withoutEscapingSlashes])
            guard data.count <= 128_000 else { throw PetError("插件 Hooks 配置超过128KB") }
            let preview = try inspector.parse(data, file: inspector.profile.appendingPathComponent("hooks.json"), scope: "插件", workspace: nil, inspectResources: false, inspectCredentials: false)
            guard preview.allSatisfy({ $0.diagnostic == nil }) else { throw PetError(preview.compactMap(\.diagnostic).joined(separator: "；")) }
            result.append(AgentPluginHookDefinition(key: key, data: data, preview: preview))
        }
        guard result.reduce(0, { $0 + $1.preview.count }) <= 128 else { throw PetError("每个插件最多128项 Hooks") }; return result
    }
    private static func validateHookFields(_ object: [String: Any]) throws {
        guard let events = object["hooks"] as? [String: Any] else { throw PetError("插件 Hooks 需要 hooks 对象") }
        let keys: Set<String> = ["type", "command", "timeout", "name", "network", "async", "asyncRewake", "rewakeMessage", "rewakeSummary", "statusMessage", "shell", "args", "env", "if", "once", "url", "prompt", "model", "tools", "maxTurns", "headers", "allowedEnvVars"]
        for groups in events.values {
            guard let groups = groups as? [[String: Any]] else { throw PetError("插件 Hook 事件需要数组") }
            for group in groups {
                guard Set(group.keys).isSubset(of: ["matcher", "hooks", "timeout", "async"]), group["matcher"] == nil || group["matcher"] is String, let handlers = group["hooks"] as? [[String: Any]] else { throw PetError("插件 Hook 分组字段无效或尚未支持") }
                for item in [group] + handlers {
                    for key in ["network", "async", "asyncRewake", "once"] where item[key] != nil { let raw = item[key]!; guard CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() else { throw PetError("插件 Hook \(key) 需要布尔值") } }
                    for key in ["timeout", "maxTurns"] where item[key] != nil { let raw = item[key]!; guard let value = raw as? Double, CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(), value.isFinite, key != "maxTurns" || value.rounded() == value else { throw PetError("插件 Hook \(key) 需要有效数值") } }
                }
                for handler in handlers {
                    guard Set(handler.keys).isSubset(of: keys) else { throw PetError("插件 Hook 字段尚未支持：" + Set(handler.keys).subtracting(keys).sorted().joined(separator: ", ")) }
                    for key in ["type", "command", "name", "url", "prompt", "model", "shell", "if", "statusMessage", "rewakeMessage", "rewakeSummary"] where handler[key] != nil { guard handler[key] is String else { throw PetError("插件 Hook \(key) 需要文字") } }
                    if let env = handler["env"] as? [String: String], !Set(env.keys).isDisjoint(with: Set(hookRootVariables)) { throw PetError("插件 Hook 不能覆盖插件根目录变量") }
                }
            }
        }
    }
    func hookReferences(workspace: String? = nil, onlyScope: Bool = false) throws -> [AgentPluginHookReference] {
        try catalog(workspace: workspace, onlyScope: onlyScope).flatMap { item in item.hooks.map { AgentPluginHookReference(name: item.id, installationID: item.instanceID, key: $0.key) } }
    }
    func hookConfiguration(_ reference: AgentPluginHookReference, workspace: String? = nil) throws -> (data: Data, file: URL, root: URL, fingerprint: Data, enabled: Bool, workspace: String?, title: String) {
        var item = try installation(reference.name)
        if item.workspace == nil { item.selection = try pluginSelection(item.metadata.name, workspace: workspace) }
        guard item.instanceID == reference.installationID, UUID(uuidString: item.instanceID) != nil, let definition = item.hooks.first(where: { $0.key == reference.key }) else { throw PetError("插件 Hook 已移除或更新，请刷新") }
        let root = item.root.appendingPathComponent("payload"), file = try AgentFiles(workspace: profile.path).literalURL("extensions/plugin-hooks/" + item.instanceID + "/" + String(AgentFiles.hash(Data(reference.key.utf8)).prefix(24)) + ".json")
        func expand(_ text: String) -> String { Self.hookRootVariables.reduce(text) { $0.replacingOccurrences(of: "${" + $1 + "}", with: root.path) } }
        var object = try JSONSerialization.jsonObject(with: definition.data) as! [String: Any], events = object["hooks"] as! [String: Any]
        for event in events.keys {
            var groups = events[event] as! [[String: Any]]
            for index in groups.indices {
                var handlers = groups[index]["hooks"] as! [[String: Any]]
                for row in handlers.indices {
                    if let args = handlers[row]["args"] as? [String] { handlers[row]["args"] = args.map(expand); if let command = handlers[row]["command"] as? String { handlers[row]["command"] = expand(command) } }
                    if let env = handlers[row]["env"] as? [String: String] { handlers[row]["env"] = env.mapValues(expand) }
                }; groups[index]["hooks"] = handlers
            }; events[event] = groups
        }; object["hooks"] = events
        let fingerprint: [String: Any] = ["installation": item.instanceID, "activation": item.activationID, "hashes": item.receipt.hashes]
        return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), file, root, try JSONSerialization.data(withJSONObject: fingerprint, options: [.sortedKeys]), item.enabled, item.workspace, item.metadata.name)
    }
    func validateHook(_ reference: AgentPluginHookReference, workspace: String? = nil) throws {
        let item = try requireScope(reference.name, workspace: workspace)
        guard item.instanceID == reference.installationID, item.enabled, item.hooks.contains(where: { $0.key == reference.key }) else { throw PetError("所属插件已停用、移除或更新") }
        for path in item.receipt.hashes.keys { _ = try content(path, installation: item) }
    }
}

@MainActor extension AgentHooks {
    func pluginItems(workspace: String?) throws -> [AgentHookDefinition] {
        var result: [AgentHookDefinition] = []
        for reference in try plugins.hookReferences(workspace: workspace) {
            do {
            let config = try plugins.hookConfiguration(reference, workspace: workspace), files = try AgentFiles(workspace: profile.path)
            let configured = FileManager.default.fileExists(atPath: config.file.path), data = configured ? try files.readData(config.file, maximum: 128_000) : config.data
            try validatePluginConfiguration(data, canonical: config.data)
            var hooks = try parse(data, file: config.file, scope: (config.workspace == nil ? "插件 · " : "项目插件 · ") + config.title, workspace: config.workspace, resource: config.root, fingerprintSuffix: config.fingerprint, inspectResources: false, inspectCredentials: configured)
            for i in hooks.indices {
                hooks[i].plugin = reference; hooks[i].pluginEnabled = config.enabled
                hooks[i].name = config.title + ":" + hooks[i].name
                if !configured { hooks[i].diagnostic = "请先保存插件 Hooks 配置，再启用处理器" }
            }; result += hooks
            } catch { result += pluginConfigurationFailure(reference, error: error, workspace: workspace) }
        }; return result
    }
    private func validatePluginConfiguration(_ data: Data, canonical: Data) throws {
        let edited = try JSONSerialization.jsonObject(with: credentials.mask(data)) as? NSDictionary, expected = try JSONSerialization.jsonObject(with: credentials.mask(canonical)) as? NSDictionary
        guard edited == expected else { throw PetError("插件处理器由插件管理，只能修改 env 或 Headers 的填写值") }
    }
    func pluginDocument(_ reference: AgentPluginHookReference) throws -> (text: String, hash: String?, original: Data) {
        let config = try plugins.hookConfiguration(reference), files = try AgentFiles(workspace: profile.path)
        let saved = FileManager.default.fileExists(atPath: config.file.path) ? try files.readData(config.file, maximum: 128_000) : nil
        let data = saved ?? config.data; try validatePluginConfiguration(data, canonical: config.data)
        return (String(decoding: try credentials.mask(data), as: UTF8.self), saved.map(AgentFiles.hash), data)
    }
    func savePluginDocument(_ text: String, reference: AgentPluginHookReference, original: Data, expectedHash: String?) throws {
        guard text.utf8.count <= 128_000 else { throw PetError("插件 Hooks 配置超过128KB") }
        let config = try plugins.hookConfiguration(reference), files = try AgentFiles(workspace: profile.path), previous = try pluginDocument(reference)
        guard previous.hash == expectedHash else { throw PetError("插件 Hook 本机配置已变化，请重新打开") }
        let data = try credentials.restoreImported(Data(text.utf8), original: original, file: config.file)
        try validatePluginConfiguration(data, canonical: config.data)
        _ = try parse(data, file: config.file, scope: "插件", workspace: nil, resource: config.root, inspectResources: false, inspectCredentials: false)
        try commitConfiguration(data, target: config.file) { try files.writeData($0, to: config.file, permissions: 0o600) }
    }
    func validatePlugin(_ hook: AgentHookDefinition, workspace: String? = nil) throws { if let reference = hook.plugin { try plugins.validateHook(reference, workspace: workspace ?? hook.workspace) } }
}
