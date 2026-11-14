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
    var isPageVisible: Bool { pageContentView?.window?.isVisible == true && pageContentView?.isHiddenOrHasHiddenAncestor != true }
    var minimumSettingsContentHeight: CGFloat { max(360, (window?.minSize.height ?? 420) - 22) }

    func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        guard let content = embeddedContent ?? window?.contentView else { return nil }
        if embeddedContent == nil { window?.contentView = nil; embeddedContent = content }
        settingsHostWindow = host
        if styled { host.effectiveAppearance.performAsCurrentDrawingAppearance { AgentSettingsStyle.prepare(content) } }
        return content
    }
    func pageDidLayout() {}
    func canLeaveSettings() -> Bool {
        guard presentingWindow?.attachedSheet == nil else { return false }
        guard let window else { return true }
        return window.delegate?.windowShouldClose?(window) ?? true
    }
    func prepareForWorkspaceClose() async -> Bool { canLeaveSettings() }
    func settingsDidAppear() {
        if let window { window.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: window)) }
    }
    func settingsWillLeave() {}
    func detachSettingsHosting() {
        guard let content = embeddedContent else { return }
        content.removeFromSuperview(); embeddedContent = nil; settingsHostWindow = nil
        onSettingsPush = nil; onSettingsClose = nil; window?.contentView = content
    }
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

@MainActor final class AgentSettingsTableRow: NSTableRowView {
    var selectionColor: NSColor { AgentWorkbenchTheme.selection }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        AgentThemeContext.resolve(selectionColor, in: self).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
}

@MainActor final class AgentSettingsStatusField: NSTextField {
    override var stringValue: String { didSet { isHidden = stringValue.isEmpty; toolTip = stringValue } }
    init(_ label: String) {
        super.init(frame: .zero)
        isEditable = false; isSelectable = true; isBezeled = false; drawsBackground = false
        cell?.wraps = true; cell?.isScrollable = false; usesSingleLineMode = false; maximumNumberOfLines = 0; lineBreakMode = .byWordWrapping
        font = .systemFont(ofSize: 11); textColor = AgentWorkbenchTheme.secondaryText; isHidden = true; setAccessibilityLabel(label)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal); setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor enum AgentSettingsStyle {
    static func field(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 13); field.controlSize = .large
        if field.isBezeled { field.bezelStyle = .roundedBezel; field.backgroundColor = .textBackgroundColor }
    }
    static func formRow(_ title: String, _ control: NSView, trailing: Bool) -> NSStackView {
        if let popup = control as? NSPopUpButton {
            popup.font = .systemFont(ofSize: 13); popup.controlSize = .large; popup.bezelColor = .textBackgroundColor
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        }
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13); label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        if !trailing { label.widthAnchor.constraint(equalToConstant: 88).isActive = true }
        let views: [NSView] = title.isEmpty ? [control] : trailing ? [label, NSView(), control] : [label, control]
        let row = NSStackView(views: views); row.alignment = .centerY; row.spacing = 12; row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return row
    }
    static func labeledField(_ title: String, _ field: NSTextField) -> NSStackView {
        self.field(field); field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [label, field]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 8
        field.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }
    static func section(_ title: String, id: String, rows: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 12, weight: .medium); heading.textColor = AgentWorkbenchTheme.secondaryText
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        for row in rows {
            if !body.arrangedSubviews.isEmpty { let line = AgentWorkbenchTheme.rule(); body.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
            body.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let card = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line)
        card.identifier = .init("settings-card-" + id); card.layer?.cornerRadius = 12; card.layer?.borderWidth = 1
        card.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16), body.topAnchor.constraint(equalTo: card.topAnchor, constant: 16), body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)])
        let column = NSStackView(views: [heading, card]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        column.identifier = .init("settings-section-" + id); card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }
    static func form(_ sections: [NSView], label: String) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.identifier = .init("form-input"); scroll.setAccessibilityLabel(label)
        let document = AgentSettingsDocument(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        let body = NSStackView(views: sections); body.orientation = .vertical; body.alignment = .leading; body.spacing = 24
        document.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        for section in sections { section.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        let preferred = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor); preferred.priority = .defaultLow
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor), preferred, body.topAnchor.constraint(equalTo: document.topAnchor, constant: 4), body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2), body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12), body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)])
        return scroll
    }
    static func primaryAction(_ button: NSButton) {
        button.bezelStyle = .rounded; button.controlSize = .large; button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.bezelColor = AgentWorkbenchTheme.accent; button.contentTintColor = AgentWorkbenchTheme.accentText
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
    }
    static func prepare(_ root: NSView) {
        func apply(_ view: NSView) {
            if let table = view as? NSTableView { table.style = .inset; table.backgroundColor = .clear; table.rowHeight = max(32, table.rowHeight); table.intercellSpacing.height = 4 }
            if let label = view as? NSTextField, view.superview is NSTableCellView { label.font = .systemFont(ofSize: 13) }
            if let scroll = view as? NSScrollView {
                scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 9
                scroll.layer?.borderWidth = ["hook-event-groups", "form-input"].contains(scroll.identifier?.rawValue ?? "") ? 0 : 1; scroll.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
                scroll.backgroundColor = .textBackgroundColor
            }
            if let button = view as? NSButton, !(button is NSPopUpButton) { button.font = .systemFont(ofSize: 13) }
            if let popup = view as? NSPopUpButton { popup.font = .systemFont(ofSize: 13); popup.bezelColor = .textBackgroundColor }
            if let tabs = view as? NSSegmentedControl { tabs.font = .systemFont(ofSize: 13); tabs.selectedSegmentBezelColor = AgentWorkbenchTheme.accent }
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

@MainActor enum AgentSettingsScroll {
    static func target(from hit: NSView, within boundary: NSScrollView, dx: CGFloat, dy: CGFloat, modifiers: NSEvent.ModifierFlags) -> NSScrollView? {
        guard abs(dy) > abs(dx), modifiers.intersection([.shift, .control, .option, .command]).isEmpty,
              hit === boundary || hit.isDescendant(of: boundary) else { return nil }
        var view: NSView? = hit, passedInner = false
        while let current = view {
            // These controls own their wheel operations, including value changes.
            if current is NSSlider || current is NSStepper || current is NSPopUpButton || current is NSComboBox || current is NSDatePicker || current is NSScroller { return nil }
            if let scroll = current as? NSScrollView {
                if let document = scroll.documentView {
                    let visible = scroll.documentVisibleRect, bounds = document.bounds
                    let towardMaximum = (dy < 0) == document.isFlipped
                    let remaining = towardMaximum ? bounds.maxY - visible.maxY : visible.minY - bounds.minY
                    if remaining > 0.5 { return passedInner ? scroll : nil }
                }
                passedInner = true
            }
            if current === boundary { break }
            view = current.superview
        }
        return nil
    }
}

@MainActor private final class AgentSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class AgentSettingsPageHost: NSView {
    private struct Entry { let controller: AgentSettingsPageController; let view: NSView; let title: String }
    private let back = NSButton(title: "返回", target: nil, action: nil), header = NSStackView()
    private let tabs = NSSegmentedControl(), context = NSTextField(labelWithString: "")
    private let sourceFolder = NSPopUpButton(), sourceRow = NSStackView()
    private var selectedSource:String?, onSelectSource:((String)->Bool)?
    private let viewport = NSScrollView(), document = AgentSettingsDocument(), empty = NSTextField(labelWithString: "请先选择任务")
    private var entries: [Entry] = [], keys: [String] = [], selectedTab = 0
    private var category = "", identity = ""
    private var makePage: ((String) -> AgentSettingsPageController?)?
    private var scrollMonitor: Any?
    private let forwardedScrolls = NSHashTable<NSScrollView>.weakObjects()
    var currentController: AgentSettingsPageController? { entries.last?.controller }
    var controllers: [AgentSettingsPageController] { entries.map(\.controller) }
    var selectedPageKey:String? { keys.indices.contains(selectedTab) ? keys[selectedTab] : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.isBordered = false; back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.target = self; back.action = #selector(goBack)
        tabs.trackingMode = .selectOne; tabs.font = .systemFont(ofSize: 13); tabs.selectedSegmentBezelColor = AgentWorkbenchTheme.accent
        tabs.target = self; tabs.action = #selector(changeTab); tabs.setAccessibilityLabel("设置页面类型")
        context.font = .systemFont(ofSize: 12); context.textColor = AgentWorkbenchTheme.secondaryText; context.lineBreakMode = .byTruncatingMiddle
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [back, tabs, NSView(), context] { header.addArrangedSubview(view) }; header.spacing = 12
        sourceFolder.target = self; sourceFolder.action = #selector(changeSource); sourceFolder.setAccessibilityLabel("设置源文件夹"); sourceFolder.identifier = .init("settings-source-folder")
        sourceFolder.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        sourceRow.addArrangedSubview(NSTextField(labelWithString:"源文件夹")); sourceRow.addArrangedSubview(sourceFolder); sourceRow.addArrangedSubview(NSView()); sourceRow.spacing = 10; sourceRow.isHidden = true
        viewport.drawsBackground = false; viewport.hasVerticalScroller = true; viewport.scrollerStyle = .overlay; viewport.setAccessibilityLabel("设置内容")
        document.translatesAutoresizingMaskIntoConstraints = false; viewport.documentView = document
        // Short pages fill the viewport; longer pages keep their own minimum
        // height and scroll without imposing that height on the window.
        let preferredHeight = document.heightAnchor.constraint(equalTo: viewport.contentView.heightAnchor); preferredHeight.priority = .defaultLow
        let column = NSStackView(views: [sourceRow, header, viewport]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 14; column.distribution = .fill
        for view in [column, empty] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            sourceRow.widthAnchor.constraint(equalTo:column.widthAnchor),sourceFolder.widthAnchor.constraint(lessThanOrEqualTo:column.widthAnchor,multiplier:0.8),sourceRow.heightAnchor.constraint(equalToConstant:30),header.widthAnchor.constraint(equalTo: column.widthAnchor), header.heightAnchor.constraint(equalToConstant: 30), viewport.widthAnchor.constraint(equalTo: column.widthAnchor),
            document.widthAnchor.constraint(equalTo: viewport.contentView.widthAnchor), document.heightAnchor.constraint(greaterThanOrEqualTo: viewport.contentView.heightAnchor), preferredHeight,
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateHeader()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopScrollMonitor() }
        else if !entries.isEmpty { startScrollMonitor() }
    }
    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, !self.entries.isEmpty, !self.isHiddenOrHasHiddenAncestor,
                  let window = self.window, event.window === window else { return event }
            if event.phase.contains(.began) || event.momentumPhase.contains(.began) { self.forwardedScrolls.removeAllObjects() }
            let hit = self.viewport.superview.flatMap { self.viewport.hitTest($0.convert(event.locationInWindow, from: nil)) }
            // AppKit also needs the original zero-delta gesture and momentum
            // endings in each scroll view that received forwarded movement.
            if event.scrollingDeltaX == 0 && event.scrollingDeltaY == 0 {
                let native = (hit as? NSScrollView) ?? hit?.enclosingScrollView
                self.forwardedScrolls.allObjects.filter { $0 !== native }.forEach { $0.scrollWheel(with: event) }
                if !event.phase.intersection([.ended, .cancelled]).isEmpty || event.momentumPhase.contains(.ended) { self.forwardedScrolls.removeAllObjects() }
                return event
            }
            guard let hit,
                  let target = AgentSettingsScroll.target(from: hit, within: self.viewport, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, modifiers: event.modifierFlags) else { return event }
            if !event.phase.isEmpty || !event.momentumPhase.isEmpty { self.forwardedScrolls.add(target) }
            target.scrollWheel(with: event)
            return nil
        }
    }
    private func stopScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        forwardedScrolls.removeAllObjects()
    }

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
    func setSourceFolders(_ folders:[String], selected:String?, primary:String?, onSelect:((String)->Bool)?) {
        sourceRow.isHidden = folders.count < 2; context.isHidden = !sourceRow.isHidden
        selectedSource = selected; onSelectSource = onSelect; sourceFolder.removeAllItems()
        let names = folders.map{URL(fileURLWithPath:$0).lastPathComponent}
        for (index,path) in folders.enumerated() {
            let label = names.filter{$0 == names[index]}.count > 1 ? URL(fileURLWithPath:path).deletingLastPathComponent().lastPathComponent + "/" + names[index] : names[index]
            let item = NSMenuItem(title:label + (path == primary ? " · 主要" : ""),action:nil,keyEquivalent:""); item.representedObject = path; item.toolTip = path; sourceFolder.menu?.addItem(item)
            if path == selected { sourceFolder.select(item) }
        }
        sourceFolder.toolTip = selected
    }
    @objc private func changeSource() {
        guard let path = sourceFolder.selectedItem?.representedObject as? String, path != selectedSource else { return }
        if onSelectSource?(path) != true, let previous = selectedSource, let item = sourceFolder.itemArray.first(where:{$0.representedObject as? String == previous}) { sourceFolder.select(item) }
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
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: controller.minimumSettingsContentHeight).isActive = true
        entries.append(Entry(controller: controller, view: content, title: controller.window?.title ?? "设置"))
        displayCurrent()
    }
    private func displayCurrent() {
        guard let entry = entries.last else { updateHeader(); return }
        forwardedScrolls.removeAllObjects()
        let content = entry.view; document.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor), content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        layoutSubtreeIfNeeded()
        viewport.contentView.scroll(to: .zero); viewport.reflectScrolledClipView(viewport.contentView)
        startScrollMonitor()
        entry.controller.settingsDidAppear(); updateHeader()
    }
    private func updateHeader() {
        back.isHidden = entries.count < 2; back.title = entries.count > 1 ? "返回 " + entries[entries.count - 2].title : "返回"
        tabs.isHidden = entries.count > 1 || keys.count < 2
        empty.isHidden = !entries.isEmpty
        header.isHidden = ["hooks", "worktrees"].contains(category) && entries.count == 1
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
        stopScrollMonitor()
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
