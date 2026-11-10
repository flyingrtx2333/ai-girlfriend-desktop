import Foundation

struct AgentPluginRuleReference: Codable, Equatable {
    var name: String, installationID: String, activationID: String, key: String, sha256: String
    var workspace: String?
}
struct AgentPluginRuleItem: Identifiable {
    var id: String, name: String, source: URL, enabled: Bool
    var definition: AgentPluginRuleDefinition, reference: AgentPluginRuleReference
}

@MainActor extension AgentPlugins {
    static func ruleDefinitions(_ manifest: [String: Any], paths: Set<String>, read: (String) throws -> Data) throws -> [AgentPluginRuleDefinition] {
        let bases: [String]
        if let raw = manifest["rules"], !(raw is NSNull) {
            if let path = raw as? String { bases = [path] }
            else if let list = raw as? [String] { bases = list }
            else { throw PetError("插件 rules 需要相对路径或路径数组") }
        } else { bases = ["rules"] }
        var result: [AgentPluginRuleDefinition] = [], names = Set<String>(), selected = Set<String>()
        for raw in bases {
            var base = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            while base.hasSuffix("/") { base.removeLast() }
            guard AgentArchive.validPath(base), !base.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { throw PetError("插件规则路径无效") }
            let single = paths.contains(base) && base.hasSuffix(".md")
            let matches = single ? [base] : paths.filter { $0.hasPrefix(base + "/") && $0.hasSuffix(".md") }.sorted()
            if manifest["rules"] != nil && matches.isEmpty { throw PetError("插件声明的规则路径没有组件：" + base) }
            for path in matches {
                guard selected.insert(path).inserted else { throw PetError("插件规则路径重复：" + path) }
                guard let text = String(data: try read(path), encoding: .utf8) else { throw PetError("插件规则需要 UTF-8 Markdown") }
                let fallback = single ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : String(path.dropFirst(base.count + 1).dropLast(3)).replacingOccurrences(of: "/", with: ":")
                let rule = try AgentRuleDocument.parse(text, path: path, fallback: fallback)
                guard names.insert(rule.key.lowercased()).inserted else { throw PetError("插件规则名称重复：" + rule.key) }
                result.append(rule)
            }
        }
        if result.isEmpty, paths.contains(where: { $0.hasPrefix("rules/") }) { throw PetError("插件 rules 目录没有 Markdown 规则") }
        guard result.count <= 128 else { throw PetError("每个插件最多128项规则") }; return result
    }
    static func ruleMatches(_ patterns: [String], path: String) throws -> Bool { try AgentRuleDocument.matches(patterns, path: path) }
    func ruleItems() throws -> [AgentPluginRuleItem] {
        try catalog().flatMap { item in item.rules.map { rule in
            let reference = AgentPluginRuleReference(name: item.id, installationID: item.instanceID, activationID: item.receipt.activationID ?? item.receiptHash, key: rule.key, sha256: item.receipt.hashes[rule.path]!)
            return AgentPluginRuleItem(id: Self.mcpUUID("rule:" + item.instanceID + ":" + rule.key), name: item.id + ":" + rule.key, source: item.root.appendingPathComponent("payload/" + rule.path), enabled: item.receipt.enabled, definition: rule, reference: reference)
        } }
    }
    func currentRule(_ id: String) throws -> AgentPluginRuleItem {
        guard let item = try ruleItems().first(where: { $0.id == id && $0.enabled }) else { throw PetError("未找到已启用的规则id，请使用当前上下文或list_rules中的编号；停用、移除或更新后请重新选择规则") }
        try validateRuleParent(item.reference); return item
    }
    private func validateRuleParent(_ reference: AgentPluginRuleReference) throws {
        let item = try installation(reference.name)
        guard item.receipt.enabled, item.instanceID == reference.installationID, (item.receipt.activationID ?? item.receiptHash) == reference.activationID else { throw PetError("所属插件已停用、移除或更新") }
        for path in item.receipt.hashes.keys { _ = try content(path, installation: item) }
    }
    func ruleInput(_ text: String, task: AgentTaskRecord) throws -> AgentPluginRuleReference? {
        let parts = text.split(whereSeparator: { $0.isWhitespace }); guard let first = parts.first else { return nil }
        let name: String
        if first.hasPrefix("@rule:") { name = String(first.dropFirst(6)) }
        else if first == "@rule", parts.count > 1 { name = String(parts[1]) }
        else { return nil }
        guard !task.isProjectDocumentation, task.kind != "hook", let item = try ruleItems().first(where: { $0.name == name && $0.enabled }) else { throw PetError("未找到已启用的规则，请在插件中选择") }
        guard (task.activeRules?.count ?? 0) < 256 || task.activeRules?.contains(where: { $0.name == item.reference.name && $0.key == item.reference.key }) == true else { throw PetError("当前任务已载入256项规则，请使用新任务") }
        let current = try currentRule(item.id); var reference = current.reference; reference.workspace = task.workspace; return reference
    }
    func activateRule(_ reference: AgentPluginRuleReference, store: AgentStore, taskID: String) throws {
        guard let task = store.task(taskID), !task.archived, !task.isProjectDocumentation, task.kind != "hook", task.workspace == reference.workspace else { throw PetError("规则不属于当前任务范围") }
        var unbound = reference; unbound.workspace = nil
        guard let item = try ruleItems().first(where: { $0.reference == unbound && $0.enabled }) else { throw PetError("规则来源已变化，请重新选择") }
        guard (task.activeRules?.count ?? 0) < 256 || task.activeRules?.contains(where: { $0.name == reference.name && $0.key == reference.key }) == true else { throw PetError("当前任务已载入256项规则，请使用新任务") }
        _ = try currentRule(item.id)
        store.update(taskID) { $0.activateRule(reference) }
        if let error = store.writeError { throw PetError("规则状态未保存：" + error) }
    }
    func accessRules(_ path: String, store: AgentStore, taskID: String) throws {
        guard let task = store.task(taskID), !task.isProjectDocumentation, task.kind != "hook", let workspace = task.workspace else { return }
        let files = try AgentFiles(workspace: workspace), url = try files.resolve(path), relative = files.relative(url)
        for item in try ruleItems() where item.enabled && item.definition.trigger == .glob {
            guard try Self.ruleMatches(item.definition.patterns, path: relative) else { continue }
            var reference = item.reference; reference.workspace = task.workspace
            if store.task(taskID)?.activeRules?.contains(reference) != true { try activateRule(reference, store: store, taskID: taskID) }
        }
    }
    func ruleContext(_ task: AgentTaskRecord) throws -> (text: String, plugins: [String]) {
        let result = try ruleContextEntries(task)
        return (AgentRuleContextEntry.render(result.entries), result.plugins)
    }
    func ruleContextEntries(_ task: AgentTaskRecord) throws -> (entries: [AgentRuleContextEntry], plugins: [String]) {
        guard !task.isProjectDocumentation, task.kind != "hook" else { return ([], []) }
        let all = try ruleItems(), enabled = all.filter(\.enabled)
        // A damaged enabled package cannot silently remove its instructions. Disabled packages do not block unrelated work.
        let base = profile.appendingPathComponent("extensions/plugins")
        if FileManager.default.fileExists(atPath: base.path) {
            for url in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                if all.contains(where: { $0.reference.name == url.lastPathComponent }) { continue }
                if let item = try? installation(url.lastPathComponent) { if item.rules.isEmpty { continue } }
                let files = try AgentFiles(workspace: profile.path), receipt = try JSONDecoder().decode(AgentPluginReceipt.self, from: files.readData(files.literalURL("extensions/plugins/" + url.lastPathComponent + "/receipt.json"), maximum: 500_000))
                if receipt.enabled { throw PetError("启用的插件无法载入，请修复或停用：" + url.lastPathComponent) }
            }
        }
        var entries: [AgentRuleContextEntry] = [], used = Set<String>()
        for item in enabled {
            var reference = item.reference; reference.workspace = task.workspace
            let loaded = item.definition.trigger == .always || task.activeRules?.contains(reference) == true
            guard loaded || item.definition.trigger == .decision else { continue }
            if used.insert(item.reference.name).inserted { try validateRuleParent(item.reference) }
            entries.append(AgentRuleContextEntry(id: item.id, name: item.name, sha256: item.reference.sha256, definition: item.definition, loaded: loaded))
        }
        return (entries, used.sorted())
    }
}

extension AgentTaskRecord {
    mutating func activateRule(_ reference: AgentPluginRuleReference) {
        if activeRules == nil { activeRules = [] }
        activeRules?.removeAll { $0.name == reference.name && $0.key == reference.key }; activeRules?.append(reference)
    }
}
