import AppKit

@MainActor final class AgentAppShotSettingsView: NSStackView {
    private let service: AgentAppShot
    private let shortcut = NSPopUpButton(), capture = NSButton(title: "截取当前窗口", target: nil, action: nil), state = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    init(service: AgentAppShot) {
        self.service = service; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        shortcut.addItems(withTitles: AgentAppShot.Shortcut.allCases.map(\.title)); shortcut.target = self; shortcut.action = #selector(changeShortcut); shortcut.setAccessibilityLabel("AppShot 全局快捷键")
        capture.target = self; capture.action = #selector(captureWindow)
        let reload = NSButton(title: "重新载入", target: self, action: #selector(reloadSettings)), label = NSTextField(labelWithString: "全局快捷键")
        let line = NSStackView(views: [label, shortcut, NSView(), capture, reload]); line.spacing = 10; line.alignment = .centerY
        addArrangedSubview(line); line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        state.font = .systemFont(ofSize: 12); state.textColor = .secondaryLabelColor; state.setAccessibilityLabel("AppShot 状态"); addArrangedSubview(state); state.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        observer = NotificationCenter.default.addObserver(forName: AgentAppShot.changed, object: service, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak service] _ in Task { @MainActor in service?.refreshPermissions() } }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }
    private func refresh() { shortcut.selectItem(at: AgentAppShot.Shortcut.allCases.firstIndex(of: service.shortcut) ?? 0); capture.isEnabled = !service.isBusy; state.stringValue = service.status; state.isHidden = service.status.isEmpty }
    @objc private func changeShortcut() { do { try service.setShortcut(AgentAppShot.Shortcut.allCases[shortcut.indexOfSelectedItem]); refresh() } catch { state.stringValue = error.localizedDescription; state.isHidden = false } }
    @objc private func captureWindow() { service.capture() }
    @objc private func reloadSettings() { service.reload(); refresh() }
}
