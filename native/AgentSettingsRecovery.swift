import AppKit

enum AgentSettingsRecovery {
    struct Context: Codable, Equatable, Sendable {
        var taskID: String?, workspace: String?, taskWorkspace: String?, scope: AgentWorkspaceScope?
        var mode: String?, archived: Bool?, ruleDirectories: [AgentRuleDirectory]?
        @MainActor init(task: AgentTaskRecord?, workspace: String?) {
            taskID = task?.id; self.workspace = workspace; taskWorkspace = task?.workspace; scope = task?.workspaceScope
            mode = task?.organizationMode.rawValue; archived = task?.archived; ruleDirectories = task?.ruleDirectories
        }
        var folders: [String] { scope?.folders ?? taskWorkspace.map { [$0] } ?? [] }
        var identity: String { ([taskID ?? "", workspace ?? "", scope?.group ?? taskWorkspace ?? ""] + folders).joined(separator: "\0") }
        var valid: Bool {
            func path(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 16_384 }
            return (taskID.map { UUID(uuidString: $0) != nil } ?? true) &&
                [workspace, taskWorkspace, scope?.group, scope?.primary].compactMap { $0 }.allSatisfy(path) && folders.count <= 128 && folders.allSatisfy(path) &&
                (workspace == nil || folders.contains(workspace!)) &&
                (taskID != nil || workspace == nil && taskWorkspace == nil && scope == nil && mode == nil && archived == nil && ruleDirectories == nil)
        }
        @MainActor func requireCurrent(_ store: AgentStore) throws {
            guard valid else { throw PetError("设置草稿所属范围无效，原记录已保留") }
            if let taskID {
                guard let task = store.task(taskID), Context(task: task, workspace: workspace) == self else { throw PetError("原任务或源文件夹已变化，设置草稿已保留") }
                if task.workspaceScope != nil { _ = try AgentWorkspaceScope.roots(task) }
                if let workspace { _ = try AgentFiles(workspace: workspace) }
            }
        }
    }
    struct Page: Codable, Equatable, Sendable {
        var kind: String
        var state: Data
    }
    static func page<T: Encodable>(_ kind: String, _ value: T) throws -> Page {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 20_000_000 else { throw PetError("设置草稿超过恢复记录容量，当前输入已保留") }
        return .init(kind: kind, state: data)
    }
    struct State: Codable, Equatable, Sendable {
        var version = 1
        var context: Context
        var category: String, root: String
        var active: Bool
        var pages: [Page]
        var y: Double
        var valid: Bool {
            version == 1 && context.valid && ((category == "memory" && root == "rules") || (category == "extensions" && ["skills", "commands"].contains(root))) &&
                (1...16).contains(pages.count) && pages.first?.kind == root && pages.allSatisfy { ["rules", "skills", "commands", "extension-create"].contains($0.kind) && $0.state.count <= 20_000_000 } &&
                y.isFinite && (0...1_000_000_000).contains(y)
        }
    }
    static func object(_ raw: Any, keys: Set<String>) throws -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: keys) else { throw PetError("设置草稿包含未知字段，原记录已保留") }; return value
    }
    static func validateObject(_ raw: Any) throws {
        let value = try object(raw, keys: ["version", "context", "category", "root", "active", "pages", "y"])
        if let context = value["context"] {
            let context = try object(context, keys: ["taskID", "workspace", "taskWorkspace", "scope", "mode", "archived", "ruleDirectories"])
            if let scope = context["scope"], !(scope is NSNull) { _ = try object(scope, keys: ["group", "folders", "primary"]) }
            for directory in context["ruleDirectories"] as? [Any] ?? [] { _ = try object(directory, keys: ["workspace", "path"]) }
        }
        for page in value["pages"] as? [Any] ?? [] { _ = try object(page, keys: ["kind", "state"]) }
    }
}

// Only explicitly named, non-credential editor controls participate. The source
// draft is owned by its manager; this object retains its last content position.
@MainActor final class AgentSettingsDraftViewport: NSObject {
    struct Field: Codable, Equatable {
        var hash: String, count: Int
        var selection: AgentTextViewport.Selection?
    }
    struct State: Codable, Equatable {
        var version = 1
        var text: AgentTextViewport
        var fields: [String: Field]
        var focus: String
    }
    private let text: NSTextView, fields: [String: NSTextField], catalog: NSView
    private let host: () -> NSWindow?
    private var cached: [String: Field] = [:], focus = "body", pending: State?, deferredText: AgentTextViewport?
    private var applying = false, scheduled = false
    var onChange: (() -> Void)?
    init(text: NSTextView, fields: [String: NSTextField], catalog: NSView, host: @escaping () -> NSWindow?) {
        self.text = text; self.fields = fields; self.catalog = catalog; self.host = host
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: NSTextView.didChangeSelectionNotification, object: nil)
        if let clip = text.enclosingScrollView?.contentView { clip.postsBoundsChangedNotifications = true; NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip) }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func field(_ input: NSTextField) -> Field {
        let value = input.stringValue, hash = AgentFiles.hash(Data(value.utf8)), count = (value as NSString).length
        let selection = (input.currentEditor() as? NSTextView).map { AgentTextViewport.Selection(location: $0.selectedRange().location, length: $0.selectedRange().length) }
        let previous = fields.first(where: { $0.value === input }).flatMap { cached[$0.key] }
        return Field(hash: hash, count: count, selection: selection?.valid(in: count) == true ? selection : previous?.hash == hash ? previous?.selection : nil)
    }
    private func remember() {
        guard !applying, pending == nil, let responder = host()?.firstResponder else { return }
        if responder === text { focus = "body" }
        else if responder === catalog { focus = "catalog" }
        else if let item = fields.first(where: { $0.value.currentEditor() === responder }) { focus = item.key; cached[item.key] = field(item.value) }
    }
    @objc private func selectionChanged(_ note: Notification) {
        guard !applying, let editor = note.object as? NSTextView, editor === text || fields.values.contains(where: { $0.currentEditor() === editor }) else { return }
        remember(); onChange?()
    }
    @objc private func boundsChanged(_ note: Notification) { if !applying { onChange?() } }
    func changed() { if !applying { pending = nil; if deferredText?.matches(text) == false { deferredText = nil }; remember(); onChange?() } }
    func reset() { pending = nil; deferredText = nil; cached = [:]; focus = "body" }
    func capture() throws -> State {
        if let pending { return pending }
        remember(); var viewport = try deferredText ?? AgentTextViewport(text); viewport.focused = focus == "body"
        let values = fields.mapValues(field); cached = values
        return State(text: viewport, fields: values, focus: focus)
    }
    func restore(_ value: State) throws {
        try validate(value, text: text.string, fields: fields.mapValues(\.stringValue))
        pending = value; deferredText = value.text; cached = value.fields; focus = value.focus; schedule()
    }
    func validate(_ value: State, text: String, fields values: [String: String]) throws {
        guard value.version == 1, value.text.valid, value.text.hash == AgentFiles.hash(Data(text.utf8)), value.text.count == (text as NSString).length,
              Set(value.fields.keys) == Set(fields.keys), Set(values.keys) == Set(fields.keys), ["body", "catalog"].contains(value.focus) || fields[value.focus] != nil else { throw PetError("设置草稿选区与正文不符，原记录已保留") }
        for (key, saved) in value.fields {
            let current = values[key]!
            guard saved.hash == AgentFiles.hash(Data(current.utf8)), saved.count == (current as NSString).length, saved.selection?.valid(in: saved.count) != false else { throw PetError("设置字段选区与原输入不符，原记录已保留") }
        }
    }
    func appear(default target: NSView) {
        if pending != nil { schedule(); return }
        if let window = host(), let current = window.firstResponder,
           (current === text && text.window === window && !text.isHiddenOrHasHiddenAncestor) ||
            (current === catalog && catalog.window === window && !catalog.isHiddenOrHasHiddenAncestor) ||
            fields.values.contains(where: { $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.currentEditor() === current }) { return }
        applying = true; host()?.makeFirstResponder(target); applying = false; schedule()
    }
    func schedule() {
        guard pending != nil || deferredText != nil, !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { scheduled = false }
            guard let window = host(), window.isVisible else { return }
            if pending == nil {
                guard let value = deferredText, text.window === window, !text.isHiddenOrHasHiddenAncestor else { return }
                applying = true; defer { applying = false }; window.contentView?.layoutSubtreeIfNeeded()
                if value.apply(to: text, focus: false) { deferredText = nil }; return
            }
            let value = pending!
            let target: NSView = value.focus == "body" ? text : value.focus == "catalog" ? catalog : fields[value.focus]!
            guard target.window === window, !target.isHiddenOrHasHiddenAncestor else { return }
            applying = true; defer { applying = false }
            window.contentView?.layoutSubtreeIfNeeded()
            if text.window === window, !text.isHiddenOrHasHiddenAncestor {
                guard value.text.apply(to: text, focus: false) else { return }; deferredText = nil
            }
            guard window.makeFirstResponder(target) else { return }
            if target === text { guard value.text.apply(to: text, focus: false) else { return } }
            else if let field = fields[value.focus], let selection = value.fields[value.focus]?.selection { (field.currentEditor() as? NSTextView)?.setSelectedRange(selection.range) }
            pending = nil
        }
    }
    static func validateObject(_ raw: Any) throws {
        let value = try AgentSettingsRecovery.object(raw, keys: ["version", "text", "fields", "focus"])
        if let text = value["text"] { try AgentTextViewport.validateObject(text) }
        for raw in (value["fields"] as? [String: Any] ?? [:]).values {
            let field = try AgentSettingsRecovery.object(raw, keys: ["hash", "count", "selection"])
            if let selection = field["selection"], !(selection is NSNull) { _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"]) }
        }
    }
}
