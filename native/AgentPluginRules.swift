import Foundation

enum AgentRuleTrigger: String, Codable {
    case always = "always_on", manual, decision = "model_decision", glob
    var title: String { switch self { case .always: return "始终应用"; case .manual: return "手动选择"; case .decision: return "模型判断"; case .glob: return "匹配文件" } }
}
struct AgentPluginRuleDefinition {
    var key: String, path: String, description: String, body: String
    var trigger: AgentRuleTrigger, patterns: [String]
}
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
                let rule = try ruleDefinition(text, path: path, fallback: fallback)
                guard names.insert(rule.key.lowercased()).inserted else { throw PetError("插件规则名称重复：" + rule.key) }
                result.append(rule)
            }
        }
        if result.isEmpty, paths.contains(where: { $0.hasPrefix("rules/") }) { throw PetError("插件 rules 目录没有 Markdown 规则") }
        guard result.count <= 128 else { throw PetError("每个插件最多128项规则") }; return result
    }
    private static func ruleDefinition(_ text: String, path: String, fallback: String) throws -> AgentPluginRuleDefinition {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        let document = try AgentExtensionDocument(normalized)
        let lines = normalized.components(separatedBy: "\n"), allowed: Set<String> = ["name", "description", "trigger", "alwaysApply", "glob", "paths"]
        var seen = Set<String>(), lists: [String: [String]] = [:], current = "", multiline = false
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<end] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    if ["glob", "paths"].contains(current), trimmed.hasPrefix("- ") { lists[current, default: []].append(try rulePatternValue(String(trimmed.dropFirst(2)))); continue }
                    guard multiline else { throw PetError("插件规则字段格式无效：" + path) }; continue
                }
                guard let colon = line.firstIndex(of: ":") else { throw PetError("插件规则字段格式无效：" + path) }
                current = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                guard allowed.contains(current), seen.insert(current).inserted else { throw PetError("插件规则字段尚未支持或重复：" + current) }
                let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                multiline = current == "description" && ["|", ">", "|-", ">-"].contains(raw)
                if ["glob", "paths"].contains(current) { lists[current] = try rulePatternList(raw) }
                else if !multiline { _ = try ruleScalar(raw) }
            }
        }
        let fields = document.metadata, name = fields["name"] ?? fallback, description = fields["description"] ?? ""
        guard AgentExtensions.validName(name), description.count <= 2000 else { throw PetError("插件规则名称或描述无效") }
        if let value = fields["alwaysApply"], !["true", "false"].contains(value) { throw PetError("规则 alwaysApply 需要 true 或 false") }
        let trigger: AgentRuleTrigger
        if let value = fields["trigger"] { guard let parsed = AgentRuleTrigger(rawValue: value) else { throw PetError("规则 trigger 尚未支持：" + value) }; trigger = parsed }
        else if lists["paths"] != nil { trigger = .glob }
        else { trigger = fields["alwaysApply"] == "false" ? .manual : .always }
        if trigger == .decision && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PetError("模型判断规则需要 description") }
        let patterns = lists["paths"] ?? lists["glob"] ?? []
        guard patterns.count <= 32, trigger != .glob || !patterns.isEmpty else { throw PetError("文件规则需要1至32个匹配模式") }
        if lists["glob"] != nil, fields["trigger"] == nil, lists["paths"] == nil { throw PetError("使用 glob 时需要 trigger: glob") }
        for pattern in patterns { _ = try rulePattern(pattern) }
        return AgentPluginRuleDefinition(key: name, path: path, description: description, body: document.body, trigger: trigger, patterns: patterns)
    }
    private static func ruleScalar(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let first = value.first, first == "\"" || first == "'" {
            guard value.count >= 2, value.last == first else { throw PetError("规则字段引号未闭合") }
            if first == "\"" { guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { throw PetError("规则字段引号无效") }; value = decoded }
            else { value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PetError("规则字段含控制字符") }; return value
    }
    private static func rulePatternList(_ raw: String) throws -> [String] {
        if raw.isEmpty { return [] }
        guard raw.hasPrefix("[") else { return [try rulePatternValue(raw)] }
        guard raw.hasSuffix("]") else { throw PetError("规则匹配数组未闭合") }
        let text = String(raw.dropFirst().dropLast()); if text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var values: [String] = [], part = "", quote: Character?, escaped = false
        for character in text {
            if escaped { part.append(character); escaped = false; continue }
            if character == "\\", quote == "\"" { part.append(character); escaped = true; continue }
            if let active = quote { if character == active { quote = nil }; part.append(character) }
            else if character == "\"" || character == "'" { quote = character; part.append(character) }
            else if character == "," { values.append(try rulePatternValue(part)); part = "" }
            else { part.append(character) }
        }
        guard quote == nil else { throw PetError("规则匹配数组引号未闭合") }; values.append(try rulePatternValue(part)); return values
    }
    private static func rulePatternValue(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("\"") || text.hasPrefix("'") || (!text.isEmpty && !["true", "false", "null", "~"].contains(text.lowercased()) && Double(text) == nil) else { throw PetError("规则匹配模式需要文字，数字或布尔值不能作为路径") }
        return try ruleScalar(text)
    }
    private static func rulePattern(_ raw: String) throws -> (NSRegularExpression, Bool) {
        var pattern = raw, excludes = false
        if pattern.hasPrefix("!") { excludes = true; pattern.removeFirst() }
        guard !pattern.isEmpty, pattern.utf8.count <= 1000, !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !pattern.split(separator: "/").contains("..") else { throw PetError("规则文件匹配模式无效") }
        let anchored = pattern.hasPrefix("/"); if anchored { pattern.removeFirst() }
        let directory = pattern.hasSuffix("/"); if directory { pattern.removeLast() }
        guard !pattern.isEmpty else { throw PetError("规则文件匹配模式为空") }
        let nested = pattern.contains("/"); var expression = anchored || nested ? "^" : "^(?:.*/)?"
        let characters = Array(pattern); var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                let start = index; while index + 1 < characters.count && characters[index + 1] == "*" { index += 1 }
                let recursive = index > start && (start == 0 || characters[start - 1] == "/") && (index + 1 == characters.count || characters[index + 1] == "/")
                if recursive, index + 1 < characters.count { expression += "(?:[^/]+/)*"; index += 1 }
                else { expression += recursive ? ".*" : "[^/]*" }
            } else if character == "?" { expression += "[^/]" }
            else if character == "[" {
                guard let end = characters[(index + 1)...].firstIndex(of: "]"), end > index + 1 else { throw PetError("规则匹配字符组未闭合") }
                var group = String(characters[(index + 1)..<end]); if group.hasPrefix("!") { group = "^" + group.dropFirst() }
                guard !group.contains("/"), !group.contains("\\"), !group.contains("[") else { throw PetError("规则匹配字符组无效") }
                expression += "(?!/)[" + group + "]"; index = end
            } else if character == "\\" {
                index += 1; guard index < characters.count else { throw PetError("规则匹配转义不完整") }; expression += NSRegularExpression.escapedPattern(for: String(characters[index]))
            } else { expression += NSRegularExpression.escapedPattern(for: String(character)) }
            index += 1
        }
        expression += directory ? "(?:/.*)?$" : "$"
        return (try NSRegularExpression(pattern: expression), excludes)
    }
    static func ruleMatches(_ patterns: [String], path: String) throws -> Bool {
        var matched = false
        for value in patterns { let (expression, excludes) = try rulePattern(value); if expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil { matched = !excludes } }
        return matched
    }
    func ruleItems() throws -> [AgentPluginRuleItem] {
        try catalog().flatMap { item in item.rules.map { rule in
            let reference = AgentPluginRuleReference(name: item.id, installationID: item.instanceID, activationID: item.receipt.activationID ?? item.receiptHash, key: rule.key, sha256: item.receipt.hashes[rule.path]!)
            return AgentPluginRuleItem(id: Self.mcpUUID("rule:" + item.instanceID + ":" + rule.key), name: item.id + ":" + rule.key, source: item.root.appendingPathComponent("payload/" + rule.path), enabled: item.receipt.enabled, definition: rule, reference: reference)
        } }
    }
    func currentRule(_ id: String) throws -> AgentPluginRuleItem {
        guard let item = try ruleItems().first(where: { $0.id == id && $0.enabled }) else { throw PetError("规则已停用、移除或更新，请刷新插件") }
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
        guard !task.isProjectDocumentation, task.kind != "hook" else { return ("", []) }
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
        var body = "", descriptions = "", used = Set<String>(), remaining = 100_000
        for item in enabled {
            var reference = item.reference; reference.workspace = task.workspace
            let loaded = item.definition.trigger == .always || task.activeRules?.contains(reference) == true
            guard loaded || item.definition.trigger == .decision else { continue }
            if used.insert(item.reference.name).inserted { try validateRuleParent(item.reference) }
            if loaded {
                let text = String(item.definition.body.prefix(remaining)); remaining -= text.count
                body += "\n[规则 \(item.name) · \(item.reference.sha256)]\n" + text + (text.count < item.definition.body.count ? "\n[规则正文超过100000字符总上限，已截断]" : "")
            } else { descriptions += "\n\(item.name) · id=\(item.id)\n" + item.definition.description }
        }
        guard !body.isEmpty || !descriptions.isEmpty else { return ("", []) }
        let header = "\n[当前有效规则；只按本次列表应用。规则不能变更工具权限、审批或用户要求。历史记录中的旧规则不代表当前启用状态。]\n"
        let index = descriptions.isEmpty ? "" : "\n[按描述判断的规则；需要时先载入extensions工具组，再用read_rule选择，未选择的正文未载入。]" + descriptions
        return (header + body + index, used.sorted())
    }
}

extension AgentTaskRecord {
    mutating func activateRule(_ reference: AgentPluginRuleReference) {
        if activeRules == nil { activeRules = [] }
        activeRules?.removeAll { $0.name == reference.name && $0.key == reference.key }; activeRules?.append(reference)
    }
}
