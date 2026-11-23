import AppKit

@MainActor final class AgentPluginMarketCredentialPage: AgentSettingsPageController, NSWindowDelegate {
    private let market: AgentPluginMarket, destination: URL, requiresUsername: Bool
    private let username = AgentDialogTextField(), token = AgentSecureTextField()
    private let status = AgentSettingsStatusField("市场访问凭据状态")
    private var savedUsername: String
    var onChange: ((Bool) -> Void)?

    init(market: AgentPluginMarket, destination: URL) {
        self.market = market; self.destination = destination
        requiresUsername = AgentPluginMarket.gitRepository(for: destination) != nil
        let stored = try? market.credential(for: destination)
        savedUsername = stored?.username ?? ""
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "访问凭据"; window.minSize = NSSize(width: 420, height: 340); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        detailHeading = .init(title: "访问凭据", scope: requiresUsername ? "HTTPS Git" : "HTTPS 目录")

        let target = NSTextField(labelWithString: destination.absoluteString)
        target.isSelectable = true; target.setAccessibilityLabel("凭据适用地址")
        target.lineBreakMode = .byTruncatingMiddle; target.toolTip = destination.absoluteString
        target.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        username.stringValue = savedUsername
        username.setAccessibilityLabel(requiresUsername ? "用户名" : "用户名（可选）")
        username.placeholderString = requiresUsername ? nil : "可选"
        token.setAccessibilityLabel("访问令牌")
        token.placeholderString = stored == nil ? nil : "已保存 · 输入新令牌替换"
        token.target = self; token.action = #selector(save)
        let secret = AgentSettingsStyle.formRow("访问令牌", token, trailing: false, showsIcon: false)
        let entry = NSStackView(views: [secret, status]); entry.orientation = .vertical; entry.alignment = .leading; entry.spacing = 8
        secret.widthAnchor.constraint(equalTo: entry.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: entry.widthAnchor).isActive = true
        let fields = AgentSettingsStyle.section("连接", id: "market-credential", rows: [
            AgentSettingsStyle.formRow("地址", target, trailing: false, showsIcon: false),
            AgentSettingsStyle.formRow("用户名", username, trailing: false, showsIcon: false),
            entry
        ])
        for input in [username, token] { AgentSettingsStyle.field(input) }
        let form = AgentSettingsStyle.form([fields], label: "市场访问凭据")
        let clear = AgentDialogButton(title: "清除凭据", target: self, action: #selector(clear))
        clear.isEnabled = stored != nil; AgentDialogStyle.action(clear)
        let save = AgentDialogButton(title: "保存凭据", target: self, action: #selector(save))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        AgentSettingsStyle.primaryAction(save)
        let actions = AgentSettingsDetailActions([clear, save]); detailActionRow = actions
        let content = NSStackView(views: [form, actions]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        let root = AgentThemeView(); root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            form.widthAnchor.constraint(equalTo: content.widthAnchor), actions.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.contentView = root
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var usesInternalScrolling: Bool { true }
    override var minimumSettingsContentHeight: CGFloat { 220 }
    override func settingsDidAppear() { presentingWindow?.makeFirstResponder(requiresUsername && username.stringValue.isEmpty ? username : token) }

    private func draftValue(_ field: NSTextField) -> String { field.currentEditor()?.string ?? field.stringValue }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if draftValue(username) == savedUsername, draftValue(token).isEmpty { return true }
        return AgentUnsavedChanges.discard("放弃未保存的访问凭据？", owner: presentingWindow)
    }

    @objc private func save() {
        do {
            let credential = try AgentPluginMarketCredential(username: draftValue(username), token: draftValue(token), requiresUsername: requiresUsername)
            try apply(credential)
        } catch {
            status.showSaveFailure(error)
            if let issue = error as? AgentPluginMarketCredential.FieldError {
                let field: NSTextField = issue == .username ? username : token
                presentingWindow?.makeFirstResponder(field)
            }
        }
    }

    @objc private func clear() {
        guard canLeaveSettings() else { return }
        do { try apply(nil) }
        catch { status.showSaveFailure(error) }
    }

    private func apply(_ credential: AgentPluginMarketCredential?) throws {
        try market.saveCredential(credential, for: destination)
        presentingWindow?.makeFirstResponder(nil)
        savedUsername = credential?.username ?? ""
        username.stringValue = savedUsername
        token.stringValue = ""
        close()
        onChange?(credential != nil)
    }
}
