import AppKit

@MainActor final class AgentThemePreviewButton: NSButton {
    let style: AgentThemeStyle
    init(style: AgentThemeStyle) {
        self.style = style; super.init(frame: .zero)
        title = style.title; isBordered = false; setButtonType(.momentaryPushIn)
        setAccessibilityLabel(style.title + "主题"); identifier = NSUserInterfaceItemIdentifier("theme-preview-" + style.rawValue)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let selected = state == .on, accent = AgentThemePalette.literal(.accent, style: style, dark: dark)
        let preview = NSRect(x: 3, y: 30, width: max(0, bounds.width - 6), height: bounds.height - 34)
        let outline = NSBezierPath(roundedRect: preview, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState(); outline.addClip()
        AgentThemePalette.literal(.sidebar, style: style, dark: dark).setFill(); preview.fill()
        AgentThemePalette.sidebarGradient(style: style, dark: dark)?.draw(in: preview, angle: -90)
        let page = NSRect(x: preview.minX + preview.width * 0.27, y: preview.minY + 5, width: preview.width * 0.73 - 5, height: preview.height - 10)
        AgentThemePalette.literal(.surface, style: style, dark: dark).setFill(); NSBezierPath(roundedRect: page, xRadius: 4, yRadius: 4).fill()
        accent.setFill(); NSBezierPath(roundedRect: NSRect(x: preview.minX + 6, y: preview.maxY - 18, width: max(8, preview.width * 0.27 - 12), height: 5), xRadius: 2, yRadius: 2).fill()
        AgentThemePalette.literal(.secondaryText, style: style, dark: dark).withAlphaComponent(0.35).setFill()
        for i in 0..<3 { NSBezierPath(roundedRect: NSRect(x: page.minX + 8, y: page.maxY - 17 - CGFloat(i * 8), width: max(8, page.width * (i == 2 ? 0.42 : 0.66)), height: 3), xRadius: 1.5, yRadius: 1.5).fill() }
        accent.setFill(); NSBezierPath(roundedRect: NSRect(x: page.maxX - 14, y: page.minY + 7, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        (selected ? accent : AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: self)).setStroke(); outline.lineWidth = selected ? 2 : 1; outline.stroke()
        let name = NSAttributedString(string: style.title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular), .foregroundColor: isEnabled ? NSColor.labelColor : .disabledControlTextColor])
        name.draw(at: NSPoint(x: max(3, (bounds.width - name.size().width) / 2 - 8), y: 7))
        let mark = NSRect(x: bounds.midX + name.size().width / 2 + 2, y: 10, width: 9, height: 9)
        if selected { accent.setFill(); NSBezierPath(ovalIn: mark).fill() }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke(); let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9); focus.lineWidth = 2; focus.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class AgentThemeStyleSelectionView: NSStackView {
    private let service: AgentThemeStyles, mode: () -> AgentWorkMode, gallery: Bool
    private let caption = NSTextField(labelWithString: ""), popup = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: ""), reload = NSButton(title: "重新载入", target: nil, action: nil)
    private var previews: [AgentThemePreviewButton] = []
    init(service: AgentThemeStyles, gallery: Bool, mode: @escaping () -> AgentWorkMode) {
        self.service = service; self.mode = mode; self.gallery = gallery; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        if gallery {
            caption.font = .systemFont(ofSize: 13); addArrangedSubview(caption)
            previews = AgentThemeStyle.allCases.map(AgentThemePreviewButton.init)
            let row = NSStackView(views: previews); row.distribution = .fillEqually; row.spacing = 12
            for (index, button) in previews.enumerated() { button.tag = index; button.target = self; button.action = #selector(selectStyle(_:)); button.heightAnchor.constraint(equalToConstant: 112).isActive = true }
            addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        } else {
            popup.addItems(withTitles: AgentThemeStyle.allCases.map(\.title)); popup.target = self; popup.action = #selector(selectPopup)
            popup.identifier = NSUserInterfaceItemIdentifier("theme-binding-" + mode().rawValue)
            popup.setAccessibilityLabel(mode().title + "：绑定主题"); popup.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let row = AgentSettingsStyle.formRow("绑定主题", popup, trailing: true); addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText
        reload.target = self; reload.action = #selector(reloadSettings)
        let footer = NSStackView(views: [status, NSView(), reload]); footer.spacing = 12; addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentThemeStyles.changed, object: service)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewWillDraw() { refresh(); super.viewWillDraw() }
    @objc private func refresh() {
        let currentMode = mode(), selected = service.settings[currentMode]
        let title = currentMode.title + "模式配色"
        if caption.stringValue != title { caption.stringValue = title }
        let index = AgentThemeStyle.allCases.firstIndex(of: selected) ?? 0
        if popup.indexOfSelectedItem != index { popup.selectItem(at: index) }
        popup.isEnabled = service.error == nil
        for button in previews {
            let next: NSControl.StateValue = button.style == selected ? .on : .off
            if button.state != next { button.state = next; button.needsDisplay = true }
            button.isEnabled = service.error == nil; button.setAccessibilityValue(next == .on ? "已选择" : "未选择")
        }
        if let error = service.error, status.stringValue != error { status.stringValue = error }
        reload.isHidden = status.stringValue.isEmpty || status.stringValue == "已保存"
        status.superview?.isHidden = status.stringValue.isEmpty
    }
    private func save(_ style: AgentThemeStyle) {
        var value = service.settings; value[mode()] = style
        do { try service.save(value); status.stringValue = "已保存" }
        catch { status.stringValue = error.localizedDescription }
        refresh()
    }
    @objc private func selectStyle(_ sender: AgentThemePreviewButton) { save(sender.style) }
    @objc private func selectPopup() { guard popup.indexOfSelectedItem >= 0 else { return }; save(AgentThemeStyle.allCases[popup.indexOfSelectedItem]) }
    @objc private func reloadSettings() { service.reload(); service.publish(); status.stringValue = service.error ?? "已重新载入"; refresh() }
}
