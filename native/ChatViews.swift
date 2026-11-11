import AppKit

final class SidebarBackground: NSView {
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        AgentWorkbenchTheme.sidebar.setFill(); bounds.fill()
    }
}

final class ContentSurface: NSView {
    var onAppearanceChange: (() -> Void)?
    var showsSettings = false { didSet { needsDisplay = true } }
    var usesWorkbenchSurface = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (showsSettings ? AgentWorkbenchTheme.settings : AgentWorkbenchTheme.surface).setFill(); bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true; onAppearanceChange?() }
}

final class ChatMessageRow: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    private(set) var text = ""
    private var renderedMarkdown = true
    private var highlightQuery: String?
    private var highlightDisplayRange: NSRange?, highlightDisplayText: String?
    private(set) var searchRange: NSRange?
    private(set) var searchUsesSource = false
    private let isUser: Bool
    private let workbench: Bool
    private var renderedSize: CGFloat = 0
    private let attachments = AgentAttachmentStrip()
    private let body = NSStackView(), replyActions = NSStackView()
    private let copyReply = NSButton(), helpful = NSButton(), unhelpful = NSButton(), branchReply = NSButton()
    private let roundActions = NSStackView(), rollbackFiles = NSButton(), editInput = NSButton()
    private var onRoundRollback: (() -> Void)?, onEditInput: (() -> Void)?
    private var replyBinding: String?, copiedReset: DispatchWorkItem?
    private var onCopyReply: (() -> Bool)?, onReplyFeedback: ((String) -> Void)?, onBranchReply: (() -> Void)?
    init(message: ChatMessage, workbench: Bool = false) {
        isUser = message.role == "user"; self.workbench = workbench
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(isUser ? "你的消息" : "小鲸回复"); setAccessibilityIdentifier("message-" + message.id)
        let user = message.role == "user", container = AgentThemeView(fill: message.role == "user" && !workbench ? AgentWorkbenchTheme.subtle : .clear)
        container.translatesAutoresizingMaskIntoConstraints = false; container.wantsLayer = true
        container.layer?.cornerRadius = 14; addSubview(container); container.addSubview(body)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 0; body.translatesAutoresizingMaskIntoConstraints = false
        for view in [label, attachments, replyActions, roundActions] as [NSView] { body.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        replyActions.spacing = 8; replyActions.alignment = .centerY; replyActions.isHidden = true
        for (button, title, symbol, action) in [(copyReply, "复制回复", "doc.on.doc", #selector(copyResponse)), (helpful, "有帮助", "hand.thumbsup", #selector(markHelpful)), (unhelpful, "无帮助", "hand.thumbsdown", #selector(markUnhelpful)), (branchReply, "从这条回复创建分支", "arrow.triangle.branch", #selector(branchResponse))] {
            button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.isBordered = false; button.contentTintColor = AgentWorkbenchTheme.secondaryText
            button.target = self; button.action = action; button.toolTip = title; button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true; button.heightAnchor.constraint(equalToConstant: 22).isActive = true; replyActions.addArrangedSubview(button)
        }; replyActions.addArrangedSubview(NSView())
        roundActions.spacing = 6; roundActions.alignment = .centerY; roundActions.isHidden = true
        rollbackFiles.isBordered = false; rollbackFiles.font = .systemFont(ofSize: 12); rollbackFiles.contentTintColor = AgentWorkbenchTheme.secondaryText
        rollbackFiles.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil); rollbackFiles.imagePosition = .imageLeading
        rollbackFiles.target = self; rollbackFiles.action = #selector(rollbackRound); rollbackFiles.heightAnchor.constraint(equalToConstant: 22).isActive = true
        editInput.title = "编辑并重发"; editInput.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil); editInput.imagePosition = .imageLeading
        editInput.isBordered = false; editInput.font = .systemFont(ofSize: 12); editInput.contentTintColor = AgentWorkbenchTheme.secondaryText; editInput.target = self; editInput.action = #selector(editMessage); editInput.setAccessibilityLabel("编辑并重发")
        editInput.heightAnchor.constraint(equalToConstant: 22).isActive = true
        roundActions.addArrangedSubview(editInput); roundActions.addArrangedSubview(rollbackFiles); roundActions.addArrangedSubview(NSView())
        attachments.maximumRows = 6
        label.translatesAutoresizingMaskIntoConstraints = false; label.isSelectable = true; label.allowsEditingTextAttributes = true
        label.font = .systemFont(ofSize: AgentAppearance.messageSize + (workbench ? 0 : 1)); label.textColor = .labelColor
        if workbench { label.lineBreakMode = .byCharWrapping; label.cell?.wraps = true; label.cell?.usesSingleLineMode = false }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset: CGFloat = workbench ? 0 : user ? 15 : 0
        var layout = [container.topAnchor.constraint(equalTo: topAnchor), container.bottomAnchor.constraint(equalTo: bottomAnchor), body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset), body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset), body.topAnchor.constraint(equalTo: container.topAnchor, constant: workbench ? 8 : user ? 11 : 4), body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: workbench ? -8 : user ? -11 : -4)]
        if workbench {
            let mark = NSImageView(image: NSImage(systemSymbolName: user ? "person" : "fish", accessibilityDescription: user ? "你" : "小鲸")!)
            mark.contentTintColor = user ? AgentWorkbenchTheme.secondaryText : AgentWorkbenchTheme.accent; addSubview(mark); mark.translatesAutoresizingMaskIntoConstraints = false
            layout += [mark.leadingAnchor.constraint(equalTo: leadingAnchor), mark.widthAnchor.constraint(equalToConstant: 18), mark.heightAnchor.constraint(equalToConstant: 18), mark.topAnchor.constraint(equalTo: topAnchor, constant: 8), container.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 20), container.trailingAnchor.constraint(equalTo: trailingAnchor)]
        } else {
            layout += [user ? container.trailingAnchor.constraint(equalTo: trailingAnchor) : container.leadingAnchor.constraint(equalTo: leadingAnchor), user ? container.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.86) : container.widthAnchor.constraint(equalTo: widthAnchor)]
        }
        NSLayoutConstraint.activate(layout)
        update(message.content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { copiedReset?.cancel() }
    func setReplyActions(binding: String?, feedback: String?, canFeedback: Bool, canBranch: Bool, copy: (() -> Bool)?, mark: ((String) -> Void)?, branch: (() -> Void)?) {
        if replyBinding != binding { copiedReset?.cancel(); copyReply.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil); copyReply.setAccessibilityValue("") }
        replyBinding = binding; onCopyReply = copy; onReplyFeedback = mark; onBranchReply = branch
        replyActions.isHidden = binding == nil; helpful.isEnabled = canFeedback; unhelpful.isEnabled = canFeedback; branchReply.isEnabled = canBranch
        for (button, value, title, symbol) in [(helpful, "helpful", "有帮助", "hand.thumbsup"), (unhelpful, "unhelpful", "无帮助", "hand.thumbsdown")] {
            let selected = feedback == value; button.image = NSImage(systemSymbolName: symbol + (selected ? ".fill" : ""), accessibilityDescription: nil)
            button.contentTintColor = selected ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.secondaryText; button.setAccessibilityLabel((selected ? "取消" : "") + title); button.setAccessibilityValue(selected ? "已标记" : "未标记")
        }
        branchReply.toolTip = canBranch ? "从这条回复创建分支；沿用当前项目文件与原任务执行限制" : "任务执行中或受管任务不能在此创建分支"
        updateBodySpacing()
    }
    private func updateBodySpacing() {
        body.setCustomSpacing(attachments.isHidden && replyActions.isHidden && roundActions.isHidden ? 0 : 6, after: label)
        body.setCustomSpacing(replyActions.isHidden && roundActions.isHidden ? 0 : 6, after: attachments)
        body.setCustomSpacing(roundActions.isHidden ? 0 : 6, after: replyActions)
    }
    func setRoundRollback(visible: Bool, enabled: Bool, recovery: Bool, action: (() -> Void)?, edit: (() -> Void)? = nil, canEdit: Bool = false) {
        roundActions.isHidden = !isUser || (!visible && edit == nil); onRoundRollback = action; rollbackFiles.isEnabled = enabled; rollbackFiles.isHidden = !visible
        onEditInput = edit; editInput.isHidden = edit == nil; editInput.isEnabled = canEdit
        rollbackFiles.title = recovery ? "恢复撤回前文件" : "撤回文件"; rollbackFiles.setAccessibilityLabel(rollbackFiles.title)
        rollbackFiles.toolTip = recovery ? "恢复被中断的撤回操作，保留当前对话" : "撤回从这条要求起的项目文件，保留对话"
        updateBodySpacing()
    }
    @objc private func editMessage() { onEditInput?() }
    @objc private func rollbackRound() { onRoundRollback?() }
    @objc private func copyResponse() {
        guard onCopyReply?() == true else { return }; let binding = replyBinding
        copiedReset?.cancel(); copyReply.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil); copyReply.setAccessibilityValue("已复制")
        let reset = DispatchWorkItem { [weak self] in guard let self, replyBinding == binding else { return }; copyReply.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil); copyReply.setAccessibilityValue("") }
        copiedReset = reset; DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
    }
    @objc private func markHelpful() { onReplyFeedback?("helpful") }
    @objc private func markUnhelpful() { onReplyFeedback?("unhelpful") }
    @objc private func branchResponse() { onBranchReply?() }
    func update(_ value: String, markdown: Bool = true, searchQuery: String? = nil, searchDisplayRange: NSRange? = nil, searchDisplayText: String? = nil) {
        let size = AgentAppearance.messageSize + (workbench ? 0 : 1)
        guard text != value || renderedMarkdown != markdown || highlightQuery != searchQuery || highlightDisplayRange != searchDisplayRange || highlightDisplayText != searchDisplayText || renderedSize != size || label.stringValue.isEmpty else { return }
        renderedSize = size
        text = value; renderedMarkdown = markdown; highlightQuery = searchQuery; highlightDisplayRange = searchDisplayRange; highlightDisplayText = searchDisplayText
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        if workbench { paragraph.lineBreakMode = .byCharWrapping }
        let content = value.isEmpty ? "…" : value, font = NSFont.systemFont(ofSize: size), color = NSColor.labelColor
        let plain = NSAttributedString(string: content, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        var output = isUser || !markdown ? plain : NativeMarkdown.render(content, font: font, color: color, paragraph: paragraph)
        searchRange = nil; searchUsesSource = false
        if let searchQuery, !searchQuery.isEmpty {
            if let range = searchDisplayRange {
                if searchDisplayText == output.string, range.location >= 0, range.location <= output.length, range.length > 0, range.length <= output.length - range.location { searchRange = range }
            } else {
                if output.string.range(of: searchQuery, options: .caseInsensitive, locale: .current) == nil, content.localizedCaseInsensitiveContains(searchQuery) { output = plain; searchUsesSource = true }
                if let range = output.string.range(of: searchQuery, options: .caseInsensitive, locale: .current) { searchRange = NSRange(range, in: output.string) }
            }
            if let range = searchRange {
                let selected = NSMutableAttributedString(attributedString: output)
                selected.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.42), range: range); output = selected
            }
        }
        label.attributedStringValue = output; label.setAccessibilityHelp(searchRange == nil ? nil : "搜索命中")
        label.invalidateIntrinsicContentSize()
    }
    func refreshAppearance() { update(text, markdown: renderedMarkdown, searchQuery: highlightQuery, searchDisplayRange: highlightDisplayRange, searchDisplayText: highlightDisplayText); label.needsDisplay = true }
    func clearSearchHighlight() { if highlightQuery != nil { update(text, markdown: renderedMarkdown) } }
    func searchMatchRect() -> NSRect? {
        guard let range = searchRange, range.length > 0, let cell = label.cell else { return nil }
        let drawing = cell.drawingRect(forBounds: label.bounds); guard drawing.width > 0 else { return nil }
        let storage = NSTextStorage(attributedString: label.attributedStringValue), layout = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: drawing.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; container.lineBreakMode = label.lineBreakMode
        storage.addLayoutManager(layout); layout.addTextContainer(container); layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return convert(NSRect(x: drawing.minX + rect.minX, y: label.isFlipped ? drawing.minY + rect.minY : drawing.maxY - rect.maxY, width: max(1, rect.width), height: max(1, rect.height)), from: label)
    }
    func fit(width: CGFloat) {
        let maximum = max(40, workbench ? width - 38 : width * (isUser ? 0.86 : 1) - (isUser ? 34 : 4))
        if abs(label.preferredMaxLayoutWidth - maximum) > 0.5 {
            label.preferredMaxLayoutWidth = maximum; label.invalidateIntrinsicContentSize()
        }
    }
    func setAttachments(_ files: [AgentAttachment], onOpen: @escaping (String) -> Void) { attachments.onOpen = onOpen; attachments.update(files, removable: false); updateBodySpacing() }
}
