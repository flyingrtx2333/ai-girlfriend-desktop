import AppKit

@MainActor final class AgentUnsavedChanges: NSObject {
    private let panel: NSPanel
    private let owner: NSWindow?, previousResponder: NSResponder?
    private static let identifier = NSUserInterfaceItemIdentifier("unsaved-changes-confirmation")

    static func discard(_ title: String, detail: String = "", discardTitle: String = "放弃更改") -> Bool {
        AgentUnsavedChanges(title: title, detail: detail, actions: ["继续编辑", discardTitle], primary: 0, cancel: 0, destructive: 1).run() == .alertSecondButtonReturn
    }
    static func saveOrDiscard(_ title: String) -> NSApplication.ModalResponse {
        AgentUnsavedChanges(title: title, detail: "", actions: ["保存", "放弃更改", "继续编辑"], primary: 0, cancel: 2, destructive: 1).run()
    }
    private init(title: String, detail: String, actions: [String], primary: Int, cancel: Int, destructive: Int) {
        let presenting = NSApp.keyWindow; owner = presenting; previousResponder = presenting?.firstResponder
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.title = title; panel.identifier = Self.identifier; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isMovable = false
        let body = AgentThemeView(fill: AgentWorkbenchTheme.surface); panel.contentView = body
        let heading = NSTextField(wrappingLabelWithString: title); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let close = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(close, title: "继续编辑", symbol: "xmark")
        close.tag = cancel; close.target = self; close.action = #selector(choose(_:)); close.keyEquivalent = "\u{1b}"
        let header = NSStackView(views: [heading, NSView(), close]); header.alignment = .top
        let column = NSStackView(views: [header]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 16
        if !detail.isEmpty {
            let text = NSTextView(); text.string = detail; text.font = .systemFont(ofSize: 13); text.textColor = AgentWorkbenchTheme.secondaryText
            text.isEditable = false; text.isRichText = false; text.drawsBackground = false; text.textContainerInset = .zero
            text.textContainer?.lineFragmentPadding = 0; text.textContainer?.widthTracksTextView = true; text.isVerticallyResizable = true; text.autoresizingMask = [.width]
            text.setAccessibilityLabel("未保存内容")
            let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
            let height = (detail as NSString).boundingRect(with: NSSize(width: 392, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)]).height
            text.frame = NSRect(x: 0, y: 0, width: 392, height: max(20, ceil(height) + 4))
            scroll.heightAnchor.constraint(equalToConstant: min(160, max(20, ceil(height) + 4))).isActive = true; column.addArrangedSubview(scroll)
        }
        let buttons = actions.enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(choose(_:))); button.tag = index; button.bezelStyle = .rounded; button.controlSize = .large
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
            if index == primary { button.bezelColor = AgentWorkbenchTheme.accent; button.keyEquivalent = "\r" }
            if index == destructive { button.contentTintColor = .systemRed }
            return button
        }
        let order = (cancel == primary ? [] : [cancel]) + actions.indices.filter { $0 != primary && $0 != cancel } + [primary]
        let footer = NSStackView(views: [NSView()] + order.map { buttons[$0] }); footer.spacing = 8; column.addArrangedSubview(footer)
        body.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24), column.topAnchor.constraint(equalTo: body.topAnchor, constant: 18), column.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -20)])
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        panel.setContentSize(NSSize(width: 440, height: max(150, column.fittingSize.height + 38)))
        panel.initialFirstResponder = buttons[primary]; panel.defaultButtonCell = buttons[primary].cell as? NSButtonCell
    }
    private func run() -> NSApplication.ModalResponse {
        if let owner {
            let area = owner.screen?.visibleFrame ?? owner.frame, size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: max(area.minX, min(owner.frame.midX - size.width / 2, area.maxX - size.width)), y: max(area.minY, min(owner.frame.midY - size.height / 2, area.maxY - size.height))))
        } else { panel.center() }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel.initialFirstResponder)
        let response = NSApp.runModal(for: panel); panel.orderOut(nil)
        if let owner, owner.isVisible {
            owner.makeKeyAndOrderFront(nil)
            if let view = previousResponder as? NSView, view.window === owner { owner.makeFirstResponder(view) }
        }
        return response
    }
    @objc private func choose(_ sender: NSButton) { NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag)) }
    static func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--unsaved-changes-check"), let window = NSApp.modalWindow, window.identifier == identifier else { return ["visible": false] }
        return ["visible": window.isVisible, "title": window.title, "styled": window.contentView is AgentThemeView, "default": window.defaultButtonCell?.title ?? "", "size": [window.frame.width, window.frame.height], "ambiguous": window.contentView?.hasAmbiguousLayout == true]
    }
}
