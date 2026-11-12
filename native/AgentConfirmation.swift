import AppKit

@MainActor final class AgentConfirmation: NSObject {
    var messageText = "", informativeText = ""
    var primaryButtonIndex: Int?, cancellationButtonIndex: Int?, defaultButtonIndex: Int?
    private(set) var buttons: [NSButton] = []
    private var panel: NSPanel?
    private weak var owner: NSWindow?, previousResponder: NSResponder?
    private static let identifier = NSUserInterfaceItemIdentifier("agent-confirmation")

    @discardableResult func addButton(withTitle title: String) -> NSButton {
        precondition(panel == nil, "请在显示确认前配置按钮")
        let button = NSButton(title: title, target: self, action: #selector(choose(_:))); button.tag = buttons.count
        button.bezelStyle = .rounded; button.controlSize = .large; button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        buttons.append(button); return button
    }
    var window: NSWindow { build() }
    private func build() -> NSPanel {
        if let panel { return panel }
        if buttons.isEmpty { addButton(withTitle: "确定") }
        let cancel = cancellationButtonIndex ?? buttons.firstIndex { ["取消", "关闭", "继续编辑", "继续等待"].contains($0.title) } ?? 0
        let primary = primaryButtonIndex ?? buttons.indices.first { $0 != cancel } ?? cancel
        let selected = defaultButtonIndex ?? buttons.firstIndex { $0.keyEquivalent == "\r" } ?? 0
        precondition([cancel, primary, selected].allSatisfy { buttons.indices.contains($0) })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        self.panel = panel; panel.title = messageText; panel.identifier = Self.identifier; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isMovable = false
        let body = AgentThemeView(fill: AgentWorkbenchTheme.surface); panel.contentView = body
        let headingHeight = (messageText as NSString).boundingRect(with: NSSize(width: 350, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).height
        let longHeading = headingHeight > 60, detail = longHeading ? [messageText, informativeText].filter { !$0.isEmpty }.joined(separator: "\n\n") : informativeText
        let heading = NSTextField(wrappingLabelWithString: longHeading ? "确认操作" : messageText); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let close = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(close, title: "关闭确认", symbol: "xmark")
        close.tag = cancel; close.target = self; close.action = #selector(choose(_:)); close.keyEquivalent = "\u{1b}"; close.keyEquivalentModifierMask = []
        let header = NSStackView(views: [heading, NSView(), close]); header.alignment = .top
        let column = NSStackView(views: [header]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 16
        if !detail.isEmpty {
            let text = NSTextView(); text.string = detail; text.font = .systemFont(ofSize: 13); text.textColor = AgentWorkbenchTheme.secondaryText
            text.isEditable = false; text.isRichText = false; text.drawsBackground = false; text.textContainerInset = .zero
            text.textContainer?.lineFragmentPadding = 0; text.textContainer?.widthTracksTextView = true; text.isVerticallyResizable = true; text.autoresizingMask = [.width]
            text.setAccessibilityLabel("操作详情")
            let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
            let height = (detail as NSString).boundingRect(with: NSSize(width: 392, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)]).height
            text.frame = NSRect(x: 0, y: 0, width: 392, height: max(20, ceil(height) + 4))
            scroll.heightAnchor.constraint(equalToConstant: min(160, max(20, ceil(height) + 4))).isActive = true; column.addArrangedSubview(scroll)
        }
        for (index, button) in buttons.enumerated() {
            if index == primary { button.bezelColor = button.hasDestructiveAction ? .systemRed : AgentWorkbenchTheme.accent }
            else if button.hasDestructiveAction { button.contentTintColor = .systemRed }
            if index == selected { button.keyEquivalent = "\r"; button.keyEquivalentModifierMask = [] }
        }
        let order = (cancel == primary ? [] : [cancel]) + buttons.indices.filter { $0 != primary && $0 != cancel } + [primary]
        let footer = NSStackView(views: [NSView()] + order.map { buttons[$0] }); footer.spacing = 8; column.addArrangedSubview(footer)
        body.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24), column.topAnchor.constraint(equalTo: body.topAnchor, constant: 18), column.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -20)])
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        panel.setContentSize(NSSize(width: 440, height: max(150, column.fittingSize.height + 38)))
        panel.initialFirstResponder = buttons[selected]; panel.defaultButtonCell = buttons[selected].cell as? NSButtonCell
        return panel
    }
    private func prepare(in window: NSWindow?) { owner = window; previousResponder = window?.firstResponder }
    private func restoreFocus() {
        if let owner, owner.isVisible {
            owner.makeKeyAndOrderFront(nil)
            if let view = previousResponder as? NSView, view.window === owner { owner.makeFirstResponder(view) }
        }
    }
    @discardableResult func runModal() -> NSApplication.ModalResponse {
        prepare(in: NSApp.keyWindow); let panel = build()
        if let owner {
            let area = owner.screen?.visibleFrame ?? owner.frame, size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: max(area.minX, min(owner.frame.midX - size.width / 2, area.maxX - size.width)), y: max(area.minY, min(owner.frame.midY - size.height / 2, area.maxY - size.height))))
        } else { panel.center() }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel.initialFirstResponder)
        let response = NSApp.runModal(for: panel); panel.orderOut(nil); restoreFocus(); return response
    }
    func beginSheetModal(for owner: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        prepare(in: owner); let panel = build()
        owner.beginSheet(panel) { [self] response in panel.orderOut(nil); restoreFocus(); completionHandler?(response) }
        panel.makeFirstResponder(panel.initialFirstResponder)
    }
    @objc private func choose(_ sender: NSButton) {
        let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag)
        if let panel, let parent = panel.sheetParent { parent.endSheet(panel, returnCode: response) } else { NSApp.stopModal(withCode: response) }
    }
    static func checkState() -> [String: Any] {
        guard ["--manual-ui", "--unsaved-changes-check", "--operation-confirmation-check"].contains(where: CommandLine.arguments.contains), let window = NSApp.modalWindow ?? NSApp.keyWindow, window.identifier == identifier else { return ["visible": false] }
        return ["visible": window.isVisible, "title": window.title, "styled": window.contentView is AgentThemeView, "sheet": window.sheetParent != nil, "default": window.defaultButtonCell?.title ?? "", "size": [window.frame.width, window.frame.height], "ambiguous": window.contentView?.hasAmbiguousLayout == true]
    }
}

@MainActor enum AgentUnsavedChanges {
    static func discard(_ title: String, detail: String = "", discardTitle: String = "放弃更改") -> Bool {
        let alert = AgentConfirmation(); alert.messageText = title; alert.informativeText = detail
        alert.primaryButtonIndex = 0; alert.cancellationButtonIndex = 0
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: discardTitle).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
    static func saveOrDiscard(_ title: String) -> NSApplication.ModalResponse {
        let alert = AgentConfirmation(); alert.messageText = title; alert.primaryButtonIndex = 0; alert.cancellationButtonIndex = 2
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "放弃更改").hasDestructiveAction = true; alert.addButton(withTitle: "继续编辑")
        return alert.runModal()
    }
    static func checkState() -> [String: Any] { AgentConfirmation.checkState() }
}
