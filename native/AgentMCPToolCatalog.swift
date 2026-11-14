import AppKit

@MainActor final class AgentMCPToolCatalog: NSScrollView {
    private let body = NSStackView()
    var string = "" { didSet { reload() } }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    init() {
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true; scrollerStyle = .overlay; identifier = .init("form-input"); setAccessibilityLabel("MCP 实际工具目录")
        let document = AgentMCPToolDocument(); document.translatesAutoresizingMaskIntoConstraints = false; documentView = document
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12; document.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        let preferred = document.heightAnchor.constraint(equalTo: contentView.heightAnchor); preferred.priority = .defaultLow
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: contentView.widthAnchor), document.heightAnchor.constraint(greaterThanOrEqualTo: contentView.heightAnchor), preferred, body.topAnchor.constraint(equalTo: document.topAnchor, constant: 12), body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12), body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12), body.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -12)])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func reload() {
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let rows = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [[String: Any]] else { addLabel(string.isEmpty ? "连接后显示工具" : string); return }
        guard !rows.isEmpty else { addLabel("此连接器未提供工具"); return }
        addLabel("工具 " + String(rows.count))
        for row in rows {
            let name = row["name"] as? String ?? "", title = NSButton(title: name, target: nil, action: nil)
            title.setButtonType(.pushOnPushOff); title.isBordered = false; title.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil); title.imagePosition = .imageLeading; title.font = .monospacedSystemFont(ofSize: 12, weight: .medium); title.setAccessibilityLabel("展开 MCP 工具 " + name)
            let detail = NSStackView(); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 10; detail.isHidden = true
            if let description = row["description"] as? String, !description.isEmpty {
                let label = NSTextField(wrappingLabelWithString: description); label.isSelectable = true; label.font = .systemFont(ofSize: 12); label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); detail.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
            }
            if let schema = row["inputSchema"], let data = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                let label = NSTextField(wrappingLabelWithString: String(decoding: data, as: UTF8.self)); label.isSelectable = true; label.font = .monospacedSystemFont(ofSize: 11, weight: .regular); label.textColor = AgentWorkbenchTheme.secondaryText; label.setAccessibilityLabel("MCP 工具参数 " + name); label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); detail.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
            }
            let row = AgentMCPToolDisclosure(title: title, detail: detail); body.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
    }
    private func addLabel(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 12); label.textColor = AgentWorkbenchTheme.secondaryText; label.isSelectable = true
        body.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
}

@MainActor private final class AgentMCPToolDisclosure: NSStackView {
    private let detail: NSView
    init(title: NSButton, detail: NSView) {
        self.detail = detail; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 10; edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        title.target = self; title.action = #selector(toggle(_:)); addArrangedSubview(title); addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: widthAnchor, constant: -16).isActive = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); title.lineBreakMode = .byTruncatingTail; title.toolTip = title.title
        title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func toggle(_ sender: NSButton) { detail.isHidden = sender.state != .on; sender.image = NSImage(systemSymbolName: sender.state == .on ? "chevron.down" : "chevron.right", accessibilityDescription: nil); sender.setAccessibilityExpanded(sender.state == .on) }
}

@MainActor private final class AgentMCPToolDocument: NSView { override var isFlipped: Bool { true } }
