import AppKit

@MainActor extension AgentKnowledgeCardWindow {
    struct RecoveryScope: Codable { var root: String, branch: String }
    struct RecoveryState: Codable {
        var version = 1
        var taskID: String, scope: RecoveryScope, language: String, revision: String
        var book: AgentKnowledgeCardBook?, selected: String?
        var query: String, category: Int, focus: String, mode: Int, reference: Int
        var title: String, body: String?, dirty: Bool
        var views: [String: AgentTextViewport], fields: [String: AgentTextViewport.Selection], active: String
        var source: AgentKnowledgeSourcePage.RecoveryState?, sourceOwner: AgentKnowledgeCard?
        var versionReview: AgentKnowledgeVersionPosition? = nil
    }
    static func recoveryState(_ page: AgentWorkspaceRecovery.Page) throws -> RecoveryState {
        guard page.kind == "knowledge-cards", page.asset == nil,
              let raw = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(raw.keys).isSubset(of: ["version", "taskID", "scope", "language", "revision", "book", "selected", "query", "category", "focus", "mode", "reference", "title", "body", "dirty", "views", "fields", "active", "source", "sourceOwner", "versionReview"]),
              let scope = raw["scope"] as? [String: Any], Set(scope.keys).isSubset(of: ["root", "branch"]) else { throw PetError("知识卡片恢复格式不受支持，原编辑已保留") }
        func card(_ raw: Any) throws {
            guard let card = raw as? [String: Any], Set(card.keys).isSubset(of: ["id", "title", "kind", "body", "sources", "manual", "updated"]), let sources = card["sources"] as? [[String: Any]], sources.allSatisfy({ Set($0.keys).isSubset(of: ["path", "line", "endLine", "sha256"]) }) else { throw PetError("卡片原版本格式不受支持，原编辑已保留") }
        }
        if let value = raw["book"], !(value is NSNull) {
            guard let book = value as? [String: Any], Set(book.keys).isSubset(of: ["version", "id", "workspace", "branch", "language", "sourceRevision", "taskID", "cards", "created", "focus"]), let cards = book["cards"] as? [Any] else { throw PetError("卡片版本恢复格式不受支持") }
            try cards.forEach(card)
        }
        if let value = raw["sourceOwner"], !(value is NSNull) { try card(value) }
        if let value = raw["source"], !(value is NSNull) { try AgentKnowledgeSourcePage.RecoveryState.validateObject(value) }
        if let value = raw["versionReview"], !(value is NSNull) { try AgentKnowledgeVersionPosition.validateObject(value) }
        for value in (raw["views"] as? [String: Any] ?? [:]).values { try AgentTextViewport.validateObject(value) }
        for value in (raw["fields"] as? [String: Any] ?? [:]).values { guard let field = value as? [String: Any], Set(field.keys).isSubset(of: ["location", "length"]) else { throw PetError("卡片输入位置格式不受支持") } }
        let value = try JSONDecoder().decode(RecoveryState.self, from: page.state), root = value.scope.root
        guard value.version == 1, value.taskID == page.taskID, UUID(uuidString: value.taskID) != nil,
              root.hasPrefix("/"), root.utf8.count <= 8192, !root.contains("\0"), URL(fileURLWithPath: root).standardizedFileURL.path == root,
              !value.scope.branch.isEmpty, value.scope.branch.utf8.count <= 4096, !value.scope.branch.contains("\0"), ["zh", "en"].contains(value.language),
              value.revision.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (0...AgentKnowledgeCardKind.allCases.count).contains(value.category), [0, 1].contains(value.mode), (-1...11).contains(value.reference),
              value.query.utf8.count <= 100_000, value.focus.utf8.count <= 100_000, value.title.utf8.count <= 100_000, (value.body?.utf8.count ?? 0) <= 2_000_000,
              value.dirty == page.dirty, !value.dirty || (value.mode == 1 && value.body != nil && value.selected != nil),
              value.views.count <= 60, value.views.allSatisfy({ key, viewport in let parts = key.split(separator: "|"); return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && ["0", "1"].contains(String(parts[1])) && viewport.valid }),
              Set(value.fields.keys).isSubset(of: ["query", "analysis", "title"]), ["query", "analysis", "title", "body"].contains(value.active),
              value.source?.valid != false, value.source.map({ $0.taskID == value.taskID && $0.root == root }) ?? true,
              value.sourceOwner.map(AgentKnowledgeCards.valid) ?? true else { throw PetError("知识卡片恢复范围或位置无效，原编辑已保留") }
        if let book = value.book {
            guard book.version == 1, UUID(uuidString: book.id) != nil, book.workspace == root, book.branch == value.scope.branch, book.language == value.language,
                  book.cards.count <= 30, Set(book.cards.map(\.id)).count == book.cards.count, book.cards.allSatisfy(AgentKnowledgeCards.valid),
                  value.selected.map({ id in book.cards.contains { $0.id == id } }) ?? true else { throw PetError("卡片原版本与所属范围不符") }
        } else { guard value.selected == nil, !value.dirty else { throw PetError("卡片编辑缺少原始版本") } }
        if let selected = value.book?.cards.first(where: { $0.id == value.selected }) { guard selected.sources.indices.contains(value.reference) else { throw PetError("卡片引用选项无效，原记录已保留") } }
        else { guard value.reference == -1 else { throw PetError("卡片引用缺少对应卡片") } }
        for (key, selection) in value.fields {
            let text = key == "query" ? value.query : key == "analysis" ? value.focus : value.title
            guard selection.valid(in: (text as NSString).length) else { throw PetError("卡片输入选区无效，原编辑已保留") }
        }
        if let source = value.source {
            guard let owner = value.sourceOwner, owner.sources.contains(where: { URL(fileURLWithPath: $0.path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path == URL(fileURLWithPath: source.path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path && $0.sha256 == source.citationHash && $0.line == source.line }) else { throw PetError("卡片来源与原引用不符") }
        }
        if let review = value.versionReview {
            guard review.valid, !value.dirty, review.context.kind == .cards, review.context.taskID == value.taskID,
                  review.context.workspace == root, review.context.branch == value.scope.branch, review.context.language == value.language else {
                throw PetError("恢复的卡片版本与原任务、项目或语言不符")
            }
        }
        return value
    }
    var canPreserveForQuit: Bool { openedScope != nil && task?.sideTask?.retained != false && task != nil }
    func prepareWorkspaceNavigation() -> Bool { !busy && reviewWindow?.hasPendingOperation != true && presentingWindow?.hasBlockingDialog != true }
    func captureWorkspaceRecovery() throws -> AgentWorkspaceRecovery.Page? {
        guard prepareWorkspaceNavigation() else { throw PetError("请先完成当前知识卡片操作") }
        guard let scope = openedScope else { if dirty { throw PetError("卡片原范围尚未读取，编辑已保留") }; return nil }
        rememberCardViewport(); rememberCurrentFieldSelection()
        let state = RecoveryState(taskID: taskID, scope: scope, language: selectedLanguage, revision: revision, book: value, selected: selected?.id,
            query: search.stringValue, category: category.indexOfSelectedItem, focus: focus.stringValue, mode: format.selectedSegment, reference: sources.indexOfSelectedItem, title: titleField.stringValue,
            body: format.selectedSegment == 1 ? preview.string : nil, dirty: dirty, views: savedViews, fields: fieldSelections, active: lastContentFocus,
            source: try sourceWindow?.captureWorkspaceRecovery(), sourceOwner: sourceOwner, versionReview: try reviewWindow?.captureVersionPosition())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let page = AgentWorkspaceRecovery.Page(taskID: taskID, kind: "knowledge-cards", state: try encoder.encode(state), dirty: dirty, asset: nil)
        _ = try Self.recoveryState(page); return page
    }
    func restoreWorkspaceRecovery(_ page: AgentWorkspaceRecovery.Page) throws {
        let state = try Self.recoveryState(page)
        guard state.taskID == taskID, task != nil else { throw PetError("知识卡片原任务不可用") }
        applyingRecovery = true; loading = true
        defer { loading = false; applyingRecovery = false; onWorkspaceChange?() }
        openedScope = state.scope; hasRestoredSnapshot = true; value = state.book; revision = state.revision
        language.selectItem(at: state.language == "en" ? 1 : 0); category.selectItem(at: state.category); search.stringValue = state.query; focus.stringValue = state.focus
        format.selectedSegment = state.mode; savedViews = state.views; fieldSelections = state.fields; lastContentFocus = state.active; filter(preferred: state.selected)
        if state.selected == nil { table.deselectAll(nil); selected = nil; render() }
        if sources.numberOfItems > state.reference, state.reference >= 0 { sources.selectItem(at: state.reference) }
        if state.mode == 1 { titleField.stringValue = state.title; preview.string = state.body ?? selected?.body ?? "" }
        dirty = state.dirty; restoreRememberedCardViewport(); cardFocusRequested = true
        let branch = state.scope.branch == "folder" ? "文件夹" : state.scope.branch.replacingOccurrences(of: "refs/heads/", with: "")
        scopeLabel.stringValue = URL(fileURLWithPath: state.scope.root).lastPathComponent + " · " + branch; scopeLabel.toolTip = state.scope.root
        if let source = state.source { sourceOwner = state.sourceOwner; retainSource(try AgentKnowledgeSourcePage(store: store, restoring: source)); if source.presentation == "window" { sourceWindow?.presentRecoveredWindow() } }
        try restoreCardVersionReview(state.versionReview)
        checkRestoredContext()
    }
    func requireOriginalCardScope(checkLanguage: Bool = true) throws {
        guard let task, let original = openedScope else { throw PetError("卡片所属范围尚未读取") }
        let current = try cards.scope(task)
        guard current.root == original.root, current.branch == original.branch else { throw PetError("卡片工作区或分支已变化，原编辑已保留；请刷新核对") }
        if checkLanguage, try cards.options(workspace: current.root).language != selectedLanguage { throw PetError("卡片语言已变化，原编辑已保留；请刷新核对") }
    }
    func checkRestoredContext() {
        do { try requireOriginalCardScope(); guard let task, try cards.book(task, language: selectedLanguage).1 == revision else { throw PetError("卡片已在外部变化，原编辑和来源已保留；请刷新核对") }; state.stringValue = dirty ? "有未保存编辑；保存时核对当前版本" : "" }
        catch { state.stringValue = error.localizedDescription }
    }
    func resetRecoverySnapshot() {
        hasRestoredSnapshot = false; sourceWindow?.onClose = nil; sourceWindow?.endSettingsHosting(); sourceWindow = nil; sourceOwner = nil; openedScope = nil; savedViews = [:]; pendingCardViewport = nil; renderedCardViewKey = nil
    }
    func retainSource(_ page: AgentKnowledgeSourcePage) {
        sourceWindow?.onClose = nil; sourceWindow?.close(); sourceWindow = page
        page.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
        page.onClose = { [weak self, weak page] in guard let self, sourceWindow === page else { return }; sourceWindow = nil; sourceOwner = nil; onWorkspaceChange?() }
    }
    func rememberCardViewport() {
        guard !loading, !applyingRecovery, pendingCardViewport == nil, let key = renderedCardViewKey, var viewport = try? AgentTextViewport(preview) else { return }
        viewport.focused = lastContentFocus == "body"; savedViews[key] = viewport
    }
    func restoreRememberedCardViewport() {
        if !applyingRecovery, let old = renderedCardViewKey?.split(separator: "|").first, old != selected.map({ Substring($0.id) }) { fieldSelections["title"] = nil }
        renderedCardViewKey = selected.map { $0.id + "|" + String(format.selectedSegment) }
        pendingCardViewport = renderedCardViewKey.flatMap { savedViews[$0] }
        if !applyingRecovery, let pendingCardViewport, !pendingCardViewport.matches(preview) { if let key = renderedCardViewKey { savedViews[key] = nil }; self.pendingCardViewport = nil }
        scheduleCardViewport()
    }
    func scheduleCardViewport() {
        guard !viewportScheduled, !applyingRecovery, pendingCardViewport != nil || cardFocusRequested else { return }; viewportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { viewportScheduled = false }
            guard isPageVisible, presentingWindow?.hasBlockingDialog != true else { return }
            applyingRecovery = true; presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            if let viewport = pendingCardViewport, viewport.apply(to: preview, focus: cardFocusRequested && lastContentFocus == "body") { pendingCardViewport = nil }
            if cardFocusRequested, lastContentFocus == "body", pendingCardViewport == nil { presentingWindow?.makeFirstResponder(preview) }
            if cardFocusRequested, let field = recoveryFields[lastContentFocus] {
                presentingWindow?.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView, let selection = fieldSelections[lastContentFocus], selection.valid(in: (editor.string as NSString).length) { editor.setSelectedRange(selection.range) }
            }
            cardFocusRequested = false; applyingRecovery = false; onWorkspaceChange?()
        }
    }
    var recoveryFields: [String: NSTextField] { ["query": search, "analysis": focus, "title": titleField] }
    func rememberControlFocus(_ field: NSTextField?) {
        guard !applyingRecovery, !cardFocusRequested, let field, let key = recoveryFields.first(where: { $0.value === field })?.key else { return }; lastContentFocus = key; rememberCurrentFieldSelection()
    }
    func rememberCurrentFieldSelection() {
        for (key, field) in recoveryFields { if let editor = field.currentEditor() as? NSTextView { let range = editor.selectedRange(); fieldSelections[key] = .init(location: range.location, length: range.length) } }
        for (key, selection) in fieldSelections { if let field = recoveryFields[key], !selection.valid(in: (field.stringValue as NSString).length) { let count = (field.stringValue as NSString).length, location = min(selection.location, count); fieldSelections[key] = .init(location: location, length: min(selection.length, count - location)) } }
    }
    @objc func cardFieldSelectionChanged(_ notification: Notification) {
        guard !applyingRecovery, !cardFocusRequested, let editor = notification.object as? NSTextView, editor.isFieldEditor, presentingWindow?.firstResponder === editor else { return }
        for (key, field) in recoveryFields where field.currentEditor() === editor { lastContentFocus = key; rememberCurrentFieldSelection(); onWorkspaceChange?() }
    }
    @objc func cardViewportChanged(_ notification: Notification) { if !applyingRecovery, !cardFocusRequested, pendingCardViewport == nil { if presentingWindow?.firstResponder === preview { lastContentFocus = "body" }; onWorkspaceChange?() } }
    func checkRecovery(title: String? = nil, body: String? = nil, target: String = "", y: Double? = nil, titleSelection: NSRange? = nil, action: String = "") throws {
        guard ["--knowledge-reader-recovery-check", "--knowledge-reader-recovery-ui"].contains(where: CommandLine.arguments.contains) else { return }
        if title != nil || body != nil || !target.isEmpty {
            if format.selectedSegment != 1 { rememberCardViewport(); format.selectedSegment = 1; render() }
            if let title { titleField.stringValue = title; dirty = true }
            if let body { preview.string = body; pendingCardViewport = nil; dirty = true }
            if !target.isEmpty { let range = (preview.string as NSString).range(of: target); guard range.location != NSNotFound else { throw PetError("卡片编辑选文不存在") }; preview.setSelectedRange(range); presentingWindow?.makeFirstResponder(preview); lastContentFocus = "body" }
            if let y { preview.scroll(NSPoint(x: 0, y: y)) }
        }
        if let titleSelection {
            presentingWindow?.makeFirstResponder(titleField)
            if let editor = titleField.currentEditor() as? NSTextView { editor.setSelectedRange(titleSelection) }; lastContentFocus = "title"; rememberCurrentFieldSelection()
        }
        if action == "source" { openSource() }; if action == "save" { saveCard() }
        onWorkspaceChange?()
    }
}
