import AppKit

@MainActor final class AgentRuleWindow: AgentSettingsPageController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    private let store: AgentStore, taskID: String
    private let scopes = NSSegmentedControl(labels: ["全部", "用户", "项目"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), table = NSTableView(), name = NSTextField(), editor = NSTextView(), descriptionField = NSTextField(), patterns = NSTextField()
    private let trigger = NSPopUpButton(), createScope = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let save = NSButton(title: "保存", target: nil, action: nil), use = NSButton(title: "在任务中使用", target: nil, action: nil)
    private let remove = NSButton(title: "移到废纸篓", target: nil, action: nil), reveal = NSButton(title: "打开来源", target: nil, action: nil)
    private let location = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: "")
    private var descriptionRow = NSStackView(), patternsRow = NSStackView(), scopeRow = NSStackView()
    private let triggers: [AgentRuleTrigger] = [.always, .manual, .decision, .glob]
    private var items: [AgentLocalRuleItem] = [], selected: AgentLocalRuleItem?, creating = false, dirty = false, loading = false, selectedScope = 0
    var onInsert: ((AgentLocalRuleItem) throws -> Void)? { didSet { updateControls() } }
    private var task: AgentTaskRecord? { store.task(taskID) }
    init(store: AgentStore, taskID: String) {
        self.store = store; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "规则"; window.minSize = NSSize(width: 760, height: 540); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        scopes.selectedSegment = 0; scopes.target = self; scopes.action = #selector(changeScope); scopes.setAccessibilityLabel("规则范围")
        search.placeholderString = "搜索规则"; search.delegate = self
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshList)), add = NSButton(title: "新建规则", target: self, action: #selector(createItem))
        let header = NSStackView(views: [scopes, search, refresh, add]); header.spacing = 8
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule")); table.addTableColumn(column); table.headerView = nil; table.rowHeight = 50; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("规则列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        for field in [name, descriptionField, patterns] { field.delegate = self; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        name.placeholderString = "规则名称"; name.setAccessibilityLabel("规则名称"); descriptionField.setAccessibilityLabel("规则适用场景"); patterns.setAccessibilityLabel("规则匹配模式")
        descriptionField.maximumNumberOfLines = 2; descriptionField.lineBreakMode = .byWordWrapping
        patterns.maximumNumberOfLines = 3; patterns.lineBreakMode = .byWordWrapping; patterns.placeholderString = "src/**/*.ts\n!src/vendor/**"
        trigger.addItems(withTitles: triggers.map(\.title)); trigger.selectItem(at: 0); trigger.target = self; trigger.action = #selector(changeTrigger); trigger.setAccessibilityLabel("规则触发方式")
        createScope.addItems(withTitles: ["用户", "项目"]); createScope.autoenablesItems = false; createScope.item(at: 1)?.isEnabled = task?.workspace != nil; createScope.target = self; createScope.action = #selector(formChanged); createScope.setAccessibilityLabel("新规则范围")
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        let titleRow = NSStackView(views: [name, enabled]); titleRow.spacing = 10
        func row(_ title: String, _ field: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12); label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let view = NSStackView(views: [label, field]); view.spacing = 8; return view
        }
        let triggerRow = row("触发方式", trigger)
        scopeRow = row("范围", createScope); descriptionRow = row("适用场景", descriptionField); patternsRow = row("匹配模式（逐行）", patterns)
        let form = NSStackView(views: [titleRow, scopeRow, triggerRow, descriptionRow, patternsRow]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 10
        for view in form.arrangedSubviews { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        editor.isRichText = false; editor.allowsUndo = true; editor.delegate = self; editor.isEditable = false; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.setAccessibilityLabel("规则正文")
        let viewer = NSScrollView(); viewer.documentView = editor; viewer.hasVerticalScroller = true; viewer.borderType = .bezelBorder
        for label in [location, state] { label.font = .systemFont(ofSize: 11); label.textColor = AgentWorkbenchTheme.secondaryText; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        for (button, action) in [(save, #selector(saveItem)), (use, #selector(useItem)), (remove, #selector(removeItem)), (reveal, #selector(revealItem))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let sourceRow = NSStackView(views: [location, NSView(), use]); sourceRow.spacing = 8
        let footer = NSStackView(views: [state, NSView(), reveal, remove, save]); footer.spacing = 8
        for view in [header, list, form, viewer, sourceRow, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), header.heightAnchor.constraint(equalToConstant: 28),
            list.leadingAnchor.constraint(equalTo: header.leadingAnchor), list.widthAnchor.constraint(equalToConstant: 230), list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), list.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            form.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 14), form.trailingAnchor.constraint(equalTo: header.trailingAnchor), form.topAnchor.constraint(equalTo: list.topAnchor),
            sourceRow.leadingAnchor.constraint(equalTo: form.leadingAnchor), sourceRow.trailingAnchor.constraint(equalTo: form.trailingAnchor), sourceRow.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 10), sourceRow.heightAnchor.constraint(equalToConstant: 28),
            viewer.leadingAnchor.constraint(equalTo: form.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: form.trailingAnchor), viewer.topAnchor.constraint(equalTo: sourceRow.bottomAnchor, constant: 10), viewer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: form.leadingAnchor), footer.trailingAnchor.constraint(equalTo: form.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), footer.heightAnchor.constraint(equalToConstant: 28), viewer.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row], title = NSTextField(labelWithString: item.name + (item.enabled ? "" : " · 已停用"))
        title.font = .systemFont(ofSize: 12, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.scope + " · " + (item.definition?.trigger.title ?? "格式错误")); detail.font = .systemFont(ofSize: 11); detail.textColor = item.error == nil ? AgentWorkbenchTheme.secondaryText : .systemRed; detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; stack.toolTip = item.source.path; return stack
    }
    private func selectRow(_ id: String?) {
        table.delegate = nil
        if let index = items.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } else { table.deselectAll(nil) }
        table.delegate = self
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard items.indices.contains(table.selectedRow) else { return }; let next = items[table.selectedRow]
        guard confirmClosing() else { selectRow(selected?.id); return }; open(next)
    }
    private func reload(select id: String? = nil) {
        guard let task else { setState("原任务已不存在"); return }
        do {
            let query = search.stringValue, all = try store.rules.catalog(workspace: task.workspace, directories: task.ruleDirectories ?? [])
            items = all.filter { (scopes.selectedSegment == 0 || $0.project == (scopes.selectedSegment == 2)) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.invocation.localizedCaseInsensitiveContains(query)) }
            table.delegate = nil; table.reloadData(); table.delegate = self; let next = items.first(where: { $0.id == (id ?? selected?.id) }) ?? items.first
            selectRow(next?.id); if let next { open(next) } else { clear() }; if next?.error == nil { setState(items.isEmpty ? "暂无规则" : "\(items.count) 项") }
        } catch { setState(error.localizedDescription); updateControls() }
    }
    private func clear() {
        loading = true; selected = nil; creating = false; name.stringValue = ""; descriptionField.stringValue = ""; patterns.stringValue = ""; editor.string = ""; location.stringValue = ""; dirty = false; loading = false; updateControls()
    }
    private func open(_ item: AgentLocalRuleItem) {
        loading = true; selected = item; creating = false
        name.stringValue = item.name; descriptionField.stringValue = item.definition?.description ?? ""; patterns.stringValue = item.definition?.patterns.joined(separator: "\n") ?? ""
        trigger.selectItem(at: triggers.firstIndex(of: item.definition?.trigger ?? .always) ?? 0)
        editor.string = item.definition?.body ?? item.text ?? ""; editor.setAccessibilityLabel(item.definition == nil ? "规则源文件" : "规则正文"); editor.undoManager?.removeAllActions()
        enabled.state = item.enabled ? .on : .off; location.stringValue = item.scope + " · @rule:" + item.invocation; location.toolTip = item.source.path
        dirty = false; loading = false; setState(item.error ?? ""); updateControls()
    }
    private func updateControls() {
        let has = creating || selected != nil, structured = creating || selected?.definition != nil
        name.isEnabled = has && structured; trigger.isEnabled = has && structured; editor.isEditable = has && (structured || selected?.text != nil)
        descriptionRow.isHidden = !structured || triggers[trigger.indexOfSelectedItem] != .decision
        patternsRow.isHidden = !structured || triggers[trigger.indexOfSelectedItem] != .glob; scopeRow.isHidden = !creating
        enabled.isHidden = creating; enabled.isEnabled = selected != nil && !dirty
        save.isEnabled = has && dirty; remove.isEnabled = selected?.permissions != nil && !dirty; reveal.isEnabled = selected != nil
        use.isEnabled = selected?.enabled == true && selected?.definition != nil && onInsert != nil && !dirty
        window?.isDocumentEdited = dirty
    }
    private func setState(_ text: String) { state.stringValue = text; state.toolTip = text.isEmpty ? nil : text }
    private func markDirty() { guard !loading else { return }; dirty = true; setState("未保存"); updateControls() }
    func textDidChange(_ notification: Notification) { markDirty() }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { if !dirty { reload() } else { setState("请先保存或放弃更改") } }
        else { markDirty() }
    }
    @objc private func formChanged() { markDirty() }
    @objc private func changeTrigger() { markDirty() }
    @objc private func changeScope() { guard confirmClosing() else { scopes.selectedSegment = selectedScope; return }; selectedScope = scopes.selectedSegment; reload() }
    @objc private func refreshList() { if confirmClosing() { reload() } }
    @objc private func createItem() {
        guard confirmClosing() else { return }; clear(); creating = true; createScope.selectItem(at: scopes.selectedSegment == 2 && task?.workspace != nil ? 1 : 0)
        trigger.selectItem(at: 0); editor.setAccessibilityLabel("规则正文"); location.stringValue = ""; dirty = true; selectRow(nil); updateControls(); presentingWindow?.makeFirstResponder(name)
    }
    @discardableResult private func saveChanges() -> Bool {
        guard let task else { setState("原任务已不存在"); return false }
        do {
            let text: String
            if !creating, selected?.definition == nil { text = editor.string }
            else { text = try AgentRuleDocument.text(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), trigger: triggers[trigger.indexOfSelectedItem], description: descriptionField.stringValue, patterns: patterns.stringValue.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, body: editor.string) }
            let value: AgentLocalRuleItem
            if creating { value = try store.rules.create(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), text: text, project: createScope.indexOfSelectedItem == 1, task: task) }
            else if let selected { value = try store.rules.save(selected, text: text, task: task) } else { return false }
            dirty = false; search.stringValue = ""; scopes.selectedSegment = 0; selectedScope = 0; reload(select: value.id); setState("已保存"); return true
        } catch { setState(error.localizedDescription); return false }
    }
    @objc private func saveItem() { _ = saveChanges() }
    @objc private func toggleEnabled() {
        guard let selected, let task else { return }
        do { try store.rules.setEnabled(selected, enabled.state == .on, task: task); reload(select: selected.id) }
        catch { enabled.state = selected.enabled ? .on : .off; setState(error.localizedDescription) }
    }
    @objc private func useItem() { guard let selected else { return }; do { try onInsert?(selected) } catch { setState(error.localizedDescription) } }
    @objc private func revealItem() { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.source]) } }
    @objc private func removeItem() {
        guard let selected, let task, let window = presentingWindow else { return }
        let alert = AgentConfirmation(); alert.messageText = "将“\(selected.name)”移到废纸篓？"; alert.informativeText = selected.source.path; alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true; alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try store.rules.trash(selected, task: task); self.selected = nil; reload(); setState("已移到废纸篓") } catch { setState(error.localizedDescription) }
        }
    }
    func confirmClosing() -> Bool {
        guard window?.attachedSheet == nil else { return false }; guard dirty else { return true }
        switch AgentUnsavedChanges.saveOrDiscard("保存规则更改？") { case .alertFirstButtonReturn: return saveChanges(); case .alertSecondButtonReturn: dirty = false; if creating { clear() } else { reload(select: selected?.id) }; return true; default: return false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClosing() }
}
