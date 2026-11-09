import AppKit

@MainActor final class AgentAttentionWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate {
    private struct ListState { var query = "", kind: String?, source: String?, sender: String?; var days = 0, limit = 50 }
    private let attention: AgentAttention, runtime: AgentRuntime
    private let tabs = NSSegmentedControl(labels: ["待处理", "已处理"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), kind = NSPopUpButton(), source = NSPopUpButton(), time = NSPopUpButton(), sender = NSPopUpButton()
    private let table = NSTableView(), status = NSTextField(labelWithString: ""), more = NSButton(title: "加载更多", target: nil, action: nil)
    private let detailTitle = NSTextField(wrappingLabelWithString: ""), metadata = NSTextField(labelWithString: ""), body = NSTextView()
    private let reply = NSTextView(), replyScroll = NSScrollView(), replyCaption = NSTextField(labelWithString: "答复")
    private let open = NSButton(title: "打开任务", target: nil, action: nil), mark = NSButton(title: "标记已处理", target: nil, action: nil)
    private let answer = NSButton(title: "回复并继续", target: nil, action: nil), allow = NSButton(title: "允许一次", target: nil, action: nil), deny = NSButton(title: "拒绝", target: nil, action: nil)
    private let execute = NSButton(title: "采纳计划并执行", target: nil, action: nil)
    private var states = [ListState(), ListState()], activeTab = 0, rows: [AgentAttentionItem] = [], selected: AgentAttentionItem?
    private var suppressSelection = false, draftSave: DispatchWorkItem?, operationIssue: String?
    private var replySavedText = "", replyLoaded = true
    private var settingsPanel: NSPanel?, settingsControls: [String: NSButton] = [:]
    var onOpenTask: ((String) -> Void)?
    init(attention: AgentAttention, runtime: AgentRuntime) {
        self.attention = attention; self.runtime = runtime
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "需要我"; window.minSize = NSSize(width: 830, height: 550); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.center()
        super.init(window: window); window.delegate = self
        let settings = NSButton(title: "设置", target: self, action: #selector(showSettings)), reload = NSButton(title: "刷新", target: self, action: #selector(reload))
        let title = NSTextField(labelWithString: "需要我"); title.font = .systemFont(ofSize: 20, weight: .semibold)
        let heading = NSStackView(views: [title, NSView(), reload, settings]); heading.spacing = 8
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab); tabs.setAccessibilityLabel("需要我列表")
        search.placeholderString = "搜索当前列表"; search.setAccessibilityLabel("搜索需要我当前列表"); search.delegate = self
        let navigation = NSStackView(views: [tabs, NSView(), search]); search.widthAnchor.constraint(equalToConstant: 240).isActive = true
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
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.widthAnchor.constraint(equalToConstant: 325).isActive = true
        detailTitle.font = .systemFont(ofSize: 16, weight: .semibold); detailTitle.maximumNumberOfLines = 3
        metadata.font = .systemFont(ofSize: 11); metadata.textColor = .secondaryLabelColor; metadata.lineBreakMode = .byTruncatingTail
        for text in [body, reply] {
            text.isRichText = false; text.font = .systemFont(ofSize: 13); text.textContainerInset = NSSize(width: 10, height: 10)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        }
        body.isEditable = false; body.setAccessibilityLabel("需要我事项详情")
        let document = NSScrollView(); document.documentView = body; document.hasVerticalScroller = true
        reply.delegate = self; reply.allowsUndo = true; reply.setAccessibilityLabel("答复此问题"); replyScroll.documentView = reply; replyScroll.hasVerticalScroller = true; replyScroll.borderType = .bezelBorder
        replyScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true; replyCaption.font = .systemFont(ofSize: 12, weight: .medium)
        for (button, action) in [(open, #selector(openTask)), (mark, #selector(markHandled)), (answer, #selector(answerQuestion)), (allow, #selector(allowRequest)), (deny, #selector(denyRequest)), (execute, #selector(executePlan))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        let actions = NSStackView(views: [open, NSView(), mark, deny, allow, execute, answer]); actions.spacing = 6
        let details = NSStackView(views: [detailTitle, metadata, document, replyCaption, replyScroll, actions]); details.orientation = .vertical; details.alignment = .leading; details.spacing = 10
        for child in details.arrangedSubviews { child.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true }
        let panes = NSStackView(views: [list, details]); panes.spacing = 16
        list.heightAnchor.constraint(equalTo: panes.heightAnchor).isActive = true; details.heightAnchor.constraint(equalTo: panes.heightAnchor).isActive = true
        status.font = .systemFont(ofSize: 12); status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 2; status.setAccessibilityLabel("需要我状态")
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        more.target = self; more.action = #selector(loadMore); let footer = NSStackView(views: [status, NSView(), more]); footer.spacing = 8
        let content = NSStackView(views: [heading, navigation, filters, panes, footer]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 13
        let root = NSView(); root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false; window.contentView = root
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)])
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        panes.setContentHuggingPriority(.defaultLow, for: .vertical); document.setContentHuggingPriority(.defaultLow, for: .vertical)
        attention.refresh(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
        guard window?.isVisible == true || selected == nil else { return }
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
        more.isHidden = loaded.count >= matching.count; more.isEnabled = !attention.loading
        status.textColor = operationIssue != nil || attention.issue != nil ? .systemRed : .secondaryLabelColor
        status.stringValue = operationIssue ?? attention.issue ?? (!attention.settings.enabled ? "需要我已关闭" : attention.loading ? "正在载入…" : matching.isEmpty ? "暂无事项" : "\(rows.count) 项 · 已加载 \(loaded.count)／\(matching.count)")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]
        let title = NSTextField(labelWithString: item.title), summary = NSTextField(labelWithString: item.summary.replacingOccurrences(of: "\n", with: " "))
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor; summary.lineBreakMode = .byTruncatingTail
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
        return ["allow": "已允许", "deny": "已拒绝", "ended": "请求已结束"][decision] ?? "已处理"
    }
    private func showSelection() {
        let item = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil, changed = item?.id != selected?.id
        selected = item; detailTitle.stringValue = item?.title ?? ""; metadata.stringValue = ""; body.string = ""
        for view in [replyCaption, replyScroll, open, mark, answer, allow, deny, execute] { view.isHidden = true }
        guard let item else { return }
        let date = DateFormatter.localizedString(from: item.date, dateStyle: .medium, timeStyle: .short)
        metadata.stringValue = item.kind.title + " · " + item.source.title + " · " + item.sender + " · " + date
        let text = item.body + (item.handled ? "\n\n" + outcome(item) : "")
        body.string = text; open.isHidden = false
        mark.isHidden = item.callID != nil; mark.title = item.handled ? "标记待处理" : "标记已处理"
        if item.kind == .question {
            if changed || !replyLoaded {
                do { reply.string = try attention.replyDraft(item); replySavedText = reply.string; replyLoaded = true; reply.undoManager?.removeAllActions() }
                catch { reply.string = ""; replySavedText = ""; replyLoaded = false; operationIssue = "答复草稿无法读取：" + error.localizedDescription }
            }
            replyCaption.isHidden = item.handled && reply.string.isEmpty; replyScroll.isHidden = replyCaption.isHidden
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
        guard let item = selected, item.kind == .question, reply.string != replySavedText else { return true }
        do {
            try attention.saveReply(item, text: reply.string); replySavedText = reply.string
            if operationIssue?.hasPrefix("答复草稿未保存：") == true { operationIssue = nil; status.stringValue = "答复草稿已保存"; status.textColor = .secondaryLabelColor }
            return true
        }
        catch { operationIssue = "答复草稿未保存：" + error.localizedDescription; status.stringValue = operationIssue!; status.textColor = .systemRed; return false }
    }
    @objc private func openTask() { if let item = selected { onOpenTask?(item.taskID) } }
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
    func prepareToClose() -> Bool { guard settingsPanel == nil else { status.stringValue = "请先保存或取消需要我设置"; window?.makeKeyAndOrderFront(nil); return false }; return persistReply() }
    func requireDeletionAllowed(_ ids: Set<String>) throws { if let item = selected, ids.contains(item.taskID), reply.string != replySavedText { throw PetError("请先保存需要我窗口中的答复草稿") } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { settingsPanel == nil && prepareToClose() }
    func windowWillClose(_ notification: Notification) { draftSave?.cancel() }
    @objc func showSettings() {
        guard let window, settingsPanel == nil, persistReply() else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 360), styleMask: [.titled], backing: .buffered, defer: false); panel.title = "需要我设置"; settingsPanel = panel; settingsControls = [:]
        func check(_ key: String, _ title: String, _ enabled: Bool) -> NSButton { let button = NSButton(checkboxWithTitle: title, target: nil, action: nil); button.state = enabled ? .on : .off; settingsControls[key] = button; return button }
        let current = attention.settings, master = check("enabled", "启用需要我", current.enabled)
        let sources = NSStackView(views: AgentAttentionSource.allCases.map { check("source:" + $0.rawValue, $0.title, current.sources.contains($0.rawValue)) }); sources.spacing = 18
        let kinds = NSStackView(views: AgentAttentionKind.allCases.map { check("kind:" + $0.rawValue, $0.title, current.kinds.contains($0.rawValue)) }); kinds.spacing = 18
        let notifications = check("notifications", "自动化桌面通知", current.automationNotifications)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSettings)), save = NSButton(title: "保存", target: self, action: #selector(saveSettings)); save.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), cancel, save]); actions.spacing = 8
        let content = NSStackView(views: [master, NSTextField(labelWithString: "来源"), sources, NSTextField(labelWithString: "内容"), kinds, NSTextField(labelWithString: "通知"), notifications, NSView(), actions]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        let root = NSView(); root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false; panel.contentView = root
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), actions.widthAnchor.constraint(equalTo: content.widthAnchor)])
        window.beginSheet(panel)
    }
    @objc private func cancelSettings() { if let panel = settingsPanel { window?.endSheet(panel); settingsPanel = nil } }
    @objc private func saveSettings() {
        var settings = attention.settings; settings.enabled = settingsControls["enabled"]?.state == .on
        settings.sources = AgentAttentionSource.allCases.filter { settingsControls["source:" + $0.rawValue]?.state == .on }.map(\.rawValue)
        settings.kinds = AgentAttentionKind.allCases.filter { settingsControls["kind:" + $0.rawValue]?.state == .on }.map(\.rawValue)
        settings.automationNotifications = settingsControls["notifications"]?.state == .on
        do { try attention.setSettings(settings); operationIssue = nil; cancelSettings(); refresh() }
        catch { let alert = NSAlert(); alert.messageText = "设置未保存"; alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "好"); alert.runModal() }
    }
    func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--attention-live-ui") else { return [:] }
        let state = states[activeTab]
        return ["visible": window?.isVisible == true, "tab": activeTab, "query": state.query, "kind": state.kind as Any? ?? NSNull(), "source": state.source as Any? ?? NSNull(), "sender": state.sender as Any? ?? NSNull(), "days": state.days, "limit": state.limit, "rows": rows.map { ["id": $0.id, "taskID": $0.taskID, "kind": $0.kind.rawValue, "handled": $0.handled] as [String: Any] }, "selected": selected?.id as Any? ?? NSNull(), "reply": reply.string, "status": status.stringValue, "pendingCount": attention.pendingCount, "enabled": attention.settings.enabled, "loading": attention.loading, "settingsVisible": settingsPanel != nil]
    }
}
