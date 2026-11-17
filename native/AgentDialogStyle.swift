import AppKit

@MainActor enum AgentDialogStyle {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let error = adaptive(0xb42318, 0xffb4ad)
    static let destructive = adaptive(0xb42318, 0xff938d)
    static let destructiveText = adaptive(0xffffff, 0x3b0a07)
    static func action(_ button: AgentDialogButton, prominent: Bool = false) {
        button.prominent = prominent
        NSLayoutConstraint.activate([button.heightAnchor.constraint(equalToConstant: 28), button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84)])
    }
}

@MainActor final class AgentDialogButton: NSButton {
    var prominent = false { didSet { refreshStyle() } }
    var palette = false { didSet { refreshStyle() } }
    private var tracking: NSTrackingArea?, hovered = false
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; controlSize = .regular; focusRingType = .exterior
        font = .systemFont(ofSize: 13)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isEnabled: Bool { didSet { refreshStyle() } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    private func refreshStyle() {
        if !palette {
            let token = prominent ? (hasDestructiveAction ? AgentDialogStyle.destructiveText : AgentWorkbenchTheme.accentText) : hasDestructiveAction ? AgentDialogStyle.error : .labelColor
            font = .systemFont(ofSize: 13, weight: prominent ? .medium : .regular)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = AgentThemeContext.resolve(token, in: self).usingColorSpace(.sRGB) ?? token
                contentTintColor = color
                attributedTitle = NSAttributedString(string: title, attributes: [.font: font!, .foregroundColor: color.withAlphaComponent(isEnabled ? 1 : 0.4)])
            }
        }
        needsDisplay = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshStyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshStyle() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5), path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill = prominent ? (hasDestructiveAction ? AgentDialogStyle.destructive : AgentWorkbenchTheme.accent) : hasDestructiveAction ? AgentWorkbenchTheme.removed : AgentWorkbenchTheme.subtle
        AgentThemeContext.resolve(fill, in: self).withAlphaComponent(isEnabled ? 1 : 0.4).setFill(); path.fill()
        if isEnabled && (hovered || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill(); path.fill()
        }
        if palette && state == .on {
            AgentThemeContext.resolve(contentTintColor ?? AgentWorkbenchTheme.accent, in: self).setStroke(); path.lineWidth = 1; path.stroke()
        }
        super.draw(dirtyRect)
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
}

@MainActor final class AgentInputAppearance {
    private weak var field: NSTextField?
    private var windowObserver: NSObjectProtocol?, focusVisible = false
    var outlined = false { didSet { refresh(force: true) } }
    init(_ field: NSTextField, outlined: Bool = false) {
        self.field = field; self.outlined = outlined
        field.font = .systemFont(ofSize: 13); field.isEditable = true; field.isSelectable = true
        field.isBezeled = true; field.bezelStyle = .roundedBezel; field.focusRingType = .none
        field.usesSingleLineMode = true; field.cell?.wraps = false; field.cell?.isScrollable = true
        field.drawsBackground = false; field.backgroundColor = AgentWorkbenchTheme.card
        field.isAutomaticTextCompletionEnabled = false; field.wantsLayer = true; field.layer?.cornerRadius = 6
        refresh(force: true)
    }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
    func movedToWindow() {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }; windowObserver = nil
        if let window = field?.window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh(force: true)
    }
    func refresh(force: Bool = false) {
        guard let field else { return }
        let focused = field.currentEditor().map { field.window?.firstResponder === $0 } ?? false
        guard force || focused != focusVisible else { return }; focusVisible = focused
        field.layer?.borderWidth = focused ? 1.5 : outlined ? 1 : 0
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            field.layer?.borderColor = AgentThemeContext.resolve(focused ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.line, in: field).cgColor
        }
    }
    static func paint(_ frame: NSRect, in field: NSTextField, outlined: Bool) {
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            AgentThemeContext.resolve(field.backgroundColor ?? AgentWorkbenchTheme.card, in: field).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            if !outlined {
                AgentThemeContext.resolve(AgentWorkbenchTheme.line, in: field).setStroke()
                let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                border.lineWidth = 1; border.stroke()
            }
        }
    }
}

@MainActor final class AgentDialogTextField: NSTextField {
    private var inputStyle: AgentInputAppearance?
    var outlined: Bool {
        get { inputStyle?.outlined ?? false }
        set { inputStyle?.outlined = newValue }
    }
    override init(frame: NSRect) {
        super.init(frame: frame); cell = AgentDialogFieldCell(textCell: "")
        inputStyle = AgentInputAppearance(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.inputStyle?.refresh() } }
        return accepted
    }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); inputStyle?.refresh() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); inputStyle?.refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); inputStyle?.refresh(force: true) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); inputStyle?.movedToWindow() }
}

@MainActor final class AgentSecureTextField: NSSecureTextField {
    private var inputStyle: AgentInputAppearance?
    override init(frame: NSRect) {
        super.init(frame: frame); cell = AgentSecureFieldCell(textCell: "")
        inputStyle = AgentInputAppearance(self, outlined: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.inputStyle?.refresh() } }
        return accepted
    }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); inputStyle?.refresh() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); inputStyle?.refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); inputStyle?.refresh(force: true) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); inputStyle?.movedToWindow() }
}

@MainActor final class AgentComboBox: NSComboBox {
    private var inputStyle: AgentInputAppearance?
    override init(frame: NSRect) {
        super.init(frame: frame); cell = AgentComboBoxCell(textCell: "")
        inputStyle = AgentInputAppearance(self, outlined: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.inputStyle?.refresh() } }
        return accepted
    }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); inputStyle?.refresh() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); inputStyle?.refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); inputStyle?.refresh(force: true) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); inputStyle?.movedToWindow() }
}

@MainActor private final class AgentSecureFieldCell: NSSecureTextFieldCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        guard let field = controlView as? AgentSecureTextField else { super.draw(withFrame: frame, in: controlView); return }
        AgentInputAppearance.paint(frame, in: field, outlined: true)
        super.drawInterior(withFrame: frame, in: controlView)
    }
}

@MainActor private final class AgentComboBoxCell: NSComboBoxCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        guard let field = controlView as? AgentComboBox else { super.draw(withFrame: frame, in: controlView); return }
        AgentInputAppearance.paint(frame, in: field, outlined: true)
        // Combo cells position their text in titleRect, unlike ordinary fields.
        super.drawInterior(withFrame: super.titleRect(forBounds: frame), in: controlView)
        let x = frame.maxX - 15, y = frame.midY, down: CGFloat = controlView.isFlipped ? 1 : -1
        let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: x - 4, y: y - 2 * down))
        arrow.line(to: NSPoint(x: x, y: y + 2 * down)); arrow.line(to: NSPoint(x: x + 4, y: y - 2 * down))
        arrow.lineWidth = 1.2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        AgentThemeContext.resolve(AgentWorkbenchTheme.secondaryText, in: field).withAlphaComponent(field.isEnabled ? 1 : 0.4).setStroke(); arrow.stroke()
    }
}
