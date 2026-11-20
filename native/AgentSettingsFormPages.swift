import AppKit

@MainActor class AgentSettingsFormPage: AgentSettingsPageController, NSTextFieldDelegate, NSWindowDelegate {
    private let status = AgentSettingsStatusField("设置保存状态")
    private var dirty = false
    private weak var firstInput: NSView?
    private weak var actionsHost: NSStackView?
    private let footer = NSStackView()
    private var actions: [NSView] = []
    private var footerHeight: NSLayoutConstraint!
    private weak var trackedField: NSTextField?
    private var savedSelection: AgentTextViewport.Selection?, selectionText = ""
    private var pendingSelection = false, applyingSelection = false, selectionScheduled = false

    init(title: String, rows: [[NSView]], submitTitle: String, showsSectionHeading: Bool = true) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 420, height: 300); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        firstInput = rows.first?.last
        var fields: [NSView] = []
        for row in rows {
            let label = (row.first as? NSTextField)?.stringValue ?? ""
            if let input = row.last as? NSTextField {
                input.delegate = self; fields.append(AgentSettingsStyle.labeledField(label, input))
            } else if let input = row.last as? NSPopUpButton {
                input.target = self; input.action = #selector(changed)
                fields.append(AgentSettingsStyle.formRow(label, input, trailing: true))
            }
        }
        let section = AgentSettingsStyle.section(showsSectionHeading ? title : "", id: "short-form", rows: fields)
        status.font = .systemFont(ofSize: 12); status.textColor = .systemRed
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(cancelForm))
        let submit = AgentDialogButton(title: submitTitle, target: self, action: #selector(submitForm))
        AgentDialogStyle.action(cancel); AgentDialogStyle.action(submit, prominent: true)
        submit.keyEquivalent = "s"; submit.keyEquivalentModifierMask = .command
        actions = [cancel, submit]
        for view in [NSView(), cancel, submit] { footer.addArrangedSubview(view) }; footer.spacing = 10
        footerHeight = footer.heightAnchor.constraint(equalToConstant: 28)
        let content = AgentThemeView(); window.contentView = content
        for view in [section, status, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), section.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), section.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            status.leadingAnchor.constraint(equalTo: section.leadingAnchor), status.trailingAnchor.constraint(equalTo: section.trailingAnchor), status.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: section.leadingAnchor), footer.trailingAnchor.constraint(equalTo: section.trailingAnchor), footer.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12), footer.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18), footerHeight
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func setSettingsActionsHost(_ host: NSStackView?) {
        guard actionsHost !== host else { return }
        for view in actions {
            if let stack = view.superview as? NSStackView, stack.arrangedSubviews.contains(where: { $0 === view }) { stack.removeArrangedSubview(view) }
            view.removeFromSuperview(); (host ?? footer).addArrangedSubview(view)
        }
        actionsHost = host; footer.isHidden = host != nil; footerHeight.constant = host == nil ? 28 : 0
    }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        if pendingSelection { scheduleSelection(); return }
        guard let host = presentingWindow, let firstInput, host.firstResponder !== firstInput else { return }
        if let field = firstInput as? NSTextField, field.currentEditor() === host.firstResponder { return }
        host.makeFirstResponder(firstInput)
    }
    override func pageDidLayout() { scheduleSelection() }
    func trackSelection(in field: NSTextField) {
        trackedField = field
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: NSTextView.didChangeSelectionNotification, object: nil)
    }
    private func rememberSelection(in editor: NSTextView, field: NSTextField) {
        let range = editor.selectedRange(), selection = AgentTextViewport.Selection(location: range.location, length: range.length)
        if selection.valid(in: field.stringValue.utf16.count) { savedSelection = selection; selectionText = field.stringValue }
    }
    @objc private func selectionChanged(_ notification: Notification) {
        guard !applyingSelection, let field = trackedField, let editor = notification.object as? NSTextView, editor === field.currentEditor() else { return }
        rememberSelection(in: editor, field: field); onSettingsRecoveryChange?()
    }
    func captureFieldSelection() -> AgentTextViewport.Selection? {
        guard let field = trackedField else { return nil }
        if let editor = field.currentEditor() as? NSTextView { rememberSelection(in: editor, field: field) }
        return selectionText == field.stringValue ? savedSelection : nil
    }
    func restoreFieldSelection(_ value: AgentTextViewport.Selection?) {
        guard let field = trackedField else { return }
        savedSelection = value; selectionText = field.stringValue; pendingSelection = true; scheduleSelection()
    }
    private func scheduleSelection() {
        guard pendingSelection, !selectionScheduled else { return }; selectionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { selectionScheduled = false }
            guard isPageVisible, let host = presentingWindow, let field = trackedField else { return }
            applyingSelection = true; defer { applyingSelection = false }
            host.contentView?.layoutSubtreeIfNeeded()
            guard host.makeFirstResponder(field) else { return }
            if let savedSelection { (field.currentEditor() as? NSTextView)?.setSelectedRange(savedSelection.range) }
            pendingSelection = false
        }
    }
    func controlTextDidChange(_ notification: Notification) { changed() }
    @objc private func changed() { dirty = true; status.stringValue = ""; onSettingsRecoveryChange?() }
    @objc private func submitForm() { submit() }
    func submit() {}
    func showError(_ error: Error) { status.showSaveFailure(error); onSettingsRecoveryChange?() }
    var formRecoveryValues: (dirty: Bool, status: String) { (dirty, status.stringValue) }
    func restoreFormRecovery(dirty: Bool, status: String) {
        self.dirty = dirty; self.status.stringValue = status
        if !status.isEmpty { self.status.textColor = AgentDialogStyle.error }
        onSettingsRecoveryChange?()
    }
    func finish() { dirty = false; close() }
    @objc func cancelForm() { guard let window, windowShouldClose(window) else { return }; close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        guard AgentUnsavedChanges.discard("放弃未保存的填写内容？") else { return false }; dirty = false; return true
    }
}

@MainActor final class AgentExtensionCreationPage: AgentSettingsFormPage {
    private let service: AgentExtensions, kind: AgentExtensionKind, workspace: String?
    private let name: NSTextField, scope: NSPopUpButton
    var onCreated: ((AgentExtensionItem) -> Void)?

    init(service: AgentExtensions, kind: AgentExtensionKind, workspace: String?) {
        self.service = service; self.kind = kind; self.workspace = workspace
        let name = AgentDialogTextField(), scope = NSPopUpButton(); self.name = name; self.scope = scope; name.outlined = true
        name.placeholderString = "名称"; name.setAccessibilityLabel("扩展名称")
        scope.addItems(withTitles: ["全局", "当前项目"]); scope.menu?.autoenablesItems = false; scope.item(at: 1)?.isEnabled = workspace != nil; scope.setAccessibilityLabel("扩展范围")
        super.init(title: kind == .skill ? "新建 Skill" : "新建命令", rows: [[NSTextField(labelWithString: "名称"), name], [NSTextField(labelWithString: "范围"), scope]], submitTitle: "创建")
        trackSelection(in: name)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private struct Recovery: Codable {
        var version = 1
        var kind: AgentExtensionKind, workspace: String?, name: String, scope: Int, dirty: Bool, status: String
        var selection: AgentTextViewport.Selection?
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        let presentation = formRecoveryValues
        let value = Recovery(kind: kind, workspace: workspace, name: name.stringValue, scope: scope.indexOfSelectedItem, dirty: presentation.dirty,
            status: presentation.status, selection: captureFieldSelection())
        return try AgentSettingsRecovery.page("extension-create", value)
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "extension-create" else { throw PetError("此草稿不属于扩展新建表单") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "kind", "workspace", "name", "scope", "dirty", "status", "selection"])
        if let selection = raw["selection"], !(selection is NSNull) { _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"]) }
        let value = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard value.version == 1, value.kind == kind, value.workspace == workspace, (0...1).contains(value.scope),
              value.scope == 0 || workspace != nil, value.selection?.valid(in: (value.name as NSString).length) != false else { throw PetError("扩展新建草稿范围或选区无效，原记录已保留") }
        name.stringValue = value.name; scope.selectItem(at: value.scope)
        restoreFieldSelection(value.selection); restoreFormRecovery(dirty: value.dirty, status: value.status)
    }
    override func submit() {
        do {
            let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = kind == .skill ? "---\nname: \(value)\ndescription: \n---\n\n# 工作流\n\n1. 读取任务要求和实际输入。\n2. 执行所需步骤。\n3. 核对实际结果。\n" : "---\ndescription: \n---\n\n$ARGUMENTS\n"
            let item = try service.create(kind, name: value, text: text, project: scope.indexOfSelectedItem == 1, workspace: workspace)
            finish(); onCreated?(item)
        } catch { showError(error) }
    }
}

@MainActor final class AgentMCPToolRulePage: AgentSettingsFormPage {
    private let servers: [AgentMCPServer]
    private let server: NSPopUpButton, tool: NSTextField, permission: NSPopUpButton
    var onApply: ((AgentMCPToolPermission) throws -> Void)?
    var onApplied: (() -> Void)?

    init(servers: [AgentMCPServer]) {
        self.servers = servers
        let server = NSPopUpButton(), tool = AgentDialogTextField(), permission = NSPopUpButton(); self.server = server; self.tool = tool; self.permission = permission; tool.outlined = true
        for item in servers {
            let duplicate = servers.filter { $0.name == item.name }.count > 1
            let title = duplicate ? AgentMCPSelection.title(item) : item.name
            let repeated = duplicate && servers.filter { AgentMCPSelection.title($0) == title }.count > 1
            server.addItem(withTitle: repeated ? AgentMCPSelection.selectionTitle(item) : title); server.lastItem?.toolTip = AgentMCPSelection.selectionTitle(item)
        }
        server.setAccessibilityLabel("MCP 连接器"); server.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); server.cell?.lineBreakMode = .byTruncatingTail
        tool.placeholderString = "实际工具名"; tool.setAccessibilityLabel("MCP 工具名")
        permission.addItems(withTitles: AgentToolPermission.allCases.map(\.title)); permission.selectItem(at: AgentToolPermission.allCases.firstIndex(of: .ask)!); permission.setAccessibilityLabel("MCP 工具权限")
        super.init(title: "MCP 工具权限", rows: [[NSTextField(labelWithString: "连接器"), server], [NSTextField(labelWithString: "工具"), tool], [NSTextField(labelWithString: "权限"), permission]], submitTitle: "应用")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func submit() {
        do {
            let value = tool.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 128, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PetError("请输入有效的实际工具名") }
            guard servers.indices.contains(server.indexOfSelectedItem), AgentToolPermission.allCases.indices.contains(permission.indexOfSelectedItem), let onApply else { throw PetError("连接器已变化，请返回重新选择") }
            try onApply(AgentMCPToolPermission(serverID: servers[server.indexOfSelectedItem].id, tool: value, permission: AgentToolPermission.allCases[permission.indexOfSelectedItem]))
            finish(); onApplied?()
        } catch { showError(error) }
    }
}
