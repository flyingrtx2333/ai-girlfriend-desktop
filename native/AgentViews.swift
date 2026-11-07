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
    var onNewInWorkspace: ((String) -> Void)?
    var onAction: ((String, String) -> Void)?
    private enum Row { case group(String, String?), task(AgentTaskRecord, Int) }
    private let table = AgentTaskTable(), search = NSSearchField(), searchButton = AgentWorkbenchButton(), attention = AgentWorkbenchButton()
    private let create = AgentWorkbenchButton(), viewMenu = NSPopUpButton(frame: .zero, pullsDown: true)
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
        let heading = NSTextField(labelWithString: "工作区"); heading.font = .systemFont(ofSize: 12, weight: .medium); heading.textColor = .secondaryLabelColor
        viewMenu.addItem(withTitle: ""); viewMenu.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "任务视图"); viewMenu.isBordered = false; viewMenu.setAccessibilityLabel("任务视图")
        for (i, title) in ["全部任务", "需要我", "归档"].enumerated() { let item = NSMenuItem(title: title, action: #selector(changeFilter(_:)), keyEquivalent: ""); item.tag = i; item.target = self; viewMenu.menu?.addItem(item) }
        let add = AgentWorkbenchButton(title: "", target: self, action: #selector(newWorkspace)); AgentWorkbenchTheme.toolbar(add, title: "选择工作区", symbol: "folder.badge.plus")
        viewMenu.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [heading, NSView(), viewMenu, add]); header.spacing = 4
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tasks")); table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear; table.style = .plain; table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2); table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("任务列表")
        table.taskMenu = { [weak self] row in self?.menu(row) }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        let rule = AgentWorkbenchTheme.rule(), content = NSStackView(views: [create, attention, searchButton, search, rule, header, scroll])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 3; content.setCustomSpacing(13, after: searchButton); content.setCustomSpacing(7, after: rule); content.setCustomSpacing(0, after: header)
        addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.modifierFlags.intersection([.option, .control, .shift]).isEmpty, event.charactersIgnoringModifiers?.lowercased() == "f" { showSearch(); return true }
        return super.performKeyEquivalent(with: event)
    }
    func refresh(_ values: [AgentTaskRecord], selected: String?) {
        let previous = self.selected; self.selected = selected
        if previous != selected, let path = values.first(where: { $0.id == selected })?.workspace { collapsed.remove(path) }
        let next = values.map { "\($0.id)|\($0.title)|\($0.workspace ?? "")|\($0.status.rawValue)|\($0.archived)|\($0.pinned)|\($0.summary)" }.joined(separator: "\n")
        let waiting = values.filter { !$0.archived && $0.status == .waiting }.count
        attention.title = waiting > 0 ? "需要我  \(waiting)" : "需要我"
        if signature != next || previous != selected { signature = next; tasks = values; applyFilter() } else { selectCurrent() }
    }
    @objc private func newTask() { onNew?() }
    @objc private func newWorkspace() { onNewWorkspace?() }
    @objc private func showSearch() { searchVisible.toggle(); search.isHidden = !searchVisible; if searchVisible { window?.makeFirstResponder(search) } else { search.stringValue = ""; applyFilter() } }
    @objc private func showAttention() { filter = filter == 1 ? 0 : 1; applyFilter() }
    @objc private func changeFilter(_ sender: NSMenuItem) { filter = sender.tag; applyFilter() }
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
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = tasks.filter { task in
            (filter == 2 ? task.archived : !task.archived && (filter != 1 || task.status == .waiting)) && (query.isEmpty || (task.title + "\n" + task.summary).localizedCaseInsensitiveContains(query))
        }.sorted { $0.updated > $1.updated }
        rows = []
        func append(_ task: AgentTaskRecord, depth: Int = 0) {
            rows.append(.task(task, depth))
            guard depth < 3, expandedTasks.contains(task.id) || visible.contains(where: { $0.id == selected && childOwner($0) == task.id }) else { return }
            for child in visible where childOwner(child) == task.id { append(child, depth: depth + 1) }
        }
        let standalone = visible.filter { task in query.isEmpty && filter == 0 ? !visible.contains(where: { $0.id == childOwner(task) }) : true }
        let pinned = standalone.filter(\.pinned)
        if !pinned.isEmpty { rows.append(.group("置顶", nil)); for task in pinned { append(task) } }
        let unpinned = standalone.filter { !$0.pinned }
        let workspaces = Set(unpinned.compactMap(\.workspace)).sorted { a, b in
            let aSelected = visible.contains { $0.id == selected && $0.workspace == a }, bSelected = visible.contains { $0.id == selected && $0.workspace == b }
            return aSelected != bSelected ? aSelected : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        for workspace in workspaces {
            let title = unpinned.first(where: { $0.workspace == workspace && $0.worktreeOrigin != nil })?.workspaceDisplayName ?? URL(fileURLWithPath: workspace).lastPathComponent
            rows.append(.group(title, workspace))
            if !collapsed.contains(workspace) || visible.contains(where: { $0.id == selected && $0.workspace == workspace }) && !query.isEmpty { for task in unpinned where task.workspace == workspace { append(task) } }
        }
        let ungrouped = unpinned.filter { $0.workspace == nil }
        if !ungrouped.isEmpty { rows.append(.group(filter == 2 ? "归档" : "最近任务", nil)); for task in ungrouped { append(task) } }
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
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .group = rows[row] { return false }; return true }
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
            let button = AgentWorkbenchButton(title: title, target: self, action: #selector(toggleGroup(_:))); AgentWorkbenchTheme.sidebarControl(button, group: true, folder: path != nil); button.tag = row; button.isBordered = false; button.alignment = .left
            button.font = .systemFont(ofSize: 15); button.contentTintColor = .labelColor
            button.image = NSImage(systemSymbolName: path == nil ? "clock" : collapsed.contains(path!) ? "chevron.right" : "chevron.down", accessibilityDescription: nil); button.imagePosition = .imageLeading
            button.toolTip = path; return button
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
    @objc private func toggleGroup(_ sender: NSButton) { guard rows.indices.contains(sender.tag), case .group(_, let path) = rows[sender.tag], let path else { return }; if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }; applyFilter() }
    private func menu(_ row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }; let menu = NSMenu(); menu.autoenablesItems = false
        if case .group(_, let path) = rows[row], let path { let item = NSMenuItem(title: "在此新建任务", action: #selector(newInWorkspace(_:)), keyEquivalent: ""); item.target = self; item.representedObject = path; menu.addItem(item); return menu }
        guard case .task(let task, _) = rows[row] else { return nil }
        if tasks.contains(where: { childOwner($0) == task.id }) { let item = NSMenuItem(title: expandedTasks.contains(task.id) ? "收起子任务" : "展开子任务", action: #selector(toggleChildren(_:)), keyEquivalent: ""); item.target = self; item.representedObject = task.id; menu.addItem(item); menu.addItem(.separator()) }
        for (title, action) in [("重命名", "rename"), (task.pinned ? "取消置顶" : "置顶", "pin"), ("创建分支", "fork"), (task.archived ? "恢复任务" : "归档", "archive")] { let item = NSMenuItem(title: title, action: #selector(taskAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, action]; item.isEnabled = task.status != .running; menu.addItem(item) }
        return menu
    }
    @objc private func newInWorkspace(_ sender: NSMenuItem) { if let path = sender.representedObject as? String { onNewInWorkspace?(path) } }
    @objc private func toggleChildren(_ sender: NSMenuItem) { guard let id = sender.representedObject as? String else { return }; if expandedTasks.contains(id) { expandedTasks.remove(id) } else { expandedTasks.insert(id) }; applyFilter() }
    @objc private func taskAction(_ sender: NSMenuItem) { if let value = sender.representedObject as? [String], value.count == 2 { onAction?(value[0], value[1]) } }
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
        let browserNames = ["browser_open": "打开网页", "browser_read": "读取页面", "browser_action": "网页操作", "browser_close": "关闭浏览器", "browser_tabs": "浏览器标签页", "browser_screenshot": "截取页面", "desktop_status": "电脑操作状态", "desktop_windows": "查找窗口", "desktop_connect": "连接指定窗口", "desktop_read": "读取窗口", "desktop_screenshot": "截取窗口", "desktop_action": "窗口操作", "desktop_disconnect": "断开窗口", "load_tools": "启用工具"]
        button.title = (expanded ? "⌄ " : "› ") + (call.displayName ?? names[call.name] ?? browserNames[call.name] ?? call.name) + "  " + String(visibleDetail.prefix(85))
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
