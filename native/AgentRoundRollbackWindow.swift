import AppKit

@MainActor final class AgentRoundRollbackWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: AgentStore, taskID: String, messageID: String
    private let table = NSTableView(), text = NSTextView(), state = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(), refreshButton = NSButton(title: "重新检查", target: nil, action: nil)
    private var review: AgentRoundRollback.Review?, loading: Task<Void, Never>?, generation = 0, applying = false
    private let actionTitle: String?
    var beforeApply: (() throws -> Void)?
    var performReview: ((AgentRoundRollback.Review) throws -> Void)?
    var onComplete: (() -> Void)?
    init(store: AgentStore, taskID: String, messageID: String, actionTitle: String? = nil, notice: String? = nil) {
        self.store = store; self.taskID = taskID; self.messageID = messageID; self.actionTitle = actionTitle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 540, height: 520); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let path = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path")); path.title = "文件"; path.width = 480
        let action = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action")); action.title = "操作"; action.width = 150
        table.addTableColumn(path); table.addTableColumn(action); table.rowHeight = 28; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("将恢复的文件")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.isRichText = false; text.textContainerInset = NSSize(width: 8, height: 8); text.setAccessibilityLabel("文件撤回差异")
        let diff = NSScrollView(); diff.documentView = text; diff.hasVerticalScroller = true; diff.borderType = .bezelBorder
        let notice = NSTextField(wrappingLabelWithString: notice ?? "对话记录会保留。命令、服务及外部操作不能自动撤回。"); notice.font = .systemFont(ofSize: 12); notice.textColor = AgentWorkbenchTheme.secondaryText
        state.font = .systemFont(ofSize: 12); state.textColor = .systemRed
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        applyButton.target = self; applyButton.action = #selector(apply)
        let buttons = NSStackView(views: [refreshButton, NSView(), cancel, applyButton]); buttons.spacing = 8
        for view in [list, diff, notice, state, buttons] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([list.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), list.heightAnchor.constraint(equalToConstant: 150),
            diff.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 10), diff.leadingAnchor.constraint(equalTo: list.leadingAnchor), diff.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            notice.topAnchor.constraint(equalTo: diff.bottomAnchor, constant: 10), notice.leadingAnchor.constraint(equalTo: list.leadingAnchor), notice.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            state.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 6), state.leadingAnchor.constraint(equalTo: list.leadingAnchor), state.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: state.bottomAnchor, constant: 10), buttons.leadingAnchor.constraint(equalTo: list.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: list.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16), diff.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func refresh() {
        guard !applying else { return }; generation += 1; loading?.cancel(); text.string = ""; state.stringValue = ""
        do {
            let value = try AgentRoundRollback.review(taskID: taskID, from: messageID, store: store); review = value
            let title = actionTitle ?? (value.recovery ? "恢复撤回前文件" : "撤回文件")
            window?.title = title + " · " + (store.task(taskID)?.title ?? "任务"); applyButton.title = title; applyButton.setAccessibilityLabel(title)
            applyButton.isEnabled = value.canApply; state.stringValue = value.issues.prefix(2).joined(separator: "\n"); state.toolTip = value.issues.joined(separator: "\n")
            table.deselectAll(nil); table.reloadData(); text.string = value.issues.joined(separator: "\n")
            if !value.paths.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        } catch { review = nil; applyButton.title = actionTitle ?? "撤回文件"; applyButton.isEnabled = false; state.stringValue = error.localizedDescription; table.reloadData() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { review?.paths.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let review, review.paths.indices.contains(row) else { return nil }; let path = review.paths[row], label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "path" { label.stringValue = String(path.dropFirst(review.workspace.count + 1)); label.toolTip = path }
        else if let entry = review.entries.first(where: { $0.path == path }) { label.stringValue = entry.desired.state.kind == "missing" ? "移除新增文件" : entry.current.state.kind == "missing" ? "恢复已删除文件" : entry.desired.state.kind == "link" ? "恢复链接" : "恢复内容" }
        else { label.stringValue = "不可自动恢复" }; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { loadSelection() }
    private func loadSelection() {
        generation += 1; let token = generation; loading?.cancel(); text.string = ""
        guard let review, review.paths.indices.contains(table.selectedRow) else { return }
        guard let entry = review.entries.first(where: { $0.path == review.paths[table.selectedRow] }) else { text.string = review.issues.joined(separator: "\n"); return }
        let desired = entry.desired.state, current = entry.current.state
        let change = AgentChange(path: entry.path, existed: desired.kind != "missing", backup: entry.desired.backup, beforeHash: desired.hash, afterHash: current.hash, permissions: desired.permissions, beforeKind: desired.kind, afterKind: current.kind, afterPermissions: current.permissions)
        loading = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let comparison = try AgentChanges.comparison(change, taskID: taskID, store: store, strict: true)
                defer { try? FileManager.default.removeItem(at: comparison.directory) }
                let diff = try await AgentChanges.fileDiff(left: comparison.right, right: comparison.left, directory: comparison.directory, protectedData: store.directory.deletingLastPathComponent())
                guard !Task.isCancelled, token == generation else { return }; text.string = diff.isEmpty ? "文件内容相同；检查权限或类型变更。" : AgentChanges.labels(diff, path: URL(fileURLWithPath: entry.path).lastPathComponent)
            }
            catch { guard !Task.isCancelled, token == generation else { return }; text.string = error.localizedDescription }
        }
    }
    @objc private func apply() {
        guard let review, review.canApply, !applying else { return }; loading?.cancel(); generation += 1
        do {
            try beforeApply?(); applying = true; applyButton.isEnabled = false; refreshButton.isEnabled = false; state.stringValue = "正在恢复文件…"; window?.displayIfNeeded()
            if let performReview { try performReview(review) } else { try AgentRoundRollback.apply(review, store: store) }
            applying = false; onComplete?(); close()
        } catch { applying = false; refreshButton.isEnabled = true; applyButton.isEnabled = false; state.stringValue = error.localizedDescription }
    }
    @objc private func cancel() { if !applying { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !applying }
    func windowWillClose(_ notification: Notification) { loading?.cancel(); generation += 1 }
}
