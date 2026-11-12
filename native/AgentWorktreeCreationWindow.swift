import AppKit

@MainActor final class AgentWorktreeCreationWindow: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate {
    private let store: AgentStore, taskID: String, git: AgentGit, onCreated: (String) -> Void
    private let start = NSPopUpButton(), branch = NSTextField(string: "agent/" + String(UUID().uuidString.lowercased().prefix(8)))
    private let include = NSButton(checkboxWithTitle: "带入当前修改", target: nil, action: nil)
    private let preview = NSButton(title: "预览", target: nil, action: nil), create = NSButton(title: "创建任务", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: ""), diff = AgentGitDiffView()
    private var points: [AgentWorktreeStart] = [], review: AgentWorktreeCreationReview?, job: Task<Void, Never>?
    private let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
    private var originalBranch = "", completed = false
    private let activityOwner = UUID()
    private var busy = false { didSet { if busy != oldValue { store.worktreeRetention.setNativeOperation(activityOwner, taskID: taskID, busy: busy) } } }
    init(store: AgentStore, taskID: String, directory: URL, onCreated: @escaping (String) -> Void) throws {
        self.store = store; self.taskID = taskID; self.onCreated = onCreated; git = try AgentGit(store: store, taskID: taskID, directory: directory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "新建工作树 · " + git.files.root.lastPathComponent; window.minSize = NSSize(width: 640, height: 430); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        window.contentView = content; originalBranch = branch.stringValue
        let root = NSTextField(labelWithString: git.files.root.path); root.font = .systemFont(ofSize: 11); root.textColor = AgentWorkbenchTheme.secondaryText; root.lineBreakMode = .byTruncatingMiddle; root.toolTip = git.files.root.path
        start.setAccessibilityLabel("起点分支"); branch.setAccessibilityLabel("新分支"); branch.delegate = self
        for control in [start, branch] { control.font = .systemFont(ofSize: 13); control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        start.cell?.lineBreakMode = .byTruncatingMiddle
        start.target = self; start.action = #selector(changed); include.target = self; include.action = #selector(changed)
        include.toolTip = "忽略文件不带入"
        preview.target = self; preview.action = #selector(previewCreation); create.target = self; create.action = #selector(confirm)
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText; state.maximumNumberOfLines = 4; state.lineBreakMode = .byTruncatingTail; diff.text.setAccessibilityLabel("待带入修改")
        let options = NSGridView(views: [[NSTextField(labelWithString: "起点分支"), start], [NSTextField(labelWithString: "新分支"), branch]])
        options.rowSpacing = 10; options.columnSpacing = 12; options.column(at: 0).xPlacement = .trailing; options.column(at: 1).xPlacement = .fill
        options.column(at: 0).width = 72
        let actions = NSStackView(views: [NSView(), preview, create]); actions.spacing = 10
        for view in [root, options, include, state, diff, actions] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            options.leadingAnchor.constraint(equalTo: root.leadingAnchor), options.trailingAnchor.constraint(equalTo: root.trailingAnchor), options.topAnchor.constraint(equalTo: root.bottomAnchor, constant: 14),
            include.leadingAnchor.constraint(equalTo: root.leadingAnchor), include.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 12),
            state.leadingAnchor.constraint(equalTo: root.leadingAnchor), state.trailingAnchor.constraint(equalTo: root.trailingAnchor), state.topAnchor.constraint(equalTo: include.bottomAnchor, constant: 10),
            diff.leadingAnchor.constraint(equalTo: root.leadingAnchor), diff.trailingAnchor.constraint(equalTo: root.trailingAnchor), diff.topAnchor.constraint(equalTo: state.bottomAnchor, constant: 10), diff.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -14),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor), actions.trailingAnchor.constraint(equalTo: root.trailingAnchor), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        setBusy(true)
        job = Task { [weak self] in
            guard let self else { return }
            do { points = try await git.worktreeStartingPoints(); start.addItems(withTitles: points.map { $0.title + " · " + String($0.commit.prefix(8)) }); state.stringValue = "" }
            catch { state.stringValue = error.localizedDescription }
            setBusy(false)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var boundTaskID: String { taskID }
    var hasPendingChanges: Bool { busy || !completed && (branch.stringValue != originalBranch || include.state == .on || start.indexOfSelectedItem > 0 || review != nil) }
    func prepareWorkspaceNavigation() -> Bool { !busy }
    override func settingsDidAppear() { super.settingsDidAppear(); presentingWindow?.makeFirstResponder(branch) }
    override func settingsWillLeave() { job?.cancel(); git.cancel(); busy = false }
    func windowWillClose(_ notification: Notification) { settingsWillLeave() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !busy else { return false }
        guard hasPendingChanges else { return true }
        return AgentUnsavedChanges.discard("放弃工作树创建配置？", detail: branch.stringValue, discardTitle: "放弃配置")
    }
    func controlTextDidChange(_ obj: Notification) { changed() }
    @objc private func changed() { review = nil; create.isEnabled = false; state.stringValue = ""; diff.show("", oldTitle: "起点", newTitle: "当前修改") }
    private func setBusy(_ value: Bool) {
        busy = value; start.isEnabled = !value; branch.isEnabled = !value; include.isEnabled = !value
        preview.isEnabled = !value && !points.isEmpty; create.isEnabled = !value && review != nil
    }
    private func checkTask() throws {
        guard let task = store.task(taskID), !task.archived, ![.running, .waiting].contains(task.status) else { throw PetError("来源任务正在执行或已归档，请稍后重试") }
    }
    @objc private func previewCreation() {
        guard !busy, points.indices.contains(start.indexOfSelectedItem) else { return }
        let name = branch.stringValue, base = points[start.indexOfSelectedItem].ref, carry = include.state == .on
        review = nil; setBusy(true); state.stringValue = "正在预览…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                try checkTask(); let value = try await git.prepareWorktreeCreation(branch: name, startPoint: base, includeChanges: carry)
                try Task.checkCancellation(); review = value; state.stringValue = value.includeChanges ? "将带入 \(value.paths.count) 个文件 · 保持未暂存" : "预览完成"
                diff.show(value.patch, oldTitle: "所选起点", newTitle: "新工作树")
            } catch { state.stringValue = error.localizedDescription; review = nil }
            setBusy(false)
        }
    }
    @objc private func confirm() {
        guard !busy, let review else { return }
        createReviewed(review)
    }
    private func createReviewed(_ review: AgentWorktreeCreationReview) {
        setBusy(true); state.stringValue = "创建工作树…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                try checkTask(); let result = try await git.createReviewedWorktree(review.hash)
                try store.copyEnvironmentDraft(sourceID: taskID, targetID: result.taskID)
                completed = true; setBusy(false); close(); onCreated(result.taskID)
            } catch { state.stringValue = error.localizedDescription; self.review = nil; setBusy(false) }
        }
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let frames = [start, branch, include, preview, create].map { content.convert($0.bounds, from: $0) }
        return ["taskID": taskID, "branch": branch.stringValue, "startPoint": points.indices.contains(start.indexOfSelectedItem) ? points[start.indexOfSelectedItem].ref : "", "includeChanges": include.state == .on, "reviewHash": review?.hash ?? "", "patch": diff.patch, "state": state.stringValue, "busy": busy, "hasPendingChanges": hasPendingChanges, "createEnabled": create.isEnabled,
                "checks": ["creationUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow, "creationHasNoFloatingWindow": window?.isVisible != true, "creationControlsFit": frames.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains($0) }, "creationPreviewHasUsableHeight": diff.bounds.height >= 120]]
    }
    func checkWorkspace(branch name: String? = nil, startPoint: String? = nil, includeChanges: Bool? = nil, action: String = "") async {
        guard AgentTaskWorkspace.readbackEnabled else { return }; await job?.value
        if let name { branch.stringValue = name; changed() }
        if let startPoint, let index = points.firstIndex(where: { $0.ref == startPoint }) { start.selectItem(at: index); changed() }
        if let includeChanges { include.state = includeChanges ? .on : .off; changed() }
        if action == "preview" { previewCreation(); await job?.value }
        if action == "create" { confirm(); await job?.value }
    }
}

@MainActor extension AgentStore {
    func copyEnvironmentDraft(sourceID: String, targetID: String) throws {
        guard let source = task(sourceID), let target = task(targetID), target.messages.isEmpty else { throw PetError("新任务不可用，原草稿仍保留") }
        try AgentAttachments.copyDraft(store: self, sourceID: sourceID, targetID: targetID)
        update(targetID) {
            $0.draft = source.draft; $0.permission = source.permission; $0.mode = source.mode
            $0.model = source.model; $0.modelOverride = source.modelOverride; $0.toolGroups = source.toolGroups
            $0.agent = source.agent; $0.agent?.workspace = target.workspace; $0.team = source.team
        }
        if let error = writeError { throw PetError("新任务草稿未保存，原草稿仍保留：" + error) }
    }
}
