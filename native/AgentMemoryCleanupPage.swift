import AppKit

@MainActor final class AgentMemoryCleanupPage: AgentSettingsPageController, NSTableViewDelegate, NSTableViewDataSource {
    private struct Scope: Codable, Equatable {
        let title: String
        let workspace: String?
        var identity: String?
    }
    private struct Row {
        let scope: Scope
        let preview: AgentMemoryCleanup.Preview?
        let fingerprint: String?
        let problem: String?
        var canSelect: Bool { preview?.entries.isEmpty == false }
    }
    private struct Position: Codable {
        let row: Int?, tableY: Double, tableFocused: Bool
        let files: AgentTextViewport?
    }
    private struct Recovery: Codable {
        var version = 1
        let global: Bool, scopes: [Scope], fingerprints: [String?], checked: [Int]
        let position: Position, reviewRequired: Bool, outcome: AgentMemoryCleanup.Outcome?
    }

    private let store: AgentStore
    private let global: Bool
    private var scopes: [Scope]
    private let execute: ([AgentMemoryCleanup.Preview]) throws -> AgentMemoryCleanup.Outcome
    private let list = NSTableView(), preview = NSTextView()
    private let scopesScroll = NSScrollView(), filesScroll = NSScrollView()
    private let selectAll = NSButton(checkboxWithTitle: "全选可清理范围", target: nil, action: nil)
    private let status = AgentSettingsStatusField("记忆清理状态")
    private let move = AgentDialogButton(title: "移至废纸篓", target: nil, action: nil)
    private let recheck = AgentDialogButton(title: "重新检查", target: nil, action: nil)
    private var rows: [Row] = []
    private var selected = Set<Int>()
    private var reviewRequired = false
    private var outcome: AgentMemoryCleanup.Outcome?
    private var pendingPosition: Position?, positionScheduled = false

    override var minimumSettingsContentHeight: CGFloat { 220 }
    override var usesInternalScrolling: Bool { true }

    convenience init(store: AgentStore, projects: [AgentMemoryProjectSource]?,
                     execute: (([AgentMemoryCleanup.Preview]) throws -> AgentMemoryCleanup.Outcome)? = nil) {
        let scopes = projects?.map { Scope(title: $0.title, workspace: $0.workspace) } ?? [Scope(title: AgentMemoryScope.global.title, workspace: nil)]
        self.init(store: store, global: projects == nil, scopes: scopes, execute: execute)
    }

    private init(store: AgentStore, global: Bool, scopes: [Scope], execute: (([AgentMemoryCleanup.Preview]) throws -> AgentMemoryCleanup.Outcome)?) {
        self.store = store; self.global = global; self.scopes = scopes
        self.execute = execute ?? { try AgentMemoryCleanup.apply($0, store: store) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = global ? "清空全局记忆" : "清空项目记忆"
        window.minSize = NSSize(width: 500, height: 360); window.isReleasedWhenClosed = false
        super.init(window: window)
        settingsContext = (window.title, "")
        detailHeading = .init(title: window.title, scope: "")

        let checkbox = NSTableColumn(identifier: .init("check"))
        checkbox.width = 32; checkbox.minWidth = 32; checkbox.maxWidth = 32
        list.addTableColumn(checkbox)
        list.addTableColumn(NSTableColumn(identifier: .init("scope")))
        list.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        list.headerView = nil; list.rowHeight = 46; list.delegate = self; list.dataSource = self
        list.setAccessibilityLabel("记忆清理范围")
        scopesScroll.documentView = list; scopesScroll.hasVerticalScroller = true
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        preview.textContainerInset = NSSize(width: 10, height: 10); preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.setAccessibilityLabel("记忆清理文件")
        filesScroll.documentView = preview; filesScroll.hasVerticalScroller = true
        let split = NSStackView(views: global ? [filesScroll] : [scopesScroll, filesScroll]); split.spacing = 12
        filesScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        if !global {
            scopesScroll.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.45).isActive = true
            scopesScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        }

        selectAll.target = self; selectAll.action = #selector(toggleAll); selectAll.allowsMixedState = true
        selectAll.identifier = .init("memory-cleanup-select-all"); selectAll.isHidden = global
        move.target = self; move.action = #selector(apply); move.hasDestructiveAction = true
        move.identifier = .init("memory-cleanup-trash")
        AgentDialogStyle.action(move, prominent: true)
        recheck.target = self; recheck.action = #selector(reload)
        recheck.identifier = .init("memory-cleanup-recheck")
        AgentDialogStyle.action(recheck)
        let actions = AgentSettingsDetailActions([recheck, move]); detailActionRow = actions
        let footer = NSStackView(views: [status, NSView(), actions]); footer.spacing = 8; footer.alignment = .centerY
        footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        let content = AgentThemeView(), layout = NSStackView(views: [selectAll, split, footer])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 12
        content.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            split.widthAnchor.constraint(equalTo: layout.widthAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            footer.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
        window.contentView = content
        for scroll in [scopesScroll, filesScroll] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSTextView.didChangeSelectionNotification, object: preview)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private static func decode(_ page: AgentSettingsRecovery.Page) throws -> Recovery {
        guard page.kind == "memory-cleanup" else { throw PetError("设置记录不属于记忆清理") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state),
            keys: ["version", "global", "scopes", "fingerprints", "checked", "position", "reviewRequired", "outcome"])
        for scope in raw["scopes"] as? [Any] ?? [] {
            _ = try AgentSettingsRecovery.object(scope, keys: ["title", "workspace", "identity"])
        }
        let position = try AgentSettingsRecovery.object(raw["position"] ?? NSNull(), keys: ["row", "tableY", "tableFocused", "files"])
        if let files = position["files"] { try AgentTextViewport.validateObject(files) }
        if let result = raw["outcome"] { _ = try AgentSettingsRecovery.object(result, keys: ["moved", "failures"]) }
        let value = try JSONDecoder().decode(Recovery.self, from: page.state)
        let paths = value.scopes.compactMap(\.workspace)
        guard value.version == 1, value.global ? value.scopes.count == 1 && paths.isEmpty : paths.count == value.scopes.count,
              Set(paths).count == paths.count, paths.allSatisfy({ $0.hasPrefix("/") && $0 != "/" && !$0.contains("\0") && $0.utf8.count < 8192 }),
              value.scopes.allSatisfy({ AgentSettingsRecovery.validHash($0.identity) }),
              value.fingerprints.count == value.scopes.count, value.fingerprints.allSatisfy({ AgentSettingsRecovery.validHash($0) }),
              Set(value.checked).count == value.checked.count, value.checked.allSatisfy(value.scopes.indices.contains),
              value.position.row.map(value.scopes.indices.contains) != false, AgentSettingsRecovery.validScroll(value.position.tableY),
              value.position.files?.valid != false, (value.outcome?.moved ?? 0) >= 0 else { throw PetError("清理预览位置无效，原记录已保留") }
        return value
    }
    static func reopened(_ page: AgentSettingsRecovery.Page, store: AgentStore) throws -> AgentMemoryCleanupPage {
        let saved = try decode(page)
        return AgentMemoryCleanupPage(store: store, global: saved.global, scopes: saved.scopes, execute: nil)
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        let position = try pendingPosition ?? Position(row: rows.indices.contains(list.selectedRow) ? list.selectedRow : nil,
            tableY: max(0, scopesScroll.contentView.bounds.minY), tableFocused: presentingWindow?.firstResponder === list,
            files: AgentTextViewport(preview))
        return try AgentSettingsRecovery.page("memory-cleanup", Recovery(global: global, scopes: scopes, fingerprints: rows.map(\.fingerprint),
            checked: selected.sorted(), position: position, reviewRequired: reviewRequired, outcome: outcome))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        let saved = try Self.decode(page)
        guard saved.global == global, saved.scopes.map(\.workspace) == scopes.map(\.workspace) else { throw PetError("原清理范围已变化") }
        selected = Set(saved.checked)
        pendingPosition = saved.position
        if let result = saved.outcome { showOutcome(result) }
        else {
            reviewRequired = saved.reviewRequired || saved.fingerprints != rows.map(\.fingerprint)
            if reviewRequired {
                status.stringValue = "记忆文件或范围已变化，请重新检查"
                status.textColor = AgentDialogStyle.error
            }
        }
        showRow(saved.position.row)
        refreshAction(); schedulePosition()
    }
    override func settingsDidAppear() { super.settingsDidAppear(); schedulePosition() }
    override func pageDidLayout() { schedulePosition() }
    @objc private func positionChanged() { if pendingPosition == nil { onSettingsRecoveryChange?() } }
    private func schedulePosition() {
        guard pendingPosition != nil, !positionScheduled else { return }
        positionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { positionScheduled = false }
            guard let position = pendingPosition, isPageVisible, let host = presentingWindow else { return }
            host.contentView?.layoutSubtreeIfNeeded()
            if !global {
                AgentSettingsRecovery.restoreScroll(position.tableY, to: scopesScroll)
                if let row = position.row, !AgentSettingsRecovery.selectionIsVisible(in: list) { list.scrollRowToVisible(row) }
                if position.tableFocused { host.makeFirstResponder(list) }
            }
            if let files = position.files, files.apply(to: preview), files.focused, !files.focusedSelectionIsVisible(in: preview),
               let selection = files.selections.first { preview.scrollRangeToVisible(selection.range) }
            pendingPosition = nil; onSettingsRecoveryChange?()
        }
    }

    private func loadRows() {
        rows = scopes.indices.map { index in
            var scope = scopes[index]
            do {
                let plan = try AgentMemoryCleanup.preview(workspace: scope.workspace, store: store)
                guard scope.identity == nil || scope.identity == plan.directoryIdentity else { throw PetError("原记忆范围已变化") }
                scope.identity = plan.directoryIdentity
                scopes[index] = scope
                return Row(scope: scope, preview: plan, fingerprint: plan.fingerprint, problem: nil)
            } catch {
                return Row(scope: scope, preview: nil, fingerprint: nil, problem: error.localizedDescription)
            }
        }
    }

    @objc private func reload() {
        let previous = list.selectedRow
        pendingPosition = nil; loadRows()
        outcome = nil; reviewRequired = false
        selected = global && rows.first?.canSelect == true ? [0] : []
        list.isEnabled = true
        showRow(rows.isEmpty ? nil : max(0, previous))
        refreshAction(); onSettingsRecoveryChange?()
    }

    private func showRow(_ row: Int?) {
        list.reloadData()
        let indexes = row.map(IndexSet.init(integer:)) ?? []
        list.selectRowIndexes(indexes, byExtendingSelection: false)
        showFiles()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let value = rows[row]
        let location = value.preview?.root ?? value.scope.workspace
        if column?.identifier.rawValue == "check" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
            button.tag = row; button.state = selected.contains(row) ? .on : .off
            button.isEnabled = value.canSelect && outcome == nil && !reviewRequired
            button.toolTip = location; button.setAccessibilityLabel("选择" + value.scope.title)
            button.setAccessibilityIdentifier("memory-cleanup-scope-\(row)")
            return button
        }
        let title = NSTextField(labelWithString: value.scope.title)
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingMiddle
        let count = "\(value.preview?.entries.count ?? 0) 个文件"
        let detail = NSTextField(labelWithString: value.problem ?? (count + (location.map { " · " + ($0 as NSString).abbreviatingWithTildeInPath } ?? "")))
        detail.font = .systemFont(ofSize: 11); detail.textColor = value.problem == nil ? AgentWorkbenchTheme.secondaryText : AgentDialogStyle.warning
        detail.lineBreakMode = .byTruncatingMiddle
        let cell = NSStackView(views: [title, detail])
        cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 3
        cell.toolTip = [location, value.problem].compactMap { $0 }.joined(separator: "\n")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showFiles(); positionChanged() }

    private func showFiles() {
        guard outcome == nil else { return }
        let index = global ? 0 : list.selectedRow
        guard rows.indices.contains(index) else { preview.string = ""; return }
        let row = rows[index]
        let names = row.preview?.entries.map(\.path) ?? []
        let content = ([row.preview?.root ?? row.scope.workspace].compactMap { $0 } + ["",
            row.problem ?? (names.isEmpty ? "暂无记忆文件" : names.joined(separator: "\n"))]).joined(separator: "\n")
        guard content != preview.string else { return }
        preview.string = content
        preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private var eligible: Set<Int> { Set(rows.indices.filter { rows[$0].canSelect }) }
    private var plans: [AgentMemoryCleanup.Preview] { selected.sorted().compactMap { rows[$0].preview } }

    @objc private func toggleAll() {
        guard selectAll.isEnabled else { return }
        let available = eligible
        selected = selected == available ? [] : available
        let focus = list.selectedRow
        list.reloadData()
        if rows.indices.contains(focus) { list.selectRowIndexes(IndexSet(integer: focus), byExtendingSelection: false) }
        refreshAction(); onSettingsRecoveryChange?()
    }
    @objc private func toggleRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), rows[sender.tag].canSelect, outcome == nil, !reviewRequired else { return }
        if sender.state == .on { selected.insert(sender.tag) } else { selected.remove(sender.tag) }
        list.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        refreshAction(); onSettingsRecoveryChange?()
    }

    private func refreshAction() {
        selectAll.state = selected.isEmpty ? .off : selected == eligible ? .on : .mixed
        selectAll.isEnabled = !reviewRequired && outcome == nil && !eligible.isEmpty
        move.isHidden = outcome != nil
        move.isEnabled = !reviewRequired && !selected.isEmpty && outcome == nil
        recheck.isHidden = !reviewRequired
        if !reviewRequired, outcome == nil {
            let count = plans.reduce(0) { $0 + $1.entries.count }
            status.stringValue = count == 0 ? (eligible.isEmpty ? "没有可清理的范围" : "请选择范围") : "\(selected.count) 个范围 · \(count) 个文件 · 可在废纸篓恢复"
            if global, count == 0 { status.stringValue = rows.first?.problem ?? "暂无记忆文件" }
        }
    }

    @objc private func apply() {
        guard move.isEnabled else { return }
        move.isEnabled = false
        do {
            let result = try execute(plans)
            showOutcome(result); list.reloadData()
        } catch {
            reviewRequired = true
            status.stringValue = error.localizedDescription
            status.textColor = AgentDialogStyle.error
            list.reloadData()
        }
        refreshAction(); onSettingsRecoveryChange?()
    }

    private func showOutcome(_ result: AgentMemoryCleanup.Outcome) {
        outcome = result; reviewRequired = !result.failures.isEmpty
        status.stringValue = "已移至废纸篓 \(result.moved) 个文件" + (reviewRequired ? " · \(result.failures.count) 个未移动" : "")
        preview.string = result.failures.isEmpty ? "可在访达的废纸篓恢复文件。" : result.failures.joined(separator: "\n\n")
        list.isEnabled = false
    }
}
