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
        text.size.width = max(0, frame.maxX - text.minX - (shortcut == nil ? 8 : 30))
        _ = drawTitle(attributedTitle, withFrame: text, in: controlView)
        if let shortcut {
            let value = NSAttributedString(string: shortcut, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            let size = value.size(); value.draw(at: NSPoint(x: frame.maxX - size.width - 3, y: frame.midY - size.height / 2))
        }
    }
}

@MainActor enum AgentWorkbenchTheme {
    static let sidebar = NSColor(srgbRed: 237 / 255, green: 239 / 255, blue: 243 / 255, alpha: 1)
    static let surface = NSColor(srgbRed: 254 / 255, green: 254 / 255, blue: 254 / 255, alpha: 1)
    static let line = NSColor(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)
    static let accent = NSColor(red: 0.02, green: 0.46, blue: 0.38, alpha: 1)
    static let selection = NSColor(red: 0.82, green: 0.895, blue: 0.885, alpha: 1)
    static func color(_ layer: CALayer?, _ color: NSColor, animated: Bool = true) {
        guard let layer else { return }
        let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.removeAnimation(forKey: "selection")
        layer.backgroundColor = color.cgColor
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let previous else { return }
        let transition = CABasicAnimation(keyPath: "backgroundColor"); transition.fromValue = previous; transition.toValue = color.cgColor
        transition.duration = 0.12; layer.add(transition, forKey: "selection")
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
        let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = line.cgColor
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
}

class AgentWorkbenchButton: NSButton {
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next; wantsLayer = true; layer?.cornerRadius = 6
        if layer?.backgroundColor == nil { layer?.backgroundColor = NSColor.clear.cgColor }
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { AgentWorkbenchTheme.color(layer, NSColor(white: 0, alpha: 0.045)) } }
    override func mouseExited(with event: NSEvent) { AgentWorkbenchTheme.color(layer, state == .on ? AgentWorkbenchTheme.selection : .clear) }
}

@MainActor final class AgentStatusBadge: NSView {
    private let label = NSTextField(labelWithString: ""), dot = NSView()
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false; wantsLayer = true; layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 12, weight: .medium); dot.wantsLayer = true; dot.layer?.cornerRadius = 3
        for view in [dot, label] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 22), dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6), dot.centerYAnchor.constraint(equalTo: centerYAnchor), label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: label.intrinsicContentSize.width + 27, height: 22) }
    func update(_ task: AgentTaskRecord) {
        let color: NSColor = task.statusTitle == "校验未通过" || task.status == .failed ? .systemRed : task.status == .completed ? AgentWorkbenchTheme.accent : task.status == .waiting ? .systemOrange : .secondaryLabelColor
        label.stringValue = task.statusTitle; label.textColor = color; dot.layer?.backgroundColor = color.cgColor; layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
        invalidateIntrinsicContentSize()
        setAccessibilityLabel(task.statusTitle)
    }
}

@MainActor final class AgentTaskInspector: NSView {
    var onOpen: ((Int, String) -> Void)?
    var onShowAll: ((Int) -> Void)?
    var onSideTask: ((String) -> Void)?
    private var sideTasks: [AgentTaskRecord] = []
    private let column = NSStackView(), scroll = NSScrollView(), empty = NSTextField(labelWithString: "暂无记录")
    private var signature = ""
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false; wantsLayer = true; layer?.backgroundColor = AgentWorkbenchTheme.surface.cgColor
        let heading = NSTextField(labelWithString: "记录"); heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let more = AgentWorkbenchButton(title: "", target: self, action: #selector(showLog)); AgentWorkbenchTheme.toolbar(more, title: "完整记录", symbol: "ellipsis")
        let header = NSStackView(views: [heading, NSView(), more]); header.spacing = 8
        let line = AgentWorkbenchTheme.rule(), document = FormDocumentView()
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 22; column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor
        for view in [header, line, scroll] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), header.topAnchor.constraint(equalTo: topAnchor, constant: 10), header.heightAnchor.constraint(equalToConstant: 28), line.leadingAnchor.constraint(equalTo: header.leadingAnchor), line.trailingAnchor.constraint(equalTo: header.trailingAnchor), line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8), scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), column.leadingAnchor.constraint(equalTo: document.leadingAnchor), column.trailingAnchor.constraint(equalTo: document.trailingAnchor), column.topAnchor.constraint(equalTo: document.topAnchor), column.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        setAccessibilityLabel("任务记录侧栏")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func showLog() { onShowAll?(4) }
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
                icon.contentTintColor = step.status == "completed" ? AgentWorkbenchTheme.accent : .secondaryLabelColor
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
