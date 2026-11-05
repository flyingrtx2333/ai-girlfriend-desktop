import AppKit

final class SidebarBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(red: 0.87, green: 0.91, blue: 0.93, alpha: 1),
                   ending: NSColor(red: 0.94, green: 0.95, blue: 0.83, alpha: 1))?.draw(in: bounds, angle: 90)
    }
}

final class ContentSurface: NSView {
    var showsSettings = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (showsSettings ? NSColor(white: 0.988, alpha: 1) : .white).setFill(); bounds.fill()
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
    private let attachments = AgentAttachmentStrip()
    private var attachmentGap: NSLayoutConstraint!
    init(message: ChatMessage) {
        isUser = message.role == "user"
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        let user = message.role == "user", container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false; container.wantsLayer = true
        container.layer?.backgroundColor = user ? NSColor(white: 0.95, alpha: 1).cgColor : NSColor.clear.cgColor
        container.layer?.cornerRadius = 14; addSubview(container); container.addSubview(label); container.addSubview(attachments)
        attachments.maximumRows = 6
        label.translatesAutoresizingMaskIntoConstraints = false; label.isSelectable = true; label.allowsEditingTextAttributes = true
        label.font = .systemFont(ofSize: 15); label.textColor = NSColor(white: 0.12, alpha: 1)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset: CGFloat = user ? 15 : 0
        attachmentGap = attachments.topAnchor.constraint(equalTo: label.bottomAnchor)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor), container.bottomAnchor.constraint(equalTo: bottomAnchor),
            user ? container.trailingAnchor.constraint(equalTo: trailingAnchor) : container.leadingAnchor.constraint(equalTo: leadingAnchor),
            user ? container.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.86) : container.widthAnchor.constraint(equalTo: widthAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset), label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: user ? 11 : 4), attachmentGap,
            attachments.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset), attachments.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset), attachments.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: user ? -11 : -4)])
        update(message.content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ value: String, markdown: Bool = true) {
        guard text != value || renderedMarkdown != markdown || label.stringValue.isEmpty else { return }; text = value; renderedMarkdown = markdown
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let content = value.isEmpty ? "…" : value, font = NSFont.systemFont(ofSize: 15), color = NSColor(white: 0.12, alpha: 1)
        label.attributedStringValue = isUser || !markdown ? NSAttributedString(string: content, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            : NativeMarkdown.render(content, font: font, color: color, paragraph: paragraph)
        label.invalidateIntrinsicContentSize()
    }
    func fit(width: CGFloat) {
        let maximum = max(40, width * (isUser ? 0.86 : 1) - (isUser ? 34 : 4))
        if abs(label.preferredMaxLayoutWidth - maximum) > 0.5 {
            label.preferredMaxLayoutWidth = maximum; label.invalidateIntrinsicContentSize()
        }
    }
    func setAttachments(_ files: [AgentAttachment], onOpen: @escaping (String) -> Void) { attachments.onOpen = onOpen; attachments.update(files, removable: false); attachmentGap.constant = files.isEmpty ? 0 : 6 }
}
