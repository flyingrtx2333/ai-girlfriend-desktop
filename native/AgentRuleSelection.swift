import Foundation

enum AgentRuleSelection {
    static func title(_ item: AgentLocalRuleItem) -> String { item.invocation + " · " + item.source.path }
    static func title(_ item: AgentPluginRuleItem) -> String { item.name + " · " + item.source.path }
    static func invocation(_ title: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return "@rule " + String(decoding: try encoder.encode(title), as: UTF8.self)
    }
    static func command(_ text: String) throws -> (name: String, arguments: String)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.split(whereSeparator: \.isWhitespace).first == "@rule" else { return nil }
        let input = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.first == "\"" else { return nil }
        return try AgentQuotedCommand.parse(input, label: "规则", maximumBytes: 16_384)
    }
}

@MainActor extension AgentRuleSelection {
    static func prepare(_ message: inout AgentMessage, task: AgentTaskRecord, store: AgentStore) throws -> Bool {
        guard let command = try command(message.content) else { return false }
        let local = try store.rules.catalog(task: task).filter { $0.enabled }
        let plugins = try store.extensions.plugins.ruleItems(task: task).filter { $0.enabled }
        var localMatches = local.filter { title($0) == command.name }
        var pluginMatches = plugins.filter { title($0) == command.name }
        if localMatches.isEmpty && pluginMatches.isEmpty {
            localMatches = local.filter { $0.invocation == command.name }
            pluginMatches = plugins.filter { $0.name == command.name }
        }
        guard localMatches.count + pluginMatches.count == 1 else {
            throw PetError(localMatches.isEmpty && pluginMatches.isEmpty ? "规则已停用、移除或不属于当前任务，请重新选择" : "规则名称重复，请在设置中按源文件夹选择")
        }
        if let item = localMatches.first { message.localRuleReferences = [try store.rules.selection(item.id, task: task)] }
        else if let item = pluginMatches.first { message.ruleReferences = [try store.extensions.plugins.ruleSelection(item.id, task: task)] }
        return true
    }
}
