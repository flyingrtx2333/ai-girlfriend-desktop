import AppKit
import UniformTypeIdentifiers

struct AgentImportNavigation: Codable, Equatable, Sendable {
    struct SourceRoute: Codable, Equatable, Sendable {
        var route: AgentImportRoute
        var checked: [String: String]?
    }
    struct Reading: Codable, Equatable, Sendable {
        var recordID: String?
        var listY: Double
        var text: AgentTextViewport?
    }
    var source: AgentImportSource
    var category: AgentImportCategory?
    var routes: [SourceRoute]
    var reading: Reading?
    var ssh: Bool? = nil

    var valid: Bool {
        func validPath(_ value: String) -> Bool {
            value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 16_384
        }
        func validID(_ value: String, source: AgentImportSource) -> Bool {
            value.hasPrefix(source.rawValue + ":") && !value.contains("\0") && value.utf8.count <= 512
        }
        let keys = routes.map { $0.route.source.rawValue + "/" + $0.route.category.rawValue + ($0.route.sshHost == nil ? "" : "/ssh") }
        return (ssh != true || category.map { AgentSSHImport.categories.contains($0) } != false) && Set(keys).count == routes.count && routes.allSatisfy { item in
            let route = item.route
            let path = route.sshHost.map { AgentSSHImport.categories.contains(route.category) && AgentSSHImport.valid(host: $0, root: route.root) } ?? validPath(route.root)
            return path && route.workspace.map { route.category.globalTarget != nil && validPath($0) } != false &&
                item.checked.map { checked in
                    checked.count <= 5_000 && checked.allSatisfy { validID($0.key, source: item.route.source) && AgentSettingsRecovery.validHash($0.value) }
                } != false
        } && reading.map {
            category != nil && AgentSettingsRecovery.validScroll($0.listY) && $0.recordID.map { validID($0, source: source) } != false &&
                ($0.text == nil || $0.recordID != nil && $0.text?.valid == true)
        } != false
    }

    static func validateObject(_ raw: Any) throws {
        let value = try AgentSettingsRecovery.object(raw, keys: ["source", "category", "routes", "reading", "ssh"])
        for route in value["routes"] as? [Any] ?? [] {
            let item = try AgentSettingsRecovery.object(route, keys: ["route", "checked"])
            if let data = item["route"] { _ = try AgentSettingsRecovery.object(data, keys: ["source", "category", "root", "workspace", "sshHost"]) }
        }
        if let raw = value["reading"], !(raw is NSNull) {
            let reading = try AgentSettingsRecovery.object(raw, keys: ["recordID", "listY", "text"])
            if let text = reading["text"], !(text is NSNull) { try AgentTextViewport.validateObject(text) }
        }
    }

    static func reviewHash(_ record: AgentImportCandidate) -> String? {
        let source = [record.file, record.rawHash, record.sourceHash, record.title, record.preview, record.issue ?? ""]
        let target = [record.targetWorkspace ?? "", record.automation?.workspace ?? "", record.configuration?.destination ?? ""]
        let parts = record.memory?.parts.map { [$0.name, $0.hash] } ?? []
        guard let data = try? JSONEncoder().encode([source, target, record.warnings] + parts) else { return nil }
        return AgentFiles.hash(data)
    }
}

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
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class AgentDataImportView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: AgentStore, service: AgentDataImport
    private let locations = NSSegmentedControl(labels: ["本机", "SSH"], trackingMode: .selectOne, target: nil, action: nil)
    private let sources = NSSegmentedControl(labels: AgentImportSource.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let sshHost = AgentDialogTextField(), sshRoot = AgentDialogTextField(), connection = NSStackView()
    private let detectAll = AgentDialogButton(title: "检测可导入内容", target: nil, action: nil)
    private let folder = AgentDialogButton(title: "", target: nil, action: nil), detect = AgentDialogButton(title: "重新检测", target: nil, action: nil)
    private let back = AgentDialogButton(title: "返回导入", target: nil, action: nil)
    private let overview = NSStackView(), editor = NSStackView()
    private let categoryTitle = NSTextField(labelWithString: "")
    private let destination = NSPopUpButton()
    private lazy var destinationControl = AgentSettingsPopupFrame(destination)
    private let table = NSTableView(), detail = NSTextView(), state = NSTextField(labelWithString: ""), selectAll = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    private let begin = AgentDialogButton(title: "导入所选数据", target: nil, action: nil)
    private let confirmSSH = AgentDialogButton(title: "导入所选数据", target: nil, action: nil)
    private let pause = NSButton(title: "暂停", target: nil, action: nil), resume = NSButton(title: "继续导入", target: nil, action: nil), cancel = NSButton(title: "取消导入", target: nil, action: nil)
    private let open = NSButton(title: "打开任务", target: nil, action: nil), original = NSButton(title: "来源副本", target: nil, action: nil)
    private struct Selection { let preview: UUID; let fingerprints: [String: String]; var ids: Set<String> }
    private var categoryRows: [AgentImportCategory: AgentImportCategoryRow] = [:]
    private var categoryDividers: [AgentImportCategory: NSView] = [:]
    private var routes: [AgentImportSource: [AgentImportCategory: AgentImportRoute]] = [:]
    private var remoteRoutes: [AgentImportSource: [AgentImportCategory: AgentImportRoute]] = [:]
    private var selections: [AgentImportRoute: Selection] = [:]
    private var reviewed: [AgentImportRoute: [String: String]] = [:]
    private var changedChecks: [AgentImportRoute: Int] = [:]
    private var editing: AgentImportCategory?, shownRoute: AgentImportRoute?, shownBatch: String?
    private var readings: [AgentImportRoute: AgentImportNavigation.Reading] = [:]
    private var rows: [AgentImportCandidate] = [], states: [String: String] = [:]
    private var listHeight: NSLayoutConstraint?
    private var refreshing = false
    private var inputIssue: String?
    var onNavigationChange: (() -> Void)?
    var onOpen: ((String) -> Void)?
    var onOpenConnector: ((String, String?) throws -> Void)?
    var onOpenAutomation: ((String) throws -> Void)?
    var onOpenPlugin: ((String, String?) throws -> Void)?
    var onOpenConfiguration: ((AgentStandaloneImportPlan, URL) throws -> Void)?
    var onOpenAgent: ((String, String?) throws -> Void)?
    var onOpenHooks: ((URL, String?) throws -> Void)?
    private var selectedSource: AgentImportSource { AgentImportSource.allCases[max(0, sources.selectedSegment)] }
    private var usesSSH: Bool { locations.selectedSegment == 1 }
    private var categories: [AgentImportCategory] { usesSSH ? AgentSSHImport.categories : AgentImportCategory.allCases }
    private var stoppableRoute: AgentImportRoute? {
        usesSSH ? categories.lazy.map(route).first { service.canStopScan(for: $0) } : nil
    }
    private var selectedCategory: AgentImportCategory { editing ?? .tasks }
    private var currentRoute: AgentImportRoute { route(selectedCategory) }
    private var canConfigure: Bool { !service.active && !service.scanning && !service.unfinished }
    private var selected: Set<String> { selections[currentRoute]?.ids ?? [] }
    init(store: AgentStore) {
        self.store = store; service = store.dataImport
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        locations.selectedSegment = 0; locations.target = self; locations.action = #selector(changeLocation)
        locations.setAccessibilityLabel("连接方式"); locations.setAccessibilityIdentifier("import-location")
        for index in 0..<locations.segmentCount { locations.setWidth(50, forSegment: index) }
        sources.selectedSegment = 0; sources.target = self; sources.action = #selector(changeSource)
        sources.setAccessibilityLabel("导入来源"); sources.setAccessibilityIdentifier("import-sources")
        for index in 0..<sources.segmentCount { sources.setWidth(76, forSegment: index) }
        connection.orientation = .vertical; connection.alignment = .leading; connection.spacing = 6
        for (label, field, hint, id) in [("SSH 主机", sshHost, "别名或用户@主机", "import-ssh-host"),
                                          ("远程路径", sshRoot, "~/" + selectedSource.homeName, "import-ssh-directory")] {
            field.placeholderString = hint; field.delegate = self
            field.outlined = true
            field.setAccessibilityLabel(label); field.setAccessibilityIdentifier(id)
            AgentSettingsStyle.field(field)
            field.heightAnchor.constraint(equalToConstant: 32).isActive = true
            let title = NSTextField(labelWithString: label)
            title.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let row = NSStackView(views: [title, field]); row.alignment = .centerY; row.spacing = 10
            append(row, to: connection)
        }
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
        for (button, action) in [(begin, #selector(start)), (confirmSSH, #selector(start)), (pause, #selector(pauseImport)), (resume, #selector(resumeImport)), (cancel, #selector(cancelImport)), (open, #selector(openTask)), (original, #selector(showOriginal))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        for button in [begin, confirmSSH] { AgentSettingsStyle.primaryAction(button) }
        confirmSSH.setAccessibilityIdentifier("import-ssh-confirm")
        let sourcesBar = NSStackView(views: [locations, sources, NSView(), detectAll]); sourcesBar.spacing = 8; sourcesBar.alignment = .centerY
        append(sourcesBar, to: overview)
        append(connection, to: overview)
        for (index, category) in AgentImportCategory.allCases.enumerated() {
            let divider = AgentSettingsStyle.divider()
            categoryDividers[category] = divider
            append(divider, to: overview)
            let row = AgentImportCategoryRow(category, index: index, target: self, toggle: #selector(toggleCategory(_:)), open: #selector(openCategory(_:)))
            categoryRows[category] = row
            append(row, to: overview)
        }
        let kinds = NSStackView(views: [back, categoryTitle, NSView(), destinationControl, confirmSSH]); kinds.spacing = 10; kinds.alignment = .centerY
        let header = NSStackView(views: [folder, NSView(), detect]); header.spacing = 8; header.alignment = .centerY
        let selection = NSStackView(views: [selectAll, NSView(), open, original]); selection.spacing = 8
        let actions = NSStackView(views: [state, NSView(), begin, pause, resume, cancel]); actions.spacing = 6
        for view in [kinds, header, selection, list, preview] { append(view, to: editor) }
        let column = NSStackView()
        for view in [overview, editor, actions] { append(view, to: column) }
        for stack in [overview, editor, column] { stack.orientation = .vertical; stack.alignment = .leading }
        overview.spacing = 2; overview.setCustomSpacing(10, after: sourcesBar)
        editor.spacing = 10; column.spacing = 12
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        let height = list.heightAnchor.constraint(equalToConstant: 236); listHeight = height
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor), folder.widthAnchor.constraint(greaterThanOrEqualToConstant: 90), height, preview.heightAnchor.constraint(equalToConstant: 142)])
        for scroll in [list, preview] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(readingChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(readingChanged), name: NSTextView.didChangeSelectionNotification, object: detail)
        folder.setContentHuggingPriority(.defaultLow, for: .horizontal); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func append(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    func captureNavigation() -> AgentImportNavigation? {
        rememberReading()
        var known = routes
        for route in reviewed.keys where route.sshHost == nil { known[route.source, default: [:]][route.category] = route }
        var remote = remoteRoutes
        if usesSSH {
            for category in categories {
                let draft = route(category)
                if let host = draft.sshHost, AgentSSHImport.valid(host: host, root: draft.root) { remote[draft.source, default: [:]][category] = draft }
            }
        }
        let local = AgentImportSource.allCases.flatMap { source in
            AgentImportCategory.allCases.compactMap { category in
                known[source]?[category].map { AgentImportNavigation.SourceRoute(route: $0, checked: reviewed[$0]) }
            }
        }
        let saved = local + AgentImportSource.allCases.flatMap { source in
            AgentSSHImport.categories.compactMap { category -> AgentImportNavigation.SourceRoute? in
                guard let route = remote[source]?[category], let host = route.sshHost,
                      AgentSSHImport.valid(host: host, root: route.root) else { return nil }
                return AgentImportNavigation.SourceRoute(route: route, checked: reviewed[route])
            }
        }
        let reading = editing.flatMap { readings[route($0)] }
        let value = AgentImportNavigation(source: selectedSource, category: editing, routes: saved, reading: reading, ssh: usesSSH ? true : nil)
        return value.valid ? value : nil
    }
    func restoreNavigation(_ value: AgentImportNavigation) {
        if let batch = service.batch, service.unfinished || service.active {
            guard batch.source == value.source, (batch.sshHost != nil) == (value.ssh == true) else { return }
            editing = value.category
        } else {
            locations.selectedSegment = value.ssh == true ? 1 : 0
            sources.selectedSegment = AgentImportSource.allCases.firstIndex(of: value.source) ?? 0
            editing = value.category
            routes.removeAll()
            remoteRoutes.removeAll()
            reviewed.removeAll()
            for entry in value.routes {
                let route = entry.route
                if route.sshHost != nil { remoteRoutes[route.source, default: [:]][route.category] = route }
                else { routes[route.source, default: [:]][route.category] = route }
                reviewed[route] = entry.checked
            }
            loadRemoteFields()
        }
        shownRoute = nil
        selections.removeAll()
        changedChecks.removeAll()
        readings.removeAll()
        if let editing { readings[route(editing)] = value.reading }
        refresh()
    }
    func restorePreviews(then ready: (() -> Void)? = nil) {
        guard !usesSSH else { return }
        let source = selectedSource, category = editing
        let saved = AgentImportCategory.allCases.map(route).filter { reviewed[$0] != nil && service.preview(for: $0) == nil }
        guard canConfigure, !saved.isEmpty else { return }
        Task { [weak self] in
            guard let self, canConfigure, selectedSource == source, saved.allSatisfy({ route($0.category) == $0 }) else { return }
            await service.detect(saved)
            if selectedSource == source, editing == category, saved.allSatisfy({ route($0.category) == $0 }) { ready?() }
        }
    }
    private func rememberReading() {
        guard !refreshing, !isHiddenOrHasHiddenAncestor, let route = shownRoute,
              !rows.isEmpty, let list = table.enclosingScrollView else { return }
        let id = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        let text = id == nil ? nil : try? AgentTextViewport(detail)
        readings[route] = .init(recordID: id, listY: max(0, list.contentView.bounds.minY), text: text)
    }
    @objc private func readingChanged() {
        if !refreshing, !isHiddenOrHasHiddenAncestor { onNavigationChange?() }
    }
    func refresh() {
        guard !refreshing else { return }
        rememberReading()
        refreshing = true
        defer { refreshing = false; onNavigationChange?() }
        let batch = service.batch
        if let batch, shownBatch != batch.id {
            shownBatch = batch.id
            locations.selectedSegment = batch.sshHost == nil ? 0 : 1
            sources.selectedSegment = AgentImportSource.allCases.firstIndex(of: batch.source) ?? 0
            reviewed = reviewed.filter { $0.key.source != batch.source || $0.key.sshHost != batch.sshHost }
            changedChecks = changedChecks.filter { $0.key.source != batch.source || $0.key.sshHost != batch.sshHost }
            if let host = batch.sshHost {
                remoteRoutes[batch.source, default: [:]][.tasks] = .init(source: batch.source, category: .tasks, root: batch.root, workspace: nil, sshHost: host)
            }
            for item in batch.items {
                let route = batch.route(for: item)
                if route.sshHost != nil { remoteRoutes[route.source, default: [:]][route.category] = route }
                else { routes[route.source, default: [:]][route.category] = route }
            }
            loadRemoteFields()
        }
        selections = selections.filter { service.preview(for: $0.key)?.id == $0.value.preview }
        let grouped = batch.map { batch in Dictionary(grouping: batch.items) { batch.route(for: $0) } } ?? [:]
        var picked = 0, hasPreview = false
        for (category, row) in categoryRows {
            let hidden = !categories.contains(category)
            row.isHidden = hidden; categoryDividers[category]?.isHidden = hidden
        }
        for category in categories {
            let route = route(category), preview = service.preview(for: route)
            if let preview, preview.issue == nil, selections[route] == nil { reconcileSelection(route, preview: preview) }
            picked += selections[route]?.ids.count ?? 0
            hasPreview = hasPreview || preview != nil
            updateCategory(route, preview: preview, items: grouped[route] ?? [])
        }
        let canStop = stoppableRoute != nil
        locations.isEnabled = canConfigure; sources.isEnabled = canConfigure; detectAll.isEnabled = canConfigure || canStop
        connection.isHidden = !usesSSH
        sshHost.isEnabled = canConfigure; sshRoot.isEnabled = canConfigure
        if canStop { detectAll.title = "停止检测" }
        else { detectAll.title = hasPreview ? "重新检测全部" : "检测可导入内容" }
        overview.isHidden = editing != nil; editor.isHidden = editing == nil
        let preview = editing.flatMap { service.preview(for: route($0)) }
        refreshEditor(preview: preview, items: editing.map { grouped[route($0)] ?? [] } ?? [])
        let reviewingSSH = usesSSH && editing != nil
        begin.isHidden = !canConfigure || !hasPreview || reviewingSSH
        confirmSSH.isHidden = !canConfigure || !hasPreview || !reviewingSSH
        for button in [begin, confirmSSH] {
            button.isEnabled = picked > 0
            button.title = picked > 0 ? "导入 \(picked) 项" : "导入所选数据"
        }
        pause.isHidden = !service.active; pause.isEnabled = batch?.state == "running"
        resume.isHidden = !service.unfinished || service.active; cancel.isHidden = !service.unfinished && !service.active
        let changed = editing.map { changedChecks[route($0), default: 0] } ?? categories.reduce(0) { $0 + changedChecks[route($1), default: 0] }
        let allRemoteFailed = usesSSH && editing == nil && categories.allSatisfy { service.preview(for: route($0))?.issue != nil }
        let remoteIssue = allRemoteFailed ? service.preview(for: route(.tasks))?.issue : nil
        if let issue = inputIssue ?? service.operationIssue ?? preview?.issue ?? remoteIssue { state.stringValue = issue; state.textColor = .systemRed }
        else {
            state.textColor = AgentWorkbenchTheme.secondaryText
            if service.stoppingScan { state.stringValue = "正在停止检测…" }
            else if service.scanning { state.stringValue = "正在检测…" }
            else if categories.contains(where: { service.stoppedScan == route($0) }) { state.stringValue = "已停止检测" }
            else if let batch, batch.source == selectedSource, batch.sshHost == route(.tasks).sshHost,
                    service.active || service.unfinished || !hasPreview {
                let done = batch.items.filter { $0.state == "imported" }.count, failed = batch.items.filter { $0.state == "failed" }.count
                state.stringValue = ["running": "导入中", "paused": "已暂停", "cancelled": "已取消", "completed": "已完成"][batch.state, default: batch.state] + " · \(done)/\(batch.items.count)" + (failed > 0 ? " · 失败 \(failed) 项" : "")
            } else if changed > 0 { state.stringValue = "\(changed) 项原勾选内容已变化，请重新审阅" }
            else if let preview {
                let available = preview.available.count, skipped = preview.records.count - available
                state.stringValue = preview.records.isEmpty ? "此类别无可导入内容" : "\(available) 项可导入" + (skipped > 0 ? " · 跳过 \(skipped) 项" : "")
            } else if usesSSH, categories.contains(where: { reviewed[route($0)] != nil }) { state.stringValue = "重新检测后恢复原勾选" }
            else { state.stringValue = hasPreview ? "" : "尚未检测" }
        }
        state.toolTip = state.stringValue
    }
    private func reconcileSelection(_ route: AgentImportRoute, preview: AgentImportPreview) {
        var fingerprints: [String: String] = [:]
        for record in preview.records where record.issue == nil { fingerprints[record.id] = AgentImportNavigation.reviewHash(record) }
        let previous = reviewed[route]
        let checked = previous.map { saved in fingerprints.filter { saved[$0.key] == $0.value } } ?? fingerprints
        changedChecks[route] = previous.map { $0.count - checked.count }
        reviewed[route] = checked
        selections[route] = .init(preview: preview.id, fingerprints: fingerprints, ids: Set(checked.keys))
    }
    private func updateCategory(_ route: AgentImportRoute, preview: AgentImportPreview?, items: [AgentImportItem]) {
        guard let row = categoryRows[route.category] else { return }
        let chosen = selections[route]?.ids.count ?? 0, available = preview?.available.count ?? 0
        row.choice.isEnabled = canConfigure && available > 0
        row.choice.state = chosen == 0 ? .off : chosen == available ? .on : .mixed
        row.status.textColor = AgentWorkbenchTheme.secondaryText
        row.status.toolTip = preview?.issue
        if preview?.issue != nil {
            let unavailable = route.sshHost == nil && route.root == defaultRoot(route.category).path && !FileManager.default.fileExists(atPath: route.root)
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
        let previous = shownRoute
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
        folder.title = route.sshHost.map { "SSH · " + $0 } ?? (isDefault ? "~/" + String(root.path.dropFirst(home.path.count + 1)) : root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
        folder.toolTip = route.sshHost.map { $0 + ":" + route.root } ?? root.path
        folder.setAccessibilityLabel(route.sshHost == nil ? "来源目录" : "SSH 来源")
        let canStop = stoppableRoute != nil
        folder.isEnabled = canConfigure; detect.isEnabled = canConfigure || canStop
        if canStop { detect.title = "停止检测" }
        else { detect.title = preview == nil && !usesSSH ? "检测此类" : "重新检测" }
        destinationControl.isHidden = route.category.globalTarget == nil
        if let title = route.category.globalTarget {
            updateDestinations(globalTitle: route.category == .automations && route.sshHost != nil ? "选择本机项目" : title)
        }
        table.setAccessibilityLabel("可导入" + route.category.title)
        let available = preview?.available.count ?? 0
        selectAll.isEnabled = canConfigure && available > 0
        selectAll.state = selected.isEmpty ? .off : selected.count == available ? .on : .mixed
        table.reloadData()
        let reading = readings[route]
        if let id = reading?.recordID, let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        table.enclosingScrollView?.isHidden = rows.isEmpty; selectAll.superview?.isHidden = rows.isEmpty
        listHeight?.constant = CGFloat(min(236, max(48, rows.count * 48)))
        updateDetail()
        guard !isHiddenOrHasHiddenAncestor, !rows.isEmpty else { return }
        layoutSubtreeIfNeeded()
        if let list = table.enclosingScrollView, reading != nil || previous != route {
            AgentSettingsRecovery.restoreScroll(reading?.listY ?? 0, to: list)
        }
        if table.selectedRow >= 0, let text = reading?.text { text.apply(to: detail, focus: false) }
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
        let kind = value.standaloneMCPHooks == true ? nil : value.configuration?.kind.title
        let subtitle = value.issue ?? states[value.id] ?? kind ?? target
            ?? (value.archived ? "已归档" : value.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "无工作目录")
        let title = NSTextField(labelWithString: value.title), status = NSTextField(labelWithString: subtitle)
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail; status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText; status.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, status]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; stack.toolTip = value.file; return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !refreshing {
            updateDetail()
            readingChanged()
        }
    }
    private func setDetail(_ value: String) {
        guard detail.string != value else { return }
        detail.string = value
        detail.setSelectedRange(NSRange(location: 0, length: 0))
        if let scroll = detail.enclosingScrollView { AgentSettingsRecovery.restoreScroll(0, to: scroll) }
    }
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
        guard hasSelection else { setDetail(""); open.isEnabled = false; original.isEnabled = false; return }
        let record = rows[table.selectedRow]
        let source = record.sshHost.map { $0 + ":" + record.file } ?? record.file
        if let plan = record.memory {
            let names = plan.parts.prefix(8).map(\.name).joined(separator: "、")
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局记忆"
            var lines = [record.title, "来源 · " + source, destination]
            if !names.isEmpty { lines.append("目标文件 · " + names + (plan.parts.count > 8 ? " 等\(plan.parts.count)份" : "")) }
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            setDetail(lines.joined(separator: "\n") + "\n\n" + record.preview)
            open.isEnabled = states[record.id] == "已导入" || record.issue == "已经导入"
            original.isHidden = record.sshHost != nil
            original.isEnabled = record.sshHost == nil && (try? AgentMemoryImport.sourceURL(record, root: root)) != nil
            return
        }
        if let plan = record.skill {
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局 Skills"
            var lines = [record.title, "来源 · " + source, destination]
            if plan.fileCount > 0 { lines.append("\(plan.fileCount) 个文件") }
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            setDetail(lines.joined(separator: "\n") + "\n\n" + record.preview)
            open.isEnabled = states[record.id] == "已导入" || record.issue == "已经导入"
            original.isHidden = record.sshHost != nil
            original.isEnabled = record.sshHost == nil && (try? AgentSkillImport.sourceURL(record, root: root)) != nil
            return
        }
        if let plan = record.connector {
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局连接器"
            var lines = [record.title, "来源 · " + record.file, destination]
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            if record.issue == nil { lines.append(plan.needsSetup ? "待配置 · 导入后需补全" : "导入后可在连接器中启用") }
            lines.append(contentsOf: record.warnings)
            setDetail(lines.joined(separator: "\n") + "\n\n" + record.preview)
            open.isEnabled = store.mcp.containsImported(record.targetID, workspace: plan.workspace)
            original.isEnabled = (try? AgentMCPDataImport.reveal(record, root: root)) != nil
            return
        }
        if let plan = record.automation {
            var lines = [record.title, "来源 · " + source]
            if let workspace = plan.workspace { lines.append("目标项目 · " + workspace) }
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            if record.issue == nil && states[record.id] == nil { lines.append("导入后为停用状态") }
            lines.append(contentsOf: record.warnings)
            setDetail(lines.joined(separator: "\n") + "\n\n" + record.preview)
            open.isEnabled = store.automations.values.contains { $0.id == record.targetID }
            original.isHidden = record.sshHost != nil
            original.isEnabled = record.sshHost == nil && (try? AgentAutomationDataImport.reveal(record, root: root)) != nil
            return
        }
        if let plan = record.plugin {
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局插件"
            var lines = [record.title, "来源 · " + record.file, destination]
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            else { lines.append("导入后为停用状态") }
            lines.append(contentsOf: record.warnings)
            setDetail(lines.joined(separator: "\n") + "\n\n" + record.preview)
            open.isEnabled = AgentPluginDataImport.installedID(record, store: store) != nil
            original.isEnabled = (try? AgentPluginDataImport.reveal(record, root: root)) != nil
            return
        }
        if let plan = record.configuration {
            let destination = plan.workspace.map { "目标项目 · " + $0 } ?? "目标 · 全局扩展配置"
            let title = record.standaloneMCPHooks == true ? record.title : plan.kind.title + " · " + record.title
            var lines = [title, "来源 · " + record.file, destination]
            if !plan.destination.isEmpty { lines.append("目标文件 · " + (record.issue == "已共享" ? record.file : plan.destination)) }
            if let status = record.issue ?? states[record.id] { lines.append(status) }
            lines.append(contentsOf: record.warnings)
            setDetail(lines.joined(separator: "\n") + "\n\n" + record.preview)
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
        let origin = record.sshHost.map { "来源 · " + $0 + ":" + record.file + "\n" } ?? ""
        setDetail(record.title + "\n" + origin + (record.workspace ?? "无工作目录") + "\n" + record.warnings.joined(separator: "\n") + (record.issue.map { "\n" + $0 } ?? states[record.id].map { "\n" + $0 } ?? "") + "\n\n" + record.preview)
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
        if usesSSH {
            let saved = remoteRoutes[selectedSource]?[category]
            if service.active || service.unfinished, let saved { return saved }
            return .init(source: selectedSource, category: category, root: sshRoot.stringValue, workspace: saved?.workspace,
                         sshHost: sshHost.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return routes[selectedSource]?[category] ?? .init(source: selectedSource, category: category, root: defaultRoot(category).path, workspace: nil)
    }
    private func setRoute(_ newRoute: AgentImportRoute) {
        let previous = route(newRoute.category)
        guard newRoute.source == selectedSource, newRoute != previous else { return }
        reviewed.removeValue(forKey: previous)
        selections.removeValue(forKey: previous)
        changedChecks.removeValue(forKey: previous)
        readings.removeValue(forKey: previous)
        shownRoute = nil
        if newRoute.sshHost != nil { remoteRoutes[newRoute.source, default: [:]][newRoute.category] = newRoute }
        else { routes[newRoute.source, default: [:]][newRoute.category] = newRoute }
        refresh()
    }
    private func loadRemoteFields(fallbackHost: String = "") {
        let saved = remoteRoutes[selectedSource]
        let route = AgentSSHImport.categories.lazy.compactMap { saved?[$0] }.first
        sshHost.stringValue = route?.sshHost ?? fallbackHost
        sshRoot.stringValue = route?.root ?? "~/" + selectedSource.homeName
    }
    private func rememberRemoteRoute(_ route: AgentImportRoute) {
        if let host = route.sshHost, AgentSSHImport.valid(host: host, root: route.root) {
            remoteRoutes[route.source, default: [:]][route.category] = route
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard usesSSH else { return }
        categories.map(route).forEach(rememberRemoteRoute)
        inputIssue = nil
        refresh()
    }
    @objc private func changeLocation() {
        editing = nil; inputIssue = nil
        if usesSSH { loadRemoteFields() }
        refresh(); restorePreviews()
    }
    @objc private func changeSource() {
        inputIssue = nil
        if usesSSH { loadRemoteFields(fallbackHost: sshHost.stringValue) }
        refresh(); restorePreviews()
    }
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
        setRoute(.init(source: route.source, category: route.category, root: route.root,
                       workspace: destination.selectedItem?.representedObject as? String, sshHost: route.sshHost))
    }
    @objc private func chooseFolder() {
        if usesSSH { closeCategory(); window?.makeFirstResponder(sshHost); return }
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
        if usesSSH { detectSSH(categories); return }
        let routes = AgentImportCategory.allCases.map(route)
        Task { await service.detect(routes) }
    }
    @objc private func detectRecords() {
        if usesSSH { detectSSH([selectedCategory]); return }
        let route = currentRoute
        Task { await service.detect([route]) }
    }
    private func detectSSH(_ categories: [AgentImportCategory]) {
        if let route = stoppableRoute { service.stopScan(for: route); return }
        guard canConfigure else { return }
        window?.makeFirstResponder(nil)
        let confirmed = categories.map(route)
        guard let first = confirmed.first, let host = first.sshHost, AgentSSHImport.valid(host: host, root: first.root) else {
            inputIssue = "请填写 SSH 主机和远程路径（绝对路径或 ~/）"
            refresh()
            if editing == nil { window?.makeFirstResponder(sshHost) }
            return
        }
        inputIssue = nil
        confirmed.forEach(rememberRemoteRoute)
        refresh()
        Task { await service.detect(confirmed) }
    }
    @objc private func toggleRecord(_ sender: NSButton) {
        let route = currentRoute
        guard canConfigure, rows.indices.contains(sender.tag), rows[sender.tag].issue == nil, var choice = selections[route] else { return }
        let id = rows[sender.tag].id
        if choice.ids.contains(id) { choice.ids.remove(id) } else { choice.ids.insert(id) }
        saveSelection(choice, for: route)
    }
    @objc private func toggleCategory(_ sender: NSButton) { toggleSelection(route(AgentImportCategory.allCases[sender.tag])) }
    @objc private func toggleAll() { toggleSelection(currentRoute) }
    private func toggleSelection(_ route: AgentImportRoute) {
        guard canConfigure, let preview = service.preview(for: route), var choice = selections[route] else { return }
        choice.ids = choice.ids == preview.available ? [] : preview.available
        saveSelection(choice, for: route)
    }
    private func saveSelection(_ choice: Selection, for route: AgentImportRoute) {
        selections[route] = choice
        reviewed[route] = choice.fingerprints.filter { choice.ids.contains($0.key) }
        refresh()
    }
    @objc private func start() {
        let choices = categories.map(route).compactMap { route in selections[route].map { (route, $0.ids) } }
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
