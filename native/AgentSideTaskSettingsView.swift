import AppKit

@MainActor final class AgentSideTaskSettingsView: NSView {
    private let service: AgentSideTasks, enabled = NSSwitch(), state = NSTextField(wrappingLabelWithString: "")
    private var revision: String?
    init(service: AgentSideTasks) {
        self.service = service; super.init(frame: .zero)
        enabled.setAccessibilityLabel("可恢复侧任务")
        let line = NSStackView(views: [NSTextField(labelWithString: "可恢复侧任务"), NSView(), enabled]); line.spacing = 12
        let note = NSTextField(wrappingLabelWithString: "仅影响新建的侧任务；保留后可从主任务记录中重新打开。")
        note.font = .systemFont(ofSize: 12); note.textColor = AgentWorkbenchTheme.secondaryText
        let apply = NSButton(title: "应用设置", target: self, action: #selector(save)), reload = NSButton(title: "重新载入", target: self, action: #selector(load))
        let buttons = NSStackView(views: [apply, reload, NSView()]); buttons.spacing = 8
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText
        let column = NSStackView(views: [line, note, buttons, state]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 12
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }; load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func load() {
        do { try service.refreshSettings(); revision = service.revision; enabled.state = service.settings.recoverable ? .on : .off; state.stringValue = service.issue ?? "" }
        catch { state.stringValue = error.localizedDescription; state.textColor = .systemRed }
    }
    @objc private func save() {
        do { try service.saveSettings(recoverable: enabled.state == .on, expectedRevision: revision); revision = service.revision; state.textColor = AgentWorkbenchTheme.secondaryText; state.stringValue = "已保存" }
        catch { state.stringValue = error.localizedDescription; state.textColor = .systemRed }
    }
}
