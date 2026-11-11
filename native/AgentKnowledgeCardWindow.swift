import AppKit

@MainActor final class AgentKnowledgeCardWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let store: AgentStore, taskID: String
    let search = NSSearchField(), category = NSPopUpButton(), language = NSPopUpButton()
    let automatic = NSButton(checkboxWithTitle: "自动更新", target: nil, action: nil)
    let exporting = NSButton(checkboxWithTitle: "自动导出", target: nil, action: nil)
    let citation = NSButton(checkboxWithTitle: "自动引用", target: nil, action: nil)
    let generate = NSButton(title: "生成卡片", target: nil, action: nil), taskButton = NSButton(title: "查看任务", target: nil, action: nil)
    let focus = NSTextField(string: ""), scopeLabel = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: "")
    let table = NSTableView(), titleField = NSTextField(string: ""), preview = NSTextView(), sources = NSPopUpButton()
    let format = NSSegmentedControl(labels: ["阅读", "编辑"], trackingMode: .selectOne, target: nil, action: nil)
    let save = NSButton(title: "保存", target: nil, action: nil), open = NSButton(title: "查看源码", target: nil, action: nil)
    var value: AgentKnowledgeCardBook?, revision = "", rows: [AgentKnowledgeCard] = [], selected: AgentKnowledgeCard?
    var dirty = false, loading = false, busy = false, job: Task<Void, Never>?, sourceWindow: NSWindowController?
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
        category.addItems(withTitles: ["全部类型"] + AgentKnowledgeCardKind.allCases.map(\.title)); category.setAccessibilityLabel("卡片类型"); category.target = self; category.action = #selector(filterChanged)
        language.addItems(withTitles: ["简体中文", "English"]); language.setAccessibilityLabel("卡片语言"); language.target = self; language.action = #selector(languageChanged)
        for button in [automatic, exporting, citation] { button.target = self; button.action = #selector(optionsChanged(_:)) }
        for (button, action) in [(generate, #selector(generateCards)), (taskButton, #selector(viewTask)), (save, #selector(saveCard)), (open, #selector(openSource))] { button.target = self; button.action = action }
        focus.placeholderString = "重点模块或问题（可选）"; focus.setAccessibilityLabel("卡片分析重点")
        for field in [scopeLabel, state] { field.font = .systemFont(ofSize: 11); field.textColor = AgentWorkbenchTheme.secondaryText; field.lineBreakMode = .byTruncatingMiddle; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        table.addTableColumn(NSTableColumn(identifier: .init("card"))); table.headerView = nil; table.rowHeight = 54; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("知识卡片列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        titleField.font = .systemFont(ofSize: 16, weight: .semibold); titleField.isBordered = false; titleField.drawsBackground = false; titleField.isEditable = false; titleField.setAccessibilityLabel("卡片标题")
        titleField.target = self; titleField.action = #selector(titleChanged); titleField.delegate = self
        preview.isEditable = false; preview.isRichText = true; preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.textContainerInset = NSSize(width: 16, height: 16); preview.delegate = self; preview.setAccessibilityLabel("卡片正文")
        let viewer = NSScrollView(); viewer.documentView = preview; viewer.hasVerticalScroller = true; viewer.borderType = .bezelBorder
        format.selectedSegment = 0; format.target = self; format.action = #selector(formatChanged); sources.setAccessibilityLabel("卡片源码引用")
        let more = NSPopUpButton(frame: .zero, pullsDown: true); more.addItem(withTitle: "更多")
        for (title, action) in [("刷新", #selector(reloadCards)), ("导入项目卡片…", #selector(importCards)), ("导出到项目", #selector(exportCards)), ("恢复版本…", #selector(restoreVersion))] { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; more.menu?.addItem(item) }
        more.autoenablesItems = false; more.setAccessibilityLabel("知识卡片操作")
        let query = row([search, category]), actions = row([language, NSView(), generate, more])
        let header = NSStackView(views: [query, actions]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        for item in [query, actions] { item.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        let options = row([automatic, exporting, citation, NSView(), taskButton])
        let editHeader = row([titleField, format, save]), sourceRow = row([sources, open])
        for view in [header, options, scopeLabel, focus, list, editHeader, viewer, sourceRow, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            options.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10), options.leadingAnchor.constraint(equalTo: header.leadingAnchor), options.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scopeLabel.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 10), scopeLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor), scopeLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            focus.topAnchor.constraint(equalTo: scopeLabel.bottomAnchor, constant: 10), focus.leadingAnchor.constraint(equalTo: header.leadingAnchor), focus.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            list.topAnchor.constraint(equalTo: focus.bottomAnchor, constant: 14), list.leadingAnchor.constraint(equalTo: header.leadingAnchor), list.widthAnchor.constraint(equalToConstant: 165), list.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -14),
            editHeader.topAnchor.constraint(equalTo: list.topAnchor), editHeader.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 14), editHeader.trailingAnchor.constraint(equalTo: header.trailingAnchor), titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            viewer.topAnchor.constraint(equalTo: editHeader.bottomAnchor, constant: 10), viewer.leadingAnchor.constraint(equalTo: editHeader.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: editHeader.trailingAnchor), viewer.bottomAnchor.constraint(equalTo: sourceRow.topAnchor, constant: -10),
            sourceRow.leadingAnchor.constraint(equalTo: viewer.leadingAnchor), sourceRow.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), sourceRow.bottomAnchor.constraint(equalTo: list.bottomAnchor), sources.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            state.leadingAnchor.constraint(equalTo: header.leadingAnchor), state.trailingAnchor.constraint(equalTo: header.trailingAnchor), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); sources.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        for scroll in [list, viewer] { scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; scroll.borderType = .noBorder }
        table.style = .inset; table.backgroundColor = .clear; preview.drawsBackground = false; preview.textColor = .labelColor
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func row(_ views: [NSView]) -> NSStackView { let value = NSStackView(views: views); value.spacing = 8; return value }
    func windowShouldClose(_ sender: NSWindow) -> Bool { discard() }
    func windowDidBecomeKey(_ notification: Notification) { reload() }
    func windowWillClose(_ notification: Notification) { job?.cancel(); sourceWindow?.close() }
    func discard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存的卡片编辑？"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃编辑")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }; dirty = false; render(); return true
    }
    func reload() {
        guard !dirty, let task, let workspace = task.workspace else { if dirty { state.stringValue = "有未保存编辑；保存时核对当前版本" }; return }
        do {
            let options = try cards.options(workspace: workspace), previous = selected?.id
            language.selectItem(at: options.language == "en" ? 1 : 0); automatic.state = options.autoUpdate ? .on : .off; exporting.state = options.autoExport ? .on : .off; citation.state = options.citation ? .on : .off
            let scope = try cards.scope(task)
            (value, revision) = try cards.book(task, language: options.language)
            let branch = scope.branch == "folder" ? "文件夹" : scope.branch.replacingOccurrences(of: "refs/heads/", with: "")
            scopeLabel.stringValue = URL(fileURLWithPath: scope.root).lastPathComponent + " · " + branch; scopeLabel.toolTip = scope.root
            if focus.stringValue.isEmpty { focus.stringValue = value?.focus ?? "" }
            filter(preferred: previous)
            let active = activeTask
            generate.title = active == nil ? (value == nil ? "生成卡片" : "重新生成") : "生成中…"; generate.isEnabled = active == nil && !busy
            taskButton.isEnabled = active != nil || latestTask != nil || value?.taskID != nil
            state.stringValue = cards.notices[scope.root].flatMap { $0.isEmpty ? nil : $0 } ?? (value == nil ? "暂无卡片" : "\(value!.cards.count) 张卡片")
            if active == nil, let latest = latestTask, latest.updated > (value?.created ?? .distantPast) {
                if latest.status == .failed { state.stringValue = store.task(latest.id)?.events.last(where: { $0.status == "failed" })?.detail ?? "生成未完成，请查看任务" }
                if latest.status == .stopped { state.stringValue = "生成已停止" }
            }
        } catch { state.stringValue = error.localizedDescription; generate.isEnabled = !busy }
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
    @objc func filterChanged() { guard discard() else { return }; filter(preferred: selected?.id) }
    func filter(preferred: String?) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), index = category.indexOfSelectedItem - 1
        rows = (value?.cards ?? []).filter { card in (index < 0 || card.kind == AgentKnowledgeCardKind.allCases[index]) && (query.isEmpty || (card.title + "\n" + card.body).localizedCaseInsensitiveContains(query)) }
        table.delegate = nil; table.reloadData(); table.deselectAll(nil)
        if let i = rows.firstIndex(where: { $0.id == preferred }) ?? (rows.isEmpty ? nil : 0) { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false); selected = rows[i] } else { selected = nil }
        table.delegate = self; render()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { discard() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let card = rows[row], title = NSTextField(labelWithString: card.title), detail = NSTextField(labelWithString: card.kind.title + (card.manual ? " · 已编辑" : "") + (task?.workspace.map({ cards.fresh(card, workspace: $0) }) == true ? "" : " · 来源已变化"))
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail; detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText
        let column = NSStackView(views: [title, detail]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 4; return column
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil; render() }
    func render() {
        loading = true; defer { loading = false }
        let editing = format.selectedSegment == 1 && selected != nil
        titleField.stringValue = selected?.title ?? ""; titleField.isEditable = editing; preview.isEditable = editing; preview.isRichText = !editing
        if editing { preview.font = .monospacedSystemFont(ofSize: 13, weight: .regular); preview.string = selected?.body ?? "" }
        else { let p = NSMutableParagraphStyle(); p.lineSpacing = 5; p.paragraphSpacing = 8; preview.textStorage?.setAttributedString(NativeMarkdown.render(selected?.body ?? "", font: .systemFont(ofSize: 14), color: .labelColor, paragraph: p)) }
        sources.removeAllItems(); sources.addItems(withTitles: selected?.sources.map { $0.path + ":\($0.line)–\($0.endLine)" } ?? [])
        open.isEnabled = selected != nil; format.isEnabled = selected != nil; save.isEnabled = editing; dirty = false
    }
    @objc func formatChanged() { guard discard() else { format.selectedSegment = 1; return }; render() }
    @objc func titleChanged() { if !loading { dirty = true } }
    func controlTextDidChange(_ notification: Notification) { if !loading, notification.object as? NSTextField === titleField { dirty = true } }
    func textDidChange(_ notification: Notification) { if !loading && preview.isEditable { dirty = true } }
}
