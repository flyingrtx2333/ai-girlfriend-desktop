import AppKit

struct AgentKnowledgeReviewItem {
    let title: String, detail: String, text: String
    var isDiff = false
}
struct AgentKnowledgeReviewVersion {
    let id: String, title: String, detail: String
}
@MainActor struct AgentKnowledgeReviewSnapshot {
    let scope: String, impact: String, items: [AgentKnowledgeReviewItem]
    let apply: () async throws -> String

    static func wikiItems(_ value: AgentWikiImportPreview) throws -> [AgentKnowledgeReviewItem] {
        try value.metadata.documents.map { document in
            guard let data = value.data[document.file] else { throw PetError("Wiki 预览缺少文档：" + document.file) }
            return AgentKnowledgeReviewItem(title: document.title, detail: document.file, text: try AgentTextFile.decode(data).text)
        }
    }
    static func cardItems(_ value: AgentKnowledgeCardBook) -> [AgentKnowledgeReviewItem] {
        value.cards.map { AgentKnowledgeReviewItem(title: $0.title, detail: $0.kind.title, text: $0.body) }
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
    var hasPendingOperation: Bool { !closed && job != nil }
    private var hasKeyboardFocus: Bool {
        guard let content = pageContentView, let focus = presentingWindow?.firstResponder as? NSView else { return false }
        return focus.isDescendant(of: content)
    }
    var onClose: (() -> Void)?

    init(title: String, action: String, scope: String, versions: [AgentKnowledgeReviewVersion] = [], load: @escaping (Int?) async throws -> AgentKnowledgeReviewSnapshot, onApplied: @escaping (String) -> Void) {
        self.versions = versions; self.load = load; self.onApplied = onApplied; choosingVersion = !versions.isEmpty
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
        body.setContentHuggingPriority(.defaultLow, for: .vertical); updatePage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() { super.settingsDidAppear(); startIfNeeded() }
    func windowDidBecomeKey(_ notification: Notification) { startIfNeeded() }
    private func startIfNeeded() { guard !started else { return }; started = true; if !choosingVersion { readPreview() } }
    private func updatePage() {
        let focused = presentingWindow?.firstResponder as? NSView, keepFocus = hasKeyboardFocus
        NSLayoutConstraint.deactivate(fullList + documentList); NSLayoutConstraint.activate(choosingVersion ? fullList : documentList)
        viewer.isHidden = choosingVersion || showingDiff; diff.isHidden = choosingVersion || !showingDiff; impact.isHidden = choosingVersion; back.isHidden = choosingVersion || versions.isEmpty
        preview.title = choosingVersion ? "预览" : "重新预览"; apply.isHidden = choosingVersion
        let enabled = !hasPendingOperation && !closed
        for button in [back, cancel, preview] { button.isEnabled = enabled }
        preview.isEnabled = enabled && (!choosingVersion || selectedVersion != nil)
        apply.isEnabled = enabled && snapshot != nil; table.isEnabled = enabled
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
        if choosingVersion { selectedVersion = versions.indices.contains(table.selectedRow) ? table.selectedRow : nil; updatePage() }
        else if let items = snapshot?.items, items.indices.contains(table.selectedRow) { showItem(items[table.selectedRow]) }
    }
    private func showItem(_ item: AgentKnowledgeReviewItem?) {
        showingDiff = item?.isDiff == true
        text.string = showingDiff ? "" : item?.text ?? ""; text.scrollToBeginningOfDocument(nil)
        if showingDiff || !diff.patch.isEmpty { diff.show(showingDiff ? item?.text ?? "" : "", oldTitle: "基线", newTitle: "当前提交", accessibilityContext: "Wiki"); diff.text.scrollToBeginningOfDocument(nil) }
        updatePage()
    }
    @objc private func readPreview() {
        guard job == nil, !closed, !choosingVersion || selectedVersion != nil else { return }
        let waitingForVersion = choosingVersion && hasKeyboardFocus
        if waitingForVersion { presentingWindow?.makeFirstResponder(nil) }
        let version = selectedVersion; snapshot = nil; showItem(nil); state.stringValue = "正在读取预览…"; state.textColor = AgentWorkbenchTheme.secondaryText
        job = Task { @MainActor [weak self] in
            guard let self else { return }; var focusList = false
            defer {
                job = nil
                if !closed {
                    let restoreFocus = focusList || waitingForVersion && presentingWindow?.firstResponder === presentingWindow
                    updatePage(); if restoreFocus, isPageVisible { presentingWindow?.makeFirstResponder(table) }
                }
            }
            do {
                let value = try await load(version); try Task.checkCancellation(); guard !closed else { return }
                focusList = hasKeyboardFocus
                snapshot = value; choosingVersion = false; scope.stringValue = value.scope; impact.stringValue = value.impact
                scope.toolTip = value.scope; impact.toolTip = value.impact
                showItem(value.items.first); table.reloadData(); if !value.items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                state.stringValue = "\(value.items.count) 项"; updatePage()
            } catch { if !closed, !Task.isCancelled { state.stringValue = error.localizedDescription; state.textColor = .systemRed; table.reloadData() } }
        }; updatePage()
    }
    @objc private func showVersions() {
        guard job == nil, !versions.isEmpty else { return }; snapshot = nil; choosingVersion = true; state.stringValue = ""; showItem(nil); table.reloadData()
        if let selectedVersion { table.selectRowIndexes(IndexSet(integer: selectedVersion), byExtendingSelection: false) }; updatePage()
    }
    @objc private func openVersion() { if choosingVersion { readPreview() } }
    @objc private func applyPreview() {
        guard job == nil, let value = snapshot, !closed else { return }
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
    var checkState: [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--knowledge-review-check") else { return [:] }
        return ["phase": choosingVersion ? "versions" : "preview", "busy": hasPendingOperation, "closed": closed, "versionID": selectedVersion.map { versions[$0].id } ?? "", "versionCount": versions.count, "items": snapshot?.items.map { ["title": $0.title, "detail": $0.detail, "textHash": AgentFiles.hash(Data($0.text.utf8)), "isDiff": $0.isDiff] } ?? [], "selectedItem": table.selectedRow, "text": showingDiff ? diff.patch : text.string, "showingDiff": showingDiff && !diff.isHidden, "scope": scope.stringValue, "impact": impact.stringValue, "state": state.stringValue, "applyEnabled": apply.isEnabled, "focusInReview": hasKeyboardFocus, "bodyFocused": presentingWindow?.firstResponder === text || presentingWindow?.firstResponder === diff.text]
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
