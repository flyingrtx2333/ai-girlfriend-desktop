import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentPluginWindow: AgentSettingsPageController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate, NSWindowDelegate {
    private struct Recovery: Codable {
        var version = 1
        var workspace: String?, selectedID: String?
        var project: Bool, query: String, showsDetail: Bool
    }
    private let store: AgentStore, workspace: String?
    private let scopes = NSSegmentedControl(labels: ["用户", "项目"], trackingMode: .selectOne, target: nil, action: nil)
    private var scopeWorkspace: String? { scopes.selectedSegment == 1 ? workspace : nil }
    private let list = AgentSettingsCatalogTable(), components = NSTableView(), search = NSSearchField(), readme = NSTextView()
    private let title = NSTextField(labelWithString: ""), metadata = NSTextField(labelWithString: ""), state = AgentSettingsStatusField("插件状态")
    private var catalogLayout: (toolbar: NSStackView, actions: NSStackView, components: NSScrollView, document: NSScrollView, footer: NSStackView)?
    private var detailPage: AgentSettingsDetailPage?
    private var componentHeight: NSLayoutConstraint?
    private let catalogState = AgentSettingsStatusField("插件列表状态")
    private let enabled = NSButton(checkboxWithTitle: "启用插件", target: nil, action: nil), use = AgentDialogButton(title: "在任务中使用", target: nil, action: nil)
    private let upload = AgentDialogButton(title: "导入插件…", target: nil, action: nil)
    private let disableAll = NSButton(title: "全部停用", target: nil, action: nil)
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private lazy var moreFrame = AgentSettingsPopupFrame(more)
    private let settings = NSMenuItem(title: "启用设置", action: nil, keyEquivalent: "")
    private var settingsWindow: AgentPluginSettingsWindow?
    private let source = NSMenuItem(title: "打开来源", action: nil, keyEquivalent: "")
    private let update = NSMenuItem(title: "更新插件…", action: nil, keyEquivalent: "")
    private let remove = NSMenuItem(title: "移除", action: nil, keyEquivalent: "")
    private let history = NSMenuItem(title: "历史版本", action: nil, keyEquivalent: "")
    private var items: [AgentPluginInstallation] = [], selected: AgentPluginInstallation?, entries: [AgentExtensionItem] = [], job: Task<Void, Never>?
    private var connectors: [AgentMCPServer] = []
    private var agents: [AgentProfile] = []
    private var hooks: [AgentHookDefinition] = []
    private var rules: [AgentPluginRuleItem] = []
    var onInsert: ((AgentExtensionItem) throws -> Void)? { didSet { updateControls() } }
    var onConfigureMCP: ((String, String?) -> Void)? { didSet { updateControls() } }
    var onConfigureAgent: ((String, String?) -> Void)? { didSet { updateControls() } }
    var onConfigureHook: ((String, String?) -> Void)? { didSet { updateControls() } }
    var onInsertRule: ((AgentPluginRuleItem) throws -> Void)? { didSet { updateControls() } }
    var onChange: (() -> Void)?
    private var service: AgentPlugins { store.extensions.plugins }
    init(store: AgentStore, workspace: String?) {
        self.store = store; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "插件"; window.minSize = NSSize(width: 740, height: 480); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self; let content = NSView(); window.contentView = content
        scopes.selectedSegment = 0; scopes.target = self; scopes.action = #selector(changeScope); scopes.setEnabled(workspace != nil, forSegment: 1); scopes.setAccessibilityLabel("插件范围"); scopes.setToolTip(workspace, forSegment: 1)
        search.placeholderString = "搜索插件"; search.delegate = self
        upload.target = self; upload.action = #selector(importPackage); enabled.target = self; enabled.action = #selector(toggleEnabled)
        use.target = self; use.action = #selector(useComponent); AgentDialogStyle.action(use)
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshList))
        disableAll.target = self; disableAll.action = #selector(disableProject)
        more.addItem(withTitle: "更多"); more.setAccessibilityLabel("插件更多操作"); more.menu?.autoenablesItems = false
        for (item, action) in [(settings, #selector(openSettings)), (source, #selector(revealPackage)), (update, #selector(updatePackage)), (history, #selector(openHistory)), (remove, #selector(removePackage))] {
            item.target = self; item.action = action
        }
        for item in [settings, source, .separator(), update, history, .separator(), remove] { more.menu?.addItem(item) }
        moreFrame.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let header = NSStackView(views: [scopes, search, refresh, upload]); header.spacing = 8
        var scrolls: [NSScrollView] = []
        for (table, label) in [(list, "插件列表"), (components, "插件组件")] {
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(label))); table.headerView = nil; table.delegate = self; table.dataSource = self; table.rowHeight = table === list ? 44 : 30; table.setAccessibilityLabel(label)
            let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scrolls.append(scroll)
        }
        title.font = .systemFont(ofSize: 18, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        for label in [metadata, state] { label.font = .systemFont(ofSize: 11); label.textColor = AgentWorkbenchTheme.secondaryText; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        readme.isEditable = false; readme.isRichText = false; readme.isSelectable = true; readme.font = .systemFont(ofSize: 12); readme.textContainerInset = NSSize(width: 12, height: 12); readme.isVerticallyResizable = true; readme.autoresizingMask = [.width]; readme.textContainer?.widthTracksTextView = true; readme.setAccessibilityLabel("插件说明")
        let document = NSScrollView(); document.documentView = readme; document.hasVerticalScroller = true; document.borderType = .bezelBorder
        let actions = NSStackView(views: [enabled, NSView(), moreFrame, use]); actions.spacing = 8; actions.alignment = .centerY
        let footer = NSStackView(views: [state, NSView(), disableAll]); footer.spacing = 8
        catalogLayout = (header, actions, scrolls[1], document, footer)
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
    override func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        if detailPage == nil, let content = window?.contentView, let layout = catalogLayout {
            AgentSettingsCatalog.detach(content)
            layout.footer.removeArrangedSubview(disableAll); disableAll.removeFromSuperview(); layout.toolbar.insertArrangedSubview(disableAll, at: max(0, layout.toolbar.arrangedSubviews.count - 1))
            search.setContentHuggingPriority(.defaultLow, for: .horizontal)
            layout.footer.removeArrangedSubview(state); state.removeFromSuperview()
            for view in [enabled, moreFrame, use] as [NSView] { layout.actions.removeArrangedSubview(view); view.removeFromSuperview() }
            let subtitle = NSStackView(views: [enabled, metadata, NSView()]); subtitle.spacing = 12; subtitle.alignment = .centerY
            subtitle.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            metadata.setContentHuggingPriority(.defaultLow, for: .horizontal)
            AgentSettingsStyle.primaryAction(use)
            let actions = AgentSettingsDetailActions([moreFrame, use])
            let detail = NSStackView(views: [subtitle, actions, layout.components, layout.document, state]); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 8
            for view in detail.arrangedSubviews { view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
            NSLayoutConstraint.deactivate(layout.components.constraints.filter { $0.firstAttribute == .height && $0.secondItem == nil })
            componentHeight = layout.components.heightAnchor.constraint(equalToConstant: 60); componentHeight?.priority = .defaultHigh; componentHeight?.isActive = true
            NSLayoutConstraint.activate([layout.components.heightAnchor.constraint(greaterThanOrEqualToConstant: 44), layout.document.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)])
            let page = AgentSettingsDetailPage(title: "插件详情", content: AgentSettingsCatalog.detail(detail))
            page.detailActionRow = actions
            page.onAppear = { [weak self] in guard let self else { return }; reload(select: selected?.id); presentingWindow?.makeFirstResponder(components) }
            detailPage = page; catalogLayout = nil
            state.onChange = { [weak self] value in self?.catalogState.stringValue = value }; catalogState.stringValue = state.stringValue
            list.target = self; list.action = #selector(openSelectedPlugin); list.onOpen = { [weak self] in self?.showDetail() }
            list.groupName = { [weak self] _ in self?.scopeWorkspace == nil ? "用户插件" : "项目插件" }
            AgentSettingsStyle.primaryAction(upload)
            window?.contentView = AgentSettingsCatalog.content(table: list, toolbar: layout.toolbar, status: catalogState, actions: [upload], symbol: "puzzlepiece.extension"); list.reloadData()
        }
        return super.settingsContent(in: host, styled: styled)
    }
    override var usesInternalScrolling: Bool { detailPage != nil }
    override var minimumSettingsContentHeight: CGFloat { detailPage == nil ? super.minimumSettingsContentHeight : 220 }
    @objc private func openSelectedPlugin() { showDetail() }
    private func showDetail() {
        guard selected != nil, let detailPage else { return }
        if detailPage.settingsHostWindow == nil { presentSettingsChild(detailPage) } else { detailPage.settingsDidAppear() }
    }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        guard detailPage?.settingsHostWindow == nil else { return }
        reload(select: selected?.id); presentingWindow?.makeFirstResponder(list)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === list ? items.count : entries.count + connectors.count + agents.count + hooks.count + rules.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === list, detailPage != nil, items.indices.contains(row) {
            let item = items[row]
            return AgentSettingsCatalogCell(title: item.metadata.title, summary: item.metadata.description, symbol: "puzzlepiece.extension", status: item.enabled ? "已启用" : "已停用", group: list.group(at: row)) { [weak self] in
                guard let self, let index = items.firstIndex(where: { $0.id == item.id }) else { return }; open(index); showDetail()
            }
        }
        let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        if tableView === list, items.indices.contains(row) { let item = items[row]; label.stringValue = (item.enabled ? "● " : "○ ") + item.metadata.title; label.toolTip = item.metadata.name + (item.workspace.map { "\n" + $0 } ?? "") }
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
    func controlTextDidChange(_ notification: Notification) { reload(); onSettingsRecoveryChange?() }
    @objc private func refreshList() { reload() }
    @objc private func changeScope() {
        search.stringValue = ""; selected = nil
        window?.title = scopeWorkspace.map { "插件 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "插件"; reload(); onSettingsRecoveryChange?()
    }
    private func reload(select id: String? = nil) {
        do {
            let all = try service.catalog(workspace: scopeWorkspace, onlyScope: true), query = search.stringValue
            items = all.filter { query.isEmpty || $0.metadata.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) || $0.metadata.description.localizedCaseInsensitiveContains(query) }
            list.delegate = nil; list.reloadData(); let row = items.firstIndex(where: { $0.id == (id ?? selected?.id) }) ?? (items.isEmpty ? -1 : 0)
            if row >= 0 { list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { list.deselectAll(nil) }; list.delegate = self; open(row)
            let needsReview = selected?.workspace != nil && selected?.requestedEnabled == true && selected?.locallyApproved == false
            if !service.warnings.isEmpty { state.stringValue = service.warnings.joined(separator: "；") }
            else if needsReview { state.stringValue = "需本机审阅后启用" }
            else { state.stringValue = detailPage == nil ? "\(items.count) 项" : "" }
        } catch { state.stringValue = error.localizedDescription }; updateControls()
    }
    private func open(_ row: Int) {
        selected = items.indices.contains(row) ? items[row] : nil; entries = []; connectors = []; agents = []; hooks = []; rules = []; title.stringValue = ""; metadata.stringValue = ""; readme.string = ""; enabled.state = .off
        detailPage?.detailHeading = selected.map { item in
            let scope = item.workspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "用户插件"
            return .init(title: item.metadata.title, scope: scope, location: item.root.path)
        }
        if let item = selected {
            title.stringValue = item.metadata.title; metadata.stringValue = [item.metadata.version, item.metadata.author, item.receipt.sourceName].filter { !$0.isEmpty }.joined(separator: " · "); enabled.state = item.enabled ? .on : .off
            do { readme.string = try service.readme(item); entries = try service.extensionItems(workspace: item.workspace, onlyScope: true).filter { $0.pluginName == item.id }; connectors = store.mcp.availableServers(workspace: item.workspace, onlyScope: true).filter { $0.plugin?.name == item.id }; agents = try store.agents.packagedProfiles(workspace: item.workspace, onlyScope: true).filter { $0.pluginSource?.name == item.id }; hooks = try store.hooks.catalog(workspace: item.workspace).filter { $0.plugin?.name == item.id && $0.plugin?.installationID == item.instanceID }; rules = try service.ruleItems(workspace: item.workspace, onlyScope: true).filter { $0.reference.name == item.id && $0.reference.installationID == item.instanceID } } catch { state.stringValue = error.localizedDescription }
        }
        components.reloadData()
        componentHeight?.constant = components.numberOfRows == 0 ? 60 : min(120, max(44, components.rect(ofRow: components.numberOfRows - 1).maxY + 4))
        if numberOfRows(in: components) > 0 { components.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; updateControls()
    }
    private var selectedRuleIndex: Int? { let index = components.selectedRow - entries.count - connectors.count - agents.count - hooks.count; return rules.indices.contains(index) ? index : nil }
    private func showRule(_ item: AgentPluginRuleItem) {
        readme.string = item.definition.trigger.title + (item.definition.patterns.isEmpty ? "" : " · " + item.definition.patterns.joined(separator: ", ")) + "\n" + item.source.path + "\n\n" + item.definition.body
    }
    private func updateControls() {
        AgentSettingsStyle.listState(list, text: search.stringValue.isEmpty ? "暂无插件" : "未找到匹配插件")
        AgentSettingsStyle.listState(components, text: selected == nil ? "选择插件查看组件" : "暂无组件")
        let idle = job == nil; scopes.isEnabled = idle; scopes.setEnabled(workspace != nil, forSegment: 1); list.isEnabled = idle; search.isEnabled = idle; upload.isEnabled = idle; enabled.isEnabled = idle && selected != nil; remove.isEnabled = idle && selected != nil; source.isEnabled = idle && selected != nil
        disableAll.isHidden = scopeWorkspace == nil; disableAll.isEnabled = idle && service.hasProjectActivations(scopeWorkspace)
        settings.isEnabled = idle && selected != nil; more.isEnabled = idle && selected != nil
        (more.superview as? AgentSettingsPopupFrame)?.refreshEnabledState()
        update.isEnabled = idle && selected != nil; history.isEnabled = idle && selected != nil
        let connector = connectors.indices.contains(components.selectedRow - entries.count)
        let agent = agents.indices.contains(components.selectedRow - entries.count - connectors.count)
        let hook = hooks.indices.contains(components.selectedRow - entries.count - connectors.count - agents.count)
        use.title = connector ? "配置连接器" : agent ? "配置 Agent" : hook ? "配置 Hooks" : "在任务中使用"
        let available = selected.map { (try? service.requireScope($0.id, workspace: workspace)) != nil } ?? false
        let configurable = selected?.locallyReviewed != false
        use.isEnabled = idle && (connector ? configurable && onConfigureMCP != nil : agent ? configurable && onConfigureAgent != nil : hook ? configurable && onConfigureHook != nil : selectedRuleIndex != nil ? available && onInsertRule != nil : available && entries.indices.contains(components.selectedRow) && onInsert != nil)
    }
    @objc private func openSettings() {
        if let window = settingsWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        guard let selected else { return }
        presentSettingsChild(makeSettingsEditor(selected))
    }
    private func makeSettingsEditor(_ item: AgentPluginInstallation) -> AgentPluginSettingsWindow {
        let editor = AgentPluginSettingsWindow(service: service, item: item, workspace: workspace)
        editor.onChange = { [weak self] in self?.reload(select: item.id); self?.onChange?() }
        settingsWindow = editor
        return editor
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        try AgentSettingsRecovery.page("plugins", Recovery(workspace: workspace, selectedID: selected?.id,
            project: scopes.selectedSegment == 1, query: search.stringValue, showsDetail: detailPage?.settingsHostWindow != nil))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "plugins" else { throw PetError("设置草稿不属于插件") }
        _ = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state),
            keys: ["version", "workspace", "selectedID", "project", "query", "showsDetail"])
        let recovery = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard recovery.version == 1, recovery.workspace == workspace, !recovery.project || workspace != nil else {
            throw PetError("原插件设置范围已变化，草稿已保留")
        }
        scopes.selectedSegment = recovery.project ? 1 : 0
        search.stringValue = recovery.query
        selected = nil
        reload(select: recovery.selectedID)
        if recovery.showsDetail {
            guard let id = recovery.selectedID, selected?.id == id, detailPage != nil else { throw PetError("原插件暂不可用，草稿已保留") }
            showDetail()
        }
    }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        guard page.kind == "plugin-settings" else { return nil }
        guard let selected, detailPage?.settingsHostWindow != nil else { throw PetError("原插件详情暂不可用，草稿已保留") }
        return makeSettingsEditor(selected)
    }
    @objc private func disableProject() {
        guard let workspace = scopeWorkspace else { return }
        do { let failures = try service.disableProject(workspace); reload(); state.stringValue = failures.isEmpty ? "已全部停用" : "已停用；\(failures.count)项来源需核对"; state.toolTip = failures.joined(separator: "\n"); onChange?() }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        do {
            if item.workspace != nil && enabled.state == .on { enabled.state = .off; review(try service.reviewPackage(item), replacing: item, activating: true); return }
            try service.setEnabled(item, enabled.state == .on); reload(select: item.id); onChange?() }
        catch { enabled.state = item.enabled ? .on : .off; state.stringValue = error.localizedDescription }
    }
    @objc private func useComponent() {
        if let index = selectedRuleIndex { do { try onInsertRule?(rules[index]); close() } catch { state.stringValue = error.localizedDescription }; return }
        let index = components.selectedRow - entries.count
        if connectors.indices.contains(index) { onConfigureMCP?(connectors[index].id, selected?.workspace); return }
        let agent = index - connectors.count
        if agents.indices.contains(agent) { onConfigureAgent?(agents[agent].id, selected?.workspace); return }
        let hook = agent - agents.count
        if hooks.indices.contains(hook) { onConfigureHook?(hooks[hook].id, selected?.workspace); return }
        guard entries.indices.contains(components.selectedRow), let onInsert else { return }
        do { let item = try store.extensions.item(entries[components.selectedRow].id, workspace: workspace); try onInsert(item); close() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func revealPackage() { if let item = selected { NSWorkspace.shared.activateFileViewerSelecting([item.root]) } }
    @objc private func importPackage() { choosePackage(replacing: nil) }
    @objc private func updatePackage() { if let selected { choosePackage(replacing: selected) } }
    private func choosePackage(replacing installed: AgentPluginInstallation?) {
        guard let window = presentingWindow else { return }; let targetWorkspace = installed?.workspace ?? scopeWorkspace; let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip, .folder]; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.prompt = "检查插件"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            state.stringValue = "读取插件…"; job = Task { [weak self] in
                guard let self else { return }; defer { job = nil; updateControls() }
                do {
                    let package = try await service.inspect(url); try Task.checkCancellation()
                    let target = try installed ?? service.catalog(workspace: targetWorkspace, onlyScope: true).first { $0.metadata.name == package.metadata.name }
                    if let target, target.metadata.name != package.metadata.name { throw PetError("新包名称与所选插件不同，未更新") }
                    review(package, replacing: target, installWorkspace: targetWorkspace)
                }
                catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
            }; updateControls()
        }
    }
    @objc private func openHistory() {
        guard let selected, job == nil else { return }
        do {
            let page = AgentPluginHistoryPage(item: try service.installation(selected.id))
            page.onReview = { [weak self, weak page] revision in
                guard let self, let page else { return }
                do { review(try service.package(revision, of: page.item), replacing: page.item, restoring: true, historyPage: page) }
                catch { page.showFailure(error) }
            }
            if let detailPage, detailPage.isPageVisible { detailPage.presentSettingsChild(page) }
            else { presentSettingsChild(page) }
        } catch { state.showSaveFailure(error) }
    }
    func review(_ package: AgentPluginPackage, replacing installed: AgentPluginInstallation? = nil, restoring: Bool = false, activating: Bool = false, installWorkspace: String? = nil) {
        review(package, replacing: installed, restoring: restoring, activating: activating, installWorkspace: installWorkspace, historyPage: nil)
    }
    private func review(_ package: AgentPluginPackage, replacing installed: AgentPluginInstallation? = nil, restoring: Bool, activating: Bool = false, installWorkspace: String? = nil, historyPage: AgentPluginHistoryPage?) {
        do {
            let old = try installed.map { try service.reviewPackage($0).files } ?? [:]
            let page = AgentPluginReviewPage(package: package, installed: installed, oldFiles: old, restoring: restoring, activating: activating, workspace: installed?.workspace ?? installWorkspace)
            page.onApply = { [weak self] in
                guard let self else { throw PetError("插件页面已关闭，请重新打开") }
                if let installed, activating { try service.setEnabled(installed, true); return try service.installation(installed.id) }
                if let installed { return try service.update(package, replacing: installed) }
                return try service.install(package, workspace: installWorkspace)
            }
            page.onApplied = { [weak self, weak historyPage] item in
                guard let self else { return }
                let action = activating ? "启用" : installed == nil ? "安装" : restoring ? "恢复" : "更新"
                search.stringValue = ""; reload(select: item.id); state.stringValue = "已" + action + (installed == nil || activating ? "" : "，已停用"); onChange?(); presentingWindow?.makeFirstResponder(detailPage?.isPageVisible == true ? components : list)
                historyPage?.didRestore(item)
            }
            if let historyPage { historyPage.presentSettingsChild(page) } else { presentSettingsChild(page) }
        } catch {
            if let historyPage { historyPage.showFailure(error) } else { state.showSaveFailure(error) }
        }
    }
    @objc private func removePackage() {
        guard let item = selected, let window = presentingWindow else { return }; let alert = AgentConfirmation(); alert.messageText = "移除「\(item.metadata.title)」？"; alert.informativeText = "插件会移到废纸篓，已有任务记录保留。"; alert.addButton(withTitle: "移除").hasDestructiveAction = true; alert.addButton(withTitle: "取消")
        alert.beginModal(in: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try service.trash(item); selected = nil; reload(); onChange?() } catch { state.stringValue = error.localizedDescription }
        }
    }
    override func settingsWillLeave() { job?.cancel() }
    func windowWillClose(_ notification: Notification) { job?.cancel() }
}

@MainActor private final class AgentPluginHistoryPage: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = AgentSettingsCatalogTable(), status = AgentSettingsStatusField("插件历史状态")
    private var revisions: [AgentPluginRevision] = []
    private(set) var item: AgentPluginInstallation
    var onReview: ((AgentPluginRevision) -> Void)?
    override var usesInternalScrolling: Bool { true }
    override var minimumSettingsContentHeight: CGFloat { 220 }

    init(item: AgentPluginInstallation) {
        self.item = item
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "历史版本 · " + item.metadata.title; window.minSize = NSSize(width: 480, height: 350); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        table.addTableColumn(NSTableColumn(identifier: .init("revision"))); table.headerView = nil
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelection)
        table.setAccessibilityLabel("插件历史版本列表"); table.onOpen = { [weak self] in self?.openSelection() }
        window.contentView = AgentSettingsCatalog.content(table: table, toolbar: NSStackView(), status: status, symbol: "clock.arrow.circlepath")
        refresh(item)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refresh(_ item: AgentPluginInstallation) {
        self.item = item
        detailHeading = .init(title: "历史版本 · " + item.metadata.title, scope: "当前 " + (item.metadata.version.isEmpty ? "未标版本" : item.metadata.version), location: item.root.path)
        revisions = Array((item.receipt.revisions ?? []).reversed())
        table.reloadData(); AgentSettingsStyle.listState(table, text: "暂无历史版本")
    }
    func didRestore(_ item: AgentPluginInstallation) { refresh(item); status.stringValue = "已恢复，插件已停用" }
    func showFailure(_ error: Error) { status.showSaveFailure(error) }
    func numberOfRows(in tableView: NSTableView) -> Int { revisions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard revisions.indices.contains(row) else { return nil }
        let revision = revisions[row], version = revision.version.flatMap { $0.isEmpty ? nil : $0 } ?? "未标版本"
        let date = revision.created.formatted(date: .numeric, time: .shortened)
        let summary = [date, revision.sourceName ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return AgentSettingsCatalogCell(title: version, summary: summary, symbol: "clock.arrow.circlepath", status: "", group: table.group(at: row), actionLabel: "审阅版本 " + version) { [weak self] in
            guard let self, let currentRow = revisions.firstIndex(of: revision) else { return }
            table.selectRowIndexes(IndexSet(integer: currentRow), byExtendingSelection: false); openSelection()
        }
    }
    @objc private func openSelection() {
        let row = table.selectedRow
        if revisions.indices.contains(row) { onReview?(revisions[row]) }
    }
}
