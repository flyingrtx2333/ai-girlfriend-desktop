import Foundation
import BlueFatFishMCP

struct AgentMCPImportPlan: Codable {
    let workspace: String?
    var needsSetup = false
}

enum AgentMCPDataImport {
    private static let maximumBytes = 512_000
    private static let missing = AgentMCP.importPlaceholder

    private struct SourceFile {
        let url: URL
        let files: AgentFiles
        let requiresProject: Bool
    }

    private struct Definition: Codable, Sendable {
        let name: String
        let type: String
        var command: String?
        var args: [String] = []
        var cwd: String?
        var url: String?
        var env: [String] = []
        var headers: [String] = []
        var bearer = false
        let timeout: Double
        var needsSetup = false
        var authorizationReview = false

        func hash() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return AgentFiles.hash(try encoder.encode(self))
        }
        var preview: String {
            var rows = [type.uppercased() + " · " + String(format: "%g", timeout) + " 秒"]
            if let command { rows.append("程序 · " + command) }
            if !args.isEmpty { rows.append("参数 · " + args.map(AgentGit.quote).joined(separator: " ")) }
            if let cwd { rows.append("工作目录 · " + cwd) }
            if let url { rows.append("地址 · " + url) }
            if !env.isEmpty { rows.append("环境变量 · " + env.joined(separator: "、")) }
            if !headers.isEmpty { rows.append("请求头 · " + headers.joined(separator: "、")) }
            if bearer { rows.append("Bearer Token 待填写") }
            return String(rows.joined(separator: "\n").replacingOccurrences(of: AgentMCP.importPlaceholder, with: "〈待填写〉").prefix(1500))
        }
        func server(id: String, workspace: String?) -> AgentMCPServer {
            var value = AgentMCPServer(name: name, type: type)
            value.id = id; value.workspace = workspace; value.command = command; value.args = args; value.url = url
            value.workingDirectory = cwd; value.environmentKeys = env; value.headerKeys = headers.isEmpty ? nil : headers
            value.hasBearerToken = bearer; value.timeoutSeconds = timeout; value.enabled = false; value.configured = !needsSetup
            return value
        }
    }

    private static func sourceFiles(_ source: AgentImportSource, root: URL) throws -> [SourceFile] {
        var isDirectory: ObjCBool = false
        guard root.path != "/", FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw PetError("找不到连接器来源，请选择配置文件或目录")
        }
        let directory = isDirectory.boolValue ? root : root.deletingLastPathComponent()
        let files = try AgentFiles(workspace: directory.path, followParentLinks: false)
        guard files.root.path == directory.standardizedFileURL.path else { throw PetError("连接器来源位置已变化，请重新选择") }
        if !isDirectory.boolValue {
            let extensions = source == .codex ? ["toml"] : ["json"]
            guard extensions.contains(root.pathExtension.lowercased()) else { throw PetError(source.title + "连接器配置文件格式不符") }
            let file = try files.literalURL(root.path)
            guard try files.entryMetadata(file).kind == "file" else { throw PetError("连接器配置需要是普通文件") }
            return [SourceFile(url: file, files: files, requiresProject: file.lastPathComponent == ".mcp.json")]
        }
        let locations: [(String, Bool)] = source == .codex
            ? [("config.toml", false), (".codex/config.toml", true)]
            : [("settings.json", false), ("mcp.json", false), (".qoder/settings.json", true), (".mcp.json", true)]
        return try locations.compactMap { path, project in
            let file = try files.literalURL(path), entry = try files.entryMetadata(file)
            guard entry.kind != "missing" else { return nil }
            guard entry.kind == "file" else { throw PetError("连接器来源需要是普通文件：" + file.lastPathComponent) }
            return SourceFile(url: file, files: files, requiresProject: project)
        }
    }

    static func configuredAddress(_ text: String) throws -> String {
        guard text.utf8.count <= 4000, var url = URLComponents(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw PetError("远程连接器需要 HTTPS，本机可用 HTTP")
        }
        url.scheme = scheme
        guard let address = url.string else { throw PetError("远程连接器地址格式无效") }
        return scrubAddress(address)
    }

    private static func scrubAddress(_ text: String) -> String {
        guard var url = URLComponents(string: text), url.host != nil,
              url.user != nil || url.password != nil || url.percentEncodedQuery != nil || url.fragment != nil else { return text }
        url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
        return (url.string ?? "") + "?" + missing
    }

    static func scrubArguments(_ args: [String], command: String) -> [String] {
        func credentialOption(_ text: String) -> Bool {
            let key = text.lowercased().filter { $0.isASCII && $0.isLetter }
            return ["token", "key", "secret", "password", "authorization", "credential", "passphrase"].contains { key.hasSuffix($0) }
        }
        let program = URL(fileURLWithPath: command).lastPathComponent
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh"]
        let interpreters = ["python", "node", "perl", "ruby", "deno"]
        var nextMissing = false
        return args.map { arg in
            if nextMissing { nextMissing = false; return missing }
            let pair = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 {
                let key = String(pair[0]), value = String(pair[1])
                if credentialOption(key) { return key + "=" + missing }
                let redacted = scrubAddress(value)
                if redacted != value { return key + "=" + redacted }
            }
            if arg.hasPrefix("-"), credentialOption(arg) { nextMissing = true; return arg }
            if (arg == "-c" && (shells.contains(program) || program.hasPrefix("python"))) ||
                (["-e", "--eval"].contains(arg) && interpreters.contains(where: { program.hasPrefix($0) })) {
                nextMissing = true; return arg
            }
            if arg.range(of: #"^(authorization\s*:|bearer\s+)"#, options: [.regularExpression, .caseInsensitive]) != nil { return missing }
            return scrubAddress(arg)
        }
    }

    private static func definition(_ name: String, type: String?, command: String?, args: [String], cwd: String?, url: String?,
                                   env: [String], headers: [String], bearer: Bool, timeout: Double?, authorization: Bool) throws -> Definition {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.contains("\0"), name.count <= 160,
              (command == nil) != (url == nil) else { throw PetError("需要名称和一种连接方式") }
        let type = type == "streamable-http" ? "http" : type ?? (url == nil ? "stdio" : "http")
        let timeout = timeout ?? 60
        guard timeout.isFinite, (1...600).contains(timeout) else { throw PetError("连接器超时范围为 1 至 600 秒") }
        guard !args.contains(where: { $0.contains("\0") || $0.utf8.count > 4000 }), args.count <= 100 else { throw PetError("命令参数格式无效或超过限制") }
        var result = Definition(name: name, type: type, timeout: timeout, authorizationReview: authorization)
        if let command {
            guard type == "stdio", !command.isEmpty, !command.contains("\0"), command.utf8.count <= 4000,
                  headers.isEmpty, !bearer else { throw PetError("本机连接器配置格式无效") }
            guard env.count <= 64, env.allSatisfy({
                $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && !$0.hasPrefix("DYLD_") && !$0.hasPrefix("LD_")
            }) else { throw PetError("连接器含无效或不支持的环境变量名称") }
            let executable = AgentMCP.configurationCommand(command)
            result.command = executable.contains(where: \.isWhitespace) && !FileManager.default.isExecutableFile(atPath: executable) ? missing : executable
            result.args = scrubArguments(args, command: executable)
            if let cwd, !cwd.isEmpty {
                result.cwd = cwd.hasPrefix("/") && !cwd.contains("\0") && cwd.utf8.count <= 4000 ? cwd : missing
            }
            let directoryAvailable = result.cwd.map { (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? true
            result.env = env.sorted()
            result.needsSetup = !env.isEmpty || result.args != args || !executable.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: executable) || !directoryAvailable || authorization
        } else if let url {
            guard ["sse", "http"].contains(type), env.isEmpty, args.isEmpty, cwd == nil else { throw PetError("远程连接器配置格式无效") }
            let normalized = try configuredAddress(url)
            try AgentMCP.validateHeaders(Dictionary(uniqueKeysWithValues: headers.map { ($0, "") }))
            guard !bearer || !headers.contains(where: { $0.lowercased() == "authorization" }) else { throw PetError("Bearer Token 与 Authorization 请求头重复") }
            result.url = normalized; result.headers = headers.sorted(); result.bearer = bearer
            result.needsSetup = normalized.contains(missing) || !headers.isEmpty || bearer || authorization
        }
        return result
    }

    private static func qoder(_ name: String, raw: Any) throws -> Definition {
        guard let raw = raw as? [String: Any] else { throw PetError("连接器需要是配置对象") }
        func read<T>(_ key: String, as type: T.Type) throws -> T? {
            guard let value = raw[key] else { return nil }
            guard let value = value as? T else { throw PetError("连接器字段格式无效：" + key) }
            return value
        }
        let headers = try read("headers", as: [String: String].self) ?? [:]
        let env = try read("env", as: [String: String].self) ?? [:]
        let bearer = try !(read("bearerToken", as: String.self) ?? "").isEmpty
        let timeout = try read("timeout", as: Double.self)
        let seconds = try read("timeoutSeconds", as: Double.self)
        guard (timeout == nil || seconds == nil),
              ["timeout", "timeoutSeconds"].allSatisfy({ raw[$0].map { CFGetTypeID($0 as CFTypeRef) != CFBooleanGetTypeID() } ?? true }) else {
            throw PetError("连接器超时字段无效")
        }
        return try definition(name, type: read("type", as: String.self), command: read("command", as: String.self),
            args: read("args", as: [String].self) ?? [], cwd: read("cwd", as: String.self), url: read("url", as: String.self),
            env: Array(env.keys), headers: Array(headers.keys), bearer: bearer, timeout: seconds ?? timeout.map { $0 / 1000 },
            authorization: raw["oauth"] != nil || raw["auth"] != nil)
    }

    private static func declarations(_ source: AgentImportSource, file: SourceFile) throws -> [String: Result<Definition, Error>] {
        let data = try file.files.readData(file.url, maximum: maximumBytes)
        if source == .qoder {
            let object: [String: Any]
            do { object = try AgentConfigurationJSON.object(data) } catch { throw PetError("Qoder 连接器 JSON 格式无效") }
            if let raw = object["mcpServers"] {
                guard let values = raw as? [String: Any], values.count <= 128 else { throw PetError("mcpServers 需要是最多 128 项的对象") }
                return Dictionary(uniqueKeysWithValues: values.map { name, value in (name, Result { try qoder(name, raw: value) }) })
            }
            if let name = object["name"] as? String, object["command"] != nil || object["url"] != nil {
                return [name: Result { try qoder(name, raw: object) }]
            }
            return [:]
        }
        let entries: [String: CodexMCPConfiguration?]
        do { entries = try CodexMCPConfiguration.read(data) } catch { throw PetError("Codex config.toml 格式无效") }
        guard entries.count <= 128 else { throw PetError("每份配置最多可检测 128 个连接器") }
        return Dictionary(uniqueKeysWithValues: entries.map { name, entry in
            (name, Result {
                guard let entry else { throw PetError("连接器字段格式无效") }
                return try definition(name, type: nil, command: entry.command, args: entry.args, cwd: entry.cwd, url: entry.url, env: entry.environmentKeys,
                    headers: entry.headerKeys, bearer: entry.hasBearerToken, timeout: entry.timeoutSeconds, authorization: entry.needsAuthorizationReview)
            })
        })
    }

    static func discover(_ source: AgentImportSource, root: URL, workspace: String?) throws -> [AgentImportCandidate] {
        var rows: [AgentImportCandidate] = []
        for file in try sourceFiles(source, root: root) {
            try Task.checkCancellation()
            let time = try file.files.entryMetadata(file.url).modified ?? Date()
            let values: [String: Result<Definition, Error>]
            do { values = try declarations(source, file: file) }
            catch {
                let sourceID = "mcp-file:" + AgentFiles.hash(Data(file.url.path.utf8))
                var record = AgentImportCandidate(source: source, sourceID: sourceID, file: file.url.path, rawHash: "", sourceHash: "",
                                                  title: file.url.lastPathComponent, created: time, updated: time)
                record.connector = AgentMCPImportPlan(workspace: workspace)
                record.issue = error.localizedDescription
                rows.append(record)
                continue
            }
            for name in values.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let sourceID = "mcp:" + AgentFiles.hash(Data((file.url.path + "\0" + name).utf8))
                var record = AgentImportCandidate(source: source, sourceID: sourceID, file: file.url.path, rawHash: "", sourceHash: "", title: name, created: time, updated: time)
                record.connector = AgentMCPImportPlan(workspace: workspace)
                switch values[name]! {
                case .failure(let error): record.issue = error.localizedDescription
                case .success(let definition):
                    record.sourceHash = try definition.hash(); record.rawHash = record.sourceHash
                    record.preview = definition.preview
                    record.connector?.needsSetup = definition.needsSetup
                    if definition.authorizationReview { record.warnings.append("连接前检查授权与工具范围") }
                    if file.requiresProject, workspace == nil { record.issue = "项目来源，请选择目标项目" }
                }
                rows.append(record)
            }
        }
        return rows
    }

    private static func sourceFile(_ record: AgentImportCandidate, root: URL) throws -> SourceFile {
        guard record.connector != nil, let file = try sourceFiles(record.source, root: root).first(where: { $0.url.path == record.file }) else {
            throw PetError("连接器来源已变化，请重新检测")
        }
        return file
    }

    static func reveal(_ record: AgentImportCandidate, root: URL) throws -> URL { try sourceFile(record, root: root).url }

    @MainActor static func requireDestination(_ workspace: String?, store: AgentStore) throws {
        guard let workspace else { return }
        guard AgentMemory.projects(store: store, preferredTaskID: store.selectedID).contains(where: { $0.workspace == workspace }),
              try AgentFiles(workspace: workspace, followParentLinks: false).root.path == URL(fileURLWithPath: workspace).standardizedFileURL.path else {
            throw PetError("目标项目不可用，请重新选择")
        }
    }

    @MainActor static func plan(_ entries: [AgentImportCandidate], workspace: String?, store: AgentStore) throws -> [AgentImportCandidate] {
        try requireDestination(workspace, store: store)
        if let issue = store.mcp.loadError { throw PetError(issue) }
        let groups = Dictionary(grouping: entries.filter { $0.issue == nil }) { $0.title.lowercased() }
        return entries.map { entry in
            var record = entry
            if record.issue == nil {
                if store.mcp.hasImportName(record.title, workspace: workspace) { record.issue = "同名连接器已存在，保留现有配置" }
                else if groups[record.title.lowercased(), default: []].count > 1 { record.issue = "多份同名连接器，请分别选择来源文件" }
            }
            return record
        }
    }

    @MainActor static func install(_ record: AgentImportCandidate, root: URL, store: AgentStore) async throws {
        let workspace = record.targetWorkspace
        try requireDestination(workspace, store: store)
        if store.mcp.containsImported(record.targetID, workspace: workspace) { return }
        let definition = try await Task.detached(priority: .utility) {
            let file = try sourceFile(record, root: root)
            guard !file.requiresProject || workspace != nil else { throw PetError("项目来源，请选择目标项目") }
            guard let value = try declarations(record.source, file: file)[record.title], case .success(let definition) = value,
                  try definition.hash() == record.sourceHash else { throw PetError("来源连接器配置已变化，请重新检测") }
            return definition
        }.value
        try requireDestination(workspace, store: store)
        try store.mcp.addImported(definition.server(id: record.targetID, workspace: workspace))
    }
}
