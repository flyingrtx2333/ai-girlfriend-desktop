import AppKit

@MainActor final class AgentGitPushWindow: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate {
    private let store: AgentStore, taskID: String, git: AgentGit
    private let remote = NSPopUpButton(), address = NSPopUpButton(), branch = AgentDialogTextField(), source = NSTextField(labelWithString: ""), count = NSTextField(labelWithString: "")
    private let upstream = NSButton(checkboxWithTitle: "设为上游", target: nil, action: nil), inspectCommit = NSPopUpButton()
    private let add = AgentDialogButton(title: "添加远端", target: nil, action: nil), prepare = AgentDialogButton(title: "检查远端", target: nil, action: nil), push = AgentDialogButton(title: "推送", target: nil, action: nil)
    private let refresh = AgentDialogButton(title: "刷新", target: nil, action: nil)
    private let stop = AgentDialogButton(title: "停止", target: nil, action: nil), verify = AgentDialogButton(title: "核对上次结果", target: nil, action: nil), state = AgentSettingsStatusField("推送状态")
    private let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface), diffView = AgentGitDiffView()
    private let displayMode = NSSegmentedControl(labels: ["统一", "并排"], trackingMode: .selectOne, target: nil, action: nil), wrap = NSButton(checkboxWithTitle: "换行", target: nil, action: nil)
    private lazy var remoteFrame = AgentSettingsPopupFrame(remote, outlined: true)
    private lazy var addressFrame = AgentSettingsPopupFrame(address, outlined: true, maximumWidth: nil)
    private lazy var commitFrame = AgentSettingsPopupFrame(inspectCommit, outlined: true, maximumWidth: nil)
    private var remotes: [AgentGitRemote] = [], remoteHash = "", review: AgentGitPushReview?, job: Task<Void, Never>?, sending = false
    private var remotePage: AgentGitRemotePage?, pushContent: NSView?
    private var draft: AgentGitDraftRecovery.Push?, scope: AgentGitDraftRecovery.Scope?
    private var restoreDraftFocus = false
    private let activityOwner = UUID()
    private var busy = false { didSet { if busy != oldValue { store.worktreeRetention.setNativeOperation(activityOwner, taskID: taskID, busy: busy) } } }
    var onReceipt: ((AgentGitPushReceipt) -> Void)?
    var onDraftChange: (() -> Void)?
    var onDraftClose: ((AgentGitDraftRecovery.Push?) -> Void)?
    init(store: AgentStore, taskID: String, directory: URL, recovery: AgentGitDraftRecovery.Push? = nil) throws {
        self.store = store; self.taskID = taskID; git = try AgentGit(store: store, taskID: taskID, directory: directory)
        draft = recovery; draft?.opened = true; restoreDraftFocus = recovery?.focused == true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "推送 · " + git.files.root.lastPathComponent; window.minSize = NSSize(width: 640, height: 460); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        window.contentView = content
        source.font = .systemFont(ofSize: 13, weight: .medium); source.lineBreakMode = .byTruncatingMiddle
        count.font = .systemFont(ofSize: 12); count.textColor = AgentWorkbenchTheme.secondaryText; count.lineBreakMode = .byTruncatingTail
        branch.placeholderString = "目标分支"; branch.setAccessibilityLabel("推送目标分支"); branch.target = self; branch.action = #selector(invalidate)
        branch.delegate = self; branch.outlined = true; branch.heightAnchor.constraint(equalToConstant: 32).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(branchSelectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        remote.setAccessibilityLabel("推送远端"); address.setAccessibilityLabel("推送地址"); inspectCommit.setAccessibilityLabel("待推送提交")
        remote.target = self; remote.action = #selector(changeRemote); address.target = self; address.action = #selector(changeAddress)
        upstream.target = self; upstream.action = #selector(changeUpstream); inspectCommit.target = self; inspectCommit.action = #selector(selectCommit)
        for button in [add, prepare, push, stop, verify, refresh] { button.target = self; AgentDialogStyle.action(button, prominent: button === push) }
        add.action = #selector(addRemote); prepare.action = #selector(preparePush); push.action = #selector(sendPush); stop.action = #selector(stopJob); verify.action = #selector(verifyPush)
        refresh.action = #selector(reload)
        push.keyEquivalent = ""; stop.isHidden = true
        func label(_ title: String) -> NSTextField { let field = NSTextField(labelWithString: title); field.font = .systemFont(ofSize: 13); field.widthAnchor.constraint(equalToConstant: 44).isActive = true; return field }
        remoteFrame.widthAnchor.constraint(equalToConstant: 130).isActive = true
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); address.cell?.lineBreakMode = .byTruncatingMiddle
        inspectCommit.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); inspectCommit.cell?.lineBreakMode = .byTruncatingTail
        branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        upstream.font = .systemFont(ofSize: 13); upstream.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let header = NSStackView(views: [source, NSView(), refresh, add]), destination = NSStackView(views: [label("远端"), remoteFrame, addressFrame]), target = NSStackView(views: [label("分支"), branch, upstream, prepare])
        for row in [header, destination, target] { row.spacing = 10; row.alignment = .centerY }
        addressFrame.widthAnchor.constraint(equalTo: destination.widthAnchor, constant: -194).isActive = true
        displayMode.selectedSegment = 0; displayMode.target = self; displayMode.action = #selector(changeDisplay); displayMode.segmentStyle = .roundRect; displayMode.font = .systemFont(ofSize: 13); displayMode.setAccessibilityLabel("待推送差异视图")
        wrap.state = .on; wrap.target = self; wrap.action = #selector(changeDisplay); wrap.font = .systemFont(ofSize: 13)
        for view in [displayMode, wrap] { view.heightAnchor.constraint(equalToConstant: 28).isActive = true; view.setContentHuggingPriority(.required, for: .horizontal); view.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let reading = NSStackView(views: [commitFrame, displayMode, wrap]); reading.spacing = 8; reading.alignment = .centerY; reading.distribution = .fill
        let top = NSStackView(views: [header, destination, target, count, reading]); top.orientation = .vertical; top.alignment = .leading; top.spacing = 10
        for row in top.arrangedSubviews { row.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true }
        inspectCommit.addItem(withTitle: "待推送整体变更")
        state.font = .systemFont(ofSize: 12)
        let buttons = NSStackView(views: [NSView(), verify, stop, push]); buttons.spacing = 10
        let bottom = NSStackView(views: [state, buttons]); bottom.orientation = .vertical; bottom.alignment = .leading; bottom.spacing = 8
        for row in [state, buttons] { row.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true }
        for view in [top, diffView, bottom] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), top.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            diffView.leadingAnchor.constraint(equalTo: top.leadingAnchor), diffView.trailingAnchor.constraint(equalTo: top.trailingAnchor), diffView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12), diffView.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12), diffView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            bottom.leadingAnchor.constraint(equalTo: top.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: top.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        if restoreDraftFocus { requestDraftFocus() }
        else if !busy { presentingWindow?.makeFirstResponder(add) }
    }
    var hasDraft: Bool { draft != nil }
    var recoveryRemoteForm: AgentGitRemotePage? { remotePage }
    func discardDraft() { draft = nil }
    override func settingsWillLeave() { parkDraft() }
    var hasPendingOperation: Bool { busy || remotePage?.hasPendingChanges == true }
    private var writable: Bool { guard let task = store.task(taskID) else { return false }; return !task.archived && ![.running, .waiting].contains(task.status) }
    private func controls() {
        let mayEdit = !busy && writable && scope != nil
        for control in [branch, upstream, add] as [NSControl] { control.isEnabled = mayEdit }
        refresh.isEnabled = !busy && writable
        remote.isEnabled = mayEdit && remote.numberOfItems > 0
        address.isEnabled = mayEdit && address.numberOfItems > 0
        prepare.isEnabled = mayEdit && remotes.indices.contains(remote.indexOfSelectedItem) && address.indexOfSelectedItem >= 0
        inspectCommit.isEnabled = !busy && review != nil
        displayMode.isHidden = review == nil; displayMode.isEnabled = !busy
        wrap.isHidden = diffView.patch.isEmpty; wrap.isEnabled = !busy
        changeDisplay()
        push.isEnabled = !busy && writable && (review?.commitCount ?? 0) > 0
        verify.isHidden = store.task(taskID)?.gitPushReceipt == nil; verify.isEnabled = !busy
        stop.isHidden = !busy
        for frame in [remoteFrame, addressFrame, commitFrame] { frame.refreshEnabledState() }
    }
    private func showError(_ error: Error) { state.stringValue = error.localizedDescription; state.textColor = AgentDialogStyle.error }
    func windowDidBecomeKey(_ notification: Notification) { controls() }
    func windowWillClose(_ notification: Notification) { parkDraft(); restorePushPage(); job?.cancel(); git.cancel(); busy = false }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if settingsHostWindow == nil, let remotePage, !remotePage.canLeaveSettings() { return false }
        guard sending else { return true }
        let alert = AgentConfirmation(); alert.messageText = "停止等待并关闭？"; alert.informativeText = "远端可能已收到提交。关闭后请核对上次结果。"; alert.addButton(withTitle: "停止并关闭").hasDestructiveAction = true; alert.addButton(withTitle: "继续等待")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func reload() { if !busy { load() } }
    private func load(focusRemote: Bool = false) {
        let saved = captureDraft()
        restoreDraftFocus = saved?.focused == true
        scope = nil; invalidate(); busy = true; controls(); state.stringValue = "读取 Git…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                try saved?.requireCurrent(store.task(taskID))
                let current = try AgentGitDraftRecovery.Scope.current(store.task(taskID))
                guard let checkout = current.checkout else { throw PetError("请先连接当前 Git 仓库") }
                let status = try await git.status(), options = try await git.remotes()
                try Task.checkCancellation(); try current.requireCurrent(store.task(taskID), preserving: "请刷新后重试")
                remotes = options; scope = current; remoteHash = store.task(taskID)?.gitRemoteSnapshot?.hash ?? ""
                source.stringValue = status.branch + (status.head.map { " · " + String($0.prefix(12)) } ?? " · 尚无提交")
                remote.removeAllItems(); remote.addItems(withTitles: remotes.map(\.name)); updateAddresses()
                branch.stringValue = status.branch == "分离状态" ? "" : status.branch; upstream.state = status.branch == "分离状态" ? .off : .on
                let sourceRef = checkout.head.hasPrefix("ref: ") ? String(checkout.head.dropFirst(5)) : "HEAD"
                if let saved {
                    restoreDestination(saved)
                    state.stringValue = remotes.isEmpty ? "请添加 Git 远端" : address.indexOfSelectedItem < 0 ? "请选择推送草稿的远端和地址" : "推送草稿已恢复，请检查远端"
                } else if let saved = store.task(taskID)?.gitPushReview, saved.processID == AgentGitTransport.processID, saved.sourceHead == status.head, saved.sourceRef == sourceRef,
                   saved.gitDirectory == git.directory.path, saved.configHash == store.task(taskID)?.gitRemoteSnapshot?.configHash,
                   let i = remotes.firstIndex(where: { $0.name == saved.remote }), remotes[i].urls.indices.contains(saved.urlIndex), remotes[i].urls[saved.urlIndex] == saved.endpoint.location {
                    remote.selectItem(at: i); updateAddresses(); address.selectItem(at: saved.urlIndex); branch.stringValue = saved.targetBranch; upstream.state = saved.setUpstream ? .on : .off; show(saved)
                } else { state.stringValue = remotes.isEmpty ? "请添加 Git 远端" : "" }
            } catch { if !Task.isCancelled { showError(error) } }
            busy = false; controls()
            if focusRemote, remotePage == nil, isPageVisible { presentingWindow?.makeFirstResponder(remote) }
            else { requestDraftFocus() }
        }
    }
    private func updateAddresses() {
        address.removeAllItems()
        if remotes.indices.contains(remote.indexOfSelectedItem) { address.addItems(withTitles: remotes[remote.indexOfSelectedItem].urls) }
    }
    private func restoreDestination(_ saved: AgentGitDraftRecovery.Push) {
        branch.stringValue = saved.branch; upstream.state = saved.upstream ? .on : .off
        remote.select(nil)
        if let i = remotes.firstIndex(where: { $0.name == saved.remote }) { remote.selectItem(at: i) }
        updateAddresses(); address.select(nil)
        if let hash = saved.addressHash, let i = address.itemTitles.firstIndex(where: { Self.addressHash($0) == hash }) { address.selectItem(at: i) }
    }
    private static func addressHash(_ value: String) -> String { AgentFiles.hash(Data(value.utf8)) }
    @objc private func changeRemote() { updateAddresses(); editDraft(destinationChanged: true) }
    @objc private func changeAddress() { editDraft(destinationChanged: true) }
    @objc private func changeUpstream() { editDraft() }
    func controlTextDidChange(_ obj: Notification) { editDraft() }
    private func editDraft(destinationChanged: Bool = false) {
        guard !busy, writable, let scope else { return }
        if draft == nil || destinationChanged {
            let name = remote.titleOfSelectedItem, hash = address.titleOfSelectedItem.map(Self.addressHash)
            if draft == nil { draft = .init(scope: scope, branch: "", upstream: false) }
            draft?.remote = name; draft?.addressHash = hash
        }
        draft?.branch = (branch.currentEditor() as? NSTextView)?.string ?? branch.stringValue
        draft?.upstream = upstream.state == .on
        restoreDraftFocus = false; _ = captureDraft(); invalidate(); onDraftChange?()
    }
    func captureDraft() -> AgentGitDraftRecovery.Push? {
        if draft != nil, !restoreDraftFocus {
            if let editor = branch.currentEditor() as? NSTextView {
                let range = editor.selectedRange(), selection = AgentTextViewport.Selection(location: range.location, length: range.length)
                if selection.valid(in: draft?.branch.utf16.count ?? 0) { draft?.selection = selection }
                draft?.focused = presentingWindow?.firstResponder === editor
            } else if isPageVisible, !busy { draft?.focused = false }
        }
        return draft
    }
    @objc private func branchSelectionChanged(_ notification: Notification) {
        guard draft != nil, !restoreDraftFocus, let editor = notification.object as? NSTextView,
              editor === branch.currentEditor(), editor === presentingWindow?.firstResponder else { return }
        _ = captureDraft(); onDraftChange?()
    }
    private func requestDraftFocus() {
        guard restoreDraftFocus, !busy else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, restoreDraftFocus, !busy, isPageVisible, branch.isEnabled,
                  let window = presentingWindow, !window.hasBlockingDialog,
                  window.makeFirstResponder(branch), let editor = branch.currentEditor() as? NSTextView else { return }
            if let selection = draft?.selection { editor.setSelectedRange(selection.range) }
            restoreDraftFocus = false
        }
    }
    private func parkDraft() {
        guard let onDraftClose else { return }
        self.onDraftClose = nil
        var saved = captureDraft(); saved?.opened = false; onDraftClose(saved)
    }
    @objc private func invalidate() { review = nil; render(""); count.stringValue = ""; inspectCommit.removeAllItems(); inspectCommit.addItem(withTitle: "待推送整体变更"); state.textColor = AgentWorkbenchTheme.secondaryText; state.stringValue = ""; controls() }
    @objc private func changeDisplay() {
        let split = review != nil && displayMode.selectedSegment == 1, wraps = wrap.state == .on
        if diffView.splitMode != split { diffView.splitMode = split }
        if diffView.wraps != wraps { diffView.wraps = wraps }
    }
    private func render(_ patch: String, oldTitle: String = "远端", newTitle: String = "本地") {
        diffView.show(patch, oldTitle: oldTitle, newTitle: newTitle, accessibilityContext: "待推送"); changeDisplay()
    }
    private func renderReview(_ value: AgentGitPushReview) {
        render(value.diff + (value.diffTruncated ? "\n[差异已截取；可选择具体提交查看]" : ""), oldTitle: value.remoteHead == nil ? "空版本" : "远端")
    }
    private func show(_ value: AgentGitPushReview) {
        review = value; branch.stringValue = value.targetBranch; inspectCommit.removeAllItems(); inspectCommit.addItem(withTitle: "待推送整体变更")
        for line in value.commits.split(separator: "\n") {
            let pair = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let item = NSMenuItem(title: String(pair[0].prefix(12)) + " " + pair[1], action: nil, keyEquivalent: ""); item.representedObject = pair[0]; inspectCommit.menu?.addItem(item)
        }
        count.stringValue = "待推送 \(value.commitCount) 项" + (value.commitCount > 100 ? " · 列表显示前100项" : "") + (value.uncommittedFiles > 0 ? " · \(value.uncommittedFiles) 个未提交文件留在本地" : "")
        renderReview(value)
        state.stringValue = value.commitCount == 0 ? "远端已包含目标提交" : value.remoteHead == nil ? "将在远端创建分支" : "已核对远端分支"
        controls()
    }
    @objc private func preparePush() {
        guard !busy, writable, let scope, remotes.indices.contains(remote.indexOfSelectedItem), address.indexOfSelectedItem >= 0 else { return }
        branch.validateEditing()
        editDraft()
        let name = remotes[remote.indexOfSelectedItem].name, index = address.indexOfSelectedItem, target = branch.stringValue, wantsUpstream = upstream.state == .on, hash = remoteHash
        review = nil; busy = true; controls(); state.textColor = AgentWorkbenchTheme.secondaryText; state.stringValue = "检查远端并准备提交…"
        job = Task { [weak self] in
            guard let self else { return }
            do { let value = try await git.preparePush(remote: name, urlIndex: index, branch: target, setUpstream: wantsUpstream, remoteHash: hash, draftScope: scope); show(value) }
            catch { showError(error) }
            busy = false; controls()
        }
    }
    @objc private func sendPush() {
        guard !busy, writable, let scope, let value = review, value.commitCount > 0 else { return }
        do { try scope.requireCurrent(store.task(taskID), preserving: "请重新检查远端") }
        catch { invalidate(); showError(error); return }
        let alert = AgentConfirmation(); alert.messageText = "推送 \(value.commitCount) 项提交？"; alert.informativeText = value.summary; alert.addButton(withTitle: "推送"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; sending = true; controls(); state.textColor = AgentWorkbenchTheme.secondaryText; state.stringValue = "推送中…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await git.push(reviewHash: value.hash, draftScope: scope)
                if receipt.verified { discardDraft(); onDraftChange?() }
                state.stringValue = receipt.verified ? "远端已核对 · " + String(receipt.sourceHead.prefix(12)) + (receipt.localUpdate.isEmpty ? "" : " · " + receipt.localUpdate) : "结果待核对，请核对上次结果"
                count.stringValue = receipt.verified ? "已推送 \(value.commitCount) 项" : ""
                inspectCommit.removeAllItems(); inspectCommit.addItem(withTitle: "推送结果")
                review = nil; render(receipt.output); onReceipt?(receipt)
            } catch { showError(error); review = nil }
            busy = false; sending = false; controls()
        }
    }
    @objc private func stopJob() { job?.cancel(); git.cancel() }
    @objc private func verifyPush() {
        guard !busy, let receipt = store.task(taskID)?.gitPushReceipt else { return }
        busy = true; controls(); state.textColor = AgentWorkbenchTheme.secondaryText; state.stringValue = "核对远端结果…"
        job = Task { [weak self] in
            guard let self else { return }
            do { let result = try await AgentGitTransport.verifyReceipt(store: store, taskID: taskID, operationID: receipt.id); state.stringValue = result.verified ? "远端与目标提交一致 · " + String(result.sourceHead.prefix(12)) : "远端当前未指向目标提交"; onReceipt?(result) }
            catch { showError(error) }
            busy = false; controls()
        }
    }
    @objc private func selectCommit() {
        guard !busy, let value = review else { return }
        guard let oid = inspectCommit.selectedItem?.representedObject as? String else { renderReview(value); return }
        guard oid.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil else { return }
        busy = true; controls(); state.textColor = AgentWorkbenchTheme.secondaryText
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let transport = try AgentGitTransport(store: store, taskID: taskID, sessionID: value.sessionID)
                let result = try await transport.run(["-C", transport.repository.path, "show", "--no-ext-diff", "--no-textconv", "--no-color", "--format=medium", "--stat", "-p", oid, "--"], maximumOutput: 200_000)
                guard !result.failed else { throw PetError(result.text) }; render((result.stdout ?? "") + (result.truncated == true ? "\n[此提交差异已截取]" : ""), oldTitle: "父版本", newTitle: "当前提交")
            } catch { showError(error) }
            busy = false; controls()
        }
    }
    @objc private func addRemote() {
        guard !busy, writable, let scope else { return }
        do { try presentRemoteForm(scope: scope) }
        catch { showError(error) }
    }
    func restoreRemoteForm(_ saved: AgentGitDraftRecovery.RemoteForm) throws {
        try presentRemoteForm(scope: saved.scope, recovery: saved)
    }
    private func presentRemoteForm(scope: AgentGitDraftRecovery.Scope, recovery: AgentGitDraftRecovery.RemoteForm? = nil) throws {
        guard remotePage == nil else { throw PetError("当前已打开远端编辑") }
        try scope.requireCurrent(store.task(taskID), preserving: "添加远端草稿已保留")
        let page = AgentGitRemotePage(git: git, store: store, taskID: taskID, scope: scope, recovery: recovery) { [weak self] in self?.load(focusRemote: true) }
        page.onDraftChange = { [weak self] in self?.onDraftChange?() }
        page.onLeave = { [weak self] in
            guard let self else { return }
            remotePage = nil; onDraftChange?()
        }
        if settingsHostWindow != nil {
            presentSettingsChild(page)
            guard page.settingsHostWindow != nil else { page.endSettingsHosting(); throw PetError("工作区当前无法打开远端草稿") }
            remotePage = page; onDraftChange?(); return
        }
        guard let window, let original = window.contentView, let body = page.settingsContent(in: window) else { throw PetError("无法打开添加远端表单") }
        let back = NSButton(title: "返回推送", target: self, action: #selector(closeRemotePage))
        back.isBordered = false; back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil); back.imagePosition = .imageLeading; back.setAccessibilityLabel("返回推送"); back.keyEquivalent = "\u{1b}"
        let heading = NSTextField(labelWithString: "添加 Git 远端"); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let column = NSStackView(views: [back, heading, body]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 12; column.distribution = .fill
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), column.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18), back.heightAnchor.constraint(equalToConstant: 28), body.widthAnchor.constraint(equalTo: column.widthAnchor)])
        pushContent = original; remotePage = page
        page.onSettingsClose = { [weak self] in self?.closeRemotePage() }
        window.contentView = content; content.layoutSubtreeIfNeeded(); page.settingsDidAppear()
    }
    @objc private func closeRemotePage() {
        guard remotePage?.canLeaveSettings() == true else { return }; restorePushPage()
        if add.isEnabled { presentingWindow?.makeFirstResponder(add) }
    }
    private func restorePushPage() {
        guard let pushContent, let page = remotePage else { return }
        self.pushContent = nil; page.endSettingsHosting(); window?.contentView = pushContent
    }
    func checkLayout(_ output: URL) async -> [String: Bool] {
        let deadline = Date().addingTimeInterval(20)
        while busy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        var checks: [String: Bool] = ["pushWindowShowsActualConfiguredRemote": !remotes.isEmpty && !address.itemTitles.isEmpty]
        for (name, size) in [("normal", NSSize(width: 860, height: 650)), ("narrow", NSSize(width: 640, height: 460))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["pushWindowLayout-" + name] = !branch.hasAmbiguousLayout && branch.bounds.width > 100 && diffView.bounds.height > 100 && !push.hasAmbiguousLayout
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("git-push-" + name + ".png")) }
        }
        return checks
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        let items: [NSView] = [remoteFrame, addressFrame, branch, commitFrame, upstream, add, prepare, push, stop, verify, refresh, displayMode, wrap]
        let controls = items.filter { !$0.isHiddenOrHasHiddenAncestor }.map { view in
            let rect = content.convert(view.bounds, from: view)
            return ["label": view.accessibilityLabel() ?? (view as? NSButton)?.title ?? "", "frame": [rect.minX, rect.minY, rect.width, rect.height], "inside": content.bounds.insetBy(dx: -1, dy: -1).contains(rect)] as [String: Any]
        }
        func frame(_ view: NSView) -> [CGFloat] { let r = content.convert(view.bounds, from: view); return [r.minX, r.minY, r.width, r.height] }
        return ["taskID": taskID, "busy": busy, "sending": sending, "remote": remote.titleOfSelectedItem ?? "", "address": address.titleOfSelectedItem ?? "", "branch": branch.stringValue, "count": count.stringValue, "state": state.stringValue, "stateIsError": state.textColor == AgentDialogStyle.error, "diff": diffView.patch, "diffReader": diffView.readingReadback(), "reviewHash": review?.hash ?? "", "pushEnabled": push.isEnabled, "usesMainWindow": settingsHostWindow != nil && pageContentView?.window === presentingWindow, "standaloneRemotePage": pushContent != nil, "windowSize": [Double(window?.contentView?.bounds.width ?? 0), Double(window?.contentView?.bounds.height ?? 0)], "contentSize": [content.bounds.width, content.bounds.height], "controls": controls, "popupFrames": [frame(remoteFrame), frame(addressFrame), frame(commitFrame)], "branchFrame": frame(branch), "diffFrame": frame(diffView), "stateFrame": frame(state)]
    }
    func checkPrepare() async {
        guard AgentTaskWorkspace.readbackEnabled else { return }
        let deadline = Date().addingTimeInterval(25)
        while busy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        preparePush()
        while busy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
}

@MainActor final class AgentGitRemotePage: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate {
    private typealias Draft = AgentGitDraftRecovery.RemoteForm
    private let git: AgentGit, store: AgentStore, taskID: String, onAdded: () -> Void
    private let scope: AgentGitDraftRecovery.Scope
    private let name = AgentDialogTextField(string: "origin"), address = AgentDialogTextField(), state = AgentSettingsStatusField("远端保存状态"), save = AgentDialogButton(title: "添加远端", target: nil, action: nil)
    private var job: Task<Void, Never>?
    private var focus: Draft.Field = .address, selections: [Draft.Field: AgentTextViewport.Selection] = [:]
    private var applyingFocus = false, restorePending = false
    private let activity = UUID()
    var onDraftChange: (() -> Void)?
    var onLeave: (() -> Void)?
    private var isEdited: Bool { liveValue(name) != "origin" || !liveValue(address).isEmpty }
    var hasPendingChanges: Bool { job != nil || isEdited }
    var canPreserveForQuit: Bool { job == nil && isEdited && Draft.canPreserve(name: liveValue(name), address: liveValue(address)) }
    init(git: AgentGit, store: AgentStore, taskID: String, scope: AgentGitDraftRecovery.Scope, recovery: AgentGitDraftRecovery.RemoteForm?, onAdded: @escaping () -> Void) {
        self.git = git; self.store = store; self.taskID = taskID; self.scope = scope; self.onAdded = onAdded
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "添加 Git 远端"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        name.setAccessibilityLabel("新远端名称"); address.setAccessibilityLabel("新远端地址"); address.placeholderString = "SSH、HTTPS 或本机仓库地址"
        for field in [name, address] { field.delegate = self; field.outlined = true; field.heightAnchor.constraint(equalToConstant: 32).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        if let recovery {
            name.stringValue = recovery.name; address.stringValue = recovery.address
            focus = recovery.focus; selections = [.name: recovery.nameSelection, .address: recovery.addressSelection].compactMapValues { $0 }
            restorePending = true
        }
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText; state.setAccessibilityLabel("远端保存状态")
        save.target = self; save.action = #selector(addRemote); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        AgentDialogStyle.action(save, prominent: true)
        let labels = [NSTextField(labelWithString: "名称"), NSTextField(labelWithString: "地址")]; for label in labels { label.font = .systemFont(ofSize: 13) }
        let actions = NSStackView(views: [NSView(), save]), column = NSStackView(views: [labels[0], name, labels[1], address, state, actions, NSView()])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 12; column.distribution = .fill
        content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for view in [name, address, state, actions] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), column.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func liveValue(_ field: NSTextField) -> String { (field.currentEditor() as? NSTextView)?.string ?? field.stringValue }
    private func rememberSelection() {
        guard !applyingFocus, !restorePending, let editor = presentingWindow?.firstResponder as? NSTextView else { return }
        if editor === name.currentEditor() { focus = .name }
        else if editor === address.currentEditor() { focus = .address }
        else { return }
        let range = editor.selectedRange()
        selections[focus] = .init(location: range.location, length: range.length)
    }
    @objc private func selectionChanged(_ notification: Notification) {
        guard !applyingFocus, !restorePending, let editor = notification.object as? NSTextView,
              editor === presentingWindow?.firstResponder, editor === name.currentEditor() || editor === address.currentEditor() else { return }
        rememberSelection(); onDraftChange?()
    }
    func controlTextDidChange(_ notification: Notification) {
        restorePending = false; rememberSelection(); state.stringValue = ""; onDraftChange?()
    }
    func captureDraft() -> AgentGitDraftRecovery.RemoteForm? {
        let remote = liveValue(name), url = liveValue(address)
        guard (remote != "origin" || !url.isEmpty), Draft.canPreserve(name: remote, address: url) else { return nil }
        rememberSelection()
        let nameSelection = selections[.name].flatMap { $0.valid(in: remote.utf16.count) ? $0 : nil }
        let addressSelection = selections[.address].flatMap { $0.valid(in: url.utf16.count) ? $0 : nil }
        return .init(scope: scope, name: remote, address: url, focus: focus, nameSelection: nameSelection, addressSelection: addressSelection)
    }
    override func settingsDidAppear() {
        if restorePending || !selections.isEmpty {
            restorePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, restorePending else { return }
                _ = restoreFocus()
            }
        } else if !restoreFocus() { DispatchQueue.main.async { [weak self] in _ = self?.restoreFocus() } }
    }
    @discardableResult private func restoreFocus() -> Bool {
        guard job == nil, isPageVisible, let host = presentingWindow, !host.hasBlockingDialog else { return false }
        let field = focus == .name ? name : address
        applyingFocus = true; defer { applyingFocus = false }
        if field.currentEditor() == nil || field.currentEditor() !== host.firstResponder {
            guard host.makeFirstResponder(field) else { return false }
        }
        guard let editor = field.currentEditor() as? NSTextView else { return false }
        if let selection = selections[focus], selection.valid(in: editor.string.utf16.count) { editor.setSelectedRange(selection.range) }
        restorePending = false
        return true
    }
    override func settingsWillLeave() { onLeave?(); onLeave = nil; onDraftChange = nil }
    private func resetInputs() {
        name.abortEditing(); address.abortEditing(); name.stringValue = "origin"; address.stringValue = ""
        focus = .address; selections = [:]; restorePending = false; onDraftChange?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard job == nil else { state.stringValue = "请等待远端保存完成"; return false }
        guard isEdited else { return true }
        let detail = Draft.canPreserve(name: liveValue(name), address: liveValue(address)) ? "" : "请缩短输入或移除登录信息，以保存草稿。"
        guard AgentUnsavedChanges.discard("放弃远端编辑？", detail: detail, discardTitle: "放弃编辑", owner: presentingWindow) else { return false }
        resetInputs(); return true
    }
    func windowWillClose(_ notification: Notification) { job?.cancel(); store.worktreeRetention.setNativeOperation(activity, taskID: taskID, busy: false) }
    @objc private func addRemote() {
        guard job == nil, let task = store.task(taskID), !task.archived, ![.running, .waiting].contains(task.status) else { return }
        rememberSelection()
        name.validateEditing(); address.validateEditing()
        let remote = name.stringValue, url = address.stringValue
        for field in [name, address, save] as [NSControl] { field.isEnabled = false }
        state.stringValue = "保存远端…"; store.worktreeRetention.setNativeOperation(activity, taskID: taskID, busy: true)
        job = Task { [weak self] in
            guard let self else { return }
            do {
                try await git.addRemote(name: remote, url: url, draftScope: scope)
                job = nil; store.worktreeRetention.setNativeOperation(activity, taskID: taskID, busy: false); resetInputs(); onAdded(); close()
            } catch {
                job = nil; store.worktreeRetention.setNativeOperation(activity, taskID: taskID, busy: false)
                for field in [name, address, save] as [NSControl] { field.isEnabled = true }
                state.stringValue = error.localizedDescription; state.textColor = AgentDialogStyle.error; restoreFocus(); onDraftChange?()
            }
        }
    }
}
