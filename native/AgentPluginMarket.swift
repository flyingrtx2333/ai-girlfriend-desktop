import Foundation

struct AgentPluginMarketOrigin: Codable, Equatable {
    let catalog: URL, archive: URL
    let marketplace: String, publisher: String, entry: String

    func matches(_ directory: AgentPluginMarket.Directory, entry: String) -> Bool {
        catalog == directory.address && marketplace == directory.name && self.entry == entry
    }
}

struct AgentPluginMarket {
    struct Entry {
        let name: String, title: String, description: String, author: String, category: String, version: String
        let tags: [String]
        let archive: URL?, digest: String?, unavailable: String?

        var searchable: String { ([name, title, description, author, category] + tags).joined(separator: " ") }
    }

    struct Directory {
        let address: URL, name: String, publisher: String
        let entries: [Entry]
    }

    private struct Cache: Codable {
        let address: URL, catalog: Data
    }

    private let profile: URL, network: URLSession
    private let fixtureOrigin: URL?
    private static let listingLimit = 1_000_000, archiveLimit = 20_000_000
    private static let cachePath = "extensions/plugin-market.json"

    init(profile: URL, network: URLSession? = nil, fixtureOrigin: URL? = nil) {
        self.profile = profile; self.fixtureOrigin = fixtureOrigin
        self.network = network ?? Self.publicSession
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler((try? AgentPluginMarket.publicAddress(request.url)) == nil ? nil : request)
        }
    }

    private static let publicSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    private static func address(_ url: URL?) throws -> URL {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, url.absoluteString.utf8.count <= 4096 else { throw PetError("请输入有效的 HTTPS 地址") }
        return url
    }

    private static func publicAddress(_ url: URL?) throws -> URL {
        let address = try address(url)
        guard (try? AgentWeb.validate(address)) != nil else { throw PetError("插件市场地址不可访问，请核对公开 HTTPS 地址") }
        return address
    }

    private func networkAddress(_ url: URL?) throws -> URL {
        let url = try Self.address(url)
        if let fixtureOrigin, url.host == fixtureOrigin.host, url.port == fixtureOrigin.port { return url }
        return try Self.publicAddress(url)
    }

    private func download(_ url: URL, maximum: Int, accept: String) async throws -> (Data, URL) {
        let initial = try networkAddress(url)
        var request = URLRequest(url: initial, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (stream, response) = try await network.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PetError("市场下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        let final = try networkAddress(http.url)
        guard http.expectedContentLength <= maximum else { throw PetError("市场文件超过下载上限") }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in stream {
            guard data.count < maximum else { throw PetError("市场文件超过下载上限") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, final)
    }

    func cachedDirectory() throws -> Directory? {
        let files = try AgentFiles(workspace: profile.path, followParentLinks: false)
        guard let bytes = try cacheBytes(files) else { return nil }
        let cache = try JSONDecoder().decode(Cache.self, from: bytes)
        return try Self.directory(cache.catalog, address: Self.address(cache.address))
    }

    func refresh(_ address: String) async throws -> Directory {
        let url = try Self.address(URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)))
        let files = try AgentFiles(workspace: profile.path, followParentLinks: false)
        let previous = try cacheBytes(files)
        let (bytes, _) = try await download(url, maximum: Self.listingLimit, accept: "application/json")
        let result = try Self.directory(bytes, address: url)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(Cache(address: url, catalog: bytes))
        if encoded != previous {
            let target = try files.literalURL(Self.cachePath)
            let write = try AgentKnowledgeFileWrite(files: files, path: target.path, data: encoded, expectedHash: previous.map(AgentFiles.hash),
                missing: previous == nil, permissions: 0o600, label: "插件市场目录")
            try write.requireCurrent(); try Task.checkCancellation()
            try files.writeData(encoded, to: write.url, permissions: write.permissions, expectedTarget: write.signature)
        }
        return result
    }

    private func cacheBytes(_ files: AgentFiles) throws -> Data? {
        let target = try files.literalURL(Self.cachePath)
        if try files.entryMetadata(target).kind == "missing" { return nil }
        return try files.readData(target, maximum: 2_000_000)
    }

    @MainActor func prepare(_ entry: Entry, in directory: Directory, scope: String?, plugins: AgentPlugins) async throws -> (AgentPluginPackage, AgentPluginInstallation?) {
        guard let archive = entry.archive, entry.unavailable == nil else { throw PetError(entry.unavailable ?? "此插件没有可用的 ZIP 包") }
        let (bytes, final) = try await download(archive, maximum: Self.archiveLimit, accept: "application/zip, application/octet-stream")
        let digest = AgentFiles.hash(bytes)
        guard entry.digest == nil || entry.digest == digest else { throw PetError("插件包的 SHA-256 与目录不一致，未安装") }
        let origin = AgentPluginMarketOrigin(catalog: directory.address, archive: final, marketplace: directory.name, publisher: directory.publisher, entry: entry.name)
        var package = try await plugins.inspectArchive(bytes, sourceName: directory.name + " · " + (final.host ?? ""), importing: true)
        package.receipt.marketOrigin = origin
        let installations = try plugins.catalog(workspace: scope, onlyScope: true)
        if let prior = installations.first(where: { $0.receipt.marketOrigin?.matches(directory, entry: entry.name) == true }) {
            guard prior.metadata.name == package.metadata.name else { throw PetError("市场包名称与已安装插件不同") }
            guard prior.receipt.hashes != package.receipt.hashes else { throw PetError("插件已是目录中的版本") }
            return (package, prior)
        }
        guard !installations.contains(where: { $0.metadata.name == package.metadata.name }) else { throw PetError("已有其他来源的同名插件，请到已安装列表核对") }
        return (package, nil)
    }

    private static func directory(_ bytes: Data, address: URL) throws -> Directory {
        let object = try AgentConfigurationJSON.object(bytes)
        guard let name = object["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
              let owner = object["owner"] as? [String: Any], let publisher = owner["name"] as? String,
              !publisher.isEmpty, publisher.utf8.count <= 200, let entries = object["plugins"] as? [[String: Any]], entries.count <= 512 else {
            throw PetError("插件目录需要名称、发布者和插件列表")
        }
        var names = Set<String>()
        let result = try entries.map { value -> Entry in
            guard let name = value["name"] as? String, !name.isEmpty, name.utf8.count <= 128, names.insert(name).inserted else {
                throw PetError("市场插件名称无效或重复")
            }
            func text(_ key: String, limit: Int = 200) -> String { String((value[key] as? String ?? "").prefix(limit)) }
            let source = value["source"] as? [String: Any], raw = source?["url"] as? String
            let archive = source?["source"] as? String == "archive" ? (try? Self.address(raw.flatMap(URL.init(string:)))) : nil
            let digest = source?["sha256"] as? String
            let issue: String?
            if archive == nil { issue = "需要 HTTPS ZIP 包" }
            else if source?["sha256"] != nil, digest?.range(of: "^[A-Fa-f0-9]{64}\\z", options: .regularExpression) == nil { issue = "目录中的 SHA-256 无效" }
            else if (value["dependencies"] as? [Any])?.isEmpty == false || (value["headers"] as? [String: Any])?.isEmpty == false || value["strict"] as? Bool == false { issue = "此条目需要额外的依赖或来源配置" }
            else { issue = nil }
            let title = text("displayName")
            let author = value["author"] as? [String: Any]
            return Entry(name: name, title: title.isEmpty ? name : title, description: text("description", limit: 2000),
                author: String((author?["name"] as? String ?? "").prefix(200)), category: text("category", limit: 80), version: text("version", limit: 128),
                tags: Array((value["tags"] as? [String] ?? []).prefix(20)).map { String($0.prefix(80)) },
                archive: archive, digest: digest?.lowercased(), unavailable: issue)
        }
        return Directory(address: address, name: name, publisher: publisher, entries: result)
    }
}
