import AppKit

@MainActor class AgentSettingsFormPage: AgentSettingsPageController, NSTextFieldDelegate, NSWindowDelegate {
    private let status = NSTextField(wrappingLabelWithString: "")
    private var dirty = false
    private weak var firstInput: NSView?

    init(title: String, rows: [[NSView]], submitTitle: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 420, height: 300); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let grid = NSGridView(views: rows); grid.columnSpacing = 14; grid.rowSpacing = 16
        grid.column(at: 0).width = 76; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .fill
        firstInput = rows.first?.last
        for row in rows {
            if let input = row.last as? NSTextField { input.delegate = self; input.font = .systemFont(ofSize: 13) }
            if let input = row.last as? NSPopUpButton { input.target = self; input.action = #selector(changed) }
        }
        status.font = .systemFont(ofSize: 12); status.textColor = .systemRed
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelForm))
        let submit = NSButton(title: submitTitle, target: self, action: #selector(submitForm))
        submit.keyEquivalent = "s"; submit.keyEquivalentModifierMask = .command
        let footer = NSStackView(views: [NSView(), cancel, submit]); footer.spacing = 10
        let content = AgentThemeView(); window.contentView = content
        for view in [heading, grid, status, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            grid.leadingAnchor.constraint(equalTo: heading.leadingAnchor), grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 24),
            status.leadingAnchor.constraint(equalTo: grid.leadingAnchor), status.trailingAnchor.constraint(equalTo: grid.trailingAnchor), status.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14), status.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: grid.leadingAnchor), footer.trailingAnchor.constraint(equalTo: grid.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() { super.settingsDidAppear(); presentingWindow?.makeFirstResponder(firstInput) }
    func controlTextDidChange(_ notification: Notification) { changed() }
    @objc private func changed() { dirty = true; status.stringValue = "" }
    @objc private func submitForm() { submit() }
    func submit() {}
    func showError(_ error: Error) { status.stringValue = error.localizedDescription }
    func finish() { dirty = false; close() }
    @objc private func cancelForm() { guard let window, windowShouldClose(window) else { return }; close() }
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
        let name = NSTextField(), scope = NSPopUpButton(); self.name = name; self.scope = scope
        name.placeholderString = "名称"; name.setAccessibilityLabel("扩展名称")
        scope.addItems(withTitles: ["全局", "当前项目"]); scope.item(at: 1)?.isEnabled = workspace != nil; scope.setAccessibilityLabel("扩展范围")
        super.init(title: kind == .skill ? "新建 Skill" : "新建命令", rows: [[NSTextField(labelWithString: "名称"), name], [NSTextField(labelWithString: "范围"), scope]], submitTitle: "创建")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
        let server = NSPopUpButton(), tool = NSTextField(), permission = NSPopUpButton(); self.server = server; self.tool = tool; self.permission = permission
        server.addItems(withTitles: servers.map(\.name)); server.setAccessibilityLabel("MCP 连接器")
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
