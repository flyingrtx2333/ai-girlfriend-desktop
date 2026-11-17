import AppKit
import ImageIO

private final class AgentMCPContentDocument: NSView { override var isFlipped: Bool { true } }
@MainActor private final class AgentMCPParameterTextView: NSTextView {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { onFocus?() }; return accepted }
}

@MainActor private extension AgentMCPContentWindow {
    func observeViewBounds(_ clip: NSClipView) {
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewBoundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
    }
    @objc func viewBoundsChanged(_ notification: Notification) { if !applyingViews { onWorkspaceChange?() } }
    @objc func fieldSelectionChanged(_ notification: Notification) {
        guard !applyingViews, let editor = notification.object as? NSTextView,
              editor === search.currentEditor() || editor === uri.currentEditor() else { return }
        rememberInputFocus()
        if editor === uri.currentEditor(), let key = selectedFormKey, !pendingFormViews.contains(key), let value = try? currentFormView() { formViews[key] = value }
        onWorkspaceChange?()
    }
    func fieldSelection(_ field: NSTextField) -> AgentTextViewport.Selection? {
        guard let editor = field.currentEditor() as? NSTextView else { return nil }
        let range = editor.selectedRange(), value = AgentTextViewport.Selection(location: range.location, length: range.length)
        return value.valid(in: (field.stringValue as NSString).length) ? value : nil
    }
    func rememberInputFocus() {
        guard !applyingViews, !focusPending, let focus = presentingWindow?.firstResponder else { return }
        if let name = fields.first(where: { $0.value === focus })?.key { contentFocus = "field:" + name }
        else if search.currentEditor() === focus { contentFocus = "search"; querySelection = fieldSelection(search) }
        else if uri.currentEditor() === focus { contentFocus = "uri" }
        else if focus === viewer { contentFocus = "preview" }
        else if focus === table { contentFocus = "catalog" }
        if querySelection?.valid(in: (search.stringValue as NSString).length) == false { querySelection = nil }
    }
    func currentFormView() throws -> FormView {
        let active = contentFocus.hasPrefix("field:") || contentFocus == "uri" ? contentFocus : selectedFormKey.flatMap { formViews[$0]?.active } ?? "catalog"
        var views: [String: AgentTextViewport] = [:]
        for (name, text) in fields { var view = try AgentTextViewport(text); view.focused = active == "field:" + name; views[name] = view }
        let previous = selectedFormKey.flatMap { formViews[$0] }
        let selection = fieldSelection(uri) ?? (previous.map { Data($0.uri.utf8) == Data(uri.stringValue.utf8) } == true ? previous?.uriSelection : nil)
        return FormView(fields: views, uri: uri.stringValue, uriSelection: selection, active: active,
            argumentY: max(0, argumentScroll.contentView.bounds.minY), detailY: max(0, detailViewport.contentView.bounds.minY))
    }
    func captureViewState() throws -> ViewState {
        rememberInputFocus()
        if let key = selectedFormKey, !pendingFormViews.contains(key), !inserted { formViews[key] = try currentFormView() }
        let keys = Set(formDrafts.keys).union([selectedFormKey].compactMap { $0 })
        let views = formViews.filter { keys.contains($0.key) }
        let focus = contentFocus.hasPrefix("field:") && selectedFormKey.flatMap({ views[$0]?.fields[String(contentFocus.dropFirst(6))] }) == nil ? "catalog" : contentFocus
        return ViewState(focus: focus, querySelection: querySelection, forms: views, listY: pendingListY ?? max(0, catalogList.contentView.bounds.minY))
    }
    func inputFocusTarget() -> NSView? {
        if contentFocus.hasPrefix("field:"), let field = fields[String(contentFocus.dropFirst(6))], field.isEditable, !field.isHiddenOrHasHiddenAncestor { return field }
        if contentFocus == "uri", uri.isEnabled, !uri.isHiddenOrHasHiddenAncestor { return uri }
        if contentFocus == "search", search.isEnabled, !search.isHiddenOrHasHiddenAncestor { return search }
        if contentFocus == "preview", !viewer.isHiddenOrHasHiddenAncestor { return viewer }
        return contentFocus == "catalog" && table.isEnabled ? table : nil
    }
    func scheduleViews() {
        guard !closed, !hasPendingOperation, !applyingViews, !viewsScheduled, isPageVisible,
              focusPending || selectedFormKey.map(pendingFormViews.contains) == true || pendingListY != nil else { return }
        viewsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { viewsScheduled = false }
            guard !closed, !hasPendingOperation, isPageVisible, presentingWindow?.hasBlockingDialog != true else { return }
            applyingViews = true; defer { applyingViews = false }
            pageContentView?.layoutSubtreeIfNeeded()
            if let key = selectedFormKey, pendingFormViews.contains(key), let value = formViews[key] {
                var applied = true
                for (name, view) in value.fields {
                    guard let text = fields[name] else { continue }
                    if !view.apply(to: text, focus: false) { applied = false }
                }
                argumentScroll.contentView.scroll(to: NSPoint(x: 0, y: value.argumentY)); argumentScroll.reflectScrolledClipView(argumentScroll.contentView)
                detailViewport.contentView.scroll(to: NSPoint(x: 0, y: value.detailY)); detailViewport.reflectScrolledClipView(detailViewport.contentView)
                if applied { pendingFormViews.remove(key) }
            }
            if let y = pendingListY, !rows.isEmpty { catalogList.contentView.scroll(to: NSPoint(x: 0, y: y)); catalogList.reflectScrolledClipView(catalogList.contentView); pendingListY = nil }
            if focusPending, let target = inputFocusTarget(), target.canBecomeKeyView, presentingWindow?.makeFirstResponder(target) == true {
                if target === search, let selection = querySelection { (search.currentEditor() as? NSTextView)?.setSelectedRange(selection.range) }
                if target === uri, let key = selectedFormKey, let value = formViews[key], Data(value.uri.utf8) == Data(uri.stringValue.utf8), let selection = value.uriSelection { (uri.currentEditor() as? NSTextView)?.setSelectedRange(selection.range) }
                if let key = selectedFormKey, let name = fields.first(where: { $0.value === target })?.key, let view = formViews[key]?.fields[name], let text = target as? NSTextView { view.apply(to: text, focus: false) }
                focusPending = false
            }
        }
    }
}

extension AgentMCPContentWindow {
    struct FormView: Codable, Equatable {
        var fields: [String: AgentTextViewport], uri: String, uriSelection: AgentTextViewport.Selection?, active: String
        var argumentY: Double, detailY: Double
    }
    struct ViewState: Codable, Equatable {
        var version = 1
        var focus: String, querySelection: AgentTextViewport.Selection?, forms: [String: FormView], listY: Double
        func valid(for state: RecoveryState) -> Bool {
            var currentKey: String?
            if let data = state.selected, let id = state.serverID, let revision = state.serverRevision,
               let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let identity = item[state.kind == "resources" ? "uri" : state.kind == "templates" ? "uriTemplate" : "name"] as? String {
                currentKey = [id, revision, state.kind, identity].joined(separator: "\n")
            }
            func allowedFocus(_ value: String, fields: [String: AgentTextViewport], uri: Bool) -> Bool {
                ["catalog", "search", "preview"].contains(value) || value == "uri" && uri || value.hasPrefix("field:") && fields[String(value.dropFirst(6))] != nil
            }
            guard version == 1, forms.count <= 1024, listY.isFinite, (0...1_000_000_000).contains(listY),
                  querySelection?.valid(in: (state.query as NSString).length) != false,
                  allowedFocus(focus, fields: currentKey.flatMap { forms[$0]?.fields } ?? [:], uri: currentKey != nil && state.kind != "prompts") else { return false }
            let allowed = Set(state.drafts.keys).union([currentKey].compactMap { $0 })
            for (key, value) in forms {
                let parts = key.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
                guard allowed.contains(key), key.utf8.count <= 16_384, !key.contains("\0"), parts.count == 4, ["resources", "templates", "prompts"].contains(String(parts[2])), value.fields.count <= 256,
                      value.uri.utf8.count <= 20_000_000, value.uriSelection?.valid(in: (value.uri as NSString).length) != false,
                      [value.argumentY, value.detailY].allSatisfy({ $0.isFinite && (0...1_000_000_000).contains($0) }),
                      allowedFocus(value.active, fields: value.fields, uri: parts[2] != "prompts") else { return false }
                let expectedURI = parts[2] == "prompts" ? "" : state.drafts[key]?.uri ?? String(parts[3])
                guard Data(expectedURI.utf8) == Data(value.uri.utf8) else { return false }
                for (name, view) in value.fields {
                    let text = state.drafts[key]?.fields[name] ?? ""
                    guard name.utf8.count <= 4096, !name.contains("\0"), view.valid, view.hash == AgentFiles.hash(Data(text.utf8)), view.count == (text as NSString).length else { return false }
                }
            }
            return true
        }
        static func validateObject(_ raw: Any) throws {
            func selection(_ raw: Any?) throws {
                if let raw, !(raw is NSNull) { guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["location", "length"]) else { throw PetError("MCP 输入选区格式不受支持") } }
            }
            guard let raw = raw as? [String: Any], Set(raw.keys).isSubset(of: ["version", "focus", "querySelection", "forms", "listY"]), let forms = raw["forms"] as? [String: Any] else { throw PetError("MCP 输入位置格式不受支持，原草稿已保留") }
            try selection(raw["querySelection"])
            for raw in forms.values {
                guard let form = raw as? [String: Any], Set(form.keys).isSubset(of: ["fields", "uri", "uriSelection", "active", "argumentY", "detailY"]), let fields = form["fields"] as? [String: Any] else { throw PetError("MCP 表单位置格式不受支持，原草稿已保留") }
                try selection(form["uriSelection"]); for view in fields.values { try AgentTextViewport.validateObject(view) }
            }
        }
    }
}
@MainActor private final class AgentMCPContentPage: AgentThemeView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { AgentSettingsStyle.prepare(self) }
    }
}

@MainActor final class AgentMCPContentWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String, sessionOwner: String, workspace: String?
    private let workspaceScope: AgentWorkspaceScope?
    private let insert: (String, [String]) throws -> Void
    private let servers = NSPopUpButton(), kinds = NSSegmentedControl(labels: ["资源", "URI 模板", "提示词"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), table = NSTableView(), viewer = NSTextView(), uri = NSTextField()
    private let title = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: ""), destination = NSTextField(labelWithString: "")
    private let connect = NSButton(title: "连接", target: nil, action: nil), disconnect = NSButton(title: "断开", target: nil, action: nil)
    private let refresh = NSButton(title: "刷新", target: nil, action: nil), more = NSButton(title: "更多", target: nil, action: nil)
    private let read = NSButton(title: "读取", target: nil, action: nil), add = NSButton(title: "加入附件", target: nil, action: nil)
    private let track = NSButton(checkboxWithTitle: "跟踪更新", target: nil, action: nil)
    private let arguments = NSStackView(), argumentScroll = NSScrollView(), image = NSImageView()
    private var argumentHeight: NSLayoutConstraint!, imageHeight: NSLayoutConstraint!
    private var rows: [[String: Any]] = [], fields: [String: NSTextView] = [:], nextOffset: Int?, catalog = ""
    private var selected: [String: Any]?, preview: AgentMCPContentPreview?, inserted = false
    private var job: Task<Void, Never>?, observer: UUID?, closed = false
    private var loadingList = false, pendingSearch = false
    private let main = NSStackView(), listColumn = NSStackView(), detailViewport = NSScrollView()
    private let catalogList = NSScrollView()
    private var wideLayout: [NSLayoutConstraint] = [], narrowLayout: [NSLayoutConstraint] = [], narrow: Bool?
    struct FormDraft: Codable { let fields: [String: String]; let uri: String? }
    private var formDrafts: [String: FormDraft] = [:], selectedFormKey: String?
    private var restoredSelection: [String: Any]?
    private var formViews: [String: FormView] = [:], pendingFormViews = Set<String>()
    private var contentFocus = "catalog", querySelection: AgentTextViewport.Selection?, pendingListY: Double?
    private var applyingViews = false, viewsScheduled = false, focusPending = false
    var onWorkspaceChange: (() -> Void)?
    var hasPendingOperation: Bool { job != nil }
    var workspaceHasUnsavedChanges: Bool {
        !closed && (!formDrafts.isEmpty || (!inserted && fields.values.contains { !$0.string.isEmpty }))
    }
    var canPreserveForQuit: Bool { !closed && !hasPendingOperation && store.task(taskID).map { $0.sideTask?.retained != false } == true }
    private var serverID: String? { servers.selectedItem?.representedObject as? String }
    private var kind: String { ["resources", "templates", "prompts"][max(0, kinds.selectedSegment)] }
    init(store: AgentStore, taskID: String, serverID: String? = nil, onInsert: @escaping (String, [String]) throws -> Void) {
        self.store = store; self.taskID = taskID; self.insert = onInsert; workspace = store.task(taskID)?.workspace
        workspaceScope = store.task(taskID)?.workspaceScope
        sessionOwner = taskID + "/context-" + UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 690), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MCP 资料 · " + (store.task(taskID)?.title ?? "任务"); window.minSize = NSSize(width: 760, height: 540); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = AgentMCPContentPage(fill: AgentWorkbenchTheme.surface); window.contentView = content
        servers.target = self; servers.action = #selector(changeServer); servers.setAccessibilityLabel("MCP 资料连接器")
        servers.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        servers.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        servers.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal); servers.cell?.lineBreakMode = .byTruncatingMiddle
        kinds.selectedSegment = 0; kinds.target = self; kinds.action = #selector(changeKind)
        search.placeholderString = "搜索名称或 URI"; search.delegate = self; search.setAccessibilityLabel("搜索 MCP 资料")
        for (button, action) in [(connect, #selector(start)), (disconnect, #selector(stop)), (refresh, #selector(refreshList)), (more, #selector(loadMore)), (read, #selector(readContent)), (add, #selector(addContent)), (track, #selector(toggleTracking))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        for label in [state, destination] { label.font = .systemFont(ofSize: 12); label.textColor = AgentWorkbenchTheme.secondaryText; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let header = NSStackView(views: [servers, destination, NSView(), disconnect, connect]); header.spacing = 10
        let filters = NSStackView(views: [kinds, search, refresh]); filters.spacing = 10
        table.addTableColumn(NSTableColumn(identifier: .init("mcp-content"))); table.headerView = nil; table.rowHeight = 46; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("MCP 资源与提示词目录")
        let list = catalogList; list.documentView = table; list.hasVerticalScroller = true
        for view in [list, more] { listColumn.addArrangedSubview(view) }; listColumn.orientation = .vertical; listColumn.alignment = .leading; listColumn.spacing = 8
        list.widthAnchor.constraint(equalTo: listColumn.widthAnchor).isActive = true
        title.font = .systemFont(ofSize: 16, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        uri.font = .systemFont(ofSize: 12); uri.isEditable = false; uri.isSelectable = true; uri.isBordered = true; uri.delegate = self; uri.setAccessibilityLabel("MCP 资源 URI")
        uri.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        uri.cell?.usesSingleLineMode = true; uri.cell?.lineBreakMode = .byTruncatingMiddle
        let argumentDocument = AgentMCPContentDocument(); arguments.orientation = .vertical; arguments.alignment = .leading; arguments.spacing = 10; arguments.translatesAutoresizingMaskIntoConstraints = false; argumentDocument.addSubview(arguments)
        argumentScroll.documentView = argumentDocument; argumentScroll.hasVerticalScroller = true; argumentScroll.drawsBackground = false; argumentDocument.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([argumentDocument.widthAnchor.constraint(equalTo: argumentScroll.contentView.widthAnchor), arguments.leadingAnchor.constraint(equalTo: argumentDocument.leadingAnchor), arguments.trailingAnchor.constraint(equalTo: argumentDocument.trailingAnchor), arguments.topAnchor.constraint(equalTo: argumentDocument.topAnchor), arguments.bottomAnchor.constraint(equalTo: argumentDocument.bottomAnchor)])
        argumentHeight = argumentScroll.heightAnchor.constraint(equalToConstant: 0); argumentHeight.isActive = true
        viewer.isEditable = false; viewer.isRichText = false; viewer.font = .systemFont(ofSize: 13); viewer.textContainerInset = NSSize(width: 12, height: 12); viewer.isVerticallyResizable = true; viewer.autoresizingMask = [.width]; viewer.textContainer?.widthTracksTextView = true; viewer.setAccessibilityLabel("MCP 资料预览")
        let previewScroll = NSScrollView(); previewScroll.documentView = viewer; previewScroll.hasVerticalScroller = true; previewScroll.borderType = .bezelBorder
        image.imageScaling = .scaleProportionallyUpOrDown; imageHeight = image.heightAnchor.constraint(equalToConstant: 0); imageHeight.priority = .defaultLow; imageHeight.isActive = true; image.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true; image.setContentCompressionResistancePriority(.init(200), for: .vertical); image.setAccessibilityLabel("MCP 实际图片预览"); image.isHidden = true
        let detail = NSStackView(views: [title, uri, argumentScroll, image, previewScroll]); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 10
        for view in detail.arrangedSubviews { view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        let detailDocument = AgentMCPContentDocument(); detailDocument.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false; detailDocument.addSubview(detail)
        detailViewport.documentView = detailDocument; detailViewport.hasVerticalScroller = true; detailViewport.drawsBackground = false; detailViewport.setAccessibilityLabel("MCP 资料内容")
        NSLayoutConstraint.activate([detailDocument.widthAnchor.constraint(equalTo: detailViewport.contentView.widthAnchor), detailDocument.heightAnchor.constraint(greaterThanOrEqualTo: detailViewport.contentView.heightAnchor), detail.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor), detail.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor), detail.topAnchor.constraint(equalTo: detailDocument.topAnchor), detail.bottomAnchor.constraint(equalTo: detailDocument.bottomAnchor), previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)])
        for view in [listColumn, detailViewport] { main.addArrangedSubview(view) }; main.spacing = 14; main.alignment = .top; main.distribution = .fill
        detailViewport.setContentHuggingPriority(.init(1), for: .horizontal); detailViewport.setContentCompressionResistancePriority(.init(1), for: .vertical)
        wideLayout = [listColumn.widthAnchor.constraint(equalToConstant: 220), listColumn.heightAnchor.constraint(equalTo: main.heightAnchor), detailViewport.heightAnchor.constraint(equalTo: main.heightAnchor)]
        narrowLayout = [listColumn.widthAnchor.constraint(equalTo: main.widthAnchor), listColumn.heightAnchor.constraint(equalToConstant: 120), detailViewport.widthAnchor.constraint(equalTo: main.widthAnchor)]
        let footer = NSStackView(views: [state, NSView(), track, read, add]); footer.spacing = 10
        for view in [header, filters, main, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), filters.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), filters.leadingAnchor.constraint(equalTo: header.leadingAnchor), filters.trailingAnchor.constraint(equalTo: header.trailingAnchor), main.leadingAnchor.constraint(equalTo: header.leadingAnchor), main.trailingAnchor.constraint(equalTo: header.trailingAnchor), main.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 14), main.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14), footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        content.onLayout = { [weak self] in self?.pageDidLayout() }; AgentSettingsStyle.prepare(content)
        for clip in [catalogList.contentView, argumentScroll.contentView, detailViewport.contentView] { observeViewBounds(clip) }
        NotificationCenter.default.addObserver(self, selector: #selector(fieldSelectionChanged), name: NSTextView.didChangeSelectionNotification, object: nil)
        populateServers(); if let serverID, let item = servers.itemArray.first(where: { $0.representedObject as? String == serverID }) { servers.select(item) }
        observer = store.mcp.observeContent { [weak self] in self?.refreshState() }; clearSelection(); state.stringValue = "未连接"; refreshState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    struct RecoveryState: Codable {
        var version = 1
        var taskID: String
        var serverID: String?
        var serverRevision: String?
        var kind: String
        var query: String
        var selected: Data?
        var drafts: [String: FormDraft]
        var dirty: Bool
        var view: ViewState? = nil
    }
    static func recoveryState(_ page: AgentWorkspaceRecovery.Page) throws -> RecoveryState {
        guard page.kind == "mcp-content", page.asset == nil,
              let object = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "taskID", "serverID", "serverRevision", "kind", "query", "selected", "drafts", "dirty", "view"]),
              let drafts = object["drafts"] as? [String: [String: Any]],
              drafts.values.allSatisfy({ Set($0.keys).isSubset(of: ["fields", "uri"]) }) else { throw PetError("MCP 参数恢复格式不受支持，原草稿已保留") }
        if let view = object["view"], !(view is NSNull) { try ViewState.validateObject(view) }
        let value = try JSONDecoder().decode(RecoveryState.self, from: page.state)
        guard value.version == 1, value.taskID == page.taskID, ["resources", "templates", "prompts"].contains(value.kind),
              value.dirty == page.dirty, value.dirty == !value.drafts.isEmpty,
              (value.serverID == nil) == (value.serverRevision == nil), value.serverID != nil || value.selected == nil else { throw PetError("MCP 参数恢复版本或归属无效，原草稿已保留") }
        if let selected = value.selected {
            guard let item = try JSONSerialization.jsonObject(with: selected) as? [String: Any],
                  selectionIdentity(item, kind: value.kind) != nil else { throw PetError("MCP 资料恢复对象无效，原草稿已保留") }
        }
        guard value.view?.valid(for: value) != false else { throw PetError("MCP 输入位置与原参数不符，原草稿已保留") }
        return value
    }
    private static func selectionIdentity(_ item: [String: Any], kind: String) -> String? {
        let value = item[kind == "resources" ? "uri" : kind == "templates" ? "uriTemplate" : "name"] as? String
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }
    private func formKey(_ item: [String: Any], server: AgentMCPServer) -> String? {
        Self.selectionIdentity(item, kind: kind).map { server.id + "\n" + server.revision + "\n" + kind + "\n" + $0 }
    }
    func captureWorkspaceRecovery() throws -> AgentWorkspaceRecovery.Page {
        guard !closed, !hasPendingOperation else { throw PetError("请先完成或取消 MCP 资料操作") }
        _ = try currentTask(); retainForm()
        let server = try serverID.map(currentServer)
        if let selected, let server, selectedFormKey != formKey(selected, server: server) { throw PetError("连接器版本已变化，原参数已保留，请重新检查") }
        let selectedData = try selected.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let value = RecoveryState(taskID: taskID, serverID: serverID, serverRevision: server?.revision, kind: kind,
            query: search.stringValue, selected: selectedData, drafts: formDrafts, dirty: !formDrafts.isEmpty, view: try captureViewState())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let page = AgentWorkspaceRecovery.Page(taskID: taskID, kind: "mcp-content", state: try encoder.encode(value), dirty: value.dirty, asset: nil)
        _ = try Self.recoveryState(page); return page
    }
    func restoreWorkspaceRecovery(_ page: AgentWorkspaceRecovery.Page) throws {
        let value = try Self.recoveryState(page)
        guard value.taskID == taskID, !hasPendingOperation else { throw PetError("MCP 参数所属任务已变化") }
        _ = try currentTask()
        if let id = value.serverID {
            guard let item = servers.itemArray.first(where: { $0.representedObject as? String == id }),
                  try currentServer(id).revision == value.serverRevision else { throw PetError("原连接器已改变或不可用，原参数已保留") }
            servers.select(item)
        } else { servers.select(nil) }
        applyingViews = true; defer { applyingViews = false; scheduleViews() }
        kinds.selectedSegment = ["resources", "templates", "prompts"].firstIndex(of: value.kind)!
        search.stringValue = value.query; clearSelection(); formDrafts = value.drafts
        formViews = value.view?.forms ?? [:]; pendingFormViews = Set(formViews.keys)
        querySelection = value.view?.querySelection; pendingListY = value.view?.listY
        if let data = value.selected, let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            restoredSelection = item; showSelection(item)
        }
        contentFocus = value.view?.focus ?? "catalog"; focusPending = value.view != nil
        // Restoring a form never opens a connector or reuses a live preview.
        refreshState(); if restoredSelection != nil { state.stringValue = "参数已恢复，连接后核对原资料。" }
    }
    private func populateServers() {
        let previous = serverID, allowed = store.task(taskID)?.agent?.mcpServers
        servers.removeAllItems()
        guard let task = try? currentTask(), let available = try? store.mcp.availableServers(task: task) else { return }
        for server in available where server.enabled && (allowed?.contains(server.id) ?? true) {
            servers.addItem(withTitle: workspaceScope == nil ? server.name : AgentMCPSelection.title(server)); servers.lastItem?.representedObject = server.id
            servers.lastItem?.toolTip = AgentMCPSelection.sourceWorkspace(server) ?? workspace
        }
        if let previous, let item = servers.itemArray.first(where: { $0.representedObject as? String == previous }) { servers.select(item) }
    }
    func selectRequestedServer(_ id: String) {
        guard id != serverID else { return }
        guard !hasPendingOperation else { state.stringValue = "请先完成当前操作，再切换连接器。"; return }
        guard let item = servers.itemArray.first(where: { $0.representedObject as? String == id }) else { state.stringValue = "此任务没有该连接器的访问权限。"; return }
        servers.select(item); changeServer()
    }
    private func currentTask() throws -> AgentTaskRecord {
        guard let task = store.task(taskID), !task.archived, task.kind != "wiki", task.kind != "hook", task.workspace == workspace, task.workspaceScope == workspaceScope else { throw PetError("任务或项目已改变，请重新打开 MCP 资料") }
        return task
    }
    private func currentServer(_ id: String) throws -> AgentMCPServer { try store.mcp.server(id, task: currentTask()) }
    private func taskScope(_ serverID: String, operation: String = "connect_mcp") throws -> AgentTaskRecord {
        let task = try currentTask()
        guard [.agent, .goal].contains(task.mode) else { throw PetError("请先切换到 Agent 或目标模式") }
        _ = try store.mcp.server(serverID, task: task)
        let call = AgentToolCall(id: "mcp-context", name: operation, arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["server_id": serverID]), as: UTF8.self))
        try store.agents.check(call, task: task, store: store); return task
    }
    private func clearSelection() {
        retainForm(); selectedFormKey = nil
        selected = nil; preview = nil; inserted = false; viewer.string = ""; title.stringValue = ""; uri.stringValue = ""; uri.isHidden = true; image.image = nil; image.isHidden = true; imageHeight.constant = 0
        for field in fields.values { if let clip = field.enclosingScrollView?.contentView { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip) } }
        fields = [:]; for view in arguments.arrangedSubviews { arguments.removeArrangedSubview(view); view.removeFromSuperview() }; argumentHeight.constant = 0; argumentScroll.isHidden = true
        if contentFocus.hasPrefix("field:") || contentFocus == "uri" { contentFocus = "catalog" }
    }
    private func retainForm() {
        guard let key = selectedFormKey else { return }
        rememberInputFocus()
        if !applyingViews, !pendingFormViews.contains(key), let view = try? currentFormView() { formViews[key] = view }
        let values = fields.mapValues(\.string).filter { !$0.value.isEmpty }
        let editedURI = (selected?["uriTemplate"] as? String).flatMap { $0 == uri.stringValue ? nil : uri.stringValue }
        if !inserted && (!values.isEmpty || editedURI != nil) { formDrafts[key] = FormDraft(fields: values, uri: editedURI) }
        else { formDrafts[key] = nil; if inserted { formViews[key] = nil; pendingFormViews.remove(key) } }
    }
    private func resetList() { rows = []; nextOffset = nil; catalog = ""; table.reloadData(); clearSelection() }
    @objc private func changeServer() { restoredSelection = nil; resetList(); pendingListY = nil; contentFocus = "catalog"; refreshState(); if let id = serverID, store.mcp.connected(id, owner: sessionOwner) { loadList() } }
    @objc private func changeKind() { restoredSelection = nil; search.stringValue = ""; querySelection = nil; resetList(); pendingListY = nil; contentFocus = "catalog"; refreshState(); loadList() }
    @objc private func start() {
        guard job == nil, let id = serverID else { return }
        launch {
            let task = try self.taskScope(id), server = try self.currentServer(id)
            _ = try await self.store.mcp.connect(id, revision: server.revision, owner: self.sessionOwner, workspace: self.store.mcp.workspaceForServer(id, task: task))
            try await self.fetchList(refresh: false, append: false)
        }
    }
    @objc private func stop() { job?.cancel(); if let id = serverID { store.mcp.disconnect(owner: sessionOwner, serverID: id) }; resetList(); state.stringValue = "已断开"; refreshState() }
    @objc private func refreshList() { loadList(refresh: true) }
    @objc private func loadMore() { loadList(append: true) }
    private func loadList(refresh: Bool = false, append: Bool = false) {
        guard job == nil, let id = serverID, store.mcp.connected(id, owner: sessionOwner) else { refreshState(); return }
        loadingList = true
        launch { defer { self.loadingList = false }; try await self.fetchList(refresh: refresh, append: append) }
    }
    private func fetchList(refresh: Bool, append: Bool) async throws {
        guard let id = serverID, let connection = store.mcp.token(id, owner: sessionOwner) else { throw PetError("请先连接") }
        _ = try taskScope(id, operation: kind == "prompts" ? "connect_mcp" : "list_mcp_resources")
        let query = search.stringValue
        let result = try await store.mcp.contentCatalog(id, owner: sessionOwner, connection: connection, kind: kind, query: String(query.prefix(300)), offset: append ? nextOffset ?? 0 : 0, refresh: refresh)
        try Task.checkCancellation(); guard !closed, search.stringValue == query else { return }
        let values = result["items"] as? [[String: Any]] ?? []
        rows = append ? rows + values : values; nextOffset = result["next_offset"] as? Int; catalog = result["catalog"] as? String ?? ""
        let restore = restoredSelection, restoredFocus = contentFocus
        clearSelection(); table.reloadData()
        state.stringValue = result["supported"] as? Bool == false ? "连接器未提供此类内容" : rows.isEmpty ? "没有匹配内容" : ""
        if let restore {
            if let index = rows.firstIndex(where: { Self.selectionIdentity($0, kind: kind) == Self.selectionIdentity(restore, kind: kind) }) {
                restoredSelection = nil; table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); showSelection(rows[index])
            } else {
                table.deselectAll(nil); restoredSelection = restore; showSelection(restore)
                state.stringValue = "原资料暂不在当前目录，参数已保留。"
            }
            contentFocus = restoredFocus; focusPending = true
        } else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    private func launch(revealPreview: Bool = false, _ action: @escaping () async throws -> Void) {
        guard job == nil else { return }; state.stringValue = "读取中…"
        job = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            defer {
                self.job = nil; self.refreshState()
                if succeeded && revealPreview { self.revealReadResult() }
                if self.pendingSearch { self.pendingSearch = false; self.loadList() }
            }
            do { try await action(); succeeded = true }
            catch { if !self.closed { self.state.stringValue = Task.isCancelled ? "已取消" : error.localizedDescription; self.state.toolTip = self.state.stringValue } }
        }; refreshState()
    }
    private func revealReadResult() {
        guard isPageVisible, preview != nil, let document = detailViewport.documentView else { return }
        pageContentView?.layoutSubtreeIfNeeded()
        let target: NSView = image.isHidden ? (viewer.enclosingScrollView ?? viewer) : image
        let rect = target.convert(target.bounds, to: document), clip = detailViewport.contentView
        guard !clip.documentVisibleRect.contains(rect) else { return }
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, rect.minY), maxY)))
        detailViewport.reflectScrolledClipView(clip)
    }
    func controlTextDidChange(_ obj: Notification) {
        if !applyingViews { if let key = selectedFormKey { pendingFormViews.remove(key) }; rememberInputFocus() }
        if obj.object as? NSSearchField === search {
            restoredSelection = nil; pendingListY = nil; clearSelection()
            if job != nil { pendingSearch = true } else { loadList() }
        }
        else { preview = nil; inserted = false; viewer.string = ""; image.image = nil; image.isHidden = true; imageHeight.constant = 0; retainForm(); refreshState() }
    }
    func textDidChange(_ notification: Notification) { if let key = selectedFormKey { pendingFormViews.remove(key) }; rememberInputFocus(); preview = nil; inserted = false; viewer.string = ""; image.image = nil; image.isHidden = true; imageHeight.constant = 0; retainForm(); refreshState() }
    func textViewDidChangeSelection(_ notification: Notification) { guard !applyingViews else { return }; rememberInputFocus(); onWorkspaceChange?() }
    func controlTextDidBeginEditing(_ notification: Notification) { if !applyingViews { focusPending = false; rememberInputFocus(); onWorkspaceChange?() } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row], name = NSTextField(labelWithString: item["title"] as? String ?? item["name"] as? String ?? "")
        name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: item["uri"] as? String ?? item["uriTemplate"] as? String ?? item["name"] as? String ?? "")
        detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText; detail.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [name, detail]); cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 4; cell.toolTip = item["description"] as? String; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !applyingViews, presentingWindow?.firstResponder === table { contentFocus = "catalog" }
        guard rows.indices.contains(table.selectedRow) else { clearSelection(); refreshState(); return }
        restoredSelection = nil; showSelection(rows[table.selectedRow])
    }
    private func showSelection(_ item: [String: Any]) {
        clearSelection(); selected = item; title.stringValue = item["title"] as? String ?? item["name"] as? String ?? ""
        if let id = serverID, let server = try? currentServer(id) { selectedFormKey = formKey(item, server: server) }
        uri.stringValue = item["uri"] as? String ?? item["uriTemplate"] as? String ?? ""; uri.isHidden = kind == "prompts"; uri.isEditable = kind == "templates"; uri.toolTip = uri.stringValue
        viewer.string = item["description"] as? String ?? ""
        let parameters = item["arguments"] as? [[String: Any]] ?? []
        for field in parameters {
            guard let name = field["name"] as? String else { continue }
            let label = NSTextField(labelWithString: (field["title"] as? String ?? name) + (field["required"] as? Bool == true ? " *" : "")); label.font = .systemFont(ofSize: 12, weight: .medium); label.lineBreakMode = .byTruncatingTail; label.toolTip = field["description"] as? String; label.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let text = AgentMCPParameterTextView(); text.isRichText = false; text.font = .systemFont(ofSize: 12); text.textContainerInset = NSSize(width: 6, height: 6); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.delegate = self; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false; text.setAccessibilityLabel("提示词参数 " + name)
            text.onFocus = { [weak self] in guard let self, !applyingViews else { return }; contentFocus = "field:" + name; onWorkspaceChange?() }
            let input = AgentThemeView(fill: AgentWorkbenchTheme.subtle, stroke: AgentWorkbenchTheme.line)
            input.wantsLayer = true; input.layer?.cornerRadius = 6; input.layer?.borderWidth = 1; input.layer?.masksToBounds = true
            text.drawsBackground = false
            let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false; scroll.identifier = .init("form-input")
            observeViewBounds(scroll.contentView)
            input.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([input.heightAnchor.constraint(equalToConstant: 54), scroll.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: input.trailingAnchor, constant: -1), scroll.topAnchor.constraint(equalTo: input.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: input.bottomAnchor, constant: -1)])
            let row = NSStackView(views: [label, input]); row.spacing = 8; arguments.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: arguments.widthAnchor).isActive = true; fields[name] = text
        }
        if let key = selectedFormKey, let draft = formDrafts[key] {
            for (name, value) in draft.fields { fields[name]?.string = value }
            if let value = draft.uri { uri.stringValue = value }
        }
        if let key = selectedFormKey, let view = formViews[key] {
            pendingFormViews.insert(key)
            if contentFocus != "search" { contentFocus = view.active; focusPending = true }
        }
        argumentHeight.constant = min(164, CGFloat(parameters.count) * 64); argumentScroll.isHidden = parameters.isEmpty; refreshState()
    }
    @objc private func readContent() {
        guard job == nil, restoredSelection == nil, let id = serverID, let selected, let connection = store.mcp.token(id, owner: sessionOwner) else { return }
        let requestedKind = kind, requestedURI = uri.stringValue, currentCatalog = catalog, values = fields.mapValues(\.string)
        launch(revealPreview: true) {
            _ = try self.taskScope(id, operation: requestedKind == "prompts" ? "connect_mcp" : "read_mcp_resource")
            let result: AgentMCPContentPreview
            if requestedKind == "prompts" { result = try await self.store.mcp.prompt(id, owner: self.sessionOwner, connection: connection, catalog: currentCatalog, name: selected["name"] as? String ?? "", arguments: values.filter { !$0.value.isEmpty }) }
            else {
                guard !requestedURI.contains("{"), !requestedURI.contains("}") else { throw PetError("请填写展开后的资源 URI") }
                result = try await self.store.mcp.readResource(id, owner: self.sessionOwner, connection: connection, catalog: currentCatalog, uri: requestedURI, template: requestedKind == "templates" ? selected["uriTemplate"] as? String : nil)
            }
            try Task.checkCancellation(); guard !self.closed else { return }; _ = try self.taskScope(id, operation: requestedKind == "prompts" ? "connect_mcp" : "read_mcp_resource")
            self.preview = result; self.catalog = result.catalog; self.inserted = false; self.viewer.string = result.displayText; self.viewer.scrollToBeginningOfDocument(nil); self.state.stringValue = ""
            if let part = result.parts.first(where: { $0.mimeType.hasPrefix("image/") }), let source = CGImageSourceCreateWithData(part.data as CFData, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { self.image.image = NSImage(cgImage: thumbnail, size: .zero); self.image.isHidden = false; self.imageHeight.constant = 150 }
        }
    }
    @objc private func addContent() {
        guard job == nil, let preview, !inserted, store.mcp.previewCurrent(preview) else { return }
        launch {
            _ = try self.taskScope(preview.server.id, operation: preview.kind == "prompts" ? "connect_mcp" : "read_mcp_resource")
            let files = try await AgentMCPContent.importParts(preview, store: self.store, taskID: self.taskID)
            do {
                try Task.checkCancellation(); guard !self.closed, self.store.mcp.previewCurrent(preview) else { throw PetError("内容或连接已变化，请重新预览") }
                _ = try self.taskScope(preview.server.id, operation: preview.kind == "prompts" ? "connect_mcp" : "read_mcp_resource")
                try self.insert(preview.kind == "prompts" ? preview.promptText : "", files.map(\.id))
                self.inserted = true; if let key = self.selectedFormKey { self.formDrafts[key] = nil }; self.state.stringValue = "已加入草稿"
            } catch { for file in files { try? AgentAttachments.removeDraft(store: self.store, taskID: self.taskID, id: file.id) }; throw error }
        }
    }
    @objc private func toggleTracking() {
        guard job == nil, let preview else { return }
        let enabled = track.state == .on
        launch { _ = try self.taskScope(preview.server.id, operation: "list_mcp_resources"); try await self.store.mcp.subscription(preview, enabled: enabled); self.state.stringValue = "" }
    }
    private func refreshState() {
        let id = serverID, connected = id.map { store.mcp.connected($0, owner: sessionOwner) } ?? false, busy = job != nil
        let scopeError: String? = { guard let id else { return "暂无可用连接器" }; do { _ = try taskScope(id); return nil } catch { return error.localizedDescription } }()
        connect.isEnabled = id != nil && !connected && !busy && scopeError == nil; disconnect.isEnabled = connected || busy; disconnect.title = busy ? "取消" : "断开"
        refresh.isEnabled = connected && !busy && scopeError == nil; more.isHidden = nextOffset == nil; more.isEnabled = !busy
        servers.isEnabled = !busy; kinds.isEnabled = !busy; table.isEnabled = !busy; search.isEnabled = connected && (!busy || loadingList); uri.isEnabled = !busy; for field in fields.values { field.isEditable = !busy }
        let catalogCurrent = id.flatMap { id in store.mcp.token(id, owner: sessionOwner).map { store.mcp.contentCatalogCurrent(id, owner: sessionOwner, connection: $0, catalog: catalog, kind: kind) } } ?? false
        read.title = kind == "prompts" ? "预览" : "读取"; read.isEnabled = connected && selected != nil && restoredSelection == nil && !busy && scopeError == nil && catalogCurrent
        add.title = kind == "prompts" ? "加入草稿" : "加入附件"; add.isEnabled = !busy && !inserted && scopeError == nil && preview.map(store.mcp.previewCurrent) == true
        track.isHidden = preview?.kind != "resources"; track.isEnabled = !busy && scopeError == nil && preview.map(store.mcp.supportsSubscription) == true; track.state = preview.map(store.mcp.subscribed) == true ? .on : .off
        servers.toolTip = servers.titleOfSelectedItem
        if let server = id.flatMap({ try? currentServer($0) }) { destination.stringValue = server.destination; destination.toolTip = server.destination }
        else { destination.stringValue = "" }
        if let scopeError { state.stringValue = scopeError }
        else if connected, !catalog.isEmpty, !catalogCurrent { state.stringValue = "目录已更新，请刷新" }
        else if let preview, !store.mcp.previewCurrent(preview) { state.stringValue = connected ? "内容已更新，请重新读取" : "连接已断开" }
        state.toolTip = state.stringValue
        onWorkspaceChange?()
        if !busy, isPageVisible, let host = presentingWindow, host.firstResponder === host { focusContent() }
        scheduleViews()
    }
    override func pageDidLayout() {
        guard let content = pageContentView, content.bounds.width > 0 else { return }
        let next = content.bounds.width < 740
        if narrow != next {
            narrow = next; NSLayoutConstraint.deactivate(wideLayout + narrowLayout)
            main.orientation = next ? .vertical : .horizontal; main.alignment = next ? .leading : .top
            NSLayoutConstraint.activate(next ? narrowLayout : wideLayout)
        }
        scheduleViews()
    }
    override func settingsDidAppear() {
        super.settingsDidAppear(); pageDidLayout()
        if let content = pageContentView { content.effectiveAppearance.performAsCurrentDrawingAppearance { AgentSettingsStyle.prepare(content) } }
        focusPending = true; scheduleViews()
        if let content = pageContentView, let focused = presentingWindow?.firstResponder as? NSView, focused.isDescendant(of: content) { return }
        focusContent()
    }
    private func focusContent() {
        guard isPageVisible else { return }
        let target: NSView = inputFocusTarget() ?? (table.isEnabled ? table : viewer)
        let previous = applyingViews; applyingViews = true
        presentingWindow?.makeFirstResponder(target); applyingViews = previous
    }
    override func canLeaveSettings() -> Bool {
        guard presentingWindow?.hasBlockingDialog != true else { return false }
        guard !hasPendingOperation else { state.stringValue = "请先完成操作，或点击取消。"; return false }
        guard workspaceHasUnsavedChanges else { return true }
        return AgentUnsavedChanges.discard("关闭 MCP 资料？", detail: "未加入草稿的参数将清除。任务草稿与已添加附件保留。", discardTitle: "关闭资料页", owner: presentingWindow)
    }
    override func settingsWillLeave() { finishContent() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeaveSettings() }
    func windowWillClose(_ notification: Notification) { finishContent() }
    private func finishContent() {
        guard !closed else { return }; closed = true; job?.cancel(); onWorkspaceChange = nil
        NotificationCenter.default.removeObserver(self)
        if let observer { store.mcp.removeContentObserver(observer); self.observer = nil }; store.mcp.disconnect(owner: sessionOwner)
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled || ["--mcp-content-check", "--workspace-capabilities-check", "--workspace-mcp-recovery-check", "--workspace-mcp-recovery-ui"].contains(where: CommandLine.arguments.contains), let content = pageContentView else { return [:] }
        func rect(_ view: NSView) -> [String: Double] { let r = view.convert(view.bounds, to: content); return ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        func inside(_ view: NSView) -> Bool { content.bounds.insetBy(dx: -1, dy: -1).contains(view.convert(view.bounds, to: content)) }
        let focused = presentingWindow?.firstResponder
        let focusInPage = (focused as? NSView)?.isDescendant(of: content) == true || (focused != nil && (search.currentEditor() === focused || uri.currentEditor() === focused))
        let previewRect = viewer.enclosingScrollView.map { $0.convert($0.bounds, to: detailViewport.documentView) } ?? .zero
        let previewVisibleHeight = Double(max(0, previewRect.intersection(detailViewport.contentView.documentVisibleRect).height))
        let checks = ["pageActuallyVisible": isPageVisible, "serverPickerReadable": inside(servers) && servers.bounds.width >= 139, "catalogFitsPage": inside(listColumn), "detailViewportFitsPage": inside(detailViewport), "searchFitsPage": inside(search), "readButtonFitsPage": inside(read), "addButtonFitsPage": inside(add), "detailHasUsableHeight": detailViewport.bounds.height >= 80, "catalogHasUsableHeight": table.enclosingScrollView!.bounds.height >= 70]
        return ["taskID": taskID, "sessionOwner": sessionOwner, "serverID": serverID ?? "", "connected": serverID.map { store.mcp.connected($0, owner: sessionOwner) } ?? false, "closed": closed, "busy": hasPendingOperation, "unsaved": workspaceHasUnsavedChanges, "kind": kind, "narrow": narrow == true, "fields": fields.mapValues(\.string), "parametersEditable": fields.values.allSatisfy(\.isEditable), "focusInPage": focusInPage, "previewFocused": focused === viewer, "previewVisibleHeight": previewVisibleHeight, "uri": uri.stringValue, "previewText": viewer.string, "promptText": preview?.promptText ?? "", "inserted": inserted, "restoredSelectionPending": restoredSelection != nil, "readEnabled": read.isEnabled, "selectedName": selected?["name"] as? String ?? "", "formDraftCount": formDrafts.count, "rows": rows, "content": rect(content), "catalog": rect(listColumn), "detail": rect(detailViewport), "checks": checks]
    }
    func checkAction(_ action: String, kind index: Int? = nil, query: String? = nil, row: Int? = nil, values: [String: String]? = nil, resourceURI: String? = nil) {
        guard ["--mcp-content-check", "--workspace-capabilities-check", "--workspace-mcp-recovery-check", "--workspace-mcp-recovery-ui"].contains(where: CommandLine.arguments.contains), !CommandLine.arguments.contains("--live-agent") else { return }
        if let index { kinds.selectedSegment = index; changeKind() }
        if let query { search.stringValue = query; loadList() }
        if let row, rows.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if let values { for (name, value) in values { fields[name]?.string = value }; textDidChange(Notification(name: NSText.didChangeNotification)) }
        if let resourceURI { uri.stringValue = resourceURI; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: uri)) }
        switch action { case "connect": start(); case "disconnect": stop(); case "read": readContent(); case "add": addContent(); case "focus-preview": presentingWindow?.makeFirstResponder(viewer); default: break }
    }
    func checkInputView(_ name: String, selection: NSRange? = nil, y: Double? = nil) -> [String: Any] {
        guard ["--workspace-mcp-recovery-check", "--workspace-mcp-recovery-ui"].contains(where: CommandLine.arguments.contains), !CommandLine.arguments.contains("--live-agent") else { return [:] }
        if let selection, let text = fields[name], AgentTextViewport.Selection(location: selection.location, length: selection.length).valid(in: (text.string as NSString).length) {
            pendingFormViews.remove(selectedFormKey ?? ""); focusPending = false
            presentingWindow?.makeFirstResponder(text); text.setSelectedRange(selection)
            if let y, let scroll = text.enclosingScrollView { text.layoutManager?.ensureLayout(for: text.textContainer!); scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
            rememberInputFocus(); onWorkspaceChange?()
        }
        guard let text = fields[name], let view = try? AgentTextViewport(text) else { return [:] }
        return ["location": text.selectedRange().location, "length": text.selectedRange().length, "focused": presentingWindow?.firstResponder === text, "y": view.y, "anchor": view.anchor, "plannedFocus": contentFocus, "focusPending": focusPending, "canBecomeKeyView": text.canBecomeKeyView, "visible": !text.isHiddenOrHasHiddenAncestor]
    }
    func checkFieldView(_ name: String, selection: NSRange? = nil) -> [String: Any] {
        guard ["search", "uri"].contains(name), ["--workspace-mcp-recovery-check", "--workspace-mcp-recovery-ui"].contains(where: CommandLine.arguments.contains), !CommandLine.arguments.contains("--live-agent") else { return [:] }
        let field: NSTextField = name == "search" ? search : uri
        if let selection, AgentTextViewport.Selection(location: selection.location, length: selection.length).valid(in: (field.stringValue as NSString).length) {
            focusPending = false; presentingWindow?.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.setSelectedRange(selection); rememberInputFocus(); onWorkspaceChange?()
        }
        let editor = field.currentEditor() as? NSTextView
        return ["value": field.stringValue, "location": editor?.selectedRange().location ?? -1, "length": editor?.selectedRange().length ?? -1, "focused": editor != nil && presentingWindow?.firstResponder === editor]
    }
}
