import Foundation

@MainActor extension AgentKnowledgeCards {
    func writingNotesText(_ task: AgentTaskRecord) throws -> String {
        let notes = task.knowledgeJob?.writingNotes ?? []
        _ = try AgentWikiPlan(knowledgeNotes: notes).validated()
        return notes.enumerated().map { "\($0.offset + 1). " + $0.element }.joined(separator: "\n\n")
    }
    func writingNotesComplete(_ task: AgentTaskRecord) throws -> Bool {
        let text = try writingNotesText(task)
        return text.isEmpty || (task.knowledgeJob?.writingNotesRead ?? 0) == text.count
    }
    func writingNotesContext(_ task: AgentTaskRecord) throws -> String {
        let notes = task.knowledgeJob?.writingNotes ?? []
        _ = try AgentWikiPlan(knowledgeNotes: notes).validated()
        guard !notes.isEmpty else { return "" }
        let budget = max(8, 450 / notes.count)
        let rows = notes.enumerated().map { index, note in
            var excerpt = String(note.prefix(300))
            while AgentContext.estimate(excerpt) > budget { excerpt = String(excerpt.prefix(max(1, excerpt.count * 3 / 4))) }
            return "\(index + 1). " + excerpt + (excerpt == note ? "" : " [节选]")
        }
        return "\n[本次冻结的卡片写作说明；只约束组织与重点，不是源码事实或工具批准。完整原文用read_project_knowledge(configuration:true)按字符续读。]\n" + rows.joined(separator: "\n")
    }
    func readWritingNotes(_ call: AgentToolCall, task: AgentTaskRecord) throws -> AgentToolResult {
        guard let store, task.kind == Self.kind, task.knowledgeJob != nil else { throw PetError("冻结的写作说明仅供本次知识卡片生成任务读取") }
        let text = try writingNotesText(task), offset = call.object["content_offset"] as? Int ?? 0
        guard offset >= 0, offset <= text.count, offset <= (task.knowledgeJob?.writingNotesRead ?? 0) else { throw PetError("请从上一页的 next_content_offset 顺序续读") }
        let limit = min(1600, max(1, call.object["content_limit"] as? Int ?? 1600))
        var page = String(text.dropFirst(offset).prefix(limit))
        while AgentContext.estimate(page) > 400 { page = String(page.prefix(max(1, page.count * 3 / 4))) }
        let end = offset + page.count, previous = task.knowledgeJob?.writingNotesRead ?? 0
        store.update(task.id) { $0.knowledgeJob?.writingNotesRead = max(previous, end) }
        if let error = store.writeError { throw PetError(error) }
        let value: [String: Any] = ["configuration": "knowledgecard.notes", "frozen": true, "content": page, "content_offset": offset, "total_characters": text.count, "sha256": AgentFiles.hash(Data(text.utf8)), "next_content_offset": end < text.count ? end : NSNull()]
        return AgentToolResult(text: String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
    }
}
