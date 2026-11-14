import Foundation

struct AgentMCPSelection: Codable, Equatable {
    var id:String, name:String, revision:String, hash:String
    static func scope(_ server:AgentMCPServer) -> String {
        guard let plugin = server.plugin else { return "用户" }
        return (try? AgentPlugins.scope(plugin.name).workspace) == nil ? "用户插件" : "项目插件"
    }
    static func title(_ server:AgentMCPServer) -> String { scope(server) + " · " + server.name }
    static func invocation(_ server:AgentMCPServer) throws -> String { "mcp " + String(decoding:try JSONEncoder().encode(title(server)),as:UTF8.self) }
    static func fingerprint(_ server:AgentMCPServer) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return AgentFiles.hash(try encoder.encode(server)) }
    static func reference(_ server:AgentMCPServer) throws -> Self { .init(id:server.id,name:server.name,revision:server.revision,hash:try fingerprint(server)) }
    static func command(_ text:String) throws -> (name:String,arguments:String)? {
        let text = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.split(whereSeparator:\.isWhitespace).first == "/mcp" else { return nil }
        let input = String(text.dropFirst(4)).trimmingCharacters(in:.whitespacesAndNewlines)
        guard input.first == "\"" else { throw PetError("请从连接器分类选择服务，或在 /mcp 后填写带引号的连接器名称") }
        return try AgentQuotedCommand.parse(input, label: "连接器")
    }
}

@MainActor extension AgentMCPSelection {
    static func eligible(_ task:AgentTaskRecord) -> Bool {
        !task.archived && !task.isProjectDocumentation && !task.isKnowledgeEditing && task.kind != "hook" && task.skillEvolutionJob == nil && [.agent,.goal].contains(task.mode)
    }
    static func current(_ reference:Self, task:AgentTaskRecord, store:AgentStore) throws -> AgentMCPServer {
        guard eligible(task) else { throw PetError("请在普通 Agent 或目标任务中选择连接器") }
        let server = try store.mcp.server(reference.id,revision:reference.revision,workspace:task.workspace)
        guard reference.name == server.name, try reference.hash == fingerprint(server) else { throw PetError("连接器配置已变化，请重新选择") }
        let args = try JSONSerialization.data(withJSONObject:["server_id":server.id,"configuration":server.revision])
        let call = AgentToolCall(id:"explicit-mcp-selection",name:"connect_mcp",arguments:String(decoding:args,as:UTF8.self))
        try store.agents.check(call,task:task,store:store); _ = try store.mcp.approvalReason(call,task:task)
        return server
    }
    static func candidates(task:AgentTaskRecord, store:AgentStore) -> [AgentMCPServer] {
        guard eligible(task) else { return [] }
        return store.mcp.availableServers(workspace:task.workspace).compactMap { server in
            try? current(reference(server),task:task,store:store)
        }.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }
    static func prepare(_ message:inout AgentMessage, task:AgentTaskRecord, store:AgentStore) throws -> Bool {
        guard let command = try command(message.content) else { return false }
        let all = store.mcp.availableServers(workspace:task.workspace)
        var matches = all.filter { title($0).localizedCaseInsensitiveCompare(command.name) == .orderedSame }
        if matches.isEmpty { matches = all.filter { $0.name.localizedCaseInsensitiveCompare(command.name) == .orderedSame } }
        guard matches.count == 1 else { throw PetError(matches.isEmpty ? "连接器已移除或不属于当前项目，请重新选择" : "连接器名称重复，请从分类中按来源选择") }
        let server = try current(reference(matches[0]),task:task,store:store)
        message.mcpSelection = try reference(server)
        let data = try JSONSerialization.data(withJSONObject:["server_id":server.id,"name":server.name,"configuration":server.revision],options:[.sortedKeys])
        message.extensionInstructions = "[用户明确选择连接器；此选择不表示已连接或批准调用。应用已载入mcp工具组。使用当前服务信息调用connect_mcp，再根据真实工具目录处理用户的后续要求，遵循原审批与权限，不猜测外部结果。]\n" + String(decoding:data,as:UTF8.self)
        return true
    }
    static func validate(_ task:AgentTaskRecord, store:AgentStore) throws {
        if let selected = task.messages.last(where:\.isHumanInput)?.mcpSelection { _ = try current(selected,task:task,store:store) }
    }
}
