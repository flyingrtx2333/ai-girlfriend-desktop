import AppKit

enum AgentSettingsNavigation {
    static let groups: [(String, [String])] = [
        ("个人", ["general", "attention", "modes", "monitor", "shortcuts", "appearance", "model", "memory", "imports"]),
        ("陪伴", ["persona", "voice", "screen", "desktop"]),
        ("集成", ["extensions", "agents", "teams", "hooks", "computer"]),
        ("编码", ["worktrees"]), ("其他", ["experiments", "archived", "about"])
    ]
    static func group(for category: String) -> String { groups.first { $0.1.contains(category) }?.0 ?? "其他" }
    static func symbol(for category: String, fallback: String) -> String {
        ["modes": "rectangle.3.group", "monitor": "list.bullet.rectangle", "appearance": "paintbrush", "teams": "person.2", "imports": "tray.and.arrow.down"][category] ?? fallback
    }
}

@MainActor final class AgentSettingsNavigationButton: NSButton {
    private let navigation: Bool
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var keyboardFocused = false
    override var isFlipped: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var acceptsFirstResponder: Bool { true }
    override var title: String { didSet { setAccessibilityLabel(title); needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    init(title: String, symbol: String, navigation: Bool = true, target: AnyObject?, action: Selector?) {
        self.navigation = navigation
        super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        font = .systemFont(ofSize: 13); isBordered = false; focusRingType = .none
        setButtonType(navigation ? .toggle : .momentaryPushIn)
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { keyboardFocused = false; super.mouseDown(with: event); needsDisplay = true }
    override func keyDown(with event: NSEvent) { keyboardFocused = true; super.keyDown(with: event); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); keyboardFocused = NSApp.currentEvent?.type == .keyDown; needsDisplay = true; return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); needsDisplay = true; return accepted }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = navigation && state == .on
        let fill = selected ? AgentWorkbenchTheme.navigationSelection : hovered && window?.isKeyWindow == true ? AgentWorkbenchTheme.hover : .clear
        AgentThemeContext.resolve(fill, in: self).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let color = AgentThemeContext.resolve(selected ? .labelColor : AgentWorkbenchTheme.secondaryText, in: self)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular).applying(.init(paletteColors: [color]))
        (image?.withSymbolConfiguration(config) ?? image)?.draw(in: NSRect(x: navigation ? 10 : 6, y: 7, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let value = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: selected ? .medium : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
        let x: CGFloat = navigation ? 32 : 28
        value.draw(in: NSRect(x: x, y: floor((bounds.height - value.size().height) / 2), width: max(0, bounds.width - x - 10), height: value.size().height))
        if keyboardFocused && window?.isKeyWindow == true && window?.firstResponder === self {
            AgentThemeContext.resolve(AgentWorkbenchTheme.accent, in: self).setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5); focus.lineWidth = 1.5; focus.stroke()
        }
    }
}

@MainActor private final class AgentSettingsSidebarSearchCell: NSSearchFieldCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        AgentThemeContext.resolve(AgentWorkbenchTheme.card, in: controlView).setFill(); path.fill()
        let editor = (controlView as? NSTextField)?.currentEditor()
        let focused = editor != nil && controlView.window?.firstResponder === editor
        AgentThemeContext.resolve(focused ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.line, in: controlView).setStroke()
        path.lineWidth = focused ? 1.5 : 1; path.stroke()
        super.drawInterior(withFrame: frame, in: controlView)
    }
}

@MainActor final class AgentSettingsSidebarSearchField: NSSearchField {
    override init(frame: NSRect) {
        super.init(frame: frame); cell = AgentSettingsSidebarSearchCell(textCell: "")
        isEditable = true; isSelectable = true; isBezeled = true; focusRingType = .none
        font = .systemFont(ofSize: 13); controlSize = .regular
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
