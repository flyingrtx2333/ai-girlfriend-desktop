import AppKit

@MainActor final class AgentGitWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String, onSelectTask: (String) -> Void
    private let table = NSTableView(), text = NSTextView(), branch = NSTextField(labelWithString: "Git"), state = NSTextField(labelWithString: "")
    private let message = NSTextField(), refreshButton = NSButton(title: "刷新", target: nil, action: nil), commitButton = NSButton(title: "提交", target: nil, action: nil)
    private let worktreeButton = NSButton(title: "新建工作树", target: nil, action: nil), initializeButton = NSButton(title: "初始化 Git", target: nil, action: nil)
    private var changes: [AgentGitChange] = [], review: AgentGitReview?, git: AgentGit?, job: Task<Void, Never>?, busy = false, lastResult = ""
    init(store: AgentStore, taskID: String, onSelectTask: @escaping (String) -> Void) {
        self.store = store; self.taskID = taskID; self.onSelectTask = onSelectTask
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git · " + (store.task(taskID)?.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "项目")
        window.minSize = NSSize(width: 700, height: 470); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.center()
        super.init(window: window); window.delegate = self
        let content = NSView(); content.wantsLayer = true; content.layer?.backgroundColor = NSColor(white: 0.98, alpha: 1).cgColor; window.contentView = content
        branch.font = .systemFont(ofSize: 13, weight: .medium); branch.lineBreakMode = .byTruncatingMiddle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 29; table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = true
        table.setAccessibilityLabel("Git 变更文件")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 12, height: 12); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Git 实际差异")
        let viewer = NSScrollView(); viewer.documentView = text; viewer.hasVerticalScroller = true
        message.placeholderString = "提交说明"; message.setAccessibilityLabel("Git 提交说明")
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail
        for button in [refreshButton, commitButton, worktreeButton, initializeButton] { button.target = self }
        refreshButton.action = #selector(refresh); commitButton.action = #selector(commit); worktreeButton.action = #selector(createWorktree); initializeButton.action = #selector(initialize)
        initializeButton.isHidden = true
        let toolbar = NSStackView(views: [branch, NSView(), initializeButton, worktreeButton, refreshButton]); toolbar.spacing = 8
        let composer = NSStackView(views: [message, commitButton]); composer.spacing = 10
        for view in [toolbar, list, viewer, composer, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 14), list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), list.widthAnchor.constraint(equalToConstant: 210), list.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -14),
            viewer.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), viewer.topAnchor.constraint(equalTo: list.topAnchor), viewer.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), composer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), composer.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -10), message.heightAnchor.constraint(equalToConstant: 28),
            state.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), state.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { job?.cancel(); git?.cancel() }
    private func writable() -> Bool {
        guard let task = store.task(taskID) else { return false }
        return !task.archived && ![.running, .waiting].contains(task.status)
    }
    private func setBusy(_ value: Bool) {
        busy = value; table.isEnabled = !value; refreshButton.isEnabled = !value
        worktreeButton.isEnabled = !value && writable() && initializeButton.isHidden
        initializeButton.isEnabled = !value && writable(); message.isEnabled = !value && writable()
        commitButton.isEnabled = !value && writable() && review?.diff.isEmpty == false
    }
    private func connect(creating: Bool = false) throws -> AgentGit {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        let files = try AgentFiles(workspace: task.workspace), directory = try AgentGit.metadata(workspace: task.workspace, creating: creating)
        if directory != files.root, !directory.path.hasPrefix(files.root.path + "/"), task.gitDirectory != directory.path {
            let alert = NSAlert(); alert.messageText = "连接 Git 仓库"; alert.informativeText = directory.path
            alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { throw PetError("未连接 Git 元数据") }
            store.update(taskID) { $0.gitDirectory = directory.path }
        }
        let result = try AgentGit(store: store, taskID: taskID, directory: directory); git = result; return result
    }
    @objc private func refresh() {
        guard !busy else { return }; review = nil; setBusy(true); state.stringValue = "读取 Git…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let git = try connect(), result = try await git.status(); try Task.checkCancellation()
                changes = result.changes; branch.stringValue = result.branch + " · \(changes.count) 个变更"; initializeButton.isHidden = true
                table.delegate = nil; table.reloadData(); table.deselectAll(nil); table.delegate = self
                state.stringValue = lastResult; text.string = changes.isEmpty ? "工作区干净" : ""; setBusy(false)
                if !changes.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            } catch {
                guard !Task.isCancelled else { return }
                let root = store.task(taskID)?.workspace.map { URL(fileURLWithPath: $0) }
                initializeButton.isHidden = root == nil || FileManager.default.fileExists(atPath: root!.appendingPathComponent(".git").path)
                state.stringValue = error.localizedDescription; setBusy(false)
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { changes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let change = changes[row], label = NSTextField(labelWithString: change.status + "  " + change.path.replacingOccurrences(of: "\n", with: "↵"))
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = change.path; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !busy, let git else { return }
        let selected = table.selectedRowIndexes.filter { changes.indices.contains($0) }.map { changes[$0].path }
        review = nil; text.string = ""; guard !selected.isEmpty else { setBusy(false); return }; setBusy(true); state.stringValue = "读取差异…"
        job = Task { [weak self] in
            guard let self else { return }
            do { let result = try await git.diff(selected); try Task.checkCancellation(); review = result; text.string = result.diff.isEmpty ? "没有差异" : result.diff; state.stringValue = lastResult.isEmpty ? "\(result.paths.count) 个文件" : lastResult }
            catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
            if !Task.isCancelled { setBusy(false) }
        }
    }
    private func log(_ title: String, result: String, failed: Bool = false) { store.update(taskID) { $0.events.append(AgentEvent(kind: "git", title: title, detail: result, status: failed ? "failed" : "completed")) } }
    @objc private func commit() {
        guard !busy, writable(), let git, let review else { return }
        let value = message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { state.stringValue = "请填写提交说明"; window?.makeFirstResponder(message); return }
        setBusy(true); state.stringValue = "提交中…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await git.commit(paths: review.paths, message: value, reviewHash: review.hash)
                log("Git 提交", result: result.commit + "\n" + result.output); message.stringValue = ""; self.review = nil; lastResult = "已提交 " + String(result.commit.prefix(8))
                setBusy(false); refresh()
            } catch { log("Git 提交失败", result: error.localizedDescription, failed: true); self.review = nil; state.stringValue = error.localizedDescription; setBusy(false) }
        }
    }
    @objc private func createWorktree() {
        guard !busy, writable(), let git else { return }
        let alert = NSAlert(); alert.messageText = "新建工作树"; alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        let name = NSTextField(string: "agent/" + String(UUID().uuidString.lowercased().prefix(8))); name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = name; alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }; setBusy(true); state.stringValue = "创建工作树…"
        job = Task { [weak self] in
            guard let self else { return }
            do { let result = try await git.createWorktree(branch: name.stringValue); log("Git 工作树", result: result.branch + "\n" + result.workspace); onSelectTask(result.taskID); state.stringValue = "已创建 " + result.branch }
            catch { log("工作树创建失败", result: error.localizedDescription, failed: true); state.stringValue = error.localizedDescription }
            setBusy(false)
        }
    }
    @objc private func initialize() {
        guard !busy, writable() else { return }; setBusy(true)
        job = Task { [weak self] in
            guard let self else { return }
            do { let git = try connect(creating: true); _ = try await git.initialize(); log("Git 初始化", result: git.files.root.path); setBusy(false); refresh() }
            catch { state.stringValue = error.localizedDescription; setBusy(false) }
        }
    }
    func checkLayout(_ output: URL) async -> [String: Bool] {
        let deadline = Date().addingTimeInterval(15)
        while busy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        var checks: [String: Bool] = ["nativeGitShowsActualDiff": review?.diff.isEmpty == false && text.string == review?.diff]
        for (name, size) in [("normal", NSSize(width: 900, height: 620)), ("narrow", NSSize(width: 700, height: 470))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["nativeGitLayout-" + name] = !busy && table.bounds.width > 150 && text.bounds.width > 350 && message.bounds.width > 350 && !message.hasAmbiguousLayout && !commitButton.hasAmbiguousLayout
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("git-" + name + ".png")) }
        }
        return checks
    }
}
