import Foundation

enum AgentExtensionKind: String, Codable, CaseIterable, Sendable {
    case skill, command
    var title: String { self == .skill ? "Skills" : "命令" }
    var folder: String { self == .skill ? "skills" : "commands" }
}

struct AgentExtensionReference: Codable, Sendable {
    var id: String
    var name: String
    var kind: AgentExtensionKind
    var source: String
    var sha256: String
    var snapshot: String?
    var pluginName: String? = nil
}

struct AgentExtensionItem: Identifiable, Sendable {
    var id: String
    var name: String
    var description: String
    var kind: AgentExtensionKind
    var file: URL
    var root: URL
    var scope: String
    var managed: Bool
    var enabled: Bool
    var manualOnly: Bool
    var sha256: String
    var pluginName: String? = nil
    var invocation: String { kind.rawValue + ":" + name }
}

struct AgentExtensionDocument: Sendable {
    var metadata: [String: String]
    var body: String
    init(_ text: String) throws {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\0"), normalized.utf8.count <= 65_536 else { throw PetError("扩展说明必须是 64KB 以内的 UTF-8 文本") }
        var lines = normalized.components(separatedBy: "\n"), fields: [String: String] = [:]
        if lines.first == "---" {
            guard let end = lines.dropFirst().firstIndex(of: "---"), end < 200 else { throw PetError("扩展文件的 frontmatter 未闭合或过长") }
            var key: String?, multiline = false
            for line in lines[1..<end] {
                if multiline, line.hasPrefix(" ") || line.hasPrefix("\t") {
                    if let key { fields[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }; continue
                }
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("#") else { continue }
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                multiline = ["|", ">", "|-", ">-"].contains(value); key = name
                if multiline { value = "" }
                else if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first { value = String(value.dropFirst().dropLast()) }
                fields[name] = value
            }
            lines.removeFirst(end + 1)
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PetError("扩展说明没有正文") }
        metadata = fields; self.body = body
    }
}

@MainActor final class AgentExtensions {
    let profile: URL
    let sharedHome: URL?
    let plugins: AgentPlugins
    private(set) var warnings: [String] = []
    private struct Settings: Codable { var disabled: Set<String> = [] }
    init(profile: URL, sharedHome: URL? = FileManager.default.homeDirectoryForCurrentUser) {
        let root = profile.standardizedFileURL.resolvingSymlinksInPath()
        self.profile = root; self.sharedHome = sharedHome; plugins = AgentPlugins(profile: root, sharedHome: sharedHome)
    }
    private var settingsFile: URL { profile.appendingPathComponent("extensions/settings.json") }
    private func settings() throws -> Settings {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return Settings() }
        let files = try AgentFiles(workspace: profile.path)
        return try JSONDecoder().decode(Settings.self, from: files.readData(files.resolve(settingsFile.path), maximum: 500_000))
    }
    static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 160 else { return false }
        return name.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { segment in
            !segment.isEmpty && segment.count <= 64 && segment.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }
        }
    }
    private func roots(_ kind: AgentExtensionKind, workspace: String?) throws -> [(URL, String, Bool)] {
        var result: [(URL, String, Bool)] = [(profile.appendingPathComponent("extensions/" + kind.folder), "全局", true)]
        if let sharedHome {
            result.append((sharedHome.appendingPathComponent(".qoder/" + kind.folder), "Qoder 全局", false))
            if kind == .skill { result.append((sharedHome.appendingPathComponent(".agents/skills"), "共享全局", false)) }
        }
        if let workspace {
            let files = try AgentFiles(workspace: workspace)
            for path in [".bluefatfish/" + kind.folder, ".qoder/" + kind.folder, ".agents/" + kind.folder] {
                result.append((try files.resolve(path), "项目", path.hasPrefix(".bluefatfish/")))
            }
        }
        return result
    }
    func catalog(workspace: String?, includeDisabled: Bool = true) throws -> [AgentExtensionItem] {
        warnings = []; let disabled = try settings().disabled
        var items: [AgentExtensionItem] = [], seen: Set<String> = []
        for kind in AgentExtensionKind.allCases {
            for (directory, scope, managed) in try roots(kind, workspace: workspace) {
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                do {
                    let files = try AgentFiles(workspace: directory.path)
                    guard let iterator = FileManager.default.enumerator(at: files.root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
                    var visited = 0
                    while let enumerated = iterator.nextObject() as? URL {
                        let file = enumerated.standardizedFileURL.resolvingSymlinksInPath()
                        visited += 1
                        guard visited <= 5000, items.count < 1000 else { warnings.append("扩展扫描达到上限：" + directory.path); break }
                        let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                        if values.isDirectory == true {
                            if kind == .skill, files.relative(file).split(separator: "/").count > 1 { iterator.skipDescendants() }
                            continue
                        }
                        let relative = files.relative(file), segments = relative.split(separator: "/")
                        if kind == .skill, file.lastPathComponent != "SKILL.md" || segments.count != 2 { continue }
                        if kind == .command, file.pathExtension.lowercased() != "md" { continue }
                        do {
                            let data = try files.readData(file, maximum: 65_536)
                            guard let text = String(data: data, encoding: .utf8) else { throw PetError("扩展说明不是 UTF-8") }
                            let document = try AgentExtensionDocument(text)
                            let name = kind == .skill ? document.metadata["name"] ?? file.deletingLastPathComponent().lastPathComponent : String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
                            guard Self.validName(name) else { throw PetError("名称只支持文字、数字、连字符和下划线") }
                            let key = kind.rawValue + ":" + name.lowercased()
                            guard seen.insert(key).inserted else { continue }
                            let id = String(AgentFiles.hash(Data(file.standardizedFileURL.path.utf8)).prefix(24))
                            let description = document.metadata["description"] ?? String(document.body.split(separator: "\n").first ?? "")
                            let item = AgentExtensionItem(id: id, name: name, description: String(description.prefix(500)), kind: kind, file: file, root: kind == .skill ? file.deletingLastPathComponent() : files.root, scope: scope, managed: managed, enabled: !disabled.contains(id), manualOnly: document.metadata["disable-model-invocation"]?.lowercased() == "true", sha256: AgentFiles.hash(data))
                            if includeDisabled || item.enabled { items.append(item) }
                        } catch { warnings.append(file.path + "：" + error.localizedDescription) }
                    }
                } catch { warnings.append(directory.path + "：" + error.localizedDescription) }
            }
        }
        for item in try plugins.extensionItems(workspace: workspace) {
            guard seen.insert(item.kind.rawValue + ":" + item.name.lowercased()).inserted else { warnings.append("插件组件与已有扩展同名：" + item.name); continue }
            if includeDisabled || item.enabled { items.append(item) }
        }
        warnings += plugins.warnings
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func item(_ id: String, workspace: String?, enabled: Bool = true) throws -> AgentExtensionItem {
        guard let item = try catalog(workspace: workspace).first(where: { $0.id == id }), !enabled || item.enabled else { throw PetError("扩展已停用、移除或不属于当前项目，请重新选择") }
        return item
    }
    func document(_ item: AgentExtensionItem) throws -> (String, AgentExtensionDocument) {
        try plugins.validate(item)
        let files = try AgentFiles(workspace: item.root.path), data = try files.readData(files.resolve(item.file.path), maximum: 65_536)
        guard let text = String(data: data, encoding: .utf8) else { throw PetError("扩展说明不是 UTF-8") }
        return (text, try AgentExtensionDocument(text))
    }
    func setEnabled(_ item: AgentExtensionItem, enabled: Bool, workspace: String?) throws {
        let current = try self.item(item.id, workspace: workspace, enabled: false)
        guard current.pluginName == nil else { throw PetError("请在插件中启停整个插件") }
        var value = try settings(); if enabled { value.disabled.remove(item.id) } else { value.disabled.insert(item.id) }
        let files = try AgentFiles(workspace: profile.path)
        try files.writeData(JSONEncoder().encode(value), to: files.resolve(settingsFile.path), permissions: 0o600)
    }
    func save(_ item: AgentExtensionItem, text: String, expectedHash: String, workspace: String?) throws -> AgentExtensionItem {
        let current = try self.item(item.id, workspace: workspace, enabled: false)
        guard current.managed else { throw PetError("共享扩展请打开源文件编辑") }
        let document = try AgentExtensionDocument(text)
        if current.kind == .skill, let name = document.metadata["name"] {
            guard Self.validName(name), !name.contains(":") else { throw PetError("Skill 名称使用文字、数字、连字符或下划线") }
            guard try !catalog(workspace: workspace).contains(where: { $0.id != current.id && $0.kind == .skill && $0.name.lowercased() == name.lowercased() }) else { throw PetError("同名 Skill 已存在") }
        }
        let files = try AgentFiles(workspace: current.root.path), data = try files.readData(files.resolve(current.file.path), maximum: 65_536)
        guard AgentFiles.hash(data) == expectedHash else { throw PetError("扩展已被其他程序修改，请刷新后重新编辑") }
        try files.writeData(Data(text.utf8), to: files.resolve(current.file.path), permissions: 0o600)
        guard let saved = try catalog(workspace: workspace).first(where: { $0.file == current.file }) else { throw PetError("文件已保存，但名称无效，请打开源文件修正") }
        return saved
    }
    private func destination(_ kind: AgentExtensionKind, name: String, project: Bool, workspace: String?) throws -> URL {
        guard Self.validName(name), kind != .skill || !name.contains(":") else { throw PetError("名称使用文字、数字、连字符或下划线；命令可用冒号分组") }
        let files = try AgentFiles(workspace: project ? workspace : profile.path)
        let base = project ? ".bluefatfish/" : "extensions/"
        return try files.resolve(base + kind.folder + "/" + name.replacingOccurrences(of: ":", with: "/") + (kind == .skill ? "/SKILL.md" : ".md"))
    }
    func create(_ kind: AgentExtensionKind, name: String, text: String, project: Bool, workspace: String?) throws -> AgentExtensionItem {
        let file = try destination(kind, name: name, project: project, workspace: workspace)
        let document = try AgentExtensionDocument(text)
        guard kind != .skill || document.metadata["name"] == nil || document.metadata["name"] == name else { throw PetError("Skill 的 name 必须与新建名称一致") }
        guard try !catalog(workspace: workspace).contains(where: { $0.kind == kind && $0.name.lowercased() == name.lowercased() }) else { throw PetError("同名扩展已存在，请换一个名称") }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("同名扩展已存在，请换一个名称") }
        let files = try AgentFiles(workspace: project ? workspace : profile.path)
        try files.writeData(Data(text.utf8), to: file, permissions: 0o600)
        guard let item = try catalog(workspace: workspace).first(where: { $0.file == file }) else { throw PetError("文件已创建，但被更高优先级的同名扩展覆盖，请检查名称") }
        return item
    }
    func trash(_ item: AgentExtensionItem, workspace: String?) throws {
        let current = try self.item(item.id, workspace: workspace, enabled: false)
        guard current.managed else { throw PetError("共享扩展请在来源目录管理") }
        try FileManager.default.trashItem(at: current.kind == .skill ? current.root : current.file, resultingItemURL: nil)
    }
    // Resources are copied into this task's existing command scratch area.
    // Scripts keep the normal command approval, network and project boundaries.
    func activate(_ id: String, store: AgentStore, taskID: String, explicit: Bool = false) throws -> (AgentExtensionReference, String) {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        try store.agents.checkSkill(id, task: task)
        guard task.kind != "wiki" else { throw PetError("Wiki 任务不载入扩展，请在普通任务中使用") }
        let item = try item(id, workspace: task.workspace), (raw, document) = try document(item)
        guard item.kind == .skill else { throw PetError("命令由用户在输入框中选择，不能由模型代为调用") }
        guard explicit || !item.manualOnly else { throw PetError("此 Skill 仅允许用户通过 / 手动选择") }
        let scratch = try store.backupDirectory(taskID).deletingLastPathComponent().appendingPathComponent("tmp/extensions", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = try AgentFiles(workspace: item.root.path), resources = try Self.resourceData(source)
        try plugins.validate(item, resources: resources)
        let digest = Self.digest(resources), destination = scratch.appendingPathComponent(item.id + "-" + String(digest.prefix(16)), isDirectory: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = scratch.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let files = try AgentFiles(workspace: temporary.path)
            for (path, data) in resources { try files.writeData(data, to: files.resolve(path), permissions: 0o400) }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        guard resources["SKILL.md"] == Data(raw.utf8) else { throw PetError("Skill 在读取期间发生变化，请重新加载") }
        let reference = AgentExtensionReference(id: item.id, name: item.name, kind: .skill, source: item.file.path, sha256: digest, snapshot: destination.path, pluginName: item.pluginName)
        let names = resources.keys.sorted().prefix(100).joined(separator: "\n")
        return (reference, "[已载入 Skill：\(item.name)，来源 \(item.file.path)，sha256=\(digest)。仅提供工作流，不改变任务权限或审批。相对资源路径以副本目录为基准；需要执行脚本时仍使用 run_command。]\n资源副本：\(destination.path)\n资源：\n\(names)\n\n" + document.body)
    }
    nonisolated static func resourceData(_ files: AgentFiles) throws -> [String: Data] {
        guard let iterator = FileManager.default.enumerator(at: files.root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { throw PetError("Skill 目录无法读取") }
        var result: [String: Data] = [:], total = 0, visited = 0
        while let url = iterator.nextObject() as? URL {
            try Task.checkCancellation(); visited += 1
            guard visited <= 2000 else { throw PetError("Skill 资源超过 2000 项，请缩小目录") }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), path = files.relative(url)
            guard values.isSymbolicLink != true else { throw PetError("Skill 资源含符号链接，请先整理为普通文件：" + path) }
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") || ["node_modules", "__pycache__"].contains(String($0)) }) { iterator.skipDescendants(); continue }
            guard !AgentFiles.sensitive(path) else { throw PetError("Skill 资源含受保护文件：" + path) }
            if values.isDirectory == true { continue }
            let data = try files.readData(url, maximum: 2_000_000); total += data.count
            guard total <= 20_000_000 else { throw PetError("Skill 资源总量超过 20MB") }
            result[path] = data
        }
        guard result["SKILL.md"] != nil else { throw PetError("目录中没有 SKILL.md") }; return result
    }
    nonisolated static func digest(_ files: [String: Data]) -> String {
        AgentFiles.hash(Data(files.keys.sorted().map { $0 + "\0" + AgentFiles.hash(files[$0]!) }.joined(separator: "\n").utf8))
    }
    func expand(_ message: AgentMessage, store: AgentStore, taskID: String) throws -> AgentMessage {
        guard message.content.hasPrefix("/"), let task = store.task(taskID) else { return message }
        guard task.kind != "wiki" else { throw PetError("Wiki 任务不载入扩展，请在普通任务中使用") }
        let parts = message.content.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }), route = String(parts[0].dropFirst())
        if route.contains("/"), FileManager.default.fileExists(atPath: String(parts[0])) { return message }
        let all = try catalog(workspace: task.workspace, includeDisabled: false)
        let item = all.first { $0.invocation.caseInsensitiveCompare(route) == .orderedSame } ?? all.first { $0.kind == .command && $0.name.caseInsensitiveCompare(route) == .orderedSame } ?? all.first { $0.name.caseInsensitiveCompare(route) == .orderedSame }
        guard let item else { throw PetError("未找到已启用的 /\(route)，请在扩展中检查名称和项目范围") }
        var result = message
        if item.kind == .skill {
            let (reference, instructions) = try activate(item.id, store: store, taskID: taskID, explicit: true)
            result.extensionReferences = [reference]; result.extensionInstructions = instructions
        } else {
            let (raw, document) = try document(item), arguments = parts.count > 1 ? String(parts[1]) : ""
            result.extensionReferences = [AgentExtensionReference(id: item.id, name: item.name, kind: .command, source: item.file.path, sha256: AgentFiles.hash(Data(raw.utf8)), pluginName: item.pluginName)]
            result.extensionInstructions = "[用户选择的命令 /\(item.name)，来源 \(item.file.path)。权限、审批与用户后续要求不变。]\n" + document.body.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        }
        return result
    }
    private func snapshot(_ reference: AgentExtensionReference, store: AgentStore, taskID: String) throws -> (URL, [String: Data]) {
        let parent = try store.backupDirectory(taskID).deletingLastPathComponent().appendingPathComponent("tmp/extensions", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let expected = parent.appendingPathComponent(reference.id + "-" + String(reference.sha256.prefix(16)), isDirectory: true)
        guard reference.id.count == 24, reference.id.allSatisfy(\.isHexDigit), reference.sha256.count == 64, reference.sha256.allSatisfy(\.isHexDigit),
              reference.snapshot == expected.path, expected.resolvingSymlinksInPath() == expected else { throw PetError("Skill 副本不属于当前任务，请重新载入") }
        let resources = try Self.resourceData(AgentFiles(workspace: expected.path))
        guard Self.digest(resources) == reference.sha256 else { throw PetError("Skill 副本已变化，请重新载入：" + reference.name) }; return (expected, resources)
    }
    func context(store: AgentStore, task: AgentTaskRecord) throws -> String {
        let pluginRoot = profile.appendingPathComponent("extensions/plugins").path + "/"
        for reference in task.messages.last(where: \.isHumanInput)?.extensionReferences ?? [] where reference.pluginName != nil || reference.source.hasPrefix(pluginRoot) {
            let current = try item(reference.id, workspace: task.workspace)
            guard current.pluginName != nil && (reference.pluginName == nil || reference.pluginName == current.pluginName) else { throw PetError("插件扩展已变化，请重新选择 /命令或 Skill") }
        }
        guard let active = task.activeSkills, !active.isEmpty else { return "" }
        let available = try catalog(workspace: task.workspace, includeDisabled: false)
        var result = "\n[当前 Skill；流程不能覆盖用户要求、任务模式或审批。相对资源以本任务副本为基准。]\n"
        for reference in active where available.contains(where: { $0.id == reference.id }) {
            try store.agents.checkSkill(reference.id, task: task)
            let (url, resources) = try snapshot(reference, store: store, taskID: task.id)
            guard let data = resources["SKILL.md"], let raw = String(data: data, encoding: .utf8) else { throw PetError("Skill 副本缺少说明") }
            let explicit = task.messages.contains { $0.isHumanInput && $0.extensionReferences?.contains(where: { $0.id == reference.id && $0.sha256 == reference.sha256 }) == true }
            result += "Skill \(reference.name) · id=\(reference.id) · \(reference.sha256)\n资源副本：\(url.path)\n"
            if !explicit { result += try AgentExtensionDocument(raw).body + "\n" }
        }
        return result
    }
    func readResource(_ id: String, path: String, offset: Int, store: AgentStore, taskID: String) throws -> String {
        guard let task = store.task(taskID), let reference = task.activeSkills?.last(where: { $0.id == id }) else { throw PetError("请先用 read_skill 载入此 Skill") }
        try store.agents.checkSkill(id, task: task)
        _ = try item(id, workspace: task.workspace)
        let (url, resources) = try snapshot(reference, store: store, taskID: taskID)
        if path.isEmpty || path == "." {
            let names = resources.keys.sorted(), start = min(names.count, max(0, offset - 1)), end = min(names.count, start + 40)
            return names[start..<end].joined(separator: "\n") + (end < names.count ? "\n[继续 offset=\(end + 1)]" : "")
        }
        guard resources[path] != nil else { throw PetError("此资源不在 Skill 副本中，请读取 path=. 查看实际资源") }
        let files = try AgentFiles(workspace: url.path)
        return try files.readResolved(files.resolve(path), offset: offset, limit: 100)
    }
    func copyForFork(store: AgentStore, sourceID: String, task: inout AgentTaskRecord) throws {
        let references = (task.messages + (task.queuedMessages ?? [])).flatMap { $0.extensionReferences ?? [] } + (task.activeSkills ?? [])
        var mapped: [String: String] = [:]
        for reference in references where reference.kind == .skill {
            guard let old = reference.snapshot, mapped[old] == nil else { continue }
            let (_, resources) = try snapshot(reference, store: store, taskID: sourceID)
            let parent = try store.backupDirectory(task.id).deletingLastPathComponent().appendingPathComponent("tmp/extensions", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = parent.appendingPathComponent(URL(fileURLWithPath: old).lastPathComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let files = try AgentFiles(workspace: destination.path)
            for (path, data) in resources { try files.writeData(data, to: files.resolve(path), permissions: 0o400) }; mapped[old] = destination.path
        }
        func rewrite(_ message: inout AgentMessage) {
            for (old, new) in mapped { message.extensionInstructions = message.extensionInstructions?.replacingOccurrences(of: old, with: new) }
            if let refs = message.extensionReferences { message.extensionReferences = refs.map { ref in var result = ref; if let path = ref.snapshot { result.snapshot = mapped[path] ?? path }; return result } }
        }
        for index in task.messages.indices { rewrite(&task.messages[index]) }
        if task.queuedMessages != nil { for index in task.queuedMessages!.indices { rewrite(&task.queuedMessages![index]) } }
        task.activeSkills = task.activeSkills?.map { ref in var result = ref; if let path = ref.snapshot { result.snapshot = mapped[path] ?? path }; return result }
    }
}
