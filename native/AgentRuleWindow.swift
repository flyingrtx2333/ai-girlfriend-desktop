import AppKit

@MainActor final class AgentRuleWindow: AgentSettingsPageController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    private let store: AgentStore, taskID: String
    private let managementWorkspace: String?
    private let scopes = NSSegmentedControl(labels: ["全部", "用户", "项目"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), table = NSTableView(), name = AgentDialogTextField(), editor = NSTextView(), descriptionField = NSTextField(), patterns = NSTextField()
    private let trigger = NSPopUpButton(), createScope = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let save = AgentDialogButton(title: "保存", target: nil, action: nil), use = NSButton(title: "在任务中使用", target: nil, action: nil)
    private let remove = NSButton(title: "移到废纸篓", target: nil, action: nil), reveal = NSButton(title: "打开来源", target: nil, action: nil)
    private let location = NSTextField(labelWithString: ""), state = AgentSettingsStatusField("规则保存状态")
    private var descriptionRow = NSStackView(), patternsRow = NSStackView(), scopeRow = NSStackView()
    private let triggers: [AgentRuleTrigger] = [.always, .manual, .decision, .glob]
    private var items: [AgentLocalRuleItem] = [], selected: AgentLocalRuleItem?, creating = false, dirty = false, loading = false, selectedScope = 0
    private var readOnlySaveFailed = false
    private lazy var draftViewport: AgentSettingsDraftViewport = {
        let view = AgentSettingsDraftViewport(text: editor, fields: ["name": name, "description": descriptionField, "patterns": patterns, "search": search], catalog: table, host: { [weak self] in self?.presentingWindow })
        view.onChange = { [weak self] in self?.onSettingsRecoveryChange?() }; return view
    }()
    var onInsert: ((AgentLocalRuleItem) throws -> Void)? { didSet { updateControls() } }
    private var task: AgentTaskRecord? { try? editingTask() }
    private func editingTask() throws -> AgentTaskRecord {
        guard let original = store.task(taskID) else { throw PetError("原任务已不存在") }
        return try AgentWorkspaceScope.settingsTask(original, workspace: managementWorkspace)
    }
    init(store: AgentStore, taskID: String, managementWorkspace: String? = nil) {
        self.store = store; self.taskID = taskID; self.managementWorkspace = managementWorkspace
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
        for field in [name, descriptionField, patterns] { AgentSettingsStyle.field(field); field.delegate = self; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        name.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        name.placeholderString = "规则名称"; name.setAccessibilityLabel("规则名称"); descriptionField.setAccessibilityLabel("规则适用场景"); patterns.setAccessibilityLabel("规则匹配模式")
        descriptionField.maximumNumberOfLines = 2; descriptionField.lineBreakMode = .byWordWrapping
        patterns.maximumNumberOfLines = 3; patterns.lineBreakMode = .byWordWrapping; patterns.placeholderString = "src/**/*.ts\n!src/vendor/**"
        trigger.addItems(withTitles: triggers.map(\.title)); trigger.selectItem(at: 0); trigger.target = self; trigger.action = #selector(changeTrigger); trigger.setAccessibilityLabel("规则触发方式")
        createScope.addItems(withTitles: ["用户", "项目"]); createScope.autoenablesItems = false; createScope.item(at: 1)?.isEnabled = task?.workspace != nil; createScope.target = self; createScope.action = #selector(formChanged); createScope.setAccessibilityLabel("新规则范围")
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        let titleRow = NSStackView(views: [name, enabled]); titleRow.spacing = 10
        func row(_ title: String, _ field: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13); label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let control: NSView = (field as? NSPopUpButton).map(AgentSettingsPopupFrame.init) ?? field
            let view = NSStackView(views: [label, control]); view.spacing = 8; return view
        }
        let triggerRow = row("触发方式", trigger)
        scopeRow = row("范围", createScope); descriptionRow = row("适用场景", descriptionField); patternsRow = row("匹配模式", patterns)
        patterns.toolTip = "每行一个模式，使用 ! 排除"
        let form = NSStackView(views: [titleRow, scopeRow, triggerRow, descriptionRow, patternsRow]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 10
        for view in form.arrangedSubviews { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        editor.isRichText = false; editor.allowsUndo = true; editor.delegate = self; editor.isEditable = false; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.setAccessibilityLabel("规则正文")
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.identifier = .init("form-input")
        let viewer = AgentThemeView(fill: AgentWorkbenchTheme.card, stroke: AgentWorkbenchTheme.line); viewer.identifier = .init("settings-card-rule-body")
        viewer.layer?.cornerRadius = 12; viewer.layer?.borderWidth = 1; viewer.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: viewer.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: viewer.trailingAnchor, constant: -1), scroll.topAnchor.constraint(equalTo: viewer.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: viewer.bottomAnchor, constant: -1)])
        location.font = .systemFont(ofSize: 11); location.textColor = AgentWorkbenchTheme.secondaryText; location.lineBreakMode = .byTruncatingMiddle; location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(save, #selector(saveItem)), (use, #selector(useItem)), (remove, #selector(removeItem)), (reveal, #selector(revealItem))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; AgentSettingsStyle.primaryAction(save)
        let sourceRow = NSStackView(views: [location, NSView(), use]); sourceRow.spacing = 8
        let footer = NSStackView(views: [NSView(), reveal, remove, save]); footer.spacing = 8
        for view in [header, list, form, viewer, sourceRow, state, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), header.heightAnchor.constraint(equalToConstant: 28),
            list.leadingAnchor.constraint(equalTo: header.leadingAnchor), list.widthAnchor.constraint(equalToConstant: 230), list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), list.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            form.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 14), form.trailingAnchor.constraint(equalTo: header.trailingAnchor), form.topAnchor.constraint(equalTo: list.topAnchor),
            sourceRow.leadingAnchor.constraint(equalTo: form.leadingAnchor), sourceRow.trailingAnchor.constraint(equalTo: form.trailingAnchor), sourceRow.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 10), sourceRow.heightAnchor.constraint(equalToConstant: 28),
            viewer.leadingAnchor.constraint(equalTo: form.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: form.trailingAnchor), viewer.topAnchor.constraint(equalTo: sourceRow.bottomAnchor, constant: 10), viewer.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -10),
            state.leadingAnchor.constraint(equalTo: form.leadingAnchor), state.trailingAnchor.constraint(equalTo: form.trailingAnchor), state.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
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
        do {
            let task = try editingTask()
            let query = search.stringValue, all = try store.rules.catalog(workspace: task.workspace, directories: task.ruleDirectories ?? [])
            items = all.filter { (scopes.selectedSegment == 0 || $0.project == (scopes.selectedSegment == 2)) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.invocation.localizedCaseInsensitiveContains(query)) }
            table.delegate = nil; table.reloadData(); table.delegate = self; let next = items.first(where: { $0.id == (id ?? selected?.id) }) ?? items.first
            selectRow(next?.id); if let next { open(next) } else { clear() }; if next?.error == nil { setState(items.isEmpty ? "暂无规则" : "\(items.count) 项") }
        } catch { setState(error.localizedDescription); updateControls() }
    }
    private func clear() {
        draftViewport.reset()
        loading = true; selected = nil; creating = false; readOnlySaveFailed = false; name.stringValue = ""; descriptionField.stringValue = ""; patterns.stringValue = ""; editor.string = ""; location.stringValue = ""; dirty = false; loading = false; updateControls()
    }
    private func open(_ item: AgentLocalRuleItem) {
        draftViewport.reset()
        loading = true; selected = item; creating = false; readOnlySaveFailed = false
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
        onSettingsRecoveryChange?()
    }
    private func setState(_ text: String) { state.stringValue = text; state.toolTip = text.isEmpty ? nil : text; onSettingsRecoveryChange?() }
    private func markDirty() { guard !loading else { return }; draftViewport.changed(); dirty = true; setState("未保存"); updateControls() }
    func textDidChange(_ notification: Notification) { markDirty() }
    func controlTextDidChange(_ notification: Notification) {
        draftViewport.changed()
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
        do {
            let task = try editingTask()
            if readOnlySaveFailed, let opened = selected, !creating {
                let current = try store.rules.current(opened.id, task: task, enabledOnly: false)
                guard current.owner == opened.owner, current.source == opened.source, current.sha256 == opened.sha256 else { throw PetError("规则已被其他编辑器修改，请刷新后再编辑；未覆盖外部改动") }
                selected = current
            }
            let text: String
            if !creating, selected?.definition == nil { text = editor.string }
            else { text = try AgentRuleDocument.text(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), trigger: triggers[trigger.indexOfSelectedItem], description: descriptionField.stringValue, patterns: patterns.stringValue.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, body: editor.string) }
            let value: AgentLocalRuleItem
            if creating { value = try store.rules.create(name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), text: text, project: createScope.indexOfSelectedItem == 1, task: task) }
            else if let selected { value = try store.rules.save(selected, text: text, task: task) } else { return false }
            dirty = false; search.stringValue = ""; scopes.selectedSegment = 0; selectedScope = 0; reload(select: value.id); setState("已保存"); return true
        } catch { readOnlySaveFailed = (error as? AgentSaveFailure)?.reason == .readOnly; state.showSaveFailure(error); onSettingsRecoveryChange?(); return false }
    }
    @objc private func saveItem() { _ = saveChanges() }
    @objc private func toggleEnabled() {
        guard let selected else { return }
        do { try store.rules.setEnabled(selected, enabled.state == .on, task: editingTask()); reload(select: selected.id) }
        catch { enabled.state = selected.enabled ? .on : .off; setState(error.localizedDescription) }
    }
    @objc private func useItem() { guard let selected else { return }; do { try onInsert?(selected) } catch { setState(error.localizedDescription) } }
    @objc private func revealItem() { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.source]) } }
    @objc private func removeItem() {
        guard let selected, let window = presentingWindow else { return }
        let alert = AgentConfirmation(); alert.messageText = "将“\(selected.name)”移到废纸篓？"; alert.informativeText = selected.source.path; alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true; alert.addButton(withTitle: "取消")
        alert.beginModal(in: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try store.rules.trash(selected, task: editingTask()); self.selected = nil; reload(); setState("已移到废纸篓") } catch { setState(error.localizedDescription) }
        }
    }
    func confirmClosing() -> Bool {
        guard window?.hasBlockingDialog != true else { return false }; guard dirty else { return true }
        switch AgentUnsavedChanges.saveOrDiscard("保存规则更改？") { case .alertFirstButtonReturn: return saveChanges(); case .alertSecondButtonReturn: dirty = false; if creating { clear() } else { reload(select: selected?.id) }; return true; default: return false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClosing() }
    override func settingsDidAppear() { super.settingsDidAppear(); draftViewport.appear(default: creating ? name : editor) }
    override func pageDidLayout() { draftViewport.schedule() }
    private struct Recovery: Codable {
        var version = 1
        var taskID: String, workspace: String?
        var selected: AgentLocalRuleItem?, creating: Bool, dirty: Bool, readOnlySaveFailed: Bool
        var scope: Int, query: String, createScope: Int, trigger: Int
        var name: String, description: String, patterns: String, body: String, status: String
        var viewport: AgentSettingsDraftViewport.State
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        guard !taskID.isEmpty else { return nil }
        let value = Recovery(taskID: taskID, workspace: managementWorkspace, selected: selected, creating: creating, dirty: dirty,
            readOnlySaveFailed: readOnlySaveFailed, scope: selectedScope, query: search.stringValue, createScope: createScope.indexOfSelectedItem,
            trigger: trigger.indexOfSelectedItem, name: name.stringValue, description: descriptionField.stringValue, patterns: patterns.stringValue,
            body: editor.string, status: state.stringValue, viewport: try draftViewport.capture())
        return try AgentSettingsRecovery.page("rules", value)
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "rules" else { throw PetError("设置草稿不属于规则编辑器") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "taskID", "workspace", "selected", "creating", "dirty", "readOnlySaveFailed", "scope", "query", "createScope", "trigger", "name", "description", "patterns", "body", "status", "viewport"])
        if let viewport = raw["viewport"] { try AgentSettingsDraftViewport.validateObject(viewport) }
        if let item = raw["selected"], !(item is NSNull) {
            let item = try AgentSettingsRecovery.object(item, keys: ["id", "invocation", "source", "owner", "base", "rootPath", "relative", "scope", "project", "enabled", "text", "sha256", "signature", "permissions", "definition", "error"])
            if let definition = item["definition"], !(definition is NSNull) { _ = try AgentSettingsRecovery.object(definition, keys: ["key", "path", "description", "body", "trigger", "patterns"]) }
        }
        let value = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard value.version == 1, value.taskID == taskID, value.workspace == managementWorkspace,
              (0...2).contains(value.scope), (0...1).contains(value.createScope), triggers.indices.contains(value.trigger),
              !value.creating || value.selected == nil else { throw PetError("规则草稿范围或格式已变化，原记录已保留") }
        let task = try editingTask(), all = try store.rules.catalog(workspace: task.workspace, directories: task.ruleDirectories ?? [])
        if let item = value.selected {
            guard item.id == "local-rule-" + AgentFiles.hash(Data(item.source.path.utf8)).prefix(32) else { throw PetError("规则草稿与原来源不符") }
        }
        // Validate text positions against the complete draft before changing UI.
        try draftViewport.validate(value.viewport, text: value.body, fields: ["name": value.name, "description": value.description, "patterns": value.patterns, "search": value.query])
        loading = true; defer { loading = false }
        selectedScope = value.scope; scopes.selectedSegment = value.scope; search.stringValue = value.query
        items = all.filter { (value.scope == 0 || $0.project == (value.scope == 2)) && (value.query.isEmpty || $0.name.localizedCaseInsensitiveContains(value.query) || $0.invocation.localizedCaseInsensitiveContains(value.query)) }
        if let item = value.selected { items.removeAll { $0.id == item.id }; items.append(item) }
        selected = value.selected; creating = value.creating; readOnlySaveFailed = value.readOnlySaveFailed
        name.stringValue = value.name; descriptionField.stringValue = value.description; patterns.stringValue = value.patterns; editor.string = value.body
        createScope.selectItem(at: value.createScope); trigger.selectItem(at: value.trigger); enabled.state = selected?.enabled == true ? .on : .off
        editor.setAccessibilityLabel(creating || selected?.definition != nil ? "规则正文" : "规则源文件")
        location.stringValue = selected.map { $0.scope + " · @rule:" + $0.invocation } ?? ""; location.toolTip = selected?.source.path
        let changed = value.selected.map { old in !all.contains { $0.id == old.id && $0.source == old.source && $0.owner == old.owner && $0.sha256 == old.sha256 } } ?? false
        dirty = value.dirty || changed; table.delegate = nil; table.reloadData(); table.delegate = self; selectRow(selected?.id)
        setState(changed ? "原规则已变化，恢复草稿已保留；刷新可重新读取" : value.status); updateControls(); editor.undoManager?.removeAllActions()
        try draftViewport.restore(value.viewport)
    }
}
