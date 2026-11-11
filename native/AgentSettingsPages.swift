import AppKit

// The existing managers keep their storage and permission logic. Their content
// can be hosted in Settings while short confirmations use the visible window.
@MainActor class AgentSettingsPageController: NSWindowController {
    private(set) weak var settingsHostWindow: NSWindow?
    private var embeddedContent: NSView?
    var onSettingsPush: ((AgentSettingsPageController) -> Void)?
    var onSettingsClose: (() -> Void)?
    var presentingWindow: NSWindow? { settingsHostWindow ?? window }
    var pageContentView: NSView? { embeddedContent ?? window?.contentView }

    func settingsContent(in host: NSWindow) -> NSView? {
        guard let content = embeddedContent ?? window?.contentView else { return nil }
        if embeddedContent == nil { window?.contentView = nil; embeddedContent = content }
        settingsHostWindow = host
        host.effectiveAppearance.performAsCurrentDrawingAppearance { AgentSettingsStyle.prepare(content) }
        return content
    }
    func canLeaveSettings() -> Bool {
        guard presentingWindow?.attachedSheet == nil else { return false }
        guard let window else { return true }
        return window.delegate?.windowShouldClose?(window) ?? true
    }
    func settingsDidAppear() {
        if let window { window.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: window)) }
    }
    func settingsWillLeave() {}
    func endSettingsHosting() {
        settingsWillLeave()
        onSettingsPush = nil; onSettingsClose = nil
        embeddedContent?.removeFromSuperview(); settingsHostWindow = nil
        window?.close()
    }
    func presentSettingsChild(_ controller: AgentSettingsPageController) {
        if let onSettingsPush { onSettingsPush(controller) }
        else { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil) }
    }
    override func close() {
        if let onSettingsClose { onSettingsClose() } else { super.close() }
    }
    @objc func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        settingsHostWindow == nil ? nil : AgentSettingsTableRow()
    }
}

@MainActor private final class AgentSettingsTableRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
}

@MainActor enum AgentSettingsStyle {
    static func prepare(_ root: NSView) {
        func apply(_ view: NSView) {
            if let table = view as? NSTableView { table.style = .inset; table.backgroundColor = .clear }
            if let scroll = view as? NSScrollView {
                scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 9
                scroll.layer?.borderWidth = scroll.identifier?.rawValue == "hook-event-groups" ? 0 : 1; scroll.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
                scroll.backgroundColor = .textBackgroundColor
            }
            if let button = view as? NSButton, !(button is NSPopUpButton) { button.font = .systemFont(ofSize: 13) }
            if let tabs = view as? NSSegmentedControl { tabs.font = .systemFont(ofSize: 12) }
            // Keep the detail usable alongside the settings navigation on a
            // narrow desktop window, without changing the stored configuration.
            for constraint in view.constraints where constraint.firstAttribute == .width && constraint.relation == .equal && constraint.secondItem == nil && (185...260).contains(constraint.constant) {
                if constraint.firstItem is NSScrollView { constraint.constant = 180 }
            }
            for child in view.subviews { apply(child) }
        }
        root.wantsLayer = true
        if let root = root as? AgentThemeView { root.fill = AgentWorkbenchTheme.surface }
        else { root.layer?.backgroundColor = AgentWorkbenchTheme.surface.cgColor }
        apply(root)
    }
}

@MainActor private final class AgentSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class AgentSettingsPageHost: NSView {
    private struct Entry { let controller: AgentSettingsPageController; let view: NSView; let title: String }
    private let back = NSButton(title: "返回", target: nil, action: nil), header = NSStackView()
    private let tabs = NSSegmentedControl(), context = NSTextField(labelWithString: "")
    private let viewport = NSScrollView(), document = AgentSettingsDocument(), empty = NSTextField(labelWithString: "请先选择任务")
    private var entries: [Entry] = [], keys: [String] = [], selectedTab = 0
    private var category = "", identity = ""
    private var makePage: ((String) -> AgentSettingsPageController?)?
    var currentController: AgentSettingsPageController? { entries.last?.controller }

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.isBordered = false; back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.target = self; back.action = #selector(goBack)
        tabs.trackingMode = .selectOne; tabs.target = self; tabs.action = #selector(changeTab); tabs.setAccessibilityLabel("设置页面类型")
        context.font = .systemFont(ofSize: 12); context.textColor = AgentWorkbenchTheme.secondaryText; context.lineBreakMode = .byTruncatingMiddle
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [back, tabs, NSView(), context] { header.addArrangedSubview(view) }; header.spacing = 12
        viewport.drawsBackground = false; viewport.hasVerticalScroller = true; viewport.scrollerStyle = .overlay; viewport.setAccessibilityLabel("设置内容")
        document.translatesAutoresizingMaskIntoConstraints = false; viewport.documentView = document
        let column = NSStackView(views: [header, viewport]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 14
        for view in [column, empty] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor), header.heightAnchor.constraint(equalToConstant: 30), viewport.widthAnchor.constraint(equalTo: column.widthAnchor),
            document.widthAnchor.constraint(equalTo: viewport.contentView.widthAnchor), document.heightAnchor.constraint(greaterThanOrEqualTo: viewport.contentView.heightAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateHeader()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }
    func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance { entries.forEach { AgentSettingsStyle.prepare($0.view) } }
    }

    @discardableResult func show(category: String, identity: String, scope: String, make: @escaping (String) -> AgentSettingsPageController?) -> Bool {
        if self.category == category, self.identity == identity, !entries.isEmpty { return true }
        guard leave() else { return false }
        self.category = category; self.identity = identity; makePage = make; context.stringValue = scope
        let options: [(String, String)] = category == "extensions" ? [("plugins", "插件"), ("skills", "技能"), ("commands", "指令"), ("mcp", "连接器"), ("agents", "智能体")] : category == "memory" ? [("memory", "记忆与指令"), ("rules", "规则")] : [(category, category)]
        keys = options.map(\.0); tabs.segmentCount = options.count
        for (index, option) in options.enumerated() { tabs.setLabel(option.1, forSegment: index) }
        selectedTab = 0; tabs.selectedSegment = 0; loadRoot(); return true
    }
    private func loadRoot() {
        if keys.indices.contains(selectedTab), let controller = makePage?(keys[selectedTab]) { push(controller) }
        updateHeader()
    }
    private func push(_ controller: AgentSettingsPageController) {
        guard let host = window, let content = controller.settingsContent(in: host) else { return }
        entries.last?.view.removeFromSuperview()
        controller.onSettingsPush = { [weak self] child in self?.push(child) }
        controller.onSettingsClose = { [weak self] in self?.goBack() }
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: max(360, (controller.window?.minSize.height ?? 420) - 22)).isActive = true
        entries.append(Entry(controller: controller, view: content, title: controller.window?.title ?? "设置"))
        displayCurrent()
    }
    private func displayCurrent() {
        guard let entry = entries.last else { updateHeader(); return }
        let content = entry.view; document.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor), content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        layoutSubtreeIfNeeded()
        viewport.contentView.scroll(to: .zero); viewport.reflectScrolledClipView(viewport.contentView)
        entry.controller.settingsDidAppear(); updateHeader()
    }
    private func updateHeader() {
        back.isHidden = entries.count < 2; back.title = entries.count > 1 ? "返回 " + entries[entries.count - 2].title : "返回"
        tabs.isHidden = entries.count > 1 || keys.count < 2
        empty.isHidden = !entries.isEmpty
        header.isHidden = category == "hooks" && entries.count == 1
    }
    @objc private func goBack() {
        guard entries.count > 1, entries.last?.controller.canLeaveSettings() == true else { return }
        let entry = entries.removeLast(); entry.controller.endSettingsHosting(); displayCurrent()
    }
    @objc private func changeTab() {
        let next = tabs.selectedSegment
        guard entries.reversed().allSatisfy({ $0.controller.canLeaveSettings() }) else { tabs.selectedSegment = selectedTab; return }
        clearEntries(); selectedTab = next; loadRoot()
    }
    func selectPage(_ key: String) {
        guard let index = keys.firstIndex(of: key), index != selectedTab else { return }
        tabs.selectedSegment = index; changeTab()
    }
    private func clearEntries() {
        for entry in entries.reversed() { entry.controller.endSettingsHosting() }
        entries = []; updateHeader()
    }
    @discardableResult func leave() -> Bool {
        guard entries.reversed().allSatisfy({ $0.controller.canLeaveSettings() }) else { return false }
        clearEntries(); category = ""; identity = ""; makePage = nil; return true
    }
    func finish() { clearEntries(); category = ""; identity = ""; makePage = nil }
}

@MainActor final class AgentAttentionSettingsView: NSStackView {
    private let attention: AgentAttention
    private var controls: [String: NSButton] = [:]
    private let status = NSTextField(labelWithString: "")
    init(attention: AgentAttention) {
        self.attention = attention; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 18
        let current = attention.settings
        func check(_ key: String, _ title: String, _ value: Bool) -> NSButton {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(change)); button.state = value ? .on : .off
            controls[key] = button; return button
        }
        addArrangedSubview(check("enabled", "启用需要我", current.enabled))
        for (title, values) in [("来源", AgentAttentionSource.allCases.map { ("source:" + $0.rawValue, $0.title, current.sources.contains($0.rawValue)) }), ("内容", AgentAttentionKind.allCases.map { ("kind:" + $0.rawValue, $0.title, current.kinds.contains($0.rawValue)) })] {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = AgentWorkbenchTheme.secondaryText
            addArrangedSubview(label)
            let row = NSStackView(views: values.map { check($0.0, $0.1, $0.2) }); row.spacing = 16; addArrangedSubview(row)
        }
        addArrangedSubview(check("notifications", "自动化桌面通知", current.automationNotifications))
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText; addArrangedSubview(status)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func change() {
        var value = attention.settings; value.enabled = controls["enabled"]?.state == .on
        value.sources = AgentAttentionSource.allCases.filter { controls["source:" + $0.rawValue]?.state == .on }.map(\.rawValue)
        value.kinds = AgentAttentionKind.allCases.filter { controls["kind:" + $0.rawValue]?.state == .on }.map(\.rawValue)
        value.automationNotifications = controls["notifications"]?.state == .on
        do { try attention.setSettings(value); status.stringValue = "已保存" }
        catch {
            status.stringValue = error.localizedDescription
            controls["enabled"]?.state = attention.settings.enabled ? .on : .off
            controls["notifications"]?.state = attention.settings.automationNotifications ? .on : .off
            for source in AgentAttentionSource.allCases { controls["source:" + source.rawValue]?.state = attention.settings.sources.contains(source.rawValue) ? .on : .off }
            for kind in AgentAttentionKind.allCases { controls["kind:" + kind.rawValue]?.state = attention.settings.kinds.contains(kind.rawValue) ? .on : .off }
        }
    }
}
