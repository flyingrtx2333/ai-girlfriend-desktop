import Foundation

struct AgentPluginMarketCredential: Codable {
    let username: String?, token: String

    init(username: String, token: String, requiresUsername: Bool) throws {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        func visibleASCII(_ text: String) -> Bool { text.utf8.allSatisfy { (33...126).contains($0) } }
        guard name.utf8.count <= 256, visibleASCII(name), !name.contains(":"), !requiresUsername || !name.isEmpty else {
            throw PetError("请输入有效的 Git 或 HTTPS 用户名")
        }
        guard !secret.isEmpty, secret.utf8.count <= 2048, visibleASCII(secret) else { throw PetError("请输入有效的访问令牌") }
        self.username = name.isEmpty ? nil : name
        self.token = secret
    }

    var authorization: String {
        if let username { return "Basic " + Data((username + ":" + token).utf8).base64EncodedString() }
        return "Bearer " + token
    }

    // Decode each segment separately so escaped slashes and traversal cannot
    // broaden the directory to which a saved credential may be sent.
    static func path(_ url: URL) -> [String]? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.query == nil, parts.port.map({ (1...65535).contains($0) }) != false,
              parts.percentEncodedPath.hasPrefix("/") else { return nil }
        let segments = parts.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        let decoded = segments.compactMap { $0.removingPercentEncoding }
        let excluded = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\%;"))
        guard decoded.count == segments.count, !decoded.isEmpty, decoded.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.rangeOfCharacter(from: excluded) == nil
        }) else { return nil }
        return decoded
    }

    static func contains(_ url: URL, in catalog: URL) -> Bool {
        guard url.scheme == catalog.scheme, url.host?.lowercased() == catalog.host?.lowercased(),
              (url.port ?? 443) == (catalog.port ?? 443),
              let target = path(url), let source = path(catalog) else { return false }
        let folder = source.dropLast()
        return target.count > folder.count && target.starts(with: folder, by: { $0.utf8.elementsEqual($1.utf8) })
    }
}
