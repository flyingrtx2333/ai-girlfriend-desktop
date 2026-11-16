import AppKit

@MainActor final class AgentConfirmation: AgentDialogController {
    var messageText = "", informativeText = ""
    var primaryButtonIndex: Int?, cancellationButtonIndex: Int?, defaultButtonIndex: Int?
    private(set) var buttons: [NSButton] = []
    private var built = false, cancelIndex = 0
    private var standalone: NSPanel?
    private static let identifier = NSUserInterfaceItemIdentifier("agent-confirmation")
    init() { super.init(title: "", size: NSSize(width: 440, height: 180)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @discardableResult func addButton(withTitle title: String) -> NSButton {
        precondition(!built, "请在显示确认前配置按钮")
        let button = AgentDialogButton(title: title, target: self, action: #selector(choose(_:))); button.tag = buttons.count
        buttons.append(button); return button
    }
    private func build() {
        guard !built else { return }
        if buttons.isEmpty { addButton(withTitle: "确定") }
        let cancel = cancellationButtonIndex ?? buttons.firstIndex { ["取消", "关闭", "继续编辑", "继续等待"].contains($0.title) } ?? 0
        let primary = primaryButtonIndex ?? buttons.indices.first { $0 != cancel } ?? cancel
        let requested = defaultButtonIndex ?? buttons.firstIndex { $0.keyEquivalent == "\r" } ?? 0
        precondition([cancel, primary, requested].allSatisfy { buttons.indices.contains($0) })
        let selected = buttons[requested].hasDestructiveAction && !buttons[cancel].hasDestructiveAction ? cancel : requested
        built = true; cancelIndex = cancel; title = messageText
        view.identifier = Self.identifier; view.setAccessibilityLabel(messageText)
        let body = view
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
            if let button = button as? AgentDialogButton { AgentDialogStyle.action(button, prominent: index == primary) }
            if index == selected { button.keyEquivalent = "\r"; button.keyEquivalentModifierMask = [] }
            else if button.keyEquivalent == "\r" { button.keyEquivalent = "" }
        }
        let order = (cancel == primary ? [] : [cancel]) + buttons.indices.filter { $0 != primary && $0 != cancel } + [primary]
        let footer = NSStackView(views: [NSView()] + order.map { buttons[$0] }); footer.spacing = 8; column.addArrangedSubview(footer)
        body.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24), column.topAnchor.constraint(equalTo: body.topAnchor, constant: 18), column.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -20)])
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        preferredContentSize = NSSize(width: 440, height: max(150, column.fittingSize.height + 38))
        initialFocus = buttons[selected]; defaultButton = buttons[selected]
    }
    @discardableResult func runModal(for requestedOwner: NSWindow? = nil) -> NSApplication.ModalResponse {
        build()
        let owner: NSWindow
        if let existing = requestedOwner ?? NSApp.keyWindow ?? NSApp.mainWindow { owner = existing }
        else {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: preferredContentSize.width + 32, height: preferredContentSize.height + 32)), styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = messageText; panel.isReleasedWhenClosed = false; panel.center()
            standalone = panel; owner = panel
        }
        var modalRunning = false
        guard presentDialog(in: owner, completion: { response in if modalRunning { NSApp.stopModal(withCode: response) } }) else { standalone = nil; return .abort }
        modalRunning = true
        let response = NSApp.runModal(for: owner)
        modalRunning = false
        if isVisible { endDialog(response) }
        standalone?.orderOut(nil); standalone = nil
        return response
    }
    func beginModal(in owner: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        build()
        if !presentDialog(in: owner, completion: { response in completionHandler?(response) }) { completionHandler?(.abort) }
    }
    @objc private func choose(_ sender: NSButton) {
        let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag)
        endDialog(response)
    }
    override func cancel() { if buttons.indices.contains(cancelIndex) { choose(buttons[cancelIndex]) } }
    static func checkState() -> [String: Any] {
        guard ["--manual-ui", "--unsaved-changes-check", "--operation-confirmation-check"].contains(where: CommandLine.arguments.contains), let owner = NSApp.modalWindow ?? NSApp.keyWindow, let dialog = owner.agentDialog as? AgentConfirmation else { return ["visible": false] }
        var result = dialog.presentationState()
        result.merge(["styled": dialog.view is AgentThemeView, "sheet": false, "default": owner.defaultButtonCell?.title ?? "", "size": [dialog.cardFrame.width, dialog.cardFrame.height], "ambiguous": dialog.view.hasAmbiguousLayout]) { _, new in new }
        return result
    }
}

@MainActor enum AgentUnsavedChanges {
    static func discard(_ title: String, detail: String = "", discardTitle: String = "放弃更改", owner: NSWindow? = nil) -> Bool {
        let alert = AgentConfirmation(); alert.messageText = title; alert.informativeText = detail
        alert.primaryButtonIndex = 0; alert.cancellationButtonIndex = 0
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: discardTitle).hasDestructiveAction = true
        return alert.runModal(for: owner) == .alertSecondButtonReturn
    }
    static func saveOrDiscard(_ title: String) -> NSApplication.ModalResponse {
        let alert = AgentConfirmation(); alert.messageText = title; alert.primaryButtonIndex = 0; alert.cancellationButtonIndex = 2
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "放弃更改").hasDestructiveAction = true; alert.addButton(withTitle: "继续编辑")
        return alert.runModal()
    }
    static func checkState() -> [String: Any] { AgentConfirmation.checkState() }
}
