import AppKit

@MainActor final class AgentPluginSettingsWindow: AgentSettingsPageController, NSWindowDelegate {
    private struct Draft: Codable {
        var scope: Int, path: String, hash: String?, base: Int, choice: Int
        var valid: Bool {
            path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 16_384 &&
                AgentSettingsRecovery.validHash(hash) && (0...2).contains(base) && (0...2).contains(choice) && choice != base
        }
    }
    private struct Recovery: Codable {
        var version = 1
        var id: String, instance: String, receiptHash: String, workspace: String?
        var scope: Int, scopeFocused: Bool, drafts: [Draft]
    }
    private let service: AgentPlugins, item: AgentPluginInstallation, workspace: String?
    private let scopes = NSSegmentedControl(labels: ["用户", "项目", "本机"], trackingMode: .selectOne, target: nil, action: nil)
    private let value = NSPopUpButton(), source = NSTextField(labelWithString: ""), state = AgentSettingsStatusField("插件设置保存状态")
    private let save = NSButton(title: "保存", target: nil, action: nil)
    private var displayedDocument: AgentPluginSettingDocument?
    private var drafts: [AgentPluginSettingScope: Draft] = [:]
    private var scopeFocused = false
    var onChange: (() -> Void)?
    private var scope: AgentPluginSettingScope { AgentPluginSettingScope(rawValue: scopes.selectedSegment) ?? .user }
    init(service: AgentPlugins, item: AgentPluginInstallation, workspace: String?) {
        self.service = service; self.item = item; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 270), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 420, height: 270)
        window.title = "插件启用设置" + (workspace.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        scopes.selectedSegment = item.workspace == nil ? 0 : 1; scopes.setEnabled(service.sharedHome != nil, forSegment: 0)
        for index in [1, 2] { scopes.setEnabled(workspace != nil, forSegment: index) }; scopes.target = self; scopes.action = #selector(changeScope); scopes.setAccessibilityLabel("插件设置范围")
        value.addItems(withTitles: ["继承上层", "启用", "停用"]); value.target = self; value.action = #selector(changeValue); value.setAccessibilityLabel("插件启用声明")
        let name = NSTextField(labelWithString: item.metadata.title + " · " + item.metadata.name + "@local"); name.font = .systemFont(ofSize: 14, weight: .semibold); name.lineBreakMode = .byTruncatingTail; name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        source.font = .systemFont(ofSize: 11); source.textColor = AgentWorkbenchTheme.secondaryText; source.lineBreakMode = .byTruncatingMiddle; source.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        save.target = self; save.action = #selector(saveSetting); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshSetting))
        let footer = NSStackView(views: [NSView(), refresh, save]); footer.spacing = 10
        let stack = NSStackView(views: [name, scopes, value, source, state, NSView(), footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); window.contentView = content; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16), source.widthAnchor.constraint(equalTo: stack.widthAnchor), state.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func choice(in document: AgentPluginSettingDocument) -> Int {
        document.values[item.metadata.name + "@local"].map { $0 ? 1 : 2 } ?? 0
    }
    private func requireOriginalInstallation() throws {
        guard let current = try? service.installation(item.id), current.instanceID == item.instanceID,
              current.receiptHash == item.receiptHash else { throw PetError("原插件或版本已变化，草稿已保留") }
    }
    private func showSource(_ path: String) {
        source.stringValue = path
        source.toolTip = path
    }
    private func load() {
        let draft = drafts[scope]
        displayedDocument = nil
        showSource(draft?.path ?? "")
        value.selectItem(at: draft?.choice ?? 0)
        value.isEnabled = draft != nil
        save.isEnabled = false
        do {
            let current = try service.settingDocument(scope, workspace: workspace)
            displayedDocument = current
            showSource(draft?.path ?? current.file.path)
            value.selectItem(at: draft?.choice ?? choice(in: current))
            value.isEnabled = true
            save.isEnabled = draft != nil
            if let draft, draft.path != current.file.path || draft.hash != current.hash {
                state.showSaveFailure(PetError("插件设置已变化，请刷新后重试"))
                return
            }
            let effective = try service.catalog(workspace: workspace).first { $0.metadata.name == item.metadata.name }
            state.stringValue = effective?.enabled == true ? "当前：已启用" : effective?.requestedEnabled == true ? "当前：需本机审阅" : "当前：已停用"
            if let selection = effective?.selection { state.stringValue += " · " + selection.scope.title }
        } catch { state.showSaveFailure(error) }
    }
    @objc private func changeScope() {
        scopeFocused = true
        load()
        onSettingsRecoveryChange?()
    }
    @objc private func refreshSetting() {
        do {
            if var draft = drafts[scope] {
                try requireOriginalInstallation()
                let current = try service.settingDocument(scope, workspace: workspace)
                guard draft.path == current.file.path else { throw PetError("插件设置路径已变化，草稿已保留") }
                draft.hash = current.hash
                draft.base = choice(in: current)
                drafts[scope] = draft.base == draft.choice ? nil : draft
            }
            load()
            onSettingsRecoveryChange?()
        } catch { state.showSaveFailure(error) }
    }
    @objc private func changeValue() {
        let choice = value.indexOfSelectedItem
        guard (0...2).contains(choice) else { return }
        if var draft = drafts[scope] {
            draft.choice = choice
            drafts[scope] = choice == draft.base ? nil : draft
        } else if let document = displayedDocument {
            let base = self.choice(in: document)
            if choice != base {
                drafts[scope] = Draft(scope: scope.rawValue, path: document.file.path, hash: document.hash, base: base, choice: choice)
            }
        }
        scopeFocused = false
        if drafts[scope] == nil { load() }
        else { save.isEnabled = displayedDocument != nil }
        onSettingsRecoveryChange?()
    }
    @objc private func saveSetting() {
        guard let draft = drafts[scope] else { return }
        do {
            try requireOriginalInstallation()
            let current = try service.settingDocument(scope, workspace: workspace)
            guard current.file.path == draft.path else { throw PetError("插件设置路径已变化，草稿已保留") }
            try service.setPluginSetting(draft.choice == 0 ? nil : draft.choice == 1, name: item.metadata.name, scope: scope, workspace: workspace, expectedHash: draft.hash)
            drafts[scope] = nil
            load()
            state.stringValue = "已保存 · " + state.stringValue
            onSettingsRecoveryChange?()
            onChange?()
        } catch { state.showSaveFailure(error) }
    }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        presentingWindow?.makeFirstResponder(scopeFocused ? scopes : value)
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        let responder = presentingWindow?.firstResponder
        let focused = responder === scopes || (responder !== value && scopeFocused)
        return try AgentSettingsRecovery.page("plugin-settings", Recovery(id: item.id, instance: item.instanceID,
            receiptHash: item.receiptHash, workspace: workspace, scope: scope.rawValue, scopeFocused: focused,
            drafts: drafts.values.sorted { $0.scope < $1.scope }))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "plugin-settings" else { throw PetError("设置草稿不属于插件启用设置") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state),
            keys: ["version", "id", "instance", "receiptHash", "workspace", "scope", "scopeFocused", "drafts"])
        for row in raw["drafts"] as? [Any] ?? [] {
            _ = try AgentSettingsRecovery.object(row, keys: ["scope", "path", "hash", "base", "choice"])
        }
        let recovery = try JSONDecoder().decode(Recovery.self, from: page.state)
        let allowed = Set(AgentPluginSettingScope.allCases.map(\.rawValue).filter { scopes.isEnabled(forSegment: $0) })
        guard recovery.version == 1, recovery.id == item.id, recovery.instance == item.instanceID,
              recovery.receiptHash == item.receiptHash, recovery.workspace == workspace else {
            throw PetError("原插件、版本或设置范围已变化，草稿已保留")
        }
        guard allowed.contains(recovery.scope), recovery.drafts.count <= allowed.count,
              Set(recovery.drafts.map(\.scope)).count == recovery.drafts.count,
              recovery.drafts.allSatisfy({ allowed.contains($0.scope) && $0.valid }) else { throw PetError("插件设置草稿范围无效") }
        try requireOriginalInstallation()
        drafts = Dictionary(uniqueKeysWithValues: recovery.drafts.compactMap { draft in
            AgentPluginSettingScope(rawValue: draft.scope).map { ($0, draft) }
        })
        scopes.selectedSegment = recovery.scope
        scopeFocused = recovery.scopeFocused
        load()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !drafts.isEmpty else { return true }
        return AgentUnsavedChanges.discard("放弃未保存的插件设置？")
    }
}
