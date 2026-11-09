import Foundation

enum AgentTaskExport {
    enum Format: String, CaseIterable { case markdown, json
        var title: String { self == .markdown ? "Markdown (.md)…" : "JSON (.json)…" }
        var suffix: String { self == .markdown ? "md" : "json" }
    }
    struct Call: Codable { var id: String, name: String, arguments: String }
    struct Message: Codable {
        var id: String, role: String, content: String
        var reasoning: String?, toolCalls: [Call]?, toolCallID: String?, attachmentIDs: [String]?
        var visualIDs: [String]?
        var importedContext: Bool?, hookRejected: Bool?
    }
    struct Event: Codable {
        var id: String, kind: String, title: String, detail: String, status: String, created: Date
        var duration: Double?, toolCallID: String?, childTaskID: String?
    }
    struct Attachment: Codable { var id: String, name: String, type: String, bytes: Int, sha256: String }
    struct History: Codable {
        var version = 1
        var taskID: String, title: String, workspace: String?, model: String
        var workMode: AgentWorkMode, mode: AgentMode, status: AgentTaskStatus
        var created: Date, updated: Date, exported: Date
        var messages: [Message], events: [Event], attachments: [Attachment]
    }
    static func snapshot(_ task: AgentTaskRecord) -> History {
        let visible = task.messages.filter { $0.nativeContext != true }, ids = Set(visible.flatMap { ($0.attachmentIDs ?? []) + ($0.visuals ?? []).map(\.id) })
        return History(taskID: task.id, title: task.title, workspace: task.workspace, model: task.model, workMode: task.organizationMode, mode: task.mode, status: task.status, created: task.created, updated: task.updated, exported: Date(),
                       messages: visible.map { Message(id: $0.id, role: $0.role, content: $0.content, reasoning: $0.reasoning, toolCalls: $0.toolCalls?.map { Call(id: $0.id, name: $0.name, arguments: $0.arguments) }, toolCallID: $0.toolCallID, attachmentIDs: $0.attachmentIDs, visualIDs: $0.visuals?.map(\.id), importedContext: $0.importedContext, hookRejected: $0.hookRejected) },
                       events: task.events.map { Event(id: $0.id, kind: $0.kind, title: $0.title, detail: $0.detail, status: $0.status, created: $0.created, duration: $0.duration, toolCallID: $0.toolCallID, childTaskID: $0.childTaskID) },
                       attachments: (task.attachments ?? []).filter { ids.contains($0.id) }.map { Attachment(id: $0.id, name: $0.name, type: $0.fileExtension, bytes: $0.bytes, sha256: $0.sha256) })
    }
    static func data(_ history: History, format: Format) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        if format == .json { return try encoder.encode(history) }
        let date = ISO8601DateFormatter()
        var output = "# " + line(history.title) + "\n\n任务：" + history.taskID + "\n工作区：" + line(history.workspace ?? "无") + "\n模式：" + history.mode.title + "\n状态：" + history.status.title + "\n导出时间：" + date.string(from: history.exported) + "\n"
        for message in history.messages {
            let role = ["user": "用户", "assistant": "助手", "tool": "工具", "system": "系统"][message.role] ?? line(message.role)
            output += "\n---\n\n## " + role + "\n\n"
            if let id = message.toolCallID { output += "调用：" + line(id) + "\n\n" }
            output += message.role == "tool" ? fence(message.content) : message.content
            output += "\n"
            if let reasoning = message.reasoning, !reasoning.isEmpty { output += "\n### 思考记录\n\n" + fence(reasoning) }
            for call in message.toolCalls ?? [] { output += "\n### " + line(call.name) + "\n\n调用：" + line(call.id) + "\n\n" + fence(call.arguments, language: "json") }
            var seen = Set<String>()
            for id in (message.attachmentIDs ?? []) + (message.visualIDs ?? []) where seen.insert(id).inserted {
                if let file = history.attachments.first(where: { $0.id == id }) { output += "\n附件：" + line(file.name) + " · " + String(file.bytes) + " 字节 · SHA256 " + file.sha256 + "\n" }
            }
        }
        if !history.events.isEmpty { output += "\n---\n\n## 执行记录\n\n" + fence(String(decoding: try encoder.encode(history.events), as: UTF8.self), language: "json") }
        return Data(output.utf8)
    }
    private static func line(_ value: String) -> String { value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
    private static func fence(_ value: String, language: String = "text") -> String {
        var longest = 0, current = 0
        for character in value { if character == "`" { current += 1; longest = max(longest, current) } else { current = 0 } }
        let marker = String(repeating: "`", count: max(3, longest + 1)); return marker + language + "\n" + value + "\n" + marker + "\n"
    }
    static func destination(_ url: URL, profile: URL, application: URL) throws -> (files: AgentFiles, url: URL, signature: String) {
        let files = try AgentFiles(workspace: url.deletingLastPathComponent().path), target = try files.literalURL(url.lastPathComponent)
        let path = target.path.lowercased(), roots = [profile, application].map { $0.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }
        guard !AgentFiles.sensitive(target.path), !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { throw PetError("不能覆盖应用配置或受保护文件，请选择其他导出位置") }
        let entry = try files.entryMetadata(target)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("导出目标只读或为链接，请选择其他位置") }
        return (files, target, entry.signature)
    }
}
