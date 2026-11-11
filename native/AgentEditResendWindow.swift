import AppKit

@MainActor final class AgentEditResendWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let store: AgentStore, runtime: AgentRuntime, taskID: String, messageID: String, original: String
    private let editor = NSTextView(), notice = NSTextField(wrappingLabelWithString: ""), state = NSTextField(wrappingLabelWithString: "")
    private let send = NSButton(title: "重新发送", target: nil, action: nil)
    private var reviewWindow: AgentRoundRollbackWindow?, currentReview: AgentEditResend.Review?, applying = false
    var beforeApply: (() throws -> Void)?
    var onSent: ((String) -> Void)?
    init(store: AgentStore, runtime: AgentRuntime, taskID: String, messageID: String) throws {
        let review = try AgentEditResend.review(taskID: taskID, messageID: messageID, store: store)
        guard let task = store.task(taskID), let message = task.messages.first(where: { $0.id == messageID }) else { throw PetError("原始要求已变化") }
        self.store = store; self.runtime = runtime; self.taskID = taskID; self.messageID = messageID; original = message.content
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 350), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "编辑并重发 · " + task.title; window.minSize = NSSize(width: 480, height: 300); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        editor.isRichText = false; editor.font = .systemFont(ofSize: 14); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = .width; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8); editor.string = original; editor.delegate = self; editor.allowsUndo = true; editor.setAccessibilityLabel("修改后的要求")
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
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
    func textDidChange(_ notification: Notification) { update() }
    private func update() {
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let review = currentReview else { send.isEnabled = false; return }
        notice.stringValue = review.notice; send.title = review.rollback == nil ? "重新发送" : "审阅文件并重发…"; send.setAccessibilityLabel(send.title)
        send.isEnabled = !applying && review.canApply && !text.isEmpty && text != original.trimmingCharacters(in: .whitespacesAndNewlines) && text.utf8.count <= 100_000
        state.stringValue = (review.rollback?.issues ?? []).prefix(2).joined(separator: "\n")
    }
    @objc private func refresh() {
        do {
            currentReview = try AgentEditResend.review(taskID: taskID, messageID: messageID, store: store); update()
        } catch { currentReview = nil; send.isEnabled = false; state.stringValue = error.localizedDescription }
    }
    @objc private func resend() {
        guard !applying else { return }
        do {
            try beforeApply?()
            let review = try AgentEditResend.review(taskID: taskID, messageID: messageID, store: store), text = editor.string
            if review.rollback != nil {
                if reviewWindow?.window?.isVisible == true { reviewWindow?.window?.makeKeyAndOrderFront(nil); return }
                let panel = AgentRoundRollbackWindow(store: store, taskID: taskID, messageID: messageID, actionTitle: "重新发送", notice: review.notice)
                var sentID: String?
                panel.beforeApply = beforeApply
                panel.performReview = { [weak self] files in
                    guard let self, editor.string == text else { throw PetError("输入已变化，请关闭审阅窗口后重新检查") }
                    let current = try AgentEditResend.review(taskID: taskID, messageID: messageID, store: store)
                    guard current.rollback?.fingerprint == files.fingerprint else { throw PetError("文件或任务已变化，请重新审阅") }
                    sentID = try AgentEditResend.apply(current, text: text, store: store, runtime: runtime)
                }
                panel.onComplete = { [weak self] in if let sentID { self?.onSent?(sentID); self?.close() } }
                reviewWindow = panel; panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil)
            } else {
                applying = true; send.isEnabled = false
                let id = try AgentEditResend.apply(review, text: text, store: store, runtime: runtime)
                applying = false; onSent?(id); close()
            }
        } catch { applying = false; update(); state.stringValue = error.localizedDescription }
    }
    @objc private func cancel() { if !applying { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !applying }
    func windowWillClose(_ notification: Notification) { reviewWindow?.window?.performClose(nil) }
}
