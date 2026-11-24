import AppKit

@MainActor extension AgentKnowledgeWindow {
    struct RecoveryState: Codable {
        var version = 1
        var taskID: String, root: String, query: String
        var submittedQuery: String? = nil
        var hits: [AgentIndexHit], selected: Int, hash: String?, viewport: AgentTextViewport?
        var querySelection: AgentTextViewport.Selection?, active: String, summary: String
        var source: AgentKnowledgeSourcePage.RecoveryState?, sourceOwner: AgentIndexHit?
    }
    static func recoveryState(_ page: AgentWorkspaceRecovery.Page) throws -> RecoveryState {
        guard page.kind == "knowledge-index", !page.dirty, page.asset == nil,
              let raw = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(raw.keys).isSubset(of: ["version", "taskID", "root", "query", "submittedQuery", "hits", "selected", "hash", "viewport", "querySelection", "active", "summary", "source", "sourceOwner"]) else { throw PetError("项目检索恢复格式不受支持，原记录已保留") }
        func hit(_ raw: Any) throws { guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["path", "line", "text", "sha256", "source"]) else { throw PetError("检索结果恢复格式不受支持") } }
        try (raw["hits"] as? [Any] ?? []).forEach(hit)
        if let raw = raw["sourceOwner"], !(raw is NSNull) { try hit(raw) }
        if let raw = raw["viewport"], !(raw is NSNull) { try AgentTextViewport.validateObject(raw) }
        if let raw = raw["source"], !(raw is NSNull) { try AgentKnowledgeSourcePage.RecoveryState.validateObject(raw) }
        if let raw = raw["querySelection"], !(raw is NSNull) { guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["location", "length"]) else { throw PetError("检索输入位置格式不受支持") } }
        let value = try JSONDecoder().decode(RecoveryState.self, from: page.state)
        func validHit(_ hit: AgentIndexHit) -> Bool {
            !hit.path.isEmpty && !hit.path.hasPrefix("/") && !hit.path.contains("\0") && !hit.path.split(separator: "/").contains("..") && !AgentFiles.sensitive(hit.path) && hit.path.utf8.count <= 8192 &&
            (1...1_000_000).contains(hit.line) && hit.text.utf8.count <= 100_000 && hit.source.utf8.count <= 8192 && hit.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        }
        guard value.version == 1, value.taskID == page.taskID, UUID(uuidString: value.taskID) != nil,
              value.root.hasPrefix("/"), !value.root.contains("\0"), value.root.utf8.count <= 8192, URL(fileURLWithPath: value.root).standardizedFileURL.path == value.root,
              value.query.utf8.count <= 100_000, value.submittedQuery.map({ !$0.isEmpty && $0.count <= 500 && !$0.contains("\0") }) != false,
              value.summary.utf8.count <= 100_000, value.hits.count <= 500, value.hits.allSatisfy(validHit),
              value.selected == -1 || value.hits.indices.contains(value.selected), ["query", "preview"].contains(value.active),
              value.hash.map({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) ?? true,
              value.viewport?.valid != false, value.viewport == nil || value.hash != nil && value.selected >= 0,
              value.querySelection?.valid(in: (value.query as NSString).length) != false,
              value.source?.valid != false, value.source.map({ $0.taskID == value.taskID && $0.root == value.root }) ?? true,
              value.sourceOwner.map(validHit) ?? true else { throw PetError("项目检索恢复范围或位置无效，原记录已保留") }
        if let source = value.source {
            guard let owner = value.sourceOwner, owner.line == source.line, owner.sha256 == source.citationHash,
                  URL(fileURLWithPath: owner.path, relativeTo: URL(fileURLWithPath: value.root, isDirectory: true)).standardizedFileURL.path == URL(fileURLWithPath: source.path, relativeTo: URL(fileURLWithPath: value.root, isDirectory: true)).standardizedFileURL.path else { throw PetError("检索来源与原结果不符") }
        }
        return value
    }
    var canPreserveForQuit: Bool { openedRoot != nil && store.task(taskID).map { $0.sideTask?.retained != false } == true }
    func prepareWorkspaceNavigation() -> Bool {
        (!busy || knowledgeApproval?.isWaiting == true) && presentingWindow?.hasBlockingDialog != true
    }
    @discardableResult func requireOriginalIndexScope() throws -> AgentFiles {
        guard let root = openedRoot, let task = store.task(taskID) else { throw PetError("项目检索原任务不可用") }
        let files = try AgentFiles(workspace: task.workspace)
        guard files.root.path == root else { throw PetError("检索所属工作区已变化，原查询和来源已保留；请重新打开项目检索") }; return files
    }
    func loadSelectedPreview(expected: String? = nil) {
        let wasApplying = applyingRecovery; applyingRecovery = true; defer { applyingRecovery = wasApplying; scheduleIndexViewport() }
        refreshResultHeading()
        guard hits.indices.contains(table.selectedRow) else {
            if previewBlocked && !busy { state.stringValue = indexSummary }
            preview.string = ""; open.isEnabled = false; selectedHash = nil; previewBlocked = false
            return
        }
        do {
            let files = try requireOriginalIndexScope(), hit = hits[table.selectedRow], file = try files.resolve(hit.path)
            guard !AgentFiles.sensitive(files.relative(file)), try AgentProjectIndex(workspace: files.root.path, storage: store.directory).contains(hit.path) else { throw PetError("来源不在当前项目索引中，原结果已保留") }
            let hash = try files.fileHash(file, maximum: 2_000_000)
            guard expected == nil || hash == expected else { throw PetError("原来源已变化，请更新索引后核对") }
            guard hash == hit.sha256 else { throw PetError("检索结果所用文件已变化，请更新索引") }
            let body = try files.read(file.path, offset: max(1, hit.line - 4), limit: 100)
            guard hash == (try files.fileHash(file, maximum: 2_000_000)) else { throw PetError("读取期间来源已变化，请重试") }
            preview.string = body
            if let pendingIndexViewport { guard pendingIndexViewport.matches(preview) else { throw PetError("来源显示内容已变化，原位置已保留") } }
            else { preview.setSelectedRange(NSRange(location: 0, length: 0)); preview.scroll(.zero) }
            if previewBlocked && !busy { state.stringValue = indexSummary }
            selectedHash = hash; previewBlocked = false; open.isEnabled = !busy
        } catch { preview.string = ""; previewBlocked = true; open.isEnabled = false; showIndexFailure(error) }
    }
    func captureWorkspaceRecovery() throws -> AgentWorkspaceRecovery.Page? {
        guard prepareWorkspaceNavigation() else { throw PetError("请先完成当前项目检索操作") }
        guard let root = openedRoot else { return nil }
        rememberQuerySelection()
        var viewport = pendingIndexViewport
        if !previewBlocked, selectedHash != nil, viewport == nil { viewport = try AgentTextViewport(preview); viewport?.focused = lastContentFocus == "preview" }
        let value = RecoveryState(taskID: taskID, root: root, query: search.stringValue, submittedQuery: submittedQuery,
            hits: hits, selected: table.selectedRow, hash: selectedHash, viewport: viewport,
            querySelection: querySelection, active: lastContentFocus, summary: knowledgeApproval?.isWaiting == true ? indexSummary : state.stringValue,
            source: try sourceWindow?.captureWorkspaceRecovery(), sourceOwner: sourceOwner)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let page = AgentWorkspaceRecovery.Page(taskID: taskID, kind: "knowledge-index", state: try encoder.encode(value), dirty: false, asset: nil)
        _ = try Self.recoveryState(page); return page
    }
    func restoreWorkspaceRecovery(_ page: AgentWorkspaceRecovery.Page) throws {
        let value = try Self.recoveryState(page)
        guard value.taskID == taskID, store.task(taskID) != nil else { throw PetError("检索所属任务不存在") }
        applyingRecovery = true; defer { applyingRecovery = false; onWorkspaceChange?() }
        openedRoot = value.root; search.stringValue = value.query; submittedQuery = value.submittedQuery; hits = value.hits
        selectedHash = value.hash; pendingIndexViewport = value.viewport; querySelection = value.querySelection; lastContentFocus = value.active
        table.delegate = nil; table.reloadData(); table.deselectAll(nil)
        if value.hits.indices.contains(value.selected) { table.selectRowIndexes(IndexSet(integer: value.selected), byExtendingSelection: false) }; table.delegate = self
        state.stringValue = value.summary; loadSelectedPreview(expected: value.hash); indexFocusRequested = true
        if let source = value.source { sourceOwner = value.sourceOwner; let page = try AgentKnowledgeSourcePage(store: store, restoring: source); retainSource(page); if source.presentation == "window" { page.presentRecoveredWindow() } }
    }
    func retainSource(_ page: AgentKnowledgeSourcePage) {
        sourceWindow = page
        page.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
        page.onClose = { [weak self, weak page] in guard let self, sourceWindow === page else { return }; sourceWindow = nil; sourceOwner = nil; onWorkspaceChange?() }
    }
    func scheduleIndexViewport() {
        guard !viewportScheduled, !applyingRecovery, (!previewBlocked && pendingIndexViewport != nil) || indexFocusRequested else { return }; viewportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { viewportScheduled = false }
            guard isPageVisible, presentingWindow?.hasBlockingDialog != true else { return }
            applyingRecovery = true; presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            if !previewBlocked, let value = pendingIndexViewport, value.apply(to: preview, focus: indexFocusRequested && lastContentFocus == "preview") { pendingIndexViewport = nil }
            if !previewBlocked, indexFocusRequested, lastContentFocus == "preview", pendingIndexViewport == nil { presentingWindow?.makeFirstResponder(preview) }
            if indexFocusRequested, lastContentFocus == "query" {
                presentingWindow?.makeFirstResponder(search)
                if let editor = search.currentEditor() as? NSTextView, let selection = querySelection, selection.valid(in: (editor.string as NSString).length) { editor.setSelectedRange(selection.range) }
            }
            indexFocusRequested = false; applyingRecovery = false; onWorkspaceChange?()
        }
    }
    func rememberQuerySelection() { if let editor = search.currentEditor() as? NSTextView { let range = editor.selectedRange(); querySelection = .init(location: range.location, length: range.length) } }
    func controlTextDidChange(_ notification: Notification) {
        guard !applyingRecovery else { return }
        lastContentFocus = "query"; rememberQuerySelection(); refreshResultHeading(); onWorkspaceChange?()
    }
    func controlTextDidBeginEditing(_ notification: Notification) { if !applyingRecovery, !indexFocusRequested { lastContentFocus = "query"; rememberQuerySelection() } }
    @objc func indexViewChanged(_ notification: Notification) {
        guard !applyingRecovery, !indexFocusRequested else { return }
        if let editor = notification.object as? NSTextView, editor.isFieldEditor {
            guard search.currentEditor() === editor, presentingWindow?.firstResponder === editor else { return }; lastContentFocus = "query"; rememberQuerySelection()
        } else if notification.object as? NSTextView === preview || notification.object as? NSClipView === preview.enclosingScrollView?.contentView {
            guard pendingIndexViewport == nil else { return }; if presentingWindow?.firstResponder === preview { lastContentFocus = "preview" }
        } else { return }
        onWorkspaceChange?()
    }
    func checkRecoveryView(target: String = "", y: Double? = nil, querySelection: NSRange? = nil) throws {
        guard ["--knowledge-reader-recovery-check", "--knowledge-reader-recovery-ui"].contains(where: CommandLine.arguments.contains) else { return }
        if !target.isEmpty { let range = (preview.string as NSString).range(of: target); guard range.location != NSNotFound else { throw PetError("检索预览选文不存在") }; preview.setSelectedRange(range); presentingWindow?.makeFirstResponder(preview); lastContentFocus = "preview" }
        if let y { preview.scroll(NSPoint(x: 0, y: y)) }
        if let querySelection { presentingWindow?.makeFirstResponder(search); if let editor = search.currentEditor() as? NSTextView { editor.setSelectedRange(querySelection) }; lastContentFocus = "query"; rememberQuerySelection() }
        onWorkspaceChange?()
    }
}
