import Foundation

enum AgentTaskSearch {
    struct Candidate: Sendable { var id: String, version: String, title: String }
    struct Hit: Sendable { var messageID: String, role: String, excerpt: String }
    struct Result: Sendable {
        var hits: [String: Hit] = [:], checked: [String: String] = [:], issues: [String: String] = [:]
    }
    static func message(in record: AgentTaskRecord, query: String, preferredID: String? = nil) -> AgentMessage? {
        guard !query.isEmpty else { return nil }
        func matches(_ message: AgentMessage) -> Bool {
            (message.isHumanInput || message.role == "assistant" && message.nativeContext != true) && message.content.localizedCaseInsensitiveContains(query)
        }
        if let preferredID, let message = record.messages.first(where: { $0.id == preferredID }), matches(message) { return message }
        return record.messages.reversed().first(where: matches)
    }
    static func excerpt(_ text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive, locale: .current) else { return String(text.prefix(90)).replacingOccurrences(of: "\n", with: " ") }
        let start = range.lowerBound
        let end = text.index(start, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end == text.endIndex ? "" : "…")
    }
    static func find(_ query: String, candidates: [Candidate], directory: URL) async -> Result {
        // ponytail: scan changed records only while searching; add a disk index if real history volume makes this slow.
        let worker = Task.detached(priority: .userInitiated) { () -> Result in
            var result = Result()
            for candidate in candidates {
                if Task.isCancelled { break }
                result.checked[candidate.id] = candidate.version
                do {
                    guard UUID(uuidString: candidate.id) != nil else { throw PetError("任务编号无效") }
                    let files = try AgentFiles(workspace: directory.path)
                    let bytes = try files.readData(files.literalURL(candidate.id + ".json"), maximum: 20_000_000)
                    let record = try JSONDecoder().decode(AgentTaskRecord.self, from: bytes)
                    guard record.id == candidate.id else { throw PetError("任务编号不匹配") }
                    if let message = message(in: record, query: query) {
                        result.hits[candidate.id] = Hit(messageID: message.id, role: message.role, excerpt: excerpt(message.content, query: query))
                    }
                } catch { result.issues[candidate.id] = candidate.title + "：" + error.localizedDescription }
            }
            return result
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
}
