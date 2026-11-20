import AppKit

@MainActor final class AgentTaskModelPicker: NSViewController, NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Row {
        let title: String
        let model: String?
    }

    private let runtime: AgentRuntime
    private let taskID: String
    private weak var popover: NSPopover?
    private weak var owner: NSWindow?
    private let onClose: (Bool) -> Void
    private let search = AgentSettingsSidebarSearchField(frame: .zero)
    private let table = NSTableView()
    private let state = AgentSettingsStatusField("任务模型状态")
    private let refreshButton = AgentDialogButton(title: "刷新列表", target: nil, action: nil)
    private let choose = AgentDialogButton(title: "使用模型", target: nil, action: nil)
    private var rows: [Row] = []
    private var load: Task<Void, Never>?
    private var error: Error?
    private var returnFocus = false

    init(runtime: AgentRuntime, taskID: String, popover: NSPopover, owner: NSWindow?, onClose: @escaping (Bool) -> Void) {
        self.runtime = runtime; self.taskID = taskID; self.popover = popover; self.owner = owner; self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 424, height: 368)
        let content = AgentThemeView(fill: AgentWorkbenchTheme.card, stroke: AgentWorkbenchTheme.line)
        content.layer?.cornerRadius = 10; content.layer?.borderWidth = 1
        content.setAccessibilityLabel("任务模型选择")
        view = content

        search.placeholderString = "搜索或输入模型 ID"; search.setAccessibilityLabel("搜索或输入模型 ID")
        search.delegate = self; search.target = self; search.action = #selector(queryChanged)
        search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: .init("model")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 34; table.style = .plain; table.backgroundColor = .clear
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(useModel)
        table.setAccessibilityLabel("任务可选模型")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        list.drawsBackground = false; list.scrollerStyle = .overlay; list.autohidesScrollers = true
        let border = AgentThemeView(fill: .clear, stroke: AgentWorkbenchTheme.line)
        border.layer?.cornerRadius = 8; border.layer?.borderWidth = 1; border.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: border.leadingAnchor, constant: 3), list.trailingAnchor.constraint(equalTo: border.trailingAnchor, constant: -3),
                                     list.topAnchor.constraint(equalTo: border.topAnchor, constant: 3), list.bottomAnchor.constraint(equalTo: border.bottomAnchor, constant: -3)])

        refreshButton.target = self; refreshButton.action = #selector(refreshModels); AgentDialogStyle.action(refreshButton)
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(closeAndReturn))
        cancel.keyEquivalent = "\u{1b}"; AgentDialogStyle.action(cancel)
        choose.target = self; choose.action = #selector(useModel); choose.keyEquivalent = "\r"
        AgentDialogStyle.action(choose, prominent: true)
        let header = NSStackView(views: [search, refreshButton]); header.alignment = .centerY; header.spacing = 8
        let actions = NSStackView(views: [NSView(), cancel, choose]); actions.spacing = 8
        let body = NSStackView(views: [header, border, state, actions]); body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        content.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        for item in body.arrangedSubviews { item.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        border.setContentHuggingPriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
                                     body.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
        reloadRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func popoverDidShow(_ notification: Notification) {
        if let window = view.window { AgentThemeContext.inherit(window, from: owner); window.makeFirstResponder(search) }
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }

    func popoverWillClose(_ notification: Notification) { load?.cancel(); load = nil }
    func popoverDidClose(_ notification: Notification) { onClose(returnFocus) }

    @objc private func closeAndReturn() { returnFocus = true; popover?.close() }

    private var selectedRow: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var query: String {
        ((search.currentEditor() as? NSTextView)?.string ?? search.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refreshState() {
        let task = runtime.store.task(taskID)
        let available = task?.archived == false && task?.kind != "hook"
        let busy = runtime.isBusy(taskID) || task?.pendingCalls.isEmpty == false
        choose.isEnabled = load == nil && available && !busy && selectedRow != nil
        refreshButton.isEnabled = load == nil
        if load != nil { state.stringValue = "正在刷新模型列表…" }
        else if !available { state.stringValue = "此任务无法更换模型" }
        else if busy { state.stringValue = "请先停止执行或处理待确认操作" }
        else if let error { state.showSaveFailure(error) }
        else { state.stringValue = rows.isEmpty ? "没有匹配的模型" : "" }
    }

    private func reloadRows(preservingSelection: Bool = false) {
        let previous = preservingSelection ? selectedRow : nil
        let text = query, defaultTitle = "跟随默认"
        let matches = runtime.modelChoices(taskID).filter { text.isEmpty || $0.localizedCaseInsensitiveContains(text) }
        rows = text.isEmpty || defaultTitle.contains(text) ? [Row(title: defaultTitle, model: nil)] : []
        rows += matches.map { Row(title: $0, model: $0) }
        if AgentTaskModels.validID(text), text != defaultTitle, !matches.contains(text) {
            rows.append(Row(title: "使用 ID · " + text, model: text))
        }
        table.reloadData()
        let retained = previous.flatMap { old in rows.firstIndex(where: { $0.model == old.model }) }
        let suggested = text.isEmpty
            ? rows.firstIndex(where: { $0.model == runtime.store.task(taskID)?.modelOverride })
            : matches.contains(text) ? rows.firstIndex(where: { $0.model == text }) : nil
        if !rows.isEmpty { selectRow(retained ?? suggested ?? 0) }
        refreshState()
    }

    private func selectRow(_ index: Int) {
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    @objc private func queryChanged() { reloadRows() }
    func controlTextDidChange(_ obj: Notification) { reloadRows() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { useModel(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { closeAndReturn(); return true }
        let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : selector == #selector(NSResponder.moveUp(_:)) ? -1 : 0
        guard step != 0 else { return false }
        if !rows.isEmpty { selectRow(min(rows.count - 1, max(0, table.selectedRow + step))) }
        return true
    }

    @objc private func refreshModels() {
        guard load == nil else { return }
        error = nil
        load = Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.refreshTaskModels(); try Task.checkCancellation()
                load = nil; reloadRows(preservingSelection: true)
            } catch {
                guard !Task.isCancelled else { return }
                load = nil; self.error = error; refreshState()
            }
        }
        refreshState()
    }

    @objc private func useModel() {
        refreshState()
        guard choose.isEnabled, let selectedRow, popover?.isShown == true else { return }
        do { try runtime.chooseModel(taskID, model: selectedRow.model); closeAndReturn() }
        catch { self.error = error; refreshState() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshState() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let value = rows[row], active = runtime.store.task(taskID)?.modelOverride == value.model
        let cell = NSTableCellView(), label = NSTextField(labelWithString: value.title), check = NSImageView()
        label.font = .systemFont(ofSize: 13, weight: active ? .medium : .regular)
        label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.textField = label; cell.toolTip = value.title
        check.image = active ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "当前选用") : nil
        check.contentTintColor = AgentWorkbenchTheme.accent
        for item in [label, check] { cell.addSubview(item); item.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                     label.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -8),
                                     check.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                     check.widthAnchor.constraint(equalToConstant: 14), check.heightAnchor.constraint(equalToConstant: 14)])
        return cell
    }
}
