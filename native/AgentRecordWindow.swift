import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentRecordWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String
    private let taskHosted: Bool, documentOnly: Bool
    private let sections = NSSegmentedControl(labels: ["计划", "产物", "来源", "变更", "日志", "记忆", "Wiki"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView(), text = AgentMarkdownTextView(), state = NSTextField(labelWithString: "")
    private let list = NSScrollView(), wikiTree = AgentWikiTree()
    private let sourceAdd = NSButton(title: "加入任务", target: nil, action: nil)
    private let readingToolbar = NSStackView()
    private lazy var sourceSelection = AgentMarkdownSelectionAction(text: text, button: sourceAdd) { [weak self] in
        guard let self, !self.viewer.isHidden, let workspace = self.store.task(self.taskID)?.workspace, let path = self.selection, [1, 6].contains(self.sections.selectedSegment), let file = try? AgentFiles(workspace: workspace).resolve(path) else { return nil }; return (file, workspace)
    }
    var onAddSelection: ((AgentMarkdownSelection) throws -> Void)? { didSet {
        markdown.onAddSelection = onAddSelection; sourceSelection.onAdd = onAddSelection
        markdown.canAddSelection = { [weak self] in self?.canAddSelection == true }; sourceSelection.canAdd = markdown.canAddSelection
    } }
    var onOpenVideo: ((URL) throws -> Void)? { didSet {
        if onOpenVideo != nil, taskHosted, !documentOnly, let file = openedFile, AgentVideoSnapshot.supports(file) { open.title = "打开标签页" }
    } }
    var onChooseWorkspaceFile: (() -> Void)?
    private var canAddSelection: Bool { guard let task = store.task(taskID) else { return false }; return !task.archived && task.kind != "hook" && !task.isProjectDocumentation && task.agent?.ownerID == nil && task.automation == nil }
    private let markdown = AgentMarkdownReader(), viewer = NSScrollView(), video = AgentVideoPreview()
    private let displayMode = NSSegmentedControl(labels: ["预览", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let encodingMenu = NSPopUpButton()
    private var requestedEncoding: AgentTextEncoding?, encodings: [String: AgentTextEncoding] = [:], fileFormat = AgentTextFormat()
    private let save = NSButton(title: "保存", target: nil, action: nil), undo = NSButton(title: "撤回修改", target: nil, action: nil), open = NSButton(title: "打开", target: nil, action: nil)
    private let compare = NSButton(title: "比较", target: nil, action: nil)
    private let allowInstruction = NSButton(title: "允许引用…", target: nil, action: nil), revokeInstruction = NSPopUpButton()
    private let generate = NSButton(title: "生成／更新", target: nil, action: nil)
    private let wikiCards = NSButton(title: "知识卡片", target: nil, action: nil)
    private let newOffice = NSPopUpButton(), openOffice = NSButton(title: "打开文件…", target: nil, action: nil)
    var onGenerateWiki: ((String) -> Void)?
    var onOpenKnowledgeCards: ((String) -> Void)? { didSet { wikiCards.isHidden = sections.selectedSegment != 6 || onOpenKnowledgeCards == nil } }
    private weak var wikiRuntime: AgentRuntime?
    private var onWikiTask: ((String) -> Void)?
    private var wikiGeneration: AgentWikiGenerationState?
    private var wikiKnowledgeSignature = ""
    private var wikiPlanWindow: AgentWikiPlanWindow?
    private var wikiSharingTask: Task<Void, Never>?
    private var wikiSharingAlert: NSAlert?
    private var wikiReviewWindow: AgentKnowledgeReviewWindow?
    private var wikiCitation: (enabled: Bool, signature: String, workspace: String)?
    private var wikiMaintenance: (options: AgentWikiMaintenanceOptions, signature: String, workspace: String)?
    private var wikiMaintenanceNotice = ""
    private var items: [(title: String, value: String)] = [], selection: String?, openedHash: String?, load: Task<Void, Never>?
    private var openedFiles: [String] = []
    private var dirty = false { didSet { if dirty != oldValue { onWorkspaceChange?() } } }
    private var activeSection = 0, saving = false
    var onWorkspaceChange: (() -> Void)?
    var workspaceHasUnsavedChanges: Bool { dirty }
    private let itemPicker = NSPopUpButton(), filesToggle = NSButton(), taskFileArea = NSView(), taskNavigation = NSView(), taskSecondaryActions = NSStackView()
    private var wideNavigation: [NSLayoutConstraint] = [], compactNavigation: [NSLayoutConstraint] = [], navigationWidth: NSLayoutConstraint!, navigationHeight: NSLayoutConstraint!, documentLeading: NSLayoutConstraint!, documentTop: NSLayoutConstraint!
    private var compactTaskLayout: Bool?, filesRequested = false
    func requireDeletionAllowed(_ ids: Set<String>) throws {
        if ids.contains(taskID) { try markdown.finishEditing() }
        if ids.contains(taskID), dirty || saving || wikiSharingTask != nil || wikiReviewWindow?.hasPendingOperation == true || wikiPlanWindow?.hasUnsavedChanges == true { throw PetError("请先保存或关闭此任务未保存或正在处理的记录窗口") }
    }
    func belongsToTasks(_ ids: Set<String>) -> Bool { ids.contains(taskID) }
    func closeDeletedTask(_ ids: Set<String>) { if ids.contains(taskID) { close() } }
    private var fileBOM: Bool { fileFormat.bom }
    private var openedFile: URL?
    private var fileContent: String { (fileBOM ? "\u{FEFF}" : "") + text.string }
    private func fileData() throws -> Data { try fileFormat.encode(text.string) }
    private var logSignature = ""
    private var attachmentWindow: AgentAttachmentWindow?
    private var markdownFile: URL?, sourceWindow: AgentMarkdownSourceWindow?
    private var conflictWindow: AgentFileConflictWindow?
    private var videoWindow: AgentVideoWindow?
    init(store: AgentStore, taskID: String, section: Int = 0, memoryOnly: Bool = false, wikiOnly: Bool = false, taskHosted: Bool = false, documentOnly: Bool = false) {
        self.store = store; self.taskID = taskID; self.taskHosted = taskHosted; self.documentOnly = documentOnly
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = store.task(taskID)?.title ?? "任务记录"; window.minSize = NSSize(width: 650, height: 450); window.center(); window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window); window.delegate = self; text.delegate = self
        let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        sections.target = self; sections.action = #selector(refresh); sections.selectedSegment = memoryOnly ? 5 : min(6, max(0, section)); activeSection = sections.selectedSegment; sections.isHidden = memoryOnly || wikiOnly || documentOnly
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("record")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 31; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("任务产物与来源")
        list.documentView = table; list.hasVerticalScroller = true
        let navigation = taskNavigation
        for child in [list, wikiTree] { navigation.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([child.topAnchor.constraint(equalTo: navigation.topAnchor), child.leadingAnchor.constraint(equalTo: navigation.leadingAnchor), child.trailingAnchor.constraint(equalTo: navigation.trailingAnchor), child.bottomAnchor.constraint(equalTo: navigation.bottomAnchor)]) }
        wikiTree.canSelect = { [weak self] path in guard let self else { return false }; return path == self.selection || self.canLeave() }
        wikiTree.onSelect = { [weak self] path in guard let self, path != self.selection else { return }; self.loadSelection(path) }
        wikiTree.onRefresh = { [weak self] in self?.refreshWikiCatalog() }
        wikiTree.setLanguage(store.task(taskID)?.wikiLanguage ?? store.task(taskID)?.wikiJob?.language ?? "zh")
        wikiTree.onLanguage = { [weak self] language in
            guard let self else { return false }
            guard self.canLeave() else { self.wikiTree.setLanguage(self.store.task(self.taskID)?.wikiLanguage ?? self.store.task(self.taskID)?.wikiJob?.language ?? "zh"); return false }
            self.store.update(self.taskID) { $0.wikiLanguage = language }; self.wikiTree.show([], selected: nil); self.refresh(); return true
        }
        wikiTree.onPlan = { [weak self] in self?.openWikiPlan() }
        wikiTree.onSharing = { [weak self] in self?.shareWiki($0) }
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
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        save.target = self; save.action = #selector(saveFile); undo.target = self; undo.action = #selector(restoreFile); open.target = self; open.action = #selector(openItem)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        generate.target = self; generate.action = #selector(generateWiki)
        wikiCards.target = self; wikiCards.action = #selector(openWikiCards)
        newOffice.addItems(withTitles: ["新建", "Word 文稿…", "Excel 表格…", "幻灯片…"]); newOffice.target = self; newOffice.action = #selector(createOffice); newOffice.setAccessibilityLabel("新建办公文件")
        openOffice.target = self; openOffice.action = #selector(chooseOffice)
        compare.target = self; compare.action = #selector(presentConflict); compare.setAccessibilityLabel("比较磁盘文件与草稿")
        allowInstruction.target = self; allowInstruction.action = #selector(allowInstructionFile)
        revokeInstruction.target = self; revokeInstruction.action = #selector(revokeInstructionFile); revokeInstruction.setAccessibilityLabel("撤销指令引用允许")
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if taskHosted {
            table.style = .plain; table.backgroundColor = .clear
            list.drawsBackground = false; list.scrollerStyle = .overlay; viewer.drawsBackground = false; viewer.scrollerStyle = .overlay; text.drawsBackground = false; text.textColor = .labelColor
            let primary = NSStackView(views: [state, NSView(), open, compare, save]); primary.spacing = 8
            for view in [allowInstruction, revokeInstruction, newOffice, openOffice, generate, wikiCards, undo, NSView()] { taskSecondaryActions.addArrangedSubview(view) }; taskSecondaryActions.spacing = 8
            let actions = NSStackView(views: [taskSecondaryActions, primary]); actions.orientation = .vertical; actions.alignment = .leading; actions.spacing = 8
            for row in [taskSecondaryActions, primary] { row.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true }
            itemPicker.setAccessibilityLabel("记录中的文件与来源"); itemPicker.target = self; itemPicker.action = #selector(selectTaskItem); itemPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); itemPicker.cell?.lineBreakMode = .byTruncatingMiddle
            filesToggle.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil); filesToggle.isBordered = false; filesToggle.target = self; filesToggle.action = #selector(toggleTaskFiles); filesToggle.setAccessibilityLabel("显示记录列表"); filesToggle.widthAnchor.constraint(equalToConstant: 26).isActive = true
            let picker = NSStackView(views: [itemPicker, filesToggle]); picker.spacing = 8; picker.isHidden = documentOnly
            for child in [navigation, documentPane] { taskFileArea.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
            navigationWidth = navigation.widthAnchor.constraint(equalToConstant: 165); navigationHeight = navigation.heightAnchor.constraint(equalToConstant: 86)
            documentLeading = documentPane.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: 12); documentTop = documentPane.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 8)
            wideNavigation = [navigationWidth, navigation.bottomAnchor.constraint(equalTo: taskFileArea.bottomAnchor), documentLeading, documentPane.topAnchor.constraint(equalTo: taskFileArea.topAnchor)]
            compactNavigation = [navigationHeight, navigation.trailingAnchor.constraint(equalTo: taskFileArea.trailingAnchor), documentTop, documentPane.leadingAnchor.constraint(equalTo: taskFileArea.leadingAnchor)]
            NSLayoutConstraint.activate([navigation.leadingAnchor.constraint(equalTo: taskFileArea.leadingAnchor), navigation.topAnchor.constraint(equalTo: taskFileArea.topAnchor), documentPane.trailingAnchor.constraint(equalTo: taskFileArea.trailingAnchor), documentPane.bottomAnchor.constraint(equalTo: taskFileArea.bottomAnchor)])
            let column = NSStackView(views: [sections, picker, taskFileArea, actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
            for child in [sections, picker, taskFileArea, actions] { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), column.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
            taskFileArea.setContentHuggingPriority(.defaultLow, for: .vertical)
            content.onResize = { [weak self] in self?.pageDidLayout() }; pageDidLayout(); refresh(); return
        }
        let actions = NSStackView(views: [state, NSView(), allowInstruction, revokeInstruction, newOffice, openOffice, generate, wikiCards, undo, open, compare, save]); actions.spacing = 8
        for view in [sections, navigation, documentPane, actions] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([sections.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), sections.centerXAnchor.constraint(equalTo: content.centerXAnchor), navigation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), navigation.widthAnchor.constraint(equalToConstant: 165), navigation.topAnchor.constraint(equalTo: memoryOnly || wikiOnly ? content.topAnchor : sections.bottomAnchor, constant: memoryOnly || wikiOnly ? 14 : 16), navigation.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12), documentPane.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: 12), documentPane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), documentPane.topAnchor.constraint(equalTo: navigation.topAnchor), documentPane.bottomAnchor.constraint(equalTo: navigation.bottomAnchor), actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func selectItem(section: Int, value: String) {
        if section == sections.selectedSegment, value == selection { return }
        guard canLeave() else { return }
        sections.selectedSegment = min(6, max(0, section)); refreshCatalog(selecting: value)
        if section == 6 { _ = wikiTree.select(value); return }
        if let index = items.firstIndex(where: { $0.value == value }) { table.scrollRowToVisible(index) }
    }
    func selectSection(_ section: Int) { guard sections.selectedSegment != section else { return }; sections.selectedSegment = min(6, max(0, section)); refresh() }
    func openWorkspaceDocument(_ path: String) throws {
        let files = try AgentFiles(workspace: store.task(taskID)?.workspace), file = try files.resolve(path)
        guard !AgentFiles.sensitive(files.relative(file)) else { throw PetError("不能打开受保护的文件") }
        if documentOnly { window?.title = file.lastPathComponent }
        if !openedFiles.contains(file.path) { openedFiles.append(file.path) }
        selectItem(section: 1, value: file.path)
    }
    override func pageDidLayout() {
        guard taskHosted, let content = pageContentView else { return }
        let compact = content.bounds.width < 700, shown = !documentOnly && !items.isEmpty && filesRequested
        if compactTaskLayout != compact { NSLayoutConstraint.deactivate(wideNavigation + compactNavigation); NSLayoutConstraint.activate(compact ? compactNavigation : wideNavigation); compactTaskLayout = compact }
        taskNavigation.isHidden = !shown; navigationWidth.constant = shown ? 165 : 0; navigationHeight.constant = shown ? min(100, max(56, floor(content.bounds.height * 0.16))) : 0
        documentLeading.constant = shown ? 12 : 0; documentTop.constant = shown ? 8 : 0
        filesToggle.setAccessibilityLabel(shown ? "隐藏记录列表" : "显示记录列表")
        taskSecondaryActions.isHidden = !taskSecondaryActions.arrangedSubviews.contains { ($0 is NSControl) && !$0.isHidden }
    }
    private func updateTaskItemPicker() {
        guard taskHosted else { return }; itemPicker.removeAllItems()
        for item in items { itemPicker.addItem(withTitle: item.title); itemPicker.lastItem?.representedObject = item.value; itemPicker.lastItem?.toolTip = item.value }
        if let selection, let index = items.firstIndex(where: { $0.value == selection }) { itemPicker.selectItem(at: index) }
        if items.isEmpty { itemPicker.addItem(withTitle: sections.selectedSegment == 0 ? "计划" : "暂无记录") }
        itemPicker.isEnabled = !items.isEmpty; filesToggle.isEnabled = !items.isEmpty
        if documentOnly { newOffice.isHidden = true; openOffice.isHidden = true }; pageDidLayout()
    }
    @objc private func selectTaskItem() { if let value = itemPicker.selectedItem?.representedObject as? String { selectItem(section: sections.selectedSegment, value: value); updateTaskItemPicker() } }
    @objc private func toggleTaskFiles() { filesRequested.toggle(); pageDidLayout() }
    func prepareWorkspaceNavigation() -> Bool {
        guard wikiReviewWindow?.hasPendingOperation != true else { state.stringValue = "请等待当前知识操作完成"; return false }
        guard !saving else { state.stringValue = "正在保存…"; return false }
        do { try markdown.finishEditing(); video.pause(); videoWindow?.preview.pause(); return true } catch { state.stringValue = error.localizedDescription; return false }
    }
    @objc private func refresh() {
        refreshCatalog(selecting: nil)
    }
    private func refreshCatalog(selecting preferred: String?) {
        guard canLeave() else { sections.selectedSegment = activeSection; return }; activeSection = sections.selectedSegment
        load?.cancel(); selection = nil; openedHash = nil; state.stringValue = ""; text.isEditable = false; resetDocumentMode()
        save.isHidden = true; undo.isHidden = true; open.isHidden = true; compare.isHidden = true
        allowInstruction.isHidden = true; revokeInstruction.isHidden = true
        generate.isHidden = sections.selectedSegment != 6; generate.isEnabled = onGenerateWiki != nil && wikiTree.selectedLanguage != "legacy"
        wikiCards.isHidden = sections.selectedSegment != 6 || onOpenKnowledgeCards == nil
        wikiTree.isHidden = sections.selectedSegment != 6; list.isHidden = !wikiTree.isHidden
        guard let task = store.task(taskID) else { return }
        updateWikiSharingState()
        newOffice.isHidden = sections.selectedSegment != 1; openOffice.isHidden = newOffice.isHidden
        openOffice.isEnabled = task.workspace != nil; newOffice.isEnabled = task.workspace != nil && ![.running, .waiting].contains(task.status) && !task.archived
        switch sections.selectedSegment {
        case 0:
            items = []; text.string = task.plan.enumerated().map { index, step in "\(step.status == "completed" ? "✓" : step.status == "in_progress" ? "◉" : "○") \(index + 1). \(step.title)" }.joined(separator: "\n\n")
        case 1:
            var seen = Set<String>()
            items = (task.artifacts + openedFiles).filter { seen.insert($0).inserted }.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) } + (task.canvases ?? []).map { ($0.title, $0.reference) }
        case 2: items = task.sources.map { source in let url = URL(string: source); return (url?.isFileURL == true ? url!.lastPathComponent : url?.host ?? source, source) }
        case 3: items = task.changes.map { ((($0.restoredAt != nil) ? "✓ " : "") + URL(fileURLWithPath: $0.path).lastPathComponent, $0.id) }
        case 4:
            items = [("全部日志", "all-logs")] + task.events.filter { $0.kind == "hook" }.suffix(64).reversed().map { ($0.statusTitle + " · " + $0.title, $0.id) }
        case 5: items = AgentMemoryScope.allCases.map { ($0.title, $0.rawValue) }
        case 6:
            do { let view = try AgentWiki.view(store: store, taskID: taskID, language: wikiTree.selectedLanguage), pages = view.pages; items = pages.map { ($0.title, $0.path) }; let preferred = pages.first { $0.path == wikiTree.selectedDocument }?.path ?? items.first?.value; wikiTree.show(pages, selected: preferred, root: view.root); state.stringValue = items.isEmpty ? "未生成" : try AgentWiki.status(store: store, taskID: taskID, language: wikiTree.selectedLanguage) }
            catch { items = []; wikiTree.show([], selected: nil); state.stringValue = error.localizedDescription }
        default:
            items = []; text.string = task.events.map { "\($0.title) · \($0.status)\n\($0.detail)" }.joined(separator: "\n\n────────\n\n")
        }
        if [1, 2, 3, 5, 6].contains(sections.selectedSegment) { text.string = "" }
        table.delegate = nil; table.reloadData(); table.deselectAll(nil); table.delegate = self
        updateTaskItemPicker()
        if sections.selectedSegment == 6 { if let selected = wikiTree.selectedDocument { _ = wikiTree.select(selected, notify: false); loadSelection(selected) } }
        else if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: items.firstIndex(where: { $0.value == preferred }) ?? 0), byExtendingSelection: false) }
    }
    private func refreshWikiCatalog() {
        guard sections.selectedSegment == 6, store.task(taskID) != nil else { return }
        updateWikiSharingState()
        do {
            let view = try AgentWiki.view(store: store, taskID: taskID, language: wikiTree.selectedLanguage), pages = view.pages; items = pages.map { ($0.title, $0.path) }; wikiTree.show(pages, selected: selection, root: view.root)
            if let selection, !pages.contains(where: { $0.path == selection }) { state.stringValue = dirty ? "文档已移出目录，草稿已保留" : "文档已移出目录" }
            else if selection == nil, let first = items.first { _ = wikiTree.select(first.value) }
        } catch { state.stringValue = error.localizedDescription }
    }
    func refreshLiveRecords(_ id: String) {
        if isPageVisible, sections.selectedSegment == 6 {
            updateWikiSharingState()
            let notice = store.wikiMaintenance.notice(workspace: store.task(taskID)?.workspace ?? "", language: wikiTree.selectedLanguage)
            if notice != wikiMaintenanceNotice { wikiMaintenanceNotice = notice; if !notice.isEmpty, !dirty, wikiSharingTask == nil { state.stringValue = notice } }
            return
        }
        guard id == taskID, isPageVisible, [3, 4].contains(sections.selectedSegment), !dirty, let task = store.task(taskID) else { return }
        let next = sections.selectedSegment == 3
            ? task.changes.map { "\($0.id)|\($0.afterHash ?? "")|\($0.afterKind ?? "")|\($0.restoredAt?.description ?? "")" }.joined() + task.status.rawValue + (task.pendingFileCapture?.id ?? "")
            : task.events.map { "\($0.id)|\($0.status)|\($0.duration ?? -1)|\($0.detail.count)|\($0.hook?.delivery ?? "")" }.joined()
        guard next != logSignature else { return }; logSignature = next
        let previous = selection, clip = text.enclosingScrollView?.contentView, origin = text.enclosingScrollView?.contentView.bounds.origin
        refresh()
        if let index = items.firstIndex(where: { $0.value == previous }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        if let clip, let origin { clip.scroll(to: origin); text.enclosingScrollView?.reflectScrolledClipView(clip) }
    }
    @objc private func generateWiki() {
        guard wikiSharingTask == nil, wikiTree.selectedLanguage != "legacy" else { return }
        guard let runtime = wikiRuntime else { if wikiPlanWindow?.confirmClosing() != false, canLeave() { onGenerateWiki?(wikiTree.selectedLanguage) }; return }
        do {
            let language = wikiTree.selectedLanguage
            guard let snapshot = wikiGeneration else { throw PetError("请刷新 Wiki 生成状态") }
            if snapshot.action == "pause", let id = snapshot.taskID {
                try AgentWiki.pauseGeneration(store: store, runtime: runtime, sourceID: taskID, language: language, expectedID: id)
                state.stringValue = "生成已暂停" + (dirty ? " · 草稿未保存" : "")
            } else {
                guard !["publishing", "preparing"].contains(snapshot.action), wikiPlanWindow?.confirmClosing() != false, canLeave() else { return }
                wikiSharingTask = Task { @MainActor [weak self] in
                    guard let self else { return }; defer { wikiSharingTask = nil; updateWikiSharingState() }
                    do {
                        try await connectWikiIndex()
                        if snapshot.action == "resume", try AgentWiki.generationState(store: store, runtime: runtime, sourceID: taskID, language: language).taskID != snapshot.taskID { throw PetError("生成状态已变化，请刷新后重试") }
                        let id = try await store.projectKnowledge.start(sourceID: taskID, language: language, runtime: runtime)
                        guard !Task.isCancelled else { return }
                        state.stringValue = snapshot.action == "resume" ? "已继续生成" : "已开始生成"; onWikiTask?(id)
                    } catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
                }
            }
        } catch { state.stringValue = error.localizedDescription }
        updateWikiSharingState()
    }
    func enableWikiGeneration(_ action: @escaping () -> Void) { enableWikiGeneration { _ in action() } }
    @objc private func openWikiCards() { guard ["zh", "en"].contains(wikiTree.selectedLanguage) else { return }; onOpenKnowledgeCards?(wikiTree.selectedLanguage) }
    func enableWikiGeneration(_ action: @escaping (String) -> Void) { onGenerateWiki = action; updateWikiSharingState() }
    func configureWikiRuntime(_ runtime: AgentRuntime, onTask: @escaping (String) -> Void) { wikiRuntime = runtime; onWikiTask = onTask; updateWikiSharingState() }
    private func openWikiPlan() {
        guard wikiSharingTask == nil else { return }
        do {
            guard let task = store.task(taskID), let workspace = task.workspace else { throw PetError("请选择项目文件夹") }
            if let old = wikiPlanWindow, old.isPageVisible { old.presentingWindow?.makeKeyAndOrderFront(nil); return }
            let original = try AgentFiles(workspace: workspace).root
            let next = try AgentWikiPlanWindow(workspace: workspace, storage: store.directory) { [weak self] in
                guard let self, let current = self.store.task(self.taskID), !current.archived, current.kind != "hook", (try? AgentFiles(workspace: current.workspace).root) == original, (try? self.store.agents.limits(current, store: self.store).readOnly) == false else { return false }
                let path = original.appendingPathComponent(AgentWikiPlan.configurationPath).path
                return FileManager.default.isWritableFile(atPath: FileManager.default.fileExists(atPath: path) ? path : original.path)
            }
            wikiPlanWindow = next; presentSettingsChild(next)
        } catch { state.stringValue = error.localizedDescription }
    }
    private func updateWikiSharingState() {
        let task = store.task(taskID), writable = task.map { !$0.archived && $0.kind != "hook" && (try? store.agents.limits($0, store: store).readOnly) == false } ?? false
        do {
            if let workspace = task?.workspace { wikiCitation = try AgentWiki.citation(store: store, workspace: workspace); wikiTree.setCitationState(wikiCitation?.enabled) }
            else { wikiCitation = nil; wikiTree.setCitationState(nil) }
        } catch { wikiCitation = nil; wikiTree.setCitationState(nil, problem: error.localizedDescription) }
        do {
            if let workspace = task?.workspace, ["zh", "en"].contains(wikiTree.selectedLanguage) { wikiMaintenance = try AgentWiki.maintenance(store: store, workspace: workspace, language: wikiTree.selectedLanguage); wikiTree.setMaintenanceState(wikiMaintenance?.options) }
            else { wikiMaintenance = nil; wikiTree.setMaintenanceState(nil) }
        } catch { wikiMaintenance = nil; wikiTree.setMaintenanceState(nil, problem: error.localizedDescription) }
        wikiGeneration = nil
        if let runtime = wikiRuntime, wikiTree.selectedLanguage != "legacy" {
            do { wikiGeneration = try AgentWiki.generationState(store: store, runtime: runtime, sourceID: taskID, language: wikiTree.selectedLanguage); generate.toolTip = nil }
            catch { generate.toolTip = error.localizedDescription }
        }
        generate.title = wikiGeneration?.title ?? "生成 Wiki"
        state.toolTip = nil
        if !dirty, wikiSharingTask == nil, let id = wikiGeneration?.taskID, let notice = store.projectKnowledge.notice(wikiID: id) {
            state.toolTip = notice.text
            if notice.signature != wikiKnowledgeSignature { wikiKnowledgeSignature = notice.signature; state.stringValue = notice.text }
        }
        wikiCards.isEnabled = task?.workspace != nil && ["zh", "en"].contains(wikiTree.selectedLanguage)
        wikiTree.setSharingState(busy: wikiSharingTask != nil, writable: writable, canRegenerate: wikiGeneration != nil && !["publishing", "preparing"].contains(wikiGeneration?.action ?? ""))
        generate.isEnabled = wikiSharingTask == nil && writable && (wikiRuntime == nil ? onGenerateWiki != nil : wikiGeneration != nil) && !["publishing", "preparing"].contains(wikiGeneration?.action ?? "") && wikiTree.selectedLanguage != "legacy"
    }
    private func connectWikiIndex() async throws {
        let tools = AgentTools(store: store, taskID: taskID), call = AgentToolCall(id: UUID().uuidString, name: "index_project", arguments: "{}"), directory = try tools.gitDirectory(for: call)
        if let reason = try tools.approvalReason(for: call, gitDirectory: directory) {
            let alert = NSAlert(); alert.messageText = "连接项目知识"; alert.informativeText = reason; alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
            guard try await presentWikiAlert(alert) == .alertFirstButtonReturn else { throw PetError("已取消") }; if let directory { store.update(taskID) { $0.gitDirectory = directory } }
        }
        _ = try await tools.execute(call, gitDirectory: directory); try Task.checkCancellation()
    }
    private func presentWikiAlert(_ alert: NSAlert) async throws -> NSApplication.ModalResponse {
        try Task.checkCancellation()
        guard let window = presentingWindow, window.isVisible, window.attachedSheet == nil else { throw PetError("请先完成当前窗口操作") }
        wikiSharingAlert = alert; defer { wikiSharingAlert = nil }
        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
    private func presentKnowledgeReview(_ review: AgentKnowledgeReviewWindow) {
        guard wikiReviewWindow?.hasPendingOperation != true else { state.stringValue = "请等待当前知识操作完成"; return }
        wikiReviewWindow?.close(); wikiReviewWindow = review; state.stringValue = ""
        review.onClose = { [weak self, weak review] in if self?.wikiReviewWindow === review { self?.wikiReviewWindow = nil } }
        presentSettingsChild(review)
    }
    private func knowledgeReviewApplied(_ message: String, language: String) {
        if activeSection == 6, wikiTree.selectedLanguage == language { wikiTree.show([], selected: nil); refresh() }
        state.stringValue = message
    }
    private func wikiReview(_ value: AgentWikiImportPreview, restoring: Bool) throws -> AgentKnowledgeReviewSnapshot {
        var impact = "\(value.metadata.documents.count) 页 Wiki · \(value.metadata.resources?.count ?? 0) 个资源；替换当前语言，原版本保留。"
        if value.metadata.branch != value.branch { impact += "来自分支：" + value.metadata.branch }
        if value.manuallyChanged > 0 { impact += "包含 \(value.manuallyChanged) 页外部修改。" }
        return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(value.branch, language: value.language), impact: impact, items: try AgentKnowledgeReviewSnapshot.wikiItems(value)) { [weak self] in
            guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
            try await AgentWiki.importWiki(value, store: self.store, taskID: self.taskID, restoring: restoring)
            return "已\(restoring ? "恢复" : "导入") \(value.metadata.documents.count) 页 Wiki"
        }
    }
    private func shareWiki(_ action: String) {
        guard wikiSharingTask == nil, (action == "citation" || ["zh", "en"].contains(wikiTree.selectedLanguage)), let task = store.task(taskID), let workspace = task.workspace else { return }
        let language = wikiTree.selectedLanguage
        if action == "citation" {
            do {
                guard let snapshot = wikiCitation, try AgentFiles(workspace: workspace).root.path == snapshot.workspace else { throw PetError("Wiki 引用设置或项目已变化，请刷新后重试") }
                try AgentWiki.setCitation(store: store, workspace: workspace, enabled: !snapshot.enabled, expected: snapshot.signature)
                state.stringValue = "Wiki 自动引用已" + (snapshot.enabled ? "关闭" : "开启") + (dirty ? " · 草稿未保存" : "")
            } catch { state.stringValue = error.localizedDescription }
            updateWikiSharingState(); return
        }
        if ["auto-update", "auto-export"].contains(action) { configureWikiMaintenance(action); return }
        if action == "open" {
            do { let files = try AgentFiles(workspace: workspace), folder = try files.resolve(AgentWiki.sharingPath(language)); guard FileManager.default.fileExists(atPath: folder.path) else { throw PetError("共享目录尚未创建，请先导出") }; NSWorkspace.shared.open(folder) }
            catch { state.stringValue = error.localizedDescription }; return
        }
        guard !dirty else { state.stringValue = "请先保存当前文档，草稿已保留"; return }
        if action == "update" { updateWiki(); return }
        if action == "regenerate" { regenerateWiki(); return }
        if action.hasPrefix("knowledge-") { shareProjectKnowledge(action, language: language); return }
        state.stringValue = action == "export" ? "正在导出 Wiki…" : "正在读取 Wiki…"
        wikiSharingTask = Task { @MainActor [weak self] in
            guard let self else { return }; defer { wikiSharingTask = nil; updateWikiSharingState() }
            do {
                if action == "export" {
                    let count = try await AgentWiki.exportWiki(store: store, taskID: taskID, language: language)
                    state.stringValue = "已导出 \(count) 页 · " + (try AgentWiki.sharingPath(language)) + (dirty ? " · 当前草稿未保存" : ""); return
                }
                try await connectWikiIndex(); try Task.checkCancellation()
                let restoring = action == "restore", versions = restoring ? try AgentWiki.wikiHistory(store: store, taskID: taskID, language: language) : []
                if restoring, versions.isEmpty { throw PetError("暂无可恢复的 Wiki 版本") }
                let choices = versions.map { AgentKnowledgeReviewVersion(id: $0.id, title: AgentKnowledgeReviewSnapshot.versionTitle($0.created, count: "\($0.metadata.documents.count) 页"), detail: String($0.id.prefix(8))) }
                let review = AgentKnowledgeReviewWindow(title: restoring ? "恢复 Wiki" : "导入 Wiki", action: restoring ? "恢复" : "导入", scope: URL(fileURLWithPath: workspace).lastPathComponent + " · " + (language == "zh" ? "简体中文" : "English"), versions: choices, load: { [weak self] index in
                    guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
                    let value: AgentWikiImportPreview
                    if restoring {
                        guard let index, versions.indices.contains(index) else { throw PetError("请选择实际存在的 Wiki 版本") }
                        value = try await AgentWiki.previewWikiRestore(versions[index], store: self.store, taskID: self.taskID, language: language)
                    } else { value = try await AgentWiki.previewWikiImport(store: self.store, taskID: self.taskID, language: language) }
                    return try self.wikiReview(value, restoring: restoring)
                }, onApplied: { [weak self] message in self?.knowledgeReviewApplied(message, language: language) })
                wikiSharingTask = nil; presentKnowledgeReview(review)
            } catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
        }
        updateWikiSharingState()
    }
    private func shareProjectKnowledge(_ action: String, language: String) {
        state.stringValue = action == "knowledge-export" ? "正在导出项目知识…" : "正在读取项目知识…"
        wikiSharingTask = Task { @MainActor [weak self] in
            guard let self else { return }; defer { wikiSharingTask = nil; updateWikiSharingState() }
            do {
                if action == "knowledge-export" {
                    let count = try await AgentProjectKnowledgeSharing.export(store: store, taskID: taskID, language: language)
                    state.stringValue = "已导出 \(count.pages) 页 Wiki · \(count.cards) 张卡片"; return
                }
                try await connectWikiIndex(); try Task.checkCancellation()
                let restoring = action == "knowledge-restore", versions = restoring ? try AgentProjectKnowledgeSharing.history(store: store, taskID: taskID, language: language) : []
                if restoring, versions.isEmpty { throw PetError("暂无可恢复的项目知识版本") }
                let choices = versions.map { AgentKnowledgeReviewVersion(id: $0.id, title: AgentKnowledgeReviewSnapshot.versionTitle($0.created, count: "\($0.wiki?.metadata.documents.count ?? 0) 页 / \($0.cards?.cards.count ?? 0) 张"), detail: String($0.id.prefix(8))) }
                let review = AgentKnowledgeReviewWindow(title: restoring ? "恢复项目知识" : "导入项目知识", action: restoring ? "恢复" : "导入", scope: language == "zh" ? "简体中文" : "English", versions: choices, load: { [weak self] index in
                    guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
                    let value: AgentProjectKnowledgeImport
                    if restoring {
                        guard let index, versions.indices.contains(index) else { throw PetError("请选择实际存在的项目知识版本") }
                        value = try await AgentProjectKnowledgeSharing.previewRestore(versions[index], store: self.store, taskID: self.taskID, language: language)
                    } else { value = try await AgentProjectKnowledgeSharing.previewImport(store: self.store, taskID: self.taskID, language: language) }
                    let documents = try value.wiki.map(AgentKnowledgeReviewSnapshot.wikiItems) ?? []
                    let cardItems = value.cards.map { AgentKnowledgeReviewSnapshot.cardItems($0.book) } ?? []
                    let wikiImpact = value.wiki != nil ? "Wiki：\(value.pageCount) 页" : restoring ? "Wiki：恢复为未发布" : "Wiki：保留当前版本"
                    let cardImpact = value.cards != nil ? "卡片：\(value.cardCount) 张" : restoring ? "卡片：恢复为未发布" : "卡片：保留当前版本"
                    return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(value.scope.branch, language: language), impact: wikiImpact + " · " + cardImpact + "；替换前的完整版本保留。", items: documents + cardItems) { [weak self] in
                        guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
                        try await AgentProjectKnowledgeSharing.apply(value, store: self.store, taskID: self.taskID)
                        return "已\(restoring ? "恢复" : "导入")项目知识 · \(value.pageCount) 页 / \(value.cardCount) 张"
                    }
                }, onApplied: { [weak self] message in self?.knowledgeReviewApplied(message, language: language) })
                wikiSharingTask = nil; presentKnowledgeReview(review)
            } catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
        }
        updateWikiSharingState()
    }
    private func configureWikiMaintenance(_ action: String) {
        guard let snapshot = wikiMaintenance else { return }
        let language = wikiTree.selectedLanguage, enabling = action == "auto-update" ? !snapshot.options.autoUpdate : !snapshot.options.autoExport
        guard !enabling || !dirty else { state.stringValue = "请先保存当前文档，草稿已保留"; return }
        wikiSharingTask = Task { @MainActor [weak self] in
            guard let self else { return }; defer { wikiSharingTask = nil; updateWikiSharingState() }
            do {
                guard let task = store.task(taskID), try AgentFiles(workspace: task.workspace).root.path == snapshot.workspace else { throw PetError("项目已变化，请刷新后重试") }
                if enabling {
                    if action == "auto-update" { try await connectWikiIndex() }
                    let alert = NSAlert(); alert.messageText = action == "auto-update" ? "开启自动更新？" : "开启自动导出？"
                    alert.informativeText = (language == "zh" ? "简体中文" : "English") + "\n" + (action == "auto-update" ? "应用运行期间，Git 提交变化后自动使用此任务的模型增量更新 Wiki，可能产生模型费用。人工修改的文档先保留，需手动审阅更新。" : "生成、更新或导入发布后，自动导出当前语言的 Wiki 与知识卡片。检测到外部文件修改时停止覆盖。")
                    alert.addButton(withTitle: "开启"); alert.addButton(withTitle: "取消")
                    guard try await presentWikiAlert(alert) == .alertFirstButtonReturn else { state.stringValue = "已取消"; return }
                }
                try Task.checkCancellation(); var options = snapshot.options
                if action == "auto-update" { options.autoUpdate = enabling } else { options.autoExport = enabling }
                try AgentWiki.setMaintenance(store: store, sourceID: taskID, language: language, options: options, expected: snapshot.signature)
                state.stringValue = (action == "auto-update" ? "自动更新已" : "自动导出已") + (enabling ? "开启" : "关闭") + (dirty ? " · 草稿未保存" : "")
            } catch { if !Task.isCancelled { state.stringValue = error.localizedDescription } }
        }
        updateWikiSharingState()
    }
    private func updateWiki() {
        guard let runtime = wikiRuntime, wikiPlanWindow?.confirmClosing() != false else { return }
        let language = wikiTree.selectedLanguage
        let review = AgentKnowledgeReviewWindow(title: "增量更新 Wiki", action: "更新", scope: language == "zh" ? "简体中文" : "English", load: { [weak self] _ in
            guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
            try await self.connectWikiIndex()
            let preview = try await AgentWiki.previewUpdate(store: self.store, runtime: runtime, sourceID: self.taskID, language: language)
            let commits = String(preview.baseCommit.prefix(8)) + " → " + String(preview.commit.prefix(8))
            let items = [AgentKnowledgeReviewItem(title: "提交差异", detail: commits, text: preview.diff, isDiff: true), AgentKnowledgeReviewItem(title: "变更文件", detail: "\(preview.changedPaths.count) 个文件", text: preview.changedPaths.joined(separator: "\n"))]
            return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(preview.snapshot.metadata.branch, language: language), impact: "\(preview.changedPaths.count) 个文件；使用当前任务模型，可能产生费用。原任务和文档保留。", items: items) { [weak self] in
                guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
                return try await AgentWiki.startUpdate(preview, store: self.store, runtime: runtime, sourceID: self.taskID)
            }
        }, onApplied: { [weak self] id in self?.state.stringValue = "已开始增量更新"; self?.onWikiTask?(id) })
        presentKnowledgeReview(review)
    }
    private func regenerateWiki() {
        guard let runtime = wikiRuntime, wikiPlanWindow?.confirmClosing() != false else { return }
        let language = wikiTree.selectedLanguage
        let review = AgentKnowledgeReviewWindow(title: "重新生成 Wiki", action: "重新生成", scope: language == "zh" ? "简体中文" : "English", load: { [weak self] _ in
            guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
            let preview = try AgentWiki.previewRegeneration(store: self.store, runtime: runtime, sourceID: self.taskID, language: language)
            let configuration = try AgentWikiPlan.load(files: AgentFiles(workspace: preview.workspace))
            guard configuration.hash == preview.configurationHash else { throw PetError("生成规划已变化，请重新预览") }
            let pages = try AgentWiki.view(store: self.store, taskID: self.taskID, language: language).pages
            var items = [AgentKnowledgeReviewItem(title: "生成规划", detail: configuration.path ?? "默认规划", text: configuration.text)]
            if !pages.isEmpty { items.append(AgentKnowledgeReviewItem(title: "当前文档", detail: "\(pages.count) 页", text: pages.map(\.title).joined(separator: "\n"))) }
            let target = pages.isEmpty ? "Wiki 与卡片" : "Wiki"
            let count = preview.documentCount.map { "\($0) 页" } ?? "自动规划"
            return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(preview.branch, language: language), impact: target + " · " + count + "；使用当前任务模型，可能产生费用。当前生成将暂停，原任务和文档保留。", items: items) { [weak self] in
                guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
                try await self.connectWikiIndex()
                return try await self.store.projectKnowledge.regenerate(preview, sourceID: self.taskID, runtime: runtime)
            }
        }, onApplied: { [weak self] id in self?.state.stringValue = "已重新开始生成"; self?.onWikiTask?(id) })
        presentKnowledgeReview(review)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: items[row].title); label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = items[row].value; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard items.indices.contains(table.selectedRow) else { return }
        guard canLeave() else {
            table.delegate = nil
            if let previous = items.firstIndex(where: { $0.value == selection }) { table.selectRowIndexes(IndexSet(integer: previous), byExtendingSelection: false) }
            table.delegate = self; return
        }
        loadSelection(items[table.selectedRow].value)
    }
    private func loadSelection(_ value: String) {
        defer { updateTaskItemPicker() }
        guard let task = store.task(taskID) else { return }
        load?.cancel(); selection = value; openedHash = nil; text.isEditable = false; state.stringValue = ""; resetDocumentMode()
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
                text.isEditable = scope != .effectiveInstructions && task.status != .running && (!scope.isInstructions || task.status != .waiting)
                save.isHidden = scope == .effectiveInstructions; save.isEnabled = text.isEditable
                allowInstruction.isHidden = scope != .effectiveInstructions; revokeInstruction.isHidden = allowInstruction.isHidden
                allowInstruction.isEnabled = !task.archived && ![.running, .waiting].contains(task.status) && store.instructions.report(task).issues.contains(where: \.needsPermission)
                revokeInstruction.removeAllItems(); revokeInstruction.addItem(withTitle: "撤销允许")
                for grant in task.instructionGrants ?? [] where grant.workspace == task.workspace {
                    let item = NSMenuItem(title: URL(fileURLWithPath: grant.path).lastPathComponent, action: nil, keyEquivalent: ""); item.representedObject = grant.path; item.toolTip = grant.path; revokeInstruction.menu?.addItem(item)
                }
                revokeInstruction.isEnabled = revokeInstruction.numberOfItems > 1; return
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
            do {
                let document = try AgentTextFile.decode(data, encoding: requestedEncoding); loadText(document, data: data, file: file, task: task)
                let name = sections.selectedSegment == 6 ? items.first(where: { $0.value == value })?.title ?? file.lastPathComponent : files.relative(file)
                state.stringValue = (text.isEditable ? "" : "只读 · ") + name; state.toolTip = files.relative(file)
            }
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
        if taskHosted, !documentOnly, !separate, let onOpenVideo {
            openedFile = file; text.string = file.lastPathComponent; state.stringValue = files.relative(file); open.isHidden = false; open.title = "打开标签页"
            try onOpenVideo(file); return
        }
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
        if taskHosted { open.title = "在默认应用打开" }
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
            if taskHosted, AgentVideoSnapshot.supports(target), let onOpenVideo { try onOpenVideo(target); return }
            if let row = items.firstIndex(where: { (try? files.resolve($0.value).path) == target.path }) {
                guard canLeave() else { return }
                if sections.selectedSegment == 6 { _ = wikiTree.select(items[row].value) }
                else { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
                _ = markdown.navigate(AgentMarkdownDocument.fragment(target))
            } else if AgentVideoSnapshot.supports(target) { try showVideo(target, files: files, separate: true) }
            else {
                let next = try AgentMarkdownSourceWindow(workspace: workspace, target: target)
                next.onAddSelection = onAddSelection; next.canAddSelection = { [weak self] in self?.canAddSelection == true }
                sourceWindow?.close(); sourceWindow = next; presentSettingsChild(next)
            }
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func allowInstructionFile() {
        guard let window = presentingWindow, let task = store.task(taskID), canLeave() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "允许引用"
        panel.message = "允许所选文件作为此任务的项目指令引用。"
        if let pending = store.instructions.report(task).issues.first(where: \.needsPermission) { panel.directoryURL = URL(fileURLWithPath: pending.path).deletingLastPathComponent() }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let file = panel.url else { return }
            do { try self.store.instructions.allow(file, store: self.store, taskID: self.taskID); self.loadSelection(AgentMemoryScope.effectiveInstructions.rawValue) }
            catch { self.state.stringValue = error.localizedDescription }
        }
    }
    @objc private func revokeInstructionFile() {
        guard let path = revokeInstruction.selectedItem?.representedObject as? String else { return }
        do { try store.instructions.revoke(path, store: store, taskID: taskID); loadSelection(AgentMemoryScope.effectiveInstructions.rawValue) }
        catch { state.stringValue = error.localizedDescription }
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
        let ownComparisonVisible = settingsHostWindow != nil && conflictWindow?.isPageVisible == true && conflictWindow?.presentingWindow === presentingWindow
        guard !saving, isPageVisible || ownComparisonVisible, [1, 6].contains(sections.selectedSegment), let task = store.task(taskID), let workspace = task.workspace, let file = openedFile, let path = selection, try AgentFiles(workspace: workspace).resolve(path) == file else { throw PetError("文档或任务已变化，草稿已保留") }
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
            self.presentingWindow?.makeKeyAndOrderFront(nil)
        })
        conflictWindow = next; presentSettingsChild(next)
    }
    @objc private func restoreFile() {
        guard let task = store.task(taskID), let change = task.changes.first(where: { $0.id == selection }) else { return }
        do { try AgentChanges.restore(change, taskID: taskID, store: store); refresh(); state.stringValue = "已撤回" }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func openItem() {
        guard let value = selection else { return }
        if taskHosted, !documentOnly, let onOpenVideo, let file = openedFile, AgentVideoSnapshot.supports(file) {
            do { try onOpenVideo(file) } catch { state.stringValue = error.localizedDescription }; return
        }
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
        if taskHosted, let onChooseWorkspaceFile { onChooseWorkspaceFile(); return }
        guard let window = presentingWindow, let workspace = store.task(taskID)?.workspace, canLeave() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.directoryURL = URL(fileURLWithPath: workspace)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url, let self else { return }
            do {
                let files = try AgentFiles(workspace: workspace)
                guard let task = self.store.task(self.taskID), try AgentFiles(workspace: task.workspace).root == files.root else { throw PetError("任务工作区已变化，请重新打开文件") }
                let safe = try files.resolve(file.path)
                guard !AgentFiles.sensitive(files.relative(safe)) else { throw PetError("不能打开敏感文件") }
                if AgentVideoSnapshot.supports(safe) { try self.showVideo(safe, files: files, separate: true) }
                else if AgentOffice.supports(safe.path) { self.showOffice(safe.path) }
                else {
                    if !self.openedFiles.contains(safe.path) { self.openedFiles.append(safe.path) }
                    self.selectItem(section: 1, value: safe.path)
                }
            } catch { self.state.stringValue = error.localizedDescription }
        }
    }
    @objc private func createOffice() {
        let index = newOffice.indexOfSelectedItem - 1; newOffice.selectItem(at: 0)
        guard AgentOffice.formats.indices.contains(index), let window = presentingWindow, let workspace = store.task(taskID)?.workspace else { return }
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
        guard wikiReviewWindow?.hasPendingOperation != true else { state.stringValue = "请等待当前知识操作完成"; return false }
        guard !saving else { state.stringValue = "正在保存…"; return false }
        do { try markdown.finishEditing() } catch { state.stringValue = error.localizedDescription; return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存的更改？"; alert.informativeText = openedFile?.lastPathComponent ?? state.stringValue; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }; dirty = false; return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { guard wikiPlanWindow?.confirmClosing() != false else { return false }; if canLeave() { load?.cancel(); return true }; return false }
    override func canLeaveSettings() -> Bool {
        let edited = dirty
        guard super.canLeaveSettings() else { return false }
        if edited, !dirty, let selection { loadSelection(selection) }
        return true
    }
    private func closeContent() { load?.cancel(); wikiSharingTask?.cancel(); wikiReviewWindow?.close(); wikiReviewWindow = nil; if let alert = wikiSharingAlert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }; wikiPlanWindow?.close(); wikiPlanWindow = nil; video.clear(); videoWindow?.close(); videoWindow = nil; markdown.clear(); sourceWindow?.close(); sourceWindow = nil; conflictWindow?.close(); conflictWindow = nil }
    override func settingsWillLeave() { closeContent() }
    func windowWillClose(_ notification: Notification) { closeContent() }
    func videoPreviewReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled || CommandLine.arguments.contains("--video-preview-check") else { return [:] }
        var result = await video.checkState(); result["saveVisible"] = !save.isHidden; result["compareVisible"] = !compare.isHidden; result["textEditable"] = text.isEditable; result["selection"] = selection ?? ""; result["openTitle"] = open.title
        if let videoWindow { result["separateWindowVisible"] = videoWindow.window?.isVisible == true; result["separatePlayer"] = await videoWindow.preview.checkState() }
        return result
    }
    func checkVideoWorkspace(action: String = "", time: Double? = nil, link: URL? = nil) async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        if let link { openDocumentLink(link) }
        if action == "new-window" || action == "open" { openItem() }
        if action == "refresh" { await video.checkWorkspace(action: "refresh") }
        if let time { await video.checkWorkspace(time: time) }
        return await videoPreviewReadback()
    }
    func markdownEditingReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled || AgentKnowledgePageHost.readbackEnabled || ["--markdown-edit-check", "--file-conflict-check", "--text-encoding-check", "--markdown-table-check", "--wiki-tree-check", "--wiki-plan-check", "--repo-wiki-overview-check"].contains(where: CommandLine.arguments.contains) else { return [:] }
        await markdown.waitForDiagrams()
        let data = try? fileData()
        var result: [String: Any] = ["draft": text.string, "encodedDraft": fileContent, "encodedDraftBase64": data?.base64EncodedString() ?? "", "draftHash": data.map(AgentFiles.hash) ?? "", "openedHash": openedHash ?? "", "dirty": dirty, "utf8BOM": fileBOM, "encoding": fileFormat.encoding.rawValue, "byteOrderMark": fileFormat.bom, "sourceEditable": text.isEditable, "preview": markdown.editingCheckState, "comparison": conflictWindow?.checkState ?? [:]]
        if CommandLine.arguments.contains("--file-conflict-check") { result["snapshotAllowsOverwrite"] = (try? conflictSnapshot().allowsOverwrite) ?? false }
        if CommandLine.arguments.contains("--text-encoding-check") { result["encodingMenuVisible"] = !encodingMenu.isHidden; result["state"] = state.stringValue; result["file"] = openedFile?.path ?? "" }
        if AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--wiki-tree-check") || CommandLine.arguments.contains("--wiki-plan-check") || CommandLine.arguments.contains("--repo-wiki-overview-check") { result["tree"] = wikiTree.checkState; result["wikiPlan"] = wikiPlanWindow?.checkState ?? [:]; result["wikiSharingBusy"] = wikiSharingTask != nil; result["wikiSharingConfirmation"] = wikiSharingAlert?.messageText ?? ""; result["wikiSharingSheetVisible"] = wikiSharingAlert.map { presentingWindow?.attachedSheet === $0.window } ?? false; result["state"] = state.stringValue; result["file"] = openedFile?.path ?? "" }
        if ["--wiki-generation-check", "--wiki-updates-check", "--project-knowledge-check"].contains(where: CommandLine.arguments.contains) { result["generation"] = ["title": generate.title, "enabled": generate.isEnabled, "taskID": wikiGeneration?.taskID ?? "", "action": wikiGeneration?.action ?? "", "includesCards": wikiGeneration?.includesCards ?? false, "problem": generate.toolTip ?? ""] }
        if CommandLine.arguments.contains("--wiki-updates-check") { result["maintenance"] = ["available": wikiMaintenance != nil, "autoUpdate": wikiMaintenance?.options.autoUpdate ?? false, "autoExport": wikiMaintenance?.options.autoExport ?? false, "notice": store.wikiMaintenance.notice(workspace: store.task(taskID)?.workspace ?? "", language: wikiTree.selectedLanguage)] }
        return result
    }
    func workspaceReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        var value = await markdownEditingReadback()
        value["taskID"] = taskID; value["section"] = sections.selectedSegment; value["selection"] = selection ?? ""; value["file"] = openedFile?.path ?? ""; value["state"] = state.stringValue
        value["taskHosted"] = taskHosted; value["documentOnly"] = documentOnly; value["visible"] = isPageVisible; value["items"] = items.map { ["title": $0.title, "value": $0.value] }
        if !video.isHidden { value["video"] = await videoPreviewReadback() }
        value["checks"] = ["documentUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === presentingWindow && presentingWindow?.isVisible == true,
            "recordWindowStaysHidden": window?.isVisible != true, "documentHasUsableWidth": taskFileArea.bounds.width - (taskNavigation.isHidden || compactTaskLayout == true ? 0 : taskNavigation.bounds.width + 12) >= 300,
            "documentHasUsableHeight": taskFileArea.bounds.height >= 140,
            "catalogFitsAvailableWidth": sections.isHidden || sections.fittingSize.width <= (pageContentView?.bounds.width ?? 0) - 28,
            "documentTabHasNoCatalog": !documentOnly || sections.isHidden && itemPicker.isHiddenOrHasHiddenAncestor]
        return value
    }
    func checkTaskDocument(text value: String? = nil, action: String? = nil) async {
        guard ["--task-workspace-check", "--video-workspace-check"].contains(where: CommandLine.arguments.contains) else { return }
        if let value, text.isEditable { displayMode.selectedSegment = 1; switchDocumentMode(); text.string = value; textDidChange(Notification(name: NSText.didChangeNotification, object: text)) }
        if action == "save" { saveFile(); await load?.value }
        else if action == "compare" { presentConflict() }
        else if action == "files" { toggleTaskFiles() }
    }
    func checkOpenKnowledgePlan() { if CommandLine.arguments.contains("--knowledge-page-check") { openWikiPlan() } }
    func checkKnowledgeReview(_ action: String, language: String? = nil) async -> AgentKnowledgeReviewWindow? {
        guard AgentKnowledgePageHost.readbackEnabled else { return nil }
        if let language { guard ["zh", "en"].contains(language) else { return nil }; wikiTree.setLanguage(language); guard wikiTree.onLanguage?(language) == true else { return nil } }
        shareWiki(action); await wikiSharingTask?.value; return wikiReviewWindow
    }
    func checkPresentKnowledgeReview(_ review: AgentKnowledgeReviewWindow) { if AgentKnowledgePageHost.readbackEnabled { presentKnowledgeReview(review) } }
    func checkEditKnowledgeDocument(_ value: String) async {
        guard CommandLine.arguments.contains("--knowledge-page-check") else { return }
        displayMode.selectedSegment = 1; switchDocumentMode(); text.string = value; textDidChange(Notification(name: NSText.didChangeNotification, object: text)); saveFile(); await load?.value
    }
    func checkKnowledgeSource(_ target: URL) { if CommandLine.arguments.contains("--knowledge-page-check") { openDocumentLink(target) } }
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
