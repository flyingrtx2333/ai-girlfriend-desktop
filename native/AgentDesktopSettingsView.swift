import AppKit
import ApplicationServices

@MainActor final class AgentDesktopSettingsView: NSStackView {
    private let desktop: AgentDesktop
    private let enabled = NSSwitch(), accessibility = NSTextField(labelWithString: ""), recording = NSTextField(labelWithString: ""), connections = NSTextField(labelWithString: ""), status = NSTextField(wrappingLabelWithString: "")
    private var configurationHash: String?, observer: NSObjectProtocol?
    init(desktop: AgentDesktop) {
        self.desktop = desktop
        super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 14
        enabled.target = self; enabled.action = #selector(toggle); enabled.setAccessibilityLabel("启用电脑操作")
        func row(_ title: String, _ items: [NSView]) {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 104).isActive = true
            let line = NSStackView(views: [label] + items); line.spacing = 10; line.alignment = .centerY; addArrangedSubview(line); line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        let ax = NSButton(title: "打开系统设置", target: self, action: #selector(requestAccessibility)), screen = NSButton(title: "打开系统设置", target: self, action: #selector(requestRecording))
        ax.setAccessibilityLabel("授权辅助功能"); screen.setAccessibilityLabel("授权屏幕录制")
        let refresh = NSButton(title: "刷新权限", target: self, action: #selector(refreshState)), disconnect = NSButton(title: "断开全部窗口", target: self, action: #selector(disconnectAll))
        row("启用电脑操作", [NSView(), enabled]); row("辅助功能", [accessibility, NSView(), ax]); row("屏幕录制", [recording, NSView(), screen]); row("窗口连接", [connections, NSView(), disconnect])
        addArrangedSubview(refresh); status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText; addArrangedSubview(status); status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshState() } }
        refreshState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    @objc func refreshState() {
        do { let config = try desktop.configuration(); configurationHash = config.hash; enabled.state = config.enabled ? .on : .off; status.stringValue = "" }
        catch { enabled.state = .off; status.stringValue = error.localizedDescription }
        let values = desktop.status; accessibility.stringValue = values["accessibility"] as? Bool == true ? "已授权" : "未授权"; recording.stringValue = values["screen_recording"] as? Bool == true ? "已授权" : "未授权"; connections.stringValue = "\(values["connected_tasks"] as? Int ?? 0) 个任务"
    }
    @objc private func toggle() {
        let next = enabled.state == .on
        if next {
            let alert = NSAlert(); alert.messageText = "启用电脑操作？"; alert.informativeText = "连接窗口时仍需确认。批准后，指定窗口的截图和文字会进入当前模型上下文，点击与输入会直接影响该应用。"; alert.addButton(withTitle: "启用"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { enabled.state = .off; return }
        }
        do { try desktop.configure(enabled: next, expectedHash: configurationHash); refreshState() } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        open("Privacy_Accessibility")
    }
    @objc private func requestRecording() { _ = CGRequestScreenCaptureAccess(); open("Privacy_ScreenCapture") }
    private func open(_ pane: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) } }
    @objc private func disconnectAll() { desktop.disconnectAll(); refreshState() }
}
