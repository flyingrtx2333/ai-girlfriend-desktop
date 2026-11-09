import Foundation

struct AgentWikiEditRead: Codable {
    var workspace: String, identity: String, branch: String, language: String, root: String, pointer: String
    var read: AgentKnowledgeCardRead
}

@MainActor extension AgentWiki {
    private struct EditText: Decodable { let old_text: String, new_text: String }
    private static func editingTask(_ task: AgentTaskRecord, store: AgentStore) throws {
        guard task.isKnowledgeEditing, [.agent, .goal].contains(task.mode), !task.archived, task.queuedCount == 0 else { throw PetError("请在普通 Agent 任务中明确使用 /knowledge-edit 编辑项目 Wiki") }
    }
    static func editApproval(_ call: AgentToolCall, store: AgentStore, task: AgentTaskRecord) throws -> String {
        try editingTask(task, store: store)
        guard try !store.agents.limits(task, store: store).readOnly, let path = call.object["path"] as? String, let read = task.wikiEditReads?[path], read.read.sha256 == call.object["expected_hash"] as? String else { throw PetError("请先读取当前 Wiki 页面及 hash；只读任务不可编辑") }
        return "更新 Wiki（" + (read.language == "zh" ? "中文" : "English") + "）：" + path + "\n\n" + String((call.object["old_text"] as? String ?? "").prefix(500)) + "\n→\n" + String((call.object["new_text"] as? String ?? "").prefix(500))
    }
    static func executeEditing(_ call: AgentToolCall, store: AgentStore, task: AgentTaskRecord) async throws -> AgentToolResult {
        try editingTask(task, store: store)
        let args = call.object, language = args["language"] as? String ?? task.wikiLanguage ?? "zh"
        guard ["zh", "en"].contains(language) else { throw PetError("请选择中文或英文 Wiki") }
        let scope = try store.knowledgeCards.scope(task), files = try AgentFiles(workspace: scope.root), identity = try AgentKnowledgeCards.identity(scope.root)
        let view = try view(store: store, taskID: task.id, language: language)
        func result(_ value: [String: Any]) throws -> AgentToolResult { AgentToolResult(text: String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)) }
        guard let path = args["path"] as? String, !path.isEmpty else {
            guard call.name == "read_project_wiki" else { throw PetError("请指定实际 Wiki 页面路径") }
            let offset = min(view.pages.count, max(0, args["offset"] as? Int ?? 0)), limit = min(20, max(1, args["limit"] as? Int ?? 10)), page = Array(view.pages.dropFirst(offset).prefix(limit))
            return try result(["language": language, "branch": scope.branch, "total": view.pages.count, "documents": page.map { ["path": $0.path, "title": $0.title, "parent": $0.parent ?? ""] }, "next_offset": offset + page.count < view.pages.count ? offset + page.count : NSNull()])
        }
        guard view.pages.contains(where: { $0.path == path }), files.relative(try files.resolve(path)) == path else { throw PetError("请从当前分支及语言的 Wiki 目录选择实际页面") }
        let file = try files.literalURL(path), bytes = try files.readData(file, maximum: 512_000), hash = AgentFiles.hash(bytes), document = try AgentTextFile.decode(bytes), text = document.text
        guard text.utf16.count <= 300_000 else { throw PetError("Wiki 页面超过读取上限") }
        let snapshot = try await snapshot(store, task.id, language)
        try Task.checkCancellation()
        guard let current = store.task(task.id) else { throw PetError("任务已关闭") }; try editingTask(current, store: store)
        guard try AgentKnowledgeCards.identity(scope.root) == identity, try store.knowledgeCards.scope(current).branch == scope.branch, snapshot.workspace == scope.root, snapshot.root == view.root, snapshot.data[String(path.dropFirst(view.root.count + 1))] == bytes else { throw PetError("读取期间 Wiki 页面或项目范围已变化，请重新读取") }
        if call.name == "read_project_wiki" {
            let offset = args["content_offset"] as? Int ?? 0
            guard offset >= 0, offset <= text.count else { throw PetError("Wiki 正文分页位置无效") }
            var page = String(text.dropFirst(offset).prefix(min(1600, max(1, args["content_limit"] as? Int ?? 1600))))
            while AgentContext.estimate(page) > 400 { page = String(page.prefix(max(1, page.count * 3 / 4))) }
            let end = offset + page.count
            var read = current.wikiEditReads?[path].flatMap { $0.workspace == scope.root && $0.identity == identity && $0.branch == scope.branch && $0.language == language && $0.root == view.root && $0.pointer == snapshot.pointer && $0.read.sha256 == hash ? $0 : nil } ?? AgentWikiEditRead(workspace: scope.root, identity: identity, branch: scope.branch, language: language, root: view.root, pointer: snapshot.pointer, read: AgentKnowledgeCardRead(sha256: hash, ranges: []))
            if end > offset { read.read.ranges = mergedEditRanges(read.read.ranges + [[offset + 1, end]]) }
            guard read.read.ranges.count <= 200, (current.wikiEditReads?.count ?? 0) < 1000 || current.wikiEditReads?[path] != nil else { throw PetError("Wiki 编辑读取记录过多，请新建任务") }
            store.update(task.id) { $0.wikiEditReads = ($0.wikiEditReads ?? [:]).merging([path: read]) { _, new in new } }
            if let error = store.writeError { throw PetError(error) }
            return try result(["path": path, "language": language, "branch": scope.branch, "hash": hash, "content": page, "content_offset": offset, "total_characters": text.count, "next_content_offset": end < text.count ? end : NSNull()])
        }
        guard call.name == "edit_project_wiki", try !store.agents.limits(current, store: store).readOnly,
              let read = current.wikiEditReads?[path], read.workspace == scope.root, read.identity == identity, read.branch == scope.branch, read.language == language, read.root == view.root, read.pointer == snapshot.pointer, read.read.sha256 == hash, args["expected_hash"] as? String == hash else { throw PetError("Wiki、分支或发布版本已变化，或尚未读取；请重新读取后编辑") }
        let exact = try JSONDecoder().decode(EditText.self, from: Data(call.arguments.utf8))
        guard !exact.old_text.isEmpty, !exact.new_text.contains("\0"), text.components(separatedBy: exact.old_text).count == 2, let span = text.range(of: exact.old_text) else { throw PetError("Wiki 旧文本必须存在且唯一") }
        let first = text.distance(from: text.startIndex, to: span.lowerBound) + 1, last = text.distance(from: text.startIndex, to: span.upperBound)
        guard read.read.covers(first, through: last) else { throw PetError("修改的 Wiki 片段尚未完整读取，请按 next_content_offset 继续读取") }
        let updated = text.replacingCharacters(in: span, with: exact.new_text), data = try document.format.encode(updated)
        guard data != bytes, data.count <= 512_000, updated.utf16.count <= 300_000 else { throw PetError("Wiki 未变化或超过页面上限") }
        let sources = try store.knowledgeCards.sources(args["sources"], task: current), verified = try pageSources(current, file: file, text: updated, retained: snapshot.metadata.sourceHashes)
        guard sources.allSatisfy({ verified[$0.path] == $0.sha256 }) else { throw PetError("核对的源码必须保留在 Wiki 正文行号链接中") }
        return try await store.projectChanges.observe(taskID: task.id, origin: "Wiki 编辑", paths: [file.path]) {
            try Task.checkCancellation()
            guard let latest = store.task(task.id) else { throw PetError("任务已关闭") }; try editingTask(latest, store: store)
            try store.agents.check(call, task: latest, store: store)
            guard try AgentKnowledgeCards.identity(scope.root) == identity, try !store.agents.limits(latest, store: store).readOnly else { throw PetError("项目位置或权限已变化，未写入") }
            _ = try store.knowledgeCards.sources(args["sources"], task: latest)
            try saveEditedPage(snapshot, store: store, taskID: task.id, path: path, data: data)
            store.update(task.id) { $0.wikiEditReads?.removeValue(forKey: path) }
            return try result(["saved": true, "path": path, "language": language, "hash": AgentFiles.hash(data), "previous_hash": hash, "history_saved": true, "note": "已保存，其他页面保留；请回读核对。自动更新不会覆盖手工编辑的 Wiki。"])
        }
    }
    private static func mergedEditRanges(_ input: [[Int]]) -> [[Int]] {
        var output: [[Int]] = []
        for span in input.sorted(by: { $0[0] < $1[0] }) {
            if let previous = output.last, span[0] <= previous[1] + 1 { output[output.count - 1][1] = max(previous[1], span[1]) }
            else { output.append(span) }
        }; return output
    }
}
