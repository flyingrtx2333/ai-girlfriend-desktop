import Foundation
import Darwin

struct AgentPluginComponent: Codable {
    var kind: AgentExtensionKind, name: String, path: String
}
struct AgentPluginReceipt: Codable {
    var name: String, manifest: String, components: [AgentPluginComponent], hashes: [String: String]
    var sourceName: String, sourceHash: String, installedAt: Date, enabled = false
    var installationID: String? = nil, activationID: String? = nil
}
struct AgentPluginMetadata {
    var name: String, title: String, version: String, author: String, description: String
}
struct AgentPluginPackage {
    var metadata: AgentPluginMetadata, receipt: AgentPluginReceipt, files: [String: Data]
    var mcpServers: [AgentPluginMCPDefinition] = []
}
struct AgentPluginInstallation: Identifiable {
    var metadata: AgentPluginMetadata, receipt: AgentPluginReceipt, root: URL, receiptHash: String
    var mcpServers: [AgentPluginMCPDefinition] = []
    var id: String { receipt.name }
}

@MainActor final class AgentPlugins {
    let profile: URL
    private(set) var warnings: [String] = []
    private var observers: [UUID: (String) -> Void] = [:]
    func observeChanges(_ action: @escaping (String) -> Void) -> UUID { let id = UUID(); observers[id] = action; return id }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    private func notify(_ name: String) { for action in Array(observers.values) { action(name) } }
    init(profile: URL) { self.profile = profile }
    private func folder(_ name: String) throws -> URL {
        guard Self.validName(name) else { throw PetError("插件名称须为64字以内的小写字母、数字和连字符") }
        return try AgentFiles(workspace: profile.path).literalURL("extensions/plugins/" + name)
    }
    private static func validName(_ name: String) -> Bool {
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
        let manifests = [".qoder-plugin/plugin.json", ".claude-plugin/plugin.json"].filter { files[$0] != nil }
        guard let manifest = manifests.first else { throw PetError("插件缺少 .qoder-plugin/plugin.json 或 .claude-plugin/plugin.json") }
        let (info, value) = try metadata(files[manifest]!)
        for other in manifests.dropFirst() {
            let a = try JSONSerialization.jsonObject(with: files[manifest]!) as? NSDictionary, b = try JSONSerialization.jsonObject(with: files[other]!) as? NSDictionary
            guard a == b else { throw PetError("插件的两份 manifest 内容不一致") }
        }
        let unsupported = ["agents", "hooks", "rules", "settings", "outputStyles", "workflowsPath", "workflowsPaths", "permissions", "sdk", "dependencies"]
        for key in unsupported where value[key] != nil {
            let item = value[key]!
            if (item as? [Any])?.isEmpty == true || (item as? [String: Any])?.isEmpty == true || item is NSNull { continue }
            throw PetError("此插件包含尚未接入的 \(key)，未安装")
        }
        guard !files.keys.contains(where: { ["agents/", "hooks/", "rules/", "output-styles/", "workflows/"].contains(where: $0.hasPrefix) }) else { throw PetError("此插件包含尚未接入的 Agent、Hooks、规则或工作流，未安装") }
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
        guard !(components.isEmpty && mcpServers.isEmpty), components.count + mcpServers.count <= 500 else { throw PetError("插件须包含1至500项 Skills、命令或 MCP 连接器") }
        let receipt = AgentPluginReceipt(name: info.name, manifest: manifest, components: components, hashes: files.mapValues(AgentFiles.hash), sourceName: sourceName, sourceHash: sourceHash, installedAt: Date(), installationID: UUID().uuidString, activationID: UUID().uuidString)
        guard try JSONEncoder().encode(receipt).count <= 500_000 else { throw PetError("插件资源索引过大，请缩小插件包") }
        return AgentPluginPackage(metadata: info, receipt: receipt, files: files, mcpServers: mcpServers)
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
    @discardableResult func install(_ candidate: AgentPluginPackage) throws -> AgentPluginInstallation {
        guard try catalog().count < 64 else { throw PetError("插件数量已达到64项") }
        let package = try Self.package(candidate.files, sourceName: candidate.receipt.sourceName, sourceHash: candidate.receipt.sourceHash)
        guard try catalog().reduce(0, { $0 + $1.mcpServers.count }) + package.mcpServers.count <= 64 else { throw PetError("插件 MCP 总数最多64项") }
        let target = try folder(package.metadata.name), files = try AgentFiles(workspace: profile.path), (parentFD, name) = try files.parentDescriptor(target, create: true)
        defer { Darwin.close(parentFD) }
        guard try files.entryMetadata(target).kind == "missing" else { throw PetError("同名插件已安装，请先查看现有版本") }
        let temporaryName = ".plugin-" + UUID().uuidString, temporary = target.deletingLastPathComponent().appendingPathComponent(temporaryName)
        guard mkdirat(parentFD, temporaryName, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var published = false; defer { if !published { try? FileManager.default.removeItem(at: temporary) } }
        let staged = try AgentFiles(workspace: temporary.path)
        for (path, data) in package.files { try staged.writeData(data, to: staged.literalURL("payload/" + path), permissions: 0o400) }
        try staged.writeData(JSONEncoder().encode(package.receipt), to: staged.literalURL("receipt.json"), permissions: 0o600)
        guard renameatx_np(parentFD, temporaryName, parentFD, name, UInt32(RENAME_EXCL)) == 0 else { throw PetError("插件未安装，目标可能已存在") }; published = true
        let installed = try installation(package.metadata.name); notify(installed.id); return installed
    }
    func installation(_ name: String) throws -> AgentPluginInstallation {
        let root = try folder(name)
        guard root.resolvingSymlinksInPath() == root else { throw PetError("插件目录不能是链接") }
        let files = try AgentFiles(workspace: root.path), data = try files.readData(files.literalURL("receipt.json"), maximum: 500_000), receipt = try JSONDecoder().decode(AgentPluginReceipt.self, from: data)
        guard receipt.name == name, receipt.hashes.count <= 2000, !receipt.hashes.isEmpty, receipt.components.count <= 500, receipt.hashes.allSatisfy({ AgentArchive.validPath($0.key) && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit) }), [".qoder-plugin/plugin.json", ".claude-plugin/plugin.json"].contains(receipt.manifest) else { throw PetError("插件安装记录无效") }
        let payloadURL = root.appendingPathComponent("payload")
        guard payloadURL.resolvingSymlinksInPath() == payloadURL else { throw PetError("插件资源目录不能是链接") }
        let payload = try AgentFiles(workspace: payloadURL.path), definition = try payload.readData(payload.literalURL(receipt.manifest), maximum: 65_536)
        guard AgentFiles.hash(definition) == receipt.hashes[receipt.manifest] else { throw PetError("插件清单已变化，请重新导入") }
        let (info, value) = try Self.metadata(definition); guard info.name == name else { throw PetError("插件名称与安装记录不一致") }
        for component in receipt.components { guard AgentExtensions.validName(component.name), receipt.hashes[component.path] != nil, AgentArchive.validPath(component.path) else { throw PetError("插件组件记录无效") } }
        var installed = AgentPluginInstallation(metadata: info, receipt: receipt, root: root, receiptHash: AgentFiles.hash(data))
        installed.mcpServers = try Self.mcpDefinitions(value, paths: Set(receipt.hashes.keys)) { try self.content($0, installation: installed, maximum: 65_536) }
        return installed
    }
    func catalog() throws -> [AgentPluginInstallation] {
        warnings = []; let base = profile.appendingPathComponent("extensions/plugins")
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]); guard children.count <= 64 else { throw PetError("插件数量超过64项") }
        return children.compactMap { url in
            do { guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw PetError("插件目录不能是链接") }; return try installation(url.lastPathComponent) }
            catch { warnings.append(url.lastPathComponent + "：" + error.localizedDescription); return nil }
        }.sorted { $0.metadata.title.localizedStandardCompare($1.metadata.title) == .orderedAscending }
    }
    private func payload(_ item: AgentPluginInstallation) throws -> AgentFiles { try AgentFiles(workspace: item.root.appendingPathComponent("payload").path) }
    func content(_ path: String, installation: AgentPluginInstallation, maximum: Int = 2_000_000) throws -> Data {
        let files = try payload(installation), data = try files.readData(files.literalURL(path), maximum: maximum)
        guard AgentFiles.hash(data) == installation.receipt.hashes[path] else { throw PetError("插件文件已变化，请重新导入：" + path) }; return data
    }
    func setEnabled(_ item: AgentPluginInstallation, _ enabled: Bool) throws {
        let current = try installation(item.id); guard current.receiptHash == item.receiptHash else { throw PetError("插件状态已变化，请刷新") }
        if enabled { for path in current.receipt.hashes.keys { _ = try content(path, installation: current) } }
        var receipt = current.receipt; receipt.enabled = enabled; receipt.activationID = UUID().uuidString
        let files = try AgentFiles(workspace: current.root.path); try files.writeData(JSONEncoder().encode(receipt), to: files.literalURL("receipt.json"), permissions: 0o600)
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
    func extensionItems() throws -> [AgentExtensionItem] {
        var result: [AgentExtensionItem] = []
        for plugin in try catalog() {
            for component in plugin.receipt.components {
                do {
                    let data = try content(component.path, installation: plugin, maximum: 65_536)
                    guard let raw = String(data: data, encoding: .utf8) else { throw PetError("插件组件不是 UTF-8") }
                    let doc = try AgentExtensionDocument(raw), files = try payload(plugin), file = try files.literalURL(component.path)
                    result.append(AgentExtensionItem(id: String(AgentFiles.hash(Data(file.path.utf8)).prefix(24)), name: plugin.id + ":" + component.name, description: doc.metadata["description"] ?? "", kind: component.kind, file: file, root: component.kind == .skill ? file.deletingLastPathComponent() : files.root, scope: "插件 · " + plugin.metadata.title, managed: false, enabled: plugin.receipt.enabled, manualOnly: doc.metadata["disable-model-invocation"]?.lowercased() == "true", sha256: AgentFiles.hash(data), pluginName: plugin.id))
                } catch { warnings.append(plugin.id + "：" + error.localizedDescription) }
            }
        }
        return result
    }
    func validate(_ item: AgentExtensionItem, resources: [String: Data]? = nil) throws {
        guard let owner = item.pluginName else { return }
        let plugin = try installation(owner), files = try payload(plugin)
        guard let component = plugin.receipt.components.first(where: { plugin.id + ":" + $0.name == item.name && $0.kind == item.kind }), try files.literalURL(component.path) == item.file else { throw PetError("插件组件不属于此插件") }
        _ = try content(component.path, installation: plugin, maximum: 65_536)
        if let resources {
            guard plugin.receipt.enabled else { throw PetError("插件已停用") }
            let prefix = files.relative(item.root) + "/", expected = Dictionary(uniqueKeysWithValues: plugin.receipt.hashes.filter { $0.key.hasPrefix(prefix) }.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
            guard resources.mapValues(AgentFiles.hash) == expected else { throw PetError("插件 Skill 资源已变化，请重新导入") }
        }
    }
}
