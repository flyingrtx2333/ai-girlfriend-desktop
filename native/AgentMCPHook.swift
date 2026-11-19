import Foundation

struct AgentMCPHook: Codable {
    static let type = "mcp_tool"
    private static let argumentLimit = 100_000
    private static let placeholder = try! NSRegularExpression(pattern: #"\$\{([^{}]+)\}"#)

    struct Target: Codable, Equatable {
        let id: String
        let revision: String
        let destination: String
        let fingerprint: String

        init(_ server: AgentMCPServer) throws {
            id = server.id
            revision = server.revision
            destination = server.destination
            fingerprint = try AgentMCPSelection.fingerprint(server)
        }
    }

    let server: String
    let tool: String
    private let template: Data
    var target: Target?

    init(_ handler: [String: Any]) throws {
        func identifier(_ key: String) throws -> String {
            guard let value = handler[key] as? String, !value.isEmpty, value.utf8.count <= 256,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw PetError("MCP Hook 需要有效的 " + key)
            }
            return value
        }
        server = try identifier("server")
        tool = try identifier("tool")
        guard let input = (handler["input"] ?? [:]) as? [String: Any] else { throw PetError("MCP Hook 的 input 需要是 JSON 对象") }
        template = try Self.encode(input)
        guard template.count <= Self.argumentLimit else { throw PetError("MCP Hook 参数模板超过 100KB") }
    }

    var display: String {
        let path = target.map { "\n" + $0.destination } ?? ""
        return server + " / " + tool + path + "\n\n" + String(decoding: template, as: UTF8.self)
    }

    private static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    func arguments(_ event: Data) throws -> Data {
        let fields = try JSONSerialization.jsonObject(with: event)
        let input = try JSONSerialization.jsonObject(with: template)
        var remaining = Self.argumentLimit
        func debit(_ size: Int) throws {
            remaining -= size
            guard remaining >= 0 else { throw PetError("MCP Hook 参数超过 100KB") }
        }
        func resolve(_ path: String) throws -> Any {
            try path.components(separatedBy: ".").reduce(fields) { current, field in
                guard !field.isEmpty, let value = (current as? [String: Any])?[field] else {
                    throw PetError("MCP Hook 缺少事件字段 " + path)
                }
                return value
            }
        }
        func expand(_ value: Any, depth: Int) throws -> Any {
            guard depth <= 64 else { throw PetError("MCP Hook 参数嵌套过深") }
            if let object = value as? [String: Any] {
                return try object.mapValues { try expand($0, depth: depth + 1) }
            }
            if let values = value as? [Any] {
                return try values.map { try expand($0, depth: depth + 1) }
            }
            guard let text = value as? String else { return value }
            let full = NSRange(text.startIndex..., in: text)
            let matches = Self.placeholder.matches(in: text, range: full)
            if matches.count == 1, let match = matches.first, match.range == full,
               let path = Range(match.range(at: 1), in: text) {
                let field = try resolve(String(text[path]))
                try debit(Self.encode(field).count)
                return field
            }
            var result = "", end = text.startIndex
            for match in matches {
                guard let range = Range(match.range, in: text), let path = Range(match.range(at: 1), in: text) else { continue }
                let field = try resolve(String(text[path]))
                let rendered = try (field as? String) ?? String(decoding: Self.encode(field), as: UTF8.self)
                let literal = text[end..<range.lowerBound]
                try debit(literal.utf8.count + rendered.utf8.count)
                result += literal
                result += rendered
                end = range.upperBound
            }
            try debit(text[end...].utf8.count)
            return result + text[end...]
        }
        let output = try Self.encode(expand(input, depth: 0))
        guard output.count <= Self.argumentLimit else { throw PetError("MCP Hook 参数超过 100KB") }
        return output
    }

    static func containsLiteralCredential(_ input: Any) -> Bool {
        if let values = input as? [Any] { return values.contains(where: containsLiteralCredential) }
        guard let object = input as? [String: Any] else { return false }
        return object.contains { key, value in
            let normalized = key.lowercased().filter(\.isLetter)
            if ["authorization", "token", "password", "secret", "apikey", "credential"].contains(where: normalized.hasSuffix) {
                if value is NSNull { return false }
                guard let text = value as? String else { return true }
                let range = NSRange(text.startIndex..., in: text)
                return !text.isEmpty && placeholder.firstMatch(in: text, range: range)?.range != range
            }
            return containsLiteralCredential(value)
        }
    }
}
