import AppKit
import UniformTypeIdentifiers

@MainActor private final class AgentImportCategoryRow: NSStackView {
    let choice = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    let inspect = AgentWorkbenchButton(title: "", target: nil, action: nil)

    init(_ category: AgentImportCategory, index: Int, target: AnyObject, toggle: Selector, open: Selector) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: category.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.textColor = AgentWorkbenchTheme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        choice.tag = index; choice.target = target; choice.action = toggle; choice.allowsMixedState = true
        choice.setAccessibilityLabel("选择" + category.title)
        choice.setAccessibilityIdentifier("import-select-" + category.rawValue)
        inspect.tag = index; inspect.target = target; inspect.action = open
        inspect.isBordered = false
        inspect.focusRingType = .exterior
        inspect.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        inspect.imagePosition = .imageOnly
        inspect.contentTintColor = AgentWorkbenchTheme.secondaryText
        inspect.toolTip = "查看" + category.title
        inspect.widthAnchor.constraint(equalToConstant: 32).isActive = true
        inspect.heightAnchor.constraint(equalToConstant: 28).isActive = true
        inspect.setAccessibilityLabel("查看" + category.title)
        inspect.setAccessibilityIdentifier("import-category-" + category.rawValue)
        [choice, title, NSView(), status, inspect].forEach(addArrangedSubview)
        spacing = 10; alignment = .centerY
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class AgentDataImportView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: AgentStore, service: AgentDataImport
    private let sources = NSSegmentedControl(labels: AgentImportSource.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let detectAll = AgentDialogButton(title: "检测可导入内容", target: nil, action: nil)
    private let folder = AgentDialogButton(title: "", target: nil, action: nil), detect = AgentDialogButton(title: "重新检测", target: nil, action: nil)
    private let back = AgentDialogButton(title: "返回导入", target: nil, action: nil)
    private let overview = NSStackView(), editor = NSStackView()
    private let categoryTitle = NSTextField(labelWithString: "")
    private let destination = NSPopUpButton()
    private lazy var destinationControl = AgentSettingsPopupFrame(destination)
    private let table = NSTableView(), detail = NSTextView(), state = NSTextField(labelWithString: ""), selectAll = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    private let begin = AgentDialogButton(title: "导入所选数据", target: nil, action: nil)
    private let pause = NSButton(title: "暂停", target: nil, action: nil), resume = NSButton(title: "继续导入", target: nil, action: nil), cancel = NSButton(title: "取消导入", target: nil, action: nil)
    private let open = NSButton(title: "打开任务", target: nil, action: nil), original = NSButton(title: "来源副本", target: nil, action: nil)
    private struct Selection { let preview: UUID; var ids: Set<String> }
    private var categoryRows: [AgentImportCategory: AgentImportCategoryRow] = [:]
    private var routes: [AgentImportSource: [AgentImportCategory: AgentImportRoute]] = [:]
    private var selections: [AgentImportRoute: Selection] = [:]
    private var editing: AgentImportCategory?, shownRoute: AgentImportRoute?, shownBatch: String?
    private var highlighted: [AgentImportRoute: String] = [:]
    private var rows: [AgentImportCandidate] = [], states: [String: String] = [:]
    private var listHeight: NSLayoutConstraint?
    var onOpen: ((String) -> Void)?
    var onOpenConnector: ((String, String?) throws -> Void)?
    var onOpenAutomation: ((String) throws -> Void)?
    var onOpenPlugin: ((String, String?) throws -> Void)?
    var onOpenConfiguration: ((AgentStandaloneImportPlan, URL) throws -> Void)?
    var onOpenAgent: ((String, String?) throws -> Void)?
    var onOpenHooks: ((URL, String?) throws -> Void)?
    private var selectedSource: AgentImportSource { AgentImportSource.allCases[max(0, sources.selectedSegment)] }
    private var selectedCategory: AgentImportCategory { editing ?? .tasks }
    private var currentRoute: AgentImportRoute { route(selectedCategory) }
    private var canConfigure: Bool { !service.active && !service.scanning && !service.unfinished }
    private var selected: Set<String> { selections[currentRoute]?.ids ?? [] }
    init(store: AgentStore) {
        self.store = store; service = store.dataImport
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        sources.selectedSegment = 0; sources.target = self; sources.action = #selector(changeSource)
        sources.setAccessibilityLabel("导入来源"); sources.setAccessibilityIdentifier("import-sources")
        for index in 0..<sources.segmentCount { sources.setWidth(76, forSegment: index) }
        destination.target = self; destination.action = #selector(changeDestination)
        destination.cell?.lineBreakMode = .byTruncatingMiddle
        destinationControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.target = self; folder.action = #selector(chooseFolder); folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); folder.imagePosition = .imageLeading; folder.setAccessibilityLabel("来源目录"); folder.cell?.lineBreakMode = .byTruncatingMiddle
        folder.alignment = .left
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detect.target = self; detect.action = #selector(detectRecords)
        detectAll.target = self; detectAll.action = #selector(detectSource)
        back.target = self; back.action = #selector(closeCategory); back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil); back.imagePosition = .imageLeading
        for button in [folder, detect, detectAll, back] { AgentDialogStyle.action(button) }
        categoryTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        categoryTitle.lineBreakMode = .byTruncatingTail
        selectAll.target = self; selectAll.action = #selector(toggleAll); selectAll.allowsMixedState = true
        let check = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check")); check.width = 28; check.minWidth = 28; check.maxWidth = 28; table.addTableColumn(check)
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "任务记录"; table.addTableColumn(name)
        table.headerView = nil; table.rowHeight = 48; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("可导入任务")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.drawsBackground = false; list.borderType = .noBorder; table.backgroundColor = .clear
        detail.isEditable = false; detail.isRichText = false; detail.font = .systemFont(ofSize: 12); detail.textContainerInset = NSSize(width: 8, height: 8); detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true; detail.setAccessibilityLabel("导入预览")
        let preview = NSScrollView(); preview.documentView = detail; preview.hasVerticalScroller = true; preview.drawsBackground = false; preview.borderType = .noBorder; detail.drawsBackground = false
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byWordWrapping; state.maximumNumberOfLines = 3
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(begin, #selector(start)), (pause, #selector(pauseImport)), (resume, #selector(resumeImport)), (cancel, #selector(cancelImport)), (open, #selector(openTask)), (original, #selector(showOriginal))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        AgentSettingsStyle.primaryAction(begin)
        let sourcesBar = NSStackView(views: [sources, NSView(), detectAll]); sourcesBar.spacing = 10; sourcesBar.alignment = .centerY
        append(sourcesBar, to: overview)
        for (index, category) in AgentImportCategory.allCases.enumerated() {
            append(AgentSettingsStyle.divider(), to: overview)
            let row = AgentImportCategoryRow(category, index: index, target: self, toggle: #selector(toggleCategory(_:)), open: #selector(openCategory(_:)))
            categoryRows[category] = row
            append(row, to: overview)
        }
        let kinds = NSStackView(views: [back, categoryTitle, NSView(), destinationControl]); kinds.spacing = 10; kinds.alignment = .centerY
        let header = NSStackView(views: [folder, NSView(), detect]); header.spacing = 8; header.alignment = .centerY
        let selection = NSStackView(views: [selectAll, NSView(), open, original]); selection.spacing = 8
        let actions = NSStackView(views: [state, NSView(), begin, pause, resume, cancel]); actions.spacing = 6
        for view in [kinds, header, selection, list, preview] { append(view, to: editor) }
        let column = NSStackView()
        for view in [overview, editor, actions] { append(view, to: column) }
        for stack in [overview, editor, column] { stack.orientation = .vertical; stack.alignment = .leading }
        overview.spacing = 3; overview.setCustomSpacing(10, after: sourcesBar)
        editor.spacing = 10; column.spacing = 12
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        let height = list.heightAnchor.constraint(equalToConstant: 236); listHeight = height
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor), folder.widthAnchor.constraint(greaterThanOrEqualToConstant: 90), height, preview.heightAnchor.constraint(equalToConstant: 142)])
        folder.setContentHuggingPriority(.defaultLow, for: .horizontal); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func append(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    func refresh() {
        let batch = service.batch
        if let batch, shownBatch != batch.id {
            shownBatch = batch.id
            sources.selectedSegment = AgentImportSource.allCases.firstIndex(of: batch.source) ?? 0
            for item in batch.items {
                let route = batch.route(for: item)
                routes[route.source, default: [:]][route.category] = route
            }
        }
        selections = selections.filter { service.preview(for: $0.key)?.id == $0.value.preview }
        let grouped = batch.map { batch in Dictionary(grouping: batch.items) { batch.route(for: $0) } } ?? [:]
        var picked = 0, hasPreview = false
        for category in AgentImportCategory.allCases {
            let route = route(category), preview = service.preview(for: route)
            if let preview, selections[route] == nil { selections[route] = .init(preview: preview.id, ids: preview.available) }
            picked += selections[route]?.ids.count ?? 0
            hasPreview = hasPreview || preview != nil
            updateCategory(route, preview: preview, items: grouped[route] ?? [])
        }
        sources.isEnabled = canConfigure; detectAll.isEnabled = canConfigure
        detectAll.title = hasPreview ? "重新检测全部" : "检测可导入内容"
        overview.isHidden = editing != nil; editor.isHidden = editing == nil
        let preview = editing.flatMap { service.preview(for: route($0)) }
        refreshEditor(preview: preview, items: editing.map { grouped[route($0)] ?? [] } ?? [])
        begin.isHidden = !canConfigure || !hasPreview
        begin.isEnabled = picked > 0
        begin.title = picked > 0 ? "导入 \(picked) 项" : "导入所选数据"
        pause.isHidden = !service.active; pause.isEnabled = batch?.state == "running"
        resume.isHidden = !service.unfinished || service.active; cancel.isHidden = !service.unfinished && !service.active
        if let issue = service.operationIssue ?? preview?.issue { state.stringValue = issue; state.textColor = .systemRed }
        else {
            state.textColor = AgentWorkbenchTheme.secondaryText
            if service.scanning { state.stringValue = "正在检测…" }
            else if let batch, batch.source == selectedSource, service.active || service.unfinished || !hasPreview {
                let done = batch.items.filter { $0.state == "imported" }.count, failed = batch.items.filter { $0.state == "failed" }.count
                state.stringValue = ["running": "导入中", "paused": "已暂停", "cancelled": "已取消", "completed": "已完成"][batch.state, default: batch.state] + " · \(done)/\(batch.items.count)" + (failed > 0 ? " · 失败 \(failed) 项" : "")
            } else if let preview {
                let available = preview.available.count, skipped = preview.records.count - available
                state.stringValue = preview.records.isEmpty ? "此类别无可导入内容" : "\(available) 项可导入" + (skipped > 0 ? " · 跳过 \(skipped) 项" : "")
            } else { state.stringValue = hasPreview ? "" : "尚未检测" }
        }
        state.toolTip = state.stringValue
    }
    private func updateCategory(_ route: AgentImportRoute, preview: AgentImportPreview?, items: [AgentImportItem]) {
        guard let row = categoryRows[route.category] else { return }
        let chosen = selections[route]?.ids.count ?? 0, available = preview?.available.count ?? 0
        row.choice.isEnabled = canConfigure && available > 0
        row.choice.state = chosen == 0 ? .off : chosen == available ? .on : .mixed
        row.status.textColor = AgentWorkbenchTheme.secondaryText
        row.status.toolTip = preview?.issue
        if preview?.issue != nil {
            let unavailable = route.root == defaultRoot(route.category).path && !FileManager.default.fileExists(atPath: route.root)
            row.status.stringValue = unavailable ? "来源不可用" : "检测失败"
            if !unavailable { row.status.textColor = .systemRed }
        }
        else if let preview {
            let skipped = preview.records.count - available
            row.status.stringValue = preview.records.isEmpty ? "无可导入内容" : "\(available) 项可导入" + (skipped > 0 ? " · 跳过 \(skipped) 项" : "")
        } else if !items.isEmpty {
            let imported = items.filter { $0.state == "imported" }.count, failed = items.filter { $0.state == "failed" }.count
            row.status.stringValue = "已导入 \(imported)/\(items.count)" + (failed > 0 ? " · 失败 \(failed) 项" : "")
        } else { row.status.stringValue = "" }
    }
    private func refreshEditor(preview: AgentImportPreview?, items: [AgentImportItem]) {
        if let shownRoute, rows.indices.contains(table.selectedRow) { highlighted[shownRoute] = rows[table.selectedRow].id }
        shownRoute = editing.map { route($0) }
        guard let route = shownRoute else { return }
        let root = route.directory
        rows = preview?.records ?? items.map(\.record)
        states = [:]
        if preview == nil {
            for item in items {
                states[item.id] = item.state == "failed" ? "失败 · " + item.detail : ["pending": "等待导入", "imported": "已导入"][item.state, default: item.state]
            }
        }
        categoryTitle.stringValue = route.source.title + " · " + route.category.title
        let home = store.extensions.sharedHome ?? FileManager.default.homeDirectoryForCurrentUser
        let isDefault = root.path == defaultRoot(route.category).path && root.path.hasPrefix(home.path + "/")
        folder.title = isDefault ? "~/" + String(root.path.dropFirst(home.path.count + 1)) : root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        folder.toolTip = root.path
        folder.isEnabled = canConfigure; detect.isEnabled = canConfigure
        detect.title = preview == nil ? "检测此类" : "重新检测"
        destinationControl.isHidden = route.category.globalTarget == nil
        if let title = route.category.globalTarget { updateDestinations(globalTitle: title) }
        table.setAccessibilityLabel("可导入" + route.category.title)
        let available = preview?.available.count ?? 0
        selectAll.isEnabled = canConfigure && available > 0
        selectAll.state = selected.isEmpty ? .off : selected.count == available ? .on : .mixed
        table.reloadData()
        if let id = highlighted[route], let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        table.enclosingScrollView?.isHidden = rows.isEmpty; selectAll.superview?.isHidden = rows.isEmpty
        listHeight?.constant = CGFloat(min(236, max(48, rows.count * 48)))
        updateDetail()
    }
    private func updateDestinations(globalTitle: String) {
        destination.removeAllItems()
        destination.setAccessibilityLabel(selectedCategory.title + "目标")
        destination.addItem(withTitle: globalTitle)
        for project in AgentMemory.projects(store: store, preferredTaskID: store.selectedID) {
            let item = NSMenuItem(title: "项目 · " + project.title, action: nil, keyEquivalent: "")
            item.representedObject = project.workspace; item.toolTip = project.workspace
            destination.menu?.addItem(item)
        }
        let workspace = currentRoute.workspace
        if let workspace {
            if let item = destination.itemArray.first(where: { $0.representedObject as? String == workspace }) { destination.select(item) }
            else {
                destination.addItem(withTitle: URL(fileURLWithPath: workspace).lastPathComponent + "（不可用）")
                destination.lastItem?.representedObject = workspace
                destination.select(destination.lastItem)
            }
        } else { destination.selectItem(at: 0) }
        destination.toolTip = workspace
        destination.isEnabled = canConfigure; destinationControl.refreshEnabledState()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let value = rows[row]
        if column?.identifier.rawValue == "check" {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRecord(_:))); box.tag = row; box.state = selected.contains(value.id) ? .on : .off; box.isEnabled = selectAll.isEnabled && value.issue == nil; box.setAccessibilityLabel("导入：" + value.title); return box
        }
        let target = value.category.globalTarget.map { title in
            (value.automation?.workspace ?? value.targetWorkspace).map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? title
        }
        let subtitle = value.issue ?? states[value.id] ?? value.configuration?.kind.title ?? target
            ?? (value.archived ? "已归档" : value.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "无工作目录")
        let title = NSTextField(labelWithString: value.title), status = NSTextField(labelWithString: subtitle)
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail; status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText; status.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, status]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; stack.toolTip = value.file; return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }
    private func updateDetail() {
        let root = currentRoute.directory
        switch selectedCategory {
        case .tasks: open.title = "打开任务"
        case .connectors: open.title = "配置连接器"
        case .automations: open.title = "打开自动化"
        case .plugins: open.title = "打开插件"
        case .memory, .skills, .configuration: open.title = "在访达中显示"
        }
        original.title = selectedCategory == .tasks ? "来源副本" : "来源文件"
        let hasSelection = rows.indices.contains(table.selectedRow)
        detail.enclosingScrollView?.isHidden = !hasSelection; open.isHidden = !hasSelection; original.isHidden = !hasSelection
        guard hasSelection else { detail.string = ""; open.isEnabled = false; original.isEnabled = false; return }
        let record = rows[table.selectedRow]
        if let plan = record.memory {
            let names = plan.parts.prefix(8).map(\.name).joined(separator: "、")
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局记忆"
            var lines = [record.title, "来源 · " + record.file, destination]
            if !names.isEmpty { lines.append("目标文件 · " + names + (plan.parts.count > 8 ? " 等\(plan.parts.count)份" : "")) }
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            detail.string = lines.joined(separator: "\n") + "\n\n" + record.preview
            open.isEnabled = states[record.id] == "已导入" || record.issue == "已经导入"
            original.isEnabled = (try? AgentMemoryImport.sourceURL(record, root: root)) != nil
            return
        }
        if let plan = record.skill {
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局 Skills"
            var lines = [record.title, "来源 · " + record.file, destination]
            if plan.fileCount > 0 { lines.append("\(plan.fileCount) 个文件") }
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            detail.string = lines.joined(separator: "\n") + "\n\n" + record.preview
            open.isEnabled = states[record.id] == "已导入" || record.issue == "已经导入"
            original.isEnabled = (try? AgentSkillImport.sourceURL(record, root: root)) != nil
            return
        }
        if let plan = record.connector {
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局连接器"
            var lines = [record.title, "来源 · " + record.file, destination]
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            if record.issue == nil { lines.append(plan.needsSetup ? "待配置 · 导入后需补全" : "导入后可在连接器中启用") }
            lines.append(contentsOf: record.warnings)
            detail.string = lines.joined(separator: "\n") + "\n\n" + record.preview
            open.isEnabled = store.mcp.containsImported(record.targetID, workspace: plan.workspace)
            original.isEnabled = (try? AgentMCPDataImport.reveal(record, root: root)) != nil
            return
        }
        if let plan = record.automation {
            var lines = [record.title, "来源 · " + record.file]
            if let workspace = plan.workspace { lines.append("目标项目 · " + workspace) }
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            if record.issue == nil && states[record.id] == nil { lines.append("导入后为停用状态") }
            lines.append(contentsOf: record.warnings)
            detail.string = lines.joined(separator: "\n") + "\n\n" + record.preview
            open.isEnabled = store.automations.values.contains { $0.id == record.targetID }
            original.isEnabled = (try? AgentAutomationDataImport.reveal(record, root: root)) != nil
            return
        }
        if let plan = record.plugin {
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局插件"
            var lines = [record.title, "来源 · " + record.file, destination]
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            else { lines.append("导入后为停用状态") }
            lines.append(contentsOf: record.warnings)
            detail.string = lines.joined(separator: "\n") + "\n\n" + record.preview
            open.isEnabled = AgentPluginDataImport.installedID(record, store: store) != nil
            original.isEnabled = (try? AgentPluginDataImport.reveal(record, root: root)) != nil
            return
        }
        if let plan = record.configuration {
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局扩展配置"
            var lines = [plan.kind.title + " · " + record.title, "来源 · " + record.file, destination]
            if !plan.destination.isEmpty { lines.append("目标文件 · " + (record.issue == "已共享" ? record.file : plan.destination)) }
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            lines.append(contentsOf: record.warnings)
            detail.string = lines.joined(separator: "\n") + "\n\n" + record.preview
            if plan.kind == .command || (plan.kind == .instruction && plan.directory.isEmpty && record.issue != "已共享") {
                open.title = "打开" + plan.kind.title
            }
            if plan.kind == .agent {
                open.title = "打开智能体"
                open.isEnabled = AgentStandaloneDataImport.installedProfile(record, store: store) != nil
            } else {
                if plan.kind == .hooks { open.title = "打开 Hooks" }
                open.isEnabled = (try? AgentStandaloneDataImport.installedURL(record, store: store)) != nil
            }
            original.isEnabled = (try? AgentStandaloneDataImport.reveal(record, root: root, store: store)) != nil
            return
        }
        detail.string = record.title + "\n" + (record.workspace ?? "无工作目录") + "\n" + record.warnings.joined(separator: "\n") + (record.issue.map { "\n" + $0 } ?? states[record.id].map { "\n" + $0 } ?? "") + "\n\n" + record.preview
        open.isEnabled = store.task(record.targetID) != nil; original.isEnabled = store.task(record.targetID)?.importOrigin != nil
    }
    private func defaultRoot(_ category: AgentImportCategory) -> URL {
        let home = store.extensions.sharedHome ?? FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(selectedSource.homeName)
        switch category {
        case .skills: return AgentSkillImport.defaultDirectory(for: selectedSource, home: home)
        case .plugins: return base.appendingPathComponent("plugins", isDirectory: true)
        default: return base
        }
    }
    private func route(_ category: AgentImportCategory) -> AgentImportRoute {
        routes[selectedSource]?[category] ?? .init(source: selectedSource, category: category, root: defaultRoot(category).path, workspace: nil)
    }
    private func setRoute(_ route: AgentImportRoute) {
        routes[route.source, default: [:]][route.category] = route
        refresh()
    }
    @objc private func changeSource() { refresh() }
    @objc private func openCategory(_ sender: NSButton) {
        editing = AgentImportCategory.allCases[sender.tag]; refresh()
        window?.makeFirstResponder(back)
    }
    @objc private func closeCategory() {
        let category = selectedCategory
        editing = nil; refresh()
        window?.makeFirstResponder(categoryRows[category]?.inspect)
    }
    @objc private func changeDestination() {
        let route = currentRoute
        setRoute(.init(source: route.source, category: route.category, root: route.root, workspace: destination.selectedItem?.representedObject as? String))
    }
    @objc private func chooseFolder() {
        let route = currentRoute, root = route.directory
        let canChooseFile = selectedCategory.acceptsFiles
        let panel = NSOpenPanel(); panel.canChooseFiles = canChooseFile; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        if selectedCategory == .plugins { panel.allowedContentTypes = [.zip] }
        else if canChooseFile { panel.allowedContentTypes = [selectedSource == .qoder ? .json : UTType(filenameExtension: "toml") ?? .data] }
        panel.directoryURL = root.hasDirectoryPath ? root : root.deletingLastPathComponent()
        panel.prompt = canChooseFile ? "选择来源" : "选择来源目录"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            setRoute(.init(source: route.source, category: route.category, root: url.path, workspace: route.workspace))
        }
    }
    @objc private func detectSource() {
        let routes = AgentImportCategory.allCases.map(route)
        Task { await service.detect(routes) }
    }
    @objc private func detectRecords() {
        let route = currentRoute
        Task { await service.detect([route]) }
    }
    @objc private func toggleRecord(_ sender: NSButton) {
        let route = currentRoute
        guard canConfigure, rows.indices.contains(sender.tag), rows[sender.tag].issue == nil, var choice = selections[route] else { return }
        let id = rows[sender.tag].id
        if choice.ids.contains(id) { choice.ids.remove(id) } else { choice.ids.insert(id) }
        selections[route] = choice; refresh()
    }
    @objc private func toggleCategory(_ sender: NSButton) { toggleSelection(route(AgentImportCategory.allCases[sender.tag])) }
    @objc private func toggleAll() { toggleSelection(currentRoute) }
    private func toggleSelection(_ route: AgentImportRoute) {
        guard canConfigure, let preview = service.preview(for: route), var choice = selections[route] else { return }
        choice.ids = choice.ids == preview.available ? [] : preview.available
        selections[route] = choice; refresh()
    }
    @objc private func start() {
        let choices = AgentImportCategory.allCases.map(route).compactMap { route in selections[route].map { (route, $0.ids) } }
        do {
            try service.begin(Dictionary(uniqueKeysWithValues: choices))
            editing = nil; refresh()
        }
        catch { state.stringValue = error.localizedDescription; state.textColor = .systemRed }
    }
    @objc private func pauseImport() { service.pause() }
    @objc private func resumeImport() { service.resume() }
    @objc private func cancelImport() { service.cancel() }
    @objc private func openTask() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let record = rows[table.selectedRow]
        guard record.category != .tasks else { onOpen?(record.targetID); return }
        do {
            if record.connector != nil { try onOpenConnector?(record.targetID, record.targetWorkspace); return }
            if record.automation != nil { try onOpenAutomation?(record.targetID); return }
            if record.plugin != nil {
                guard let id = AgentPluginDataImport.installedID(record, store: store) else { throw PetError("插件已移除或更新") }
                try onOpenPlugin?(id, record.targetWorkspace)
                return
            }
            if let plan = record.configuration {
                if plan.kind == .agent {
                    guard let profile = AgentStandaloneDataImport.installedProfile(record, store: store) else { throw PetError("导入的智能体已移除") }
                    try onOpenAgent?(profile.id, plan.workspace)
                    return
                }
                let url = try AgentStandaloneDataImport.installedURL(record, store: store)
                if plan.kind == .hooks {
                    try onOpenHooks?(url, plan.workspace)
                    return
                }
                if open.title != "在访达中显示", let onOpenConfiguration { try onOpenConfiguration(plan, url) }
                else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                return
            }
            let files = record.category == .skills ? [try AgentSkillImport.destinationURL(record, store: store)] : try AgentMemoryImport.destinationURLs(record, store: store)
            guard !files.isEmpty else { throw PetError("目标记忆文件已移除") }
            NSWorkspace.shared.activateFileViewerSelecting(files)
        } catch { state.stringValue = error.localizedDescription; state.textColor = .systemRed }
    }
    @objc private func showOriginal() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let record = rows[table.selectedRow]
        let root = currentRoute.directory
        do {
            let url: URL
            switch record.category {
            case .tasks: url = try service.sourceURL(record.targetID)
            case .memory: url = try AgentMemoryImport.sourceURL(record, root: root)
            case .skills: url = try AgentSkillImport.sourceURL(record, root: root)
            case .connectors: url = try AgentMCPDataImport.reveal(record, root: root)
            case .automations: url = try AgentAutomationDataImport.reveal(record, root: root)
            case .plugins: url = try AgentPluginDataImport.reveal(record, root: root)
            case .configuration: url = try AgentStandaloneDataImport.reveal(record, root: root, store: store)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { state.stringValue = error.localizedDescription; state.textColor = .systemRed }
    }
}
