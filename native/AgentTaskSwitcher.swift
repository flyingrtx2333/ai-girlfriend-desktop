import AppKit

@MainActor private final class AgentTaskSwitcherTable: NSTableView {
    var onOpen: (() -> Void)?, onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode { case 36, 76: onOpen?(); case 53: onCancel?(); default: super.keyDown(with: event) }
    }
}

@MainActor final class AgentTaskSwitcher: AgentDialogController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: AgentStore
    private let search = AgentDialogSearchField(frame: .zero), table = AgentTaskSwitcherTable(), empty = NSTextField(labelWithString: "没有匹配的任务")
    private let openButton = AgentDialogButton(title: "打开", target: nil, action: nil)
    private let onSelect: (String) -> Void, onClose: () -> Void
    private var values: [AgentTaskRecord] = [], initialSelection: String?, chosen: String?
    private var waitingStates: [String: AgentTaskWaitingStatus] = [:]
    static func candidates(store: AgentStore, query: String) -> [AgentTaskRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.tasks.filter { task in
            guard !task.archived, store.organization.archiveID(task.organizationWorkspace, mode: task.organizationMode) == nil else { return false }
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
        super.init(title: "切换任务", size: NSSize(width: 560, height: 480))
        let root = view
        let heading = NSTextField(labelWithString: "切换任务"); heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let close = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(close, title: "取消切换任务", symbol: "xmark"); close.target = self; close.action = #selector(cancel)
        let header = NSStackView(views: [heading, NSView(), close]); header.alignment = .centerY
        search.placeholderString = "查找任务或工作区…"; search.setAccessibilityLabel("筛选任务"); search.delegate = self; search.target = self; search.action = #selector(queryChanged)
        search.font = .systemFont(ofSize: 13); search.controlSize = .large; search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let column = NSTableColumn(identifier: .init("task")); column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 54; table.intercellSpacing = NSSize(width: 0, height: 2); table.style = .plain; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("快速切换任务"); table.target = self; table.doubleAction = #selector(openSelected)
        table.onOpen = { [weak self] in self?.openSelected() }; table.onCancel = { [weak self] in self?.cancel() }
        table.backgroundColor = .clear
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        let list = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line); list.layer?.cornerRadius = 6; list.layer?.borderWidth = 1
        list.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -4), scroll.topAnchor.constraint(equalTo: list.topAnchor, constant: 4), scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor, constant: -4)])
        empty.textColor = AgentWorkbenchTheme.secondaryText; empty.font = .systemFont(ofSize: 13)
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        AgentDialogStyle.action(cancel); AgentDialogStyle.action(openButton, prominent: true)
        openButton.target = self; openButton.action = #selector(openSelected); openButton.keyEquivalent = "\r"
        let actions = NSStackView(views: [empty, NSView(), cancel, openButton]), content = NSStackView(views: [header, search, list, actions])
        actions.spacing = 8; content.orientation = .vertical; content.alignment = .leading; content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)])
        for view in [header, search, list, actions] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        list.setContentHuggingPriority(.defaultLow, for: .vertical)
        initialFocus = search; defaultButton = openButton; restoreFocusOnAccept = false; refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func begin(in owner: NSWindow) {
        presentDialog(in: owner) { [self] response in
            if response == .OK, let chosen, Self.candidates(store: store, query: "").contains(where: { $0.id == chosen }) { onSelect(chosen) }
            onClose()
        }
    }
    override func layoutForOwner(_ available: NSSize) { preferredContentSize = NSSize(width: min(560, available.width), height: min(480, available.height)) }
    func refresh() {
        let selected = values.indices.contains(table.selectedRow) ? values[table.selectedRow].id : initialSelection
        initialSelection = nil; values = Self.candidates(store: store, query: search.stringValue)
        waitingStates = store.workbenchWaitingStates(for: values)
        table.reloadData()
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
    @objc private func openSelected() {
        guard values.indices.contains(table.selectedRow) else { return }
        let id = values[table.selectedRow].id
        guard Self.candidates(store: store, query: search.stringValue).contains(where: { $0.id == id }) else { refresh(); return }
        chosen = id; endDialog(.OK)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { values.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard values.indices.contains(row) else { return nil }; let task = values[row], id = NSUserInterfaceItemIdentifier("task-switch-entry")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            let title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 14, weight: .medium); detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText
            for view in [title, detail] { view.lineBreakMode = .byTruncatingTail; view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            cell.identifier = id; cell.textField = title; detail.identifier = .init("detail")
            NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8), detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.trailingAnchor.constraint(equalTo: title.trailingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)])
        }
        cell.textField?.stringValue = task.title
        let directory = store.organization.name(task.workspace, mode: task.organizationMode) ?? "无" + task.organizationMode.directoryTitle
        let state = waitingStates[task.id]?.title ?? task.statusTitle
        (cell.subviews.first { $0.identifier?.rawValue == "detail" } as? NSTextField)?.stringValue = task.organizationMode.title + " · " + directory + " · " + state
        return cell
    }
    func checkState() -> [String: Any] {
        var result = presentationState()
        result.merge(["query": search.stringValue, "tasks": values.map(\.id), "selected": values.indices.contains(table.selectedRow) ? values[table.selectedRow].id : ""]) { _, new in new }
        return result
    }
}
