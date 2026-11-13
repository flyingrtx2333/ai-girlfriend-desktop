import Foundation

enum AgentSlashPresentation: String, Codable, CaseIterable {
    case recent, expanded, collapsed
    var title: String { switch self { case .recent: return "最近使用与分类"; case .expanded: return "全部展开"; case .collapsed: return "收起插件内容" } }
}
enum AgentSlashCategory: String, CaseIterable {
    case recent, modes, skills, plugins, commands
    var title: String { switch self { case .recent: return "最近使用"; case .modes: return "模式"; case .skills: return "技能"; case .plugins: return "插件"; case .commands: return "命令" } }
}
enum AgentSlashBuiltin: String, CaseIterable {
    case compact, canvas, knowledgeEdit = "knowledge-edit", automation
    var title: String { switch self { case .compact: return "压缩上下文"; case .canvas: return "创建画布"; case .knowledgeEdit: return "编辑项目知识"; case .automation: return "创建自动化" } }
    var detail: String { switch self { case .compact: return "压缩当前任务的上下文"; case .canvas: return "生成可交互的画布产物"; case .knowledgeEdit: return "编辑当前项目的 Wiki 与知识卡片"; case .automation: return "按目标与时间起草计划" } }
}
enum AgentSlashEntry {
    case item(AgentExtensionItem), builtin(AgentSlashBuiltin), mode(AgentMode)
    case plugin(String, String, [AgentExtensionItem])
    var id: String {
        switch self { case .item(let item): return "item." + item.id; case .builtin(let value): return "builtin." + value.rawValue; case .mode(let value): return "mode." + value.rawValue; case .plugin(let key, _, _): return "plugin." + String(AgentFiles.hash(Data(key.utf8)).prefix(24)) }
    }
    var title: String { switch self { case .item(let item): return item.name; case .builtin(let value): return value.title; case .mode(let value): return value.title; case .plugin(_, let title, _): return title } }
    var detail: String {
        switch self { case .item(let item): return item.description; case .builtin(let value): return value.detail; case .mode(let value): return value == .goal ? "持续推进目标，依据实际结果核对完成" : "先制定计划，再决定如何执行"; case .plugin(_, _, let items): return "\(items.count) 项能力" }
    }
    var scope: String { switch self { case .item(let item): return item.scope; case .builtin: return "内置命令"; case .mode: return "任务模式"; case .plugin(_, _, let items): return items.first?.scope ?? "插件" } }
    var kindTitle: String { switch self { case .item(let item): return item.kind == .skill ? "技能" : "命令"; case .builtin: return "命令"; case .mode: return "模式"; case .plugin: return "插件" } }
    var symbol: String { switch self { case .item(let item): return item.kind == .skill ? "hammer" : "terminal"; case .builtin: return "command"; case .mode: return "list.bullet.clipboard"; case .plugin: return "puzzlepiece.extension" } }
    var pluginKey: String? { if case .plugin(let key, _, _) = self { return key }; return nil }
    var pluginChildren: [AgentExtensionItem]? { if case .plugin(_, _, let items) = self { return items }; return nil }
    var extensionItem: AgentExtensionItem? { if case .item(let item) = self { return item }; return nil }
    func matches(_ query: String) -> Bool {
        let invocation: String
        switch self { case .item(let item): invocation = item.invocation; case .builtin(let value): invocation = value.rawValue; case .mode(let mode): invocation = mode.rawValue; case .plugin: invocation = "" }
        return [title, detail, scope, invocation].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

@MainActor final class AgentSlashMenu {
    private struct History: Codable { var version = 1; var ids: [String] = [] }
    let profile: URL
    private var history = History(), revision: String?, loadError: String?, writeError: String?
    var issue: String? { loadError ?? writeError }
    var recentIDs: [String] { history.ids }
    init(profile: URL) { self.profile = profile; reload() }
    private static func validID(_ id: String) -> Bool {
        if id.hasPrefix("item.") { let suffix = id.dropFirst(5); return suffix.count == 24 && suffix.allSatisfy { "0123456789abcdef".contains($0) } }
        if id.hasPrefix("builtin.") { return AgentSlashBuiltin(rawValue: String(id.dropFirst(8))) != nil }
        if id.hasPrefix("mode.") { return [AgentMode.goal.rawValue, AgentMode.plan.rawValue].contains(String(id.dropFirst(5))) }
        return false
    }
    func reload() {
        do {
            let files = try AgentFiles(workspace: profile.path), file = try files.literalURL("slash-history.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("slash-history.json") == file, ["file", "missing"].contains(entry.kind) else { throw PetError("命令最近使用必须是普通文件") }
            if entry.kind == "missing" { history = History(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 4096)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "ids"],
                      let value = try? JSONDecoder().decode(History.self, from: data), value.version == 1, value.ids.count <= 12,
                      Set(value.ids).count == value.ids.count, value.ids.allSatisfy(Self.validID) else { throw PetError("命令最近使用的版本或记录无效") }
                history = value; revision = AgentFiles.hash(data)
            }
            loadError = nil
        } catch { loadError = "最近使用未载入：" + error.localizedDescription }
    }
    private func record(_ id: String) {
        guard Self.validID(id) else { return }; reload()
        guard loadError == nil else { return }
        let ids = Array(([id] + history.ids.filter { $0 != id }).prefix(12))
        guard ids != history.ids else { writeError = nil; return }
        do {
            let files = try AgentFiles(workspace: profile.path), file = try files.literalURL("slash-history.json"), entry = try files.entryMetadata(file)
            guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("最近使用配置只读") }
            let value = History(ids: ids), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
            let write = try AgentKnowledgeFileWrite(files: files, path: "slash-history.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "命令最近使用")
            try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
            history = value; revision = AgentFiles.hash(data); writeError = nil
        } catch { writeError = "最近使用未保存：" + error.localizedDescription }
    }
    func recordAccepted(_ message: AgentMessage) {
        guard message.isHumanInput else { return }
        if let reference = message.extensionReferences?.first { record("item." + reference.id); return }
        guard let first = message.content.split(whereSeparator: \.isWhitespace).first, first.hasPrefix("/"), let value = AgentSlashBuiltin(rawValue: String(first.dropFirst())) else { return }
        recordBuiltin(value)
    }
    func recordBuiltin(_ value: AgentSlashBuiltin) { record("builtin." + value.rawValue) }
    func recordMode(_ value: AgentMode) { record("mode." + value.rawValue) }
    func entries(_ items: [AgentExtensionItem], task: AgentTaskRecord, idle: Bool, canChangeMode: Bool) -> [AgentSlashEntry] {
        guard !task.archived, !task.isProjectDocumentation, task.kind != "hook" else { return [] }
        let enabled = items.filter(\.enabled)
        var result: [AgentSlashEntry] = canChangeMode && ![.running, .waiting].contains(task.status) && task.automation == nil && task.agent?.ownerID == nil ? [.mode(.goal), .mode(.plan)] : []
        if idle, !task.messages.isEmpty { result.append(.builtin(.compact)) }
        if [.agent, .goal].contains(task.mode) {
            result.append(.builtin(.canvas)); if task.workspace != nil { result.append(.builtin(.knowledgeEdit)) }
        }
        if task.automation == nil, task.agent?.ownerID == nil { result.append(.builtin(.automation)) }
        result += enabled.map(AgentSlashEntry.item)
        let groups = Dictionary(grouping: enabled.filter { $0.pluginName != nil }, by: { $0.pluginName! })
        let plugins = groups.map { key, items -> AgentSlashEntry in
            var title = items.first?.scope ?? key
            for prefix in ["项目插件 · ", "插件 · "] where title.hasPrefix(prefix) { title = String(title.dropFirst(prefix.count)); break }
            return .plugin(key, title, items)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result + plugins
    }
    func visible(_ entries: [AgentSlashEntry], presentation: AgentSlashPresentation, category: AgentSlashCategory, query: String, plugin: String?) -> [AgentSlashEntry] {
        if let plugin { return entries.first(where: { $0.pluginKey == plugin })?.pluginChildren?.map(AgentSlashEntry.item) ?? [] }
        if !query.isEmpty { return entries.filter { $0.matches(query) } }
        if presentation == .expanded { return entries.filter { $0.pluginKey == nil } }
        if presentation == .collapsed { return entries.filter { $0.extensionItem?.pluginName == nil } }
        switch category {
        case .recent:
            let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }); return history.ids.compactMap { values[$0] }
        case .modes: return entries.filter { if case .mode = $0 { return true }; return false }
        case .skills: return entries.filter { $0.extensionItem?.kind == .skill }
        case .plugins: return entries.filter { $0.pluginKey != nil }
        case .commands: return entries.filter { if case .builtin = $0 { return true }; return $0.extensionItem?.kind == .command }
        }
    }
}
