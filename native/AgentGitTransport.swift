import Foundation

struct AgentGitEndpoint: Codable, Equatable {
    var input: String; var location: String; var scheme: String; var localPath: String?
    var needsNetwork: Bool { localPath == nil }
    var needsCredentials: Bool { ["ssh", "http", "https"].contains(scheme) }
    static func parse(_ raw: String, relativeTo root: URL) throws -> Self {
        guard !raw.isEmpty, raw.utf8.count <= 4096, raw.rangeOfCharacter(from: .controlCharacters) == nil, !raw.hasPrefix("-"), raw.range(of: "^[A-Za-z][A-Za-z0-9+.-]*::", options: .regularExpression) == nil else { throw PetError("Git 远端地址无效或使用了不支持的外部传输程序") }
        if raw.contains("://") {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["https", "http", "ssh", "git", "file"].contains(scheme), url.query == nil, url.fragment == nil, url.password == nil else { throw PetError("请使用不含凭据、查询参数的 Git 远端地址，登录沿用现有 Git 配置") }
            if scheme == "file" {
                guard url.host == nil || url.host == "" || url.host == "localhost", url.user == nil else { throw PetError("本机 Git 地址无效") }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                return Self(input: path, location: path, scheme: "file", localPath: path)
            }
            guard let host = url.host, !host.isEmpty, !host.hasPrefix("-"), !url.path.isEmpty, url.path.rangeOfCharacter(from: .controlCharacters) == nil, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, url.user?.hasPrefix("-") != true, url.port.map({ (1...65535).contains($0) }) != false else { throw PetError("Git 远端缺少有效主机或仓库路径") }
            guard scheme == "ssh" || url.user == nil else { throw PetError("请从远端地址移除登录信息，使用现有 Git 凭据助手") }
            return Self(input: raw, location: raw, scheme: scheme)
        }
        if let colon = raw.firstIndex(of: ":"), !raw.hasPrefix("/"), !raw.hasPrefix(".") {
            let host = String(raw[..<colon]), path = String(raw[raw.index(after: colon)...])
            guard !host.isEmpty, !path.isEmpty, !path.hasPrefix("-"), host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !host.hasPrefix("-") else { throw PetError("SSH Git 地址无效") }
            return Self(input: raw, location: raw, scheme: "ssh")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)).standardizedFileURL.resolvingSymlinksInPath()
        return Self(input: url.path, location: url.path, scheme: "file", localPath: url.path)
    }
}

struct AgentGitRemote: Codable { var name: String; var urls: [String] }
struct AgentGitRemoteSnapshot: Codable { var remotes: [AgentGitRemote]; var configHash: String; var processID: String; var hash: String }
struct AgentGitPushReview: Codable {
    var sessionID: String; var processID: String; var taskID: String; var promptID: String; var workspace: String; var gitDirectory: String
    var remote: String; var urlIndex: Int; var configuredURL: String; var endpoint: AgentGitEndpoint
    var sourceBranch: String; var sourceRef: String; var sourceHead: String; var targetBranch: String; var remoteHead: String?
    var configHash: String; var transportConfigHash: String; var scopeHash: String; var hookPath: String?; var hookHash: String
    var trackingRef: String?; var trackingHead: String?; var setUpstream: Bool
    var commitCount: Int; var commits: String; var diff: String; var diffTruncated: Bool; var uncommittedFiles: Int
    var hash: String; var created = Date()
    var destinationRef: String { "refs/heads/" + targetBranch }
    var summary: String {
        "\(remote) · \(endpoint.location)\n\(sourceBranch) → \(targetBranch)\n提交 \(sourceHead.prefix(12)) · \(commitCount) 项\n远端 " + (remoteHead.map { String($0.prefix(12)) } ?? "新分支")
    }
}
struct AgentGitPushReceipt: Codable {
    var id = UUID().uuidString; var taskID: String; var remote: String; var input: AgentGitEndpoint; var endpoint: AgentGitEndpoint; var branch: String; var sourceHead: String; var beforeHead: String?
    var afterHead: String?; var verified = false; var output = ""; var exitCode: Int?; var localUpdate = ""; var created = Date()
}

// The authenticated process sees a clean bare repository, never the original
// workspace or its hooks. Its directory is a sibling of project-command scratch.
@MainActor final class AgentGitTransport {
    static let processID = UUID().uuidString
    let root: URL, repository: URL, hooks: URL, store: AgentStore
    private var command: AgentCommand?
    init(store: AgentStore, taskID: String, sessionID: String = UUID().uuidString) throws {
        guard UUID(uuidString: sessionID) != nil else { throw PetError("推送会话无效") }
        self.store = store
        root = try store.backupDirectory(taskID).deletingLastPathComponent().appendingPathComponent("git-transport").appendingPathComponent(sessionID)
        repository = root.appendingPathComponent("repository.git"); hooks = root.appendingPathComponent("empty-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func cancel() { command?.cancel() }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    private func localRoot(_ endpoint: AgentGitEndpoint) throws -> URL? {
        guard let path = endpoint.localPath else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let protected = store.directory.deletingLastPathComponent().path
        let critical = [NSHomeDirectory(), protected, Bundle.main.bundleURL.path]
        guard url.path != "/", !critical.contains(where: { $0 == url.path || $0.hasPrefix(url.path + "/") }), !url.path.hasPrefix(protected + "/"), FileManager.default.fileExists(atPath: url.appendingPathComponent("HEAD").path), FileManager.default.fileExists(atPath: url.appendingPathComponent("objects").path) else { throw PetError("本机远端必须是应用数据之外的实际 Git 仓库目录") }
        return url
    }
    func run(_ args: [String], endpoint: AgentGitEndpoint? = nil, writingRemote: Bool = false, timeout: Double = 60, maximumOutput: Int = 100_000) async throws -> AgentToolResult {
        let process = AgentCommand(); command = process; defer { command = nil }
        let local = try endpoint.flatMap(localRoot)
        var environment = ["SSH_ASKPASS_REQUIRE": "never", "GCM_INTERACTIVE": "never"]
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !socket.isEmpty { environment["SSH_AUTH_SOCK"] = socket }
        let flags = ["--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.quotePath=false", "-c", "init.templateDir=" + hooks.path,
                     "-c", "protocol.allow=never", "-c", "protocol.file.allow=always", "-c", "http.followRedirects=false", "-c", "push.followTags=false", "-c", "push.recurseSubmodules=no", "-c", "fetch.recurseSubmodules=false", "-c", "credential.interactive=false"]
            + (endpoint.map { ["-c", "protocol." + $0.scheme + ".allow=always"] } ?? [])
        return try await process.run(command: AgentGit.executablePath(), workspace: root, scratch: root, network: endpoint?.needsNetwork == true, timeout: timeout, gitConfiguration: true, maximumOutput: maximumOutput, protectedData: store.directory.deletingLastPathComponent(), readRoots: local.map { [$0] } ?? [], writeRoots: writingRemote ? local.map { [$0] } ?? [] : [], gitTransportAuth: endpoint?.needsCredentials == true, environment: environment, arguments: flags + args)
    }
    func output(_ args: [String], endpoint: AgentGitEndpoint? = nil) async throws -> String {
        let result = try await run(args, endpoint: endpoint)
        guard !result.failed, result.truncated != true else { throw PetError(String(result.text.prefix(3000))) }
        return result.stdout ?? ""
    }
    func initialize(format: String = "sha1") async throws {
        guard ["sha1", "sha256"].contains(format) else { throw PetError("Git 对象格式不受支持") }
        _ = try await output(["init", "--bare", "--object-format=" + format, "--template=" + hooks.path, repository.path])
        _ = try await output(["-C", repository.path, "config", "--local", "core.hooksPath", hooks.path])
    }
    func effective(_ input: AgentGitEndpoint) async throws -> AgentGitEndpoint {
        let value = try await output(["-C", repository.path, "ls-remote", "--get-url", "--", input.input]).trimmingCharacters(in: .whitespacesAndNewlines)
        return try AgentGitEndpoint.parse(value, relativeTo: root)
    }
    func remoteHead(input: AgentGitEndpoint, endpoint: AgentGitEndpoint, branch: String) async throws -> String? {
        let raw = try await output(["-C", repository.path, "ls-remote", "--refs", "--heads", "--", input.input, "refs/heads/" + branch], endpoint: endpoint)
        let rows = raw.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        guard rows.allSatisfy({ $0.count == 2 && $0[1] == "refs/heads/" + branch && $0[0].range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil }), rows.count <= 1 else { throw PetError("远端分支响应无效") }
        return rows.first?.first
    }
    func configurationHash() async throws -> String {
        let result = try await run(["-C", repository.path, "config", "--null", "--list"], maximumOutput: 1_000_000)
        guard !result.failed, result.truncated != true else { throw PetError("无法读取 Git 连接配置") }
        return AgentFiles.hash(Data((result.stdout ?? "").utf8))
    }
}
