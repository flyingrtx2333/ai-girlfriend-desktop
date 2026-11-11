import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentKnowledgeLibraryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
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
        func list(_ table: NSTableView, label: String) -> NSScrollView {
            table.addTableColumn(NSTableColumn(identifier: .init("name"))); table.headerView = nil; table.rowHeight = 45
            table.dataSource = self; table.delegate = self; table.setAccessibilityLabel(label)
            let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; return scroll
        }
        let baseList = list(bases, label: "知识库列表"), fileList = list(files, label: "知识文件列表")
        heading.font = .systemFont(ofSize: 17, weight: .semibold); heading.lineBreakMode = .byTruncatingMiddle
        preview.isEditable = false; preview.isRichText = true; preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.textContainerInset = NSSize(width: 14, height: 14); preview.setAccessibilityLabel("知识文件预览")
        let viewer = NSScrollView(); viewer.documentView = preview; viewer.hasVerticalScroller = true; viewer.borderType = .bezelBorder
        for label in [state, provenance, total] { label.font = .systemFont(ofSize: 11); label.textColor = AgentWorkbenchTheme.secondaryText; label.lineBreakMode = .byTruncatingMiddle }
        part.setAccessibilityLabel("知识文件部分"); part.alignment = .right; part.target = self; part.action = #selector(loadPreview)
        format.selectedSegment = 0; format.target = self; format.action = #selector(renderPreview)
        for (button, action) in [(create, #selector(newBase)), (rename, #selector(renameBase)), (removeBase, #selector(archiveBase)), (add, #selector(addFiles)), (replace, #selector(replaceFile)), (removeFile, #selector(archiveFile)), (download, #selector(downloadFile)), (open, #selector(openFile)), (copy, #selector(copyText))] { button.target = self; button.action = action }
        let header = row([baseSearch, scope, archived, create]), baseFooter = row([rename, removeBase])
        let fileHeader = row([fileSearch, add, replace, removeFile]), previewHeader = row([format, NSView(), NSTextField(labelWithString: "部分"), part, total, copy])
        let previewFooter = row([provenance, NSView(), open, download])
        for view in [header, baseList, baseFooter, heading, fileHeader, fileList, previewHeader, viewer, previewFooter, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            baseSearch.widthAnchor.constraint(greaterThanOrEqualToConstant: 180), part.widthAnchor.constraint(equalToConstant: 46),
            baseList.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), baseList.widthAnchor.constraint(equalToConstant: 190), baseList.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), baseList.bottomAnchor.constraint(equalTo: baseFooter.topAnchor, constant: -8),
            baseFooter.leadingAnchor.constraint(equalTo: baseList.leadingAnchor), baseFooter.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -12),
            heading.leadingAnchor.constraint(equalTo: baseList.trailingAnchor, constant: 16), heading.topAnchor.constraint(equalTo: baseList.topAnchor), heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            fileHeader.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12), fileHeader.leadingAnchor.constraint(equalTo: heading.leadingAnchor), fileHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            fileList.leadingAnchor.constraint(equalTo: heading.leadingAnchor), fileList.topAnchor.constraint(equalTo: fileHeader.bottomAnchor, constant: 10), fileList.widthAnchor.constraint(equalToConstant: 210), fileList.bottomAnchor.constraint(equalTo: baseFooter.bottomAnchor),
            previewHeader.leadingAnchor.constraint(equalTo: fileList.trailingAnchor, constant: 12), previewHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), previewHeader.topAnchor.constraint(equalTo: fileList.topAnchor),
            viewer.leadingAnchor.constraint(equalTo: previewHeader.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: previewHeader.trailingAnchor), viewer.topAnchor.constraint(equalTo: previewHeader.bottomAnchor, constant: 8), viewer.bottomAnchor.constraint(equalTo: previewFooter.topAnchor, constant: -10),
            previewFooter.leadingAnchor.constraint(equalTo: viewer.leadingAnchor), previewFooter.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), previewFooter.bottomAnchor.constraint(equalTo: fileList.bottomAnchor),
            state.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), state.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        provenance.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileSearch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var workspace: String? { taskID.flatMap(store.task)?.workspace.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path } }
    private var selectedBase: AgentKnowledgeBase? { baseRows.first { $0.id == baseID } }
    private var selectedSource: AgentKnowledgeSource? { fileRows.first { $0.id == sourceID } }
    private func row(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.spacing = 7; row.orientation = .horizontal; return row }
    func windowWillClose(_ notification: Notification) { job?.cancel(); previewJob?.cancel() }
    @objc private func filterChanged() { reload() }
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
            reloadFiles()
            state.stringValue = "\(baseRows.count) 个知识库"
        } catch { state.stringValue = error.localizedDescription; setBusy(false) }
    }
    private func reloadFiles() {
        fileRows = catalog.sources.filter { $0.baseID == baseID && (archived.state == .on || !$0.archived) && (fileSearch.stringValue.isEmpty || $0.file.name.localizedCaseInsensitiveContains(fileSearch.stringValue)) }
        if !fileRows.contains(where: { $0.id == sourceID }) { sourceID = fileRows.first?.id }
        files.delegate = nil; files.reloadData(); files.deselectAll(nil)
        if let i = fileRows.firstIndex(where: { $0.id == sourceID }) { files.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }; files.delegate = self
        heading.stringValue = selectedBase.map { $0.name + " · " + ($0.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "用户") + ($0.archived ? " · 已移除" : "") } ?? "知识库"
        heading.toolTip = selectedBase?.workspace
        part.stringValue = "1"; setBusy(busy); loadPreview()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === bases ? baseRows.count : fileRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title: String, detail: String
        if tableView === bases { let value = baseRows[row]; title = value.name; detail = (value.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "用户") + (value.archived ? " · 已移除" : "") }
        else { let value = fileRows[row]; title = value.file.name; detail = ByteCountFormatter.string(fromByteCount: Int64(value.file.bytes), countStyle: .file) + (value.archived ? " · 已移除" : "") }
        let name = NSTextField(labelWithString: title), metadata = NSTextField(labelWithString: detail)
        name.font = .systemFont(ofSize: 12, weight: .medium); metadata.font = .systemFont(ofSize: 10); metadata.textColor = AgentWorkbenchTheme.secondaryText
        for label in [name, metadata] { label.lineBreakMode = .byTruncatingMiddle }
        let cell = NSStackView(views: [name, metadata]); cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 3; cell.setAccessibilityLabel(title + "，" + detail); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === bases {
            baseID = baseRows.indices.contains(bases.selectedRow) ? baseRows[bases.selectedRow].id : nil; sourceID = nil; reloadFiles()
        } else { sourceID = fileRows.indices.contains(files.selectedRow) ? fileRows[files.selectedRow].id : nil; part.stringValue = "1"; setBusy(busy); loadPreview() }
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
    private func askName(title: String, current: String, includeScope: Bool = false) -> (String, Bool)? {
        let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let name = NSTextField(string: current); name.placeholderString = "知识库名称"; name.setAccessibilityLabel("知识库名称")
        let picker = NSPopUpButton(); picker.addItems(withTitles: ["用户", "当前工作区"]); picker.autoenablesItems = false; picker.item(at: 1)?.isEnabled = workspace != nil; picker.setAccessibilityLabel("生效范围")
        let fields = NSStackView(views: includeScope ? [name, picker] : [name]); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 10; fields.frame = NSRect(x: 0, y: 0, width: 330, height: includeScope ? 75 : 32)
        name.translatesAutoresizingMaskIntoConstraints = false; name.widthAnchor.constraint(equalToConstant: 330).isActive = true; alert.accessoryView = fields
        alert.window.initialFirstResponder = name
        return alert.runModal() == .alertFirstButtonReturn ? (name.stringValue, picker.indexOfSelectedItem == 1) : nil
    }
    @objc private func newBase() {
        guard let (name, scoped) = askName(title: "新建知识库", current: "", includeScope: true) else { return }
        do { let base = try store.knowledge.create(name: name, workspace: scoped ? workspace : nil); baseID = base.id; sourceID = nil; archived.state = .off; baseSearch.stringValue = ""; scope.selectItem(at: 0); reload() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func renameBase() {
        guard let base = selectedBase, let (name, _) = askName(title: "重命名知识库", current: base.name) else { return }
        do { try store.knowledge.rename(base.id, name: name, expected: revision); reload() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func archiveBase() {
        guard let base = selectedBase else { return }
        do { try store.knowledge.archive(base: base.id, archived: !base.archived, expected: revision); reload() } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func archiveFile() {
        guard let source = selectedSource else { return }
        do { try store.knowledge.archive(source: source.id, archived: !source.archived, expected: revision); reload() } catch { state.stringValue = error.localizedDescription }
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
