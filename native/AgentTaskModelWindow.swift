import AppKit

@MainActor final class AgentTaskModelWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let runtime: AgentRuntime, taskID: String
    private let search = NSSearchField(), table = NSTableView(), state = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "刷新列表", target: nil, action: nil), choose = NSButton(title: "使用模型", target: nil, action: nil)
    private var rows: [(title: String, model: String?)] = []
    private var load: Task<Void, Never>?
    private var loading = false
    init(runtime: AgentRuntime, taskID: String) {
        self.runtime = runtime; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 510), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "任务模型"; window.minSize = NSSize(width: 440, height: 360); window.center(); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        super.init(window: window)
        let content = NSView(); window.contentView = content
        search.placeholderString = "搜索或输入模型 ID"; search.delegate = self; search.setAccessibilityLabel("搜索或输入模型 ID")
        refreshButton.target = self; refreshButton.action = #selector(refreshModels)
        choose.target = self; choose.action = #selector(useModel); choose.keyEquivalent = "\r"
        table.addTableColumn(NSTableColumn(identifier: .init("model"))); table.headerView = nil; table.rowHeight = 36
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(useModel); table.setAccessibilityLabel("任务可选模型")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail; state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [search, refreshButton]); top.spacing = 10
        let footer = NSStackView(views: [state, NSView(), choose]); footer.spacing = 10
        for view in [top, list, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), top.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), list.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14), list.leadingAnchor.constraint(equalTo: top.leadingAnchor), list.trailingAnchor.constraint(equalTo: top.trailingAnchor), list.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14), footer.leadingAnchor.constraint(equalTo: top.leadingAnchor), footer.trailingAnchor.constraint(equalTo: top.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)])
        updateRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func controlTextDidChange(_ obj: Notification) { updateRows() }
    func refreshState() {
        let task = runtime.store.task(taskID)
        choose.isEnabled = !loading && !runtime.isBusy(taskID) && task?.archived == false && task?.pendingCalls.isEmpty == true && rows.indices.contains(table.selectedRow)
        refreshButton.isEnabled = !loading
        if runtime.isBusy(taskID) { state.stringValue = "请先停止执行" }
    }
    private func updateRows() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = [("跟随默认", nil)] + runtime.modelChoices(taskID).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.map { ($0, Optional($0)) }
        if !query.isEmpty, AgentTaskModels.validID(query), !rows.contains(where: { $0.model == query }) { rows.append(("使用 ID：" + query, query)) }
        table.reloadData()
        let selected = runtime.store.task(taskID)?.modelOverride
        table.selectRowIndexes(IndexSet(integer: rows.firstIndex(where: { $0.model == selected }) ?? 0), byExtendingSelection: false)
        state.stringValue = loading ? "正在读取服务模型列表…" : ""
        refreshState()
    }
    @objc private func refreshModels() {
        guard !loading else { return }; loading = true; updateRows()
        load = Task { [weak self] in
            guard let self else { return }
            do { try await runtime.refreshTaskModels(); loading = false; updateRows() }
            catch { loading = false; updateRows(); state.stringValue = error.localizedDescription; state.toolTip = error.localizedDescription }
        }
    }
    @objc private func useModel() {
        guard rows.indices.contains(table.selectedRow), !loading else { return }
        do { try runtime.chooseModel(taskID, model: rows[table.selectedRow].model); window?.performClose(nil) }
        catch { state.stringValue = error.localizedDescription; state.toolTip = error.localizedDescription }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshState() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let chosen = runtime.store.task(taskID)?.modelOverride == rows[row].model
        let label = NSTextField(labelWithString: (chosen ? "✓  " : "    ") + rows[row].title)
        label.font = .systemFont(ofSize: 13, weight: chosen ? .medium : .regular); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = rows[row].title
        return label
    }
}
