import AppKit
import QuartzCore

@MainActor private final class AgentSidebarCell: NSButtonCell {
    var folder = false, group = false, shortcut: String?
    override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
        if let image {
            let width: CGFloat = group ? 12 : 18, inset: CGFloat = group ? 8 : 12
            drawImage(image, withFrame: NSRect(x: frame.minX + inset, y: frame.midY - width / 2, width: width, height: width), in: controlView)
        }
        if folder, let image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) {
            drawImage(image, withFrame: NSRect(x: frame.minX + 28, y: frame.midY - 8, width: 16, height: 16), in: controlView)
        }
        var text = super.titleRect(forBounds: frame); text.origin.x = frame.minX + 46
        let shortcutWidth = shortcut.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 12 } ?? 8
        text.size.width = max(0, frame.maxX - text.minX - shortcutWidth)
        _ = drawTitle(attributedTitle, withFrame: text, in: controlView)
        if let shortcut {
            let value = NSAttributedString(string: shortcut, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: AgentWorkbenchTheme.secondaryText])
            let size = value.size(); value.draw(at: NSPoint(x: frame.maxX - size.width - 3, y: frame.midY - size.height / 2))
        }
    }
}

@MainActor enum AgentWorkbenchTheme {
    private static func adaptive(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
        }
    }
    static let sidebar = adaptive(0xedeff3, 0x1c1e22)
    static let surface = adaptive(0xfefefe, 0x242629)
    static let settings = adaptive(0xfcfcfc, 0x242629)
    static let card = adaptive(0xfefefe, 0x242629)
    static let line = adaptive(0xd6dbe0, 0x3a3d42)
    static let accent = NSColor(named: "AccentColor") ?? adaptive(0x057561, 0x6bd4b6)
    static let accentText = adaptive(0xffffff, 0x10352b)
    static let selection = adaptive(0xd1e4e2, 0x28453f)
    static let navigationSelection = adaptive(0x000000, 0xffffff, alpha: 0.07)
    static let hover = adaptive(0x000000, 0xffffff, alpha: 0.045)
    static let subtle = adaptive(0xf2f3f5, 0x303338)
    static let secondaryText = adaptive(0x59616b, 0xb6bbc4)
    static let primary = adaptive(0x1a1a1a, 0xe5e7eb)
    static let primaryText = adaptive(0xffffff, 0x1c1e22)
    static let added = adaptive(0xebf7ed, 0x203b2d)
    static let removed = adaptive(0xfcebea, 0x492b2d)
    static func color(_ layer: CALayer?, _ color: NSColor, animated: Bool = true) {
        guard let layer else { return }
        AgentThemeContext.remember(layer, color: color)
        let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.removeAnimation(forKey: "selection")
        let appearance = (layer.delegate as? NSView)?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance { layer.backgroundColor = AgentThemeContext.resolve(color, in: layer.delegate as? NSView).cgColor }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let previous else { return }
        let transition = CABasicAnimation(keyPath: "backgroundColor"); transition.fromValue = previous; transition.toValue = color.cgColor
        transition.duration = 0.12; transition.toValue = layer.backgroundColor; layer.add(transition, forKey: "selection")
    }
    @discardableResult static func layout(in view: NSView?, duration: TimeInterval, animated: Bool = true, _ changes: () -> Void) -> TimeInterval {
        let effective = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? duration : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = effective; context.allowsImplicitAnimation = effective > 0
            if effective == 0 { CATransaction.begin(); CATransaction.setDisableActions(true) }
            changes(); view?.layoutSubtreeIfNeeded()
            if effective == 0 { CATransaction.commit() }
        }
        return effective
    }
    static func cancelMotion(in view: NSView) {
        func clear(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] where ["selection", "position", "bounds", "frameOrigin", "frameSize"].contains(key) { layer.removeAnimation(forKey: key) }
            layer.sublayers?.forEach(clear)
        }
        if let layer = view.layer { clear(layer) } else { view.subviews.forEach { cancelMotion(in: $0) } }
    }
    static func rule() -> NSView {
        let view = AgentThemeView(fill: line)
        view.translatesAutoresizingMaskIntoConstraints = false; view.heightAnchor.constraint(equalToConstant: 1).isActive = true; return view
    }
    static func toolbar(_ button: NSButton, title: String, symbol: String) {
        button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.image?.size = NSSize(width: 16, height: 16)
        button.imagePosition = .imageOnly; button.isBordered = false; button.contentTintColor = .labelColor
        button.toolTip = title; button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true; button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    static func sidebarControl(_ button: NSButton, group: Bool = false, folder: Bool = false, shortcut: String? = nil) {
        let target = button.target, action = button.action
        let cell = AgentSidebarCell(textCell: button.title); cell.group = group; cell.folder = folder; cell.shortcut = shortcut
        button.cell = cell; button.setButtonType(.momentaryPushIn); button.target = target; button.action = action
    }
    static func shortcut(_ button: NSButton, _ value: String?) { (button.cell as? AgentSidebarCell)?.shortcut = value; button.needsDisplay = true }
}

class AgentWorkbenchButton: NSButton {
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next; wantsLayer = true; layer?.cornerRadius = 6
        if layer?.backgroundColor == nil { layer?.backgroundColor = NSColor.clear.cgColor }
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { AgentWorkbenchTheme.color(layer, AgentWorkbenchTheme.hover) } }
    override func mouseExited(with event: NSEvent) { AgentWorkbenchTheme.color(layer, state == .on ? AgentWorkbenchTheme.selection : .clear) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); AgentWorkbenchTheme.color(layer, state == .on ? AgentWorkbenchTheme.selection : .clear, animated: false) }
}

enum AgentTaskWaitingStatus: String {
    case approval, answer

    init?(task: AgentTaskRecord) {
        guard !task.archived, task.status == .waiting, let call = task.pendingCalls.first,
              task.approvals.contains(where: { $0.call.id == call.id && $0.decision == nil }) else { return nil }
        self = call.name == "ask_user" ? .answer : .approval
    }

    var title: String { self == .approval ? "待审批" : "待答复" }
    var symbol: String { self == .approval ? "exclamationmark.circle.fill" : "questionmark.circle.fill" }
}

@MainActor struct AgentTaskStatusAppearance {
    let title: String
    let symbol: String
    let color: NSColor
    private static let runningColor = NSColor(name: "AgentTaskRunning") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.52, green: 0.76, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.02, green: 0.31, blue: 0.69, alpha: 1)
    }

    init(_ task: AgentTaskRecord, waiting: AgentTaskWaitingStatus? = nil) {
        title = waiting?.title ?? task.statusTitle
        if let waiting { (symbol, color) = (waiting.symbol, AgentDialogStyle.warning); return }
        let status: AgentTaskStatus = task.statusTitle == "校验未通过" ? .failed : task.status
        switch status {
        case .ready: (symbol, color) = ("circle", AgentWorkbenchTheme.secondaryText)
        case .running: (symbol, color) = ("arrow.triangle.2.circlepath", Self.runningColor)
        case .waiting: (symbol, color) = ("exclamationmark.circle.fill", AgentDialogStyle.warning)
        case .stopped: (symbol, color) = ("stop.circle", AgentWorkbenchTheme.secondaryText)
        case .completed: (symbol, color) = ("checkmark.circle.fill", AgentWorkbenchTheme.accent)
        case .failed: (symbol, color) = ("exclamationmark.circle", .systemRed)
        }
    }

    func apply(to icon: NSImageView) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
    }
}

@MainActor final class AgentStatusBadge: NSButton {
    private let label = NSTextField(labelWithString: ""), icon = NSImageView(), arrow = NSImageView()
    private var trailingPadding: NSLayoutConstraint!
    private var statusColor: NSColor = AgentWorkbenchTheme.secondaryText
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false; wantsLayer = true; layer?.cornerRadius = 9
        title = ""; setButtonType(.momentaryPushIn); isBordered = false; isEnabled = false; focusRingType = .exterior
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        setAccessibilityRole(.staticText); setAccessibilityElement(true)
        arrow.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        arrow.isHidden = true
        for view in [icon, label, arrow] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        trailingPadding = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.widthAnchor.constraint(equalToConstant: 12), icon.heightAnchor.constraint(equalToConstant: 12), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5), trailingPadding, label.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7), arrow.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, super.hitTest(point) != nil else { return nil }
        return self
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill() }
    override func draw(_ dirtyRect: NSRect) {}
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = AgentThemeContext.resolve(statusColor, in: self).withAlphaComponent(isHighlighted ? 0.2 : 0.08).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var intrinsicContentSize: NSSize { NSSize(width: label.intrinsicContentSize.width + (isEnabled ? 46 : 33), height: 22) }
    func update(_ task: AgentTaskRecord, waiting: AgentTaskWaitingStatus?) {
        let appearance = AgentTaskStatusAppearance(task, waiting: waiting)
        appearance.apply(to: icon)
        arrow.contentTintColor = appearance.color
        label.stringValue = appearance.title; label.textColor = appearance.color; statusColor = appearance.color; needsDisplay = true
        invalidateIntrinsicContentSize()
        updateAccessibilityTitle()
    }
    func setOpenTitle(_ title: String?) {
        guard toolTip != title else { return }
        toolTip = title; isEnabled = title != nil; arrow.isHidden = title == nil
        setAccessibilityRole(title == nil ? .staticText : .button); updateAccessibilityTitle()
        trailingPadding.constant = title == nil ? -8 : -21
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
    }
    private func updateAccessibilityTitle() {
        setAccessibilityLabel(toolTip.map { label.stringValue + "，" + $0 } ?? label.stringValue)
    }
}

@MainActor final class AgentInspectorFileButton: AgentWorkbenchButton {
    let value: String, section: Int
    var onOpen: ((Int, String) -> Void)?
    var onOpenIn: ((AgentArtifactLocation) -> Void)? { didSet { menu = onOpenIn == nil ? nil : AgentArtifactLocation.menu(target: self, action: #selector(openIn(_:))) } }
    init(title: String, value: String, section: Int, symbol: String, inline: Bool = false) {
        self.value = value; self.section = section
        super.init(frame: .zero); self.title = title; target = self; action = #selector(open)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading; image?.size = NSSize(width: 15, height: 15)
        isBordered = false; alignment = .left; font = .systemFont(ofSize: 15); contentTintColor = .labelColor; cell?.lineBreakMode = .byTruncatingMiddle; toolTip = value
        if symbol == "doc" { AgentFileIcons.bind(self, filename: title) }
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: inline ? 38 : 30).isActive = true; setAccessibilityLabel(title)
        if inline {
            for top in [true, false] {
                let line = AgentWorkbenchTheme.rule(); addSubview(line)
                NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor), top ? line.topAnchor.constraint(equalTo: topAnchor) : line.bottomAnchor.constraint(equalTo: bottomAnchor)])
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func open() { onOpen?(section, value) }
    @objc private func openIn(_ sender: NSMenuItem) { if let value = sender.representedObject as? String, let location = AgentArtifactLocation(rawValue: value) { onOpenIn?(location) } }
}
