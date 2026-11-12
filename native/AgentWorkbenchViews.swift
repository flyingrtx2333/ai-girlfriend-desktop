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
        let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.removeAnimation(forKey: "selection")
        let appearance = (layer.delegate as? NSView)?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance { layer.backgroundColor = color.cgColor }
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

@MainActor final class AgentStatusBadge: NSView {
    private let label = NSTextField(labelWithString: ""), dot = NSView()
    private var statusColor: NSColor = AgentWorkbenchTheme.secondaryText
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false; wantsLayer = true; layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 12, weight: .medium); dot.wantsLayer = true; dot.layer?.cornerRadius = 3
        for view in [dot, label] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 22), dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6), dot.centerYAnchor.constraint(equalTo: centerYAnchor), label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { dot.layer?.backgroundColor = statusColor.cgColor; layer?.backgroundColor = statusColor.withAlphaComponent(0.08).cgColor } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var intrinsicContentSize: NSSize { NSSize(width: label.intrinsicContentSize.width + 27, height: 22) }
    func update(_ task: AgentTaskRecord) {
        let color: NSColor = task.statusTitle == "校验未通过" || task.status == .failed ? .systemRed : task.status == .completed ? AgentWorkbenchTheme.accent : task.status == .waiting ? .systemOrange : AgentWorkbenchTheme.secondaryText
        label.stringValue = task.statusTitle; label.textColor = color; statusColor = color; needsDisplay = true
        invalidateIntrinsicContentSize()
        setAccessibilityLabel(task.statusTitle)
    }
}

@MainActor final class AgentTaskInspector: AgentThemeView {
    var onOpen: ((Int, String) -> Void)?
    var onShowAll: ((Int) -> Void)?
    var onSideTask: ((String) -> Void)?
    var onOpenTerminal: (() -> Void)?
    var canOpenTerminal = true { didSet { addTab.isHidden = !canOpenTerminal } }
    private let addTab = AgentWorkbenchButton()
    private var sideTasks: [AgentTaskRecord] = []
    private let column = NSStackView(), scroll = NSScrollView(), empty = NSTextField(labelWithString: "暂无记录")
    private var signature = ""
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false; fill = AgentWorkbenchTheme.surface
        layer?.masksToBounds = true
        let heading = NSTextField(labelWithString: "记录"); heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let more = AgentWorkbenchButton(title: "", target: self, action: #selector(showLog)); AgentWorkbenchTheme.toolbar(more, title: "完整记录", symbol: "ellipsis")
        AgentWorkbenchTheme.toolbar(addTab, title: "添加标签页", symbol: "plus")
        addTab.target = self; addTab.action = #selector(showTabMenu(_:))
        let header = NSStackView(views: [heading, NSView(), addTab, more]); header.spacing = 6
        let line = AgentWorkbenchTheme.rule(), document = FormDocumentView()
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 22; column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor
        for view in [header, line, scroll] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        let trailing = header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        // The pane folds during live resize; its controls must not clamp the window first.
        trailing.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), trailing, header.topAnchor.constraint(equalTo: topAnchor, constant: 10), header.heightAnchor.constraint(equalToConstant: 28), line.leadingAnchor.constraint(equalTo: header.leadingAnchor), line.trailingAnchor.constraint(equalTo: header.trailingAnchor), line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8), scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), column.leadingAnchor.constraint(equalTo: document.leadingAnchor), column.trailingAnchor.constraint(equalTo: document.trailingAnchor), column.topAnchor.constraint(equalTo: document.topAnchor), column.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        setAccessibilityLabel("任务记录侧栏")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func showLog() { onShowAll?(4) }
    @objc private func showTabMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开终端", action: #selector(openTerminal), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func openTerminal() { onOpenTerminal?() }
    private func section(_ title: String, views: [NSView]) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 14, weight: .semibold)
        let group = NSStackView(views: [label] + views); group.orientation = .vertical; group.alignment = .leading; group.spacing = 10
        column.addArrangedSubview(group); group.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        for view in views { view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
    }
    private func file(_ title: String, value: String, section: Int, symbol: String = "doc") -> NSView {
        let button = AgentInspectorFileButton(title: title, value: value, section: section, symbol: symbol)
        button.onOpen = { [weak self] section, value in self?.onOpen?(section, value) }
        return button
    }
    private func sideTitle(_ task: AgentTaskRecord) -> String {
        let state = task.sideTask?.needsReview == true ? "需核对文件" : task.pendingFileRollback != nil ? "需恢复文件" : task.sideTask?.sessionID != AgentSideTasks.sessionID ? (task.sideTask?.retained == true ? "已保留" : "其他会话") : task.status.title
        return (task.title == "新的任务" ? "新的侧任务" : task.title) + " · " + state + (task.sideTask?.retained == false ? " · 临时" : "")
    }
    @objc private func moreSideTasks(_ sender: NSButton) {
        let menu = NSMenu()
        for task in sideTasks { let item = NSMenuItem(title: sideTitle(task), action: #selector(openSideTask(_:)), keyEquivalent: ""); item.target = self; item.representedObject = task.id; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func openSideTask(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onSideTask?(id) } }
    func update(_ task: AgentTaskRecord, sideTasks: [AgentTaskRecord] = []) {
        self.sideTasks = sideTasks
        let hooks = Array(task.events.filter { $0.kind == "hook" }.suffix(8))
        let hookSignature = hooks.map { "\($0.id)|\($0.status)|\($0.duration ?? -1)|\($0.hook?.delivery ?? "")" }.joined()
        let next = task.id + task.plan.map { $0.id + $0.status }.joined() + task.artifacts.joined() + (task.canvases ?? []).map { $0.id + $0.hash }.joined() + task.sources.joined() + task.changes.map { $0.id + ($0.restoredAt?.description ?? "") }.joined() + "|\(task.events.count)|\(task.inputTokens)|\(task.outputTokens)|" + hookSignature + sideTasks.map { $0.id + sideTitle($0) }.joined()
        guard signature != next else { return }; signature = next
        column.arrangedSubviews.forEach { column.removeArrangedSubview($0); $0.removeFromSuperview() }
        if !sideTasks.isEmpty {
            var rows: [NSView] = sideTasks.prefix(8).map { task in
                let button = AgentInspectorFileButton(title: sideTitle(task), value: task.id, section: 5, symbol: "bubble.left.and.bubble.right")
                button.font = .systemFont(ofSize: 12); button.onOpen = { [weak self] _, id in self?.onSideTask?(id) }; return button
            }
            if sideTasks.count > 8 { rows.append(NSButton(title: "全部侧任务（\(sideTasks.count)）", target: self, action: #selector(moreSideTasks(_:)))) }
            section("侧任务", views: rows)
        }
        if !task.plan.isEmpty {
            let rows: [NSView] = task.plan.prefix(8).map { step in
                let text = NSTextField(wrappingLabelWithString: step.title); text.font = .systemFont(ofSize: 12); text.maximumNumberOfLines = 3
                let icon = NSImageView(image: NSImage(systemSymbolName: step.status == "completed" ? "checkmark.circle.fill" : step.status == "in_progress" ? "circle.dotted" : "circle", accessibilityDescription: step.status)!)
                icon.contentTintColor = step.status == "completed" ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.secondaryText
                icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
                let row = NSStackView(views: [icon, text]); row.alignment = .top; row.spacing = 8; return row
            }; section("计划", views: rows)
        }
        if !task.artifacts.isEmpty { section("产物", views: task.artifacts.prefix(8).map { file(URL(fileURLWithPath: $0).lastPathComponent, value: $0, section: 1) }) }
        if let canvases = task.canvases, !canvases.isEmpty { section("画布", views: canvases.prefix(8).map { file($0.title, value: $0.reference, section: 1, symbol: "rectangle.3.group") }) }
        var seen = Set<String>(), sources: [NSView] = []
        for value in task.sources {
            let url = URL(string: value), key = url?.isFileURL == true ? url!.path : value
            guard seen.insert(key).inserted else { continue }
            var title = url?.isFileURL == true ? url!.lastPathComponent : url?.host ?? value
            if url?.scheme == "attachment", let host = url?.host, let attachment = task.attachments?.first(where: { $0.id.caseInsensitiveCompare(host) == .orderedSame }) { title = attachment.name }
            sources.append(file(title, value: value, section: 2, symbol: url?.scheme == "http" || url?.scheme == "https" ? "globe" : "doc"))
            if sources.count == 10 { break }
        }
        if !sources.isEmpty { section("来源", views: sources) }
        if !task.changes.isEmpty { section("变更", views: task.changes.prefix(6).map { file(URL(fileURLWithPath: $0.path).lastPathComponent, value: $0.id, section: 3, symbol: $0.restoredAt == nil ? "square.and.pencil" : "arrow.uturn.backward") }) }
        if !hooks.isEmpty {
            section("Hooks", views: hooks.reversed().map { event in
                let title = event.statusTitle + " · " + event.title + (event.duration.map { " · " + String(format: "%.1fs", $0) } ?? "")
                let button = file(title, value: event.id, section: 4, symbol: event.status == "running" ? "clock" : event.status == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                (button as? NSButton)?.font = .systemFont(ofSize: 12); button.toolTip = event.detail; return button
            })
        }
        if column.arrangedSubviews.isEmpty { column.addArrangedSubview(empty) }
    }
}

@MainActor final class AgentInspectorFileButton: AgentWorkbenchButton {
    let value: String, section: Int
    var onOpen: ((Int, String) -> Void)?
    init(title: String, value: String, section: Int, symbol: String, inline: Bool = false) {
        self.value = value; self.section = section
        super.init(frame: .zero); self.title = title; target = self; action = #selector(open)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading; image?.size = NSSize(width: 15, height: 15)
        isBordered = false; alignment = .left; font = .systemFont(ofSize: 15); contentTintColor = .labelColor; cell?.lineBreakMode = .byTruncatingMiddle; toolTip = value
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
}
