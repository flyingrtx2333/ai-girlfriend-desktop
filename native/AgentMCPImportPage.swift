import AppKit

@MainActor final class AgentMCPImportPage: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Source: Codable, Equatable {
        case file(path: String, digest: String)
        case pasted(document: String)

        var path: String? { if case .file(let path, _) = self { return path }; return nil }
        var label: String { path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "粘贴的 JSON" }
        @MainActor var validForRecovery: Bool {
            switch self {
            case .file(let path, let digest):
                return path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 16_384 && AgentSettingsRecovery.validHash(digest)
            case .pasted(let document): return AgentMCPConfigForm.canPreserveDocument(document, allowingImport: true)
            }
        }
    }
    private struct Definition { let name: String, document: String }
    private struct Recovery: Codable {
        var version = 1
        let source: Source, selected: String?, listY: Double, selectedVisible: Bool
        let reading: AgentTextViewport?
    }
    private var source: Source, definitions: [Definition]
    private let list = NSTableView(), preview = NSTextView()
    private let listScroll = NSScrollView(), previewScroll = NSScrollView()
    private let state = AgentSettingsStatusField("MCP 导入状态")
    private let retry = AgentDialogButton(title: "重新读取", target: nil, action: nil)
    private let load = AgentDialogButton(title: "载入草稿", target: nil, action: nil)
    private var finished = false, pending: Recovery?, restoreScheduled = false
    var onLoad: ((String) -> Void)?
    override var minimumSettingsContentHeight: CGFloat { 220 }
    override var usesInternalScrolling: Bool { true }

    convenience init(source: URL) throws {
        let path = source.standardizedFileURL.path
        let data = try Self.readFile(path), origin = Source.file(path: path, digest: AgentFiles.hash(data))
        self.init(source: origin, definitions: try Self.definitions(data, label: origin.label))
    }
    convenience init(document: String) throws {
        let origin = Source.pasted(document: document)
        self.init(source: origin, definitions: try Self.definitions(Data(document.utf8), label: origin.label))
    }
    convenience init(recovery: AgentSettingsRecovery.Page) throws {
        self.init(source: try Self.decodeRecovery(recovery).source, definitions: [])
    }
    private static func readFile(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let files = try AgentFiles(workspace: url.deletingLastPathComponent().path, followParentLinks: false)
        return try files.readData(url, maximum: 64_000)
    }
    private static func definitions(_ data: Data, label: String) throws -> [Definition] {
        guard data.count <= 64_000 else { throw PetError("配置文件需小于 64KB") }
        let object = try AgentConfigurationJSON.object(data)
        guard let raw = object["mcpServers"] else {
            return [Definition(name: object["name"] as? String ?? label, document: String(decoding: data, as: UTF8.self))]
        }
        guard let servers = raw as? [String: [String: Any]] else { throw PetError("mcpServers 须为连接器对象") }
        guard (1...64).contains(servers.count) else { throw PetError("mcpServers 需包含 1 至 64 个连接器") }
        return try servers.sorted { $0.key < $1.key }.map { name, fields in
            var value = fields
            value["name"] = name
            if value["url"] != nil { value["type"] = value["type"] ?? "http"; value["bearerToken"] = value["bearerToken"] ?? "" }
            else { value["type"] = value["type"] ?? "stdio"; value["args"] = value["args"] ?? []; value["env"] = value["env"] ?? [:] }
            if let raw = value.removeValue(forKey: "timeout") {
                guard value["timeoutSeconds"] == nil, let ms = raw as? Double, CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(), ms.isFinite else {
                    throw PetError("timeout 需为毫秒数，不能与 timeoutSeconds 同时填写")
                }
                value["timeoutSeconds"] = ms / 1000
            }
            if let command = value["command"] as? String { value["command"] = AgentMCP.configurationCommand(command) }
            let document = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return Definition(name: name, document: String(decoding: document, as: UTF8.self))
        }
    }

    private init(source: Source, definitions: [Definition]) {
        self.source = source; self.definitions = definitions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "导入 MCP 连接器"; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        detailHeading = .init(title: "导入 MCP 连接器", scope: "JSON", location: source.path)
        let sourceName = NSTextField(labelWithString: source.label)
        sourceName.font = .systemFont(ofSize: 13, weight: .medium); sourceName.textColor = AgentWorkbenchTheme.secondaryText
        sourceName.lineBreakMode = .byTruncatingMiddle; sourceName.toolTip = source.path
        sourceName.setAccessibilityLabel("MCP 导入来源")
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("import")))
        list.headerView = nil; list.rowHeight = 36; list.delegate = self; list.dataSource = self
        list.setAccessibilityLabel("待导入 MCP 连接器")
        listScroll.documentView = list; listScroll.hasVerticalScroller = true
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 12, height: 12); preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("MCP 导入配置预览")
        previewScroll.documentView = preview; previewScroll.hasVerticalScroller = true
        let split = NSStackView(views: [listScroll, previewScroll]); split.spacing = 12; split.alignment = .top
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(cancelImport)); cancel.keyEquivalent = "\u{1b}"
        AgentDialogStyle.action(cancel)
        retry.target = self; retry.action = #selector(reloadSource); retry.isHidden = true; AgentDialogStyle.action(retry)
        load.target = self; load.action = #selector(loadSelected); AgentSettingsStyle.primaryAction(load)
        let actions = AgentSettingsDetailActions([retry, cancel, load]); detailActionRow = actions
        let layout = NSStackView(views: [sourceName, state, split, actions]); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 8
        let root = AgentThemeView(); window.contentView = root; root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        for view in [sourceName, state, split, actions] { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            listScroll.widthAnchor.constraint(equalToConstant: 164), listScroll.heightAnchor.constraint(equalTo: split.heightAnchor),
            previewScroll.heightAnchor.constraint(equalTo: split.heightAnchor), split.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        for clip in [listScroll.contentView, previewScroll.contentView] {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(readingChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(readingChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: preview)
        showRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        if !retry.isHidden { presentingWindow?.makeFirstResponder(retry) }
        else if pending != nil { scheduleRecovery() }
        else if presentingWindow?.firstResponder !== preview { presentingWindow?.makeFirstResponder(list) }
    }
    override func pageDidLayout() { scheduleRecovery() }
    func numberOfRows(in tableView: NSTableView) -> Int { definitions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard definitions.indices.contains(row) else { return nil }
        let name = NSTextField(labelWithString: definitions[row].name)
        name.font = .systemFont(ofSize: 12); name.lineBreakMode = .byTruncatingMiddle; name.toolTip = name.stringValue
        return name
    }
    func tableViewSelectionDidChange(_ notification: Notification) { pending = nil; showSelection(); readingChanged() }
    private func showRows(selected: String? = nil) {
        list.reloadData()
        if !definitions.isEmpty {
            let index = selected.flatMap { name in definitions.firstIndex(where: { $0.name == name }) } ?? 0
            list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        showSelection()
    }
    private func showSelection() {
        let definition = definitions.indices.contains(list.selectedRow) ? definitions[list.selectedRow] : nil
        preview.string = definition?.document ?? ""
        preview.setSelectedRange(NSRange(location: 0, length: 0))
        AgentSettingsRecovery.restoreScroll(0, to: previewScroll)
        load.isEnabled = retry.isHidden && definition != nil
    }
    @objc private func readingChanged(_ notification: Notification? = nil) { if pending == nil, isPageVisible { onSettingsRecoveryChange?() } }

    private static func decodeRecovery(_ page: AgentSettingsRecovery.Page) throws -> Recovery {
        guard page.kind == "mcp-import" else { throw PetError("设置记录不属于连接器导入审阅") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "source", "selected", "listY", "selectedVisible", "reading"])
        if let reading = raw["reading"] { try AgentTextViewport.validateObject(reading) }
        let value = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard value.version == 1, value.source.validForRecovery, AgentSettingsRecovery.validScroll(value.listY), value.reading?.valid != false else {
            throw PetError("连接器导入审阅记录无效，原记录已保留")
        }
        return value
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        guard source.validForRecovery else { return nil }
        return try AgentSettingsRecovery.page("mcp-import", pending ?? readingPosition())
    }
    private func readingPosition() throws -> Recovery {
        let selected = definitions.indices.contains(list.selectedRow) ? definitions[list.selectedRow].name : nil
        let reading = selected == nil ? nil : try AgentTextViewport(preview)
        return Recovery(source: source, selected: selected, listY: max(0, listScroll.contentView.bounds.minY),
                        selectedVisible: AgentSettingsRecovery.selectionIsVisible(in: list), reading: reading)
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        let value = try Self.decodeRecovery(page)
        guard value.source == source else { throw PetError("导入审阅来源已变化，原记录已保留") }
        switch source {
        case .file(let path, let digest):
            let data: Data
            do { data = try Self.readFile(path) }
            catch { pending = value; sourceProblem("来源文件暂不可读。恢复文件后可重新读取。"); return }
            guard AgentFiles.hash(data) == digest else { pending = value; sourceProblem("来源文件已变化，请重新读取并审阅。"); return }
            definitions = try Self.definitions(data, label: source.label)
        case .pasted(let document): definitions = try Self.definitions(Data(document.utf8), label: source.label)
        }
        showRows(selected: value.selected); pending = value; scheduleRecovery()
    }
    private func scheduleRecovery() {
        guard pending != nil, retry.isHidden, !restoreScheduled else { return }
        restoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            restoreScheduled = false
            guard isPageVisible, previewScroll.contentSize.height > 0, let saved = pending else { return }
            if saved.reading?.focused != true { presentingWindow?.makeFirstResponder(list) }
            AgentSettingsRecovery.restoreScroll(saved.listY, to: listScroll)
            if saved.selectedVisible, list.selectedRow >= 0, !AgentSettingsRecovery.selectionIsVisible(in: list) { list.scrollRowToVisible(list.selectedRow) }
            if let reading = saved.reading {
                if reading.apply(to: preview) == false { presentingWindow?.makeFirstResponder(list) }
                else if reading.focused, let range = reading.selections.first?.range { preview.scrollRangeToVisible(range) }
            }
            pending = nil; readingChanged()
        }
    }
    private func sourceProblem(_ message: String) {
        state.showSaveFailure(PetError(message)); retry.isHidden = false; load.isEnabled = false
        readingChanged()
    }
    @objc private func reloadSource() {
        guard case .file(let path, let previousDigest) = source else { return }
        do {
            let data = try Self.readFile(path)
            let digest = AgentFiles.hash(data)
            let prior = digest == previousDigest ? (pending ?? (try? readingPosition())) : nil
            definitions = try Self.definitions(data, label: source.label)
            source = .file(path: path, digest: digest); state.stringValue = ""; retry.isHidden = true
            showRows(selected: prior?.selected); pending = prior
            if prior == nil { presentingWindow?.makeFirstResponder(list); AgentSettingsRecovery.restoreScroll(0, to: listScroll) }
            scheduleRecovery(); readingChanged()
        } catch { sourceProblem("来源文件无法读取或不是有效的连接器 JSON，请核对后重试。") }
    }
    @objc private func cancelImport() { close() }
    @objc private func loadSelected() {
        guard !finished, retry.isHidden, definitions.indices.contains(list.selectedRow) else { return }
        if case .file(let path, let digest) = source {
            let data: Data
            do { data = try Self.readFile(path) }
            catch { sourceProblem("来源文件暂不可读。恢复文件后可重新读取。"); return }
            guard AgentFiles.hash(data) == digest else { sourceProblem("来源文件已变化，请重新读取并审阅。"); return }
        }
        finished = true
        let document = definitions[list.selectedRow].document
        close(); onLoad?(document)
    }
}
