import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentPluginWindow: AgentSettingsPageController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    private enum DetailTab: Int, Codable { case readme, components }
    private enum ReadmeMode: Int, Codable { case preview, source }
    private struct DetailRecovery: Codable {
        let instance: String, sourceHash: String, tab: DetailTab, component: String?
        let selectedVisible: Bool
        var listY: Double?, readme: AgentTextViewport?, rule: AgentTextViewport?
        var display: ReadmeMode?, preview: AgentMarkdownReader.ViewRecovery?
    }
    private struct Recovery: Codable {
        var version = 1
        var workspace: String?, selectedID: String?
        var project: Bool, query: String, showsDetail: Bool
        var detail: DetailRecovery?
    }
    private let store: AgentStore, workspace: String?
    var loadMarketReviewCopy: ((String) async throws -> Data)?
    private let scopes = NSSegmentedControl(labels: ["用户", "项目"], trackingMode: .selectOne, target: nil, action: nil)
    private var scopeWorkspace: String? { scopes.selectedSegment == 1 ? workspace : nil }
    private let list = AgentSettingsCatalogTable(), components = NSTableView(), search = NSSearchField(), readme = NSTextView()
    private let title = NSTextField(labelWithString: ""), metadata = NSTextField(labelWithString: ""), state = AgentSettingsStatusField("插件状态")
    private var catalogLayout: (toolbar: NSStackView, actions: NSStackView, components: NSScrollView, document: NSScrollView, footer: NSStackView)?
    private var detailPage: AgentSettingsDetailPage?
    private let detailTabs = NSSegmentedControl(labels: ["说明", "组件"], trackingMode: .selectOne, target: nil, action: nil)
    private let readmeMode = NSSegmentedControl(labels: ["预览", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let readmePreview = AgentMarkdownReader(), previewSurface = AgentThemeView(fill: AgentWorkbenchTheme.card, stroke: AgentWorkbenchTheme.line)
    private var readmeFile: URL?
    private let ruleText = NSTextView()
    private lazy var ruleScroll = Self.documentScroll(ruleText, label: "插件规则正文")
    private var pendingDetail: DetailRecovery?
    private var applyingDetail = false
    private let catalogState = AgentSettingsStatusField("插件列表状态")
    private let enabled = NSButton(checkboxWithTitle: "启用插件", target: nil, action: nil), use = AgentDialogButton(title: "在任务中使用", target: nil, action: nil)
    private let upload = AgentDialogButton(title: "导入插件…", target: nil, action: nil)
    private let marketplace = AgentDialogButton(title: "插件市场", target: nil, action: nil)
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
    var makeComponentSettingsPage: ((String, String?, String?) -> AgentSettingsPageController?)? { didSet { updateControls() } }
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
        marketplace.target = self; marketplace.action = #selector(openMarketplace); AgentDialogStyle.action(marketplace)
        use.target = self; use.action = #selector(useComponent); AgentDialogStyle.action(use)
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshList))
        disableAll.target = self; disableAll.action = #selector(disableProject)
        more.addItem(withTitle: "更多"); more.setAccessibilityLabel("插件更多操作"); more.menu?.autoenablesItems = false
        for (item, action) in [(settings, #selector(openSettings)), (source, #selector(revealPackage)), (update, #selector(updatePackage)), (history, #selector(openHistory)), (remove, #selector(removePackage))] {
            item.target = self; item.action = action
        }
        for item in [settings, source, .separator(), update, history, .separator(), remove] { more.menu?.addItem(item) }
        moreFrame.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let header = NSStackView(views: [scopes, search, refresh, marketplace, upload]); header.spacing = 8
        var scrolls: [NSScrollView] = []
        for (table, label) in [(list, "插件列表"), (components, "插件组件")] {
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(label))); table.headerView = nil; table.delegate = self; table.dataSource = self; table.rowHeight = table === list ? 44 : 30; table.setAccessibilityLabel(label)
            let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scrolls.append(scroll)
        }
        title.font = .systemFont(ofSize: 18, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        for label in [metadata, state] { label.font = .systemFont(ofSize: 11); label.textColor = AgentWorkbenchTheme.secondaryText; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let document = Self.documentScroll(readme, label: "插件说明")
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
    private static func documentScroll(_ text: NSTextView, label: String) -> NSScrollView {
        text.isEditable = false
        text.isRichText = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel(label)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    override func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        if detailPage == nil, let content = window?.contentView, let layout = catalogLayout {
            AgentSettingsCatalog.detach(content)
            layout.footer.removeArrangedSubview(disableAll); disableAll.removeFromSuperview(); layout.toolbar.insertArrangedSubview(disableAll, at: max(0, layout.toolbar.arrangedSubviews.count - 1))
            search.setContentHuggingPriority(.defaultLow, for: .horizontal)
            layout.footer.removeArrangedSubview(state); state.removeFromSuperview()
            for view in [enabled, moreFrame, use] as [NSView] { layout.actions.removeArrangedSubview(view); view.removeFromSuperview() }
            detailTabs.selectedSegment = DetailTab.readme.rawValue
            detailTabs.target = self; detailTabs.action = #selector(changeDetailTab)
            detailTabs.setAccessibilityLabel("插件详情内容")
            readmeMode.selectedSegment = ReadmeMode.preview.rawValue
            readmeMode.target = self; readmeMode.action = #selector(changeDetailTab)
            readmeMode.setAccessibilityLabel("插件说明显示方式")
            let subtitle = NSStackView(views: [detailTabs, readmeMode, NSView(), metadata, enabled]); subtitle.spacing = 12; subtitle.alignment = .centerY
            subtitle.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            metadata.setContentHuggingPriority(.defaultLow, for: .horizontal)
            AgentSettingsStyle.primaryAction(use)
            let actions = AgentSettingsDetailActions([moreFrame, use])
            readmePreview.text.setAccessibilityLabel("插件说明预览")
            readmePreview.text.drawsBackground = false
            readmePreview.text.enclosingScrollView?.drawsBackground = false
            readmePreview.onViewportChange = { [weak self] in self?.detailViewportChanged() }
            readmePreview.onLink = { [weak self] url in self?.followReadmeLink(url) }
            previewSurface.layer?.cornerRadius = 12; previewSurface.layer?.borderWidth = 1
            previewSurface.addSubview(readmePreview); readmePreview.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                readmePreview.leadingAnchor.constraint(equalTo: previewSurface.leadingAnchor, constant: 1),
                readmePreview.trailingAnchor.constraint(equalTo: previewSurface.trailingAnchor, constant: -1),
                readmePreview.topAnchor.constraint(equalTo: previewSurface.topAnchor, constant: 4),
                readmePreview.bottomAnchor.constraint(equalTo: previewSurface.bottomAnchor, constant: -4)
            ])
            let detail = NSStackView(views: [subtitle, actions, layout.document, previewSurface, layout.components, ruleScroll, state])
            detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 8
            for view in detail.arrangedSubviews { view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
            NSLayoutConstraint.deactivate(layout.components.constraints.filter { $0.firstAttribute == .height && $0.secondItem == nil })
            let ruleHeight = ruleScroll.heightAnchor.constraint(equalToConstant: 140)
            ruleHeight.priority = .defaultHigh; ruleHeight.isActive = true
            for scroll in [layout.document, layout.components, ruleScroll] {
                scroll.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(detailViewportChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            }
            readme.delegate = self; ruleText.delegate = self
            let page = AgentSettingsDetailPage(title: "插件详情", content: AgentSettingsCatalog.detail(detail))
            page.detailActionRow = actions
            page.onAppear = { [weak self] in
                guard let self else { return }
                reload(select: selected?.id)
                focusDetail()
            }
            detailPage = page; catalogLayout = nil
            state.onChange = { [weak self] value in self?.catalogState.stringValue = value }; catalogState.stringValue = state.stringValue
            list.target = self; list.action = #selector(openSelectedPlugin); list.onOpen = { [weak self] in self?.showDetail() }
            list.groupName = { [weak self] _ in self?.scopeWorkspace == nil ? "用户插件" : "项目插件" }
            AgentSettingsStyle.primaryAction(upload)
            window?.contentView = AgentSettingsCatalog.content(table: list, toolbar: layout.toolbar, status: catalogState, actions: [marketplace, upload], symbol: "puzzlepiece.extension"); list.reloadData()
            updateDetailVisibility()
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
    func selectInstallation(_ id: String) throws {
        let target = try AgentPlugins.scope(id)
        guard target.workspace == nil || target.workspace == workspace else { throw PetError("插件项目已变化，请重新选择") }
        search.stringValue = ""
        scopes.selectedSegment = target.workspace == nil ? 0 : 1
        reload(select: id)
        guard selected?.id == id else { throw PetError("插件已移除或无法读取") }
        showDetail()
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
        else {
            pendingDetail?.rule = nil
            if detailPage != nil { updateDetailVisibility() }
            else if let index = selectedRuleIndex { readme.string = ruleBody(rules[index]) }
            else if let selected { readme.string = (try? service.readme(selected)) ?? "" }
            updateControls()
            detailViewportChanged()
        }
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
            if state.stringValue.isEmpty {
                if !service.warnings.isEmpty { state.stringValue = service.warnings.joined(separator: "；") }
                else if needsReview { state.stringValue = "需本机审阅后启用" }
                else if detailPage == nil { state.stringValue = "\(items.count) 项" }
            }
        } catch { state.stringValue = error.localizedDescription }; updateControls()
    }
    private func open(_ row: Int) {
        let next = items.indices.contains(row) ? items[row] : nil
        let sameSource = next != nil && selected?.instanceID == next?.instanceID && selected?.receipt.sourceHash == next?.receipt.sourceHash
        let previousComponent = sameSource ? componentID : nil
        let previousY = sameSource ? componentY : 0
        if !sameSource {
            pendingDetail = nil
            detailTabs.selectedSegment = DetailTab.readme.rawValue
            readmeMode.selectedSegment = ReadmeMode.preview.rawValue
            readmePreview.clear()
            ruleText.string = ""
        }
        selected = next; entries = []; connectors = []; agents = []; hooks = []; rules = []
        title.stringValue = ""; metadata.stringValue = ""; enabled.state = .off
        state.stringValue = ""
        var body = ""
        readmeFile = nil
        detailPage?.detailHeading = selected.map { item in
            let scope = item.workspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "用户插件"
            return .init(title: item.metadata.title, scope: scope, location: item.root.path)
        }
        if let item = selected {
            title.stringValue = item.metadata.title; metadata.stringValue = [item.metadata.version, item.metadata.author, item.receipt.sourceName].filter { !$0.isEmpty }.joined(separator: " · "); enabled.state = item.enabled ? .on : .off
            do {
                (body, readmeFile) = try service.readmeSource(item)
                entries = try service.extensionItems(workspace: item.workspace, onlyScope: true).filter { $0.pluginName == item.id }
                connectors = store.mcp.availableServers(workspace: item.workspace, onlyScope: true).filter { $0.plugin?.name == item.id }
                agents = try store.agents.packagedProfiles(workspace: item.workspace, onlyScope: true).filter { $0.pluginSource?.name == item.id }
                hooks = try store.hooks.catalog(workspace: item.workspace).filter { $0.plugin?.name == item.id && $0.plugin?.installationID == item.instanceID }
                rules = try service.ruleItems(workspace: item.workspace, onlyScope: true).filter { $0.reference.name == item.id && $0.reference.installationID == item.instanceID }
            } catch { state.stringValue = error.localizedDescription }
        }
        if detailPage != nil, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body = "暂无说明" }
        setBody(body, in: readme)
        components.delegate = nil
        components.reloadData()
        let selectedRow = previousComponent.flatMap { componentIDs.firstIndex(of: $0) } ?? (sameSource && detailPage != nil ? -1 : 0)
        selectComponent(selectedRow)
        components.delegate = self
        if let scroll = components.enclosingScrollView { AgentSettingsRecovery.restoreScroll(previousY, to: scroll) }
        updateDetailVisibility()
        updateControls()
    }
    private var selectedRuleIndex: Int? { let index = components.selectedRow - entries.count - connectors.count - agents.count - hooks.count; return rules.indices.contains(index) ? index : nil }
    private func ruleBody(_ item: AgentPluginRuleItem) -> String {
        item.definition.trigger.title + (item.definition.patterns.isEmpty ? "" : " · " + item.definition.patterns.joined(separator: ", ")) + "\n" + item.source.path + "\n\n" + item.definition.body
    }
    private var detailTab: DetailTab { DetailTab(rawValue: detailTabs.selectedSegment) ?? .readme }
    private var showsReadmePreview: Bool { readmeFile != nil && readmeMode.selectedSegment == ReadmeMode.preview.rawValue }
    private var componentIDs: [String] {
        entries.map { "extension:" + $0.id } + connectors.map { "mcp:" + $0.id }
            + agents.map { "agent:" + $0.id } + hooks.map { "hook:" + $0.id } + rules.map { "rule:" + $0.id }
    }
    private var componentID: String? {
        let ids = componentIDs
        return ids.indices.contains(components.selectedRow) ? ids[components.selectedRow] : nil
    }
    private var componentY: Double { max(0, components.enclosingScrollView?.contentView.bounds.minY ?? 0) }
    private func selectComponent(_ row: Int) {
        if row >= 0, row < components.numberOfRows { components.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { components.deselectAll(nil) }
    }
    private func setBody(_ body: String, in text: NSTextView) {
        guard text.string != body else { return }
        text.string = body
        text.setSelectedRange(NSRange(location: 0, length: 0))
        if let scroll = text.enclosingScrollView { AgentSettingsRecovery.restoreScroll(0, to: scroll) }
    }
    private func updateDetailVisibility() {
        guard detailPage != nil else { return }
        let showsComponents = detailTab == .components
        let previewsReadme = !showsComponents && showsReadmePreview
        readmeMode.isHidden = showsComponents || readmeFile == nil
        readme.enclosingScrollView?.isHidden = showsComponents || previewsReadme
        previewSurface.isHidden = !previewsReadme
        if previewsReadme, detailPage?.isPageVisible == true, let readmeFile {
            readmePreview.show(readme.string, file: readmeFile, workspace: readmeFile.deletingLastPathComponent().path, reuseIfUnchanged: true)
        }
        components.enclosingScrollView?.isHidden = !showsComponents
        use.isHidden = !showsComponents
        let rule = selectedRuleIndex.map { ruleBody(rules[$0]) }
        ruleScroll.isHidden = !showsComponents || rule == nil
        setBody(rule ?? "", in: ruleText)
    }
    private func followReadmeLink(_ url: URL) {
        if ["https", "http"].contains(url.scheme?.lowercased()) { NSWorkspace.shared.open(url); return }
        guard url.isFileURL, let readmeFile,
              let files = try? AgentFiles(workspace: readmeFile.deletingLastPathComponent().path),
              let target = try? AgentMarkdownDocument.target(url, document: readmeFile, files: files) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
    @objc private func changeDetailTab() {
        updateDetailVisibility()
        focusDetail()
        detailViewportChanged()
    }
    @objc private func detailViewportChanged(_ notification: Notification? = nil) {
        if !applyingDetail, detailPage?.isPageVisible == true { onSettingsRecoveryChange?() }
    }
    func textViewDidChangeSelection(_ notification: Notification) { detailViewportChanged() }
    private func focusDetail() {
        guard let host = detailPage?.presentingWindow else { return }
        applyingDetail = true; defer { applyingDetail = false }
        host.contentView?.layoutSubtreeIfNeeded()
        if detailTab == .readme, showsReadmePreview {
            host.makeFirstResponder(readmePreview.text)
            if let position = pendingDetail?.preview {
                do { try readmePreview.restoreViewRecovery(position); pendingDetail?.preview = nil }
                catch { state.showSaveFailure(error) }
            }
        } else if detailTab == .readme {
            host.makeFirstResponder(readme)
            if let position = pendingDetail?.readme, position.apply(to: readme, focus: false) { pendingDetail?.readme = nil }
        } else {
            host.makeFirstResponder(components)
            if let value = pendingDetail, let y = value.listY, let scroll = components.enclosingScrollView {
                AgentSettingsRecovery.restoreScroll(y, to: scroll)
                if value.selectedVisible, components.selectedRow >= 0 { components.scrollRowToVisible(components.selectedRow) }
                pendingDetail?.listY = nil
            }
            if !ruleScroll.isHidden, let position = pendingDetail?.rule, position.apply(to: ruleText) { pendingDetail?.rule = nil }
        }
    }
    private func updateControls() {
        AgentSettingsStyle.listState(list, text: search.stringValue.isEmpty ? "暂无插件" : "未找到匹配插件")
        AgentSettingsStyle.listState(components, text: selected == nil ? "选择插件查看组件" : "暂无组件")
        let idle = job == nil; scopes.isEnabled = idle; scopes.setEnabled(workspace != nil, forSegment: 1); list.isEnabled = idle; search.isEnabled = idle; upload.isEnabled = idle; enabled.isEnabled = idle && selected != nil; remove.isEnabled = idle && selected != nil; source.isEnabled = idle && selected != nil
        marketplace.isEnabled = idle
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
        let hostedConfiguration = makeComponentSettingsPage != nil
        use.isEnabled = idle && (connector ? configurable && (hostedConfiguration || onConfigureMCP != nil)
            : agent ? configurable && (hostedConfiguration || onConfigureAgent != nil)
            : hook ? configurable && (hostedConfiguration || onConfigureHook != nil)
            : selectedRuleIndex != nil ? available && onInsertRule != nil
            : available && entries.indices.contains(components.selectedRow) && onInsert != nil)
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
        let showsDetail = detailPage?.settingsHostWindow != nil
        var detail: DetailRecovery?
        if showsDetail, let item = selected {
            let readmePosition = try pendingDetail?.readme ?? AgentTextViewport(readme)
            let rulePosition = try pendingDetail?.rule ?? (selectedRuleIndex == nil ? nil : AgentTextViewport(ruleText))
            let previewPosition = try pendingDetail?.preview ?? readmePreview.captureViewRecovery(source: readme.string)
            detail = DetailRecovery(instance: item.instanceID, sourceHash: item.receipt.sourceHash,
                tab: detailTab, component: componentID, selectedVisible: pendingDetail?.listY != nil
                    ? pendingDetail?.selectedVisible == true : AgentSettingsRecovery.selectionIsVisible(in: components),
                listY: pendingDetail?.listY ?? componentY, readme: readmePosition, rule: rulePosition,
                display: ReadmeMode(rawValue: readmeMode.selectedSegment), preview: previewPosition)
        }
        return try AgentSettingsRecovery.page("plugins", Recovery(workspace: workspace, selectedID: selected?.id,
            project: scopes.selectedSegment == 1, query: search.stringValue, showsDetail: showsDetail, detail: detail))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "plugins" else { throw PetError("设置草稿不属于插件") }
        let fields = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state),
            keys: ["version", "workspace", "selectedID", "project", "query", "showsDetail", "detail"])
        if let raw = fields["detail"], !(raw is NSNull) {
            let details = try AgentSettingsRecovery.object(raw, keys: ["instance", "sourceHash", "tab", "component", "selectedVisible", "listY", "readme", "rule", "display", "preview"])
            for key in ["readme", "rule"] {
                if let value = details[key], !(value is NSNull) { try AgentTextViewport.validateObject(value) }
            }
            if let value = details["preview"], !(value is NSNull) { try AgentMarkdownReader.ViewRecovery.validateObject(value) }
        }
        let recovery = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard recovery.version == 1, recovery.workspace == workspace, !recovery.project || workspace != nil else {
            throw PetError("原插件设置范围已变化，草稿已保留")
        }
        scopes.selectedSegment = recovery.project ? 1 : 0
        search.stringValue = recovery.query
        selected = nil
        reload(select: recovery.selectedID)
        if recovery.showsDetail {
            guard let item = selected, recovery.selectedID == item.id, detailPage != nil else { throw PetError("原插件暂不可用，草稿已保留") }
            if let detail = recovery.detail {
                guard AgentSettingsRecovery.validHash(detail.sourceHash), (1...128).contains(detail.instance.utf8.count),
                      detail.listY.map(AgentSettingsRecovery.validScroll) != false, (detail.component?.utf8.count ?? 0) <= 160,
                      detail.readme?.valid != false, detail.rule?.valid != false,
                      detail.preview?.valid != false, detail.preview?.editing != true, detail.preview?.editor == nil else { throw PetError("插件阅读位置无效，原记录已保留") }
                if detail.instance == item.instanceID, detail.sourceHash == item.receipt.sourceHash {
                    components.delegate = nil
                    selectComponent(detail.component.flatMap { componentIDs.firstIndex(of: $0) } ?? -1)
                    components.delegate = self
                    pendingDetail = detail
                    detailTabs.selectedSegment = detail.tab.rawValue
                    readmeMode.selectedSegment = (detail.display ?? (detail.readme == nil ? .preview : .source)).rawValue
                    updateDetailVisibility()
                    updateControls()
                }
            }
            showDetail()
        }
    }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        if page.kind == "plugin-market" { return makeMarketPage(workspace: scopeWorkspace) }
        if page.kind == "plugin-review" {
            let target = try AgentPluginReviewPage.recoveryTarget(page)
            guard target.workspace == scopeWorkspace else { throw PetError("原插件审阅范围已变化，记录已保留") }
            let review = makeReviewPage(operation: target.operation, workspace: target.workspace, draft: target)
            review.onReload = { [weak self] in
                guard let self else { throw PetError("插件页面已关闭，请重新打开") }
                return try await reloadReview(target)
            }
            return review
        }
        let componentPage = ["mcp", "agents", "hooks"].contains(page.kind)
        guard componentPage || ["plugin-settings", "plugin-history"].contains(page.kind) else { return nil }
        guard let selected, detailPage?.settingsHostWindow != nil else { throw PetError("原插件详情暂不可用，草稿已保留") }
        if componentPage {
            guard let child = makeComponentSettingsPage?(page.kind, selected.workspace, nil) else { throw PetError("原组件设置暂不可用，草稿已保留") }
            return child
        }
        if page.kind == "plugin-settings" { return makeSettingsEditor(selected) }
        return makeHistoryPage(try service.installation(selected.id))
    }
    @objc private func disableProject() {
        guard let workspace = scopeWorkspace else { return }
        do { let failures = try service.disableProject(workspace); reload(); state.stringValue = failures.isEmpty ? "已全部停用" : "已停用；\(failures.count)项来源需核对"; state.toolTip = failures.joined(separator: "\n"); onChange?() }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        do {
            if item.workspace != nil && enabled.state == .on { enabled.state = .off; try reviewProjectActivation(item); return }
            try service.setEnabled(item, enabled.state == .on); reload(select: item.id); onChange?() }
        catch { enabled.state = item.enabled ? .on : .off; state.stringValue = error.localizedDescription }
    }
    @objc private func useComponent() {
        if let index = selectedRuleIndex { do { try onInsertRule?(rules[index]); close() } catch { state.stringValue = error.localizedDescription }; return }
        let index = components.selectedRow - entries.count
        if connectors.indices.contains(index) { configureComponent("mcp", id: connectors[index].id, standalone: onConfigureMCP); return }
        let agent = index - connectors.count
        if agents.indices.contains(agent) { configureComponent("agents", id: agents[agent].id, standalone: onConfigureAgent); return }
        let hook = agent - agents.count
        if hooks.indices.contains(hook) { configureComponent("hooks", id: hooks[hook].id, standalone: onConfigureHook); return }
        guard entries.indices.contains(components.selectedRow), let onInsert else { return }
        do { let item = try store.extensions.item(entries[components.selectedRow].id, workspace: workspace); try onInsert(item); close() } catch { state.stringValue = error.localizedDescription }
    }
    private func configureComponent(_ kind: String, id: String, standalone: ((String, String?) -> Void)?) {
        if let child = makeComponentSettingsPage?(kind, selected?.workspace, id) { presentSettingsChild(child) }
        else { standalone?(id, selected?.workspace) }
    }
    @objc private func revealPackage() { if let item = selected { NSWorkspace.shared.activateFileViewerSelecting([item.root]) } }
    @objc private func openMarketplace() {
        guard job == nil else { return }
        presentSettingsChild(makeMarketPage(workspace: scopeWorkspace))
    }
    private func makeMarketPage(workspace: String?) -> AgentPluginMarketPage {
        let page = AgentPluginMarketPage(plugins: service, workspace: workspace)
        page.onReview = { [weak self, weak page] package, installed in
            guard let self, let page else { return }
            let copy = AgentWorkspaceRecovery.MarketReviewCopy(try service.marketReviewData(package))
            let target = AgentPluginReviewPage.DraftTarget(path: nil, workspace: workspace, name: package.metadata.name,
                title: package.metadata.title, sourceHash: package.receipt.sourceHash,
                installed: installed.map(AgentPluginReviewPage.InstallationTarget.init), marketCopyHash: copy.hash)
            let review = try makeReview(package, replacing: installed, restoring: false, installWorkspace: workspace, marketPage: page, draft: target)
            review.marketCopy = copy
            page.presentSettingsChild(review)
        }
        page.restoreReview = { [weak self, weak page] target in
            guard let self, let page else { throw PetError("插件市场已关闭") }
            let review = makeReviewPage(operation: target.operation, workspace: workspace, marketPage: page, draft: target)
            review.onReload = { [weak self] in
                guard let self else { throw PetError("插件市场已关闭，请重新打开") }
                return try await reloadMarketReview(target)
            }
            return review
        }
        return page
    }
    @objc private func importPackage() { choosePackage(replacing: nil) }
    @objc private func updatePackage() { if let selected { choosePackage(replacing: selected) } }
    private func choosePackage(replacing installed: AgentPluginInstallation?) {
        guard let window = presentingWindow else { return }; let targetWorkspace = installed?.workspace ?? scopeWorkspace; let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip, .folder]; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.prompt = "检查插件"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            state.stringValue = "读取插件…"; job = Task { [weak self] in
                guard let self else { return }; defer { job = nil; updateControls() }
                do {
                    try await reviewLocalPackage(url, replacing: installed, workspace: targetWorkspace)
                }
                catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
            }; updateControls()
        }
    }
    @discardableResult func reviewLocalPackage(_ url: URL, replacing installed: AgentPluginInstallation? = nil,
                                               workspace: String?) async throws -> AgentPluginReviewPage {
        let source = url.standardizedFileURL
        let package = try await service.inspect(source)
        try Task.checkCancellation()
        let item = try installed ?? service.catalog(workspace: workspace, onlyScope: true).first { $0.metadata.name == package.metadata.name }
        if let item, item.metadata.name != package.metadata.name { throw PetError("新包名称与所选插件不同，未更新") }
        let draft = AgentPluginReviewPage.DraftTarget(path: source.path, workspace: workspace, name: package.metadata.name,
            title: package.metadata.title, sourceHash: package.receipt.sourceHash, installed: item.map(AgentPluginReviewPage.InstallationTarget.init))
        let page = try makeReview(package, replacing: item, restoring: false, installWorkspace: workspace, draft: draft)
        presentSettingsChild(page)
        return page
    }
    @discardableResult func reviewProjectActivation(_ item: AgentPluginInstallation) throws -> AgentPluginReviewPage {
        let package = try service.reviewPackage(item)
        let draft = AgentPluginReviewPage.DraftTarget(path: nil, workspace: item.workspace, name: item.metadata.name,
            title: item.metadata.title, sourceHash: AgentExtensions.digest(package.files), installed: .init(item))
        let page = try makeReview(package, replacing: item, restoring: false, activating: true, draft: draft)
        presentSettingsChild(page)
        return page
    }
    private func reviewInstallation(_ binding: AgentPluginReviewPage.InstallationTarget, workspace: String?) throws -> AgentPluginInstallation {
        guard let item = try? service.installation(binding.id), item.workspace == workspace,
              AgentPluginReviewPage.InstallationTarget(item) == binding else {
            throw PetError("原插件或启用配置已变化。恢复原状态后可重新检查，或取消后重新审阅。")
        }
        return item
    }
    private func requireMarketScope(_ workspace: String?) throws {
        if let workspace, try AgentFiles(workspace: workspace).root.path != workspace {
            throw PetError("原项目位置已变化，请重新审阅")
        }
    }
    private func reloadMarketReview(_ target: AgentPluginReviewPage.DraftTarget) async throws -> AgentPluginReviewPage.Snapshot {
        guard let loadMarketReviewCopy, let hash = target.marketCopyHash else { throw PetError("缺少原市场插件审阅副本") }
        let data = try await loadMarketReviewCopy(hash)
        try Task.checkCancellation()
        try requireMarketScope(target.workspace)
        let package = try service.marketReviewPackage(data)
        guard package.metadata.name == target.name, package.metadata.title == target.title, package.receipt.sourceHash == target.sourceHash else {
            throw PetError("原市场插件包与审阅记录不一致")
        }
        let installed = try target.installed.map { try reviewInstallation($0, workspace: target.workspace) }
        if installed == nil, try service.catalog(workspace: target.workspace, onlyScope: true).contains(where: { $0.metadata.name == target.name }) {
            throw PetError("原安装位置已有同名插件，请重新审阅")
        }
        let oldFiles = try installed.map { try service.reviewPackage($0).files } ?? [:]
        return .init(package: package, installed: installed, oldFiles: oldFiles)
    }
    private func reloadReview(_ target: AgentPluginReviewPage.DraftTarget) async throws -> AgentPluginReviewPage.Snapshot {
        if let path = target.path {
            let package: AgentPluginPackage
            do { package = try await service.inspect(URL(fileURLWithPath: path)) }
            catch {
                try Task.checkCancellation()
                throw PetError("来源插件暂不可读。恢复原文件后可重新检查。")
            }
            guard package.metadata.name == target.name, package.receipt.sourceHash == target.sourceHash else {
                throw PetError("来源插件已变化。恢复原文件后可重新检查，或取消后重新审阅。")
            }
            let installed = try target.installed.map { try reviewInstallation($0, workspace: target.workspace) }
            if installed == nil, try service.catalog(workspace: target.workspace, onlyScope: true).contains(where: { $0.metadata.name == target.name }) {
                throw PetError("目标范围已有同名插件。请取消后重新审阅。")
            }
            let old = try installed.map { try service.reviewPackage($0).files } ?? [:]
            return .init(package: package, installed: installed, oldFiles: old)
        }
        guard let binding = target.installed else { throw PetError("原插件审阅记录无效") }
        let installed = try reviewInstallation(binding, workspace: target.workspace)
        let package = try service.reviewPackage(installed)
        guard package.metadata.name == target.name, AgentExtensions.digest(package.files) == target.sourceHash else { throw PetError("来源插件已变化，请重新审阅。") }
        return .init(package: package, installed: installed, oldFiles: package.files)
    }
    @objc private func openHistory() {
        guard let selected, job == nil else { return }
        do {
            let page = makeHistoryPage(try service.installation(selected.id))
            if let detailPage, detailPage.isPageVisible { detailPage.presentSettingsChild(page) }
            else { presentSettingsChild(page) }
        } catch { state.showSaveFailure(error) }
    }
    private func makeHistoryPage(_ item: AgentPluginInstallation) -> AgentPluginHistoryPage {
        let page = AgentPluginHistoryPage(item: item)
        page.makeReview = { [weak self, weak page] revision in
            guard let self, let page else { throw PetError("插件历史已关闭，请重新打开") }
            let current = page.item, package = try service.package(revision, of: current)
            return try makeReview(package, replacing: current, restoring: true, historyPage: page, revision: revision)
        }
        return page
    }
    func review(_ package: AgentPluginPackage, replacing installed: AgentPluginInstallation? = nil, restoring: Bool = false, activating: Bool = false, installWorkspace: String? = nil) {
        presentReview(package, replacing: installed, restoring: restoring, activating: activating, installWorkspace: installWorkspace)
    }
    private func presentReview(_ package: AgentPluginPackage, replacing installed: AgentPluginInstallation?, restoring: Bool,
                               activating: Bool = false, installWorkspace: String?) {
        do {
            let page = try makeReview(package, replacing: installed, restoring: restoring, activating: activating,
                                      installWorkspace: installWorkspace)
            presentSettingsChild(page)
        } catch { state.showSaveFailure(error) }
    }
    private func makeReview(_ package: AgentPluginPackage, replacing installed: AgentPluginInstallation?, restoring: Bool,
                            activating: Bool = false, installWorkspace: String? = nil, historyPage: AgentPluginHistoryPage? = nil,
                            revision: AgentPluginRevision? = nil, marketPage: AgentPluginMarketPage? = nil,
                            draft: AgentPluginReviewPage.DraftTarget? = nil) throws -> AgentPluginReviewPage {
        let old = try installed.map { try service.reviewPackage($0).files } ?? [:]
        let historyTarget = installed.flatMap { current in revision.map { AgentPluginReviewPage.HistoryTarget(receiptHash: current.receiptHash, revision: $0.directory) } }
        let operation: AgentPluginReviewPage.Operation = activating ? .activate : restoring ? .restore : installed == nil ? .install : .update
        let page = makeReviewPage(operation: operation, workspace: installed?.workspace ?? installWorkspace,
            historyTarget: historyTarget, historyPage: historyPage, revision: revision, marketPage: marketPage, draft: draft)
        page.display(.init(package: package, installed: installed, oldFiles: old))
        return page
    }
    private func makeReviewPage(operation: AgentPluginReviewPage.Operation, workspace: String?,
                                historyTarget: AgentPluginReviewPage.HistoryTarget? = nil, historyPage: AgentPluginHistoryPage? = nil,
                                revision: AgentPluginRevision? = nil, marketPage: AgentPluginMarketPage? = nil,
                                draft: AgentPluginReviewPage.DraftTarget? = nil) -> AgentPluginReviewPage {
        let page = AgentPluginReviewPage(operation: operation, workspace: workspace, protectedData: service.profile, historyTarget: historyTarget, draftTarget: draft)
        page.onApply = { [weak self] snapshot in
            guard let self else { throw PetError("插件页面已关闭，请重新打开") }
            if draft?.marketCopyHash != nil { try requireMarketScope(workspace) }
            if let binding = draft?.installed { _ = try reviewInstallation(binding, workspace: workspace) }
            if let installed = snapshot.installed {
                if operation == .activate { try service.setEnabled(installed, true); return try service.installation(installed.id) }
                if let revision { _ = try service.revision(revision, of: installed) }
                return try service.update(snapshot.package, replacing: installed)
            }
            return try service.install(snapshot.package, workspace: workspace)
        }
        page.onApplied = { [weak self, weak historyPage, weak marketPage] item in
            guard let self else { return }
            search.stringValue = ""; reload(select: item.id); state.stringValue = "已" + operation.title + (operation.comparesVersions ? "，已停用" : ""); onChange?()
            if let marketPage { marketPage.didApply(item, updating: operation == .update) }
            else if let historyPage { historyPage.didRestore(item) }
            else if detailPage?.isPageVisible == true { focusDetail() }
            else { presentingWindow?.makeFirstResponder(list) }
        }
        return page
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
    private struct Recovery: Codable {
        var version = 1
        let plugin: String, receiptHash: String, revision: String?, y: Double
        let selectedVisible: Bool?
    }
    private let table = AgentSettingsCatalogTable(), status = AgentSettingsStatusField("插件历史状态")
    private var revisions: [AgentPluginRevision] = []
    private var pendingRecovery: Recovery?
    private(set) var item: AgentPluginInstallation
    var makeReview: ((AgentPluginRevision) throws -> AgentPluginReviewPage)?
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
        if let clip = table.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        refresh(item)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var selectedRevision: AgentPluginRevision? {
        revisions.indices.contains(table.selectedRow) ? revisions[table.selectedRow] : nil
    }
    override func settingsDidAppear() {
        super.settingsDidAppear(); presentingWindow?.makeFirstResponder(table)
        guard pendingRecovery != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, isPageVisible, let value = pendingRecovery, let scroll = table.enclosingScrollView else { return }
            presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            AgentSettingsRecovery.restoreScroll(value.y, to: scroll)
            if value.selectedVisible == true, table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
            pendingRecovery = nil; onSettingsRecoveryChange?()
        }
    }
    private func recoveryPosition() -> Recovery {
        Recovery(plugin: item.id, receiptHash: item.receiptHash, revision: selectedRevision?.directory,
            y: max(0, table.enclosingScrollView?.contentView.bounds.minY ?? 0), selectedVisible: AgentSettingsRecovery.selectionIsVisible(in: table))
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        try AgentSettingsRecovery.page("plugin-history", pendingRecovery ?? recoveryPosition())
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "plugin-history" else { throw PetError("设置记录不属于插件历史") }
        _ = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "plugin", "receiptHash", "revision", "y", "selectedVisible"])
        let value = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard value.version == 1, value.plugin == item.id, value.receiptHash == item.receiptHash, AgentSettingsRecovery.validScroll(value.y) else {
            throw PetError("当前插件版本已变化，请重新打开历史版本")
        }
        if let revision = value.revision {
            guard let row = revisions.firstIndex(where: { $0.directory == revision }) else { throw PetError("原历史版本已不可用，审阅记录已保留") }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        pendingRecovery = value
    }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        guard page.kind == "plugin-history-review" else { return nil }
        guard let selectedRevision, let makeReview else { throw PetError("原历史版本未选中，审阅记录已保留") }
        return try makeReview(selectedRevision)
    }

    private func refresh(_ item: AgentPluginInstallation) {
        self.item = item
        detailHeading = .init(title: "历史版本 · " + item.metadata.title, scope: "当前 " + (item.metadata.version.isEmpty ? "未标版本" : item.metadata.version), location: item.root.path)
        revisions = Array((item.receipt.revisions ?? []).reversed())
        table.reloadData(); AgentSettingsStyle.listState(table, text: "暂无历史版本")
    }
    func didRestore(_ item: AgentPluginInstallation) {
        let previous = selectedRevision
        pendingRecovery = nil
        refresh(item)
        if let previous, let row = revisions.firstIndex(of: previous) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        status.stringValue = "已恢复，插件已停用"; presentingWindow?.makeFirstResponder(table); onSettingsRecoveryChange?()
    }
    func showFailure(_ error: Error) { status.showSaveFailure(error) }
    func tableViewSelectionDidChange(_ notification: Notification) { onSettingsRecoveryChange?() }
    @objc private func scrolled(_ notification: Notification) { if pendingRecovery == nil { onSettingsRecoveryChange?() } }
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
        guard let selectedRevision, let makeReview else { return }
        do {
            let review = try makeReview(selectedRevision)
            if settingsHostWindow != nil { pendingRecovery = recoveryPosition() }
            presentSettingsChild(review)
        }
        catch { showFailure(error) }
    }
}
