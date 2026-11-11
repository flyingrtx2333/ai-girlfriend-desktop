import AppKit

@MainActor final class AgentPluginSettingsWindow: AgentSettingsPageController, NSWindowDelegate {
    private let service: AgentPlugins, item: AgentPluginInstallation, workspace: String?
    private let scopes = NSSegmentedControl(labels: ["用户", "项目", "本机"], trackingMode: .selectOne, target: nil, action: nil)
    private let value = NSPopUpButton(), source = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: "")
    private let save = NSButton(title: "保存", target: nil, action: nil)
    private var documents: [AgentPluginSettingScope: AgentPluginSettingDocument] = [:], drafts: [AgentPluginSettingScope: Int] = [:]
    var onChange: (() -> Void)?
    private var scope: AgentPluginSettingScope { AgentPluginSettingScope(rawValue: scopes.selectedSegment) ?? .user }
    init(service: AgentPlugins, item: AgentPluginInstallation, workspace: String?) {
        self.service = service; self.item = item; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "插件启用设置" + (workspace.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.center()
        super.init(window: window); window.delegate = self
        scopes.selectedSegment = item.workspace == nil ? 0 : 1; scopes.setEnabled(service.sharedHome != nil, forSegment: 0)
        for index in [1, 2] { scopes.setEnabled(workspace != nil, forSegment: index) }; scopes.target = self; scopes.action = #selector(changeScope); scopes.setAccessibilityLabel("插件设置范围")
        value.addItems(withTitles: ["继承上层", "启用", "停用"]); value.target = self; value.action = #selector(changeValue); value.setAccessibilityLabel("插件启用声明")
        let name = NSTextField(labelWithString: item.metadata.title + " · " + item.metadata.name + "@local"); name.font = .systemFont(ofSize: 14, weight: .semibold); name.lineBreakMode = .byTruncatingTail; name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [source, state] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        save.target = self; save.action = #selector(saveSetting)
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshSetting))
        let footer = NSStackView(views: [state, NSView(), refresh, save]); footer.spacing = 10
        let stack = NSStackView(views: [name, scopes, value, source, NSView(), footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); window.contentView = content; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16), source.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func index(_ value: Bool?) -> Int { value.map { $0 ? 1 : 2 } ?? 0 }
    private var dirty: Bool { drafts.contains { key, draft in draft != index(documents[key]?.values[item.metadata.name + "@local"]) } }
    private func load() {
        do {
            let document = try documents[scope] ?? service.settingDocument(scope, workspace: workspace); documents[scope] = document
            value.selectItem(at: drafts[scope] ?? index(document.values[item.metadata.name + "@local"]))
            source.stringValue = document.file.path; source.toolTip = source.stringValue
            let effective = try service.catalog(workspace: workspace).first { $0.metadata.name == item.metadata.name }
            state.stringValue = effective?.enabled == true ? "当前：已启用" : effective?.requestedEnabled == true ? "当前：需本机审阅" : "当前：已停用"
            if let selection = effective?.selection { state.stringValue += " · " + selection.scope.title }
            save.isEnabled = value.indexOfSelectedItem != index(document.values[item.metadata.name + "@local"])
        } catch { state.stringValue = error.localizedDescription; save.isEnabled = false }
    }
    @objc private func changeScope() { load() }
    @objc private func refreshSetting() { documents[scope] = nil; load() }
    @objc private func changeValue() { drafts[scope] = value.indexOfSelectedItem; save.isEnabled = value.indexOfSelectedItem != index(documents[scope]?.values[item.metadata.name + "@local"]) }
    @objc private func saveSetting() {
        guard let document = documents[scope] else { return }
        do {
            try service.setPluginSetting(value.indexOfSelectedItem == 0 ? nil : value.indexOfSelectedItem == 1, name: item.metadata.name, scope: scope, workspace: workspace, expectedHash: document.hash)
            documents[scope] = nil; drafts[scope] = nil; load(); state.stringValue = "已保存 · " + state.stringValue; onChange?()
        } catch { state.stringValue = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }; let alert = NSAlert(); alert.messageText = "放弃未保存的插件设置？"; alert.addButton(withTitle: "放弃更改"); alert.addButton(withTitle: "继续编辑"); return alert.runModal() == .alertFirstButtonReturn
    }
}
