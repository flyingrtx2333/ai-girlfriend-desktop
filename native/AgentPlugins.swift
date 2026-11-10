import Foundation
import Darwin

struct AgentPluginComponent: Codable {
    var kind: AgentExtensionKind, name: String, path: String
}
struct AgentPluginRevision: Codable, Equatable {
    var directory: String, receiptHash: String, created: Date
    var version: String? = nil, sourceName: String? = nil
}
struct AgentPluginReceipt: Codable {
    var name: String, manifest: String, components: [AgentPluginComponent], hashes: [String: String]
    var sourceName: String, sourceHash: String, installedAt: Date, enabled = false
    var installationID: String? = nil, activationID: String? = nil
    var revisions: [AgentPluginRevision]? = nil
}
struct AgentPluginMetadata {
    var name: String, title: String, version: String, author: String, description: String
}
struct AgentPluginPackage {
    var metadata: AgentPluginMetadata, receipt: AgentPluginReceipt, files: [String: Data]
    var mcpServers: [AgentPluginMCPDefinition] = []
    var agents: [AgentPluginAgentDefinition] = []
    var hooks: [AgentPluginHookDefinition] = []
    var rules: [AgentPluginRuleDefinition] = []
}
struct AgentPluginInstallation: Identifiable {
    var metadata: AgentPluginMetadata, receipt: AgentPluginReceipt, root: URL, receiptHash: String
    var workspace: String? = nil
    var locallyReviewed = true
    var locallyApproved = true
    var mcpServers: [AgentPluginMCPDefinition] = []
    var agents: [AgentPluginAgentDefinition] = []
    var hooks: [AgentPluginHookDefinition] = []
    var rules: [AgentPluginRuleDefinition] = []
    var id: String { AgentPlugins.scopedID(receipt.name, workspace: workspace) }
    var enabled: Bool { receipt.enabled && locallyReviewed && locallyApproved }
}

@MainActor final class AgentPlugins {
    let profile: URL
    private(set) var warnings: [String] = []
    private var observers: [UUID: (String) -> Void] = [:]
    func observeChanges(_ action: @escaping (String) -> Void) -> UUID { let id = UUID(); observers[id] = action; return id }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    func notify(_ name: String) { for action in Array(observers.values) { action(name) } }
    init(profile: URL) { self.profile = profile }
    func folder(_ id: String) throws -> URL {
        let scope = try Self.scope(id), files = try AgentFiles(workspace: scope.workspace ?? profile.path)
        guard scope.workspace == nil || files.root.path == scope.workspace else { throw PetError("项目位置已变化，请重新选择插件") }
        return try files.literalURL((scope.workspace == nil ? "extensions/plugins/" : ".bluefatfish/plugins/") + scope.name)
    }
    nonisolated static func validName(_ name: String) -> Bool {
        name.count <= 64 && name.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }
    private static func metadata(_ data: Data) throws -> (AgentPluginMetadata, [String: Any]) {
        guard data.count <= 65_536, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = value["name"] as? String, validName(name) else { throw PetError("插件缺少有效的 name") }
        func text(_ key: String, fallback: String = "") throws -> String {
            guard value[key] == nil || value[key] is String else { throw PetError("插件 \(key) 必须是文字") }
            let text = value[key] as? String ?? fallback
            guard !text.contains("\0"), text.utf8.count <= 2000 else { throw PetError("插件元信息过长或无效") }; return text
        }
        let author = (value["author"] as? [String: Any])?["name"] as? String ?? value["author"] as? String ?? ""
        guard author.count <= 200, !author.contains("\0") else { throw PetError("插件作者信息无效") }
        return (AgentPluginMetadata(name: name, title: try text("displayName", fallback: name), version: try text("version"), author: author, description: try text("description")), value)
    }
    private static func package(_ files: [String: Data], sourceName: String, sourceHash: String) throws -> AgentPluginPackage {
        guard !files.isEmpty, files.count <= 2000, files.allSatisfy({ AgentArchive.validPath($0.key) && $0.value.count <= 2_000_000 }), files.values.reduce(0, { $0 + $1.count }) <= 20_000_000 else { throw PetError("插件资源超过数量或大小上限") }
        let manifests = [".qoder-plugin/plugin.json", ".claude-plugin/plugin.json"].filter { files[$0] != nil }
        guard let manifest = manifests.first else { throw PetError("插件缺少 .qoder-plugin/plugin.json 或 .claude-plugin/plugin.json") }
        let (info, value) = try metadata(files[manifest]!)
        for other in manifests.dropFirst() {
            let a = try JSONSerialization.jsonObject(with: files[manifest]!) as? NSDictionary, b = try JSONSerialization.jsonObject(with: files[other]!) as? NSDictionary
            guard a == b else { throw PetError("插件的两份 manifest 内容不一致") }
        }
        let unsupported = ["settings", "outputStyles", "workflowsPath", "workflowsPaths", "permissions", "sdk", "dependencies"]
        for key in unsupported where value[key] != nil {
            let item = value[key]!
            if (item as? [Any])?.isEmpty == true || (item as? [String: Any])?.isEmpty == true || item is NSNull { continue }
            throw PetError("此插件包含尚未接入的 \(key)，未安装")
        }
        guard !files.keys.contains(where: { ["output-styles/", "workflows/"].contains(where: $0.hasPrefix) }) else { throw PetError("此插件包含尚未接入的输出样式或工作流，未安装") }
        func paths(_ key: String, fallback: String) throws -> [String] {
            let raw: [String]
            if value[key] == nil { raw = [fallback] }
            else if let path = value[key] as? String { raw = [path] }
            else if let paths = value[key] as? [String] { raw = paths }
            else { throw PetError("插件 \(key) 目前支持相对路径或路径数组") }
            return try raw.map { input in
                var path = input
                if path.hasPrefix("./") { path.removeFirst(2) }; while path.hasSuffix("/") { path.removeLast() }
                guard AgentArchive.validPath(path), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { throw PetError("插件组件路径无效") }; return path
            }
        }
        var components: [AgentPluginComponent] = [], seen = Set<String>()
        func add(_ kind: AgentExtensionKind, _ path: String, _ fallback: String) throws {
            guard let data = files[path], let raw = String(data: data, encoding: .utf8) else { throw PetError("插件组件不是 UTF-8：" + path) }
            let doc = try AgentExtensionDocument(raw), name = kind == .skill ? doc.metadata["name"] ?? fallback : fallback
            guard AgentExtensions.validName(name), kind != .skill || !name.contains(":"), seen.insert(kind.rawValue + ":" + name.lowercased()).inserted else { throw PetError("插件组件名称无效或重复：" + name) }
            components.append(AgentPluginComponent(kind: kind, name: name, path: path))
        }
        for base in try paths("skills", fallback: "skills") {
            let previous = components.count
            if files[base + "/SKILL.md"] != nil { try add(.skill, base + "/SKILL.md", URL(fileURLWithPath: base).lastPathComponent) }
            else {
                for path in files.keys.sorted() where path.hasPrefix(base + "/") && path.hasSuffix("/SKILL.md") {
                    let relative = String(path.dropFirst(base.count + 1)); if relative.split(separator: "/").count == 2 { try add(.skill, path, String(relative.split(separator: "/")[0])) }
                }
            }
            if value["skills"] != nil, components.count == previous { throw PetError("插件声明的 Skill 路径没有组件：" + base) }
        }
        for base in try paths("commands", fallback: "commands") {
            let previous = components.count
            if base.hasSuffix(".md"), files[base] != nil { try add(.command, base, URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent) }
            else { for path in files.keys.sorted() where path.hasPrefix(base + "/") && path.hasSuffix(".md") { try add(.command, path, String(path.dropFirst(base.count + 1).dropLast(3)).replacingOccurrences(of: "/", with: ":")) } }
            if value["commands"] != nil, components.count == previous { throw PetError("插件声明的命令路径没有组件：" + base) }
        }
        let mcpServers = try mcpDefinitions(value, paths: Set(files.keys)) { path in guard let data = files[path] else { throw PetError("插件 MCP 配置不存在") }; return data }
        let agents = try agentDefinitions(value, paths: Set(files.keys)) { path in guard let data = files[path] else { throw PetError("插件 Agent 不存在") }; return data }
        try validateAgentReferences(agents, name: info.name, components: components, servers: mcpServers)
        let hooks = try hookDefinitions(value, paths: Set(files.keys)) { path in guard let data = files[path] else { throw PetError("插件 Hook 不存在") }; return data }
        let hookCount = hooks.reduce(0) { $0 + $1.preview.count }
        let rules = try ruleDefinitions(value, paths: Set(files.keys)) { path in guard let data = files[path] else { throw PetError("插件规则不存在") }; return data }
        guard !(components.isEmpty && mcpServers.isEmpty && agents.isEmpty && hookCount == 0 && rules.isEmpty), components.count + mcpServers.count + agents.count + hookCount + rules.count <= 500 else { throw PetError("插件须包含1至500项 Skills、命令、Agent、规则、Hooks 或 MCP 连接器") }
        let receipt = AgentPluginReceipt(name: info.name, manifest: manifest, components: components, hashes: files.mapValues(AgentFiles.hash), sourceName: sourceName, sourceHash: sourceHash, installedAt: Date(), installationID: UUID().uuidString, activationID: UUID().uuidString)
        guard try JSONEncoder().encode(receipt).count <= 500_000 else { throw PetError("插件资源索引过大，请缩小插件包") }
        return AgentPluginPackage(metadata: info, receipt: receipt, files: files, mcpServers: mcpServers, agents: agents, hooks: hooks, rules: rules)
    }
    func inspect(_ archive: URL) async throws -> AgentPluginPackage {
        guard archive.pathExtension.lowercased() == "zip" else { throw PetError("请选择一个插件 ZIP 文件") }
        let input = try AgentFiles(workspace: archive.deletingLastPathComponent().path), data = try input.readData(input.literalURL(archive.lastPathComponent), maximum: 20_000_000)
        let scratch = profile.appendingPathComponent(".plugin-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: scratch) }
        let pinned = scratch.appendingPathComponent("package.zip"); try data.write(to: pinned)
        let files = try await AgentArchive.resources(pinned, scratchParent: scratch, definitions: [".qoder-plugin/plugin.json", ".claude-plugin/plugin.json"], hiddenRoots: [".qoder-plugin", ".claude-plugin", ".mcp.json"])
        return try Self.package(files, sourceName: archive.lastPathComponent, sourceHash: AgentFiles.hash(data))
    }
    @discardableResult func install(_ candidate: AgentPluginPackage, workspace: String? = nil) throws -> AgentPluginInstallation {
        let workspace = try workspace.map { try AgentFiles(workspace: $0).root.path }, existing = try catalog(workspace: workspace, onlyScope: true)
        guard existing.count < 64 else { throw PetError("此范围插件数量已达到64项") }
        let package = try Self.package(candidate.files, sourceName: candidate.receipt.sourceName, sourceHash: candidate.receipt.sourceHash)
        guard existing.reduce(0, { $0 + $1.mcpServers.count }) + package.mcpServers.count <= 64 else { throw PetError("插件 MCP 总数最多64项") }
        guard existing.reduce(0, { $0 + $1.hooks.reduce(0, { $0 + $1.preview.count }) }) + package.hooks.reduce(0, { $0 + $1.preview.count }) <= 128 else { throw PetError("插件 Hooks 总数最多128项") }
        guard existing.reduce(0, { $0 + $1.rules.count }) + package.rules.count <= 256 else { throw PetError("插件规则总数最多256项") }
        let id = Self.scopedID(package.metadata.name, workspace: workspace), target = try folder(id), files = try AgentFiles(workspace: workspace ?? profile.path), (parentFD, name) = try files.parentDescriptor(target, create: true)
        defer { Darwin.close(parentFD) }
        guard try files.entryMetadata(target).kind == "missing" else { throw PetError("同名插件已安装，请先查看现有版本") }
        let temporaryName = ".plugin-" + UUID().uuidString, temporary = target.deletingLastPathComponent().appendingPathComponent(temporaryName)
        guard mkdirat(parentFD, temporaryName, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var published = false; defer { if !published { try? FileManager.default.removeItem(at: temporary) } }
        try write(package, receipt: package.receipt, at: temporary)
        guard renameatx_np(parentFD, temporaryName, parentFD, name, UInt32(RENAME_EXCL)) == 0 else { throw PetError("插件未安装，目标可能已存在") }; published = true
        let installed = try installation(id); try recordProjectReview(installed, active: false)
        notify(installed.id); return try installation(id)
    }
    func installation(_ name: String) throws -> AgentPluginInstallation {
        try installation(name, at: folder(name))
    }
    private func installation(_ name: String, at root: URL) throws -> AgentPluginInstallation {
        let scope = try Self.scope(name)
        guard root.resolvingSymlinksInPath() == root else { throw PetError("插件目录不能是链接") }
        let files = try AgentFiles(workspace: root.path), data = try files.readData(files.literalURL("receipt.json"), maximum: 500_000), receipt = try JSONDecoder().decode(AgentPluginReceipt.self, from: data)
        guard receipt.name == scope.name, receipt.hashes.count <= 2000, !receipt.hashes.isEmpty, receipt.components.count <= 500, receipt.hashes.allSatisfy({ AgentArchive.validPath($0.key) && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit) }), [".qoder-plugin/plugin.json", ".claude-plugin/plugin.json"].contains(receipt.manifest) else { throw PetError("插件安装记录无效") }
        let revisions = receipt.revisions ?? []
        guard revisions.count <= 2000, Set(revisions.map(\.directory)).count == revisions.count, revisions.allSatisfy({ Self.validRevision($0) }) else { throw PetError("插件历史版本记录无效") }
        let payloadURL = root.appendingPathComponent("payload")
        guard payloadURL.resolvingSymlinksInPath() == payloadURL else { throw PetError("插件资源目录不能是链接") }
        let payload = try AgentFiles(workspace: payloadURL.path), definition = try payload.readData(payload.literalURL(receipt.manifest), maximum: 65_536)
        guard AgentFiles.hash(definition) == receipt.hashes[receipt.manifest] else { throw PetError("插件清单已变化，请重新导入") }
        let (info, value) = try Self.metadata(definition); guard info.name == scope.name else { throw PetError("插件名称与安装记录不一致") }
        for component in receipt.components { guard AgentExtensions.validName(component.name), receipt.hashes[component.path] != nil, AgentArchive.validPath(component.path) else { throw PetError("插件组件记录无效") } }
        let hash = AgentFiles.hash(data)
        let review = scope.workspace == nil ? nil : try projectApprovals()[name]
        let approved = scope.workspace == nil || review?.activeHash == hash
        let fingerprint = try Self.reviewFingerprint(receipt)
        let reviewed = scope.workspace == nil || review?.reviewedHash == fingerprint
        var installed = AgentPluginInstallation(metadata: info, receipt: receipt, root: root, receiptHash: hash, workspace: scope.workspace, locallyReviewed: reviewed, locallyApproved: approved)
        installed.mcpServers = try Self.mcpDefinitions(value, paths: Set(receipt.hashes.keys)) { try self.content($0, installation: installed, maximum: 65_536) }
        installed.agents = try Self.agentDefinitions(value, paths: Set(receipt.hashes.keys)) { try self.content($0, installation: installed, maximum: 65_536) }
        try Self.validateAgentReferences(installed.agents, name: name, components: receipt.components, servers: installed.mcpServers)
        installed.hooks = try Self.hookDefinitions(value, paths: Set(receipt.hashes.keys)) { try self.content($0, installation: installed, maximum: 128_000) }
        installed.rules = try Self.ruleDefinitions(value, paths: Set(receipt.hashes.keys)) { try self.content($0, installation: installed, maximum: 65_536) }
        return installed
    }
    private static func validRevision(_ revision: AgentPluginRevision) -> Bool {
        let prefix = ".plugin-revision-"
        return revision.directory.hasPrefix(prefix) && UUID(uuidString: String(revision.directory.dropFirst(prefix.count))) != nil && revision.receiptHash.count == 64 && revision.receiptHash.allSatisfy(\.isHexDigit) && revision.created.timeIntervalSince1970.isFinite && (revision.version?.utf8.count ?? 0) <= 2000 && (revision.sourceName?.utf8.count ?? 0) <= 2000
    }
    private func write(_ package: AgentPluginPackage, receipt: AgentPluginReceipt, at root: URL) throws {
        guard root.resolvingSymlinksInPath() == root else { throw PetError("插件暂存目录不能是链接") }
        let files = try AgentFiles(workspace: root.path)
        for (path, data) in package.files { try files.writeData(data, to: files.literalURL("payload/" + path), permissions: 0o400) }
        try files.writeData(JSONEncoder().encode(receipt), to: files.literalURL("receipt.json"), permissions: 0o600)
    }
    private func unchanged(_ item: AgentPluginInstallation) throws -> AgentPluginInstallation {
        let current = try installation(item.id)
        guard current.receiptHash == item.receiptHash else { throw PetError("插件已被其他操作修改，请刷新后重新审阅") }
        for path in current.receipt.hashes.keys { _ = try content(path, installation: current) }
        return current
    }
    func revision(_ revision: AgentPluginRevision, of item: AgentPluginInstallation) throws -> AgentPluginInstallation {
        let current = try installation(item.id)
        guard current.receiptHash == item.receiptHash, current.receipt.revisions?.contains(revision) == true, Self.validRevision(revision) else { throw PetError("插件历史版本已变化，请刷新") }
        let root = try AgentFiles(workspace: current.root.deletingLastPathComponent().path).literalURL(revision.directory)
        let snapshot = try installation(item.id, at: root)
        guard snapshot.receiptHash == revision.receiptHash else { throw PetError("历史版本原件已变化，未载入") }
        guard revision.version == nil || revision.version == snapshot.metadata.version else { throw PetError("历史版本名称与原件不一致") }
        for path in snapshot.receipt.hashes.keys { _ = try content(path, installation: snapshot) }
        return snapshot
    }
    func package(_ revision: AgentPluginRevision, of item: AgentPluginInstallation) throws -> AgentPluginPackage {
        try packageContents(self.revision(revision, of: item))
    }
    func reviewPackage(_ item: AgentPluginInstallation) throws -> AgentPluginPackage { try packageContents(unchanged(item)) }
    private func packageContents(_ snapshot: AgentPluginInstallation) throws -> AgentPluginPackage {
        var files: [String: Data] = [:], total = 0
        for path in snapshot.receipt.hashes.keys {
            let data = try content(path, installation: snapshot); total += data.count
            guard total <= 20_000_000 else { throw PetError("历史插件资源超过20 MB") }; files[path] = data
        }
        return try Self.package(files, sourceName: snapshot.receipt.sourceName, sourceHash: snapshot.receipt.sourceHash)
    }
    @discardableResult func update(_ candidate: AgentPluginPackage, replacing reviewed: AgentPluginInstallation, onPrepared: (() throws -> Void)? = nil) throws -> AgentPluginInstallation {
        let current = try unchanged(reviewed), package = try Self.package(candidate.files, sourceName: candidate.receipt.sourceName, sourceHash: candidate.receipt.sourceHash)
        guard package.metadata.name == current.metadata.name else { throw PetError("新包名称与所选插件不同，未更新") }
        guard package.receipt.hashes != current.receipt.hashes else { throw PetError("插件内容与当前版本一致") }
        let others = try catalog(workspace: current.workspace, onlyScope: true).filter { $0.id != current.id }
        guard others.reduce(0, { $0 + $1.mcpServers.count }) + package.mcpServers.count <= 64,
              others.reduce(0, { $0 + $1.hooks.reduce(0, { $0 + $1.preview.count }) }) + package.hooks.reduce(0, { $0 + $1.preview.count }) <= 128,
              others.reduce(0, { $0 + $1.rules.count }) + package.rules.count <= 256 else { throw PetError("更新后的插件组件总数超过上限") }
        var receipt = package.receipt
        guard (current.receipt.revisions?.count ?? 0) < 2000 else { throw PetError("插件历史索引已满，请先备份后移除并重新导入插件") }
        let record = AgentPluginRevision(directory: ".plugin-revision-" + UUID().uuidString, receiptHash: current.receiptHash, created: Date(), version: current.metadata.version, sourceName: current.receipt.sourceName)
        receipt.revisions = (current.receipt.revisions ?? []) + [record]
        guard try JSONEncoder().encode(receipt).count <= 500_000 else { throw PetError("插件历史索引超过500 KB，请先备份后移除并重新导入插件") }
        let files = try AgentFiles(workspace: current.workspace ?? profile.path), (parent, name) = try files.parentDescriptor(current.root, create: false)
        defer { Darwin.close(parent) }
        let temporary = current.root.deletingLastPathComponent().appendingPathComponent(record.directory)
        guard mkdirat(parent, record.directory, 0o700) == 0 else { throw PetError("无法准备插件更新，原版本保留") }
        var published = false; defer { if !published { try? FileManager.default.removeItem(at: temporary) } }
        try write(package, receipt: receipt, at: temporary)
        let staged = try installation(current.id, at: temporary)
        for path in staged.receipt.hashes.keys { _ = try content(path, installation: staged) }
        try onPrepared?(); _ = try unchanged(current)
        var expectedRoot = stat()
        guard fstatat(parent, name, &expectedRoot, AT_SYMLINK_NOFOLLOW) == 0, expectedRoot.st_mode & S_IFMT == S_IFDIR else { throw PetError("原插件目录已变化") }
        if current.workspace != nil { try revokeProjectApproval(current.id) }
        notify(current.id); _ = try unchanged(current)
        guard renameatx_np(parent, name, parent, record.directory, UInt32(RENAME_SWAP)) == 0 else { throw PetError("插件未更新，当前版本和已保存历史保留") }
        published = true
        do {
            var movedRoot = stat()
            guard fstatat(parent, record.directory, &movedRoot, AT_SYMLINK_NOFOLLOW) == 0, movedRoot.st_dev == expectedRoot.st_dev, movedRoot.st_ino == expectedRoot.st_ino else { throw PetError("插件目录在发布时被替换") }
            let old = try installation(current.id, at: temporary)
            guard old.receiptHash == current.receiptHash else { throw PetError("插件状态在发布时已变化") }
            for path in old.receipt.hashes.keys { _ = try content(path, installation: old) }
            let installed = try installation(current.id)
            guard installed.receiptHash == staged.receiptHash else { throw PetError("发布后的插件状态已变化") }
            try recordProjectReview(installed, active: false)
            notify(current.id); return try installation(current.id)
        } catch {
            let visible = try? installation(current.id)
            if visible?.receiptHash == staged.receiptHash, renameatx_np(parent, name, parent, record.directory, UInt32(RENAME_SWAP)) == 0 {
                throw PetError("插件更新未完成，已恢复原版本，两份副本保留：" + error.localizedDescription)
            }
            notify(current.id); throw PetError("插件更新状态需要核对，两份原件均已保留：" + temporary.path)
        }
    }
    func catalog(workspace: String? = nil, onlyScope: Bool = false) throws -> [AgentPluginInstallation] {
        warnings = []
        let canonical = try workspace.map { try AgentFiles(workspace: $0).root.path }
        let project = try canonical.map { try scopeCatalog($0) }
        let user = onlyScope && canonical != nil ? (items: [AgentPluginInstallation](), names: Set<String>(), warnings: [String]()) : try scopeCatalog(nil)
        warnings = user.warnings + (project?.warnings ?? [])
        if onlyScope { return project?.items ?? user.items }
        return ((project?.items.filter(\.locallyReviewed) ?? []) + user.items.filter { !(project?.names.contains($0.metadata.name) ?? false) }).sorted { $0.metadata.title.localizedStandardCompare($1.metadata.title) == .orderedAscending }
    }
    private func payload(_ item: AgentPluginInstallation) throws -> AgentFiles { try AgentFiles(workspace: item.root.appendingPathComponent("payload").path) }
    func content(_ path: String, installation: AgentPluginInstallation, maximum: Int = 2_000_000) throws -> Data {
        let files = try payload(installation), data = try files.readData(files.literalURL(path), maximum: maximum)
        guard AgentFiles.hash(data) == installation.receipt.hashes[path] else { throw PetError("插件文件已变化，请重新导入：" + path) }; return data
    }
    func setEnabled(_ item: AgentPluginInstallation, _ enabled: Bool) throws {
        let current = try installation(item.id); guard current.receiptHash == item.receiptHash else { throw PetError("插件状态已变化，请刷新") }
        if enabled { for path in current.receipt.hashes.keys { _ = try content(path, installation: current) } }
        if current.workspace != nil { try revokeProjectApproval(current.id); notify(current.id) }
        var receipt = current.receipt; receipt.enabled = enabled; receipt.activationID = UUID().uuidString
        let data = try JSONEncoder().encode(receipt), files = try AgentFiles(workspace: current.root.path)
        try files.writeData(data, to: files.literalURL("receipt.json"), permissions: 0o600)
        if current.workspace != nil && enabled { try recordProjectReview(installation(current.id), active: true) }
        notify(current.id)
    }
    func trash(_ item: AgentPluginInstallation) throws {
        let current = try installation(item.id); guard current.receiptHash == item.receiptHash else { throw PetError("插件状态已变化，请刷新") }
        let files = try AgentFiles(workspace: current.root.path), original = try files.readData(files.literalURL("receipt.json"), maximum: 500_000)
        try setEnabled(current, false)
        do { try FileManager.default.trashItem(at: current.root, resultingItemURL: nil); notify(current.id) }
        catch { try? files.writeData(original, to: files.literalURL("receipt.json"), permissions: 0o600); notify(current.id); throw error }
    }
    func readme(_ item: AgentPluginInstallation) throws -> String {
        for path in ["README.md", "readme.md"] where item.receipt.hashes[path] != nil { return String(String(decoding: try content(path, installation: item), as: UTF8.self).prefix(80_000)) }
        return item.metadata.description
    }
    func extensionItems(workspace: String? = nil, onlyScope: Bool = false) throws -> [AgentExtensionItem] {
        var result: [AgentExtensionItem] = []
        for plugin in try catalog(workspace: workspace, onlyScope: onlyScope) {
            for component in plugin.receipt.components {
                do {
                    let data = try content(component.path, installation: plugin, maximum: 65_536)
                    guard let raw = String(data: data, encoding: .utf8) else { throw PetError("插件组件不是 UTF-8") }
                    let doc = try AgentExtensionDocument(raw), files = try payload(plugin), file = try files.literalURL(component.path)
                    result.append(AgentExtensionItem(id: Self.extensionID(component.path, installation: plugin), name: plugin.metadata.name + ":" + component.name, description: doc.metadata["description"] ?? "", kind: component.kind, file: file, root: component.kind == .skill ? file.deletingLastPathComponent() : files.root, scope: (plugin.workspace == nil ? "插件 · " : "项目插件 · ") + plugin.metadata.title, managed: false, enabled: plugin.enabled, manualOnly: doc.metadata["disable-model-invocation"]?.lowercased() == "true", sha256: AgentFiles.hash(data), pluginName: plugin.id))
                } catch { warnings.append(plugin.id + "：" + error.localizedDescription) }
            }
        }
        return result
    }
    static func extensionID(_ path: String, installation: AgentPluginInstallation) -> String {
        String(AgentFiles.hash(Data((installation.instanceID + ":" + installation.root.appendingPathComponent("payload/" + path).path).utf8)).prefix(24))
    }
    func validate(_ item: AgentExtensionItem, resources: [String: Data]? = nil) throws {
        guard let owner = item.pluginName else { return }
        let plugin = try installation(owner), files = try payload(plugin)
        guard let component = plugin.receipt.components.first(where: { plugin.metadata.name + ":" + $0.name == item.name && $0.kind == item.kind }), try files.literalURL(component.path) == item.file else { throw PetError("插件组件不属于此插件") }
        _ = try content(component.path, installation: plugin, maximum: 65_536)
        if let resources {
            guard plugin.enabled else { throw PetError("插件已停用") }
            let prefix = files.relative(item.root) + "/", expected = Dictionary(uniqueKeysWithValues: plugin.receipt.hashes.filter { $0.key.hasPrefix(prefix) }.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
            guard resources.mapValues(AgentFiles.hash) == expected else { throw PetError("插件 Skill 资源已变化，请重新导入") }
        }
    }
}
