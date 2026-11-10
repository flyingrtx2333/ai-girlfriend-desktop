import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentPluginWindow: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: AgentStore, workspace: String?
    private let list = NSTableView(), components = NSTableView(), search = NSSearchField(), readme = NSTextView()
    private let title = NSTextField(labelWithString: ""), metadata = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: "")
    private let enabled = NSButton(checkboxWithTitle: "启用插件", target: nil, action: nil), use = NSButton(title: "在任务中使用", target: nil, action: nil)
    private let upload = NSButton(title: "导入插件…", target: nil, action: nil), remove = NSButton(title: "移除", target: nil, action: nil)
    private let source = NSButton(title: "打开来源", target: nil, action: nil)
    private var items: [AgentPluginInstallation] = [], selected: AgentPluginInstallation?, entries: [AgentExtensionItem] = [], job: Task<Void, Never>?
    private var connectors: [AgentMCPServer] = []
    private var agents: [AgentProfile] = []
    private var hooks: [AgentHookDefinition] = []
    var onInsert: ((AgentExtensionItem) throws -> Void)? { didSet { updateControls() } }
    var onConfigureMCP: ((String) -> Void)? { didSet { updateControls() } }
    var onConfigureAgent: ((String) -> Void)? { didSet { updateControls() } }
    var onConfigureHook: ((String) -> Void)? { didSet { updateControls() } }
    var onChange: (() -> Void)?
    private var service: AgentPlugins { store.extensions.plugins }
    init(store: AgentStore, workspace: String?) {
        self.store = store; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "插件"; window.minSize = NSSize(width: 740, height: 480); window.appearance = NSAppearance(named: .aqua); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self; let content = NSView(); window.contentView = content
        search.placeholderString = "搜索插件"; search.delegate = self
        upload.target = self; upload.action = #selector(importPackage); enabled.target = self; enabled.action = #selector(toggleEnabled); use.target = self; use.action = #selector(useComponent); remove.target = self; remove.action = #selector(removePackage)
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshList)); source.target = self; source.action = #selector(revealPackage)
        let header = NSStackView(views: [search, refresh, upload]); header.spacing = 8
        var scrolls: [NSScrollView] = []
        for (table, label) in [(list, "插件列表"), (components, "插件组件")] {
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(label))); table.headerView = nil; table.delegate = self; table.dataSource = self; table.rowHeight = table === list ? 44 : 30; table.setAccessibilityLabel(label)
            let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scrolls.append(scroll)
        }
        title.font = .systemFont(ofSize: 18, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        for label in [metadata, state] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        readme.isEditable = false; readme.isRichText = false; readme.isSelectable = true; readme.font = .systemFont(ofSize: 12); readme.textContainerInset = NSSize(width: 12, height: 12); readme.isVerticallyResizable = true; readme.autoresizingMask = [.width]; readme.textContainer?.widthTracksTextView = true; readme.setAccessibilityLabel("插件说明")
        let document = NSScrollView(); document.documentView = readme; document.hasVerticalScroller = true; document.borderType = .bezelBorder
        let actions = NSStackView(views: [enabled, NSView(), use]); actions.spacing = 8
        let footer = NSStackView(views: [state, NSView(), source, remove]); footer.spacing = 8
        for view in [header, scrolls[0], title, metadata, actions, scrolls[1], document, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.heightAnchor.constraint(equalToConstant: 28),
            scrolls[0].leadingAnchor.constraint(equalTo: header.leadingAnchor), scrolls[0].topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), scrolls[0].widthAnchor.constraint(equalToConstant: 210), scrolls[0].bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            title.leadingAnchor.constraint(equalTo: scrolls[0].trailingAnchor, constant: 16), title.trailingAnchor.constraint(equalTo: header.trailingAnchor), title.topAnchor.constraint(equalTo: scrolls[0].topAnchor), title.heightAnchor.constraint(equalToConstant: 26),
            metadata.leadingAnchor.constraint(equalTo: title.leadingAnchor), metadata.trailingAnchor.constraint(equalTo: title.trailingAnchor), metadata.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6), metadata.heightAnchor.constraint(equalToConstant: 18),
            actions.leadingAnchor.constraint(equalTo: title.leadingAnchor), actions.trailingAnchor.constraint(equalTo: title.trailingAnchor), actions.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 10), actions.heightAnchor.constraint(equalToConstant: 28),
            scrolls[1].leadingAnchor.constraint(equalTo: title.leadingAnchor), scrolls[1].trailingAnchor.constraint(equalTo: title.trailingAnchor), scrolls[1].topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 10), scrolls[1].heightAnchor.constraint(equalToConstant: 130),
            document.leadingAnchor.constraint(equalTo: title.leadingAnchor), document.trailingAnchor.constraint(equalTo: title.trailingAnchor), document.topAnchor.constraint(equalTo: scrolls[1].bottomAnchor, constant: 12), document.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), footer.heightAnchor.constraint(equalToConstant: 28)
        ]); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === list ? items.count : entries.count + connectors.count + agents.count + hooks.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        if tableView === list, items.indices.contains(row) { let item = items[row]; label.stringValue = (item.receipt.enabled ? "● " : "○ ") + item.metadata.title; label.toolTip = item.id }
        else if entries.indices.contains(row) { let item = entries[row]; label.stringValue = (item.kind == .skill ? "Skill · " : "命令 · ") + item.name; label.toolTip = "/" + item.invocation }
        else if tableView === components, connectors.indices.contains(row - entries.count) { let server = connectors[row - entries.count]; label.stringValue = "MCP · " + server.name; label.toolTip = server.destination }
        else if tableView === components, agents.indices.contains(row - entries.count - connectors.count) { let agent = agents[row - entries.count - connectors.count]; label.stringValue = "Agent · " + agent.name; label.toolTip = agent.description }
        else if tableView === components, hooks.indices.contains(row - entries.count - connectors.count - agents.count) { let hook = hooks[row - entries.count - connectors.count - agents.count]; label.stringValue = "Hook · " + hook.name; label.toolTip = hook.event.rawValue }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === list { open(list.selectedRow) }; updateControls()
    }
    func controlTextDidChange(_ notification: Notification) { reload() }
    @objc private func refreshList() { reload() }
    private func reload(select id: String? = nil) {
        do {
            let all = try service.catalog(), query = search.stringValue
            items = all.filter { query.isEmpty || $0.metadata.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) || $0.metadata.description.localizedCaseInsensitiveContains(query) }
            list.delegate = nil; list.reloadData(); let row = items.firstIndex(where: { $0.id == (id ?? selected?.id) }) ?? (items.isEmpty ? -1 : 0)
            if row >= 0 { list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { list.deselectAll(nil) }; list.delegate = self; open(row)
            state.stringValue = service.warnings.isEmpty ? (items.isEmpty ? "暂无插件" : "\(items.count) 项") : service.warnings.joined(separator: "；"); state.toolTip = state.stringValue
        } catch { state.stringValue = error.localizedDescription }; updateControls()
    }
    private func open(_ row: Int) {
        selected = items.indices.contains(row) ? items[row] : nil; entries = []; connectors = []; agents = []; hooks = []; title.stringValue = ""; metadata.stringValue = ""; readme.string = ""; enabled.state = .off
        if let item = selected {
            title.stringValue = item.metadata.title; metadata.stringValue = [item.metadata.version, item.metadata.author, item.receipt.sourceName].filter { !$0.isEmpty }.joined(separator: " · "); enabled.state = item.receipt.enabled ? .on : .off
            do { readme.string = try service.readme(item); entries = try store.extensions.catalog(workspace: workspace).filter { $0.pluginName == item.id }; connectors = store.mcp.servers.filter { $0.plugin?.name == item.id }; agents = try store.agents.packagedProfiles().filter { $0.pluginSource?.name == item.id }; hooks = try store.hooks.catalog(workspace: workspace).filter { $0.plugin?.name == item.id && $0.plugin?.installationID == item.instanceID } } catch { state.stringValue = error.localizedDescription }
        }
        components.reloadData(); if !entries.isEmpty || !connectors.isEmpty || !agents.isEmpty || !hooks.isEmpty { components.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; updateControls()
    }
    private func updateControls() {
        let idle = job == nil; list.isEnabled = idle; search.isEnabled = idle; upload.isEnabled = idle; enabled.isEnabled = idle && selected != nil; remove.isEnabled = idle && selected != nil; source.isEnabled = idle && selected != nil
        let connector = connectors.indices.contains(components.selectedRow - entries.count)
        let agent = agents.indices.contains(components.selectedRow - entries.count - connectors.count)
        let hook = hooks.indices.contains(components.selectedRow - entries.count - connectors.count - agents.count)
        use.title = connector ? "配置连接器" : agent ? "配置 Agent" : hook ? "配置 Hooks" : "在任务中使用"
        use.isEnabled = idle && (connector ? onConfigureMCP != nil : agent ? onConfigureAgent != nil : hook ? onConfigureHook != nil : selected?.receipt.enabled == true && entries.indices.contains(components.selectedRow) && onInsert != nil)
    }
    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        do { try service.setEnabled(item, enabled.state == .on); reload(select: item.id); onChange?() }
        catch { enabled.state = item.receipt.enabled ? .on : .off; state.stringValue = error.localizedDescription }
    }
    @objc private func useComponent() {
        let index = components.selectedRow - entries.count
        if connectors.indices.contains(index) { onConfigureMCP?(connectors[index].id); return }
        let agent = index - connectors.count
        if agents.indices.contains(agent) { onConfigureAgent?(agents[agent].id); return }
        let hook = agent - agents.count
        if hooks.indices.contains(hook) { onConfigureHook?(hooks[hook].id); return }
        guard entries.indices.contains(components.selectedRow), let onInsert else { return }
        do { let item = try store.extensions.item(entries[components.selectedRow].id, workspace: workspace); try onInsert(item); close() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func revealPackage() { if let item = selected { NSWorkspace.shared.activateFileViewerSelecting([item.root]) } }
    @objc private func importPackage() {
        guard let window else { return }; let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "检查插件"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            state.stringValue = "读取插件…"; job = Task { [weak self] in
                guard let self else { return }; defer { job = nil; updateControls() }
                do { let package = try await service.inspect(url); try Task.checkCancellation(); review(package) }
                catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
            }; updateControls()
        }
    }
    private func review(_ package: AgentPluginPackage) {
        guard let window else { return }; let alert = NSAlert(); alert.messageText = "安装「\(package.metadata.title)」？"; alert.informativeText = [package.metadata.version, package.metadata.author, package.receipt.sourceName].filter { !$0.isEmpty }.joined(separator: " · ")
        alert.addButton(withTitle: "安装"); alert.addButton(withTitle: "取消")
        var rows = package.receipt.components.map { ($0.kind == .skill ? "Skill · " : "命令 · ") + package.metadata.name + ":" + $0.name }
        rows += package.mcpServers.map { "MCP · " + package.metadata.name + ":" + $0.key + "\n" + $0.destination + ($0.fields.isEmpty ? "" : "\n" + $0.fields.joined(separator: ", ")) }
        rows += package.agents.map { "Agent · " + package.metadata.name + ":" + $0.key + "\n" + $0.summary + "\n\n" + $0.profile.instructions }
        for config in package.hooks { for hook in config.preview { rows.append("Hook · " + package.metadata.name + ":" + hook.name + "\n" + hook.event.rawValue + "\n" + hook.display) } }
        let text = NSTextView(); text.isEditable = false; text.font = .systemFont(ofSize: 12); text.string = rows.joined(separator: "\n\n"); text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel("待安装的插件组件")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: min(240, CGFloat(text.string.components(separatedBy: "\n").count * 24 + 18)))); scroll.documentView = text; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { let item = try service.install(package); search.stringValue = ""; reload(select: item.id); state.stringValue = "已安装"; onChange?() } catch { state.stringValue = error.localizedDescription }
        }
    }
    @objc private func removePackage() {
        guard let item = selected, let window else { return }; let alert = NSAlert(); alert.messageText = "移除「\(item.metadata.title)」？"; alert.informativeText = "插件会移到废纸篓，已有任务记录保留。"; alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try service.trash(item); selected = nil; reload(); onChange?() } catch { state.stringValue = error.localizedDescription }
        }
    }
    func windowWillClose(_ notification: Notification) { job?.cancel() }
}
