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

@MainActor final class AgentDialogTextField: NSTextField {
    var outlined = false { didSet { refreshFocus(force: true) } }
    private var windowObserver: NSObjectProtocol?, focusVisible = false
    override init(frame: NSRect) {
        super.init(frame: frame); cell = AgentDialogFieldCell(textCell: "")
        font = .systemFont(ofSize: 13); isEditable = true; isSelectable = true; isBezeled = true; bezelStyle = .roundedBezel; focusRingType = .none
        usesSingleLineMode = true; cell?.wraps = false; cell?.isScrollable = true
        drawsBackground = false; backgroundColor = AgentWorkbenchTheme.card; isAutomaticTextCompletionEnabled = false
        wantsLayer = true; layer?.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.refreshFocus() } }
        return accepted
    }
    private func refreshFocus(force: Bool = false) {
        let focused = currentEditor().map { window?.firstResponder === $0 } ?? false
        guard force || focused != focusVisible else { return }; focusVisible = focused
        layer?.borderWidth = focused ? 1.5 : outlined ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = AgentThemeContext.resolve(focused ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.line, in: self).cgColor
        }
    }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); refreshFocus() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); refreshFocus() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshFocus(force: true) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }; windowObserver = nil
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFocus() }
            }
        }
        refreshFocus(force: true)
    }
}
