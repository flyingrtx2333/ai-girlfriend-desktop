import AppKit

struct AgentArchivedTaskNavigation: Codable, Equatable, Sendable {
    struct Scope: Codable, Hashable, Sendable {
        var path: String?
        var mode: AgentWorkMode?

        init(path: String?, mode: AgentWorkMode?) { self.path = path; self.mode = path == nil ? nil : mode }
        init(_ task: AgentTaskRecord) { self.init(path: task.organizationWorkspace, mode: task.organizationMode) }
        var valid: Bool {
            if let path { return mode != nil && path.hasPrefix("/") && path.utf8.count <= 16_384 && !path.contains("\0") }
            return mode == nil
        }
    }
    struct Cursor: Codable, Equatable, Sendable {
        var selected: String?
        var y = 0.0
        var valid: Bool {
            AgentSettingsRecovery.validScroll(y) &&
                selected.map { !$0.isEmpty && $0.utf8.count <= 16_400 && !$0.contains("\0") } != false
        }
    }
    struct Record: Codable, Equatable, Sendable {
        var version = 1
        let windowID: String
        let state: AgentArchivedTaskNavigation
        var valid: Bool { version == 1 && UUID(uuidString: windowID)?.uuidString == windowID && state.valid }

        static func validateObject(_ raw: Any) throws {
            let data = try AgentSettingsRecovery.object(raw, keys: ["version", "windowID", "state"])
            guard let state = data["state"] else { throw PetError("归档位置无效，原记录已保留") }
            let fields = try AgentSettingsRecovery.object(state, keys: ["tab", "query", "scope", "workspaces", "tasks", "selection"])
            for key in ["workspaces", "tasks"] {
                if let cursor = fields[key] { _ = try AgentSettingsRecovery.object(cursor, keys: ["selected", "y"]) }
            }
            if let scope = fields["scope"], !(scope is NSNull) { _ = try AgentSettingsRecovery.object(scope, keys: ["path", "mode"]) }
            if let selection = fields["selection"], !(selection is NSNull) { _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"]) }
        }
    }

    var tab = 0
    var query = ""
    var scope: Scope?
    var workspaces = Cursor(), tasks = Cursor()
    var selection: AgentTextViewport.Selection?
    var cursor: Cursor {
        get { tab == 0 ? workspaces : tasks }
        set { if tab == 0 { workspaces = newValue } else { tasks = newValue } }
    }
    var valid: Bool {
        (0...1).contains(tab) && query.utf8.count <= 1_000_000 && !query.contains("\0") &&
            scope?.valid != false && workspaces.valid && tasks.valid && selection?.valid(in: query.utf16.count) != false
    }
}

@MainActor final class AgentArchivedTasksView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private typealias Scope = AgentArchivedTaskNavigation.Scope
    private enum Item {
        case workspace(AgentDirectoryEntry, Int), task(AgentTaskRecord)
        var id: String { switch self { case .workspace(let entry, _): return entry.mode.rawValue + "\n" + entry.path; case .task(let task): return task.id } }
        var title: String { switch self { case .workspace(let entry, _): return entry.title; case .task(let task): return task.title } }
        var scope: Scope {
            switch self {
            case .workspace(let entry, _): return Scope(path: entry.path, mode: entry.mode)
            case .task(let task): return Scope(task)
            }
        }
        var mode: AgentWorkMode { switch self { case .workspace(let entry, _): return entry.mode; case .task(let task): return task.organizationMode } }
    }

    private let store: AgentStore
    private let tabs = NSSegmentedControl(labels: ["工作区", "任务"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField(), project = NSPopUpButton(), list = NSScrollView(), table = NSTableView()
    private lazy var projectFrame = AgentSettingsPopupFrame(project)
    private let state = AgentSettingsStatusField("归档状态")
    private let count = NSTextField(labelWithString: "")
    private let restore = AgentDialogButton(title: "恢复", target: nil, action: nil)
    private let remove = AgentDialogButton(title: "永久删除…", target: nil, action: nil)
    private let clear = AgentDialogButton(title: "清空当前列表…", target: nil, action: nil)
    private var rows: [Item] = [], scopeLabels: [Scope: String] = [:], signature = ""
    private var preferredListHeight: NSLayoutConstraint?
    private var navigation = AgentArchivedTaskNavigation()
    private var visited = false, updating = false, waitingForLayout = false
    private var restoredSearchSelection: AgentTextViewport.Selection?
    private var busy = false, operationIssue: String?
    var onWillChange: (() -> Bool)?
    var onChange: (() -> Void)?
    var onNavigationChange: (() -> Void)?
    var onDelete: (([String], [String]) async throws -> String?)? { didSet { updateAction() } }

    init(store: AgentStore) {
        self.store = store
        super.init(frame: .zero)
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab); tabs.setAccessibilityLabel("归档类型")
        tabs.font = .systemFont(ofSize: 13, weight: .medium)
        search.placeholderString = "搜索归档"; search.setAccessibilityLabel("搜索归档"); search.delegate = self
        search.font = .systemFont(ofSize: 13)
        project.target = self; project.action = #selector(changeProject); project.setAccessibilityLabel("筛选归档项目")
        project.cell?.lineBreakMode = .byTruncatingMiddle; project.autoenablesItems = false
        let name = NSTableColumn(identifier: .init("item")); name.minWidth = 80; table.addTableColumn(name)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 48; table.intercellSpacing.height = 2
        table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("归档列表"); table.backgroundColor = .clear
        list.documentView = table; list.hasVerticalScroller = true; list.drawsBackground = false; list.scrollerStyle = .overlay
        list.identifier = .init("settings-catalog-scroll")
        let card = AgentThemeView(fill: AgentWorkbenchTheme.card, stroke: AgentWorkbenchTheme.line)
        card.layer?.cornerRadius = 10; card.layer?.borderWidth = 1
        card.addSubview(list); list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 1), list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -1),
            list.topAnchor.constraint(equalTo: card.topAnchor, constant: 1), list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1)
        ])
        restore.target = self; restore.action = #selector(restoreSelection); AgentSettingsStyle.primaryAction(restore)
        remove.target = self; remove.action = #selector(deleteSelection)
        clear.target = self; clear.action = #selector(deleteVisible)
        for button in [remove, clear] { AgentDialogStyle.action(button); button.hasDestructiveAction = true }
        let filters = NSStackView(views: [search, projectFrame]); filters.spacing = 8; filters.alignment = .centerY
        count.font = .systemFont(ofSize: 12); count.textColor = AgentWorkbenchTheme.secondaryText
        count.setAccessibilityLabel("归档数量")
        let actions = NSStackView(views: [count, NSView(), clear, remove, restore]); actions.spacing = 8; actions.alignment = .centerY
        let flexibleSpace = NSView()
        let column = NSStackView(views: [tabs, filters, card, flexibleSpace, state, actions])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 150), projectFrame.widthAnchor.constraint(lessThanOrEqualToConstant: 228),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 90), flexibleSpace.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        for view in [filters, card, state, actions] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        column.setCustomSpacing(0, after: card)
        let preferredHeight = card.heightAnchor.constraint(equalToConstant: 90)
        preferredHeight.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        preferredHeight.isActive = true; preferredListHeight = preferredHeight
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        card.setContentHuggingPriority(.defaultLow, for: .vertical)
        list.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)), name: NSView.boundsDidChangeNotification, object: list.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private var visible: Bool { window != nil && !isHiddenOrHasHiddenAncestor }
    private var selected: Item? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var canChange: Bool { !busy && !store.deletions.working && store.deletions.issue == nil }

    private func rememberNavigation() {
        guard !updating, !waitingForLayout, visible else { return }
        var current = navigation
        current.cursor = .init(selected: selected?.id, y: max(0, list.contentView.bounds.minY))
        current.selection = restoredSearchSelection ?? searchSelection()
        if current != navigation {
            navigation = current; visited = true; onNavigationChange?()
        }
    }
    private func searchSelection() -> AgentTextViewport.Selection? {
        guard let editor = search.currentEditor() as? NSTextView, editor === window?.firstResponder else { return nil }
        let range = editor.selectedRange(), value = AgentTextViewport.Selection(location: range.location, length: range.length)
        return value.valid(in: search.stringValue.utf16.count) ? value : nil
    }
    @objc private func viewportChanged(_ note: Notification) {
        guard note.object as? NSClipView === list.contentView || note.object as? NSTextView === search.currentEditor() else { return }
        rememberNavigation()
    }
    func captureNavigation() -> AgentArchivedTaskNavigation? {
        guard visited else { return nil }
        var captured = navigation
        if visible, !waitingForLayout {
            captured.cursor = .init(selected: selected?.id, y: max(0, list.contentView.bounds.minY))
            captured.selection = restoredSearchSelection ?? searchSelection()
        }
        return captured.valid ? captured : nil
    }
    func restoreNavigation(_ saved: AgentArchivedTaskNavigation) {
        navigation = saved; visited = true; waitingForLayout = true
        restoredSearchSelection = saved.selection
        tabs.selectedSegment = saved.tab; search.stringValue = saved.query; signature = ""
        if visible { reveal() }
    }
    func reveal(restoreSearch: Bool = true) {
        tabs.selectedSegmentBezelColor = AgentWorkbenchTheme.accent
        refresh()
        guard waitingForLayout || (restoreSearch && restoredSearchSelection != nil) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, visible else { return }
            if waitingForLayout { finishPendingViewport() }
            if restoreSearch { restoreSearchFocus() }
        }
    }
    func restoreSearchFocus() {
        guard visible, let selection = restoredSearchSelection, window?.makeFirstResponder(search) == true,
              let editor = search.currentEditor() as? NSTextView else { return }
        restoredSearchSelection = nil
        editor.setSelectedRange(selection.range)
        rememberNavigation()
    }
    func focusSearch() { window?.makeFirstResponder(search) }
    private func finishPendingViewport() {
        window?.contentView?.layoutSubtreeIfNeeded()
        AgentSettingsRecovery.restoreScroll(navigation.cursor.y, to: list)
        waitingForLayout = false
    }
    @objc private func changeTab() {
        guard navigation.tab != tabs.selectedSegment else { return }
        rememberNavigation(); navigation.tab = tabs.selectedSegment
        navigation.selection = nil; changedFilters()
    }
    @objc private func changeProject() {
        let scope = project.selectedItem?.representedObject as? Scope
        guard navigation.scope != scope else { return }
        navigation.scope = scope
        navigation.tasks = .init(); changedFilters()
    }
    @objc private func chooseProjectOption(_ option: NSMenuItem) {
        project.select(option)
        changeProject()
    }
    func controlTextDidChange(_ obj: Notification) {
        navigation.query = search.stringValue
        navigation.selection = searchSelection()
        navigation.tasks = .init(); navigation.workspaces = .init()
        changedFilters()
    }
    private func changedFilters() {
        visited = true; operationIssue = nil; restoredSearchSelection = nil; signature = ""
        waitingForLayout = true
        refresh(); finishPendingViewport(); onNavigationChange?()
    }

    private func name(_ scope: Scope) -> String {
        guard let path = scope.path, let mode = scope.mode else { return "无工作区" }
        return store.organization.name(path, mode: mode) ?? URL(fileURLWithPath: path).lastPathComponent
    }
    private func updateProjects(_ archived: [AgentTaskRecord]) {
        projectFrame.isHidden = navigation.tab == 0
        var scopes = Set(archived.map(Scope.init))
        if let saved = navigation.scope { scopes.insert(saved) }
        let names = Dictionary(grouping: scopes, by: name)
        scopeLabels.removeAll(keepingCapacity: true)
        for (label, choices) in names {
            for scope in choices {
                guard let path = scope.path, let mode = scope.mode, choices.count > 1 else {
                    scopeLabels[scope] = label; continue
                }
                let disambiguated = label + " · " + mode.title
                let alternatives = choices.filter { $0.mode == mode }
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                let uniqueParent = alternatives.filter { option in
                    option.path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent == parent } == true
                }.count == 1
                scopeLabels[scope] = alternatives.count == 1 ? disambiguated : disambiguated + " · " + (uniqueParent ? parent : path)
            }
        }
        let visible = scopes.sorted {
            let order = (scopeLabels[$0] ?? "").localizedStandardCompare(scopeLabels[$1] ?? "")
            if order != .orderedSame { return order == .orderedAscending }
            return ($0.path ?? "") < ($1.path ?? "")
        }
        project.removeAllItems(); project.addItem(withTitle: "全部项目")
        for scope in visible {
            let option = NSMenuItem(title: scopeLabels[scope] ?? name(scope), action: #selector(chooseProjectOption(_:)), keyEquivalent: "")
            option.target = self; option.representedObject = scope; option.toolTip = scope.path
            project.menu?.addItem(option)
        }
        project.selectItem(at: project.itemArray.firstIndex { $0.representedObject as? Scope == navigation.scope } ?? 0)
    }
    func refresh() {
        let archived = store.tasks.filter(\.archived)
        let next = "\(store.organization.revision)|\(store.deletions.revision)|\(busy)|\(navigation.tab)|\(navigation.query)|\(navigation.scope.debugDescription)|" +
            archived.map { "\($0.id)|\($0.title)|\($0.organizationWorkspace ?? "")|\($0.organizationMode.rawValue)" }.joined(separator: "\n")
        guard next != signature else { updateAction(); return }
        if !waitingForLayout { rememberNavigation() }
        updating = true; defer { updating = false }
        signature = next
        updateProjects(archived)
        let query = navigation.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if navigation.tab == 0 {
            rows = AgentWorkMode.allCases.flatMap { mode in
                store.organization.directories(mode, tasks: store.tasks, includingArchived: true).compactMap { entry in
                    guard entry.archiveID != nil else { return nil }
                    let scope = Scope(path: entry.path, mode: mode)
                    return Item.workspace(entry, archived.lazy.filter { Scope($0) == scope }.count)
                }
            }
        } else {
            rows = archived.filter { navigation.scope == nil || Scope($0) == navigation.scope }.map(Item.task)
        }
        rows = rows.filter { item in
            query.isEmpty || [item.title, name(item.scope), item.scope.path ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        table.reloadData(); table.deselectAll(nil)
        if let selected = navigation.cursor.selected, let row = rows.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let filtered = !query.isEmpty || navigation.tab == 1 && navigation.scope != nil
        AgentSettingsStyle.listState(table, text: filtered ? "没有匹配的归档" : navigation.tab == 0 ? "暂无归档的工作区" : "暂无归档的任务")
        preferredListHeight?.constant = max(90, CGFloat(rows.count) * (table.rowHeight + table.intercellSpacing.height) + 6)
        count.stringValue = rows.isEmpty ? "" : "\(rows.count) 项"
        if let operationIssue { state.stringValue = operationIssue; state.textColor = AgentDialogStyle.error }
        else { state.stringValue = busy ? "正在处理…" : "" }
        updateAction()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateAction(); rememberNavigation() }
    private func updateAction() {
        restore.title = navigation.tab == 0 ? "恢复工作区" : "恢复任务"
        restore.isEnabled = canChange && selected != nil
        remove.isEnabled = canChange && onDelete != nil && selected != nil
        clear.isEnabled = canChange && onDelete != nil && !rows.isEmpty
    }
    @objc private func deleteSelection() { if let selected { delete([selected]) } }
    @objc private func deleteVisible() { delete(rows) }
    private func delete(_ items: [Item]) {
        guard canChange, !items.isEmpty, let action = onDelete, onWillChange?() != false else { return }
        let ids = items.compactMap { item -> String? in if case .task(let task) = item { return task.id }; return nil }
        let archives = items.compactMap { item -> String? in if case .workspace(let entry, _) = item { return entry.archiveID }; return nil }
        busy = true; operationIssue = nil; signature = ""; refresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busy = false; signature = ""; refresh(); onChange?() }
            do { operationIssue = try await action(ids, archives) }
            catch { operationIssue = error.localizedDescription }
        }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let title = NSTextField(labelWithString: item.title)
        let detail = NSTextField(labelWithString: scopeLabels[item.scope] ?? name(item.scope))
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11); detail.textColor = AgentWorkbenchTheme.secondaryText; detail.lineBreakMode = .byTruncatingMiddle
        if case .workspace(_, let count) = item { title.stringValue += " · \(count) 项任务" }
        for label in [title, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        let cell = NSTableCellView(); cell.toolTip = item.scope.path
        cell.setAccessibilityLabel(title.stringValue + "，" + item.mode.title + "，" + detail.stringValue)
        cell.addSubview(labels); labels.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.widthAnchor.constraint(equalTo: labels.widthAnchor), detail.widthAnchor.constraint(equalTo: labels.widthAnchor)])
        return cell
    }
    @objc private func restoreSelection() {
        guard canChange, let item = selected, onWillChange?() != false else { return }
        do {
            switch item {
            case .workspace(let entry, _):
                guard store.organization.archiveID(entry.path, mode: entry.mode) == entry.archiveID else { throw PetError("归档的工作区已变化，请重新选择") }
                try store.setWorkspaceArchived(entry.path, mode: entry.mode, archived: false)
            case .task(let task):
                guard store.task(task.id)?.archived == true else { throw PetError("归档任务已变化，请重新选择") }
                try store.setArchived([task.id], archived: false)
            }
            operationIssue = nil; signature = ""; refresh(); onChange?()
        } catch {
            operationIssue = error.localizedDescription; signature = ""; refresh()
        }
    }
    func checkState() -> [String: Any] {
        guard CommandLine.arguments.contains("--task-archive-check") || CommandLine.arguments.contains("--task-records-check") else { return [:] }
        layoutSubtreeIfNeeded()
        func fits(_ control: NSView) -> Bool { bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: self)) }
        return ["tab": navigation.tab, "query": navigation.query, "project": navigation.scope?.path as Any? ?? NSNull(),
            "projectMode": navigation.scope?.mode?.rawValue as Any? ?? NSNull(),
            "scopes": project.itemArray.map { option in
                let scope = option.representedObject as? Scope
                return ["title": option.title, "path": scope?.path as Any? ?? NSNull(),
                        "mode": scope?.mode?.rawValue as Any? ?? NSNull(), "all": scope == nil]
            },
            "rows": rows.map { ["id": $0.id, "title": $0.title, "path": $0.scope.path as Any? ?? NSNull(), "mode": $0.mode.rawValue] },
            "selected": selected?.id as Any? ?? NSNull(), "state": state.stringValue, "canRestore": restore.isEnabled,
            "canDelete": remove.isEnabled, "canClear": clear.isEnabled, "busy": busy, "visible": visible,
            "scroll": Double(list.contentView.bounds.minY), "tableHeight": Double(list.contentSize.height),
            "controlsFit": fits(search) && fits(tabs) && fits(restore) && fits(remove) && fits(clear)]
    }
}
