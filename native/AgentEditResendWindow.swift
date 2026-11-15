import AppKit

@MainActor final class AgentEditResendWindow: AgentSettingsPageController, NSWindowDelegate, NSTextViewDelegate {
    private let store: AgentStore, runtime: AgentRuntime, taskID: String, messageID: String, original: String, originalHash: String
    private let editor = NSTextView(), scroll = NSScrollView(), notice = NSTextField(wrappingLabelWithString: ""), state = NSTextField(wrappingLabelWithString: "")
    private let send = NSButton(title: "重新发送", target: nil, action: nil)
    private var reviewWindow: AgentRoundRollbackWindow?, currentReview: AgentEditResend.Review?, applying = false, completed = false
    var onWorkspaceChange: (() -> Void)?
    var beforeApply: (() throws -> Void)?
    var onSent: ((String) -> Void)?
    static func title(task: AgentTaskRecord, messageID: String) -> String? {
        let inputs = task.messages.filter(\.isHumanInput)
        guard let index = inputs.firstIndex(where: { $0.id == messageID }) else { return nil }
        let text = String(inputs[index].content.prefix(160)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let label = "编辑 \(index + 1)"
        return text.isEmpty ? label : label + " · " + String(text.prefix(48)) + (text.count > 48 ? "…" : "")
    }
    init(store: AgentStore, runtime: AgentRuntime, taskID: String, messageID: String) throws {
        let review = try AgentEditResend.review(taskID: taskID, messageID: messageID, store: store)
        guard let task = store.task(taskID), let message = task.messages.first(where: { $0.id == messageID }) else { throw PetError("原始要求已变化") }
        self.store = store; self.runtime = runtime; self.taskID = taskID; self.messageID = messageID; original = message.content
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        originalHash = AgentFiles.hash(try encoder.encode(message))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 350), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Self.title(task: task, messageID: messageID) ?? "编辑并重发"; window.minSize = NSSize(width: 480, height: 300); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        editor.isRichText = false; editor.font = .systemFont(ofSize: 14); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = .width; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8); editor.string = original; editor.delegate = self; editor.allowsUndo = true; editor.setAccessibilityLabel("修改后的要求")
        scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(recoveryViewChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        notice.stringValue = review.notice; notice.font = .systemFont(ofSize: 12); notice.textColor = AgentWorkbenchTheme.secondaryText
        state.font = .systemFont(ofSize: 12); state.textColor = .systemRed
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let refresh = NSButton(title: "重新检查", target: self, action: #selector(refresh))
        send.target = self; send.action = #selector(resend)
        let buttons = NSStackView(views: [refresh, NSView(), cancel, send]); buttons.spacing = 8
        for view in [scroll, notice, state, buttons] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            notice.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10), notice.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), notice.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            state.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 6), state.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), state.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: state.bottomAnchor, constant: 10), buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        window.initialFirstResponder = editor; currentReview = review; update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var boundTaskID: String { taskID }
    var hasPendingOperation: Bool { applying || reviewWindow?.hasPendingOperation == true }
    var workspaceHasUnsavedChanges: Bool { !completed && editor.string != original }
    var canPreserveForQuit: Bool { !completed && !hasPendingOperation && store.task(taskID).map { $0.sideTask?.retained != false } == true }
    func prepareWorkspaceNavigation() -> Bool { !hasPendingOperation }
    struct RecoveryState: Codable {
        var version = 1
        var taskID: String, messageID: String, originalHash: String, text: String
        var selectionLocation: Int, selectionLength: Int
        var scrollY: Double
    }
    static func recoveryState(_ page: AgentWorkspaceRecovery.Page) throws -> RecoveryState {
        guard page.kind == "edit-resend", page.asset == nil,
              let object = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "taskID", "messageID", "originalHash", "text", "selectionLocation", "selectionLength", "scrollY"]) else { throw PetError("编辑重发恢复格式不受支持，原草稿已保留") }
        let value = try JSONDecoder().decode(RecoveryState.self, from: page.state), count = (value.text as NSString).length
        guard value.version == 1, value.taskID == page.taskID, UUID(uuidString: value.taskID) != nil, UUID(uuidString: value.messageID) != nil,
              value.originalHash.count == 64, value.originalHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              (0...count).contains(value.selectionLocation), (0...(count - value.selectionLocation)).contains(value.selectionLength),
              value.scrollY.isFinite, (0...1_000_000_000).contains(value.scrollY) else { throw PetError("编辑重发恢复版本或选择范围无效，原草稿已保留") }
        return value
    }
    func captureWorkspaceRecovery() throws -> AgentWorkspaceRecovery.Page {
        guard !completed, !hasPendingOperation else { throw PetError("请先完成当前重发或文件审阅操作") }
        let selection = editor.selectedRange()
        let value = RecoveryState(taskID: taskID, messageID: messageID, originalHash: originalHash, text: editor.string,
            selectionLocation: selection.location, selectionLength: selection.length, scrollY: scroll.contentView.bounds.minY)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let page = AgentWorkspaceRecovery.Page(taskID: taskID, kind: "edit-resend", state: try encoder.encode(value), dirty: workspaceHasUnsavedChanges, asset: nil)
        _ = try Self.recoveryState(page); return page
    }
    func restoreWorkspaceRecovery(_ page: AgentWorkspaceRecovery.Page) throws {
        let value = try Self.recoveryState(page)
        guard value.taskID == taskID, value.messageID == messageID, value.originalHash == originalHash,
              page.dirty == (value.text != original) else { throw PetError("恢复编辑所属的原消息已变化，原草稿已保留") }
        editor.string = value.text; editor.setSelectedRange(NSRange(location: value.selectionLocation, length: value.selectionLength))
        update(); presentingWindow?.contentView?.layoutSubtreeIfNeeded()
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: value.scrollY)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func recoveryViewChanged(_ notification: Notification) { if !completed { onWorkspaceChange?() } }
    func textViewDidChangeSelection(_ notification: Notification) { recoveryViewChanged(notification) }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        if let content = pageContentView { content.effectiveAppearance.performAsCurrentDrawingAppearance { AgentSettingsStyle.prepare(content) } }
        if isPageVisible { presentingWindow?.makeFirstResponder(editor) }
    }
    override func settingsWillLeave() { onWorkspaceChange = nil }
    func textDidChange(_ notification: Notification) { update() }
    private func update() {
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let review = currentReview else { send.isEnabled = false; return }
        notice.stringValue = review.notice; send.title = review.rollback == nil ? "重新发送" : "审阅文件并重发…"; send.setAccessibilityLabel(send.title)
        send.isEnabled = !applying && review.canApply && !text.isEmpty && text != original.trimmingCharacters(in: .whitespacesAndNewlines) && text.utf8.count <= 100_000
        state.stringValue = (review.rollback?.issues ?? []).prefix(2).joined(separator: "\n"); onWorkspaceChange?()
    }
    @objc private func refresh() {
        do {
            currentReview = try AgentEditResend.review(taskID: taskID, messageID: messageID, store: store); update()
        } catch { currentReview = nil; send.isEnabled = false; state.stringValue = error.localizedDescription }
    }
    @objc private func resend() { performResend() }
    private func finishSend(_ id: String) { completed = true; applying = false; onSent?(id); close() }
    private func performResend(startImmediately: Bool = true) {
        guard !applying else { return }
        do {
            try beforeApply?()
            let review = try AgentEditResend.review(taskID: taskID, messageID: messageID, store: store), text = editor.string
            if review.rollback != nil {
                if reviewWindow?.isPageVisible == true { reviewWindow?.presentingWindow?.makeKeyAndOrderFront(nil); return }
                let panel = AgentRoundRollbackWindow(store: store, taskID: taskID, messageID: messageID, actionTitle: "重新发送", notice: review.notice)
                var sentID: String?
                panel.beforeApply = beforeApply
                panel.performReview = { [weak self] files in
                    guard let self, editor.string == text else { throw PetError("输入已变化，请返回编辑页后重新审阅") }
                    let current = try AgentEditResend.review(taskID: taskID, messageID: messageID, store: store)
                    guard current.rollback?.fingerprint == files.fingerprint else { throw PetError("文件或任务已变化，请重新审阅") }
                    sentID = try AgentEditResend.apply(current, text: text, store: store, runtime: runtime, startImmediately: startImmediately)
                }
                panel.onComplete = { [weak self] in if let sentID { self?.finishSend(sentID) } }
                reviewWindow = panel; presentSettingsChild(panel)
            } else {
                applying = true; send.isEnabled = false
                let id = try AgentEditResend.apply(review, text: text, store: store, runtime: runtime, startImmediately: startImmediately)
                finishSend(id)
            }
        } catch { applying = false; update(); state.stringValue = error.localizedDescription }
    }
    @objc private func cancel() { if settingsHostWindow != nil { close() } else { window?.performClose(nil) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !hasPendingOperation else { return false }
        guard workspaceHasUnsavedChanges else { return true }
        return AgentUnsavedChanges.discard("放弃修改后的要求？", detail: (window?.title ?? "编辑并重发") + "\n原任务与未发送的任务草稿会保留。", discardTitle: "放弃修改", owner: presentingWindow)
    }
    func windowWillClose(_ notification: Notification) { if reviewWindow?.settingsHostWindow == nil { reviewWindow?.window?.performClose(nil) }; settingsWillLeave() }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled, let content = pageContentView else { return [:] }
        func inside(_ view: NSView) -> Bool { content.bounds.insetBy(dx: -1, dy: -1).contains(view.convert(view.bounds, to: content)) }
        return ["taskID": taskID, "messageID": messageID, "visible": isPageVisible, "busy": hasPendingOperation, "dirty": workspaceHasUnsavedChanges, "text": editor.string, "original": original, "notice": notice.stringValue, "status": state.stringValue, "sendEnabled": send.isEnabled, "sendTitle": send.title, "editorFocused": presentingWindow?.firstResponder === editor, "selectionLocation": editor.selectedRange().location, "selectionLength": editor.selectedRange().length, "scrollY": Double(scroll.contentView.bounds.minY), "checks": ["editedInputFitsPage": inside(editor.enclosingScrollView!), "editedInputHasUsableHeight": editor.enclosingScrollView!.bounds.height >= 100, "resendButtonFitsPage": inside(send), "resendNoticeFitsPage": inside(notice)]]
    }
    func checkAction(_ action: String = "", text: String? = nil) {
        guard ["--conversation-workspace-check", "--workspace-edit-recovery-check", "--workspace-edit-recovery-ui"].contains(where: CommandLine.arguments.contains) else { return }
        if let text { editor.string = text; update() }
        if action == "refresh" { refresh() }; if action == "send" { performResend(startImmediately: false) }; if action == "cancel" { cancel() }
    }
    func checkRecoveryView(_ range: NSRange, scrollY: Double) {
        guard ["--workspace-edit-recovery-check", "--workspace-edit-recovery-ui"].contains(where: CommandLine.arguments.contains) else { return }
        editor.setSelectedRange(range); presentingWindow?.contentView?.layoutSubtreeIfNeeded()
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scrollY)); scroll.reflectScrolledClipView(scroll.contentView)
        onWorkspaceChange?()
    }
}
