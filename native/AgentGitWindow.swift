import AppKit

@MainActor final class AgentGitWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String, onSelectTask: (String) -> Void
    private let table = NSTableView(), diffView = AgentGitDiffView(), branch = NSTextField(labelWithString: "Git"), state = NSTextField(labelWithString: "")
    private var text: NSTextView { diffView.text }
    private let message = NSTextField(), refreshButton = NSButton(title: "刷新", target: nil, action: nil), commitButton = NSButton(title: "提交", target: nil, action: nil)
    private let worktreeButton = NSButton(title: "新建工作树", target: nil, action: nil), initializeButton = NSButton(title: "初始化 Git", target: nil, action: nil)
    private let pushButton = NSButton(title: "推送…", target: nil, action: nil), commitPushButton = NSButton(title: "提交并推送…", target: nil, action: nil)
    private var pushWindow: AgentGitPushWindow?
    private var securityWindow: AgentCodeSecurityWindow?
    private let securityButton = NSButton(title: "安全检查…", target: nil, action: nil)
    private var dependencyWindow: AgentDependencyWindow?
    private let dependencyButton = NSButton(title: "依赖漏洞…", target: nil, action: nil)
    private var worktreeWindow: AgentWorktreeWindow?
    private var creationWindow: AgentWorktreeCreationWindow?
    private let manageWorktrees = NSButton(title: "工作树…", target: nil, action: nil)
    private let sourcePopup = NSPopUpButton(), revision = NSTextField(string: "HEAD"), statistics = NSTextField(labelWithString: "")
    private let displayMode = NSSegmentedControl(labels: ["统一", "并排"], trackingMode: .selectOne, target: nil, action: nil), wrap = NSButton(checkboxWithTitle: "换行", target: nil, action: nil)
    private let stageButton = NSButton(title: "暂存文件", target: nil, action: nil), unstageButton = NSButton(title: "取消暂存", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复未暂存", target: nil, action: nil), undoRestoreButton = NSButton(title: "撤销恢复", target: nil, action: nil)
    private var source: AgentGitSource = .uncommitted, inspection: AgentGitInspection?, restoreID: String?
    private var changes: [AgentGitChange] = [], review: AgentGitReview?, git: AgentGit?, job: Task<Void, Never>?, lastResult = "", displayedBranchRef = ""
    private let activityOwner = UUID()
    private var busy = false { didSet { if busy != oldValue { store.worktreeRetention.setNativeOperation(activityOwner, taskID: taskID, busy: busy) } } }
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
        let viewer = diffView
        message.placeholderString = "提交说明"; message.setAccessibilityLabel("Git 提交说明")
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail
        for button in [refreshButton, commitButton, worktreeButton, initializeButton, stageButton, unstageButton, restoreButton, undoRestoreButton, pushButton, commitPushButton, securityButton] { button.target = self }
        refreshButton.action = #selector(refresh); commitButton.action = #selector(commit); worktreeButton.action = #selector(createWorktree); initializeButton.action = #selector(initialize)
        manageWorktrees.target = self; manageWorktrees.action = #selector(openWorktrees)
        stageButton.action = #selector(stageFile); unstageButton.action = #selector(unstageFile); restoreButton.action = #selector(restoreFile); undoRestoreButton.action = #selector(undoRestore)
        pushButton.action = #selector(openPush); commitPushButton.action = #selector(commitAndPush)
        securityButton.action = #selector(openSecurityOptions)
        securityButton.toolTip = "静态检查、轻量语义检查与上次报告"
        dependencyButton.target = self
        dependencyButton.action = #selector(openDependencies)
        sourcePopup.addItems(withTitles: AgentGitSource.allCases.map(\.title)); sourcePopup.selectItem(at: AgentGitSource.allCases.firstIndex(of: source)!)
        sourcePopup.target = self; sourcePopup.action = #selector(changeSource); sourcePopup.setAccessibilityLabel("Git 改动来源")
        sourcePopup.item(at: 0)?.toolTip = "本轮文件工具、命令和 MCP 执行期间记录的项目文件变化。"
        revision.target = self; revision.action = #selector(refresh); revision.placeholderString = "提交或基准分支"; revision.setAccessibilityLabel("Git 比较修订"); revision.isHidden = true
        revision.widthAnchor.constraint(equalToConstant: 170).isActive = true
        statistics.font = .monospacedSystemFont(ofSize: 11, weight: .regular); statistics.textColor = .secondaryLabelColor
        statistics.lineBreakMode = .byTruncatingTail; statistics.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        displayMode.selectedSegment = 0; displayMode.target = self; displayMode.action = #selector(changeDisplay); displayMode.controlSize = .small; displayMode.setAccessibilityLabel("Git 差异视图")
        wrap.state = .on; wrap.target = self; wrap.action = #selector(changeDisplay); wrap.controlSize = .small
        undoRestoreButton.isHidden = true; commitButton.toolTip = "提交所选来源中已审阅的文件版本"
        initializeButton.isHidden = true
        let toolbar = NSStackView(views: [branch, NSView(), initializeButton, manageWorktrees, worktreeButton, pushButton, refreshButton]); toolbar.spacing = 8
        let sources = NSStackView(views: [sourcePopup, revision, NSView(), statistics, displayMode, wrap]); sources.spacing = 10
        let actions = NSStackView(views: [stageButton, unstageButton, restoreButton, undoRestoreButton, NSView(), dependencyButton, securityButton]); actions.spacing = 8
        for button in [stageButton, unstageButton, restoreButton, undoRestoreButton, dependencyButton, securityButton] { button.controlSize = .small; button.font = .systemFont(ofSize: 12) }
        let composer = NSStackView(views: [message, commitButton, commitPushButton]); composer.spacing = 10
        for view in [toolbar, sources, list, viewer, actions, composer, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sources.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), sources.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), sources.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            list.topAnchor.constraint(equalTo: sources.bottomAnchor, constant: 12), list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), list.widthAnchor.constraint(equalToConstant: 210), list.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            viewer.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), viewer.topAnchor.constraint(equalTo: list.topAnchor), viewer.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), composer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), composer.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -10), message.heightAnchor.constraint(equalToConstant: 28),
            actions.leadingAnchor.constraint(equalTo: composer.leadingAnchor), actions.trailingAnchor.constraint(equalTo: composer.trailingAnchor), actions.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10),
            state.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), state.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { job?.cancel(); git?.cancel(); dependencyWindow?.close(); busy = false }
    private func writable() -> Bool {
        guard let task = store.task(taskID) else { return false }
        return !task.archived && ![.running, .waiting].contains(task.status)
    }
    private func setBusy(_ value: Bool) {
        busy = value; table.isEnabled = !value; refreshButton.isEnabled = !value
        sourcePopup.isEnabled = !value; revision.isEnabled = !value
        worktreeButton.isEnabled = !value && writable() && initializeButton.isHidden
        manageWorktrees.isEnabled = !value && initializeButton.isHidden
        initializeButton.isEnabled = !value && writable(); message.isEnabled = !value && writable()
        commitButton.title = source == .staged ? "提交已暂存" : "提交"
        commitButton.isEnabled = !value && writable() && [.uncommitted, .staged].contains(source) && review?.diff.isEmpty == false
        commitPushButton.isEnabled = commitButton.isEnabled
        pushButton.isEnabled = !value && initializeButton.isHidden
        securityButton.isEnabled = !value && git != nil
        dependencyButton.isEnabled = !value && store.task(taskID)?.workspace != nil
        let item = inspection?.paths.count == 1 ? changes.first(where: { $0.path == inspection?.paths.first }) : nil
        let columns = Array(item?.status ?? ""), current = !value && writable() && item != nil && !source.usesRevision && !columns.contains("U") && !["AA", "DD"].contains(item?.status ?? "")
        let hasUnstaged = item?.status == "??" || (source == .unstaged || source == .lastTurn) || (source == .uncommitted && columns.count == 2 && columns[1] != " ")
        let hasStaged = source == .staged || (source == .uncommitted && columns.count == 2 && columns[0] != " " && columns[0] != "?")
        stageButton.isEnabled = current && [.uncommitted, .unstaged, .lastTurn].contains(source) && hasUnstaged
        unstageButton.isEnabled = current && [.uncommitted, .staged].contains(source) && hasStaged
        restoreButton.isEnabled = current && [.uncommitted, .unstaged].contains(source) && hasUnstaged
        undoRestoreButton.isEnabled = !value && writable() && restoreID != nil
    }
    @objc private func openDependencies() {
        guard !busy else { return }
        if let dependencyWindow, dependencyWindow.window?.isVisible == true {
            dependencyWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let dependencyGit: AgentGit?
            if let git {
                dependencyGit = try AgentGit(store: store, taskID: taskID, directory: git.directory)
            } else {
                let files = try AgentFiles(workspace: store.task(taskID)?.workspace)
                guard !FileManager.default.fileExists(atPath: files.root.appendingPathComponent(".git").path) else {
                    throw PetError("请先连接当前 Git 仓库")
                }
                dependencyGit = nil
            }
            let service = try AgentDependencySecurity(store: store, taskID: taskID, git: dependencyGit)
            let paths = table.selectedRowIndexes.filter { changes.indices.contains($0) }.map { changes[$0].path }
                .filter { AgentDependencySecurity.ecosystem($0) != nil }
            let controller = AgentDependencyWindow(service: service, store: store, taskID: taskID,
                defaultSource: source == .staged ? .staged : .working, selectedPaths: paths)
            dependencyWindow = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } catch { state.stringValue = error.localizedDescription }
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
        let result = try AgentGit(store: store, taskID: taskID, directory: directory); window?.title = "Git · " + result.files.root.lastPathComponent; git = result; return result
    }
    @objc private func refresh() {
        guard !busy else { return }; review = nil; inspection = nil; changes = []; table.reloadData(); showDiff(""); statistics.stringValue = ""; branch.stringValue = "Git"; setBusy(true); state.stringValue = "读取 Git…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let git = try connect(); _ = try await git.status(); try Task.checkCancellation()
                let symbolic = try await git.run(["symbolic-ref", "--quiet", "HEAD"])
                displayedBranchRef = symbolic.failed ? "HEAD" : (symbolic.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let currentBranch = displayedBranchRef == "HEAD" ? "分离状态" : displayedBranchRef.hasPrefix("refs/heads/") ? String(displayedBranchRef.dropFirst(11)) : displayedBranchRef
                branch.stringValue = currentBranch
                changes = try await git.inspectionChanges(source: source, revision: revision.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                branch.stringValue = currentBranch + " · \(changes.count) 个文件"
                do { let total = try await git.statistics(source: source, revision: revision.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), changes: changes); branch.stringValue += " · 总 " + total.title }
                catch { if Task.isCancelled { throw CancellationError() }; branch.stringValue += " · 统计不可用" }
                initializeButton.isHidden = true
                table.delegate = nil; table.reloadData(); table.deselectAll(nil); table.delegate = self
                state.stringValue = lastResult; showDiff(changes.isEmpty ? (source == .lastTurn ? "本轮尚无文件修改记录" : "此来源没有变更") : ""); setBusy(false)
                if !changes.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            } catch {
                guard !Task.isCancelled else { return }
                let root = store.task(taskID)?.workspace.map { URL(fileURLWithPath: $0) }
                initializeButton.isHidden = root == nil || FileManager.default.fileExists(atPath: root!.appendingPathComponent(".git").path)
                state.stringValue = error.localizedDescription; setBusy(false)
            }
        }
    }
    @objc private func changeSource() {
        guard !busy, AgentGitSource.allCases.indices.contains(sourcePopup.indexOfSelectedItem) else { return }
        source = AgentGitSource.allCases[sourcePopup.indexOfSelectedItem]
        sourcePopup.toolTip = source == .lastTurn ? "本轮文件工具、命令和 MCP 执行期间记录的项目文件变化。" : nil
        revision.isHidden = !source.usesRevision; revision.stringValue = source == .committed ? "HEAD" : ""
        lastResult = ""; refresh()
        if source == .branch { window?.makeFirstResponder(revision) }
    }
    @objc private func changeDisplay() { diffView.splitMode = displayMode.selectedSegment == 1; diffView.wraps = wrap.state == .on }
    private func showDiff(_ patch: String) {
        let titles: (String, String)
        switch source {
        case .staged: titles = ("HEAD", "暂存区")
        case .unstaged: titles = ("暂存区", "工作区")
        case .lastTurn: titles = ("本轮修改前", "工作区")
        case .committed: titles = ("父提交", "所选提交")
        case .branch: titles = ("合并基准", "HEAD")
        default: titles = ("HEAD", "工作区")
        }
        diffView.show(patch, oldTitle: titles.0, newTitle: titles.1)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { changes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let change = changes[row], label = NSTextField(labelWithString: change.status + "  " + change.path.replacingOccurrences(of: "\n", with: "↵"))
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = change.path; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        inspectSelection()
    }
    private func inspectSelection(location: (AgentSecurityFinding, AgentSecurityReport)? = nil) {
        guard !busy, let git else { return }
        let selected = table.selectedRowIndexes.filter { changes.indices.contains($0) }.map { changes[$0].path }
        review = nil; inspection = nil; showDiff(""); statistics.stringValue = ""; guard !selected.isEmpty else { setBusy(false); return }; setBusy(true); state.stringValue = "读取差异…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                if let (finding, report) = location { try await git.validateSecurityLocation(finding, report: report) }
                let result = try await git.inspect(source: source, revision: revision.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), requested: selected)
                if let (finding, report) = location { try await git.validateSecurityLocation(finding, report: report) }
                try Task.checkCancellation()
                if [.uncommitted, .staged].contains(source) {
                    let saved = store.task(taskID)?.gitReview
                    if source == .staged, saved?.branchRef != displayedBranchRef { throw PetError("当前分支已变化，请刷新后重新审阅") }
                    review = saved
                }
                inspection = result
                showDiff(result.diff.isEmpty ? "没有差异" : result.diff)
                statistics.stringValue = "所选 +\(result.additions)  −\(result.deletions)" + (result.binaryFiles > 0 ? " · \(result.binaryFiles) 二进制" : "")
                state.stringValue = lastResult.isEmpty ? "\(result.paths.count) 个文件" : lastResult
                if let (finding, _) = location {
                    let position = "\(finding.path):\(finding.line)"
                    state.stringValue = diffView.focusNewLine(finding.line) ? position : position + " · 此行在差异范围外"
                }
            }
            catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
            if !Task.isCancelled { setBusy(false) }
        }
    }
    @objc private func openSecurityOptions() {
        guard !busy else { return }
        let available = AgentCodeSecurity.sources.contains(source) && !table.selectedRowIndexes.isEmpty
        let menu = NSMenu()
        for (title, action, enabled) in [
            ("静态检查所选文件", #selector(checkSecurity), available),
            ("轻量语义检查所选文件", #selector(checkSemanticSecurity), available),
            ("上次语义报告", #selector(showPreviousSemanticReport), (try? git?.previousSemanticReport()) != nil)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: securityButton.bounds.maxY), in: securityButton)
    }
    @objc private func checkSecurity() { runSecurity(mode: .patterns) }
    @objc private func checkSemanticSecurity() { runSecurity(mode: .semantic) }
    @objc private func showPreviousSemanticReport() {
        guard !busy, let git else { return }
        do { presentSecurityReport(try git.previousSemanticReport(), git: git) }
        catch { state.stringValue = error.localizedDescription }
    }
    private func runSecurity(mode: AgentSecurityMode) {
        guard !busy, let git, let window, window.attachedSheet == nil, AgentCodeSecurity.sources.contains(source) else { return }
        let selected = table.selectedRowIndexes.filter { changes.indices.contains($0) }.map { changes[$0].path }
        guard (1...50).contains(selected.count) else { state.stringValue = "请选择 1 至 50 个文件"; return }
        setBusy(true)
        state.stringValue = mode.title + " · \(selected.count) 个文件…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await git.checkCodeSecurity(source: source, requested: selected, mode: mode)
                try Task.checkCancellation()
                setBusy(false)
                state.stringValue = report.summary
                presentSecurityReport(report, git: git)
            } catch {
                guard !Task.isCancelled else { return }
                state.stringValue = error.localizedDescription
                setBusy(false)
            }
        }
    }
    private func presentSecurityReport(_ report: AgentSecurityReport, git: AgentGit) {
        guard let window, window.attachedSheet == nil else { return }
        let controller = AgentCodeSecurityWindow(report: report, onLocate: { [weak self] finding in
                    self?.locateSecurityFinding(finding, report: report)
                }, onFix: writable() && report.mode != .semantic ? { [weak self] finding in
                    guard let self else { throw PetError("Git 窗口已关闭") }
                    let checkpoint = try git.applySecurityFix(finding, report: report)
                    restoreID = checkpoint
                    undoRestoreButton.title = "撤销修复"
                    undoRestoreButton.isHidden = false
                    lastResult = "已启用证书校验"
                    log(lastResult, result: "\(finding.path):\(finding.line)")
                    refresh()
                } : nil)
                securityWindow = controller
                if let sheet = controller.window { window.beginSheet(sheet) { [weak self] _ in self?.securityWindow = nil } }
    }
    private func locateSecurityFinding(_ finding: AgentSecurityFinding, report: AgentSecurityReport) {
        guard !busy, source == report.source, let row = changes.firstIndex(where: { $0.path == finding.path }) else {
            state.stringValue = "Git 来源已变化，请重新检查"
            return
        }
        table.delegate = nil
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.delegate = self
        inspectSelection(location: (finding, report))
    }
    private func log(_ title: String, result: String, failed: Bool = false) { store.update(taskID) { $0.events.append(AgentEvent(kind: "git", title: title, detail: result, status: failed ? "failed" : "completed")) } }
    @objc private func stageFile() { performFileAction(.stage) }
    @objc private func unstageFile() { performFileAction(.unstage) }
    @objc private func restoreFile() {
        guard !busy, writable(), let inspection, inspection.paths.count == 1 else { return }
        let path = inspection.paths[0], untracked = changes.contains { $0.path == path && $0.status == "??" }
        let alert = NSAlert(); alert.messageText = untracked ? "移入废纸篓？" : "恢复未暂存内容？"
        alert.informativeText = path + (untracked ? "\n可在访达的废纸篓中放回。" : "\n恢复为暂存区版本，保留已暂存内容。可通过“撤销恢复”或任务记录恢复本次改动。")
        alert.addButton(withTitle: untracked ? "移入废纸篓" : "恢复"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }; performFileAction(.restore)
    }
    private func performFileAction(_ action: AgentGitFileAction) {
        guard !busy, writable(), let git, let inspection else { return }
        let untracked = inspection.changes.contains { $0.path == inspection.paths.first && $0.status == "??" }
        let title = action == .stage ? "已暂存" : action == .unstage ? "已取消暂存" : untracked ? "已移入废纸篓" : "已恢复未暂存内容"
        setBusy(true); state.stringValue = "处理中…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await git.apply(action, inspection: inspection)
                if action == .restore { restoreID = result.checkpointID; undoRestoreButton.title = "撤销恢复"; undoRestoreButton.isHidden = result.checkpointID == nil }
                lastResult = title + " · " + inspection.paths.joined(separator: ", "); log(title, result: inspection.paths.joined(separator: "\n"))
                setBusy(false); refresh()
            } catch { state.stringValue = error.localizedDescription; setBusy(false) }
        }
    }
    @objc private func undoRestore() {
        guard !busy, writable(), let id = restoreID, let change = store.task(taskID)?.changes.first(where: { $0.id == id }) else { return }
        do { try AgentChanges.restore(change, taskID: taskID, store: store); restoreID = nil; undoRestoreButton.isHidden = true; lastResult = change.origin == "安全检查" ? "已撤销修复" : "已撤销恢复"; refresh() }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func commit() {
        performCommit(openPushAfter: false)
    }
    @objc private func commitAndPush() {
        performCommit(openPushAfter: true)
    }
    private func performCommit(openPushAfter: Bool) {
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
                if openPushAfter { lastResult += " · 待确认推送"; openPush() }
            } catch { log("Git 提交失败", result: error.localizedDescription, failed: true); self.review = nil; state.stringValue = error.localizedDescription; setBusy(false) }
        }
    }
    @objc private func openPush() {
        guard let git else { return }
        do {
            let controller = try AgentGitPushWindow(store: store, taskID: taskID, directory: git.directory)
            controller.onReceipt = { [weak self] receipt in
                guard let self else { return }
                lastResult = receipt.verified ? "远端已核对 · " + receipt.remote + "/" + receipt.branch + " · " + String(receipt.sourceHead.prefix(12)) : "推送结果待核对"
                if !busy { refresh() }
            }
            pushWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func createWorktree() {
        guard !busy, writable(), let git else { return }
        do {
            let controller = try AgentWorktreeCreationWindow(store: store, taskID: taskID, directory: git.directory, onCreated: onSelectTask)
            creationWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func openWorktrees() {
        do { let manager = try AgentWorktreeWindow(store: store, taskID: taskID, onSelectTask: onSelectTask); worktreeWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil) }
        catch { state.stringValue = error.localizedDescription }
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
    func checkReviewViews(_ output: URL, path: String) async -> [String: Bool] {
        if let index = changes.firstIndex(where: { $0.path == path }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        let deadline = Date().addingTimeInterval(15)
        while busy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        var checks: [String: Bool] = [:]
        displayMode.selectedSegment = 1; diffView.splitMode = true
        for (name, size) in [("normal", NSSize(width: 900, height: 620)), ("narrow", NSSize(width: 700, height: 470))] {
            window?.setContentSize(size)
            for wrapping in [true, false] {
                diffView.wraps = wrapping; wrap.state = wrapping ? .on : .off; window?.contentView?.layoutSubtreeIfNeeded()
                for (key, value) in diffView.checkSplitLayout() { checks[key + "-" + name + (wrapping ? "-wrap" : "-no-wrap")] = value }
            }
            diffView.wraps = true; wrap.state = .on; window?.contentView?.layoutSubtreeIfNeeded()
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("git-split-" + name + ".png")) }
        }
        return checks
    }
}
