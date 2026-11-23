import AppKit

@MainActor final class AgentWorktreeSettingsWindow: AgentSettingsPageController, NSWindowDelegate {
    private struct ReviewSource: Codable, Equatable {
        let policy: AgentWorktreeRetentionPolicy
        let revision: String?
        let parentY: Double
    }
    private typealias PolicyReview = AgentSettingsResumableReview<ReviewSource>
    private var reviewPage: PolicyReview?
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
        policy.onReview = { [weak self] value, revision in
            guard let self else { return }
            let source = ReviewSource(policy: value, revision: revision, parentY: max(0, policy.enclosingScrollView?.contentView.bounds.minY ?? 0))
            presentSettingsChild(makeReview(source))
        }
        policy.onDraftChange = { [weak self] in self?.onSettingsRecoveryChange?() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        guard let content = super.settingsContent(in: host, styled: styled) else { return nil }
        for constraint in content.constraints where constraint.firstItem as? NSView === policy && constraint.secondItem as? NSView === content {
            constraint.constant = 0
        }
        return content
    }
    override func settingsDidAppear() {
        super.settingsDidAppear(); policy.reloadUpstreamPreference(); policy.refreshState()
        if reviewPage != nil { reviewPage = nil; policy.focusApply() }
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? { try policy.captureRecovery() }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws { try policy.restoreRecovery(page) }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        if page.kind == "worktree-manager" {
            return try policy.restoreManager(JSONDecoder().decode(AgentWorktreeManagerRecovery.self, from: page.state))
        }
        guard page.kind == "worktree-policy-review" else { return nil }
        let source = try PolicyReview.savedSource(page, kind: page.kind)
        try source.policy.validate()
        guard source.policy.enabled, AgentSettingsRecovery.validHash(source.revision),
              AgentSettingsRecovery.validScroll(source.parentY) else { throw PetError("原回收审阅记录无效") }
        if let scroll = policy.enclosingScrollView {
            presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            AgentSettingsRecovery.restoreScroll(source.parentY, to: scroll)
        }
        return makeReview(source)
    }
    private func makeReview(_ source: ReviewSource) -> PolicyReview {
        let page = PolicyReview(kind: "worktree-policy-review", source: source, title: "审阅自动回收", metadata: "所有项目",
            notice: "符合条件的工作树会在备份文件与暂存区后移除。备份与分支长期保留。",
            sections: [("回收设置", source.policy.summary)], applyTitle: "应用")
        page.prefersCancelFocus = true
        page.onApply = { [weak self, weak page] in
            guard let self else { throw PetError("工作树设置已关闭，请重新打开") }
            do { try policy.requireReview(source.policy, revision: source.revision) }
            catch { page?.showPreviewFailure(error); throw error }
            try policy.savePolicy(source.policy, consent: true)
        }
        do { try policy.requireReview(source.policy, revision: source.revision) }
        catch { page.showPreviewFailure(error) }
        reviewPage = page
        return page
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { policy.prepareToLeave() }
}

@MainActor final class AgentWorktreePolicyView: NSView {
    var onOpenManager: ((AgentWorktreeWindow) -> Void)?
    var onReview: ((AgentWorktreeRetentionPolicy, String?) -> Void)?
    var onDraftChange: (() -> Void)?
    private let store: AgentStore, onOpenTask: (String) -> Void
    private let fetchUpstream = NSSwitch()
    private let upstreamStatus = AgentSettingsStatusField("上游设置保存状态")
    private var upstreamRevision: String?
    private let enabled = NSSwitch(), scope = NSPopUpButton(), period = NSPopUpButton(), projects = NSPopUpButton()
    private let condition = NSPopUpButton(), maximum = NSPopUpButton()
    private let apply = AgentDialogButton(title: "应用回收设置", target: nil, action: nil), reload = NSButton(title: "重新载入", target: nil, action: nil)
    private let check = NSButton(title: "立即检查", target: nil, action: nil), manage = NSButton(title: "管理工作树…", target: nil, action: nil), backups = NSButton(title: "打开备份", target: nil, action: nil)
    private let state = AgentSettingsStatusField("工作树回收状态"), history = NSTextView()
    private let emptyProjects = NSTextField(labelWithString: "暂无托管工作树"), historyScroll = NSScrollView()
    private lazy var projectFrame = AgentSettingsPopupFrame(projects)
    private lazy var periodFrame = AgentSettingsPopupFrame(period)
    private lazy var maximumFrame = AgentSettingsPopupFrame(maximum)
    private var periods: [Double] = [], roots: [AgentWorktreeRoot] = [], revision: String?, savedRevision: String?
    private var counts: [Int] = []
    private var hasEdits = false
    private var historyHeight: NSLayoutConstraint?
    init(store: AgentStore, onOpenTask: @escaping (String) -> Void) {
        self.store = store; self.onOpenTask = onOpenTask; super.init(frame: .zero)
        fetchUpstream.setAccessibilityLabel("创建前获取上游更新")
        fetchUpstream.toolTip = "预览时获取所选起点已配置的上游分支"
        fetchUpstream.target = self; fetchUpstream.action = #selector(saveUpstreamPreference)
        let creation = AgentSettingsStyle.section("", id: "worktree-creation", rows: [
            AgentSettingsStyle.formRow("创建前获取上游更新", fetchUpstream, trailing: true), upstreamStatus], separatesRows: false)
        enabled.setAccessibilityLabel("自动回收工作树"); scope.setAccessibilityLabel("自动回收范围"); period.setAccessibilityLabel("工作树保留期"); projects.setAccessibilityLabel("工作树项目")
        condition.setAccessibilityLabel("工作树回收条件"); maximum.setAccessibilityLabel("每项目工作树保留上限")
        scope.addItems(withTitles: ["仅已归档任务", "全部闲置任务"])
        condition.addItems(withTitles: ["按闲置时间", "按数量"])
        for control in [enabled, scope, condition, period, maximum] as [NSControl] { control.target = self; control.action = #selector(policyEdited) }
        let backup = NSTextField(labelWithString: "完整文件与暂存区 · 长期保留")
        backup.font = .systemFont(ofSize: 12); backup.textColor = AgentWorkbenchTheme.secondaryText
        for button in [apply, reload, check, manage, backups] { button.target = self }
        apply.action = #selector(save); reload.action = #selector(reloadPolicy); check.action = #selector(checkNow); manage.action = #selector(openManager); backups.action = #selector(openBackups)
        projects.target = self; projects.action = #selector(projectChanged)
        AgentSettingsStyle.primaryAction(apply); apply.keyEquivalent = "s"; apply.keyEquivalentModifierMask = .command
        let actions = NSStackView(views: [check, NSView(), reload, apply]); actions.spacing = 10
        let project = NSStackView(views: [emptyProjects, projectFrame, NSView(), manage, backups]); project.spacing = 10
        emptyProjects.font = .systemFont(ofSize: 13); emptyProjects.textColor = AgentWorkbenchTheme.secondaryText
        projects.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText
        history.isEditable = false; history.isSelectable = true; history.font = .systemFont(ofSize: 13); history.setAccessibilityLabel("自动回收记录")
        history.textContainerInset = NSSize(width: 8, height: 8); history.autoresizingMask = [.width]; history.textContainer?.widthTracksTextView = true
        historyScroll.documentView = history; historyScroll.hasVerticalScroller = true; historyScroll.identifier = .init("form-input")
        let amount = NSStackView(views: [AgentSettingsPopupFrame(condition), periodFrame, maximumFrame]); amount.alignment = .centerY; amount.spacing = 8
        let policy = AgentSettingsStyle.section("自动回收", id: "worktree-policy", rows: [
            AgentSettingsStyle.formRow("启用", enabled, trailing: true), AgentSettingsStyle.formRow("回收范围", scope, trailing: true),
            AgentSettingsStyle.formRow("保留方式", amount, trailing: true),
            AgentSettingsStyle.formRow("备份", backup, trailing: true), actions])
        let details = NSStackView(views: [project, state, historyScroll]); details.orientation = .vertical; details.alignment = .leading; details.spacing = 10
        for view in details.arrangedSubviews { view.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true }
        let records = AgentSettingsStyle.section("工作树与记录", id: "worktree-history", rows: [details])
        let column = NSStackView(views: [creation, policy, records]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 24
        column.setCustomSpacing(16, after: creation)
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        let historyHeight = historyScroll.heightAnchor.constraint(equalToConstant: 150); self.historyHeight = historyHeight
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor), historyHeight])
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        reloadUpstreamPreference(); loadControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func reloadUpstreamPreference() {
        do {
            let value = try store.gitPreferences.worktreeFetchPreference()
            fetchUpstream.state = value.enabled ? .on : .off
            fetchUpstream.isEnabled = true; upstreamRevision = value.revision; upstreamStatus.stringValue = ""
        } catch {
            fetchUpstream.state = .off; fetchUpstream.isEnabled = false
            upstreamStatus.showSaveFailure(error)
        }
    }
    @objc private func saveUpstreamPreference() {
        do {
            try store.gitPreferences.saveWorktreeFetchPreference(fetchUpstream.state == .on, replacing: upstreamRevision)
            reloadUpstreamPreference()
        } catch {
            reloadUpstreamPreference()
            upstreamStatus.showSaveFailure(error)
        }
    }
    private var draftPolicy: AgentWorktreeRetentionPolicy {
        var value = AgentWorktreeRetentionPolicy(); value.enabled = enabled.state == .on; value.archivedOnly = scope.indexOfSelectedItem == 0
        if periods.indices.contains(period.indexOfSelectedItem) { value.idleSeconds = periods[period.indexOfSelectedItem] }
        if condition.indexOfSelectedItem == 1, counts.indices.contains(maximum.indexOfSelectedItem) { value.maximumCount = counts[maximum.indexOfSelectedItem] }
        return value
    }
    var hasPendingChanges: Bool { hasEdits && draftPolicy != store.worktreeRetention.policy }
    func prepareToLeave() -> Bool {
        guard hasPendingChanges else { return true }
        return AgentUnsavedChanges.discard("放弃未应用的工作树设置？", discardTitle: "放弃修改", owner: window)
    }
    private func loadControls() {
        let service = store.worktreeRetention; revision = service.revision; hasEdits = false
        showPolicy(service.policy)
        refreshState()
    }
    private func showPolicy(_ value: AgentWorktreeRetentionPolicy) {
        enabled.state = value.enabled ? .on : .off; scope.selectItem(at: value.archivedOnly ? 0 : 1)
        periods = [3600, 86400, 7 * 86400, 14 * 86400, 30 * 86400, 90 * 86400]
        if !periods.contains(value.idleSeconds) { periods.append(value.idleSeconds) }
        period.removeAllItems(); period.addItems(withTitles: periods.map(AgentWorktreeRetentionPolicy.duration)); period.selectItem(at: periods.firstIndex(of: value.idleSeconds) ?? 4)
        let limit = value.maximumCount ?? 15
        counts = [1, 5, 10, 15, 20, 30, 50, 100]
        if !counts.contains(limit) { counts.append(limit); counts.sort() }
        maximum.removeAllItems(); maximum.addItems(withTitles: counts.map { "每项目 \($0) 个" }); maximum.selectItem(at: counts.firstIndex(of: limit) ?? 0)
        condition.selectItem(at: value.maximumCount == nil ? 0 : 1)
        showCondition()
    }
    private func showCondition() {
        let byCount = condition.indexOfSelectedItem == 1
        periodFrame.isHidden = byCount; maximumFrame.isHidden = !byCount
    }
    func refreshState() {
        let service = store.worktreeRetention
        if !hasEdits, revision != service.revision { loadControls(); return }
        let selection = roots.indices.contains(projects.indexOfSelectedItem) ? roots[projects.indexOfSelectedItem].id : nil
        roots = service.roots(); projects.removeAllItems()
        for root in roots { projects.addItem(withTitle: root.title); projects.lastItem?.toolTip = root.path }
        if let selection, let index = roots.firstIndex(where: { $0.id == selection }) { projects.selectItem(at: index) }
        emptyProjects.isHidden = !roots.isEmpty; projectFrame.isHidden = roots.isEmpty; manage.isHidden = roots.isEmpty
        projects.isEnabled = !roots.isEmpty; manage.isEnabled = !roots.isEmpty; check.isEnabled = service.policy.enabled && !service.isChecking
        updateStatus()
        do {
            let values = try service.receipts()
            historyScroll.isHidden = roots.isEmpty && values.isEmpty
            historyHeight?.constant = values.isEmpty ? 56 : 150
            history.string = values.isEmpty ? "暂无自动回收记录" : values.prefix(10).map { receipt in
                let task = store.tasks.first { $0.workspace == receipt.path }
                return receipt.created.formatted(date: .abbreviated, time: .shortened) + " · " + (task?.title ?? URL(fileURLWithPath: receipt.root).lastPathComponent) + "\n" + (receipt.error ?? "已备份并回收")
            }.joined(separator: "\n\n")
        } catch { historyScroll.isHidden = false; historyHeight?.constant = 150; history.string = error.localizedDescription }
    }
    private func updateStatus() {
        let service = store.worktreeRetention
        if hasPendingChanges, revision != service.revision {
            showFailure(PetError("回收设置已变化，请重新载入后保存")); return
        }
        let prefix = hasPendingChanges ? "未应用 · " : savedRevision != nil && savedRevision == service.revision ? "已保存 · " : ""
        state.stringValue = prefix + service.status + (service.nextCheck.map { "\n下次检查：" + $0.formatted(date: .numeric, time: .shortened) } ?? "")
        state.isHidden = roots.isEmpty && state.stringValue == "自动回收未开启"
    }
    private func showFailure(_ error: Error) { state.isHidden = false; state.showSaveFailure(error) }
    func focusApply() { window?.makeFirstResponder(apply) }
    @objc private func policyEdited() { hasEdits = true; savedRevision = nil; showCondition(); updateStatus(); onDraftChange?() }
    @objc private func save() {
        guard periods.indices.contains(period.indexOfSelectedItem) else { return }
        let value = draftPolicy
        if value.enabled, value != store.worktreeRetention.policy {
            onReview?(value, revision)
        } else {
            do { try savePolicy(value) } catch { showFailure(error) }
        }
    }
    func requireReview(_ value: AgentWorktreeRetentionPolicy, revision expected: String?) throws {
        guard value.enabled, hasPendingChanges, draftPolicy == value, expected == revision, expected == store.worktreeRetention.revision else {
            throw PetError("回收设置已变化。请返回核对后重新审阅。")
        }
        try store.worktreeRetention.requirePolicyRevision(expected)
    }
    func savePolicy(_ value: AgentWorktreeRetentionPolicy, consent: Bool = false) throws {
        try store.worktreeRetention.save(value, expectedRevision: revision, consent: consent)
        savedRevision = store.worktreeRetention.revision
        loadControls()
        onDraftChange?()
    }
    @objc private func reloadPolicy() { savedRevision = nil; store.worktreeRetention.reload(); loadControls(); onDraftChange?() }
    @objc private func checkNow() { store.worktreeRetention.checkNow(); refreshState() }
    @objc private func projectChanged() { manage.isEnabled = roots.indices.contains(projects.indexOfSelectedItem); onDraftChange?() }
    @objc private func openManager() {
        guard roots.indices.contains(projects.indexOfSelectedItem), let onOpenManager else { return }
        do {
            let root = roots[projects.indexOfSelectedItem]
            let controller = try AgentWorktreeWindow(store: store, taskID: root.taskID, allowsArchivedSource: true, workspace: root.path, onSelectTask: onOpenTask)
            onOpenManager(controller)
        } catch { showFailure(error) }
    }
    func restoreManager(_ recovery: AgentWorktreeManagerRecovery) throws -> AgentWorktreeWindow {
        let source = recovery.source
        guard recovery.valid, roots.contains(where: { $0.path == source.workspace && $0.metadata == source.metadata }) else {
            throw PetError("原托管工作树项目已不可用，阅读记录已保留")
        }
        return try AgentWorktreeWindow(store: store, taskID: source.taskID, allowsArchivedSource: true,
            workspace: source.workspace, recovery: recovery, onSelectTask: onOpenTask)
    }
    @objc private func openBackups() {
        let folder = store.directory.appendingPathComponent("worktrees")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        catch { showFailure(error) }
    }
    private struct Recovery: Codable {
        var version = 1
        var revision: String?
        var draft: AgentWorktreeRetentionPolicy?
        var project: String?
    }
    func captureRecovery() throws -> AgentSettingsRecovery.Page? {
        let project = roots.indices.contains(projects.indexOfSelectedItem) ? roots[projects.indexOfSelectedItem].id : nil
        let draft = hasPendingChanges ? draftPolicy : nil
        guard draft != nil || project != nil else { return nil }
        return try AgentSettingsRecovery.page("worktrees", Recovery(revision: revision, draft: draft, project: project))
    }
    func restoreRecovery(_ page: AgentSettingsRecovery.Page) throws {
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "revision", "draft", "project"])
        let recovery = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard page.kind == "worktrees", recovery.version == 1, AgentSettingsRecovery.validHash(recovery.revision),
              AgentSettingsRecovery.validHash(recovery.project),
              recovery.draft != nil || recovery.project != nil else { throw PetError("工作树设置草稿格式无效，原记录已保留") }
        if let draft = recovery.draft, let rawDraft = raw["draft"] {
            _ = try AgentWorktreeRetentionPolicy.read(JSONSerialization.data(withJSONObject: rawDraft))
            if draft != store.worktreeRetention.policy {
                revision = recovery.revision; hasEdits = true; showPolicy(draft)
            }
        }
        refreshState()
        if let project = recovery.project, let index = roots.firstIndex(where: { $0.id == project }) { projects.selectItem(at: index) }
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let controls: [NSView] = [fetchUpstream, enabled, scope, condition, period, maximum, projects, apply, reload, check, manage, backups, emptyProjects]
        let records = try? store.worktreeRetention.receipts(), historySize = history.enclosingScrollView?.bounds.size ?? .zero
        let empty = records?.isEmpty == true
        let historyFits = empty ? (roots.isEmpty ? historyScroll.isHidden : abs(historySize.height - 56) < 1 && !historyScroll.isHidden) : historySize.height >= 150 && !historyScroll.isHidden && !history.string.isEmpty
        return ["enabled": enabled.state == .on, "fetchUpstream": fetchUpstream.state == .on, "archivedOnly": scope.indexOfSelectedItem == 0, "idleSeconds": draftPolicy.idleSeconds, "pendingChanges": hasPendingChanges,
                "maximumCount": draftPolicy.maximumCount.map { $0 as Any } ?? NSNull(), "periodVisible": !periodFrame.isHidden, "maximumVisible": !maximumFrame.isHidden,
                "selectedProject": roots.indices.contains(projects.indexOfSelectedItem) ? roots[projects.indexOfSelectedItem].path : "", "projects": roots.map(\.path), "manageEnabled": manage.isEnabled, "state": state.stringValue, "history": history.string, "historyCount": records?.count ?? -1, "historySize": [historySize.width, historySize.height],
                "emptyProjectsVisible": !emptyProjects.isHidden, "projectPickerVisible": !projectFrame.isHidden, "historyVisible": !historyScroll.isHidden,
                "checks": ["policyControlsFit": controls.filter { !$0.isHiddenOrHasHiddenAncestor }.allSatisfy { bounds.insetBy(dx: -1, dy: -1).contains(convert($0.bounds, from: $0)) },
                           "policyHistoryHasUsableSpace": historyFits]]
    }
    func checkWorkspace(project: String? = nil, idleSeconds: Double? = nil, enable: Bool? = nil, action: String = "") {
        guard AgentTaskWorkspace.readbackEnabled else { return }
        if let project, let index = roots.firstIndex(where: { $0.path == project }) { projects.selectItem(at: index); projectChanged() }
        if let idleSeconds, let index = periods.firstIndex(of: idleSeconds) { period.selectItem(at: index); policyEdited() }
        if let enable { enabled.state = enable ? .on : .off; policyEdited() }
        switch action { case "manage": openManager(); case "save": save(); case "reload": reloadPolicy(); default: break }
    }
}
