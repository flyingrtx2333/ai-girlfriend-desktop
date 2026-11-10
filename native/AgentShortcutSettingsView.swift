import AppKit

@MainActor final class AgentShortcutSettingsView: NSStackView {
    private let shortcuts: AgentShortcuts
    private var buttons: [AgentShortcutCommand: NSButton] = [:], resets: [AgentShortcutCommand: NSButton] = [:]
    private let message = NSTextField(wrappingLabelWithString: "")
    private var recorder: AgentShortcutRecorder?
    init(shortcuts: AgentShortcuts) {
        self.shortcuts = shortcuts; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        let restore = NSButton(title: "恢复全部默认", target: self, action: #selector(restoreAll)), reload = NSButton(title: "重新载入", target: self, action: #selector(reloadSettings))
        let toolbar = NSStackView(views: [restore, reload, NSView()]); toolbar.spacing = 8; addArrangedSubview(toolbar)
        for command in AgentShortcutCommand.allCases {
            let title = NSTextField(labelWithString: command.title), button = NSButton(title: "", target: self, action: #selector(record(_:))), reset = NSButton(title: "恢复默认", target: self, action: #selector(restore(_:)))
            title.font = .systemFont(ofSize: 13); title.widthAnchor.constraint(equalToConstant: 148).isActive = true
            button.tag = AgentShortcutCommand.allCases.firstIndex(of: command)!; reset.tag = button.tag
            button.bezelStyle = .rounded; button.font = .monospacedSystemFont(ofSize: 13, weight: .medium); button.widthAnchor.constraint(equalToConstant: 106).isActive = true
            button.setAccessibilityLabel(command.title + "快捷键"); reset.setAccessibilityLabel(command.title + "恢复默认"); reset.bezelStyle = .inline; reset.font = .systemFont(ofSize: 11)
            let line = NSStackView(views: [title, button, reset, NSView()]); line.spacing = 12; line.alignment = .centerY
            addArrangedSubview(line); line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            buttons[command] = button; resets[command] = reset
        }
        message.font = .systemFont(ofSize: 12); message.textColor = .systemRed; message.setAccessibilityLabel("快捷键状态"); addArrangedSubview(message); message.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refresh() {
        for command in AgentShortcutCommand.allCases { buttons[command]?.title = shortcuts.binding(command).display; resets[command]?.isEnabled = shortcuts.overrides[command.rawValue] != nil }
        show(shortcuts.error)
    }
    private func show(_ error: String?) { message.stringValue = error ?? ""; message.isHidden = error == nil }
    @objc private func reloadSettings() { shortcuts.reload(); refresh() }
    @objc private func restoreAll() { do { try shortcuts.reset(); refresh() } catch { show(error.localizedDescription) } }
    @objc private func restore(_ sender: NSButton) { do { try shortcuts.set(nil, for: AgentShortcutCommand.allCases[sender.tag]); refresh() } catch { show(error.localizedDescription) } }
    @objc private func record(_ sender: NSButton) {
        guard let window, recorder == nil else { return }
        let command = AgentShortcutCommand.allCases[sender.tag]
        recorder = AgentShortcutRecorder(command: command, shortcuts: shortcuts) { [weak self] in self?.recorder = nil; self?.refresh() }
        recorder?.begin(in: window)
    }
}

@MainActor private final class AgentShortcutRecorder: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
    private let message = NSTextField(wrappingLabelWithString: "按下新的快捷键")
    private let command: AgentShortcutCommand, shortcuts: AgentShortcuts, finish: () -> Void
    private var monitor: Any?
    init(command: AgentShortcutCommand, shortcuts: AgentShortcuts, finish: @escaping () -> Void) {
        self.command = command; self.shortcuts = shortcuts; self.finish = finish; super.init()
        panel.title = command.title; panel.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: command.title); title.font = .systemFont(ofSize: 15, weight: .semibold)
        message.font = .systemFont(ofSize: 13); message.setAccessibilityLabel("录入快捷键")
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel)), clear = NSButton(title: "清除快捷键", target: self, action: #selector(clear))
        let actions = NSStackView(views: [clear, NSView(), cancel]), column = NSStackView(views: [title, message, actions])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 20; column.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24), column.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 22), actions.widthAnchor.constraint(equalTo: column.widthAnchor), message.widthAnchor.constraint(equalTo: column.widthAnchor)])
    }
    func begin(in owner: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, NSApp.keyWindow === self.panel else { return event }
            if event.keyCode == 53 { self.cancel() }
            else { self.save(AgentShortcutBinding.recorded(event)) }
            return nil
        }
        owner.beginSheet(panel) { [self] _ in
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            panel.orderOut(nil); finish()
        }
    }
    @objc private func cancel() { panel.sheetParent?.endSheet(panel) }
    @objc private func clear() { save(.cleared) }
    private func save(_ value: AgentShortcutBinding) {
        do { try shortcuts.set(value, for: command); cancel() }
        catch { message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    }
}
