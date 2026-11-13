import AppKit

enum AgentSidebarItem: String, Codable, CaseIterable {
    case attention, search, automation, extensions, library, wiki
    var title: String {
        switch self { case .attention: return "需要我"; case .search: return "搜索"; case .automation: return "自动化"; case .extensions: return "扩展"; case .library: return "知识库"; case .wiki: return "项目知识" }
    }
    var symbol: String {
        switch self { case .attention: return "bell"; case .search: return "magnifyingglass"; case .automation: return "clock.arrow.circlepath"; case .extensions: return "puzzlepiece.extension"; case .library: return "tray.full"; case .wiki: return "books.vertical" }
    }
}
enum AgentSidebarSection: Int, CaseIterable {
    case upper, lower, more
    var title: String { switch self { case .upper: return "侧导上方"; case .lower: return "侧导下方"; case .more: return "更多" } }
}

@MainActor final class AgentSidebarLayout {
    struct Settings: Codable, Equatable {
        var version = 1
        var upper: [AgentSidebarItem] = [.attention, .search]
        var lower: [AgentSidebarItem] = [.automation, .extensions]
        var more: [AgentSidebarItem] = [.library, .wiki]
        subscript(_ section: AgentSidebarSection) -> [AgentSidebarItem] {
            get { switch section { case .upper: return upper; case .lower: return lower; case .more: return more } }
            set { switch section { case .upper: upper = newValue; case .lower: lower = newValue; case .more: more = newValue } }
        }
        func section(of item: AgentSidebarItem) -> AgentSidebarSection? { AgentSidebarSection.allCases.first { self[$0].contains(item) } }
        mutating func move(_ item: AgentSidebarItem, to section: AgentSidebarSection, before: AgentSidebarItem? = nil) throws {
            guard before != item else { return }
            guard self.section(of: item) != nil, before == nil || self[section].contains(before!) else { throw PetError("侧栏入口位置已变化，请重新选择") }
            for key in AgentSidebarSection.allCases { self[key].removeAll { $0 == item } }
            let index = before.flatMap { self[section].firstIndex(of: $0) } ?? self[section].count
            self[section].insert(item, at: index)
        }
    }
    let directory: URL
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    var onChange: (() -> Void)?
    static let changed = Notification.Name("BlueFatFishSidebarLayoutChanged")
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("sidebar.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("sidebar.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("侧栏配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 4096)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "upper", "lower", "more"] else { throw PetError("侧栏配置包含不支持的字段") }
                let value = try JSONDecoder().decode(Settings.self, from: data); try validate(value)
                settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "侧栏配置未载入：" + error.localizedDescription }
    }
    private func validate(_ value: Settings) throws {
        let items = value.upper + value.lower + value.more
        guard value.version == 1, items.count == AgentSidebarItem.allCases.count, Set(items) == Set(AgentSidebarItem.allCases) else { throw PetError("侧栏配置版本或入口无效") }
    }
    func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }; try validate(value)
        guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("sidebar.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("侧栏配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "sidebar.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "侧栏配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); publish()
    }
    func publish() { onChange?(); NotificationCenter.default.post(name: Self.changed, object: self) }
}

@MainActor private final class AgentSidebarNavigationDocument: NSView { override var isFlipped: Bool { true } }

// The navigation groups yield height to the task list on a small window; their
// document stays complete and scrollable instead of hiding configured entries.
@MainActor final class AgentSidebarNavigationList: NSScrollView {
    private let document = AgentSidebarNavigationDocument(), column = NSStackView()
    private var preferred: NSLayoutConstraint!, minimum: NSLayoutConstraint!, widths: [NSLayoutConstraint] = []
    private(set) var buttons: [NSButton] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; hasVerticalScroller = true; scrollerStyle = .overlay; verticalScrollElasticity = .none
        document.translatesAutoresizingMaskIntoConstraints = false; documentView = document
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 3; column.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(column)
        preferred = heightAnchor.constraint(equalToConstant: 0); preferred.priority = .defaultHigh
        minimum = heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: contentView.widthAnchor), column.leadingAnchor.constraint(equalTo: document.leadingAnchor), column.trailingAnchor.constraint(equalTo: document.trailingAnchor), column.topAnchor.constraint(equalTo: document.topAnchor), column.bottomAnchor.constraint(equalTo: document.bottomAnchor), preferred, minimum])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(_ buttons: [NSButton], priority: Float = 750) {
        NSLayoutConstraint.deactivate(widths); widths = []
        for view in column.arrangedSubviews { column.removeArrangedSubview(view); view.removeFromSuperview() }
        self.buttons = buttons
        for button in buttons { column.addArrangedSubview(button); widths.append(button.widthAnchor.constraint(equalTo: column.widthAnchor)) }
        NSLayoutConstraint.activate(widths)
        preferred.constant = CGFloat(buttons.count * 32 + max(0, buttons.count - 1) * 3); preferred.priority = NSLayoutConstraint.Priority(priority)
        minimum.constant = buttons.isEmpty ? 0 : 32
        isHidden = buttons.isEmpty
        contentView.scroll(to: .zero); reflectScrolledClipView(contentView)
    }
}

@MainActor private final class AgentSidebarLayoutTable: NSTableView {
    var onMove: ((UInt16) -> Bool)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, selectedRow < 0, numberOfRows > 0, delegate?.tableView?(self, shouldSelectRow: 0) != false { selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, onMove?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor private final class AgentSidebarPreviewScroll: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Every preview row is visible. Keep the entire vertical gesture,
        // including zero-delta endings, with the surrounding settings page.
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty, let parent = superview?.enclosingScrollView { parent.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

@MainActor final class AgentSidebarLayoutSettingsView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private let service: AgentSidebarLayout
    private var tables: [AgentSidebarSection: NSTableView] = [:], heights: [AgentSidebarSection: NSLayoutConstraint] = [:]
    private let status = NSTextField(labelWithString: ""), reload = NSButton(title: "重新载入", target: nil, action: nil)
    private let restore = NSButton(title: "恢复默认", target: nil, action: nil)
    private let morePreview = NSTextField(labelWithString: "•••  更多")
    private static let dragType = NSPasteboard.PasteboardType("com.xjs.bluefatfish.sidebar-menu")
    init(service: AgentSidebarLayout) {
        self.service = service; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        func label(_ title: String) -> NSTextField { let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13, weight: .medium); return label }
        func fixed(_ title: String, symbol: String) -> NSStackView {
            let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 13)
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!), lock = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: title + "固定，无法移动")!)
            for image in [icon, lock] { image.contentTintColor = AgentWorkbenchTheme.secondaryText; image.widthAnchor.constraint(equalToConstant: 16).isActive = true }
            let row = NSStackView(views: [icon, name, NSView(), lock]); row.spacing = 8; row.heightAnchor.constraint(equalToConstant: 32).isActive = true; return row
        }
        func section(_ section: AgentSidebarSection) -> NSStackView {
            let table = AgentSidebarLayoutTable(), column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("menu")); table.addTableColumn(column)
            tables[section] = table
            table.headerView = nil; table.rowHeight = 34; table.intercellSpacing = NSSize(width: 0, height: 2); table.backgroundColor = .clear; table.style = .plain
            table.delegate = self; table.dataSource = self; table.setAccessibilityLabel(section.title); table.toolTip = "↑ ↓ 调整顺序，← → 切换分组"
            table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
            table.onMove = { [weak self, weak table] code in guard let self, let table else { return false }; return self.moveSelection(in: table, key: code) }
            let scroll = AgentSidebarPreviewScroll(); scroll.documentView = table; scroll.hasVerticalScroller = false; scroll.drawsBackground = false
            let height = scroll.heightAnchor.constraint(equalToConstant: 72); height.isActive = true; heights[section] = height; tables[section] = table
            let box = NSStackView(views: [label(section.title), scroll]); box.orientation = .vertical; box.alignment = .leading; box.spacing = 8
            scroll.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
            return box
        }
        let heading = label("侧栏菜单"); addArrangedSubview(heading)
        let gap = NSView(); gap.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let top = section(.upper), bottom = section(.lower), more = section(.more)
        morePreview.font = .systemFont(ofSize: 13); morePreview.textColor = AgentWorkbenchTheme.secondaryText
        let preview = NSStackView(views: [fixed("新的任务", symbol: "plus.square"), top, gap, bottom, morePreview, fixed("设置", symbol: "gearshape")]); preview.orientation = .vertical; preview.alignment = .leading; preview.spacing = 12
        for view in preview.arrangedSubviews { view.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true }
        func card(_ content: NSView) -> NSView {
            let card = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line); card.layer?.cornerRadius = 10; card.layer?.borderWidth = 1
            card.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12), content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)])
            return card
        }
        let moreColumn = NSStackView(views: [more, NSView()]); moreColumn.orientation = .vertical; moreColumn.alignment = .leading; more.widthAnchor.constraint(equalTo: moreColumn.widthAnchor).isActive = true
        let left = card(preview), right = card(moreColumn)
        let columns = NSStackView(views: [left, right]); columns.alignment = .top; columns.spacing = 12; columns.distribution = .fillEqually
        right.heightAnchor.constraint(equalTo: left.heightAnchor).isActive = true
        addArrangedSubview(columns); columns.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText; status.setAccessibilityLabel("侧栏保存状态")
        reload.target = self; reload.action = #selector(reloadSettings); restore.target = self; restore.action = #selector(restoreSettings)
        let footer = NSStackView(views: [status, NSView(), reload, restore]); footer.spacing = 10; addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentSidebarLayout.changed, object: service)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func section(_ table: NSTableView) -> AgentSidebarSection { tables.first { $0.value === table }!.key }
    func numberOfRows(in tableView: NSTableView) -> Int { max(1, service.settings[section(tableView)].count) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { service.error == nil && service.settings[section(tableView)].indices.contains(row) }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let selected = notification.object as? NSTableView, selected.selectedRow >= 0 else { return }
        for table in tables.values where table !== selected { table.deselectAll(nil) }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = service.settings[section(tableView)]
        guard items.indices.contains(row) else { let empty = NSTextField(labelWithString: "暂无入口"); empty.textColor = AgentWorkbenchTheme.secondaryText; return empty }
        let item = items[row], icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)!), title = NSTextField(labelWithString: item.title), handle = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动" )!)
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail
        for image in [icon, handle] { image.contentTintColor = AgentWorkbenchTheme.secondaryText; image.widthAnchor.constraint(equalToConstant: 16).isActive = true }
        let cell = NSStackView(views: [icon, title, NSView(), handle]); cell.spacing = 8; cell.setAccessibilityLabel(item.title); return cell
    }
    @objc private func refresh() {
        for section in AgentSidebarSection.allCases { tables[section]?.reloadData(); tables[section]?.isEnabled = service.error == nil; heights[section]?.constant = CGFloat(max(1, service.settings[section].count) * 36) }
        restore.isEnabled = service.error == nil && service.settings != AgentSidebarLayout.Settings()
        morePreview.isHidden = service.settings.more.isEmpty
        if let error = service.error { status.stringValue = error }
        reload.isHidden = status.stringValue.isEmpty || status.stringValue == "已保存"
    }
    private func move(_ item: AgentSidebarItem, to section: AgentSidebarSection, before: AgentSidebarItem? = nil) -> Bool {
        do {
            var next = service.settings; try next.move(item, to: section, before: before); try service.save(next)
            status.stringValue = "已保存"; refresh()
            for table in tables.values { table.deselectAll(nil) }
            window?.contentView?.layoutSubtreeIfNeeded()
            for table in tables.values {
                if let scroll = table.enclosingScrollView { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
            }
            if let table = tables[section], let index = service.settings[section].firstIndex(of: item) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                if let outer = table.enclosingScrollView?.superview?.enclosingScrollView, let document = outer.documentView { document.scrollToVisible(document.convert(table.rect(ofRow: index), from: table)) }
                window?.makeFirstResponder(table)
            }
            return true
        } catch { status.stringValue = error.localizedDescription; reload.isHidden = false; return false }
    }
    @discardableResult func moveSelection(in table: NSTableView, key: UInt16) -> Bool {
        guard [123, 124, 125, 126].contains(key) else { return false }
        let section = self.section(table), items = service.settings[section], index = table.selectedRow
        guard items.indices.contains(index), service.error == nil else { return true }
        if key == 123 || key == 124 {
            let next = section.rawValue + (key == 123 ? -1 : 1)
            if let target = AgentSidebarSection(rawValue: next) { _ = move(items[index], to: target) }
        } else {
            let next = index + (key == 126 ? -1 : 1)
            if items.indices.contains(next) { _ = move(items[index], to: section, before: key == 126 ? items[next] : (next + 1 < items.count ? items[next + 1] : nil)) }
        }
        return true
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let items = service.settings[section(tableView)]; guard service.error == nil, items.indices.contains(row) else { return nil }
        let item = NSPasteboardItem(); item.setString(items[row].rawValue, forType: Self.dragType); return item
    }
    private func dropItem(_ info: NSDraggingInfo) -> AgentSidebarItem? {
        guard service.error == nil, let source = info.draggingSource as? NSTableView, tables.values.contains(where: { $0 === source }), let raw = info.draggingPasteboard.string(forType: Self.dragType) else { return nil }
        guard let item = AgentSidebarItem(rawValue: raw), service.settings[section(source)].contains(item) else { return nil }
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropItem(info) != nil else { return [] }
        let count = service.settings[section(tableView)].count
        tableView.setDropRow(row < 0 ? count : min(row, count), dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = dropItem(info) else { return false }; let section = self.section(tableView), items = service.settings[section]
        return move(item, to: section, before: items.indices.contains(row) ? items[row] : nil)
    }
    @objc private func reloadSettings() { service.reload(); service.publish(); status.stringValue = service.error ?? "已重新载入"; refresh() }
    @objc private func restoreSettings() {
        do { try service.save(AgentSidebarLayout.Settings()); status.stringValue = "已保存"; refresh() }
        catch { status.stringValue = error.localizedDescription; reload.isHidden = false }
    }
}
