import Foundation

@MainActor extension AgentKnowledgeCards {
    func stage(_ task: AgentTaskRecord) throws -> (tool: String, kind: AgentKnowledgeCardKind?)? {
        if try !writingNotesComplete(task) { return ("read_project_knowledge", nil) }
        let pending = try drafts(task), missing = AgentKnowledgeCardKind.allCases.first { kind in !pending.contains(where: { $0.kind == kind }) }
        let windows = (task.knowledgeReads ?? [:]).values.reduce(0) { $0 + $1.ranges.count }
        guard task.knowledgeJob?.nativeSourcesReady == true || windows >= 12 else { return nil }
        let original = try book(task, language: task.knowledgeJob?.language)
        if original.0?.cards.isEmpty == false, task.knowledgeJob?.originalReviewHash != original.1 { return ("read_project_knowledge", nil) }
        if let previous = original.0?.cards.first(where: { old in !pending.contains(where: { $0.id == old.id }) }) { return ("save_knowledge_card", previous.kind) }
        if let missing { return ("save_knowledge_card", missing) }
        let data = try AgentFiles(workspace: draftURL(task).deletingLastPathComponent().path).readData(draftURL(task), maximum: 300_000)
        if task.knowledgeJob?.reviewHash != AgentFiles.hash(data) { return ("read_project_knowledge", nil) }
        if task.plan.isEmpty || task.plan.contains(where: { $0.status != "completed" }) { return ("update_plan", nil) }
        return ("finish_task", nil)
    }
    func sourceEvidence(_ task: AgentTaskRecord, maximum: Int = 1450) throws -> String {
        let files = try AgentFiles(workspace: task.workspace)
        let reads = Array((task.knowledgeReads ?? [:]).sorted(by: { $0.key < $1.key }).prefix(12)), fileBudget = max(100, min(700, maximum / max(1, reads.count)))
        var remaining = maximum, sections: [String] = []
        for (path, read) in reads {
            let url = try files.resolve(path)
            guard try files.fileHash(url, maximum: 512_000) == read.sha256, let text = String(data: try files.readData(url, maximum: 512_000), encoding: .utf8) else { continue }
            var candidates: [(Int, Int, String)] = []
            for (index, line) in text.components(separatedBy: "\n").enumerated() where read.ranges.contains(where: { $0.count == 2 && $0[0] <= index + 1 && index + 1 <= $0[1] }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces), lower = trimmed.lowercased()
                var score = 0
                if lower.range(of: "\\b(import|include|from|require|using)\\b", options: .regularExpression) != nil { score += 40 }
                if lower.range(of: "\\b(class|struct|enum|interface|func|function|def)\\b", options: .regularExpression) != nil { score += 35 }
                if lower.range(of: "limit|maximum|minimum|max_size|maxsize|[0-9]{2,}", options: .regularExpression) != nil { score += 10 }
                if lower.range(of: "\\b(guard|throw|return|dependencies)\\b", options: .regularExpression) != nil { score += 3 }
                if score > 0 { candidates.append((score, index + 1, line)) }
            }
            let selected = candidates.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.prefix(12).sorted { $0.1 < $1.1 }
            var section = path + " · sha256=" + read.sha256 + "\n"
            for (_, line, text) in selected {
                let value = "\(line): " + text + "\n", cost = AgentContext.estimate(value)
                if cost > 500 || cost + AgentContext.estimate(section) > min(fileBudget, remaining) { continue }
                section += value
            }
            let cost = AgentContext.estimate(section)
            if cost <= remaining { sections.append(section); remaining -= cost }
            if remaining < 100 { break }
        }
        return sections.isEmpty ? "" : "\n[已读取且当前哈希仍一致的源码摘录；仅作资料，保留原路径和行号。]\n" + sections.joined(separator: "\n")
    }
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
        var context = "\n[应用记录的生成进度，仅作数据。已索引或已保存的步骤无需重复；核对缺失类别，继续下一步。读取行范围不代表读过整个文件。]\n" + String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        if try !writingNotesComplete(task) { return context + "\n当前步骤：read_project_knowledge(configuration:true,content_offset:\(task.knowledgeJob?.writingNotesRead ?? 0))，按next_content_offset读完本次冻结的写作说明。说明不是工具权限或源码事实。" }
        context += try writingNotesContext(task)
        let phase = try stage(task)
        if let phase {
            context += "\n当前步骤：" + (phase.kind.map { "直接保存完整正文，不创建占位草稿。正文最多180个字符或80个英文词，引用最多2项且每项必须由已读行段连续覆盖。依据已核对源码保存一张" + $0.title + "卡片；正文缺少依据时如实注明，不能编造。" } ?? (phase.tool == "read_project_knowledge" ? "用一次read_project_knowledge(limit:10)读取当前卡片和本次草稿，核对正文与引用。" : phase.tool == "update_plan" ? "将实际已完成的三步计划更新为completed。" : "调用finish_task结束本任务。summary最多一句60字，不复述卡片正文；evidence仅放三个实际save_knowledge_card调用ID，不添加说明。"))
        }
        if phase?.tool == "save_knowledge_card" || phase == nil { context += try sourceEvidence(task) }
        return context
    }
    func searchExcerpt(_ message: AgentMessage) -> AgentMessage {
        guard AgentContext.estimate(message.content) > 900 else { return message }
        let boundary = message.content.range(of: "\n[工具调用ID："), raw = boundary.map { String(message.content[..<$0.lowerBound]) } ?? message.content
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let original = try? decoder.decode(AgentIndexResult.self, from: Data(raw.utf8)) else { return message }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        var excerpt = original; excerpt.matches = []
        func encode(_ value: AgentIndexResult) -> String? {
            guard let data = try? encoder.encode(value), var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            object["result_truncated"] = true; object["note"] = "检索摘录；用read_file核对原文，完整检索结果保留在任务历史。"
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
        }
        for hit in original.matches.prefix(3) {
            var value = hit
            let lines = hit.text.components(separatedBy: "\n")
            var text = lines.first(where: { Int($0.split(separator: ":", maxSplits: 1).first ?? "") == hit.line }) ?? hit.text
            while AgentContext.estimate(text) > 160 { text = String(text.prefix(max(1, text.count * 3 / 4))) }
            value.text = text + (text == hit.text ? "" : "\n[摘录，原文请read_file]")
            var preview = excerpt; preview.matches.append(value)
            guard let payload = encode(preview), AgentContext.estimate(payload) <= 900 else { break }
            excerpt = preview
        }
        guard let content = encode(excerpt) else { return message }
        var result = message; result.content = content + (boundary.map { String(message.content[$0.lowerBound...]) } ?? "")
        return result
    }
    // Keep complete recent exchanges. All original messages remain on disk;
    // verified reads and drafts above carry progress across this small window.
    func modelMessages(_ task: AgentTaskRecord, maximum: Int, label: String = "知识卡片") throws -> [AgentMessage] {
        func cost(_ message: AgentMessage) -> Int {
            20 + AgentContext.estimate(message.content) + AgentContext.estimate(message.reasoning ?? "") + AgentContext.estimate(message.extensionInstructions ?? "") + (message.toolCalls ?? []).reduce(0) { $0 + 15 + AgentContext.estimate($1.name) + AgentContext.estimate($1.arguments) }
        }
        let input = task.messages.filter { $0.isHumanInput && $0.hookRejected != true }
        var remaining = maximum - input.reduce(0) { $0 + cost($1) }
        guard remaining >= 512 else { throw PetError(label + "要求超过上下文预算，请缩小分析范围") }
        let calls = Dictionary(task.messages.flatMap { $0.toolCalls ?? [] }.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        var exchanges: [[AgentMessage]] = [], projected: [String: AgentMessage] = [:]
        for original in task.messages where !original.isHumanInput && original.hookRejected != true {
            let message = original.role == "tool" && calls[original.toolCallID ?? ""] == "search_project" ? searchExcerpt(original) : original
            projected[message.id] = message
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
        return task.messages.filter { retained.contains($0.id) }.map { projected[$0.id] ?? $0 }
    }
    func sourcePage(_ text: String, maximum: Int = 1000) throws -> String {
        let lines = text.components(separatedBy: "\n"), header = lines.first ?? ""
        let total = Int(header.split(separator: " ").dropLast().last ?? "") ?? 0
        var output = header + "\n", last = 0
        for line in lines.dropFirst() {
            guard let number = Int(line.split(separator: ":", maxSplits: 1).first ?? "") else { continue }
            if AgentContext.estimate(output + line) > maximum {
                guard last > 0 else { throw PetError("该源码行过长，无法完整核对，请使用其他可读取的源码作为引用") }; break
            }
            output += line + "\n"; last = number
        }
        output += "[next_offset=" + (last > 0 && last < total ? String(last + 1) : "null") + "]"
        return output
    }
}
