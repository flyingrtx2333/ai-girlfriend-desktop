import AppKit

@MainActor final class AgentKnowledgeWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate {
    let store: AgentStore, taskID: String
    let search = AgentSettingsSidebarSearchField(), table = NSTableView(), preview = NSTextView()
    let state = AgentSettingsStatusField("项目检索状态")
    let find = AgentDialogButton(title: "检索", target: nil, action: nil)
    let update = AgentDialogButton(title: "更新索引", target: nil, action: nil)
    let open = AgentDialogButton(title: "打开原文", target: nil, action: nil)
    private let more = AgentWorkbenchButton(), resultHeading = NSTextField(labelWithString: "")
    private let sourceHeading = NSTextField(labelWithString: ""), empty = NSTextField(labelWithString: "未找到匹配内容")
    var hits: [AgentIndexHit] = [], job: Task<Void, Never>?, busy = false
    var submittedQuery: String?, indexSummary = ""
    var openedRoot: String?, selectedHash: String?, sourceWindow: AgentKnowledgeSourcePage?, sourceOwner: AgentIndexHit?
    var pendingIndexViewport: AgentTextViewport?, querySelection: AgentTextViewport.Selection?, lastContentFocus = "query"
    var applyingRecovery = false, viewportScheduled = false, indexFocusRequested = false, previewBlocked = false
    var onOpenWiki: (() -> Void)?
    var onOpenCards: (() -> Void)?
    var onWorkspaceChange: (() -> Void)?
    init(store: AgentStore, taskID: String) {
        self.store = store; self.taskID = taskID
        openedRoot = store.task(taskID)?.workspace.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "项目检索 · " + (store.task(taskID)?.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "项目"); window.minSize = NSSize(width: 700, height: 470); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        search.placeholderString = "搜索代码、文档或符号"; search.sendsWholeSearchString = true; search.sendsSearchStringImmediately = false
        search.target = self; search.action = #selector(searchProject); search.delegate = self
        search.setAccessibilityLabel("检索项目文件"); window.initialFirstResponder = search
        search.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil; table.rowHeight = 43; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("项目检索结果")
        table.target = self; table.doubleAction = #selector(openSelectedRow)
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; table.style = .inset; table.backgroundColor = .clear
        preview.isEditable = false; preview.isRichText = false; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.textContainerInset = NSSize(width: 12, height: 12)
        let viewer = NSScrollView(); viewer.documentView = preview; viewer.hasVerticalScroller = true
        viewer.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(indexViewChanged(_:)), name: NSView.boundsDidChangeNotification, object: viewer.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(indexViewChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        preview.drawsBackground = false; preview.textColor = .labelColor
        preview.setAccessibilityLabel("匹配文件预览")
        for scroll in [list, viewer] { scroll.drawsBackground = false; scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder }
        for (button, action) in [(find, #selector(searchProject)), (update, #selector(updateIndex)), (open, #selector(openSource))] {
            button.target = self; button.action = action
        }
        AgentWorkbenchTheme.toolbar(more, title: "更多索引操作", symbol: "ellipsis")
        more.target = self; more.action = #selector(showIndexMenu)
        let wiki = AgentDialogButton(title: "Repo Wiki", target: self, action: #selector(openWiki))
        let cards = AgentDialogButton(title: "知识卡片", target: self, action: #selector(openCards))
        cards.isEnabled = store.task(taskID)?.workspace != nil
        for button in [find, update, open, wiki, cards] { AgentDialogStyle.action(button, prominent: button === find) }
        let query = NSStackView(views: [search, find]), actions = NSStackView(views: [update, more, NSView(), wiki, cards])
        let header = NSStackView(views: [query, actions]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 8
        for row in [query, actions] { row.spacing = 8; row.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        let divider = AgentThemeView(fill: AgentWorkbenchTheme.line)
        let surface = AgentThemeView(fill: AgentWorkbenchTheme.card, stroke: AgentWorkbenchTheme.line)
        surface.layer?.cornerRadius = 8; surface.layer?.borderWidth = 1
        surface.layer?.masksToBounds = true
        resultHeading.font = .systemFont(ofSize: 12, weight: .medium); resultHeading.textColor = AgentWorkbenchTheme.secondaryText
        sourceHeading.font = .systemFont(ofSize: 13, weight: .medium)
        for label in [resultHeading, sourceHeading] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        empty.font = .systemFont(ofSize: 13); empty.textColor = AgentWorkbenchTheme.secondaryText
        let readingHeader = NSStackView(views: [sourceHeading, NSView(), open]); readingHeader.spacing = 8; readingHeader.alignment = .centerY
        state.maximumNumberOfLines = 3; state.isHidden = false
        open.isEnabled = false
        for view in [header, surface, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [resultHeading, list, divider, readingHeader, viewer, empty] { surface.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        let proportional = list.widthAnchor.constraint(equalTo: surface.widthAnchor, multiplier: 0.32)
        proportional.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            surface.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), surface.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: header.trailingAnchor), surface.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -8),
            state.leadingAnchor.constraint(equalTo: header.leadingAnchor), state.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4), state.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
            resultHeading.topAnchor.constraint(equalTo: surface.topAnchor, constant: 19), resultHeading.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 12),
            resultHeading.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -8),
            list.topAnchor.constraint(equalTo: surface.topAnchor, constant: 48), list.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 2),
            list.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -4),
            proportional, list.widthAnchor.constraint(greaterThanOrEqualToConstant: 144), list.widthAnchor.constraint(lessThanOrEqualToConstant: 246),
            divider.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 2), divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: surface.topAnchor), divider.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            readingHeader.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12), readingHeader.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            readingHeader.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
            viewer.topAnchor.constraint(equalTo: readingHeader.bottomAnchor, constant: 6), viewer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -2),
            viewer.leadingAnchor.constraint(equalTo: divider.trailingAnchor), viewer.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -2),
            empty.centerXAnchor.constraint(equalTo: viewer.centerXAnchor), empty.centerYAnchor.constraint(equalTo: viewer.centerYAnchor)
        ])
        if let workspace = store.task(taskID)?.workspace, let stats = try? AgentProjectIndex(workspace: workspace, storage: store.directory).snapshot() {
            indexSummary = "\(stats.files) 个文件"; state.stringValue = indexSummary
        }
        refreshResultHeading()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { closeContent() }
    override func settingsWillLeave() { closeContent() }
    private func closeContent() { job?.cancel(); NotificationCenter.default.removeObserver(self); sourceWindow?.onClose = nil; sourceWindow?.endSettingsHosting(); sourceWindow = nil; sourceOwner = nil }
    override func settingsDidAppear() {
        super.settingsDidAppear(); indexFocusRequested = true
        if let sourceWindow, sourceWindow.needsHostedPresentation, onSettingsPush != nil { presentSettingsChild(sourceWindow) }
        scheduleIndexViewport()
    }
    override func pageDidLayout() { scheduleIndexViewport() }
    @objc private func searchProject() { run(query: search.stringValue) }
    @objc private func updateIndex() { run(query: submittedQuery, refreshing: true) }
    @objc private func rebuildIndex() { run(query: submittedQuery, refreshing: true, rebuild: true) }
    @objc private func showIndexMenu() {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "重建索引", action: #selector(rebuildIndex), keyEquivalent: "")
        item.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }
    @objc private func openWiki() { do { try requireOriginalIndexScope(); onOpenWiki?() } catch { showIndexFailure(error) } }
    @objc private func openCards() { do { try requireOriginalIndexScope(); onOpenCards?() } catch { showIndexFailure(error) } }

    func showIndexFailure(_ error: Error) {
        state.stringValue = error.localizedDescription
        state.textColor = AgentDialogStyle.error
    }

    func refreshResultHeading() {
        let selected = hits.indices.contains(table.selectedRow) ? hits[table.selectedRow] : nil
        resultHeading.stringValue = hits.isEmpty ? "检索结果" : "\(hits.count) 个结果"
        if let submittedQuery, submittedQuery != search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) {
            resultHeading.stringValue += " · " + submittedQuery
        }
        resultHeading.toolTip = resultHeading.stringValue
        sourceHeading.stringValue = selected.map { ($0.path as NSString).lastPathComponent + "  ·  第 \($0.line) 行" } ?? ""
        sourceHeading.toolTip = selected?.path
        empty.isHidden = busy || !hits.isEmpty || submittedQuery == nil
    }

    private func run(query: String?, refreshing: Bool = false, rebuild: Bool = false) {
        guard !busy else { return }
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if query != nil && query?.isEmpty != false { return }
        do { try requireOriginalIndexScope() } catch { showIndexFailure(error); return }
        busy = true
        for button in [find, update, more, open] { button.isEnabled = false }
        state.stringValue = refreshing ? (rebuild ? "正在重建索引…" : "正在更新索引…") : "检索中…"
        refreshResultHeading()
        job = Task { [weak self] in
            guard let self else { return }
            defer {
                busy = false
                for button in [find, update, more] { button.isEnabled = true }
                open.isEnabled = selectedHash != nil && !previewBlocked
                refreshResultHeading(); onWorkspaceChange?()
            }
            do {
                func operation(_ name: String, query: String? = nil) throws -> AgentToolCall {
                    var args: [String: Any] = ["rebuild": rebuild]
                    if let query { args["query"] = query }
                    let bytes = try JSONSerialization.data(withJSONObject: args)
                    return .init(id: UUID().uuidString, name: name, arguments: String(decoding: bytes, as: UTF8.self))
                }
                let primary = refreshing ? try operation("index_project") : try operation("search_project", query: query)
                let tools = AgentTools(store: store, taskID: taskID), directory = try tools.gitDirectory(for: primary)
                let reason = try tools.approvalReason(for: primary, gitDirectory: directory)
                if let reason {
                    let alert = AgentConfirmation(); alert.messageText = "连接项目知识"; alert.informativeText = reason; alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
                    guard alert.runModal(for: presentingWindow) == .alertFirstButtonReturn else { throw PetError("已取消") }
                    try Task.checkCancellation()
                    try requireOriginalIndexScope()
                    guard try tools.gitDirectory(for: primary) == directory else { throw PetError("Git 元数据的位置已变化，请重新检索") }
                    if let currentReason = try tools.approvalReason(for: primary, gitDirectory: directory), currentReason != reason {
                        throw PetError("项目权限已变化，请重试")
                    }
                    if let directory { store.update(taskID) { $0.gitDirectory = directory } }
                }
                try requireOriginalIndexScope()
                var call = primary
                if refreshing, let query {
                    let search = try operation("search_project", query: query)
                    // A refresh retains the index action's permission and can
                    // repeat the stored search only within that approved scope.
                    do {
                        let searchDirectory = try tools.gitDirectory(for: search)
                        let searchReason = try tools.approvalReason(for: search, gitDirectory: searchDirectory)
                        if searchDirectory == directory, searchReason == nil || searchReason == reason { call = search }
                    } catch {
                        // The pending index operation remains available.
                    }
                }
                let result = try await tools.execute(call, gitDirectory: directory); try Task.checkCancellation(); try requireOriginalIndexScope()
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let value = try decoder.decode(AgentIndexResult.self, from: Data(result.text.utf8))
                indexSummary = "\(value.index.files) 个文件 · 更新 \(value.index.updatedFiles)" + (value.index.partial ? " · 部分索引" : "") + (value.index.skipped > 0 ? " · 跳过 \(value.index.skipped)" : "")
                state.stringValue = indexSummary
                if call.name == "search_project", let query {
                    let selected = refreshing && hits.indices.contains(table.selectedRow) ? hits[table.selectedRow] : nil
                    let viewport = selected != nil && !previewBlocked ? (try? AgentTextViewport(preview)) : nil
                    submittedQuery = query
                    showResults(value.matches, previous: selected, viewport: viewport)
                } else if hits.indices.contains(table.selectedRow) {
                    loadSelectedPreview(expected: selectedHash)
                }
            } catch { if !Task.isCancelled { showIndexFailure(error) } }
        }
    }

    private func showResults(_ matches: [AgentIndexHit], previous: AgentIndexHit?, viewport: AgentTextViewport?) {
        hits = matches
        let same = previous.flatMap { hit in hits.firstIndex { $0.path == hit.path && $0.line == hit.line } }
        let row = same ?? previous.flatMap { hit in hits.firstIndex { $0.path == hit.path } } ?? 0
        table.delegate = nil; table.reloadData(); table.deselectAll(nil)
        if hits.indices.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        table.delegate = self
        pendingIndexViewport = same.flatMap { hits[$0].sha256 == previous?.sha256 ? viewport : nil }
        selectedHash = nil
        loadSelectedPreview()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hit = hits[row], path = hit.path as NSString
        let title = NSTextField(labelWithString: path.lastPathComponent)
        let location = path.deletingLastPathComponent
        let detail = NSTextField(labelWithString: (location.isEmpty ? "" : location + " · ") + "第 \(hit.line) 行")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 1
        let view = NSTableCellView(); view.toolTip = hit.path + ":" + String(hit.line)
        view.setAccessibilityLabel(hit.path + "  第 \(hit.line) 行")
        view.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
                                     stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        pendingIndexViewport = nil; selectedHash = nil; loadSelectedPreview(); onWorkspaceChange?()
    }
    @objc private func openSelectedRow() {
        if table.clickedRow == table.selectedRow { openSource() }
    }
    @objc private func openSource() {
        guard open.isEnabled, !busy, hits.indices.contains(table.selectedRow) else { return }
        do {
            let files = try requireOriginalIndexScope(), hit = hits[table.selectedRow]
            let page = try AgentKnowledgeSourcePage(store: store, taskID: taskID, file: files.resolve(hit.path), offset: max(1, hit.line - 4), limit: 500, citationHash: hit.sha256, line: hit.line)
            sourceWindow?.onClose = nil; sourceWindow?.close(); sourceWindow = page; sourceOwner = hit
            retainSource(page); presentSettingsChild(page); onWorkspaceChange?()
        }
        catch { showIndexFailure(error) }
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
    func checkRecoverySearch(_ query: String, open: Bool = true) async -> Bool {
        guard ["--knowledge-reader-recovery-check", "--knowledge-reader-recovery-ui"].contains(where: CommandLine.arguments.contains) else { return false }
        search.stringValue = query; searchProject(); await job?.value
        guard !hits.isEmpty, !preview.string.isEmpty else { return false }; if open { openSource() }; return true
    }
    func checkRecoveryOpenSource() {
        if ["--knowledge-reader-recovery-check", "--knowledge-reader-recovery-ui"].contains(where: CommandLine.arguments.contains) { openSource() }
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
