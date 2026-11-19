import Foundation

struct AgentBrowserTabReference: Codable, Equatable, Sendable {
    let id: String
    let documentID: UUID
    let url: String
    let title: String

    func identifies(_ page: Self) -> Bool {
        id == page.id && documentID == page.documentID && url == page.url
    }
}

struct AgentBrowserPageSource: Codable, Sendable {
    let tab: AgentBrowserTabReference
    let capturedAt: Date
    let partial: Bool
}

struct AgentBrowserPageSnapshot {
    let source: AgentBrowserPageSource
    let text: String

    @MainActor func attach(store: AgentStore, taskID: String, replacingDraft: @escaping () throws -> (before: String, after: String)) async throws -> AgentAttachment {
        let directory = store.directory.appendingPathComponent(".browser-reference-" + UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let safeTitle = String(source.tab.title.prefix(60)).components(separatedBy: separators).joined(separator: " ")
        let file = directory.appendingPathComponent("网页-" + safeTitle + ".txt")
        let content = source.tab.title + "\n" + source.tab.url + "\n\n" + text
        try Data(content.utf8).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try await AgentAttachments.importFile(file, store: store, taskID: taskID, browserPage: source, replacingDraft: replacingDraft)
    }
}

struct AgentBrowserMention: Equatable {
    let range: NSRange
    let query: String

    init?(in draft: String, selection: NSRange) {
        let text = draft as NSString
        guard selection.length == 0, (0...text.length).contains(selection.location) else { return nil }
        let caret = Range(selection, in: draft)?.lowerBound
        guard let caret, let start = draft[..<caret].suffix(161).lastIndex(of: "@"),
              start == draft.startIndex || draft[draft.index(before: start)].isWhitespace else { return nil }
        let query = draft[draft.index(after: start)..<caret]
        guard !query.contains(where: \.isWhitespace), !query.lowercased().hasPrefix("rule:"),
              caret == draft.endIndex || draft[caret].isWhitespace else { return nil }
        range = NSRange(start..<caret, in: draft)
        self.query = String(query)
    }
}
