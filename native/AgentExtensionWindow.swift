import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentExtensionWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String
    private let kinds = NSSegmentedControl(labels: ["Skills", "命令"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), table = NSTableView(), editor = NSTextView()
    private let enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let add = NSButton(title: "新建", target: nil, action: nil), importButton = NSButton(title: "导入", target: nil, action: nil)
    private let save = NSButton(title: "保存", target: nil, action: nil), remove = NSButton(title: "移除", target: nil, action: nil)
    private let use = NSButton(title: "在任务中使用", target: nil, action: nil), reveal = NSButton(title: "打开来源", target: nil, action: nil)
    private let location = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: "")
    private var items: [AgentExtensionItem] = [], selected: AgentExtensionItem?, openedHash: String?, dirty = false, selectedKind = 0
    private var job: Task<Void, Never>?
    private var mcpWindow: AgentMCPWindow?
    private var hookWindow: AgentHookWindow?
    private var agentWindow: AgentProfileWindow?
    private var teamWindow: AgentTeamWindow?
    private var pluginWindow: AgentPluginWindow?
    private var ruleWindow: AgentRuleWindow?
    var onStartAgent: ((String) -> Void)?
    var onBrowseMCP: ((String?) -> Void)?
    var onInsert: ((AgentExtensionItem) throws -> Void)? { didSet { updateControls() } }
    var onInsertRule: ((AgentPluginRuleItem) throws -> Void)?
    var onInsertLocalRule: ((AgentLocalRuleItem) throws -> Void)?
    private var workspace: String? { store.task(taskID)?.workspace }
    private var kind: AgentExtensionKind { kinds.selectedSegment == 1 ? .command : .skill }
    init(store: AgentStore, taskID: String) {
        self.store = store; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "扩展"; window.minSize = NSSize(width: 720, height: 480); window.center(); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        kinds.selectedSegment = 0; kinds.target = self; kinds.action = #selector(changeKind)
        search.placeholderString = "搜索扩展"; search.delegate = self
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshList))
        let mcp = NSButton(title: "MCP 连接器", target: self, action: #selector(showMCP))
        let hooks = NSButton(title: "Hooks", target: self, action: #selector(showHooks))
        let agents = NSButton(title: "自定义 Agent", target: self, action: #selector(showAgents))
        let teams = NSButton(title: "团队", target: self, action: #selector(showTeams))
        let plugins = NSButton(title: "插件", target: self, action: #selector(showPlugins))
        let header = NSStackView(views: [kinds, search, refresh, plugins, mcp, hooks, agents, teams]); header.spacing = 8
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extension")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 48; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("扩展列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        editor.isRichText = false; editor.allowsUndo = true; editor.delegate = self; editor.isEditable = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.setAccessibilityLabel("扩展说明")
        let viewer = NSScrollView(); viewer.documentView = editor; viewer.hasVerticalScroller = true; viewer.borderType = .bezelBorder
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        for label in [location, state] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle }
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(add, #selector(createItem)), (importButton, #selector(importItem)), (save, #selector(saveItem)), (remove, #selector(removeItem)), (use, #selector(useItem)), (reveal, #selector(revealItem))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let detailHeader = NSStackView(views: [enabled, location, NSView(), use]); detailHeader.spacing = 10
        let rules = NSButton(title: "规则", target: self, action: #selector(showRules))
        let listActions = NSStackView(views: [add, importButton, rules, NSView()]); listActions.spacing = 8
        let footer = NSStackView(views: [state, NSView(), reveal, remove, save]); footer.spacing = 8
        for view in [header, list, viewer, detailHeader, listActions, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), header.heightAnchor.constraint(equalToConstant: 28),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), list.widthAnchor.constraint(equalToConstant: 210), list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), list.bottomAnchor.constraint(equalTo: listActions.topAnchor, constant: -10),
            listActions.leadingAnchor.constraint(equalTo: list.leadingAnchor), listActions.trailingAnchor.constraint(equalTo: list.trailingAnchor), listActions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), listActions.heightAnchor.constraint(equalToConstant: 28),
            detailHeader.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), detailHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), detailHeader.topAnchor.constraint(equalTo: list.topAnchor), detailHeader.heightAnchor.constraint(equalToConstant: 28),
            viewer.leadingAnchor.constraint(equalTo: detailHeader.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: detailHeader.trailingAnchor), viewer.topAnchor.constraint(equalTo: detailHeader.bottomAnchor, constant: 10), viewer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: viewer.leadingAnchor), footer.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func showRules() {
        guard canLeave() else { return }
        if let window = ruleWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let manager = AgentRuleWindow(store: store, taskID: taskID); manager.onInsert = onInsertLocalRule; ruleWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showPlugins() {
        guard canLeave() else { return }
        if let window = pluginWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let manager = AgentPluginWindow(store: store, workspace: workspace); manager.onInsert = onInsert; manager.onInsertRule = onInsertRule; manager.onChange = { [weak self] in self?.reload() }; manager.onConfigureMCP = { [weak self] id, scope in self?.openMCP(id, workspace: scope) }; manager.onConfigureAgent = { [weak self] id, scope in self?.openAgent(id, workspace: scope) }; manager.onConfigureHook = { [weak self] id, scope in self?.openHook(id, workspace: scope) }; pluginWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showMCP() {
        openMCP(nil, workspace: workspace)
    }
    private func openMCP(_ id: String?, workspace: String?) {
        if let manager = mcpWindow, let window = manager.window, window.isVisible {
            if manager.scopeWorkspace == workspace { if let id { manager.selectServer(id) }; window.makeKeyAndOrderFront(nil); return }
            window.performClose(nil); if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        }
        let manager = AgentMCPWindow(service: store.mcp, workspace: workspace); manager.onBrowseContent = onBrowseMCP; mcpWindow = manager; if let id { manager.selectServer(id) }; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showHooks() {
        openHook(nil, workspace: workspace)
    }
    private func openHook(_ id: String?, workspace: String?) {
        if let manager = hookWindow, let window = manager.window, window.isVisible {
            if manager.scopeWorkspace == workspace { if let id { manager.selectHook(id) }; window.makeKeyAndOrderFront(nil); return }
            window.performClose(nil); if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        }
        let manager = AgentHookWindow(service: store.hooks, workspace: workspace); hookWindow = manager; if let id { manager.selectHook(id) }; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showAgents() {
        openAgent(nil, workspace: workspace)
    }
    private func openAgent(_ id: String?, workspace: String?) {
        if let manager = agentWindow, let window = manager.window, window.isVisible {
            if manager.scopeWorkspace == workspace { if let id { manager.selectProfile(id) }; window.makeKeyAndOrderFront(nil); return }
            window.performClose(nil); if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        }
        let manager = AgentProfileWindow(store: store, workspace: workspace, workMode: store.task(taskID)?.organizationMode); manager.onUse = onStartAgent; agentWindow = manager; if let id { manager.selectProfile(id) }; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showTeams() {
        if let window = teamWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let manager = AgentTeamWindow(store: store, workspace: workspace, workMode: store.task(taskID)?.organizationMode); manager.onUse = onStartAgent; teamWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row], name = NSTextField(labelWithString: item.name + (item.enabled ? "" : " · 已停用"))
        name.font = .systemFont(ofSize: 12, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        let source = NSTextField(labelWithString: item.scope + (item.manualOnly ? " · 手动" : "")); source.font = .systemFont(ofSize: 11); source.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [name, source]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; stack.toolTip = item.description; return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard items.indices.contains(table.selectedRow) else { return }
        if !canLeave() { selectRow(selected?.id); return }; open(items[table.selectedRow])
    }
    private func selectRow(_ id: String?) {
        table.delegate = nil
        if let index = items.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }; table.delegate = self
    }
    private func reload(select id: String? = nil) {
        guard !dirty else { state.stringValue = "请先保存或放弃更改"; return }
        do {
            let all = try store.extensions.catalog(workspace: workspace), query = search.stringValue
            items = all.filter { $0.kind == kind && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)) }
            table.delegate = nil; table.reloadData(); table.delegate = self
            let next = items.first(where: { $0.id == (id ?? selected?.id) }) ?? items.first
            selectRow(next?.id); if let next { open(next) }
            else { selected = nil; openedHash = nil; editor.string = ""; editor.isEditable = false; location.stringValue = ""; updateControls() }
            if !store.extensions.warnings.isEmpty { state.stringValue = store.extensions.warnings.joined(separator: "\n"); state.toolTip = state.stringValue }
            else { state.stringValue = items.isEmpty ? "暂无扩展" : "\(items.count) 项"; state.toolTip = nil }
        } catch { state.stringValue = error.localizedDescription }
    }
    private func open(_ item: AgentExtensionItem) {
        do {
            let (text, _) = try store.extensions.document(item)
            selected = item; openedHash = AgentFiles.hash(Data(text.utf8)); editor.string = text; editor.isEditable = item.managed
            editor.undoManager?.removeAllActions(); dirty = false
            location.stringValue = item.scope + " · /" + item.invocation; location.toolTip = item.file.path
            enabled.state = item.enabled ? .on : .off; updateControls()
        } catch { state.stringValue = error.localizedDescription }
    }
    private func updateControls() {
        let idle = job == nil, managed = selected?.managed == true
        kinds.isEnabled = idle; search.isEnabled = idle; table.isEnabled = idle; add.isEnabled = idle; importButton.isEnabled = idle
        enabled.isEnabled = idle && selected != nil && selected?.pluginName == nil; use.isEnabled = idle && selected?.enabled == true && onInsert != nil
        remove.isEnabled = idle && managed; save.isEnabled = idle && managed && dirty; reveal.isEnabled = idle && selected != nil
        editor.isEditable = idle && managed
    }
    @objc private func changeKind() {
        guard canLeave() else { kinds.selectedSegment = selectedKind; return }; selectedKind = kinds.selectedSegment; selected = nil; reload()
    }
    @objc private func refreshList() { if canLeave() { reload() } }
    func controlTextDidChange(_ notification: Notification) { if !dirty { reload() } }
    func textDidChange(_ notification: Notification) { dirty = true; state.stringValue = "未保存"; updateControls() }
    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        do {
            try store.extensions.setEnabled(item, enabled: enabled.state == .on, workspace: workspace)
            if let current = try? store.extensions.item(item.id, workspace: workspace, enabled: false) {
                selected = current
                if let row = items.firstIndex(where: { $0.id == current.id }) { items[row] = current; table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
            }; updateControls()
        }
        catch { enabled.state = item.enabled ? .on : .off; state.stringValue = error.localizedDescription }
    }
    @objc private func saveItem() {
        guard let item = selected, let hash = openedHash else { return }
        do { let saved = try store.extensions.save(item, text: editor.string, expectedHash: hash, workspace: workspace); dirty = false; reload(select: saved.id); state.stringValue = "已保存" }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func revealItem() { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.file]) } }
    @objc private func useItem() {
        guard let item = selected, canLeave() else { return }
        do { try onInsert?(store.extensions.item(item.id, workspace: workspace)); close() }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func removeItem() {
        guard let item = selected, canLeave(), let window else { return }
        let alert = NSAlert(); alert.messageText = "移除「\(item.name)」？"; alert.informativeText = "文件会移到废纸篓，已有任务记录保留。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try store.extensions.trash(item, workspace: workspace); selected = nil; reload() } catch { state.stringValue = error.localizedDescription }
        }
    }
    private func scopeControl() -> NSPopUpButton {
        let scope = NSPopUpButton(); scope.addItems(withTitles: ["全局", "当前项目"]); scope.item(at: 1)?.isEnabled = workspace != nil; return scope
    }
    @objc private func createItem() {
        guard canLeave(), let window else { return }
        let alert = NSAlert(); alert.messageText = kind == .skill ? "新建 Skill" : "新建命令"; alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        let name = NSTextField(), scope = scopeControl(); name.placeholderString = "名称"; name.setAccessibilityLabel("扩展名称"); scope.setAccessibilityLabel("扩展范围")
        let form = NSStackView(views: [name, scope]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 10; form.frame = NSRect(x: 0, y: 0, width: 300, height: 64)
        name.widthAnchor.constraint(equalToConstant: 300).isActive = true; alert.accessoryView = form; alert.window.initialFirstResponder = name
        let chosen = kind
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = chosen == .skill ? "---\nname: \(value)\ndescription: \n---\n\n# 工作流\n\n1. 读取任务要求和实际输入。\n2. 执行所需步骤。\n3. 核对实际结果。\n" : "---\ndescription: \n---\n\n$ARGUMENTS\n"
                let item = try store.extensions.create(chosen, name: value, text: text, project: scope.indexOfSelectedItem == 1, workspace: workspace)
                search.stringValue = ""; reload(select: item.id); window.makeFirstResponder(editor)
            } catch { state.stringValue = error.localizedDescription }
        }
    }
    @objc private func importItem() {
        guard canLeave(), let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = kind == .skill; panel.allowsMultipleSelection = false
        panel.prompt = "导入"; panel.message = kind == .skill ? "选择 SKILL.md、Skill 文件夹、ZIP 或 .skill 文件" : "选择命令 Markdown 文件"
        let scope = scopeControl(); scope.setAccessibilityLabel("导入范围"); panel.accessoryView = scope
        let chosen = kind
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            state.stringValue = "导入中…"
            job = Task { [weak self] in
                guard let self else { return }; defer { job = nil; updateControls() }
                do {
                    let item = try await store.extensions.importItem(url, kind: chosen, project: scope.indexOfSelectedItem == 1, workspace: workspace)
                    try Task.checkCancellation(); search.stringValue = ""; reload(select: item.id); state.stringValue = "已导入"
                } catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
            }; updateControls()
        }
    }
    private func canLeave() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存的更改？"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }; dirty = false; return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let child = ruleWindow?.window, child.isVisible { child.performClose(nil); if child.isVisible { return false } }
        if canLeave() { job?.cancel(); return true }; return false
    }
    func checkLayout(_ output: URL) -> [String: Bool] {
        showWindow(nil); var checks = ["extensionEditorMatchesActualFile": selected.flatMap { try? store.extensions.document($0).0 } == editor.string, "extensionEnableAndSourceControls": enabled.isEnabled && reveal.isEnabled]
        if let item = selected, item.enabled, let row = items.firstIndex(where: { $0.id == item.id }) {
            enabled.state = .off; toggleEnabled()
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSStackView
            checks["toggleUpdatesVisibleRowAndPreservesSelection"] = (cell?.arrangedSubviews.first as? NSTextField)?.stringValue.contains("已停用") == true && table.selectedRow == row && !use.isEnabled
            enabled.state = .on; toggleEnabled()
        }
        for (name, size) in [("normal", NSSize(width: 1000, height: 700)), ("narrow", NSSize(width: 720, height: 480))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["extensionLayout-" + name] = !editor.hasAmbiguousLayout && editor.bounds.width > 370 && !table.hasAmbiguousLayout && !save.hasAmbiguousLayout && footerFits()
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("extensions-" + name + ".png")) }
        }
        return checks
    }
    private func footerFits() -> Bool { guard let content = window?.contentView, let parent = save.superview else { return false }; return content.bounds.contains(parent.convert(save.frame, to: content)) }
}

@MainActor final class AgentExtensionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "命令与 Skills"; isReleasedWhenClosed = false; hasShadow = true; hidesOnDeactivate = true; animationBehavior = .none
        backgroundColor = .windowBackgroundColor
    }
}
@MainActor final class AgentExtensionTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
@MainActor final class AgentExtensionPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = AgentExtensionTable()
    private(set) var items: [AgentExtensionItem] = []
    var onPick: ((AgentExtensionItem) -> Void)?
    var onAutomation: (() -> Void)?
    private var automation = false
    var candidateCount: Int { items.count + (automation ? 1 : 0) }
    override func loadView() {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workflow"))); table.headerView = nil
        table.rowHeight = 44; table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(pick)
        table.setAccessibilityLabel("命令与 Skills 候选"); scroll.documentView = table; view = scroll
    }
    func setItems(_ items: [AgentExtensionItem], automation: Bool = false) { loadViewIfNeeded(); self.items = items; self.automation = automation; table.reloadData(); if candidateCount > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) } }
    func move(_ amount: Int) { guard candidateCount > 0 else { return }; let row = min(candidateCount - 1, max(0, table.selectedRow + amount)); table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
    func numberOfRows(in tableView: NSTableView) -> Int { candidateCount }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = automation && row == 0 ? nil : items[row - (automation ? 1 : 0)]
        let title = NSTextField(labelWithString: item.map { "/" + $0.invocation + " · " + $0.scope } ?? "/automation · 自动化"); title.font = .systemFont(ofSize: 12, weight: .medium)
        let description = NSTextField(labelWithString: item?.description ?? "按目标与时间起草计划"); description.font = .systemFont(ofSize: 11); description.textColor = .secondaryLabelColor
        for field in [title, description] { field.lineBreakMode = .byTruncatingTail }
        let stack = NSStackView(views: [title, description]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3; return stack
    }
    @objc func pick() {
        if automation && table.selectedRow == 0 { onAutomation?(); return }
        let row = table.selectedRow - (automation ? 1 : 0); if items.indices.contains(row) { onPick?(items[row]) }
    }
}
