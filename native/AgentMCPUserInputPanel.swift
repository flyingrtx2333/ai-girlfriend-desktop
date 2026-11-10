import AppKit

@MainActor final class AgentMCPUserInputPanel: NSWindowController {
    let request: AgentMCPUserInput
    private let inputs: AgentMCPUserInputs
    private let issue = NSTextField(wrappingLabelWithString: "")
    private var getters: [String: () throws -> Any?] = [:]
    private var ended = false
    var onClose: (() -> Void)?

    init(request: AgentMCPUserInput, inputs: AgentMCPUserInputs) {
        self.request = request; self.inputs = inputs
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: 465), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "连接器问询"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let name = NSTextField(labelWithString: request.serverName); name.font = .systemFont(ofSize: 16, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        let origin = NSTextField(labelWithString: request.destination); origin.font = .systemFont(ofSize: 11); origin.textColor = .secondaryLabelColor; origin.lineBreakMode = .byTruncatingMiddle; origin.toolTip = request.destination
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FormDocumentView(); scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 12; body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        func add(_ view: NSView) { body.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        let message = NSTextField(wrappingLabelWithString: request.message); message.font = .systemFont(ofSize: 13); add(message)
        if let url = request.url {
            let host = NSTextField(wrappingLabelWithString: "目标：" + (url.host ?? "")); host.font = .systemFont(ofSize: 13, weight: .semibold); add(host)
            let address = NSTextField(wrappingLabelWithString: url.absoluteString); address.isSelectable = true; address.font = .monospacedSystemFont(ofSize: 11, weight: .regular); add(address)
        }
        for field in request.fields { add(makeField(field)) }
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelInput)); cancel.keyEquivalent = "\u{1b}"
        let decline = NSButton(title: "拒绝", target: self, action: #selector(declineInput))
        let accept = NSButton(title: request.url == nil ? "提交给连接器" : "打开网页", target: self, action: #selector(acceptInput))
        let actions = NSStackView(views: [NSView(), cancel, decline, accept]); actions.spacing = 8
        issue.font = .systemFont(ofSize: 12); issue.textColor = .systemRed; issue.isHidden = true
        let layout = NSStackView(views: [name, origin, scroll, issue, actions]); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 9
        let root = NSView(); panel.contentView = root; root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor), body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 8), body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])
        for view in [name, origin, scroll, issue, actions] { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func makeField(_ field: AgentMCPUserInput.Field) -> NSView {
        let caption = NSTextField(wrappingLabelWithString: field.title + (field.required ? " *" : ""))
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        let label = field.title + (field.required ? "（必填）" : "")
        let row = NSStackView(views: [caption]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
        if !field.detail.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: field.detail); detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
            row.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        caption.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        if field.kind == .array {
            let defaults = Set(field.initial as? [String] ?? [])
            let buttons = field.options.map { option -> NSButton in
                let button = NSButton(checkboxWithTitle: option.title, target: nil, action: nil)
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
            row.addArrangedSubview(popup); popup.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            getters[field.key] = { popup.selectedItem?.representedObject }
        } else {
            let text = NSTextField(); text.setAccessibilityLabel(label); text.isAutomaticTextCompletionEnabled = false
            if let value = field.initial as? String { text.stringValue = value }
            else if let value = field.initial as? NSNumber { text.stringValue = value.stringValue }
            row.addArrangedSubview(text); text.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            getters[field.key] = {
                let value = text.stringValue
                if field.kind == .string { return value.isEmpty && !field.required ? nil : value }
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                return try field.number(value)
            }
        }
        return row
    }
    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in
            guard let self else { return }
            if !ended { try? inputs.respond(taskID: request.taskID, id: request.id, action: .cancel); ended = true }
            onClose?()
        }
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
        } catch { issue.stringValue = error.localizedDescription; issue.isHidden = false; window?.contentView?.layoutSubtreeIfNeeded() }
    }
    @objc private func acceptInput() { submit(.accept) }
    @objc private func declineInput() { submit(.decline) }
    @objc private func cancelInput() { submit(.cancel) }
}
