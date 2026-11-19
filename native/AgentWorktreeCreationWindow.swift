import AppKit

@MainActor final class AgentWorktreeCreationWindow: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate {
    typealias Draft = AgentGitDraftRecovery.WorktreeForm
    private let store: AgentStore, taskID: String, git: AgentGit, onCreated: (String) -> Void
    private let start = NSPopUpButton(), branch = AgentDialogTextField(string: "agent/" + String(UUID().uuidString.lowercased().prefix(8)))
    private let include = NSButton(checkboxWithTitle: "带入当前修改", target: nil, action: nil)
    private let preview = AgentDialogButton(title: "预览", target: nil, action: nil), create = AgentDialogButton(title: "创建任务", target: nil, action: nil)
    private let state = AgentSettingsStatusField("工作树创建状态"), diff = AgentGitDiffView()
    private lazy var startFrame = AgentSettingsPopupFrame(start, outlined: true, maximumWidth: nil)
    private var sourceFrames: [AgentSettingsPopupFrame] = []
    private var review: AgentWorktreeCreationReview?, job: Task<Void, Never>?
    private let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
    private let sourceOptions = NSStackView(), optionsScroll = NSScrollView()
    private var sourceStarts: [String: NSPopUpButton] = [:]
    private var retainedRoots = Set<String>(), sourceRoots: [String] = [], resumeTaskID: String?
    private var originalInclude = false, originalStarts: [String: String] = [:]
    private var originalBranch = "", completed = false
    private var draftSources: [Draft.Source] = [], loadingDraft: Draft?
    private var restoredForm = false, restoreViewportPending = true
    private var focus: String?, branchSelection: AgentTextViewport.Selection?, scroll: Double = 0
    var onDraftChange: (() -> Void)?
    var onLeave: (() -> Void)?
    private let activityOwner = UUID()
    private var busy = false { didSet { if busy != oldValue { store.worktreeRetention.setNativeOperation(activityOwner, taskID: taskID, busy: busy) } } }
    init(store: AgentStore, taskID: String, directory: URL, resumeTaskID: String? = nil, recovery: Draft? = nil, onCreated: @escaping (String) -> Void) throws {
        let git = try AgentGit(store: store, taskID: taskID, directory: directory)
        let setup = resumeTaskID.flatMap { store.task($0)?.worktreeSetup }
        if let recovery {
            guard try recovery.sources == git.worktreeDraftSources(resumeTaskID: resumeTaskID), setup == nil || recovery.branch == setup?.branch else {
                throw PetError("请回到创建配置的原源文件夹、仓库和分支后重试，草稿已保留")
            }
        }
        self.store = store; self.taskID = taskID; self.onCreated = onCreated; self.git = git
        self.resumeTaskID = resumeTaskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "新建工作树 · " + git.files.root.lastPathComponent; window.minSize = NSSize(width: 640, height: 430); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        window.contentView = content
        if let setup { branch.stringValue = setup.branch; include.state = setup.includeChanges ? .on : .off }
        originalBranch = branch.stringValue; originalInclude = include.state == .on
        if let recovery {
            loadingDraft = recovery; restoredForm = true
            branch.stringValue = recovery.branch; include.state = recovery.includeChanges ? .on : .off
            focus = recovery.focus; branchSelection = recovery.branchSelection; scroll = recovery.scroll
        } else if resumeTaskID == nil { focus = "branch" }
        let root = NSTextField(labelWithString: git.files.root.path); root.font = .systemFont(ofSize: 11); root.textColor = AgentWorkbenchTheme.secondaryText; root.lineBreakMode = .byTruncatingMiddle; root.toolTip = git.files.root.path
        start.setAccessibilityLabel("起点分支"); branch.setAccessibilityLabel("新分支"); branch.delegate = self
        branch.outlined = true; branch.heightAnchor.constraint(equalToConstant: 32).isActive = true
        for control in [start, branch] { control.font = .systemFont(ofSize: 13); control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        start.cell?.lineBreakMode = .byTruncatingMiddle
        start.target = self; start.action = #selector(changeOption(_:)); include.target = self; include.action = #selector(changeOption(_:))
        include.toolTip = "忽略文件不带入"
        preview.target = self; preview.action = #selector(previewCreation); create.target = self; create.action = #selector(confirm)
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText; state.isSelectable = true; state.maximumNumberOfLines = 0; diff.text.setAccessibilityLabel("待带入修改")
        diff.isHidden = true
        include.font = .systemFont(ofSize: 13); include.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let labels = [NSTextField(labelWithString: "起点分支"), NSTextField(labelWithString: "新分支")]; for label in labels { label.font = .systemFont(ofSize: 13) }
        let options = NSGridView(views: [[labels[0], startFrame], [labels[1], branch]])
        options.rowSpacing = 10; options.columnSpacing = 12; options.column(at: 0).xPlacement = .trailing; options.column(at: 1).xPlacement = .fill
        options.column(at: 0).width = 72
        sourceOptions.orientation = .vertical; sourceOptions.alignment = .leading; sourceOptions.spacing = 10
        sourceOptions.addArrangedSubview(options); options.widthAnchor.constraint(equalTo: sourceOptions.widthAnchor).isActive = true
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; optionsScroll.documentView = document; optionsScroll.hasVerticalScroller = true; optionsScroll.drawsBackground = false; optionsScroll.identifier = .init("form-input"); optionsScroll.setAccessibilityLabel("各源起点配置")
        optionsScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollChanged(_:)), name: NSView.boundsDidChangeNotification, object: optionsScroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(branchSelectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        document.addSubview(sourceOptions); sourceOptions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: optionsScroll.contentView.widthAnchor), sourceOptions.leadingAnchor.constraint(equalTo: document.leadingAnchor), sourceOptions.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12), sourceOptions.topAnchor.constraint(equalTo: document.topAnchor, constant: 2), sourceOptions.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2), optionsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 52), optionsScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 150)])
        let preferred = optionsScroll.heightAnchor.constraint(equalToConstant: CGFloat(min(148, 84 + 40 * max(0, (store.task(taskID)?.workspacePaths.count ?? 1) - 1))))
        // Let the source list scroll before the form grows the workbench window.
        preferred.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        preferred.isActive = true
        AgentDialogStyle.action(preview); AgentDialogStyle.action(create, prominent: true)
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
                let sources = try git.worktreeDraftSources(resumeTaskID: resumeTaskID)
                let values = try await git.workspaceWorktreeStartingPoints()
                try Task.checkCancellation()
                let current = try git.worktreeDraftSources(resumeTaskID: resumeTaskID)
                guard values.map(\.root) == sources.map(\.root), sources == current,
                      loadingDraft?.sources == nil || loadingDraft?.sources == sources else {
                    throw PetError("源文件夹或仓库已变化，请重新打开创建配置")
                }
                sourceRoots = values.map(\.root)
                for (index, value) in values.enumerated() {
                    let popup = index == 0 ? start : NSPopUpButton()
                    popup.menu?.autoenablesItems = false
                    for point in value.points {
                        let scope = point.ref == "HEAD" ? "" : point.ref.hasPrefix("refs/heads/") ? "本地 · " : "远程 · "
                        let item = NSMenuItem(title: scope + point.title, action: nil, keyEquivalent: "")
                        item.representedObject = point.ref; item.toolTip = point.ref; popup.menu?.addItem(item)
                    }
                    popup.target = self; popup.action = #selector(changeOption(_:)); popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); popup.cell?.lineBreakMode = .byTruncatingMiddle
                    let original = setup?.startPoints[value.root] ?? "HEAD"
                    originalStarts[value.root] = original
                    let selected = loadingDraft?.startPoints[value.root] ?? original
                    if let item = popup.itemArray.first(where: { $0.representedObject as? String == selected }) { popup.select(item) }
                    else {
                        let unavailable = NSMenuItem(title: "已不可用 · " + selected, action: nil, keyEquivalent: "")
                        unavailable.representedObject = selected; unavailable.tag = -1; unavailable.isEnabled = false
                        popup.menu?.addItem(unavailable); popup.select(unavailable)
                    }
                    sourceStarts[value.root] = popup
                    if index > 0 {
                        popup.setAccessibilityLabel("起点分支 · " + value.root)
                        let label = NSTextField(labelWithString: URL(fileURLWithPath: value.root).lastPathComponent); label.font = .systemFont(ofSize: 13); label.toolTip = value.root; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                        let frame = AgentSettingsPopupFrame(popup, outlined: true, maximumWidth: nil); sourceFrames.append(frame)
                        let row = NSStackView(views: [label, frame]); row.spacing = 12; row.alignment = .centerY; frame.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.65).isActive = true
                        sourceOptions.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: sourceOptions.widthAnchor).isActive = true
                    }
                }
                draftSources = sources; loadingDraft = nil; refreshRetainedRoots()
                include.title = values.count > 1 ? "带入待创建源的当前修改" : "带入当前修改"
                updateInputStatus()
                if restoredForm, !hasUnavailableStart { state.stringValue = "请重新预览" }
            }
            catch { if !Task.isCancelled { showFailure(error.localizedDescription, title: "源文件夹不可用") } }
            setBusy(false); requestViewportRestore()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var boundTaskID: String { resumeTaskID ?? taskID }
    func usesTask(_ ids: Set<String>) -> Bool { ids.contains(taskID) || ids.contains(boundTaskID) }
    private var liveBranch: String { (branch.currentEditor() as? NSTextView)?.string ?? branch.stringValue }
    private var selectedStart: String? { start.selectedItem?.representedObject as? String }
    private var selectedStarts: [String: String] { sourceStarts.compactMapValues { $0.selectedItem?.representedObject as? String } }
    private var hasUnavailableStart: Bool { sourceStarts.contains { !retainedRoots.contains($0.key) && $0.value.selectedItem?.tag == -1 } }
    private func refreshRetainedRoots() { retainedRoots = Set(resumeTaskID.flatMap { store.task($0)?.managedWorktreeOrigins.map(\.root) } ?? []); create.title = resumeTaskID == nil ? "创建任务" : "继续创建" }
    var hasDraft: Bool { !completed && (restoredForm || liveBranch != originalBranch || (include.state == .on) != originalInclude || selectedStarts != originalStarts || review != nil) }
    var hasPendingChanges: Bool { busy || hasDraft }
    var canPreserveForQuit: Bool { !busy && captureDraft() != nil }
    func captureDraft() -> Draft? {
        guard hasDraft else { return nil }
        if let loadingDraft { return loadingDraft }
        let name = liveBranch
        guard !draftSources.isEmpty, name.utf8.count <= 65_536, !name.contains("\0") else { return nil }
        rememberViewport()
        return Draft(sourceTaskID: taskID, resumeTaskID: resumeTaskID, sources: draftSources, branch: name,
                     startPoints: selectedStarts, includeChanges: include.state == .on, focus: focus,
                     branchSelection: branchSelection.flatMap { $0.valid(in: name.utf16.count) ? $0 : nil }, scroll: scroll)
    }
    private func rememberViewport() {
        guard !restoreViewportPending, !busy, isPageVisible else { return }
        scroll = max(0, Double(optionsScroll.contentView.bounds.minY))
        guard let responder = presentingWindow?.firstResponder else { return }
        if let editor = branch.currentEditor() as? NSTextView, responder === editor {
            let range = editor.selectedRange()
            branchSelection = .init(location: range.location, length: range.length); focus = "branch"
        } else if responder === include { focus = "include" }
        else if let root = sourceStarts.first(where: { $0.value === responder })?.key { focus = root }
    }
    private func requestViewportRestore() {
        guard restoreViewportPending, !busy else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, restoreViewportPending, !busy, isPageVisible, let host = presentingWindow, !host.hasBlockingDialog else { return }
            let target: NSControl? = focus == "branch" ? branch : focus == "include" ? include : focus.flatMap { self.sourceStarts[$0] }
            if let target, target.isEnabled { host.makeFirstResponder(target) }
            if focus == "branch", let editor = branch.currentEditor() as? NSTextView,
               let branchSelection, branchSelection.valid(in: editor.string.utf16.count) { editor.setSelectedRange(branchSelection.range) }
            content.layoutSubtreeIfNeeded()
            let clip = optionsScroll.contentView
            var viewport = clip.bounds; viewport.origin.y = scroll
            clip.scroll(to: clip.constrainBoundsRect(viewport).origin); optionsScroll.reflectScrolledClipView(clip)
            restoreViewportPending = false
        }
    }
    @objc private func scrollChanged(_ notification: Notification) {
        guard !busy, !restoreViewportPending, isPageVisible else { return }
        rememberViewport(); if hasDraft { onDraftChange?() }
    }
    @objc private func branchSelectionChanged(_ notification: Notification) {
        guard !restoreViewportPending, let editor = notification.object as? NSTextView,
              editor === branch.currentEditor(), editor === presentingWindow?.firstResponder else { return }
        rememberViewport(); if hasDraft { onDraftChange?() }
    }
    func prepareWorkspaceNavigation() -> Bool { rememberViewport(); return !busy }
    override func settingsDidAppear() {
        super.settingsDidAppear(); restoreViewportPending = true; requestViewportRestore()
    }
    override func settingsWillLeave() {
        job?.cancel(); git.cancel(); busy = false
        onLeave?(); onLeave = nil; onDraftChange = nil
    }
    func windowWillClose(_ notification: Notification) { settingsWillLeave() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !busy else { return false }
        guard hasPendingChanges else { return true }
        return AgentUnsavedChanges.discard("放弃工作树创建配置？", detail: liveBranch, discardTitle: "放弃配置", owner: presentingWindow)
    }
    func controlTextDidChange(_ obj: Notification) { changed() }
    @objc private func changeOption(_ sender: NSControl) { changed(focused: sender) }
    private func changed(focused sender: NSControl? = nil) {
        restoredForm = false; rememberViewport()
        if sender === include { focus = "include" }
        else if let sender, let root = sourceStarts.first(where: { $0.value === sender })?.key { focus = root }
        review = nil; create.isEnabled = false
        preview.isEnabled = !busy && selectedStart != nil && !hasUnavailableStart
        updateInputStatus(); onDraftChange?()
    }
    private func updateInputStatus() {
        state.stringValue = ""; state.toolTip = nil
        diff.show("", oldTitle: "起点", newTitle: "当前修改"); diff.isHidden = true
        if hasUnavailableStart {
            state.stringValue = "起点分支已不可用，请重新选择"; state.textColor = AgentDialogStyle.error
        }
    }
    private func setBusy(_ value: Bool) {
        let hasStart = selectedStart != nil
        busy = value; start.isEnabled = !value && hasStart; branch.isEnabled = !value && hasStart && resumeTaskID == nil; include.isEnabled = !value && hasStart
        if value { state.textColor = AgentWorkbenchTheme.secondaryText; state.toolTip = nil }
        for (root, popup) in sourceStarts { popup.isEnabled = !value && !retainedRoots.contains(root) }
        preview.isEnabled = !value && hasStart && !hasUnavailableStart; create.isEnabled = !value && review != nil
        for frame in [startFrame] + sourceFrames { frame.refreshEnabledState() }
    }
    private func showFailure(_ message: String, title: String) {
        state.stringValue = title; state.textColor = AgentDialogStyle.error; state.toolTip = message
        diff.show(message, oldTitle: "工作树", newTitle: "错误详情"); diff.isHidden = false
    }
    private func checkTask() throws {
        guard let task = store.task(taskID), !task.archived, ![.running, .waiting].contains(task.status) else { throw PetError("来源任务正在执行或已归档，请稍后重试") }
        guard try git.worktreeDraftSources(resumeTaskID: resumeTaskID) == draftSources else {
            throw PetError("源文件夹、仓库或分支已变化，请回到原来源后重新预览")
        }
    }
    private func matchesInputs(_ value: AgentWorktreeCreationReview) -> Bool {
        guard value.branch == branch.stringValue, value.startPoint == selectedStart, value.includeChanges == (include.state == .on) else { return false }
        return value.sources?.allSatisfy { selectedStarts[$0.root] == $0.startPoint } ?? true
    }
    @objc private func previewCreation() {
        guard !busy, !hasUnavailableStart, let base = selectedStart else { return }
        rememberViewport()
        branch.validateEditing()
        let name = branch.stringValue, carry = include.state == .on, starts = selectedStarts
        review = nil; setBusy(true); state.stringValue = "正在预览…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                try checkTask(); let value = try await git.prepareWorktreeCreation(branch: name, startPoint: base, includeChanges: carry, sourceStartPoints: starts, resumeTaskID: resumeTaskID)
                try Task.checkCancellation()
                guard selectedStarts == starts, matchesInputs(value) else { throw PetError("创建选项已变化，请重新预览") }
                review = value
                if let sources = value.sources {
                    state.stringValue = "\(sources.count) 个待创建源 · 已保留 \(value.retained?.count ?? 0) 个 · \(value.paths.count) 个文件"
                } else {
                    let commit = "起点 " + String(value.baseCommit.prefix(12))
                    state.stringValue = value.includeChanges ? "\(commit) · 将带入 \(value.paths.count) 个文件 · 保持未暂存" : commit
                }
                diff.show(value.patch, oldTitle: "所选起点", newTitle: "新工作树"); diff.isHidden = value.patch.isEmpty
            } catch { showFailure(error.localizedDescription, title: "预览失败"); review = nil }
            setBusy(false); onDraftChange?()
        }
    }
    @objc private func confirm() {
        guard !busy, let review else { return }
        branch.validateEditing()
        guard matchesInputs(review) else {
            self.review = nil; showFailure("创建选项已变化，请重新预览", title: "预览已失效"); setBusy(false); return
        }
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
                showFailure(message, title: resumeTaskID == nil ? "工作树创建失败" : "已保留未完成的工作树"); self.review = nil; setBusy(false); onDraftChange?()
            }
        }
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let frames = [start, branch, include, preview, create].map { content.convert($0.bounds, from: $0) }
        func frame(_ view: NSView) -> [CGFloat] { let r = content.convert(view.bounds, from: view); return [r.minX, r.minY, r.width, r.height] }
        return ["taskID": taskID, "resumeTaskID": resumeTaskID ?? "", "sources": sourceRoots, "sourceStartPoints": selectedStarts, "retainedRoots": retainedRoots.sorted(), "branch": branch.stringValue, "startPoint": selectedStart ?? "", "includeChanges": include.state == .on, "reviewHash": review?.hash ?? "", "patch": diff.patch, "state": state.stringValue, "stateIsError": state.textColor == AgentDialogStyle.error, "busy": busy, "hasPendingChanges": hasPendingChanges, "createEnabled": create.isEnabled, "inputFrames": [frame(startFrame), frame(branch)], "actionFrames": [frame(preview), frame(create)], "diffFrame": frame(diff),
                "sourceViewport": [optionsScroll.contentView.bounds.height, optionsScroll.documentView?.bounds.height ?? 0],
                "checks": ["creationUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow, "creationHasNoFloatingWindow": window?.isVisible != true, "creationControlsFit": frames.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains($0) }, "creationPreviewHasUsableHeight": diff.bounds.height >= 120]]
    }
    func checkWorkspace(branch name: String? = nil, startPoint: String? = nil, includeChanges: Bool? = nil, action: String = "") async {
        guard AgentTaskWorkspace.readbackEnabled else { return }; await job?.value
        if let name { branch.stringValue = name; changed() }
        if let startPoint, let item = start.itemArray.first(where: { $0.representedObject as? String == startPoint }) { start.select(item); changed() }
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
            $0.inheritedLimits = source.inheritedLimits
            $0.agent = source.agent; $0.agent?.workspace = target.workspace; $0.team = source.team
        }
        if let error = writeError { throw PetError("新任务草稿未保存，原草稿仍保留：" + error) }
    }
}
