import Foundation
import Darwin

struct AgentPluginMarketGit {
    struct Commit: Codable, Equatable {
        let repository: URL, sha: String
        var label: String { AgentPluginMarketGit.label(repository) + "@" + sha.prefix(12) }
    }

    struct Fixture {
        let origin: URL, certificate: Data
    }

    let profile: URL
    var fixture: Fixture?

    static func address(_ url: URL) -> URL? {
        guard let checked = try? AgentPluginMarket.address(url), checked.query == nil,
              var parts = URLComponents(url: checked, resolvingAgainstBaseURL: false),
              let host = checked.host, !host.hasPrefix("-"), checked.port.map({ (1...65535).contains($0) }) != false,
              checked.path != "/", checked.path.hasPrefix("/"),
              AgentArchive.validPath(String(checked.path.dropFirst())) else { return nil }
        parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        if parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        return parts.url
    }

    static func label(_ url: URL) -> String { (url.host ?? "") + (url.port.map { ":\($0)" } ?? "") + url.path }

    static func sha(_ value: String) -> String? {
        value.range(of: "^[A-Fa-f0-9]{40}([A-Fa-f0-9]{24})?\\z", options: .regularExpression).map { _ in value.lowercased() }
    }

    func directory(_ url: URL, maximum: Int) async throws -> (Data, Commit) {
        try await withRepository(url, ref: nil, pinned: nil) { scratch, commit in
            let paths = [".qoder-plugin/marketplace.json", ".claude-plugin/marketplace.json"]
            let entries = try await local(["ls-tree", "-z", commit.sha, "--"] + paths, in: scratch)
            let files = String(decoding: entries, as: UTF8.self).split(separator: "\0").compactMap { entry -> String? in
                guard entry.hasPrefix("100644 blob ") || entry.hasPrefix("100755 blob "),
                      let tab = entry.firstIndex(of: "\t") else { return nil }
                return String(entry[entry.index(after: tab)...])
            }
            guard let path = paths.first(where: files.contains) else { throw PetError("仓库缺少常规文件格式的插件市场清单") }
            let contents = try await local(["cat-file", "blob", commit.sha + ":" + path], in: scratch, maximum: maximum)
            return (contents, commit)
        }
    }

    func archive(_ url: URL, ref: String?, pinned: String?, folder: String, maximum: Int) async throws -> (Data, Commit) {
        try await withRepository(url, ref: ref, pinned: pinned) { scratch, commit in
            let target = scratch.appendingPathComponent("selected.zip")
            let tree = commit.sha + (folder.isEmpty ? "" : ":" + folder)
            _ = try await local(["archive", "--format=zip", "--prefix=repository/", "--output=" + target.path, tree],
                in: scratch, failure: "无法归档所选 Git 仓库目录")
            let files = try AgentFiles(workspace: scratch.path, followParentLinks: false)
            return (try files.readData(target, maximum: maximum), commit)
        }
    }

    private func withRepository<Value>(_ address: URL, ref: String?, pinned: String?,
                                       use: (URL, Commit) async throws -> Value) async throws -> Value {
        guard let url = Self.address(address), let host = url.host else { throw PetError("请使用不含登录参数的公开 HTTPS Git 地址") }
        let scratch = profile.appendingPathComponent(".plugin-git-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let config = try await run(["help", "--config"], in: scratch, maximum: 200_000, failure: "无法核对 Git 的 HTTPS 能力")
        guard String(decoding: config, as: UTF8.self).split(separator: "\n").contains("http.curloptResolve") else {
            throw PetError("当前 Git 缺少 HTTPS 地址校验支持，请更新 Xcode 命令行工具")
        }
        let network = try networkFlags(url, host: host, scratch: scratch)
        let branch = ref ?? "HEAD"
        let object: String
        if let pinned {
            guard let normalized = Self.sha(pinned) else { throw PetError("Git 提交编号无效") }
            object = normalized
        } else {
            let discovery = try await run(["ls-remote", "--", url.absoluteString, "HEAD", branch], in: scratch, network: network,
                failure: "无法读取 Git 仓库，请检查地址、分支或公开访问权限")
            let refs = String(decoding: discovery, as: UTF8.self).split(separator: "\n")
            guard let first = refs.first, let hash = first.split(separator: "\t").first,
                  let detected = Self.sha(String(hash)) else { throw PetError("Git 仓库没有可读取的分支或标签") }
            object = detected
        }
        let format = object.count == 64 ? "sha256" : "sha1"
        _ = try await run(["init", "--bare", "--quiet", "--template=", "--object-format=" + format, "objects.git"], in: scratch,
            failure: "无法准备 Git 插件目录")
        _ = try await run(["--git-dir=objects.git", "fetch", "--quiet", "--depth=1", "--no-tags", "--no-recurse-submodules",
            "--", url.absoluteString, pinned == nil ? branch : object], in: scratch, network: network,
            failure: "无法读取所选 Git 提交，请核对分支、标签或提交是否可访问")
        let bytes = try await local(["rev-parse", "--verify", "FETCH_HEAD^{commit}"], in: scratch)
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commit = Self.sha(text), pinned == nil || commit == object else { throw PetError("Git 仓库返回的提交与所选版本不一致") }
        return try await use(scratch, Commit(repository: url, sha: commit))
    }

    private func networkFlags(_ url: URL, host: String, scratch: URL) throws -> [String] {
        var options = ["-c", "protocol.https.allow=always"]
        let lookupHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let resolved: [String]
        if let fixture, fixture.origin.host == host, fixture.origin.port == url.port {
            let certificate = scratch.appendingPathComponent("fixture-ca.pem")
            try fixture.certificate.write(to: certificate)
            options += ["-c", "http.sslCAInfo=" + certificate.path]
            resolved = ["127.0.0.1"]
        } else {
            do { resolved = try AgentWeb.publicAddresses(lookupHost) }
            catch { throw PetError("Git 仓库地址不可访问，请核对公开 HTTPS 地址") }
        }
        if lookupHost.contains(":") { return options }
        let addresses = resolved.map { $0.contains(":") ? "[" + $0 + "]" : $0 }
        return options + ["-c", "http.curloptResolve=\(host):\(url.port ?? 443):\(addresses.joined(separator: ","))"]
    }

    private func local(_ args: [String], in scratch: URL, maximum: Int = 100_000, failure: String = "无法读取所选 Git 文件") async throws -> Data {
        try await run(["--git-dir=objects.git"] + args, in: scratch, maximum: maximum, failure: failure)
    }

    private func run(_ args: [String], in scratch: URL, network: [String] = [], maximum: Int = 100_000, failure: String) async throws -> Data {
        let git = try AgentGit.executablePath()
        let flags = ["--no-pager", "--literal-pathspecs", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never",
            "-c", "http.followRedirects=false", "-c", "http.sslVerify=true", "-c", "http.proxy=", "-c", "credential.helper=",
            "-c", "credential.interactive=false", "-c", "fetch.fsckObjects=true", "-c", "fetch.unpackLimit=0",
            "-c", "fetch.writeCommitGraph=false", "-c", "maintenance.auto=false", "-c", "gc.auto=0"]
        // Apply a 64 MiB per-file cap before Git reads any network objects.
        let argv = ["-c", "ulimit -f 65536 && exec \"$@\"", "market-git", git] + flags + network + args
        let result = try await AgentCommand().run(command: "/bin/sh", workspace: scratch, scratch: scratch,
            network: !network.isEmpty, timeout: network.isEmpty ? 10 : 45, maximumOutput: maximum, protectedData: profile,
            environment: ["GIT_ASKPASS": "/usr/bin/false", "GIT_CONFIG_NOSYSTEM": "1"], arguments: argv)
        if result.timedOut == true { throw PetError("读取 Git 仓库超时，请稍后重试") }
        if result.truncated == true { throw PetError("Git 仓库文件超过可读上限") }
        if result.failed || result.stdoutData == nil {
            let diagnostic = (result.stderr ?? "").lowercased()
            if diagnostic.contains("certificate") || diagnostic.contains("ssl connect") {
                throw PetError("Git 仓库的 HTTPS 证书校验失败，请核对地址")
            }
            if result.exitCode == 128 + Int(SIGXFSZ) || diagnostic.contains("file size limit") {
                throw PetError("Git 仓库的数据超过本机读取上限")
            }
            throw PetError(failure)
        }
        return result.stdoutData ?? Data()
    }
}
