import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentMCPWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTabViewDelegate, NSWindowDelegate {
    private struct CatalogRow { let heading: String?; let server: AgentMCPServer? }
    private let service: AgentMCP, workspace: String?, sessionOwner = "manager-" + UUID().uuidString
    private let table = AgentMCPSettingsTable(), editor = NSTextView(), tools = AgentMCPToolCatalog()
    private let configurationKind = NSSegmentedControl(labels: ["表单", "JSON"], trackingMode: .selectOne, target: nil, action: nil)
    private let configurationHost = NSView(), jsonScroll = NSScrollView(), loadJSON = NSButton(title: "载入 JSON", target: nil, action: nil)
    private var form: AgentMCPConfigForm?
    private var displayedConfiguration = 0
    private let tabs = NSTabView()
    private let detailKinds = NSSegmentedControl(labels: ["配置", "工具"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), listState = AgentSettingsStatusField("连接器列表状态"), empty = NSTextField(labelWithString: "暂无连接器")
    private var catalogRows: [CatalogRow] = [], detailPage: AgentMCPDetailPage?, requestedDetail = false
    private let enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let connect = NSButton(title: "连接", target: nil, action: nil), disconnect = NSButton(title: "断开", target: nil, action: nil)
    private let save = NSButton(title: "保存", target: nil, action: nil), remove = NSButton(title: "移除", target: nil, action: nil)
    private let add = NSPopUpButton(frame: .zero, pullsDown: true), importButton = NSButton(title: "导入 JSON", target: nil, action: nil)
    private let state = AgentSettingsStatusField("MCP 保存与连接状态"), access = AgentSettingsStatusField("MCP 访问范围")
    var scopeWorkspace: String? { workspace }
    private var selected: AgentMCPServer?, dirty = false, creating = false, job: Task<Void, Never>?
    private var items: [AgentMCPServer] = []
    var onBrowseContent: ((String?) -> Void)? { didSet { browse.isHidden = onBrowseContent == nil } }
    private let browse = NSButton(title: "资料与提示词", target: nil, action: nil)
    override var minimumSettingsContentHeight: CGFloat { 220 }
    private var editingPage: AgentMCPDetailPage? { detailPage.flatMap { $0.settingsHostWindow != nil || $0.window?.isVisible == true ? $0 : nil } }
    private var editorWindow: NSWindow? { editingPage?.presentingWindow ?? presentingWindow }
    init(service: AgentMCP, workspace: String?) {
        self.service = service; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MCP 连接器" + (workspace.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""); window.minSize = NSSize(width: 740, height: 520); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(); window.contentView = content
        add.addItem(withTitle: "新建"); add.setAccessibilityLabel("新建 MCP 连接器")
        for (title, type) in [("本机程序", "stdio"), ("HTTP", "http"), ("SSE", "sse")] {
            let item = NSMenuItem(title: title, action: #selector(create(_:)), keyEquivalent: ""); item.target = self; item.representedObject = type; add.menu?.addItem(item)
        }
        importButton.target = self; importButton.action = #selector(importJSON)
        search.placeholderString = "搜索连接器"; search.setAccessibilityLabel("搜索连接器"); search.target = self; search.action = #selector(filterCatalog); search.sendsSearchStringImmediately = true
        let actions = NSStackView(views: [search, NSView(), add, importButton]); actions.spacing = 8
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mcp"))); table.headerView = nil
        table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("MCP 连接器列表")
        table.target = self; table.action = #selector(openSelectedServer); table.doubleAction = #selector(openSelectedServer)
        table.onOpen = { [weak self] in self?.openSelectedServer() }
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.drawsBackground = false; list.identifier = .init("form-input")
        empty.font = .systemFont(ofSize: 13); empty.textColor = AgentWorkbenchTheme.secondaryText
        let index = NSStackView(views: [actions, listState, list]); index.orientation = .vertical; index.alignment = .leading; index.spacing = 12
        content.addSubview(index); index.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
        for view in [actions, listState, list] { view.widthAnchor.constraint(equalTo: index.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([index.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), index.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), index.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), index.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), actions.heightAnchor.constraint(equalToConstant: 28), search.widthAnchor.constraint(lessThanOrEqualToConstant: 260), search.widthAnchor.constraint(greaterThanOrEqualToConstant: 140), list.heightAnchor.constraint(greaterThanOrEqualToConstant: 100), empty.centerXAnchor.constraint(equalTo: list.centerXAnchor), empty.centerYAnchor.constraint(equalTo: list.centerYAnchor)])

        editor.isRichText = false; editor.allowsUndo = true; editor.delegate = self; editor.isEditable = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = NSSize(width: 16, height: 16); editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.setAccessibilityLabel("MCP 配置 JSON")
        jsonScroll.documentView = editor; jsonScroll.hasVerticalScroller = true; jsonScroll.identifier = .init("form-input")
        configurationKind.selectedSegment = 0; configurationKind.setAccessibilityLabel("MCP 配置方式"); configurationKind.target = self; configurationKind.action = #selector(changeConfiguration)
        loadJSON.target = self; loadJSON.action = #selector(reviewPastedJSON); loadJSON.isHidden = true
        let configHeader = NSStackView(views: [configurationKind, NSView(), loadJSON]); configHeader.spacing = 8
        let config = NSStackView(views: [configHeader, configurationHost]); config.orientation = .vertical; config.alignment = .leading; config.spacing = 10
        for child in [configHeader, configurationHost] { child.widthAnchor.constraint(equalTo: config.widthAnchor).isActive = true }; configHeader.heightAnchor.constraint(equalToConstant: 28).isActive = true
        attachConfiguration(jsonScroll)
        tabs.tabViewType = .noTabsNoBorder; tabs.setAccessibilityLabel("连接器详情标签"); tabs.delegate = self
        for (label, view) in [("配置", config as NSView), ("工具", tools as NSView)] { let tab = NSTabViewItem(identifier: label); tab.label = label; tab.view = view; tabs.addTabViewItem(tab) }
        detailKinds.selectedSegment = 0; detailKinds.target = self; detailKinds.action = #selector(changeDetails); detailKinds.setAccessibilityLabel("连接器详情类型")
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        for (button, action) in [(connect, #selector(start)), (disconnect, #selector(stop)), (save, #selector(saveConfig)), (remove, #selector(removeConfig))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; AgentSettingsStyle.primaryAction(save)
        let header = NSStackView(views: [enabled, NSView(), disconnect, connect, save]); header.spacing = 8
        browse.target = self; browse.action = #selector(browseContent); browse.isHidden = true
        let navigation = NSStackView(views: [detailKinds, NSView(), browse, remove]); navigation.spacing = 8
        let card = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line); card.identifier = .init("settings-card-mcp-editor"); card.layer?.cornerRadius = 12; card.layer?.borderWidth = 1
        card.addSubview(tabs); tabs.translatesAutoresizingMaskIntoConstraints = false
        let preferredCardHeight = card.heightAnchor.constraint(greaterThanOrEqualToConstant: 120); preferredCardHeight.priority = .defaultHigh; preferredCardHeight.isActive = true
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 1), tabs.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -1), tabs.topAnchor.constraint(equalTo: card.topAnchor, constant: 1), tabs.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1), card.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)])
        let detail = AgentThemeView(), column = NSStackView(views: [header, state, navigation, card, access]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        detail.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, state, navigation, card, access] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 14), column.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -14), column.topAnchor.constraint(equalTo: detail.topAnchor, constant: 14), column.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -14), header.heightAnchor.constraint(equalToConstant: 28), navigation.heightAnchor.constraint(equalToConstant: 28)])
        let page = AgentMCPDetailPage(content: detail)
        page.onCanLeave = { [weak self] in
            guard let self, self.canLeave() else { return false }
            if self.dirty { self.dirty = false; self.reload(self.selected?.id) }
            return true
        }
        page.onAppear = { [weak self] in self?.focusDetail() }
        detailPage = page
        service.onChange = { [weak self] in self?.refreshCatalog() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() {
        super.settingsDidAppear(); service.onChange = { [weak self] in self?.refreshCatalog() }
        if requestedDetail { requestedDetail = false; showDetail() }
        else { refreshCatalog(); presentingWindow?.makeFirstResponder(table) }
    }
    override func canLeaveSettings() -> Bool { editingPage?.settingsHostWindow != nil ? true : super.canLeaveSettings() }
    private func showDetail() {
        guard let detailPage else { return }
        if editingPage != nil { detailPage.settingsDidAppear() }
        else { presentSettingsChild(detailPage) }
    }
    @objc private func filterCatalog() { rebuildRows() }
    private func attachConfiguration(_ view: NSView) {
        configurationHost.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: configurationHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: configurationHost.trailingAnchor), view.topAnchor.constraint(equalTo: configurationHost.topAnchor), view.bottomAnchor.constraint(equalTo: configurationHost.bottomAnchor)])
    }
    private func installForm() throws {
        let next = try AgentMCPConfigForm(document: editor.string, pluginLocked: selected?.plugin != nil)
        form?.view.removeFromSuperview(); form = next; attachConfiguration(next.view)
        next.onChange = { [weak self, weak next] in
            guard let self, let next else { return }; self.dirty = true
            do { self.editor.string = try next.document(); self.refreshState(); self.state.stringValue = "未保存" }
            catch { self.refreshState(); self.state.stringValue = error.localizedDescription }
        }
    }
    private func applyConfigurationKind() {
        let json = configurationKind.selectedSegment == 1; jsonScroll.isHidden = !json; form?.view.isHidden = json; loadJSON.isHidden = !json
        displayedConfiguration = configurationKind.selectedSegment
    }
    private func prepareConfiguration() {
        do { try installForm() } catch { form?.view.removeFromSuperview(); form = nil; configurationKind.selectedSegment = 1 }
        applyConfigurationKind()
    }
    private func focusDetail() {
        let target: NSView = tabs.selectedTabViewItem?.identifier as? String == "工具" ? tools : configurationKind.selectedSegment == 0 ? form?.firstInput ?? editor : editor
        editorWindow?.makeFirstResponder(target)
    }
    @objc private func changeConfiguration() {
        guard configurationKind.selectedSegment != displayedConfiguration else { return }
        do {
            if configurationKind.selectedSegment == 0 { try installForm() }
            else if let form { editor.string = try form.document() }
            applyConfigurationKind(); focusDetail()
        } catch { configurationKind.selectedSegment = displayedConfiguration; state.stringValue = error.localizedDescription }
    }
    @objc private func reviewPastedJSON() {
        do { try reviewImport(document: editor.string) } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func changeDetails() { tabs.selectTabViewItem(at: detailKinds.selectedSegment) }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        detailKinds.selectedSegment = tabViewItem.map { tabs.indexOfTabViewItem($0) } ?? 0
        if editingPage?.isPageVisible == true { focusDetail() }
    }
    @objc private func browseContent() { onBrowseContent?(selected?.id) }
    func numberOfRows(in tableView: NSTableView) -> Int { catalogRows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { catalogRows[row].server == nil ? 34 : 80 }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { catalogRows[row].server == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { catalogRows[row].server != nil }
    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { catalogRows[row].server == nil ? NSTableRowView() : AgentMCPSettingsRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard catalogRows.indices.contains(row) else { return nil }
        guard let server = catalogRows[row].server else {
            let label = NSTextField(labelWithString: catalogRows[row].heading ?? ""); label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = AgentWorkbenchTheme.secondaryText; return label
        }
        let name = NSTextField(labelWithString: server.name); name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingTail
        let type = NSTextField(labelWithString: (server.type == "stdio" ? "本机程序" : server.type == "sse" ? "SSE" : "HTTP") + (server.plugin.map { " · " + ((try? AgentPlugins.scope($0.name).name) ?? "") } ?? "")); type.font = .systemFont(ofSize: 11); type.textColor = AgentWorkbenchTheme.secondaryText; type.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [name, type]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 6
        let status = NSTextField(labelWithString: service.status(server.id, owner: sessionOwner, workspace: workspace)); status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText; status.lineBreakMode = .byTruncatingTail; status.toolTip = status.stringValue
        let toggle = NSSwitch(); toggle.target = self; toggle.action = #selector(toggleListedServer(_:)); toggle.identifier = .init(server.id); toggle.state = server.enabled ? .on : .off; toggle.isEnabled = server.configured != false && server.pluginEnabled != false && job == nil; toggle.setAccessibilityLabel("启用连接器 " + server.name)
        let open = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!, target: self, action: #selector(openListedServer(_:))); open.isBordered = false; open.identifier = .init(server.id); open.setAccessibilityLabel("配置连接器 " + server.name)
        let icon = NSImageView(image: NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)!); icon.contentTintColor = AgentWorkbenchTheme.secondaryText
        let stack = NSStackView(views: [icon, labels, NSView(), status, toggle, open]); stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 14)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true; open.widthAnchor.constraint(equalToConstant: 20).isActive = true; status.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.toolTip = server.name + " · " + type.stringValue + " · " + status.stringValue; return stack
    }
    @objc private func openSelectedServer() {
        guard catalogRows.indices.contains(table.selectedRow), let server = catalogRows[table.selectedRow].server else { return }; selectServer(server.id)
    }
    @objc private func openListedServer(_ sender: NSButton) { if let id = sender.identifier?.rawValue { selectServer(id) } }
    @objc private func toggleListedServer(_ sender: NSSwitch) {
        guard job == nil, !dirty, let id = sender.identifier?.rawValue else { rebuildRows(); return }
        do { try service.setEnabled(id, sender.state == .on, workspace: workspace); refreshCatalog() }
        catch { listState.stringValue = error.localizedDescription; rebuildRows() }
    }
    func selectServer(_ id: String) {
        guard canLeave() else { return }; reload(id); requestedDetail = true
        if settingsHostWindow != nil || window?.isVisible == true { requestedDetail = false; showDetail() }
    }
    private func select(_ id: String?) { table.delegate = nil; if let id, let row = catalogRows.firstIndex(where: { $0.server?.id == id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { table.deselectAll(nil) }; table.delegate = self }
    private func rebuildRows() {
        let query = search.stringValue, filtered = items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.type.localizedCaseInsensitiveContains(query) }
        catalogRows = []
        for (title, servers) in [("由插件提供", filtered.filter { $0.plugin != nil }), ("自定义连接器", filtered.filter { $0.plugin == nil })] where !servers.isEmpty {
            catalogRows.append(CatalogRow(heading: title + " " + String(servers.count), server: nil)); catalogRows += servers.map { CatalogRow(heading: nil, server: $0) }
        }
        table.delegate = nil; table.reloadData(); table.delegate = self; select(selected?.id)
        empty.stringValue = query.isEmpty ? "暂无连接器" : "没有匹配的连接器"; empty.isHidden = !filtered.isEmpty
    }
    private func refreshCatalog() {
        let id = selected?.id; items = service.availableServers(workspace: workspace); rebuildRows(); select(id); listState.stringValue = service.loadError ?? ""
        if !dirty, !creating {
            let current = items.first { $0.id == id }
            if let current, current.revision != selected?.revision { open(current) }
            else { selected = current; if current == nil { editor.string = ""; tools.string = "" } }
        }
        refreshState()
    }
    private func reload(_ id: String? = nil) {
        items = service.availableServers(workspace: workspace); rebuildRows(); let next = items.first { $0.id == (id ?? selected?.id) } ?? items.first
        select(next?.id); if let next { open(next) } else { selected = nil; creating = false; dirty = false; editor.string = ""; tools.string = ""; refreshState() }
    }
    private func open(_ server: AgentMCPServer) {
        do { editor.string = try service.document(server); selected = server; creating = false; dirty = false; prepareConfiguration(); tools.string = ""; editor.undoManager?.removeAllActions(); showTools(); refreshState() }
        catch { state.stringValue = error.localizedDescription }
    }
    private func showTools() {
        guard let selected, let token = service.token(selected.id, owner: sessionOwner) else { tools.string = ""; return }
        do {
            tools.string = String(decoding: try service.toolCatalogForSettings(selected.id, owner: sessionOwner, token: token), as: UTF8.self)
        } catch { tools.string = error.localizedDescription }
    }
    private func refreshState() {
        let current = items.first { $0.id == selected?.id }
        let connected = selected.map { service.connected($0.id, owner: sessionOwner) } ?? false
        editor.isEditable = (creating || selected != nil) && job == nil
        form?.setEnabled(editor.isEditable, pluginLocked: selected?.plugin != nil); configurationKind.isEnabled = job == nil; loadJSON.isEnabled = job == nil
        enabled.isEnabled = current != nil && current?.configured != false && current?.pluginEnabled != false && !dirty && job == nil; enabled.state = current?.enabled == true ? .on : .off
        connect.isEnabled = current?.enabled == true && !dirty && job == nil && !connected
        disconnect.isEnabled = selected != nil && (connected || job != nil)
        remove.isEnabled = selected != nil && selected?.plugin == nil && job == nil; save.isEnabled = (dirty || selected?.configured == false) && job == nil; table.isEnabled = job == nil
        add.isEnabled = job == nil; importButton.isEnabled = job == nil
        let draftType = (dirty || creating) && editor.string.utf8.count <= 64_000 ? ((try? JSONSerialization.jsonObject(with: Data(editor.string.utf8))) as? [String: Any])?["type"] as? String : nil
        let type = configurationKind.selectedSegment == 0 ? form?.type : dirty || creating ? draftType : selected?.type
        access.stringValue = (selected?.plugin.map { "插件 " + ((try? AgentPlugins.scope($0.name).name) ?? "") + " · " } ?? "") + (["http", "sse"].contains(type) ? "凭据保存在钥匙串" : type == "stdio" ? "本机程序使用当前账户权限" : "")
        if !dirty { state.stringValue = service.loadError ?? selected.map { service.status($0.id, owner: sessionOwner, workspace: workspace) } ?? "暂无连接器"; state.toolTip = state.stringValue }
    }
    func textDidChange(_ notification: Notification) { dirty = true; refreshState(); state.stringValue = "未保存" }
    @objc private func create(_ sender: NSMenuItem) {
        guard job == nil, let type = sender.representedObject as? String, ["stdio", "http", "sse"].contains(type), canLeave() else { return }
        do { loadDraft(try service.document(type == "stdio" ? nil : AgentMCPServer(name: "新的连接器", type: type))) }
        catch { state.stringValue = error.localizedDescription }
    }
    private func loadDraft(_ document: String) {
        selected = nil; creating = true; dirty = true; select(nil); tools.string = ""; editor.string = document
        configurationKind.selectedSegment = 0; prepareConfiguration()
        editor.undoManager?.removeAllActions(); tabs.selectTabViewItem(at: 0); editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        refreshState(); state.stringValue = "待保存"; showDetail(); focusDetail()
    }
    @objc private func saveConfig() {
        do {
            if configurationKind.selectedSegment == 0, let form { editor.string = try form.document() }
            if let object = try? JSONSerialization.jsonObject(with: Data(editor.string.utf8)) as? [String: Any], object["mcpServers"] != nil { try reviewImport(document: editor.string); return }
            let server = try service.save(editor.string, id: selected?.id, expectedRevision: selected?.revision, workspace: workspace); dirty = false; reload(server.id); state.stringValue = "已保存"
        }
        catch { state.stringValue = error.localizedDescription; state.toolTip = state.stringValue }
    }
    @objc private func toggleEnabled() {
        guard let selected else { return }
        do { try service.setEnabled(selected.id, enabled.state == .on, workspace: workspace); reload(selected.id) } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func start() {
        guard let selected, !dirty, job == nil else { return }
        job = Task { [weak self] in
            guard let self else { return }; defer { self.job = nil; self.refreshState() }
            do { _ = try await self.service.connect(selected.id, revision: selected.revision, owner: self.sessionOwner, workspace: self.workspace); self.showTools() }
            catch { self.state.stringValue = error.localizedDescription; self.listState.stringValue = error.localizedDescription }
        }; refreshState()
    }
    @objc private func stop() { job?.cancel(); if let selected { service.disconnect(owner: sessionOwner, serverID: selected.id) }; tools.string = ""; refreshState() }
    @objc private func removeConfig() {
        guard let selected else { return }
        let alert = AgentConfirmation(); alert.messageText = "移除“\(selected.name)”？"; alert.addButton(withTitle: "移除").hasDestructiveAction = true; alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try service.remove(selected.id, revision: selected.revision); dirty = false; reload() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func importJSON() {
        guard job == nil, let window = editorWindow, window.attachedSheet == nil, canLeave() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.reviewImport(url) }
            catch { self.state.stringValue = error.localizedDescription; self.listState.stringValue = error.localizedDescription }
        }
    }
    func reviewImport(_ url: URL) throws {
        guard job == nil else { throw PetError("请先等待连接操作完成") }
        let page = try AgentMCPImportPage(source: url)
        presentImport(page)
    }
    func reviewImport(document: String) throws {
        guard job == nil else { throw PetError("请先等待连接操作完成") }
        presentImport(try AgentMCPImportPage(document: document))
    }
    private func presentImport(_ page: AgentMCPImportPage) {
        page.onLoad = { [weak self] document in self?.loadDraft(document) }
        if let editingPage { editingPage.presentSettingsChild(page) } else { presentSettingsChild(page) }
    }
    private func canLeave() -> Bool {
        guard !dirty else { return AgentUnsavedChanges.discard("放弃未保存的配置？", discardTitle: "放弃") }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeave() }
    private func closeConnection() { job?.cancel(); service.disconnect(owner: sessionOwner); service.onChange = nil }
    override func settingsWillLeave() { closeConnection() }
    func windowWillClose(_ notification: Notification) { closeConnection(); if detailPage?.settingsHostWindow == nil { detailPage?.window?.close() } }
    func connectForSettingsCheck() async throws -> Int32? {
        guard CommandLine.arguments.contains("--settings-pages-check"), let selected else { throw PetError("仅用于设置页检查") }
        showDetail()
        _ = try await service.connect(selected.id, revision: selected.revision, owner: sessionOwner, workspace: workspace)
        showTools(); return await service.processID(selected.id, owner: sessionOwner)
    }
}

@MainActor private final class AgentMCPDetailPage: AgentSettingsPageController, NSWindowDelegate {
    var onCanLeave: (() -> Bool)?, onAppear: (() -> Void)?
    override var minimumSettingsContentHeight: CGFloat { 220 }
    override var usesInternalScrolling: Bool { true }
    init(content: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "连接器配置"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.contentView = content; window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onCanLeave?() ?? true }
    func windowDidBecomeKey(_ notification: Notification) { onAppear?() }
}

@MainActor private final class AgentMCPSettingsTable: NSTableView {
    var onOpen: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36, 76, 124].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty { onOpen?(); return }
        super.keyDown(with: event)
    }
}

@MainActor private final class AgentMCPSettingsRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawBackground(in dirtyRect: NSRect) { drawCard(AgentWorkbenchTheme.surface) }
    override func drawSelection(in dirtyRect: NSRect) { drawCard(AgentWorkbenchTheme.selection) }
    private func drawCard(_ color: NSColor) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 4), xRadius: 12, yRadius: 12)
        AgentThemeContext.resolve(color, in: self).setFill(); path.fill()
        AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: self).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
