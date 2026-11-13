import AppKit

@MainActor final class AgentNameEditor: NSWindowController, NSTextFieldDelegate {
    private let input = NSTextField(), status = NSTextField(wrappingLabelWithString: "")
    private let saveName: (String) throws -> Void, onClose: () -> Void
    private weak var previousResponder: NSResponder?

    init(title: String, label: String, value: String, save: @escaping (String) throws -> Void, onClose: @escaping () -> Void) {
        saveName = save; self.onClose = onClose
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 208), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = title; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let body = AgentThemeView(fill: AgentWorkbenchTheme.surface); panel.contentView = body
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let close = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(close, title: "取消" + title, symbol: "xmark"); close.target = self; close.action = #selector(cancel)
        let header = NSStackView(views: [heading, NSView(), close]); header.alignment = .centerY
        input.stringValue = value; input.font = .systemFont(ofSize: 13); input.bezelStyle = .roundedBezel; input.delegate = self; input.setAccessibilityLabel(label)
        input.heightAnchor.constraint(equalToConstant: 32).isActive = true
        status.font = .systemFont(ofSize: 12); status.textColor = .systemRed; status.setAccessibilityLabel("名称保存状态")
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel)), save = NSButton(title: "保存", target: self, action: #selector(submit))
        for button in [cancel, save] { button.bezelStyle = .rounded; button.controlSize = .large; button.widthAnchor.constraint(equalToConstant: 84).isActive = true }
        cancel.keyEquivalent = "\u{1b}"; save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        save.bezelColor = AgentWorkbenchTheme.accent
        let actions = NSStackView(views: [NSView(), cancel, save]); actions.spacing = 8
        let column = NSStackView(views: [header, input, status, actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24), column.topAnchor.constraint(equalTo: body.topAnchor, constant: 18), column.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -20)])
        for view in [header, input, status, actions] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        panel.initialFirstResponder = input
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func begin(in owner: NSWindow) {
        guard let panel = window, owner.attachedSheet == nil else { return }
        previousResponder = owner.firstResponder
        AgentThemeContext.inherit(panel, from: owner)
        owner.beginSheet(panel) { [self, weak owner] _ in
            panel.orderOut(nil); onClose()
            if let view = previousResponder as? NSView, view.window === owner { owner?.makeFirstResponder(view) }
        }
        panel.makeFirstResponder(input); input.selectText(nil)
    }
    @objc func cancel() { if let window { window.sheetParent?.endSheet(window, returnCode: .cancel) } }
    @objc private func submit() {
        guard (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        do { try saveName(input.stringValue); if let window { window.sheetParent?.endSheet(window, returnCode: .OK) } }
        catch { status.stringValue = error.localizedDescription; window?.makeFirstResponder(input) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
    func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--name-editor-check") else { return [:] }
        return ["visible": window?.isVisible == true, "title": window?.title ?? "", "value": input.stringValue, "error": status.stringValue, "inputFocused": input.currentEditor().map { window?.firstResponder === $0 } ?? false, "ambiguousLayout": input.hasAmbiguousLayout || status.hasAmbiguousLayout, "inputWidth": input.bounds.width]
    }
}
