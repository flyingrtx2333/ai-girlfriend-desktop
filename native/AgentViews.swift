import AppKit

private final class AgentTaskTable: NSTableView {
    var taskMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? taskMenu?(row) : nil
    }
}

@MainActor final class AgentTaskSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onNew: (() -> Void)?
    var onAction: ((String, String) -> Void)?
    private let table = AgentTaskTable(), search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["全部", "需要我", "归档"], trackingMode: .selectOne, target: nil, action: nil)
    private var tasks: [AgentTaskRecord] = [], rows: [AgentTaskRecord] = []
    private var selected: String?, signature = "", updating = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        let create = NSButton(title: "新的任务", target: self, action: #selector(newTask))
        create.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil); create.imagePosition = .imageLeading
        create.isBordered = false; create.alignment = .left; create.font = .systemFont(ofSize: 13, weight: .medium)
        search.placeholderString = "搜索任务"; search.setAccessibilityLabel("搜索任务"); search.delegate = self
        search.controlSize = .small
        filter.selectedSegment = 0; filter.segmentStyle = .roundRect; filter.controlSize = .small
        filter.target = self; filter.action = #selector(applyFilter)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tasks")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 46; table.backgroundColor = .clear; table.style = .plain; table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 3); table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("任务列表")
        table.taskMenu = { [weak self] row in self?.menu(row) }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        let content = NSStackView(views: [create, search, filter, scroll]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for view in [create, search, filter, scroll] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refresh(_ values: [AgentTaskRecord], selected: String?) {
        self.selected = selected
        let next = values.map { "\($0.id)|\($0.title)|\($0.status.rawValue)|\($0.archived)|\($0.pinned)|\($0.summary)" }.joined(separator: "\n")
        if signature != next { signature = next; tasks = values; applyFilter() }
        else { selectCurrent() }
    }
    @objc private func newTask() { onNew?() }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    @objc private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = tasks.filter { task in
            let category = filter.selectedSegment == 2 ? task.archived : !task.archived && (filter.selectedSegment != 1 || task.status == .waiting)
            return category && (query.isEmpty || (task.title + "\n" + task.summary).localizedCaseInsensitiveContains(query))
        }.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.created > b.created }
        updating = true; table.reloadData(); updating = false; selectCurrent()
    }
    private func selectCurrent() {
        updating = true; defer { updating = false }
        if let row = rows.firstIndex(where: { $0.id == selected }) {
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        } else { table.deselectAll(nil) }
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<NSMaxRange(visible) {
                table.view(atColumn: 0, row: row, makeIfNecessary: false)?.layer?.backgroundColor = rows.indices.contains(row) && rows[row].id == selected ? NSColor(white: 0.88, alpha: 1).cgColor : NSColor.clear.cgColor
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, rows.indices.contains(table.selectedRow) else { return }; onSelect?(rows[table.selectedRow].id)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let task = rows[row], identifier = NSUserInterfaceItemIdentifier("task-row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.wantsLayer = true; cell.layer?.cornerRadius = 7; cell.layer?.backgroundColor = task.id == selected ? NSColor(white: 0.88, alpha: 1).cgColor : NSColor.clear.cgColor
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 12, weight: .medium); label.lineBreakMode = .byTruncatingTail
            let state = NSTextField(labelWithString: ""); state.font = .systemFont(ofSize: 10); state.textColor = .secondaryLabelColor; state.tag = 2
            let column = NSStackView(views: [label, state]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 3
            cell.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false; cell.textField = label
            NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), column.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7), column.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.widthAnchor.constraint(equalTo: column.widthAnchor)])
        }
        cell.textField?.stringValue = (task.pinned ? "• " : "") + task.title
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = task.status.title + (task.workspace.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "")
        cell.setAccessibilityLabel(task.title + "，" + task.status.title); return cell
    }
    private func menu(_ row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }; let task = rows[row], menu = NSMenu(); menu.autoenablesItems = false
        for (title, action) in [("重命名", "rename"), (task.pinned ? "取消置顶" : "置顶", "pin"), ("创建分支", "fork"), (task.archived ? "恢复任务" : "归档", "archive")] {
            let item = NSMenuItem(title: title, action: #selector(taskAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, action]
            item.isEnabled = task.status != .running; menu.addItem(item)
        }
        return menu
    }
    @objc private func taskAction(_ sender: NSMenuItem) { if let value = sender.representedObject as? [String], value.count == 2 { onAction?(value[0], value[1]) } }
}

@MainActor final class AgentToolRow: NSView {
    private let button = NSButton(), scroll = NSScrollView(), text = NSTextView()
    private var height: NSLayoutConstraint!, expanded = false, lastDetail = ""
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading; button.target = self; button.action = #selector(toggle)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 9, height: 9); text.drawsBackground = false
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.isHidden = true
        for view in [button, scroll] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        height = heightAnchor.constraint(equalToConstant: 28)
        NSLayoutConstraint.activate([height, button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor), button.topAnchor.constraint(equalTo: topAnchor), button.heightAnchor.constraint(equalToConstant: 28), scroll.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.heightAnchor.constraint(equalToConstant: 170)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(call: AgentToolCall, event: AgentEvent?) {
        let names = ["read_file": "读取", "list_directory": "浏览", "search_files": "搜索文件", "write_file": "写入", "edit_file": "编辑", "run_command": "终端", "web_search": "联网搜索", "fetch_url": "读取网页", "update_plan": "更新计划", "ask_user": "需要你", "finish_task": "核对结果", "read_task_history": "查回历史", "read_memory": "读取记忆", "write_memory": "保存记忆"]
        let state = event?.status ?? "running"
        let symbol = state == "completed" ? "checkmark.circle" : state == "failed" ? "exclamationmark.circle" : state == "waiting" ? "hand.raised" : state == "stopped" ? "stop.circle" : "circle.dotted"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state)
        button.contentTintColor = state == "failed" ? .systemRed : state == "waiting" ? .systemOrange : .secondaryLabelColor
        let detail = AgentRuntime.description(call).replacingOccurrences(of: "\n", with: " ")
        button.title = (expanded ? "⌄ " : "› ") + (names[call.name] ?? call.name) + "  " + String(detail.prefix(85))
        button.cell?.lineBreakMode = .byTruncatingTail
        let content = (event?.detail ?? AgentRuntime.description(call))
        if content != lastDetail { lastDetail = content; text.string = content }
        button.toolTip = detail; button.setAccessibilityLabel(button.title)
    }
    @objc private func toggle() {
        expanded.toggle(); scroll.isHidden = !expanded; height.constant = expanded ? 202 : 28
        if button.title.hasPrefix("› ") { button.title = "⌄ " + button.title.dropFirst(2) }
        else { button.title = "› " + button.title.dropFirst(2) }
    }
}
