import AppKit

@MainActor final class AgentArchivedTasksView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Item {
        case workspace(AgentDirectoryEntry, Int), task(AgentTaskRecord)
        var id: String { switch self { case .workspace(let entry, _): return entry.mode.rawValue + "\n" + entry.path; case .task(let task): return task.id } }
        var title: String { switch self { case .workspace(let entry, _): return entry.title; case .task(let task): return task.title } }
        var path: String? { switch self { case .workspace(let entry, _): return entry.path; case .task(let task): return task.organizationWorkspace } }
        var mode: AgentWorkMode { switch self { case .workspace(let entry, _): return entry.mode; case .task(let task): return task.organizationMode } }
    }
    private let store: AgentStore, tabs = NSSegmentedControl(labels: ["工作区", "任务"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), project = NSPopUpButton(), table = NSTableView()
    private let state = NSTextField(labelWithString: ""), restore = NSButton(title: "恢复", target: nil, action: nil)
    private let remove = NSButton(title: "永久删除…", target: nil, action: nil), clear = NSButton(title: "清空当前列表…", target: nil, action: nil)
    private var rows: [Item] = [], signature = "", projectPath: String?
    private var busy = false, operationIssue: String?
    var onWillChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onDelete: (([String], [String]) async throws -> String?)? { didSet { updateAction() } }
    init(store: AgentStore) {
        self.store = store; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab); tabs.setAccessibilityLabel("归档类型")
        search.placeholderString = "搜索归档"; search.setAccessibilityLabel("搜索归档"); search.delegate = self
        project.target = self; project.action = #selector(changeProject); project.setAccessibilityLabel("筛选归档项目"); project.cell?.lineBreakMode = .byTruncatingMiddle
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item")); table.addTableColumn(name)
        table.headerView = nil; table.rowHeight = 53; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("归档列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byWordWrapping; state.maximumNumberOfLines = 3; state.setAccessibilityLabel("归档状态")
        restore.target = self; restore.action = #selector(restoreSelection); restore.bezelStyle = .rounded
        remove.target = self; remove.action = #selector(deleteSelection); clear.target = self; clear.action = #selector(deleteVisible)
        for button in [remove, clear] { button.bezelStyle = .rounded; button.hasDestructiveAction = true }
        let filters = NSStackView(views: [search, project]); filters.spacing = 8
        let actions = NSStackView(views: [state, NSView(), clear, remove, restore]); actions.spacing = 8
        let column = NSStackView(views: [tabs, filters, list, actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 12
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor), list.heightAnchor.constraint(equalToConstant: 318), search.widthAnchor.constraint(greaterThanOrEqualToConstant: 160), project.widthAnchor.constraint(lessThanOrEqualToConstant: 210)])
        for view in [filters, list, actions] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        search.setContentHuggingPriority(.defaultLow, for: .horizontal); state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func changeTab() { operationIssue = nil; projectPath = nil; signature = ""; refresh() }
    @objc private func changeProject() { operationIssue = nil; projectPath = project.selectedItem?.representedObject as? String; signature = ""; refresh() }
    func controlTextDidChange(_ obj: Notification) { operationIssue = nil; signature = ""; refresh() }
    func refresh() {
        let next = "\(store.organization.revision)|\(store.deletions.revision)|\(busy)|\(tabs.selectedSegment)|\(search.stringValue)|\(projectPath ?? "")|" + store.tasks.map { "\($0.id)|\($0.title)|\($0.updated)|\($0.archived)" }.joined(separator: "\n")
        guard next != signature else { return }; signature = next
        let selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        project.isHidden = tabs.selectedSegment == 0
        project.removeAllItems(); project.addItem(withTitle: "全部项目")
        var projectPaths = Set(store.tasks.filter(\.archived).compactMap(\.workspace)); if let projectPath { projectPaths.insert(projectPath) }
        let paths = projectPaths.sorted()
        for path in paths { project.addItem(withTitle: URL(fileURLWithPath: path).lastPathComponent); project.lastItem?.representedObject = path; project.lastItem?.toolTip = path }
        project.selectItem(at: project.itemArray.firstIndex { $0.representedObject as? String == projectPath } ?? 0)
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if tabs.selectedSegment == 0 {
            rows = AgentWorkMode.allCases.flatMap { mode in
                store.organization.directories(mode, tasks: store.tasks, includingArchived: true).filter { $0.archiveID != nil }.map { entry in Item.workspace(entry, store.tasks.filter { $0.archived && $0.organizationWorkspace == entry.path && $0.organizationMode == mode }.count) }
            }
        } else { rows = store.tasks.filter { $0.archived && (projectPath == nil || $0.organizationWorkspace == projectPath) }.map(Item.task) }
        rows = rows.filter { query.isEmpty || ($0.title + "\n" + ($0.path ?? "")).localizedCaseInsensitiveContains(query) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        table.reloadData(); table.deselectAll(nil); if let selection, let row = rows.firstIndex(where: { $0.id == selection }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        state.textColor = operationIssue == nil ? AgentWorkbenchTheme.secondaryText : .systemRed; state.stringValue = operationIssue ?? (busy ? "正在删除…" : rows.isEmpty ? "没有匹配的归档" : "\(rows.count) 项"); updateAction()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateAction() }
    private func updateAction() {
        let allowed = !busy && !store.deletions.working && store.deletions.issue == nil
        restore.isEnabled = allowed && rows.indices.contains(table.selectedRow); restore.title = tabs.selectedSegment == 0 ? "恢复工作区" : "恢复任务"
        remove.isEnabled = allowed && onDelete != nil && rows.indices.contains(table.selectedRow); clear.isEnabled = allowed && onDelete != nil && !rows.isEmpty
    }
    @objc private func deleteSelection() { guard rows.indices.contains(table.selectedRow) else { return }; delete([rows[table.selectedRow]]) }
    @objc private func deleteVisible() { delete(rows) }
    private func delete(_ selected: [Item]) {
        guard !busy, !selected.isEmpty, let action = onDelete else { return }
        let ids = selected.compactMap { item -> String? in if case .task(let task) = item { return task.id }; return nil }
        let archives = selected.compactMap { item -> String? in if case .workspace(let entry, _) = item { return entry.archiveID }; return nil }
        busy = true; operationIssue = nil; signature = ""; refresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busy = false; signature = ""; refresh(); onChange?() }
            do { operationIssue = try await action(ids, archives) } catch { operationIssue = error.localizedDescription }
        }
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]
        let title = NSTextField(labelWithString: item.title), detail = NSTextField(labelWithString: item.mode.title + " · " + (item.path ?? "无工作区"))
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail; detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText; detail.lineBreakMode = .byTruncatingMiddle
        if case .workspace(_, let count) = item { title.stringValue += "  ·  \(count) 项任务" }
        let column = NSStackView(views: [title, detail]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 5; column.toolTip = item.path; column.setAccessibilityLabel(title.stringValue + "，" + detail.stringValue); return column
    }
    @objc private func restoreSelection() {
        guard rows.indices.contains(table.selectedRow) else { return }; let item = rows[table.selectedRow]
        do {
            onWillChange?()
            switch item { case .workspace(let entry, _): try store.setWorkspaceArchived(entry.path, mode: entry.mode, archived: false); case .task(let task): try store.setArchived([task.id], archived: false) }
            signature = ""; refresh(); onChange?()
        } catch { state.stringValue = error.localizedDescription; state.textColor = .systemRed }
    }
    func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--task-archive-check") || CommandLine.arguments.contains("--task-records-check") else { return [:] }
        return ["tab": tabs.selectedSegment, "query": search.stringValue, "project": projectPath as Any? ?? NSNull(), "rows": rows.map { ["id": $0.id, "title": $0.title, "path": $0.path as Any? ?? NSNull(), "mode": $0.mode.rawValue] }, "selected": rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id as Any : NSNull(), "state": state.stringValue, "canRestore": restore.isEnabled, "canDelete": remove.isEnabled, "canClear": clear.isEnabled, "busy": busy]
    }
}
