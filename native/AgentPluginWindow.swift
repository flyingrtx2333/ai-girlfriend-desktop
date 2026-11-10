import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentPluginWindow: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: AgentStore, workspace: String?
    private let list = NSTableView(), components = NSTableView(), search = NSSearchField(), readme = NSTextView()
    private let title = NSTextField(labelWithString: ""), metadata = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: "")
    private let enabled = NSButton(checkboxWithTitle: "启用插件", target: nil, action: nil), use = NSButton(title: "在任务中使用", target: nil, action: nil)
    private let upload = NSButton(title: "导入插件…", target: nil, action: nil), remove = NSButton(title: "移除", target: nil, action: nil)
    private let source = NSButton(title: "打开来源", target: nil, action: nil)
    private let update = NSButton(title: "更新插件…", target: nil, action: nil), history = NSPopUpButton(frame: .zero, pullsDown: true)
    private var items: [AgentPluginInstallation] = [], selected: AgentPluginInstallation?, entries: [AgentExtensionItem] = [], job: Task<Void, Never>?
    private var connectors: [AgentMCPServer] = []
    private var agents: [AgentProfile] = []
    private var hooks: [AgentHookDefinition] = []
    private var rules: [AgentPluginRuleItem] = []
    var onInsert: ((AgentExtensionItem) throws -> Void)? { didSet { updateControls() } }
    var onConfigureMCP: ((String) -> Void)? { didSet { updateControls() } }
    var onConfigureAgent: ((String) -> Void)? { didSet { updateControls() } }
    var onConfigureHook: ((String) -> Void)? { didSet { updateControls() } }
    var onInsertRule: ((AgentPluginRuleItem) throws -> Void)? { didSet { updateControls() } }
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
        update.target = self; update.action = #selector(updatePackage); history.target = self; history.action = #selector(restoreRevision); history.setAccessibilityLabel("插件历史版本")
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
        let footer = NSStackView(views: [state, NSView(), history, update, source, remove]); footer.spacing = 8
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
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === list ? items.count : entries.count + connectors.count + agents.count + hooks.count + rules.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        if tableView === list, items.indices.contains(row) { let item = items[row]; label.stringValue = (item.receipt.enabled ? "● " : "○ ") + item.metadata.title; label.toolTip = item.id }
        else if entries.indices.contains(row) { let item = entries[row]; label.stringValue = (item.kind == .skill ? "Skill · " : "命令 · ") + item.name; label.toolTip = "/" + item.invocation }
        else if tableView === components, connectors.indices.contains(row - entries.count) { let server = connectors[row - entries.count]; label.stringValue = "MCP · " + server.name; label.toolTip = server.destination }
        else if tableView === components, agents.indices.contains(row - entries.count - connectors.count) { let agent = agents[row - entries.count - connectors.count]; label.stringValue = "Agent · " + agent.name; label.toolTip = agent.description }
        else if tableView === components, hooks.indices.contains(row - entries.count - connectors.count - agents.count) { let hook = hooks[row - entries.count - connectors.count - agents.count]; label.stringValue = "Hook · " + hook.name; label.toolTip = hook.event.rawValue }
        else if tableView === components, rules.indices.contains(row - entries.count - connectors.count - agents.count - hooks.count) { let rule = rules[row - entries.count - connectors.count - agents.count - hooks.count]; label.stringValue = "规则 · " + rule.name; label.toolTip = "来自插件 · " + rule.definition.trigger.title }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === list { open(list.selectedRow) }
        else if let index = selectedRuleIndex { showRule(rules[index]) }
        else if let selected { readme.string = (try? service.readme(selected)) ?? "" }
        updateControls()
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
        selected = items.indices.contains(row) ? items[row] : nil; entries = []; connectors = []; agents = []; hooks = []; rules = []; title.stringValue = ""; metadata.stringValue = ""; readme.string = ""; enabled.state = .off
        if let item = selected {
            title.stringValue = item.metadata.title; metadata.stringValue = [item.metadata.version, item.metadata.author, item.receipt.sourceName].filter { !$0.isEmpty }.joined(separator: " · "); enabled.state = item.receipt.enabled ? .on : .off
            do { readme.string = try service.readme(item); entries = try store.extensions.catalog(workspace: workspace).filter { $0.pluginName == item.id }; connectors = store.mcp.servers.filter { $0.plugin?.name == item.id }; agents = try store.agents.packagedProfiles().filter { $0.pluginSource?.name == item.id }; hooks = try store.hooks.catalog(workspace: workspace).filter { $0.plugin?.name == item.id && $0.plugin?.installationID == item.instanceID }; rules = try service.ruleItems().filter { $0.reference.name == item.id && $0.reference.installationID == item.instanceID } } catch { state.stringValue = error.localizedDescription }
        }
        components.reloadData(); if numberOfRows(in: components) > 0 { components.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; updateControls()
        history.removeAllItems(); history.addItem(withTitle: "历史版本")
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        for revision in (selected?.receipt.revisions ?? []).reversed() {
            let item = NSMenuItem(title: (revision.version?.isEmpty == false ? revision.version! : "未标版本") + " · " + formatter.string(from: revision.created), action: nil, keyEquivalent: "")
            item.representedObject = revision.directory; item.toolTip = revision.sourceName; history.menu?.addItem(item)
        }
    }
    private var selectedRuleIndex: Int? { let index = components.selectedRow - entries.count - connectors.count - agents.count - hooks.count; return rules.indices.contains(index) ? index : nil }
    private func showRule(_ item: AgentPluginRuleItem) {
        readme.string = item.definition.trigger.title + (item.definition.patterns.isEmpty ? "" : " · " + item.definition.patterns.joined(separator: ", ")) + "\n" + item.source.path + "\n\n" + item.definition.body
    }
    private func updateControls() {
        let idle = job == nil; list.isEnabled = idle; search.isEnabled = idle; upload.isEnabled = idle; enabled.isEnabled = idle && selected != nil; remove.isEnabled = idle && selected != nil; source.isEnabled = idle && selected != nil
        update.isEnabled = idle && selected != nil; history.isEnabled = idle && selected?.receipt.revisions?.isEmpty == false
        let connector = connectors.indices.contains(components.selectedRow - entries.count)
        let agent = agents.indices.contains(components.selectedRow - entries.count - connectors.count)
        let hook = hooks.indices.contains(components.selectedRow - entries.count - connectors.count - agents.count)
        use.title = connector ? "配置连接器" : agent ? "配置 Agent" : hook ? "配置 Hooks" : "在任务中使用"
        use.isEnabled = idle && (connector ? onConfigureMCP != nil : agent ? onConfigureAgent != nil : hook ? onConfigureHook != nil : selectedRuleIndex != nil ? selected?.receipt.enabled == true && onInsertRule != nil : selected?.receipt.enabled == true && entries.indices.contains(components.selectedRow) && onInsert != nil)
    }
    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        do { try service.setEnabled(item, enabled.state == .on); reload(select: item.id); onChange?() }
        catch { enabled.state = item.receipt.enabled ? .on : .off; state.stringValue = error.localizedDescription }
    }
    @objc private func useComponent() {
        if let index = selectedRuleIndex { do { try onInsertRule?(rules[index]); close() } catch { state.stringValue = error.localizedDescription }; return }
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
    @objc private func importPackage() { choosePackage(replacing: nil) }
    @objc private func updatePackage() { if let selected { choosePackage(replacing: selected) } }
    private func choosePackage(replacing installed: AgentPluginInstallation?) {
        guard let window else { return }; let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "检查插件"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            state.stringValue = "读取插件…"; job = Task { [weak self] in
                guard let self else { return }; defer { job = nil; updateControls() }
                do {
                    let package = try await service.inspect(url); try Task.checkCancellation()
                    let target = try installed ?? service.catalog().first { $0.id == package.metadata.name }
                    if let target, target.id != package.metadata.name { throw PetError("新包名称与所选插件不同，未更新") }
                    review(package, replacing: target)
                }
                catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
            }; updateControls()
        }
    }
    @objc private func restoreRevision() {
        guard let selected, let directory = history.selectedItem?.representedObject as? String, let revision = selected.receipt.revisions?.first(where: { $0.directory == directory }) else { return }
        do { review(try service.package(revision, of: selected), replacing: selected, restoring: true) }
        catch { state.stringValue = error.localizedDescription }
    }
    private func review(_ package: AgentPluginPackage, replacing installed: AgentPluginInstallation? = nil, restoring: Bool = false) {
        guard let window else { return }; let alert = NSAlert(); let action = installed == nil ? "安装" : restoring ? "恢复" : "更新"
        alert.messageText = action + "「\(package.metadata.title)」？"
        let version = installed.map { ($0.metadata.version.isEmpty ? "未标版本" : $0.metadata.version) + " → " + (package.metadata.version.isEmpty ? "未标版本" : package.metadata.version) } ?? package.metadata.version
        alert.informativeText = [version, package.metadata.author, package.receipt.sourceName].filter { !$0.isEmpty }.joined(separator: " · ") + (installed == nil ? "" : "\n完成后停用；旧任务记录和本机配置保留，组件需重新选择及配置。")
        alert.addButton(withTitle: installed == nil ? "安装" : action + "并停用"); alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        var rows = package.receipt.components.map { ($0.kind == .skill ? "Skill · " : "命令 · ") + package.metadata.name + ":" + $0.name }
        rows += package.mcpServers.map { "MCP · " + package.metadata.name + ":" + $0.key + "\n" + $0.destination + ($0.fields.isEmpty ? "" : "\n" + $0.fields.joined(separator: ", ")) }
        rows += package.agents.map { "Agent · " + package.metadata.name + ":" + $0.key + "\n" + $0.summary + "\n\n" + $0.profile.instructions }
        for config in package.hooks { for hook in config.preview { rows.append("Hook · " + package.metadata.name + ":" + hook.name + "\n" + hook.event.rawValue + "\n" + hook.display) } }
        for rule in package.rules { rows.append("规则 · " + package.metadata.name + ":" + rule.key + "\n" + rule.trigger.title + (rule.patterns.isEmpty ? "" : " · " + rule.patterns.joined(separator: ", ")) + "\n\n" + rule.body) }
        if let installed {
            let old = installed.receipt.hashes, new = package.receipt.hashes
            let changes = Set(old.keys).union(new.keys).sorted().filter { old[$0] != new[$0] }
            rows.insert(changes.prefix(100).map { (old[$0] == nil ? "新增 · " : new[$0] == nil ? "移除 · " : "变更 · ") + $0 }.joined(separator: "\n") + (changes.count > 100 ? "\n另有\(changes.count - 100)项，完整内容保留在包内。" : ""), at: 0)
        }
        let text = NSTextView(); text.isEditable = false; text.font = .systemFont(ofSize: 12); text.string = rows.joined(separator: "\n\n"); text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel(installed == nil ? "待安装的插件组件" : "待更新的插件组件")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: min(240, CGFloat(text.string.components(separatedBy: "\n").count * 24 + 18)))); scroll.documentView = text; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; guard response == .alertFirstButtonReturn else { reload(select: installed?.id); return }
            do {
                let item: AgentPluginInstallation
                if let installed { item = try service.update(package, replacing: installed) } else { item = try service.install(package) }
                search.stringValue = ""; reload(select: item.id); state.stringValue = "已" + action + (installed == nil ? "" : "，已停用"); onChange?()
            } catch { state.stringValue = error.localizedDescription }
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
