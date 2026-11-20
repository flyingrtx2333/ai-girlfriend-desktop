import Foundation

struct AgentPluginMarketOrigin: Codable, Equatable {
    let catalog: URL, archive: URL
    let marketplace: String, publisher: String, entry: String
    let commit: AgentPluginMarketCommit?, repositoryPath: String?
    var gitCommit: AgentPluginMarketGit.Commit? = nil

    var sourceName: String {
        ([marketplace, commit?.label ?? gitCommit?.label ?? archive.host ?? "", repositoryPath ?? ""])
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func matches(_ directory: AgentPluginMarket.Directory, entry: String) -> Bool {
        catalog == directory.address && marketplace == directory.name && self.entry == entry
    }
}

struct AgentPluginMarket {
    struct Entry {
        let name: String, title: String, description: String, author: String, category: String, version: String
        let tags: [String]
        let source: Source?, unavailable: String?

        var searchable: String { ([name, title, description, author, category, source?.label ?? ""] + tags).joined(separator: " ") }
    }

    struct Directory {
        let address: URL, name: String, publisher: String
        let entries: [Entry]
    }

    struct Catalogs {
        var directories: [Directory] = []
        var selection: URL?
        var selected: Directory? { directories.first { $0.address == selection } }
    }

    private struct Cache: Codable, Equatable {
        let address: URL, catalog: Data
        let commit: AgentPluginMarketCommit?
        var gitCommit: AgentPluginMarketGit.Commit? = nil

        func directory() throws -> Directory {
            if let commit {
                guard AgentPluginMarketRepository(address: address) == commit.repository,
                      AgentPluginMarketRepository.commit(commit.sha) == commit.sha else {
                    throw PetError("已保存的市场仓库来源无效")
                }
            }
            if let gitCommit {
                guard commit == nil, AgentPluginMarket.gitRepository(for: address) == gitCommit.repository,
                      AgentPluginMarketGit.sha(gitCommit.sha) == gitCommit.sha else {
                    throw PetError("已保存的 Git 市场来源无效")
                }
            }
            if address.scheme == "ssh", gitCommit == nil { throw PetError("已保存的 SSH 市场缺少提交") }
            return try AgentPluginMarket.directory(catalog, address: AgentPluginMarket.savedAddress(address), commit: commit, gitCommit: gitCommit)
        }
    }

    private struct Index: Codable {
        var selection: URL?
        var items: [Cache] = []

        func catalogs() throws -> Catalogs {
            Catalogs(directories: try items.map { try $0.directory() }, selection: selection)
        }
    }

    private struct HTTPFailure: LocalizedError {
        let status: Int
        let authenticated: Bool
        var errorDescription: String? {
            if status == 401 || (authenticated && status == 403) { return "市场拒绝访问（HTTP \(status)）。请检查访问凭据和读取权限。" }
            if authenticated && (300..<400).contains(status) { return "此地址会跳转，请填写市场文件的最终 HTTPS 地址。" }
            return "市场下载失败（HTTP \(status)）。请核对地址或稍后重试。"
        }
    }

    private let profile: URL, network: URLSession
    private let fixtureOrigin: URL?
    private let git: AgentPluginMarketGit
    private static let listingLimit = 1_000_000, archiveLimit = 20_000_000
    private static let catalogLimit = 12
    private static let cachePath = "extensions/plugin-markets.json"
    private static let legacyCachePath = "extensions/plugin-market.json"

    init(profile: URL, network: URLSession? = nil, fixtureOrigin: URL? = nil, gitFixture: AgentPluginMarketGit.Fixture? = nil,
         sshFixture: AgentPluginMarketGit.SSHFixture? = nil) {
        self.profile = profile; self.fixtureOrigin = fixtureOrigin
        self.network = network ?? Self.publicSession
        self.git = AgentPluginMarketGit(profile: profile, fixture: gitFixture, sshFixture: sshFixture)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            if task.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil {
                completionHandler(nil)
                return
            }
            if task.originalRequest?.url?.host == "api.github.com",
               request.url.map({ $0.port == nil && ["api.github.com", "codeload.github.com"].contains($0.host ?? "") }) != true {
                completionHandler(nil)
                return
            }
            completionHandler((try? AgentPluginMarket.publicAddress(request.url)) == nil ? nil : request)
        }
    }

    private static let publicSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    static func address(_ url: URL?) throws -> URL {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, url.absoluteString.utf8.count <= 4096 else { throw PetError("请输入有效的 HTTPS 地址") }
        return url
    }

    private static func catalogAddress(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let repository = AgentPluginMarketGit.address(text), repository.scheme == "ssh" { return repository }
        let url: URL
        do { url = try address(URL(string: text)) }
        catch { throw PetError("请输入有效的 HTTPS 目录或 HTTPS／SSH Git 地址") }
        if let repository = AgentPluginMarketRepository(address: url) { return repository.address }
        if url.path.lowercased().hasSuffix(".git") {
            guard let repository = AgentPluginMarketGit.address(url) else { throw PetError("请填写不含登录参数的 HTTPS Git 地址") }
            return repository
        }
        return url
    }

    static func savedAddress(_ url: URL) throws -> URL {
        if url.scheme == "ssh", AgentPluginMarketGit.address(url) == url { return url }
        return try address(url)
    }

    static func gitRepository(for address: URL) -> URL? {
        if address.scheme == "ssh" { return AgentPluginMarketGit.address(address) }
        return AgentPluginMarketRepository(address: address)?.cloneAddress
            ?? (address.path.lowercased().hasSuffix(".git") ? AgentPluginMarketGit.address(address) : nil)
    }

    static func credentialDestination(_ input: String) throws -> URL {
        let target = try catalogAddress(input)
        if target.scheme == "ssh" { throw PetError("SSH 仓库使用本机 SSH 代理与已知主机记录。") }
        guard AgentPluginMarketCredential.path(target) != nil else { throw PetError("请填写不含查询参数的 HTTPS 目录文件或 Git 仓库地址") }
        return target
    }

    private var credentialConfig: PetCredentialConfig { .init(file: profile.appendingPathComponent("credentials.json")) }

    private func credentialAccount(_ address: URL) -> String {
        "plugin-market-" + AgentFiles.hash(Data(address.absoluteString.utf8))
    }

    func credential(for address: URL) throws -> AgentPluginMarketCredential? {
        guard address.scheme == "https" else { return nil }
        guard let stored = try credentialConfig.value(credentialAccount(address)) else { return nil }
        guard let item = try? JSONDecoder().decode(AgentPluginMarketCredential.self, from: Data(stored.utf8)),
              let value = try? AgentPluginMarketCredential(username: item.username ?? "", token: item.token,
                  requiresUsername: Self.gitRepository(for: address) != nil) else {
            throw PetError("该市场的访问凭据无法读取，请重新保存。")
        }
        return value
    }

    @MainActor func saveCredential(_ value: AgentPluginMarketCredential?, for address: URL) throws {
        let destination = try Self.credentialDestination(address.absoluteString)
        if let value, value.username == nil, Self.gitRepository(for: destination) != nil {
            throw PetError("请填写 Git 用户名。")
        }
        let stored = try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try credentialConfig.write(stored, account: credentialAccount(destination))
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

    private func download(_ url: URL, maximum: Int, accept: String, credential: AgentPluginMarketCredential? = nil) async throws -> (Data, URL) {
        let initial = try networkAddress(url)
        var request = URLRequest(url: initial, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("BlueFatFish", forHTTPHeaderField: "User-Agent")
        request.setValue(credential?.authorization, forHTTPHeaderField: "Authorization")
        let delegate = network.delegate as? URLSessionTaskDelegate
        do {
            let (stream, response) = try await network.bytes(for: request, delegate: delegate)
            defer { stream.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw PetError("市场未返回有效响应") }
            guard (200..<300).contains(http.statusCode) else { throw HTTPFailure(status: http.statusCode, authenticated: credential != nil) }
            let final = try networkAddress(http.url)
            guard credential == nil || final == initial else { throw PetError("请填写市场文件的最终 HTTPS 地址。") }
            guard http.expectedContentLength <= maximum else { throw PetError("市场文件超过下载上限") }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in stream {
                guard data.count < maximum else { throw PetError("市场文件超过下载上限") }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, final)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw PetError("加载市场超时，请稍后重试")
            case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed:
                throw PetError("市场的 HTTPS 证书校验失败，请核对地址")
            default: throw PetError("无法连接插件市场，请检查网络或地址后重试")
            }
        }
    }

    func cachedCatalogs() throws -> Catalogs {
        let files = try AgentFiles(workspace: profile.path, followParentLinks: false)
        return try readIndex(files).index.catalogs()
    }

    func refresh(_ address: String) async throws -> Catalogs {
        let key = try Self.catalogAddress(address)
        let credential = try credential(for: key)
        let files = try AgentFiles(workspace: profile.path, followParentLinks: false)
        let original = try readIndex(files).index.items.first { $0.address == key }
        let fetched: Cache
        if let repository = AgentPluginMarketRepository(address: key), credential == nil {
            let commit = try await resolve(repository, ref: nil)
            let manifest = try await repositoryDirectory(commit)
            fetched = Cache(address: key, catalog: manifest, commit: commit)
        } else if let gitAddress = Self.gitRepository(for: key) {
            let (manifest, commit) = try await git.directory(gitAddress, maximum: Self.listingLimit, credential: credential)
            fetched = Cache(address: key, catalog: manifest, commit: nil, gitCommit: commit)
        } else {
            let (bytes, _) = try await download(key, maximum: Self.listingLimit, accept: "application/json", credential: credential)
            fetched = Cache(address: key, catalog: bytes, commit: nil)
        }
        _ = try fetched.directory()
        return try await register(fetched, replacing: original, files: files)
    }

    @MainActor private func register(_ fetched: Cache, replacing original: Cache?, files: AgentFiles) throws -> Catalogs {
        let key = fetched.address
        let current = try readIndex(files)
        var index = current.index
        if let position = index.items.firstIndex(where: { $0.address == key }) {
            guard original == index.items[position] || fetched == index.items[position] else { throw Self.changedCatalog }
            index.items[position] = fetched
        } else {
            guard original == nil else { throw Self.changedCatalog }
            guard index.items.count < Self.catalogLimit else { throw PetError("最多保存 \(Self.catalogLimit) 个目录，请先移除一个目录") }
            index.items.append(fetched)
        }
        index.selection = key
        return try save(index, files: files, previous: current.bytes)
    }

    @MainActor func select(_ address: URL) throws -> Catalogs {
        let files = try AgentFiles(workspace: profile.path, followParentLinks: false)
        let current = try readIndex(files)
        guard current.index.items.contains(where: { $0.address == address }) else { throw Self.changedCatalog }
        var index = current.index
        index.selection = address
        return try save(index, files: files, previous: current.bytes)
    }

    @MainActor func remove(_ address: URL) throws -> Catalogs {
        let files = try AgentFiles(workspace: profile.path, followParentLinks: false)
        let current = try readIndex(files)
        var index = current.index
        guard let offset = index.items.firstIndex(where: { $0.address == address }) else { throw Self.changedCatalog }
        index.items.remove(at: offset)
        if index.selection == address { index.selection = index.items.first?.address }
        return try save(index, files: files, previous: current.bytes)
    }

    private static var changedCatalog: PetError { PetError("该目录已在另一窗口更改，请重新打开插件市场") }

    private func save(_ index: Index, files: AgentFiles, previous: Data?) throws -> Catalogs {
        let catalogs = try index.catalogs()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(index)
        if encoded != previous {
            let target = try files.literalURL(Self.cachePath)
            let write = try AgentKnowledgeFileWrite(files: files, path: target.path, data: encoded, expectedHash: previous.map(AgentFiles.hash),
                missing: previous == nil, permissions: 0o600, label: "插件市场目录")
            try write.requireCurrent(); try Task.checkCancellation()
            try files.writeData(encoded, to: write.url, permissions: write.permissions, expectedTarget: write.signature)
        }
        return catalogs
    }

    private func readIndex(_ files: AgentFiles) throws -> (index: Index, bytes: Data?) {
        let target = try files.literalURL(Self.cachePath)
        let decoder = JSONDecoder()
        if try files.entryMetadata(target).kind == "missing" {
            let legacy = try files.literalURL(Self.legacyCachePath)
            if try files.entryMetadata(legacy).kind == "missing" { return (Index(), nil) }
            let previous = try decoder.decode(Cache.self, from: files.readData(legacy, maximum: 2_000_000))
            return (Index(selection: previous.address, items: [previous]), nil)
        }
        let bytes = try files.readData(target, maximum: 17_000_000)
        let index = try decoder.decode(Index.self, from: bytes)
        let addresses = Set(index.items.map(\.address))
        guard index.items.count <= Self.catalogLimit, index.items.count == addresses.count,
              index.selection.map(addresses.contains) ?? addresses.isEmpty else { throw PetError("已保存的市场目录索引无效") }
        return (index, bytes)
    }

    private func api(_ repository: AgentPluginMarketRepository, path: [String], ref: String? = nil) -> URL {
        let base = fixtureOrigin ?? URL(string: "https://api.github.com")!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let segments = ["repos", repository.owner, repository.name] + path
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        url.percentEncodedPath = "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        if let ref { url.queryItems = [URLQueryItem(name: "ref", value: ref)] }
        return url.url!
    }

    private func resolve(_ repository: AgentPluginMarketRepository, ref: String?) async throws -> AgentPluginMarketCommit {
        let (bytes, _) = try await download(api(repository, path: ["commits", ref ?? "HEAD"]), maximum: 256, accept: "application/vnd.github.sha")
        let response = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sha = AgentPluginMarketRepository.commit(response) else {
            throw PetError("GitHub 未返回有效的提交编号")
        }
        return AgentPluginMarketCommit(repository: repository, sha: sha)
    }

    private func repositoryDirectory(_ commit: AgentPluginMarketCommit) async throws -> Data {
        func manifest(in folder: String) async throws -> Data {
            let url = api(commit.repository, path: ["contents", folder, "marketplace.json"], ref: commit.sha)
            return try await download(url, maximum: Self.listingLimit, accept: "application/vnd.github.raw+json").0
        }
        do { return try await manifest(in: ".qoder-plugin") }
        catch let error as HTTPFailure where error.status == 404 {
            do { return try await manifest(in: ".claude-plugin") }
            catch let error as HTTPFailure where error.status == 404 { throw PetError("仓库缺少插件市场清单") }
        }
    }

    @MainActor func prepare(_ entry: Entry, in directory: Directory, scope: String?, plugins: AgentPlugins) async throws -> (AgentPluginPackage, AgentPluginInstallation?) {
        guard let source = entry.source, entry.unavailable == nil else { throw PetError(entry.unavailable ?? "此插件没有可用来源") }
        let bytes: Data, final: URL
        var commit: AgentPluginMarketCommit?, gitCommit: AgentPluginMarketGit.Commit?, path: String?
        let acceptedTypes = "application/zip, application/octet-stream"
        let credential = try credential(for: directory.address)
        let catalogRepository = Self.gitRepository(for: directory.address)
        switch source {
        case let .archive(url, digest):
            let scoped = catalogRepository == nil && AgentPluginMarketCredential.contains(url, in: directory.address) ? credential : nil
            (bytes, final) = try await download(url, maximum: Self.archiveLimit, accept: acceptedTypes, credential: scoped)
            if let digest, digest != AgentFiles.hash(bytes) { throw PetError("插件包的 SHA-256 与目录不一致，未安装") }
        case let .repository(repository, ref, sha, location) where repository.cloneAddress == catalogRepository && credential != nil:
            let (archive, verified) = try await git.archive(repository.cloneAddress, ref: ref, pinned: sha, folder: location,
                maximum: Self.archiveLimit, credential: credential)
            bytes = archive
            final = verified.repository
            gitCommit = verified
            path = location
        case let .repository(repository, ref, sha, location):
            let verified: AgentPluginMarketCommit
            if let sha { verified = AgentPluginMarketCommit(repository: repository, sha: sha) }
            else { verified = try await resolve(repository, ref: ref) }
            let archive = api(repository, path: ["zipball", verified.sha])
            (bytes, final) = try await download(archive, maximum: Self.archiveLimit, accept: acceptedTypes)
            commit = verified
            path = location
        case let .git(url, ref, sha, location):
            guard url.scheme != "ssh" || url == catalogRepository else { throw PetError(Self.separateSSHRepository) }
            let (archive, verified) = try await git.archive(url, ref: ref, pinned: sha, folder: location,
                maximum: Self.archiveLimit, credential: url == catalogRepository ? credential : nil)
            bytes = archive
            final = verified.repository
            gitCommit = verified
            path = location
        }
        // Download query parameters can contain temporary access signatures.
        // The provenance retains the final host and path used for review.
        var provenance = URLComponents(url: final, resolvingAgainstBaseURL: false)
        provenance?.percentEncodedQuery = nil
        let origin = AgentPluginMarketOrigin(catalog: directory.address, archive: provenance?.url ?? final, marketplace: directory.name,
            publisher: directory.publisher, entry: entry.name, commit: commit, repositoryPath: path, gitCommit: gitCommit)
        var package = try await plugins.inspectArchive(bytes, sourceName: origin.sourceName, importing: true,
            repositoryPath: gitCommit == nil ? path : "")
        guard (commit == nil && gitCommit == nil) || package.metadata.name == entry.name else { throw PetError("仓库插件名称与市场目录不一致") }
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

    static let separateSSHRepository = "请先将该 SSH 仓库直接添加为市场目录。"

    private static func directory(_ bytes: Data, address: URL, commit: AgentPluginMarketCommit?, gitCommit: AgentPluginMarketGit.Commit?) throws -> Directory {
        let object = try AgentConfigurationJSON.object(bytes)
        guard let name = object["name"] as? String, !name.isEmpty, name.utf8.count <= 128,
              let owner = object["owner"] as? [String: Any], let publisher = owner["name"] as? String,
              !publisher.isEmpty, publisher.utf8.count <= 200, let entries = object["plugins"] as? [[String: Any]], entries.count <= 512 else {
            throw PetError("插件目录需要名称、发布者和插件列表")
        }
        let pluginRoot = (object["metadata"] as? [String: Any])?["pluginRoot"]
        var names = Set<String>()
        let result = try entries.map { value -> Entry in
            guard let name = value["name"] as? String, !name.isEmpty, name.utf8.count <= 128, names.insert(name).inserted else {
                throw PetError("市场插件名称无效或重复")
            }
            func text(_ key: String, limit: Int = 200) -> String { String((value[key] as? String ?? "").prefix(limit)) }
            let source: Source?, issue: String?
            do {
                if (value["dependencies"] as? [Any])?.isEmpty == false || (value["headers"] as? [String: Any])?.isEmpty == false || value["strict"] as? Bool == false {
                    throw PetError("此条目需要额外的依赖或来源配置")
                }
                source = try Source.parse(value["source"], directory: commit, gitDirectory: gitCommit, pluginRoot: pluginRoot)
                issue = nil
            } catch {
                source = nil
                issue = error.localizedDescription
            }
            let title = text("displayName")
            let author = value["author"] as? [String: Any]
            return Entry(name: name, title: title.isEmpty ? name : title, description: text("description", limit: 2000),
                author: String((author?["name"] as? String ?? "").prefix(200)), category: text("category", limit: 80), version: text("version", limit: 128),
                tags: Array((value["tags"] as? [String] ?? []).prefix(20)).map { String($0.prefix(80)) },
                source: source, unavailable: issue)
        }
        return Directory(address: address, name: name, publisher: publisher, entries: result)
    }
}
