import AppKit

struct AgentDelimitedPosition: Codable, Equatable {
    var firstRowIsHeader = true
    var query = ""
    var selectedRow: Int?
    var widths: [Double]?
    var x: Double = 0
    var y: Double = 0

    var valid: Bool {
        query.utf8.count <= 2048 && x.isFinite && y.isFinite && x >= 0 && y >= 0
            && (selectedRow.map { (0..<AgentDelimitedText.rowLimit).contains($0) } ?? true)
            && (widths.map { $0.count <= AgentDelimitedText.columnLimit && $0.allSatisfy { (56...640).contains($0) } } ?? true)
    }

    static func validateObject(_ value: Any) throws {
        guard let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["firstRowIsHeader", "query", "selectedRow", "widths", "x", "y"]) else {
            throw PetError("附件表格位置无法读取")
        }
    }
}

@MainActor final class AgentDelimitedPreview: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let controls = NSStackView()
    private let search = NSSearchField()
    private let headerRow = NSButton(checkboxWithTitle: "首行为表头", target: nil, action: nil)
    private let table = NSTableView(), scroll = NSScrollView()
    private var model: AgentDelimitedText?
    private var displayedRows: [Int] = [], titles: [String] = []
    private var pending: AgentDelimitedPosition?, applying = false
    private var cellReader: NSPopover?
    var onChange: (() -> Void)?
    var onSummary: ((String) -> Void)?
    var position: AgentDelimitedPosition? {
        if let pending { return pending }
        guard model != nil else { return nil }
        let origin = scroll.contentView.bounds.origin
        return AgentDelimitedPosition(firstRowIsHeader: headerRow.state == .on, query: search.stringValue,
            selectedRow: selectedRecord, widths: table.tableColumns.dropFirst().map { Double($0.width) },
            x: max(0, origin.x), y: max(0, origin.y))
    }
    private var selectedRecord: Int? {
        displayedRows.indices.contains(table.selectedRow) ? displayedRows[table.selectedRow] : nil
    }

    init() {
        super.init(frame: .zero)
        search.placeholderString = "筛选行"; search.setAccessibilityLabel("筛选表格行")
        search.controlSize = .small; search.delegate = self
        search.target = self; search.action = #selector(filterChanged)
        search.widthAnchor.constraint(equalToConstant: 148).isActive = true
        headerRow.controlSize = .small; headerRow.state = .on
        headerRow.target = self; headerRow.action = #selector(headerChanged)
        controls.orientation = .horizontal; controls.spacing = 10; controls.alignment = .centerY
        controls.addArrangedSubview(search); controls.addArrangedSubview(headerRow)

        table.delegate = self; table.dataSource = self
        table.style = .plain; table.headerView = NSTableHeaderView()
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false; table.allowsColumnResizing = true
        table.backgroundColor = AgentWorkbenchTheme.surface
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = AgentWorkbenchTheme.line
        table.rowHeight = 25; table.intercellSpacing = NSSize(width: 10, height: 1)
        table.setAccessibilityLabel("附件表格")
        table.target = self; table.doubleAction = #selector(readCell)
        let cellActions = NSMenu()
        let readItem = NSMenuItem(title: "查看单元格", action: #selector(readCell), keyEquivalent: "")
        readItem.target = self; cellActions.addItem(readItem); table.menu = cellActions
        scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(documentResized), name: NSView.frameDidChangeNotification, object: table)
        addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func display(_ preview: AgentDelimitedText, position: AgentDelimitedPosition?) {
        applying = true
        defer { applying = false }
        model = preview
        pending = position ?? AgentDelimitedPosition()
        headerRow.state = pending?.firstRowIsHeader == false ? .off : .on
        search.stringValue = pending?.query ?? ""
        updateColumns(widths: pending?.widths)
        updateRows(selecting: pending?.selectedRow)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if pending != nil {
            DispatchQueue.main.async { [weak self] in self?.applyPosition() }
        }
    }

    private func applyPosition() {
        guard let pending, !isHidden, window != nil, scroll.contentView.bounds.height > 1 else { return }
        applying = true
        defer { applying = false }
        table.tile()
        scroll.tile()
        // Loading rows and showing scrollers can change the document frame in
        // this layout pass. Clamp against the completed grid, not the old frame.
        let rowEnd = displayedRows.isEmpty ? 0 : table.rect(ofRow: displayedRows.count - 1).maxY
        let columnEnd = table.rect(ofColumn: table.numberOfColumns - 1).maxX
        guard table.frame.height >= rowEnd - 1, table.frame.width >= columnEnd - 1 else { return }
        setScroll(NSPoint(x: pending.x, y: pending.y))
        self.pending = nil
        onChange?()
    }

    private func setScroll(_ point: NSPoint) {
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        if let headerClip = table.headerView?.superview as? NSClipView {
            headerClip.scroll(to: NSPoint(x: clip.bounds.minX, y: headerClip.bounds.minY))
        }
    }

    @objc private func headerChanged() {
        let selection = selectedRecord
        updateColumns(widths: position?.widths)
        updateRows(selecting: selection)
        setScroll(.zero)
        onChange?()
    }

    func controlTextDidChange(_ notification: Notification) { filterChanged() }

    @objc private func filterChanged() {
        if search.stringValue.utf8.count > 2048 {
            search.stringValue = String(decoding: search.stringValue.utf8.prefix(2045), as: UTF8.self)
        }
        updateRows(selecting: selectedRecord)
        setScroll(NSPoint(x: scroll.contentView.bounds.minX, y: 0))
        onChange?()
    }

    private func updateColumns(widths: [Double]?) {
        guard let model else { return }
        for column in table.tableColumns { table.removeTableColumn(column) }
        let ordinal = NSTableColumn(identifier: .init("row")); ordinal.title = "行"
        ordinal.minWidth = 48; ordinal.maxWidth = 62; ordinal.width = 52
        table.addTableColumn(ordinal)
        let header = headerRow.state == .on ? model.rows.first ?? [] : []
        titles = (0..<min(model.columnCount, AgentDelimitedText.columnLimit)).map { index in
            guard header.indices.contains(index), !header[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "列 \(index + 1)" }
            return header[index].components(separatedBy: .newlines).joined(separator: " ")
        }
        let font = NSFont.systemFont(ofSize: 12)
        for (index, title) in titles.enumerated() {
            let column = NSTableColumn(identifier: .init(String(index)))
            column.title = String(title.prefix(160)); column.headerToolTip = String(title.prefix(250))
            let sample = model.rows.prefix(60).compactMap { $0.indices.contains(index) ? $0[index] : nil }
            let measured = (sample + [title]).map { value in
                (String(value.prefix(40)) as NSString).size(withAttributes: [.font: font]).width
            }.max() ?? 0
            column.minWidth = 56; column.maxWidth = 640
            let restored = widths?.indices.contains(index) == true ? widths?[index] : nil
            column.width = restored ?? max(78, min(242, ceil(measured) + 28))
            table.addTableColumn(column)
        }
    }

    private func updateRows(selecting record: Int?) {
        guard let model else { return }
        let wasApplying = applying
        applying = true
        defer { applying = wasApplying }
        let first = headerRow.state == .on && !model.rows.isEmpty ? 1 : 0
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = model.rows.indices.dropFirst(first)
        displayedRows = query.isEmpty ? Array(records) : records.filter { index in
            model.rows[index].contains { $0.localizedStandardContains(query) }
        }
        table.reloadData()
        if let record, let index = displayedRows.firstIndex(of: record) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        let total = model.rowCount - first
        var summary: [String] = []
        if model.rowCount == 0 { summary.append("空表格") }
        else if displayedRows.isEmpty && !query.isEmpty { summary.append("无匹配行") }
        if model.rowCount > 0 {
            summary.append(query.isEmpty ? "\(total) 行" : "\(displayedRows.count) / \(total) 行")
            summary.append("\(model.columnCount) 列")
        }
        if model.rowCount > model.rows.count { summary.append("预览前 \(model.rows.count - first) 行") }
        if model.columnCount > titles.count { summary.append("预览前 \(titles.count) 列") }
        onSummary?(summary.joined(separator: " · "))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let model, displayedRows.indices.contains(row) else { return 25 }
        return model.rows[displayedRows[row]].contains(where: { $0.utf8.contains(10) || $0.utf8.contains(13) }) ? 40 : 25
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let model, let column, displayedRows.indices.contains(row) else { return nil }
        let record = displayedRows[row], cells = model.rows[record]
        let columnIndex = Int(column.identifier.rawValue)
        let value = columnIndex.map { cells.indices.contains($0) ? cells[$0] : "" } ?? String(record + (headerRow.state == .on ? 0 : 1))
        let identifier = NSUserInterfaceItemIdentifier("attachment-table-cell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = identifier; field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = columnIndex == nil ? AgentWorkbenchTheme.secondaryText : .labelColor
        field.alignment = columnIndex == nil ? .right : .left
        field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 2
        field.stringValue = String(value.prefix(240))
        field.toolTip = columnIndex == nil ? nil : String(value.prefix(1600))
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { positionChanged() }
    func tableViewColumnDidResize(_ notification: Notification) { positionChanged() }
    @objc private func positionChanged() { if !applying && !isHidden { onChange?() } }
    @objc private func documentResized() { if pending != nil && !applying { needsLayout = true } }

    @objc private func readCell() {
        let row = table.clickedRow, column = table.clickedColumn
        guard let model, displayedRows.indices.contains(row), table.tableColumns.indices.contains(column),
              let index = Int(table.tableColumns[column].identifier.rawValue) else { return }
        let values = model.rows[displayedRows[row]]
        guard values.indices.contains(index) else { return }
        cellReader?.close()
        let reader = NSViewController()
        let content = NSTextView.scrollableTextView()
        guard let text = content.documentView as? NSTextView else { return }
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .systemFont(ofSize: 13); text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.string = values[index]
        text.setAccessibilityLabel(titles[index] + "单元格内容")
        reader.view = content
        let popover = NSPopover()
        popover.behavior = .transient; popover.contentViewController = reader
        popover.contentSize = NSSize(width: 340, height: 114)
        popover.show(relativeTo: table.frameOfCell(atColumn: column, row: row), of: table, preferredEdge: .maxY)
        text.window?.makeFirstResponder(text)
        cellReader = popover
    }

    func readback() -> [String: Any] {
        guard let model, let position else { return [:] }
        let origin = scroll.contentView.bounds.origin
        return ["headers": titles, "rows": displayedRows.count, "totalRows": model.rowCount, "totalColumns": model.columnCount,
                "query": position.query, "firstRowIsHeader": position.firstRowIsHeader,
                "selectedRow": selectedRecord as Any? ?? NSNull(), "widths": position.widths ?? [],
                "x": origin.x, "y": origin.y, "pendingPosition": pending != nil,
                "firstVisibleValues": displayedRows.first.map { model.rows[$0].map { String($0.prefix(300)) } } ?? []]
    }
}
