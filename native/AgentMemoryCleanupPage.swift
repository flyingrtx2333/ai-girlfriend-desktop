import AppKit

@MainActor final class AgentMemoryCleanupPage: AgentSettingsPageController, NSTableViewDelegate, NSTableViewDataSource {
    private struct Row {
        let title: String
        let workspace: String?
        let preview: AgentMemoryCleanup.Preview?
        let problem: String?
        var canSelect: Bool { preview?.entries.isEmpty == false }
    }

    private let store: AgentStore
    private let projects: [AgentMemoryProjectSource]?
    private let execute: ([AgentMemoryCleanup.Preview]) throws -> AgentMemoryCleanup.Outcome
    private let list = NSTableView(), preview = NSTextView()
    private let selectAll = NSButton(checkboxWithTitle: "全选可清理范围", target: nil, action: nil)
    private let status = AgentSettingsStatusField("记忆清理状态")
    private let move = AgentDialogButton(title: "移至废纸篓", target: nil, action: nil)
    private let recheck = AgentDialogButton(title: "重新检查", target: nil, action: nil)
    private var rows: [Row] = []
    private var selected = Set<Int>()
    private var reviewRequired = false
    private var outcome: AgentMemoryCleanup.Outcome?

    override var minimumSettingsContentHeight: CGFloat { 220 }
    override var usesInternalScrolling: Bool { true }

    init(store: AgentStore, projects: [AgentMemoryProjectSource]?,
         execute: (([AgentMemoryCleanup.Preview]) throws -> AgentMemoryCleanup.Outcome)? = nil) {
        self.store = store; self.projects = projects
        self.execute = execute ?? { try AgentMemoryCleanup.apply($0, store: store) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = projects == nil ? "清空全局记忆" : "清空项目记忆"
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
        let scopes = NSScrollView(); scopes.documentView = list; scopes.hasVerticalScroller = true
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        preview.textContainerInset = NSSize(width: 10, height: 10); preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.setAccessibilityLabel("记忆清理文件")
        let files = NSScrollView(); files.documentView = preview; files.hasVerticalScroller = true
        let split = NSStackView(views: projects == nil ? [files] : [scopes, files]); split.spacing = 12
        files.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        if projects != nil {
            scopes.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.45).isActive = true
            scopes.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        }

        selectAll.target = self; selectAll.action = #selector(toggleAll); selectAll.allowsMixedState = true
        selectAll.identifier = .init("memory-cleanup-select-all"); selectAll.isHidden = projects == nil
        move.target = self; move.action = #selector(apply); move.hasDestructiveAction = true
        move.identifier = .init("memory-cleanup-trash")
        AgentDialogStyle.action(move, prominent: true)
        recheck.target = self; recheck.action = #selector(reload)
        recheck.identifier = .init("memory-cleanup-recheck")
        AgentDialogStyle.action(recheck)
        let footer = NSStackView(views: [status, NSView(), recheck, move]); footer.spacing = 8; footer.alignment = .centerY
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
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func reload() {
        let scopes = projects?.map { (title: $0.title, workspace: Optional($0.workspace)) } ?? [(AgentMemoryScope.global.title, nil)]
        rows = scopes.map { title, workspace in
            do { return Row(title: title, workspace: workspace, preview: try AgentMemoryCleanup.preview(workspace: workspace, store: store), problem: nil) }
            catch { return Row(title: title, workspace: workspace, preview: nil, problem: error.localizedDescription) }
        }
        outcome = nil; reviewRequired = false
        selected = projects == nil && rows.first?.canSelect == true ? [0] : []
        list.isEnabled = true
        list.reloadData()
        if !rows.isEmpty { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        showFiles()
        refreshAction()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let value = rows[row]
        let location = value.preview?.root ?? value.workspace
        if column?.identifier.rawValue == "check" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
            button.tag = row; button.state = selected.contains(row) ? .on : .off
            button.isEnabled = value.canSelect && outcome == nil && !reviewRequired
            button.toolTip = location; button.setAccessibilityLabel("选择" + value.title)
            button.setAccessibilityIdentifier("memory-cleanup-scope-\(row)")
            return button
        }
        let title = NSTextField(labelWithString: value.title)
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

    func tableViewSelectionDidChange(_ notification: Notification) { showFiles() }

    private func showFiles() {
        guard outcome == nil else { return }
        let index = projects == nil ? 0 : list.selectedRow
        guard rows.indices.contains(index) else { preview.string = ""; return }
        let row = rows[index]
        let names = row.preview?.entries.map(\.path) ?? []
        preview.string = ([row.preview?.root ?? row.workspace].compactMap { $0 } + ["",
            row.problem ?? (names.isEmpty ? "暂无记忆文件" : names.joined(separator: "\n"))]).joined(separator: "\n")
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
        refreshAction()
    }
    @objc private func toggleRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), rows[sender.tag].canSelect, outcome == nil, !reviewRequired else { return }
        if sender.state == .on { selected.insert(sender.tag) } else { selected.remove(sender.tag) }
        list.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        refreshAction()
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
            if projects == nil, count == 0 { status.stringValue = rows.first?.problem ?? "暂无记忆文件" }
        }
    }

    @objc private func apply() {
        guard move.isEnabled else { return }
        move.isEnabled = false
        do {
            let result = try execute(plans)
            outcome = result
            reviewRequired = !result.failures.isEmpty
            status.stringValue = "已移至废纸篓 \(result.moved) 个文件" + (reviewRequired ? " · \(result.failures.count) 个未移动" : "")
            preview.string = result.failures.isEmpty ? "可在访达的废纸篓恢复文件。" : result.failures.joined(separator: "\n\n")
            list.isEnabled = false; list.reloadData()
        } catch {
            reviewRequired = true
            status.stringValue = error.localizedDescription
            status.textColor = AgentDialogStyle.error
            list.reloadData()
        }
        refreshAction()
    }
}
