import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentKnowledgeLibraryWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let store: AgentStore, taskID: String?
    private let bases = NSTableView(), files = NSTableView(), baseSearch = NSSearchField(), fileSearch = NSSearchField()
    private let scope = NSPopUpButton(), archived = NSButton(checkboxWithTitle: "显示已移除", target: nil, action: nil)
    private let heading = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: ""), provenance = NSTextField(labelWithString: "")
    private let preview = NSTextView(), part = NSTextField(string: "1"), total = NSTextField(labelWithString: "")
    private let format = NSSegmentedControl(labels: ["预览", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let create = NSButton(title: "新建知识库", target: nil, action: nil), rename = NSButton(title: "重命名", target: nil, action: nil), removeBase = NSButton(title: "移除", target: nil, action: nil)
    private let add = NSButton(title: "添加文件", target: nil, action: nil), replace = NSButton(title: "替换", target: nil, action: nil), removeFile = NSButton(title: "移除文件", target: nil, action: nil)
    private let download = NSButton(title: "下载文件", target: nil, action: nil), open = NSButton(title: "打开原文件", target: nil, action: nil), copy = NSButton(title: "复制文字", target: nil, action: nil)
    private var catalog = AgentKnowledgeCatalog(), revision = "", baseRows: [AgentKnowledgeBase] = [], fileRows: [AgentKnowledgeSource] = []
    private var baseID: String?, sourceID: String?, selectedText = "", job: Task<Void, Never>?, previewJob: Task<Void, Never>?, busy = false
    private enum Page { case bases, files, document, name }
    private var page = Page.bases, editingBaseID: String?, editingWorkspace: String?, editingBaseWorkspace: String?, editingRevision: String?, nameChanged = false
    private var nameSelection: AgentTextViewport.Selection?, nameFocus = "", pendingRecovery: RecoveryState?, applyingRecovery = false, recoveryScheduled = false
    var onWorkspaceChange: (() -> Void)?
    var boundTaskID: String? { taskID }
    var hasPendingChanges: Bool { nameChanged || busy }
    var canPreserveForQuit: Bool { page == .name && !busy && (taskID == nil || taskID.flatMap(store.task).map { $0.sideTask?.retained != false } == true) }
    private let back = NSButton(title: "返回", target: nil, action: nil), baseName = AgentDialogTextField(frame: .zero), baseScope = NSPopUpButton()
    private let nameForm = NSStackView(), saveName = NSButton(title: "保存", target: nil, action: nil)
    private let baseList = NSScrollView(), fileList = NSScrollView(), viewer = NSScrollView(), body = NSView()
    private var navigation: NSStackView!, header: NSStackView!, fileHeader: NSStackView!, previewHeader: NSStackView!, previewFooter: NSStackView!, baseFooter: NSStackView!
    init(store: AgentStore, taskID: String?) {
        self.store = store; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "知识库"; window.minSize = NSSize(width: 900, height: 560); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        baseSearch.placeholderString = "搜索知识库"; fileSearch.placeholderString = "搜索文件"
        for field in [baseSearch, fileSearch] { field.target = self; field.action = #selector(filterChanged); field.sendsSearchStringImmediately = true }
        scope.addItems(withTitles: ["全部范围", "用户", "当前工作区"]); scope.target = self; scope.action = #selector(filterChanged); scope.setAccessibilityLabel("知识库范围")
        scope.autoenablesItems = false; scope.item(at: 2)?.isEnabled = workspace != nil
        archived.target = self; archived.action = #selector(filterChanged)
        for (table, scroll, label) in [(bases, baseList, "知识库列表"), (files, fileList, "知识文件列表")] {
            table.addTableColumn(NSTableColumn(identifier: .init("name"))); table.headerView = nil; table.rowHeight = 48; table.style = .inset; table.backgroundColor = .clear
            table.dataSource = self; table.delegate = self; table.setAccessibilityLabel(label)
            scroll.documentView = table; scroll.hasVerticalScroller = true
        }
        files.target = self; files.action = #selector(openSelectedFile)
        heading.font = .systemFont(ofSize: 17, weight: .semibold); heading.lineBreakMode = .byTruncatingMiddle; heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        back.target = self; back.action = #selector(goBack); back.isBordered = false; back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil); back.imagePosition = .imageLeading
        back.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true; back.cell?.lineBreakMode = .byTruncatingTail; back.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        navigation = row([back, heading, NSView()])
        preview.isEditable = false; preview.isRichText = true; preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.textContainerInset = NSSize(width: 14, height: 14); preview.drawsBackground = false; preview.setAccessibilityLabel("知识文件预览")
        viewer.documentView = preview; viewer.hasVerticalScroller = true
        for scroll in [baseList, fileList, viewer] { scroll.drawsBackground = false; scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder }
        for label in [state, provenance, total] { label.font = .systemFont(ofSize: 11); label.textColor = AgentWorkbenchTheme.secondaryText; label.lineBreakMode = .byTruncatingMiddle }
        part.setAccessibilityLabel("知识文件部分"); part.alignment = .right; part.target = self; part.action = #selector(loadPreview); part.widthAnchor.constraint(equalToConstant: 46).isActive = true
        format.selectedSegment = 0; format.target = self; format.action = #selector(renderPreview)
        for (button, action) in [(create, #selector(newBase)), (rename, #selector(renameBase)), (removeBase, #selector(archiveBase)), (add, #selector(addFiles)), (replace, #selector(replaceFile)), (removeFile, #selector(archiveFile)), (download, #selector(downloadFile)), (open, #selector(openFile)), (copy, #selector(copyText))] { button.target = self; button.action = action }
        header = row([baseSearch, scope, archived, create]); baseFooter = row([NSView(), rename, removeBase])
        fileHeader = row([fileSearch, add, replace, removeFile]); previewHeader = row([format, NSView(), NSTextField(labelWithString: "部分"), part, total, copy])
        previewFooter = row([NSView(), open, download])
        baseName.placeholderString = "知识库名称"; baseName.setAccessibilityLabel("知识库名称"); baseName.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(nameSelectionChanged), name: NSTextView.didChangeSelectionNotification, object: nil)
        baseScope.addItems(withTitles: ["用户", "当前工作区"]); baseScope.setAccessibilityLabel("知识库生效范围"); baseScope.autoenablesItems = false; baseScope.item(at: 1)?.isEnabled = workspace != nil
        baseScope.target = self; baseScope.action = #selector(nameScopeChanged)
        saveName.target = self; saveName.action = #selector(saveBaseName); saveName.keyEquivalent = "s"; saveName.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelBaseName))
        nameForm.orientation = .vertical; nameForm.alignment = .leading; nameForm.spacing = 16
        for view in [NSTextField(labelWithString: "名称"), baseName, NSTextField(labelWithString: "范围"), baseScope, row([NSView(), cancel, saveName])] { nameForm.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: nameForm.widthAnchor).isActive = true }
        for view in [baseList, fileList, viewer, nameForm] { body.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [baseList, fileList, viewer] { NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: body.leadingAnchor), view.trailingAnchor.constraint(equalTo: body.trailingAnchor), view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor)]) }
        NSLayoutConstraint.activate([nameForm.leadingAnchor.constraint(equalTo: body.leadingAnchor), nameForm.trailingAnchor.constraint(equalTo: body.trailingAnchor), nameForm.topAnchor.constraint(equalTo: body.topAnchor)])
        let column = NSStackView(views: [navigation, header, fileHeader, previewHeader, body, baseFooter, previewFooter, state]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 14
        content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for child in column.arrangedSubviews { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor), column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var workspace: String? { taskID.flatMap(store.task)?.workspace.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path } }
    private var selectedBase: AgentKnowledgeBase? { baseRows.first { $0.id == baseID } }
    private var selectedSource: AgentKnowledgeSource? { fileRows.first { $0.id == sourceID } }
    private func row(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.spacing = 7; row.orientation = .horizontal; return row }
    override func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { AgentSettingsTableRow() }
    private func updatePage() {
        navigation.isHidden = page == .bases; header.isHidden = page != .bases; baseFooter.isHidden = page != .files
        fileHeader.isHidden = page != .files && page != .document; fileSearch.isHidden = page == .document; previewHeader.isHidden = page != .document; previewFooter.isHidden = page != .document
        baseList.isHidden = page != .bases; fileList.isHidden = page != .files; viewer.isHidden = page != .document; nameForm.isHidden = page != .name
        if page == .document { heading.stringValue = selectedSource?.file.name ?? "文件"; back.title = selectedBase?.name ?? "返回文件" }
        else if page == .name { heading.stringValue = editingBaseID == nil ? "新建知识库" : "重命名知识库"; back.title = "返回知识库" }
        else { heading.stringValue = selectedBase.map { $0.name + " · " + ($0.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "用户") } ?? "知识库"; back.title = "全部知识库" }
        presentingWindow?.recalculateKeyViewLoop()
    }
    @objc private func goBack() { guard confirmName() else { return }; previewJob?.cancel(); if page == .document { sourceID = nil; page = .files } else { page = .bases }; reload() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmName() }
    private func confirmName() -> Bool {
        guard page == .name, nameChanged else { return true }
        guard AgentUnsavedChanges.discard("放弃未保存的知识库名称？") else { return false }; nameChanged = false; pendingRecovery = nil; page = .bases; updatePage(); onWorkspaceChange?(); return true
    }
    func controlTextDidChange(_ notification: Notification) { if notification.object as? NSTextField === baseName, !applyingRecovery { nameChanged = true; pendingRecovery = nil; rememberNameSelection(); onWorkspaceChange?() } }
    @objc private func nameScopeChanged() { nameChanged = true; pendingRecovery = nil; nameFocus = "scope"; onWorkspaceChange?() }
    @objc private func nameSelectionChanged(_ notification: Notification) {
        guard !applyingRecovery, page == .name, let editor = baseName.currentEditor() as? NSTextView, notification.object as? NSTextView === editor else { return }
        rememberNameSelection(); onWorkspaceChange?()
    }
    private func rememberNameSelection() {
        if let editor = baseName.currentEditor() as? NSTextView, presentingWindow?.firstResponder === editor {
            let range = editor.selectedRange(); nameSelection = .init(location: range.location, length: range.length); nameFocus = "name"
        } else if presentingWindow?.firstResponder === baseScope { nameFocus = "scope" }
    }
    func prepareWorkspaceNavigation() -> Bool { !busy && presentingWindow?.hasBlockingDialog != true }
    func windowWillClose(_ notification: Notification) { job?.cancel(); previewJob?.cancel() }
    @objc private func filterChanged() { reload() }
    func checkState() -> [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled else { return [:] }
        return ["page": String(describing: page), "bases": baseRows.map { ["id": $0.id, "name": $0.name, "archived": $0.archived] as [String: Any] }, "files": fileRows.map { ["id": $0.id, "name": $0.file.name, "hash": $0.file.sha256, "archived": $0.archived] as [String: Any] }, "baseID": baseID ?? "", "sourceID": sourceID ?? "", "preview": selectedText, "name": baseName.stringValue, "dirty": nameChanged, "state": state.stringValue, "busy": busy]
    }
    func checkSelect(base id: String, source: String? = nil) async -> Bool {
        guard CommandLine.arguments.contains("--knowledge-page-check") else { return false }; reload()
        guard let row = baseRows.firstIndex(where: { $0.id == id }) else { return false }
        bases.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: bases))
        if let source {
            guard let row = fileRows.firstIndex(where: { $0.id == source }) else { return false }
            files.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); await previewJob?.value
        }
        return source == nil ? page == .files : page == .document && !selectedText.isEmpty
    }
    func checkGoBack() { if CommandLine.arguments.contains("--knowledge-page-check") { goBack() } }
    func checkOpenAlreadySelectedSource() async -> Bool {
        guard CommandLine.arguments.contains("--knowledge-page-check"), sourceID != nil else { return false }
        page = .files; reloadFiles()
        guard files.selectedRow >= 0, let action = files.action, NSApp.sendAction(action, to: files.target, from: files) else { return false }
        await previewJob?.value; return page == .document && !selectedText.isEmpty
    }
    func checkNameOperations() throws -> [String: Bool] {
        guard CommandLine.arguments.contains("--knowledge-page-check") else { return [:] }
        var checks: [String: Bool] = [:]
        newBase(); baseName.stringValue = "页内创建的资料"; nameChanged = true; baseScope.selectItem(at: 0); saveBaseName()
        guard let created = selectedBase else { throw PetError("页内创建未保存") }
        checks["inlineLibraryCreationUsesRealCatalog"] = page == .files && created.name == "页内创建的资料" && !nameChanged
        renameBase(); baseName.stringValue = "页内重命名的资料"; nameChanged = true; saveBaseName()
        checks["inlineRenamePersistsWithoutFormModal"] = try store.knowledge.document().0.bases.first(where: { $0.id == created.id })?.name == "页内重命名的资料" && page == .files
        renameBase(); baseName.stringValue = "应当保留的冲突草稿"; nameChanged = true
        _ = try store.knowledge.create(name: "另一次实际目录变更", workspace: nil); saveBaseName()
        checks["staleRenameKeepsDraftAndCurrentCatalog"] = try page == .name && nameChanged && baseName.stringValue == "应当保留的冲突草稿" && store.knowledge.document().0.bases.first(where: { $0.id == created.id })?.name == "页内重命名的资料"
        cancelBaseName(); reload(); archiveBase()
        checks["softRemovedLibraryRetainsOriginalEntry"] = try store.knowledge.document().0.bases.first(where: { $0.id == created.id })?.archived == true
        archived.state = .on; reload(); baseID = created.id; reloadFiles(); archiveBase()
        checks["restoredLibraryKeepsIdentityAndName"] = try store.knowledge.document().0.bases.first(where: { $0.id == created.id }).map { !$0.archived && $0.name == "页内重命名的资料" } == true
        archived.state = .off; page = .bases; reload(); return checks
    }
    private func reload() {
        do {
            (catalog, revision) = try store.knowledge.document()
            baseRows = catalog.bases.filter { base in
                (archived.state == .on || !base.archived) && (baseSearch.stringValue.isEmpty || base.name.localizedCaseInsensitiveContains(baseSearch.stringValue)) &&
                (scope.indexOfSelectedItem == 0 || scope.indexOfSelectedItem == 1 && base.workspace == nil || scope.indexOfSelectedItem == 2 && base.workspace == workspace)
            }
            if !baseRows.contains(where: { $0.id == baseID }) { baseID = baseRows.first?.id }
            bases.delegate = nil; bases.reloadData(); bases.deselectAll(nil)
            if let i = baseRows.firstIndex(where: { $0.id == baseID }) { bases.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }; bases.delegate = self
            if page == .bases { bases.delegate = nil; bases.deselectAll(nil); bases.delegate = self }
            reloadFiles()
            state.stringValue = "\(baseRows.count) 个知识库"
            updatePage()
        } catch { state.stringValue = error.localizedDescription; setBusy(false) }
    }
    private func reloadFiles() {
        fileRows = catalog.sources.filter { $0.baseID == baseID && (archived.state == .on || !$0.archived) && (fileSearch.stringValue.isEmpty || $0.file.name.localizedCaseInsensitiveContains(fileSearch.stringValue)) }
        if !fileRows.contains(where: { $0.id == sourceID }) { sourceID = nil; if page == .document { page = .files } }
        files.delegate = nil; files.reloadData(); files.deselectAll(nil)
        if let i = fileRows.firstIndex(where: { $0.id == sourceID }) { files.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }; files.delegate = self
        heading.stringValue = selectedBase.map { $0.name + " · " + ($0.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "用户") + ($0.archived ? " · 已移除" : "") } ?? "知识库"
        heading.toolTip = selectedBase?.workspace
        part.stringValue = "1"; setBusy(busy); if page == .document { loadPreview() }; updatePage()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === bases ? baseRows.count : fileRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title: String, detail: String
        if tableView === bases { let value = baseRows[row]; title = value.name; detail = (value.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "用户") + (value.archived ? " · 已移除" : "") }
        else { let value = fileRows[row]; title = value.file.name; detail = ByteCountFormatter.string(fromByteCount: Int64(value.file.bytes), countStyle: .file) + (value.archived ? " · 已移除" : "") }
        let name = NSTextField(labelWithString: title), metadata = NSTextField(labelWithString: detail)
        name.font = .systemFont(ofSize: 13, weight: .medium); metadata.font = .systemFont(ofSize: 11); metadata.textColor = AgentWorkbenchTheme.secondaryText
        for label in [name, metadata] { label.lineBreakMode = .byTruncatingMiddle }
        let cell = NSStackView(views: [name, metadata]); cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 3; cell.setAccessibilityLabel(title + "，" + detail); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === bases {
            guard baseRows.indices.contains(bases.selectedRow) else { return }; baseID = baseRows[bases.selectedRow].id; sourceID = nil; page = .files; reloadFiles()
        } else { openSelectedFile() }
    }
    @objc private func openSelectedFile() {
        guard page == .files, fileRows.indices.contains(files.selectedRow) else { return }
        sourceID = fileRows[files.selectedRow].id; page = .document; part.stringValue = "1"; setBusy(busy); updatePage(); loadPreview()
    }
    private func setBusy(_ value: Bool) {
        busy = value
        for control in [create, rename, removeBase, add, replace, removeFile, download, open, copy] { control.isEnabled = !value }
        bases.isEnabled = !value; files.isEnabled = !value
        rename.isEnabled = !value && selectedBase != nil; removeBase.isEnabled = rename.isEnabled
        removeBase.title = selectedBase?.archived == true ? "恢复" : "移除"
        add.isEnabled = !value && selectedBase?.archived == false
        replace.isEnabled = add.isEnabled && selectedSource?.archived == false
        removeFile.isEnabled = add.isEnabled && selectedSource != nil; removeFile.title = selectedSource?.archived == true ? "恢复文件" : "移除文件"
        download.isEnabled = !value && selectedSource != nil; open.isEnabled = download.isEnabled; copy.isEnabled = download.isEnabled
    }
    @objc private func loadPreview() {
        previewJob?.cancel(); selectedText = ""; preview.string = ""; provenance.stringValue = ""; total.stringValue = ""
        guard let source = selectedSource else { return }
        total.stringValue = "/ \(source.file.totalParts)"
        previewJob = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await store.knowledge.part(source, number: part.integerValue)
                try Task.checkCancellation(); guard sourceID == source.id else { return }
                selectedText = value.text; renderPreview()
                provenance.stringValue = "SHA256 " + source.file.sha256; provenance.toolTip = source.file.sha256
                let notes = (source.file.notes ?? []) + (source.file.partial || value.partial ? ["仅显示已提取范围"] : []) + (value.ocr == true ? ["本机OCR"] : [])
                state.stringValue = notes.isEmpty ? source.file.name : source.file.name + " · " + notes.joined(separator: "；")
            } catch { if !Task.isCancelled { preview.string = error.localizedDescription } }
        }
    }
    @objc private func renderPreview() {
        if format.selectedSegment == 0, selectedSource?.file.fileExtension == "md" {
            let style = NSMutableParagraphStyle(); style.paragraphSpacing = 7
            preview.textStorage?.setAttributedString(NativeMarkdown.render(selectedText, font: .systemFont(ofSize: 13), color: .labelColor, paragraph: style))
        } else { preview.textStorage?.setAttributedString(NSAttributedString(string: selectedText, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])) }
    }
    private func editBaseName(_ base: AgentKnowledgeBase?) {
        editingBaseID = base?.id; editingWorkspace = workspace; editingBaseWorkspace = base?.workspace; editingRevision = revision
        baseName.stringValue = base?.name ?? ""; baseScope.selectItem(at: base?.workspace == nil ? 0 : 1); baseScope.isEnabled = base == nil; baseScope.item(at: 1)?.isEnabled = workspace != nil; nameChanged = false
        pendingRecovery = nil; nameSelection = nil; nameFocus = "name"; page = .name; updatePage(); presentingWindow?.makeFirstResponder(baseName); onWorkspaceChange?()
    }
    @objc private func newBase() { editBaseName(nil) }
    @objc private func renameBase() { if let base = selectedBase { editBaseName(base) } }
    @objc private func cancelBaseName() { nameChanged = false; pendingRecovery = nil; page = editingBaseID == nil ? .bases : .files; reload(); onWorkspaceChange?() }
    @objc private func saveBaseName() {
        do {
            if let editingBaseID { try store.knowledge.rename(editingBaseID, name: baseName.stringValue, expected: editingRevision ?? revision); baseID = editingBaseID }
            else {
                if baseScope.indexOfSelectedItem == 1 { guard editingWorkspace != nil, workspace == editingWorkspace else { throw PetError("工作区已变化，名称草稿已保留；请返回后重新选择范围") } }
                let base = try store.knowledge.create(name: baseName.stringValue, workspace: baseScope.indexOfSelectedItem == 1 ? editingWorkspace : nil); baseID = base.id; sourceID = nil; archived.state = .off; baseSearch.stringValue = ""; scope.selectItem(at: 0)
            }
            nameChanged = false; pendingRecovery = nil; page = .files; reload(); state.stringValue = "已保存"
        } catch { state.stringValue = error.localizedDescription }
        onWorkspaceChange?()
    }
    struct RecoveryState: Codable {
        var version = 1
        var taskID: String?, openedWorkspace: String?, destinationWorkspace: String?, editingBaseID: String?, editingRevision: String
        var baseID: String?, sourceID: String?, name: String, project: Bool, baseQuery: String, fileQuery: String, filter: Int, archived: Bool
        var selection: AgentTextViewport.Selection?, focus: String, status: String, baseY: Double, fileY: Double
        var valid: Bool {
            let paths = [openedWorkspace, destinationWorkspace].compactMap { $0 }
            let ids = [taskID, editingBaseID, baseID, sourceID].compactMap { $0 }
            return version == 1 && ids.allSatisfy { UUID(uuidString: $0) != nil } && paths.allSatisfy { $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 8192 && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 } &&
                (taskID != nil || openedWorkspace == nil) && project == (destinationWorkspace != nil) && (editingBaseID != nil || !project || destinationWorkspace == openedWorkspace) &&
                (editingBaseID == nil || editingBaseID == baseID) && editingRevision.utf8.count <= 4096 && !editingRevision.contains("\0") && name.utf8.count <= 20_000_000 &&
                [baseQuery, fileQuery, status].allSatisfy { $0.utf8.count <= 100_000 } && (0...2).contains(filter) && ["", "name", "scope"].contains(focus) &&
                (selection?.valid(in: (name as NSString).length) ?? true) && [baseY, fileY].allSatisfy { $0.isFinite && (0...1_000_000_000).contains($0) }
        }
        static func decode(_ data: Data) throws -> Self {
            guard data.count <= 20_000_000, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys).isSubset(of: ["version", "taskID", "openedWorkspace", "destinationWorkspace", "editingBaseID", "editingRevision", "baseID", "sourceID", "name", "project", "baseQuery", "fileQuery", "filter", "archived", "selection", "focus", "status", "baseY", "fileY"]) else { throw PetError("知识库命名恢复格式不受支持，原记录已保留") }
            if let selection = raw["selection"], !(selection is NSNull) { guard let selection = selection as? [String: Any], Set(selection.keys).isSubset(of: ["location", "length"]) else { throw PetError("知识库名称选区无效") } }
            let value = try JSONDecoder().decode(Self.self, from: data); guard value.valid else { throw PetError("知识库命名范围或内容无效，原记录已保留") }; return value
        }
    }
    func captureWorkspaceRecovery() throws -> AgentWorkspaceRecovery.KnowledgeLibrary? {
        guard page == .name else { return nil }; guard prepareWorkspaceNavigation() else { throw PetError("请先完成当前知识库操作") }
        if pendingRecovery == nil { rememberNameSelection() }
        let destination = baseScope.indexOfSelectedItem == 1 ? (editingBaseID == nil ? editingWorkspace : editingBaseWorkspace) : nil
        let value = pendingRecovery ?? RecoveryState(taskID: taskID, openedWorkspace: editingWorkspace, destinationWorkspace: destination, editingBaseID: editingBaseID, editingRevision: editingRevision ?? revision, baseID: baseID, sourceID: sourceID, name: baseName.stringValue, project: baseScope.indexOfSelectedItem == 1, baseQuery: baseSearch.stringValue, fileQuery: fileSearch.stringValue, filter: scope.indexOfSelectedItem, archived: archived.state == .on, selection: nameSelection, focus: nameFocus, status: state.stringValue, baseY: max(0, baseList.contentView.bounds.minY), fileY: max(0, fileList.contentView.bounds.minY))
        guard value.valid else { throw PetError("知识库命名草稿或范围无效，原记录已保留") }
        let data = try JSONEncoder().encode(value); guard data.count <= 20_000_000 else { throw PetError("知识库命名草稿过大，原记录已保留") }
        return .init(state: data, dirty: nameChanged)
    }
    func restoreWorkspaceRecovery(_ envelope: AgentWorkspaceRecovery.KnowledgeLibrary) throws {
        let value = try RecoveryState.decode(envelope.state); guard value.taskID == taskID else { throw PetError("知识库命名所属任务已变化，原记录已保留") }
        page = .name; baseSearch.stringValue = value.baseQuery; fileSearch.stringValue = value.fileQuery; scope.selectItem(at: value.filter); archived.state = value.archived ? .on : .off; reload()
        editingBaseID = value.editingBaseID; editingWorkspace = value.openedWorkspace; editingBaseWorkspace = value.destinationWorkspace; editingRevision = value.editingRevision
        baseID = value.baseID; sourceID = value.sourceID; baseName.stringValue = value.name; baseScope.selectItem(at: value.project ? 1 : 0); baseScope.isEnabled = value.editingBaseID == nil
        baseScope.item(at: 1)?.isEnabled = workspace != nil && workspace == value.openedWorkspace; baseScope.toolTip = value.destinationWorkspace
        nameChanged = envelope.dirty; nameSelection = value.selection; nameFocus = value.focus; state.stringValue = value.status; pendingRecovery = value; updatePage(); scheduleRecovery()
    }
    private func scheduleRecovery() {
        guard pendingRecovery != nil, !recoveryScheduled else { return }; recoveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { recoveryScheduled = false }
            guard page == .name, isPageVisible, let value = pendingRecovery else { return }; applyingRecovery = true
            if value.focus == "name" { presentingWindow?.makeFirstResponder(baseName); if let selection = value.selection { (baseName.currentEditor() as? NSTextView)?.setSelectedRange(selection.range) } }
            else if value.focus == "scope" { presentingWindow?.makeFirstResponder(baseScope) }
            baseList.contentView.scroll(to: NSPoint(x: 0, y: value.baseY)); baseList.reflectScrolledClipView(baseList.contentView)
            fileList.contentView.scroll(to: NSPoint(x: 0, y: value.fileY)); fileList.reflectScrolledClipView(fileList.contentView)
            pendingRecovery = nil; applyingRecovery = false
        }
    }
    override func settingsDidAppear() { super.settingsDidAppear(); scheduleRecovery() }
    override func pageDidLayout() { scheduleRecovery() }
    func windowDidBecomeKey(_ notification: Notification) { scheduleRecovery() }
    func checkRecovery(action: String, name: String? = nil, project: Bool? = nil, baseID: String? = nil, selection: NSRange? = nil) throws {
        guard ["--knowledge-editor-recovery-check", "--knowledge-editor-recovery-ui"].contains(where: CommandLine.arguments.contains) else { throw PetError("仅用于知识库命名恢复验收") }
        if action == "new" { newBase() }
        else if action == "rename" { reload(); self.baseID = baseID; reloadFiles(); renameBase() }
        if let name { baseName.stringValue = name; nameSelection = nil; nameChanged = true; pendingRecovery = nil }
        if let project { baseScope.selectItem(at: project ? 1 : 0); nameScopeChanged() }
        if let selection { presentingWindow?.makeFirstResponder(baseName); (baseName.currentEditor() as? NSTextView)?.setSelectedRange(selection); rememberNameSelection() }
        if action == "save" { saveBaseName() } else if action == "cancel" { cancelBaseName() }
        onWorkspaceChange?()
    }
    @objc private func archiveBase() {
        guard let base = selectedBase else { return }
        do { try store.knowledge.archive(base: base.id, archived: !base.archived, expected: revision); page = .bases; reload() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func archiveFile() {
        guard let source = selectedSource else { return }
        do { try store.knowledge.archive(source: source.id, archived: !source.archived, expected: revision); page = .files; reload() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func addFiles() { importFiles(replacing: nil) }
    @objc private func replaceFile() { importFiles(replacing: sourceID) }
    private func importFiles(replacing: String?) {
        guard let baseID, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = replacing == nil
        panel.allowedContentTypes = (AgentDocument.textTypes.union(AgentDocument.imageTypes).union(["pdf", "docx", "xlsx", "pptx"])).compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        setBusy(true); state.stringValue = "添加中…"
        job = Task { [weak self] in
            guard let self else { return }; defer { setBusy(false) }
            var failures: [String] = []
            for url in panel.urls {
                do { try Task.checkCancellation(); let source = try await store.knowledge.add(url, baseID: baseID, replacing: replacing); self.baseID = baseID; sourceID = source.id; reload() }
                catch { if Task.isCancelled { return }; failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
            }
            if !failures.isEmpty { state.stringValue = failures.prefix(3).joined(separator: "；"); state.toolTip = failures.joined(separator: "\n") }
        }
    }
    @objc private func downloadFile() {
        guard let source = selectedSource, !busy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = source.file.name
        guard panel.runModal() == .OK, let target = panel.url else { return }
        setBusy(true); state.stringValue = "保存中…"
        job = Task { [weak self] in
            guard let self else { return }; defer { setBusy(false) }
            do { try await store.knowledge.export(source, to: target); state.stringValue = "已保存 " + target.lastPathComponent }
            catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
        }
    }
    @objc private func openFile() {
        guard let source = selectedSource else { return }
        do { NSWorkspace.shared.open(try store.knowledge.sourceURL(source)) } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedText, forType: .string) }
}
