import AppKit

// The existing managers keep their storage and permission logic. Their content
// can be hosted in Settings while short confirmations use the visible window.
@MainActor class AgentSettingsPageController: NSWindowController {
    struct DetailHeading: Equatable {
        let title: String
        let scope: String
        var location: String? = nil
    }
    private(set) weak var settingsHostWindow: NSWindow?
    private var embeddedContent: NSView?
    var onSettingsPush: ((AgentSettingsPageController) -> Void)?
    var onSettingsClose: (() -> Void)?
    var settingsContext: (title: String, location: String)?
    var detailHeading: DetailHeading? { didSet { if detailHeading != oldValue { onDetailHeadingChange?() } } }
    var onDetailHeadingChange: (() -> Void)?
    var detailActionRow: AgentSettingsDetailActions?
    var onSettingsRecoveryChange: (() -> Void)?
    func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? { nil }
    func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws { throw PetError("此设置页暂不支持草稿恢复，原记录已保留") }
    func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? { nil }
    var presentingWindow: NSWindow? { settingsHostWindow ?? window }
    var pageContentView: NSView? { embeddedContent ?? window?.contentView }
    var isPageVisible: Bool { pageContentView?.window?.isVisible == true && pageContentView?.isHiddenOrHasHiddenAncestor != true }
    var minimumSettingsContentHeight: CGFloat { max(360, (window?.minSize.height ?? 420) - 22) }
    var usesInternalScrolling: Bool { false }

    func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        guard let content = embeddedContent ?? window?.contentView else { return nil }
        if embeddedContent == nil { window?.contentView = nil; embeddedContent = content }
        settingsHostWindow = host
        if styled { host.effectiveAppearance.performAsCurrentDrawingAppearance { AgentSettingsStyle.prepare(content) } }
        return content
    }
    func pageDidLayout() {}
    func setSettingsActionsHost(_ host: NSStackView?) {
        if let detailActionRow { detailActionRow.setActionsHost(host) }
        else { (pageContentView as? AgentSettingsCatalogPage)?.setActionsHost(host) }
    }
    func canLeaveSettings() -> Bool {
        guard presentingWindow?.hasBlockingDialog != true else { return false }
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
        onSettingsPush = nil; onSettingsClose = nil; onSettingsRecoveryChange = nil; onDetailHeadingChange = nil
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
        if let table = tableView as? AgentSettingsCatalogTable, table.identifier?.rawValue == "settings-catalog" { return AgentSettingsCatalogRow(group: table.group(at: row)) }
        return settingsHostWindow == nil ? nil : AgentSettingsTableRow()
    }
    @objc func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let table = tableView as? AgentSettingsCatalogTable, table.identifier?.rawValue == "settings-catalog" else { return tableView.rowHeight }
        return table.group(at: row).height
    }
}

@MainActor final class AgentSettingsDetailActions: NSStackView {
    private let actions: [NSView]
    private weak var actionsHost: NSStackView?
    private lazy var rowHeight = heightAnchor.constraint(equalToConstant: 28)
    init(_ actions: [NSView]) {
        self.actions = actions
        super.init(frame: .zero)
        alignment = .centerY; spacing = 8
        addArrangedSubview(NSView())
        actions.forEach(addArrangedSubview)
        rowHeight.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setActionsHost(_ host: NSStackView?) {
        guard actionsHost !== host else { return }
        for action in actions {
            (action.superview as? NSStackView)?.removeArrangedSubview(action)
            action.removeFromSuperview()
            (host ?? self).addArrangedSubview(action)
        }
        actionsHost = host
        rowHeight.constant = host == nil ? 28 : 0
        isHidden = host != nil
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
    var onChange: ((String) -> Void)?
    override var stringValue: String { didSet { isHidden = stringValue.isEmpty; toolTip = stringValue; textColor = AgentWorkbenchTheme.secondaryText; onChange?(stringValue) } }
    func showSaveFailure(_ error: Error) {
        stringValue = AgentSaveFailure.message(for: error)
        toolTip = error.localizedDescription
        textColor = AgentDialogStyle.error
    }
    init(_ label: String) {
        super.init(frame: .zero)
        isEditable = false; isSelectable = true; isBezeled = false; drawsBackground = false
        cell?.wraps = true; cell?.isScrollable = false; usesSingleLineMode = false; maximumNumberOfLines = 0; lineBreakMode = .byWordWrapping
        font = .systemFont(ofSize: 11); textColor = AgentWorkbenchTheme.secondaryText; isHidden = true; setAccessibilityLabel(label)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal); setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class AgentSettingsJSONFeedback: NSStackView {
    private let status: AgentSettingsStatusField
    private let locate = AgentDialogButton(title: "定位错误", target: nil, action: nil)
    private weak var editor: NSTextView?
    private var offset: Int?
    var revealEditor: (() -> Void)?
    var stringValue: String {
        get { status.stringValue }
        set { status.stringValue = newValue }
    }

    init(_ label: String, editor: NSTextView) {
        self.editor = editor
        status = AgentSettingsStatusField(label)
        super.init(frame: .zero)
        alignment = .centerY; spacing = 8; isHidden = true
        locate.target = self; locate.action = #selector(locateError); locate.isHidden = true
        AgentDialogStyle.action(locate)
        addArrangedSubview(status); addArrangedSubview(locate)
        status.onChange = { [weak self] message in
            self?.offset = nil
            self?.locate.isHidden = true
            self?.isHidden = message.isEmpty
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showSaveFailure(_ error: Error) {
        let syntax = editor.flatMap { AgentConfigurationJSON.draftSyntaxFailure(after: error, in: $0.string) }
        status.showSaveFailure((syntax as Error?) ?? error)
        offset = syntax?.location?.offset
        locate.isHidden = offset == nil
    }

    @objc private func locateError() {
        guard let editor, let offset, offset <= editor.string.utf16.count else { return }
        revealEditor?()
        guard let window = editor.window, !editor.isHiddenOrHasHiddenAncestor, window.makeFirstResponder(editor) else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let caret = NSRange(location: offset, length: 0)
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
    }
}

@MainActor final class AgentSettingsDetailPage: AgentSettingsPageController, NSWindowDelegate {
    var onCanLeave: (() -> Bool)?
    var onAppear: (() -> Void)?
    private let scrollsInternally: Bool
    override var minimumSettingsContentHeight: CGFloat { 220 }
    override var usesInternalScrolling: Bool { scrollsInternally }
    init(title: String, content: NSView, scrollsInternally: Bool = true) {
        self.scrollsInternally = scrollsInternally
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false
        super.init(window: window); window.contentView = content; window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onCanLeave?() ?? true }
    override func settingsDidAppear() { onAppear?() }
}

struct AgentSettingsCatalogGroup {
    var title: String? = nil
    var first = true
    var last = true
    var headerHeight: CGFloat { title == nil ? 0 : 30 }
    var footerHeight: CGFloat { last ? 12 : 0 }
    var height: CGFloat { headerHeight + 64 + footerHeight }
}

@MainActor final class AgentSettingsCatalogTable: NSTableView {
    var onOpen: (() -> Void)?
    var onCountChanged: ((Int) -> Void)?
    var groupName: ((Int) -> String)?
    weak var emptyCard: AgentSettingsCatalogEmptyView?
    func group(at row: Int) -> AgentSettingsCatalogGroup {
        guard row >= 0, row < numberOfRows, let groupName else { return .init() }
        let name = groupName(row), first = row == 0 || groupName(row - 1) != name
        return .init(title: first ? name : nil, first: first, last: row == numberOfRows - 1 || groupName(row + 1) != name)
    }
    override func reloadData() {
        super.reloadData()
        onCountChanged?(numberOfRows)
        emptyCard?.isHidden = numberOfRows > 0
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, [36, 76, 124].contains(event.keyCode), selectedRow >= 0, let onOpen { onOpen(); return }
        super.keyDown(with: event)
    }
}

@MainActor final class AgentSettingsCatalogRow: NSTableRowView {
    private let group: AgentSettingsCatalogGroup?
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    init(group: AgentSettingsCatalogGroup? = nil) { self.group = group; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func drawBackground(in dirtyRect: NSRect) {
        guard let group else {
            if isSelected || hovered {
                AgentThemeContext.resolve(isSelected ? AgentWorkbenchTheme.selection : AgentWorkbenchTheme.hover, in: self).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 7, yRadius: 7).fill()
            }
            AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: self).setFill()
            NSRect(x: 16, y: bounds.maxY - 1, width: max(0, bounds.width - 32), height: 1).fill()
            return
        }
        let body = NSRect(x: 1, y: isFlipped ? group.headerHeight : group.footerHeight, width: max(0, bounds.width - 2), height: 64)
        var card = body
        if !group.first { if isFlipped { card.origin.y -= 10 }; card.size.height += 10 }
        if !group.last { if !isFlipped { card.origin.y -= 10 }; card.size.height += 10 }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: body).addClip()
        let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        AgentThemeContext.resolve(AgentWorkbenchTheme.card, in: self).setFill(); outline.fill()
        AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: self).setStroke(); outline.lineWidth = 1; outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if isSelected || hovered {
            AgentThemeContext.resolve(isSelected ? AgentWorkbenchTheme.selection : AgentWorkbenchTheme.hover, in: self).setFill()
            NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        if !group.last {
            AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: self).setFill()
            NSRect(x: 18, y: isFlipped ? body.maxY - 1 : body.minY, width: max(0, bounds.width - 36), height: 1).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class AgentSettingsCatalogCell: NSTableCellView {
    private let open = NSButton()
    var onOpen: (() -> Void)?
    init(title: String, summary: String, symbol: String, status: String, group: AgentSettingsCatalogGroup = .init(), actionLabel: String? = nil, onOpen: (() -> Void)? = nil) {
        super.init(frame: .zero); self.onOpen = onOpen
        let body = NSView(); addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor), body.topAnchor.constraint(equalTo: topAnchor, constant: group.headerHeight), body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -group.footerHeight)])
        if let title = group.title {
            let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 12); heading.textColor = AgentWorkbenchTheme.secondaryText; heading.lineBreakMode = .byTruncatingMiddle; heading.toolTip = title
            heading.identifier = .init("settings-catalog-group"); heading.setAccessibilityLabel("来源分组")
            addSubview(heading); heading.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), heading.topAnchor.constraint(equalTo: topAnchor, constant: 4)])
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()); icon.contentTintColor = AgentWorkbenchTheme.secondaryText
        let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingTail
        let description = NSTextField(labelWithString: summary); description.font = .systemFont(ofSize: 12); description.textColor = AgentWorkbenchTheme.secondaryText; description.lineBreakMode = .byTruncatingTail; description.isHidden = summary.isEmpty
        let labels = NSStackView(views: [name, description]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
        let state = NSTextField(labelWithString: status); state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.isHidden = status.isEmpty
        let actionLabel = actionLabel ?? "配置 " + title
        open.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil); open.symbolConfiguration = .init(pointSize: 11, weight: .medium); open.contentTintColor = AgentWorkbenchTheme.secondaryText; open.isBordered = false; open.target = self; open.action = #selector(showDetails); open.setAccessibilityLabel(actionLabel); open.toolTip = actionLabel
        open.isHidden = onOpen == nil
        imageView = icon; textField = name; toolTip = summary
        for view in [icon, labels, state, open] { body.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal); state.setContentHuggingPriority(.required, for: .horizontal)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 18), icon.centerYAnchor.constraint(equalTo: body.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14), labels.centerYAnchor.constraint(equalTo: body.centerYAnchor), labels.trailingAnchor.constraint(equalTo: state.leadingAnchor, constant: -12),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor), description.widthAnchor.constraint(equalTo: labels.widthAnchor),
            state.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: onOpen == nil ? 0 : -10), state.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            open.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14), open.centerYAnchor.constraint(equalTo: body.centerYAnchor), open.widthAnchor.constraint(equalToConstant: onOpen == nil ? 0 : 24), open.heightAnchor.constraint(equalToConstant: 28)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func showDetails() { onOpen?() }
}

@MainActor private final class AgentSettingsEmptyIllustration: NSView {
    let icon = NSImageView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 24, weight: .regular); icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = AgentWorkbenchTheme.secondaryText
        addSubview(icon); icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4), icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: self).setStroke()
        for rect in [NSRect(x: 6, y: 13, width: 52, height: 36), NSRect(x: 11, y: 18, width: 42, height: 36), NSRect(x: 16, y: 23, width: 32, height: 36)] {
            let outline = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5); outline.lineWidth = 1; outline.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class AgentSettingsCatalogEmptyView: AgentThemeView {
    let label: NSTextField
    private let illustration = AgentSettingsEmptyIllustration()
    private let symbol: String
    init(symbol: String, text: String) {
        self.symbol = symbol; label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero); fill = AgentWorkbenchTheme.card; stroke = AgentWorkbenchTheme.line
        identifier = .init("settings-catalog-empty-card"); layer?.cornerRadius = 10; layer?.borderWidth = 1
        label.identifier = .init("settings-list-empty"); label.font = .systemFont(ofSize: 16, weight: .medium); label.alignment = .center
        illustration.identifier = .init("settings-empty-illustration")
        let column = NSStackView(views: [illustration, label]); column.orientation = .vertical; column.alignment = .centerX; column.spacing = 12
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.centerYAnchor.constraint(equalTo: centerYAnchor), column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), label.widthAnchor.constraint(equalTo: column.widthAnchor), illustration.widthAnchor.constraint(equalToConstant: 64), illustration.heightAnchor.constraint(equalToConstant: 64), heightAnchor.constraint(equalToConstant: 154)])
        setMessage(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setMessage(_ text: String) {
        label.stringValue = text
        illustration.icon.image = NSImage(systemSymbolName: text.hasPrefix("未找到") ? "magnifyingglass" : symbol, accessibilityDescription: nil)
    }
}

@MainActor final class AgentSettingsCatalogPage: AgentThemeView {
    private let actions: [NSView], toolbar: NSView
    private let count = NSTextField(labelWithString: ""), bar = NSStackView(), filters = NSStackView(), actionRow = NSStackView(), filterSpacer = NSView()
    private var hasFilters = false
    private var barTop: NSLayoutConstraint!, barHeight: NSLayoutConstraint!, filtersTop: NSLayoutConstraint!, filtersHeight: NSLayoutConstraint!, toolbarWidth: NSLayoutConstraint?
    private weak var actionsHost: NSStackView?

    init(table: AgentSettingsCatalogTable, toolbar: NSView, status: AgentSettingsStatusField, actions: [NSView], symbol: String) {
        self.actions = actions; self.toolbar = toolbar
        super.init(frame: .zero); fill = AgentWorkbenchTheme.settings; identifier = .init("settings-catalog-page")
        let scroll = table.enclosingScrollView ?? NSScrollView(), count = self.count
        for view in actions {
            (view.superview as? NSStackView)?.removeArrangedSubview(view); view.removeFromSuperview()
            view.heightAnchor.constraint(equalToConstant: 28).isActive = true; actionRow.addArrangedSubview(view)
        }
        actionRow.alignment = .centerY; actionRow.spacing = 8; actionRow.identifier = .init("settings-catalog-actions")
        count.stringValue = "\(table.numberOfRows) 项"; count.font = .systemFont(ofSize: 12); count.textColor = AgentWorkbenchTheme.secondaryText
        count.identifier = .init("settings-catalog-count"); count.setAccessibilityLabel("列表数量"); count.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.onChange = { [weak status, weak table] value in
            guard let status, let table else { return }
            status.isHidden = value.isEmpty || value == "\(table.numberOfRows) 项" || value == "暂无扩展"
        }
        status.onChange?(status.stringValue)
        for view in [count, NSView(), actionRow] { bar.addArrangedSubview(view) }; bar.alignment = .centerY; bar.spacing = 12; bar.identifier = .init("settings-catalog-toolbar")
        hasFilters = (toolbar as? NSStackView)?.arrangedSubviews.contains { !$0.isHidden && $0 is NSControl } ?? true
        if toolbar.subviews.contains(where: { $0 is NSSearchField }) { toolbar.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        filters.alignment = .centerY; filters.spacing = 12; filters.identifier = .init("settings-catalog-filters"); filters.isHidden = !hasFilters
        if hasFilters { filters.addArrangedSubview(toolbar); toolbarWidth = toolbar.widthAnchor.constraint(equalTo: filters.widthAnchor); toolbarWidth?.isActive = true }
        NSLayoutConstraint.deactivate(scroll.constraints.filter { ($0.firstItem as? NSView) === scroll && $0.firstAttribute == .width && $0.relation == .equal && $0.secondItem == nil })
        table.identifier = .init("settings-catalog"); table.rowHeight = 64; table.intercellSpacing = .zero; table.selectionHighlightStyle = .regular
        scroll.identifier = .init("settings-catalog-scroll"); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let oldEmpty = scroll.subviews.first { $0.identifier?.rawValue == "settings-list-empty" } as? NSTextField
        let empty = AgentSettingsCatalogEmptyView(symbol: symbol, text: oldEmpty?.stringValue ?? "暂无内容"); oldEmpty?.removeFromSuperview(); table.emptyCard = empty; empty.isHidden = table.numberOfRows > 0
        for view in [bar, filters, scroll, status, empty] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        barTop = bar.topAnchor.constraint(equalTo: topAnchor, constant: 4); barHeight = bar.heightAnchor.constraint(equalToConstant: 28)
        filtersTop = filters.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: hasFilters ? 12 : 0); filtersHeight = filters.heightAnchor.constraint(equalToConstant: hasFilters ? 28 : 0)
        NSLayoutConstraint.activate([
            barTop, barHeight, bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            filtersTop, filtersHeight, filters.leadingAnchor.constraint(equalTo: bar.leadingAnchor), filters.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor), status.trailingAnchor.constraint(equalTo: bar.trailingAnchor), status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 1), empty.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -1), empty.topAnchor.constraint(equalTo: scroll.topAnchor)
        ])
        updateCount(table.numberOfRows)
        table.onCountChanged = { [weak self] in self?.updateCount($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setActionsHost(_ host: NSStackView?) {
        guard actionsHost !== host else { return }
        for view in actions {
            (view.superview as? NSStackView)?.removeArrangedSubview(view); view.removeFromSuperview(); (host ?? actionRow).addArrangedSubview(view)
        }
        (count.superview as? NSStackView)?.removeArrangedSubview(count); count.removeFromSuperview()
        if filters.arrangedSubviews.contains(where: { $0 === filterSpacer }) { filters.removeArrangedSubview(filterSpacer) }; filterSpacer.removeFromSuperview()
        let external = host != nil
        if external { filters.insertArrangedSubview(count, at: 0); if !hasFilters { filters.addArrangedSubview(filterSpacer) } }
        else { bar.insertArrangedSubview(count, at: 0) }
        toolbarWidth?.isActive = !external
        barTop.constant = external ? 0 : 4; barHeight.constant = external ? 0 : 28; bar.isHidden = external
        actionsHost = host
        updateFilters()
    }
    private func updateCount(_ rowCount: Int) {
        count.stringValue = "\(rowCount) 项"
        count.isHidden = rowCount == 0
        updateFilters()
    }
    private func updateFilters() {
        let external = actionsHost != nil
        let visible = hasFilters || (external && !count.isHidden)
        filtersTop.constant = visible ? (external ? 4 : 12) : 0
        filtersHeight.constant = visible ? 28 : 0
        filters.isHidden = !visible
    }
}

@MainActor enum AgentSettingsCatalog {
    // Reuse each manager's controls after removing only its old split layout.
    static func detach(_ content: NSView) {
        NSLayoutConstraint.deactivate(content.constraints)
        for view in content.subviews { view.removeFromSuperview() }
    }
    static func detail(_ content: NSView) -> NSView {
        let root = NSView(); root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)])
        return root
    }
    static func content(table: AgentSettingsCatalogTable, toolbar: NSView, status: AgentSettingsStatusField, actions: [NSView] = [], symbol: String = "tray") -> NSView {
        AgentSettingsCatalogPage(table: table, toolbar: toolbar, status: status, actions: actions, symbol: symbol)
    }
}

@MainActor enum AgentSettingsStyle {
    static let searchRowPrefix = "settings-search-row:"
    static let sectionHeadingSpacing: CGFloat = 16
    static func listState(_ table: NSTableView, text: String) {
        if let table = table as? AgentSettingsCatalogTable, let empty = table.emptyCard {
            empty.setMessage(text); empty.isHidden = table.numberOfRows > 0; empty.label.isHidden = empty.isHidden
            return
        }
        guard let scroll = table.enclosingScrollView else { return }
        let catalog = scroll.identifier?.rawValue == "settings-catalog-scroll"
        let container = catalog ? (scroll.superview ?? scroll) : scroll
        let identifier = NSUserInterfaceItemIdentifier("settings-list-empty")
        let label: NSTextField
        if let existing = (container.subviews + scroll.subviews).first(where: { $0.identifier == identifier }) as? NSTextField { label = existing }
        else {
            label = NSTextField(wrappingLabelWithString: text); label.identifier = identifier
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        // NSScrollView tiles its own subviews. Catalog feedback belongs to the
        // page layer so changing the message cannot retain an old clip width.
        if label.superview !== container {
            label.removeFromSuperview(); container.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16), label.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16), label.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 20)])
        }
        label.font = .systemFont(ofSize: catalog ? 13 : 12); label.textColor = AgentWorkbenchTheme.secondaryText; label.alignment = catalog ? .left : .center
        label.stringValue = text; label.isHidden = table.numberOfRows > 0
    }
    static func field(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 13); field.controlSize = .large
        if field.isBezeled { field.bezelStyle = .roundedBezel; field.backgroundColor = AgentWorkbenchTheme.card }
    }
    static func formRow(_ title: String, _ control: NSView, trailing: Bool) -> NSStackView {
        func compact(_ view: NSView) {
            if let toggle = view as? NSSwitch { toggle.controlSize = .mini }
            view.subviews.forEach(compact)
        }
        compact(control)
        let accessory: NSView = (control as? NSPopUpButton).map(AgentSettingsPopupFrame.init) ?? control
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 14); label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        if !trailing { label.widthAnchor.constraint(equalToConstant: 88).isActive = true }
        let views: [NSView] = title.isEmpty ? [accessory] : trailing ? [rowIcon(title), label, NSView(), accessory] : [rowIcon(title), label, accessory]
        let row = NSStackView(views: views); row.alignment = .centerY; row.spacing = 12; row.translatesAutoresizingMaskIntoConstraints = false
        if !title.isEmpty { row.identifier = .init(searchRowPrefix + title) }
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return row
    }
    static func labeledField(_ title: String, _ field: NSTextField) -> NSStackView {
        self.field(field); field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 14)
        let row = NSStackView(views: [label, field]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 8
        field.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }
    static func sectionHeading(_ title: String) -> NSView {
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13, weight: .medium); heading.textColor = AgentWorkbenchTheme.secondaryText
        let view = NSView(); view.addSubview(heading); heading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), heading.topAnchor.constraint(equalTo: view.topAnchor), heading.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        return view
    }
    static func section(_ title: String, id: String, rows: [NSView], separatesRows: Bool = true) -> NSStackView {
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        for row in rows {
            if separatesRows, !body.arrangedSubviews.isEmpty { let line = divider(); body.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
            body.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let card = AgentThemeView(fill: AgentWorkbenchTheme.card, stroke: AgentWorkbenchTheme.line)
        card.identifier = .init("settings-card-" + id); card.layer?.cornerRadius = 12; card.layer?.borderWidth = 1
        card.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16), body.topAnchor.constraint(equalTo: card.topAnchor, constant: 10), body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)])
        let column = NSStackView(views: title.isEmpty ? [card] : [sectionHeading(title), card]); column.orientation = .vertical; column.alignment = .leading; column.spacing = sectionHeadingSpacing
        column.identifier = .init("settings-section-" + id)
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }
    static func form(_ sections: [NSView], label: String) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.identifier = .init("form-input"); scroll.setAccessibilityLabel(label)
        let document = AgentSettingsDocument(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        let body = NSStackView(views: sections); body.orientation = .vertical; body.alignment = .leading; body.spacing = 24
        document.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        for section in sections { section.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor), body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)
        ])
        return scroll
    }
    static func primaryAction(_ button: AgentDialogButton) { AgentDialogStyle.action(button, prominent: true) }
    static func refreshPrimaryAction(_ button: AgentDialogButton) { button.prominent = true }
    static func prepare(_ root: NSView) {
        func apply(_ view: NSView) {
            if let table = view as? NSTableView {
                let catalog = table.identifier?.rawValue == "settings-catalog"
                table.style = catalog ? .fullWidth : .inset; table.backgroundColor = .clear; table.rowHeight = max(32, table.rowHeight); table.intercellSpacing.height = catalog ? 0 : 4
            }
            if let label = view as? NSTextField, view.superview is NSTableCellView { label.font = .systemFont(ofSize: 13) }
            if let scroll = view as? NSScrollView {
                scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 9
                scroll.layer?.borderWidth = ["hook-event-groups", "form-input", "settings-catalog-scroll"].contains(scroll.identifier?.rawValue ?? "") ? 0 : 1; scroll.layer?.borderColor = AgentWorkbenchTheme.line.cgColor
                scroll.drawsBackground = false
            }
            if let text = view as? NSTextView { text.drawsBackground = false; text.textColor = .labelColor }
            if let button = view as? NSButton, !(button is NSPopUpButton) { button.font = .systemFont(ofSize: 13) }
            if let popup = view as? NSPopUpButton { popup.font = .systemFont(ofSize: 13); popup.bezelColor = AgentWorkbenchTheme.card }
            if let tabs = view as? NSSegmentedControl { tabs.font = .systemFont(ofSize: 13); tabs.selectedSegmentBezelColor = AgentWorkbenchTheme.accent }
            // Keep the detail usable alongside the settings navigation on a
            // narrow desktop window, without changing the stored configuration.
            for constraint in view.constraints where constraint.firstAttribute == .width && constraint.relation == .equal && constraint.secondItem == nil && (185...260).contains(constraint.constant) {
                if constraint.firstItem is NSScrollView { constraint.constant = 180 }
            }
            for child in view.subviews { apply(child) }
        }
        root.wantsLayer = true
        if let root = root as? AgentThemeView { root.fill = AgentWorkbenchTheme.settings }
        else { AgentWorkbenchTheme.color(root.layer, AgentWorkbenchTheme.settings, animated: false) }
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
    private struct Entry {
        let controller: AgentSettingsPageController, view: NSView, title: String
        var scrollY: Double = 0
    }
    private let back = AgentWorkbenchButton(title: "返回", target: nil, action: nil), header = NSStackView()
    private let tabs = NSSegmentedControl(), context = NSTextField(labelWithString: "")
    private let sourceFolder = NSPopUpButton(), sourceRow = NSStackView()
    private var selectedSource:String?, onSelectSource:((String)->Bool)?
    private let viewport = NSScrollView(), document = AgentSettingsDocument(), empty = NSTextField(labelWithString: "请先选择任务")
    private var entries: [Entry] = [], keys: [String] = [], selectedTab = 0
    private var category = "", identity = "", contextTitle = ""
    private var recoveryContext: AgentSettingsRecovery.Context?, pendingRecoveryY: Double?, recoveryScrollScheduled = false
    var onRecoveryChange: (() -> Void)?
    var onDetailHeading: ((String?) -> Void)?
    private var makePage: ((String) -> AgentSettingsPageController?)?
    private var scrollMonitor: Any?
    private var pageHeight: NSLayoutConstraint?
    private let forwardedScrolls = NSHashTable<NSScrollView>.weakObjects()
    weak var actionsHost: NSStackView? { didSet { updateActions() } }
    private var scopeWidth: NSLayoutConstraint?
    private lazy var compactBackSize = [back.widthAnchor.constraint(equalToConstant: 28), back.heightAnchor.constraint(equalToConstant: 28)]
    weak var titleHost: NSStackView? {
        didSet {
            guard oldValue !== titleHost else { return }
            scopeWidth?.isActive = false
            for view in [back, context] {
                (oldValue ?? header).removeArrangedSubview(view); view.removeFromSuperview()
            }
            let host = titleHost ?? header
            host.insertArrangedSubview(back, at: 0); host.addArrangedSubview(context)
            if titleHost != nil { NSLayoutConstraint.activate(compactBackSize) }
            else { NSLayoutConstraint.deactivate(compactBackSize) }
            scopeWidth = titleHost.map { context.widthAnchor.constraint(lessThanOrEqualTo: $0.widthAnchor, multiplier: 0.42) }
            scopeWidth?.isActive = true
            updateHeader()
        }
    }
    var actionsEnabled = false { didSet { updateHeader() } }
    var currentController: AgentSettingsPageController? { entries.last?.controller }
    var controllers: [AgentSettingsPageController] { entries.map(\.controller) }
    var selectedPageKey:String? { keys.indices.contains(selectedTab) ? keys[selectedTab] : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.isBordered = false; back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.image?.size = NSSize(width: 16, height: 16); back.contentTintColor = .labelColor
        back.identifier = .init("settings-detail-back")
        back.cell?.lineBreakMode = .byTruncatingTail
        back.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        back.target = self; back.action = #selector(goBack)
        tabs.trackingMode = .selectOne; tabs.font = .systemFont(ofSize: 13); tabs.selectedSegmentBezelColor = AgentWorkbenchTheme.accent
        tabs.target = self; tabs.action = #selector(changeTab); tabs.setAccessibilityLabel("设置页面类型")
        context.font = .systemFont(ofSize: 12); context.textColor = AgentWorkbenchTheme.secondaryText; context.lineBreakMode = .byTruncatingMiddle
        context.identifier = .init("settings-editing-context"); context.setAccessibilityLabel("设置编辑对象")
        context.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        context.setContentHuggingPriority(.defaultHigh, for: .horizontal); context.alignment = .right
        for view in [back, tabs, NSView(), context] { header.addArrangedSubview(view) }; header.spacing = 12; header.identifier = .init("settings-manager-navigation")
        sourceFolder.target = self; sourceFolder.action = #selector(changeSource); sourceFolder.setAccessibilityLabel("设置源文件夹"); sourceFolder.identifier = .init("settings-source-folder")
        sourceFolder.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let sourceControl = AgentSettingsPopupFrame(sourceFolder, outlined: true, maximumWidth: 520)
        sourceRow.addArrangedSubview(NSTextField(labelWithString:"源文件夹")); sourceRow.addArrangedSubview(sourceControl); sourceRow.addArrangedSubview(NSView()); sourceRow.spacing = 10; sourceRow.isHidden = true
        viewport.drawsBackground = false; viewport.hasVerticalScroller = true; viewport.scrollerStyle = .overlay; viewport.setAccessibilityLabel("设置内容")
        document.translatesAutoresizingMaskIntoConstraints = false; viewport.documentView = document
        // Short pages fill the viewport; longer pages keep their own minimum
        // height and scroll without imposing that height on the window.
        let preferredHeight = document.heightAnchor.constraint(equalTo: viewport.contentView.heightAnchor); preferredHeight.priority = .defaultLow
        let column = NSStackView(views: [sourceRow, header, viewport]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10; column.distribution = .fill
        for view in [column, empty] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            sourceRow.widthAnchor.constraint(equalTo:column.widthAnchor),sourceControl.widthAnchor.constraint(lessThanOrEqualTo:column.widthAnchor,multiplier:0.8),sourceRow.heightAnchor.constraint(equalToConstant:30),header.widthAnchor.constraint(equalTo: column.widthAnchor), header.heightAnchor.constraint(equalToConstant: 26), viewport.widthAnchor.constraint(equalTo: column.widthAnchor),
            document.widthAnchor.constraint(equalTo: viewport.contentView.widthAnchor), document.heightAnchor.constraint(greaterThanOrEqualTo: viewport.contentView.heightAnchor), preferredHeight,
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateHeader()
        viewport.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(recoveryBoundsChanged), name: NSView.boundsDidChangeNotification, object: viewport.contentView)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func recoveryBoundsChanged(_ note: Notification) { if pendingRecoveryY == nil { onRecoveryChange?() } }
    override func layout() { super.layout(); entries.forEach { $0.controller.pageDidLayout() }; scheduleRecoveryScroll() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.autorecalculatesKeyViewLoop = true
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

    @discardableResult func show(category: String, identity: String, scope: String, recoveryContext: AgentSettingsRecovery.Context? = nil, make: @escaping (String) -> AgentSettingsPageController?) -> Bool {
        if self.category == category, self.identity == identity, !entries.isEmpty { return true }
        guard leave() else { return false }
        self.category = category; self.identity = identity; makePage = make; contextTitle = scope
        self.recoveryContext = recoveryContext
        let options: [(String, String)] = category == "extensions" ? [("plugins", "插件"), ("skills", "技能"), ("commands", "指令"), ("mcp", "连接器"), ("agents", "智能体")] : category == "memory" ? [("memory", "记忆与指令"), ("rules", "规则")] : [(category, category)]
        keys = options.map(\.0); tabs.segmentCount = options.count
        for (index, option) in options.enumerated() { tabs.setLabel(option.1, forSegment: index) }
        selectedTab = 0; tabs.selectedSegment = 0; loadRoot(); return true
    }
    func setSourceFolders(_ folders:[String], selected:String?, primary:String?, onSelect:((String)->Bool)?) {
        selectedSource = selected; onSelectSource = onSelect; sourceFolder.removeAllItems()
        let names = folders.map{URL(fileURLWithPath:$0).lastPathComponent}
        for (index,path) in folders.enumerated() {
            let label = names.filter{$0 == names[index]}.count > 1 ? URL(fileURLWithPath:path).deletingLastPathComponent().lastPathComponent + "/" + names[index] : names[index]
            let item = NSMenuItem(title:label + (path == primary ? " · 主要" : ""),action:nil,keyEquivalent:""); item.representedObject = path; item.toolTip = path; sourceFolder.menu?.addItem(item)
            if path == selected { sourceFolder.select(item) }
        }
        sourceFolder.toolTip = selected
        updateHeader()
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
        if let index = entries.indices.last {
            entries[index].scrollY = pendingRecoveryY ?? max(0, viewport.contentView.bounds.minY)
            entries[index].view.removeFromSuperview()
        }
        controller.onSettingsPush = { [weak self] child in self?.push(child) }
        controller.onSettingsClose = { [weak self] in self?.goBack() }
        controller.onSettingsRecoveryChange = { [weak self] in self?.onRecoveryChange?() }
        controller.onDetailHeadingChange = { [weak self, weak controller] in
            if self?.currentController === controller { self?.updateHeader() }
        }
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: controller.minimumSettingsContentHeight).isActive = true
        entries.append(Entry(controller: controller, view: content, title: controller.window?.title ?? "设置"))
        displayCurrent()
    }
    private func displayCurrent() {
        guard let entry = entries.last else { updateHeader(); return }
        pendingRecoveryY = nil
        pageHeight?.isActive = false; pageHeight = nil
        forwardedScrolls.removeAllObjects()
        let content = entry.view; document.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        AgentThemeContext.refresh(content, invalidate: true)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor), content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        if entry.controller.usesInternalScrolling {
            pageHeight = content.heightAnchor.constraint(equalTo: viewport.contentView.heightAnchor)
            pageHeight?.isActive = true
        }
        updateHeader(); layoutSubtreeIfNeeded()
        AgentSettingsRecovery.restoreScroll(entry.scrollY, to: viewport)
        startScrollMonitor()
        entry.controller.settingsDidAppear()
        window?.recalculateKeyViewLoop()
        onRecoveryChange?()
    }
    private func updateHeader() {
        let editing = entries.reversed().compactMap { $0.controller.settingsContext }.first
        let detail = currentController?.detailHeading
        context.stringValue = detail?.scope ?? editing?.title ?? contextTitle
        context.toolTip = detail?.location ?? editing?.location
        sourceRow.isHidden = editing != nil || sourceFolder.numberOfItems < 2
        context.isHidden = entries.isEmpty || (detail == nil && !sourceRow.isHidden) || (titleHost != nil && !actionsEnabled)
        let hasParent = entries.count > 1
        back.isHidden = !hasParent || (titleHost != nil && !actionsEnabled)
        let backLabel = hasParent ? "返回 " + entries[entries.count - 2].title : "返回"
        back.title = titleHost == nil ? backLabel : ""
        back.imagePosition = titleHost == nil ? .imageLeading : .imageOnly
        back.toolTip = backLabel; back.setAccessibilityLabel(backLabel)
        tabs.isHidden = entries.count > 1 || keys.count < 2
        empty.isHidden = !entries.isEmpty
        header.isHidden = titleHost != nil ? tabs.isHidden : ["hooks", "worktrees"].contains(category) && entries.count == 1
        if actionsEnabled { onDetailHeading?(detail?.title) }
        updateActions()
    }
    private func updateActions() {
        let current = actionsEnabled ? entries.last?.controller : nil
        // Return hidden pages' actual controls before attaching the visible page.
        for entry in entries where entry.controller !== current { entry.controller.setSettingsActionsHost(nil) }
        current?.setSettingsActionsHost(actionsHost)
        actionsHost?.isHidden = !actionsEnabled || current == nil || actionsHost?.arrangedSubviews.isEmpty == true
        if let actionsHost { AgentThemeContext.refresh(actionsHost, invalidate: true) }
    }
    @objc private func goBack() {
        guard entries.count > 1, entries.last?.controller.canLeaveSettings() == true else { return }
        let entry = entries.removeLast(); entry.controller.setSettingsActionsHost(nil); entry.controller.endSettingsHosting(); displayCurrent()
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
        pageHeight?.isActive = false; pageHeight = nil
        for entry in entries.reversed() { entry.controller.setSettingsActionsHost(nil); entry.controller.endSettingsHosting() }
        entries = []; updateHeader()
    }
    @discardableResult func leave() -> Bool {
        guard entries.reversed().allSatisfy({ $0.controller.canLeaveSettings() }) else { return false }
        clearEntries(); category = ""; identity = ""; makePage = nil; recoveryContext = nil; pendingRecoveryY = nil; onRecoveryChange?(); return true
    }
    func finish() { clearEntries(); category = ""; identity = ""; makePage = nil; recoveryContext = nil; pendingRecoveryY = nil }
    func prepareToQuit(preserving ids: Set<ObjectIdentifier>) -> Bool {
        entries.reversed().allSatisfy { ids.contains(ObjectIdentifier($0.controller)) || $0.controller.canLeaveSettings() }
    }
    func captureRecovery(active: Bool) throws -> AgentSettingsRecovery.State? {
        guard let recoveryContext, let root = selectedPageKey, AgentSettingsRecovery.roots.contains(root), !entries.isEmpty else { return nil }
        var pages: [AgentSettingsRecovery.Page] = []
        for entry in entries where !(entry.controller is AgentSettingsDetailPage) {
            guard let page = try entry.controller.captureSettingsRecovery() else { return nil }; pages.append(page)
        }
        let value = AgentSettingsRecovery.State(context: recoveryContext, category: category, root: root, active: active,
            pages: pages, y: pendingRecoveryY ?? max(0, viewport.contentView.bounds.minY))
        guard value.valid else { throw PetError("设置编辑恢复格式无效，原草稿已保留") }; return value
    }
    func restoreRecovery(_ value: AgentSettingsRecovery.State, make: @escaping (String) -> AgentSettingsPageController?) throws {
        guard value.valid else { throw PetError("设置草稿版本或范围无效，原记录已保留") }
        do {
            let scope = value.category == "worktrees" ? "所有项目" : value.context.workspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "用户设置"
            guard show(category: value.category, identity: value.context.identity, scope: scope, recoveryContext: value.context, make: make) else { throw PetError("请先处理当前设置更改") }
            selectPage(value.root)
            guard let root = entries.first?.controller else { throw PetError("原设置页面暂不可用") }
            try root.restoreSettingsRecovery(value.pages[0]); root.settingsDidAppear()
            for page in value.pages.dropFirst() {
                var child: AgentSettingsPageController?
                for entry in entries.reversed() { if let candidate = try entry.controller.makeSettingsRecoveryChild(page) { child = candidate; break } }
                if child == nil { child = make(page.kind) }
                guard let child else { throw PetError("设置子页面暂不支持恢复，原草稿已保留") }
                try child.restoreSettingsRecovery(page); push(child)
            }
            pendingRecoveryY = value.y; scheduleRecoveryScroll()
        } catch { finish(); throw error }
    }
    private func scheduleRecoveryScroll() {
        guard pendingRecoveryY != nil, !recoveryScrollScheduled else { return }; recoveryScrollScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { recoveryScrollScheduled = false }
            guard let y = pendingRecoveryY, window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
            layoutSubtreeIfNeeded(); viewport.contentView.scroll(to: NSPoint(x: 0, y: y)); viewport.reflectScrolledClipView(viewport.contentView); pendingRecoveryY = nil
        }
    }
}

@MainActor final class AgentAttentionSettingsView: NSStackView {
    private let attention: AgentAttention
    private var controls: [String: NSSwitch] = [:]
    private let status = AgentSettingsStatusField("需要我设置状态")
    init(attention: AgentAttention) {
        self.attention = attention; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 20
        let current = attention.settings
        func row(_ key: String, _ title: String, _ value: Bool) -> NSView {
            let toggle = NSSwitch(); toggle.target = self; toggle.action = #selector(change); toggle.state = value ? .on : .off
            toggle.setAccessibilityLabel(title); controls[key] = toggle
            return AgentSettingsStyle.formRow(title, toggle, trailing: true)
        }
        let general = AgentSettingsStyle.section("常规", id: "attention-general", rows: [
            row("enabled", "启用需要我", current.enabled),
            row("notifications", "自动化桌面通知", current.automationNotifications)
        ])
        let sources = AgentSettingsStyle.section("来源", id: "attention-sources", rows: AgentAttentionSource.allCases.map {
            row("source:" + $0.rawValue, $0.title, current.sources.contains($0.rawValue))
        })
        let kinds = AgentSettingsStyle.section("内容", id: "attention-kinds", rows: AgentAttentionKind.allCases.map {
            row("kind:" + $0.rawValue, $0.title, current.kinds.contains($0.rawValue))
        })
        for section in [general, status, sources, kinds] {
            addArrangedSubview(section); section.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func change() {
        var value = attention.settings; value.enabled = controls["enabled"]?.state == .on
        value.sources = AgentAttentionSource.allCases.filter { controls["source:" + $0.rawValue]?.state == .on }.map(\.rawValue)
        value.kinds = AgentAttentionKind.allCases.filter { controls["kind:" + $0.rawValue]?.state == .on }.map(\.rawValue)
        value.automationNotifications = controls["notifications"]?.state == .on
        do { try attention.setSettings(value); status.stringValue = "已保存" }
        catch {
            status.showSaveFailure(error); status.scrollToVisible(status.bounds)
            controls["enabled"]?.state = attention.settings.enabled ? .on : .off
            controls["notifications"]?.state = attention.settings.automationNotifications ? .on : .off
            for source in AgentAttentionSource.allCases { controls["source:" + source.rawValue]?.state = attention.settings.sources.contains(source.rawValue) ? .on : .off }
            for kind in AgentAttentionKind.allCases { controls["kind:" + kind.rawValue]?.state = attention.settings.kinds.contains(kind.rawValue) ? .on : .off }
        }
    }
}
