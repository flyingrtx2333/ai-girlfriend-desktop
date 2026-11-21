import Foundation

struct AgentStandaloneImportPlan: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case rule, instruction, command, agent, hooks, policy
        var title: String {
            switch self {
            case .rule: return "规则"
            case .instruction: return "指令"
            case .command: return "命令"
            case .agent: return "智能体"
            case .hooks: return "Hooks"
            case .policy: return "终端审批策略"
            }
        }
    }
    var kind: Kind
    var workspace: String?
    var directory: String
    var relative: String

    var commandName: String { String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":") }
    var maximumReadBytes: Int {
        guard kind == .hooks else { return 65_536 }
        return relative == "config.toml" ? 512_000 : 128_000
    }
    var destination: String {
        let folder = workspace == nil ? "extensions/" : ".bluefatfish/"
        switch kind {
        case .rule: return (directory.isEmpty ? "" : directory + "/") + folder + "rules/" + relative
        case .instruction: return (directory.isEmpty ? "" : directory + "/") + relative
        case .command: return folder + "commands/" + relative
        case .agent, .hooks, .policy: return ""
        }
    }
}

enum AgentStandaloneDataImport {
    private struct RemoteContext: Sendable {
        let route: AgentImportRoute, transport: AgentSSHImport
        let origin: AgentSSHConfigurationSource.Origin
        let issues: [String: PetError], resourceIssues: [String: PetError]
    }

    private struct Location: Sendable {
        let files: AgentFiles, source: AgentImportSource, workspace: String?
        let configurationRoot: Bool, project: Bool
        let remote: RemoteContext?

        init(_ root: URL, source: AgentImportSource, workspace: String?, userRoots: Set<String> = [], remote: RemoteContext? = nil) throws {
            files = try AgentFiles(workspace: root.path, followParentLinks: false)
            guard files.root.path == root.standardizedFileURL.path, !AgentFiles.sensitive(root.path) else { throw PetError("请选择普通来源目录") }
            self.source = source
            self.workspace = workspace
            self.remote = remote
            if let remote {
                configurationRoot = remote.origin.configurationRoot
                project = remote.origin.project
                return
            }
            configurationRoot = root.lastPathComponent == source.homeName
            let parent = root.deletingLastPathComponent()
            project = !configurationRoot || (!userRoots.contains(root.path) && (workspace == parent.path ||
                [".git", ".bluefatfish", "AGENTS.md", "AGENTS.local.md", "AGENTS.override.md"].contains {
                    FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path)
                }))
        }

        func logicalPath(_ file: URL) -> String {
            guard let remote else { return file.path }
            let root = remote.route.root
            return (root.hasSuffix("/") ? root : root + "/") + relativePath(file)
        }

        func relativePath(_ file: URL) -> String {
            String(file.path.dropFirst(files.root.path.count + 1))
        }

        func read(_ file: URL, plan: AgentStandaloneImportPlan) throws -> Data {
            if let issue = remote?.issues[relativePath(file)] { throw issue }
            return try AgentStandaloneDataImport.read(file, from: files, maximum: plan.maximumReadBytes)
        }

        func events(_ bytes: Data, file: URL) throws -> [String: Any]? {
            try AgentStandaloneHookPackage.events(bytes, source: source, file: file, projected: remote != nil)
        }

        func originalHookDirectory(_ file: URL, mcpOnly: Bool) throws -> String? {
            guard let remote else { return nil }
            let path = relativePath(file.deletingLastPathComponent().appendingPathComponent("hooks"))
            if !mcpOnly, let failure = remote.resourceIssues[path] { throw failure }
            return remote.origin.root + "/" + path
        }

        func entry(_ file: URL) throws -> AgentStandaloneImportPlan? {
            let checked = try files.literalURL(file.path)
            let path = String(checked.path.dropFirst(files.root.path.count + 1))
            guard AgentArchive.validPath(path), !AgentFiles.sensitive(path) else { return nil }
            let parts = path.components(separatedBy: "/")
            let name = file.lastPathComponent
            if ["AGENTS.md", "AGENTS.local.md", "AGENTS.override.md"].contains(name) {
                let directory = parts.dropLast().joined(separator: "/")
                guard configurationRoot ? (!project && directory.isEmpty) : !parts.dropLast().contains(where: { $0.hasPrefix(".") }) else { return nil }
                if source == .codex {
                    guard name != "AGENTS.local.md",
                          name == (try codexInstruction(in: directory)) else { return nil }
                } else if name == "AGENTS.override.md" || (configurationRoot && name != "AGENTS.md") { return nil }
                return .init(kind: .instruction, workspace: workspace, directory: directory,
                             relative: name == "AGENTS.override.md" ? "AGENTS.md" : name)
            }
            let anchor = configurationRoot ? nil : parts.firstIndex(of: source.homeName)
            guard configurationRoot || anchor != nil else { return nil }
            let start = anchor.map { $0 + 1 } ?? 0
            let directory = parts.prefix(anchor ?? 0).joined(separator: "/")
            if parts.count == start + 1 {
                switch (source, name) {
                case (.qoder, "settings.json"), (.codex, "hooks.json"), (.codex, "config.toml"):
                    return .init(kind: .hooks, workspace: workspace, directory: directory, relative: name)
                case (.qoder, "settings.local.json") where project:
                    return .init(kind: .hooks, workspace: workspace, directory: directory, relative: name)
                default: return nil
                }
            }
            guard parts.count > start + 1 else { return nil }
            let relative = parts.dropFirst(start + 1).joined(separator: "/")
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
            let kind: AgentStandaloneImportPlan.Kind
            switch (source, parts[start], file.pathExtension) {
            case (.qoder, "rules", "md"): kind = .rule
            case (.qoder, "commands", "md") where directory.isEmpty: kind = .command
            case (.qoder, "agents", "md"), (.codex, "agents", "toml"):
                guard directory.isEmpty, parts.count == start + 2 else { return nil }
                kind = .agent
            case (.codex, "prompts", "md") where configurationRoot && !project && parts.count == 2: kind = .command
            case (.codex, "rules", "rules") where parts.count == start + 2: kind = .policy
            default: return nil
            }
            return .init(kind: kind, workspace: workspace, directory: directory,
                         relative: source == .codex && kind == .command ? "prompts/" + relative : relative)
        }

        private func codexInstruction(in directory: String) throws -> String {
            let prefix = directory.isEmpty ? "" : directory + "/"
            for name in ["AGENTS.override.md", "AGENTS.md"] {
                let file = try files.literalURL(prefix + name), metadata = try files.entryMetadata(file)
                guard metadata.kind != "missing" else { continue }
                if remote?.issues[prefix + name] != nil { return name }
                // A present but unreadable override is surfaced as a skipped row.
                guard metadata.kind == "file", let bytes = try? files.readData(file, maximum: 65_536),
                      let text = String(data: bytes, encoding: .utf8) else { return name }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty { return name }
            }
            return ""
        }

        func scan() throws -> [(URL, AgentStandaloneImportPlan)] {
            var result: [(URL, AgentStandaloneImportPlan)] = [], visited = 0
            func add(_ child: URL, _ plan: AgentStandaloneImportPlan) throws {
                result.append((child, plan))
                guard result.count <= 256 else { throw PetError("一次最多检测 256 项扩展配置，请选择更小的目录") }
            }
            func visit(_ path: String, recursive: Bool, projectTree: Bool = false) throws {
                let url = path.isEmpty ? files.root : try files.literalURL(path)
                if !path.isEmpty {
                    let kind = try files.entryMetadata(url).kind
                    if kind == "missing" { return }
                    guard kind == "directory" else { throw PetError("来源目录需要普通文件夹：" + path) }
                }
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try Task.checkCancellation()
                    visited += 1
                    guard visited <= 5_000 else { throw PetError("来源超过 5000 项，请选择更小的目录") }
                    let relative = path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent
                    guard AgentArchive.validPath(relative), !AgentFiles.sensitive(relative) else { continue }
                    let child = try files.literalURL(relative)
                    if let plan = try entry(child) {
                        try add(child, plan)
                    } else if recursive, !["node_modules", "__pycache__"].contains(child.lastPathComponent),
                              try files.entryMetadata(child).kind == "directory" {
                        try visit(relative, recursive: true, projectTree: projectTree)
                    }
                }
                if projectTree { try configuration(path.isEmpty ? source.homeName : path + "/" + source.homeName, nested: !path.isEmpty) }
            }
            func configuration(_ path: String, nested: Bool) throws {
                let prefix = path.isEmpty ? "" : path + "/"
                if source == .qoder {
                    try visit(prefix + "rules", recursive: true)
                    if !nested { try visit(prefix + "commands", recursive: true) }
                } else {
                    if !nested { try visit(prefix + "rules", recursive: false) }
                    if configurationRoot && !project { try visit(prefix + "prompts", recursive: false) }
                }
                if !nested { try visit(prefix + "agents", recursive: false) }
                if !configurationRoot && (!nested || source == .codex) {
                    for name in source == .qoder ? ["settings.json", "settings.local.json"] : ["hooks.json", "config.toml"] {
                        let child = try files.literalURL(prefix + name)
                        if try files.entryMetadata(child).kind != "missing", let plan = try entry(child) { try add(child, plan) }
                    }
                }
            }
            if configurationRoot {
                try visit("", recursive: false)
                try configuration("", nested: false)
            } else {
                try visit("", recursive: true, projectTree: true)
            }
            return result.sorted { $0.0.path < $1.0.path }
        }
    }

    @MainActor private static func location(_ root: URL, source: AgentImportSource, workspace: String?, store: AgentStore) throws -> Location {
        let homes = [store.extensions.sharedHome, FileManager.default.homeDirectoryForCurrentUser].compactMap { $0 }
        let roots = Set(homes.map { $0.appendingPathComponent(source.homeName).standardizedFileURL.resolvingSymlinksInPath().path })
        return try Location(root, source: source, workspace: workspace, userRoots: roots)
    }

    @MainActor private static func withRemoteLocation<T>(_ route: AgentImportRoute, transport: AgentSSHImport,
                                                        selected: String = "", _ use: (Location) async throws -> T) async throws -> T {
        let snapshot = try await transport.readConfiguration(route, selected: selected)
        let scratch = transport.profile.appendingPathComponent("ssh-configuration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let location = try await Task.detached(priority: .utility) {
            var issues: [String: PetError] = [:]
            let files = try AgentFiles(workspace: scratch.path, followParentLinks: false)
            for (path, result) in snapshot.files {
                let data: Data
                switch result {
                case .success(let value): data = value
                case .failure(let error): issues[path] = error; data = Data()
                }
                try files.writeData(data, to: files.literalURL(path), permissions: 0o600, expectedTarget: "missing")
            }
            for (path, asset) in snapshot.resources {
                try files.writeData(asset.data, to: files.literalURL(path), permissions: asset.executable ? 0o700 : 0o600, expectedTarget: "missing")
            }
            let remote = RemoteContext(route: route, transport: transport, origin: snapshot.origin, issues: issues, resourceIssues: snapshot.resourceIssues)
            return try Location(files.root, source: route.source, workspace: route.workspace, remote: remote)
        }.value
        try Task.checkCancellation()
        return try await use(location)
    }

    private static func read(_ url: URL, from files: AgentFiles, maximum: Int = 65_536) throws -> Data {
        let before = try files.entryMetadata(url)
        guard before.kind == "file" else { throw PetError("来源或引用需要普通文件") }
        let bytes = try files.readData(url, maximum: maximum)
        guard try files.entryMetadata(url).signature == before.signature else { throw PetError("文件读取期间已变化，请重新检测") }
        return bytes
    }

    private static func text(_ bytes: Data) throws -> String {
        guard let value = String(data: bytes, encoding: .utf8), !value.contains("\0"),
              !value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty else {
            throw PetError("需要非空的 UTF-8 Markdown")
        }
        return value
    }

    private static func commandPayload(_ bytes: Data, text: String, plan: AgentStandaloneImportPlan, source: AgentImportSource) throws -> (data: Data, hint: String?) {
        let document = try AgentExtensionDocument(text)
        guard AgentExtensions.validName(plan.commandName), !text.hasPrefix("\u{FEFF}"),
              Set(document.metadata.keys).isSubset(of: ["name", "description", "argument-hint", "argument_hint", "disable-model-invocation"]) else {
            throw PetError("命令名称或附加的执行配置尚不兼容")
        }
        guard source == .codex else { return (bytes, nil) }
        let prompt = AgentCodexPrompt(document.body)
        guard prompt.hasPlaceholders else { return (bytes, nil) }
        let marked = AgentCodexPrompt.markCommand(text)
        _ = try AgentExtensionDocument(marked)
        return (Data(marked.utf8), document.customArgumentHint ?? prompt.argumentHint)
    }

    private static func installedHash(_ record: AgentImportCandidate, _ plan: AgentStandaloneImportPlan) -> String {
        plan.kind == .command ? record.sourceHash : record.rawHash
    }

    // Compare the entire chain without copying or granting access to any referenced files.
    @MainActor private static func fingerprint(_ bytes: Data, at url: URL, files: AgentFiles, kind: AgentStandaloneImportPlan.Kind,
                                               source: AgentImportSource, reference: ((String, String) -> Void)? = nil) throws -> String {
        guard kind == .instruction else { return AgentFiles.hash(bytes) }
        var visited = Set<String>(), hashes: [String] = [], size = 0
        func visit(_ url: URL, _ bytes: Data, depth: Int) throws {
            guard visited.insert(url.path).inserted else { return }
            size += bytes.count
            guard depth <= 8, visited.count <= 64, size <= 262_144 else { throw PetError("指令引用超过当前支持的范围") }
            let digest = AgentFiles.hash(bytes)
            hashes.append(digest)
            if depth > 0 { reference?(String(url.path.dropFirst(files.root.path.count + 1)), digest) }
            for reference in AgentInstructions.imports(try text(bytes)) {
                guard source == .qoder else { throw PetError("Codex 指令含 @ 引用，请先核对引用含义") }
                guard !reference.hasPrefix("/"), !reference.hasPrefix("~"), !AgentFiles.sensitive(reference) else {
                    throw PetError("指令引用超出所选范围或包含受保护文件")
                }
                let target = try files.literalURL(url.deletingLastPathComponent().path + "/" + reference)
                guard !AgentFiles.sensitive(target.path) else { throw PetError("指令引用指向受保护文件") }
                if !visited.contains(target.path) { try visit(target, read(target, from: files), depth: depth + 1) }
            }
        }
        try visit(url, bytes, depth: 0)
        return AgentFiles.hash(Data(hashes.joined(separator: "\n").utf8))
    }

    @MainActor private static func sourceFingerprint(_ bytes: Data, file: URL, location: Location, plan: AgentStandaloneImportPlan,
                                                     target: URL, destination: AgentFiles) async throws -> String {
        guard let remote = location.remote, plan.kind == .instruction else {
            return try fingerprint(bytes, at: file, files: location.files, kind: plan.kind, source: location.source)
        }
        // The target must already contain the matching reference tree. Only its
        // relative names and the remote hashes are needed to compare the trees.
        var references: [String: String] = [:]
        let digest: String
        do {
            digest = try fingerprint(bytes, at: target, files: destination, kind: plan.kind, source: location.source) { references[$0] = $1 }
        } catch {
            throw PetError("目标范围缺少匹配的指令引用，请先核对引用文件")
        }
        try await remote.transport.verifyConfigurationReferences(references, route: remote.route)
        return digest
    }

    @MainActor private static func destination(_ plan: AgentStandaloneImportPlan, store: AgentStore) throws -> (AgentFiles, URL) {
        try AgentMCPDataImport.requireDestination(plan.workspace, store: store)
        guard plan.kind != .policy, AgentArchive.validPath(plan.destination), !AgentFiles.sensitive(plan.destination),
              plan.directory.isEmpty || plan.workspace != nil else { throw PetError("扩展配置目标无效") }
        let files = try AgentFiles(workspace: plan.workspace ?? store.extensions.profile.path, followParentLinks: false)
        if !plan.directory.isEmpty {
            guard try files.entryMetadata(files.literalURL(plan.directory)).kind == "directory" else {
                throw PetError("目标项目缺少对应目录：" + plan.directory)
            }
        }
        return (files, try files.literalURL(plan.destination))
    }

    @MainActor private static func sharedURL(_ plan: AgentStandaloneImportPlan, store: AgentStore) -> URL? {
        if let workspace = plan.workspace {
            let base = URL(fileURLWithPath: workspace).appendingPathComponent(plan.directory)
            switch plan.kind {
            case .instruction: return base.appendingPathComponent(plan.relative).standardizedFileURL
            case .rule: return base.appendingPathComponent(".qoder/rules/" + plan.relative).standardizedFileURL
            case .command: return base.appendingPathComponent(".qoder/commands/" + plan.relative).standardizedFileURL
            case .hooks: return base.appendingPathComponent(".qoder/" + plan.relative).standardizedFileURL
            case .agent, .policy: return nil
            }
        }
        guard let base = store.extensions.sharedHome?.appendingPathComponent(".qoder") else { return nil }
        switch plan.kind {
        case .instruction: return base.appendingPathComponent("AGENTS.md")
        case .rule: return base.appendingPathComponent("rules/" + plan.relative)
        case .command: return base.appendingPathComponent("commands/" + plan.relative)
        case .hooks: return base.appendingPathComponent(plan.relative)
        case .agent, .policy: return nil
        }
    }

    @MainActor static func discover(_ source: AgentImportSource, root: URL, workspace: String?, store: AgentStore) async throws -> [AgentImportCandidate] {
        try AgentMCPDataImport.requireDestination(workspace, store: store)
        return try await discover(location(root, source: source, workspace: workspace, store: store), store: store)
    }

    @MainActor static func discoverRemote(_ route: AgentImportRoute, transport: AgentSSHImport, store: AgentStore) async throws -> [AgentImportCandidate] {
        try AgentMCPDataImport.requireDestination(route.workspace, store: store)
        return try await withRemoteLocation(route, transport: transport) { try await discover($0, store: store) }
    }

    @MainActor private static func discover(_ location: Location, store: AgentStore) async throws -> [AgentImportCandidate] {
        let source = location.source, workspace = location.workspace
        let entries = try await Task.detached(priority: .utility) { try location.scan() }.value
        let commands = entries.contains { $0.1.kind == .command } ? try store.extensions.catalog(workspace: workspace).filter { $0.kind == .command } : []
        var rows: [AgentImportCandidate] = []
        for (file, plan) in entries {
            try Task.checkCancellation()
            let date = (try? location.files.entryMetadata(file).modified) ?? .distantPast
            let path = location.logicalPath(file)
            let key = "configuration:" + AgentFiles.hash(Data(path.utf8))
            var record = AgentImportCandidate(source: source, sourceID: key, file: path, rawHash: "", sourceHash: "",
                                              title: file.lastPathComponent, created: date, updated: date)
            record.configuration = plan
            record.sshHost = location.remote?.route.sshHost
            do {
                guard plan.kind != .policy else { throw PetError("Codex 终端审批策略需要单独配置") }
                let bytes = try location.read(file, plan: plan)
                record.rawHash = AgentFiles.hash(bytes)
                if plan.kind == .agent {
                    if try previewExtension(&record, plan: plan, file: file, bytes: bytes, location: location, store: store) { rows.append(record) }
                    continue
                }
                if plan.kind == .hooks {
                    guard let events = try location.events(bytes, file: file) else { continue }
                    let types = AgentStandaloneHookPackage.handlerTypes(events)
                    var candidates: [AgentImportCandidate] = []
                    if source != .codex || types.other || !types.mcp { candidates.append(record) }
                    if source == .codex, types.mcp {
                        var companion = record
                        companion.sourceID += ":mcp-hooks"
                        companion.title += " · MCP 工具 Hooks"
                        companion.standaloneMCPHooks = true
                        candidates.append(companion)
                    }
                    for var candidate in candidates {
                        do {
                            if try previewExtension(&candidate, plan: plan, file: file, bytes: bytes, location: location, store: store, hookEvents: events) {
                                rows.append(candidate)
                            }
                        } catch { candidate.issue = error.localizedDescription; rows.append(candidate) }
                    }
                    continue
                }
                let body = try text(bytes)
                var commandHash: String?
                switch plan.kind {
                case .rule:
                    let name = String(plan.relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
                    let rule = try AgentRuleDocument.parse(body, path: plan.relative, fallback: name)
                    record.title = rule.key
                    record.warnings = [rule.trigger.title] + rule.patterns
                case .command:
                    let payload = try commandPayload(bytes, text: body, plan: plan, source: source)
                    commandHash = AgentFiles.hash(payload.data)
                    if let hint = payload.hint { record.warnings = ["参数 " + String(hint.prefix(300))] }
                    record.title = "/" + plan.commandName
                case .instruction:
                    record.warnings = ["导入后按原目录载入"]
                case .agent, .hooks, .policy: break
                }
                record.preview = String(body.prefix(1200))
                guard !location.project || workspace != nil else { throw PetError("项目来源，请选择目标项目") }
                if record.sshHost == nil, source == .qoder, sharedURL(plan, store: store)?.path == file.path,
                   plan.kind != .command || commands.contains(where: { $0.file.path == file.path }) {
                    record.issue = "已共享"
                } else {
                    let (files, target) = try destination(plan, store: store)
                    let current = try files.entryMetadata(target)
                    if plan.kind == .command, commands.contains(where: { $0.name.caseInsensitiveCompare(plan.commandName) == .orderedSame && $0.file.path != target.path }) {
                        throw PetError("同名命令已存在，保留现有配置")
                    }
                    if let commandHash { record.sourceHash = commandHash }
                    else { record.sourceHash = try await sourceFingerprint(bytes, file: file, location: location, plan: plan, target: target, destination: files) }
                    if current.kind != "missing" {
                        guard current.kind == "file", try files.fileHash(target, maximum: 65_536) == installedHash(record, plan) else {
                            throw PetError(plan.kind == .command ? "同名命令已存在，保留现有配置" : "目标文件已存在，保留现有内容")
                        }
                        record.issue = "已经导入"
                    }
                    try validateReferences(bytes, target: target, files: files, record: record, plan: plan)
                }
            } catch { record.issue = error.localizedDescription }
            rows.append(record)
        }
        func destinationKey(_ row: AgentImportCandidate) -> String {
            guard let plan = row.configuration else { return row.id }
            if plan.kind == .agent { return "agent:" + row.title.lowercased() }
            return plan.kind == .hooks ? "hooks:" + row.targetID : plan.destination.lowercased()
        }
        let duplicates = Dictionary(grouping: rows.filter { $0.issue == nil }, by: destinationKey)
        return rows.map { row in
            var value = row
            if row.issue == nil, duplicates[destinationKey(row), default: []].count > 1 {
                value.issue = "多份来源对应同一目标，请分别选择来源目录"
            }
            return value
        }
    }

    @MainActor private static func previewExtension(_ record: inout AgentImportCandidate, plan: AgentStandaloneImportPlan, file: URL,
                                                   bytes: Data, location: Location, store: AgentStore, hookEvents: [String: Any]? = nil) throws -> Bool {
        let variant = record.standaloneMCPHooks == true ? "\0mcp-hooks" : ""
        let host = record.sshHost.map { "ssh:" + $0 + "\0" } ?? ""
        record.targetID = AgentPlugins.mcpUUID("standalone:" + plan.kind.rawValue + ":" + record.source.rawValue + "\0" + host + record.file + "\0" + (plan.workspace ?? "") + variant)
        guard !location.project || plan.workspace != nil else { throw PetError("项目来源，请选择目标项目") }
        guard plan.directory.isEmpty else { throw PetError("请选择对应的子目录作为来源和目标项目") }
        if plan.kind == .agent {
            let (value, warnings) = try AgentStandaloneRoleImport.profile(bytes, source: record.source, file: file, id: record.targetID, workspace: plan.workspace, store: store)
            record.title = value.name
            record.preview = value.description + "\n" + (value.readOnly ? "只读项目" : "可编辑项目")
                + (value.network ? " · 可联网" : "") + "\n" + value.tools.joined(separator: ", ") + "\n\n" + String(value.instructions.prefix(1000))
            record.warnings = warnings
            record.sourceHash = try AgentFiles.hash(Data((record.rawHash + store.agents.encode([value])).utf8))
            let known = try store.agents.decode(store.agents.document(workspace: plan.workspace).0)
            if known.contains(where: { $0.id == value.id }) { record.issue = "已经导入" }
            else if known.contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) { record.issue = "同名智能体已存在，保留现有配置" }
        } else {
            if record.sshHost == nil, record.source == .qoder, sharedURL(plan, store: store)?.path == file.path {
                record.issue = "已共享"; return true
            }
            let (files, target) = try store.hooks.importedConfiguration(record.targetID, workspace: plan.workspace)
            guard let hookEvents, let package = try AgentStandaloneHookPackage.prepare(hookEvents, source: record.source, file: file,
                files: location.files, projectSource: location.project, target: target, workspace: plan.workspace, service: store.hooks,
                mcpOnly: record.standaloneMCPHooks == true,
                originalResourcePath: try location.originalHookDirectory(file, mcpOnly: record.standaloneMCPHooks == true)) else { return false }
            record.preview = package.events.joined(separator: "\n")
            record.warnings = package.warnings
            record.sourceHash = AgentFiles.hash(Data((record.rawHash + package.fingerprint).utf8))
            if try files.entryMetadata(target).kind == "file", try store.hooks.importedReceipt(record.targetID, workspace: plan.workspace) != nil {
                record.issue = "已经导入"
            }
        }
        return true
    }

    @MainActor private static func validateReferences(_ bytes: Data, target: URL, files: AgentFiles,
                                                      record: AgentImportCandidate, plan: AgentStandaloneImportPlan) throws {
        guard plan.kind == .instruction else { return }
        guard (try? fingerprint(bytes, at: target, files: files, kind: plan.kind, source: record.source)) == record.sourceHash else {
            throw PetError("目标项目缺少匹配的指令引用，请先核对引用文件")
        }
    }

    @MainActor static func reveal(_ record: AgentImportCandidate, root: URL, store: AgentStore) throws -> URL {
        guard record.sshHost == nil else { throw PetError("来源文件在 SSH 主机上") }
        let location = try location(root, source: record.source, workspace: record.targetWorkspace, store: store)
        let file = try location.files.literalURL(record.file)
        guard try location.entry(file) == record.configuration, try location.files.entryMetadata(file).kind == "file" else {
            throw PetError("来源文件已离线或变化")
        }
        return file
    }

    @MainActor static func installedURL(_ record: AgentImportCandidate, store: AgentStore) throws -> URL {
        guard let plan = record.configuration, !record.rawHash.isEmpty,
              record.issue == nil || record.issue == "已共享" || record.issue == "已经导入" else { throw PetError("扩展配置尚未导入") }
        if plan.kind == .hooks {
            try AgentMCPDataImport.requireDestination(plan.workspace, store: store)
            if record.issue == "已共享", record.source == .qoder, let shared = sharedURL(plan, store: store), shared.path == record.file,
               FileManager.default.fileExists(atPath: shared.path) { return shared }
            let (files, target) = try store.hooks.importedConfiguration(record.targetID, workspace: plan.workspace)
            guard try files.entryMetadata(target).kind == "file", try store.hooks.importedReceipt(record.targetID, workspace: plan.workspace) != nil else {
                throw PetError("原 Hooks 配置已移除")
            }
            return target
        }
        let (files, target) = try destination(plan, store: store)
        if record.issue == "已共享", record.source == .qoder, let shared = sharedURL(plan, store: store), shared.path == record.file {
            let owner = plan.workspace ?? store.extensions.sharedHome?.path
            let sharedFiles = try AgentFiles(workspace: owner, followParentLinks: false)
            let file = try sharedFiles.literalURL(shared.path)
            guard try sharedFiles.fileHash(file, maximum: 65_536) == record.rawHash else { throw PetError("共享配置已变化，请重新检测") }
            return file
        }
        guard try files.entryMetadata(target).kind == "file", try files.fileHash(target, maximum: 65_536) == installedHash(record, plan) else {
            throw PetError("目标配置已移除或变化")
        }
        return target
    }

    @MainActor static func install(_ record: AgentImportCandidate, root: URL, store: AgentStore) async throws {
        guard record.sshHost == nil else { throw PetError("缺少原 SSH 扩展配置来源") }
        let plan = try importPlan(record)
        if try alreadyInstalled(record, plan: plan, store: store) { return }
        let location = try location(root, source: record.source, workspace: plan.workspace, store: store)
        try await install(record, plan: plan, file: location.files.literalURL(record.file), location: location, store: store)
    }

    @MainActor static func installRemote(_ record: AgentImportCandidate, route: AgentImportRoute, transport: AgentSSHImport, store: AgentStore) async throws {
        let plan = try importPlan(record)
        let prefix = route.root.hasSuffix("/") ? route.root : route.root + "/"
        guard route.category == .configuration, let host = route.sshHost, host == record.sshHost, record.source == route.source,
              plan.workspace == route.workspace, record.file.hasPrefix(prefix) else { throw PetError("SSH 扩展配置与原来源不符，请重新检测") }
        let relative = String(record.file.dropFirst(prefix.count))
        guard AgentSSHConfigurationSource.validPath(relative) else { throw PetError("SSH 扩展配置来源无效") }
        if try alreadyInstalled(record, plan: plan, store: store) { return }
        try await withRemoteLocation(route, transport: transport, selected: relative) { location in
            try await install(record, plan: plan, file: location.files.literalURL(relative), location: location, store: store)
        }
    }

    private static func importPlan(_ record: AgentImportCandidate) throws -> AgentStandaloneImportPlan {
        guard let plan = record.configuration, plan.kind != .policy, record.issue == nil,
              !record.rawHash.isEmpty, !record.sourceHash.isEmpty else {
            throw PetError("扩展配置导入记录无效")
        }
        return plan
    }

    @MainActor private static func alreadyInstalled(_ record: AgentImportCandidate, plan: AgentStandaloneImportPlan, store: AgentStore) throws -> Bool {
        try AgentMCPDataImport.requireDestination(plan.workspace, store: store)
        if plan.kind == .agent { return installedProfile(record, store: store) != nil }
        if plan.kind == .hooks {
            guard (try? installedURL(record, store: store)) != nil else { return false }
            guard try store.hooks.importedReceipt(record.targetID, workspace: plan.workspace)?.sourceHash == record.sourceHash else {
                throw PetError("此范围的 Hooks 导入记录已变化，请重新检测")
            }
            return true
        }
        let (files, target) = try destination(plan, store: store)
        let current = try files.entryMetadata(target)
        if current.kind == "missing" { return false }
        guard current.kind == "file" else { throw PetError("目标文件已存在，保留现有内容") }
        let bytes = try read(target, from: files)
        guard AgentFiles.hash(bytes) == installedHash(record, plan) else { throw PetError("目标文件已存在，保留现有内容") }
        try validateReferences(bytes, target: target, files: files, record: record, plan: plan)
        return true
    }

    @MainActor private static func install(_ record: AgentImportCandidate, plan: AgentStandaloneImportPlan, file: URL,
                                           location: Location, store: AgentStore) async throws {
        try Task.checkCancellation()
        guard try location.entry(file) == plan, !location.project || plan.workspace != nil else {
            throw PetError("来源或项目已变化，请重新检测")
        }
        let bytes = try location.read(file, plan: plan)
        guard AgentFiles.hash(bytes) == record.rawHash else { throw PetError("来源已变化，请重新检测") }
        if plan.kind == .agent || plan.kind == .hooks {
            guard plan.directory.isEmpty else { throw PetError("来源或项目已变化，请重新检测") }
            try installExecutionConfiguration(record, plan: plan, file: file, bytes: bytes, location: location, store: store)
            return
        }
        let (files, target) = try destination(plan, store: store)
        let payload = plan.kind == .command ? try commandPayload(bytes, text: text(bytes), plan: plan, source: record.source).data : bytes
        let observedHash = plan.kind == .command ? AgentFiles.hash(payload) :
            try await sourceFingerprint(bytes, file: file, location: location, plan: plan, target: target, destination: files)
        guard observedHash == record.sourceHash else { throw PetError("来源已变化，请重新检测") }
        try Task.checkCancellation()
        try AgentMCPDataImport.requireDestination(plan.workspace, store: store)
        try validateReferences(bytes, target: target, files: files, record: record, plan: plan)
        var rule: AgentRuleDefinition?
        if plan.kind == .rule {
            let directories = plan.workspace.flatMap { workspace in plan.directory.isEmpty ? nil : AgentRuleDirectory(workspace: workspace, path: plan.directory) }.map { [$0] } ?? []
            guard try store.rules.catalog(workspace: plan.workspace, directories: directories).count < 256 else { throw PetError("当前范围最多支持 256 项规则") }
            rule = try AgentRuleDocument.parse(text(bytes), path: plan.relative, fallback: plan.commandName)
        } else if plan.kind == .command {
            guard try !store.extensions.catalog(workspace: plan.workspace).contains(where: { $0.kind == .command && $0.name.caseInsensitiveCompare(plan.commandName) == .orderedSame }) else {
                throw PetError("同名命令已存在，保留现有配置")
            }
        }
        if payload == bytes {
            try files.copyFile(file, from: location.files, to: target, expectedHash: record.rawHash, expectedTarget: "missing", maximum: 65_536)
        } else {
            try files.writeData(payload, to: target, permissions: 0o600, expectedTarget: "missing")
        }
        if let rule {
            let id = "local-rule-" + AgentFiles.hash(Data(target.path.utf8)).prefix(32)
            store.rules.onChange?(id, plan.workspace, rule.trigger == .always || rule.trigger == .decision)
        } else if plan.kind == .instruction {
            store.instructions.onChange?(nil, plan.workspace)
        }
    }

    @MainActor static func installedProfile(_ record: AgentImportCandidate, store: AgentStore) -> AgentProfile? {
        guard let plan = record.configuration, plan.kind == .agent,
              (try? AgentMCPDataImport.requireDestination(plan.workspace, store: store)) != nil else { return nil }
        return (try? store.agents.list(workspace: plan.workspace))?.first {
            $0.id == record.targetID && $0.sourceWorkspace == plan.workspace && $0.pluginSource == nil
        }
    }

    @MainActor private static func installExecutionConfiguration(_ record: AgentImportCandidate, plan: AgentStandaloneImportPlan,
                                                                file: URL, bytes: Data, location: Location, store: AgentStore) throws {
        if try alreadyInstalled(record, plan: plan, store: store) { return }
        if plan.kind == .agent {
            let (value, _) = try AgentStandaloneRoleImport.profile(bytes, source: record.source, file: file, id: record.targetID, workspace: plan.workspace, store: store)
            guard value.name == record.title,
                  try AgentFiles.hash(Data((record.rawHash + store.agents.encode([value])).utf8)) == record.sourceHash else {
                throw PetError("智能体内容或引用的扩展已变化，请重新检测")
            }
            try AgentStandaloneRoleImport.install(value, workspace: plan.workspace, store: store)
            return
        }
        let (files, target) = try store.hooks.importedConfiguration(record.targetID, workspace: plan.workspace)
        guard try store.hooks.importedConfigurations(workspace: plan.workspace).count < 128 else { throw PetError("同一范围最多 128 份独立 Hooks 配置") }
        guard let events = try location.events(bytes, file: file),
              var bundle = try AgentStandaloneHookPackage.prepare(events, source: record.source, file: file, files: location.files,
                projectSource: location.project, target: target, workspace: plan.workspace, service: store.hooks,
                mcpOnly: record.standaloneMCPHooks == true,
                originalResourcePath: try location.originalHookDirectory(file, mcpOnly: record.standaloneMCPHooks == true)),
              AgentFiles.hash(Data((record.rawHash + bundle.fingerprint).utf8)) == record.sourceHash else {
            throw PetError("来源 Hooks 或资源已变化，请重新检测")
        }
        bundle.files["receipt.json"] = try JSONEncoder().encode(AgentImportedHookReceipt(originalName: plan.relative, sourceHash: record.sourceHash))
        try files.publishDirectory(bundle.files, to: target.deletingLastPathComponent(), label: "Hooks", executable: bundle.executable) { staging in
            for (path, data) in bundle.files {
                guard try staging.fileHash(staging.literalURL(path), maximum: 1_000_000) == AgentFiles.hash(data) else { throw PetError("Hooks 资源未完整发布") }
            }
        }
    }
}
