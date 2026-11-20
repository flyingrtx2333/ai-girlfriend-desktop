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
    struct SSHFixture {
        let repository: URL, knownHosts: URL
    }

    let profile: URL
    var fixture: Fixture?
    var sshFixture: SSHFixture? = nil

    static func address(_ input: String) -> URL? {
        guard input.utf8.count <= 4096, input.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if input.contains("://") { return URL(string: input).flatMap(address) }
        // A scp-style relative path is relative to the login directory.
        // Preserve that meaning when storing the equivalent SSH URL.
        let authorityEnd = input.firstIndex(of: "]").map { input.index(after: $0) } ?? input.startIndex
        guard let colon = input[authorityEnd...].firstIndex(of: ":"), colon != input.startIndex,
              !input[..<colon].contains("/"),
              var parts = URLComponents(string: "ssh://" + input[..<colon]),
              parts.path.isEmpty else { return nil }
        let path = String(input[input.index(after: colon)...])
        guard !path.isEmpty, !path.hasPrefix(":") else { return nil }
        parts.path = path.hasPrefix("/") ? path : (path.hasPrefix("~") ? "/" : "/~/") + path
        return parts.url.flatMap(address)
    }

    static func address(_ url: URL) -> URL? {
        if url.scheme?.lowercased() == "ssh" { return sshAddress(url) }
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

    private static func sshAddress(_ url: URL) -> URL? {
        guard url.absoluteString.utf8.count <= 4096,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, host.range(of: #"^(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])\z"#, options: .regularExpression) != nil,
              parts.user.map({ $0.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z"#, options: .regularExpression) != nil }) != false,
              parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) != false,
              parts.path.hasPrefix("/"), parts.path.rangeOfCharacter(from: .controlCharacters) == nil,
              AgentArchive.validPath(String(parts.path.dropFirst())) else { return nil }
        parts.scheme = "ssh"; parts.host = host.lowercased()
        if parts.port == 22 { parts.port = nil }
        let path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = path
        return parts.url
    }

    static func label(_ url: URL) -> String { (url.host ?? "") + (url.port.map { ":\($0)" } ?? "") + url.path }

    static func sha(_ value: String) -> String? {
        value.range(of: "^[A-Fa-f0-9]{40}([A-Fa-f0-9]{24})?\\z", options: .regularExpression).map { _ in value.lowercased() }
    }

    func directory(_ url: URL, maximum: Int, credential: AgentPluginMarketCredential? = nil) async throws -> (Data, Commit) {
        try await withRepository(url, ref: nil, pinned: nil, credential: credential) { scratch, commit in
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

    func archive(_ url: URL, ref: String?, pinned: String?, folder: String, maximum: Int,
                 credential: AgentPluginMarketCredential? = nil) async throws -> (Data, Commit) {
        try await withRepository(url, ref: ref, pinned: pinned, credential: credential) { scratch, commit in
            let target = scratch.appendingPathComponent("selected.zip")
            let tree = commit.sha + (folder.isEmpty ? "" : ":" + folder)
            _ = try await local(["archive", "--format=zip", "--prefix=repository/", "--output=" + target.path, tree],
                in: scratch, failure: "无法归档所选 Git 仓库目录")
            let files = try AgentFiles(workspace: scratch.path, followParentLinks: false)
            return (try files.readData(target, maximum: maximum), commit)
        }
    }

    private func withRepository<Value>(_ address: URL, ref: String?, pinned: String?, credential: AgentPluginMarketCredential?,
                                       use: (URL, Commit) async throws -> Value) async throws -> Value {
        guard let url = Self.address(address), let host = url.host else { throw PetError("请填写有效的 HTTPS 或 SSH Git 地址") }
        let scratch = profile.appendingPathComponent(".plugin-git-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let network: [String], sshHosts: [URL]?, authentication: URL?
        if url.scheme == "ssh" {
            network = ["-c", "protocol.ssh.allow=always"]
            sshHosts = try configureSSH(url, in: scratch)
            authentication = nil
        } else {
            let config = try await run(["help", "--config"], in: scratch, maximum: 200_000, failure: "无法核对 Git 的 HTTPS 能力")
            guard String(decoding: config, as: UTF8.self).split(separator: "\n").contains("http.curloptResolve") else {
                throw PetError("当前 Git 缺少 HTTPS 地址校验支持，请更新 Xcode 命令行工具")
            }
            network = try networkFlags(url, host: host, scratch: scratch)
            sshHosts = nil
            authentication = try credential.map { try authConfig($0, repository: url, in: scratch) }
        }
        let branch = ref ?? "HEAD"
        let object: String
        if let pinned {
            guard let normalized = Self.sha(pinned) else { throw PetError("Git 提交编号无效") }
            object = normalized
        } else {
            let discovery = try await run(["ls-remote", "--", url.absoluteString, "HEAD", branch], in: scratch, network: network,
                authentication: authentication, sshHosts: sshHosts, failure: "无法读取 Git 仓库，请检查地址、分支和读取权限")
            let refs = String(decoding: discovery, as: UTF8.self).split(separator: "\n")
            guard let first = refs.first, let hash = first.split(separator: "\t").first,
                  let detected = Self.sha(String(hash)) else { throw PetError("Git 仓库没有可读取的分支或标签") }
            object = detected
        }
        let format = object.count == 64 ? "sha256" : "sha1"
        _ = try await run(["init", "--bare", "--quiet", "--template=", "--object-format=" + format, "objects.git"], in: scratch,
            failure: "无法准备 Git 插件目录")
        _ = try await run(["--git-dir=objects.git", "fetch", "--quiet", "--depth=1", "--no-tags", "--no-recurse-submodules",
            "--", url.absoluteString, pinned == nil ? branch : object], in: scratch, network: network, authentication: authentication,
            sshHosts: sshHosts, failure: "无法读取所选 Git 提交，请核对分支、标签或提交是否可访问")
        let bytes = try await local(["rev-parse", "--verify", "FETCH_HEAD^{commit}"], in: scratch)
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commit = Self.sha(text), pinned == nil || commit == object else { throw PetError("Git 仓库返回的提交与所选版本不一致") }
        return try await use(scratch, Commit(repository: url, sha: commit))
    }

    private func configureSSH(_ repository: URL, in scratch: URL) throws -> [URL] {
        // Use the local agent and public host keys. Keep local SSH config,
        // private keys and forwarding outside the repository fetch process.
        var config = """
        Host *
          BatchMode yes
          StrictHostKeyChecking yes
          UpdateHostKeys no
          IdentityFile none
          IdentityAgent SSH_AUTH_SOCK
          PreferredAuthentications publickey
          ClearAllForwardings yes
          ForwardAgent no
        """ + "\n"
        let hosts: [URL]
        if let sshFixture, sshFixture.repository == repository {
            let known = try Data(contentsOf: sshFixture.knownHosts)
            try known.write(to: scratch.appendingPathComponent("ssh-known-hosts"))
            config += "  UserKnownHostsFile ./ssh-known-hosts\n  GlobalKnownHostsFile /dev/null\n"
            hosts = []
        } else {
            let ssh = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
            hosts = ["known_hosts", "known_hosts2"].map { ssh.appendingPathComponent($0) }
        }
        try config.write(to: scratch.appendingPathComponent("ssh-config"), atomically: true, encoding: .utf8)
        return hosts
    }

    private func authConfig(_ credential: AgentPluginMarketCredential, repository: URL, in scratch: URL) throws -> URL {
        guard credential.username != nil, AgentPluginMarketCredential.path(repository) != nil else {
            throw PetError("请检查 Git 仓库地址和访问凭据。")
        }
        let path = scratch.appendingPathComponent("https-auth.config")
        let url = repository.absoluteString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let config = "[http \"\(url)\"]\n\textraHeader = Authorization: \(credential.authorization)\n"
        guard FileManager.default.createFile(atPath: path.path, contents: Data(config.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw PetError("无法准备 Git 的访问凭据。")
        }
        return path
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

    private func run(_ args: [String], in scratch: URL, network: [String] = [], authentication: URL? = nil,
                     sshHosts: [URL]? = nil, maximum: Int = 100_000, failure: String) async throws -> Data {
        let git = try AgentGit.executablePath()
        let flags = ["--no-pager", "--literal-pathspecs", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never",
            "-c", "http.followRedirects=false", "-c", "http.sslVerify=true", "-c", "http.proxy=", "-c", "credential.helper=",
            "-c", "credential.interactive=false", "-c", "fetch.fsckObjects=true", "-c", "fetch.unpackLimit=0",
            "-c", "fetch.writeCommitGraph=false", "-c", "maintenance.auto=false", "-c", "gc.auto=0"]
        // Apply a 64 MiB per-file cap before Git reads any network objects.
        let argv = ["-c", "ulimit -f 65536 && exec \"$@\"", "market-git", git] + flags + network + args
        var environment = ["GIT_ASKPASS": "/usr/bin/false", "GIT_CONFIG_NOSYSTEM": "1"]
        if let authentication { environment["GIT_CONFIG_GLOBAL"] = authentication.path }
        if sshHosts != nil {
            environment["GIT_SSH_VARIANT"] = "ssh"
            environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -F ssh-config"
            environment["SSH_ASKPASS_REQUIRE"] = "never"
            environment["SSH_AUTH_SOCK"] = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        }
        let result = try await AgentCommand().run(command: "/bin/sh", workspace: scratch, scratch: scratch,
            network: !network.isEmpty, timeout: network.isEmpty ? 10 : 45, maximumOutput: maximum, protectedData: profile,
            readRoots: sshHosts ?? [], sshClient: sshHosts != nil, environment: environment, arguments: argv)
        if result.timedOut == true { throw PetError("读取 Git 仓库超时，请稍后重试") }
        if result.truncated == true { throw PetError("Git 仓库文件超过可读上限") }
        if result.failed || result.stdoutData == nil {
            let diagnostic = (result.stderr ?? "").lowercased()
            if sshHosts != nil {
                if diagnostic.contains("host identification has changed") { throw PetError("SSH 主机指纹已变化，请先核对主机身份。") }
                if diagnostic.contains("host key verification failed") { throw PetError("SSH 主机身份未受信任，请核对主机指纹与本机已知主机记录。") }
                if diagnostic.contains("permission denied (publickey") { throw PetError("SSH 密钥认证失败，请检查本机 SSH 代理和仓库读取权限。") }
            }
            if diagnostic.contains("certificate") || diagnostic.contains("ssl connect") {
                throw PetError("Git 仓库的 HTTPS 证书校验失败，请核对地址")
            }
            if result.exitCode == 128 + Int(SIGXFSZ) || diagnostic.contains("file size limit") {
                throw PetError("Git 仓库的数据超过本机读取上限")
            }
            if ["returned error: 401", "returned error: 403", "authentication failed", "could not read username",
                "unable to get password from user"].contains(where: diagnostic.contains)
                || (authentication != nil && diagnostic.contains("repository not found")) {
                throw PetError("Git 仓库拒绝访问，请检查访问凭据和读取权限。")
            }
            throw PetError(failure)
        }
        return result.stdoutData ?? Data()
    }
}
