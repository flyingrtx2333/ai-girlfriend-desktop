import AppKit

private final class AgentTaskTable: NSTableView {
    var taskMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? taskMenu?(row) : nil
    }
}

@MainActor private final class AgentTaskCell: NSTableCellView {
    private let selection = NSView()
    override init(frame: NSRect) {
        super.init(frame: frame); selection.wantsLayer = true; selection.layer?.cornerRadius = 6
        addSubview(selection); selection.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([selection.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), selection.trailingAnchor.constraint(equalTo: trailingAnchor), selection.topAnchor.constraint(equalTo: topAnchor, constant: 3), selection.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func select(_ selected: Bool, animated: Bool = true) { AgentWorkbenchTheme.color(selection.layer, selected ? AgentWorkbenchTheme.selection : .clear, animated: animated) }
}

@MainActor final class AgentTaskSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onNew: (() -> Void)?
    var onNewWorkspace: (() -> Void)?
    var onNewInWorkspace: ((String, AgentWorkMode) -> Void)?
    var onAction: ((String, String) -> Void)?
    var onWorkMode: ((AgentWorkMode) -> Void)?
    var onDirectoryAction: ((String, AgentWorkMode, String) -> Void)?
    var onDirectorySort: ((AgentDirectorySort, AgentWorkMode) -> Void)?
    var onTaskView: ((AgentTaskView?, AgentWorkMode) -> Void)?
    var onCustomGroup: ((String?, AgentWorkMode, String) -> Void)?
    var onAssignGroup: ((String, String?, AgentWorkMode) -> Bool)?
    var onReorderGroup: ((String, String?, AgentWorkMode, AgentTaskGrouping) -> Bool)?
    private enum Row { case group(String, String?), task(AgentTaskRecord, Int) }
    private let table = AgentTaskTable(), search = NSSearchField(), searchButton = AgentWorkbenchButton(), attention = AgentWorkbenchButton()
    private let create = AgentWorkbenchButton(), viewMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let workModePicker = NSPopUpButton(), heading = NSTextField(labelWithString: "工作区"), add = AgentWorkbenchButton()
    private let empty = NSTextField(labelWithString: "没有匹配的任务")
    private var dayObservers: [NSObjectProtocol] = []
    private var draggingRows = false
    private var workMode = AgentWorkMode.coding, organization: AgentOrganization?
    private var taskView = AgentTaskView()
    private var viewMenuSignature = ""
    private var effectiveGrouping: AgentTaskGrouping { filter == 1 ? .workspace : taskView.grouping }
    private static let dragType = NSPasteboard.PasteboardType("com.xjs.bluefatfish.task-view")
    private var tasks: [AgentTaskRecord] = [], rows: [Row] = []
    private var selected: String?, signature = "", updating = false, searchVisible = false, filter = 0
    private var collapsed = Set<String>(), expandedTasks = Set<String>()
    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, title, symbol, action) in [(create, "新的任务", "plus.square", #selector(newTask)), (attention, "需要我", "bell", #selector(showAttention)), (searchButton, "搜索", "magnifyingglass", #selector(showSearch))] {
            AgentWorkbenchTheme.sidebarControl(button, shortcut: button === searchButton ? "⌘K" : nil)
            button.title = title; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading
            button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 15); button.contentTintColor = .labelColor; button.target = self; button.action = action
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true; button.setAccessibilityLabel(title)
        }
        create.keyEquivalent = "n"; create.keyEquivalentModifierMask = .command
        searchButton.keyEquivalent = "k"; searchButton.keyEquivalentModifierMask = .command; searchButton.toolTip = "搜索任务 · ⌘K"
        search.placeholderString = "搜索任务"; search.setAccessibilityLabel("搜索任务"); search.delegate = self; search.controlSize = .small; search.isHidden = true
        workModePicker.addItems(withTitles: AgentWorkMode.allCases.map(\.title)); workModePicker.isBordered = false; workModePicker.font = .systemFont(ofSize: 13, weight: .medium); workModePicker.target = self; workModePicker.action = #selector(changeWorkMode); workModePicker.setAccessibilityLabel("工作模式"); workModePicker.heightAnchor.constraint(equalToConstant: 28).isActive = true
        heading.font = .systemFont(ofSize: 12, weight: .medium); heading.textColor = .secondaryLabelColor
        viewMenu.addItem(withTitle: ""); viewMenu.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "任务视图"); viewMenu.isBordered = false; viewMenu.setAccessibilityLabel("任务视图")
        viewMenu.menu?.autoenablesItems = false
        add.target = self; add.action = #selector(newWorkspace); AgentWorkbenchTheme.toolbar(add, title: "添加工作区", symbol: "folder.badge.plus")
        viewMenu.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [heading, NSView(), viewMenu, add]); header.spacing = 4
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tasks")); table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear; table.style = .plain; table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2); table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("任务列表")
        table.taskMenu = { [weak self] row in self?.menu(row) }
        table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor; empty.isHidden = true; empty.setAccessibilityLabel("任务筛选状态")
        let rule = AgentWorkbenchTheme.rule(), content = NSStackView(views: [workModePicker, create, attention, searchButton, search, rule, header, empty, scroll])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 3; content.setCustomSpacing(13, after: searchButton); content.setCustomSpacing(7, after: rule); content.setCustomSpacing(0, after: header)
        addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] { dayObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.applyFilter() } }) }
    }
    deinit { for observer in dayObservers { NotificationCenter.default.removeObserver(observer) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.modifierFlags.intersection([.option, .control, .shift]).isEmpty, event.charactersIgnoringModifiers?.lowercased() == "f" { showSearch(); return true }
        return super.performKeyEquivalent(with: event)
    }
    func refresh(_ values: [AgentTaskRecord], selected: String?, organization: AgentOrganization) {
        self.organization = organization
        let previous = self.selected; self.selected = selected
        workMode = values.first(where: { $0.id == selected })?.organizationMode ?? .coding
        taskView = organization.taskView(workMode)
        workModePicker.selectItem(at: AgentWorkMode.allCases.firstIndex(of: workMode) ?? 0)
        heading.stringValue = workMode.directoryTitle; add.toolTip = "添加" + workMode.directoryTitle; add.setAccessibilityLabel("添加" + workMode.directoryTitle)
        if previous != selected, let path = values.first(where: { $0.id == selected })?.workspace { collapsed.remove(groupKey(path)) }
        let next = values.map { "\($0.id)|\($0.title)|\($0.workspace ?? "")|\($0.organizationMode.rawValue)|\($0.status.rawValue)|\($0.archived)|\($0.pinned)|\($0.summary)|\($0.activityAt ?? $0.updated)" }.joined(separator: "\n") + "\n\(organization.revision)|\(workMode.rawValue)|\(Calendar.current.startOfDay(for: Date()))"
        let waiting = values.filter { !$0.archived && $0.status == .waiting }.count
        attention.title = waiting > 0 ? "需要我  \(waiting)" : "需要我"
        if signature != next || previous != selected { signature = next; tasks = values; applyFilter() } else { selectCurrent() }
    }
    @objc private func newTask() { onNew?() }
    @objc private func newWorkspace() { onNewWorkspace?() }
    @objc private func showSearch() { searchVisible.toggle(); search.isHidden = !searchVisible; if searchVisible { window?.makeFirstResponder(search) } else { search.stringValue = ""; applyFilter() } }
    @objc private func showAttention() { filter = filter == 1 ? 0 : 1; applyFilter() }
    @objc private func changeFilter(_ sender: NSMenuItem) { filter = sender.tag; applyFilter() }
    @objc private func changeWorkMode() {
        guard AgentWorkMode.allCases.indices.contains(workModePicker.indexOfSelectedItem) else { return }
        filter = 0; search.stringValue = ""; searchVisible = false; search.isHidden = true
        onWorkMode?(AgentWorkMode.allCases[workModePicker.indexOfSelectedItem]); workModePicker.selectItem(at: AgentWorkMode.allCases.firstIndex(of: workMode) ?? 0)
    }
    @objc private func changeDirectorySort(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let sort = AgentDirectorySort(rawValue: raw) { onDirectorySort?(sort, workMode) } }
    @objc private func changeGrouping(_ sender: NSMenuItem) { guard let raw = sender.representedObject as? String, let value = AgentTaskGrouping(rawValue: raw) else { return }; var next = taskView; next.grouping = value; onTaskView?(next, workMode) }
    @objc private func changeWorkspaceFilter(_ sender: NSMenuItem) { var next = taskView; next.workspace = sender.representedObject as? String; onTaskView?(next, workMode) }
    @objc private func changeActivityFilter(_ sender: NSMenuItem) { guard let raw = sender.representedObject as? String, let value = AgentTaskActivityWindow(rawValue: raw) else { return }; var next = taskView; next.activity = value; onTaskView?(next, workMode) }
    @objc private func restoreTaskView() { filter = 0; search.stringValue = ""; onTaskView?(nil, workMode) }
    @objc private func customGroupAction(_ sender: NSMenuItem) { guard let values = sender.representedObject as? [String], values.count == 2 else { return }; onCustomGroup?(values[0].isEmpty ? nil : values[0], workMode, values[1]) }
    @objc private func assignGroup(_ sender: NSMenuItem) { guard let values = sender.representedObject as? [String], values.count == 3, let mode = AgentWorkMode(rawValue: values[2]) else { return }; _ = onAssignGroup?(values[0], values[1].isEmpty ? nil : values[1], mode) }
    private func rebuildViewMenu() {
        let next = "\(organization?.revision ?? 0)|\(workMode.rawValue)|\(filter)|" + Set(tasks.filter { $0.organizationMode == workMode }.compactMap(\.workspace)).sorted().joined(separator: "\n")
        guard next != viewMenuSignature else { return }; viewMenuSignature = next
        guard let menu = viewMenu.menu else { return }; while menu.items.count > 1 { menu.removeItem(at: 1) }
        func item(_ title: String, _ action: Selector?, value: Any? = nil, checked: Bool = false, enabled: Bool = true) -> NSMenuItem { let result = NSMenuItem(title: title, action: action, keyEquivalent: ""); result.target = self; result.representedObject = value; result.state = checked ? .on : .off; result.isEnabled = enabled; return result }
        for (i, title) in ["全部任务", "需要我", "归档"].enumerated() { let entry = item(title, #selector(changeFilter(_:)), checked: filter == i); entry.tag = i; menu.addItem(entry) }
        menu.addItem(.separator())
        let grouping = item("分组方式", nil), groups = NSMenu(); groups.autoenablesItems = false
        for value in AgentTaskGrouping.allCases { groups.addItem(item(value == .workspace ? workMode.directoryTitle : value.title, #selector(changeGrouping(_:)), value: value.rawValue, checked: taskView.grouping == value, enabled: filter != 1)) }; grouping.submenu = groups; menu.addItem(grouping)
        let sorting = item("排序", nil), sorts = NSMenu(); sorts.autoenablesItems = false
        for value in AgentDirectorySort.allCases { sorts.addItem(item(value.title, #selector(changeDirectorySort(_:)), value: value.rawValue, checked: organization?.sorting(workMode) == value, enabled: effectiveGrouping != .activity || value == .recent)) }; sorting.submenu = sorts; menu.addItem(sorting)
        let workspace = item(workMode.directoryTitle, nil), paths = NSMenu(); paths.autoenablesItems = false
        paths.addItem(item("全部", #selector(changeWorkspaceFilter(_:)), checked: taskView.workspace == nil, enabled: filter != 1 && taskView.grouping == .workspace))
        paths.addItem(item("无" + workMode.directoryTitle, #selector(changeWorkspaceFilter(_:)), value: "", checked: taskView.workspace == "", enabled: filter != 1 && taskView.grouping == .workspace))
        for entry in organization?.directories(workMode, tasks: tasks) ?? [] { let option = item(entry.title, #selector(changeWorkspaceFilter(_:)), value: entry.path, checked: taskView.workspace == entry.path, enabled: filter != 1 && taskView.grouping == .workspace); option.toolTip = entry.path; paths.addItem(option) }; workspace.submenu = paths; menu.addItem(workspace)
        let activity = item("近期活动", nil), dates = NSMenu(); dates.autoenablesItems = false
        for value in AgentTaskActivityWindow.allCases { dates.addItem(item(value.title, #selector(changeActivityFilter(_:)), value: value.rawValue, checked: taskView.activity == value, enabled: filter != 1)) }; activity.submenu = dates; menu.addItem(activity)
        menu.addItem(item("新建分组…", #selector(customGroupAction(_:)), value: ["", "new"], enabled: filter != 1)); menu.addItem(.separator()); menu.addItem(item("恢复默认视图", #selector(restoreTaskView)))
    }
    private func groupKey(_ path: String) -> String { workMode.rawValue + "\n" + path }
    func organizationSnapshot() -> [String: Any] {
        ["mode": workMode.rawValue, "picker": workModePicker.titleOfSelectedItem ?? "", "heading": heading.stringValue,
         "tasks": rows.compactMap { row -> String? in if case .task(let task, _) = row { return task.id }; return nil },
         "directories": rows.compactMap { row -> String? in if case .group(let name, let path) = row, path != nil { return name }; return nil }, "attention": attention.title, "grouping": taskView.grouping.rawValue, "workspaceFilter": taskView.workspace as Any? ?? NSNull(), "activityFilter": taskView.activity.rawValue, "sort": organization?.sorting(workMode).rawValue ?? "recent"]
    }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.moveDown(_:)), let index = rows.firstIndex(where: { if case .task = $0 { return true }; return false }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); window?.makeFirstResponder(table); return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { searchVisible = false; search.isHidden = true; search.stringValue = ""; applyFilter(); return true }
        return false
    }
    private func childOwner(_ task: AgentTaskRecord) -> String? { task.agent?.ownerID ?? (task.kind == "hook" ? task.parentID : nil) }
    private func applyFilter() {
        guard !draggingRows else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date(), calendar = Calendar.current
        let visible = tasks.filter { task in
            (filter == 1 || task.organizationMode == workMode) && (filter == 2 ? task.archived : !task.archived && (filter != 1 || task.status == .waiting)) && (filter == 1 || taskView.includes(task, now: now, calendar: calendar)) && (query.isEmpty || (task.title + "\n" + task.summary).localizedCaseInsensitiveContains(query))
        }.sorted { effectiveGrouping == .activity ? ($0.activityAt ?? $0.updated) > ($1.activityAt ?? $1.updated) : $0.updated > $1.updated }
        let custom = organization?.customGroups(workMode, tasks: tasks) ?? [], byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var memberships: [String: String] = [:]; for group in custom { for id in group.taskIDs { memberships[id] = group.id } }
        func membership(_ task: AgentTaskRecord) -> String? {
            var current = task, visited = Set<String>()
            while visited.insert(current.id).inserted, visited.count <= 32 { if let group = memberships[current.id] { return group }; guard let owner = childOwner(current), let parent = byID[owner] else { return nil }; current = parent }; return nil
        }
        rows = []
        func append(_ task: AgentTaskRecord, depth: Int = 0) {
            rows.append(.task(task, depth))
            guard depth < 3, expandedTasks.contains(task.id) || visible.contains(where: { $0.id == selected && childOwner($0) == task.id }) else { return }
            for child in visible where childOwner(child) == task.id && (effectiveGrouping != .custom || membership(child) == membership(task)) { append(child, depth: depth + 1) }
        }
        let standalone = visible.filter { task in query.isEmpty && filter == 0 ? !visible.contains(where: { $0.id == childOwner(task) && (effectiveGrouping != .custom || membership($0) == membership(task)) }) : true }
        let pinned = standalone.filter(\.pinned)
        if !pinned.isEmpty { rows.append(.group("置顶", nil)); for task in pinned { append(task) } }
        let unpinned = standalone.filter { !$0.pinned }
        let narrowed = filter != 0 || !query.isEmpty || taskView.activity != .all || taskView.grouping == .workspace && taskView.workspace != nil
        switch effectiveGrouping {
        case .workspace:
            var entries = organization?.directories(workMode, tasks: visible) ?? []
            let known = Set(entries.map(\.path))
            for path in Set(unpinned.compactMap(\.workspace)).sorted() where !known.contains(path) { entries.append(AgentDirectoryEntry(path: path, mode: workMode)) }
            for entry in entries {
                let workspace = entry.path, members = unpinned.filter { $0.workspace == workspace }
                guard !narrowed || !members.isEmpty else { continue }
                let title = entry.name ?? members.first(where: { $0.worktreeOrigin != nil })?.workspaceDisplayName ?? entry.title
                rows.append(.group(title, workspace))
                if !collapsed.contains(groupKey(workspace)) || visible.contains(where: { $0.id == selected && $0.workspace == workspace }) && !query.isEmpty { for task in members { append(task) } }
            }
            let ungrouped = unpinned.filter { $0.workspace == nil }
            if !ungrouped.isEmpty { rows.append(.group(filter == 2 ? "归档" : "最近任务", nil)); for task in ungrouped { append(task) } }
        case .custom:
            for group in custom {
                let members = unpinned.filter { membership($0) == group.id }; guard !narrowed || !members.isEmpty else { continue }
                rows.append(.group(group.name, group.id)); if !collapsed.contains(groupKey(group.id)) || !query.isEmpty { for task in members { append(task) } }
            }
            let ungrouped = unpinned.filter { membership($0) == nil }
            if !ungrouped.isEmpty { rows.append(.group("未分组会话", nil)); for task in ungrouped { append(task) } }
        case .activity:
            let today = calendar.startOfDay(for: now), yesterday = calendar.date(byAdding: .day, value: -1, to: today)!, week = AgentTaskActivityWindow.week.cutoff(now: now, calendar: calendar)!, month = AgentTaskActivityWindow.month.cutoff(now: now, calendar: calendar)!
            let starts = [today, yesterday, week, month]
            for (index, title) in ["今天", "昨天", "最近7天", "最近30天", "更早"].enumerated() {
                let members = unpinned.filter { task in let date = task.activityAt ?? task.updated; return (starts.firstIndex { date >= $0 } ?? 4) == index }
                if !members.isEmpty { rows.append(.group(title, nil)); for task in members { append(task) } }
            }
        }
        heading.stringValue = filter == 1 ? "需要我" : filter == 2 ? "归档" : effectiveGrouping == .workspace ? workMode.directoryTitle : effectiveGrouping == .custom ? "自定义分组" : "最近会话"
        if filter != 1 { if taskView.grouping == .workspace, taskView.workspace != nil { heading.stringValue += " · 已筛选" }; if taskView.activity != .all { heading.stringValue += " · " + taskView.activity.title } }
        heading.toolTip = heading.stringValue; heading.lineBreakMode = .byTruncatingTail; rebuildViewMenu()
        empty.isHidden = rows.contains { if case .task = $0 { return true }; return false }; empty.stringValue = narrowed ? "没有匹配的任务" : "暂无任务"
        attention.state = filter == 1 ? .on : .off
        AgentWorkbenchTheme.color(attention.layer, filter == 1 ? AgentWorkbenchTheme.selection : .clear)
        for item in viewMenu.itemArray where item.action == #selector(changeFilter(_:)) { item.state = item.tag == filter ? .on : .off }
        updating = true; table.reloadData(); updating = false; selectCurrent()
    }
    private func selectCurrent() {
        updating = true; defer { updating = false }
        if let row = rows.firstIndex(where: { if case .task(let task, _) = $0 { return task.id == selected }; return false }) {
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        } else { table.deselectAll(nil) }
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound { for row in visible.location..<min(rows.count, NSMaxRange(visible)) {
            guard case .task(let task, _) = rows[row] else { continue }
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? AgentTaskCell)?.select(task.id == selected)
        } }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .group = rows[row] { return 32 }; return 33 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .group(_, let key) = rows[row] { return key != nil }; return true }
    func tableViewSelectionDidChange(_ notification: Notification) { guard !updating, rows.indices.contains(table.selectedRow), case .task(let task, _) = rows[table.selectedRow] else { return }; onSelect?(task.id) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title, let path):
            if path == nil {
                let view = NSView(), label = NSTextField(labelWithString: title)
                let icon = NSImageView(image: NSImage(systemSymbolName: title == "置顶" ? "pin" : "clock", accessibilityDescription: nil)!)
                label.font = .systemFont(ofSize: 14, weight: .medium); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingTail; icon.contentTintColor = .secondaryLabelColor
                for child in [icon, label] as [NSView] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14), icon.centerYAnchor.constraint(equalTo: view.centerYAnchor), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 46), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
                return view
            }
            let view = NSView(), button = AgentWorkbenchButton(title: "", target: self, action: #selector(toggleGroup(_:))), label = NSTextField(labelWithString: title), icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
            let closed = collapsed.contains(groupKey(path!)); button.image = NSImage(systemSymbolName: closed ? "chevron.right" : "chevron.down", accessibilityDescription: nil); button.tag = row; button.isBordered = false; button.contentTintColor = .secondaryLabelColor; button.setAccessibilityLabel((closed ? "展开 " : "收起 ") + title)
            label.font = .systemFont(ofSize: 15); label.lineBreakMode = .byTruncatingTail; view.toolTip = effectiveGrouping == .custom ? "自定义分组" : path
            for child in [button, icon, label] as [NSView] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4), button.widthAnchor.constraint(equalToConstant: 20), button.heightAnchor.constraint(equalToConstant: 26), button.centerYAnchor.constraint(equalTo: view.centerYAnchor), icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16), icon.centerYAnchor.constraint(equalTo: view.centerYAnchor), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 46), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return view
        case .task(let task, let depth):
            let cell = AgentTaskCell(); cell.select(task.id == selected, animated: false)
            let label = NSTextField(labelWithString: task.title); label.font = .systemFont(ofSize: 15, weight: task.id == selected ? .medium : .regular); label.lineBreakMode = .byTruncatingTail
            let icon = NSImageView(image: NSImage(systemSymbolName: task.status == .completed ? "circle.fill" : task.status == .running ? "circle.dotted" : task.status == .waiting ? "exclamationmark.circle.fill" : task.status == .failed ? "exclamationmark.circle" : task.status == .stopped ? "stop.circle" : "circle", accessibilityDescription: nil)!)
            icon.contentTintColor = task.status == .completed ? AgentWorkbenchTheme.accent : task.status == .waiting ? .systemOrange : task.status == .failed ? .systemRed : .secondaryLabelColor
            let line = NSStackView(views: [icon, label]); line.spacing = 9; cell.addSubview(line); line.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: CGFloat(37 + depth * 12)), line.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -9), line.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: task.status == .completed ? 7 : 12), icon.heightAnchor.constraint(equalToConstant: task.status == .completed ? 7 : 12)])
            cell.toolTip = task.title + " · " + task.statusTitle; cell.setAccessibilityLabel(task.title + "，" + task.statusTitle); return cell
        }
    }
    @objc private func toggleGroup(_ sender: NSButton) { guard rows.indices.contains(sender.tag), case .group(_, let path) = rows[sender.tag], let path else { return }; let key = groupKey(path); if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }; applyFilter() }
    private func menu(_ row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }; let menu = NSMenu(); menu.autoenablesItems = false
        if case .group(_, let path) = rows[row], let path {
            if effectiveGrouping == .custom {
                for (title, action) in [("重命名分组…", "rename"), ("删除分组…", "remove")] { let entry = NSMenuItem(title: title, action: #selector(customGroupAction(_:)), keyEquivalent: ""); entry.target = self; entry.representedObject = [path, action]; menu.addItem(entry) }; return menu
            }
            let item = NSMenuItem(title: "在此新建任务", action: #selector(newInWorkspace(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [path, workMode.rawValue]; menu.addItem(item)
            let pinned = organization?.directories(workMode, tasks: tasks).first(where: { $0.path == path })?.pinned == true
            for (title, action) in [("设置显示名称…", "rename"), (pinned ? "取消置顶" : "置顶" + workMode.directoryTitle, "pin")] {
                let entry = NSMenuItem(title: title, action: #selector(directoryAction(_:)), keyEquivalent: ""); entry.target = self; entry.representedObject = [path, workMode.rawValue, action]; menu.addItem(entry)
            }
            return menu
        }
        guard case .task(let task, _) = rows[row] else { return nil }
        if childOwner(task) == nil {
            let item = NSMenuItem(title: "添加到分组", action: nil, keyEquivalent: ""), groups = NSMenu(); groups.autoenablesItems = false
            let available = organization?.customGroups(task.organizationMode, tasks: tasks) ?? [], selectedGroup = available.first { $0.taskIDs.contains(task.id) }?.id
            for (title, id) in [("未分组", "")] + available.map({ ($0.name, $0.id) }) { let entry = NSMenuItem(title: title, action: #selector(assignGroup(_:)), keyEquivalent: ""); entry.target = self; entry.representedObject = [task.id, id, task.organizationMode.rawValue]; entry.state = (selectedGroup ?? "") == id ? .on : .off; groups.addItem(entry) }
            item.submenu = groups; menu.addItem(item); menu.addItem(.separator())
        }
        if tasks.contains(where: { childOwner($0) == task.id }) { let item = NSMenuItem(title: expandedTasks.contains(task.id) ? "收起子任务" : "展开子任务", action: #selector(toggleChildren(_:)), keyEquivalent: ""); item.target = self; item.representedObject = task.id; menu.addItem(item); menu.addItem(.separator()) }
        for (title, action) in [("重命名", "rename"), (task.pinned ? "取消置顶" : "置顶", "pin"), ("创建分支", "fork"), (task.archived ? "恢复任务" : "归档", "archive")] { let item = NSMenuItem(title: title, action: #selector(taskAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, action]; item.isEnabled = task.status != .running; menu.addItem(item) }
        if task.agent?.ownerID == nil, task.automation == nil, task.kind != "hook", task.kind != "wiki" {
            let item = NSMenuItem(title: task.organizationMode == .coding ? "移至通用" : "移至编程", action: #selector(taskAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, "work-mode"]; item.isEnabled = ![.running, .waiting].contains(task.status); menu.addItem(item)
        }
        return menu
    }
    @objc private func newInWorkspace(_ sender: NSMenuItem) { if let values = sender.representedObject as? [String], values.count == 2, let mode = AgentWorkMode(rawValue: values[1]) { onNewInWorkspace?(values[0], mode) } }
    @objc private func directoryAction(_ sender: NSMenuItem) { if let values = sender.representedObject as? [String], values.count == 3, let mode = AgentWorkMode(rawValue: values[1]) { onDirectoryAction?(values[0], mode, values[2]) } }
    @objc private func toggleChildren(_ sender: NSMenuItem) { guard let id = sender.representedObject as? String else { return }; if expandedTasks.contains(id) { expandedTasks.remove(id) } else { expandedTasks.insert(id) }; applyFilter() }
    @objc private func taskAction(_ sender: NSMenuItem) { if let value = sender.representedObject as? [String], value.count == 2 { onAction?(value[0], value[1]) } }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard filter != 1, effectiveGrouping != .activity, rows.indices.contains(row) else { return nil }
        let kind: String, id: String
        switch rows[row] { case .group(_, let key): guard let key else { return nil }; kind = "group"; id = key
        case .task(let task, _): guard effectiveGrouping == .custom, childOwner(task) == nil else { return nil }; kind = "task"; id = task.id }
        guard let data = try? JSONSerialization.data(withJSONObject: ["kind": kind, "id": id, "mode": workMode.rawValue, "grouping": effectiveGrouping.rawValue]) else { return nil }
        let item = NSPasteboardItem(); item.setData(data, forType: Self.dragType); return item
    }
    private func drop(_ info: NSDraggingInfo, row: Int) -> (kind: String, id: String, target: String?)? {
        guard info.draggingSource as? NSTableView === table, filter != 1, effectiveGrouping != .activity, let data = info.draggingPasteboard.data(forType: Self.dragType), data.count <= 20_000,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String], value["mode"] == workMode.rawValue, value["grouping"] == effectiveGrouping.rawValue, let kind = value["kind"], let id = value["id"] else { return nil }
        if kind == "task" {
            guard effectiveGrouping == .custom, tasks.contains(where: { $0.id == id && $0.organizationMode == workMode && childOwner($0) == nil }), rows.indices.contains(row), case .group(let title, let target) = rows[row], target != nil || title == "未分组会话" else { return nil }; return (kind, id, target)
        }
        guard kind == "group", row >= 0, row <= rows.count else { return nil }
        if row == rows.count { return (kind, id, nil) }
        guard case .group(_, let target) = rows[row], let target, id != target else { return nil }; return (kind, id, target)
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let value = drop(info, row: row) else { return [] }; tableView.setDropRow(row, dropOperation: value.kind == "task" ? .on : .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let value = drop(info, row: row) else { return false }
        return value.kind == "task" ? onAssignGroup?(value.id, value.target, workMode) ?? false : onReorderGroup?(value.id, value.target, workMode, effectiveGrouping) ?? false
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) { draggingRows = true }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { draggingRows = false; applyFilter() }
}

@MainActor final class AgentToolRow: NSView {
    private let button = NSButton(), scroll = NSScrollView(), text = NSTextView()
    private let preview = NSButton(title: "查看截图", target: nil, action: nil)
    private let statusGlyph = NSImageView()
    private var previewWidth: NSLayoutConstraint!, onPreview: (() -> Void)?
    private var height: NSLayoutConstraint!, lastDetail = ""
    private(set) var expanded = false, lastTransitionDuration: TimeInterval = 0
    private var buttonLeading: NSLayoutConstraint!, workbench = false
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.imagePosition = .imageLeading; button.target = self; button.action = #selector(toggle)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 9, height: 9); text.drawsBackground = false
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.isHidden = true
        preview.target = self; preview.action = #selector(openCapture); preview.bezelStyle = .rounded; preview.font = .systemFont(ofSize: 11); preview.isHidden = true
        statusGlyph.isHidden = true; statusGlyph.setAccessibilityElement(false)
        for view in [button, preview, scroll, statusGlyph] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        height = heightAnchor.constraint(equalToConstant: 28); buttonLeading = button.leadingAnchor.constraint(equalTo: leadingAnchor)
        previewWidth = preview.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([height, buttonLeading, button.trailingAnchor.constraint(equalTo: preview.leadingAnchor, constant: -4), button.topAnchor.constraint(equalTo: topAnchor), button.heightAnchor.constraint(equalToConstant: 28), previewWidth, preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.centerYAnchor.constraint(equalTo: button.centerYAnchor), scroll.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.heightAnchor.constraint(equalToConstant: 170), statusGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), statusGlyph.centerYAnchor.constraint(equalTo: button.centerYAnchor), statusGlyph.widthAnchor.constraint(equalToConstant: 16), statusGlyph.heightAnchor.constraint(equalToConstant: 16)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func useWorkbenchStyle() { workbench = true; buttonLeading.constant = 46; button.font = .systemFont(ofSize: 14); statusGlyph.isHidden = false; wantsLayer = true; layer?.masksToBounds = true }
    func update(call: AgentToolCall, event: AgentEvent?) {
        let names = ["read_file": "读取", "list_directory": "浏览", "search_files": "搜索文件", "write_file": "写入", "edit_file": "编辑", "run_command": "终端", "web_search": "联网搜索", "fetch_url": "读取网页", "update_plan": "更新计划", "ask_user": "需要你", "finish_task": "核对结果", "read_task_history": "查回历史", "read_memory": "读取记忆", "write_memory": "保存记忆", "StructuredOutput": "校验结论", "list_agents": "查找 Agent", "delegate_task": "委派任务"]
        let state = event?.status ?? "running"
        let symbol = state == "completed" ? (workbench ? "checkmark.circle.fill" : "checkmark.circle") : state == "failed" ? "exclamationmark.circle" : state == "waiting" ? "hand.raised" : state == "stopped" ? "stop.circle" : "circle.dotted"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state)
        button.contentTintColor = state == "failed" ? .systemRed : state == "waiting" ? .systemOrange : state == "completed" && workbench ? AgentWorkbenchTheme.accent : .secondaryLabelColor
        if workbench { statusGlyph.image = button.image; statusGlyph.contentTintColor = button.contentTintColor; button.image = nil; button.contentTintColor = .labelColor }
        let detail = AgentRuntime.description(call).replacingOccurrences(of: "\n", with: " ")
        let visibleDetail: String
        if workbench, call.name == "delegate_task", call.displayName != nil { visibleDetail = "" }
        else if workbench, ["read_file", "write_file", "edit_file", "list_directory"].contains(call.name), let path = call.object["path"] as? String { visibleDetail = path == "." ? "项目" : URL(fileURLWithPath: path).lastPathComponent }
        else if workbench, call.name == "read_mcp_resource" { visibleDetail = call.object["uri"] as? String ?? "" }
        else if workbench, AgentMCP.tools.contains(call.name) { visibleDetail = call.object["query"] as? String ?? "" }
        else { visibleDetail = AgentMCP.isModelToolName(call.name) ? (call.object["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? detail : detail }
        let browserNames = ["browser_open": "打开网页", "browser_read": "读取页面", "browser_action": "网页操作", "browser_close": "关闭浏览器", "browser_tabs": "浏览器标签页", "browser_screenshot": "截取页面", "desktop_status": "电脑操作状态", "desktop_windows": "查找窗口", "desktop_connect": "连接指定窗口", "desktop_read": "读取窗口", "desktop_screenshot": "截取窗口", "desktop_action": "窗口操作", "desktop_disconnect": "断开窗口", "canvas_create": "生成画布", "canvas_read": "读取画布", "canvas_update": "更新画布", "canvas_edit": "编辑画布", "canvas_restore": "恢复画布版本", "canvas_inspect": "核对画布", "canvas_screenshot": "截取画布", "canvas_list": "任务画布", "load_tools": "启用工具"]
        let knowledgeNames = ["list_knowledge": "知识库目录", "search_knowledge": "检索知识库", "read_knowledge": "读取知识文件", "read_project_knowledge": "读取知识卡片", "edit_project_knowledge": "更新知识卡片", "save_knowledge_card": "保存卡片草稿"]
        button.title = (expanded ? "⌄ " : "› ") + (call.displayName ?? names[call.name] ?? browserNames[call.name] ?? knowledgeNames[call.name] ?? call.name) + "  " + String(visibleDetail.prefix(85))
        button.cell?.lineBreakMode = .byTruncatingTail
        let content = (event?.detail ?? AgentRuntime.description(call))
        if content != lastDetail { lastDetail = content; text.string = content }
        button.toolTip = detail; button.setAccessibilityLabel(button.title)
    }
    func setCapture(_ file: AgentAttachment?, onOpen: @escaping () -> Void) {
        preview.title = "查看截图"
        preview.isHidden = file == nil; previewWidth.constant = file == nil ? 0 : 84; preview.toolTip = file?.name; onPreview = file == nil ? nil : onOpen
    }
    func setSubtask(_ child: AgentTaskRecord, onOpen: @escaping () -> Void) {
        preview.title = "打开子任务"; preview.isHidden = false; previewWidth.constant = 92
        preview.toolTip = child.title + " · " + child.statusTitle; onPreview = onOpen
    }
    @objc private func openCapture() { onPreview?() }
    @objc private func toggle() {
        setExpanded(!expanded)
    }
    func setExpanded(_ value: Bool, animated: Bool = true) {
        guard expanded != value else { return }; expanded = value; scroll.isHidden = !expanded
        lastTransitionDuration = AgentWorkbenchTheme.layout(in: superview, duration: 0.14, animated: workbench && animated) { self.height.constant = self.expanded ? 202 : 28 }
        if button.title.hasPrefix("› ") { button.title = "⌄ " + button.title.dropFirst(2) }
        else { button.title = "› " + button.title.dropFirst(2) }
    }
}
