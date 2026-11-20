import AppKit

enum AgentSettingsRecovery {
    struct Context: Codable, Equatable, Sendable {
        var taskID: String?, workspace: String?, taskWorkspace: String?, scope: AgentWorkspaceScope?
        var mode: String?, archived: Bool?, ruleDirectories: [AgentRuleDirectory]?
        var managedProject: Bool?
        @MainActor init(task: AgentTaskRecord?, workspace: String?) {
            taskID = task?.id; self.workspace = workspace; taskWorkspace = task?.workspace; scope = task?.workspaceScope
            mode = task?.organizationMode.rawValue; archived = task?.archived; ruleDirectories = task?.ruleDirectories
        }
        init(managedWorkspace: String) { workspace = managedWorkspace; managedProject = true }
        var folders: [String] { scope?.folders ?? taskWorkspace.map { [$0] } ?? (managedProject == true ? workspace.map { [$0] } ?? [] : []) }
        var identity: String { ([taskID ?? "", workspace ?? "", scope?.group ?? taskWorkspace ?? ""] + folders).joined(separator: "\0") }
        var valid: Bool {
            func path(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 16_384 }
            if managedProject == true {
                return taskID == nil && taskWorkspace == nil && scope == nil && workspace.map(path) == true &&
                    mode == nil && archived == nil && ruleDirectories == nil
            }
            return (taskID.map { UUID(uuidString: $0) != nil } ?? true) &&
                [workspace, taskWorkspace, scope?.group, scope?.primary].compactMap { $0 }.allSatisfy(path) && folders.count <= 128 && folders.allSatisfy(path) &&
                (workspace == nil || folders.contains(workspace!)) &&
                (taskID != nil || workspace == nil && taskWorkspace == nil && scope == nil && mode == nil && archived == nil && ruleDirectories == nil)
        }
        @MainActor func requireCurrent(_ store: AgentStore) throws {
            guard valid else { throw PetError("设置草稿所属范围无效，原记录已保留") }
            if managedProject == true { try AgentMCPDataImport.requireDestination(workspace, store: store); return }
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
    static func validHash(_ hash: String?) -> Bool {
        hash.map { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? true
    }
    static func validScroll(_ value: Double?) -> Bool { value.map { $0.isFinite && (0...1_000_000_000).contains($0) } ?? true }
    static let roots: Set<String> = ["memory", "rules", "skills", "commands", "hooks", "agents", "teams", "plugins", "mcp", "git", "worktrees"]
    struct Navigation: Codable, Equatable, Sendable {
        var version = 1
        var category: String, page: String?
        var source: String?
        var query: String, selection: AgentTextViewport.Selection?, focus: String?
        var resultVisible: Bool?
        var contentY: Double, sidebarY: Double
        var returnTab: String, knowledgeRoot: String?

        var valid: Bool {
            func identifier(_ value: String) -> Bool {
                !value.isEmpty && value.utf8.count <= 40 && value.utf8.allSatisfy { (97...122).contains($0) || $0 == 45 }
            }
            return version == 1 && identifier(category) && page.map(identifier) != false &&
                source.map({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 16_384 }) != false &&
                query.utf8.count <= 20_000_000 && !query.contains("\0") &&
                selection?.valid(in: query.utf16.count) != false &&
                focus.map({ $0 == "search" || AgentSettingsRecovery.validHash($0) }) != false &&
                (resultVisible == nil || focus != nil && focus != "search") &&
                AgentSettingsRecovery.validScroll(contentY) && AgentSettingsRecovery.validScroll(sidebarY) &&
                ["chat", "attention", "automation", "knowledge"].contains(returnTab) &&
                knowledgeRoot.map({ returnTab == "knowledge" && ["library", "wiki"].contains($0) }) != false
        }
    }
    struct State: Codable, Equatable, Sendable {
        var version = 1
        var context: Context
        var category: String, root: String
        var active: Bool
        var pages: [Page]
        var y: Double
        var valid: Bool {
            guard version == 1, context.valid, (1...16).contains(pages.count), pages.first?.kind == root,
                  pages.allSatisfy({ $0.state.count <= 20_000_000 }), AgentSettingsRecovery.validScroll(y) else { return false }
            let kinds = pages.map(\.kind)
            switch (category, root) {
            case ("memory", "memory"):
                return kinds == [root] || kinds == [root, "memory-editor"] || kinds == [root, "memory-editor", "memory-topic"] || kinds == [root, "memory-cleanup"]
            case ("memory", "rules"), ("extensions", "skills"), ("extensions", "commands"):
                return kinds.allSatisfy { ["rules", "skills", "commands", "extension-create"].contains($0) }
            case ("hooks", "hooks"): return kinds == [root] || kinds == [root, "hook-config"]
            case ("extensions", "plugins"):
                return kinds == [root] || kinds == [root, "plugin-settings"] || kinds == [root, "plugin-history"]
                    || kinds == [root, "plugin-history", "plugin-history-review"] || kinds == [root, "plugin-review"]
                    || kinds == [root, "plugin-market"] || kinds == [root, "plugin-market", "plugin-market-review"]
            case ("extensions", "mcp"):
                return kinds == [root] || kinds == [root, "mcp-detail"] || kinds == [root, "mcp-import"] || kinds == [root, "mcp-detail", "mcp-import"]
            case ("teams", "teams"): return kinds == [root] || kinds == [root, "agents"] || kinds == [root, "agents", "mcp-tool-rule"]
            case ("agents", "agents"), ("extensions", "agents"): return kinds == [root] || kinds == [root, "mcp-tool-rule"]
            case ("git", "git"), ("worktrees", "worktrees"): return kinds == [root] && context.taskID == nil && context.workspace == nil
            default: return false
            }
        }
    }
    static func object(_ raw: Any, keys: Set<String>) throws -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: keys) else { throw PetError("设置草稿包含未知字段，原记录已保留") }; return value
    }
    static func validateObject(_ raw: Any) throws {
        let value = try object(raw, keys: ["version", "context", "category", "root", "active", "pages", "y"])
        if let context = value["context"] { try validateContext(context) }
        for page in value["pages"] as? [Any] ?? [] { _ = try object(page, keys: ["kind", "state"]) }
    }
    static func validateContext(_ raw: Any) throws {
        let context = try object(raw, keys: ["taskID", "workspace", "taskWorkspace", "scope", "mode", "archived", "ruleDirectories", "managedProject"])
        if let scope = context["scope"], !(scope is NSNull) { _ = try object(scope, keys: ["group", "folders", "primary"]) }
        for directory in context["ruleDirectories"] as? [Any] ?? [] { _ = try object(directory, keys: ["workspace", "path"]) }
    }
    static func validateNavigation(_ raw: Any) throws {
        let value = try object(raw, keys: ["version", "category", "page", "source", "query", "selection", "focus",
            "resultVisible", "contentY", "sidebarY", "returnTab", "knowledgeRoot"])
        if let selection = value["selection"], !(selection is NSNull) { _ = try object(selection, keys: ["location", "length"]) }
    }
    @MainActor static func restoreScroll(_ y: Double, to scroll: NSScrollView) {
        let clip = scroll.contentView
        let bounds = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size))
        clip.scroll(to: bounds.origin); scroll.reflectScrolledClipView(clip)
    }
    @MainActor static func selectionIsVisible(in table: NSTableView) -> Bool {
        let row = table.selectedRow
        guard row >= 0, let visible = table.enclosingScrollView?.documentVisibleRect, !visible.isEmpty else { return false }
        let rect = table.rect(ofRow: row)
        return rect.minY < visible.maxY && rect.maxY > visible.minY
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
        var formY: Double? = nil
        var catalogY: Double? = nil
        var visibleSelectionHeight: Double? = nil
    }
    private let text: NSTextView, catalog: NSView
    private var fields: [String: NSTextField]
    private weak var form: NSScrollView?
    private weak var observedCatalogClip: NSClipView?
    private var tracksCatalogScroll = false
    private var deferredCatalogY: Double?
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
    func trackForm(_ form: NSScrollView?) {
        if let clip = self.form?.contentView { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip) }
        self.form = form; tracksCatalogScroll = true
        if let clip = form?.contentView { observeScroll(clip) }
    }
    func trackFields(_ fields: [String: NSTextField]) {
        self.fields = fields
        cached = cached.filter { fields[$0.key] != nil }
        if focus != "catalog", fields[focus] == nil { focus = "body" }
    }
    private func observeScroll(_ clip: NSClipView) {
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
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
        return State(text: viewport, fields: values, focus: focus, formY: form.map { max(0, $0.contentView.bounds.minY) },
                     catalogY: deferredCatalogY ?? (tracksCatalogScroll ? catalog.enclosingScrollView.map { max(0, $0.contentView.bounds.minY) } : nil),
                     visibleSelectionHeight: visibleSelectionHeight(viewport))
    }
    private func visibleSelectionHeight(_ viewport: AgentTextViewport) -> Double? {
        guard viewport.focusedSelectionIsVisible(in: text), let scroll = text.enclosingScrollView else { return nil }
        return Double(scroll.contentSize.height)
    }
    func restore(_ value: State) throws {
        try validate(value, text: text.string, fields: fields.mapValues(\.stringValue))
        pending = value; deferredText = value.text; deferredCatalogY = value.catalogY; cached = value.fields; focus = value.focus; schedule()
    }
    func validate(_ value: State, text: String, fields values: [String: String]) throws {
        guard value.version == 1, value.text.valid, value.text.hash == AgentFiles.hash(Data(text.utf8)), value.text.count == (text as NSString).length,
              Set(value.fields.keys) == Set(fields.keys), Set(values.keys) == Set(fields.keys), ["body", "catalog"].contains(value.focus) || fields[value.focus] != nil,
              AgentSettingsRecovery.validScroll(value.formY), AgentSettingsRecovery.validScroll(value.catalogY),
              AgentSettingsRecovery.validScroll(value.visibleSelectionHeight) else { throw PetError("设置草稿选区与正文不符，原记录已保留") }
        for (key, saved) in value.fields {
            let current = values[key]!
            guard saved.hash == AgentFiles.hash(Data(current.utf8)), saved.count == (current as NSString).length, saved.selection?.valid(in: saved.count) != false else { throw PetError("设置字段选区与原输入不符，原记录已保留") }
        }
    }
    func appear(default target: NSView) {
        if tracksCatalogScroll, let clip = catalog.enclosingScrollView?.contentView, clip !== observedCatalogClip {
            if let observedCatalogClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedCatalogClip) }
            observedCatalogClip = clip; observeScroll(clip)
        }
        if let y = deferredCatalogY, catalog.window != nil, let scroll = catalog.enclosingScrollView {
            applyScroll(y, to: scroll); deferredCatalogY = nil
        }
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
            if target === text {
                guard value.text.apply(to: text, focus: false) else { return }
                if let savedHeight = value.visibleSelectionHeight, let scroll = text.enclosingScrollView,
                   Double(scroll.contentSize.height) + 0.5 < savedHeight { text.scrollRangeToVisible(text.selectedRange()) }
            }
            else if let field = fields[value.focus], let selection = value.fields[value.focus]?.selection { (field.currentEditor() as? NSTextView)?.setSelectedRange(selection.range) }
            if let y = value.formY, let form, form.window === window { applyScroll(y, to: form) }
            if target === text, value.visibleSelectionHeight != nil, let form, form.window === window { revealSelection(in: form) }
            if target is NSTextField, let document = form?.documentView, target.isDescendant(of: document) {
                document.scrollToVisible(target.convert(target.bounds, to: document))
            }
            pending = nil
        }
    }
    private func applyScroll(_ y: Double, to view: NSScrollView) {
        let clip = view.contentView
        let bounds = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size))
        clip.scroll(to: bounds.origin); view.reflectScrolledClipView(clip)
    }
    private func revealSelection(in form: NSScrollView) {
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for: container)
        let count = (text.string as NSString).length
        let line: NSRect
        if text.selectedRange().location == count, layout.extraLineFragmentTextContainer === container {
            line = layout.extraLineFragmentUsedRect
        } else {
            guard count > 0, layout.numberOfGlyphs > 0 else { return }
            let glyph = min(layout.numberOfGlyphs - 1, layout.glyphIndexForCharacter(at: min(text.selectedRange().location, count - 1)))
            line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        guard line.height > 0 else { return }
        let clip = form.contentView, origin = text.textContainerOrigin
        let row = clip.convert(line.offsetBy(dx: origin.x, dy: origin.y), from: text), visible = clip.bounds
        let y = min(row.minY, max(visible.minY, row.maxY - visible.height))
        if abs(y - visible.minY) > 0.5 { applyScroll(max(0, y), to: form) }
    }
    static func validateObject(_ raw: Any) throws {
        let value = try AgentSettingsRecovery.object(raw, keys: ["version", "text", "fields", "focus", "formY", "catalogY", "visibleSelectionHeight"])
        if let text = value["text"] { try AgentTextViewport.validateObject(text) }
        for raw in (value["fields"] as? [String: Any] ?? [:]).values {
            let field = try AgentSettingsRecovery.object(raw, keys: ["hash", "count", "selection"])
            if let selection = field["selection"], !(selection is NSNull) { _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"]) }
        }
    }
}
