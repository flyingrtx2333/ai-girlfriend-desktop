import AppKit

@MainActor final class AgentDataImportView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: AgentStore, service: AgentDataImport
    private let source = NSPopUpButton(), folder = NSButton(), detect = NSButton(title: "重新检测", target: nil, action: nil)
    private let table = NSTableView(), detail = NSTextView(), state = NSTextField(labelWithString: ""), selectAll = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    private let begin = NSButton(title: "开始导入", target: nil, action: nil), pause = NSButton(title: "暂停", target: nil, action: nil), resume = NSButton(title: "继续导入", target: nil, action: nil), cancel = NSButton(title: "取消导入", target: nil, action: nil)
    private let open = NSButton(title: "打开任务", target: nil, action: nil), original = NSButton(title: "来源副本", target: nil, action: nil)
    private var root: URL, rows: [AgentImportCandidate] = [], selected = Set<String>(), states: [String: String] = [:], signature = ""
    private var shownBatch: String?
    var onOpen: ((String) -> Void)?
    private var selectedSource: AgentImportSource { AgentImportSource.allCases[max(0, source.indexOfSelectedItem)] }
    init(store: AgentStore) {
        self.store = store; service = store.dataImport
        root = service.batch.map { URL(fileURLWithPath: $0.root) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AgentImportSource.codex.homeName)
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        source.addItems(withTitles: AgentImportSource.allCases.map(\.title)); source.selectItem(at: service.batch.flatMap { AgentImportSource.allCases.firstIndex(of: $0.source) } ?? 0)
        source.target = self; source.action = #selector(changeSource); source.setAccessibilityLabel("导入来源")
        folder.target = self; folder.action = #selector(chooseFolder); folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); folder.imagePosition = .imageLeading; folder.setAccessibilityLabel("来源目录"); folder.cell?.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detect.target = self; detect.action = #selector(detectRecords)
        selectAll.target = self; selectAll.action = #selector(toggleAll)
        let check = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check")); check.width = 28; check.minWidth = 28; check.maxWidth = 28; table.addTableColumn(check)
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "任务记录"; table.addTableColumn(name)
        table.headerView = nil; table.rowHeight = 48; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("可导入任务")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        detail.isEditable = false; detail.isRichText = false; detail.font = .systemFont(ofSize: 12); detail.textContainerInset = NSSize(width: 8, height: 8); detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]; detail.textContainer?.widthTracksTextView = true; detail.setAccessibilityLabel("导入预览")
        let preview = NSScrollView(); preview.documentView = detail; preview.hasVerticalScroller = true
        state.font = .systemFont(ofSize: 12); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byWordWrapping; state.maximumNumberOfLines = 3
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(begin, #selector(start)), (pause, #selector(pauseImport)), (resume, #selector(resumeImport)), (cancel, #selector(cancelImport)), (open, #selector(openTask)), (original, #selector(showOriginal))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        let header = NSStackView(views: [source, folder, detect]); header.spacing = 8
        let selection = NSStackView(views: [selectAll, NSView(), open, original]); selection.spacing = 8
        let actions = NSStackView(views: [state, NSView(), begin, pause, resume, cancel]); actions.spacing = 6
        for line in [header, selection, actions] { line.distribution = .fill }
        let column = NSStackView(views: [header, selection, list, preview, actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor), source.widthAnchor.constraint(equalToConstant: 96), folder.widthAnchor.constraint(greaterThanOrEqualToConstant: 90), list.heightAnchor.constraint(equalToConstant: 236), preview.heightAnchor.constraint(equalToConstant: 142)])
        for view in [header, selection, list, preview, actions] { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        folder.setContentHuggingPriority(.defaultLow, for: .horizontal); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refresh() {
        let batch = service.batch
        if let batch, shownBatch != batch.id { shownBatch = batch.id; root = URL(fileURLWithPath: batch.root); source.selectItem(at: AgentImportSource.allCases.firstIndex(of: batch.source) ?? 0); signature = "" }
        let viewingPreview = service.previewSource == selectedSource && service.previewRoot == root.path
        rows = viewingPreview ? service.preview : batch?.source == selectedSource && batch?.root == root.path ? batch!.items.map(\.record) : []
        states = viewingPreview ? [:] : Dictionary((batch?.items ?? []).map { ($0.id, $0.state == "failed" ? "失败：" + $0.detail : ["pending": "等待导入", "imported": "已导入"][ $0.state ] ?? $0.state) }, uniquingKeysWith: { _, last in last })
        let next = rows.map { $0.id + $0.sourceHash + ($0.issue ?? "") }.joined()
        if signature != next { signature = next; selected = Set(rows.filter { $0.issue == nil && viewingPreview }.map(\.id)) }
        folder.title = (root.path as NSString).abbreviatingWithTildeInPath; folder.toolTip = root.path
        source.isEnabled = !service.active && !service.scanning && !service.unfinished; folder.isEnabled = source.isEnabled; detect.isEnabled = source.isEnabled
        selectAll.isEnabled = viewingPreview && !service.active && !service.scanning && rows.contains { $0.issue == nil }; selectAll.state = selected.isEmpty ? .off : selected.count == rows.filter({ $0.issue == nil }).count ? .on : .mixed
        let previous = table.selectedRow; table.reloadData(); if rows.indices.contains(previous) { table.selectRowIndexes(IndexSet(integer: previous), byExtendingSelection: false) }
        begin.isHidden = !viewingPreview; begin.isEnabled = !selected.isEmpty && !service.scanning && !service.active && !service.unfinished
        pause.isHidden = !service.active; pause.isEnabled = batch?.state == "running"
        resume.isHidden = !service.unfinished || service.active; cancel.isHidden = !service.unfinished && !service.active
        if let issue = service.issue { state.stringValue = issue; state.textColor = .systemRed }
        else {
            state.textColor = AgentWorkbenchTheme.secondaryText
            if service.scanning { state.stringValue = "正在检测…" }
            else if viewingPreview { state.stringValue = "可导入\(rows.filter { $0.issue == nil }.count)项 · 跳过\(rows.filter { $0.issue != nil }.count)项" }
            else if let batch, batch.source == selectedSource, batch.root == root.path {
                let done = batch.items.filter { $0.state == "imported" }.count, failed = batch.items.filter { $0.state == "failed" }.count
                state.stringValue = ["running": "导入中", "paused": "已暂停", "cancelled": "已取消", "completed": "已完成"][batch.state, default: batch.state] + " · \(done)/\(batch.items.count)" + (failed > 0 ? " · 失败\(failed)" : "")
            } else { state.stringValue = "尚未检测" }
        }
        updateDetail()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let value = rows[row]
        if column?.identifier.rawValue == "check" {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRecord(_:))); box.tag = row; box.state = selected.contains(value.id) ? .on : .off; box.isEnabled = selectAll.isEnabled && value.issue == nil; box.setAccessibilityLabel("导入：" + value.title); return box
        }
        let title = NSTextField(labelWithString: value.title), status = NSTextField(labelWithString: value.issue ?? states[value.id] ?? (value.archived ? "已归档" : value.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "无工作目录"))
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail; status.font = .systemFont(ofSize: 11); status.textColor = value.issue == nil ? AgentWorkbenchTheme.secondaryText : .tertiaryLabelColor; status.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, status]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4; stack.toolTip = value.file; return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }
    private func updateDetail() {
        guard rows.indices.contains(table.selectedRow) else { detail.string = ""; open.isEnabled = false; original.isEnabled = false; return }
        let record = rows[table.selectedRow]
        detail.string = record.title + "\n" + (record.workspace ?? "无工作目录") + "\n" + record.warnings.joined(separator: "\n") + (record.issue.map { "\n" + $0 } ?? states[record.id].map { "\n" + $0 } ?? "") + "\n\n" + record.preview
        open.isEnabled = store.task(record.targetID) != nil; original.isEnabled = store.task(record.targetID)?.importOrigin != nil
    }
    @objc private func changeSource() { root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(selectedSource.homeName); signature = ""; refresh() }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true; panel.directoryURL = root; panel.prompt = "选择来源目录"
        guard let window else { return }; panel.beginSheetModal(for: window) { [weak self] response in guard let self, response == .OK, let url = panel.url else { return }; root = url; signature = ""; refresh() }
    }
    @objc private func detectRecords() { let source = selectedSource, directory = root; Task { await service.detect(source, root: directory) } }
    @objc private func toggleRecord(_ sender: NSButton) { guard rows.indices.contains(sender.tag), rows[sender.tag].issue == nil else { return }; let id = rows[sender.tag].id; if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }; refresh() }
    @objc private func toggleAll() { selected = selectAll.state == .on ? Set(rows.filter { $0.issue == nil }.map(\.id)) : []; refresh() }
    @objc private func start() { do { try service.begin(selectedSource, root: root, ids: selected) } catch { state.stringValue = error.localizedDescription; state.textColor = .systemRed } }
    @objc private func pauseImport() { service.pause() }
    @objc private func resumeImport() { service.resume() }
    @objc private func cancelImport() { service.cancel() }
    @objc private func openTask() { guard rows.indices.contains(table.selectedRow) else { return }; onOpen?(rows[table.selectedRow].targetID) }
    @objc private func showOriginal() { guard rows.indices.contains(table.selectedRow) else { return }; do { NSWorkspace.shared.activateFileViewerSelecting([try service.sourceURL(rows[table.selectedRow].targetID)]) } catch { state.stringValue = error.localizedDescription; state.textColor = .systemRed } }
}
