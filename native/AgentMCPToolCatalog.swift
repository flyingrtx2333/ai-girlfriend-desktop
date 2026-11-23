import AppKit

@MainActor final class AgentMCPToolCatalog: NSStackView {
    private let filter = NSSearchField(), count = NSTextField(labelWithString: "")
    private let toolbar = NSStackView(), list = NSScrollView(), body = NSStackView()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var rows: [AgentMCPToolDisclosure] = []
    private var emptyMessage = ""
    var string = "" {
        didSet { if string != oldValue { reload() } }
    }
    var firstInput: NSView { toolbar.isHidden ? self : filter }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        setAccessibilityLabel("MCP 实际工具目录")
        filter.placeholderString = "搜索工具"
        filter.setAccessibilityLabel("搜索 MCP 工具")
        filter.sendsSearchStringImmediately = true
        filter.target = self
        filter.action = #selector(filterTools)
        count.font = .systemFont(ofSize: 12)
        count.textColor = AgentWorkbenchTheme.secondaryText
        count.setAccessibilityLabel("MCP 工具数量")
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        toolbar.alignment = .centerY
        toolbar.distribution = .fill
        toolbar.spacing = 12
        toolbar.addArrangedSubview(filter)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(count)
        addArrangedSubview(toolbar)
        addArrangedSubview(list)
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.scrollerStyle = .overlay
        list.identifier = .init("form-input")
        list.setAccessibilityLabel("MCP 工具列表")
        list.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let document = AgentMCPToolDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        list.documentView = document
        document.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        feedback.font = .systemFont(ofSize: 13)
        feedback.textColor = AgentWorkbenchTheme.secondaryText
        feedback.setAccessibilityLabel("MCP 工具目录状态")
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.addArrangedSubview(feedback)
        let preferredHeight = document.heightAnchor.constraint(equalTo: list.contentView.heightAnchor)
        preferredHeight.priority = .defaultLow
        let searchWidth = filter.widthAnchor.constraint(equalToConstant: 272)
        searchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolbar.widthAnchor.constraint(equalTo: widthAnchor),
            filter.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            searchWidth,
            filter.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            list.widthAnchor.constraint(equalTo: widthAnchor),
            document.widthAnchor.constraint(equalTo: list.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: list.contentView.heightAnchor),
            preferredHeight,
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            body.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -8),
            feedback.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func reload() {
        for row in rows {
            body.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        let definitions = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [[String: Any]]
        rows = (definitions ?? []).map(AgentMCPToolDisclosure.init)
        if string.isEmpty { emptyMessage = "连接后显示工具" }
        else { emptyMessage = definitions == nil ? string : "此连接器未提供工具" }
        for row in rows {
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        filter.stringValue = ""
        toolbar.isHidden = rows.isEmpty
        filterTools()
    }

    @objc private func filterTools() {
        let query = filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var visible = 0
        for row in rows {
            let matches = query.isEmpty || row.name.localizedCaseInsensitiveContains(query) ||
                row.toolDescription.localizedCaseInsensitiveContains(query)
            row.isHidden = !matches
            if matches { visible += 1 }
        }
        count.stringValue = query.isEmpty ? "\(rows.count) 个工具" : "\(visible) / \(rows.count)"
        feedback.isHidden = visible > 0
        feedback.stringValue = rows.isEmpty ? emptyMessage : "没有匹配的工具"
        list.contentView.scroll(to: .zero)
        list.reflectScrolledClipView(list.contentView)
    }
}

@MainActor private final class AgentMCPToolDisclosure: NSStackView {
    let name: String
    let toolDescription: String
    private let schema: Any?
    private let preview = NSTextField(labelWithString: ""), detail = NSStackView()

    init(_ definition: [String: Any]) {
        name = definition["name"] as? String ?? ""
        toolDescription = definition["description"] as? String ?? ""
        schema = definition["inputSchema"]
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 9, left: 0, bottom: 0, right: 0)
        let title = NSButton(title: name, target: self, action: #selector(toggle(_:)))
        title.setButtonType(.pushOnPushOff)
        title.isBordered = false
        title.alignment = .left
        title.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        title.imagePosition = .imageLeading
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        title.attributedTitle = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        title.focusRingType = .exterior
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = name
        title.setAccessibilityLabel("展开 MCP 工具 " + name)
        title.setAccessibilityExpanded(false)
        let summary = toolDescription.prefix(while: { !$0.isNewline }).prefix(180)
        preview.stringValue = String(summary)
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = AgentWorkbenchTheme.secondaryText
        preview.lineBreakMode = .byTruncatingTail
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.isHidden = summary.isEmpty
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 8
        detail.isHidden = true
        let content = NSStackView(views: [preview, detail])
        content.orientation = .vertical
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 4, right: 2)
        let divider = AgentThemeView(fill: AgentWorkbenchTheme.line)
        addArrangedSubview(title)
        addArrangedSubview(content)
        addArrangedSubview(divider)
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalTo: widthAnchor),
            title.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            content.widthAnchor.constraint(equalTo: widthAnchor),
            preview.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -22),
            detail.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -22),
            divider.widthAnchor.constraint(equalTo: widthAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggle(_ sender: NSButton) {
        let expanded = sender.state == .on
        if expanded && detail.arrangedSubviews.isEmpty { addDetails() }
        preview.isHidden = expanded || preview.stringValue.isEmpty
        detail.isHidden = !expanded
        sender.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        sender.setAccessibilityExpanded(expanded)
    }

    private func addDetails() {
        if !toolDescription.isEmpty {
            let label = NSTextField(wrappingLabelWithString: toolDescription)
            label.font = .systemFont(ofSize: 13)
            label.isSelectable = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
        guard let schema, let data = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        let label = NSTextField(wrappingLabelWithString: String(decoding: data, as: UTF8.self))
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.isSelectable = true
        label.setAccessibilityLabel("MCP 工具参数 " + name)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let parameters = AgentSettingsStyle.section("参数", id: "mcp-tool-schema", rows: [label])
        detail.addArrangedSubview(parameters)
        parameters.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
    }
}

@MainActor private final class AgentMCPToolDocument: NSView { override var isFlipped: Bool { true } }
