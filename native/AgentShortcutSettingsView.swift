import AppKit

@MainActor final class AgentShortcutSettingsView: NSStackView {
    private let shortcuts: AgentShortcuts
    private var buttons: [AgentShortcutCommand: NSButton] = [:], resets: [AgentShortcutCommand: NSButton] = [:]
    private let message = NSTextField(wrappingLabelWithString: "")
    private var recorder: AgentShortcutRecorder?
    init(shortcuts: AgentShortcuts) {
        self.shortcuts = shortcuts; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        let restore = AgentDialogButton(title: "恢复全部默认", target: self, action: #selector(restoreAll)), reload = AgentDialogButton(title: "重新载入", target: self, action: #selector(reloadSettings))
        AgentDialogStyle.action(restore); AgentDialogStyle.action(reload)
        let toolbar = NSStackView(views: [restore, reload, NSView()]); toolbar.spacing = 8; addArrangedSubview(toolbar)
        var rows: [NSView] = []
        for command in AgentShortcutCommand.allCases {
            let button = AgentWorkbenchButton(title: "", target: self, action: #selector(record(_:))), reset = NSButton(title: "恢复默认", target: self, action: #selector(restore(_:)))
            button.tag = AgentShortcutCommand.allCases.firstIndex(of: command)!; reset.tag = button.tag
            button.isBordered = false; button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            let key = AgentThemeView(fill: AgentWorkbenchTheme.subtle, stroke: AgentWorkbenchTheme.line); key.layer?.cornerRadius = 6; key.layer?.borderWidth = 1
            key.addSubview(button); button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([key.widthAnchor.constraint(equalToConstant: 106), key.heightAnchor.constraint(equalToConstant: 28), button.leadingAnchor.constraint(equalTo: key.leadingAnchor), button.trailingAnchor.constraint(equalTo: key.trailingAnchor), button.topAnchor.constraint(equalTo: key.topAnchor), button.bottomAnchor.constraint(equalTo: key.bottomAnchor)])
            button.setAccessibilityLabel(command.title + "快捷键"); reset.setAccessibilityLabel(command.title + "恢复默认"); reset.bezelStyle = .inline; reset.font = .systemFont(ofSize: 11)
            let actions = NSStackView(views: [key, reset]); actions.spacing = 10; actions.alignment = .centerY
            rows.append(AgentSettingsStyle.formRow(command.title, actions, trailing: true))
            buttons[command] = button; resets[command] = reset
        }
        let section = AgentSettingsStyle.section("应用快捷键", id: "shortcut-bindings", rows: rows)
        addArrangedSubview(section); section.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        message.font = .systemFont(ofSize: 12); message.textColor = AgentDialogStyle.error; message.setAccessibilityLabel("快捷键状态"); addArrangedSubview(message); message.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
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
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 160), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let message = NSTextField(wrappingLabelWithString: "按下新的快捷键")
    private let column = NSStackView()
    private let command: AgentShortcutCommand, shortcuts: AgentShortcuts, finish: () -> Void
    private var monitor: Any?
    init(command: AgentShortcutCommand, shortcuts: AgentShortcuts, finish: @escaping () -> Void) {
        self.command = command; self.shortcuts = shortcuts; self.finish = finish; super.init()
        panel.title = command.title; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isReleasedWhenClosed = false
        let body = AgentThemeView(fill: AgentWorkbenchTheme.surface); panel.contentView = body
        let title = NSTextField(labelWithString: command.title); title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(close, title: "取消录入快捷键", symbol: "xmark"); close.target = self; close.action = #selector(cancel)
        let header = NSStackView(views: [title, NSView(), close]); header.alignment = .centerY
        message.font = .systemFont(ofSize: 13); message.setAccessibilityLabel("录入快捷键")
        message.preferredMaxLayoutWidth = 336; message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.setContentCompressionResistancePriority(.required, for: .vertical)
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(cancel)), clear = AgentDialogButton(title: "清除快捷键", target: self, action: #selector(clear))
        AgentDialogStyle.action(cancel); AgentDialogStyle.action(clear)
        let actions = NSStackView(views: [clear, NSView(), cancel]); actions.spacing = 8
        for view in [header, message, actions] { column.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 16; column.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24), column.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24), column.topAnchor.constraint(equalTo: body.topAnchor, constant: 18), column.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -18)])
        resizeToContents()
    }
    private func resizeToContents() { panel.contentView?.layoutSubtreeIfNeeded(); panel.setContentSize(NSSize(width: 384, height: ceil(column.fittingSize.height) + 36)) }
    func begin(in owner: NSWindow) {
        AgentThemeContext.inherit(panel, from: owner)
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
        catch { message.stringValue = error.localizedDescription; message.textColor = AgentDialogStyle.error; resizeToContents() }
    }
}
