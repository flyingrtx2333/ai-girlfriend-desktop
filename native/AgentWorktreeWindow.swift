import AppKit

@MainActor final class AgentWorktreeWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let git: AgentGit, store: AgentStore, onSelectTask: (String) -> Void
    private let table = NSTableView(), detail = NSTextView(), state = AgentSettingsStatusField("工作树状态")
    private let heading = NSTextField(labelWithString: "")
    private let scope = NSSegmentedControl(labels: ["工作树", "回收记录"], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = AgentDialogButton(title: "刷新", target: nil, action: nil), openButton = AgentDialogButton(title: "打开任务", target: nil, action: nil)
    private let revealButton = AgentDialogButton(title: "在访达中显示", target: nil, action: nil), recycleButton = AgentDialogButton(title: "回收…", target: nil, action: nil), restoreButton = AgentDialogButton(title: "恢复…", target: nil, action: nil)
    private let cancelButton = AgentDialogButton(title: "取消", target: nil, action: nil), relinkButton = AgentDialogButton(title: "重新关联…", target: nil, action: nil)
    private var recycleReview: AgentWorktreeRecycleReview?, restoreReviewID: String?
    private var relinkReview: AgentWorktreeRelinkReview?
    private var entries: [AgentWorktreeEntry] = [], backups: [AgentWorktreeBackup] = [], job: Task<Void, Never>?
    private let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface), list = NSScrollView(), viewer = NSScrollView()
    private enum Layout: Hashable { case split, stacked, review }
    private struct BrowsingPosition {
        let detail: AgentTextViewport?, listOrigin: NSPoint
        let status: String, statusColor: NSColor?
    }
    private var layouts: [Layout: [NSLayoutConstraint]] = [:]
    private var layout: Layout?, listHeight: NSLayoutConstraint!
    private var browsingPosition: BrowsingPosition?
    private var selectedEntryPath: String?, selectedBackupID: String?
    private let activityOwner = UUID()
    private var busy = false { didSet { if busy != oldValue { store.worktreeRetention.setNativeOperation(activityOwner, taskID: git.taskID, busy: busy) } } }
    init(store: AgentStore, taskID: String, allowsArchivedSource: Bool = false, workspace: String? = nil, onSelectTask: @escaping (String) -> Void) throws {
        self.store = store; self.onSelectTask = onSelectTask
        git = try AgentGit(store: store, taskID: taskID, directory: AgentGit.metadata(workspace: workspace ?? store.task(taskID)?.workspace), allowsArchivedWorktreeSource: allowsArchivedSource, workspace: workspace, allowsExternalWorktrees: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "工作树 · " + git.files.root.lastPathComponent; window.minSize = NSSize(width: 640, height: 400); window.isReleasedWhenClosed = false
        window.center(); super.init(window: window); window.delegate = self
        window.contentView = content
        heading.stringValue = git.files.root.lastPathComponent
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.toolTip = git.files.root.path
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("worktree")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 56; table.style = .plain; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("项目工作树")
        list.documentView = table; list.hasVerticalScroller = true; table.backgroundColor = .clear
        detail.isEditable = false; detail.isSelectable = true; detail.font = .systemFont(ofSize: 13)
        detail.textContainerInset = NSSize(width: 0, height: 6); detail.textContainer?.lineFragmentPadding = 0
        detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true
        detail.isHorizontallyResizable = false; detail.isVerticallyResizable = true
        detail.setAccessibilityLabel("工作树详情")
        viewer.documentView = detail; viewer.hasVerticalScroller = true; detail.drawsBackground = false
        for scroll in [list, viewer] { scroll.drawsBackground = false; scroll.scrollerStyle = .overlay }
        scope.selectedSegment = 0; scope.target = self; scope.action = #selector(changeScope)
        scope.controlSize = .regular; scope.font = .systemFont(ofSize: 13); scope.segmentStyle = .roundRect; scope.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for button in [refreshButton, openButton, revealButton, recycleButton, restoreButton, cancelButton, relinkButton] {
            button.target = self; AgentDialogStyle.action(button, prominent: button === restoreButton || button === relinkButton)
        }
        recycleButton.hasDestructiveAction = true
        refreshButton.action = #selector(refresh); openButton.action = #selector(openTask); revealButton.action = #selector(reveal); recycleButton.action = #selector(recycle); restoreButton.action = #selector(restore)
        cancelButton.action = #selector(cancelReview)
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        relinkButton.action = #selector(relink)
        state.font = .systemFont(ofSize: 12)
        let header = NSStackView(views: [heading, NSView(), scope, refreshButton]); header.spacing = 10
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [openButton, revealButton, NSView(), cancelButton, relinkButton, recycleButton, restoreButton]); actions.spacing = 8
        let footer = NSStackView(views: [actions, state]); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 8
        for row in footer.arrangedSubviews { row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }
        for view in [header, list, viewer, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), viewer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        listHeight = list.heightAnchor.constraint(equalToConstant: 140)
        layouts = [
            .split: [list.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.4),
                list.bottomAnchor.constraint(equalTo: viewer.bottomAnchor), viewer.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 16),
                viewer.topAnchor.constraint(equalTo: list.topAnchor)],
            .stacked: [list.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), listHeight,
                viewer.leadingAnchor.constraint(equalTo: list.leadingAnchor), viewer.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 10)],
            .review: [list.widthAnchor.constraint(equalToConstant: 0), list.heightAnchor.constraint(equalToConstant: 0),
                viewer.leadingAnchor.constraint(equalTo: list.leadingAnchor), viewer.topAnchor.constraint(equalTo: list.topAnchor)]
        ]
        content.onResize = { [weak self] in self?.pageDidLayout() }; pageDidLayout(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var boundTaskID: String { git.taskID }
    var hasPendingOperation: Bool { busy }
    func prepareWorkspaceNavigation() -> Bool { !busy }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    override func settingsWillLeave() {
        job?.cancel(); git.cancel(); busy = false
        recycleReview = nil; restoreReviewID = nil; relinkReview = nil; browsingPosition = nil
    }
    func windowWillClose(_ notification: Notification) { settingsWillLeave() }
    override func pageDidLayout() {
        let next: Layout = reviewing ? .review : content.bounds.width < 700 ? .stacked : .split
        if next != layout {
            if let layout { NSLayoutConstraint.deactivate(layouts[layout] ?? []) }
            layout = next
            NSLayoutConstraint.activate(layouts[next] ?? [])
        }
        listHeight?.constant = min(165, max(110, content.bounds.height * 0.28))
    }
    private var showingBackups: Bool { scope.selectedSegment == 1 }
    func numberOfRows(in tableView: NSTableView) -> Int { showingBackups ? backups.count : entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let name: String, path: String
        if showingBackups {
            guard backups.indices.contains(row) else { return nil }; let item = backups[row]
            let kind = item.registration == nil ? "" : " · Git 登记"
            name = (item.branch.map { $0.replacingOccurrences(of: "refs/heads/", with: "") } ?? "分离状态") + kind + " · " + backupState(item); path = item.origin.path
        } else {
            guard entries.indices.contains(row) else { return nil }; let item = entries[row]
            let status = item.unavailable ?? (item.canRelink == true ? "原目录缺失" : item.owned ? nil : "外部工作树")
            name = (item.branch.map { $0.replacingOccurrences(of: "refs/heads/", with: "") } ?? (item.bare ? "裸仓库" : "分离状态")) + (status.map { " · " + $0 } ?? "")
            path = item.path
        }
        let cell = NSTableCellView(), first = NSTextField(labelWithString: name), second = NSTextField(labelWithString: path.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "↵"))
        first.font = .systemFont(ofSize: 13, weight: .medium); second.font = .systemFont(ofSize: 11.5); second.textColor = AgentWorkbenchTheme.secondaryText
        for label in [first, second] { label.lineBreakMode = .byTruncatingMiddle; label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); label.toolTip = path }
        cell.textField = first
        NSLayoutConstraint.activate([first.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), first.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), first.topAnchor.constraint(equalTo: cell.topAnchor, constant: 9), second.leadingAnchor.constraint(equalTo: first.leadingAnchor), second.trailingAnchor.constraint(equalTo: first.trailingAnchor), second.topAnchor.constraint(equalTo: first.bottomAnchor, constant: 4)])
        return cell
    }
    private func backupState(_ item: AgentWorktreeBackup) -> String {
        if git.canResumeWorktreeRecycle(item) { return "回收待继续" }
        return ["prepared": "备份已保留", "recycled": "已回收", "restoring": "恢复待核对", "restored": "已恢复"][item.state] ?? item.state
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if let entry { selectedEntryPath = entry.path }; if let backup { selectedBackupID = backup.id }; showSelection()
    }
    private var entry: AgentWorktreeEntry? { !showingBackups && entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil }
    private var backup: AgentWorktreeBackup? { showingBackups && backups.indices.contains(table.selectedRow) ? backups[table.selectedRow] : nil }
    private var reviewing: Bool { recycleReview != nil || restoreReviewID != nil || relinkReview != nil }
    private func showSelection() {
        let enteringReview = reviewing && layout != .review
        if !reviewing && !busy { browsingPosition = nil }
        let ids = entry?.taskIDs ?? backup.map { Array($0.tasks.keys).sorted() } ?? []
        var title = git.files.root.lastPathComponent
        var note = ""
        var fields: [(String, String)] = []
        if let review = relinkReview {
            title = "重新关联工作树"
            fields = [("新目录", review.destination), ("原目录", review.source), ("分支", branchName(review.branch)),
                      ("关联任务", taskNames(review.versions.keys.sorted()))]
        } else if let review = recycleReview {
            title = review.registration != nil ? "清理工作树登记" : review.external == nil ? "回收工作树" : "回收外部工作树"
            note = review.registration != nil ? "只清理这条 Git 登记。可从回收记录恢复登记和暂存区。若目录已移动，可取消后选择重新关联。" :
                "备份包括忽略文件和暂存状态。回收后移除原目录，保留分支，并归档关联任务。"
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: review.bytes), countStyle: .file)
            fields = [("原目录", review.path), ("分支", branchName(review.branch)), ("提交", review.head),
                      ("备份", "\(review.files) 项 · " + size), ("关联任务", taskNames(review.taskIDs))]
        } else if let item = entry {
            let status = item.unavailable ?? (item.missingRegistration == true ? "原目录缺失 · 可清理 Git 登记" : item.owned ? "可回收" : "外部工作树 · 可手动备份回收")
            fields = [("分支", branchName(item.branch)), ("目录", item.path), ("提交", item.head ?? ""), ("状态", status),
                      ("锁定", item.locked.map { $0.isEmpty ? "已锁定" : $0 } ?? ""), ("关联任务", taskNames(ids))]
        } else if let item = backup {
            let receipt = backupState(item) + " · " + item.created.formatted(date: .numeric, time: .shortened)
            fields = [("原目录", item.origin.path), ("分支", branchName(item.restoredBranch ?? item.branch)), ("关联任务", taskNames(ids)),
                      ("提交", item.head), ("备份记录", receipt)]
            if restoreReviewID != nil {
                if git.canResumeWorktreeRecycle(item) {
                    title = "继续回收工作树"; note = "核对备份和原目录，完成回收并归档关联任务。发现新改动时会暂停。"
                } else if item.registration != nil {
                    title = "恢复工作树登记"; note = "恢复原 Git 登记和暂存状态。若原目录仍缺失，可接回原目录或使用 Git 重新关联。"
                } else if item.state == "restoring" {
                    title = "继续恢复工作树"; note = "核对现有文件和暂存状态，补齐缺失内容。若有变化，会停下来请你先处理。"
                } else {
                    title = "恢复工作树"; note = "将文件、暂存状态与关联任务恢复到原位置。原分支已变化或被占用时创建 recovered 分支。"
                }
            }
        } else { note = showingBackups ? "暂无回收记录" : "暂无工作树" }
        heading.stringValue = title
        renderDetails(fields, note: note)
        list.isHidden = reviewing; refreshButton.isHidden = reviewing; scope.isHidden = reviewing; openButton.isHidden = reviewing
        table.isEnabled = !busy && !reviewing; refreshButton.isEnabled = !busy && !reviewing; scope.isEnabled = !busy && !reviewing
        openButton.isEnabled = !busy && !reviewing && ids.contains { store.task($0)?.archived == false }
        revealButton.isEnabled = !busy && (backup != nil || entry.map { $0.canRelink != true } == true)
        recycleButton.isHidden = showingBackups || relinkReview != nil; restoreButton.isHidden = !showingBackups
        relinkButton.isHidden = entry?.canRelink != true || recycleReview != nil
        relinkButton.isEnabled = !busy && !relinkButton.isHidden
        relinkButton.title = relinkReview == nil ? "重新关联…" : "确认关联目录"
        cancelButton.isHidden = !reviewing; cancelButton.isEnabled = !busy
        recycleButton.title = entry?.missingRegistration == true ? (recycleReview == nil ? "清理登记…" : "备份并清理登记") : (recycleReview == nil ? "回收…" : "备份并回收")
        let resumingRecycle = backup.map(git.canResumeWorktreeRecycle) == true
        if resumingRecycle { restoreButton.title = restoreReviewID == nil ? "继续回收…" : "继续回收" }
        else if backup?.state == "restoring" { restoreButton.title = restoreReviewID == nil ? "继续恢复…" : "继续恢复" }
        else { restoreButton.title = restoreReviewID == nil ? "恢复…" : backup?.registration != nil ? "恢复登记" : "恢复工作树" }
        restoreButton.hasDestructiveAction = resumingRecycle
        recycleButton.isEnabled = !busy && entry?.unavailable == nil && entry != nil
        restoreButton.isEnabled = !busy && (resumingRecycle || backup?.canRestore == true)
        pageDidLayout()
        if enteringReview { detail.window?.makeFirstResponder(detail) }
    }
    private func branchName(_ branch: String?) -> String {
        branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "分离状态"
    }
    private func taskNames(_ ids: [String]) -> String {
        ids.compactMap { store.task($0) }.map { $0.title + " · " + ($0.archived ? "已归档" : $0.status.title) }.joined(separator: "\n")
    }
    private func renderDetails(_ fields: [(String, String)], note: String) {
        let text = NSMutableAttributedString(string: "")
        func append(_ value: String, font: NSFont, color: NSColor, spacing: CGFloat, wrap: NSLineBreakMode) {
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = spacing; paragraph.lineBreakMode = wrap
            text.append(NSAttributedString(string: value + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        if !note.isEmpty { append(note, font: .systemFont(ofSize: 13), color: .labelColor, spacing: 12, wrap: .byWordWrapping) }
        for (label, value) in fields where !value.isEmpty {
            append(label, font: .systemFont(ofSize: 11, weight: .medium), color: AgentWorkbenchTheme.secondaryText, spacing: 3, wrap: .byWordWrapping)
            append(value, font: .systemFont(ofSize: 13), color: .labelColor, spacing: 10, wrap: .byCharWrapping)
        }
        guard let storage = detail.textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        detail.setSelectedRange(NSRange(location: 0, length: 0))
        viewer.contentView.scroll(to: .zero); viewer.reflectScrolledClipView(viewer.contentView)
    }
    private func setBusy(_ value: Bool) { busy = value; if value { state.textColor = AgentWorkbenchTheme.secondaryText }; showSelection() }
    private func showError(_ error: Error) { state.stringValue = error.localizedDescription; state.textColor = AgentDialogStyle.error }
    private func rememberBrowsingPosition() {
        content.layoutSubtreeIfNeeded()
        browsingPosition = BrowsingPosition(detail: try? AgentTextViewport(detail), listOrigin: list.contentView.bounds.origin,
                                            status: state.stringValue, statusColor: state.textColor)
    }
    @objc private func cancelReview() {
        guard !busy, reviewing else { return }
        let position = browsingPosition
        recycleReview = nil; restoreReviewID = nil; relinkReview = nil
        state.stringValue = position?.status ?? ""; state.textColor = position?.statusColor ?? AgentWorkbenchTheme.secondaryText
        showSelection()
        content.layoutSubtreeIfNeeded()
        if let position {
            list.contentView.scroll(to: position.listOrigin); list.reflectScrolledClipView(list.contentView)
            if position.detail?.focused != true { table.window?.makeFirstResponder(table) }
            position.detail?.apply(to: detail)
        }
    }
    private func reloadRows() {
        let row = showingBackups ? backups.firstIndex { $0.id == selectedBackupID } : entries.firstIndex { $0.path == selectedEntryPath }
        table.reloadData(); if numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: row ?? 0), byExtendingSelection: false) }; showSelection()
    }
    @objc private func changeScope() { reloadRows() }
    @objc func refresh() {
        guard !busy, !reviewing else { return }; setBusy(true); state.stringValue = "读取工作树…"
        job = Task { [weak self] in
            guard let self else { return }
            do { entries = try await git.worktrees(); backups = try git.worktreeBackups(); reloadRows(); state.stringValue = "\(entries.count) 个工作树 · \(backups.count) 条回收记录" }
            catch { entries = []; backups = []; table.reloadData(); showError(error) }
            setBusy(false)
        }
    }
    @objc private func openTask() {
        let ids = entry?.taskIDs ?? backup.map { Array($0.tasks.keys).sorted() } ?? []
        if let id = ids.first(where: { store.task($0)?.archived == false }) { onSelectTask(id) }
    }
    @objc private func reveal() {
        let path = entry?.path ?? backup.map { item in
            if let held = git.heldWorktreeRecyclePath(item) { return held }
            if item.registration == nil { return store.directory.appendingPathComponent("worktrees/" + item.id + "/files").path }
            if item.state == "restored" { return store.directory.appendingPathComponent("worktrees/" + item.id + "/record.json").path }
            return git.worktreeRegistrationBackupURL(item.id).path
        }
        if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    @objc private func relink() {
        guard !busy, let item = entry, item.canRelink == true else { return }
        if let review = relinkReview {
            setBusy(true); state.stringValue = "重新关联 Git 登记…"
            job = Task { [weak self] in
                guard let self else { return }
                defer { relinkReview = nil; setBusy(false) }
                do {
                    try await git.relinkWorktree(review)
                    selectedEntryPath = review.destination; entries = try await git.worktrees(); reloadRows()
                    state.stringValue = "已重新关联 · " + URL(fileURLWithPath: review.destination).lastPathComponent
                } catch { showError(error) }
            }
            return
        }
        guard !reviewing, let window = presentingWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.resolvesAliases = false; panel.prompt = "审阅目录"
        let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: parent.path) ? parent : git.files.root
        rememberBrowsingPosition()
        setBusy(true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url { previewRelink(from: item.path, to: url.standardizedFileURL.path) }
            else { setBusy(false) }
        }
    }
    private func previewRelink(from old: String, to destination: String) {
        if browsingPosition == nil { rememberBrowsingPosition() }
        setBusy(true); state.stringValue = "核对工作树链接…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let review = try await git.prepareWorktreeRelink(from: old, to: destination)
                try Task.checkCancellation(); relinkReview = review; state.stringValue = ""
            } catch { showError(error) }
            setBusy(false)
        }
    }
    @objc private func recycle() {
        guard !busy, let item = entry, item.unavailable == nil else { return }
        if let review = recycleReview {
            setBusy(true)
            job = Task { [weak self] in
                guard let self else { return }
                defer { recycleReview = nil; setBusy(false) }
                do { try await recycleReviewed(review) }
                catch {
                    if let current = try? await git.worktrees(), let saved = try? git.worktreeBackups() { entries = current; backups = saved; reloadRows() }
                    showError(error)
                }
            }; return
        }
        rememberBrowsingPosition()
        setBusy(true); state.stringValue = item.missingRegistration == true ? "检查 Git 登记…" : "检查文件与暂存状态…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let review = try await (item.missingRegistration == true ? git.prepareMissingWorktreeRecycle(path: item.path) : git.prepareWorktreeRecycle(path: item.path))
                try Task.checkCancellation()
                recycleReview = review; state.stringValue = ""
            } catch { showError(error) }
            setBusy(false)
        }
    }
    private func recycleReviewed(_ review: AgentWorktreeRecycleReview) async throws {
        state.stringValue = review.registration != nil ? "备份并清理 Git 登记…" : "备份并回收工作树…"
        let result = try await (review.registration != nil ? git.recycleMissingWorktree(review) : git.recycleWorktree(reviewHash: review.hash)); selectedBackupID = result.id
        state.stringValue = "已回收 · " + (result.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "分离状态")
        entries = try await git.worktrees(); backups = try git.worktreeBackups(); reloadRows()
    }
    @objc private func restore() {
        guard !busy, let item = backup else { return }
        let resumingRecycle = git.canResumeWorktreeRecycle(item)
        guard resumingRecycle || item.canRestore else { return }
        guard restoreReviewID == item.id else {
            rememberBrowsingPosition()
            restoreReviewID = item.id; state.stringValue = ""; showSelection(); return
        }
        setBusy(true)
        state.stringValue = resumingRecycle ? "继续回收工作树…" : item.registration == nil ? "恢复工作树…" : "恢复 Git 登记…"
        job = Task { [weak self] in
            guard let self else { return }
            defer { restoreReviewID = nil; setBusy(false) }
            do {
                if resumingRecycle {
                    let result = try await git.resumeWorktreeRecycle(backupID: item.id)
                    state.stringValue = "已回收 · " + (result.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "分离状态")
                    entries = try await git.worktrees(); backups = try git.worktreeBackups(); reloadRows()
                } else { try await restoreReviewed(item.id) }
            }
            catch {
                if let saved = try? git.worktreeBackups() { backups = saved; reloadRows() }
                showError(error)
            }
        }
    }
    private func restoreReviewed(_ id: String) async throws {
        let result = try await git.restoreWorktree(backupID: id); selectedEntryPath = result.origin.path
        state.stringValue = (result.registration == nil ? "已恢复 · " : "已恢复登记 · ") + (result.restoredBranch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "分离状态")
        entries = try await git.worktrees(); backups = try git.worktreeBackups(); reloadRows()
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let controls = [scope, refreshButton, openButton, revealButton, recycleButton, restoreButton, cancelButton, relinkButton].filter { !$0.isHiddenOrHasHiddenAncestor }
        let listFrame = content.convert(list.bounds, from: list), detailFrame = content.convert(viewer.bounds, from: viewer)
        let usesCompact = layout == .stacked
        let layoutMatches: Bool
        switch layout {
        case .review:
            layoutMatches = list.isHidden && abs(detailFrame.minX - 16) < 1 && abs(detailFrame.maxX - content.bounds.width + 16) < 1
        case .stacked:
            layoutMatches = content.bounds.width < 700 && abs(listFrame.minX - detailFrame.minX) < 1 && abs(listFrame.width - detailFrame.width) < 1 && !listFrame.intersects(detailFrame)
        case .split:
            layoutMatches = content.bounds.width >= 700 && listFrame.maxX <= detailFrame.minX + 1
        case nil:
            layoutMatches = false
        }
        var checks = [
            "managerUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow,
            "managerHasNoFloatingWindow": window?.isVisible != true,
            "managerControlsFit": controls.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains(content.convert($0.bounds, from: $0)) },
            "managerListHasUsableSpace": reviewing ? list.isHidden : list.bounds.width >= 180 && list.bounds.height >= 100,
            "managerDetailHasUsableSpace": viewer.bounds.width >= 200 && viewer.bounds.height >= 80,
            "managerLayoutMatchesAvailableWidth": layoutMatches
        ]
        if reviewing {
            checks["reviewFreesListHeight"] = listFrame.height < 1 && detailFrame.height >= content.bounds.height - 132
            checks["reviewKeepsCancelAndDecisionReachable"] = controls.contains(cancelButton) &&
                [recycleButton, restoreButton, relinkButton].contains { controls.contains($0) && $0.isEnabled }
            checks["reviewKeepsFullTextSelectable"] = detail.isSelectable && !detail.isEditable && viewer.hasVerticalScroller
        }
        let controlFrames = controls.map { view in
            let rect = content.convert(view.bounds, from: view)
            return ["label": (view as? NSButton)?.title ?? "工作树范围", "frame": [rect.minX, rect.minY, rect.width, rect.height]] as [String: Any]
        }
        return ["taskID": git.taskID, "busy": busy, "scope": showingBackups ? "backups" : "worktrees", "selectedPath": entry?.path ?? "", "selectedBackupID": backup?.id ?? "", "detail": detail.string, "state": state.stringValue, "stateIsError": state.textColor == AgentDialogStyle.error, "controls": controlFrames, "stateFrame": NSStringFromRect(content.convert(state.bounds, from: state)), "rowHeight": table.rowHeight, "recycleEnabled": recycleButton.isEnabled, "restoreEnabled": restoreButton.isEnabled, "recycleReviewHash": recycleReview?.hash ?? "", "restoreReviewID": restoreReviewID ?? "", "selectionEnabled": table.isEnabled,
                "relinkEnabled": !relinkButton.isHidden && relinkButton.isEnabled, "relinkDestination": relinkReview?.destination ?? "",
                "entries": entries.map { ["path": $0.path, "branch": $0.branch ?? "", "owned": $0.owned, "unavailable": $0.unavailable ?? ""] as [String: Any] }, "backups": backups.map { ["id": $0.id, "state": $0.state, "path": $0.origin.path] }, "compact": usesCompact, "reviewing": reviewing, "heading": heading.stringValue,
                "contentSize": [content.bounds.width, content.bounds.height], "listFrame": NSStringFromRect(listFrame), "detailFrame": NSStringFromRect(detailFrame),
                "checks": checks]
    }
    func checkWorkspace(scope index: Int? = nil, path: String? = nil, backupID: String? = nil, action: String = "", relinkDestination: String? = nil) async {
        guard AgentTaskWorkspace.readbackEnabled else { return }; await job?.value
        if let index { scope.selectedSegment = index; changeScope() }
        if let path, let row = entries.firstIndex(where: { $0.path == path }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if let backupID, let row = backups.firstIndex(where: { $0.id == backupID }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if action == "refresh" { refresh(); await job?.value }
        if action == "open" { openTask() }
        if action == "cancel" { cancelReview() }
        if action == "prepare-recycle" { recycle(); await job?.value }
        if action == "recycle" {
            recycle(); await job?.value
            if recycleReview != nil { recycle(); await job?.value }
        }
        if action == "prepare-restore" { restore() }
        if let relinkDestination, let item = entry {
            previewRelink(from: item.path, to: relinkDestination); await job?.value
        }
        if action == "relink", relinkReview != nil { relink(); await job?.value }
        if action == "restore" {
            restore(); await job?.value
            if restoreReviewID != nil { restore(); await job?.value }
        }
    }
    func checkLayout() async -> [String: Bool] {
        while busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        var checks: [String: Bool] = [:]
        for size in [NSSize(width: 840, height: 520), NSSize(width: 640, height: 368)] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["worktreeManagerControlsFit\(Int(size.width))"] = [scope, refreshButton, openButton, revealButton, recycleButton].allSatisfy { view in
                guard let content = window?.contentView else { return false }; return content.bounds.insetBy(dx: -1, dy: -1).contains(view.convert(view.bounds, to: content))
            }
        }
        return checks
    }
}
