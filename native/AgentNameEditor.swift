import AppKit

@MainActor final class AgentNameEditor: AgentDialogController, NSTextFieldDelegate {
    private let input = AgentDialogTextField(frame: .zero), status = NSTextField(wrappingLabelWithString: ""), column = NSStackView()
    private let saveName: (String) throws -> Void, onClose: () -> Void

    init(title: String, label: String, value: String, actionTitle: String = "保存", note: String? = nil, statusLabel: String = "名称保存状态", save: @escaping (String) throws -> Void, onClose: @escaping () -> Void) {
        saveName = save; self.onClose = onClose
        super.init(title: title, size: NSSize(width: 384, height: 160))
        let body = view
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let close = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(close, title: "取消" + title, symbol: "xmark"); close.target = self; close.action = #selector(cancel)
        let header = NSStackView(views: [heading, NSView(), close]); header.alignment = .centerY
        input.stringValue = value; input.font = .systemFont(ofSize: 13); input.bezelStyle = .roundedBezel; input.delegate = self; input.setAccessibilityLabel(label)
        input.heightAnchor.constraint(equalToConstant: 32).isActive = true
        status.font = .systemFont(ofSize: 12); status.textColor = AgentDialogStyle.error; status.setAccessibilityLabel(statusLabel); status.isHidden = true; status.preferredMaxLayoutWidth = 336
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(cancel)), save = AgentDialogButton(title: actionTitle, target: self, action: #selector(submit))
        AgentDialogStyle.action(cancel); AgentDialogStyle.action(save, prominent: true)
        cancel.keyEquivalent = "\u{1b}"; save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let actions = NSStackView(views: [NSView(), cancel, save]); actions.spacing = 8
        var fields: [NSView] = [header]
        if let note { let hint = NSTextField(wrappingLabelWithString: note); hint.font = .systemFont(ofSize: 12); hint.textColor = AgentWorkbenchTheme.secondaryText; hint.preferredMaxLayoutWidth = 336; fields.append(hint) }
        fields += [input, status, actions]
        for view in fields { column.addArrangedSubview(view) }; column.orientation = .vertical; column.alignment = .leading; column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24), column.topAnchor.constraint(equalTo: body.topAnchor, constant: 18), column.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -20)])
        for view in fields { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        initialFocus = input; defaultButton = save; selectInitialText = true; resizeToContents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func resizeToContents() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 384, height: ceil(column.fittingSize.height) + 38)
    }
    func begin(in owner: NSWindow) {
        presentDialog(in: owner) { [self] _ in onClose() }
    }
    @objc private func submit() {
        guard (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        do { try saveName(input.stringValue); endDialog(.OK) }
        catch { status.stringValue = error.localizedDescription; status.isHidden = false; resizeToContents(); presentingWindow?.makeFirstResponder(input) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
    func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--name-editor-check") else { return [:] }
        var result = presentationState()
        result.merge(["value": input.stringValue, "error": status.stringValue, "inputFocused": input.currentEditor().map { presentingWindow?.firstResponder === $0 } ?? false, "ambiguousLayout": input.hasAmbiguousLayout || status.hasAmbiguousLayout, "inputWidth": input.bounds.width]) { _, new in new }
        return result
    }
}
