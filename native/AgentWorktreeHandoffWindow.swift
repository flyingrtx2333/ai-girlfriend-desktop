import AppKit

@MainActor final class AgentWorktreeHandoffWindow: AgentSettingsPageController, NSWindowDelegate {
    private let handoff: AgentWorktreeHandoff
    private let onCompleted: (String) -> Void
    private let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
    private let sources = NSPopUpButton()
    private lazy var sourceFrame = AgentSettingsPopupFrame(sources, outlined: true, maximumWidth: nil)
    private let origin = NSTextField(labelWithString: ""), destination = NSTextField(labelWithString: "")
    private let changes = NSSegmentedControl(labels: AgentWorktreeHandoffReview.Change.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let diff = AgentGitDiffView(), status = AgentSettingsStatusField("工作树移交状态")
    private let cancel = AgentDialogButton(title: "取消", target: nil, action: nil)
    private let refresh = AgentDialogButton(title: "重新审阅", target: nil, action: nil)
    private let confirm = AgentDialogButton(title: "确认移交", target: nil, action: nil)
    private var job: Task<Void, Never>?
    private var review: AgentWorktreeHandoffReview?
    private var busy = false

    init(store: AgentStore, taskID: String, onCompleted: @escaping (String) -> Void) {
        handoff = AgentWorktreeHandoff(store: store, taskID: taskID)
        self.onCompleted = onCompleted
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "移交到本地"
        window.minSize = NSSize(width: 570, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = content
        sources.setAccessibilityLabel("移交项目")
        sources.target = self; sources.action = #selector(showSource)
        for field in [origin, destination] {
            field.font = .systemFont(ofSize: 12, weight: .medium)
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        changes.selectedSegment = 0; changes.target = self; changes.action = #selector(showChanges)
        changes.setAccessibilityLabel("移交改动类型")
        changes.heightAnchor.constraint(equalToConstant: 28).isActive = true
        diff.text.setAccessibilityLabel("移交差异")
        status.font = .systemFont(ofSize: 12)
        for button in [cancel, refresh, confirm] {
            button.target = self
            AgentDialogStyle.action(button, prominent: button === confirm)
        }
        cancel.action = #selector(closeReview); refresh.action = #selector(load); confirm.action = #selector(apply)
        let top = NSStackView(views: [sourceFrame, origin, destination, changes])
        top.orientation = .vertical; top.alignment = .leading; top.spacing = 8
        for row in [sourceFrame, origin, destination] { row.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true }
        let buttons = NSStackView(views: [NSView(), cancel, refresh, confirm])
        buttons.spacing = 8
        let footer = NSStackView(views: [status, buttons])
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 8
        for row in [status, buttons] { row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }
        for view in [top, diff, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            diff.leadingAnchor.constraint(equalTo: top.leadingAnchor), diff.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            diff.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10), diff.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: top.leadingAnchor), footer.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            diff.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var canNavigate: Bool { !busy }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canNavigate }
    func windowWillClose(_ notification: Notification) { settingsWillLeave() }
    override func settingsWillLeave() {
        job?.cancel()
        if let review { handoff.discard(review) }
        review = nil
    }

    private func setBusy(_ value: Bool) {
        busy = value
        let ready = review != nil && !value
        sources.isEnabled = ready; changes.isEnabled = ready
        cancel.isEnabled = !value; refresh.isEnabled = !value; confirm.isEnabled = ready
        sourceFrame.refreshEnabledState()
    }
    @objc private func closeReview() { if canNavigate { close() } }
    @objc private func load() {
        guard !busy else { return }
        if let review { handoff.discard(review) }
        review = nil; setBusy(true)
        sourceFrame.isHidden = true; origin.isHidden = true; destination.isHidden = true; changes.isHidden = true
        diff.show("", oldTitle: "", newTitle: "")
        status.textColor = AgentWorkbenchTheme.secondaryText; status.stringValue = "读取待移交内容…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await handoff.prepare()
                if Task.isCancelled { handoff.discard(value); return }
                review = value
                confirm.title = value.plans.count > 1 ? "确认移交 \(value.plans.count) 个项目" : "确认移交"
                sources.removeAllItems()
                let names = value.plans.map { URL(fileURLWithPath: $0.source.to.root).lastPathComponent }
                for (index, plan) in value.plans.enumerated() {
                    let path = URL(fileURLWithPath: plan.source.to.root)
                    let name = names[index]
                    let label = names.filter { $0 == name }.count > 1 ? path.deletingLastPathComponent().lastPathComponent + "/" + name : name
                    let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                    item.toolTip = plan.source.to.root
                    sources.menu?.addItem(item)
                }
                sources.selectItem(at: 0)
                sourceFrame.isHidden = value.plans.count < 2; origin.isHidden = false; destination.isHidden = false; changes.isHidden = false
                showSource()
            } catch { showError(error) }
            setBusy(false)
        }
    }

    @objc private func showSource() {
        guard let review, review.plans.indices.contains(sources.indexOfSelectedItem) else { return }
        let plan = review.plans[sources.indexOfSelectedItem], source = plan.source
        origin.stringValue = "工作树 · \(source.from.name) · \(source.from.head.prefix(12)) · \(source.from.root)"
        destination.stringValue = "本地 · \(source.to.name) · \(source.to.head.prefix(12)) · \(source.to.root)"
        origin.toolTip = origin.stringValue; destination.toolTip = destination.stringValue
        status.stringValue = source.appliedHead == nil ? "将创建合并提交" :
            source.appliedHead != source.to.head ? "本地分支将前移至 " + String(source.from.head.prefix(12)) : "本地分支 " + source.to.name
        if !plan.hasChanges { status.stringValue = "本地已有相同内容" }
        changes.selectedSegment = !plan.commits.isEmpty || !plan.patches[0].isEmpty ? 0 : plan.patches[1].isEmpty ? 2 : 1
        showChanges()
    }
    @objc private func showChanges() {
        guard let review, review.plans.indices.contains(sources.indexOfSelectedItem),
              let change = AgentWorktreeHandoffReview.Change(rawValue: changes.selectedSegment) else { return }
        let plan = review.plans[sources.indexOfSelectedItem]
        let patch = plan.patches[change.rawValue]
        let contents = change == .commits ? [plan.commits, patch].filter { !$0.isEmpty }.joined(separator: "\n") : patch
        diff.show(contents.isEmpty ? "暂无" + change.title + "改动" : contents, oldTitle: "本地", newTitle: change.title)
    }
    private func showError(_ error: Error) {
        status.stringValue = "移交待处理"; status.textColor = AgentDialogStyle.error
        diff.show(error.localizedDescription, oldTitle: "移交", newTitle: "错误详情")
    }
    @objc private func apply() {
        guard !busy, let reviewed = review else { return }
        setBusy(true); status.stringValue = "正在移交…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await handoff.apply(reviewed)
                setBusy(false); close(); onCompleted(id)
            } catch {
                handoff.discard(reviewed); review = nil
                showError(error); setBusy(false)
            }
        }
    }
}
