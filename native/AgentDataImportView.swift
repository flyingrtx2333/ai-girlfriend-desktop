import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentDataImportView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: AgentStore, service: AgentDataImport
    private let source = NSPopUpButton(), folder = NSButton(), detect = NSButton(title: "重新检测", target: nil, action: nil)
    private let category = NSPopUpButton()
    private let destination = NSPopUpButton()
    private lazy var sourceControl = AgentSettingsPopupFrame(source)
    private lazy var categoryControl = AgentSettingsPopupFrame(category)
    private lazy var destinationControl = AgentSettingsPopupFrame(destination)
    private let table = NSTableView(), detail = NSTextView(), state = NSTextField(labelWithString: ""), selectAll = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    private let begin = AgentDialogButton(title: "开始导入", target: nil, action: nil)
    private let pause = NSButton(title: "暂停", target: nil, action: nil), resume = NSButton(title: "继续导入", target: nil, action: nil), cancel = NSButton(title: "取消导入", target: nil, action: nil)
    private let open = NSButton(title: "打开任务", target: nil, action: nil), original = NSButton(title: "来源副本", target: nil, action: nil)
    private var root: URL, rows: [AgentImportCandidate] = [], selected = Set<String>(), states: [String: String] = [:], signature = ""
    private var targetWorkspace: String?
    private var shownBatch: String?
    private var listHeight: NSLayoutConstraint?
    var onOpen: ((String) -> Void)?
    var onOpenConnector: ((String, String?) throws -> Void)?
    var onOpenAutomation: ((String) throws -> Void)?
    var onOpenPlugin: ((String, String?) throws -> Void)?
    var onOpenConfiguration: ((AgentStandaloneImportPlan, URL) throws -> Void)?
    var onOpenAgent: ((String, String?) throws -> Void)?
    var onOpenHooks: ((URL, String?) throws -> Void)?
    private var selectedSource: AgentImportSource { AgentImportSource.allCases[max(0, source.indexOfSelectedItem)] }
    private var selectedCategory: AgentImportCategory { AgentImportCategory.allCases[max(0, category.indexOfSelectedItem)] }
    private var workspace: String? { selectedCategory.globalTarget == nil ? nil : targetWorkspace }
    init(store: AgentStore) {
        self.store = store; service = store.dataImport
        root = service.batch.map { URL(fileURLWithPath: $0.root) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AgentImportSource.codex.homeName)
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        source.addItems(withTitles: AgentImportSource.allCases.map(\.title)); source.selectItem(at: service.batch.flatMap { AgentImportSource.allCases.firstIndex(of: $0.source) } ?? 0)
        source.target = self; source.action = #selector(changeSource); source.setAccessibilityLabel("导入来源")
        category.addItems(withTitles: AgentImportCategory.allCases.map(\.title))
        category.target = self; category.action = #selector(changeCategory); category.setAccessibilityLabel("导入内容")
        destination.target = self; destination.action = #selector(changeDestination)
        destination.cell?.lineBreakMode = .byTruncatingMiddle
        destinationControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.target = self; folder.action = #selector(chooseFolder); folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); folder.imagePosition = .imageLeading; folder.setAccessibilityLabel("来源目录"); folder.cell?.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detect.target = self; detect.action = #selector(detectRecords)
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
        let kinds = NSStackView(views: [categoryControl, NSView(), destinationControl]); kinds.spacing = 8
        let header = NSStackView(views: [sourceControl, folder, detect]); header.spacing = 8
        let selection = NSStackView(views: [selectAll, NSView(), open, original]); selection.spacing = 8
        let actions = NSStackView(views: [state, NSView(), begin, pause, resume, cancel]); actions.spacing = 6
        for line in [kinds, header, selection, actions] { line.distribution = .fill }
        let column = NSStackView(views: [kinds, header, selection, list, preview, actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        let height = list.heightAnchor.constraint(equalToConstant: 236); listHeight = height
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor), sourceControl.widthAnchor.constraint(equalToConstant: 120), folder.widthAnchor.constraint(greaterThanOrEqualToConstant: 90), height, preview.heightAnchor.constraint(equalToConstant: 142)])
        for view in [kinds, header, selection, list, preview, actions] { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        folder.setContentHuggingPriority(.defaultLow, for: .horizontal); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refresh() {
        let batch = service.batch
        if let batch, shownBatch != batch.id {
            shownBatch = batch.id; root = URL(fileURLWithPath: batch.root); source.selectItem(at: AgentImportSource.allCases.firstIndex(of: batch.source) ?? 0)
            category.selectItem(at: AgentImportCategory.allCases.firstIndex(of: batch.category) ?? 0)
            targetWorkspace = batch.targetWorkspace; signature = ""
        }
        let viewingPreview = service.previewSource == selectedSource && service.previewRoot == root.path
            && service.previewCategory == selectedCategory && service.previewWorkspace == workspace
        let viewingBatch = batch?.source == selectedSource && batch?.root == root.path && batch?.category == selectedCategory && batch?.targetWorkspace == workspace
        rows = viewingPreview ? service.preview : viewingBatch ? batch?.items.map(\.record) ?? [] : []
        states = viewingPreview ? [:] : Dictionary((batch?.items ?? []).map { ($0.id, $0.state == "failed" ? "失败：" + $0.detail : ["pending": "等待导入", "imported": "已导入"][ $0.state ] ?? $0.state) }, uniquingKeysWith: { _, last in last })
        let next = rows.map { $0.id + $0.sourceHash + ($0.issue ?? "") }.joined()
        if signature != next { signature = next; selected = Set(rows.filter { $0.issue == nil && viewingPreview }.map(\.id)) }
        let defaultPath = (root.path as NSString).abbreviatingWithTildeInPath
        folder.title = root.path == defaultRoot(selectedCategory).path || root.lastPathComponent.isEmpty ? defaultPath : root.lastPathComponent
        folder.toolTip = root.path
        source.isEnabled = !service.active && !service.scanning && !service.unfinished; folder.isEnabled = source.isEnabled; detect.isEnabled = source.isEnabled
        category.isEnabled = source.isEnabled
        sourceControl.refreshEnabledState(); categoryControl.refreshEnabledState()
        destinationControl.isHidden = selectedCategory.globalTarget == nil
        if let title = selectedCategory.globalTarget { updateDestinations(globalTitle: title) }
        table.setAccessibilityLabel("可导入" + selectedCategory.title)
        selectAll.isEnabled = viewingPreview && !service.active && !service.scanning && rows.contains { $0.issue == nil }; selectAll.state = selected.isEmpty ? .off : selected.count == rows.filter({ $0.issue == nil }).count ? .on : .mixed
        let previous = table.selectedRow; table.reloadData(); if rows.indices.contains(previous) { table.selectRowIndexes(IndexSet(integer: previous), byExtendingSelection: false) }
        table.enclosingScrollView?.isHidden = rows.isEmpty; selectAll.superview?.isHidden = rows.isEmpty
        listHeight?.constant = CGFloat(min(236, max(48, rows.count * 48)))
        begin.isHidden = !viewingPreview; begin.isEnabled = !selected.isEmpty && !service.scanning && !service.active && !service.unfinished
        pause.isHidden = !service.active; pause.isEnabled = batch?.state == "running"
        resume.isHidden = !service.unfinished || service.active; cancel.isHidden = !service.unfinished && !service.active
        if let issue = service.issue { state.stringValue = issue; state.textColor = .systemRed }
        else {
            state.textColor = AgentWorkbenchTheme.secondaryText
            if service.scanning { state.stringValue = "正在检测…" }
            else if viewingPreview { state.stringValue = rows.isEmpty ? "未找到可导入的" + selectedCategory.title : "可导入\(rows.filter { $0.issue == nil }.count)项 · 跳过\(rows.filter { $0.issue != nil }.count)项" }
            else if let batch, viewingBatch {
                let done = batch.items.filter { $0.state == "imported" }.count, failed = batch.items.filter { $0.state == "failed" }.count
                state.stringValue = ["running": "导入中", "paused": "已暂停", "cancelled": "已取消", "completed": "已完成"][batch.state, default: batch.state] + " · \(done)/\(batch.items.count)" + (failed > 0 ? " · 失败\(failed)" : "")
            } else { state.stringValue = "尚未检测" }
        }
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
        if let workspace = targetWorkspace {
            if let item = destination.itemArray.first(where: { $0.representedObject as? String == workspace }) { destination.select(item) }
            else {
                destination.addItem(withTitle: URL(fileURLWithPath: workspace).lastPathComponent + "（不可用）")
                destination.lastItem?.representedObject = workspace
                destination.select(destination.lastItem)
            }
        } else { destination.selectItem(at: 0) }
        destination.toolTip = targetWorkspace
        destination.isEnabled = source.isEnabled; destinationControl.refreshEnabledState()
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(selectedSource.homeName)
        switch category {
        case .skills: return AgentSkillImport.defaultDirectory(for: selectedSource, home: home)
        case .plugins: return base.appendingPathComponent("plugins", isDirectory: true)
        default: return base
        }
    }
    @objc private func changeSource() { root = defaultRoot(selectedCategory); signature = ""; refresh() }
    @objc private func changeCategory() {
        let file = !selectedCategory.acceptsFiles && (try? root.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        if file || AgentImportCategory.allCases.contains(where: { root.path == defaultRoot($0).path }) { root = defaultRoot(selectedCategory) }
        signature = ""; refresh()
    }
    @objc private func changeDestination() { targetWorkspace = destination.selectedItem?.representedObject as? String; signature = ""; refresh() }
    @objc private func chooseFolder() {
        let canChooseFile = selectedCategory.acceptsFiles
        let panel = NSOpenPanel(); panel.canChooseFiles = canChooseFile; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        if selectedCategory == .plugins { panel.allowedContentTypes = [.zip] }
        else if canChooseFile { panel.allowedContentTypes = [selectedSource == .qoder ? .json : UTType(filenameExtension: "toml") ?? .data] }
        panel.directoryURL = root.hasDirectoryPath ? root : root.deletingLastPathComponent()
        panel.prompt = canChooseFile ? "选择来源" : "选择来源目录"
        guard let window else { return }; panel.beginSheetModal(for: window) { [weak self] response in guard let self, response == .OK, let url = panel.url else { return }; root = url; signature = ""; refresh() }
    }
    @objc private func detectRecords() {
        let source = selectedSource, directory = root, category = selectedCategory, target = workspace
        Task { await service.detect(source, root: directory, category: category, workspace: target) }
    }
    @objc private func toggleRecord(_ sender: NSButton) { guard rows.indices.contains(sender.tag), rows[sender.tag].issue == nil else { return }; let id = rows[sender.tag].id; if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }; refresh() }
    @objc private func toggleAll() {
        let available = Set(rows.filter { $0.issue == nil }.map(\.id))
        selected = selected == available ? [] : available
        refresh()
    }
    @objc private func start() {
        do { try service.begin(selectedSource, root: root, ids: selected, category: selectedCategory, workspace: workspace) }
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
