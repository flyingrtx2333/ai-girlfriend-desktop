import Foundation

enum AgentSourceLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static func url(_ text: String) throws -> URL {
        guard let value = try? AgentBrowser.url(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw PetError("请输入不含账户密码的 HTTP／HTTPS 链接") }
        var parts = URLComponents(url: value, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme?.lowercased()
        guard let result = parts.url else { throw PetError("请输入 HTTP 或 HTTPS 链接") }; return result
    }
    static func inText(_ text: String) -> [String] {
        guard text.range(of: "http", options: .caseInsensitive) != nil, let detector else { return [] }
        let value = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: value.length)).compactMap { match in
            let candidate = value.substring(with: match.range)
            guard candidate.lowercased().hasPrefix("http://") || candidate.lowercased().hasPrefix("https://") else { return nil }
            return try? url(candidate).absoluteString
        }
    }
}

extension AgentTaskRecord {
    var canAddSources: Bool { !archived && !isProjectDocumentation && kind != "hook" && agent?.ownerID == nil && automation == nil }
    var sourceReferences: [String] {
        let human = messages.filter(\.isHumanInput), known = Set((attachments ?? []).map(\.id))
        let links = human.flatMap { AgentSourceLinks.inText($0.content) }
        let files = human.flatMap { $0.attachmentIDs ?? [] }.filter(known.contains).map { "attachment://\($0)/part/1" }
        var seen = Set<String>(); return (sources + links + files).filter { seen.insert($0).inserted }
    }
}
