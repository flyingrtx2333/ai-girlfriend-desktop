import AppKit

final class SidebarBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(red: 0.87, green: 0.91, blue: 0.93, alpha: 1),
                   ending: NSColor(red: 0.94, green: 0.95, blue: 0.83, alpha: 1))?.draw(in: bounds, angle: 90)
    }
}

final class ChatMessageRow: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    private(set) var text = ""
    private let isUser: Bool
    init(message: ChatMessage) {
        isUser = message.role == "user"
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        let user = message.role == "user", container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false; container.wantsLayer = true
        container.layer?.backgroundColor = user ? NSColor(white: 0.95, alpha: 1).cgColor : NSColor.clear.cgColor
        container.layer?.cornerRadius = 14; addSubview(container); container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false; label.isSelectable = true
        label.font = .systemFont(ofSize: 15); label.textColor = NSColor(white: 0.12, alpha: 1)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset: CGFloat = user ? 15 : 0
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor), container.bottomAnchor.constraint(equalTo: bottomAnchor),
            user ? container.trailingAnchor.constraint(equalTo: trailingAnchor) : container.leadingAnchor.constraint(equalTo: leadingAnchor),
            user ? container.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.86) : container.widthAnchor.constraint(equalTo: widthAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset), label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: user ? 11 : 4), label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: user ? -11 : -4)])
        update(message.content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ value: String) {
        guard text != value || label.stringValue.isEmpty else { return }; text = value
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        label.attributedStringValue = NSAttributedString(string: value.isEmpty ? "…" : value,
            attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.12, alpha: 1), .paragraphStyle: paragraph])
        label.invalidateIntrinsicContentSize()
    }
    func fit(width: CGFloat) {
        let maximum = max(40, width * (isUser ? 0.86 : 1) - (isUser ? 34 : 4))
        if abs(label.preferredMaxLayoutWidth - maximum) > 0.5 {
            label.preferredMaxLayoutWidth = maximum; label.invalidateIntrinsicContentSize()
        }
    }
}
