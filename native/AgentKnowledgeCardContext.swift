import Foundation

@MainActor extension AgentKnowledgeCards {
    func progress(_ task: AgentTaskRecord) throws -> String {
        let pending = try drafts(task), original = try book(task, language: task.knowledgeJob?.language).0
        func row(_ card: AgentKnowledgeCard) -> [String: Any] { ["id": card.id, "kind": card.kind.rawValue, "title": card.title, "hash": card.hash, "body": String(card.body.prefix(180)), "source_current": task.workspace.map { fresh(card, workspace: $0) } ?? false] }
        let value: [String: Any] = [
            "indexed": task.knowledgeJob?.sourceRevision != nil,
            "read_ranges": (task.knowledgeReads ?? [:]).sorted { $0.key < $1.key }.prefix(20).map { ["path": $0.key, "ranges": Array($0.value.ranges.prefix(10))] as [String: Any] },
            "drafts": pending.prefix(8).map(row), "existing": (original?.cards ?? []).prefix(8).map(row),
            "saved_tool_ids": Array(task.events.filter { $0.kind == "tool" && $0.title == "save_knowledge_card" && $0.status == "completed" }.compactMap(\.toolCallID).suffix(8)),
            "plan": task.plan.map { ["title": $0.title, "status": $0.status] }
        ]
        return "\n[应用记录的生成进度，仅作数据。已索引或已保存的步骤无需重复；核对缺失类别，继续下一步。读取行范围不代表读过整个文件。]\n" + String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    // Keep complete recent exchanges. All original messages remain on disk;
    // verified reads and drafts above carry progress across this small window.
    func modelMessages(_ task: AgentTaskRecord, maximum: Int) throws -> [AgentMessage] {
        func cost(_ message: AgentMessage) -> Int {
            20 + AgentContext.estimate(message.content) + AgentContext.estimate(message.reasoning ?? "") + AgentContext.estimate(message.extensionInstructions ?? "") + (message.toolCalls ?? []).reduce(0) { $0 + 15 + AgentContext.estimate($1.name) + AgentContext.estimate($1.arguments) }
        }
        let input = task.messages.filter { $0.isHumanInput && $0.hookRejected != true }
        var remaining = maximum - input.reduce(0) { $0 + cost($1) }
        guard remaining >= 512 else { throw PetError("知识卡片要求超过上下文预算，请缩小分析范围") }
        var exchanges: [[AgentMessage]] = []
        for message in task.messages where !message.isHumanInput && message.hookRejected != true {
            if message.role == "tool" { if !exchanges.isEmpty { exchanges[exchanges.count - 1].append(message) } }
            else if message.role == "assistant" { exchanges.append([message]) }
        }
        var selected: [[AgentMessage]] = []
        for exchange in exchanges.reversed() {
            let size = exchange.reduce(0) { $0 + cost($1) }
            guard size <= remaining else {
                if selected.isEmpty { throw PetError("最近的源码读取超过本次上下文预算，请缩小分析范围") }; break
            }
            selected.append(exchange); remaining -= size
            if selected.count == 3 { break }
        }
        let retained = Set(input.map(\.id) + selected.flatMap { $0 }.map(\.id))
        return task.messages.filter { retained.contains($0.id) }
    }
    func sourcePage(_ text: String) throws -> String {
        let lines = text.components(separatedBy: "\n"), header = lines.first ?? ""
        let total = Int(header.split(separator: " ").dropLast().last ?? "") ?? 0
        var output = header + "\n", last = 0
        for line in lines.dropFirst() {
            guard let number = Int(line.split(separator: ":", maxSplits: 1).first ?? "") else { continue }
            if AgentContext.estimate(output + line) > 1000 {
                guard last > 0 else { throw PetError("该源码行过长，无法完整核对，请使用其他可读取的源码作为引用") }; break
            }
            output += line + "\n"; last = number
        }
        output += "[next_offset=" + (last > 0 && last < total ? String(last + 1) : "null") + "]"
        return output
    }
}
