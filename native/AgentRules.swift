import Foundation

struct AgentLocalRuleReference: Codable, Equatable {
    var id: String, workspace: String?
}
struct AgentRuleDirectory: Codable, Equatable {
    var workspace: String, path: String
}
struct AgentLocalRuleItem: Identifiable {
    var id: String, invocation: String, source: URL, owner: URL, base: URL
    var rootPath: String, relative: String, scope: String, project: Bool, enabled: Bool
    var text: String?, sha256: String, signature: String, permissions: Int?
    var definition: AgentRuleDefinition?, error: String?
    var name: String { definition?.key ?? source.deletingPathExtension().lastPathComponent }
}

@MainActor final class AgentRules {
    private struct Root {
        var owner: URL, base: URL, path: String, route: String, scope: String, project: Bool
    }
    private struct Settings: Codable { var disabled: Set<String> = [] }
    private let profile: URL, sharedHome: URL?, plugins: AgentPlugins
    var onChange: ((String, String?, Bool) -> Void)?
    init(profile: URL, sharedHome: URL?, plugins: AgentPlugins) { self.profile = profile; self.sharedHome = sharedHome; self.plugins = plugins }

    private func roots(workspace: String?, directories: [AgentRuleDirectory]) throws -> [Root] {
        var result = [Root(owner: profile, base: profile, path: "extensions/rules", route: "user", scope: "用户", project: false)]
        if let sharedHome { result.append(Root(owner: sharedHome, base: sharedHome, path: ".qoder/rules", route: "qoder-user", scope: "用户 · Qoder", project: false)) }
        if let workspace {
            let files = try AgentFiles(workspace: workspace)
            let paths = [""] + Set(directories.filter { $0.workspace == workspace }.map(\.path)).sorted { a, b in
                let ac = a.split(separator: "/").count, bc = b.split(separator: "/").count; return ac == bc ? a < b : ac < bc
            }
            guard paths.count <= 129 else { throw PetError("任务发现的规则目录超过128个，请使用新任务") }
            for path in paths {
                guard path.isEmpty || AgentArchive.validPath(path), !AgentFiles.sensitive(path) else { throw PetError("规则目录超出任务范围") }
                let base = path.isEmpty ? files.root : try files.resolve(path)
                for (folder, route, label) in [(".bluefatfish/rules", "project", "项目"), (".qoder/rules", "qoder-project", "项目 · Qoder")] {
                    result.append(Root(owner: files.root, base: base, path: path.isEmpty ? folder : path + "/" + folder, route: route + (path.isEmpty ? "" : "/" + path), scope: label + (path.isEmpty ? "" : " · " + path), project: true))
                }
            }
        }
        return result
    }
    // Inspect every literal component before enumeration or mutation; a symlinked
    // rules directory is never promoted into a new trusted filesystem root.
    private func checkRoot(_ root: Root) throws -> (files: AgentFiles, exists: Bool) {
        let files = try AgentFiles(workspace: root.owner.path); var prefix = ""
        for part in root.path.split(separator: "/") {
            prefix += (prefix.isEmpty ? "" : "/") + part
            let metadata = try files.entryMetadata(files.literalURL(prefix))
            if metadata.kind == "missing" { return (files, false) }
            guard metadata.kind == "directory" else { throw PetError("规则目录不是普通文件夹：" + prefix) }
        }
        return (files, true)
    }
    private func settings() throws -> (Settings, String) {
        let files = try AgentFiles(workspace: profile.path), url = try files.literalURL("extensions/rule-settings.json"), metadata = try files.entryMetadata(url)
        if metadata.kind == "missing" { return (Settings(), "missing") }
        guard metadata.kind == "file" else { throw PetError("规则启用设置不是普通文件") }
        let value = try JSONDecoder().decode(Settings.self, from: files.readData(url, maximum: 500_000))
        guard value.disabled.count <= 4096, value.disabled.allSatisfy({ $0.hasPrefix("local-rule-") && $0.count == 43 }) else { throw PetError("规则启用设置无效") }
        guard try files.entryMetadata(url).signature == metadata.signature else { throw PetError("规则启用设置已变化，请重试") }
        return (value, metadata.signature)
    }
    private func item(_ root: Root, relative: String, files: AgentFiles, disabled: Set<String>) throws -> AgentLocalRuleItem {
        let url = try files.literalURL(root.path + "/" + relative), metadata = try files.entryMetadata(url)
        let id = "local-rule-" + AgentFiles.hash(Data(url.path.utf8)).prefix(32)
        var value = AgentLocalRuleItem(id: id, invocation: root.route + "/" + String(relative.dropLast(3)), source: url, owner: files.root, base: root.base, rootPath: root.path, relative: relative, scope: root.scope, project: root.project, enabled: !disabled.contains(id), text: nil, sha256: "", signature: metadata.signature, permissions: metadata.permissions)
        do {
            guard metadata.kind == "file", !AgentFiles.sensitive(relative) else { throw PetError("规则不是可读取的普通 Markdown 文件") }
            let data = try files.readData(url, maximum: 80_000)
            guard try files.entryMetadata(url).signature == metadata.signature else { throw PetError("规则文件读取期间已变化，请刷新") }
            value.sha256 = AgentFiles.hash(data)
            guard let text = String(data: data, encoding: .utf8) else { throw PetError("规则需要 UTF-8 Markdown") }
            value.text = text
            let fallback = String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
            value.definition = try AgentRuleDocument.parse(text, path: relative, fallback: fallback)
        } catch { value.error = error.localizedDescription }
        return value
    }
    func catalog(workspace: String?, directories: [AgentRuleDirectory] = []) throws -> [AgentLocalRuleItem] {
        let disabled = try settings().0.disabled; var result: [AgentLocalRuleItem] = [], visited = 0
        for root in try roots(workspace: workspace, directories: directories) {
            let (files, exists) = try checkRoot(root); guard exists else { continue }
            var pending = [""]
            while let relative = pending.popLast() {
                let folder = files.root.appendingPathComponent(root.path + (relative.isEmpty ? "" : "/" + relative))
                let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children {
                    visited += 1; guard visited <= 5000 else { throw PetError("规则目录超过5000项，请缩小范围") }
                    let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                    let metadata = try files.entryMetadata(files.literalURL(root.path + "/" + path))
                    if metadata.kind == "directory" { pending.append(path) }
                    else if child.pathExtension == "md" {
                        result.append(try item(root, relative: path, files: files, disabled: disabled))
                        guard result.count <= 256 else { throw PetError("当前范围最多支持256项用户和项目规则") }
                    } else if metadata.kind == "link" { throw PetError("规则目录含符号链接，请移除或改用普通文件：" + path) }
                }
            }
        }
        return result
    }
    func current(_ id: String, task: AgentTaskRecord, enabledOnly: Bool = true) throws -> AgentLocalRuleItem {
        guard let value = try catalog(workspace: task.workspace, directories: task.ruleDirectories ?? []).first(where: { $0.id == id }), !enabledOnly || value.enabled else { throw PetError("规则已停用、移除或不属于当前任务，请刷新规则") }
        return value
    }
    private func unchanged(_ item: AgentLocalRuleItem, task: AgentTaskRecord) throws -> AgentLocalRuleItem {
        let value = try current(item.id, task: task, enabledOnly: false)
        guard value.signature == item.signature, value.sha256 == item.sha256 else { throw PetError("规则已被其他编辑器修改，请刷新后再编辑；未覆盖外部改动") }
        return value
    }
    @discardableResult func save(_ item: AgentLocalRuleItem, text: String, task: AgentTaskRecord) throws -> AgentLocalRuleItem {
        let old = try unchanged(item, task: task), definition = try AgentRuleDocument.parse(text, path: item.relative, fallback: item.name)
        guard text.utf8.count <= 80_000 else { throw PetError("规则文件超过大小上限") }
        let files = try AgentFiles(workspace: old.owner.path)
        try files.writeData(Data(text.utf8), to: old.source, permissions: old.permissions ?? 0o600, expectedTarget: old.signature)
        let value = try current(item.id, task: task, enabledOnly: false)
        changed(value, task: task, automatic: automatic(old.definition) || automatic(definition)); return value
    }
    @discardableResult func create(name: String, text: String, project: Bool, task: AgentTaskRecord) throws -> AgentLocalRuleItem {
        guard AgentExtensions.validName(name), !name.contains(":") else { throw PetError("规则名称使用文字、数字、连字符或下划线") }
        let all = try catalog(workspace: task.workspace, directories: task.ruleDirectories ?? [])
        guard all.count < 256 else { throw PetError("当前范围最多支持256项用户和项目规则") }
        let definition = try AgentRuleDocument.parse(text, path: name + ".md", fallback: name)
        guard text.utf8.count <= 80_000 else { throw PetError("规则文件超过大小上限") }
        guard let root = try roots(workspace: task.workspace, directories: []).first(where: { $0.route == (project ? "project" : "user") }) else { throw PetError("请先选择项目文件夹") }
        let (files, _) = try checkRoot(root), url = try files.literalURL(root.path + "/" + name + ".md")
        guard try files.entryMetadata(url).kind == "missing" else { throw PetError("已存在同名规则，请使用其他名称") }
        try files.writeData(Data(text.utf8), to: url, permissions: 0o600, expectedTarget: "missing")
        let value = try item(root, relative: name + ".md", files: files, disabled: settings().0.disabled)
        changed(value, task: task, automatic: automatic(definition)); return value
    }
    func setEnabled(_ item: AgentLocalRuleItem, _ enabled: Bool, task: AgentTaskRecord) throws {
        let value = try unchanged(item, task: task); var (settings, signature) = try settings()
        if enabled { guard value.definition != nil else { throw PetError(value.error ?? "请先修复规则") }; settings.disabled.remove(item.id) }
        else { settings.disabled.insert(item.id) }
        let files = try AgentFiles(workspace: profile.path)
        try files.writeData(JSONEncoder().encode(settings), to: files.literalURL("extensions/rule-settings.json"), permissions: 0o600, expectedTarget: signature)
        changed(value, task: task, automatic: automatic(value.definition))
    }
    @discardableResult func trash(_ item: AgentLocalRuleItem, task: AgentTaskRecord) throws -> URL? {
        let value = try unchanged(item, task: task)
        guard value.permissions != nil else { throw PetError("仅支持将普通规则文件移到废纸篓") }
        var destination: NSURL?
        try FileManager.default.trashItem(at: value.source, resultingItemURL: &destination)
        changed(value, task: task, automatic: automatic(value.definition))
        return destination as URL?
    }
    private func automatic(_ definition: AgentRuleDefinition?) -> Bool { definition == nil || definition?.trigger == .always || definition?.trigger == .decision }
    private func changed(_ item: AgentLocalRuleItem, task: AgentTaskRecord, automatic: Bool) { onChange?(item.id, item.project ? task.workspace : nil, automatic) }

    func ruleInput(_ text: String, task: AgentTaskRecord) throws -> AgentLocalRuleReference? {
        let parts = text.split(whereSeparator: \.isWhitespace); guard let first = parts.first else { return nil }
        let name: String
        if first.hasPrefix("@rule:") { name = String(first.dropFirst(6)) }
        else if first == "@rule", parts.count > 1 { name = String(parts[1]) }
        else { return nil }
        guard name.contains("/") else { return nil }
        try requireTask(task)
        guard let value = try catalog(workspace: task.workspace, directories: task.ruleDirectories ?? []).first(where: { $0.invocation == name && $0.enabled }) else { throw PetError("未找到已启用的规则，请在规则列表中选择") }
        guard value.definition != nil else { throw PetError(value.error ?? "规则格式无效") }
        try requireCapacity(task, id: value.id); return AgentLocalRuleReference(id: value.id, workspace: task.workspace)
    }
    private func requireTask(_ task: AgentTaskRecord) throws {
        guard !task.archived, !task.isProjectDocumentation, task.kind != "hook" else { throw PetError("请在普通任务中使用规则") }
    }
    private func requireCapacity(_ task: AgentTaskRecord, id: String) throws {
        guard (task.activeLocalRules?.count ?? 0) < 256 || task.activeLocalRules?.contains(where: { $0.id == id }) == true else { throw PetError("当前任务已载入256项本地规则，请使用新任务") }
    }
    func activate(_ reference: AgentLocalRuleReference, store: AgentStore, taskID: String) throws {
        guard let task = store.task(taskID), task.workspace == reference.workspace else { throw PetError("规则不属于当前任务范围") }
        try requireTask(task); try requireCapacity(task, id: reference.id)
        let value = try current(reference.id, task: task)
        guard value.definition != nil else { throw PetError(value.error ?? "规则格式无效") }
        store.update(taskID) { $0.activateLocalRule(reference) }
        if let error = store.writeError { throw PetError("规则状态未保存：" + error) }
    }
    func accessRules(_ path: String, store: AgentStore, taskID: String) throws {
        guard let task = store.task(taskID), !task.isProjectDocumentation, task.kind != "hook", let workspace = task.workspace else { return }
        let files = try AgentFiles(workspace: workspace), url = try files.resolve(path)
        let parts = files.relative(url.deletingLastPathComponent()).split(separator: "/").map(String.init)
        var directories = (task.ruleDirectories ?? []).filter { $0.workspace == workspace }, prefix = ""
        for part in parts where part != "." {
            prefix += (prefix.isEmpty ? "" : "/") + part
            let value = AgentRuleDirectory(workspace: workspace, path: prefix)
            if !directories.contains(value) { directories.append(value) }
        }
        guard directories.count <= 128 else { throw PetError("任务发现的规则目录超过128个，请使用新任务") }
        if directories != task.ruleDirectories ?? [] { store.update(taskID) { $0.ruleDirectories = directories.isEmpty ? nil : directories } }
        guard let current = store.task(taskID) else { return }
        for value in try catalog(workspace: workspace, directories: directories) where value.enabled {
            guard let definition = value.definition else { throw PetError("规则无法载入：\(value.source.path) · \(value.error ?? "格式无效")") }
            guard definition.trigger == .glob else { continue }
            let base = value.project ? value.base : files.root
            guard url.path.hasPrefix(base.path + "/") else { continue }
            let relative = String(url.path.dropFirst(base.path.count + 1))
            if try AgentRuleDocument.matches(definition.patterns, path: relative) {
                let reference = AgentLocalRuleReference(id: value.id, workspace: workspace)
                if current.activeLocalRules?.contains(reference) != true { try activate(reference, store: store, taskID: taskID) }
            }
        }
        try plugins.accessRules(path, store: store, taskID: taskID)
    }
    func context(_ task: AgentTaskRecord) throws -> (text: String, plugins: [String], local: [String]) {
        guard !task.isProjectDocumentation, task.kind != "hook" else { return ("", [], []) }
        let packaged = try plugins.ruleContextEntries(task); var entries = packaged.entries, local: [String] = []
        for item in try catalog(workspace: task.workspace, directories: task.ruleDirectories ?? []) where item.enabled {
            guard let definition = item.definition else { throw PetError("规则无法载入：\(item.source.path) · \(item.error ?? "格式无效")。请在扩展的规则中修复或停用。") }
            let loaded = definition.trigger == .always || task.activeLocalRules?.contains(AgentLocalRuleReference(id: item.id, workspace: task.workspace)) == true
            if loaded || definition.trigger == .decision {
                entries.append(AgentRuleContextEntry(id: item.id, name: item.invocation, sha256: item.sha256, definition: definition, loaded: loaded)); local.append(item.id)
            }
        }
        return (AgentRuleContextEntry.render(entries), packaged.plugins, local)
    }
}

extension AgentTaskRecord {
    mutating func activateLocalRule(_ reference: AgentLocalRuleReference) {
        if activeLocalRules == nil { activeLocalRules = [] }
        activeLocalRules?.removeAll { $0.id == reference.id }; activeLocalRules?.append(reference)
    }
}
