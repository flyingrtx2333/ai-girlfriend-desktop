import AppKit

@MainActor final class AgentMCPImportPage: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Definition { let name: String, document: String }
    private let definitions: [Definition], list = NSTableView(), preview = NSTextView()
    private var finished = false
    var onLoad: ((String) -> Void)?

    convenience init(source: URL) throws {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 64_000 else { throw PetError("配置文件需小于 64KB") }
        let data = try Data(contentsOf: source)
        try self.init(data: data, label: source.lastPathComponent, path: source.path)
    }
    convenience init(document: String) throws { try self.init(data: Data(document.utf8), label: "粘贴的 JSON", path: nil) }
    private init(data: Data, label: String, path: String?) throws {
        guard data.count <= 64_000 else { throw PetError("配置文件需小于 64KB") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PetError("不是 JSON 对象") }
        if let raw = object["mcpServers"] {
            guard let servers = raw as? [String: [String: Any]] else { throw PetError("mcpServers 须为连接器对象") }
            guard !servers.isEmpty, servers.count <= 64 else { throw PetError("mcpServers 需包含 1 至 64 个连接器") }
            definitions = try servers.keys.sorted().map { name in
                var value = servers[name]!; value["name"] = name
                if value["url"] != nil { value["type"] = value["type"] ?? "http"; value["bearerToken"] = value["bearerToken"] ?? "" }
                else { value["type"] = value["type"] ?? "stdio"; value["args"] = value["args"] ?? []; value["env"] = value["env"] ?? [:] }
                if let raw = value.removeValue(forKey: "timeout") {
                    guard value["timeoutSeconds"] == nil, let ms = raw as? Double, CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(), ms.isFinite else { throw PetError("timeout 需为毫秒数，不能与 timeoutSeconds 同时填写") }; value["timeoutSeconds"] = ms / 1000
                }
                if let command = value["command"] as? String { value["command"] = AgentMCP.configurationCommand(command) }
                return Definition(name: name, document: String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            }
        } else { definitions = [Definition(name: object["name"] as? String ?? label, document: String(decoding: data, as: UTF8.self))] }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "导入 MCP 连接器"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        let heading = NSTextField(labelWithString: "导入 MCP 连接器"); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let sourceName = NSTextField(labelWithString: label); sourceName.font = .systemFont(ofSize: 12); sourceName.textColor = AgentWorkbenchTheme.secondaryText; sourceName.lineBreakMode = .byTruncatingMiddle; sourceName.toolTip = path
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("import"))); list.headerView = nil; list.rowHeight = 36; list.delegate = self; list.dataSource = self; list.setAccessibilityLabel("待导入 MCP 连接器")
        let index = NSScrollView(); index.documentView = list; index.hasVerticalScroller = true
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 12, height: 12); preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.setAccessibilityLabel("MCP 导入配置预览")
        let detail = NSScrollView(); detail.documentView = preview; detail.hasVerticalScroller = true
        let split = NSStackView(views: [index, detail]); split.spacing = 12; split.alignment = .top; split.distribution = .fill
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelImport)); cancel.keyEquivalent = "\u{1b}"
        let load = NSButton(title: "载入草稿", target: self, action: #selector(loadSelected))
        let footer = NSStackView(views: [NSView(), cancel, load]); footer.spacing = 10
        let layout = NSStackView(views: [heading, sourceName, split, footer]); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 10; layout.distribution = .fill
        let root = AgentThemeView(); window.contentView = root; root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        for view in [sourceName, split, footer] { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            heading.widthAnchor.constraint(lessThanOrEqualTo: layout.widthAnchor), index.widthAnchor.constraint(equalToConstant: 180), index.heightAnchor.constraint(equalTo: split.heightAnchor), detail.heightAnchor.constraint(equalTo: split.heightAnchor), split.heightAnchor.constraint(greaterThanOrEqualToConstant: 100), footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        list.reloadData(); list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); showSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() { super.settingsDidAppear(); presentingWindow?.makeFirstResponder(list) }
    func numberOfRows(in tableView: NSTableView) -> Int { definitions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard definitions.indices.contains(row) else { return nil }; let name = NSTextField(labelWithString: definitions[row].name)
        name.font = .systemFont(ofSize: 12); name.lineBreakMode = .byTruncatingMiddle; name.toolTip = name.stringValue; return name
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
    private func showSelection() {
        guard definitions.indices.contains(list.selectedRow) else { return }; preview.string = definitions[list.selectedRow].document; preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    @objc private func cancelImport() { close() }
    @objc private func loadSelected() {
        guard !finished, definitions.indices.contains(list.selectedRow) else { return }; finished = true
        let document = definitions[list.selectedRow].document; close(); onLoad?(document)
    }
}
