import AppKit

@MainActor final class AgentGitRestoreReview: AgentSettingsPageController, NSWindowDelegate {
    private let diff = AgentGitDiffView()
    private let mode = NSSegmentedControl(labels: ["统一", "并排"], trackingMode: .selectOne, target: nil, action: nil)
    private let wrap = NSButton(checkboxWithTitle: "换行", target: nil, action: nil)
    private let cancelButton = AgentDialogButton(title: "取消", target: nil, action: nil)
    private let applyButton = AgentDialogButton(title: "", target: nil, action: nil)
    private let status = AgentSettingsStatusField("恢复操作状态")
    private var working = false
    var onApply: (() async throws -> Void)?
    var onApplied: (() -> Void)?

    init(path: String, patch: String, untracked: Bool, split: Bool, wraps: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = untracked ? "确认移入废纸篓" : "确认恢复未暂存内容"
        window.minSize = NSSize(width: 420, height: 330); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        window.delegate = self
        let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
        window.contentView = content

        let filename = NSTextField(wrappingLabelWithString: path.replacingOccurrences(of: "\n", with: "↵"))
        filename.font = .systemFont(ofSize: 15, weight: .semibold)
        filename.maximumNumberOfLines = 2; filename.lineBreakMode = .byCharWrapping
        filename.isSelectable = true; filename.toolTip = path
        let impact = AgentSettingsStatusField("恢复操作影响")
        impact.font = .systemFont(ofSize: 12)
        impact.stringValue = untracked ? "未跟踪文件可从访达的废纸篓放回。" : "恢复为暂存区版本。可用「撤销恢复」取回当前内容。"

        let comparison = NSTextField(labelWithString: untracked ? "未跟踪文件" : "暂存区 → 工作区")
        comparison.font = .systemFont(ofSize: 12, weight: .medium)
        comparison.textColor = AgentWorkbenchTheme.secondaryText
        mode.selectedSegment = split ? 1 : 0; mode.segmentStyle = .roundRect; mode.font = .systemFont(ofSize: 13)
        mode.setAccessibilityLabel("恢复差异视图")
        wrap.state = wraps ? .on : .off; wrap.font = .systemFont(ofSize: 13)
        for control in [mode, wrap] as [NSControl] { control.target = self; control.action = #selector(changeDisplay) }
        let options = NSStackView(views: [comparison, NSView(), mode, wrap]); options.alignment = .centerY; options.spacing = 8
        diff.show(patch, oldTitle: untracked ? "无文件" : "暂存区", newTitle: "工作区", accessibilityContext: "恢复")
        changeDisplay()

        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        applyButton.title = untracked ? "移入废纸篓" : "确认恢复"
        applyButton.target = self; applyButton.action = #selector(apply); applyButton.hasDestructiveAction = true
        AgentDialogStyle.action(cancelButton)
        AgentDialogStyle.action(applyButton, prominent: true)
        content.onReturn = { [weak self] in self?.cancel() }
        status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 3
        let actions = NSStackView(views: [NSView(), cancelButton, applyButton]); actions.spacing = 8
        let layout = NSStackView(views: [filename, impact, options, diff, status, actions])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 10
        content.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        for view in layout.arrangedSubviews { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            options.heightAnchor.constraint(equalToConstant: 28),
            diff.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowDidBecomeKey(_ notification: Notification) {
        if isPageVisible, !working { presentingWindow?.makeFirstResponder(cancelButton) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !working }
    @objc private func changeDisplay() { diff.splitMode = mode.selectedSegment == 1; diff.wraps = wrap.state == .on }
    @objc private func cancel() { if !working { close() } }
    @objc private func apply() {
        guard !working, applyButton.isEnabled, let onApply else { return }
        working = true; applyButton.isEnabled = false; cancelButton.isEnabled = false
        status.stringValue = "处理中…"
        Task { [self] in
            do {
                try await onApply()
                working = false; close(); onApplied?()
            } catch {
                working = false; cancelButton.isEnabled = true
                status.showSaveFailure(error)
                presentingWindow?.makeFirstResponder(cancelButton)
            }
        }
    }
}
