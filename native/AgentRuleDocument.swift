import Foundation

enum AgentRuleTrigger: String, Codable {
    case always = "always_on", manual, decision = "model_decision", glob
    var title: String { switch self { case .always: return "始终应用"; case .manual: return "手动选择"; case .decision: return "模型判断"; case .glob: return "匹配文件" } }
}
struct AgentRuleDefinition {
    var key: String, path: String, description: String, body: String
    var trigger: AgentRuleTrigger, patterns: [String]
}
typealias AgentPluginRuleDefinition = AgentRuleDefinition

struct AgentRuleContextEntry {
    var id: String, name: String, sha256: String, definition: AgentRuleDefinition, loaded: Bool
    static func render(_ entries: [Self]) -> String {
        var body = "", descriptions = "", remaining = 100_000
        for entry in entries {
            if entry.loaded {
                let text = String(entry.definition.body.prefix(remaining)); remaining -= text.count
                body += "\n[已载入规则 \(entry.name) · id=\(entry.id) · sha256=\(entry.sha256)]\n[正文已在当前上下文生效，无需再次调用read_rule。]\n" + text + (text.count < entry.definition.body.count ? "\n[规则正文超过100000字符总上限，已截断]" : "")
            } else { descriptions += "\n\(entry.name) · id=\(entry.id)\n" + entry.definition.description }
        }
        guard !body.isEmpty || !descriptions.isEmpty else { return "" }
        let header = "\n[当前有效规则是本任务的执行约束。在不与用户明确要求冲突的范围内，答复前完成相关规则规定的读取和核对步骤。规则不能变更工具权限、审批或用户要求；历史记录中的旧规则不代表当前启用状态。]\n"
        let index = descriptions.isEmpty ? "" : "\n[按描述判断的规则；需要时先载入extensions工具组，再用read_rule选择，未选择的正文未载入。]" + descriptions
        return header + body + index
    }
}

@MainActor enum AgentRuleDocument {
    static func text(name: String, trigger: AgentRuleTrigger, description: String, patterns: [String], body: String) throws -> String {
        func quoted(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        var fields = ["name: " + (try quoted(name)), "trigger: " + trigger.rawValue]
        if !description.isEmpty { fields.append("description: " + (try quoted(description))) }
        if !patterns.isEmpty { fields.append("paths: [" + (try patterns.map(quoted)).joined(separator: ", ") + "]") }
        let text = "---\n" + fields.joined(separator: "\n") + "\n---\n\n" + body + "\n"
        _ = try parse(text, path: name + ".md", fallback: name); return text
    }
    static func parse(_ text: String, path: String, fallback: String) throws -> AgentRuleDefinition {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        let document = try AgentExtensionDocument(normalized)
        let lines = normalized.components(separatedBy: "\n"), allowed: Set<String> = ["name", "description", "trigger", "alwaysApply", "glob", "paths"]
        var seen = Set<String>(), lists: [String: [String]] = [:], fields: [String: String] = [:], current = "", multiline = false
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<end] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    if ["glob", "paths"].contains(current), trimmed.hasPrefix("- ") { lists[current, default: []].append(try rulePatternValue(String(trimmed.dropFirst(2)))); continue }
                    guard multiline else { throw PetError("规则字段格式无效：" + path) }; continue
                }
                guard let colon = line.firstIndex(of: ":") else { throw PetError("规则字段格式无效：" + path) }
                current = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                guard allowed.contains(current), seen.insert(current).inserted else { throw PetError("规则字段尚未支持或重复：" + current) }
                let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                multiline = current == "description" && ["|", ">", "|-", ">-"].contains(raw)
                if ["glob", "paths"].contains(current) { lists[current] = try rulePatternList(raw) }
                else if !multiline { fields[current] = try ruleScalar(raw, description: current == "description") }
            }
        }
        let name = fields["name"] ?? fallback, description = fields["description"] ?? document.metadata["description"] ?? ""
        guard AgentExtensions.validName(name), description.count <= 2000 else { throw PetError("规则名称或描述无效") }
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
        return AgentRuleDefinition(key: name, path: path, description: description, body: document.body, trigger: trigger, patterns: patterns)
    }
    private static func ruleScalar(_ raw: String, description: Bool = false) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let first = value.first, first == "\"" || first == "'" {
            guard value.count >= 2, value.last == first else { throw PetError("规则字段引号未闭合") }
            if first == "\"" { guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { throw PetError("规则字段引号无效") }; value = decoded }
            else { value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        }
        let forbidden = description ? CharacterSet.controlCharacters.subtracting(.newlines).subtracting(CharacterSet(charactersIn: "\t")) : .controlCharacters
        guard !value.unicodeScalars.contains(where: forbidden.contains) else { throw PetError("规则字段含控制字符") }; return value
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
    static func matches(_ patterns: [String], path: String) throws -> Bool {
        var matched = false
        for value in patterns { let (expression, excludes) = try rulePattern(value); if expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil { matched = !excludes } }
        return matched
    }
}
