import AppKit

@MainActor final class AgentWorktreeWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let git: AgentGit, store: AgentStore, onSelectTask: (String) -> Void
    private let table = NSTableView(), detail = NSTextView(), state = NSTextField(labelWithString: "")
    private let scope = NSSegmentedControl(labels: ["工作树", "回收记录"], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil), openButton = NSButton(title: "打开任务", target: nil, action: nil)
    private let revealButton = NSButton(title: "在访达中显示", target: nil, action: nil), recycleButton = NSButton(title: "回收…", target: nil, action: nil), restoreButton = NSButton(title: "恢复…", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var recycleReview: AgentWorktreeRecycleReview?, restoreReviewID: String?
    private var entries: [AgentWorktreeEntry] = [], backups: [AgentWorktreeBackup] = [], job: Task<Void, Never>?
    private let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface), list = NSScrollView(), viewer = NSScrollView()
    private var wideConstraints: [NSLayoutConstraint] = [], compactConstraints: [NSLayoutConstraint] = [], listHeight: NSLayoutConstraint!, compact: Bool?
    private var selectedEntryPath: String?, selectedBackupID: String?
    private let activityOwner = UUID()
    private var busy = false { didSet { if busy != oldValue { store.worktreeRetention.setNativeOperation(activityOwner, taskID: git.taskID, busy: busy) } } }
    init(store: AgentStore, taskID: String, allowsArchivedSource: Bool = false, onSelectTask: @escaping (String) -> Void) throws {
        self.store = store; self.onSelectTask = onSelectTask
        git = try AgentGit(store: store, taskID: taskID, directory: AgentGit.metadata(workspace: store.task(taskID)?.workspace), allowsArchivedWorktreeSource: allowsArchivedSource)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "工作树 · " + git.files.root.lastPathComponent; window.minSize = NSSize(width: 640, height: 400); window.isReleasedWhenClosed = false
        window.center(); super.init(window: window); window.delegate = self
        window.contentView = content
        let title = NSTextField(labelWithString: git.files.root.lastPathComponent); title.font = .systemFont(ofSize: 15, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle; title.toolTip = git.files.root.path
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("worktree")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 55; table.style = .plain; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("项目工作树")
        list.documentView = table; list.hasVerticalScroller = true; table.backgroundColor = .clear
        detail.isEditable = false; detail.isSelectable = true; detail.font = .systemFont(ofSize: 12); detail.textContainerInset = NSSize(width: 14, height: 14); detail.setAccessibilityLabel("工作树详情")
        detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true
        viewer.documentView = detail; viewer.hasVerticalScroller = true; detail.isRichText = false; detail.drawsBackground = false; detail.textColor = .labelColor
        for scroll in [list, viewer] { scroll.drawsBackground = false; scroll.scrollerStyle = .overlay }
        scope.selectedSegment = 0; scope.target = self; scope.action = #selector(changeScope)
        for button in [refreshButton, openButton, revealButton, recycleButton, restoreButton, cancelButton] { button.target = self }
        refreshButton.action = #selector(refresh); openButton.action = #selector(openTask); revealButton.action = #selector(reveal); recycleButton.action = #selector(recycle); restoreButton.action = #selector(restore)
        cancelButton.action = #selector(cancelReview)
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingMiddle
        let header = NSStackView(views: [title, NSView(), scope, refreshButton]); header.spacing = 10
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [openButton, revealButton, NSView(), cancelButton, recycleButton, restoreButton]); actions.spacing = 8
        for view in [header, list, viewer, actions, state] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), viewer.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            state.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 10), state.leadingAnchor.constraint(equalTo: actions.leadingAnchor), state.trailingAnchor.constraint(equalTo: actions.trailingAnchor), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        wideConstraints = [list.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.4), list.bottomAnchor.constraint(equalTo: viewer.bottomAnchor), viewer.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), viewer.topAnchor.constraint(equalTo: list.topAnchor)]
        listHeight = list.heightAnchor.constraint(equalToConstant: 140)
        compactConstraints = [list.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), listHeight, viewer.leadingAnchor.constraint(equalTo: list.leadingAnchor), viewer.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 10)]
        content.onResize = { [weak self] in self?.pageDidLayout() }; pageDidLayout(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var boundTaskID: String { git.taskID }
    var hasPendingOperation: Bool { busy }
    func prepareWorkspaceNavigation() -> Bool { !busy }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    override func settingsWillLeave() { job?.cancel(); git.cancel(); busy = false; recycleReview = nil; restoreReviewID = nil }
    func windowWillClose(_ notification: Notification) { settingsWillLeave() }
    override func pageDidLayout() {
        let next = content.bounds.width < 700
        if next != compact { NSLayoutConstraint.deactivate(wideConstraints + compactConstraints); compact = next; NSLayoutConstraint.activate(next ? compactConstraints : wideConstraints) }
        listHeight?.constant = min(165, max(110, content.bounds.height * 0.28))
    }
    private var showingBackups: Bool { scope.selectedSegment == 1 }
    func numberOfRows(in tableView: NSTableView) -> Int { showingBackups ? backups.count : entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let name: String, path: String
        if showingBackups {
            guard backups.indices.contains(row) else { return nil }; let item = backups[row]
            name = (item.branch.map { $0.replacingOccurrences(of: "refs/heads/", with: "") } ?? "分离状态") + " · " + backupState(item.state); path = item.origin.path
        } else {
            guard entries.indices.contains(row) else { return nil }; let item = entries[row]
            name = (item.branch.map { $0.replacingOccurrences(of: "refs/heads/", with: "") } ?? (item.bare ? "裸仓库" : "分离状态")) + (item.unavailable.map { " · " + $0 } ?? "")
            path = item.path
        }
        let cell = NSTableCellView(), first = NSTextField(labelWithString: name), second = NSTextField(labelWithString: path.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "↵"))
        first.font = .systemFont(ofSize: 12, weight: .medium); second.font = .systemFont(ofSize: 10); second.textColor = AgentWorkbenchTheme.secondaryText
        for label in [first, second] { label.lineBreakMode = .byTruncatingMiddle; label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); label.toolTip = path }
        cell.textField = first
        NSLayoutConstraint.activate([first.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), first.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), first.topAnchor.constraint(equalTo: cell.topAnchor, constant: 9), second.leadingAnchor.constraint(equalTo: first.leadingAnchor), second.trailingAnchor.constraint(equalTo: first.trailingAnchor), second.topAnchor.constraint(equalTo: first.bottomAnchor, constant: 4)])
        return cell
    }
    private func backupState(_ value: String) -> String { ["prepared": "备份已保留", "recycled": "已回收", "restoring": "恢复待核对", "restored": "已恢复"][value] ?? value }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if let entry { selectedEntryPath = entry.path }; if let backup { selectedBackupID = backup.id }; showSelection()
    }
    private var entry: AgentWorktreeEntry? { !showingBackups && entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil }
    private var backup: AgentWorktreeBackup? { showingBackups && backups.indices.contains(table.selectedRow) ? backups[table.selectedRow] : nil }
    private var reviewing: Bool { recycleReview != nil || restoreReviewID != nil }
    private func showSelection() {
        let ids = entry?.taskIDs ?? backup.map { Array($0.tasks.keys).sorted() } ?? []
        if let review = recycleReview {
            detail.string = ["回收工作树", review.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "分离状态", review.path, "提交 " + String(review.head.prefix(12)), "备份 \(review.files) 项 · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: review.bytes), countStyle: .file), "包括忽略文件和暂存状态。分支保留，归档 \(review.taskIDs.count) 个关联任务。"].joined(separator: "\n\n")
        } else if let item = entry {
            detail.string = [item.branch ?? "分离状态", item.path, item.head.map { "提交 " + $0 } ?? "", item.locked.map { "锁定：" + ($0.isEmpty ? "已锁定" : $0) } ?? "", item.unavailable ?? "可回收", "\n关联任务", ids.compactMap { id in store.task(id).map { $0.title + " · " + ($0.archived ? "已归档" : $0.status.title) } }.joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n\n")
        } else if let item = backup {
            detail.string = [backupState(item.state), item.restoredBranch ?? item.branch ?? "分离状态", item.origin.path, "提交 " + item.head, item.created.formatted(date: .numeric, time: .shortened), "\n关联任务", ids.compactMap { store.task($0)?.title }.joined(separator: "\n")].joined(separator: "\n\n")
            if restoreReviewID != nil { detail.string += "\n\n恢复文件、暂存状态与关联任务。原分支已变化或被占用时创建 recovered 分支。" }
        } else { detail.string = showingBackups ? "暂无回收记录" : "暂无工作树" }
        table.isEnabled = !busy && !reviewing; refreshButton.isEnabled = !busy && !reviewing; scope.isEnabled = !busy && !reviewing
        openButton.isEnabled = !busy && !reviewing && ids.contains { store.task($0)?.archived == false }
        revealButton.isEnabled = !busy && (entry != nil || backup != nil)
        recycleButton.isHidden = showingBackups; restoreButton.isHidden = !showingBackups
        cancelButton.isHidden = !reviewing; cancelButton.isEnabled = !busy
        recycleButton.title = recycleReview == nil ? "回收…" : "备份并回收"; restoreButton.title = restoreReviewID == nil ? "恢复…" : "恢复工作树"
        recycleButton.isEnabled = !busy && entry?.unavailable == nil && entry != nil
        restoreButton.isEnabled = !busy && backup.map { ["prepared", "recycled"].contains($0.state) } == true
    }
    private func setBusy(_ value: Bool) { busy = value; showSelection() }
    @objc private func cancelReview() { guard !busy else { return }; recycleReview = nil; restoreReviewID = nil; state.stringValue = ""; showSelection() }
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
            catch { entries = []; backups = []; table.reloadData(); state.stringValue = error.localizedDescription }
            setBusy(false)
        }
    }
    @objc private func openTask() {
        let ids = entry?.taskIDs ?? backup.map { Array($0.tasks.keys).sorted() } ?? []
        if let id = ids.first(where: { store.task($0)?.archived == false }) { onSelectTask(id) }
    }
    @objc private func reveal() {
        let path = entry?.path ?? backup.map { store.directory.appendingPathComponent("worktrees/" + $0.id + "/files").path }
        if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    @objc private func recycle() {
        guard !busy, let item = entry, item.unavailable == nil else { return }
        if let review = recycleReview {
            recycleReview = nil; setBusy(true)
            job = Task { [weak self] in
                guard let self else { return }
                do { try await recycleReviewed(review) } catch { state.stringValue = error.localizedDescription }
                setBusy(false)
            }; return
        }
        setBusy(true); state.stringValue = "检查文件与暂存状态…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let review = try await git.prepareWorktreeRecycle(path: item.path)
                try Task.checkCancellation()
                recycleReview = review; state.stringValue = ""
            } catch { state.stringValue = error.localizedDescription }
            setBusy(false)
        }
    }
    private func recycleReviewed(_ review: AgentWorktreeRecycleReview) async throws {
        state.stringValue = "备份并回收工作树…"
        let result = try await git.recycleWorktree(reviewHash: review.hash); selectedBackupID = result.id
        state.stringValue = "已回收 · " + (result.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "分离状态")
        entries = try await git.worktrees(); backups = try git.worktreeBackups(); reloadRows()
    }
    @objc private func restore() {
        guard !busy, let item = backup, ["prepared", "recycled"].contains(item.state) else { return }
        guard restoreReviewID == item.id else { restoreReviewID = item.id; state.stringValue = ""; showSelection(); return }
        restoreReviewID = nil; setBusy(true); state.stringValue = "恢复工作树…"
        job = Task { [weak self] in
            guard let self else { return }
            do { try await restoreReviewed(item.id) }
            catch { state.stringValue = error.localizedDescription }
            setBusy(false)
        }
    }
    private func restoreReviewed(_ id: String) async throws {
        let result = try await git.restoreWorktree(backupID: id); selectedEntryPath = result.origin.path
        state.stringValue = "已恢复 · " + (result.restoredBranch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "分离状态")
        entries = try await git.worktrees(); backups = try git.worktreeBackups(); reloadRows()
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let controls = [scope, refreshButton, openButton, revealButton, recycleButton, restoreButton, cancelButton].filter { !$0.isHiddenOrHasHiddenAncestor }
        let listFrame = content.convert(list.bounds, from: list), detailFrame = content.convert(viewer.bounds, from: viewer)
        let usesCompact = compact == true, layoutMatches = usesCompact ? abs(listFrame.minX - detailFrame.minX) < 1 && abs(listFrame.width - detailFrame.width) < 1 && !listFrame.intersects(detailFrame) : listFrame.maxX <= detailFrame.minX + 1
        return ["taskID": git.taskID, "busy": busy, "scope": showingBackups ? "backups" : "worktrees", "selectedPath": entry?.path ?? "", "selectedBackupID": backup?.id ?? "", "detail": detail.string, "state": state.stringValue, "recycleEnabled": recycleButton.isEnabled, "restoreEnabled": restoreButton.isEnabled, "recycleReviewHash": recycleReview?.hash ?? "", "restoreReviewID": restoreReviewID ?? "", "selectionEnabled": table.isEnabled,
                "entries": entries.map { ["path": $0.path, "branch": $0.branch ?? "", "owned": $0.owned, "unavailable": $0.unavailable ?? ""] as [String: Any] }, "backups": backups.map { ["id": $0.id, "state": $0.state, "path": $0.origin.path] }, "compact": usesCompact, "contentSize": [content.bounds.width, content.bounds.height], "listFrame": NSStringFromRect(listFrame), "detailFrame": NSStringFromRect(detailFrame),
                "checks": ["managerUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow, "managerHasNoFloatingWindow": window?.isVisible != true, "managerControlsFit": controls.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains(content.convert($0.bounds, from: $0)) }, "managerListHasUsableSpace": list.bounds.width >= 180 && list.bounds.height >= 100, "managerDetailHasUsableSpace": viewer.bounds.width >= 200 && viewer.bounds.height >= 80, "managerLayoutMatchesAvailableWidth": usesCompact == (content.bounds.width < 700) && layoutMatches]]
    }
    func checkWorkspace(scope index: Int? = nil, path: String? = nil, backupID: String? = nil, action: String = "") async {
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
