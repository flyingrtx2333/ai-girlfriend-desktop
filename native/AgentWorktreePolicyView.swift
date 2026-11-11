import AppKit

@MainActor final class AgentWorktreeSettingsWindow: AgentSettingsPageController, NSWindowDelegate {
    let policy: AgentWorktreePolicyView
    init(store: AgentStore, onOpenTask: @escaping (String) -> Void) {
        policy = AgentWorktreePolicyView(store: store, onOpenTask: onOpenTask)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "工作树"; window.minSize = NSSize(width: 500, height: 470); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        content.addSubview(policy); policy.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([policy.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), policy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), policy.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), policy.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)])
        policy.onOpenManager = { [weak self] in self?.presentSettingsChild($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() { super.settingsDidAppear(); policy.refreshState() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { policy.prepareToLeave() }
}

@MainActor final class AgentWorktreePolicyView: NSView {
    var onOpenManager: ((AgentWorktreeWindow) -> Void)?
    private let store: AgentStore, onOpenTask: (String) -> Void
    private let enabled = NSSwitch(), scope = NSPopUpButton(), period = NSPopUpButton(), projects = NSPopUpButton()
    private let apply = NSButton(title: "应用回收设置", target: nil, action: nil), reload = NSButton(title: "重新载入", target: nil, action: nil)
    private let check = NSButton(title: "立即检查", target: nil, action: nil), manage = NSButton(title: "管理工作树…", target: nil, action: nil), backups = NSButton(title: "打开备份", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: ""), history = NSTextView()
    private var periods: [Double] = [], roots: [AgentWorktreeRoot] = [], revision: String?, savedRevision: String?
    private var hasEdits = false
    init(store: AgentStore, onOpenTask: @escaping (String) -> Void) {
        self.store = store; self.onOpenTask = onOpenTask; super.init(frame: .zero)
        enabled.setAccessibilityLabel("自动回收工作树"); scope.setAccessibilityLabel("自动回收范围"); period.setAccessibilityLabel("工作树保留期"); projects.setAccessibilityLabel("工作树项目")
        scope.addItems(withTitles: ["仅已归档任务", "全部闲置任务"])
        for control in [enabled, scope, period] as [NSControl] { control.target = self; control.action = #selector(policyEdited) }
        let backup = NSTextField(labelWithString: "完整文件与暂存区 · 长期保留")
        let grid = NSGridView(views: [[NSTextField(labelWithString: "自动回收"), enabled], [NSTextField(labelWithString: "回收范围"), scope], [NSTextField(labelWithString: "保留期"), period], [NSTextField(labelWithString: "备份"), backup]])
        grid.rowSpacing = 12; grid.columnSpacing = 12; grid.column(at: 0).width = 72; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .fill
        grid.cell(atColumnIndex: 1, rowIndex: 0).xPlacement = .leading
        for button in [apply, reload, check, manage, backups] { button.target = self }
        apply.action = #selector(save); reload.action = #selector(reloadPolicy); check.action = #selector(checkNow); manage.action = #selector(openManager); backups.action = #selector(openBackups)
        projects.target = self; projects.action = #selector(projectChanged)
        let actions = NSStackView(views: [apply, reload, check, NSView()]); actions.spacing = 10
        let project = NSStackView(views: [projects, manage, backups]); project.spacing = 10
        projects.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText
        history.isEditable = false; history.isSelectable = true; history.font = .systemFont(ofSize: 12); history.setAccessibilityLabel("自动回收记录")
        history.textContainerInset = NSSize(width: 8, height: 8); history.autoresizingMask = [.width]; history.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = history; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSStackView(views: [grid, actions, project, state, scroll]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 16
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor), heightAnchor.constraint(equalToConstant: 430), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110)])
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        loadControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var draftPolicy: AgentWorktreeRetentionPolicy {
        var value = AgentWorktreeRetentionPolicy(); value.enabled = enabled.state == .on; value.archivedOnly = scope.indexOfSelectedItem == 0
        if periods.indices.contains(period.indexOfSelectedItem) { value.idleSeconds = periods[period.indexOfSelectedItem] }
        return value
    }
    var hasPendingChanges: Bool { hasEdits && draftPolicy != store.worktreeRetention.policy }
    func prepareToLeave() -> Bool {
        guard hasPendingChanges else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未应用的工作树设置？"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃修改")
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func loadControls() {
        let service = store.worktreeRetention, value = service.policy; revision = service.revision; hasEdits = false
        enabled.state = value.enabled ? .on : .off; scope.selectItem(at: value.archivedOnly ? 0 : 1)
        periods = [3600, 86400, 7 * 86400, 14 * 86400, 30 * 86400, 90 * 86400]
        if !periods.contains(value.idleSeconds) { periods.append(value.idleSeconds) }
        period.removeAllItems(); period.addItems(withTitles: periods.map(AgentWorktreeRetentionPolicy.duration)); period.selectItem(at: periods.firstIndex(of: value.idleSeconds) ?? 4)
        refreshState()
    }
    func refreshState() {
        let service = store.worktreeRetention
        if !hasEdits, revision != service.revision { loadControls(); return }
        let selection = roots.indices.contains(projects.indexOfSelectedItem) ? roots[projects.indexOfSelectedItem].id : nil
        roots = service.roots(); projects.removeAllItems()
        for root in roots { projects.addItem(withTitle: root.title); projects.lastItem?.toolTip = root.path }
        if let selection, let index = roots.firstIndex(where: { $0.id == selection }) { projects.selectItem(at: index) }
        if roots.isEmpty { projects.addItem(withTitle: "暂无工作树") }
        projects.isEnabled = !roots.isEmpty; manage.isEnabled = !roots.isEmpty; check.isEnabled = service.policy.enabled && !service.isChecking
        state.stringValue = (savedRevision != nil && savedRevision == service.revision ? "已保存 · " : "") + service.status + (service.nextCheck.map { "\n下次检查：" + $0.formatted(date: .numeric, time: .shortened) } ?? "")
        do {
            let values = try service.receipts()
            history.string = values.isEmpty ? "暂无自动回收记录" : values.prefix(10).map { receipt in
                let task = store.tasks.first { $0.workspace == receipt.path }
                return receipt.created.formatted(date: .abbreviated, time: .shortened) + " · " + (task?.title ?? URL(fileURLWithPath: receipt.root).lastPathComponent) + "\n" + (receipt.error ?? "已备份并回收")
            }.joined(separator: "\n\n")
        } catch { history.string = error.localizedDescription }
    }
    @objc private func policyEdited() { hasEdits = true; savedRevision = nil }
    @objc private func save() {
        guard periods.indices.contains(period.indexOfSelectedItem) else { return }
        let value = draftPolicy
        var consent = false
        if value.enabled, value != store.worktreeRetention.policy {
            let alert = NSAlert(); alert.messageText = "启用这项自动回收设置？"; alert.informativeText = value.summary
            alert.addButton(withTitle: "启用"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }; consent = true
        }
        do { try store.worktreeRetention.save(value, expectedRevision: revision, consent: consent); savedRevision = store.worktreeRetention.revision; loadControls() }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func reloadPolicy() { savedRevision = nil; store.worktreeRetention.reload(); loadControls() }
    @objc private func checkNow() { store.worktreeRetention.checkNow(); refreshState() }
    @objc private func projectChanged() { manage.isEnabled = roots.indices.contains(projects.indexOfSelectedItem) }
    @objc private func openManager() {
        guard roots.indices.contains(projects.indexOfSelectedItem), let onOpenManager else { return }
        do {
            let controller = try AgentWorktreeWindow(store: store, taskID: roots[projects.indexOfSelectedItem].taskID, allowsArchivedSource: true, onSelectTask: onOpenTask)
            onOpenManager(controller)
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func openBackups() {
        let folder = store.directory.appendingPathComponent("worktrees")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        catch { state.stringValue = error.localizedDescription }
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let controls: [NSView] = [enabled, scope, period, projects, apply, reload, check, manage, backups]
        return ["enabled": enabled.state == .on, "archivedOnly": scope.indexOfSelectedItem == 0, "idleSeconds": draftPolicy.idleSeconds, "pendingChanges": hasPendingChanges,
                "selectedProject": roots.indices.contains(projects.indexOfSelectedItem) ? roots[projects.indexOfSelectedItem].path : "", "projects": roots.map(\.path), "manageEnabled": manage.isEnabled, "state": state.stringValue,
                "checks": ["policyControlsFit": controls.allSatisfy { bounds.insetBy(dx: -1, dy: -1).contains(convert($0.bounds, from: $0)) }, "policyHistoryHasUsableSpace": history.enclosingScrollView?.bounds.height ?? 0 >= 100]]
    }
    func checkWorkspace(project: String? = nil, idleSeconds: Double? = nil, action: String = "") {
        guard AgentTaskWorkspace.readbackEnabled else { return }
        if let project, let index = roots.firstIndex(where: { $0.path == project }) { projects.selectItem(at: index); projectChanged() }
        if let idleSeconds, let index = periods.firstIndex(of: idleSeconds) { period.selectItem(at: index); policyEdited() }
        switch action { case "manage": openManager(); case "save": save(); case "reload": reloadPolicy(); default: break }
    }
}
