import AppKit

@MainActor final class AgentKnowledgeWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String
    private let search = NSSearchField(), table = NSTableView(), preview = NSTextView(), state = NSTextField(labelWithString: "")
    private let find = NSButton(title: "检索", target: nil, action: nil), update = NSButton(title: "更新索引", target: nil, action: nil), rebuild = NSButton(title: "重建", target: nil, action: nil), open = NSButton(title: "打开文件", target: nil, action: nil)
    private var hits: [AgentIndexHit] = [], job: Task<Void, Never>?, busy = false
    var onOpenWiki: (() -> Void)?
    var onOpenCards: (() -> Void)?
    var onOpenSource: ((URL) throws -> Void)?
    init(store: AgentStore, taskID: String) {
        self.store = store; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "项目知识 · " + (store.task(taskID)?.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "项目"); window.minSize = NSSize(width: 700, height: 470); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        search.placeholderString = "搜索代码、文档或符号"; search.sendsWholeSearchString = true; search.sendsSearchStringImmediately = false
        search.target = self; search.action = #selector(searchProject)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 32; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("项目检索结果")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; table.style = .inset; table.backgroundColor = .clear
        preview.isEditable = false; preview.isRichText = false; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.textContainerInset = NSSize(width: 12, height: 12)
        let viewer = NSScrollView(); viewer.documentView = preview; viewer.hasVerticalScroller = true
        preview.drawsBackground = false; preview.textColor = .labelColor
        for scroll in [list, viewer] { scroll.drawsBackground = false; scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder }
        for button in [find, update, rebuild, open] { button.target = self }
        find.action = #selector(searchProject); update.action = #selector(updateIndex); rebuild.action = #selector(rebuildIndex); open.action = #selector(openSource)
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingMiddle
        let wiki = NSButton(title: "Repo Wiki", target: self, action: #selector(openWiki))
        let cards = NSButton(title: "知识卡片", target: self, action: #selector(openCards)); cards.isEnabled = store.task(taskID)?.workspace != nil
        let query = NSStackView(views: [search, find]), actions = NSStackView(views: [update, rebuild, NSView(), wiki, cards])
        let header = NSStackView(views: [query, actions]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        for row in [query, actions] { row.spacing = 8; row.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        let footer = NSStackView(views: [state, NSView(), open]); footer.spacing = 8; open.isEnabled = false
        for view in [header, list, viewer, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), list.widthAnchor.constraint(equalToConstant: 165), list.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            viewer.topAnchor.constraint(equalTo: list.topAnchor), viewer.bottomAnchor.constraint(equalTo: list.bottomAnchor), viewer.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        if let workspace = store.task(taskID)?.workspace, let stats = try? AgentProjectIndex(workspace: workspace, storage: store.directory).snapshot() { state.stringValue = "\(stats.files) 个文件" }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { job?.cancel() }
    @objc private func searchProject() { run(query: search.stringValue) }
    @objc private func updateIndex() { run(query: nil) }
    @objc private func rebuildIndex() { run(query: nil, rebuild: true) }
    @objc private func openWiki() { onOpenWiki?() }
    @objc private func openCards() { onOpenCards?() }
    private func run(query: String?, rebuild: Bool = false) {
        guard !busy else { return }
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if query != nil && query?.isEmpty != false { return }
        busy = true; for button in [find, update, self.rebuild] { button.isEnabled = false }; state.stringValue = "检索中…"
        job = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; for button in [find, update, self.rebuild] { button.isEnabled = true } }
            do {
                let name = query == nil ? "index_project" : "search_project", args: [String: Any] = query.map { ["query": $0] } ?? ["rebuild": rebuild]
                let call = AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
                let tools = AgentTools(store: store, taskID: taskID), directory = try tools.gitDirectory(for: call)
                if let reason = try tools.approvalReason(for: call, gitDirectory: directory) {
                    let alert = AgentConfirmation(); alert.messageText = "连接项目知识"; alert.informativeText = reason; alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { throw PetError("已取消") }
                    if let directory { store.update(taskID) { $0.gitDirectory = directory } }
                }
                let result = try await tools.execute(call, gitDirectory: directory); try Task.checkCancellation()
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let value = try decoder.decode(AgentIndexResult.self, from: Data(result.text.utf8))
                hits = value.matches; table.delegate = nil; table.reloadData(); table.deselectAll(nil); table.delegate = self
                preview.string = ""; open.isEnabled = false
                state.stringValue = "\(value.index.files) 个文件 · 更新 \(value.index.updatedFiles)" + (query == nil ? "" : " · \(hits.count) 个结果") + (value.index.partial ? " · 部分索引" : "") + (value.index.skipped > 0 ? " · 跳过 \(value.index.skipped)" : "")
                if !hits.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                if query != nil && hits.isEmpty { preview.string = "没有找到匹配内容" }
            } catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hit = hits[row], label = NSTextField(labelWithString: hit.path + ":\(hit.line)")
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = hit.path; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard hits.indices.contains(table.selectedRow), let task = store.task(taskID) else { return }
        let hit = hits[table.selectedRow]
        do { let files = try AgentFiles(workspace: task.workspace); preview.string = try files.read(hit.path, offset: max(1, hit.line - 4), limit: 100); open.isEnabled = true }
        catch { preview.string = error.localizedDescription; open.isEnabled = false }
    }
    @objc private func openSource() {
        guard hits.indices.contains(table.selectedRow), let task = store.task(taskID), let files = try? AgentFiles(workspace: task.workspace), let url = try? files.resolve(hits[table.selectedRow].path) else { return }
        do { if let onOpenSource { try onOpenSource(url) } else { NSWorkspace.shared.open(url) } }
        catch { state.stringValue = error.localizedDescription }
    }
    func checkState() -> [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled else { return [:] }
        return ["query": search.stringValue, "hits": hits.map { ["path": $0.path, "line": $0.line] as [String: Any] }, "preview": preview.string, "busy": busy, "state": state.stringValue]
    }
    func checkSearchAndOpen(_ query: String) async -> Bool {
        guard CommandLine.arguments.contains("--knowledge-page-check") else { return false }
        search.stringValue = query; searchProject(); await job?.value
        guard !hits.isEmpty, !preview.string.isEmpty else { return false }; openSource(); return true
    }
    func checkLayout(query: String, output: URL) async -> [String: Bool] {
        search.stringValue = query; run(query: query); await job?.value
        var checks: [String: Bool] = [:]
        if let first = hits.first, let task = store.task(taskID), let files = try? AgentFiles(workspace: task.workspace) {
            checks["nativeKnowledgePreviewMatchesSource"] = preview.string == (try? files.read(first.path, offset: max(1, first.line - 4), limit: 100)) && !preview.string.isEmpty
        } else { checks["nativeKnowledgePreviewMatchesSource"] = false }
        for (name, size) in [("normal", NSSize(width: 900, height: 620)), ("narrow", NSSize(width: 700, height: 470))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["nativeKnowledgeLayout-" + name] = search.bounds.width > 200 && preview.bounds.width > 350 && !search.hasAmbiguousLayout && !table.hasAmbiguousLayout
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("knowledge-" + name + ".png")) }
        }
        return checks
    }
}
