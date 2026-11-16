import AppKit

@MainActor final class AgentMCPUserInputPanel: NSWindowController {
    let request: AgentMCPUserInput
    private let inputs: AgentMCPUserInputs
    private let issue = NSTextField(wrappingLabelWithString: "")
    private let body = NSStackView(), scroll = NSScrollView()
    private var viewportHeight: NSLayoutConstraint?
    private var maximumHeight: CGFloat = 465, fixedHeight: CGFloat = 142
    private weak var initialControl: NSControl?
    private var getters: [String: () throws -> Any?] = [:]
    private var ended = false
    var onClose: (() -> Void)?

    init(request: AgentMCPUserInput, inputs: AgentMCPUserInputs) {
        self.request = request; self.inputs = inputs
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 465), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "连接器问询"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let name = NSTextField(labelWithString: request.serverName); name.font = .systemFont(ofSize: 15, weight: .semibold); name.lineBreakMode = .byTruncatingTail; name.toolTip = request.serverName
        let close = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(close, title: "取消连接器问询", symbol: "xmark"); close.target = self; close.action = #selector(cancelInput)
        let header = NSStackView(views: [name, NSView(), close]); header.alignment = .centerY
        let origin = NSTextField(labelWithString: request.destination); origin.font = .systemFont(ofSize: 11); origin.textColor = AgentWorkbenchTheme.secondaryText; origin.lineBreakMode = .byTruncatingMiddle; origin.toolTip = request.destination
        for label in [name, origin] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        origin.isSelectable = true; origin.setAccessibilityLabel("连接器地址")
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        let document = FormDocumentView(); scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12; body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        func add(_ view: NSView) { body.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        issue.font = .systemFont(ofSize: 12); issue.textColor = AgentDialogStyle.error; issue.isHidden = true; issue.setAccessibilityLabel("连接器问询状态"); prepareLabel(issue); add(issue)
        let message = NSTextField(wrappingLabelWithString: request.message); message.font = .systemFont(ofSize: 13); prepareLabel(message); add(message)
        if let url = request.url {
            let host = NSTextField(wrappingLabelWithString: "目标：" + (url.host ?? "")); host.font = .systemFont(ofSize: 13, weight: .semibold); prepareLabel(host); add(host)
            let address = NSTextField(wrappingLabelWithString: url.absoluteString); address.isSelectable = true; address.font = .monospacedSystemFont(ofSize: 11, weight: .regular); prepareLabel(address); add(address)
        }
        for field in request.fields { add(makeField(field)) }
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(cancelInput)); cancel.keyEquivalent = "\u{1b}"
        let decline = AgentDialogButton(title: "拒绝", target: self, action: #selector(declineInput))
        let accept = AgentDialogButton(title: request.url == nil ? "提交给连接器" : "打开网页", target: self, action: #selector(acceptInput))
        AgentDialogStyle.action(cancel); AgentDialogStyle.action(decline); AgentDialogStyle.action(accept, prominent: true)
        let actions = NSStackView(views: [NSView(), cancel, decline, accept]); actions.spacing = 8
        let layout = NSStackView(views: [header, origin, scroll, actions]); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 12
        let root = AgentThemeView(fill: AgentWorkbenchTheme.surface); panel.contentView = root; root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor), body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 8), body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])
        for view in [header, origin, scroll, actions] { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        viewportHeight = scroll.heightAnchor.constraint(equalToConstant: 320); viewportHeight?.isActive = true
        fixedHeight = 36 + 36 + 28 + 28 + ceil(origin.intrinsicContentSize.height)
        panel.initialFirstResponder = initialControl ?? cancel
        resizeToContents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func prepareLabel(_ label: NSTextField) {
        label.preferredMaxLayoutWidth = 500
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    private func resizeToContents() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let height = min(320, max(80, ceil(body.fittingSize.height) + 16), max(80, maximumHeight - fixedHeight))
        viewportHeight?.constant = height
        window?.setContentSize(NSSize(width: 560, height: fixedHeight + height))
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    private func makeField(_ field: AgentMCPUserInput.Field) -> NSView {
        let caption = NSTextField(wrappingLabelWithString: field.title + (field.required ? " *" : ""))
        caption.font = .systemFont(ofSize: 12, weight: .medium); prepareLabel(caption)
        let label = field.title + (field.required ? "（必填）" : "")
        let row = NSStackView(views: [caption]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
        if !field.detail.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: field.detail); detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText; prepareLabel(detail)
            row.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        caption.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        if field.kind == .array {
            let defaults = Set(field.initial as? [String] ?? [])
            let buttons = field.options.map { option -> NSButton in
                let button = NSButton(checkboxWithTitle: option.title, target: nil, action: nil)
                button.font = .systemFont(ofSize: 13); button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                if initialControl == nil { initialControl = button }
                button.state = defaults.contains(option.value) ? .on : .off
                button.setAccessibilityLabel(field.title + "：" + option.title); button.toolTip = option.title; row.addArrangedSubview(button)
                button.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor).isActive = true
                return button
            }
            getters[field.key] = {
                let values = zip(field.options, buttons).compactMap { $0.1.state == .on ? $0.0.value : nil }
                return values.isEmpty && !field.required && field.initial == nil ? nil : values
            }
        } else if field.kind == .boolean || !field.options.isEmpty {
            let popup = NSPopUpButton(); popup.setAccessibilityLabel(label); popup.addItem(withTitle: "未选择")
            if field.kind == .boolean {
                for (title, value) in [("是", true), ("否", false)] {
                    popup.addItem(withTitle: title); popup.lastItem?.representedObject = value
                }
                if let value = AgentMCPUserInput.Field.boolean(field.initial) { popup.selectItem(at: value ? 1 : 2) }
            } else {
                for option in field.options {
                    let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: ""); item.representedObject = option.value; popup.menu?.addItem(item)
                }
                if let value = field.initial as? String, let i = field.options.firstIndex(where: { $0.value == value }) { popup.selectItem(at: i + 1) }
            }
            let frame = AgentSettingsPopupFrame(popup); row.addArrangedSubview(frame); frame.widthAnchor.constraint(equalToConstant: 260).isActive = true
            if initialControl == nil { initialControl = popup }
            getters[field.key] = { popup.selectedItem?.representedObject }
        } else {
            let text = AgentDialogTextField(frame: .zero); text.setAccessibilityLabel(label); text.isAutomaticTextCompletionEnabled = false
            text.heightAnchor.constraint(equalToConstant: 32).isActive = true
            if initialControl == nil { initialControl = text }
            if let value = field.initial as? String { text.stringValue = value }
            else if let value = field.initial as? NSNumber { text.stringValue = value.stringValue }
            row.addArrangedSubview(text); text.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            getters[field.key] = {
                let value = text.stringValue
                if field.kind == .string { return value.isEmpty && (field.initial as? String) != "" ? nil : value }
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                return try field.number(value)
            }
        }
        return row
    }
    func present(in parent: NSWindow) {
        guard let window else { return }
        AgentThemeContext.inherit(window, from: parent)
        maximumHeight = parent.contentLayoutRect.height - 32; resizeToContents()
        parent.beginSheet(window) { [weak self] _ in
            guard let self else { return }
            if !ended { try? inputs.respond(taskID: request.taskID, id: request.id, action: .cancel); ended = true }
            onClose?()
        }
        window.makeFirstResponder(window.initialFirstResponder)
    }
    func dismiss() {
        guard !ended else { return }; ended = true
        if let window { if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil); onClose?() } }
    }
    private func submit(_ action: AgentMCPUserInput.Action) {
        do {
            var values: [String: Any] = [:]
            if action == .accept {
                for field in request.fields { if let getter = getters[field.key], let value = try getter() { values[field.key] = value } }
            }
            try inputs.respond(taskID: request.taskID, id: request.id, action: action, values: values) { NSWorkspace.shared.open($0) }
            dismiss()
        } catch { issue.stringValue = error.localizedDescription; issue.isHidden = false; resizeToContents(); issue.scrollToVisible(issue.bounds) }
    }
    @objc private func acceptInput() { submit(.accept) }
    @objc private func declineInput() { submit(.decline) }
    @objc private func cancelInput() { submit(.cancel) }
}
