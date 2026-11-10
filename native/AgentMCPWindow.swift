import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentMCPWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let service: AgentMCP, workspace: String?, sessionOwner = "manager-" + UUID().uuidString
    private let table = NSTableView(), editor = NSTextView(), tools = NSTextView()
    private let enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let connect = NSButton(title: "连接", target: nil, action: nil), disconnect = NSButton(title: "断开", target: nil, action: nil)
    private let save = NSButton(title: "保存", target: nil, action: nil), remove = NSButton(title: "移除", target: nil, action: nil)
    private let state = NSTextField(labelWithString: ""), access = NSTextField(labelWithString: "")
    var scopeWorkspace: String? { workspace }
    private var selected: AgentMCPServer?, dirty = false, creating = false, job: Task<Void, Never>?
    private var items: [AgentMCPServer] = []
    var onBrowseContent: ((String?) -> Void)? { didSet { browse.isHidden = onBrowseContent == nil } }
    private let browse = NSButton(title: "资料与提示词", target: nil, action: nil)
    init(service: AgentMCP, workspace: String?) {
        self.service = service; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MCP 连接器"; window.minSize = NSSize(width: 740, height: 520); window.center(); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let add = NSButton(title: "新建", target: self, action: #selector(create)), importButton = NSButton(title: "导入 JSON", target: self, action: #selector(importJSON))
        let actions = NSStackView(views: [add, importButton, NSView()]); actions.spacing = 8
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mcp"))); table.headerView = nil
        table.rowHeight = 46; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("MCP 连接器列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        editor.isRichText = false; editor.allowsUndo = true; editor.delegate = self; editor.isEditable = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = NSSize(width: 12, height: 12); editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.setAccessibilityLabel("MCP 配置 JSON")
        let configScroll = NSScrollView(); configScroll.documentView = editor; configScroll.hasVerticalScroller = true
        tools.isEditable = false; tools.isRichText = false; tools.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tools.textContainerInset = NSSize(width: 12, height: 12); tools.isVerticallyResizable = true; tools.autoresizingMask = [.width]; tools.textContainer?.widthTracksTextView = true; tools.setAccessibilityLabel("MCP 实际工具目录")
        let toolScroll = NSScrollView(); toolScroll.documentView = tools; toolScroll.hasVerticalScroller = true
        let tabs = NSTabView(); tabs.tabViewType = .topTabsBezelBorder
        for (label, view) in [("配置", configScroll), ("工具", toolScroll)] { let tab = NSTabViewItem(identifier: label); tab.label = label; tab.view = view; tabs.addTabViewItem(tab) }
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        for (button, action) in [(connect, #selector(start)), (disconnect, #selector(stop)), (save, #selector(saveConfig)), (remove, #selector(removeConfig))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let header = NSStackView(views: [enabled, state, NSView(), disconnect, connect]); header.spacing = 10
        browse.target = self; browse.action = #selector(browseContent); browse.isHidden = true
        let footer = NSStackView(views: [access, NSView(), browse, remove, save]); footer.spacing = 10
        for label in [state, access] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        for view in [list, actions, tabs, header, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), list.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), list.widthAnchor.constraint(equalToConstant: 210), list.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -10),
            actions.leadingAnchor.constraint(equalTo: list.leadingAnchor), actions.trailingAnchor.constraint(equalTo: list.trailingAnchor), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), actions.heightAnchor.constraint(equalToConstant: 28),
            header.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: list.topAnchor), header.heightAnchor.constraint(equalToConstant: 28),
            tabs.leadingAnchor.constraint(equalTo: header.leadingAnchor), tabs.trailingAnchor.constraint(equalTo: header.trailingAnchor), tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10), tabs.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: tabs.leadingAnchor), footer.trailingAnchor.constraint(equalTo: tabs.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        service.onChange = { [weak self] in self?.refreshCatalog() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func browseContent() { onBrowseContent?(selected?.id) }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let server = items[row], suffix = server.pluginEnabled == false ? " · 插件已停用" : server.configured == false ? " · 待配置" : server.enabled ? "" : " · 已停用"
        let name = NSTextField(labelWithString: server.name + suffix)
        name.font = .systemFont(ofSize: 12, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        let type = NSTextField(labelWithString: (server.type == "stdio" ? "本机程序" : "HTTP") + (server.plugin.map { " · 插件 " + ((try? AgentPlugins.scope($0.name).name) ?? "") } ?? "")); type.font = .systemFont(ofSize: 11); type.textColor = .secondaryLabelColor; type.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [name, type]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard items.indices.contains(table.selectedRow) else { return }
        if !canLeave() { select(selected?.id); return }; open(items[table.selectedRow])
    }
    func selectServer(_ id: String) { guard canLeave() else { return }; reload(id) }
    private func select(_ id: String?) { table.delegate = nil; if let row = items.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { table.deselectAll(nil) }; table.delegate = self }
    private func refreshCatalog() {
        let id = selected?.id; items = service.availableServers(workspace: workspace); table.delegate = nil; table.reloadData(); table.delegate = self; select(id)
        if !dirty, !creating { selected = items.first { $0.id == id }; if selected == nil { editor.string = ""; tools.string = "" } }
        refreshState()
    }
    private func reload(_ id: String? = nil) {
        items = service.availableServers(workspace: workspace); table.delegate = nil; table.reloadData(); table.delegate = self; let next = items.first { $0.id == (id ?? selected?.id) } ?? items.first
        select(next?.id); if let next { open(next) } else { selected = nil; creating = false; dirty = false; editor.string = ""; tools.string = ""; refreshState() }
    }
    private func open(_ server: AgentMCPServer) {
        do { editor.string = try service.document(server); selected = server; creating = false; dirty = false; tools.string = ""; editor.undoManager?.removeAllActions(); showTools(); refreshState() }
        catch { state.stringValue = error.localizedDescription }
    }
    private func showTools() {
        guard let selected, let token = service.token(selected.id, owner: sessionOwner) else { tools.string = ""; return }
        do {
            var offset = 0, rows: [[String: Any]] = []
            repeat { let page = try service.catalog(selected.id, owner: sessionOwner, token: token, offset: offset); rows += page["tools"] as? [[String: Any]] ?? []; offset = page["next_offset"] as? Int ?? -1 } while offset >= 0
            tools.string = String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        } catch { tools.string = error.localizedDescription }
    }
    private func refreshState() {
        let current = items.first { $0.id == selected?.id }
        let connected = selected.map { service.connected($0.id, owner: sessionOwner) } ?? false
        editor.isEditable = (creating || selected != nil) && job == nil
        enabled.isEnabled = current != nil && current?.configured != false && current?.pluginEnabled != false && !dirty && job == nil; enabled.state = current?.enabled == true ? .on : .off
        connect.isEnabled = current?.enabled == true && !dirty && job == nil && !connected
        disconnect.isEnabled = selected != nil && (connected || job != nil)
        remove.isEnabled = selected != nil && selected?.plugin == nil && job == nil; save.isEnabled = (dirty || selected?.configured == false) && job == nil; table.isEnabled = job == nil
        access.stringValue = (selected?.plugin.map { "插件 " + $0.name + " · " } ?? "") + (selected?.type == "http" ? "凭据保存在钥匙串" : "本机程序使用当前账户权限")
        if !dirty { state.stringValue = service.loadError ?? selected.map { service.status($0.id, owner: sessionOwner, workspace: workspace) } ?? "暂无连接器"; state.toolTip = state.stringValue }
    }
    func textDidChange(_ notification: Notification) { dirty = true; refreshState(); state.stringValue = "未保存" }
    @objc private func create() {
        guard canLeave() else { return }
        let alert = NSAlert(); alert.messageText = "新建 MCP 连接器"; alert.addButton(withTitle: "本机程序"); alert.addButton(withTitle: "HTTP"); alert.addButton(withTitle: "取消")
        let answer = alert.runModal(); guard answer != .alertThirdButtonReturn else { return }
        selected = nil; creating = true; dirty = true; select(nil); tools.string = ""
        let template = answer == .alertSecondButtonReturn ? AgentMCPServer(name: "新的连接器", type: "http") : nil
        editor.string = (try? service.document(template)) ?? ""; editor.undoManager?.removeAllActions(); refreshState(); state.stringValue = "未保存"
    }
    @objc private func saveConfig() {
        do { let server = try service.save(editor.string, id: selected?.id, expectedRevision: selected?.revision, workspace: workspace); dirty = false; reload(server.id); state.stringValue = "已保存" }
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
            catch { self.state.stringValue = error.localizedDescription; self.state.toolTip = self.state.stringValue }
        }; refreshState()
    }
    @objc private func stop() { job?.cancel(); if let selected { service.disconnect(owner: sessionOwner, serverID: selected.id) }; tools.string = ""; refreshState() }
    @objc private func removeConfig() {
        guard let selected else { return }
        let alert = NSAlert(); alert.messageText = "移除“\(selected.name)”？"; alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try service.remove(selected.id, revision: selected.revision); dirty = false; reload() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func importJSON() {
        guard canLeave(), job == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]); guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 64_000 else { throw PetError("配置文件需小于 64KB") }
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PetError("不是 JSON 对象") }
            if let servers = json["mcpServers"] as? [String: [String: Any]] {
                // Import one definition at a time into the editor; nothing is
                // launched or saved merely by opening a foreign config file.
                let names = servers.keys.sorted(); guard !names.isEmpty else { throw PetError("mcpServers 为空") }
                let choice = NSPopUpButton(); choice.addItems(withTitles: names)
                let alert = NSAlert(); alert.messageText = "选择连接器"; alert.accessoryView = choice; alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn, let name = choice.titleOfSelectedItem, var value = servers[name] else { return }
                value["name"] = name
                if value["url"] != nil { value["type"] = "http"; value["bearerToken"] = value["bearerToken"] ?? "" }
                else { value["type"] = "stdio"; value["args"] = value["args"] ?? []; value["env"] = value["env"] ?? [:] }
                if let command = value["command"] as? String, !command.hasPrefix("/"), !command.contains("/") {
                    value["command"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map { $0 + "/" + command }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? command
                }
                editor.string = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            } else { editor.string = String(decoding: data, as: UTF8.self) }
            selected = nil; creating = true; dirty = true; select(nil); tools.string = ""; refreshState(); state.stringValue = "待保存"
        } catch { state.stringValue = error.localizedDescription; state.toolTip = state.stringValue }
    }
    private func canLeave() -> Bool {
        guard !dirty else { let alert = NSAlert(); alert.messageText = "放弃未保存的配置？"; alert.addButton(withTitle: "放弃"); alert.addButton(withTitle: "继续编辑"); return alert.runModal() == .alertFirstButtonReturn }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeave() }
    func windowWillClose(_ notification: Notification) { job?.cancel(); service.disconnect(owner: sessionOwner); service.onChange = nil }
}
