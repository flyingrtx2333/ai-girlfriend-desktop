import AppKit
import ImageIO

private final class AgentMCPContentDocument: NSView { override var isFlipped: Bool { true } }

@MainActor final class AgentMCPContentWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String, sessionOwner: String, workspace: String?
    private let insert: (String, [String]) throws -> Void
    private let servers = NSPopUpButton(), kinds = NSSegmentedControl(labels: ["资源", "URI 模板", "提示词"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), table = NSTableView(), viewer = NSTextView(), uri = NSTextField()
    private let title = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: ""), destination = NSTextField(labelWithString: "")
    private let connect = NSButton(title: "连接", target: nil, action: nil), disconnect = NSButton(title: "断开", target: nil, action: nil)
    private let refresh = NSButton(title: "刷新", target: nil, action: nil), more = NSButton(title: "更多", target: nil, action: nil)
    private let read = NSButton(title: "读取", target: nil, action: nil), add = NSButton(title: "加入附件", target: nil, action: nil)
    private let track = NSButton(checkboxWithTitle: "跟踪更新", target: nil, action: nil)
    private let arguments = NSStackView(), argumentScroll = NSScrollView(), image = NSImageView()
    private var argumentHeight: NSLayoutConstraint!, imageHeight: NSLayoutConstraint!
    private var rows: [[String: Any]] = [], fields: [String: NSTextView] = [:], nextOffset: Int?, catalog = ""
    private var selected: [String: Any]?, preview: AgentMCPContentPreview?, inserted = false
    private var job: Task<Void, Never>?, observer: UUID?, closed = false
    private var loadingList = false, pendingSearch = false
    private var serverID: String? { servers.selectedItem?.representedObject as? String }
    private var kind: String { ["resources", "templates", "prompts"][max(0, kinds.selectedSegment)] }
    init(store: AgentStore, taskID: String, serverID: String? = nil, onInsert: @escaping (String, [String]) throws -> Void) {
        self.store = store; self.taskID = taskID; self.insert = onInsert; workspace = store.task(taskID)?.workspace
        sessionOwner = taskID + "/context-" + UUID().uuidString
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 690), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MCP 资料 · " + (store.task(taskID)?.title ?? "任务"); window.minSize = NSSize(width: 760, height: 540); window.center(); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        servers.target = self; servers.action = #selector(changeServer); servers.setAccessibilityLabel("MCP 资料连接器")
        servers.widthAnchor.constraint(lessThanOrEqualToConstant: 310).isActive = true
        kinds.selectedSegment = 0; kinds.target = self; kinds.action = #selector(changeKind)
        search.placeholderString = "搜索名称或 URI"; search.delegate = self; search.setAccessibilityLabel("搜索 MCP 资料")
        for (button, action) in [(connect, #selector(start)), (disconnect, #selector(stop)), (refresh, #selector(refreshList)), (more, #selector(loadMore)), (read, #selector(readContent)), (add, #selector(addContent)), (track, #selector(toggleTracking))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        for label in [state, destination] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let header = NSStackView(views: [servers, destination, NSView(), disconnect, connect]); header.spacing = 10
        let filters = NSStackView(views: [kinds, search, refresh]); filters.spacing = 10
        table.addTableColumn(NSTableColumn(identifier: .init("mcp-content"))); table.headerView = nil; table.rowHeight = 46; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("MCP 资源与提示词目录")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        let listColumn = NSStackView(views: [list, more]); listColumn.orientation = .vertical; listColumn.alignment = .leading; listColumn.spacing = 8
        list.widthAnchor.constraint(equalTo: listColumn.widthAnchor).isActive = true; listColumn.widthAnchor.constraint(equalToConstant: 220).isActive = true
        title.font = .systemFont(ofSize: 16, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        uri.font = .systemFont(ofSize: 12); uri.isEditable = false; uri.isSelectable = true; uri.isBordered = true; uri.delegate = self; uri.setAccessibilityLabel("MCP 资源 URI")
        uri.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        uri.cell?.usesSingleLineMode = true; uri.cell?.lineBreakMode = .byTruncatingMiddle
        let argumentDocument = AgentMCPContentDocument(); arguments.orientation = .vertical; arguments.alignment = .leading; arguments.spacing = 10; arguments.translatesAutoresizingMaskIntoConstraints = false; argumentDocument.addSubview(arguments)
        argumentScroll.documentView = argumentDocument; argumentScroll.hasVerticalScroller = true; argumentScroll.drawsBackground = false; argumentDocument.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([argumentDocument.widthAnchor.constraint(equalTo: argumentScroll.contentView.widthAnchor), arguments.leadingAnchor.constraint(equalTo: argumentDocument.leadingAnchor), arguments.trailingAnchor.constraint(equalTo: argumentDocument.trailingAnchor), arguments.topAnchor.constraint(equalTo: argumentDocument.topAnchor), arguments.bottomAnchor.constraint(equalTo: argumentDocument.bottomAnchor)])
        argumentHeight = argumentScroll.heightAnchor.constraint(equalToConstant: 0); argumentHeight.isActive = true
        viewer.isEditable = false; viewer.isRichText = false; viewer.font = .systemFont(ofSize: 13); viewer.textContainerInset = NSSize(width: 12, height: 12); viewer.isVerticallyResizable = true; viewer.autoresizingMask = [.width]; viewer.textContainer?.widthTracksTextView = true; viewer.setAccessibilityLabel("MCP 资料预览")
        let previewScroll = NSScrollView(); previewScroll.documentView = viewer; previewScroll.hasVerticalScroller = true; previewScroll.borderType = .bezelBorder
        image.imageScaling = .scaleProportionallyUpOrDown; imageHeight = image.heightAnchor.constraint(equalToConstant: 0); imageHeight.priority = .defaultLow; imageHeight.isActive = true; image.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true; image.setContentCompressionResistancePriority(.init(200), for: .vertical); image.setAccessibilityLabel("MCP 实际图片预览"); image.isHidden = true
        let detail = NSStackView(views: [title, uri, argumentScroll, image, previewScroll]); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 10
        for view in detail.arrangedSubviews { view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        let main = NSStackView(views: [listColumn, detail]); main.spacing = 16; main.alignment = .top; main.distribution = .fill
        detail.setHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [state, NSView(), track, read, add]); footer.spacing = 10
        for view in [header, filters, main, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), filters.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), filters.leadingAnchor.constraint(equalTo: header.leadingAnchor), filters.trailingAnchor.constraint(equalTo: header.trailingAnchor), main.leadingAnchor.constraint(equalTo: header.leadingAnchor), main.trailingAnchor.constraint(equalTo: header.trailingAnchor), main.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 14), main.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14), listColumn.heightAnchor.constraint(equalTo: main.heightAnchor), detail.heightAnchor.constraint(equalTo: main.heightAnchor), footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16), previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)])
        populateServers(); if let serverID, let item = servers.itemArray.first(where: { $0.representedObject as? String == serverID }) { servers.select(item) }
        observer = store.mcp.observeContent { [weak self] in self?.refreshState() }; clearSelection(); refreshState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func populateServers() {
        let previous = serverID, allowed = store.task(taskID)?.agent?.mcpServers
        servers.removeAllItems()
        for server in store.mcp.availableServers(workspace: workspace) where server.enabled && (allowed?.contains(server.id) ?? true) { servers.addItem(withTitle: server.name); servers.lastItem?.representedObject = server.id }
        if let previous, let item = servers.itemArray.first(where: { $0.representedObject as? String == previous }) { servers.select(item) }
    }
    private func taskScope(_ serverID: String, operation: String = "connect_mcp") throws -> AgentTaskRecord {
        guard let task = store.task(taskID), !task.archived, task.kind != "wiki", task.kind != "hook", task.workspace == workspace else { throw PetError("任务或项目已改变，请重新打开 MCP 资料") }
        guard [.agent, .goal].contains(task.mode) else { throw PetError("请先切换到 Agent 或目标模式") }
        _ = try store.mcp.server(serverID, workspace: task.workspace)
        let call = AgentToolCall(id: "mcp-context", name: operation, arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["server_id": serverID]), as: UTF8.self))
        try store.agents.check(call, task: task, store: store); return task
    }
    private func clearSelection() {
        selected = nil; preview = nil; inserted = false; viewer.string = ""; title.stringValue = ""; uri.stringValue = ""; uri.isHidden = true; image.image = nil; image.isHidden = true; imageHeight.constant = 0
        fields = [:]; for view in arguments.arrangedSubviews { arguments.removeArrangedSubview(view); view.removeFromSuperview() }; argumentHeight.constant = 0; argumentScroll.isHidden = true
    }
    private func resetList() { rows = []; nextOffset = nil; catalog = ""; table.reloadData(); clearSelection() }
    @objc private func changeServer() { resetList(); refreshState(); if let id = serverID, store.mcp.connected(id, owner: sessionOwner) { loadList() } }
    @objc private func changeKind() { search.stringValue = ""; resetList(); refreshState(); loadList() }
    @objc private func start() {
        guard job == nil, let id = serverID else { return }
        launch {
            let task = try self.taskScope(id), server = try self.store.mcp.server(id, workspace: self.workspace)
            _ = try await self.store.mcp.connect(id, revision: server.revision, owner: self.sessionOwner, workspace: task.workspace)
            try await self.fetchList(refresh: false, append: false)
        }
    }
    @objc private func stop() { job?.cancel(); if let id = serverID { store.mcp.disconnect(owner: sessionOwner, serverID: id) }; resetList(); refreshState() }
    @objc private func refreshList() { loadList(refresh: true) }
    @objc private func loadMore() { loadList(append: true) }
    private func loadList(refresh: Bool = false, append: Bool = false) {
        guard job == nil, let id = serverID, store.mcp.connected(id, owner: sessionOwner) else { refreshState(); return }
        loadingList = true
        launch { defer { self.loadingList = false }; try await self.fetchList(refresh: refresh, append: append) }
    }
    private func fetchList(refresh: Bool, append: Bool) async throws {
        guard let id = serverID, let connection = store.mcp.token(id, owner: sessionOwner) else { throw PetError("请先连接") }
        _ = try taskScope(id, operation: kind == "prompts" ? "connect_mcp" : "list_mcp_resources")
        let query = search.stringValue
        let result = try await store.mcp.contentCatalog(id, owner: sessionOwner, connection: connection, kind: kind, query: String(query.prefix(300)), offset: append ? nextOffset ?? 0 : 0, refresh: refresh)
        try Task.checkCancellation(); guard !closed, search.stringValue == query else { return }
        let values = result["items"] as? [[String: Any]] ?? []
        rows = append ? rows + values : values; nextOffset = result["next_offset"] as? Int; catalog = result["catalog"] as? String ?? ""
        clearSelection(); table.reloadData()
        state.stringValue = result["supported"] as? Bool == false ? "连接器未提供此类内容" : rows.isEmpty ? "没有匹配内容" : ""
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    private func launch(_ action: @escaping () async throws -> Void) {
        guard job == nil else { return }; state.stringValue = "读取中…"
        job = Task { [weak self] in
            guard let self else { return }
            defer {
                self.job = nil; self.refreshState()
                if self.pendingSearch { self.pendingSearch = false; self.loadList() }
            }
            do { try await action() }
            catch { if !self.closed { self.state.stringValue = Task.isCancelled ? "已取消" : error.localizedDescription; self.state.toolTip = self.state.stringValue } }
        }; refreshState()
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search {
            clearSelection()
            if job != nil { pendingSearch = true } else { loadList() }
        }
        else { preview = nil; inserted = false; viewer.string = ""; image.image = nil; image.isHidden = true; imageHeight.constant = 0; refreshState() }
    }
    func textDidChange(_ notification: Notification) { preview = nil; inserted = false; viewer.string = ""; image.image = nil; image.isHidden = true; imageHeight.constant = 0; refreshState() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row], name = NSTextField(labelWithString: item["title"] as? String ?? item["name"] as? String ?? "")
        name.font = .systemFont(ofSize: 12, weight: .medium); name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: item["uri"] as? String ?? item["uriTemplate"] as? String ?? item["name"] as? String ?? "")
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [name, detail]); cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 4; cell.toolTip = item["description"] as? String; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow) else { clearSelection(); refreshState(); return }
        let item = rows[table.selectedRow]; clearSelection(); selected = item; title.stringValue = item["title"] as? String ?? item["name"] as? String ?? ""
        uri.stringValue = item["uri"] as? String ?? item["uriTemplate"] as? String ?? ""; uri.isHidden = kind == "prompts"; uri.isEditable = kind == "templates"; uri.toolTip = uri.stringValue
        viewer.string = item["description"] as? String ?? ""
        let parameters = item["arguments"] as? [[String: Any]] ?? []
        for field in parameters {
            guard let name = field["name"] as? String else { continue }
            let label = NSTextField(labelWithString: (field["title"] as? String ?? name) + (field["required"] as? Bool == true ? " *" : "")); label.font = .systemFont(ofSize: 12, weight: .medium); label.lineBreakMode = .byTruncatingTail; label.toolTip = field["description"] as? String; label.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let text = NSTextView(); text.isRichText = false; text.font = .systemFont(ofSize: 12); text.textContainerInset = NSSize(width: 6, height: 6); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.delegate = self; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false; text.setAccessibilityLabel("提示词参数 " + name)
            let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.heightAnchor.constraint(equalToConstant: 54).isActive = true
            let row = NSStackView(views: [label, scroll]); row.spacing = 8; arguments.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: arguments.widthAnchor).isActive = true; fields[name] = text
        }
        argumentHeight.constant = min(164, CGFloat(parameters.count) * 64); argumentScroll.isHidden = parameters.isEmpty; refreshState()
    }
    @objc private func readContent() {
        guard job == nil, let id = serverID, let selected, let connection = store.mcp.token(id, owner: sessionOwner) else { return }
        let requestedKind = kind, requestedURI = uri.stringValue, currentCatalog = catalog, values = fields.mapValues(\.string)
        launch {
            _ = try self.taskScope(id, operation: requestedKind == "prompts" ? "connect_mcp" : "read_mcp_resource")
            let result: AgentMCPContentPreview
            if requestedKind == "prompts" { result = try await self.store.mcp.prompt(id, owner: self.sessionOwner, connection: connection, catalog: currentCatalog, name: selected["name"] as? String ?? "", arguments: values.filter { !$0.value.isEmpty }) }
            else {
                guard !requestedURI.contains("{"), !requestedURI.contains("}") else { throw PetError("请填写展开后的资源 URI") }
                result = try await self.store.mcp.readResource(id, owner: self.sessionOwner, connection: connection, catalog: currentCatalog, uri: requestedURI, template: requestedKind == "templates" ? selected["uriTemplate"] as? String : nil)
            }
            try Task.checkCancellation(); guard !self.closed else { return }; _ = try self.taskScope(id, operation: requestedKind == "prompts" ? "connect_mcp" : "read_mcp_resource")
            self.preview = result; self.catalog = result.catalog; self.inserted = false; self.viewer.string = result.displayText; self.viewer.scrollToBeginningOfDocument(nil); self.state.stringValue = ""
            if let part = result.parts.first(where: { $0.mimeType.hasPrefix("image/") }), let source = CGImageSourceCreateWithData(part.data as CFData, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { self.image.image = NSImage(cgImage: thumbnail, size: .zero); self.image.isHidden = false; self.imageHeight.constant = 150 }
        }
    }
    @objc private func addContent() {
        guard job == nil, let preview, !inserted, store.mcp.previewCurrent(preview) else { return }
        launch {
            _ = try self.taskScope(preview.server.id, operation: preview.kind == "prompts" ? "connect_mcp" : "read_mcp_resource")
            let files = try await AgentMCPContent.importParts(preview, store: self.store, taskID: self.taskID)
            do {
                try Task.checkCancellation(); guard !self.closed, self.store.mcp.previewCurrent(preview) else { throw PetError("内容或连接已变化，请重新预览") }
                _ = try self.taskScope(preview.server.id, operation: preview.kind == "prompts" ? "connect_mcp" : "read_mcp_resource")
                try self.insert(preview.kind == "prompts" ? preview.promptText : "", files.map(\.id))
                self.inserted = true; self.state.stringValue = "已加入草稿"
            } catch { for file in files { try? AgentAttachments.removeDraft(store: self.store, taskID: self.taskID, id: file.id) }; throw error }
        }
    }
    @objc private func toggleTracking() {
        guard job == nil, let preview else { return }
        let enabled = track.state == .on
        launch { _ = try self.taskScope(preview.server.id, operation: "list_mcp_resources"); try await self.store.mcp.subscription(preview, enabled: enabled); self.state.stringValue = "" }
    }
    private func refreshState() {
        let id = serverID, connected = id.map { store.mcp.connected($0, owner: sessionOwner) } ?? false, busy = job != nil
        let scopeError: String? = { guard let id else { return "暂无可用连接器" }; do { _ = try taskScope(id); return nil } catch { return error.localizedDescription } }()
        connect.isEnabled = id != nil && !connected && !busy && scopeError == nil; disconnect.isEnabled = connected || busy; disconnect.title = busy ? "取消" : "断开"
        refresh.isEnabled = connected && !busy && scopeError == nil; more.isHidden = nextOffset == nil; more.isEnabled = !busy
        servers.isEnabled = !busy; kinds.isEnabled = !busy; table.isEnabled = !busy; search.isEnabled = connected && (!busy || loadingList); uri.isEnabled = !busy; for field in fields.values { field.isEditable = !busy }
        let catalogCurrent = id.flatMap { id in store.mcp.token(id, owner: sessionOwner).map { store.mcp.contentCatalogCurrent(id, owner: sessionOwner, connection: $0, catalog: catalog, kind: kind) } } ?? false
        read.title = kind == "prompts" ? "预览" : "读取"; read.isEnabled = connected && selected != nil && !busy && scopeError == nil && catalogCurrent
        add.title = kind == "prompts" ? "加入草稿" : "加入附件"; add.isEnabled = !busy && !inserted && scopeError == nil && preview.map(store.mcp.previewCurrent) == true
        track.isHidden = preview?.kind != "resources"; track.isEnabled = !busy && scopeError == nil && preview.map(store.mcp.supportsSubscription) == true; track.state = preview.map(store.mcp.subscribed) == true ? .on : .off
        if let server = id.flatMap({ try? store.mcp.server($0, workspace: workspace) }) { destination.stringValue = server.destination; destination.toolTip = server.destination }
        else { destination.stringValue = "" }
        if let scopeError { state.stringValue = scopeError }
        else if connected, !catalog.isEmpty, !catalogCurrent { state.stringValue = "目录已更新，请刷新" }
        else if let preview, !store.mcp.previewCurrent(preview) { state.stringValue = connected ? "内容已更新，请重新读取" : "连接已断开" }
        state.toolTip = state.stringValue
    }
    func windowWillClose(_ notification: Notification) { closed = true; job?.cancel(); if let observer { store.mcp.removeContentObserver(observer) }; store.mcp.disconnect(owner: sessionOwner) }
}
