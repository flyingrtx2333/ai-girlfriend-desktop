import AppKit

@MainActor private final class AgentTaskSwitcherTable: NSTableView {
    var onOpen: (() -> Void)?, onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode { case 36, 76: onOpen?(); case 53: onCancel?(); default: super.keyDown(with: event) }
    }
}

@MainActor final class AgentTaskSwitcher: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: AgentStore
    private let search = NSSearchField(), table = AgentTaskSwitcherTable(), empty = NSTextField(labelWithString: "没有匹配的任务")
    private let openButton = NSButton(title: "打开", target: nil, action: nil)
    private let onSelect: (String) -> Void, onClose: () -> Void
    private var values: [AgentTaskRecord] = [], initialSelection: String?, chosen: String?
    static func candidates(store: AgentStore, query: String) -> [AgentTaskRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.tasks.filter { task in
            guard !task.archived, store.organization.archiveID(task.workspace, mode: task.organizationMode) == nil else { return false }
            let directory = store.organization.name(task.workspace, mode: task.organizationMode) ?? "无" + task.organizationMode.directoryTitle
            return query.isEmpty || [task.title, directory, task.organizationMode.title, task.workspace ?? ""].joined(separator: "\n").localizedCaseInsensitiveContains(query)
        }
        return matches.sorted {
            let left = $0.activityAt ?? $0.updated, right = $1.activityAt ?? $1.updated
            return left == right ? $0.id < $1.id : left > right
        }
    }
    init(store: AgentStore, selected: String?, onSelect: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.store = store; initialSelection = selected; self.onSelect = onSelect; self.onClose = onClose
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "切换任务"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        search.placeholderString = "查找任务或工作区…"; search.setAccessibilityLabel("筛选任务"); search.delegate = self; search.target = self; search.action = #selector(queryChanged)
        let column = NSTableColumn(identifier: .init("task")); column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 54; table.intercellSpacing = NSSize(width: 0, height: 2); table.style = .plain; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("快速切换任务"); table.target = self; table.doubleAction = #selector(openSelected)
        table.onOpen = { [weak self] in self?.openSelected() }; table.onCancel = { [weak self] in self?.cancel() }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        empty.textColor = AgentWorkbenchTheme.secondaryText; empty.font = .systemFont(ofSize: 13)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        openButton.target = self; openButton.action = #selector(openSelected); openButton.keyEquivalent = "\r"
        let actions = NSStackView(views: [empty, NSView(), cancel, openButton]), content = NSStackView(views: [search, scroll, actions])
        actions.spacing = 8; content.orientation = .vertical; content.alignment = .leading; content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18), content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18), content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), content.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16), search.widthAnchor.constraint(equalTo: content.widthAnchor), scroll.widthAnchor.constraint(equalTo: content.widthAnchor), actions.widthAnchor.constraint(equalTo: content.widthAnchor)])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func begin(in owner: NSWindow) {
        guard let panel = window else { return }
        owner.beginSheet(panel) { [self] response in
            panel.orderOut(nil)
            if response == .OK, let chosen, Self.candidates(store: store, query: "").contains(where: { $0.id == chosen }) { onSelect(chosen) }
            onClose()
        }
        panel.makeFirstResponder(search)
    }
    func refresh() {
        let selected = values.indices.contains(table.selectedRow) ? values[table.selectedRow].id : initialSelection
        initialSelection = nil; values = Self.candidates(store: store, query: search.stringValue); table.reloadData()
        if !values.isEmpty { table.selectRowIndexes(IndexSet(integer: values.firstIndex(where: { $0.id == selected }) ?? 0), byExtendingSelection: false); table.scrollRowToVisible(table.selectedRow) }
        empty.isHidden = !values.isEmpty; openButton.isEnabled = !values.isEmpty
    }
    @objc private func queryChanged() { refresh() }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : selector == #selector(NSResponder.moveUp(_:)) ? -1 : 0
        guard delta != 0 else { return false }
        if !values.isEmpty { table.selectRowIndexes(IndexSet(integer: min(values.count - 1, max(0, table.selectedRow + delta))), byExtendingSelection: false); table.scrollRowToVisible(table.selectedRow) }
        return true
    }
    @objc func cancel() { if let window { window.sheetParent?.endSheet(window, returnCode: .cancel) } }
    @objc private func openSelected() {
        guard values.indices.contains(table.selectedRow), let window else { return }
        let id = values[table.selectedRow].id
        guard Self.candidates(store: store, query: search.stringValue).contains(where: { $0.id == id }) else { refresh(); return }
        chosen = id; window.sheetParent?.endSheet(window, returnCode: .OK)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { values.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard values.indices.contains(row) else { return nil }; let task = values[row], id = NSUserInterfaceItemIdentifier("task-switch-entry")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            let title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 14, weight: .medium); detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText
            for view in [title, detail] { view.lineBreakMode = .byTruncatingTail; view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            cell.identifier = id; cell.textField = title; detail.identifier = .init("detail")
            NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8), detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.trailingAnchor.constraint(equalTo: title.trailingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)])
        }
        cell.textField?.stringValue = task.title
        let directory = store.organization.name(task.workspace, mode: task.organizationMode) ?? "无" + task.organizationMode.directoryTitle
        (cell.subviews.first { $0.identifier?.rawValue == "detail" } as? NSTextField)?.stringValue = task.organizationMode.title + " · " + directory + " · " + task.status.title
        return cell
    }
    func checkState() -> [String: Any] { ["visible": window?.isVisible == true, "query": search.stringValue, "tasks": values.map(\.id), "selected": values.indices.contains(table.selectedRow) ? values[table.selectedRow].id : ""] }
}
