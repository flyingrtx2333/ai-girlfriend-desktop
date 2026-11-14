import Foundation

enum AgentExtensionSelection {
    static func title(_ item: AgentExtensionItem) -> String { item.name + " · " + item.file.path }
    static func invocation(_ item: AgentExtensionItem) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return item.kind.rawValue + " " + String(decoding: try encoder.encode(title(item)), as: UTF8.self)
    }
    static func command(_ text: String) throws -> (kind: AgentExtensionKind, name: String, arguments: String)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(whereSeparator: \.isWhitespace).first,
              first.hasPrefix("/"), let kind = AgentExtensionKind(rawValue: String(first.dropFirst())) else { return nil }
        let input = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Ordinary short commands can still receive quoted arguments. Source
        // selection uses the complete file location shown by the picker.
        guard input.first == "\"" else { return nil }
        do {
            let value = try AgentQuotedCommand.parse(input, label: "扩展", maximumBytes: 16_384)
            guard value.name.contains(" · /") else { return nil }
            return (kind, value.name, value.arguments)
        } catch {
            if input.contains(" · /") { throw error }
            return nil
        }
    }
}
