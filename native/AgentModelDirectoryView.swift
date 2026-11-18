import AppKit

@MainActor final class AgentModelDirectoryView: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onRead: (() -> Void)?
    var onChoose: ((String) -> Void)?
    private(set) var models: [ModelInfo] = []

    private let search = AgentSettingsSidebarSearchField(), table = AgentSettingsCatalogTable(), scroll = NSScrollView()
    private let read = AgentDialogButton(title: "读取列表", target: nil, action: nil)
    private let choose = AgentDialogButton(title: "使用模型", target: nil, action: nil)
    private let status = AgentSettingsStatusField("模型列表状态")
    private var rows: [ModelInfo] = []
    private var currentID = "", message = "未读取模型列表"
    private var reading = false, failed = false

    init() {
        super.init(frame: .zero)
        search.placeholderString = "搜索模型"; search.setAccessibilityLabel("搜索模型"); search.delegate = self
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.heightAnchor.constraint(equalToConstant: 28).isActive = true
        AgentDialogStyle.action(read); read.target = self; read.action = #selector(readList)
        AgentDialogStyle.action(choose); choose.target = self; choose.action = #selector(useSelection)
        table.addTableColumn(NSTableColumn(identifier: .init("model"))); table.headerView = nil
        table.style = .fullWidth; table.rowHeight = 40; table.intercellSpacing = .zero; table.backgroundColor = .clear
        table.setAccessibilityLabel("服务模型列表"); table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(useSelection)
        table.onOpen = { [weak self] in self?.useSelection() }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: 154).isActive = true
        status.stringValue = message
        let toolbar = NSStackView(views: [search, read, choose]); toolbar.alignment = .centerY; toolbar.spacing = 8
        let column = NSStackView(views: [toolbar, scroll, status]); column.orientation = .vertical
        column.alignment = .leading; column.spacing = 6
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.widthAnchor.constraint(equalTo: column.widthAnchor), scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            status.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        updateRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focus(model: String) {
        updateCurrentModel(model)
        window?.makeFirstResponder(search)
    }
    func updateCurrentModel(_ id: String) {
        currentID = id
        select(rows.firstIndex { $0.id == id })
    }
    func clear() {
        models = []; search.stringValue = ""; message = "未读取模型列表"; failed = false
        updateRows()
    }
    func setModels(_ values: [ModelInfo]) {
        var seen = Set<String>()
        models = values.filter { AgentTaskModels.validID($0.id) && seen.insert($0.id).inserted }
        message = models.isEmpty ? "服务未返回可用模型" : ""; failed = false
        updateRows()
    }
    func setRequestState(reading: Bool, detecting: Bool) {
        self.reading = reading; read.isEnabled = !detecting
        read.title = reading ? "取消读取" : models.isEmpty ? "读取列表" : "刷新列表"
        updateFeedback()
    }
    func showMessage(_ value: String, error: Bool = false) {
        message = value; failed = error; updateFeedback()
    }
    private func updateFeedback() {
        status.stringValue = reading ? "正在读取模型列表…" : !message.isEmpty ? message
            : rows.isEmpty ? "未找到匹配模型" : ""
        if failed && !reading { status.textColor = AgentDialogStyle.error }
        choose.isEnabled = !reading && rows.indices.contains(table.selectedRow)
    }
    private func select(_ row: Int?) {
        if let row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        else { table.deselectAll(nil) }
        updateFeedback()
    }
    private func updateRows() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : currentID
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = models.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) || $0.name?.localizedCaseInsensitiveContains(query) == true }
        table.reloadData(); scroll.isHidden = rows.isEmpty
        select(rows.firstIndex { $0.id == selected })
    }

    @objc private func readList() { onRead?() }
    @objc private func useSelection() {
        guard !reading, rows.indices.contains(table.selectedRow) else { return }
        onChoose?(rows[table.selectedRow].id)
    }
    func controlTextDidChange(_ notification: Notification) { updateRows() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)), !rows.isEmpty else { return false }
        window?.makeFirstResponder(table)
        if table.selectedRow < 0 { select(0) }
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateFeedback() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsCatalogRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let model = rows[row]
        let preferredName = model.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = NSTextField(labelWithString: preferredName.isEmpty ? model.id : String(preferredName.prefix(200)))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let id = NSTextField(labelWithString: model.id); id.font = .systemFont(ofSize: 11); id.textColor = AgentWorkbenchTheme.secondaryText
        let labels = title.stringValue == model.id ? [title] : [title, id]
        let column = NSStackView(views: labels); column.orientation = .vertical; column.alignment = .leading; column.spacing = 1
        let cell = NSTableCellView(); cell.toolTip = model.id; cell.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for label in labels {
            label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            column.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
