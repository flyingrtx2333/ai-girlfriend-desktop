import AppKit

@MainActor final class AgentKnowledgeCardWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let store: AgentStore, taskID: String
    let search = AgentSettingsSidebarSearchField(), category = NSPopUpButton(), language = NSPopUpButton()
    let automatic = NSMenuItem(title: "自动更新", action: #selector(optionsChanged(_:)), keyEquivalent: "")
    let exporting = NSMenuItem(title: "自动导出", action: #selector(optionsChanged(_:)), keyEquivalent: "")
    let citation = NSMenuItem(title: "自动引用", action: #selector(optionsChanged(_:)), keyEquivalent: "")
    let generate = AgentDialogButton(title: "生成卡片", target: nil, action: nil)
    let focus = AgentDialogTextField(), scopeLabel = NSTextField(labelWithString: ""), state = AgentSettingsStatusField("知识卡片状态")
    let table = NSTableView(), titleField = AgentDialogTextField(), preview = NSTextView(), sources = NSPopUpButton()
    let format = NSSegmentedControl(labels: ["阅读", "编辑"], trackingMode: .selectOne, target: nil, action: nil)
    let save = AgentDialogButton(title: "保存", target: nil, action: nil), open = AgentDialogButton(title: "查看源码", target: nil, action: nil)
    private let taskButton = AgentDialogButton(title: "查看任务", target: nil, action: nil)
    private let more = AgentWorkbenchButton(), clear = AgentDialogButton(title: "清除筛选", target: nil, action: nil)
    private let browser = NSView(), split = NSView()
    private let setup = NSStackView(), reader = NSStackView()
    private let empty = NSTextField(labelWithString: ""), count = NSTextField(labelWithString: ""), readTitle = NSTextField(labelWithString: "")
    private var appliedFilters = (query: "", category: 0)
    var value: AgentKnowledgeCardBook?, revision = AgentFiles.hash(Data()), rows: [AgentKnowledgeCard] = [], selected: AgentKnowledgeCard?
    var dirty = false { didSet { if dirty != oldValue { onWorkspaceChange?() } } }
    var loading = false, busy = false, job: Task<Void, Never>?, sourceWindow: AgentKnowledgeSourcePage?
    var needsConnection = false
    var sourceOwner: AgentKnowledgeCard?, openedScope: RecoveryScope?, hasRestoredSnapshot = false
    var savedViews: [String: AgentTextViewport] = [:], pendingCardViewport: AgentTextViewport?
    var fieldSelections: [String: AgentTextViewport.Selection] = [:], lastContentFocus = "query"
    var applyingRecovery = false, viewportScheduled = false, cardFocusRequested = false
    var renderedCardViewKey: String?
    var onWorkspaceChange: (() -> Void)?
    var reviewWindow: AgentKnowledgeReviewWindow?
    var onOpenTask: ((String) -> Void)?
    var cards: AgentKnowledgeCards { store.knowledgeCards }
    var task: AgentTaskRecord? { store.task(taskID) }
    var selectedLanguage: String { language.indexOfSelectedItem == 1 ? "en" : "zh" }
    init(store: AgentStore, taskID: String) {
        self.store = store; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "知识卡片"; window.minSize = NSSize(width: 850, height: 550); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        search.placeholderString = "搜索卡片"; search.sendsSearchStringImmediately = true; search.target = self; search.action = #selector(filterChanged)
        search.setAccessibilityLabel("搜索卡片")
        search.delegate = self; focus.delegate = self
        category.addItems(withTitles: ["全部类型"] + AgentKnowledgeCardKind.allCases.map(\.title)); category.setAccessibilityLabel("卡片类型"); category.target = self; category.action = #selector(filterChanged)
        language.addItems(withTitles: ["简体中文", "English"]); language.setAccessibilityLabel("卡片语言"); language.target = self; language.action = #selector(languageChanged)
        for (button, action) in [(generate, #selector(generateCards)), (taskButton, #selector(viewTask)),
                                 (open, #selector(openSource)), (clear, #selector(clearFilters))] {
            button.target = self; button.action = action
            AgentDialogStyle.action(button, prominent: button === generate)
        }
        save.target = self; save.action = #selector(saveCard); save.prominent = true
        generate.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        AgentWorkbenchTheme.toolbar(more, title: "知识卡片操作", symbol: "ellipsis")
        more.target = self; more.action = #selector(showCardMenu)
        focus.placeholderString = "重点模块或问题（可选）"; focus.setAccessibilityLabel("卡片分析重点")
        scopeLabel.stringValue = task?.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        scopeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        state.maximumNumberOfLines = 2
        readTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        readTitle.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize: 12, weight: .medium); count.textColor = AgentWorkbenchTheme.secondaryText
        empty.font = .systemFont(ofSize: 13); empty.textColor = AgentWorkbenchTheme.secondaryText
        for field in [scopeLabel, readTitle, focus, search, titleField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let column = NSTableColumn(identifier: .init("card"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil; table.rowHeight = 48; table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("知识卡片列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        titleField.setAccessibilityLabel("卡片标题")
        titleField.target = self; titleField.action = #selector(titleChanged); titleField.delegate = self
        preview.isEditable = false; preview.isRichText = true; preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true; preview.textContainer?.lineFragmentPadding = 0
        preview.textContainerInset = NSSize(width: 0, height: 8); preview.delegate = self; preview.setAccessibilityLabel("卡片正文")
        let viewer = NSScrollView(); viewer.documentView = preview; viewer.hasVerticalScroller = true
        viewer.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(cardViewportChanged(_:)), name: NSView.boundsDidChangeNotification, object: viewer.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(cardFieldSelectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        format.selectedSegment = 0; format.target = self; format.action = #selector(formatChanged)
        format.selectedSegmentBezelColor = AgentWorkbenchTheme.accent; format.setAccessibilityLabel("阅读或编辑卡片")
        sources.setAccessibilityLabel("卡片源码引用"); sources.target = self; sources.action = #selector(sourceReferenceChanged)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        for scroll in [list, viewer] { scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; scroll.borderType = .noBorder }
        table.style = .inset; table.backgroundColor = .clear; preview.drawsBackground = false; preview.textColor = .labelColor
        layoutPage(in: content, list: list, viewer: viewer)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.alignment = .centerY; stack.spacing = 8; return stack
    }
    private func layoutPage(in content: NSView, list: NSScrollView, viewer: NSScrollView) {
        let summary = row([scopeLabel, NSView(), taskButton, generate, more])
        let languageFrame = AgentSettingsPopupFrame(language)
        setup.alignment = .centerY; setup.spacing = 8
        [focus, languageFrame].forEach(setup.addArrangedSubview)
        let panel = AgentThemeView(fill: AgentWorkbenchTheme.card, stroke: AgentWorkbenchTheme.line)
        panel.layer?.cornerRadius = 8; panel.layer?.borderWidth = 1; panel.layer?.masksToBounds = true
        let page = NSStackView(views: [summary, setup, panel, state])
        page.orientation = .vertical; page.alignment = .leading; page.spacing = 10
        content.addSubview(page); page.translatesAutoresizingMaskIntoConstraints = false
        for item in [summary, setup, panel, state] { item.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }

        let categoryFrame = AgentSettingsPopupFrame(category)
        let filters = row([search, categoryFrame])
        let horizontal = AgentWorkbenchTheme.rule(), vertical = AgentThemeView(fill: AgentWorkbenchTheme.line)
        let sourceFrame = AgentSettingsPopupFrame(sources, outlined: true, maximumWidth: nil)
        let controls = row([readTitle, titleField, format])
        let sourceBar = row([sourceFrame, NSView(), open, save])
        reader.orientation = .vertical; reader.alignment = .leading; reader.spacing = 6
        reader.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        [controls, viewer, sourceBar].forEach(reader.addArrangedSubview)
        for item in [controls, viewer, sourceBar] { item.widthAnchor.constraint(equalTo: reader.widthAnchor, constant: -24).isActive = true }
        let emptyState = NSStackView(views: [empty, clear])
        emptyState.orientation = .vertical; emptyState.alignment = .centerX; emptyState.spacing = 10
        panel.addSubview(browser); panel.addSubview(emptyState)
        [filters, horizontal, split].forEach(browser.addSubview)
        [list, count, vertical, reader].forEach(split.addSubview)
        for view in [browser, emptyState, filters, split, list, count, vertical, reader] { view.translatesAutoresizingMaskIntoConstraints = false }
        let listWidth = list.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.30)
        listWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: content.topAnchor, constant: 4), page.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), page.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 112),
            browser.topAnchor.constraint(equalTo: panel.topAnchor), browser.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: panel.leadingAnchor), browser.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            filters.topAnchor.constraint(equalTo: browser.topAnchor, constant: 10), filters.leadingAnchor.constraint(equalTo: browser.leadingAnchor, constant: 12),
            filters.trailingAnchor.constraint(equalTo: browser.trailingAnchor, constant: -12),
            horizontal.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 10),
            horizontal.leadingAnchor.constraint(equalTo: browser.leadingAnchor), horizontal.trailingAnchor.constraint(equalTo: browser.trailingAnchor),
            split.topAnchor.constraint(equalTo: horizontal.bottomAnchor), split.bottomAnchor.constraint(equalTo: browser.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: browser.leadingAnchor), split.trailingAnchor.constraint(equalTo: browser.trailingAnchor),
            emptyState.centerXAnchor.constraint(equalTo: panel.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: panel.centerYAnchor, constant: -1),
            count.topAnchor.constraint(equalTo: split.topAnchor, constant: 12), count.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 12),
            count.trailingAnchor.constraint(lessThanOrEqualTo: list.trailingAnchor, constant: -10),
            list.topAnchor.constraint(equalTo: count.bottomAnchor, constant: 4), list.leadingAnchor.constraint(equalTo: split.leadingAnchor, constant: 2),
            list.bottomAnchor.constraint(equalTo: split.bottomAnchor, constant: -5),
            list.widthAnchor.constraint(greaterThanOrEqualToConstant: 136), list.widthAnchor.constraint(lessThanOrEqualToConstant: 228), listWidth,
            vertical.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 2), vertical.widthAnchor.constraint(equalToConstant: 1),
            vertical.topAnchor.constraint(equalTo: split.topAnchor), vertical.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            reader.leadingAnchor.constraint(equalTo: vertical.trailingAnchor), reader.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            reader.topAnchor.constraint(equalTo: split.topAnchor), reader.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            focus.heightAnchor.constraint(equalToConstant: 28), search.heightAnchor.constraint(equalToConstant: 28), controls.heightAnchor.constraint(equalToConstant: 28),
            format.trailingAnchor.constraint(equalTo: controls.trailingAnchor), format.widthAnchor.constraint(equalToConstant: 96),
            titleField.heightAnchor.constraint(equalToConstant: 28), sourceBar.heightAnchor.constraint(equalToConstant: 28),
            save.heightAnchor.constraint(equalToConstant: 28), save.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            categoryFrame.widthAnchor.constraint(equalToConstant: 104), languageFrame.widthAnchor.constraint(equalToConstant: 110)
        ])
    }
    @objc private func showCardMenu() {
        let scoped = openedScope != nil && !needsConnection
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, action, enabled) in [("刷新", #selector(reloadCards), task?.workspace != nil),
                                         ("导入项目卡片…", #selector(importCards), scoped),
                                         ("导出到项目", #selector(exportCards), scoped && value != nil),
                                         ("恢复版本…", #selector(restoreVersion), scoped)] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled && !busy
        }
        menu.addItem(.separator())
        for item in [automatic, exporting, citation] {
            item.menu?.removeItem(item)
            item.target = self; item.isEnabled = scoped && !busy; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }
    @objc private func clearFilters() {
        search.stringValue = ""; category.selectItem(at: 0)
        filter(preferred: nil); presentingWindow?.makeFirstResponder(search)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { reviewWindow?.canLeaveSettings() != false && discard() }
    func windowDidBecomeKey(_ notification: Notification) {
        format.selectedSegmentBezelColor = AgentThemeContext.resolve(AgentWorkbenchTheme.accent, in: format)
        if hasRestoredSnapshot { checkRestoredContext() } else { reload() }
        scheduleCardViewport(); reviewWindow?.presentRecoveredVersion(from: self)
    }
    private func closeContent() { job?.cancel(); NotificationCenter.default.removeObserver(self); sourceWindow?.onClose = nil; sourceWindow?.endSettingsHosting(); sourceWindow = nil; sourceOwner = nil; reviewWindow?.close(); reviewWindow = nil }
    func windowWillClose(_ notification: Notification) { closeContent() }
    override func settingsWillLeave() { closeContent() }
    override func settingsDidAppear() {
        super.settingsDidAppear(); cardFocusRequested = true
        if let sourceWindow, sourceWindow.needsHostedPresentation, onSettingsPush != nil { presentSettingsChild(sourceWindow) }
        scheduleCardViewport()
    }
    override func pageDidLayout() { scheduleCardViewport() }
    func discard() -> Bool {
        guard dirty else { return true }
        guard AgentUnsavedChanges.discard("放弃未保存的卡片编辑？", discardTitle: "放弃编辑") else { return false }; dirty = false; render(); return true
    }
    func reload() {
        if hasRestoredSnapshot { checkRestoredContext(); return }
        guard !dirty, let task, let workspace = task.workspace else {
            if dirty { state.stringValue = "有未保存编辑；保存时核对当前版本" }
            updateBrowser(); return
        }
        rememberCardViewport()
        do {
            let scope = try cards.scope(task)
            needsConnection = false
            if let openedScope, openedScope.root != scope.root || openedScope.branch != scope.branch, sourceWindow != nil { state.stringValue = "工作区或分支已变化，原来源阅读记录已保留；请刷新核对"; return }
            let options = try cards.options(workspace: workspace), previous = selected?.id
            if openedScope == nil { openedScope = .init(root: scope.root, branch: scope.branch) }
            let loaded = try cards.book(task, language: options.language)
            if openedScope?.root != scope.root || openedScope?.branch != scope.branch || value?.language != options.language {
                savedViews = [:]; pendingCardViewport = nil; renderedCardViewKey = nil; fieldSelections["title"] = nil
            }
            value = loaded.0; revision = loaded.1
            let ids = Set(value?.cards.map(\.id) ?? []); savedViews = savedViews.filter { key, _ in key.split(separator: "|").first.map { ids.contains(String($0)) } == true }
            language.selectItem(at: options.language == "en" ? 1 : 0); automatic.state = options.autoUpdate ? .on : .off; exporting.state = options.autoExport ? .on : .off; citation.state = options.citation ? .on : .off
            openedScope = .init(root: scope.root, branch: scope.branch)
            let branch = scope.branch == "folder" ? "文件夹" : scope.branch.replacingOccurrences(of: "refs/heads/", with: "")
            scopeLabel.stringValue = URL(fileURLWithPath: scope.root).lastPathComponent + " · " + branch; scopeLabel.toolTip = scope.root
            if focus.stringValue.isEmpty { focus.stringValue = value?.focus ?? "" }
            let active = activeTask
            generate.title = active == nil ? (value == nil ? "生成卡片" : "重新生成") : "生成中…"; generate.isEnabled = active == nil && !busy
            taskButton.isEnabled = active != nil || latestTask != nil || value?.taskID != nil
            state.stringValue = cards.notices[scope.root] ?? ""
            if active == nil, let latest = latestTask, latest.updated > (value?.created ?? .distantPast) {
                if latest.status == .failed { state.stringValue = store.task(latest.id)?.events.last(where: { $0.status == "failed" })?.detail ?? "生成未完成，请查看任务" }
                if latest.status == .stopped { state.stringValue = "生成已停止" }
            }
            filter(preferred: previous)
        } catch is AgentKnowledgeConnectionNeeded {
            needsConnection = true; generate.title = "连接项目知识"; generate.isEnabled = !busy
            state.stringValue = ""
        } catch { needsConnection = false; state.stringValue = error.localizedDescription; generate.isEnabled = !busy }
        updateBrowser(); onWorkspaceChange?()
    }
    var activeTask: AgentTaskRecord? {
        guard let task, let scope = try? cards.scope(task) else { return nil }
        return store.tasks.first { $0.kind == AgentKnowledgeCards.kind && $0.workspace == scope.root && $0.knowledgeJob?.branch == scope.branch && $0.knowledgeJob?.language == selectedLanguage && !$0.archived && ([.ready, .running, .waiting].contains($0.status) || cards.finalizing.contains($0.id)) }
    }
    func checkState() -> [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled else { return [:] }
        return ["taskID": taskID, "language": selectedLanguage, "cards": rows.map { ["id": $0.id, "title": $0.title, "body": $0.body, "manual": $0.manual] as [String: Any] }, "selectedID": selected?.id ?? "", "draft": preview.string, "dirty": dirty, "busy": busy, "state": state.stringValue]
    }
    func refresh(workspace: String) { if task?.workspace.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) == workspace { reload() } }
    @objc func filterChanged() {
        guard (search.stringValue, category.indexOfSelectedItem) != appliedFilters else { return }
        guard discard() else {
            search.stringValue = appliedFilters.query
            search.currentEditor()?.string = appliedFilters.query
            category.selectItem(at: appliedFilters.category)
            onWorkspaceChange?()
            return
        }
        filter(preferred: selected?.id)
    }
    func filter(preferred: String?) {
        rememberCardViewport()
        appliedFilters = (search.stringValue, category.indexOfSelectedItem)
        let query = appliedFilters.query.trimmingCharacters(in: .whitespacesAndNewlines), index = appliedFilters.category - 1
        rows = (value?.cards ?? []).filter { card in (index < 0 || card.kind == AgentKnowledgeCardKind.allCases[index]) && (query.isEmpty || (card.title + "\n" + card.body).localizedCaseInsensitiveContains(query)) }
        table.delegate = nil; table.reloadData(); table.deselectAll(nil)
        if let i = rows.firstIndex(where: { $0.id == preferred }) ?? (rows.isEmpty ? nil : 0) { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false); selected = rows[i] } else { selected = nil }
        table.delegate = self; render(); onWorkspaceChange?()
    }
    private func updateBrowser() {
        let hasWorkspace = task?.workspace != nil, hasCards = value?.cards.isEmpty == false
        setup.isHidden = openedScope == nil
        generate.isHidden = !hasWorkspace
        more.isHidden = !hasWorkspace
        taskButton.isHidden = !taskButton.isEnabled || openedScope == nil || needsConnection
        browser.isHidden = !hasCards
        split.isHidden = rows.isEmpty
        clear.isHidden = !hasCards || !rows.isEmpty
        empty.isHidden = !rows.isEmpty
        if hasCards { empty.stringValue = "未找到匹配的卡片" }
        else if needsConnection { empty.stringValue = "尚未连接项目知识" }
        else if !hasWorkspace { empty.stringValue = "请先选择工作区" }
        else if openedScope == nil { empty.stringValue = "无法读取知识卡片" }
        else { empty.stringValue = "暂无卡片" }
        let total = value?.cards.count ?? 0
        count.stringValue = rows.count == total ? "\(total) 张卡片" : "\(rows.count) / \(total) 张卡片"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { discard() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let card = rows[row], title = NSTextField(labelWithString: card.title), detail = NSTextField(labelWithString: card.kind.title + (card.manual ? " · 已编辑" : "") + (task?.workspace.map({ cards.fresh(card, workspace: $0) }) == true ? "" : " · 来源已变化"))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText
        for label in [title, detail] { label.lineBreakMode = .byTruncatingTail }
        let column = NSStackView(views: [title, detail]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 0, right: 7)
        column.toolTip = card.title
        return column
    }
    func tableViewSelectionDidChange(_ notification: Notification) { rememberCardViewport(); selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil; render(); onWorkspaceChange?() }
    func render() {
        loading = true; defer { loading = false }
        let editing = format.selectedSegment == 1 && selected != nil
        reader.isHidden = selected == nil
        readTitle.stringValue = selected?.title ?? ""; readTitle.isHidden = editing
        titleField.stringValue = selected?.title ?? ""; titleField.isEditable = editing; titleField.isHidden = !editing
        preview.isEditable = editing; preview.isRichText = !editing
        if editing { preview.font = .monospacedSystemFont(ofSize: 13, weight: .regular); preview.string = selected?.body ?? "" }
        else { let p = NSMutableParagraphStyle(); p.lineSpacing = 5; p.paragraphSpacing = 8; preview.textStorage?.setAttributedString(NativeMarkdown.render(selected?.body ?? "", font: .systemFont(ofSize: 14), color: .labelColor, paragraph: p)) }
        sources.removeAllItems(); sources.addItems(withTitles: selected?.sources.map { $0.path + ":\($0.line)–\($0.endLine)" } ?? [])
        open.isEnabled = sources.numberOfItems > 0; format.isEnabled = selected != nil
        save.isEnabled = editing; save.isHidden = !editing; dirty = false
        updateBrowser()
        restoreRememberedCardViewport()
    }
    @objc func formatChanged() { defer { onWorkspaceChange?() }; rememberCardViewport(); guard discard() else { format.selectedSegment = 1; return }; render() }
    @objc func titleChanged() { if !loading { dirty = true; onWorkspaceChange?() } }
    @objc func sourceReferenceChanged() { onWorkspaceChange?() }
    func controlTextDidChange(_ notification: Notification) {
        guard !loading, !applyingRecovery else { return }
        if notification.object as? NSTextField === titleField { dirty = true }
        rememberControlFocus(notification.object as? NSTextField); onWorkspaceChange?()
    }
    func controlTextDidBeginEditing(_ notification: Notification) { if !applyingRecovery { rememberControlFocus(notification.object as? NSTextField) } }
    func textDidChange(_ notification: Notification) { if !loading && !applyingRecovery && preview.isEditable { dirty = true; lastContentFocus = "body"; onWorkspaceChange?() } }
    func textViewDidChangeSelection(_ notification: Notification) { guard !loading, !applyingRecovery, !cardFocusRequested else { return }; if presentingWindow?.firstResponder === preview { lastContentFocus = "body" }; onWorkspaceChange?() }
}
