import AppKit

@MainActor final class AgentGitPushWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let store: AgentStore, taskID: String, git: AgentGit
    private let remote = NSPopUpButton(), address = NSPopUpButton(), branch = NSTextField(), source = NSTextField(labelWithString: ""), count = NSTextField(labelWithString: "")
    private let upstream = NSButton(checkboxWithTitle: "设为上游", target: nil, action: nil), inspectCommit = NSPopUpButton()
    private let add = NSButton(title: "添加远端", target: nil, action: nil), prepare = NSButton(title: "检查远端", target: nil, action: nil), push = NSButton(title: "推送", target: nil, action: nil)
    private let refresh = NSButton(title: "刷新", target: nil, action: nil)
    private let stop = NSButton(title: "停止", target: nil, action: nil), verify = NSButton(title: "核对上次结果", target: nil, action: nil), state = NSTextField(labelWithString: ""), text = NSTextView()
    private var remotes: [AgentGitRemote] = [], remoteHash = "", review: AgentGitPushReview?, job: Task<Void, Never>?, busy = false, sending = false
    var onReceipt: ((AgentGitPushReceipt) -> Void)?
    init(store: AgentStore, taskID: String, directory: URL) throws {
        self.store = store; self.taskID = taskID; git = try AgentGit(store: store, taskID: taskID, directory: directory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "推送 · " + git.files.root.lastPathComponent; window.minSize = NSSize(width: 640, height: 460); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.center()
        super.init(window: window); window.delegate = self
        let content = NSView(); content.wantsLayer = true; content.layer?.backgroundColor = AgentWorkbenchTheme.surface.cgColor; window.contentView = content
        source.font = .systemFont(ofSize: 13, weight: .medium); source.lineBreakMode = .byTruncatingMiddle
        count.font = .systemFont(ofSize: 12); count.textColor = .secondaryLabelColor; count.lineBreakMode = .byTruncatingTail
        branch.placeholderString = "目标分支"; branch.setAccessibilityLabel("推送目标分支"); branch.target = self; branch.action = #selector(invalidate)
        branch.delegate = self
        remote.setAccessibilityLabel("推送远端"); address.setAccessibilityLabel("推送地址"); inspectCommit.setAccessibilityLabel("待推送提交")
        remote.target = self; remote.action = #selector(changeRemote); address.target = self; address.action = #selector(invalidate)
        upstream.target = self; upstream.action = #selector(invalidate); inspectCommit.target = self; inspectCommit.action = #selector(selectCommit)
        for button in [add, prepare, push, stop, verify, refresh] { button.target = self }
        add.action = #selector(addRemote); prepare.action = #selector(preparePush); push.action = #selector(sendPush); stop.action = #selector(stopJob); verify.action = #selector(verifyPush)
        refresh.action = #selector(reload)
        push.keyEquivalent = ""; stop.isHidden = true
        func label(_ title: String) -> NSTextField { let field = NSTextField(labelWithString: title); field.font = .systemFont(ofSize: 12); field.widthAnchor.constraint(equalToConstant: 44).isActive = true; return field }
        remote.widthAnchor.constraint(equalToConstant: 130).isActive = true
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); address.cell?.lineBreakMode = .byTruncatingMiddle
        inspectCommit.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); inspectCommit.cell?.lineBreakMode = .byTruncatingTail
        branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [source, NSView(), refresh, add]), destination = NSStackView(views: [label("远端"), remote, address]), target = NSStackView(views: [label("分支"), branch, upstream, prepare])
        for row in [header, destination, target] { row.spacing = 10 }
        let top = NSStackView(views: [header, destination, target, count, inspectCommit]); top.orientation = .vertical; top.alignment = .leading; top.spacing = 12
        for row in top.arrangedSubviews { row.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true }
        inspectCommit.addItem(withTitle: "待推送整体变更")
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel("待推送实际差异")
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        state.font = .systemFont(ofSize: 12); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail; state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [state, NSView(), verify, stop, push]); bottom.spacing = 10
        for view in [top, scroll, bottom] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), top.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: top.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: top.trailingAnchor), scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -14),
            bottom.leadingAnchor.constraint(equalTo: top.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: top.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var writable: Bool { guard let task = store.task(taskID) else { return false }; return !task.archived && ![.running, .waiting].contains(task.status) }
    private func controls() {
        for control in [remote, address, branch, upstream, prepare, add, refresh] as [NSControl] { control.isEnabled = !busy && writable }
        inspectCommit.isEnabled = !busy && review != nil
        push.isEnabled = !busy && writable && (review?.commitCount ?? 0) > 0
        verify.isHidden = store.task(taskID)?.gitPushReceipt == nil; verify.isEnabled = !busy
        stop.isHidden = !busy
    }
    func windowDidBecomeKey(_ notification: Notification) { controls() }
    func windowWillClose(_ notification: Notification) { job?.cancel(); git.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sending else { return true }
        let alert = NSAlert(); alert.messageText = "停止等待并关闭？"; alert.informativeText = "远端可能已收到提交。关闭后请核对上次结果。"; alert.addButton(withTitle: "停止并关闭"); alert.addButton(withTitle: "继续等待")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func reload() { if !busy { load() } }
    private func load() {
        invalidate(); busy = true; controls(); state.stringValue = "读取 Git…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await git.status(); remotes = try await git.remotes(); remoteHash = store.task(taskID)?.gitRemoteSnapshot?.hash ?? ""
                source.stringValue = status.branch + (status.head.map { " · " + String($0.prefix(12)) } ?? " · 尚无提交")
                remote.removeAllItems(); remote.addItems(withTitles: remotes.map(\.name)); updateAddresses()
                branch.stringValue = status.branch == "分离状态" ? "" : status.branch; upstream.state = status.branch == "分离状态" ? .off : .on
                if let saved = store.task(taskID)?.gitPushReview, saved.processID == AgentGitTransport.processID, saved.sourceHead == status.head, saved.configHash == store.task(taskID)?.gitRemoteSnapshot?.configHash,
                   let i = remotes.firstIndex(where: { $0.name == saved.remote }), remotes[i].urls.indices.contains(saved.urlIndex), remotes[i].urls[saved.urlIndex] == saved.endpoint.location {
                    remote.selectItem(at: i); updateAddresses(); address.selectItem(at: saved.urlIndex); branch.stringValue = saved.targetBranch; upstream.state = saved.setUpstream ? .on : .off; show(saved)
                }
                if review == nil { state.stringValue = remotes.isEmpty ? "请添加 Git 远端" : "" }
            } catch { state.stringValue = error.localizedDescription }
            busy = false; controls()
        }
    }
    private func updateAddresses() {
        address.removeAllItems()
        if remotes.indices.contains(remote.indexOfSelectedItem) { address.addItems(withTitles: remotes[remote.indexOfSelectedItem].urls) }
    }
    @objc private func changeRemote() { updateAddresses(); invalidate() }
    func controlTextDidChange(_ obj: Notification) { invalidate() }
    @objc private func invalidate() { review = nil; text.string = ""; count.stringValue = ""; inspectCommit.removeAllItems(); inspectCommit.addItem(withTitle: "待推送整体变更"); state.stringValue = ""; controls() }
    private func show(_ value: AgentGitPushReview) {
        review = value; branch.stringValue = value.targetBranch; inspectCommit.removeAllItems(); inspectCommit.addItem(withTitle: "待推送整体变更")
        for line in value.commits.split(separator: "\n") {
            let pair = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let item = NSMenuItem(title: String(pair[0].prefix(12)) + " " + pair[1], action: nil, keyEquivalent: ""); item.representedObject = pair[0]; inspectCommit.menu?.addItem(item)
        }
        count.stringValue = "待推送 \(value.commitCount) 项" + (value.commitCount > 100 ? " · 列表显示前100项" : "") + (value.uncommittedFiles > 0 ? " · \(value.uncommittedFiles) 个未提交文件留在本地" : "")
        text.string = value.diff + (value.diffTruncated ? "\n[差异已截取；可选择具体提交查看]" : "")
        state.stringValue = value.commitCount == 0 ? "远端已包含目标提交" : value.remoteHead == nil ? "将在远端创建分支" : "已核对远端分支"
        controls()
    }
    @objc private func preparePush() {
        guard !busy, writable, remotes.indices.contains(remote.indexOfSelectedItem), address.indexOfSelectedItem >= 0 else { return }
        let name = remotes[remote.indexOfSelectedItem].name, index = address.indexOfSelectedItem, target = branch.stringValue, wantsUpstream = upstream.state == .on, hash = remoteHash
        review = nil; busy = true; controls(); state.stringValue = "检查远端并准备提交…"
        job = Task { [weak self] in
            guard let self else { return }
            do { let value = try await git.preparePush(remote: name, urlIndex: index, branch: target, setUpstream: wantsUpstream, remoteHash: hash); show(value) }
            catch { state.stringValue = error.localizedDescription }
            busy = false; controls()
        }
    }
    @objc private func sendPush() {
        guard !busy, writable, let value = review, value.commitCount > 0 else { return }
        let alert = NSAlert(); alert.messageText = "推送 \(value.commitCount) 项提交？"; alert.informativeText = value.summary; alert.addButton(withTitle: "推送"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; sending = true; controls(); state.stringValue = "推送中…"
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await git.push(reviewHash: value.hash)
                state.stringValue = receipt.verified ? "远端已核对 · " + String(receipt.sourceHead.prefix(12)) + (receipt.localUpdate.isEmpty ? "" : " · " + receipt.localUpdate) : "结果待核对，请核对上次结果"
                count.stringValue = receipt.verified ? "已推送 \(value.commitCount) 项" : ""
                inspectCommit.removeAllItems(); inspectCommit.addItem(withTitle: "推送结果")
                text.string = receipt.output; review = nil; onReceipt?(receipt)
            } catch { state.stringValue = error.localizedDescription; review = nil }
            busy = false; sending = false; controls()
        }
    }
    @objc private func stopJob() { job?.cancel(); git.cancel() }
    @objc private func verifyPush() {
        guard !busy, let receipt = store.task(taskID)?.gitPushReceipt else { return }
        busy = true; controls(); state.stringValue = "核对远端结果…"
        job = Task { [weak self] in
            guard let self else { return }
            do { let result = try await AgentGitTransport.verifyReceipt(store: store, taskID: taskID, operationID: receipt.id); state.stringValue = result.verified ? "远端与目标提交一致 · " + String(result.sourceHead.prefix(12)) : "远端当前未指向目标提交"; onReceipt?(result) }
            catch { state.stringValue = error.localizedDescription }
            busy = false; controls()
        }
    }
    @objc private func selectCommit() {
        guard !busy, let value = review else { return }
        guard let oid = inspectCommit.selectedItem?.representedObject as? String else { text.string = value.diff; return }
        guard oid.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil else { return }
        busy = true; controls()
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let transport = try AgentGitTransport(store: store, taskID: taskID, sessionID: value.sessionID)
                let result = try await transport.run(["-C", transport.repository.path, "show", "--no-ext-diff", "--no-textconv", "--no-color", "--format=medium", "--stat", "-p", oid, "--"], maximumOutput: 200_000)
                guard !result.failed else { throw PetError(result.text) }; text.string = (result.stdout ?? "") + (result.truncated == true ? "\n[此提交差异已截取]" : "")
            } catch { state.stringValue = error.localizedDescription }
            busy = false; controls()
        }
    }
    @objc private func addRemote() {
        guard !busy, writable else { return }
        let alert = NSAlert(); alert.messageText = "添加 Git 远端"; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        let name = NSTextField(string: "origin"), url = NSTextField(); name.placeholderString = "名称"; url.placeholderString = "SSH、HTTPS 或本机仓库地址"
        name.setAccessibilityLabel("新远端名称"); url.setAccessibilityLabel("新远端地址")
        let form = NSStackView(views: [name, url]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 10; form.frame = NSRect(x: 0, y: 0, width: 420, height: 62)
        for field in [name, url] { field.widthAnchor.constraint(equalToConstant: 420).isActive = true }
        alert.accessoryView = form; alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; controls()
        job = Task { [weak self] in
            guard let self else { return }
            do { try await git.addRemote(name: name.stringValue, url: url.stringValue); busy = false; load() }
            catch { state.stringValue = error.localizedDescription; busy = false; controls() }
        }
    }
    func checkLayout(_ output: URL) async -> [String: Bool] {
        let deadline = Date().addingTimeInterval(20)
        while busy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        var checks: [String: Bool] = ["pushWindowShowsActualConfiguredRemote": !remotes.isEmpty && !address.itemTitles.isEmpty]
        for (name, size) in [("normal", NSSize(width: 860, height: 650)), ("narrow", NSSize(width: 640, height: 460))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["pushWindowLayout-" + name] = !branch.hasAmbiguousLayout && branch.bounds.width > 100 && text.bounds.height > 100 && !push.hasAmbiguousLayout
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("git-push-" + name + ".png")) }
        }
        return checks
    }
}
