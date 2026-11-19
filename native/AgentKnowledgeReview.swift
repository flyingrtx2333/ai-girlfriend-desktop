import AppKit

struct AgentKnowledgeReviewItem {
    let title: String, detail: String, text: String
    var isDiff = false
    var identity: String? = nil
}
struct AgentKnowledgeReviewVersion {
    let id: String, title: String, detail: String
}
@MainActor struct AgentKnowledgeVersionContext: Codable, Equatable {
    enum Kind: String, Codable { case cards, wiki, project }
    var kind: Kind, taskID: String, workspace: String, branch: String, language: String

    init(_ kind: Kind, store: AgentStore, taskID: String, language: String) throws {
        guard let task = store.task(taskID), !task.archived else { throw PetError("版本所属任务不可用") }
        let scope = try store.knowledgeCards.scope(task)
        self.kind = kind; self.taskID = taskID; workspace = scope.root; branch = scope.branch; self.language = language
    }
    var valid: Bool {
        UUID(uuidString: taskID) != nil && workspace.hasPrefix("/") && workspace.utf8.count <= 8192 && !workspace.contains("\0") &&
        URL(fileURLWithPath: workspace).standardizedFileURL.path == workspace &&
        !branch.isEmpty && branch.utf8.count <= 4096 && !branch.contains("\0") && ["zh", "en"].contains(language)
    }
    func require(_ store: AgentStore) throws {
        guard try Self(kind, store: store, taskID: taskID, language: language) == self else {
            throw PetError("版本所属项目或分支已变化，原预览已保留")
        }
    }
}

@MainActor struct AgentKnowledgeVersionPosition: Codable {
    var version = 1
    var context: AgentKnowledgeVersionContext
    var versionID: String?, inPreview: Bool, itemID: String?
    var versionY: Double, itemY: Double
    var body: AgentTextViewport?, fingerprint: String?, targetSignature: String?
    var focus: String, presentation: String

    var valid: Bool {
        func hash(_ value: String?) -> Bool { value.map { $0.count == 64 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase } } ?? true }
        return version == 1 && context.valid && versionID.map { UUID(uuidString: $0) != nil } != false &&
            (!inPreview || versionID != nil && fingerprint != nil && targetSignature != nil) &&
            itemID.map { !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 8192 } != false &&
            (body == nil || inPreview && itemID != nil && body?.valid == true) && hash(fingerprint) && hash(targetSignature) &&
            [versionY, itemY].allSatisfy { $0.isFinite && (0...1_000_000_000).contains($0) } &&
            ["list", "body"].contains(focus) && ["page", "window"].contains(presentation)
    }
    static func validateObject(_ raw: Any) throws {
        guard let raw = raw as? [String: Any], Set(raw.keys).isSubset(of: ["version", "context", "versionID", "inPreview", "itemID", "versionY", "itemY", "body", "fingerprint", "targetSignature", "focus", "presentation"]),
              let context = raw["context"] as? [String: Any], Set(context.keys).isSubset(of: ["kind", "taskID", "workspace", "branch", "language"]) else {
            throw PetError("知识版本位置格式不受支持，原记录已保留")
        }
        if let body = raw["body"], !(body is NSNull) { try AgentTextViewport.validateObject(body) }
    }
}

@MainActor struct AgentKnowledgeReviewSnapshot {
    let scope: String, impact: String, items: [AgentKnowledgeReviewItem]
    var targetSignature: String? = nil
    let apply: () async throws -> String

    var fingerprint: String {
        let parts = items.flatMap { [$0.identity ?? "", $0.title, $0.detail, AgentFiles.hash(Data($0.text.utf8))] }
        return AgentFiles.hash(Data(parts.joined(separator: "\0").utf8))
    }
    static func target(_ wiki: AgentWikiSnapshot, cardsHash: String = "") -> String {
        let parts = [wiki.pointer, wiki.root, cardsHash] + wiki.data.keys.sorted().flatMap { [$0, AgentFiles.hash(wiki.data[$0]!)] }
        return AgentFiles.hash(Data(parts.joined(separator: "\0").utf8))
    }
    static func wikiItems(_ value: AgentWikiImportPreview) throws -> [AgentKnowledgeReviewItem] {
        try value.metadata.documents.map { document in
            guard let data = value.data[document.file] else { throw PetError("Wiki 预览缺少文档：" + document.file) }
            return AgentKnowledgeReviewItem(title: document.title, detail: document.file, text: try AgentTextFile.decode(data).text, identity: "wiki:" + document.file)
        }
    }
    static func cardItems(_ value: AgentKnowledgeCardBook) -> [AgentKnowledgeReviewItem] {
        value.cards.map { AgentKnowledgeReviewItem(title: $0.title, detail: $0.kind.title, text: $0.body, identity: "card:" + $0.id) }
    }
    static func scope(_ branch: String, language: String) -> String {
        let name = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
        return (branch == "folder" ? "文件夹" : name) + " · " + (language == "zh" ? "简体中文" : "English")
    }
    static func versionTitle(_ created: Date, count: String) -> String {
        DateFormatter.localizedString(from: created, dateStyle: .short, timeStyle: .medium) + " · " + count
    }
}

@MainActor final class AgentKnowledgeReviewWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let versions: [AgentKnowledgeReviewVersion], load: (Int?) async throws -> AgentKnowledgeReviewSnapshot
    private let onApplied: (String) -> Void
    private let table = NSTableView(), list = NSScrollView(), viewer = NSScrollView(), text = NSTextView(), body = NSView()
    private let diff = AgentGitDiffView(frame: .zero)
    private let scope = NSTextField(labelWithString: ""), impact = NSTextField(wrappingLabelWithString: ""), state = NSTextField(labelWithString: "")
    private let back = NSButton(title: "返回版本", target: nil, action: nil), cancel = NSButton(title: "取消", target: nil, action: nil)
    private let preview = NSButton(title: "预览", target: nil, action: nil), apply = NSButton(title: "", target: nil, action: nil)
    private var fullList: [NSLayoutConstraint] = [], documentList: [NSLayoutConstraint] = []
    private var snapshot: AgentKnowledgeReviewSnapshot?, selectedVersion: Int?, choosingVersion: Bool
    private var job: Task<Void, Never>?, closed = false, started = false
    private var showingDiff = false
    private let versionContext: AgentKnowledgeVersionContext?
    private var versionY: Double = 0, loadedFingerprint: String?, expectedTargetSignature: String?
    private var pendingPosition: AgentKnowledgeVersionPosition?, positionScheduled = false
    private var restoringPosition = false, recoveryPresentationScheduled = false, targetChanged = false
    var isRecoverableVersionReview: Bool { versionContext != nil }
    var hasPendingOperation: Bool { !closed && job != nil }
    private var hasKeyboardFocus: Bool {
        guard let content = pageContentView, let focus = presentingWindow?.firstResponder as? NSView else { return false }
        return focus.isDescendant(of: content)
    }
    var onClose: (() -> Void)?
    var onWorkspaceChange: (() -> Void)?

    init(title: String, action: String, scope: String, versions: [AgentKnowledgeReviewVersion] = [], context: AgentKnowledgeVersionContext? = nil, load: @escaping (Int?) async throws -> AgentKnowledgeReviewSnapshot, onApplied: @escaping (String) -> Void) {
        self.versions = versions; self.load = load; self.onApplied = onApplied; versionContext = context
        choosingVersion = context != nil || !versions.isEmpty
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 520, height: 420); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        self.scope.stringValue = scope; self.scope.lineBreakMode = .byTruncatingMiddle; self.scope.font = .systemFont(ofSize: 12, weight: .medium)
        impact.font = .systemFont(ofSize: 12); impact.maximumNumberOfLines = 2
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        for label in [self.scope, impact, state] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        table.addTableColumn(NSTableColumn(identifier: .init("item"))); table.headerView = nil; table.rowHeight = 48; table.style = .inset; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openVersion)
        table.setAccessibilityLabel("知识版本与文档列表"); list.documentView = table; list.hasVerticalScroller = true
        text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.textColor = .labelColor; text.drawsBackground = false
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 12, height: 12); text.setAccessibilityLabel("知识版本正文")
        viewer.documentView = text; viewer.hasVerticalScroller = true
        for scroll in [list, viewer] { scroll.borderType = .noBorder; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; body.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false }
        body.addSubview(diff); diff.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: body.leadingAnchor), list.topAnchor.constraint(equalTo: body.topAnchor), list.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
        fullList = [list.trailingAnchor.constraint(equalTo: body.trailingAnchor)]
        documentList = [list.widthAnchor.constraint(equalToConstant: 166), viewer.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), viewer.trailingAnchor.constraint(equalTo: body.trailingAnchor), viewer.topAnchor.constraint(equalTo: body.topAnchor), viewer.bottomAnchor.constraint(equalTo: body.bottomAnchor), diff.leadingAnchor.constraint(equalTo: viewer.leadingAnchor), diff.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), diff.topAnchor.constraint(equalTo: viewer.topAnchor), diff.bottomAnchor.constraint(equalTo: viewer.bottomAnchor)]
        for (button, action) in [(back, #selector(showVersions)), (cancel, #selector(cancelReview)), (preview, #selector(readPreview)), (apply, #selector(applyPreview))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        apply.title = action; cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        let actions = NSStackView(views: [back, cancel, NSView(), preview, apply]); actions.spacing = 8
        let column = NSStackView(views: [self.scope, impact, body, state, actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content; content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for child in column.arrangedSubviews { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor), column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        for scroll in [list, viewer] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSTextView.didChangeSelectionNotification, object: text)
        body.setContentHuggingPriority(.defaultLow, for: .vertical); updatePage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() { super.settingsDidAppear(); startIfNeeded(); scheduleRecoveredPosition() }
    override func pageDidLayout() { scheduleRecoveredPosition() }
    func windowDidBecomeKey(_ notification: Notification) { startIfNeeded(); scheduleRecoveredPosition() }
    private func startIfNeeded() {
        guard !started else { return }; started = true
        if let value = pendingPosition, value.inPreview { beginPreview(recovering: value) }
        else if !choosingVersion { readPreview() }
    }
    private func updatePage() {
        let focused = presentingWindow?.firstResponder as? NSView, keepFocus = hasKeyboardFocus
        NSLayoutConstraint.deactivate(fullList + documentList); NSLayoutConstraint.activate(choosingVersion ? fullList : documentList)
        viewer.isHidden = choosingVersion || showingDiff; diff.isHidden = choosingVersion || !showingDiff; impact.isHidden = choosingVersion; back.isHidden = choosingVersion || versions.isEmpty
        preview.title = choosingVersion ? "预览" : "重新预览"; apply.isHidden = choosingVersion
        let enabled = !hasPendingOperation && !closed
        for button in [back, cancel, preview] { button.isEnabled = enabled }
        preview.isEnabled = enabled && (!choosingVersion || selectedVersion != nil)
        apply.isEnabled = enabled && snapshot != nil && !targetChanged; table.isEnabled = enabled
        let initial: NSView = choosingVersion || enabled && snapshot != nil ? table : showingDiff ? diff.text : text
        window?.initialFirstResponder = initial
        // Hiding the focused preview must not hand arrow keys to the task list.
        if keepFocus, isPageVisible, focused?.canBecomeKeyView != true, initial.canBecomeKeyView { presentingWindow?.makeFirstResponder(initial) }
        presentingWindow?.recalculateKeyViewLoop()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { choosingVersion ? versions.count : snapshot?.items.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title: String, detail: String
        if choosingVersion { guard versions.indices.contains(row) else { return nil }; title = versions[row].title; detail = versions[row].detail }
        else { guard let items = snapshot?.items, items.indices.contains(row) else { return nil }; title = items[row].title; detail = items[row].detail }
        let cell = NSTableCellView(), heading = NSTextField(labelWithString: title), secondary = NSTextField(labelWithString: detail)
        heading.font = .systemFont(ofSize: 13, weight: .medium); secondary.font = .systemFont(ofSize: 11); secondary.textColor = AgentWorkbenchTheme.secondaryText
        for (label, offset) in [(heading, CGFloat(-9)), (secondary, CGFloat(10))] {
            label.lineBreakMode = .byTruncatingMiddle; cell.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: offset)])
        }
        cell.setAccessibilityLabel(title + " · " + detail); cell.toolTip = detail; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if choosingVersion {
            selectedVersion = versions.indices.contains(table.selectedRow) ? table.selectedRow : nil
            if !restoringPosition { pendingPosition = nil }
            updatePage()
        }
        else if let items = snapshot?.items, items.indices.contains(table.selectedRow) { showItem(items[table.selectedRow]) }
        positionChanged()
    }
    private func showItem(_ item: AgentKnowledgeReviewItem?) {
        showingDiff = item?.isDiff == true
        text.string = showingDiff ? "" : item?.text ?? ""; text.scrollToBeginningOfDocument(nil)
        if showingDiff || !diff.patch.isEmpty { diff.show(showingDiff ? item?.text ?? "" : "", oldTitle: "基线", newTitle: "当前提交", accessibilityContext: "Wiki"); diff.text.scrollToBeginningOfDocument(nil) }
        updatePage()
    }
    @objc private func readPreview() { beginPreview(recovering: nil) }
    private func beginPreview(recovering position: AgentKnowledgeVersionPosition?) {
        guard job == nil, !closed, !choosingVersion || selectedVersion != nil else { return }
        if let position { versionY = position.versionY }
        else { if choosingVersion { versionY = list.contentView.bounds.minY }; pendingPosition = nil }
        targetChanged = false; loadedFingerprint = nil; expectedTargetSignature = nil
        let waitingForVersion = choosingVersion && hasKeyboardFocus
        if waitingForVersion { presentingWindow?.makeFirstResponder(nil) }
        let version = selectedVersion; snapshot = nil; showItem(nil); state.stringValue = "正在读取预览…"; state.textColor = AgentWorkbenchTheme.secondaryText
        job = Task { @MainActor [weak self] in
            guard let self else { return }; var focusList = false
            defer {
                job = nil
                if !closed {
                    let restoreFocus = focusList || waitingForVersion && presentingWindow?.firstResponder === presentingWindow
                    updatePage()
                    if restoreFocus, pendingPosition == nil, isPageVisible { presentingWindow?.makeFirstResponder(table) }
                    scheduleRecoveredPosition(); onWorkspaceChange?()
                }
            }
            do {
                let value = try await load(version); try Task.checkCancellation(); guard !closed else { return }
                let fingerprint = versionContext == nil ? nil : value.fingerprint
                if let position, fingerprint != position.fingerprint { throw PetError("历史版本内容已变化，原阅读位置已保留。请重新预览。") }
                focusList = hasKeyboardFocus
                loadedFingerprint = fingerprint; expectedTargetSignature = position?.targetSignature ?? value.targetSignature
                targetChanged = position.map { $0.targetSignature != value.targetSignature } == true
                snapshot = value; choosingVersion = false; scope.stringValue = value.scope; impact.stringValue = value.impact
                scope.toolTip = value.scope; impact.toolTip = value.impact
                let item = position?.itemID.flatMap { id in value.items.firstIndex { $0.identity == id } } ?? 0
                showItem(value.items.indices.contains(item) ? value.items[item] : nil)
                table.reloadData(); if value.items.indices.contains(item) { table.selectRowIndexes(IndexSet(integer: item), byExtendingSelection: false) }
                state.stringValue = targetChanged ? "当前版本已变化，请重新预览后再恢复" : "\(value.items.count) 项"; updatePage()
            } catch { if !closed, !Task.isCancelled { state.stringValue = error.localizedDescription; state.textColor = .systemRed; table.reloadData() } }
        }; updatePage()
    }
    @objc private func showVersions() {
        guard job == nil, !versions.isEmpty else { return }
        pendingPosition = nil; snapshot = nil; loadedFingerprint = nil; expectedTargetSignature = nil; targetChanged = false; choosingVersion = true
        state.stringValue = ""; showItem(nil); table.reloadData()
        if let selectedVersion { table.selectRowIndexes(IndexSet(integer: selectedVersion), byExtendingSelection: false) }
        scrollList(to: versionY); updatePage(); onWorkspaceChange?()
    }
    @objc private func openVersion() { if choosingVersion { readPreview() } }
    @objc private func applyPreview() {
        guard job == nil, let value = snapshot, !closed, !targetChanged else { return }
        state.stringValue = "正在" + apply.title + "…"; state.textColor = AgentWorkbenchTheme.secondaryText
        job = Task { @MainActor [weak self] in
            guard let self else { return }; defer { job = nil; if !closed { updatePage() } }
            do {
                let result = try await value.apply(); complete(result)
            } catch { if !closed, !Task.isCancelled { snapshot = nil; showItem(nil); table.reloadData(); state.stringValue = error.localizedDescription; state.textColor = .systemRed } }
        }; updatePage()
    }
    private func complete(_ result: String) { closed = true; super.close(); onClose?(); onClose = nil; onApplied(result) }
    @objc private func cancelReview() { close() }
    override func canLeaveSettings() -> Bool { if hasPendingOperation { state.stringValue = "请等待当前知识操作完成"; return false }; return true }
    override func close() { if canLeaveSettings() { finishClose(); super.close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeaveSettings() }
    func windowWillClose(_ notification: Notification) { finishClose() }
    override func settingsWillLeave() { finishClose() }
    private func finishClose() { guard !closed else { return }; closed = true; job?.cancel(); onClose?(); onClose = nil }
    @objc private func positionChanged() { if versionContext != nil, !restoringPosition, job == nil, !closed { onWorkspaceChange?() } }
    func captureVersionPosition() throws -> AgentKnowledgeVersionPosition? {
        guard let context = versionContext, !closed else { return nil }
        if let pendingPosition { return pendingPosition }
        let item = snapshot.flatMap { $0.items.indices.contains(table.selectedRow) ? $0.items[table.selectedRow] : nil }
        let body = item == nil || showingDiff ? nil : try AgentTextViewport(text)
        let value = AgentKnowledgeVersionPosition(context: context, versionID: selectedVersion.map { versions[$0].id },
            inPreview: !choosingVersion && snapshot != nil, itemID: item?.identity,
            versionY: choosingVersion ? max(0, list.contentView.bounds.minY) : versionY,
            itemY: choosingVersion ? 0 : max(0, list.contentView.bounds.minY), body: body, fingerprint: loadedFingerprint,
            targetSignature: expectedTargetSignature, focus: body?.focused == true ? "body" : "list",
            presentation: settingsHostWindow == nil ? "window" : "page")
        guard value.valid else { throw PetError("知识版本阅读位置无效，原记录已保留") }
        return value
    }
    func restoreVersionPosition(_ value: AgentKnowledgeVersionPosition) throws {
        guard value.valid, value.context == versionContext else { throw PetError("知识版本不再属于原项目、分支或语言") }
        if let id = value.versionID {
            guard let row = versions.firstIndex(where: { $0.id == id }) else { throw PetError("原知识版本暂不可用，阅读记录已保留") }
            restoringPosition = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            restoringPosition = false
        }
        pendingPosition = value; versionY = value.versionY
    }
    func presentRecoveredVersion(from owner: AgentSettingsPageController) {
        guard let state = pendingPosition, !started, !recoveryPresentationScheduled else { return }
        recoveryPresentationScheduled = true
        DispatchQueue.main.async { [weak self, weak owner] in
            guard let self, let owner else { return }; recoveryPresentationScheduled = false
            guard !closed, !started, owner.isPageVisible, owner.presentingWindow?.hasBlockingDialog != true else { return }
            if state.presentation == "window" { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
            else if owner.onSettingsPush != nil { owner.presentSettingsChild(self) }
        }
    }
    private func scrollList(to y: Double) {
        let clip = list.contentView, proposed = NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin); list.reflectScrolledClipView(clip)
    }
    private func scheduleRecoveredPosition() {
        guard started, pendingPosition != nil, !positionScheduled, !restoringPosition, job == nil else { return }
        positionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { positionScheduled = false }
            guard isPageVisible, let value = pendingPosition, value.inPreview == !choosingVersion else { return }
            restoringPosition = true; defer { restoringPosition = false }
            presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            scrollList(to: value.inPreview ? value.itemY : value.versionY)
            if let body = value.body, !body.apply(to: text, focus: value.focus == "body") { return }
            if value.focus == "list" { presentingWindow?.makeFirstResponder(table) }
            pendingPosition = nil; onWorkspaceChange?()
        }
    }
    var checkState: [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--knowledge-review-check") else { return [:] }
        return ["phase": choosingVersion ? "versions" : "preview", "busy": hasPendingOperation, "closed": closed, "versionID": selectedVersion.map { versions[$0].id } ?? "", "versionCount": versions.count, "items": snapshot?.items.map { ["title": $0.title, "detail": $0.detail, "textHash": AgentFiles.hash(Data($0.text.utf8)), "isDiff": $0.isDiff] } ?? [], "selectedItem": table.selectedRow, "text": showingDiff ? diff.patch : text.string, "showingDiff": showingDiff && !diff.isHidden, "scope": scope.stringValue, "impact": impact.stringValue, "state": state.stringValue, "applyEnabled": apply.isEnabled, "focusInReview": hasKeyboardFocus, "bodyFocused": presentingWindow?.firstResponder === text || presentingWindow?.firstResponder === diff.text,
                "textY": viewer.contentView.bounds.minY, "listY": list.contentView.bounds.minY, "targetChanged": targetChanged]
    }
    func checkSelectVersion(_ index: Int) async {
        guard AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--knowledge-review-check"), choosingVersion, versions.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); readPreview(); await job?.value
    }
    func checkApply() async { guard AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--knowledge-review-check") else { return }; applyPreview(); await job?.value }
    func checkBeginApply() { if AgentKnowledgePageHost.readbackEnabled { applyPreview() } }
    func checkLoad() async { startIfNeeded(); await job?.value }
    func checkReload() async { guard AgentKnowledgePageHost.readbackEnabled else { return }; readPreview(); await job?.value }
    func checkSelectItem(_ index: Int) { if AgentKnowledgePageHost.readbackEnabled, !choosingVersion, let items = snapshot?.items, items.indices.contains(index) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } }
    func checkFocusBody() { if AgentKnowledgePageHost.readbackEnabled { presentingWindow?.makeFirstResponder(showingDiff ? diff.text : text) } }
    func checkVersions() { if AgentKnowledgePageHost.readbackEnabled { showVersions() } }
}
