import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentRecordWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String
    private let sections = NSSegmentedControl(labels: ["计划", "产物", "来源", "变更", "日志", "记忆", "Wiki"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView(), text = AgentMarkdownTextView(), state = NSTextField(labelWithString: "")
    private let sourceAdd = NSButton(title: "加入任务", target: nil, action: nil)
    private let readingToolbar = NSStackView()
    private lazy var sourceSelection = AgentMarkdownSelectionAction(text: text, button: sourceAdd) { [weak self] in
        guard let self, !self.viewer.isHidden, let workspace = self.store.task(self.taskID)?.workspace, let path = self.selection, [1, 6].contains(self.sections.selectedSegment), let file = try? AgentFiles(workspace: workspace).resolve(path) else { return nil }; return (file, workspace)
    }
    var onAddSelection: ((AgentMarkdownSelection) throws -> Void)? { didSet {
        markdown.onAddSelection = onAddSelection; sourceSelection.onAdd = onAddSelection
        markdown.canAddSelection = { [weak self] in self?.canAddSelection == true }; sourceSelection.canAdd = markdown.canAddSelection
    } }
    private var canAddSelection: Bool { guard let task = store.task(taskID) else { return false }; return !task.archived && task.kind != "hook" && !task.isProjectDocumentation && task.agent?.ownerID == nil && task.automation == nil }
    private let markdown = AgentMarkdownReader(), viewer = NSScrollView(), video = AgentVideoPreview()
    private let displayMode = NSSegmentedControl(labels: ["预览", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let encodingMenu = NSPopUpButton()
    private var requestedEncoding: AgentTextEncoding?, encodings: [String: AgentTextEncoding] = [:], fileFormat = AgentTextFormat()
    private let save = NSButton(title: "保存", target: nil, action: nil), undo = NSButton(title: "撤回修改", target: nil, action: nil), open = NSButton(title: "打开", target: nil, action: nil)
    private let compare = NSButton(title: "比较", target: nil, action: nil)
    private let generate = NSButton(title: "生成／更新", target: nil, action: nil)
    private let newOffice = NSPopUpButton(), openOffice = NSButton(title: "打开文件…", target: nil, action: nil)
    var onGenerateWiki: (() -> Void)?
    private var items: [(title: String, value: String)] = [], selection: String?, openedHash: String?, load: Task<Void, Never>?
    private var dirty = false, activeSection = 0, saving = false
    private var fileBOM: Bool { fileFormat.bom }
    private var openedFile: URL?
    private var fileContent: String { (fileBOM ? "\u{FEFF}" : "") + text.string }
    private func fileData() throws -> Data { try fileFormat.encode(text.string) }
    private var logSignature = ""
    private var attachmentWindow: AgentAttachmentWindow?
    private var markdownFile: URL?, sourceWindow: AgentMarkdownSourceWindow?
    private var conflictWindow: AgentFileConflictWindow?
    private var videoWindow: AgentVideoWindow?
    init(store: AgentStore, taskID: String, section: Int = 0) {
        self.store = store; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = store.task(taskID)?.title ?? "任务记录"; window.minSize = NSSize(width: 650, height: 450); window.center(); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); window.backgroundColor = .windowBackgroundColor
        super.init(window: window); window.delegate = self; text.delegate = self
        let content = NSView(); content.wantsLayer = true; content.layer?.backgroundColor = NSColor(white: 0.98, alpha: 1).cgColor; window.contentView = content
        sections.target = self; sections.action = #selector(refresh); sections.selectedSegment = min(6, max(0, section)); activeSection = sections.selectedSegment
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("record")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 31; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("任务产物与来源")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        text.isRichText = false; text.isEditable = false; text.previewUndoManager = UndoManager(); text.allowsUndo = true; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 15, height: 14); text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false
        viewer.documentView = text; viewer.hasVerticalScroller = true
        displayMode.target = self; displayMode.action = #selector(switchDocumentMode); displayMode.selectedSegment = 0; displayMode.setAccessibilityLabel("Markdown 显示方式")
        markdown.onLink = { [weak self] url in self?.openDocumentLink(url) }
        markdown.canEdit = { [weak self] in guard let self, self.text.isEditable, let task = self.store.task(self.taskID), let file = self.markdownFile else { return false }; return self.fileIsEditable(task, file: file) }
        markdown.onSourceChanged = { [weak self] value in
            guard let self else { return }; self.text.string = value; self.text.undoManager?.removeAllActions()
            do { self.dirty = AgentFiles.hash(try self.fileData()) != self.openedHash; self.state.stringValue = self.dirty ? "未保存" : self.markdownFile?.lastPathComponent ?? "" }
            catch { self.dirty = true; self.state.stringValue = error.localizedDescription }
        }
        markdown.onEditError = { [weak self] message in self?.state.stringValue = message }
        AgentTextEncoding.prepareMenu(encodingMenu); encodingMenu.target = self; encodingMenu.action = #selector(reopenEncoding); encodingMenu.isHidden = true
        let pane = NSView(); [displayMode, encodingMenu, NSView(), sourceAdd].forEach { readingToolbar.addArrangedSubview($0) }; sourceSelection.update()
        readingToolbar.heightAnchor.constraint(equalToConstant: 24).isActive = true
        video.isHidden = true
        for child in [viewer, markdown, video] { pane.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([child.topAnchor.constraint(equalTo: pane.topAnchor), child.leadingAnchor.constraint(equalTo: pane.leadingAnchor), child.trailingAnchor.constraint(equalTo: pane.trailingAnchor), child.bottomAnchor.constraint(equalTo: pane.bottomAnchor)]) }
        let documentPane = NSStackView(views: [readingToolbar, pane]); documentPane.orientation = .vertical; documentPane.distribution = .fill; documentPane.spacing = 6
        for child in [readingToolbar, pane] { child.widthAnchor.constraint(equalTo: documentPane.widthAnchor).isActive = true }
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail
        save.target = self; save.action = #selector(saveFile); undo.target = self; undo.action = #selector(restoreFile); open.target = self; open.action = #selector(openItem)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        generate.target = self; generate.action = #selector(generateWiki)
        newOffice.addItems(withTitles: ["新建", "Word 文稿…", "Excel 表格…", "幻灯片…"]); newOffice.target = self; newOffice.action = #selector(createOffice); newOffice.setAccessibilityLabel("新建办公文件")
        openOffice.target = self; openOffice.action = #selector(chooseOffice)
        compare.target = self; compare.action = #selector(presentConflict); compare.setAccessibilityLabel("比较磁盘文件与草稿")
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [state, NSView(), newOffice, openOffice, generate, undo, open, compare, save]); actions.spacing = 8
        for view in [sections, list, documentPane, actions] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([sections.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), sections.centerXAnchor.constraint(equalTo: content.centerXAnchor), list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), list.widthAnchor.constraint(equalToConstant: 165), list.topAnchor.constraint(equalTo: sections.bottomAnchor, constant: 16), list.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12), documentPane.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12), documentPane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), documentPane.topAnchor.constraint(equalTo: list.topAnchor), documentPane.bottomAnchor.constraint(equalTo: list.bottomAnchor), actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func selectItem(section: Int, value: String) {
        guard canLeave() else { return }
        sections.selectedSegment = min(6, max(0, section)); refresh()
        if let index = items.firstIndex(where: { $0.value == value }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index) }
    }
    @objc private func refresh() {
        guard canLeave() else { sections.selectedSegment = activeSection; return }; activeSection = sections.selectedSegment
        load?.cancel(); selection = nil; openedHash = nil; state.stringValue = ""; text.isEditable = false; resetDocumentMode()
        save.isHidden = true; undo.isHidden = true; open.isHidden = true; compare.isHidden = true
        generate.isHidden = sections.selectedSegment != 6; generate.isEnabled = onGenerateWiki != nil
        guard let task = store.task(taskID) else { return }
        newOffice.isHidden = sections.selectedSegment != 1; openOffice.isHidden = newOffice.isHidden
        openOffice.isEnabled = task.workspace != nil; newOffice.isEnabled = task.workspace != nil && ![.running, .waiting].contains(task.status) && !task.archived
        switch sections.selectedSegment {
        case 0:
            items = []; text.string = task.plan.enumerated().map { index, step in "\(step.status == "completed" ? "✓" : step.status == "in_progress" ? "◉" : "○") \(index + 1). \(step.title)" }.joined(separator: "\n\n")
        case 1: items = task.artifacts.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) } + (task.canvases ?? []).map { ($0.title, $0.reference) }
        case 2: items = task.sources.map { source in let url = URL(string: source); return (url?.isFileURL == true ? url!.lastPathComponent : url?.host ?? source, source) }
        case 3: items = task.changes.map { ((($0.restoredAt != nil) ? "✓ " : "") + URL(fileURLWithPath: $0.path).lastPathComponent, $0.id) }
        case 4:
            items = [("全部日志", "all-logs")] + task.events.filter { $0.kind == "hook" }.suffix(64).reversed().map { ($0.statusTitle + " · " + $0.title, $0.id) }
        case 5: items = AgentMemoryScope.allCases.map { ($0.title, $0.rawValue) }
        case 6:
            do { items = try AgentWiki.pages(workspace: task.workspace).map { (URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent, $0) }; state.stringValue = items.isEmpty ? "未生成" : try AgentWiki.status(store: store, taskID: taskID) }
            catch { items = []; state.stringValue = error.localizedDescription }
        default:
            items = []; text.string = task.events.map { "\($0.title) · \($0.status)\n\($0.detail)" }.joined(separator: "\n\n────────\n\n")
        }
        if [1, 2, 3, 5, 6].contains(sections.selectedSegment) { text.string = "" }
        table.delegate = nil; table.reloadData(); table.deselectAll(nil); table.delegate = self
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func refreshLiveRecords(_ id: String) {
        guard id == taskID, window?.isVisible == true, [3, 4].contains(sections.selectedSegment), !dirty, let task = store.task(taskID) else { return }
        let next = sections.selectedSegment == 3
            ? task.changes.map { "\($0.id)|\($0.afterHash ?? "")|\($0.afterKind ?? "")|\($0.restoredAt?.description ?? "")" }.joined() + task.status.rawValue + (task.pendingFileCapture?.id ?? "")
            : task.events.map { "\($0.id)|\($0.status)|\($0.duration ?? -1)|\($0.detail.count)|\($0.hook?.delivery ?? "")" }.joined()
        guard next != logSignature else { return }; logSignature = next
        let previous = selection, clip = text.enclosingScrollView?.contentView, origin = text.enclosingScrollView?.contentView.bounds.origin
        refresh()
        if let index = items.firstIndex(where: { $0.value == previous }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        if let clip, let origin { clip.scroll(to: origin); text.enclosingScrollView?.reflectScrolledClipView(clip) }
    }
    @objc private func generateWiki() { if canLeave() { onGenerateWiki?() } }
    func enableWikiGeneration(_ action: @escaping () -> Void) { onGenerateWiki = action; generate.isEnabled = true }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: items[row].title); label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = items[row].value; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard items.indices.contains(table.selectedRow), let task = store.task(taskID) else { return }
        guard canLeave() else {
            table.delegate = nil
            if let previous = items.firstIndex(where: { $0.value == selection }) { table.selectRowIndexes(IndexSet(integer: previous), byExtendingSelection: false) }
            table.delegate = self; return
        }
        load?.cancel(); let value = items[table.selectedRow].value; selection = value; openedHash = nil; text.isEditable = false; state.stringValue = ""; resetDocumentMode()
        text.undoManager?.removeAllActions()
        save.isHidden = true; undo.isHidden = true; open.isHidden = true; compare.isHidden = true; open.title = "打开"
        do {
            if sections.selectedSegment == 1, let url = URL(string: value), url.scheme == "canvas", let id = url.host.flatMap({ UUID(uuidString: $0)?.uuidString }) {
                let canvas = try store.canvases.source(id, taskID: taskID); text.string = canvas.code; open.isHidden = false; open.title = "打开画布"; state.stringValue = canvas.record.title; return
            }
            if sections.selectedSegment == 4 {
                let events = value == "all-logs" ? task.events : task.events.filter { $0.id == value }
                text.string = events.map { event in
                    event.title + " · " + event.statusTitle + (event.hook?.asynchronous == true ? " · 后台" : "") + (event.duration.map { " · " + String(format: "%.1fs", $0) } ?? "") + "\n" + event.detail
                }.joined(separator: "\n\n────────\n\n"); return
            }
            if sections.selectedSegment == 5, let scope = AgentMemoryScope(rawValue: value) {
                let memory = try AgentMemory.snapshot(scope, store: store, taskID: taskID)
                text.string = memory.content; openedHash = memory.hash; state.stringValue = memory.location
                text.isEditable = task.status != .running; save.isHidden = false; save.isEnabled = text.isEditable; return
            }
            if sections.selectedSegment == 2 {
                if let url = URL(string: value), url.isFileURL, AgentVideoSnapshot.supports(url) { let files = try AgentFiles(workspace: task.workspace); try showVideo(files.resolve(url.path), files: files) }
                else { text.string = value; open.isHidden = false }
                return
            }
            if sections.selectedSegment == 3 {
                guard let change = task.changes.first(where: { $0.id == value }) else { return }
                undo.isHidden = change.restoredAt != nil; undo.isEnabled = task.status != .running && task.pendingFileCapture == nil && change.reviewOnly != true && change.afterState?.kind != "directory"
                state.stringValue = (change.origin ?? "") + (change.reviewOnly == true ? " · 并行操作，需核对实际文件" : ""); text.string = "读取差异…"
                load = Task { [weak self] in
                    guard let self else { return }
                    do { let diff = try await AgentChanges.diff(change, taskID: taskID, store: store); guard !Task.isCancelled else { return }; text.string = diff }
                    catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
                }; return
            }
            let files = try AgentFiles(workspace: task.workspace), file = try files.resolve(value)
            if AgentVideoSnapshot.supports(file) { try showVideo(file, files: files); return }
            if AgentOffice.supports(file.path) { text.string = file.lastPathComponent; state.stringValue = files.relative(file); open.isHidden = false; open.title = "编辑"; return }
            let data = try files.readData(file)
            openedFile = file; requestedEncoding = encodings[file.path]; open.isHidden = false
            encodingMenu.isHidden = !AgentTextEncoding.canReopen(file)
            readingToolbar.isHidden = encodingMenu.isHidden
            AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: nil)
            do { let document = try AgentTextFile.decode(data, encoding: requestedEncoding); loadText(document, data: data, file: file, task: task); state.stringValue = (text.isEditable ? "" : "只读 · ") + files.relative(file) }
            catch { text.string = ""; state.stringValue = encodingMenu.isHidden ? "此文件不能作为文本预览" : error.localizedDescription }
        } catch { text.string = ""; state.stringValue = error.localizedDescription }
    }
    private func fileIsEditable(_ task: AgentTaskRecord, file: URL) -> Bool {
        guard !task.archived, ![.running, .waiting].contains(task.status), task.kind != "hook", task.kind != AgentKnowledgeCards.kind,
              FileManager.default.isWritableFile(atPath: file.path), let files = try? AgentFiles(workspace: task.workspace), !AgentFiles.sensitive(files.relative(file)),
              (try? store.agents.limits(task, store: store).readOnly) == false else { return false }
        return true
    }
    private func resetDocumentMode() { readingToolbar.isHidden = true; video.clear(); video.isHidden = true; conflictWindow?.close(); conflictWindow = nil; markdownFile = nil; openedFile = nil; fileFormat = AgentTextFormat(); requestedEncoding = nil; encodingMenu.isHidden = true; markdown.clear(); markdown.isHidden = true; viewer.isHidden = false; displayMode.isHidden = true; sourceSelection.update() }
    private func videoScope(_ files: AgentFiles) -> () throws -> Void {
        { [weak self] in guard let self, let task = self.store.task(self.taskID), try AgentFiles(workspace: task.workspace).root == files.root else { throw PetError("视频所属任务或工作区已变化") } }
    }
    private func showVideo(_ file: URL, files: AgentFiles, separate: Bool = false) throws {
        guard try files.resolve(file.path) == file, !AgentFiles.sensitive(files.relative(file)) else { throw PetError("不能预览此视频路径") }
        if separate {
            video.pause(); videoWindow?.close(); videoWindow = AgentVideoWindow(file: file, files: files, validate: videoScope(files))
            videoWindow?.showWindow(nil); videoWindow?.window?.makeKeyAndOrderFront(nil)
        } else {
            text.string = ""; viewer.isHidden = true; markdown.isHidden = true; video.isHidden = false; readingToolbar.isHidden = true; sourceAdd.isHidden = true
            openedFile = file; open.isHidden = false; open.title = "新窗口"; state.stringValue = files.relative(file)
            video.show(file: file, files: files, validate: videoScope(files))
        }
    }
    private func loadText(_ document: AgentTextFile, data: Data, file: URL, task: AgentTaskRecord) {
        markdown.clear(); markdownFile = nil
        text.string = document.text; fileFormat = document.format; openedHash = AgentFiles.hash(data); openedFile = file; dirty = false; text.undoManager?.removeAllActions()
        text.isEditable = data.count <= 2_000_000 && document.text.utf8.count <= 2_000_000 && fileIsEditable(task, file: file); save.isHidden = false; save.isEnabled = text.isEditable; compare.isHidden = !text.isEditable; encodingMenu.isHidden = false; readingToolbar.isHidden = false
        AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: fileFormat)
        markdown.isHidden = true; viewer.isHidden = false; displayMode.isHidden = !["md", "markdown"].contains(file.pathExtension.lowercased())
        if !displayMode.isHidden { markdownFile = file; displayMode.selectedSegment = 0; switchDocumentMode() }
        sourceSelection.update()
    }
    @objc private func reopenEncoding() {
        let chosen = AgentTextEncoding.selection(encodingMenu)
        var retainedDirty = dirty
        do {
            guard !saving, let task = store.task(taskID), let file = openedFile, let path = selection else { throw PetError("文档当前不可重新打开") }
            let files = try AgentFiles(workspace: task.workspace); guard try files.resolve(path) == file else { throw PetError("文件位置已变化") }
            try markdown.finishEditing(); retainedDirty = dirty
            let data = try files.readData(file), document = try AgentTextFile.decode(data, encoding: chosen)
            guard canLeave() else { AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: fileFormat); return }
            guard let current = store.task(taskID), selection == path, openedFile == file else { throw PetError("文档或任务已变化，草稿已保留") }
            let currentFiles = try AgentFiles(workspace: current.workspace); guard try currentFiles.resolve(path) == file else { throw PetError("文件位置已变化，草稿已保留") }
            let latest = try currentFiles.readData(file), decoded = latest == data ? document : try AgentTextFile.decode(latest, encoding: chosen)
            conflictWindow?.close(); conflictWindow = nil; requestedEncoding = chosen; encodings[file.path] = chosen; loadText(decoded, data: latest, file: file, task: current); state.stringValue = (text.isEditable ? "" : "只读 · ") + currentFiles.relative(file)
        } catch { dirty = dirty || retainedDirty; state.stringValue = error.localizedDescription; AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: openedHash == nil ? nil : fileFormat) }
    }
    @objc private func switchDocumentMode() {
        guard let file = markdownFile, let workspace = store.task(taskID)?.workspace else { return }
        do { try markdown.finishEditing() } catch { state.stringValue = error.localizedDescription; displayMode.selectedSegment = markdown.isHidden ? 1 : 0; return }
        let preview = displayMode.selectedSegment == 0
        markdown.isHidden = !preview; viewer.isHidden = preview
        sourceSelection.update(); sourceAdd.isHidden = preview || onAddSelection == nil
        if preview { markdown.show(text.string, file: file, workspace: workspace, reuseIfUnchanged: true) }
    }
    private func openDocumentLink(_ url: URL) {
        do {
            if ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url); return }
            guard let workspace = store.task(taskID)?.workspace, let file = markdownFile else { return }
            let files = try AgentFiles(workspace: workspace), target = try AgentMarkdownDocument.target(url, document: file, files: files)
            if let row = items.firstIndex(where: { (try? files.resolve($0.value).path) == target.path }) {
                guard canLeave() else { return }
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
                _ = markdown.navigate(AgentMarkdownDocument.fragment(target))
            } else if AgentVideoSnapshot.supports(target) { try showVideo(target, files: files, separate: true) }
            else {
                let next = try AgentMarkdownSourceWindow(workspace: workspace, target: target)
                next.onAddSelection = onAddSelection; next.canAddSelection = { [weak self] in self?.canAddSelection == true }
                sourceWindow?.close(); sourceWindow = next; next.showWindow(nil); next.window?.makeKeyAndOrderFront(nil)
            }
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func saveFile() {
        guard let path = selection, let task = store.task(taskID) else { return }
        guard !saving else { return }
        guard ![.running, .waiting].contains(task.status), !task.archived else { state.stringValue = "任务当前只读，草稿已保留"; return }
        do {
            try markdown.finishEditing()
            if sections.selectedSegment == 5, let scope = AgentMemoryScope(rawValue: path), let hash = openedHash {
                let saved = try AgentMemory.save(scope, content: text.string, expectedHash: hash, store: store, taskID: taskID)
                openedHash = saved.hash; dirty = false; state.stringValue = "已保存"; return
            }
            let files = try AgentFiles(workspace: task.workspace), file = try files.resolve(path), current = try files.readData(file)
            guard file == openedFile, fileIsEditable(task, file: file) else { throw PetError("文件位置已变化或当前只读，草稿已保留") }
            guard let hash = openedHash else { throw PetError("打开的文件版本不可用，草稿已保留") }
            guard AgentFiles.hash(current) == hash else { state.stringValue = "文件已更改，草稿已保留"; presentConflict(); return }
            let content = text.string, format = fileFormat
            load = Task { [weak self] in
                guard let self else { return }
                do { try await persistFile(path: path, content: content, format: format, expectedHash: hash) }
                catch {
                    state.stringValue = error.localizedDescription
                    if let current = try? files.readData(file), AgentFiles.hash(current) != hash { presentConflict() }
                }
            }
        } catch { state.stringValue = error.localizedDescription }
    }
    private func persistFile(path: String, content: String, format: AgentTextFormat, expectedHash: String) async throws {
        guard !saving, let task = store.task(taskID), let file = openedFile, fileIsEditable(task, file: file), try AgentFiles(workspace: task.workspace).resolve(path) == file else { throw PetError("文件位置已变化或当前只读，草稿已保留") }
        let data = try format.encode(content)
        let args = try JSONSerialization.data(withJSONObject: ["path": path, "content": content, "expected_hash": expectedHash, "encoding": format.encoding.rawValue, "byte_order_mark": format.bom])
        saving = true; save.isEnabled = false; compare.isEnabled = false; state.stringValue = "正在保存…"
        defer { saving = false; save.isEnabled = text.isEditable; compare.isEnabled = true }
        _ = try await AgentTools(store: store, taskID: taskID).execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: args, as: UTF8.self)))
        openedHash = AgentFiles.hash(data); dirty = (try? fileData()) != data; state.stringValue = dirty ? "未保存" : "已保存"
    }
    private func conflictSnapshot() throws -> AgentFileConflictSnapshot {
        guard !saving, window?.isVisible == true, [1, 6].contains(sections.selectedSegment), let task = store.task(taskID), let workspace = task.workspace, let file = openedFile, let path = selection, try AgentFiles(workspace: workspace).resolve(path) == file else { throw PetError("文档或任务已变化，草稿已保留") }
        try markdown.finishEditing()
        return try AgentFileConflictSnapshot.read(file: file, workspace: workspace, draft: text.string, allowsOverwrite: fileIsEditable(task, file: file), format: fileFormat)
    }
    @objc private func presentConflict() {
        guard !saving, let file = openedFile else { return }
        conflictWindow?.close()
        let next = AgentFileConflictWindow(file: file, protectedData: store.directory.deletingLastPathComponent(), read: { [weak self] in
            guard let self else { throw PetError("文档已关闭") }; return try self.conflictSnapshot()
        }, resolve: { [weak self] reviewed, resolution in
            guard let self else { throw PetError("文档已关闭") }
            let current = try self.conflictSnapshot(); try reviewed.requireUnchanged(current)
            guard let path = self.selection, let task = self.store.task(self.taskID), let workspace = task.workspace else { throw PetError("任务已变化") }
            if resolution == .draft {
                guard current.allowsOverwrite else { throw PetError("当前文件只读，草稿已保留") }
                let document = try reviewed.draftDocument()
                try await self.persistFile(path: path, content: document.text, format: document.format, expectedHash: reviewed.diskHash)
            } else {
                let document = try current.diskDocument(); self.requestedEncoding = document.format.encoding; self.encodings[current.file.path] = document.format.encoding
                self.loadText(document, data: current.disk, file: current.file, task: task)
                self.state.stringValue = "已采用磁盘版本"
            }
            self.window?.makeKeyAndOrderFront(nil)
        })
        conflictWindow = next; next.showWindow(nil); next.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func restoreFile() {
        guard let task = store.task(taskID), let change = task.changes.first(where: { $0.id == selection }) else { return }
        do { try AgentChanges.restore(change, taskID: taskID, store: store); refresh(); state.stringValue = "已撤回" }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func openItem() {
        guard let value = selection else { return }
        if !video.isHidden, let file = openedFile, let task = store.task(taskID) {
            do { try showVideo(file, files: AgentFiles(workspace: task.workspace), separate: true) } catch { state.stringValue = error.localizedDescription }; return
        }
        if sections.selectedSegment == 1, AgentOffice.supports(value) { showOffice(value); return }
        if let url = URL(string: value), url.scheme == "canvas", let id = url.host.flatMap({ UUID(uuidString: $0)?.uuidString }) {
            load = Task { [weak self] in
                guard let self else { return }; do { _ = try await store.canvases.show(id, taskID: taskID) } catch { state.stringValue = error.localizedDescription }
            }; return
        }
        if sections.selectedSegment == 2 {
            if let url = URL(string: value), url.scheme == "attachment", let host = url.host, let id = UUID(uuidString: host)?.uuidString {
                do {
                    let parts = url.pathComponents, part = parts.count > 2 && parts[1] == "part" ? Int(parts[2]) ?? 1 : 1
                    attachmentWindow?.window?.performClose(nil); attachmentWindow = try AgentAttachmentWindow(store: store, taskID: taskID, id: id, part: part)
                    attachmentWindow?.showWindow(nil); attachmentWindow?.window?.makeKeyAndOrderFront(nil)
                } catch { state.stringValue = error.localizedDescription }
            }
            else if let url = URL(string: value), ["https", "http"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            else if let url = URL(string: value), url.isFileURL, let task = store.task(taskID), let files = try? AgentFiles(workspace: task.workspace), let safe = try? files.resolve(url.path) { if AgentOffice.supports(safe.path) { showOffice(safe.path) } else { NSWorkspace.shared.open(safe) } }
        }
        else if let task = store.task(taskID), let files = try? AgentFiles(workspace: task.workspace), let url = try? files.resolve(value) { NSWorkspace.shared.open(url) }
    }
    private func showOffice(_ path: String) {
        load = Task { [weak self] in guard let self else { return }; do { _ = try await store.offices.show(path, taskID: taskID) } catch { state.stringValue = error.localizedDescription } }
    }
    @objc private func chooseOffice() {
        guard let window, let workspace = store.task(taskID)?.workspace else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = (AgentOffice.formats + ["mp4", "webm"]).compactMap { UTType(filenameExtension: $0) }; panel.canChooseDirectories = false; panel.directoryURL = URL(fileURLWithPath: workspace)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url, let self else { return }
            if AgentVideoSnapshot.supports(file) { do { let files = try AgentFiles(workspace: workspace); try self.showVideo(files.resolve(file.path), files: files, separate: true) } catch { self.state.stringValue = error.localizedDescription } }
            else { self.showOffice(file.path) }
        }
    }
    @objc private func createOffice() {
        let index = newOffice.indexOfSelectedItem - 1; newOffice.selectItem(at: 0)
        guard AgentOffice.formats.indices.contains(index), let window, let workspace = store.task(taskID)?.workspace else { return }
        let format = AgentOffice.formats[index], panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]; panel.directoryURL = URL(fileURLWithPath: workspace); panel.nameFieldStringValue = "未命名." + format
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url, let self else { return }
            self.load = Task { @MainActor in do { _ = try await self.store.offices.create(file.path, taskID: self.taskID); self.refresh() } catch { self.state.stringValue = error.localizedDescription } }
        }
    }
    func textDidChange(_ notification: Notification) { dirty = true; state.stringValue = "未保存" }
    func undoManager(for view: NSTextView) -> UndoManager? { text.previewUndoManager }
    func textViewDidChangeSelection(_ notification: Notification) { sourceSelection.update(); sourceAdd.isHidden = viewer.isHidden || onAddSelection == nil }
    private func canLeave() -> Bool {
        guard !saving else { state.stringValue = "正在保存…"; return false }
        do { try markdown.finishEditing() } catch { state.stringValue = error.localizedDescription; return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存的更改？"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }; dirty = false; return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if canLeave() { load?.cancel(); return true }; return false }
    func windowWillClose(_ notification: Notification) { video.clear(); videoWindow?.close(); videoWindow = nil; markdown.clear(); sourceWindow?.close(); sourceWindow = nil; conflictWindow?.close(); conflictWindow = nil }
    func videoPreviewReadback() async -> [String: Any] {
        guard CommandLine.arguments.contains("--video-preview-check") else { return [:] }
        var result = await video.checkState(); result["saveVisible"] = !save.isHidden; result["compareVisible"] = !compare.isHidden; result["textEditable"] = text.isEditable; result["selection"] = selection ?? ""
        if let videoWindow { result["separateWindowVisible"] = videoWindow.window?.isVisible == true; result["separatePlayer"] = await videoWindow.preview.checkState() }
        return result
    }
    func markdownEditingReadback() async -> [String: Any] {
        guard ["--markdown-edit-check", "--file-conflict-check", "--text-encoding-check"].contains(where: CommandLine.arguments.contains) else { return [:] }
        await markdown.waitForDiagrams()
        let data = try? fileData()
        var result: [String: Any] = ["draft": text.string, "encodedDraft": fileContent, "encodedDraftBase64": data?.base64EncodedString() ?? "", "draftHash": data.map(AgentFiles.hash) ?? "", "openedHash": openedHash ?? "", "dirty": dirty, "utf8BOM": fileBOM, "encoding": fileFormat.encoding.rawValue, "byteOrderMark": fileFormat.bom, "sourceEditable": text.isEditable, "preview": markdown.editingCheckState, "comparison": conflictWindow?.checkState ?? [:]]
        if CommandLine.arguments.contains("--file-conflict-check") { result["snapshotAllowsOverwrite"] = (try? conflictSnapshot().allowsOverwrite) ?? false }
        if CommandLine.arguments.contains("--text-encoding-check") { result["encodingMenuVisible"] = !encodingMenu.isHidden; result["state"] = state.stringValue; result["file"] = openedFile?.path ?? "" }
        return result
    }
    func checkMarkdown() -> [String: Bool] {
        let original = text.string, hash = openedHash
        var checks = ["wikiOpensInPreview": !markdown.isHidden && viewer.isHidden && !displayMode.isHidden && markdown.document?.headings.first?.title == "项目文档"]
        displayMode.selectedSegment = 1; switchDocumentMode()
        checks["sourceViewKeepsExactBytes"] = !viewer.isHidden && markdown.isHidden && text.string == original && openedHash == hash
        displayMode.selectedSegment = 0; switchDocumentMode()
        checks["previewSwitchDoesNotMutateSourceOrSaveState"] = !dirty && text.string == original && openedHash == hash && !markdown.isHidden
        return checks
    }
    func checkWiki(_ output: URL) -> [String: Bool] {
        sections.selectedSegment = 6; enableWikiGeneration {}; refresh()
        var checks: [String: Bool] = ["nativeWikiListsFourActualPages": items.count == 4, "nativeWikiGenerationControlVisible": !generate.isHidden && generate.isEnabled]
        if let path = selection, let task = store.task(taskID), let files = try? AgentFiles(workspace: task.workspace), let data = try? files.readData(files.resolve(path)) {
            checks["nativeWikiEditorMatchesActualMarkdown"] = text.string == String(data: data, encoding: .utf8) && openedHash == AgentFiles.hash(data) && !save.isHidden
        } else { checks["nativeWikiEditorMatchesActualMarkdown"] = false }
        window?.contentView?.layoutSubtreeIfNeeded()
        if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("wiki-reader.png")) }
        return checks
    }
    func checkPreview(_ output: URL) async -> [String: Bool] {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        sections.selectedSegment = 1; refresh()
        var checks: [String: Bool] = [:]
        if let path = selection, let task = store.task(taskID), let files = try? AgentFiles(workspace: task.workspace), let data = try? files.readData(files.resolve(path)) {
            checks["nativePreviewMatchesActualFile"] = text.string == String(data: data, encoding: .utf8) && text.string.contains("49")
        } else { checks["nativePreviewMatchesActualFile"] = false }
        sections.selectedSegment = 3; refresh(); await load?.value
        try? await Task.sleep(nanoseconds: 100_000_000); window?.displayIfNeeded()
        checks["nativeDiffShowsActualChanges"] = text.string.contains("+") && text.string.contains("49") && text.string.contains("[exit=1]")
        if let view = window?.contentView {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("agent-records.png")) }
        }
        sections.selectedSegment = 5; refresh()
        if let memory = try? AgentMemory.snapshot(.global, store: store, taskID: taskID) {
            checks["nativeMemoryEditorMatchesStoredText"] = text.string == memory.content && openedHash == memory.hash && !save.isHidden
        } else { checks["nativeMemoryEditorMatchesStoredText"] = false }
        return checks
    }
}
