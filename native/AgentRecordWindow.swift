import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentRecordWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String
    private let sections = NSSegmentedControl(labels: ["计划", "产物", "来源", "变更", "日志", "记忆", "Wiki"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView(), text = AgentMarkdownTextView(), state = NSTextField(labelWithString: "")
    private let sourceAdd = NSButton(title: "加入任务", target: nil, action: nil)
    private lazy var sourceSelection = AgentMarkdownSelectionAction(text: text, button: sourceAdd) { [weak self] in
        guard let self, !self.viewer.isHidden, let workspace = self.store.task(self.taskID)?.workspace, let path = self.selection, [1, 6].contains(self.sections.selectedSegment), let file = try? AgentFiles(workspace: workspace).resolve(path) else { return nil }; return (file, workspace)
    }
    var onAddSelection: ((AgentMarkdownSelection) throws -> Void)? { didSet {
        markdown.onAddSelection = onAddSelection; sourceSelection.onAdd = onAddSelection
        markdown.canAddSelection = { [weak self] in self?.canAddSelection == true }; sourceSelection.canAdd = markdown.canAddSelection
    } }
    private var canAddSelection: Bool { guard let task = store.task(taskID) else { return false }; return !task.archived && task.kind != "hook" && !task.isProjectDocumentation && task.agent?.ownerID == nil && task.automation == nil }
    private let markdown = AgentMarkdownReader(), viewer = NSScrollView()
    private let displayMode = NSSegmentedControl(labels: ["预览", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let save = NSButton(title: "保存", target: nil, action: nil), undo = NSButton(title: "撤回修改", target: nil, action: nil), open = NSButton(title: "打开", target: nil, action: nil)
    private let generate = NSButton(title: "生成／更新", target: nil, action: nil)
    private let newOffice = NSPopUpButton(), openOffice = NSButton(title: "打开文件…", target: nil, action: nil)
    var onGenerateWiki: (() -> Void)?
    private var items: [(title: String, value: String)] = [], selection: String?, openedHash: String?, load: Task<Void, Never>?
    private var dirty = false, activeSection = 0
    private var logSignature = ""
    private var attachmentWindow: AgentAttachmentWindow?
    private var markdownFile: URL?, sourceWindow: AgentMarkdownSourceWindow?
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
        text.isRichText = false; text.isEditable = false; text.allowsUndo = true; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 15, height: 14); text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false
        viewer.documentView = text; viewer.hasVerticalScroller = true
        displayMode.target = self; displayMode.action = #selector(switchDocumentMode); displayMode.selectedSegment = 0; displayMode.setAccessibilityLabel("Markdown 显示方式")
        markdown.onLink = { [weak self] url in self?.openDocumentLink(url) }
        let pane = NSView(), readingToolbar = NSStackView(views: [displayMode, NSView(), sourceAdd]); sourceSelection.update()
        for child in [viewer, markdown] { pane.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([child.topAnchor.constraint(equalTo: pane.topAnchor), child.leadingAnchor.constraint(equalTo: pane.leadingAnchor), child.trailingAnchor.constraint(equalTo: pane.trailingAnchor), child.bottomAnchor.constraint(equalTo: pane.bottomAnchor)]) }
        let documentPane = NSStackView(views: [readingToolbar, pane]); documentPane.orientation = .vertical; documentPane.spacing = 6
        for child in [readingToolbar, pane] { child.widthAnchor.constraint(equalTo: documentPane.widthAnchor).isActive = true }
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail
        save.target = self; save.action = #selector(saveFile); undo.target = self; undo.action = #selector(restoreFile); open.target = self; open.action = #selector(openItem)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        generate.target = self; generate.action = #selector(generateWiki)
        newOffice.addItems(withTitles: ["新建", "Word 文稿…", "Excel 表格…", "幻灯片…"]); newOffice.target = self; newOffice.action = #selector(createOffice); newOffice.setAccessibilityLabel("新建办公文件")
        openOffice.target = self; openOffice.action = #selector(chooseOffice)
        let actions = NSStackView(views: [state, NSView(), newOffice, openOffice, generate, undo, open, save]); actions.spacing = 8
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
        save.isHidden = true; undo.isHidden = true; open.isHidden = true
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
        save.isHidden = true; undo.isHidden = true; open.isHidden = true; open.title = "打开"
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
            if sections.selectedSegment == 2 { text.string = value; open.isHidden = false; return }
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
            if AgentOffice.supports(file.path) { text.string = file.lastPathComponent; state.stringValue = files.relative(file); open.isHidden = false; open.title = "编辑"; return }
            let data = try files.readData(file)
            guard !data.contains(0), let content = String(data: data, encoding: .utf8) else { text.string = file.lastPathComponent; open.isHidden = false; return }
            text.string = content; openedHash = AgentFiles.hash(data); text.isEditable = ![.running, .waiting].contains(task.status) && !task.archived
            save.isHidden = false; save.isEnabled = text.isEditable; open.isHidden = false; state.stringValue = (sections.selectedSegment == 6 ? "按上次索引：" + (try AgentWiki.status(store: store, taskID: taskID)) + " · " : "") + files.relative(file)
            if ["md", "markdown"].contains(file.pathExtension.lowercased()) { markdownFile = file; displayMode.isHidden = false; displayMode.selectedSegment = 0; switchDocumentMode() }
        } catch { text.string = ""; state.stringValue = error.localizedDescription }
    }
    private func resetDocumentMode() { markdownFile = nil; markdown.clear(); markdown.isHidden = true; viewer.isHidden = false; displayMode.isHidden = true; sourceSelection.update() }
    @objc private func switchDocumentMode() {
        guard let file = markdownFile, let workspace = store.task(taskID)?.workspace else { return }
        let preview = displayMode.selectedSegment == 0
        markdown.isHidden = !preview; viewer.isHidden = preview
        sourceSelection.update(); sourceAdd.isHidden = preview || onAddSelection == nil
        if preview { markdown.show(text.string, file: file, workspace: workspace) }
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
            } else {
                let next = try AgentMarkdownSourceWindow(workspace: workspace, target: target)
                next.onAddSelection = onAddSelection; next.canAddSelection = { [weak self] in self?.canAddSelection == true }
                sourceWindow?.close(); sourceWindow = next; next.showWindow(nil); next.window?.makeKeyAndOrderFront(nil)
            }
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func saveFile() {
        guard let path = selection, let task = store.task(taskID) else { return }
        guard task.status != .running else { state.stringValue = "请先停止任务"; return }
        do {
            if sections.selectedSegment == 5, let scope = AgentMemoryScope(rawValue: path), let hash = openedHash {
                let saved = try AgentMemory.save(scope, content: text.string, expectedHash: hash, store: store, taskID: taskID)
                openedHash = saved.hash; dirty = false; state.stringValue = "已保存"; return
            }
            let files = try AgentFiles(workspace: task.workspace), current = try files.readData(files.resolve(path))
            guard AgentFiles.hash(current) == openedHash else { throw PetError("文件已更改，请重新打开后编辑") }
            let content = text.string, args = try JSONSerialization.data(withJSONObject: ["path": path, "content": content])
            load = Task { [weak self] in
                guard let self else { return }
                do { _ = try await AgentTools(store: store, taskID: taskID).execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: args, as: UTF8.self))); openedHash = AgentFiles.hash(Data(content.utf8)); dirty = text.string != content; state.stringValue = "已保存" }
                catch { state.stringValue = error.localizedDescription }
            }
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func restoreFile() {
        guard let task = store.task(taskID), let change = task.changes.first(where: { $0.id == selection }) else { return }
        do { try AgentChanges.restore(change, taskID: taskID, store: store); refresh(); state.stringValue = "已撤回" }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func openItem() {
        guard let value = selection else { return }
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
        let panel = NSOpenPanel(); panel.allowedContentTypes = AgentOffice.formats.compactMap { UTType(filenameExtension: $0) }; panel.canChooseDirectories = false; panel.directoryURL = URL(fileURLWithPath: workspace)
        panel.beginSheetModal(for: window) { [weak self] response in guard response == .OK, let file = panel.url else { return }; self?.showOffice(file.path) }
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
    func textViewDidChangeSelection(_ notification: Notification) { sourceSelection.update(); sourceAdd.isHidden = viewer.isHidden || onAddSelection == nil }
    private func canLeave() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存的更改？"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }; dirty = false; return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if canLeave() { load?.cancel(); return true }; return false }
    func windowWillClose(_ notification: Notification) { markdown.clear(); sourceWindow?.close(); sourceWindow = nil }
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
