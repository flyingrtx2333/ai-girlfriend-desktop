import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentExtensionWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String
    private let kinds = NSSegmentedControl(labels: ["Skills", "命令"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), table = AgentSettingsCatalogTable(), editor = NSTextView()
    private let enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let add = AgentDialogButton(title: "新建", target: nil, action: nil), importButton = NSButton(title: "导入", target: nil, action: nil)
    private let save = AgentDialogButton(title: "保存", target: nil, action: nil), remove = NSButton(title: "移除", target: nil, action: nil)
    private let use = NSButton(title: "在任务中使用", target: nil, action: nil), reveal = NSButton(title: "打开来源", target: nil, action: nil)
    private let location = NSTextField(labelWithString: ""), state = AgentSettingsStatusField("扩展保存状态")
    private var catalogLayout: (toolbar: NSStackView, actions: NSStackView, header: NSStackView, viewer: NSScrollView, footer: NSStackView)?
    private var detailPage: AgentSettingsDetailPage?
    private let catalogState = AgentSettingsStatusField("扩展列表状态")
    private var requestedDetail = false
    private var items: [AgentExtensionItem] = [], selected: AgentExtensionItem?, openedHash: String?, dirty = false, selectedKind = 0
    private var availableInTask = false
    private lazy var draftViewport: AgentSettingsDraftViewport = {
        let view = AgentSettingsDraftViewport(text: editor, fields: ["search": search], catalog: table, host: { [weak self] in self?.presentingWindow })
        view.onChange = { [weak self] in self?.onSettingsRecoveryChange?() }; return view
    }()
    private var job: Task<Void, Never>?
    private var mcpWindow: AgentMCPWindow?
    private var hookWindow: AgentHookWindow?
    private var agentWindow: AgentProfileWindow?
    private var teamWindow: AgentTeamWindow?
    private var pluginWindow: AgentPluginWindow?
    private var ruleWindow: AgentRuleWindow?
    var onStartTask: ((String) -> Void)?
    var onBrowseMCP: ((String?) -> Void)?
    var onInsert: ((AgentExtensionItem) throws -> Void)? { didSet { updateControls() } }
    var onInsertRule: ((AgentPluginRuleItem) throws -> Void)?
    var onInsertLocalRule: ((AgentLocalRuleItem) throws -> Void)?
    private let workspace: String?
    private var kind: AgentExtensionKind { kinds.selectedSegment == 1 ? .command : .skill }
    init(store: AgentStore, taskID: String, managementWorkspace: String? = nil) {
        self.store = store; self.taskID = taskID; workspace = managementWorkspace ?? store.task(taskID)?.workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "扩展"; window.minSize = NSSize(width: 720, height: 480); window.center(); window.isReleasedWhenClosed = false
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
        for label in [location, state] { label.font = .systemFont(ofSize: 11); label.textColor = AgentWorkbenchTheme.secondaryText; label.lineBreakMode = .byTruncatingMiddle }
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(add, #selector(createItem)), (importButton, #selector(importItem)), (save, #selector(saveItem)), (remove, #selector(removeItem)), (use, #selector(useItem)), (reveal, #selector(revealItem))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; AgentSettingsStyle.primaryAction(save)
        let detailHeader = NSStackView(views: [enabled, location, NSView(), use]); detailHeader.spacing = 10
        let rules = NSButton(title: "规则", target: self, action: #selector(showRules))
        let listActions = NSStackView(views: [add, importButton, rules, NSView()]); listActions.spacing = 8
        let footer = NSStackView(views: [state, NSView(), reveal, remove, save]); footer.spacing = 8
        catalogLayout = (header, listActions, detailHeader, viewer, footer)
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
    override func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        if detailPage == nil, let content = window?.contentView, let layout = catalogLayout {
            AgentSettingsCatalog.detach(content)
            for view in layout.actions.arrangedSubviews {
                layout.actions.removeArrangedSubview(view); view.removeFromSuperview()
                if view is NSControl { layout.toolbar.addArrangedSubview(view) }
            }
            search.setContentHuggingPriority(.defaultLow, for: .horizontal)
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
            let detail = NSStackView(views: [layout.header, layout.viewer, layout.footer]); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 12
            for view in detail.arrangedSubviews { view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
            layout.header.heightAnchor.constraint(equalToConstant: 28).isActive = true; layout.footer.heightAnchor.constraint(equalToConstant: 28).isActive = true
            let page = AgentSettingsDetailPage(title: kind == .skill ? "技能配置" : "指令配置", content: AgentSettingsCatalog.detail(detail))
            page.onCanLeave = { [weak self] in
                guard let self else { return true }; let wasDirty = dirty
                guard canLeave() else { return false }; if wasDirty { reload(select: selected?.id) }; return true
            }
            page.onAppear = { [weak self] in guard let self else { return }; draftViewport.appear(default: editor) }
            detailPage = page; catalogLayout = nil
            state.onChange = { [weak self] value in self?.catalogState.stringValue = value }; catalogState.stringValue = state.stringValue
            table.target = self; table.action = #selector(openSelectedItem); table.onOpen = { [weak self] in self?.showDetail() }
            table.groupName = { [weak self] row in guard let self, items.indices.contains(row) else { return "" }; return items[row].scope }
            AgentSettingsStyle.primaryAction(add)
            window?.contentView = AgentSettingsCatalog.content(table: table, toolbar: layout.toolbar, status: catalogState, actions: [importButton, add], symbol: kind == .skill ? "sparkles" : "command"); table.reloadData(); selectRow(selected?.id); updateControls()
        }
        return super.settingsContent(in: host, styled: styled)
    }
    override var usesInternalScrolling: Bool { detailPage != nil }
    override var minimumSettingsContentHeight: CGFloat { detailPage == nil ? super.minimumSettingsContentHeight : 220 }
    override func canLeaveSettings() -> Bool { detailPage?.settingsHostWindow != nil ? true : super.canLeaveSettings() }
    @objc private func openSelectedItem() { showDetail() }
    private func showDetail() {
        guard selected != nil, let detailPage else { return }
        if detailPage.settingsHostWindow == nil { presentSettingsChild(detailPage) } else { detailPage.settingsDidAppear() }
    }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        if requestedDetail { requestedDetail = false; showDetail(); return }
        guard isPageVisible, let content = pageContentView, let host = presentingWindow else { return }
        if let focused = host.firstResponder as? NSView, focused.isDescendant(of: content) { return }
        draftViewport.appear(default: table)
    }
    func prepareSettings(kind: AgentExtensionKind) {
        kinds.selectedSegment = kind == .command ? 1 : 0; selectedKind = kinds.selectedSegment
        kinds.isHidden = true
        if let header = kinds.superview as? NSStackView {
            for view in header.arrangedSubviews {
                if let button = view as? NSButton, ["插件", "MCP 连接器", "Hooks", "自定义 Agent", "团队"].contains(button.title) { button.isHidden = true }
            }
        }
        reload()
    }
    func selectItem(_ id:String) { if canLeave() { reload(select:id); if settingsHostWindow != nil { showDetail() } else { requestedDetail = true } } }
    @objc private func showRules() {
        guard canLeave() else { return }
        if let window = ruleWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let manager = AgentRuleWindow(store: store, taskID: taskID, managementWorkspace: workspace); manager.onInsert = onInsertLocalRule; ruleWindow = manager; presentSettingsChild(manager)
    }
    @objc private func showPlugins() {
        guard canLeave() else { return }
        if let window = pluginWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let manager = AgentPluginWindow(store: store, workspace: workspace); manager.onInsert = onInsert; manager.onInsertRule = onInsertRule; manager.onChange = { [weak self] in self?.reload() }; manager.onConfigureMCP = { [weak self] id, scope in self?.openMCP(id, workspace: scope) }; manager.onConfigureAgent = { [weak self] id, scope in self?.openAgent(id, workspace: scope) }; manager.onConfigureHook = { [weak self] id, scope in self?.openHook(id, workspace: scope) }; pluginWindow = manager; presentSettingsChild(manager)
    }
    @objc private func showMCP() {
        openMCP(nil, workspace: workspace)
    }
    private func openMCP(_ id: String?, workspace: String?) {
        if let manager = mcpWindow, let window = manager.window, window.isVisible {
            if manager.scopeWorkspace == workspace { if let id { manager.selectServer(id) }; window.makeKeyAndOrderFront(nil); return }
            window.performClose(nil); if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        }
        let manager = AgentMCPWindow(service: store.mcp, workspace: workspace); manager.onBrowseContent = onBrowseMCP; mcpWindow = manager; if let id { manager.selectServer(id) }; presentSettingsChild(manager)
    }
    @objc private func showHooks() {
        openHook(nil, workspace: workspace)
    }
    private func openHook(_ id: String?, workspace: String?) {
        if let manager = hookWindow, let window = manager.window, window.isVisible {
            if manager.scopeWorkspace == workspace { if let id { manager.selectHook(id) }; window.makeKeyAndOrderFront(nil); return }
            window.performClose(nil); if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        }
        let manager = AgentHookWindow(service: store.hooks, workspace: workspace); hookWindow = manager; if let id { manager.selectHook(id) }; presentSettingsChild(manager)
    }
    @objc private func showAgents() {
        openAgent(nil, workspace: workspace)
    }
    private func openAgent(_ id: String?, workspace: String?) {
        if let manager = agentWindow, let window = manager.window, window.isVisible {
            if manager.scopeWorkspace == workspace { if let id { manager.selectProfile(id) }; window.makeKeyAndOrderFront(nil); return }
            window.performClose(nil); if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        }
        let manager = AgentProfileWindow(store: store, workspace: workspace, workMode: store.task(taskID)?.organizationMode, taskID: taskID.isEmpty ? nil : taskID); manager.onUse = onStartTask; agentWindow = manager; if let id { manager.selectProfile(id) }; presentSettingsChild(manager)
    }
    @objc private func showTeams() {
        if let window = teamWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let manager = AgentTeamWindow(store: store, workspace: workspace, workMode: store.task(taskID)?.organizationMode, taskID: taskID.isEmpty ? nil : taskID); manager.onUse = onStartTask; teamWindow = manager; presentSettingsChild(manager)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        if detailPage != nil {
            return AgentSettingsCatalogCell(title: item.name, summary: item.description, symbol: item.kind == .skill ? "sparkles" : "command", status: item.enabled ? "" : "已停用", group: table.group(at: row)) { [weak self] in self?.selectItem(item.id) }
        }
        let name = NSTextField(labelWithString: item.name + (item.enabled ? "" : " · 已停用"))
        name.font = .systemFont(ofSize: 12, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        let source = NSTextField(labelWithString: item.scope + (item.manualOnly ? " · 手动" : "")); source.font = .systemFont(ofSize: 11); source.textColor = AgentWorkbenchTheme.secondaryText
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
    private func reload(select id: String? = nil, keepingEditor: Bool = false) {
        guard !dirty else { state.stringValue = "请先保存或放弃更改"; return }
        do {
            let all = try store.extensions.catalog(workspace: workspace), query = search.stringValue
            let matches = all.filter { $0.kind == kind && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)) }
            var seen = Set<String>(), sources: [String] = []
            for item in matches where seen.insert(item.scope).inserted { sources.append(item.scope) }
            let groups = Dictionary(grouping: matches, by: \.scope)
            items = sources.flatMap { groups[$0] ?? [] }
            table.delegate = nil; table.reloadData(); table.delegate = self
            let next = keepingEditor ? selected : items.first(where: { $0.id == (id ?? selected?.id) }) ?? items.first
            selectRow(next?.id)
            if !keepingEditor {
                if let next { open(next) }
                else { selected = nil; availableInTask = false; openedHash = nil; editor.string = ""; editor.isEditable = false; updateControls() }
            }
            if !store.extensions.warnings.isEmpty { state.stringValue = store.extensions.warnings.joined(separator: "\n"); state.toolTip = state.stringValue }
            else { state.stringValue = items.isEmpty ? "暂无扩展" : "\(items.count) 项"; state.toolTip = nil }
        } catch { state.stringValue = error.localizedDescription }
    }
    private func open(_ item: AgentExtensionItem) {
        draftViewport.reset()
        do {
            let (text, _) = try store.extensions.document(item)
            editor.string = text
            editor.undoManager?.removeAllActions()
            adopt(item, hash: AgentFiles.hash(Data(text.utf8)))
        } catch { state.stringValue = error.localizedDescription }
    }
    private func adopt(_ item: AgentExtensionItem, hash: String) {
        selected = item; openedHash = hash; dirty = false
        availableInTask = store.task(taskID).map { task in
            guard (try? store.extensions.item(item.id, task: task, enabled: false).file) == item.file else { return false }
            return item.kind != .skill || (try? store.agents.checkSkill(item.id, task: task)) != nil
        } ?? false
        enabled.state = item.enabled ? .on : .off; updateControls()
    }
    private func updateControls() {
        detailPage?.detailHeading = selected.map { .init(title: $0.name, scope: $0.scope, location: $0.file.path) }
        location.stringValue = selected.map { (detailPage == nil ? $0.scope + " · " : "") + "/" + $0.invocation } ?? ""
        location.toolTip = selected?.file.path
        if detailPage != nil { AgentSettingsStyle.listState(table, text: search.stringValue.isEmpty ? (kind == .skill ? "暂无技能" : "暂无指令") : "未找到匹配项") }
        let idle = job == nil, managed = selected?.managed == true
        kinds.isEnabled = idle; search.isEnabled = idle; table.isEnabled = idle; add.isEnabled = idle; importButton.isEnabled = idle
        enabled.isEnabled = idle && selected != nil && selected?.pluginName == nil
        use.isEnabled = idle && selected?.enabled == true && onInsert != nil && availableInTask
        use.toolTip = availableInTask ? nil : "此扩展超出当前任务的可用范围"
        remove.isEnabled = idle && managed; save.isEnabled = idle && managed && dirty; reveal.isEnabled = idle && selected != nil
        editor.isEditable = idle && managed
        onSettingsRecoveryChange?()
    }
    @objc private func changeKind() {
        guard canLeave() else { kinds.selectedSegment = selectedKind; return }; selectedKind = kinds.selectedSegment; selected = nil; reload()
    }
    @objc private func refreshList() { if canLeave() { reload() } }
    func controlTextDidChange(_ notification: Notification) { draftViewport.changed(); if !dirty { reload() }; onSettingsRecoveryChange?() }
    func textDidChange(_ notification: Notification) { draftViewport.changed(); dirty = true; state.stringValue = "未保存"; updateControls() }
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
        do {
            let text = editor.string, submittedHash = AgentFiles.hash(Data(text.utf8))
            let saved = try store.extensions.save(item, text: text, expectedHash: hash, workspace: workspace)
            guard saved.sha256 == submittedHash else {
                throw AgentSaveFailure(reason: .changed, diagnostic: "扩展保存后发生外部修改：" + saved.file.path)
            }
            adopt(saved, hash: submittedHash)
            reload(keepingEditor: true)
            state.stringValue = "已保存"
        }
        catch { state.showSaveFailure(error); onSettingsRecoveryChange?() }
    }
    @objc private func revealItem() { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.file]) } }
    @objc private func useItem() {
        guard let item = selected, canLeave() else { return }
        do { try onInsert?(store.extensions.item(item.id, workspace: workspace)); close() }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func removeItem() {
        guard let item = selected, item.managed, job == nil, let window = presentingWindow else { return }
        if let detailPage, detailPage.settingsHostWindow != nil, detailPage.isPageVisible {
            do {
                let skill = item.kind == .skill
                let target = skill ? item.root : item.file
                let signature = try AgentSettingsRemovalReview.sourceSignature(target)
                var impact = skill ? "技能目录及其中的文件会移到废纸篓。" : "这份指令文件会移到废纸篓。"
                if dirty { impact += "当前未保存的编辑会随移除操作丢弃。" }
                var scope = item.scope
                if item.scope == "项目", let workspace { scope += " · " + URL(fileURLWithPath: workspace).lastPathComponent }
                let review = AgentSettingsRemovalReview(title: skill ? "移除技能" : "移除指令",
                    target: .init(title: item.name, scope: scope, location: target.path), impact: impact)
                let position = try draftViewport.capture()
                try draftViewport.restore(position)
                review.validateTarget = { [weak self] in
                    guard let self, job == nil, self.selected?.id == item.id,
                          let current = try? store.extensions.item(item.id, workspace: workspace, enabled: false),
                          current.managed, current.file == item.file, current.root == item.root, current.sha256 == item.sha256,
                          (try? AgentSettingsRemovalReview.sourceSignature(target)) == signature else {
                        throw PetError("扩展来源已变化，请返回核对后重新移除")
                    }
                }
                review.onApply = { [weak self] in
                    guard let self else { throw PetError("原扩展详情已关闭") }
                    try store.extensions.trash(item, workspace: workspace)
                    dirty = false; selected = nil; reload()
                }
                review.onApplied = { [weak self, weak detailPage] in
                    detailPage?.close(); self?.state.stringValue = "已移到废纸篓"
                }
                detailPage.presentSettingsChild(review)
            } catch { state.showSaveFailure(error) }
            return
        }
        guard canLeave() else { return }
        let alert = AgentConfirmation(); alert.messageText = "移除「\(item.name)」？"; alert.informativeText = "文件会移到废纸篓，已有任务记录保留。"
        alert.addButton(withTitle: "移除").hasDestructiveAction = true; alert.addButton(withTitle: "取消")
        alert.beginModal(in: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try store.extensions.trash(item, workspace: workspace); selected = nil; reload() } catch { state.stringValue = error.localizedDescription }
        }
    }
    private func scopeControl() -> NSPopUpButton {
        let scope = NSPopUpButton(); scope.addItems(withTitles: ["全局", "当前项目"]); scope.item(at: 1)?.isEnabled = workspace != nil; return scope
    }
    @objc private func createItem() {
        guard canLeave() else { return }
        if let menu = creationMenu() {
            menu.update()
            menu.popUp(positioning: nil, at: NSPoint(x: add.bounds.maxX - menu.size.width, y: add.bounds.height + 4), in: add)
        } else { createManually() }
    }
    func creationMenu() -> NSMenu? {
        guard kind == .skill else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        let task = NSMenuItem(title: "通过小鲸创建", action: #selector(createSkillTask), keyEquivalent: "")
        task.target = self; task.isEnabled = onStartTask != nil; task.identifier = .init("skill-create-task")
        let manual = NSMenuItem(title: "手动创建", action: #selector(createManually), keyEquivalent: "")
        manual.target = self; manual.identifier = .init("skill-create-manual")
        menu.addItem(task); menu.addItem(manual); return menu
    }
    @objc private func createSkillTask() {
        guard kind == .skill, let open = onStartTask, canLeave() else { return }
        do { open(try AgentSkillCreation.create(store: store, sourceTaskID: taskID.isEmpty ? nil : taskID, workspace: workspace)) }
        catch { state.showSaveFailure(error) }
    }
    @objc private func createManually() {
        guard canLeave() else { return }
        presentSettingsChild(makeCreationPage())
    }
    private func makeCreationPage() -> AgentExtensionCreationPage {
        let page = AgentExtensionCreationPage(service: store.extensions, kind: kind, workspace: workspace)
        page.onCreated = { [weak self] item in
            guard let self else { return }
            search.stringValue = ""; reload(select: item.id); state.stringValue = "已创建"; showDetail(); presentingWindow?.makeFirstResponder(editor)
        }
        return page
    }
    @objc private func importItem() {
        guard canLeave(), let window = presentingWindow else { return }
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
                    try Task.checkCancellation(); search.stringValue = ""; reload(select: item.id); state.stringValue = "已导入"; showDetail()
                } catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
            }; updateControls()
        }
    }
    private func canLeave() -> Bool {
        guard dirty else { return true }
        guard AgentUnsavedChanges.discard("放弃未保存的更改？") else { return false }; dirty = false; return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let child = ruleWindow?.window, child.isVisible { child.performClose(nil); if child.isVisible { return false } }
        if canLeave() { job?.cancel(); return true }; return false
    }
    override func settingsWillLeave() { job?.cancel() }
    override func pageDidLayout() { draftViewport.schedule() }
    private struct Recovery: Codable {
        var version = 1
        var taskID: String, workspace: String?, kind: AgentExtensionKind
        var selected: AgentExtensionItem?, openedHash: String?, body: String, query: String, dirty: Bool, detail: Bool, status: String
        var viewport: AgentSettingsDraftViewport.State
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        guard job == nil else { throw PetError("请先完成或取消扩展导入") }
        var viewport = try draftViewport.capture()
        let detail = detailPage?.settingsHostWindow != nil || requestedDetail
        if !detail { viewport.focus = search.currentEditor() === presentingWindow?.firstResponder ? "search" : "catalog"; viewport.text.focused = false }
        let value = Recovery(taskID: taskID, workspace: workspace, kind: kind, selected: selected, openedHash: openedHash,
            body: editor.string, query: search.stringValue, dirty: dirty, detail: detail, status: state.stringValue, viewport: viewport)
        return try AgentSettingsRecovery.page(kind == .skill ? "skills" : "commands", value)
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == (kind == .skill ? "skills" : "commands"), job == nil else { throw PetError("扩展草稿类型或操作已变化，原记录已保留") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "taskID", "workspace", "kind", "selected", "openedHash", "body", "query", "dirty", "detail", "status", "viewport"])
        if let viewport = raw["viewport"] { try AgentSettingsDraftViewport.validateObject(viewport) }
        if let selected = raw["selected"], !(selected is NSNull) { _ = try AgentSettingsRecovery.object(selected, keys: ["id", "name", "description", "kind", "file", "root", "scope", "managed", "enabled", "manualOnly", "sha256", "pluginName"]) }
        let value = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard value.version == 1, value.taskID == taskID, value.workspace == workspace, value.kind == kind,
              value.selected?.kind == nil || value.selected?.kind == kind, !value.detail || value.selected != nil,
              (value.selected == nil) == (value.openedHash == nil) else { throw PetError("扩展草稿所属对象或范围无效，原记录已保留") }
        try draftViewport.validate(value.viewport, text: value.body, fields: ["search": value.query])
        let current = try store.extensions.catalog(workspace: workspace)
        items = current.filter { $0.kind == kind && (value.query.isEmpty || $0.name.localizedCaseInsensitiveContains(value.query) || $0.description.localizedCaseInsensitiveContains(value.query)) }
        if let item = value.selected { items.removeAll { $0.id == item.id }; items.append(item) }
        selected = value.selected; openedHash = value.openedHash; editor.string = value.body; search.stringValue = value.query
        let changed = value.selected.map { old in !current.contains { $0.id == old.id && $0.file == old.file && $0.root == old.root && $0.sha256 == old.sha256 } } ?? false
        dirty = value.dirty || changed; requestedDetail = value.detail
        availableInTask = selected.map { item in store.task(taskID).map { task in
            (try? store.extensions.item(item.id, task: task, enabled: false).file) == item.file && (item.kind != .skill || (try? store.agents.checkSkill(item.id, task: task)) != nil)
        } ?? false } ?? false
        enabled.state = selected?.enabled == true ? .on : .off; table.delegate = nil; table.reloadData(); table.delegate = self; selectRow(selected?.id)
        state.stringValue = changed ? "原扩展已变化，恢复草稿已保留；刷新可重新读取" : value.status; updateControls(); editor.undoManager?.removeAllActions()
        try draftViewport.restore(value.viewport)
    }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        page.kind == "extension-create" ? makeCreationPage() : nil
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
        title = "指令与扩展能力"; isReleasedWhenClosed = false; hasShadow = true; hidesOnDeactivate = true; animationBehavior = .none
        backgroundColor = .windowBackgroundColor
    }
}
@MainActor final class AgentExtensionTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
@MainActor final class AgentSlashCategories: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { false }
}
@MainActor final class AgentExtensionPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = AgentExtensionTable()
    private let categories = AgentSlashCategories(labels: AgentSlashCategory.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let back = NSButton(title: "返回", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "暂无最近使用"), footer = NSTextField(labelWithString: "")
    private let scroll = NSScrollView(), header = NSStackView()
    private var listHeight: NSLayoutConstraint!
    private var service: AgentSlashMenu?, allEntries: [AgentSlashEntry] = [], presentation = AgentSlashPresentation.recent, query = "", plugin: String?
    private var connectorIssue:String?
    private(set) var category = AgentSlashCategory.recent, entries: [AgentSlashEntry] = []
    var items: [AgentExtensionItem] { allEntries.compactMap(\.extensionItem) }
    var onPick: ((AgentSlashEntry) -> Void)?, onLayoutChanged: (() -> Void)?
    var candidateCount: Int { entries.count }
    func fitHeight(_ maximum: CGFloat) -> CGFloat {
        let padding: CGFloat = header.isHidden ? 30 : 56
        let rows = max(1, min(8, entries.count, Int(max(0, (maximum - padding) / 30).rounded(.down))))
        listHeight.constant = CGFloat(rows) * 30
        return listHeight.constant + padding
    }
    var selectedID: String? { entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].id : nil }
    override func loadView() {
        let root = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line); root.layer?.cornerRadius = 8; root.layer?.borderWidth = 1
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workflow"))); table.headerView = nil
        table.style = .plain; table.usesAutomaticRowHeights = false; table.rowHeight = 30; table.intercellSpacing = .zero; table.backgroundColor = .clear; table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(pick)
        table.setAccessibilityLabel("指令与扩展能力建议"); table.identifier = NSUserInterfaceItemIdentifier("slash-menu-candidates"); scroll.documentView = table
        categories.target = self; categories.action = #selector(changeCategory); categories.controlSize = .small; categories.font = .systemFont(ofSize: 11); categories.setAccessibilityLabel("Slash 能力类别")
        back.target = self; back.action = #selector(backPressed); back.isBordered = false; back.font = .systemFont(ofSize: 11); back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil); back.imagePosition = .imageLeading; back.setAccessibilityLabel("返回插件列表")
        header.addArrangedSubview(back); header.addArrangedSubview(categories); header.addArrangedSubview(NSView()); header.spacing = 6
        empty.font = .systemFont(ofSize: 12); empty.textColor = AgentWorkbenchTheme.secondaryText; empty.alignment = .center
        footer.font = .systemFont(ofSize: 10); footer.textColor = AgentWorkbenchTheme.secondaryText; footer.lineBreakMode = .byTruncatingTail; footer.setAccessibilityLabel("命令菜单状态")
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true; footer.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let column = NSStackView(views: [header, scroll, empty, footer]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 4; column.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(column)
        for child in [header, scroll, empty, footer] { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 30); listHeight.isActive = true; empty.heightAnchor.constraint(equalToConstant: 30).isActive = true
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8), column.topAnchor.constraint(equalTo: root.topAnchor, constant: 6), column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)])
        view = root
    }
    func setEntries(_ entries: [AgentSlashEntry], service: AgentSlashMenu, presentation: AgentSlashPresentation, query: String, reset: Bool, connectorIssue:String? = nil) {
        loadViewIfNeeded()
        if reset || self.service == nil || self.presentation != presentation || self.query != query { category = .recent; plugin = nil }
        self.allEntries = entries; self.service = service; self.presentation = presentation; self.query = query
        self.connectorIssue = connectorIssue
        table.setAccessibilityLabel("指令与扩展能力建议"); footer.setAccessibilityLabel("命令菜单状态")
        if let plugin, !entries.contains(where: { $0.pluginKey == plugin }) { self.plugin = nil }
        service.reload(); refresh()
    }
    func setBrowserTabs(_ pages: [AgentBrowserTabReference], query: String) {
        loadViewIfNeeded()
        let previous = selectedID
        service = nil; plugin = nil; self.query = query; category = .recent
        allEntries = pages.map(AgentSlashEntry.browserTab)
        entries = query.isEmpty ? allEntries : allEntries.filter { $0.matches(query) }
        categories.isHidden = true; back.isHidden = true; header.isHidden = true
        empty.stringValue = "未找到匹配的网页标签"
        table.setAccessibilityLabel("当前任务网页标签"); footer.setAccessibilityLabel("网页引用菜单状态")
        footer.stringValue = "↑↓ 选择   Enter / Tab 添加   Esc 关闭"; footer.toolTip = nil
        reloadRows(previous: previous)
    }
    private func refresh() {
        guard let service else { return }
        let previous = entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].id : nil
        entries = service.visible(allEntries, presentation: presentation, category: category, query: query, plugin: plugin)
        categories.isHidden = presentation != .recent || !query.isEmpty || plugin != nil; back.isHidden = plugin == nil; header.isHidden = categories.isHidden && back.isHidden
        categories.selectedSegment = AgentSlashCategory.allCases.firstIndex(of: category) ?? 0
        for (index, value) in AgentSlashCategory.allCases.enumerated() {
            categories.setEnabled(value == .recent || value == .connectors && connectorIssue != nil || !service.visible(allEntries, presentation: .recent, category: value, query: "", plugin: nil).isEmpty, forSegment: index)
            if value == .connectors { categories.setToolTip("在 Agent 或目标任务中选择已配置连接器",forSegment:index) }
        }
        if let plugin { back.title = allEntries.first(where: { $0.pluginKey == plugin })?.title ?? "返回" }
        empty.stringValue = !query.isEmpty ? "未找到匹配项" : category == .recent && plugin == nil && presentation == .recent ? "暂无最近使用" : "暂无可用能力"
        let hints = !categories.isHidden ? "↑↓ 选择   ←→ 类别   Enter / Tab 添加   Esc 关闭" : plugin != nil ? "↑↓ 选择   ← 返回   Enter / Tab 添加   Esc 关闭" : "↑↓ 选择   Enter / Tab 添加   Esc 关闭"
        let issue = category == .connectors ? connectorIssue.map { "连接器未载入：" + $0 } ?? service.issue : service.issue
        footer.stringValue = issue ?? hints; footer.toolTip = issue
        reloadRows(previous: previous)
    }
    private func reloadRows(previous: String?) {
        scroll.isHidden = entries.isEmpty; empty.isHidden = !entries.isEmpty
        listHeight.constant = CGFloat(max(1, min(8, entries.count))) * 30
        table.reloadData()
        if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: entries.firstIndex(where: { $0.id == previous }) ?? 0), byExtendingSelection: false); table.scrollRowToVisible(table.selectedRow) }
        else { table.deselectAll(nil) }
        onLayoutChanged?()
    }
    @objc private func changeCategory() { category = AgentSlashCategory.allCases[max(0, categories.selectedSegment)]; plugin = nil; refresh() }
    @objc private func backPressed() { _ = goBack() }
    @discardableResult func goBack() -> Bool { guard plugin != nil else { return false }; plugin = nil; refresh(); return true }
    func moveCategory(_ amount: Int) -> Bool {
        if plugin != nil { return amount < 0 && goBack() }
        guard !categories.isHidden else { return false }
        let count = AgentSlashCategory.allCases.count, current = categories.selectedSegment
        for offset in 1...count {
            let index = (current + amount * offset + count * 2) % count
            if categories.isEnabled(forSegment: index) { categories.selectedSegment = index; changeCategory(); return true }
        }; return true
    }
    func move(_ amount: Int) { guard candidateCount > 0 else { return }; let row = min(candidateCount - 1, max(0, table.selectedRow + amount)); table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
    func numberOfRows(in tableView: NSTableView) -> Int { candidateCount }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }; let entry = entries[row]
        let image = NSImageView(image: NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) ?? NSImage()); image.contentTintColor = AgentWorkbenchTheme.secondaryText
        image.widthAnchor.constraint(equalToConstant: 14).isActive = true; image.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let title = NSTextField(labelWithString: entry.title); title.font = .systemFont(ofSize: 12, weight: .medium); title.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true
        let description = NSTextField(labelWithString: entry.detail); description.font = .systemFont(ofSize: 11); description.textColor = AgentWorkbenchTheme.secondaryText; description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for field in [title, description] { field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1 }
        let source = NSTextField(labelWithString: entry.scope); source.identifier = NSUserInterfaceItemIdentifier("slash-entry-source")
        source.font = .systemFont(ofSize: 11); source.textColor = AgentWorkbenchTheme.secondaryText; source.alignment = .right
        source.lineBreakMode = .byTruncatingMiddle; source.maximumNumberOfLines = 1; source.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        source.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal); source.setAccessibilityLabel("来源：" + entry.scope)
        switch entry { case .builtin, .mode: source.isHidden = true; default: break }
        let stack = NSStackView(views: [image, title, description, NSView(), source]); stack.spacing = 7; stack.toolTip = entry.scope + "\n" + entry.detail; stack.setAccessibilityLabel(entry.kindTitle + " " + entry.title + "，" + entry.scope + "，" + entry.detail); return stack
    }
    func layoutReadback() -> [String: Any] {
        guard isViewLoaded else { return ["loaded": false] }
        view.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
        let visible = table.visibleRect, first = entries.isEmpty ? NSRect.zero : table.rect(ofRow: 0), last = entries.isEmpty ? NSRect.zero : table.rect(ofRow: entries.count - 1)
        let shortListFits = entries.isEmpty || entries.count > 8 || first.minY >= visible.minY - 0.5 && last.maxY <= visible.maxY + 0.5
        return ["visibleRect": NSStringFromRect(visible), "firstRow": NSStringFromRect(first), "lastRow": NSStringFromRect(last), "shortListFits": shortListFits, "footer":footer.stringValue, "categoryCount":categories.segmentCount, "categoriesFit":categories.isHidden || categories.frame.maxX <= header.bounds.maxX + 0.5]
    }
    @objc func pick() {
        guard entries.indices.contains(table.selectedRow) else { return }; let entry = entries[table.selectedRow]
        if let key = entry.pluginKey { plugin = key; refresh(); return }; onPick?(entry)
    }
}
