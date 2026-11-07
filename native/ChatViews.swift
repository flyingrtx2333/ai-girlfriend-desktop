import AppKit

final class SidebarBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        AgentWorkbenchTheme.sidebar.setFill(); bounds.fill()
    }
}

final class ContentSurface: NSView {
    var showsSettings = false { didSet { needsDisplay = true } }
    var usesWorkbenchSurface = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (showsSettings ? NSColor(white: 0.988, alpha: 1) : usesWorkbenchSurface ? AgentWorkbenchTheme.surface : .white).setFill(); bounds.fill()
        guard showsSettings else { return }
        for offset in stride(from: CGFloat(8), through: min(180, bounds.height), by: 8) {
            NSColor(white: 0.42, alpha: 0.075 * (1 - offset / 190)).setFill()
            let dots = NSBezierPath()
            for x in stride(from: CGFloat(8), through: bounds.width, by: 8) {
                dots.appendOval(in: NSRect(x: x, y: bounds.maxY - offset, width: 1, height: 1))
            }
            dots.fill()
        }
    }
}

final class ChatMessageRow: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    private(set) var text = ""
    private var renderedMarkdown = true
    private let isUser: Bool
    private let workbench: Bool
    private let attachments = AgentAttachmentStrip()
    private var attachmentGap: NSLayoutConstraint!
    init(message: ChatMessage, workbench: Bool = false) {
        isUser = message.role == "user"; self.workbench = workbench
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        let user = message.role == "user", container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false; container.wantsLayer = true
        container.layer?.backgroundColor = user && !workbench ? NSColor(white: 0.95, alpha: 1).cgColor : NSColor.clear.cgColor
        container.layer?.cornerRadius = 14; addSubview(container); container.addSubview(label); container.addSubview(attachments)
        attachments.maximumRows = 6
        label.translatesAutoresizingMaskIntoConstraints = false; label.isSelectable = true; label.allowsEditingTextAttributes = true
        label.font = .systemFont(ofSize: workbench ? 14 : 15); label.textColor = NSColor(white: 0.12, alpha: 1)
        if workbench { label.lineBreakMode = .byCharWrapping; label.cell?.wraps = true; label.cell?.usesSingleLineMode = false }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset: CGFloat = workbench ? 0 : user ? 15 : 0
        attachmentGap = attachments.topAnchor.constraint(equalTo: label.bottomAnchor)
        var layout = [container.topAnchor.constraint(equalTo: topAnchor), container.bottomAnchor.constraint(equalTo: bottomAnchor), label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset), label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset), label.topAnchor.constraint(equalTo: container.topAnchor, constant: workbench ? 8 : user ? 11 : 4), attachmentGap!, attachments.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset), attachments.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset), attachments.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: workbench ? -8 : user ? -11 : -4)]
        if workbench {
            let mark = NSImageView(image: NSImage(systemSymbolName: user ? "person" : "fish", accessibilityDescription: user ? "你" : "小鲸")!)
            mark.contentTintColor = user ? .secondaryLabelColor : AgentWorkbenchTheme.accent; addSubview(mark); mark.translatesAutoresizingMaskIntoConstraints = false
            layout += [mark.leadingAnchor.constraint(equalTo: leadingAnchor), mark.widthAnchor.constraint(equalToConstant: 18), mark.heightAnchor.constraint(equalToConstant: 18), mark.topAnchor.constraint(equalTo: topAnchor, constant: 8), container.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 20), container.trailingAnchor.constraint(equalTo: trailingAnchor)]
        } else {
            layout += [user ? container.trailingAnchor.constraint(equalTo: trailingAnchor) : container.leadingAnchor.constraint(equalTo: leadingAnchor), user ? container.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.86) : container.widthAnchor.constraint(equalTo: widthAnchor)]
        }
        NSLayoutConstraint.activate(layout)
        update(message.content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ value: String, markdown: Bool = true) {
        guard text != value || renderedMarkdown != markdown || label.stringValue.isEmpty else { return }; text = value; renderedMarkdown = markdown
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        if workbench { paragraph.lineBreakMode = .byCharWrapping }
        let content = value.isEmpty ? "…" : value, font = NSFont.systemFont(ofSize: workbench ? 14 : 15), color = NSColor(white: 0.12, alpha: 1)
        label.attributedStringValue = isUser || !markdown ? NSAttributedString(string: content, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            : NativeMarkdown.render(content, font: font, color: color, paragraph: paragraph)
        label.invalidateIntrinsicContentSize()
    }
    func fit(width: CGFloat) {
        let maximum = max(40, workbench ? width - 38 : width * (isUser ? 0.86 : 1) - (isUser ? 34 : 4))
        if abs(label.preferredMaxLayoutWidth - maximum) > 0.5 {
            label.preferredMaxLayoutWidth = maximum; label.invalidateIntrinsicContentSize()
        }
    }
    func setAttachments(_ files: [AgentAttachment], onOpen: @escaping (String) -> Void) { attachments.onOpen = onOpen; attachments.update(files, removable: false); attachmentGap.constant = files.isEmpty ? 0 : 6 }
}
