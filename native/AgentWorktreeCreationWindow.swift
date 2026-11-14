import AppKit

@MainActor final class AgentWorktreeCreationWindow: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate {
    private let store: AgentStore, taskID: String, git: AgentGit, onCreated: (String) -> Void
    private let start = NSPopUpButton(), branch = NSTextField(string: "agent/" + String(UUID().uuidString.lowercased().prefix(8)))
    private let include = NSButton(checkboxWithTitle: "带入当前修改", target: nil, action: nil)
    private let preview = NSButton(title: "预览", target: nil, action: nil), create = NSButton(title: "创建任务", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: ""), diff = AgentGitDiffView()
    private var points: [AgentWorktreeStart] = [], review: AgentWorktreeCreationReview?, job: Task<Void, Never>?
    private let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
    private let sourceOptions = NSStackView(), optionsScroll = NSScrollView()
    private var sourceStarts: [String: NSPopUpButton] = [:], sourcePoints: [String: [AgentWorktreeStart]] = [:]
    private var retainedRoots = Set<String>(), sourceRoots: [String] = [], resumeTaskID: String?
    private var originalInclude = false, originalStarts: [String: String] = [:]
    private var originalBranch = "", completed = false
    private let activityOwner = UUID()
    private var busy = false { didSet { if busy != oldValue { store.worktreeRetention.setNativeOperation(activityOwner, taskID: taskID, busy: busy) } } }
    init(store: AgentStore, taskID: String, directory: URL, resumeTaskID: String? = nil, onCreated: @escaping (String) -> Void) throws {
        self.store = store; self.taskID = taskID; self.onCreated = onCreated; git = try AgentGit(store: store, taskID: taskID, directory: directory)
        self.resumeTaskID = resumeTaskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "新建工作树 · " + git.files.root.lastPathComponent; window.minSize = NSSize(width: 640, height: 430); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        window.contentView = content
        if let setup = resumeTaskID.flatMap({ store.task($0)?.worktreeSetup }) { branch.stringValue = setup.branch; include.state = setup.includeChanges ? .on : .off }
        originalBranch = branch.stringValue; originalInclude = include.state == .on
        let root = NSTextField(labelWithString: git.files.root.path); root.font = .systemFont(ofSize: 11); root.textColor = AgentWorkbenchTheme.secondaryText; root.lineBreakMode = .byTruncatingMiddle; root.toolTip = git.files.root.path
        start.setAccessibilityLabel("起点分支"); branch.setAccessibilityLabel("新分支"); branch.delegate = self
        for control in [start, branch] { control.font = .systemFont(ofSize: 13); control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        start.cell?.lineBreakMode = .byTruncatingMiddle
        start.target = self; start.action = #selector(changed); include.target = self; include.action = #selector(changed)
        include.toolTip = "忽略文件不带入"
        preview.target = self; preview.action = #selector(previewCreation); create.target = self; create.action = #selector(confirm)
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText; state.isSelectable = true; state.maximumNumberOfLines = 0; diff.text.setAccessibilityLabel("待带入修改")
        let options = NSGridView(views: [[NSTextField(labelWithString: "起点分支"), start], [NSTextField(labelWithString: "新分支"), branch]])
        options.rowSpacing = 10; options.columnSpacing = 12; options.column(at: 0).xPlacement = .trailing; options.column(at: 1).xPlacement = .fill
        options.column(at: 0).width = 72
        sourceOptions.orientation = .vertical; sourceOptions.alignment = .leading; sourceOptions.spacing = 10
        sourceOptions.addArrangedSubview(options); options.widthAnchor.constraint(equalTo: sourceOptions.widthAnchor).isActive = true
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; optionsScroll.documentView = document; optionsScroll.hasVerticalScroller = true; optionsScroll.drawsBackground = false; optionsScroll.identifier = .init("form-input"); optionsScroll.setAccessibilityLabel("各源起点配置")
        document.addSubview(sourceOptions); sourceOptions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: optionsScroll.contentView.widthAnchor), sourceOptions.leadingAnchor.constraint(equalTo: document.leadingAnchor), sourceOptions.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12), sourceOptions.topAnchor.constraint(equalTo: document.topAnchor, constant: 2), sourceOptions.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2), optionsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 52), optionsScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 150)])
        let preferred = optionsScroll.heightAnchor.constraint(equalToConstant: CGFloat(min(148, 68 + 40 * max(0, (store.task(taskID)?.workspacePaths.count ?? 1) - 1)))); preferred.priority = .defaultHigh; preferred.isActive = true
        AgentSettingsStyle.primaryAction(create)
        let actions = NSStackView(views: [NSView(), preview, create]); actions.spacing = 10
        for view in [root, optionsScroll, include, state, diff, actions] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            optionsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), optionsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), optionsScroll.topAnchor.constraint(equalTo: root.bottomAnchor, constant: 14),
            include.leadingAnchor.constraint(equalTo: root.leadingAnchor), include.topAnchor.constraint(equalTo: optionsScroll.bottomAnchor, constant: 12),
            state.leadingAnchor.constraint(equalTo: root.leadingAnchor), state.trailingAnchor.constraint(equalTo: root.trailingAnchor), state.topAnchor.constraint(equalTo: include.bottomAnchor, constant: 10),
            diff.leadingAnchor.constraint(equalTo: root.leadingAnchor), diff.trailingAnchor.constraint(equalTo: root.trailingAnchor), diff.topAnchor.constraint(equalTo: state.bottomAnchor, constant: 10), diff.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -14),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor), actions.trailingAnchor.constraint(equalTo: root.trailingAnchor), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16), diff.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        setBusy(true)
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let values = try await git.workspaceWorktreeStartingPoints(); sourceRoots = values.map(\.root)
                let setup = resumeTaskID.flatMap { store.task($0)?.worktreeSetup }
                for (index, value) in values.enumerated() {
                    let popup = index == 0 ? start : NSPopUpButton(); popup.addItems(withTitles: value.points.map { $0.title + " · " + String($0.commit.prefix(8)) })
                    popup.target = self; popup.action = #selector(changed); popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); popup.cell?.lineBreakMode = .byTruncatingMiddle
                    if let selected = setup?.startPoints[value.root], let index = value.points.firstIndex(where: { $0.ref == selected }) { popup.selectItem(at: index) }
                    sourceStarts[value.root] = popup; sourcePoints[value.root] = value.points
                    if index == 0 { points = value.points }
                    else {
                        popup.setAccessibilityLabel("起点分支 · " + value.root)
                        let label = NSTextField(labelWithString: URL(fileURLWithPath: value.root).lastPathComponent); label.toolTip = value.root; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                        let row = NSStackView(views: [label, popup]); row.spacing = 12; row.alignment = .centerY; popup.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.65).isActive = true
                        sourceOptions.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: sourceOptions.widthAnchor).isActive = true
                    }
                }
                originalStarts = selectedStarts; refreshRetainedRoots(); include.title = values.count > 1 ? "带入待创建源的当前修改" : "带入当前修改"; state.stringValue = ""
            }
            catch { showFailure(error.localizedDescription, title: "源文件夹不可用") }
            setBusy(false)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var boundTaskID: String { resumeTaskID ?? taskID }
    private var selectedStarts: [String: String] { Dictionary(uniqueKeysWithValues: sourceRoots.compactMap { root in guard let popup = sourceStarts[root], let values = sourcePoints[root], values.indices.contains(popup.indexOfSelectedItem) else { return nil }; return (root, values[popup.indexOfSelectedItem].ref) }) }
    private func refreshRetainedRoots() { retainedRoots = Set(resumeTaskID.flatMap { store.task($0)?.managedWorktreeOrigins.map(\.root) } ?? []); create.title = resumeTaskID == nil ? "创建任务" : "继续创建" }
    var hasPendingChanges: Bool { busy || !completed && (branch.stringValue != originalBranch || (include.state == .on) != originalInclude || selectedStarts != originalStarts || review != nil) }
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
        busy = value; start.isEnabled = !value && !points.isEmpty; branch.isEnabled = !value && !points.isEmpty && resumeTaskID == nil; include.isEnabled = !value && !points.isEmpty
        for (root, popup) in sourceStarts { popup.isEnabled = !value && !retainedRoots.contains(root) }
        preview.isEnabled = !value && !points.isEmpty; create.isEnabled = !value && review != nil
    }
    private func showFailure(_ message: String, title: String) {
        state.stringValue = title; state.toolTip = message
        diff.show(message, oldTitle: "工作树", newTitle: "错误详情")
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
                try checkTask(); let value = try await git.prepareWorktreeCreation(branch: name, startPoint: base, includeChanges: carry, sourceStartPoints: selectedStarts, resumeTaskID: resumeTaskID)
                try Task.checkCancellation(); review = value; state.stringValue = value.sources.map { "\($0.count) 个待创建源 · 已保留 \(value.retained?.count ?? 0) 个 · \(value.paths.count) 个文件" } ?? (value.includeChanges ? "将带入 \(value.paths.count) 个文件 · 保持未暂存" : "预览完成")
                diff.show(value.patch, oldTitle: "所选起点", newTitle: "新工作树")
            } catch { showFailure(error.localizedDescription, title: "预览失败"); review = nil }
            setBusy(false)
        }
    }
    @objc private func confirm() {
        guard !busy, let review else { return }
        createReviewed(review)
    }
    private func createReviewed(_ review: AgentWorktreeCreationReview) {
        let wasResuming = resumeTaskID != nil
        setBusy(true); state.stringValue = "创建工作树…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                try checkTask(); let result = try await git.createReviewedWorktree(review.hash)
                if !wasResuming { try store.copyEnvironmentDraft(sourceID: taskID, targetID: result.taskID) }
                completed = true; setBusy(false); close(); onCreated(result.taskID)
            } catch {
                var message = error.localizedDescription
                if let id = git.lastCreatedWorktreeTaskID {
                    if !wasResuming { do { try store.copyEnvironmentDraft(sourceID: taskID, targetID: id) } catch { message += "\n原任务草稿仍保留：" + error.localizedDescription } }
                    resumeTaskID = id; refreshRetainedRoots(); originalBranch = branch.stringValue; originalInclude = include.state == .on; originalStarts = selectedStarts
                }
                showFailure(message, title: resumeTaskID == nil ? "工作树创建失败" : "已保留未完成的工作树"); self.review = nil; setBusy(false)
            }
        }
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let frames = [start, branch, include, preview, create].map { content.convert($0.bounds, from: $0) }
        return ["taskID": taskID, "resumeTaskID": resumeTaskID ?? "", "sources": sourceRoots, "sourceStartPoints": selectedStarts, "retainedRoots": retainedRoots.sorted(), "branch": branch.stringValue, "startPoint": points.indices.contains(start.indexOfSelectedItem) ? points[start.indexOfSelectedItem].ref : "", "includeChanges": include.state == .on, "reviewHash": review?.hash ?? "", "patch": diff.patch, "state": state.stringValue, "busy": busy, "hasPendingChanges": hasPendingChanges, "createEnabled": create.isEnabled,
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
