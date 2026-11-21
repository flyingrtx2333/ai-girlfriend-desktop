import AppKit

@MainActor private final class AgentAttentionTable: NSTableView {
    var onActivate: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if event.clickCount == 1, row >= 0, row == selectedRow { _ = onActivate?() }
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), onActivate?() == true { return }
        super.keyDown(with: event)
    }
}

@MainActor final class AgentAttentionWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate {
    var onOpenSettings: (() -> Void)?
    var onRecoveryChange: (() -> Void)?
    private let attention: AgentAttention, runtime: AgentRuntime
    private let tabs = NSSegmentedControl(labels: ["待关注", "历史"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), kind = NSPopUpButton(), source = NSPopUpButton(), time = NSPopUpButton(), sender = NSPopUpButton()
    private let table = AgentAttentionTable(), status = NSTextField(wrappingLabelWithString: ""), more = AgentDialogButton(title: "加载更多", target: nil, action: nil)
    private let detailTitle = NSTextField(wrappingLabelWithString: ""), metadata = NSTextField(labelWithString: ""), body = NSTextView()
    private let reply = NSTextView(), replyScroll = NSScrollView(), replyCaption = NSTextField(labelWithString: "答复")
    private let replyField = AgentThemeView(fill: .textBackgroundColor, stroke: AgentWorkbenchTheme.line)
    private let savedDraft = NSTextView(), savedDraftScroll = NSScrollView()
    private let draftHeading = NSStackView(), draftCaption = NSTextField(labelWithString: "已保存稿")
    private let draftNotice = NSTextField(wrappingLabelWithString: "")
    private let toggleDraftPreview = AgentDialogButton(title: "查看原问题", target: nil, action: nil)
    private let useSavedDraft = AgentDialogButton(title: "载入已保存稿", target: nil, action: nil)
    private let saveLocalDraft = AgentDialogButton(title: "保存本窗口稿", target: nil, action: nil)
    private let open = AgentDialogButton(title: "打开任务", target: nil, action: nil), mark = AgentDialogButton(title: "标记已处理", target: nil, action: nil)
    private let answer = AgentDialogButton(title: "回复并继续", target: nil, action: nil), allow = AgentDialogButton(title: "允许一次", target: nil, action: nil), deny = AgentDialogButton(title: "拒绝", target: nil, action: nil)
    private let execute = AgentDialogButton(title: "采纳计划并执行", target: nil, action: nil)
    private var filterBar: AgentAttentionFilterBar!
    private var states = [AgentAttentionRecovery.List(), AgentAttentionRecovery.List()]
    private var activeTab = 0, rows: [AgentAttentionItem] = [], selected: AgentAttentionItem?
    private var pendingRecovery: AgentAttentionRecovery?, pendingDetail: AgentAttentionRecovery.Detail?
    private var preferredFocus: AgentAttentionRecovery.Focus?, needsSelection = false
    private var suppressSelection = false, draftSave: DispatchWorkItem?, operationIssue: String?
    private var replySavedText = "", replyLoaded = true
    private var draftConflict: AgentAttention.DraftConflict?, showingSavedDraft = false
    private weak var hostWindow: NSWindow?
    private var hostedContent: NSView?
    private let panes = NSView(), empty = NSTextField(labelWithString: "暂无待关注的事项")
    private let list = NSScrollView(), details = NSStackView(), divider = NSBox(), bodyScroll = NSScrollView(), footer = NSStackView()
    private let headingTitle = NSTextField(labelWithString: "需要我")
    private let back = AgentDialogButton(title: "返回列表", target: nil, action: nil)
    private var splitConstraints: [NSLayoutConstraint] = [], compactConstraints: [NSLayoutConstraint] = []
    private var compact = false, detailRequested = false, canLoadMore = false
    private var showingCompactDetail: Bool { compact && detailRequested && selected != nil }
    private var contentTop: NSLayoutConstraint!
    var presentingWindow: NSWindow? { hostWindow ?? window }
    var isVisible: Bool { (hostedContent?.window?.isVisible ?? window?.isVisible ?? false) && hostedContent?.isHiddenOrHasHiddenAncestor != true }
    var onOpenTask: ((String) -> Void)?
    func questionFocused(_ id: String) -> Bool {
        isVisible && !details.isHidden && presentingWindow?.isKeyWindow == true && selected?.taskID == id && selected?.kind == .question && selected?.mcpInputID == nil && selected?.handled == false
    }
    func questionInteraction(_ event: NSEvent) -> String? {
        guard isVisible, !details.isHidden, let item = selected, item.kind == .question, !item.handled, item.mcpInputID == nil else { return nil }
        return AgentQuestionAutoSkip.containsInteraction(event, views: [body.enclosingScrollView ?? body, replyField, detailTitle, metadata, open, answer]) ? item.taskID : nil
    }
    init(attention: AgentAttention, runtime: AgentRuntime) {
        self.attention = attention; self.runtime = runtime
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "需要我"; window.minSize = NSSize(width: 830, height: 550); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let settings = NSButton(title: "设置", target: self, action: #selector(showSettings)), reload = NSButton(title: "刷新", target: self, action: #selector(reload))
        AgentWorkbenchTheme.toolbar(settings, title: "需要我设置", symbol: "gearshape")
        AgentWorkbenchTheme.toolbar(reload, title: "刷新", symbol: "arrow.clockwise")
        headingTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        back.target = self; back.action = #selector(backToList)
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil); back.imagePosition = .imageLeading
        back.keyEquivalent = "\u{1b}"; back.keyEquivalentModifierMask = []
        back.identifier = .init("attention-detail-back"); AgentDialogStyle.action(back)
        let heading = NSStackView(views: [back, headingTitle, tabs, NSView(), reload, settings]); heading.spacing = 16; heading.alignment = .centerY
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab); tabs.setAccessibilityLabel("需要我列表")
        tabs.font = .systemFont(ofSize: 13); tabs.selectedSegmentBezelColor = AgentWorkbenchTheme.accent
        tabs.widthAnchor.constraint(equalToConstant: 128).isActive = true; tabs.heightAnchor.constraint(equalToConstant: 28).isActive = true
        search.placeholderString = "搜索当前列表"; search.setAccessibilityLabel("搜索需要我当前列表"); search.delegate = self
        search.font = .systemFont(ofSize: 13)
        for (menu, label) in [(kind, "筛选待办类型"), (source, "筛选待办来源"), (time, "筛选处理时间"), (sender, "筛选发起者")] {
            menu.target = self; menu.action = #selector(changeFilters); menu.setAccessibilityLabel(label); menu.cell?.lineBreakMode = .byTruncatingTail
            menu.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true
        }
        kind.addItem(withTitle: "全部类型"); for value in AgentAttentionKind.allCases { kind.addItem(withTitle: value.title); kind.lastItem?.representedObject = value.rawValue }
        source.addItem(withTitle: "全部来源"); for value in AgentAttentionSource.allCases { source.addItem(withTitle: value.title); source.lastItem?.representedObject = value.rawValue }
        for (label, days) in [("全部时间", 0), ("今天", 1), ("最近7天", 7), ("最近30天", 30)] { time.addItem(withTitle: label); time.lastItem?.representedObject = days }
        filterBar = AgentAttentionFilterBar(kind: kind, source: source, time: time, sender: sender, search: search)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("attention"))); table.headerView = nil; table.rowHeight = 76
        table.autoresizingMask = [.width]; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openRowTask); table.setAccessibilityLabel("需要我事项列表")
        table.onActivate = { [weak self] in self?.activateItem() == true }
        list.documentView = table; list.hasVerticalScroller = true
        table.style = .fullWidth; table.backgroundColor = .clear; table.intercellSpacing = .zero
        detailTitle.font = .systemFont(ofSize: 16, weight: .semibold); detailTitle.maximumNumberOfLines = 3
        metadata.font = .systemFont(ofSize: 11); metadata.textColor = AgentWorkbenchTheme.secondaryText; metadata.lineBreakMode = .byTruncatingTail
        for text in [body, reply, savedDraft] {
            text.isRichText = false; text.font = .systemFont(ofSize: 13); text.textColor = .labelColor; text.drawsBackground = false; text.textContainerInset = NSSize(width: 10, height: 10)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        }
        body.isEditable = false; body.setAccessibilityLabel("需要我事项详情")
        body.textContainerInset = NSSize(width: 0, height: 4); body.textContainer?.lineFragmentPadding = 0
        bodyScroll.documentView = body; bodyScroll.hasVerticalScroller = true
        savedDraft.isEditable = false; savedDraft.setAccessibilityLabel("已保存的答复草稿")
        savedDraft.textContainerInset = body.textContainerInset; savedDraft.textContainer?.lineFragmentPadding = 0
        savedDraftScroll.documentView = savedDraft; savedDraftScroll.hasVerticalScroller = true
        draftCaption.font = .systemFont(ofSize: 12, weight: .medium)
        for view in [draftCaption, NSView(), toggleDraftPreview] { draftHeading.addArrangedSubview(view) }
        draftHeading.alignment = .centerY
        reply.delegate = self; reply.allowsUndo = true; reply.setAccessibilityLabel("答复此问题"); replyScroll.documentView = reply; replyScroll.hasVerticalScroller = true; replyScroll.borderType = .bezelBorder
        replyField.addSubview(replyScroll); replyScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([replyScroll.leadingAnchor.constraint(equalTo: replyField.leadingAnchor, constant: 1), replyScroll.trailingAnchor.constraint(equalTo: replyField.trailingAnchor, constant: -1), replyScroll.topAnchor.constraint(equalTo: replyField.topAnchor, constant: 1), replyScroll.bottomAnchor.constraint(equalTo: replyField.bottomAnchor, constant: -1), replyField.heightAnchor.constraint(equalToConstant: 88)])
        replyCaption.font = .systemFont(ofSize: 12, weight: .medium)
        for (button, action) in [(open, #selector(openTask)), (mark, #selector(markHandled)), (answer, #selector(answerQuestion)), (allow, #selector(allowRequest)), (deny, #selector(denyRequest)), (execute, #selector(executePlan)),
                                 (toggleDraftPreview, #selector(toggleSavedDraft)), (useSavedDraft, #selector(loadReviewedDraft)), (saveLocalDraft, #selector(saveReviewedDraft))] {
            button.target = self; button.action = action
            AgentDialogStyle.action(button, prominent: button === answer || button === allow || button === execute)
        }
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let detailHeading = NSStackView(views: [detailTitle, NSView(), open]); detailHeading.spacing = 12; detailHeading.alignment = .top
        draftNotice.font = .systemFont(ofSize: 12); draftNotice.textColor = .systemRed
        draftNotice.setAccessibilityLabel("答复草稿冲突")
        draftNotice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [draftNotice, NSView(), mark, deny, allow, execute, useSavedDraft, saveLocalDraft, answer])
        actions.spacing = 8; actions.alignment = .centerY
        for view in [detailHeading, metadata, draftHeading, bodyScroll, savedDraftScroll, replyCaption, replyField, actions] { details.addArrangedSubview(view) }
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 12
        for child in details.arrangedSubviews { child.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true }
        for view in [list, details, empty] { panes.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        divider.boxType = .separator; divider.identifier = .init("attention-pane-divider"); panes.addSubview(divider); divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([divider.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 15), divider.widthAnchor.constraint(equalToConstant: 1), divider.topAnchor.constraint(equalTo: panes.topAnchor), divider.bottomAnchor.constraint(equalTo: panes.bottomAnchor)])
        let listWidth = list.widthAnchor.constraint(equalToConstant: 260); listWidth.priority = .init(499)
        empty.font = .systemFont(ofSize: 14); empty.textColor = AgentWorkbenchTheme.secondaryText
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: panes.leadingAnchor), list.topAnchor.constraint(equalTo: panes.topAnchor),
            list.bottomAnchor.constraint(equalTo: panes.bottomAnchor), details.trailingAnchor.constraint(equalTo: panes.trailingAnchor),
            details.topAnchor.constraint(equalTo: panes.topAnchor, constant: 10), details.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: panes.centerXAnchor), empty.centerYAnchor.constraint(equalTo: panes.centerYAnchor)])
        splitConstraints = [list.widthAnchor.constraint(greaterThanOrEqualToConstant: 180), list.widthAnchor.constraint(lessThanOrEqualTo: panes.widthAnchor, multiplier: 0.4),
                            listWidth, details.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 32)]
        compactConstraints = [list.trailingAnchor.constraint(equalTo: panes.trailingAnchor), details.leadingAnchor.constraint(equalTo: panes.leadingAnchor)]
        NSLayoutConstraint.activate(splitConstraints)
        for scroll in [list, bodyScroll, replyScroll, savedDraftScroll] { scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder; scroll.drawsBackground = false }
        replyField.layer?.cornerRadius = 8; replyField.layer?.masksToBounds = true; replyField.layer?.borderWidth = 1
        status.font = .systemFont(ofSize: 12); status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 0; status.isSelectable = true; status.setAccessibilityLabel("需要我状态")
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        more.target = self; more.action = #selector(loadMore); AgentDialogStyle.action(more)
        for view in [status, NSView(), more] { footer.addArrangedSubview(view) }; footer.spacing = 8
        let rule = NSBox(); rule.boxType = .separator
        let content = NSStackView(views: [heading, filterBar, rule, panes, footer]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
        let root = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface); root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false; window.contentView = root
        root.onResize = { [weak self, weak root] in if let width = root?.bounds.width { self?.adjustLayout(width) } }
        root.setAccessibilityLabel("需要我主页面")
        contentTop = content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18)
        let width = content.widthAnchor.constraint(equalToConstant: 824); width.priority = .init(499)
        NSLayoutConstraint.activate([content.centerXAnchor.constraint(equalTo: root.centerXAnchor), content.widthAnchor.constraint(lessThanOrEqualToConstant: 824), content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 28), content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28), width, contentTop, content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)])
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        panes.setContentHuggingPriority(.defaultLow, for: .vertical)
        for scroll in [bodyScroll, savedDraftScroll] { scroll.setContentHuggingPriority(.defaultLow, for: .vertical) }
        for scroll in [list, bodyScroll, replyScroll] {
            let clip = scroll.contentView; clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        attention.refresh(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func content(in host: NSWindow) -> NSView? {
        guard let content = hostedContent ?? window?.contentView else { return nil }
        if hostedContent == nil { window?.contentView = nil; hostedContent = content }
        hostWindow = host; contentTop.constant = 68; refreshAppearance()
        return content
    }
    func refreshAppearance() {
        replyField.updateLayer()
    }
    private func adjustLayout(_ width: CGFloat) {
        let next = width < 760
        guard width > 0, compact != next else { return }
        let responder = presentingWindow?.firstResponder as? NSView
        if next, responder?.isDescendant(of: details) == true {
            detailRequested = true
        }
        if next, detailRequested { rememberListPosition() }
        NSLayoutConstraint.deactivate(compact ? compactConstraints : splitConstraints)
        compact = next
        NSLayoutConstraint.activate(compact ? compactConstraints : splitConstraints)
        updateVisibility()
        if showingCompactDetail, responder?.isDescendant(of: list) == true {
            DispatchQueue.main.async { [weak self] in
                guard let self, isVisible, showingCompactDetail else { return }
                presentingWindow?.makeFirstResponder(body)
            }
        } else if !compact {
            DispatchQueue.main.async { [weak self] in self?.restoreListPosition() }
        }
    }
    private func updateVisibility() {
        let reading = showingCompactDetail, hasItems = !rows.isEmpty
        list.isHidden = !hasItems || reading
        details.isHidden = selected == nil || compact && !reading
        divider.isHidden = details.isHidden || compact
        empty.isHidden = hasItems
        back.isHidden = !reading; headingTitle.isHidden = reading; tabs.isHidden = reading; filterBar.isHidden = reading
        more.isHidden = !canLoadMore || reading
        let comparing = draftConflict != nil
        status.isHidden = comparing || reading && operationIssue == nil && attention.issue == nil && attention.settings.enabled && !attention.loading
        footer.isHidden = (status.isHidden || status.stringValue.isEmpty) && more.isHidden
        draftHeading.isHidden = !comparing
        draftNotice.isHidden = !comparing
        if comparing { draftNotice.stringValue = operationIssue ?? "答复草稿已更新，请核对后选择" }
        let viewingSaved = comparing && showingSavedDraft
        bodyScroll.isHidden = viewingSaved; savedDraftScroll.isHidden = !viewingSaved
        draftCaption.stringValue = viewingSaved ? "已保存稿" : "原问题"
        toggleDraftPreview.title = viewingSaved ? "查看原问题" : "查看已保存稿"
        useSavedDraft.isHidden = !comparing; saveLocalDraft.isHidden = !comparing
        answer.isHidden = comparing || selected?.kind != .question || selected?.handled != false || selected?.mcpInputID != nil
        replyCaption.stringValue = comparing ? "本窗口草稿" : selected?.handled == true ? "未发送答复" : "答复"
    }
    @discardableResult private func activateItem() -> Bool {
        guard selected != nil else { return false }
        guard persistReply() else { return compact }
        if compact, !showingCompactDetail { rememberListPosition() }
        detailRequested = true
        if compact {
            updateVisibility()
            hostedContent?.layoutSubtreeIfNeeded()
            presentingWindow?.recalculateKeyViewLoop()
            presentingWindow?.makeFirstResponder(body)
            preferredFocus = .body; applyDetailPosition()
        }
        onRecoveryChange?()
        return compact
    }
    @objc private func backToList() {
        guard showingCompactDetail, persistReply() else { return }
        detailRequested = false; updateVisibility()
        hostedContent?.layoutSubtreeIfNeeded(); presentingWindow?.recalculateKeyViewLoop()
        restoreListPosition()
        presentingWindow?.makeFirstResponder(table)
        preferredFocus = .list; onRecoveryChange?()
    }
    private func rememberListPosition() {
        guard isVisible, !list.isHidden, !rows.isEmpty else { return }
        let y = max(0, list.contentView.bounds.minY), index = table.row(at: NSPoint(x: 1, y: y + 0.5))
        let validIndex = rows.indices.contains(index)
        states[activeTab].position = .init(anchor: validIndex ? rows[index].id : nil, y: y,
                                          offset: validIndex ? y - table.rect(ofRow: index).minY : 0)
    }
    private func restoreListPosition() {
        guard !list.isHidden, let position = states[activeTab].position else { return }
        let clip = list.contentView
        let row = position.anchor.flatMap { id in rows.firstIndex { $0.id == id } }
        let y = row.map { table.rect(ofRow: $0).minY + position.offset } ?? position.y
        var destination = clip.bounds; destination.origin.y = y
        let constrained = clip.constrainBoundsRect(destination).origin
        if abs(constrained.y - clip.bounds.minY) > 0.5 {
            clip.scroll(to: constrained); list.reflectScrolledClipView(clip)
        }
    }
    @objc private func openRowTask() {
        if compact { activateItem() } else { openTask() }
    }
    private func rememberFocus() {
        let responder = presentingWindow?.firstResponder
        if let editor = search.currentEditor() as? NSTextView, responder === editor, !filterBar.isHidden {
            let range = editor.selectedRange(), selection = AgentTextViewport.Selection(location: range.location, length: range.length)
            if selection.valid(in: states[activeTab].query.utf16.count) { states[activeTab].selection = selection }
            preferredFocus = .search
        } else if responder === table, !list.isHidden { preferredFocus = .list }
        else if responder === body, !details.isHidden { preferredFocus = .body }
        else if responder === reply, !replyField.isHidden, !details.isHidden { preferredFocus = .reply }
    }
    func focusCurrentPage(restoringSelection: Bool = false) {
        guard pendingRecovery == nil, isVisible, let owner = presentingWindow else { return }
        let view: NSView
        switch preferredFocus {
        case .list where !list.isHidden: view = table
        case .body where !details.isHidden: view = body
        case .reply where !replyField.isHidden && !details.isHidden: view = reply
        default: view = showingCompactDetail ? body : search
        }
        let selection = states[activeTab].selection?.range
        let focused = view === owner.firstResponder ||
            (view === search && search.currentEditor() === owner.firstResponder && owner.firstResponder != nil)
        owner.recalculateKeyViewLoop()
        guard focused || owner.makeFirstResponder(view) else { return }
        if view === search, restoringSelection || !focused, let selection {
            (search.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        }
    }
    @objc private func viewportChanged(_ notification: Notification) {
        guard onRecoveryChange != nil, pendingRecovery == nil, isVisible, !suppressSelection else { return }
        if notification.name == NSTextView.didChangeSelectionNotification {
            guard let text = notification.object as? NSTextView, text === body || text === reply || text === search.currentEditor() else { return }
        }
        rememberFocus(); onRecoveryChange?()
    }
    func captureRecovery(active: Bool) -> AgentAttentionRecovery? {
        if var pendingRecovery { pendingRecovery.active = active; return pendingRecovery }
        if isVisible { rememberFocus(); rememberListPosition() }
        let detail = selected.map { item in
            AgentAttentionRecovery.Detail(item: item.id, request: item.requestSignature, reading: detailRequested,
                body: pendingDetail?.body ?? (try? AgentTextViewport(body)),
                reply: pendingDetail?.reply ?? (!replyField.isHidden && replyLoaded ? try? AgentTextViewport(reply) : nil))
        }
        let value = AgentAttentionRecovery(active: active, tab: activeTab, lists: states, detail: detail, focus: preferredFocus)
        return value.valid ? value : nil
    }
    func restoreRecovery(_ value: AgentAttentionRecovery) {
        pendingRecovery = value; activeTab = value.tab; states = value.lists
        preferredFocus = value.focus; tabs.selectedSegment = activeTab; renderFilters()
    }
    private func applyDetailPosition() {
        guard !details.isHidden, let detail = pendingDetail, detail.item == selected?.id else { return }
        pendingDetail = nil
        guard detail.request == selected?.requestSignature else { return }
        if let bodyPosition = detail.body { bodyPosition.apply(to: body, focus: false) }
        if let replyPosition = detail.reply, !replyField.isHidden, replyLoaded {
            if replyPosition.matches(reply) { replyPosition.apply(to: reply, focus: false) }
            else {
                operationIssue = "答复草稿已更新，请核对后继续"
                status.stringValue = operationIssue ?? ""; status.textColor = AgentWorkbenchTheme.secondaryText
                updateVisibility()
            }
        }
    }
    private func select(_ menu: NSPopUpButton, value: String?) { menu.selectItem(at: menu.itemArray.firstIndex { $0.representedObject as? String == value } ?? 0) }
    private func renderFilters() {
        let value = states[activeTab]
        if search.stringValue != value.query { search.stringValue = value.query }
        select(kind, value: value.kind); select(source, value: value.source)
        time.selectItem(at: time.itemArray.firstIndex { $0.representedObject as? Int == value.days } ?? 0)
        filterBar.showsHistory = activeTab == 1
        sender.removeAllItems(); sender.addItem(withTitle: "全部发起者")
        var senders = Set(attention.items.filter { $0.handled == (activeTab == 1) }.map(\.sender)); if let selected = value.sender { senders.insert(selected) }
        for name in senders.sorted() { sender.addItem(withTitle: name); sender.lastItem?.representedObject = name }; select(sender, value: value.sender)
    }
    @objc private func changeTab() {
        guard persistReply() else { tabs.selectedSegment = activeTab; return }
        rememberFocus(); rememberListPosition()
        pendingRecovery = nil; pendingDetail = nil; needsSelection = false; detailRequested = false
        activeTab = tabs.selectedSegment; operationIssue = nil; refresh()
        restoreListPosition(); onRecoveryChange?()
    }
    @objc private func changeFilters() {
        guard persistReply() else { renderFilters(); return }
        var value = states[activeTab]; value.kind = kind.selectedItem?.representedObject as? String; value.source = source.selectedItem?.representedObject as? String
        value.days = time.selectedItem?.representedObject as? Int ?? 0; value.sender = sender.selectedItem?.representedObject as? String; value.limit = 50
        pendingRecovery = nil; value.position = nil
        states[activeTab] = value; operationIssue = nil; refresh(); onRecoveryChange?()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard persistReply() else { search.stringValue = states[activeTab].query; return }
        pendingRecovery = nil; states[activeTab].query = search.stringValue; states[activeTab].selection = nil
        states[activeTab].position = nil; operationIssue = nil; refresh(); onRecoveryChange?()
    }
    @objc private func loadMore() { guard persistReply() else { return }; states[activeTab].limit += 50; refresh(); onRecoveryChange?() }
    @objc private func reload() {
        if draftConflict == nil { operationIssue = nil }
        attention.refresh(force: true); refresh()
    }
    func refresh() {
        guard isVisible || selected == nil else { return }
        if pendingRecovery != nil, !isVisible || attention.loading { return }
        let restoring = pendingRecovery
        let state = states[activeTab], calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        let cutoff = state.days == 0 ? nil : calendar.date(byAdding: .day, value: state.days == 1 ? 0 : -(state.days - 1), to: today)
        let matching = attention.items.filter {
            $0.handled == (activeTab == 1) && (state.kind == nil || state.kind == $0.kind.rawValue) && (state.source == nil || state.source == $0.source.rawValue) &&
            (activeTab == 0 || (state.sender == nil || state.sender == $0.sender) && (cutoff == nil || $0.date >= cutoff!))
        }
        let loaded = Array(matching.prefix(state.limit)), query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = loaded.filter { query.isEmpty || $0.searchable.localizedCaseInsensitiveContains(query) }
        guard persistReply() else { return }
        let previous = state.item, wasReading = showingCompactDetail
        rows = next; renderFilters(); suppressSelection = true; table.reloadData()
        let savedRow = rows.firstIndex { item in
            item.id == previous && (restoring?.detail.map { $0.request == item.requestSignature } != false)
        }
        if restoring != nil, savedRow == nil {
            needsSelection = true
            if previous != nil { operationIssue = "原事项已变化，请从列表选择" }
        }
        if let savedRow { table.selectRowIndexes(IndexSet(integer: savedRow), byExtendingSelection: false) }
        else if !rows.isEmpty, !needsSelection { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        suppressSelection = false
        if restoring != nil {
            pendingDetail = savedRow == nil ? nil : restoring?.detail
            detailRequested = pendingDetail?.reading == true
        } else if savedRow == nil { detailRequested = false }
        empty.stringValue = query.isEmpty ? activeTab == 0 ? "暂无待关注的事项" : "暂无历史" : "没有匹配的事项"
        canLoadMore = loaded.count < matching.count; more.isEnabled = !attention.loading
        status.textColor = operationIssue != nil || attention.issue != nil ? .systemRed : AgentWorkbenchTheme.secondaryText
        status.stringValue = operationIssue ?? attention.issue ?? (!attention.settings.enabled ? "需要我已关闭" : attention.loading ? "正在载入…" : matching.isEmpty ? "" : "\(rows.count) 项 · 已加载 \(loaded.count)／\(matching.count)")
        showSelection()
        if restoring != nil {
            restoreListPosition()
            pendingRecovery = nil
            focusCurrentPage(restoringSelection: true); applyDetailPosition(); onRecoveryChange?()
        } else if previous != selected?.id { onRecoveryChange?() }
        if wasReading, !showingCompactDetail {
            restoreListPosition(); if !rows.isEmpty { presentingWindow?.makeFirstResponder(table) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]
        let title = NSTextField(labelWithString: item.title), summary = NSTextField(labelWithString: item.summary.replacingOccurrences(of: "\n", with: " "))
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 12); summary.textColor = AgentWorkbenchTheme.secondaryText; summary.lineBreakMode = .byTruncatingTail
        let info = NSTextField(labelWithString: item.kind.title + " · " + item.source.title); info.font = .systemFont(ofSize: 11); info.textColor = AgentWorkbenchTheme.secondaryText; info.lineBreakMode = .byTruncatingTail
        let view = NSTableCellView(); view.textField = title
        let labels = [title, summary, info]
        for (index, label) in labels.enumerated() {
            view.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1; label.toolTip = label.stringValue
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), label.heightAnchor.constraint(equalToConstant: index == 2 ? 14 : 16)])
            label.topAnchor.constraint(equalTo: index == 0 ? view.topAnchor : labels[index - 1].bottomAnchor, constant: index == 0 ? 10 : 4).isActive = true
        }
        view.setAccessibilityLabel(item.title + "，" + item.kind.title + "，" + (item.handled ? "已处理" : "待处理") + "，" + String(item.summary.prefix(80))); return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        guard persistReply() else {
            suppressSelection = true; if let row = rows.firstIndex(where: { $0.id == selected?.id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }; suppressSelection = false; return
        }
        pendingRecovery = nil; needsSelection = false
        if operationIssue == "原事项已变化，请从列表选择", rows.indices.contains(table.selectedRow) {
            states[activeTab].item = rows[table.selectedRow].id; operationIssue = nil; refresh(); onRecoveryChange?(); return
        }
        showSelection(); onRecoveryChange?()
    }
    private func outcome(_ item: AgentAttentionItem) -> String {
        guard let decision = item.decision else { return item.handled ? "已处理" : "待处理" }
        if decision.hasPrefix("answer:") { return "已答复：" + decision.dropFirst(7) }
        return ["allow": "已允许", "deny": "已拒绝", "skip": "已静默跳过，未收到答复", "ended": "请求已结束"][decision] ?? "已处理"
    }
    private func showSelection() {
        defer { updateVisibility(); hostedContent?.layoutSubtreeIfNeeded(); presentingWindow?.recalculateKeyViewLoop() }
        let item = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil, changed = item?.id != selected?.id
        selected = item; states[activeTab].item = item?.id; detailTitle.stringValue = item?.title ?? ""
        if pendingDetail?.item != item?.id { pendingDetail = nil }
        if changed, draftConflict != nil { draftConflict = nil; operationIssue = nil; status.stringValue = "" }
        guard let item else {
            metadata.stringValue = ""; body.string = ""
            for view in [replyCaption, replyField, open, mark, answer, allow, deny, execute] { view.isHidden = true }; return
        }
        let date = DateFormatter.localizedString(from: item.date, dateStyle: .medium, timeStyle: .short)
        metadata.stringValue = item.kind.title + " · " + item.source.title + " · " + item.sender + " · " + date
        metadata.toolTip = metadata.stringValue
        let text = item.body + (item.handled ? "\n\n" + outcome(item) : "") + (!item.handled && item.kind == .question && item.mcpInputID == nil ? runtime.questionSkipError(item.taskID).map { "\n\n" + $0 } ?? "" : "")
        if body.string != text { body.string = text }; open.isHidden = false
        let question = item.kind == .question && item.mcpInputID == nil
        mark.isHidden = item.callID != nil || item.mcpInputID != nil; mark.title = item.handled ? "标记待处理" : "标记已处理"
        allow.isHidden = item.kind != .approval || item.handled; deny.isHidden = allow.isHidden
        execute.isHidden = item.kind == .question || item.handled || !item.canExecutePlan
        if item.mcpInputID != nil { reply.string = ""; replySavedText = ""; replyLoaded = false }
        if question {
            if changed || !replyLoaded {
                do { reply.string = try attention.replyDraft(item); replySavedText = reply.string; replyLoaded = true; reply.undoManager?.removeAllActions() }
                catch { reply.string = ""; replySavedText = ""; replyLoaded = false; operationIssue = "答复草稿无法读取：" + error.localizedDescription }
            }
            replyCaption.isHidden = item.handled && reply.string.isEmpty; replyField.isHidden = replyCaption.isHidden
            reply.isEditable = !item.handled && replyLoaded
        } else { replyCaption.isHidden = true; replyField.isHidden = true }
        updateActions()
    }
    func checkQuestionInteractionFocus() async -> Bool {
        guard CommandLine.arguments.contains("--attention-page-check"), isVisible, let item = selected, item.kind == .question, item.mcpInputID == nil, !item.handled, let owner = presentingWindow else { return false }
        owner.makeFirstResponder(reply); let text = reply.string, range = reply.selectedRange()
        runtime.questionInteraction(item.taskID); refresh(); try? await Task.sleep(nanoseconds: 100_000_000)
        return owner.firstResponder === reply && reply.string == text && reply.selectedRange() == range
    }
    private func updateActions() {
        let enabled = attention.settings.enabled && !attention.loading
        for button in [mark, allow, deny, execute] { button.isEnabled = enabled }
        answer.isEnabled = enabled && draftConflict == nil && replyLoaded && !reply.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === reply else { return }; updateActions(); draftSave?.cancel()
        guard draftConflict == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, persistReply() else { return }; onRecoveryChange?()
        }
        draftSave = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    @discardableResult private func persistReply() -> Bool {
        draftSave?.cancel(); draftSave = nil
        guard let item = selected, item.kind == .question, item.mcpInputID == nil else { return true }
        do {
            if reply.string != replySavedText {
                guard draftConflict == nil else { return false }
                try attention.saveReply(item, text: reply.string, expected: replySavedText); replySavedText = reply.string
            }
            if draftConflict == nil, operationIssue?.hasPrefix("答复草稿未保存：") == true { operationIssue = nil; status.stringValue = "答复草稿已保存"; status.textColor = AgentWorkbenchTheme.secondaryText; updateVisibility() }
            return true
        } catch let conflict as AgentAttention.DraftConflict {
            showDraftConflict(conflict); return false
        } catch {
            showDraftIssue("答复草稿未保存：" + error.localizedDescription); return false
        }
    }
    private func showDraftIssue(_ message: String) {
        operationIssue = message; status.stringValue = message; status.textColor = .systemRed
        updateVisibility(); updateActions()
    }
    private func showDraftConflict(_ conflict: AgentAttention.DraftConflict) {
        draftSave?.cancel(); draftSave = nil
        draftConflict = conflict; showingSavedDraft = true
        savedDraft.string = conflict.current.isEmpty ? "当前没有已保存的答复" : conflict.current
        savedDraftScroll.contentView.scroll(to: .zero); savedDraftScroll.reflectScrolledClipView(savedDraftScroll.contentView)
        showDraftIssue("答复草稿已更新，请核对后选择")
        presentingWindow?.recalculateKeyViewLoop()
    }
    @objc private func toggleSavedDraft() {
        guard draftConflict != nil else { return }
        showingSavedDraft.toggle(); updateVisibility(); presentingWindow?.recalculateKeyViewLoop()
    }
    @objc private func loadReviewedDraft() { resolveDraft(keepLocal: false) }
    @objc private func saveReviewedDraft() { resolveDraft(keepLocal: true) }
    private func resolveDraft(keepLocal: Bool) {
        guard let item = selected, let conflict = draftConflict else { return }
        do {
            let current = try attention.replyDraft(item)
            guard current == conflict.current else { throw AgentAttention.DraftConflict(current: current) }
            if keepLocal {
                try attention.saveReply(item, text: reply.string, expected: current)
            } else {
                reply.string = current; reply.undoManager?.removeAllActions()
            }
            replySavedText = reply.string; draftConflict = nil; operationIssue = nil
            refresh(); onRecoveryChange?()
            if !reply.isHiddenOrHasHiddenAncestor { presentingWindow?.makeFirstResponder(reply) }
        } catch let conflict as AgentAttention.DraftConflict {
            showDraftConflict(conflict)
        } catch { showDraftIssue(error.localizedDescription) }
    }
    @objc private func openTask() { if persistReply(), let item = selected { onOpenTask?(item.taskID) } }
    @objc private func markHandled() { perform { guard let item = self.selected else { return nil }; try self.attention.mark(item, handled: !item.handled); return nil } }
    @objc private func answerQuestion() {
        guard draftConflict == nil else { return }
        perform {
            guard let item = self.selected else { return nil }
            let warning = try self.attention.decide(item, decision: "answer:" + self.reply.string, runtime: self.runtime)
            self.reply.string = ""; self.replySavedText = ""; return warning
        }
    }
    @objc private func allowRequest() { decide("allow") }
    @objc private func denyRequest() { decide("deny") }
    private func decide(_ value: String) { perform { guard let item = self.selected else { return nil }; return try self.attention.decide(item, decision: value, runtime: self.runtime) } }
    @objc private func executePlan() { perform { guard let item = self.selected else { return nil }; try self.attention.executePlan(item, runtime: self.runtime); return nil } }
    private func perform(_ action: () throws -> String?) {
        guard persistReply() else { return }
        do { operationIssue = try action() }
        catch let conflict as AgentAttention.DraftConflict { showDraftConflict(conflict); return }
        catch { operationIssue = error.localizedDescription }
        refresh()
    }
    func prepareToClose() -> Bool {
        guard persistReply() else { return false }
        rememberFocus(); rememberListPosition(); return true
    }
    func requireDeletionAllowed(_ ids: Set<String>) throws { if let item = selected, ids.contains(item.taskID), reply.string != replySavedText { throw PetError("请先保存需要我窗口中的答复草稿") } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { prepareToClose() }
    func windowWillClose(_ notification: Notification) { draftSave?.cancel() }
    @objc func showSettings() {
        if persistReply() { onOpenSettings?() }
    }
    func checkPageControls() throws -> [String: Bool] {
        guard CommandLine.arguments.contains("--attention-page-check") else { return [:] }
        var checks: [String: Bool] = [:]
        select(kind, value: AgentAttentionKind.question.rawValue); changeFilters()
        checks["questionFilterUsesActualWaitingRequests"] = !rows.isEmpty && rows.allSatisfy { $0.kind == .question && !$0.handled }
        search.stringValue = "子任务确认输出格式"; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        checks["searchSelectsActualChildRequest"] = rows.count == 1 && selected?.source == .agent && selected?.title == search.stringValue
        guard let item = selected else { throw PetError("缺少实际问题") }
        checkSetReply("公开的需要我答复草稿。")
        checks["replyPersistsThroughExistingStore"] = try prepareToClose() && attention.replyDraft(item) == reply.string
        tabs.selectedSegment = 1; changeTab()
        checks["historyHasIndependentFilters"] = activeTab == 1 && search.stringValue.isEmpty && kind.selectedItem?.representedObject == nil && rows.allSatisfy(\.handled)
        checks["emptyHistoryHasOneClearMessage"] = rows.isEmpty && !empty.isHidden && empty.stringValue == "暂无历史" && status.stringValue.isEmpty
        tabs.selectedSegment = 0; changeTab()
        checks["pendingFiltersSelectionAndReplyReturn"] = activeTab == 0 && search.stringValue == "子任务确认输出格式" && selected?.id == item.id && reply.string == "公开的需要我答复草稿。"
        var next = search.nextKeyView, visited = Set<ObjectIdentifier>(), includesReply = false
        while let view = next, visited.insert(ObjectIdentifier(view)).inserted, visited.count <= 512 {
            if view === reply { includesReply = true }; next = view.nextKeyView
        }
        checks["dynamicQuestionReplyIsInKeyboardLoop"] = includesReply && reply.canBecomeKeyView
        return checks
    }
    func checkSetReply(_ value: String) {
        guard CommandLine.arguments.contains("--attention-page-check") else { return }
        reply.string = value; textDidChange(Notification(name: NSText.didChangeNotification, object: reply))
    }
    @discardableResult func checkChooseTask(_ id: String, decision: String? = nil) -> Bool {
        guard CommandLine.arguments.contains("--attention-page-check"), let item = attention.items.first(where: { $0.taskID == id && $0.callID != nil && !$0.handled }) else { return false }
        tabs.selectedSegment = 0; changeTab(); select(kind, value: item.kind.rawValue); select(source, value: nil); changeFilters()
        search.stringValue = item.title; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        guard selected?.id == item.id else { return false }
        if let decision {
            if compact, !checkOpenReading() { return false }
            if decision == "allow" { allow.performClick(nil) }
            else if decision == "deny" { deny.performClick(nil) }
            else { checkSetReply(decision); answer.performClick(nil) }
        }
        return true
    }
    func checkPageGeometry() -> [String: Any] {
        guard CommandLine.arguments.contains("--attention-page-check"), let root = hostedContent else { return [:] }
        root.layoutSubtreeIfNeeded()
        let bounds = root.bounds, panel = panes.convert(panes.bounds, to: root)
        var checks = ["contentIsHostedByOwner": root.window === hostWindow && window?.isVisible == false,
                      "panesFitPage": panel.minX >= 27.5 && panel.maxX <= bounds.maxX - 27.5,
                      "filterControlsFitWithoutOverlap": filterBar.isHidden || filterBar.controlsFit]
        if !list.isHidden {
            checks["visibleListUsesAvailableWidth"] = compact ? abs(list.bounds.width - panes.bounds.width) < 0.5 : list.bounds.width >= 179.5
        }
        if !details.isHidden {
            let leading = compact ? 0 : list.frame.maxX + 32
            checks["detailFillsAvailableWidth"] = abs(details.frame.maxX - panes.bounds.maxX) < 0.5 && abs(details.frame.minX - leading) < 0.5
            checks["textUsesDetailWidth"] = body.bounds.width >= details.bounds.width - 24
            checks["replyFieldFitsAndHasVisibleBorder"] = replyField.isHidden ||
                bounds.contains(replyField.convert(replyField.bounds, to: root)) && replyField.layer?.borderWidth == 1 && replyScroll.frame.minX >= 1
            checks["actionsFitHeight"] = details.arrangedSubviews.last.map { bounds.contains($0.convert($0.bounds, to: root)) } ?? false
        }
        return ["checks": checks, "mode": compact ? showingCompactDetail ? "detail" : "list" : "split",
                "pageWidth": bounds.width, "listWidth": list.isHidden ? 0 : list.bounds.width,
                "detailWidth": details.isHidden ? 0 : details.bounds.width, "bodyWidth": details.isHidden ? 0 : body.bounds.width,
                "bodyHeight": details.isHidden ? 0 : bodyScroll.contentSize.height]
    }
    func checkHistoryFilterGeometry() -> Bool {
        guard CommandLine.arguments.contains("--attention-page-check") else { return false }
        let previous = activeTab
        tabs.selectedSegment = 1; changeTab(); hostedContent?.layoutSubtreeIfNeeded()
        let fits = filterBar.controlsFit && !time.isHidden && !sender.isHidden
        tabs.selectedSegment = previous; changeTab(); hostedContent?.layoutSubtreeIfNeeded()
        return fits
    }
    func checkOpenReading() -> Bool {
        guard CommandLine.arguments.contains("--attention-page-check"), compact, let owner = presentingWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: owner.windowNumber, context: nil, characters: "\r",
                                           charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return false }
        if !showingCompactDetail { owner.makeFirstResponder(table); table.keyDown(with: event) }
        return showingCompactDetail
    }
    func checkCompactReading(capture: (String) throws -> Void) throws -> [String: Bool] {
        guard CommandLine.arguments.contains("--attention-page-check"), compact, let selected, reply.isEditable,
              let owner = presentingWindow else { throw PetError("需要一条可编辑的窄窗问题") }
        let draft = reply.string, itemID = selected.id, query = search.stringValue, previousKind = kind.selectedItem?.representedObject as? String
        if showingCompactDetail { back.performClick(nil) }
        var checks = ["startsInListWithFilters": !showingCompactDetail && !list.isHidden && details.isHidden && !filterBar.isHidden]
        try capture("narrow-list")
        checks["returnOpensSelectedItemAndFocusesBody"] = checkOpenReading() && owner.firstResponder === body &&
            self.selected?.id == itemID && list.isHidden && filterBar.isHidden && !back.isHidden && reply.string == draft
        let geometry = checkPageGeometry()
        checks["detailUsesFullWidthAndKeepsReplyAndActionsVisible"] = (geometry["bodyWidth"] as? CGFloat ?? 0) >= 490 &&
            (geometry["bodyHeight"] as? CGFloat ?? 0) >= 120 && (geometry["checks"] as? [String: Bool])?.values.allSatisfy { $0 } == true
        owner.makeFirstResponder(reply); reply.setSelectedRange(NSRange(location: 1, length: 4))
        try capture("narrow-detail")
        let oversized = String(repeating: "a", count: 65_537)
        checkSetReply(oversized); back.performClick(nil)
        checks["failedDraftSaveKeepsDetailAndShowsError"] = showingCompactDetail && !footer.isHidden && !status.isHidden &&
            status.stringValue.hasPrefix("答复草稿未保存") && reply.string == oversized && owner.firstResponder === reply
        checkSetReply(draft); back.performClick(nil)
        checks["backRestoresOriginalListFilterAndKeyboardFocus"] = !showingCompactDetail && self.selected?.id == itemID &&
            search.stringValue == query && kind.selectedItem?.representedObject as? String == previousKind && owner.firstResponder === table
        checks["sameRowReopensWithItsOwnDraft"] = checkOpenReading() && self.selected?.id == itemID && reply.string == draft
        back.performClick(nil)
        select(kind, value: nil); changeFilters()
        search.stringValue = ""; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        hostedContent?.layoutSubtreeIfNeeded()
        if !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
        let offset = list.contentView.bounds.minY
        let selectedBefore = table.selectedRow
        _ = checkOpenReading(); back.performClick(nil)
        checks["returnRestoresActualScrolledList"] = offset > 0 && abs(list.contentView.bounds.minY - offset) < 1 &&
            table.selectedRow == selectedBefore
        select(kind, value: previousKind); changeFilters()
        search.stringValue = query; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        return checks
    }
    func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--attention-live-ui") || CommandLine.arguments.contains("--attention-page-check") else { return [:] }
        let state = states[activeTab]
        return ["visible": isVisible, "embedded": hostWindow != nil, "tab": activeTab, "query": state.query, "kind": state.kind as Any? ?? NSNull(), "source": state.source as Any? ?? NSNull(), "sender": state.sender as Any? ?? NSNull(), "days": state.days, "limit": state.limit, "rows": rows.map { ["id": $0.id, "taskID": $0.taskID, "kind": $0.kind.rawValue, "handled": $0.handled] as [String: Any] }, "selected": selected?.id as Any? ?? NSNull(), "reply": reply.string, "status": status.stringValue, "pendingCount": attention.pendingCount, "enabled": attention.settings.enabled, "loading": attention.loading, "settingsVisible": false, "reading": showingCompactDetail]
    }
}
