import AppKit

@MainActor final class AgentProfileDraftRow: NSView {
    var onConfigure: (() -> Void)?
    init(_ draft: AgentProfileDraft, saved: Bool, available: Bool, issue: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10; layer?.borderWidth = 1
        let name = NSTextField(labelWithString: String(draft.profile.name.prefix(60)))
        name.font = .systemFont(ofSize: 14, weight: .semibold); name.lineBreakMode = .byTruncatingTail
        let status = NSTextField(labelWithString: issue ?? (saved ? (available ? "Agent · 已保存" : "Agent · 已移除") : "Agent 草稿 · 未保存"))
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        let purpose = NSTextField(wrappingLabelWithString: String(draft.profile.description.prefix(500))); purpose.font = .systemFont(ofSize: 12)
        let text = NSTextView(); text.isEditable = false; text.isRichText = false; text.isSelectable = true; text.font = .systemFont(ofSize: 12)
        text.string = String(draft.profile.instructions.prefix(24_000)); text.textContainerInset = NSSize(width: 8, height: 8); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel("Agent 草稿指令")
        let document = NSScrollView(); document.documentView = text; document.hasVerticalScroller = true; document.borderType = .bezelBorder
        let configure = NSButton(title: saved ? "查看配置" : "继续配置", target: self, action: #selector(openConfiguration)); configure.isEnabled = issue == nil && (!saved || available)
        configure.setAccessibilityLabel(configure.title + " · " + draft.profile.name)
        let header = NSStackView(views: [name, NSView(), status, configure]); header.spacing = 10
        let content = NSStackView(views: [header, purpose, document]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        for item in [header, purpose, document] { item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), content.topAnchor.constraint(equalTo: topAnchor, constant: 12), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12), document.heightAnchor.constraint(equalToConstant: 150)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    @objc private func openConfiguration() { onConfigure?() }
}
