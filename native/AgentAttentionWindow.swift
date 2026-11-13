import AppKit

@MainActor final class AgentAttentionWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate {
    var onOpenSettings: (() -> Void)?
    private struct ListState { var query = "", kind: String?, source: String?, sender: String?; var days = 0, limit = 50 }
    private let attention: AgentAttention, runtime: AgentRuntime
    private let tabs = NSSegmentedControl(labels: ["待关注", "历史"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), kind = NSPopUpButton(), source = NSPopUpButton(), time = NSPopUpButton(), sender = NSPopUpButton()
    private let table = NSTableView(), status = NSTextField(labelWithString: ""), more = NSButton(title: "加载更多", target: nil, action: nil)
    private let detailTitle = NSTextField(wrappingLabelWithString: ""), metadata = NSTextField(labelWithString: ""), body = NSTextView()
    private let reply = NSTextView(), replyScroll = NSScrollView(), replyCaption = NSTextField(labelWithString: "答复")
    private let replyField = AgentThemeView(fill: .textBackgroundColor, stroke: AgentWorkbenchTheme.line)
    private let open = NSButton(title: "打开任务", target: nil, action: nil), mark = NSButton(title: "标记已处理", target: nil, action: nil)
    private let answer = NSButton(title: "回复并继续", target: nil, action: nil), allow = NSButton(title: "允许一次", target: nil, action: nil), deny = NSButton(title: "拒绝", target: nil, action: nil)
    private let execute = NSButton(title: "采纳计划并执行", target: nil, action: nil)
    private var states = [ListState(), ListState()], activeTab = 0, rows: [AgentAttentionItem] = [], selected: AgentAttentionItem?
    private var suppressSelection = false, draftSave: DispatchWorkItem?, operationIssue: String?
    private var replySavedText = "", replyLoaded = true
    private weak var hostWindow: NSWindow?
    private var hostedContent: NSView?
    private let panes = NSView(), empty = NSTextField(labelWithString: "暂无待关注的事项")
    private var contentTop: NSLayoutConstraint!
    var presentingWindow: NSWindow? { hostWindow ?? window }
    var isVisible: Bool { (hostedContent?.window?.isVisible ?? window?.isVisible ?? false) && hostedContent?.isHiddenOrHasHiddenAncestor != true }
    var onOpenTask: ((String) -> Void)?
    func questionFocused(_ id: String) -> Bool {
        isVisible && presentingWindow?.isKeyWindow == true && selected?.taskID == id && selected?.kind == .question && selected?.mcpInputID == nil && selected?.handled == false
    }
    func questionInteraction(_ event: NSEvent) -> String? {
        guard isVisible, let item = selected, item.kind == .question, !item.handled, item.mcpInputID == nil else { return nil }
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
        let title = NSTextField(labelWithString: "需要我"); title.font = .systemFont(ofSize: 20, weight: .semibold)
        let heading = NSStackView(views: [title, NSView(), reload, settings]); heading.spacing = 8
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab); tabs.setAccessibilityLabel("需要我列表")
        search.placeholderString = "搜索当前列表"; search.setAccessibilityLabel("搜索需要我当前列表"); search.delegate = self
        let navigation = NSStackView(views: [tabs, NSView(), search]); search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        for (menu, label) in [(kind, "筛选待办类型"), (source, "筛选待办来源"), (time, "筛选处理时间"), (sender, "筛选发起者")] {
            menu.target = self; menu.action = #selector(changeFilters); menu.setAccessibilityLabel(label); menu.cell?.lineBreakMode = .byTruncatingTail
            menu.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true
        }
        kind.addItem(withTitle: "全部类型"); for value in AgentAttentionKind.allCases { kind.addItem(withTitle: value.title); kind.lastItem?.representedObject = value.rawValue }
        source.addItem(withTitle: "全部来源"); for value in AgentAttentionSource.allCases { source.addItem(withTitle: value.title); source.lastItem?.representedObject = value.rawValue }
        for (label, days) in [("全部时间", 0), ("今天", 1), ("最近7天", 7), ("最近30天", 30)] { time.addItem(withTitle: label); time.lastItem?.representedObject = days }
        let filters = NSStackView(views: [kind, source, time, sender, NSView()]); filters.spacing = 8
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("attention"))); table.headerView = nil; table.rowHeight = 77
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openTask); table.setAccessibilityLabel("需要我事项列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        table.style = .inset; table.backgroundColor = .clear
        detailTitle.font = .systemFont(ofSize: 16, weight: .semibold); detailTitle.maximumNumberOfLines = 3
        metadata.font = .systemFont(ofSize: 11); metadata.textColor = AgentWorkbenchTheme.secondaryText; metadata.lineBreakMode = .byTruncatingTail
        for text in [body, reply] {
            text.isRichText = false; text.font = .systemFont(ofSize: 13); text.textColor = .labelColor; text.drawsBackground = false; text.textContainerInset = NSSize(width: 10, height: 10)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        }
        body.isEditable = false; body.setAccessibilityLabel("需要我事项详情")
        let document = NSScrollView(); document.documentView = body; document.hasVerticalScroller = true
        reply.delegate = self; reply.allowsUndo = true; reply.setAccessibilityLabel("答复此问题"); replyScroll.documentView = reply; replyScroll.hasVerticalScroller = true; replyScroll.borderType = .bezelBorder
        replyField.addSubview(replyScroll); replyScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([replyScroll.leadingAnchor.constraint(equalTo: replyField.leadingAnchor, constant: 1), replyScroll.trailingAnchor.constraint(equalTo: replyField.trailingAnchor, constant: -1), replyScroll.topAnchor.constraint(equalTo: replyField.topAnchor, constant: 1), replyScroll.bottomAnchor.constraint(equalTo: replyField.bottomAnchor, constant: -1), replyField.heightAnchor.constraint(equalToConstant: 88)])
        replyCaption.font = .systemFont(ofSize: 12, weight: .medium)
        for (button, action) in [(open, #selector(openTask)), (mark, #selector(markHandled)), (answer, #selector(answerQuestion)), (allow, #selector(allowRequest)), (deny, #selector(denyRequest)), (execute, #selector(executePlan))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        let actions = NSStackView(views: [open, NSView(), mark, deny, allow, execute, answer]); actions.spacing = 6
        let details = NSStackView(views: [detailTitle, metadata, document, replyCaption, replyField, actions]); details.orientation = .vertical; details.alignment = .leading; details.spacing = 10
        for child in details.arrangedSubviews { child.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true }
        for view in [list, details, empty] { panes.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        let listWidth = list.widthAnchor.constraint(equalToConstant: 260); listWidth.priority = .init(499)
        empty.font = .systemFont(ofSize: 14); empty.textColor = AgentWorkbenchTheme.secondaryText
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: panes.leadingAnchor), list.topAnchor.constraint(equalTo: panes.topAnchor), list.bottomAnchor.constraint(equalTo: panes.bottomAnchor), list.widthAnchor.constraint(greaterThanOrEqualToConstant: 180), list.widthAnchor.constraint(lessThanOrEqualTo: panes.widthAnchor, multiplier: 0.4), listWidth, details.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 20), details.trailingAnchor.constraint(equalTo: panes.trailingAnchor), details.topAnchor.constraint(equalTo: panes.topAnchor), details.bottomAnchor.constraint(equalTo: panes.bottomAnchor), empty.centerXAnchor.constraint(equalTo: panes.centerXAnchor), empty.centerYAnchor.constraint(equalTo: panes.centerYAnchor)])
        for scroll in [list, document, replyScroll] { scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder; scroll.drawsBackground = false }
        replyField.layer?.cornerRadius = 8; replyField.layer?.masksToBounds = true; replyField.layer?.borderWidth = 1
        status.font = .systemFont(ofSize: 12); status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 2; status.setAccessibilityLabel("需要我状态")
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        more.target = self; more.action = #selector(loadMore); let footer = NSStackView(views: [status, NSView(), more]); footer.spacing = 8
        let content = NSStackView(views: [heading, navigation, filters, panes, footer]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 13
        let root = AgentThemeView(fill: AgentWorkbenchTheme.surface); root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false; window.contentView = root
        root.setAccessibilityLabel("需要我主页面")
        contentTop = content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18)
        let width = content.widthAnchor.constraint(equalToConstant: 824); width.priority = .init(499)
        NSLayoutConstraint.activate([content.centerXAnchor.constraint(equalTo: root.centerXAnchor), content.widthAnchor.constraint(lessThanOrEqualToConstant: 824), content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 28), content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28), width, contentTop, content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)])
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        panes.setContentHuggingPriority(.defaultLow, for: .vertical); document.setContentHuggingPriority(.defaultLow, for: .vertical)
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
    func focusSearch() { presentingWindow?.recalculateKeyViewLoop(); presentingWindow?.makeFirstResponder(search) }
    private func select(_ menu: NSPopUpButton, value: String?) { menu.selectItem(at: menu.itemArray.firstIndex { $0.representedObject as? String == value } ?? 0) }
    private func renderFilters() {
        let value = states[activeTab]; search.stringValue = value.query; select(kind, value: value.kind); select(source, value: value.source)
        time.selectItem(at: time.itemArray.firstIndex { $0.representedObject as? Int == value.days } ?? 0)
        time.isHidden = activeTab == 0; sender.isHidden = activeTab == 0
        sender.removeAllItems(); sender.addItem(withTitle: "全部发起者")
        var senders = Set(attention.items.filter { $0.handled == (activeTab == 1) }.map(\.sender)); if let selected = value.sender { senders.insert(selected) }
        for name in senders.sorted() { sender.addItem(withTitle: name); sender.lastItem?.representedObject = name }; select(sender, value: value.sender)
    }
    @objc private func changeTab() {
        guard persistReply() else { tabs.selectedSegment = activeTab; return }
        activeTab = tabs.selectedSegment; operationIssue = nil; renderFilters(); refresh()
    }
    @objc private func changeFilters() {
        guard persistReply() else { renderFilters(); return }
        var value = states[activeTab]; value.kind = kind.selectedItem?.representedObject as? String; value.source = source.selectedItem?.representedObject as? String
        value.days = time.selectedItem?.representedObject as? Int ?? 0; value.sender = sender.selectedItem?.representedObject as? String; value.limit = 50
        states[activeTab] = value; operationIssue = nil; refresh()
    }
    func controlTextDidChange(_ notification: Notification) { guard persistReply() else { search.stringValue = states[activeTab].query; return }; states[activeTab].query = search.stringValue; operationIssue = nil; refresh() }
    @objc private func loadMore() { guard persistReply() else { return }; states[activeTab].limit += 50; refresh() }
    @objc private func reload() { operationIssue = nil; attention.refresh(force: true); refresh() }
    func refresh() {
        guard isVisible || selected == nil else { return }
        let state = states[activeTab], calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        let cutoff = state.days == 0 ? nil : calendar.date(byAdding: .day, value: state.days == 1 ? 0 : -(state.days - 1), to: today)
        let matching = attention.items.filter {
            $0.handled == (activeTab == 1) && (state.kind == nil || state.kind == $0.kind.rawValue) && (state.source == nil || state.source == $0.source.rawValue) &&
            (activeTab == 0 || (state.sender == nil || state.sender == $0.sender) && (cutoff == nil || $0.date >= cutoff!))
        }
        let loaded = Array(matching.prefix(state.limit)), query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = loaded.filter { query.isEmpty || $0.searchable.localizedCaseInsensitiveContains(query) }
        guard persistReply() else { return }
        let previous = selected?.id; rows = next; renderFilters(); suppressSelection = true; table.reloadData()
        if let row = rows.firstIndex(where: { $0.id == previous }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        suppressSelection = false; showSelection()
        for view in panes.subviews where view !== empty { view.isHidden = rows.isEmpty }
        empty.isHidden = !rows.isEmpty; empty.stringValue = query.isEmpty ? activeTab == 0 ? "暂无待关注的事项" : "暂无历史" : "没有匹配的事项"
        more.isHidden = loaded.count >= matching.count; more.isEnabled = !attention.loading
        status.textColor = operationIssue != nil || attention.issue != nil ? .systemRed : AgentWorkbenchTheme.secondaryText
        status.stringValue = operationIssue ?? attention.issue ?? (!attention.settings.enabled ? "需要我已关闭" : attention.loading ? "正在载入…" : matching.isEmpty ? "" : "\(rows.count) 项 · 已加载 \(loaded.count)／\(matching.count)")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]
        let title = NSTextField(labelWithString: item.title), summary = NSTextField(labelWithString: item.summary.replacingOccurrences(of: "\n", with: " "))
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 11); summary.textColor = AgentWorkbenchTheme.secondaryText; summary.lineBreakMode = .byTruncatingTail
        let info = NSTextField(labelWithString: item.kind.title + " · " + item.source.title + " · " + item.sender); info.font = .systemFont(ofSize: 10); info.textColor = .tertiaryLabelColor; info.lineBreakMode = .byTruncatingTail
        let view = NSStackView(views: [title, summary, info]); view.orientation = .vertical; view.alignment = .leading; view.spacing = 5
        view.setAccessibilityLabel(item.title + "，" + item.kind.title + "，" + (item.handled ? "已处理" : "待处理") + "，" + String(item.summary.prefix(80))); return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        guard persistReply() else {
            suppressSelection = true; if let row = rows.firstIndex(where: { $0.id == selected?.id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }; suppressSelection = false; return
        }; showSelection()
    }
    private func outcome(_ item: AgentAttentionItem) -> String {
        guard let decision = item.decision else { return item.handled ? "已处理" : "待处理" }
        if decision.hasPrefix("answer:") { return "已答复：" + decision.dropFirst(7) }
        return ["allow": "已允许", "deny": "已拒绝", "skip": "已静默跳过，未收到答复", "ended": "请求已结束"][decision] ?? "已处理"
    }
    private func showSelection() {
        defer { hostedContent?.layoutSubtreeIfNeeded(); presentingWindow?.recalculateKeyViewLoop() }
        let item = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil, changed = item?.id != selected?.id
        selected = item; detailTitle.stringValue = item?.title ?? ""; metadata.stringValue = ""; body.string = ""
        for view in [replyCaption, replyField, open, mark, answer, allow, deny, execute] { view.isHidden = true }
        guard let item else { return }
        let date = DateFormatter.localizedString(from: item.date, dateStyle: .medium, timeStyle: .short)
        metadata.stringValue = item.kind.title + " · " + item.source.title + " · " + item.sender + " · " + date
        let text = item.body + (item.handled ? "\n\n" + outcome(item) : "") + (!item.handled && item.kind == .question && item.mcpInputID == nil ? runtime.questionSkipError(item.taskID).map { "\n\n" + $0 } ?? "" : "")
        body.string = text; open.isHidden = false
        if item.mcpInputID != nil { reply.string = ""; replySavedText = ""; replyLoaded = false; updateActions(); return }
        mark.isHidden = item.callID != nil; mark.title = item.handled ? "标记待处理" : "标记已处理"
        if item.kind == .question {
            if changed || !replyLoaded {
                do { reply.string = try attention.replyDraft(item); replySavedText = reply.string; replyLoaded = true; reply.undoManager?.removeAllActions() }
                catch { reply.string = ""; replySavedText = ""; replyLoaded = false; operationIssue = "答复草稿无法读取：" + error.localizedDescription }
            }
            replyCaption.isHidden = item.handled && reply.string.isEmpty; replyField.isHidden = replyCaption.isHidden
            replyCaption.stringValue = item.handled ? "未发送答复" : "答复"; reply.isEditable = !item.handled && replyLoaded
            answer.isHidden = item.handled
        } else if !item.handled { allow.isHidden = item.kind != .approval; deny.isHidden = allow.isHidden; execute.isHidden = !item.canExecutePlan }
        updateActions()
    }
    private func updateActions() {
        let enabled = attention.settings.enabled && !attention.loading
        for button in [mark, allow, deny, execute] { button.isEnabled = enabled }
        answer.isEnabled = enabled && replyLoaded && !reply.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === reply else { return }; updateActions(); draftSave?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.persistReply() }; draftSave = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    @discardableResult private func persistReply() -> Bool {
        draftSave?.cancel(); draftSave = nil
        guard let item = selected, item.kind == .question, item.mcpInputID == nil, reply.string != replySavedText else { return true }
        do {
            try attention.saveReply(item, text: reply.string); replySavedText = reply.string
            if operationIssue?.hasPrefix("答复草稿未保存：") == true { operationIssue = nil; status.stringValue = "答复草稿已保存"; status.textColor = AgentWorkbenchTheme.secondaryText }
            return true
        }
        catch { operationIssue = "答复草稿未保存：" + error.localizedDescription; status.stringValue = operationIssue!; status.textColor = .systemRed; return false }
    }
    @objc private func openTask() { if persistReply(), let item = selected { onOpenTask?(item.taskID) } }
    @objc private func markHandled() { perform { guard let item = self.selected else { return nil }; try self.attention.mark(item, handled: !item.handled); return nil } }
    @objc private func answerQuestion() { perform { guard let item = self.selected else { return nil }; let warning = try self.attention.decide(item, decision: "answer:" + self.reply.string, runtime: self.runtime); self.reply.string = ""; self.replySavedText = ""; return warning } }
    @objc private func allowRequest() { decide("allow") }
    @objc private func denyRequest() { decide("deny") }
    private func decide(_ value: String) { perform { guard let item = self.selected else { return nil }; return try self.attention.decide(item, decision: value, runtime: self.runtime) } }
    @objc private func executePlan() { perform { guard let item = self.selected else { return nil }; try self.attention.executePlan(item, runtime: self.runtime); return nil } }
    private func perform(_ action: () throws -> String?) {
        guard persistReply() else { return }
        do { operationIssue = try action() } catch { operationIssue = error.localizedDescription }
        refresh()
    }
    func prepareToClose() -> Bool { persistReply() }
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
            if decision == "allow" { allowRequest() }
            else if decision == "deny" { denyRequest() }
            else { checkSetReply(decision); answerQuestion() }
        }
        return true
    }
    func checkPageGeometry() -> [String: Any] {
        guard CommandLine.arguments.contains("--attention-page-check"), let root = hostedContent, let list = panes.subviews.first, panes.subviews.count >= 2 else { return [:] }
        root.layoutSubtreeIfNeeded()
        let detail = panes.subviews[1], bounds = root.bounds, panel = panes.convert(panes.bounds, to: root)
        let actionView = (detail as? NSStackView)?.arrangedSubviews.last
        let checks = ["contentIsHostedByOwner": root.window === hostWindow && window?.isVisible == false, "bothPanesFitPage": panel.minX >= 27.5 && panel.maxX <= bounds.maxX - 27.5 && list.bounds.width >= 179.5 && detail.bounds.width >= 259, "detailFillsAvailableWidth": abs(detail.frame.maxX - panes.bounds.maxX) < 0.5 && abs(detail.frame.minX - list.frame.maxX - 20) < 0.5, "textUsesDetailWidth": body.bounds.width >= detail.bounds.width - 24, "replyFieldFitsAndHasVisibleBorder": replyField.isHidden || bounds.contains(replyField.convert(replyField.bounds, to: root)) && replyField.layer?.borderWidth == 1 && replyScroll.frame.minX >= 1, "actionsFitHeight": actionView.map { bounds.contains($0.convert($0.bounds, to: root)) } ?? false]
        return ["checks": checks, "pageWidth": bounds.width, "listWidth": list.bounds.width, "detailWidth": detail.bounds.width, "bodyWidth": body.bounds.width]
    }
    func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--attention-live-ui") || CommandLine.arguments.contains("--attention-page-check") else { return [:] }
        let state = states[activeTab]
        return ["visible": isVisible, "embedded": hostWindow != nil, "tab": activeTab, "query": state.query, "kind": state.kind as Any? ?? NSNull(), "source": state.source as Any? ?? NSNull(), "sender": state.sender as Any? ?? NSNull(), "days": state.days, "limit": state.limit, "rows": rows.map { ["id": $0.id, "taskID": $0.taskID, "kind": $0.kind.rawValue, "handled": $0.handled] as [String: Any] }, "selected": selected?.id as Any? ?? NSNull(), "reply": reply.string, "status": status.stringValue, "pendingCount": attention.pendingCount, "enabled": attention.settings.enabled, "loading": attention.loading, "settingsVisible": false]
    }
}
