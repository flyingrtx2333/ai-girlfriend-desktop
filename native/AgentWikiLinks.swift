import Foundation
import JavaScriptCore

@MainActor enum AgentWikiLinks {
    private struct Destination: Decodable { let start: Int, end: Int; let url: String; let html: Bool }
    private static var runtime: JSContext?
    private static func destinations(_ source: String) throws -> [Destination] {
        if runtime == nil {
            guard let context = JSContext(), let file = Bundle.main.url(forResource: "runtime", withExtension: "js", subdirectory: "web/wiki") else { throw PetError("Wiki 链接解析器不可用") }
            context.evaluateScript(try String(contentsOf: file, encoding: .utf8))
            guard context.exception == nil else { throw PetError("Wiki 链接解析器未能载入") }; runtime = context
        }
        let context = runtime!; context.exception = nil
        let value = context.objectForKeyedSubscript("BlueFatFishWikiYAML")?.objectForKeyedSubscript("linkDestinations")?.call(withArguments: [source])
        guard context.exception == nil, let text = value?.toString(), text.utf8.count <= 4_000_000 else { throw PetError("Wiki 页面链接无法解析或超过处理上限") }
        return try JSONDecoder().decode([Destination].self, from: Data(text.utf8))
    }
    static func localTargets(_ data: Data, document: URL, files: AgentFiles) throws -> [URL] {
        try destinations(AgentTextFile.decode(data).text).compactMap { item in
            guard let link = URL(string: item.url), link.scheme == nil || link.scheme?.lowercased() == "file", link.host == nil || link.host == "" || link.host == "localhost" else { return nil }
            return try AgentMarkdownDocument.target(link, document: document, files: files)
        }
    }
    static func rewrite(_ data: Data, from original: URL, to destination: URL, files: AgentFiles, pages: [String: URL]) throws -> Data {
        let decoded = try AgentTextFile.decode(data), targets = try destinations(decoded.text)
        var text = decoded.text, previous = text.utf16.count
        for item in targets.reversed() {
            guard item.start >= 0, item.end >= item.start, item.end <= previous, let span = Range(NSRange(location: item.start, length: item.end - item.start), in: text) else { throw PetError("Wiki 链接位置无效") }; previous = item.start
            guard let link = URL(string: item.url) else { throw PetError("Wiki 链接无法解析：" + original.lastPathComponent) }
            if let scheme = link.scheme, scheme.lowercased() != "file" { continue }
            if let host = link.host, !host.isEmpty, host != "localhost" { continue }
            let source = try AgentMarkdownDocument.target(link, document: original, files: files)
            let target = pages[source.path] ?? source
            var components = URLComponents(url: target, resolvingAgainstBaseURL: false)!; components.fragment = AgentMarkdownDocument.fragment(source)
            guard let exact = components.url else { throw PetError("Wiki 链接目标无效") }
            // Relative links between unchanged page names need no rewriting.
            if link.scheme == nil, !item.url.hasPrefix("/"), (try? AgentMarkdownDocument.target(link, document: destination, files: files)) == exact { continue }
            let a = destination.deletingLastPathComponent().pathComponents, b = target.pathComponents
            var common = 0; while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
            let path = (Array(repeating: "..", count: a.count - common) + b.dropFirst(common)).joined(separator: "/")
            var pathCharacters = CharacterSet.urlPathAllowed; pathCharacters.remove(charactersIn: "%&()<>\\\"'` \r\n\t?#[]")
            var fragmentCharacters = CharacterSet.urlFragmentAllowed; fragmentCharacters.remove(charactersIn: "%&()<>\\\"'` \r\n\t#[]")
            guard var replacement = path.addingPercentEncoding(withAllowedCharacters: pathCharacters) else { throw PetError("Wiki 链接路径无法编码") }
            if let fragment = components.fragment { replacement += "#" + (fragment.addingPercentEncoding(withAllowedCharacters: fragmentCharacters) ?? "") }
            if item.html { replacement = replacement.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;") }
            text.replaceSubrange(span, with: replacement)
        }
        return try decoded.format.encode(text)
    }
}
