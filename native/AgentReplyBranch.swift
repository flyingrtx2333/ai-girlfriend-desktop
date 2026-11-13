import Foundation

@MainActor enum AgentReplyBranch {
    static func prefix(_ source: AgentTaskRecord, through messageID: String) throws -> AgentTaskRecord {
        guard !source.isProjectDocumentation, source.kind != "hook", let end = source.messages.firstIndex(where: { $0.id == messageID && $0.isReply }) else { throw PetError("此回复不能创建分支") }
        var task = retained(source, count: end + 1); task.branchMessageID = messageID; return task
    }
    static func before(_ source: AgentTaskRecord, messageID: String) throws -> AgentTaskRecord {
        guard !source.isProjectDocumentation, source.kind != "hook", let end = source.messages.firstIndex(where: { $0.id == messageID && $0.isHumanInput }) else { throw PetError("原始要求已变化") }
        return retained(source, count: end)
    }
    private static func retained(_ source: AgentTaskRecord, count: Int) -> AgentTaskRecord {
        var task = source
        task.messages = Array(source.messages.prefix(count))
        let ids = Set(task.messages.map(\.id)), calls = Dictionary(task.messages.flatMap { $0.toolCalls ?? [] }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        task.events = source.events.filter { $0.toolCallID.map { calls[$0] != nil } == true }
        task.modelReceipts = source.modelReceipts?.filter { $0.purpose == "conversation" && $0.messageID.map(ids.contains) == true }
        task.inputTokens = task.modelReceipts?.reduce(0) { $0 + ($1.inputTokens ?? 0) } ?? 0
        task.outputTokens = task.modelReceipts?.reduce(0) { $0 + ($1.outputTokens ?? 0) } ?? 0
        let attachments = source.attachments ?? [], used = Set(task.messages.flatMap { ($0.attachmentIDs ?? []) + ($0.visuals ?? []).map(\.id) })
        task.attachments = attachments.filter { used.contains($0.id) }; task.draftAttachmentIDs = nil; task.draft = ""
        task.activeSkills = nil; task.toolGroups = nil
        for message in task.messages {
            task.activateExtensions(message)
            if message.role == "tool", let call = message.toolCallID.flatMap({ calls[$0] }), call.name == "unload_skill", task.events.contains(where: { $0.toolCallID == call.id && $0.status == "completed" }), let id = call.object["id"] as? String { task.activeSkills?.removeAll { $0.id == id } }
        }
        var seen: [String: (hash: String, title: String?)] = [:], versions: [String: Set<String>] = [:]
        func observe(_ value: [String: Any]) {
            guard let id = value["id"] as? String, UUID(uuidString: id) != nil, let hash = value["hash"] as? String, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return }
            seen[id] = (hash, value["title"] as? String ?? seen[id]?.title); versions[id, default: []].insert(hash)
            for version in value["versions"] as? [[String: Any]] ?? [] { if let hash = version["hash"] as? String, hash.count == 64, hash.allSatisfy(\.isHexDigit) { versions[id, default: []].insert(hash) } }
        }
        for message in task.messages {
            if message.role == "tool", let call = message.toolCallID.flatMap({ calls[$0] }), AgentCanvas.tools.contains(call.name) {
                var text = message.content
                for status in ["成功", "失败"] { let receipt = "\n[工具调用ID：" + call.id + "；" + status + "]"; if text.hasSuffix(receipt) { text.removeLast(receipt.count); break } }
                if let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                    observe(value); for item in value["canvases"] as? [[String: Any]] ?? [] { observe(item) }
                }
            }
            for id in (message.attachmentIDs ?? []) + (message.visuals ?? []).map(\.id) {
                if let capture = attachments.first(where: { $0.id == id })?.canvasCapture {
                    if seen[capture.canvasID] == nil { observe(["id": capture.canvasID, "hash": capture.sourceHash, "title": capture.title]) }
                    else { versions[capture.canvasID, default: []].insert(capture.sourceHash) }
                }
            }
        }
        task.canvases = (source.canvases ?? []).compactMap { original in
            guard let observed = seen[original.id] else { return nil }; var value = original
            value.hash = observed.hash; value.title = observed.title ?? original.title
            value.versions = original.versions.filter { versions[original.id]?.contains($0.hash) == true }
            value.updated = value.versions.last(where: { $0.hash == observed.hash })?.created ?? original.created
            value.draft = nil; value.draftHash = nil; return value
        }
        task.branchMessageID = nil; task.pinned = false; task.pendingCalls = []; task.queuedInputs = nil; task.queuedMessages = nil
        task.contextSummary = nil; task.contextThroughID = nil; task.contextManualThroughID = nil; task.contextSize = nil; task.contextSnapshot = nil
        task.plan = []; task.artifacts = []; task.sources = []; task.resultHistory = nil; task.importOrigin = nil; task.automation = nil
        task.wikiJob = nil; task.wikiRevision = nil; task.wikiLanguage = nil; task.knowledgeJob = nil; task.wikiEditReads = nil; task.knowledgeReads = nil
        task.skillEvolutionJob = nil; task.skillDraft = nil; task.skillDraftHistory = nil
        task.hookRejectedAnswers = nil; task.hookPromptIDs = nil; task.hookStopBlocks = nil; task.hookCwd = nil
        return task
    }
}
