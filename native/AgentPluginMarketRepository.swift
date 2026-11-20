import Foundation

struct AgentPluginMarketRepository: Codable, Equatable {
    let owner: String, name: String

    var slug: String { owner + "/" + name }
    var address: URL { URL(string: "https://github.com/" + slug)! }

    init?(_ slug: String) {
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]), spelling = String(parts[1])
        let name = spelling.lowercased().hasSuffix(".git") ? String(spelling.dropLast(4)) : spelling
        guard owner.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}\\z", options: .regularExpression) != nil,
              name.range(of: "^[A-Za-z0-9_.-]{1,100}\\z", options: .regularExpression) != nil,
              name != ".", name != ".." else { return nil }
        self.owner = owner.lowercased()
        self.name = name.lowercased()
    }

    init?(address: URL) {
        guard address.scheme == "https", address.host?.lowercased() == "github.com",
              address.port == nil || address.port == 443, address.user == nil, address.password == nil,
              address.query == nil, address.fragment == nil else { return nil }
        self.init(address.pathComponents.dropFirst().joined(separator: "/"))
    }

    static func commit(_ value: String) -> String? {
        value.range(of: "^[A-Fa-f0-9]{40}\\z", options: .regularExpression).map { _ in value.lowercased() }
    }

    static func ref(_ value: String) -> String? {
        guard value.utf8.count <= 255, !value.isEmpty, !value.hasPrefix("-"), !value.hasSuffix("."),
              !value.contains(".."), !value.contains("@{"), value != "@",
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "~^:?*[\\%"))) == nil,
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }) else { return nil }
        return value
    }

    static func folder(_ value: String) throws -> String {
        if value == "." || value == "./" { return "" }
        let relative = value.hasPrefix("./") ? String(value.dropFirst(2)) : value
        let path = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
        guard path.utf8.count <= 500, AgentArchive.validPath(path) else { throw PetError("仓库中的插件路径无效") }
        return path
    }
}

struct AgentPluginMarketCommit: Codable, Equatable {
    let repository: AgentPluginMarketRepository
    let sha: String

    var label: String { repository.slug + "@" + sha.prefix(12) }
}

extension AgentPluginMarket {
    enum Source {
        case archive(URL, digest: String?)
        case repository(AgentPluginMarketRepository, ref: String?, sha: String?, path: String)

        var label: String {
            switch self {
            case let .archive(url, _): return url.host ?? ""
            case let .repository(repository, _, _, _): return repository.slug
            }
        }

        func matches(_ receipt: AgentPluginReceipt) -> Bool {
            switch self {
            case let .archive(_, digest):
                return digest == receipt.sourceHash
            case let .repository(repository, _, sha, path):
                guard let sha else { return false }
                return receipt.marketOrigin?.commit == AgentPluginMarketCommit(repository: repository, sha: sha)
                    && receipt.marketOrigin?.repositoryPath == path
            }
        }

        static func parse(_ value: Any?, directory: AgentPluginMarketCommit?, pluginRoot: Any?) throws -> Self {
            if let relative = value as? String {
                guard let directory else { throw PetError("相对路径需要 GitHub 仓库目录") }
                var path = try AgentPluginMarketRepository.folder(relative)
                if relative != ".", !relative.hasPrefix("./") {
                    guard let parent = pluginRoot as? String, !path.contains("/") else { throw PetError("相对插件路径须以 ./ 开头") }
                    let root = try AgentPluginMarketRepository.folder(parent)
                    if !root.isEmpty { path = root + "/" + path }
                }
                return .repository(directory.repository, ref: nil, sha: directory.sha, path: path)
            }
            guard let object = value as? [String: Any], let type = object["source"] as? String else {
                throw PetError("需要 HTTPS ZIP 或 GitHub 仓库")
            }
            if type == "archive" {
                let url = try AgentPluginMarket.address((object["url"] as? String).flatMap(URL.init(string:)))
                let digest = object["sha256"] as? String
                if object["sha256"] != nil, digest?.range(of: "^[A-Fa-f0-9]{64}\\z", options: .regularExpression) == nil {
                    throw PetError("目录中的 SHA-256 无效")
                }
                return .archive(url, digest: digest?.lowercased())
            }
            var repository: AgentPluginMarketRepository?
            var path = ""
            switch type {
            case "github":
                repository = (object["repo"] as? String).flatMap(AgentPluginMarketRepository.init)
            case "url", "git", "git-subdir":
                if let value = object["url"] as? String {
                    repository = URL(string: value).flatMap(AgentPluginMarketRepository.init(address:))
                    if type == "git-subdir", repository == nil { repository = AgentPluginMarketRepository(value) }
                }
                if type == "git-subdir" {
                    guard let folder = object["path"] as? String else { throw PetError("仓库来源需要插件目录路径") }
                    path = try AgentPluginMarketRepository.folder(folder)
                }
            default:
                throw PetError("需要 HTTPS ZIP 或 GitHub 仓库")
            }
            guard let repository else { throw PetError("需要公开 GitHub 仓库") }
            let ref = (object["ref"] as? String).flatMap(AgentPluginMarketRepository.ref)
            let sha = (object["sha"] as? String).flatMap(AgentPluginMarketRepository.commit)
            guard (object["ref"] == nil || ref != nil), (object["sha"] == nil || sha != nil) else {
                throw PetError("仓库分支、标签或提交编号无效")
            }
            return .repository(repository, ref: ref, sha: sha, path: path)
        }
    }
}
