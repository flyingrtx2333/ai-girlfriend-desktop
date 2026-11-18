import Foundation

struct AgentPluginImportPlan: Codable {
    var workspace: String?
    var name: String = ""
}

@MainActor enum AgentPluginDataImport {
    @MainActor private struct Source {
        let files: AgentFiles
        let explicit: URL?

        init(_ root: URL) throws {
            var directory = ObjCBool(false)
            guard root.path != "/", FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) else {
                throw PetError("请选择本机插件目录或 ZIP")
            }
            let base = directory.boolValue ? root : root.deletingLastPathComponent()
            files = try AgentFiles(workspace: base.path, followParentLinks: false)
            guard files.root.path == base.standardizedFileURL.path else { throw PetError("插件来源位置已变化，请重新选择") }
            explicit = directory.boolValue ? nil : try files.literalURL(root.path)
        }

        private func kind(_ url: URL) throws -> String {
            if url.path == files.root.path { return "directory" }
            return try files.entryMetadata(url).kind
        }

        private func childPaths(_ directory: URL) throws -> [URL] {
            guard try kind(directory) == "directory" else { return [] }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
            guard names.count <= 512 else { throw PetError("插件来源目录过大，请选择较小的目录") }
            return try names.sorted().map { try files.literalURL(directory.appendingPathComponent($0).path) }
        }

        private func package(_ url: URL, manifestless: Bool) throws -> Bool {
            let kind = try kind(url)
            if kind == "file" { return url.pathExtension.lowercased() == "zip" }
            guard kind == "directory" else { return false }
            let manifests = AgentImportedPlugin.manifests
            for path in manifests + (manifestless ? ["skills", "commands", "agents", "rules", "hooks/hooks.json", ".mcp.json"] : []) {
                let resource = try files.literalURL(url.appendingPathComponent(path).path)
                if let entry = try? files.entryMetadata(resource), entry.kind != "missing" { return true }
            }
            return false
        }

        func packages(_ source: AgentImportSource) throws -> [URL] {
            if let explicit { return [try checked(explicit.path)] }
            if try package(files.root, manifestless: false) { return [files.root] }
            let isQoder = source == .qoder
            let containers = (isQoder ? [".qoder/plugins"] : [".codex/plugins"]) + ["plugins"]
            let known = try containers.map(files.literalURL).first { try kind($0) == "directory" }
            let base = known ?? files.root
            if known == nil, !["plugins", "cache", "custom"].contains(base.lastPathComponent),
               try package(base, manifestless: isQoder) { return [base] }
            var scanned = 0
            func children(_ directory: URL) throws -> [URL] {
                let found = try childPaths(directory); scanned += found.count
                guard scanned <= 4096 else { throw PetError("插件来源目录过大，请选择较小的目录") }
                return found
            }
            func folders(_ directory: URL) throws -> [URL] { try children(directory).filter { try kind($0) == "directory" } }
            let custom = try files.literalURL(base.appendingPathComponent("custom").path)
            let cache = base.lastPathComponent == "cache" ? base : try files.literalURL(base.appendingPathComponent("cache").path)
            var result = try (children(base) + children(custom)).filter { url in
                guard !["cache", "custom", "data", "marketplaces"].contains(url.lastPathComponent) else { return false }
                return try package(url, manifestless: isQoder)
            }
            for market in try folders(cache) {
                for plugin in try folders(market) {
                    if try package(plugin, manifestless: false) { result.append(plugin); continue }
                    let versions = try folders(plugin).filter { $0.lastPathComponent.range(of: "^[A-Za-z0-9._+-]+$", options: .regularExpression) != nil }
                    if source == .codex {
                        let active = versions.first { $0.lastPathComponent == "local" }
                            ?? versions.max { AgentPluginDataImport.older($0.lastPathComponent, than: $1.lastPathComponent) }
                        if let active { result.append(active) }
                    } else {
                        result.append(contentsOf: try versions.filter { try package($0, manifestless: true) })
                    }
                    guard result.count <= 128 else { throw PetError("发现超过128份插件，请分别选择来源目录") }
                }
            }
            result = Array(Set(result)).sorted { $0.path < $1.path }
            guard result.count <= 128 else { throw PetError("发现超过128份插件，请分别选择来源目录") }
            return result
        }

        func checked(_ path: String) throws -> URL {
            let url = path == files.root.path ? files.root : try files.literalURL(path)
            let kind = try kind(url)
            guard explicit == nil || url.path == explicit?.path,
                  kind == "directory" || kind == "file" && url.pathExtension.lowercased() == "zip" else {
                throw PetError("插件来源已移动或不是普通文件，请重新检测")
            }
            return url
        }
    }

    private static func older(_ left: String, than right: String) -> Bool {
        func version(_ value: String) -> (numbers: [UInt64], prerelease: [Substring])? {
            let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            let numbers = components.compactMap { value -> UInt64? in
                guard value == "0" || value.first != "0" else { return nil }
                return UInt64(value)
            }
            guard components.count == 3, numbers.count == 3 else { return nil }
            let labels = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false) : []
            guard labels.allSatisfy({ !$0.isEmpty && ($0.first != "0" || $0.count == 1 || !$0.allSatisfy(\.isNumber)) }) else { return nil }
            return (numbers, labels)
        }
        guard let lhs = version(left), let rhs = version(right) else { return left < right }
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let x = UInt64(a), let y = UInt64(b) { return x < y }
            if (UInt64(a) != nil) != (UInt64(b) != nil) { return UInt64(a) != nil }
            return a < b
        }
        if lhs.prerelease.count != rhs.prerelease.count { return lhs.prerelease.count < rhs.prerelease.count }
        return left < right
    }

    private static func projectSource(_ url: URL, source: AgentImportSource) -> Bool {
        guard let index = url.pathComponents.lastIndex(of: source.homeName), index > 0 else { return false }
        let prefix = NSString.path(withComponents: Array(url.pathComponents[..<index]))
        return prefix != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    }

    private static func preview(_ package: AgentPluginPackage) -> String {
        var components = package.receipt.components.map { ($0.kind == .skill ? "Skill" : "命令") + " · " + $0.name }
        components += package.agents.map { "Agent · " + $0.key }
        components += package.rules.map { "规则 · " + $0.key }
        components += package.mcpServers.map { "MCP · " + $0.key }
        components += package.hooks.flatMap { $0.preview.map { "Hook · " + $0.event.rawValue } }
        let metadata = [package.metadata.version, package.metadata.author].filter { !$0.isEmpty }.joined(separator: " · ")
        return ([metadata, String(package.metadata.description.prefix(320))].filter { !$0.isEmpty } + Array(components.prefix(24))
            + (components.count > 24 ? ["另有 \(components.count - 24) 项"] : [])).joined(separator: "\n")
    }

    static func discover(_ source: AgentImportSource, root: URL, workspace: String?, store: AgentStore) async throws -> [AgentImportCandidate] {
        try AgentMCPDataImport.requireDestination(workspace, store: store)
        let location = try Source(root), service = store.extensions.plugins
        let existing = try service.catalog(workspace: workspace, onlyScope: true)
        var rows: [AgentImportCandidate] = []
        for url in try location.packages(source) {
            try Task.checkCancellation()
            let time = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let key = "plugin:" + AgentFiles.hash(Data(url.path.utf8))
            var record = AgentImportCandidate(source: source, sourceID: key, file: url.path, rawHash: "", sourceHash: "",
                                              title: url.lastPathComponent, created: time, updated: time)
            record.plugin = AgentPluginImportPlan(workspace: workspace)
            do {
                let package = try await service.inspect(location.checked(url.path), importing: true)
                record.title = package.metadata.title
                record.sourceHash = package.receipt.sourceHash
                record.rawHash = record.sourceHash
                record.plugin?.name = package.metadata.name
                record.preview = preview(package)
                if package.mcpServers.contains(where: { String(describing: $0.value).contains(AgentMCP.importPlaceholder) })
                    || package.hooks.contains(where: { String(decoding: $0.data, as: UTF8.self).contains(AgentHookCredentials.placeholder) }) {
                    record.warnings.append("使用前请在本机填写连接器或 Hooks 凭据")
                }
                if workspace == nil && projectSource(url, source: source) { record.issue = "项目来源，请选择目标项目" }
                else if let installed = existing.first(where: { $0.metadata.name == package.metadata.name }) {
                    record.issue = installed.receipt.sourceHash == record.sourceHash ? "已经导入" : "同名插件已存在，保留现有版本"
                } else if existing.count >= 64 { record.issue = "此范围插件数量已达到64项" }
            } catch is CancellationError { throw CancellationError() }
            catch { record.issue = error.localizedDescription }
            rows.append(record)
        }
        let duplicates = Dictionary(grouping: rows.filter { $0.issue == nil }, by: { $0.plugin?.name })
        return rows.map { entry in
            var record = entry
            if record.issue == nil, duplicates[record.plugin?.name, default: []].count > 1 {
                record.issue = "发现多个同名来源，请选择明确的版本目录或 ZIP"
            }
            return record
        }
    }

    static func reveal(_ record: AgentImportCandidate, root: URL) throws -> URL {
        try Source(root).checked(record.file)
    }

    static func installedID(_ record: AgentImportCandidate, store: AgentStore) -> String? {
        guard let plan = record.plugin, AgentPlugins.validName(plan.name) else { return nil }
        let id = AgentPlugins.scopedID(plan.name, workspace: plan.workspace)
        guard let current = try? store.extensions.plugins.installation(id),
              current.receipt.sourceHash == record.sourceHash else { return nil }
        return current.id
    }

    static func install(_ record: AgentImportCandidate, root: URL, store: AgentStore) async throws {
        guard let plan = record.plugin, AgentPlugins.validName(plan.name), UUID(uuidString: record.targetID) != nil else {
            throw PetError("插件导入记录无效")
        }
        try AgentMCPDataImport.requireDestination(plan.workspace, store: store)
        let service = store.extensions.plugins
        let id = AgentPlugins.scopedID(plan.name, workspace: plan.workspace)
        if let current = try? service.installation(id), current.receipt.installationID == record.targetID,
           current.receipt.sourceHash == record.sourceHash {
            if !current.locallyReviewed {
                _ = try service.reviewPackage(current)
                try service.recordProjectReview(current, active: false)
                service.notify(id)
            }
            return
        }
        let url = try reveal(record, root: root)
        guard plan.workspace != nil || !projectSource(url, source: record.source) else { throw PetError("项目来源，请选择目标项目") }
        let package = try await service.inspect(url, importing: true)
        guard package.receipt.sourceHash == record.sourceHash, package.metadata.name == plan.name else {
            throw PetError("来源插件已变化，请重新检测")
        }
        try AgentMCPDataImport.requireDestination(plan.workspace, store: store)
        try service.install(package, workspace: plan.workspace, importing: record.targetID)
    }
}
