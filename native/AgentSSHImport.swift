import Foundation
import BlueFatFishTerminal
import Darwin

/// Remote paths are arguments to fixed read-only scripts.
/// Preview decoding retains one record or Skill package at a time.
struct AgentSSHImport: Sendable {
    let profile: URL
    let home: URL?
    static let categories: [AgentImportCategory] = [.tasks, .memory, .skills, .connectors, .automations, .plugins]

    static func valid(host: String, root: String) -> Bool {
        guard TerminalSurface.validSSHDestination(host), root.utf8.count <= 4096,
              root.rangeOfCharacter(from: .controlCharacters) == nil,
              root == "~" || root.hasPrefix("~/") || root.hasPrefix("/") else { return false }
        return !root.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    private static func validFile(_ path: String, source: AgentImportSource) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, path.utf8.count <= 16_384,
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              AgentImportReaders.sessionDirectories(source).contains(String(components[0])),
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
              let file = components.last, file.hasSuffix(".jsonl") else { return false }
        return source == .codex || UUID(uuidString: String(file.dropLast(6))) != nil
    }

    func discover(_ route: AgentImportRoute) async throws -> [AgentImportCandidate] {
        guard route.category == .tasks else { throw PetError("缺少 SSH 任务来源") }
        let directories = AgentImportReaders.sessionDirectories(route.source)
        let pattern = route.source == .codex ? "*.jsonl" : "????????-????-????-????-????????????.jsonl"
        return try await response(route, script: Self.scan, arguments: [String(AgentImportReaders.maximumBytes), pattern] + directories,
                                  timeout: 1800) { input in
            try Self.parseScan(input, route: route)
        }
    }

    func discoverMemory(_ route: AgentImportRoute) async throws -> [AgentMemoryImport.Preview] {
        try await memoryResponse(route, wanted: "") { input in
            let records: [AgentMemoryImport.Preview] = try Self.scanFrames(input, maximum: AgentMemoryImport.maximumBytes,
                                                                          oversized: "来源记忆文件超过 4 MB") { path, bytes in
                guard Self.validMemoryFile(path, route: route) else { return nil }
                return AgentMemoryImport.preview(route.source, file: Self.prefix(route) + path, workspace: route.workspace, sshHost: route.sshHost) {
                    try bytes.get()
                }
            }
            return records.sorted { $0.record.file.localizedStandardCompare($1.record.file) == .orderedAscending }
        }
    }

    func readMemory(_ record: AgentImportCandidate, route: AgentImportRoute) async throws -> Data {
        let prefix = Self.prefix(route), path = String(record.file.dropFirst(prefix.count))
        guard record.sshHost == route.sshHost, record.source == route.source, record.category == .memory,
              record.targetWorkspace == route.workspace, record.file.hasPrefix(prefix), Self.validMemoryFile(path, route: route) else {
            throw PetError("SSH 记忆与原来源不符，请重新检测")
        }
        return try await memoryResponse(route, wanted: path) { input in
            let files: [Data] = try Self.scanFrames(input, maximum: AgentMemoryImport.maximumBytes, oversized: "来源记忆文件超过 4 MB") { name, bytes in
                guard name == path else { throw FrameError.invalid }
                return try bytes.get()
            }
            guard files.count == 1, let data = files.first else { throw PetError("远端记忆文件已移除或离开检测目录") }
            return data
        }
    }

    private func memoryResponse<Value>(_ route: AgentImportRoute, wanted: String,
                                       decode: @escaping @Sendable (FileHandle) throws -> Value) async throws -> Value {
        guard route.category == .memory else { throw PetError("缺少 SSH 记忆来源") }
        let arguments = [String(AgentMemoryImport.maximumBytes), route.source.rawValue,
                         route.workspace == nil ? "global" : "project", route.source.homeName, wanted]
        return try await response(route, script: Self.scanMemory, arguments: arguments + AgentMemoryImport.folders(for: route.source),
                                  timeout: wanted.isEmpty ? 1800 : 60, decode: decode)
    }

    private static func validMemoryFile(_ path: String, route: AgentImportRoute) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let folders = AgentMemoryImport.folders(for: route.source)
        guard (1...2).contains(parts.count), let name = parts.last,
              parts.count == 1 || folders.contains(String(parts[0])) else { return false }
        let folder = parts.count == 2 ? String(parts[0]) : (route.root as NSString).lastPathComponent
        return AgentMemoryImport.allowed(String(name), consolidated: route.source == .codex && folders.contains(folder))
    }

    func discoverSkills(_ route: AgentImportRoute) async throws -> [AgentImportCandidate] {
        try await skillsResponse(route, wanted: "") { input in
            try Self.scanSkillFrames(input, route: route) { file, package in
                AgentSkillImport.preview(route.source, file: Self.prefix(route) + file, workspace: route.workspace, sshHost: route.sshHost) {
                    try package.get()
                }
            }.sorted { $0.file.localizedStandardCompare($1.file) == .orderedAscending }
        }
    }

    func readSkill(_ record: AgentImportCandidate, route: AgentImportRoute) async throws -> AgentSkillPackage {
        let prefix = Self.prefix(route), file = String(record.file.dropFirst(prefix.count))
        guard record.sshHost == route.sshHost, record.source == route.source, record.category == .skills,
              record.targetWorkspace == route.workspace, record.file.hasPrefix(prefix), Self.validSkillDefinition(file, source: route.source) else {
            throw PetError("SSH Skill 与原来源不符，请重新检测")
        }
        return try await skillsResponse(route, wanted: file) { input in
            let packages: [AgentSkillPackage] = try Self.scanSkillFrames(input, route: route) { path, package in
                guard path == file else { throw FrameError.invalid }
                return try package.get()
            }
            guard packages.count == 1, let package = packages.first else { throw PetError("远端 Skill 已移除或离开检测目录") }
            return package
        }
    }

    private func skillsResponse<Value>(_ route: AgentImportRoute, wanted: String,
                                      decode: @escaping @Sendable (FileHandle) throws -> Value) async throws -> Value {
        guard route.category == .skills else { throw PetError("缺少 SSH Skills 来源") }
        let arguments = [wanted, route.source.homeName, String(AgentSkillPackage.maximumEntries),
                         String(AgentSkillPackage.maximumFileBytes), String(AgentSkillPackage.maximumTotalBytes),
                         String(AgentImportReaders.maximumRecords)]
        return try await response(route, script: Self.scanSkills, arguments: arguments + AgentSkillImport.containerPaths(for: route.source),
                                  timeout: wanted.isEmpty ? 1800 : 60, decode: decode)
    }

    private static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.rangeOfCharacter(from: .controlCharacters) == nil &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func validSkillDefinition(_ path: String, source: AgentImportSource) -> Bool {
        guard validRelativePath(path) else { return false }
        let parts = path.split(separator: "/")
        guard parts.last == "SKILL.md" else { return false }
        if parts.count == 1 || parts.count == 2 && !parts[0].hasPrefix(".") { return true }
        return AgentSkillImport.containerPaths(for: source).contains { directory in
            guard path.hasPrefix(directory + "/") else { return false }
            let leaf = path.dropFirst(directory.count + 1).split(separator: "/")
            return leaf.count == 1 || leaf.count == 2 && !leaf[0].hasPrefix(".")
        }
    }

    private static func scanSkillFrames<Value>(_ input: FileHandle, route: AgentImportRoute,
                                               decode: (String, Result<AgentSkillPackage, Error>) throws -> Value) throws -> [Value] {
        var reader = ResponseReader(input: input), result: [Value] = []
        guard try reader.field(limit: 16) == "BFF-SKILLS-1" else { throw FrameError.invalid }
        while true {
            let definition = try reader.field(limit: 4096)
            if definition.isEmpty { break }
            guard validSkillDefinition(definition, source: route.source) else { throw FrameError.invalid }
            guard result.count < AgentImportReaders.maximumRecords else { throw PetError("来源超过 5000 份 Skills，请分别导入") }
            let value = try autoreleasepool {
                let package = try readSkillPackage(&reader, file: prefix(route) + definition)
                return try decode(definition, package)
            }
            result.append(value)
        }
        guard try !reader.hasByte() else { throw FrameError.invalid }
        return result
    }

    private static func readSkillPackage(_ reader: inout ResponseReader, file: String) throws -> Result<AgentSkillPackage, Error> {
        var resources: [String: Data] = [:], names = Set<String>(), count = 0, total = 0
        while true {
            let path = try reader.field(limit: 4096)
            if path.isEmpty { break }
            let field = try reader.field(limit: 10)
            count += 1
            guard count <= AgentSkillPackage.maximumEntries, validRelativePath(path),
                  !AgentSkillPackage.ignoresResource(path), !AgentFiles.sensitive(path),
                  let size = Int(field), (0...AgentSkillPackage.maximumFileBytes).contains(size),
                  size <= AgentSkillPackage.maximumTotalBytes - total else { throw FrameError.invalid }
            total += size
            names.insert(path.precomposedStringWithCanonicalMapping.lowercased())
            resources[path] = try reader.body(count: size)
        }
        let status = try reader.field(limit: 2)
        let issue: String
        switch status {
        case "0":
            guard names.count == count else { return .failure(PetError("Skill 资源路径重复")) }
            let name = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return Result { try AgentSkillPackage(resources: resources, fallbackName: name) }
        case "43": issue = "远端 Skill 来源已变化或无法读取"
        case "47": issue = "Skill 资源含符号链接，请先整理为普通文件"
        case "48": issue = "Skill 资源含受保护文件"
        case "49": issue = "Skill 资源超过 2000 项，请缩小目录"
        case "50": issue = "Skill 单份资源超过 2 MB"
        case "51": issue = "Skill 资源总量超过 20 MB"
        case "52": issue = "Skill 资源路径无效或包含特殊文件"
        default: throw FrameError.invalid
        }
        return .failure(PetError(issue))
    }

    func discoverAutomations(_ route: AgentImportRoute) async throws -> [AgentImportCandidate] {
        let explicit = Self.explicitAutomationFile(route)
        return try await automationResponse(route, explicit: explicit, wanted: "") { input in
            let groups: [[AgentImportCandidate]] = try Self.scanFrames(input, maximum: AgentAutomationDataImport.maximumBytes(route.source),
                                                                       oversized: "远端定时任务文件超过大小限制") { path, bytes in
                guard Self.validRelativePath(path), AgentAutomationDataImport.allows(path, source: route.source),
                      explicit == nil || explicit == path else { throw FrameError.invalid }
                let file = explicit == nil ? Self.prefix(route) + path : route.root
                return try AgentAutomationDataImport.preview(route.source, file: file, workspace: route.workspace, sshHost: route.sshHost) {
                    try bytes.get()
                }
            }
            let records = groups.flatMap { $0 }
            guard records.count <= AgentAutomationDataImport.maximumRows else { throw PetError("计划项目过多，请分别选择来源文件") }
            return records.sorted { $0.file.localizedStandardCompare($1.file) == .orderedAscending }
        }
    }

    func readAutomation(_ record: AgentImportCandidate, route: AgentImportRoute) async throws -> Data {
        let explicit = Self.explicitAutomationFile(route), prefix = Self.prefix(route)
        let path: String
        if let explicit, record.file == route.root { path = explicit }
        else if explicit == nil && record.file.hasPrefix(prefix) { path = String(record.file.dropFirst(prefix.count)) }
        else { throw PetError("SSH 定时任务与原来源不符，请重新检测") }
        guard record.sshHost == route.sshHost, record.source == route.source, record.category == .automations,
              record.targetWorkspace == route.workspace, Self.validRelativePath(path), AgentAutomationDataImport.allows(path, source: route.source) else {
            throw PetError("SSH 定时任务与原来源不符，请重新检测")
        }
        return try await automationResponse(route, explicit: explicit, wanted: path) { input in
            let files: [Data] = try Self.scanFrames(input, maximum: AgentAutomationDataImport.maximumBytes(route.source),
                                                                   oversized: "远端定时任务文件超过大小限制") { file, bytes in
                guard file == path else { throw FrameError.invalid }
                return try bytes.get()
            }
            guard files.count == 1, let data = files.first else { throw PetError("远端定时任务文件已移除或离开检测目录") }
            return data
        }
    }

    private static func explicitAutomationFile(_ route: AgentImportRoute) -> String? {
        let name = AgentAutomationDataImport.fileName(route.source)
        return route.root.hasSuffix("/" + name) ? name : nil
    }

    private func automationResponse<Value>(_ route: AgentImportRoute, explicit: String?, wanted: String,
                                          decode: @escaping @Sendable (FileHandle) throws -> Value) async throws -> Value {
        guard route.category == .automations, let host = route.sshHost, Self.valid(host: host, root: route.root) else {
            throw PetError("缺少有效的 SSH 定时任务来源")
        }
        let directory = explicit.map { String(route.root.dropLast($0.count)) } ?? route.root
        let transfer = AgentImportRoute(source: route.source, category: route.category, root: directory, workspace: route.workspace, sshHost: host)
        let arguments = [String(AgentAutomationDataImport.maximumBytes(route.source)), AgentAutomationDataImport.fileName(route.source),
                         route.source.rawValue, explicit ?? "", wanted, String(AgentAutomationDataImport.maximumRows)]
        return try await response(transfer, script: Self.scanAutomations, arguments: arguments,
                                  timeout: wanted.isEmpty ? 1800 : 60, decode: decode)
    }

    func discoverConnectors(_ route: AgentImportRoute) async throws -> [AgentImportCandidate] {
        let explicit = Self.explicitConnectorFile(route)
        return try await connectorResponse(route, explicit: explicit, wanted: "") { input in
            let groups: [[AgentImportCandidate]] = try Self.scanFrames(input, maximum: AgentMCPDataImport.maximumProjectionBytes,
                oversized: "远端连接器配置超过大小限制") { path, bytes in
                guard Self.validConnectorPath(path, source: route.source, explicit: explicit) else { throw FrameError.invalid }
                let file = explicit == nil ? Self.prefix(route) + path : route.root
                return try AgentMCPDataImport.previewRemote(route.source, file: file, workspace: route.workspace, host: route.sshHost) {
                    try bytes.get()
                }
            }
            return groups.flatMap { $0 }
        }
    }

    func readConnector(_ record: AgentImportCandidate, route: AgentImportRoute) async throws -> Data {
        let explicit = Self.explicitConnectorFile(route), prefix = Self.prefix(route)
        let path: String
        if let explicit, record.file == route.root { path = explicit }
        else if explicit == nil && record.file.hasPrefix(prefix) { path = String(record.file.dropFirst(prefix.count)) }
        else { throw PetError("SSH 连接器与原来源不符，请重新检测") }
        guard record.sshHost == route.sshHost, record.source == route.source, record.category == .connectors,
              record.targetWorkspace == route.workspace, Self.validConnectorPath(path, source: route.source, explicit: explicit) else {
            throw PetError("SSH 连接器与原来源不符，请重新检测")
        }
        return try await connectorResponse(route, explicit: explicit, wanted: path) { input in
            let files: [Data] = try Self.scanFrames(input, maximum: AgentMCPDataImport.maximumProjectionBytes,
                oversized: "远端连接器配置超过大小限制") { file, bytes in
                guard file == path else { throw FrameError.invalid }
                return try bytes.get()
            }
            guard files.count == 1, let data = files.first else { throw PetError("远端连接器文件已移除或离开检测目录") }
            return data
        }
    }

    private static func explicitConnectorFile(_ route: AgentImportRoute) -> String? {
        let name = (route.root as NSString).lastPathComponent
        return !route.root.hasSuffix("/") && AgentMCPDataImport.acceptsFile(name, source: route.source) ? name : nil
    }

    private static func validConnectorPath(_ path: String, source: AgentImportSource, explicit: String?) -> Bool {
        guard validRelativePath(path) else { return false }
        if let explicit { return path == explicit }
        return AgentMCPDataImport.locations(source).contains { $0.path == path }
    }

    private func connectorResponse<Value>(_ route: AgentImportRoute, explicit: String?, wanted: String,
                                         decode: @escaping @Sendable (FileHandle) throws -> Value) async throws -> Value {
        guard route.category == .connectors, let host = route.sshHost, Self.valid(host: host, root: route.root) else {
            throw PetError("缺少有效的 SSH 连接器来源")
        }
        let directory = explicit.map { String(route.root.dropLast($0.count)) } ?? route.root
        let transfer = AgentImportRoute(source: route.source, category: route.category, root: directory, workspace: route.workspace, sshHost: host)
        let locations = AgentMCPDataImport.locations(route.source).flatMap { [$0.path, $0.project ? "project" : "global"] }
        let arguments = [route.source.rawValue, route.source.homeName, explicit ?? "", wanted, String(AgentMCPDataImport.maximumBytes),
                         String(AgentMCPDataImport.maximumProjectionBytes), AgentMCP.importPlaceholder,
                         AgentMCPDataImport.credentialSuffixes.joined(separator: ",")] + locations
        return try await response(transfer, script: Self.scanConnectors, arguments: arguments, timeout: 60, decode: decode)
    }

    func pluginSources(_ route: AgentImportRoute) async throws -> [AgentSSHPluginSource] {
        let explicit = Self.explicitPluginFile(route)
        return try await pluginResponse(route, explicit: explicit, selected: "") { input in
            let entries: [[AgentSSHPluginSource]] = try Self.scanFrames(input, maximum: 2_000_000,
                oversized: "远端插件目录清单过大") { path, bytes in
                guard path == ".source" else { throw FrameError.invalid }
                return try JSONDecoder().decode([AgentSSHPluginSource].self, from: bytes.get())
            }
            guard entries.count == 1, let sources = entries.first, sources.count <= 4096,
                  Set(sources.map(\.path)).count == sources.count else { throw FrameError.invalid }
            for item in sources {
                guard Self.validPluginPath(item.path, explicit: explicit) else { throw FrameError.invalid }
                if let group = item.versionGroup {
                    guard route.source == .codex, Self.validRelativePath(group),
                          item.path.hasPrefix(group + "/"), !item.path.dropFirst(group.count + 1).contains("/") else { throw FrameError.invalid }
                }
            }
            return sources
        }
    }

    static func pluginFile(_ path: String, route: AgentImportRoute) -> String {
        path == "." || explicitPluginFile(route) != nil ? route.root : prefix(route) + path
    }

    func readPlugin(_ record: AgentImportCandidate, route: AgentImportRoute) async throws -> AgentSSHPluginPayload {
        let prefix = Self.prefix(route), explicit = Self.explicitPluginFile(route)
        guard record.sshHost == route.sshHost, record.source == route.source, record.category == .plugins,
              record.targetWorkspace == route.workspace else { throw PetError("SSH 插件与原来源不符，请重新检测") }
        if record.file == route.root { return try await readPlugin(explicit ?? ".", route: route) }
        guard explicit == nil, record.file.hasPrefix(prefix) else { throw PetError("SSH 插件与原来源不符，请重新检测") }
        return try await readPlugin(String(record.file.dropFirst(prefix.count)), route: route)
    }

    func readPlugin(_ path: String, route: AgentImportRoute) async throws -> AgentSSHPluginPayload {
        let explicit = Self.explicitPluginFile(route)
        guard Self.validPluginPath(path, explicit: explicit) else { throw PetError("SSH 插件来源路径无效") }
        return try await pluginResponse(route, explicit: explicit, selected: path, decode: Self.decodePlugin)
    }

    private static func decodePlugin(_ input: FileHandle) throws -> AgentSSHPluginPayload {
        struct Metadata: Decodable { let archive, project: Bool }
        var total = 0, names = Set<String>()
        let members: [(String, Data)] = try scanFrames(input, maximum: AgentArchive.maximumBytes,
            oversized: "远端插件资源超过大小限制") { path, bytes in
            let data = try bytes.get()
            guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw FrameError.invalid }
            if path == ".source" {
                guard data.count <= 4096 else { throw FrameError.invalid }
            } else {
                total += data.count
                guard total <= AgentArchive.maximumBytes, names.count <= AgentArchive.maximumMembers + 1 else { throw FrameError.invalid }
                if path != ".archive" {
                    guard AgentArchive.validPath(path), !path.hasSuffix("/"), !AgentFiles.sensitive(path),
                          AgentArchive.included(path, hiddenRoots: AgentImportedPlugin.hiddenRoots),
                          data.count <= AgentArchive.maximumMemberBytes else { throw FrameError.invalid }
                }
            }
            return (path, data)
        }
        var files = Dictionary(uniqueKeysWithValues: members)
        guard let descriptor = files.removeValue(forKey: ".source") else { throw FrameError.invalid }
        let info = try JSONDecoder().decode(Metadata.self, from: descriptor)
        if info.archive {
            guard files.count == 1, let archive = files[".archive"] else { throw FrameError.invalid }
            return .init(project: info.project, content: .archive(archive))
        }
        guard files[".archive"] == nil else { throw FrameError.invalid }
        return .init(project: info.project, content: .directory(files))
    }

    private static func explicitPluginFile(_ route: AgentImportRoute) -> String? {
        let name = (route.root as NSString).lastPathComponent
        return !route.root.hasSuffix("/") && (name as NSString).pathExtension.lowercased() == "zip" ? name : nil
    }

    private static func validPluginPath(_ path: String, explicit: String?) -> Bool {
        if let explicit { return path == explicit && validRelativePath(path) }
        return path == "." || validRelativePath(path) && path.utf8.count <= 4096
    }

    private func pluginResponse<Value>(_ route: AgentImportRoute, explicit: String?, selected: String,
                                      decode: @escaping @Sendable (FileHandle) throws -> Value) async throws -> Value {
        guard route.category == .plugins, let host = route.sshHost, Self.valid(host: host, root: route.root) else {
            throw PetError("缺少有效的 SSH 插件来源")
        }
        let directory = explicit.map { String(route.root.dropLast($0.count)) } ?? route.root
        let transfer = AgentImportRoute(source: route.source, category: route.category, root: directory, workspace: route.workspace, sshHost: host)
        let options = [AgentImportedPlugin.manifests, AgentImportedPlugin.hiddenRoots.sorted(), AgentImportedPlugin.conventionalRoots,
                       AgentFiles.sensitiveNames, AgentFiles.sensitiveExtensions]
        let arguments = [route.source.rawValue, route.source.homeName, explicit ?? "", selected] + (try options.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }) + [String(AgentArchive.maximumMembers), String(AgentArchive.maximumMemberBytes), String(AgentArchive.maximumBytes)]
        return try await response(transfer, script: AgentSSHPluginSource.script, arguments: arguments, timeout: 60, decode: decode)
    }

    private static func prefix(_ route: AgentImportRoute) -> String {
        route.root.hasSuffix("/") ? route.root : route.root + "/"
    }

    func read(_ record: AgentImportCandidate, route: AgentImportRoute) async throws -> AgentImportDocument {
        let prefix = Self.prefix(route)
        let file = String(record.file.dropFirst(prefix.count))
        guard route.category == .tasks, record.sshHost == route.sshHost, record.source == route.source, record.category == .tasks,
              record.file.hasPrefix(prefix), Self.validFile(file, source: route.source) else { throw PetError("SSH 记录与原来源不符，请重新检测") }
        let maximum = AgentImportReaders.maximumBytes
        let bytes = try await response(route, script: Self.readFile, arguments: [file, String(maximum + 1)], timeout: 60) { input in
            var reader = ResponseReader(input: input)
            return try reader.record(maximum: maximum)
        }
        return try await Task.detached(priority: .utility) { try Self.decode(bytes, file: file, route: route) }.value
    }

    private static func decode(_ bytes: Data, file: String, route: AgentImportRoute) throws -> AgentImportDocument {
        return try AgentImportReaders.decode(route.source, file: prefix(route) + file, raw: bytes,
            sshHost: route.sshHost, archived: file.hasPrefix("archived_sessions/"))
    }

    private static func parseScan(_ input: FileHandle, route: AgentImportRoute) throws -> [AgentImportCandidate] {
        let records: [AgentImportCandidate] = try scanFrames(input, maximum: AgentImportReaders.maximumBytes,
                                                            oversized: "来源超过64 MB") { path, bytes in
            guard validFile(path, source: route.source) else { return nil }
            do { return try decode(bytes.get(), file: path, route: route).candidate }
            catch {
                let file = (path as NSString).lastPathComponent
                let id = "invalid-" + AgentFiles.hash(Data(path.utf8))
                return .init(source: route.source, sourceID: id, file: prefix(route) + path, rawHash: "", sourceHash: "",
                    title: file, created: Date(), updated: Date(), issue: error.localizedDescription, sshHost: route.sshHost)
            }
        }
        return records.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id < $1.id }
    }

    private static func scanFrames<Value>(_ input: FileHandle, maximum: Int, oversized: String,
                                          decode: (String, Result<Data, PetError>) throws -> Value?) throws -> [Value] {
        var reader = ResponseReader(input: input)
        guard try reader.field(limit: 16) == "BFF-SESSIONS-1" else { throw FrameError.invalid }
        var result: [Value] = [], count = 0
        while true {
            let path = try reader.field(limit: 16_384)
            if path.isEmpty { break }
            count += 1
            guard count <= AgentImportReaders.maximumRecords else { throw PetError("来源超过5000份记录，请选择较小的来源副本") }
            let length = try reader.field(limit: 10)
            let contents: Result<Data, PetError>
            if length == "-" { contents = .failure(PetError(oversized)) }
            else if length == "?" { contents = .failure(PetError("无法读取远端文件")) }
            else {
                guard let size = Int(length), (0...maximum).contains(size) else { throw FrameError.invalid }
                contents = .success(try reader.body(count: size))
            }
            if let candidate = try autoreleasepool(invoking: { try decode(path, contents) }) { result.append(candidate) }
        }
        guard try !reader.hasByte() else { throw FrameError.invalid }
        return result
    }

    private enum FrameError: LocalizedError, Equatable {
        case incomplete, invalid

        var errorDescription: String? { "SSH 来源传输不完整或格式异常，请重新检测" }
    }

    private struct ResponseReader {
        let input: FileHandle
        private var buffer = Data(), offset = 0

        init(input: FileHandle) { self.input = input }

        mutating func hasByte() throws -> Bool {
            if offset < buffer.count { return true }
            buffer = try autoreleasepool { try input.read(upToCount: 64 * 1024) ?? Data() }
            offset = 0
            return !buffer.isEmpty
        }

        mutating func field(limit: Int) throws -> String {
            var bytes = Data()
            while try hasByte() {
                let end = buffer[offset...].firstIndex(of: 0)
                let next = end ?? buffer.count
                guard bytes.count + next - offset <= limit else { throw FrameError.invalid }
                bytes.append(buffer[offset..<next])
                offset = next
                if end != nil {
                    offset += 1
                    guard let field = String(data: bytes, encoding: .utf8) else { throw FrameError.invalid }
                    return field
                }
            }
            throw FrameError.incomplete
        }

        mutating func body(count: Int) throws -> Data {
            var bytes = Data()
            bytes.reserveCapacity(count)
            while bytes.count < count {
                guard try hasByte() else { throw FrameError.incomplete }
                let next = min(buffer.count, offset + count - bytes.count)
                bytes.append(buffer[offset..<next])
                offset = next
            }
            return bytes
        }

        mutating func record(maximum: Int) throws -> Data {
            var bytes = Data()
            while try hasByte() {
                let chunk = buffer[offset...]
                guard chunk.count <= maximum - bytes.count else { throw PetError("来源超过64 MB，请选择较小的记录") }
                bytes.append(chunk)
                offset = buffer.count
            }
            return bytes
        }
    }

    private func response<Value>(_ route: AgentImportRoute, script: String, arguments: [String], timeout: Double,
                                 decode: @escaping @Sendable (FileHandle) throws -> Value) async throws -> Value {
        guard let host = route.sshHost, Self.valid(host: host, root: route.root), Self.categories.contains(route.category),
              route.category != .tasks || route.workspace == nil else {
            throw PetError("请填写有效的 SSH 主机与远程目录")
        }
        try Task.checkCancellation()
        let scratch = profile.appendingPathComponent("ssh-import-transfer-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("read-session.sh")
        try Data((Self.enterDirectory + script).utf8).write(to: input)
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw PetError("无法打开 SSH 传输管道") }
        let reader = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        guard descriptors.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else { throw PetError("无法配置 SSH 传输管道") }
        let command = AgentCommand()
        async let transfer: Void = run(command, host: host, root: route.root, category: route.category, arguments: arguments, scratch: scratch,
                                       input: input, output: writer, timeout: timeout)
        let parsed: Result<Value, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try decode(reader) }
                try? reader.close()
                continuation.resume(returning: result)
            }
        }
        switch parsed {
        case .success(let value):
            try await transfer
            try Task.checkCancellation()
            return value
        case .failure(let error as FrameError) where error == .incomplete:
            try await transfer
            throw error
        case .failure(let error):
            command.cancel()
            _ = try? await transfer
            try Task.checkCancellation()
            throw error
        }
    }

    private func run(_ command: AgentCommand, host: String, root: String, category: AgentImportCategory, arguments: [String], scratch: URL,
                     input: URL, output: FileHandle, timeout: Double) async throws {
        defer { try? output.close() }
        let fm = FileManager.default
        let systemHome = fm.homeDirectoryForCurrentUser
        let privateHome = home.flatMap { $0.standardizedFileURL == systemHome.standardizedFileURL ? nil : $0 }
        let sshDirectory = (privateHome ?? systemHome).appendingPathComponent(".ssh", isDirectory: true)
        var ssh = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
                   "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no",
                   "-o", "ControlPath=none", "-o", "ForkAfterAuthentication=no", "-o", "StdinNull=no", "-o", "PermitLocalCommand=no",
                   "-o", "RemoteCommand=none", "-o", "SessionType=default", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        if privateHome != nil { ssh += ["-F", sshDirectory.appendingPathComponent("config").path] }
        let remote = "/bin/sh -s -- " + ([root] + arguments).map(Self.shellQuote).joined(separator: " ")
        ssh += ["--", host, remote]
        var environment = ["SSH_ASKPASS_REQUIRE": "never"]
        if privateHome == nil { environment["SSH_AUTH_SOCK"] = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] }
        let result = try await command.run(command: "/usr/bin/ssh", workspace: scratch, scratch: scratch, network: true,
            timeout: timeout, readOnly: true, maximumOutput: 8192, protectedData: profile, inputFile: input, outputDescriptor: output.fileDescriptor,
            readRoots: [sshDirectory], sshClient: true, environment: environment,
            arguments: ssh)
        if result.timedOut == true { throw PetError("读取 SSH 来源超时，请重新检测") }
        if result.failed {
            let diagnostic = result.stderr?.lowercased() ?? ""
            if diagnostic.contains("host identification has changed") { throw PetError("SSH 主机密钥已变化，请核对主机身份") }
            if diagnostic.contains("host key verification failed") { throw PetError("SSH 主机尚未验证，请先核对已知主机密钥") }
            if diagnostic.contains("permission denied") && result.exitCode == 255 { throw PetError("SSH 无法使用当前密钥登录，请检查本机配置") }
            if result.exitCode == 42 { throw PetError("找不到远程" + (category == .tasks ? "会话" : category.title) + "目录，或目录不可读取") }
            if result.exitCode == 43 { throw PetError("远端来源文件已移动、不可读取或是链接，请重新检测") }
            if result.exitCode == 44 { throw PetError("未找到远程记忆文件夹，请核对 SSH 来源目录") }
            if result.exitCode == 45 {
                if category == .plugins { throw PetError("插件来源目录过大，请选择较小的目录") }
                throw PetError((category == .automations ? "定时任务" : "Skill") + "来源项目过多，请选择较小的目录")
            }
            if result.exitCode == 46 { throw PetError("请为 Qoder 项目记忆选择目标项目") }
            if result.exitCode == 47, category == .connectors {
                throw PetError("远端缺少连接器解析组件，需要 Python " + (arguments.first == "codex" ? "3.11 或更高版本" : "3.8 或更高版本"))
            }
            if category == .plugins {
                let issues = [47: "远端读取插件需要 Python 3.8 或更高版本", 48: "插件含受保护文件、链接或特殊文件",
                              49: "插件路径重复或资源超过数量限制", 50: "插件资源或压缩包超过大小限制",
                              51: "插件资源总量超过 20 MB", 52: "插件来源或资源路径无效", 53: "远端插件在读取期间已变化，请重新检测"]
                if let code = result.exitCode, let issue = issues[Int(code)] { throw PetError(issue) }
            }
            throw PetError("无法读取 SSH 来源，请检查连接与远端目录后重试")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let enterDirectory = #"""
    export PATH=/usr/bin:/bin LC_ALL=C
    root=$1
    shift
    case "$root" in
        '~') root="$HOME" ;;
        '~/'*) root="$HOME/${root#??}" ;;
    esac
    cd -P "$root" || exit 42
    """# + "\n"

    private static let emitRecord = #"""
    emit_file() {
        if ! size=$(wc -c 2>/dev/null < "$1"); then
            printf "%s\0?\0" "${1#./}"
            return
        fi
        size=$((size + 0))
        if [ "$size" -gt "$limit" ]; then
            printf "%s\0-\0" "${1#./}"
        else
            printf "%s\0%s\0" "${1#./}" "$size"
            head -c "$size" "$1"
        fi
    }
    """# + "\n"

    private static let scan = #"""
    limit=$1
    pattern=$2
    shift 2
    found=no
    printf 'BFF-SESSIONS-1\0'
    for directory do
        [ -d "$directory" ] && [ ! -L "$directory" ] || continue
        found=yes
        find "$directory" -name '.*' -prune -o -type f -name "$pattern" -exec /bin/sh -c '
            \#(emitRecord)
            limit=$1
            shift
            for file do emit_file "$file" || exit 43; done
        ' read-sessions "$limit" {} + || exit 43
    done
    [ "$found" = yes ] || exit 42
    printf '\0'
    """#

    private static let scanMemory = emitRecord + #"""
    limit=$1
    source=$2
    destination=$3
    home_name=$4
    wanted=$5
    shift 5
    here=$(pwd -P) || exit 42
    [ "$here" != / ] || exit 44
    visit() {
        folder=$1
        location=$here
        if [ "$folder" != . ]; then location="$here/$folder"; fi
        leaf=${location##*/}
        parent=${location%/*}
        projects=${parent%/*}
        if [ "$source" = qoder ] && [ "$destination" = global ] && [ "$leaf" = memory ] && [ "${projects##*/}" = projects ]; then
            return 46
        fi
        for file in "$folder"/*; do
            [ -f "$file" ] && [ ! -L "$file" ] || continue
            if [ -n "$wanted" ] && [ "${file#./}" != "$wanted" ]; then continue; fi
            lower=$(printf '%s' "${file##*/}" | tr '[:upper:]' '[:lower:]')
            case "$lower" in
                agents.md|agents.local.md) continue ;;
                *.md|*.markdown) ;;
                *) continue ;;
            esac
            if [ "$source" = codex ]; then
                case "$leaf:$lower" in
                    memories:memory.md|memories:memory_summary.md|memories_v2:memory.md|memories_v2:memory_summary.md) ;;
                    memories:*|memories_v2:*) continue ;;
                esac
            fi
            emit_file "$file" || return 43
        done
        return 0
    }
    found=no
    printf 'BFF-SESSIONS-1\0'
    for directory do
        [ -d "$directory" ] && [ ! -L "$directory" ] || continue
        found=yes
        visit "$directory" || exit $?
    done
    if [ "$found" = no ]; then
        [ "${here##*/}" != "$home_name" ] || exit 44
        visit . || exit $?
    fi
    printf '\0'
    """#

    private static let scanSkills = #"""
    wanted=$1
    home_name=$2
    entry_limit=$3
    file_limit=$4
    total_limit=$5
    folder_limit=$6
    shift 6
    here=$(pwd -P) || exit 42
    [ "$here" != / ] || exit 42

    walk_package() {
        [ -r "$1" ] && [ -x "$1" ] || return 43
        for member in "$1"/* "$1"/.[!.]* "$1"/..?*; do
            [ ! -L "$member" ] || return 47
            [ -e "$member" ] || continue
            visited=$((visited + 1))
            [ "$visited" -le "$entry_limit" ] || return 49
            case "${member##*/}" in
                .*|\#(AgentSkillPackage.ignoredResourceNames.joined(separator: "|"))) continue ;;
            esac
            case "$member" in *[[:cntrl:]]*) return 52 ;; esac
            lower=$(printf '%s' "${member##*/}" | tr '[:upper:]' '[:lower:]') || return 43
            case "$lower" in
                \#(AgentFiles.sensitiveNames.joined(separator: "|"))|.env.*|\#(AgentFiles.sensitiveExtensions.map { "*." + $0 }.joined(separator: "|"))) return 48 ;;
            esac
            if [ -d "$member" ]; then
                [ "$(cd -P "$member" && pwd -P)" = "$package_root/${member#./}" ] || return 43
                walk_package "$member" || return $?
            else
                [ -f "$member" ] || return 52
                size=$(wc -c 2>/dev/null < "$member") || return 43
                size=$((size + 0))
                [ "$size" -le "$file_limit" ] || return 50
                total=$((total + size))
                [ "$total" -le "$total_limit" ] || return 51
                [ -f "$member" ] && [ ! -L "$member" ] || return 43
                printf '%s\0%s\0' "${member#./}" "$size" || return 43
                head -c "$size" "$member" || return 43
            fi
        done
        return 0
    }

    emit_package() {
        definition=SKILL.md
        expected=$here
        if [ "$1" != . ]; then
            definition="${1#./}/SKILL.md"
            expected="$here/${1#./}"
        fi
        if [ -n "$wanted" ] && [ "$wanted" != "$definition" ]; then return 0; fi
        printf '%s\0' "$definition" || return 43
        (
            cd -P "$1" || exit 43
            package_root=$(pwd -P) || exit 43
            [ "$package_root" = "$expected" ] || exit 43
            [ ! -L SKILL.md ] || exit 47
            [ -f SKILL.md ] || exit 52
            visited=0
            total=0
            walk_package .
        )
        printf '\0%s\0' "$?"
    }

    list_packages() {
        [ -r "$1" ] && [ -x "$1" ] || return 43
        if [ -e "$1/SKILL.md" ] || [ -L "$1/SKILL.md" ]; then
            emit_package "$1"
            return $?
        fi
        folder_count=0
        for folder in "$1"/*; do
            [ -e "$folder" ] || [ -L "$folder" ] || continue
            folder_count=$((folder_count + 1))
            [ "$folder_count" -le "$folder_limit" ] || return 45
            [ -d "$folder" ] && [ ! -L "$folder" ] || continue
            if [ -e "$folder/SKILL.md" ] || [ -L "$folder/SKILL.md" ]; then
                emit_package "$folder" || return 43
            fi
        done
        return 0
    }

    printf 'BFF-SKILLS-1\0'
    if [ "${here##*/}" = skills ] || [ -e ./SKILL.md ] || [ -L ./SKILL.md ]; then
        list_packages . || exit $?
    else
        found=no
        for container do
            [ -d "./$container" ] && [ ! -L "./$container" ] || continue
            [ "$(cd -P "./$container" && pwd -P)" = "$here/$container" ] || continue
            found=yes
            list_packages "./$container" || exit $?
        done
        if [ "$found" = no ] && [ "${here##*/}" != "$home_name" ] && [ "${here##*/}" != .agents ]; then
            list_packages . || exit $?
        fi
    fi
    printf '\0'
    """#

    private static let scanAutomations = emitRecord + #"""
    limit=$1
    filename=$2
    source=$3
    explicit=$4
    wanted=$5
    folder_limit=$6
    here=$(pwd -P) || exit 42
    [ "$here" != / ] || [ -n "$explicit" ] || exit 42

    read_plan() {
        relative=${1#./}
        [ -z "$wanted" ] || [ "$wanted" = "$relative" ] || return 0
        [ -e "$1" ] || [ -L "$1" ] || return 0
        parent=${1%/*}
        expected=$here
        if [ "$parent" != . ]; then expected="${here%/}/${parent#./}"; fi
        if [ -L "$1" ] || [ ! -f "$1" ] || [ "$(cd -P "$parent" && pwd -P)" != "$expected" ]; then
            printf '%s\0?\0' "$relative"
        else
            emit_file "$1"
        fi
    }

    printf 'BFF-SESSIONS-1\0'
    if [ -n "$explicit" ]; then
        [ -e "./$filename" ] || [ -L "./$filename" ] || exit 43
        read_plan "./$filename" || exit 43
    elif [ "$source" = qoder ]; then
        read_plan "./$filename" || exit 43
        read_plan "./.qoder/$filename" || exit 43
    elif [ -e "./$filename" ] || [ -L "./$filename" ]; then
        read_plan "./$filename" || exit 43
    else
        if [ -L ./automations ]; then exit 43; fi
        directory=.
        if [ -d ./automations ]; then directory=./automations
        elif [ -e ./automations ]; then exit 43; fi
        [ -r "$directory" ] && [ -x "$directory" ] || exit 42
        count=0
        for folder in "$directory"/*; do
            [ -e "$folder" ] || [ -L "$folder" ] || continue
            count=$((count + 1))
            [ "$count" -le "$folder_limit" ] || exit 45
            [ -d "$folder" ] && [ ! -L "$folder" ] || continue
            read_plan "$folder/$filename" || exit 43
        done
    fi
    printf '\0'
    """#

    private static let scanConnectors = #"""
    for python in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        [ -x "$python" ] || continue
        if [ "$1" = codex ]; then
            "$python" -I -B -S -c 'import tomllib' >/dev/null 2>&1 || continue
        else
            "$python" -I -B -S -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1 || continue
        fi
        exec "$python" -I -B -S -X utf8 - "$@" <<'BFF_CONNECTORS'
    import json
    import math
    import os
    import re
    import stat
    import sys
    from urllib.parse import urlsplit, urlunsplit

    source, home_name, explicit, wanted, input_limit, output_limit, missing, suffixes = sys.argv[1:9]
    if source == "codex":
        import tomllib
    input_limit, output_limit = int(input_limit), int(output_limit)
    suffixes = tuple(suffixes.split(","))
    flags = os.O_RDONLY | os.O_NOFOLLOW

    def read_config(path):
        parts = path.split("/")
        directory = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in parts[:-1]:
                child = os.open(part, flags | os.O_DIRECTORY, dir_fd=directory)
                os.close(directory)
                directory = child
            fd = os.open(parts[-1], flags | os.O_NONBLOCK, dir_fd=directory)
            with os.fdopen(fd, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    raise OSError()
                return stream.read(input_limit + 1)
        finally:
            os.close(directory)

    def field(row, key, kind, default=None):
        if key not in row:
            return default
        value = row[key]
        if type(value) is not kind:
            raise ValueError()
        return value

    def keys(row, key):
        values = field(row, key, dict, {})
        if any(type(value) is not str for value in values.values()):
            raise ValueError()
        return set(values)

    def number(row, key):
        value = row.get(key)
        if key in row and (type(value) not in (int, float) or not math.isfinite(value)):
            raise ValueError()
        return value

    def safe_url(value):
        if "://" not in value:
            return value
        try:
            url = urlsplit(value)
            if not url.netloc:
                return value if url.scheme == "file" and "?" not in value and "#" not in value else missing
            if "@" in url.netloc or "?" in value or "#" in value:
                return urlunsplit((url.scheme, url.netloc.rsplit("@", 1)[-1], url.path, missing, ""))
            return value
        except ValueError:
            return missing

    def safe_args(args, command):
        if any(type(arg) is not str for arg in args):
            raise ValueError()
        program = os.path.basename(command or "")
        shell = program in {"sh", "bash", "zsh", "dash", "fish", "ksh"}
        interpreter = program.startswith(("python", "node", "perl", "ruby", "deno"))
        output, hide_next = [], False
        for arg in args:
            if hide_next:
                output.append(missing)
                hide_next = False
                continue
            if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", arg):
                output.append(safe_url(arg))
                continue
            key, equals, value = arg.partition("=")
            credential = re.sub("[^a-zA-Z]", "", key).lower().endswith(suffixes)
            header = key in {"-H", "--header", "--http-header"}
            inline = (shell and (key == "--command" or re.fullmatch(r"-[ilxersbuvn]*c[ilxersbuvn]*", key))) or (
                interpreter and key in {"-c", "-e", "--eval"})
            if equals and (credential or inline or header or re.match(r"^(authorization\s*:|bearer\s+)", value, re.IGNORECASE)):
                output.append(key + "=" + missing)
            elif not equals and ((arg.startswith("-") and credential) or inline or header):
                output.append(arg)
                hide_next = True
            elif (shell or interpreter) and re.match(r"^-[ce].+", arg):
                output.append(arg[:2] + missing)
            elif re.match(r"^(authorization\s*:|bearer\s+)", arg, re.IGNORECASE):
                output.append(missing)
            else:
                clean = safe_url(value if equals else arg)
                output.append(key + "=" + clean if equals else clean)
        return output

    def connector(row):
        if not isinstance(row, dict):
            raise ValueError()
        result = {}
        for key in ("command", "cwd", "url") + (("type",) if source == "qoder" else ()):
            value = field(row, key, str)
            if value is not None:
                result[key] = safe_url(value) if key == "url" else value
        args = field(row, "args", list, [])
        if args:
            result["args"] = safe_args(args, result.get("command"))
        env = keys(row, "env")
        if source == "codex":
            for variable in field(row, "env_vars", list, []):
                env.add(variable if type(variable) is str else field(variable, "name", str))
            headers = keys(row, "http_headers") | keys(row, "env_http_headers")
            bearer = field(row, "bearer_token_env_var", str, "")
            seconds = number(row, "tool_timeout_sec")
            if seconds is None:
                seconds = number(row, "startup_timeout_sec")
            auth = {"auth", "oauth", "http_headers_helper", "enabled_tools", "disabled_tools", "default_tools_approval_mode", "tools"}
        else:
            headers = keys(row, "headers")
            bearer = field(row, "bearerToken", str, "")
            seconds = number(row, "timeoutSeconds")
            milliseconds = number(row, "timeout")
            if milliseconds is not None:
                if seconds is not None:
                    raise ValueError()
                seconds = milliseconds / 1000
            auth = {"auth", "oauth", "oauthClientID", "oauthClientAuthMethod", "oauthIssuer", "oauthClientSecret"}
        if any(not isinstance(name, str) for name in env):
            raise ValueError()
        if env:
            result["env"] = dict.fromkeys(sorted(env), "")
        if headers:
            result["headers"] = dict.fromkeys(sorted(headers), "")
        if bearer:
            result["bearerToken"] = missing
        if seconds is not None:
            result["timeoutSeconds"] = seconds
        if auth.intersection(row):
            result["auth"] = True
        return result

    def unique_pairs(pairs):
        result = dict(pairs)
        if len(result) != len(pairs):
            raise ValueError()
        return result

    def project_config(data, project):
        text = data.decode("utf-8")
        content = tomllib.loads(text) if source == "codex" else json.loads(text, object_pairs_hook=unique_pairs)
        if not isinstance(content, dict):
            raise ValueError()
        key = "mcp_servers" if source == "codex" else "mcpServers"
        entries = field(content, key, dict, {})
        if source == "qoder" and key not in content and isinstance(content.get("name"), str) and ("command" in content or "url" in content):
            entries = {content["name"]: content}
        if len(entries) > 128:
            raise ValueError()
        result = {}
        for name, row in entries.items():
            try:
                result[name] = connector(row)
            except (ValueError, TypeError, AttributeError, OverflowError):
                result[name] = None
        return json.dumps({"project": project, "servers": result}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    root = os.getcwd()
    if root == "/" and not explicit:
        sys.exit(42)
    home_source = os.path.join(os.path.realpath(os.environ.get("HOME", "/")), home_name)
    locations = [(explicit, "global")] if explicit else list(zip(sys.argv[9::2], sys.argv[10::2]))
    out = sys.stdout.buffer
    out.write(b"BFF-SESSIONS-1\0")
    for path, scope in locations:
        if wanted and path != wanted:
            continue
        parent = os.path.dirname(os.path.join(root, path))
        project = scope == "project" or path == ".mcp.json" or os.path.basename(parent) == home_name and parent != home_source
        try:
            data = read_config(path)
        except FileNotFoundError:
            if explicit:
                sys.exit(43)
            continue
        except OSError:
            out.write(path.encode("utf-8") + b"\0?\0")
            continue
        projection = b""
        if len(data) <= input_limit:
            try:
                projection = project_config(data, project)
            except (ValueError, TypeError, RecursionError, OverflowError, UnicodeError):
                projection = b"{}"
        out.write(path.encode("utf-8") + b"\0")
        if not projection or len(projection) > output_limit:
            out.write(b"-\0")
        else:
            out.write(str(len(projection)).encode("ascii") + b"\0")
            out.write(projection)
    out.write(b"\0")
    BFF_CONNECTORS
    done
    exit 47
    """#

    private static let readFile = #"""
    file=$1
    parent=${file%/*}
    here=$(pwd -P)
    target=$(cd -P "$parent" && pwd -P) || exit 43
    [ "$target" = "${here%/}/$parent" ] && [ -f "$file" ] && [ ! -L "$file" ] || exit 43
    head -c "$2" "$file" || exit 43
    """#
}
