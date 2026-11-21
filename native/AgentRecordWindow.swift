import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentRecordWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let store: AgentStore, taskID: String
    private let taskHosted: Bool, documentOnly: Bool, wikiOnly: Bool
    private let memoryTaskID: String?, memoryWorkspace: String?
    private let memoryCatalogScope: AgentMemoryScope?
    private let memorySettingsTarget: MemorySettingsTarget?
    private var openedMemoryWorkspace: String?, recoveryBlockedReason: String?
    private var openedMemoryExists: Bool?, memoryTopicError: String?, topicEditor: AgentNameEditor?
    private var openedMemorySource: AgentMemoryEditorSource?
    private let memoryPicker = NSPopUpButton()
    private let addMemory = NSButton(title: "新建主题…", target: nil, action: nil)
    private let revealMemory = NSButton(title: "在访达中显示", target: nil, action: nil)
    private let sections = NSSegmentedControl(labels: ["计划", "产物", "来源", "变更", "日志", "记忆", "Wiki"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView(), text = AgentMarkdownTextView(), state = AgentSettingsStatusField("文档保存状态")
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
    var onOpenAttachment: ((String, AgentAttachmentReadingTarget) throws -> Void)?
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
    private var wikiSharingAlert: AgentConfirmation?
    private var wikiReviewWindow: AgentKnowledgeReviewWindow?
    private struct WikiCatalogScope {
        let workspace: String, branch: String, language: String, root: String
    }
    private var wikiCatalogScope: WikiCatalogScope?
    private var unavailableWiki: (directory: AgentWikiTree.RecoveryState, mode: Int, preview: AgentMarkdownReader.ViewRecovery?)?
    private var wikiCitation: (enabled: Bool, signature: String, workspace: String)?
    private var wikiMaintenance: (options: AgentWikiMaintenanceOptions, signature: String, workspace: String)?
    private var wikiMaintenanceNotice = ""
    private var items: [(title: String, value: String)] = [], selection: String?, openedHash: String?, load: Task<Void, Never>?
    private var openedFiles: [String] = []
    private var dirty = false { didSet { if dirty != oldValue { onWorkspaceChange?() } } }
    private var activeSection = 0, saving = false
    var onWorkspaceChange: (() -> Void)?
    var onWindowClose: (() -> Void)?
    var workspaceHasUnsavedChanges: Bool { dirty || wikiPlanWindow?.hasUnsavedChanges == true }
    var recoveryWikiPlan: AgentWikiPlanWindow? { wikiPlanWindow }
    var isKnowledgeWikiReader: Bool { wikiOnly }
    var canPreserveForQuit: Bool { store.task(taskID).map { $0.sideTask?.retained != false } == true }
    override var minimumSettingsContentHeight: CGFloat { sections.selectedSegment == 5 ? 220 : super.minimumSettingsContentHeight }
    var workspaceDocumentURL: URL? { documentOnly ? openedFile ?? selection.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } : nil }
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
    private var pendingConflict: AgentFileConflictWindow.RecoveryState?
    private var videoWindow: AgentVideoWindow?
    private var pendingWikiVideoPage = false
    private var restoringVideo: (file: String, state: AgentVideoPlayback)?
    private var pendingTextViewport: AgentTextViewport?, applyingTextViewport = false, textViewportScheduled = false
    private var rememberedTextFocus = false
    private var textFocusRequested = false
    private var hasInlineVideoPlayback: Bool { !video.isHidden && openedFile.map(AgentVideoSnapshot.supports) == true }
    var hasIndependentVideoWindow: Bool { videoWindow?.hasIndependentWindow == true }
    var hasIndependentWorkspaceChild: Bool { hasIndependentVideoWindow || sourceWindow?.hasIndependentWindow == true || sourceWindow?.hasIndependentVideoWindow == true || wikiPlanWindow?.hasIndependentWindow == true }
    var hasVideoPlayback: Bool { hasInlineVideoPlayback || hasIndependentVideoWindow || sourceWindow?.hasVideoPlayback == true }
    init(store: AgentStore, taskID: String?, section: Int = 0, memoryOnly: Bool = false, wikiOnly: Bool = false, taskHosted: Bool = false, documentOnly: Bool = false, memoryWorkspace: String? = nil, memoryCatalogScope: AgentMemoryScope? = nil, memorySettingsTarget: MemorySettingsTarget? = nil) {
        self.store = store; self.taskID = taskID ?? ""; self.taskHosted = taskHosted; self.documentOnly = documentOnly; self.wikiOnly = wikiOnly; self.memoryTaskID = taskID; self.memoryWorkspace = memoryWorkspace
        self.memoryCatalogScope = memoryCatalogScope; self.memorySettingsTarget = memorySettingsTarget
        let taskID = self.taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = store.task(taskID)?.title ?? "任务记录"; window.minSize = NSSize(width: 650, height: 450); window.center(); window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window); window.delegate = self; text.delegate = self; text.setAccessibilityLabel("文档原文")
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
        wikiTree.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
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
        viewer.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(textViewportChanged(_:)), name: NSView.boundsDidChangeNotification, object: viewer.contentView)
        displayMode.target = self; displayMode.action = #selector(switchDocumentMode(_:)); displayMode.selectedSegment = 0; displayMode.setAccessibilityLabel("Markdown 显示方式")
        markdown.onLink = { [weak self] url in self?.openDocumentLink(url) }
        markdown.canEdit = { [weak self] in guard let self, self.text.isEditable, let task = self.store.task(self.taskID), let file = self.markdownFile else { return false }; return self.fileIsEditable(task, file: file) }
        markdown.onSourceChanged = { [weak self] value in
            guard let self else { return }; self.pendingTextViewport = nil; self.text.string = value; self.text.undoManager?.removeAllActions()
            do { self.dirty = AgentFiles.hash(try self.fileData()) != self.openedHash; self.state.stringValue = self.dirty ? "未保存" : self.markdownFile?.lastPathComponent ?? "" }
            catch { self.dirty = true; self.state.stringValue = error.localizedDescription }
            self.onWorkspaceChange?()
        }
        markdown.onEditError = { [weak self] message in self?.state.stringValue = message }
        markdown.onViewportChange = { [weak self] in self?.onWorkspaceChange?() }
        AgentTextEncoding.prepareMenu(encodingMenu); encodingMenu.target = self; encodingMenu.action = #selector(reopenEncoding); encodingMenu.isHidden = true
        let pane = NSView(); [displayMode, encodingMenu, NSView(), sourceAdd].forEach { readingToolbar.addArrangedSubview($0) }; sourceSelection.update()
        readingToolbar.heightAnchor.constraint(equalToConstant: 24).isActive = true
        video.isHidden = true
        for child in [viewer, markdown, video] { pane.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([child.topAnchor.constraint(equalTo: pane.topAnchor), child.leadingAnchor.constraint(equalTo: pane.leadingAnchor), child.trailingAnchor.constraint(equalTo: pane.trailingAnchor), child.bottomAnchor.constraint(equalTo: pane.bottomAnchor)]) }
        video.onPlaybackChange = { [weak self] in self?.onWorkspaceChange?() }
        let documentPane = NSStackView(views: [readingToolbar, pane]); documentPane.orientation = .vertical; documentPane.distribution = .fill; documentPane.spacing = 6
        if memoryCatalogScope != nil {
            memoryPicker.target = self; memoryPicker.action = #selector(selectMemoryFile)
            memoryPicker.setAccessibilityLabel("记忆文件"); memoryPicker.identifier = .init("memory-files")
            memoryPicker.cell?.lineBreakMode = .byTruncatingMiddle
            memoryPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            save.identifier = .init("memory-save")
            addMemory.target = self; addMemory.action = #selector(createMemoryTopic); addMemory.identifier = .init("memory-create-topic")
            revealMemory.target = self; revealMemory.action = #selector(revealMemoryFile); revealMemory.identifier = .init("memory-reveal-file")
            let toolbar = NSStackView(views: [memoryPicker, NSView(), addMemory, revealMemory]); toolbar.alignment = .centerY; toolbar.spacing = 8
            toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
            documentPane.insertArrangedSubview(toolbar, at: 0)
        }
        for child in documentPane.arrangedSubviews { child.widthAnchor.constraint(equalTo: documentPane.widthAnchor).isActive = true }
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
        let singleMemory = memoryCatalogScope != nil || memoryOnly && memoryTaskID == nil && memoryWorkspace != nil
        navigation.isHidden = singleMemory
        NSLayoutConstraint.activate([sections.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), sections.centerXAnchor.constraint(equalTo: content.centerXAnchor), navigation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), navigation.widthAnchor.constraint(equalToConstant: singleMemory ? 0 : 165), navigation.topAnchor.constraint(equalTo: memoryOnly || wikiOnly ? content.topAnchor : sections.bottomAnchor, constant: memoryOnly || wikiOnly ? 14 : 16), navigation.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12), documentPane.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: singleMemory ? 0 : 12), documentPane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), documentPane.topAnchor.constraint(equalTo: navigation.topAnchor), documentPane.bottomAnchor.constraint(equalTo: navigation.bottomAnchor), actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
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
    @discardableResult func openWorkspaceDocument(_ path: String) throws -> Bool {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }; let (files,file) = try AgentWorkspaceScope.location(task,path:path)
        guard !AgentFiles.sensitive(files.relative(file)) else { throw PetError("不能打开受保护的文件") }
        guard selection == file.path || canLeave() else { return false }
        if documentOnly { window?.title = file.lastPathComponent }
        if !openedFiles.contains(file.path) { openedFiles.append(file.path) }
        selectItem(section: 1, value: file.path)
        return selection == file.path
    }
    override func pageDidLayout() {
        defer { scheduleTextViewport(); markdown.scheduleViewRecovery() }
        guard taskHosted, let content = pageContentView, documentLeading != nil else { return }
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
    private func updateMemoryPicker() {
        guard memoryCatalogScope != nil else { return }
        memoryPicker.removeAllItems()
        for item in items {
            memoryPicker.addItem(withTitle: item.title)
            memoryPicker.lastItem?.representedObject = item.value
        }
        restoreMemoryPickerSelection()
    }
    private func restoreMemoryPickerSelection() {
        if let selection, let index = items.firstIndex(where: { $0.value == selection }) { memoryPicker.selectItem(at: index) }
    }
    @objc private func selectMemoryFile() {
        guard let value = memoryPicker.selectedItem?.representedObject as? String, value != selection else { return }
        selectItem(section: 5, value: value)
        restoreMemoryPickerSelection()
        if selection == value { presentingWindow?.makeFirstResponder(text) }
    }
    private var memoryEditable: Bool {
        guard let memoryTaskID else { return true }
        guard let task = store.task(memoryTaskID) else { return false }
        return !task.archived && ![.running, .waiting].contains(task.status)
    }
    @objc private func createMemoryTopic() {
        guard let scope = memoryCatalogScope, let window = presentingWindow, !window.hasBlockingDialog, topicEditor == nil, memoryEditable else { return }
        if settingsHostWindow != nil, memorySettingsTarget != nil {
            do {
                let destination = try AgentMemory.topicDestination(scope, store: store, taskID: memoryTaskID, workspace: memoryWorkspace)
                let wasDirty = dirty
                guard canLeave() else { return }
                if wasDirty { refreshCatalog(selecting: selection) }
                presentSettingsChild(makeTopicPage(scope, destination: destination))
            } catch { state.stringValue = error.localizedDescription }
            return
        }
        guard canLeave() else { return }
        var created: AgentMemoryDocument?
        let editor = AgentNameEditor(title: "新建记忆主题", label: "主题文件名", value: "", actionTitle: "创建", save: { [weak self] name in
            guard let self, memoryEditable else { throw PetError("此记忆当前只读") }
            created = try AgentMemory.createTopic(name, scope: scope, store: store, taskID: memoryTaskID, workspace: memoryWorkspace)
        }, onClose: { [weak self] in
            guard let self else { return }
            topicEditor = nil
            if let created { refreshCatalog(selecting: created.selection); presentingWindow?.makeFirstResponder(text) }
        })
        topicEditor = editor
        editor.begin(in: window)
    }
    private func makeTopicPage(_ scope: AgentMemoryScope, destination: AgentMemory.TopicDestination) -> AgentMemoryTopicPage {
        let page = AgentMemoryTopicPage(destination: destination, scope: settingsContext?.title ?? scope.title) { [weak self] name in
            guard let self, memoryEditable, let target = memorySettingsTarget else { throw PetError("此记忆当前只读") }
            if scope == .project { try target.context.requireCurrent(store) }
            return try AgentMemory.createTopic(name, scope: scope, store: store, taskID: memoryTaskID, workspace: memoryWorkspace,
                expectedDestination: destination)
        }
        page.onCreated = { [weak self] document in
            guard let self else { return }
            refreshCatalog(selecting: document.selection); presentingWindow?.makeFirstResponder(text)
        }
        return page
    }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        guard page.kind == "memory-topic", let scope = memoryCatalogScope, memorySettingsTarget?.entry == scope else { return nil }
        return makeTopicPage(scope, destination: try AgentMemoryTopicPage.Recovery.decode(page).destination)
    }
    @objc private func revealMemoryFile() {
        guard let selection, let document = AgentMemoryDocument(selection: selection) else { return }
        do { NSWorkspace.shared.activateFileViewerSelecting([try AgentMemory.revealURL(document, store: store, taskID: memoryTaskID, workspace: openedMemoryWorkspace ?? memoryWorkspace)]) }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func selectTaskItem() { if let value = itemPicker.selectedItem?.representedObject as? String { selectItem(section: sections.selectedSegment, value: value); updateTaskItemPicker() } }
    @objc private func toggleTaskFiles() { filesRequested.toggle(); pageDidLayout() }
    func prepareWorkspaceNavigation() -> Bool {
        guard wikiReviewWindow?.hasPendingOperation != true else { state.stringValue = "请等待当前知识操作完成"; return false }
        guard !saving else { state.stringValue = "正在保存…"; return false }
        if isPageVisible, !viewer.isHidden, !textViewportScheduled, presentingWindow?.firstResponder === text { rememberedTextFocus = true }
        guard wikiPlanWindow?.prepareWorkspaceNavigation() != false else { return false }
        do { try markdown.prepareWorkspaceNavigation(); video.pause(); videoWindow?.preview.pause(); sourceWindow?.prepareWorkspaceNavigation(); return true } catch { state.stringValue = error.localizedDescription; return false }
    }
    struct MemorySettingsTarget: Codable, Equatable {
        let entry: AgentMemoryScope
        let context: AgentSettingsRecovery.Context
        var canOpen: [AgentMemoryScope] {
            if entry.hasTopics { return [entry] }
            if context.taskID != nil { return AgentMemoryScope.allCases }
            return context.workspace == nil ? [.global, .userInstructions] : [.project, .instructions, .localInstructions]
        }
    }
    struct MemorySettingsRecovery: Codable {
        var version = 1
        let target: MemorySettingsTarget
        let document: String
        let openedHash: String?
        let exists: Bool?
        let source: AgentMemoryEditorSource?
        let draft: String?
        let viewport: AgentTextViewport?

        static func decode(_ page: AgentSettingsRecovery.Page) throws -> Self {
            guard page.kind == "memory-editor" else { throw PetError("设置草稿不属于记忆编辑器") }
            let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state),
                keys: ["version", "target", "document", "openedHash", "exists", "source", "draft", "viewport"])
            let target = try AgentSettingsRecovery.object(raw["target"] ?? NSNull(), keys: ["entry", "context"])
            if let context = target["context"] { try AgentSettingsRecovery.validateContext(context) }
            if let source = raw["source"] { _ = try AgentSettingsRecovery.object(source, keys: ["path", "directoryIdentity"]) }
            if let viewport = raw["viewport"] { try AgentTextViewport.validateObject(viewport) }
            let value = try JSONDecoder().decode(Self.self, from: page.state)
            guard value.version == 1, value.target.context.valid, value.target.canOpen.contains(value.target.entry),
                  value.target.entry != .project || value.target.context.workspace != nil,
                  let document = AgentMemoryDocument(selection: value.document), value.target.canOpen.contains(document.scope),
                  AgentSettingsRecovery.validHash(value.openedHash), value.source?.valid != false, value.viewport?.valid != false,
                  (value.openedHash == nil) == (value.exists == nil),
                  value.openedHash != nil || value.source == nil && value.draft == nil && value.viewport == nil,
                  value.openedHash == nil || (value.source == nil) == [.summary, .effectiveInstructions].contains(document.scope),
                  document.scope != .effectiveInstructions || value.draft == nil else { throw PetError("原记忆范围或草稿无效，记录已保留") }
            return value
        }
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        guard let memorySettingsTarget, topicEditor == nil, let selection else { return nil }
        let value = try MemorySettingsRecovery(target: memorySettingsTarget, document: selection, openedHash: openedHash,
            exists: openedMemoryExists, source: openedMemorySource, draft: dirty ? text.string : nil, viewport: captureTextViewport())
        let page = try AgentSettingsRecovery.page("memory-editor", value)
        _ = try MemorySettingsRecovery.decode(page); return page
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        let value = try MemorySettingsRecovery.decode(page)
        guard let memorySettingsTarget, value.target == memorySettingsTarget else { throw PetError("记忆草稿所属范围已变化") }
        try memorySettingsTarget.context.requireCurrent(store)
        refreshCatalog(selecting: value.document)
        let sameSource = selection == value.document && openedMemorySource == value.source && openedMemoryExists == value.exists
        if let draft = value.draft {
            let unchanged = sameSource && openedHash == value.openedHash
            if !items.contains(where: { $0.value == value.document }), let document = AgentMemoryDocument(selection: value.document) {
                items.append((document.topic ?? document.scope.title, value.document)); table.reloadData()
            }
            selection = value.document
            openedMemoryWorkspace = memorySettingsTarget.context.workspace; openedMemorySource = value.source
            openedMemoryExists = value.exists; openedHash = value.openedHash
            text.string = draft; text.isEditable = memoryEditable; dirty = true
            save.isHidden = false; save.isEnabled = memoryEditable; revealMemory.isEnabled = sameSource && value.exists == true
            state.stringValue = unchanged ? "已恢复未保存内容" : "原文件已变化，草稿已恢复"
            if let document = AgentMemoryDocument(selection: value.document) { updateMemoryHeading(document) }
            updateMemoryPicker(); text.undoManager?.removeAllActions()
            try prepareTextViewport(value.viewport)
        } else if value.openedHash != nil {
            guard sameSource else { throw PetError("原记忆文件暂不可用，阅读位置已保留") }
            if openedHash == value.openedHash { try prepareTextViewport(value.viewport) }
        } else if selection != value.document {
            throw PetError("原记忆页面暂不可用，恢复记录已保留")
        }
        scheduleTextViewport(); onWorkspaceChange?()
    }
    struct RecoveryState: Codable {
        var version = 1
        var taskID: String
        var documentOnly: Bool
        var section: Int
        var selection: String?
        var file: String?
        var memoryWorkspace: String?
        var openedHash: String?
        var text: String?
        var encoding: String
        var bom: Bool
        var mode: Int
        var dirty: Bool
        var video: AgentVideoPlayback?
        var memoryExists: Bool? = nil
        var videoWindow: AgentVideoWindow.RecoveryState? = nil
        var textViewport: AgentTextViewport? = nil
        var markdownViewport: AgentMarkdownReader.ViewRecovery? = nil
        var sourceWindow: AgentMarkdownSourceWindow.RecoveryState? = nil
        var wikiPlan: AgentWikiPlanWindow.RecoveryState? = nil
        var wikiDirectory: AgentWikiTree.RecoveryState? = nil
        var versionReview: AgentKnowledgeVersionPosition? = nil
        var conflict: AgentFileConflictWindow.RecoveryState? = nil
    }
    static func recoveryState(_ page: AgentWorkspaceRecovery.Page) throws -> RecoveryState {
        guard page.kind == "record", page.asset == nil,
              let object = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "taskID", "documentOnly", "section", "selection", "file", "memoryWorkspace", "openedHash", "text", "encoding", "bom", "mode", "dirty", "video", "memoryExists", "videoWindow", "textViewport", "markdownViewport", "sourceWindow", "wikiPlan", "wikiDirectory", "versionReview", "conflict"]) else { throw PetError("文本恢复记录格式不受支持，原草稿已保留") }
        if let raw = object["textViewport"], !(raw is NSNull) { try AgentTextViewport.validateObject(raw) }
        if let raw = object["markdownViewport"], !(raw is NSNull) { try AgentMarkdownReader.ViewRecovery.validateObject(raw) }
        if let raw = object["sourceWindow"], !(raw is NSNull) { try AgentMarkdownSourceWindow.RecoveryState.validateObject(raw) }
        if let raw = object["wikiPlan"], !(raw is NSNull) { try AgentWikiPlanWindow.RecoveryState.validateObject(raw) }
        if let raw = object["wikiDirectory"], !(raw is NSNull) { try AgentWikiTree.RecoveryState.validateObject(raw) }
        if let raw = object["versionReview"], !(raw is NSNull) { try AgentKnowledgeVersionPosition.validateObject(raw) }
        if let raw = object["conflict"], !(raw is NSNull) { try AgentFileConflictWindow.RecoveryState.validateObject(raw) }
        if let video = object["video"] {
            guard let video = video as? [String: Any], Set(video.keys).isSubset(of: ["version", "hash", "time", "duration", "rate", "volume", "muted"]) else { throw PetError("视频播放记录格式不受支持，原记录已保留") }
        }
        if let raw = object["videoWindow"], !(raw is NSNull) {
            try AgentVideoWindow.validateRecoveryObject(raw)
        }
        let value = try JSONDecoder().decode(RecoveryState.self, from: page.state)
        guard value.version == 1, value.taskID == page.taskID, (0...6).contains(value.section), [0, 1].contains(value.mode),
              (value.dirty || value.wikiPlan?.dirty == true) == page.dirty, AgentTextEncoding(rawValue: value.encoding) != nil,
              !value.dirty || (value.text != nil && value.openedHash?.count == 64),
              value.file.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true,
              value.videoWindow?.valid != false, value.textViewport?.valid != false, value.markdownViewport?.valid != false, value.sourceWindow?.valid != false,
              value.wikiPlan?.valid != false, value.wikiPlan.map({ $0.taskID == value.taskID }) ?? true else { throw PetError("文本恢复版本或所属文件无效，原草稿已保留") }
        if let conflict = value.conflict {
            guard conflict.valid, [1, 6].contains(value.section), value.file == conflict.file, value.openedHash != nil, value.video == nil else {
                throw PetError("文件比较与原文档不符，原草稿已保留")
            }
        }
        if let directory = value.wikiDirectory {
            guard value.section == 6, directory.valid,
                  directory.document == nil || directory.document == value.selection || directory.document.map({ directory.workspace + "/" + $0 }) == value.file else {
                throw PetError("Wiki 目录与原文档不符，阅读记录已保留")
            }
        }
        if let review = value.versionReview {
            guard value.section == 6, review.valid, review.context.taskID == value.taskID, review.context.kind != .cards,
                  value.wikiDirectory.map({ $0.workspace == review.context.workspace && $0.branch == review.context.branch && $0.language == review.context.language }) != false else {
                throw PetError("知识版本与原 Wiki 页面不符，阅读记录已保留")
            }
        }
        if value.memoryExists != nil {
            guard value.section == 5, let selection = value.selection, AgentMemoryDocument(selection: selection)?.topic != nil else { throw PetError("主题记忆的原文件身份无效，草稿已保留") }
        }
        if value.textViewport != nil || value.markdownViewport != nil {
            guard value.video == nil, value.openedHash != nil else { throw PetError("文本位置没有对应正文，原记录已保留") }
        }
        if value.markdownViewport != nil { guard let file = value.file, ["md", "markdown"].contains(URL(fileURLWithPath: file).pathExtension.lowercased()) else { throw PetError("Markdown 编辑位置没有对应文档，原记录已保留") } }
        if let video = value.video {
            guard video.isValid, !value.dirty, value.text == nil, [1, 2, 6].contains(value.section),
                  let file = value.file, AgentVideoSnapshot.supports(URL(fileURLWithPath: file)),
                  value.selection == file || value.selection.flatMap(URL.init(string:))?.path == file else { throw PetError("视频播放位置或所属文件无效，原记录已保留") }
        }
        return value
    }
    func captureWorkspaceRecovery() async throws -> AgentWorkspaceRecovery.Page {
        guard !saving, wikiSharingTask == nil, wikiReviewWindow?.hasPendingOperation != true else { throw PetError("请先完成当前文档操作") }
        let playback = hasInlineVideoPlayback ? await video.capturePlayback() : nil
        let child = try await videoWindow?.captureWorkspaceRecovery(includingHosted: wikiOnly)
        var source: AgentMarkdownSourceWindow.RecoveryState?
        while let current = sourceWindow {
            let value = try await current.captureWorkspaceRecovery()
            guard sourceWindow === current else { continue }; source = value; break
        }
        let markdownViewport = try unavailableWiki?.preview ?? (markdownFile == nil ? nil : markdown.captureViewRecovery(source: text.string))
        let plan = try wikiPlanWindow?.captureWorkspaceRecovery()
        let viewport = try captureTextViewport()
        let directory = try unavailableWiki?.directory ?? (sections.selectedSegment == 6 ? wikiCatalogScope : nil).map {
            try wikiTree.captureRecovery(workspace: $0.workspace, branch: $0.branch)
        }
        let value = RecoveryState(taskID: taskID, documentOnly: documentOnly, section: sections.selectedSegment, selection: selection,
            file: openedFile?.path, memoryWorkspace: openedMemoryWorkspace ?? memoryWorkspace, openedHash: openedHash,
            text: dirty ? text.string : nil, encoding: fileFormat.encoding.rawValue, bom: fileFormat.bom, mode: unavailableWiki?.mode ?? displayMode.selectedSegment, dirty: dirty, video: playback,
            memoryExists: selection.flatMap(AgentMemoryDocument.init(selection:))?.topic == nil ? nil : openedMemoryExists,
            videoWindow: child, textViewport: viewport, markdownViewport: markdownViewport, sourceWindow: source, wikiPlan: plan, wikiDirectory: directory,
            versionReview: try wikiReviewWindow?.captureVersionPosition(), conflict: try conflictWindow?.captureRecovery() ?? pendingConflict)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let page = AgentWorkspaceRecovery.Page(taskID: taskID, kind: "record", state: try encoder.encode(value), dirty: dirty || plan?.dirty == true, asset: nil)
        _ = try Self.recoveryState(page); return page
    }
    func restoreWorkspaceRecovery(_ page: AgentWorkspaceRecovery.Page) throws {
        let value = try Self.recoveryState(page)
        guard value.taskID == taskID, value.documentOnly == documentOnly, let task = store.task(taskID) else { throw PetError("恢复草稿所属任务已变化") }
        let format = AgentTextFormat(encoding: AgentTextEncoding(rawValue: value.encoding)!, bom: value.bom)
        if let file = value.file { encodings[file] = format.encoding }
        restoringVideo = value.video.flatMap { state in value.file.map { ($0, state) } }
        defer { restoringVideo = nil }
        var issue: String?, currentHash: String?, wikiDocument: String?
        if var directory = value.wikiDirectory {
            if value.dirty, let file = value.file {
                let prefix = directory.workspace + "/"
                guard file.hasPrefix(prefix + directory.root + "/"), URL(fileURLWithPath: file).standardizedFileURL.path == file else {
                    throw PetError("Wiki 草稿与原目录不符，原草稿已保留")
                }
                let document = String(file.dropFirst(prefix.count))
                guard directory.document == nil || directory.document == document else {
                    throw PetError("Wiki 草稿与原文档不符，原草稿已保留")
                }
                directory.document = document
                wikiDocument = document
            }
            do {
                let scope = try store.knowledgeCards.scope(task)
                guard scope.root == directory.workspace, scope.branch == directory.branch else { throw PetError("Wiki 所属项目或分支已变化") }
                let current = try AgentWiki.view(store: store, taskID: taskID, language: directory.language)
                guard current.root == directory.root else { throw PetError("Wiki 发布目录已变化") }
                guard directory.document.map({ path in current.pages.contains { $0.path == path } }) != false else { throw PetError("原 Wiki 文档暂不可用") }
            } catch {
                guard value.dirty, wikiDocument != nil else { throw error }
                unavailableWiki = (directory, value.mode, value.markdownViewport)
                issue = AgentFileConflictSnapshot.readFailure(error).message
            }
            wikiTree.prepareRecovery(directory)
        }
        sections.selectedSegment = value.section
        refreshCatalog(selecting: value.selection, restoringWiki: value.wikiDirectory != nil)
        if !value.dirty {
            if documentOnly, let file = value.file { _ = try openWorkspaceDocument(file) }
            else if value.wikiDirectory == nil, let selection = value.selection { selectItem(section: value.section, value: selection) }
            if value.video != nil, openedFile?.path != value.file || video.isHidden { throw PetError("原视频暂不可访问，播放记录已保留") }
            if !displayMode.isHidden { displayMode.selectedSegment = value.mode; switchDocumentMode() }
            try restoreTextViewports(value); try restoreSourceWindow(value.sourceWindow); restoreVideoWindow(value.videoWindow); try restoreWikiPlan(value.wikiPlan)
            try restoreVersionReview(value.versionReview); pendingConflict = value.conflict; return
        }
        guard let draft = value.text, let hash = value.openedHash else { throw PetError("恢复草稿缺少原始版本") }
        if let path = value.file, [1, 6].contains(value.section) {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            if issue == nil {
                do {
                    try requireWikiFile(file, task: task)
                    let (files, current) = try AgentWorkspaceScope.location(task, path: path)
                    guard current == file, !AgentFiles.sensitive(files.relative(file)) else { throw PetError("原文件位置或访问范围已变化") }
                    currentHash = try files.fileHash(file, maximum: 4_000_000)
                } catch { issue = AgentFileConflictSnapshot.readFailure(error).message }
            }
            loadText(AgentTextFile(text: draft, format: format), data: Data(draft.utf8), file: file, task: task)
            selection = wikiDocument ?? path; openedFile = file
            if !openedFiles.contains(path) { openedFiles.append(path) }
            if documentOnly { window?.title = file.lastPathComponent }
        } else if value.section == 5, let selection = value.selection, let document = AgentMemoryDocument(selection: selection), document.scope != .effectiveInstructions {
            do {
                let current = try AgentMemory.snapshot(document.scope, store: store, taskID: taskID, workspace: value.memoryWorkspace, topic: document.topic)
                if let existed = value.memoryExists, existed != current.exists { throw PetError("主题文件已变化，原草稿已保留") }
                currentHash = current.hash
            }
            catch { issue = error.localizedDescription }
            self.selection = selection; openedMemoryWorkspace = value.memoryWorkspace; openedMemoryExists = value.memoryExists
            text.string = draft; text.isEditable = issue == nil && memoryEditable
            save.isHidden = false; save.isEnabled = text.isEditable
        } else { throw PetError("恢复草稿没有可写入的原始对象") }
        openedHash = hash; dirty = true; recoveryBlockedReason = issue
        if let issue {
            text.isEditable = false; save.isEnabled = false; compare.isHidden = openedFile == nil
            state.stringValue = "草稿只读 · " + issue
        }
        else { state.stringValue = currentHash == hash ? "已恢复未保存内容" : "文件已更改，草稿已恢复；保存前请比较" }
        if !displayMode.isHidden {
            displayMode.setEnabled(unavailableWiki == nil, forSegment: 0)
            displayMode.selectedSegment = unavailableWiki == nil ? value.mode : 1
            switchDocumentMode()
        }
        text.undoManager?.removeAllActions(); updateTaskItemPicker(); onWorkspaceChange?()
        try restoreTextViewports(value); try restoreSourceWindow(value.sourceWindow); restoreVideoWindow(value.videoWindow); try restoreWikiPlan(value.wikiPlan)
        try restoreVersionReview(value.versionReview); pendingConflict = value.conflict
    }
    private func captureTextViewport() throws -> AgentTextViewport? {
        guard openedHash != nil, !hasInlineVideoPlayback else { return nil }
        if let pendingTextViewport, pendingTextViewport.matches(text) { return pendingTextViewport }
        pendingTextViewport = nil
        var current = try AgentTextViewport(text)
        if isPageVisible, !viewer.isHidden, !textViewportScheduled, current.focused { rememberedTextFocus = true }
        current.focused = rememberedTextFocus
        return current
    }
    private func prepareTextViewport(_ viewport: AgentTextViewport?) throws {
        if let viewport {
            guard viewport.matches(text) else { throw PetError("正文已变化，原文本位置已保留") }; pendingTextViewport = viewport; rememberedTextFocus = viewport.focused
        }
    }
    private func restoreTextViewports(_ value: RecoveryState) throws {
        try prepareTextViewport(value.textViewport)
        if unavailableWiki == nil, let viewport = value.markdownViewport { try markdown.restoreViewRecovery(viewport) }
        scheduleTextViewport()
    }
    private func scheduleTextViewport(activating: Bool = false, forceFocus: Bool = false) {
        textFocusRequested = textFocusRequested || forceFocus || activating && rememberedTextFocus
        guard pendingTextViewport != nil || textFocusRequested, !applyingTextViewport, !textViewportScheduled else { return }; textViewportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; let focus = textFocusRequested; textFocusRequested = false
            defer { textViewportScheduled = false }
            guard isPageVisible, !viewer.isHidden, !text.isHiddenOrHasHiddenAncestor,
                  var viewport = pendingTextViewport ?? (try? AgentTextViewport(text)) else { return }
            applyingTextViewport = true
            presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            if focus { viewport.focused = true }
            if viewport.apply(to: text) {
                if memorySettingsTarget != nil, viewport.focused, !viewport.focusedSelectionIsVisible(in: text),
                   let selection = viewport.selections.first {
                    text.scrollRangeToVisible(selection.range)
                }
                pendingTextViewport = nil; rememberedTextFocus = viewport.focused
            }
            applyingTextViewport = false; onWorkspaceChange?()
        }
    }
    @objc private func textViewportChanged(_ notification: Notification) { if !applyingTextViewport, pendingTextViewport == nil { if presentingWindow?.firstResponder === text { rememberedTextFocus = true }; onWorkspaceChange?() } }
    private func updateMemoryHeading(_ document: AgentMemoryDocument) {
        guard let target = memorySettingsTarget else { return }
        let fileWorkspace = document.scope.isProjectFile ? target.context.workspace ?? openedMemoryWorkspace : nil
        let scope: String
        if let workspace = fileWorkspace {
            scope = "项目 · " + URL(fileURLWithPath: workspace).lastPathComponent
        } else if [.summary, .effectiveInstructions].contains(document.scope), let task = memoryTaskID.flatMap(store.task) {
            scope = task.title
        } else { scope = "用户" }
        detailHeading = .init(title: document.topic ?? document.scope.title, scope: scope, location: fileWorkspace ?? openedMemorySource?.path)
    }
    private func retainVideoWindow(_ next: AgentVideoWindow) {
        videoWindow?.close(); videoWindow = next
        next.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
        next.onClose = { [weak self, weak next] in
            guard let self, videoWindow === next else { return }; videoWindow = nil; pendingWikiVideoPage = false; onWorkspaceChange?()
        }
    }
    private func retainSourceWindow(_ next: AgentMarkdownSourceWindow) {
        sourceWindow?.onClose = nil; sourceWindow?.close(); sourceWindow = next
        next.onAddSelection = onAddSelection; next.canAddSelection = { [weak self] in self?.canAddSelection == true }
        next.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
        next.onClose = { [weak self, weak next] in guard let self, sourceWindow === next else { return }; sourceWindow = nil; onWorkspaceChange?() }
    }
    private func sourceScope(_ root: String) -> () throws -> Void {
        { [weak self] in
            guard let self, let task = store.task(taskID), try AgentWorkspaceScope.roots(task).contains(where: { $0.root.path == root }) else { throw PetError("来源所属任务或目录已变化，原阅读记录已保留") }
        }
    }
    private func restoreSourceWindow(_ value: AgentMarkdownSourceWindow.RecoveryState?) throws {
        guard let value else { return }
        let next = try AgentMarkdownSourceWindow(restoring: value, validate: sourceScope(value.root)); retainSourceWindow(next)
        if value.presentation == "window" { next.presentRecoveredWindow() }
    }
    private func presentPendingSourcePage() {
        if let pendingConflict, isPageVisible, presentingWindow?.hasBlockingDialog != true, openedFile?.path == pendingConflict.file {
            self.pendingConflict = nil
            openConflictComparison(restoring: pendingConflict)
            return
        }
        wikiReviewWindow?.presentRecoveredVersion(from: self)
        guard onSettingsPush != nil else { return }
        if let sourceWindow, sourceWindow.needsHostedPresentation { presentSettingsChild(sourceWindow) }
        if pendingWikiVideoPage, let videoWindow { pendingWikiVideoPage = false; presentSettingsChild(videoWindow) }
        if let wikiPlanWindow, wikiPlanWindow.needsHostedPresentation { presentSettingsChild(wikiPlanWindow) }
    }
    private func restoreVideoWindow(_ value: AgentVideoWindow.RecoveryState?) {
        guard let value else { return }
        let next = AgentVideoWindow(restoring: value) { [weak self] in
            guard let self, let task = store.task(taskID), try AgentWorkspaceScope.roots(task).contains(where: { $0.root.path == value.sourceRoot }) else { throw PetError("视频所属任务或目录已变化，原播放记录已保留") }
            let (files, file) = try AgentWorkspaceScope.location(task, path: value.file)
            guard files.root.path == value.sourceRoot, file.path == value.file else { throw PetError("视频来源已变化，原播放记录已保留") }
            return (files, file)
        }
        retainVideoWindow(next)
        if wikiOnly, value.frame == nil { pendingWikiVideoPage = true }
        else { next.showWindow(nil); next.window?.makeKeyAndOrderFront(nil) }
        onWorkspaceChange?()
    }
    @objc private func refresh() {
        refreshCatalog(selecting: nil)
    }
    private func refreshCatalog(selecting preferred: String?, restoringWiki: Bool = false) {
        defer { onWorkspaceChange?() }
        guard canLeave() else { sections.selectedSegment = activeSection; return }; activeSection = sections.selectedSegment
        if !restoringWiki { unavailableWiki = nil }
        load?.cancel(); selection = nil; openedHash = nil; openedMemoryExists = nil; openedMemorySource = nil; state.stringValue = ""; text.isEditable = false; resetDocumentMode()
        save.isHidden = true; undo.isHidden = true; open.isHidden = true; compare.isHidden = true
        allowInstruction.isHidden = true; revokeInstruction.isHidden = true
        generate.isHidden = sections.selectedSegment != 6; generate.isEnabled = onGenerateWiki != nil && wikiTree.selectedLanguage != "legacy"
        wikiCards.isHidden = sections.selectedSegment != 6 || onOpenKnowledgeCards == nil
        wikiTree.isHidden = sections.selectedSegment != 6; list.isHidden = !wikiTree.isHidden
        newOffice.isHidden = sections.selectedSegment != 1; openOffice.isHidden = newOffice.isHidden
        if sections.selectedSegment == 5 {
            let existing = memoryTaskID != nil ? AgentMemoryScope.allCases : memoryWorkspace == nil ? [.global, .userInstructions] : [.project, .instructions, .localInstructions]
            let scopes = memoryCatalogScope.map { [$0] } ?? existing
            memoryTopicError = nil
            items = scopes.flatMap { scope -> [(title: String, value: String)] in
                var rows = [(memoryCatalogScope == nil ? scope.title : "主记忆", scope.rawValue)]
                guard scope.hasTopics else { return rows }
                do {
                    let library = try AgentMemory.catalog(scope, store: store, taskID: memoryTaskID, workspace: memoryWorkspace)
                    if memoryCatalogScope == scope { memoryTopicError = library.topicError }
                    rows += library.topics.map { (memoryCatalogScope == nil ? scope.title + " · " + $0 : $0, AgentMemoryDocument(scope, topic: $0).selection) }
                } catch { if memoryCatalogScope == scope { memoryTopicError = error.localizedDescription } }
                return rows
            }
            addMemory.isEnabled = memoryEditable && memoryTopicError == nil
            text.string = ""; reloadRecordItems(selecting: preferred); updateMemoryPicker(); return
        }
        guard let task = store.task(taskID) else { return }
        updateWikiSharingState()
        openOffice.isEnabled = task.workspace != nil; newOffice.isEnabled = task.workspace != nil && ![.running, .waiting].contains(task.status) && !task.archived
        switch sections.selectedSegment {
        case 0:
            items = []; text.string = task.plan.enumerated().map { index, step in "\(step.status == "completed" ? "✓" : step.status == "in_progress" ? "◉" : "○") \(index + 1). \(step.title)" }.joined(separator: "\n\n")
        case 1:
            var seen = Set<String>()
            items = (task.artifacts + openedFiles).filter { seen.insert($0).inserted }.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) } + (task.canvases ?? []).map { ($0.title, $0.reference) }
        case 2: items = task.sourceReferences.map { source in
            let url = URL(string: source)
            if url?.scheme == "attachment", let id = url?.host, let item = task.attachments?.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) { return (item.name, source) }
            return (url?.isFileURL == true ? url!.lastPathComponent : url?.host ?? source, source)
        }
        case 3: items = task.changes.map { ((($0.restoredAt != nil) ? "✓ " : "") + URL(fileURLWithPath: $0.path).lastPathComponent, $0.id) }
        case 4:
            items = [("全部日志", "all-logs")] + task.events.filter { $0.kind == "hook" }.suffix(64).reversed().map { ($0.statusTitle + " · " + $0.title, $0.id) }
        case 6:
            if let saved = unavailableWiki?.directory {
                wikiCatalogScope = .init(workspace: saved.workspace, branch: saved.branch, language: saved.language, root: saved.root)
                items = []; wikiTree.show([], selected: saved.document, root: saved.root)
                break
            }
            do {
                let language = wikiTree.selectedLanguage, view = try AgentWiki.view(store: store, taskID: taskID, language: language)
                let scope = try store.knowledgeCards.scope(task)
                wikiCatalogScope = .init(workspace: scope.root, branch: scope.branch, language: language, root: view.root)
                items = view.pages.map { ($0.title, $0.path) }
                let document = restoringWiki ? wikiTree.selectedDocument : items.first { $0.value == preferred || preferred == nil && $0.value == wikiTree.selectedDocument }?.value ?? items.first?.value
                wikiTree.show(view.pages, selected: document, root: view.root)
                state.stringValue = items.isEmpty ? "未生成" : try AgentWiki.status(store: store, taskID: taskID, language: wikiTree.selectedLanguage)
            } catch { wikiCatalogScope = nil; items = []; wikiTree.show([], selected: nil); state.stringValue = error.localizedDescription }
        default:
            items = []; text.string = task.events.map { "\($0.title) · \($0.status)\n\($0.detail)" }.joined(separator: "\n\n────────\n\n")
        }
        if [1, 2, 3, 6].contains(sections.selectedSegment) { text.string = "" }
        reloadRecordItems(selecting: preferred, restoringWiki: restoringWiki)
    }
    private func reloadRecordItems(selecting preferred: String?, restoringWiki: Bool = false) {
        table.delegate = nil; table.reloadData(); table.deselectAll(nil); table.delegate = self
        updateTaskItemPicker()
        if sections.selectedSegment == 6 {
            if unavailableWiki == nil, let selected = wikiTree.selectedDocument {
                if !restoringWiki { _ = wikiTree.select(selected, notify: false) }
                loadSelection(selected)
            }
        }
        else if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: items.firstIndex(where: { $0.value == preferred }) ?? 0), byExtendingSelection: false) }
    }
    private func refreshWikiCatalog() {
        guard sections.selectedSegment == 6, let task = store.task(taskID) else { return }
        if unavailableWiki != nil { presentConflict(); return }
        updateWikiSharingState()
        do {
            if dirty, let file = openedFile { try requireWikiFile(file, task: task) }
            let language = wikiTree.selectedLanguage, view = try AgentWiki.view(store: store, taskID: taskID, language: language), pages = view.pages
            let scope = try store.knowledgeCards.scope(task)
            wikiCatalogScope = .init(workspace: scope.root, branch: scope.branch, language: language, root: view.root)
            items = pages.map { ($0.title, $0.path) }
            let document = selection.flatMap { value in pages.first { $0.path == value || scope.root + "/" + $0.path == value }?.path }
            wikiTree.show(pages, selected: document, root: view.root)
            if selection != nil, document == nil { state.stringValue = dirty ? "文档已移出目录，草稿已保留" : "文档已移出目录" }
            else if selection == nil, let first = items.first { _ = wikiTree.select(first.value) }
        } catch { state.stringValue = error.localizedDescription }
    }
    private func requireWikiFile(_ file: URL, task: AgentTaskRecord) throws {
        guard sections.selectedSegment == 6 else { return }
        guard let expected = wikiCatalogScope, expected.language == wikiTree.selectedLanguage,
              file.path.hasPrefix(expected.workspace + "/" + expected.root + "/") else {
            throw PetError("Wiki 文档已离开原目录，草稿已保留")
        }
        let scope = try store.knowledgeCards.scope(task)
        guard scope.root == expected.workspace, scope.branch == expected.branch else { throw PetError("Wiki 所属项目或分支已变化，草稿已保留") }
        if expected.language != "legacy" {
            let manifest = try AgentWiki.plannedManifest(scope: scope, language: expected.language)
            guard (manifest?.root ?? ".bluefatfish/wiki") == expected.root, expected.language != "en" || manifest != nil else {
                throw PetError("Wiki 发布目录已变化，草稿已保留")
            }
        }
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
            if let old = wikiPlanWindow, old.needsHostedPresentation || old.isPageVisible || old.hasIndependentWindow {
                if old.needsHostedPresentation { presentSettingsChild(old) } else { old.presentingWindow?.makeKeyAndOrderFront(nil) }; return
            }
            let next = try AgentWikiPlanWindow(store: store, taskID: taskID)
            retainWikiPlan(next); presentSettingsChild(next)
        } catch { state.stringValue = error.localizedDescription }
    }
    private func retainWikiPlan(_ next: AgentWikiPlanWindow) {
        wikiPlanWindow?.onClose = nil; wikiPlanWindow?.close(); wikiPlanWindow = next
        next.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
        next.onClose = { [weak self, weak next] in guard let self, wikiPlanWindow === next else { return }; wikiPlanWindow = nil; onWorkspaceChange?() }
    }
    private func restoreWikiPlan(_ value: AgentWikiPlanWindow.RecoveryState?) throws {
        guard let value else { return }
        let next = try AgentWikiPlanWindow(store: store, taskID: taskID, restoring: value); retainWikiPlan(next)
        if value.presentation == "window" { next.presentRecoveredWindow() }
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
            let alert = AgentConfirmation(); alert.messageText = "连接项目知识"; alert.informativeText = reason; alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
            guard try await presentWikiAlert(alert) == .alertFirstButtonReturn else { throw PetError("已取消") }; if let directory { store.update(taskID) { $0.gitDirectory = directory } }
        }
        _ = try await tools.execute(call, gitDirectory: directory); try Task.checkCancellation()
    }
    private func presentWikiAlert(_ alert: AgentConfirmation) async throws -> NSApplication.ModalResponse {
        try Task.checkCancellation()
        guard let window = presentingWindow, window.isVisible, !window.hasBlockingDialog else { throw PetError("请先完成当前窗口操作") }
        wikiSharingAlert = alert; defer { wikiSharingAlert = nil }
        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            alert.beginModal(in: window) { continuation.resume(returning: $0) }
        }
    }
    private func presentKnowledgeReview(_ review: AgentKnowledgeReviewWindow) {
        guard wikiReviewWindow?.hasPendingOperation != true else { state.stringValue = "请等待当前知识操作完成"; return }
        wikiReviewWindow?.close(); retainKnowledgeReview(review); state.stringValue = ""
        presentSettingsChild(review); onWorkspaceChange?()
    }
    private func retainKnowledgeReview(_ review: AgentKnowledgeReviewWindow) {
        wikiReviewWindow = review
        review.onWorkspaceChange = { [weak self] in self?.onWorkspaceChange?() }
        review.onClose = { [weak self, weak review] in
            guard let self, wikiReviewWindow === review else { return }
            wikiReviewWindow = nil; onWorkspaceChange?()
        }
    }
    private func restoreVersionReview(_ position: AgentKnowledgeVersionPosition?) throws {
        guard let position else { return }
        let review = try makeKnowledgeVersionReview(position.context.kind, language: position.context.language)
        try review.restoreVersionPosition(position)
        retainKnowledgeReview(review)
    }
    private func makeKnowledgeVersionReview(_ kind: AgentKnowledgeVersionContext.Kind, language: String) throws -> AgentKnowledgeReviewWindow {
        let context = try AgentKnowledgeVersionContext(kind, store: store, taskID: taskID, language: language)
        let label = URL(fileURLWithPath: context.workspace).lastPathComponent + " · " + (language == "zh" ? "简体中文" : "English")
        if kind == .wiki {
            let versions = try AgentWiki.wikiHistory(store: store, taskID: taskID, language: language)
            guard !versions.isEmpty else { throw PetError("暂无可恢复的 Wiki 版本") }
            let choices = versions.map { AgentKnowledgeReviewVersion(id: $0.id, title: AgentKnowledgeReviewSnapshot.versionTitle($0.created, count: "\($0.metadata.documents.count) 页"), detail: String($0.id.prefix(8))) }
            return AgentKnowledgeReviewWindow(title: "恢复 Wiki", action: "恢复", scope: label, versions: choices, context: context, load: { [weak self] index in
                guard let self, !dirty, let index, versions.indices.contains(index) else { throw PetError("请选择原 Wiki 版本，当前草稿已保留") }
                try context.require(store)
                let value = try await AgentWiki.previewWikiRestore(versions[index], store: store, taskID: taskID, language: language)
                return try wikiReview(value, restoring: true)
            }, onApplied: { [weak self] message in self?.knowledgeReviewApplied(message, language: language) })
        }
        let versions = try AgentProjectKnowledgeSharing.history(store: store, taskID: taskID, language: language)
        guard !versions.isEmpty else { throw PetError("暂无可恢复的项目知识版本") }
        let choices = versions.map { AgentKnowledgeReviewVersion(id: $0.id, title: AgentKnowledgeReviewSnapshot.versionTitle($0.created, count: "\($0.wiki?.metadata.documents.count ?? 0) 页 / \($0.cards?.cards.count ?? 0) 张"), detail: String($0.id.prefix(8))) }
        return AgentKnowledgeReviewWindow(title: "恢复项目知识", action: "恢复", scope: label, versions: choices, context: context, load: { [weak self] index in
            guard let self, !dirty, let index, versions.indices.contains(index) else { throw PetError("请选择原知识版本，当前草稿已保留") }
            try context.require(store)
            let value = try await AgentProjectKnowledgeSharing.previewRestore(versions[index], store: store, taskID: taskID, language: language)
            return try projectReview(value, restoring: true)
        }, onApplied: { [weak self] message in self?.knowledgeReviewApplied(message, language: language) })
    }
    private func knowledgeReviewApplied(_ message: String, language: String) {
        if activeSection == 6, wikiTree.selectedLanguage == language { wikiTree.show([], selected: nil); refresh() }
        state.stringValue = message
    }
    private func wikiReview(_ value: AgentWikiImportPreview, restoring: Bool) throws -> AgentKnowledgeReviewSnapshot {
        var impact = "\(value.metadata.documents.count) 页 Wiki · \(value.metadata.resources?.count ?? 0) 个资源；替换当前语言，原版本保留。"
        if value.metadata.branch != value.branch { impact += "来自分支：" + value.metadata.branch }
        if value.manuallyChanged > 0 { impact += "包含 \(value.manuallyChanged) 页外部修改。" }
        return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(value.branch, language: value.language), impact: impact,
            items: try AgentKnowledgeReviewSnapshot.wikiItems(value), targetSignature: restoring ? AgentKnowledgeReviewSnapshot.target(value.previous) : nil) { [weak self] in
            guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
            try await AgentWiki.importWiki(value, store: self.store, taskID: self.taskID, restoring: restoring)
            return "已\(restoring ? "恢复" : "导入") \(value.metadata.documents.count) 页 Wiki"
        }
    }
    private func projectReview(_ value: AgentProjectKnowledgeImport, restoring: Bool) throws -> AgentKnowledgeReviewSnapshot {
        let documents = try value.wiki.map(AgentKnowledgeReviewSnapshot.wikiItems) ?? []
        let cards = value.cards.map { AgentKnowledgeReviewSnapshot.cardItems($0.book) } ?? []
        let wiki = value.wiki != nil ? "Wiki：\(value.pageCount) 页" : restoring ? "Wiki：恢复为未发布" : "Wiki：保留当前版本"
        let card = value.cards != nil ? "卡片：\(value.cardCount) 张" : restoring ? "卡片：恢复为未发布" : "卡片：保留当前版本"
        let signature = restoring ? AgentKnowledgeReviewSnapshot.target(value.previousWiki, cardsHash: value.previousCardsHash) : nil
        return AgentKnowledgeReviewSnapshot(scope: AgentKnowledgeReviewSnapshot.scope(value.scope.branch, language: value.scope.language),
            impact: wiki + " · " + card + "；替换前的完整版本保留。", items: documents + cards, targetSignature: signature) { [weak self] in
            guard let self, !dirty else { throw PetError("请先保存当前文档，草稿已保留") }
            try await AgentProjectKnowledgeSharing.apply(value, store: store, taskID: taskID)
            return "已\(restoring ? "恢复" : "导入")项目知识 · \(value.pageCount) 页 / \(value.cardCount) 张"
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
                let review: AgentKnowledgeReviewWindow
                if action == "restore" { review = try makeKnowledgeVersionReview(.wiki, language: language) }
                else { review = AgentKnowledgeReviewWindow(title: "导入 Wiki", action: "导入", scope: URL(fileURLWithPath: workspace).lastPathComponent + " · " + (language == "zh" ? "简体中文" : "English"), load: { [weak self] _ in
                    guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
                    let value = try await AgentWiki.previewWikiImport(store: self.store, taskID: self.taskID, language: language)
                    return try self.wikiReview(value, restoring: false)
                }, onApplied: { [weak self] message in self?.knowledgeReviewApplied(message, language: language) }) }
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
                let review: AgentKnowledgeReviewWindow
                if action == "knowledge-restore" { review = try makeKnowledgeVersionReview(.project, language: language) }
                else { review = AgentKnowledgeReviewWindow(title: "导入项目知识", action: "导入", scope: language == "zh" ? "简体中文" : "English", load: { [weak self] _ in
                    guard let self, !self.dirty else { throw PetError("请先保存当前文档，草稿已保留") }
                    let value = try await AgentProjectKnowledgeSharing.previewImport(store: self.store, taskID: self.taskID, language: language)
                    return try self.projectReview(value, restoring: false)
                }, onApplied: { [weak self] message in self?.knowledgeReviewApplied(message, language: language) }) }
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
                    let alert = AgentConfirmation(); alert.messageText = action == "auto-update" ? "开启自动更新？" : "开启自动导出？"
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
        defer { updateTaskItemPicker(); onWorkspaceChange?() }
        unavailableWiki = nil
        load?.cancel(); selection = value; openedHash = nil; openedMemoryExists = nil; openedMemorySource = nil; recoveryBlockedReason = nil; text.isEditable = false; state.stringValue = ""; resetDocumentMode()
        revealMemory.isEnabled = false
        text.undoManager?.removeAllActions()
        save.isHidden = true; undo.isHidden = true; open.isHidden = true; compare.isHidden = true; open.title = "打开"
        do {
            if sections.selectedSegment == 5, let document = AgentMemoryDocument(selection: value) {
                let scope = document.scope
                let task = memoryTaskID.flatMap(store.task)
                let memory = try AgentMemory.snapshot(scope, store: store, taskID: memoryTaskID, workspace: memoryWorkspace,
                    topic: document.topic, pinEditorSource: memorySettingsTarget != nil)
                openedMemorySource = memory.editorSource
                openedMemoryWorkspace = memory.workspace ?? memoryWorkspace ?? task?.workspace
                if memorySettingsTarget != nil || document.topic != nil { openedMemoryExists = memory.exists }
                updateMemoryHeading(document)
                text.string = memory.content; openedHash = memory.hash; state.stringValue = memoryTopicError ?? memory.location
                text.isEditable = scope != .effectiveInstructions && memoryEditable
                save.isHidden = scope == .effectiveInstructions; save.isEnabled = text.isEditable
                revealMemory.isEnabled = memory.exists
                allowInstruction.isHidden = scope != .effectiveInstructions; revokeInstruction.isHidden = allowInstruction.isHidden
                guard scope == .effectiveInstructions, let task else { return }
                allowInstruction.isEnabled = !task.archived && ![.running, .waiting].contains(task.status) && store.instructions.report(task).issues.contains(where: \.needsPermission)
                revokeInstruction.removeAllItems(); revokeInstruction.addItem(withTitle: "撤销允许")
                for grant in task.instructionGrants ?? [] where grant.workspace == task.workspace {
                    let item = NSMenuItem(title: URL(fileURLWithPath: grant.path).lastPathComponent, action: nil, keyEquivalent: ""); item.representedObject = grant.path; item.toolTip = grant.path; revokeInstruction.menu?.addItem(item)
                }
                revokeInstruction.isEnabled = revokeInstruction.numberOfItems > 1; return
            }
            guard let task = store.task(taskID) else { return }
            if sections.selectedSegment == 1, let url = URL(string: value), url.scheme == "canvas", let id = url.host.flatMap({ UUID(uuidString: $0)?.uuidString }) {
                let canvas = try store.canvases.source(id, taskID: taskID); text.string = canvas.code; open.isHidden = false; open.title = "打开画布"; state.stringValue = canvas.record.title; return
            }
            if sections.selectedSegment == 4 {
                let events = value == "all-logs" ? task.events : task.events.filter { $0.id == value }
                text.string = events.map { event in
                    event.title + " · " + event.statusTitle + (event.hook?.asynchronous == true ? " · 后台" : "") + (event.duration.map { " · " + String(format: "%.1fs", $0) } ?? "") + "\n" + event.detail
                }.joined(separator: "\n\n────────\n\n"); return
            }
            if sections.selectedSegment == 2 {
                if let url = URL(string: value), url.isFileURL, AgentVideoSnapshot.supports(url) { let (files,file) = try AgentWorkspaceScope.location(task,path:url.path); try showVideo(file, files: files) }
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
            let (files,file) = try AgentWorkspaceScope.location(task,path:value)
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
              FileManager.default.isWritableFile(atPath: file.path), let files = try? AgentWorkspaceScope.files(task,path:file.path), !AgentFiles.sensitive(files.relative(file)),
              (try? store.agents.limits(task, store: store).readOnly) == false else { return false }
        return true
    }
    private func resetDocumentMode() { pendingTextViewport = nil; rememberedTextFocus = false; textFocusRequested = false; readingToolbar.isHidden = true; video.clear(); video.isHidden = true; conflictWindow?.close(); conflictWindow = nil; markdownFile = nil; openedFile = nil; fileFormat = AgentTextFormat(); requestedEncoding = nil; encodingMenu.isHidden = true; markdown.clear(); markdown.isHidden = true; viewer.isHidden = false; displayMode.isHidden = true; displayMode.setEnabled(true, forSegment: 0); sourceSelection.update() }
    private func videoScope(_ files: AgentFiles) -> () throws -> Void {
        { [weak self] in guard let self, let task = self.store.task(self.taskID), try AgentWorkspaceScope.roots(task).contains(where:{$0.root == files.root}) else { throw PetError("视频所属任务或工作区已变化") } }
    }
    private enum VideoPresentation { case inline, page, window }
    private func showVideo(_ file: URL, files: AgentFiles, presentation: VideoPresentation = .inline) throws {
        guard try files.resolve(file.path) == file, !AgentFiles.sensitive(files.relative(file)) else { throw PetError("不能预览此视频路径") }
        if taskHosted, !documentOnly, presentation == .inline, let onOpenVideo {
            openedFile = file; text.string = file.lastPathComponent; state.stringValue = files.relative(file); open.isHidden = false; open.title = "打开标签页"
            try onOpenVideo(file); return
        }
        if presentation != .inline {
            video.pause()
            let next = AgentVideoWindow(file: file, files: files, validate: videoScope(files)); retainVideoWindow(next)
            if presentation == .page { presentSettingsChild(next) }
            else { next.showWindow(nil); next.window?.makeKeyAndOrderFront(nil) }
        } else {
            text.string = ""; viewer.isHidden = true; markdown.isHidden = true; video.isHidden = false; readingToolbar.isHidden = true; sourceAdd.isHidden = true
            openedFile = file; open.isHidden = false; open.title = "新窗口"; state.stringValue = files.relative(file)
            video.show(file: file, files: files, validate: videoScope(files), restoring: restoringVideo?.file == file.path ? restoringVideo?.state : nil)
            if documentOnly { onWorkspaceChange?() }
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
        if documentOnly { onWorkspaceChange?() }
    }
    @objc private func reopenEncoding() {
        let chosen = AgentTextEncoding.selection(encodingMenu)
        var retainedDirty = dirty
        do {
            guard !saving, let task = store.task(taskID), let file = openedFile, let path = selection else { throw PetError("文档当前不可重新打开") }
            let (files,resolved) = try AgentWorkspaceScope.location(task,path:path); guard resolved == file else { throw PetError("文件位置已变化") }
            try markdown.finishEditing(); retainedDirty = dirty
            let data = try files.readData(file), document = try AgentTextFile.decode(data, encoding: chosen)
            guard canLeave() else { AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: fileFormat); return }
            guard let current = store.task(taskID), selection == path, openedFile == file else { throw PetError("文档或任务已变化，草稿已保留") }
            let (currentFiles,latestLocation) = try AgentWorkspaceScope.location(current,path:path); guard latestLocation == file else { throw PetError("文件位置已变化，草稿已保留") }
            let latest = try currentFiles.readData(file), decoded = latest == data ? document : try AgentTextFile.decode(latest, encoding: chosen)
            conflictWindow?.close(); conflictWindow = nil; requestedEncoding = chosen; encodings[file.path] = chosen; loadText(decoded, data: latest, file: file, task: current); state.stringValue = (text.isEditable ? "" : "只读 · ") + currentFiles.relative(file)
        } catch { dirty = dirty || retainedDirty; state.stringValue = error.localizedDescription; AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: openedHash == nil ? nil : fileFormat) }
    }
    @objc private func switchDocumentMode(_ sender: Any? = nil) {
        guard unavailableWiki == nil, let file = markdownFile, let task = store.task(taskID), let workspace = try? AgentWorkspaceScope.files(task,path:file.path).root.path else { return }
        if isPageVisible, !viewer.isHidden, !textViewportScheduled, presentingWindow?.firstResponder === text { rememberedTextFocus = true }
        markdown.rememberViewportFocus()
        defer {
            scheduleTextViewport(activating: sender != nil && displayMode.selectedSegment == 1, forceFocus: sender != nil && displayMode.selectedSegment == 1)
            if displayMode.selectedSegment == 0 { markdown.activateRememberedView(force: sender != nil) }
            onWorkspaceChange?()
        }
        do { try markdown.finishEditing() } catch { state.stringValue = error.localizedDescription; displayMode.selectedSegment = markdown.isHidden ? 1 : 0; return }
        let preview = displayMode.selectedSegment == 0
        markdown.isHidden = !preview; viewer.isHidden = preview
        sourceSelection.update(); sourceAdd.isHidden = preview || onAddSelection == nil
        if preview { markdown.show(text.string, file: file, workspace: workspace, reuseIfUnchanged: true) }
    }
    private func openDocumentLink(_ url: URL) {
        do {
            if ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url); return }
            guard let task = store.task(taskID), let file = markdownFile else { return }; let workspace = try AgentWorkspaceScope.files(task,path:file.path).root.path
            let files = try AgentFiles(workspace: workspace), target = try AgentMarkdownDocument.target(url, document: file, files: files)
            if taskHosted, AgentVideoSnapshot.supports(target), let onOpenVideo { try onOpenVideo(target); return }
            if settingsHostWindow != nil, !taskHosted, AgentVideoSnapshot.supports(target) { try showVideo(target, files: files, presentation: .page); return }
            if let row = items.firstIndex(where: { (try? files.resolve($0.value).path) == target.path }) {
                guard canLeave() else { return }
                if sections.selectedSegment == 6 { _ = wikiTree.select(items[row].value) }
                else { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
                _ = markdown.navigate(AgentMarkdownDocument.fragment(target))
            } else if AgentVideoSnapshot.supports(target) { try showVideo(target, files: files, presentation: .window) }
            else {
                let next = try AgentMarkdownSourceWindow(workspace: workspace, target: target, validate: sourceScope(workspace))
                retainSourceWindow(next); presentSettingsChild(next); onWorkspaceChange?()
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
        if let recoveryBlockedReason { state.stringValue = recoveryBlockedReason; return }
        guard let path = selection, !saving else { return }
        let task = store.task(taskID)
        if let task, [.running, .waiting].contains(task.status) || task.archived { state.stringValue = "任务当前只读，草稿已保留"; return }
        do {
            try markdown.finishEditing()
            if sections.selectedSegment == 5, let document = AgentMemoryDocument(selection: path), let hash = openedHash {
                if document.scope.isProjectFile { try memorySettingsTarget?.context.requireCurrent(store) }
                let saved = try AgentMemory.save(document.scope, content: text.string, expectedHash: hash, store: store, taskID: memoryTaskID,
                    workspace: memorySettingsTarget?.context.workspace ?? openedMemoryWorkspace ?? memoryWorkspace,
                    topic: document.topic, expectedExists: openedMemoryExists, expectedSource: openedMemorySource)
                if memorySettingsTarget != nil || document.topic != nil { openedMemoryExists = saved.exists }
                openedHash = saved.hash; revealMemory.isEnabled = saved.exists; dirty = false; state.stringValue = "已保存"; onWorkspaceChange?(); return
            }
            guard let task, let openedFile else { return }
            try requireWikiFile(openedFile, task: task)
            let (files,file) = try AgentWorkspaceScope.location(task,path:path), current = try files.readData(file)
            guard file == openedFile, fileIsEditable(task, file: file) else { throw PetError("文件位置已变化或当前只读，草稿已保留") }
            guard let hash = openedHash else { throw PetError("打开的文件版本不可用，草稿已保留") }
            guard AgentFiles.hash(current) == hash else { state.stringValue = "文件已更改，草稿已保留"; presentConflict(); return }
            let content = text.string, format = fileFormat
            load = Task { [weak self] in
                guard let self else { return }
                do { try await persistFile(path: path, content: content, format: format, expectedHash: hash) }
                catch {
                    state.showSaveFailure(error)
                    if let current = try? files.readData(file), AgentFiles.hash(current) != hash { presentConflict() }
                }
            }
        } catch { state.showSaveFailure(error) }
    }
    private func persistFile(path: String, content: String, format: AgentTextFormat, expectedHash: String) async throws {
        guard !saving, let task = store.task(taskID), let file = openedFile, fileIsEditable(task, file: file), try AgentWorkspaceScope.location(task,path:path).1 == file else { throw PetError("文件位置已变化或当前只读，草稿已保留") }
        try requireWikiFile(file, task: task)
        let data = try format.encode(content)
        let args = try JSONSerialization.data(withJSONObject: ["path": path, "content": content, "expected_hash": expectedHash, "encoding": format.encoding.rawValue, "byte_order_mark": format.bom])
        saving = true; save.isEnabled = false; compare.isEnabled = false; state.stringValue = "正在保存…"
        defer { saving = false; save.isEnabled = text.isEditable; compare.isEnabled = true; onWorkspaceChange?() }
        _ = try await AgentTools(store: store, taskID: taskID).execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: args, as: UTF8.self)))
        openedHash = AgentFiles.hash(data); dirty = (try? fileData()) != data; state.stringValue = dirty ? "未保存" : "已保存"
    }
    private func conflictSnapshot() throws -> AgentFileConflictSnapshot {
        let ownComparisonVisible = settingsHostWindow != nil && conflictWindow?.isPageVisible == true && conflictWindow?.presentingWindow === presentingWindow
        guard !saving, isPageVisible || ownComparisonVisible, [1, 6].contains(sections.selectedSegment), let task = store.task(taskID),
              let file = openedFile, let path = selection else { throw PetError("文档或任务已变化，草稿已保留") }
        try requireWikiFile(file, task: task)
        let (files, current) = try AgentWorkspaceScope.location(task, path: path)
        guard current == file else { throw PetError("原文件位置已变化，草稿已保留") }
        try markdown.finishEditing()
        return try AgentFileConflictSnapshot.read(file: file, workspace: files.root.path, draft: text.string, allowsOverwrite: fileIsEditable(task, file: file), format: fileFormat)
    }
    @objc private func presentConflict() { openConflictComparison(restoring: nil) }
    private func openConflictComparison(restoring recovery: AgentFileConflictWindow.RecoveryState?) {
        guard !saving, let file = openedFile else { return }
        conflictWindow?.close()
        let next = AgentFileConflictWindow(file: file, protectedData: store.directory.deletingLastPathComponent(), recovery: recovery, read: { [weak self] in
            guard let self else { throw PetError("文档已关闭") }; return try self.conflictSnapshot()
        }, didReview: { [weak self] reviewed in
            try self?.resumeAfterReview(reviewed)
        }, resolve: { [weak self] reviewed, resolution in
            guard let self else { throw PetError("文档已关闭") }
            let current = try self.conflictSnapshot(); try reviewed.requireUnchanged(current)
            guard let path = self.selection, let task = self.store.task(self.taskID) else { throw PetError("任务已变化") }
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
        next.onPositionChange = { [weak self] in self?.onWorkspaceChange?() }
        next.onClose = { [weak self, weak next] in
            guard let self, conflictWindow === next else { return }
            conflictWindow = nil; onWorkspaceChange?()
        }
        conflictWindow = next; presentSettingsChild(next); onWorkspaceChange?()
    }
    private func resumeAfterReview(_ reviewed: AgentFileConflictSnapshot) throws {
        guard recoveryBlockedReason != nil else { return }
        let saved = unavailableWiki
        if let saved {
            let directory = saved.directory
            let view = try AgentWiki.view(store: store, taskID: taskID, language: directory.language)
            guard view.root == directory.root else { throw PetError("Wiki 发布目录已变化，草稿已保留") }
            guard view.pages.contains(where: { $0.path == directory.document }) else { throw PetError("原 Wiki 文档暂不可用") }
            items = view.pages.map { ($0.title, $0.path) }
            wikiTree.prepareRecovery(directory)
            wikiTree.show(view.pages, selected: directory.document, root: directory.root)
            unavailableWiki = nil
        }
        let readOnly = "当前文件只读，草稿已保留"
        recoveryBlockedReason = reviewed.allowsOverwrite ? nil : readOnly
        text.isEditable = reviewed.allowsOverwrite; save.isEnabled = text.isEditable
        if reviewed.allowsOverwrite { state.stringValue = openedHash == reviewed.diskHash ? "已恢复未保存内容" : "文件已更改，保存前请比较" }
        else { state.stringValue = readOnly }
        if let saved {
            displayMode.setEnabled(true, forSegment: 0)
            displayMode.selectedSegment = saved.mode
            switchDocumentMode()
            if let preview = saved.preview {
                markdown.show(text.string, file: reviewed.file, workspace: saved.directory.workspace, reuseIfUnchanged: true)
                do { try markdown.restoreViewRecovery(preview) }
                catch {
                    displayMode.selectedSegment = 1
                    switchDocumentMode()
                    state.stringValue = "原预览位置暂不可用，草稿已保留"
                }
            }
        }
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
            do { try showVideo(file, files: AgentWorkspaceScope.files(task,path:file.path), presentation: .window) } catch { state.stringValue = error.localizedDescription }; return
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
                    let line = url.fragment.flatMap { $0.hasPrefix("L") ? Int($0.dropFirst()) : nil }.flatMap { $0 > 0 ? $0 : nil }
                    let target = AgentAttachmentReadingTarget(part: part, line: line)
                    if let onOpenAttachment { try onOpenAttachment(id, target) }
                    else {
                        let preview = try AgentAttachmentWindow(store: store, taskID: taskID, id: id, target: target)
                        attachmentWindow?.close(); attachmentWindow = preview
                        preview.showWindow(nil); preview.window?.makeKeyAndOrderFront(nil)
                    }
                } catch { state.stringValue = error.localizedDescription }
            }
            else if let url = URL(string: value), ["https", "http"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            else if let url = URL(string: value), url.isFileURL, let task = store.task(taskID), let files = try? AgentWorkspaceScope.files(task,path:url.path), let safe = try? files.resolve(url.path) { if AgentOffice.supports(safe.path) { showOffice(safe.path) } else { NSWorkspace.shared.open(safe) } }
        }
        else if let task = store.task(taskID), let files = try? AgentWorkspaceScope.files(task,path:value), let url = try? files.resolve(value) { NSWorkspace.shared.open(url) }
    }
    func checkOpenSource(_ value: String) {
        guard AgentTaskWorkspace.readbackEnabled else { return }
        selectItem(section: 2, value: value); open.performClick(nil)
    }
    private func showOffice(_ path: String) {
        load = Task { [weak self] in guard let self else { return }; do { _ = try await store.offices.show(path, taskID: taskID) } catch { state.stringValue = error.localizedDescription } }
    }
    @objc private func chooseOffice() {
        if taskHosted, let onChooseWorkspaceFile { onChooseWorkspaceFile(); return }
        guard let window = presentingWindow, let original = store.task(taskID), let workspace = original.workspace, canLeave() else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.directoryURL = URL(fileURLWithPath: workspace)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url, let self else { return }
            do {
                guard let task = self.store.task(self.taskID), task.workspace == original.workspace, task.workspaceScope == original.workspaceScope else { throw PetError("任务工作区已变化，请重新打开文件") }
                let (files,safe) = try AgentWorkspaceScope.location(task,path:file.path)
                guard !AgentFiles.sensitive(files.relative(safe)) else { throw PetError("不能打开敏感文件") }
                if AgentVideoSnapshot.supports(safe) { try self.showVideo(safe, files: files, presentation: self.settingsHostWindow != nil && !self.taskHosted ? .page : .window) }
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
    func textDidChange(_ notification: Notification) { pendingTextViewport = nil; if presentingWindow?.firstResponder === text { rememberedTextFocus = true }; dirty = true; state.stringValue = "未保存"; onWorkspaceChange?() }
    func undoManager(for view: NSTextView) -> UndoManager? { text.previewUndoManager }
    func textViewDidChangeSelection(_ notification: Notification) { sourceSelection.update(); sourceAdd.isHidden = viewer.isHidden || onAddSelection == nil; textViewportChanged(notification) }
    private func canLeave() -> Bool {
        guard wikiReviewWindow?.hasPendingOperation != true else { state.stringValue = "请等待当前知识操作完成"; return false }
        guard !saving else { state.stringValue = "正在保存…"; return false }
        do { try markdown.prepareWorkspaceNavigation() } catch { state.stringValue = error.localizedDescription; return false }
        guard dirty else { return true }
        guard AgentUnsavedChanges.discard("放弃未保存的更改？", detail: openedFile?.lastPathComponent ?? state.stringValue) else { return false }; dirty = false; return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { guard wikiPlanWindow?.confirmClosing() != false else { return false }; if canLeave() { load?.cancel(); return true }; return false }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        scheduleTextViewport(activating: true); markdown.activateRememberedView()
        presentPendingSourcePage()
        if pendingTextViewport == nil, sections.selectedSegment == 5, isPageVisible, !viewer.isHidden, !text.isHiddenOrHasHiddenAncestor { presentingWindow?.makeFirstResponder(text) }
    }
    override func canLeaveSettings() -> Bool {
        let edited = dirty
        guard super.canLeaveSettings() else { return false }
        if edited, !dirty, let selection { loadSelection(selection) }
        return true
    }
    private func closeContent() { load?.cancel(); wikiSharingTask?.cancel(); wikiReviewWindow?.close(); wikiReviewWindow = nil; wikiSharingAlert?.endDialog(.abort); wikiPlanWindow?.close(); wikiPlanWindow = nil; video.clear(); videoWindow?.close(); videoWindow = nil; markdown.clear(); sourceWindow?.close(); sourceWindow = nil; conflictWindow?.close(); conflictWindow = nil }
    override func settingsWillLeave() { closeContent() }
    func windowWillClose(_ notification: Notification) { closeContent(); onWindowClose?(); onWindowClose = nil }
    func windowDidResize(_ notification: Notification) { pageDidLayout() }
    func windowDidBecomeKey(_ notification: Notification) { scheduleTextViewport(activating: true); markdown.activateRememberedView(); presentPendingSourcePage() }
    func checkTextViewport(preview: Bool = false, action: String = "", target: String = "", input: String? = nil, selection: NSRange? = nil, y: Double? = nil, cell: Bool = false) throws {
        guard ["--workspace-text-viewport-check", "--workspace-text-viewport-ui"].contains(where: CommandLine.arguments.contains) else { return }
        if !displayMode.isHidden, displayMode.selectedSegment != (preview ? 0 : 1) { displayMode.selectedSegment = preview ? 0 : 1; switchDocumentMode(displayMode) }
        if preview { try markdown.checkViewRecovery(action: action, target: target, input: input, selection: selection, y: y, cell: cell) }
        else {
            if let input {
                guard text.isEditable else { throw PetError("当前文档只读") }
                text.insertText(input, replacementRange: text.selectedRange())
            }
            if let selection { text.setSelectedRange(selection); presentingWindow?.makeFirstResponder(text) }
            presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            if let y { viewer.contentView.scroll(to: NSPoint(x: 0, y: y)); viewer.reflectScrolledClipView(viewer.contentView) }
        }
    }
    var textViewportReadback: [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        return ["raw": ["location": text.selectedRange().location, "length": text.selectedRange().length, "y": Double(viewer.contentView.bounds.minY), "focused": presentingWindow?.firstResponder === text, "pending": pendingTextViewport != nil], "markdown": markdown.viewportReadback]
    }
    func sourceForRecoveryCheck(open url: URL? = nil) -> AgentMarkdownSourceWindow? {
        guard ["--knowledge-source-recovery-check", "--knowledge-source-recovery-ui", "--workspace-source-recovery-check", "--workspace-source-recovery-ui"].contains(where: CommandLine.arguments.contains) else { return nil }
        if let url { openDocumentLink(url) }; return sourceWindow
    }
    func videoPreviewReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled || CommandLine.arguments.contains("--video-preview-check") else { return [:] }
        var result = await video.checkState(); result["saveVisible"] = !save.isHidden; result["compareVisible"] = !compare.isHidden; result["textEditable"] = text.isEditable; result["selection"] = selection ?? ""; result["openTitle"] = open.title
        if let videoWindow { result["separateWindowVisible"] = videoWindow.window?.isVisible == true; result["separatePlayer"] = await videoWindow.preview.checkState(); result["separateFrame"] = videoWindow.window.map { ["x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height] } }
        return result
    }
    func checkVideoWorkspace(action: String = "", time: Double? = nil, rate: Double? = nil, volume: Double? = nil, muted: Bool? = nil, link: URL? = nil, childFrame: NSRect? = nil) async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        if let link { openDocumentLink(link) }
        if action == "new-window" || action == "open" { openItem() }
        if let childFrame { videoWindow?.window?.setFrame(childFrame, display: true) }
        if action == "child-front" { videoWindow?.window?.makeKeyAndOrderFront(nil) }
        if action == "close-child" { videoWindow?.close() }
        if action == "separate" || action == "separate-refresh" {
            await videoWindow?.preview.checkWorkspace(action: action == "separate-refresh" ? "refresh" : "", time: time, rate: rate, volume: volume, muted: muted)
            return await videoPreviewReadback()
        }
        if action == "refresh" { await video.checkWorkspace(action: "refresh") }
        await video.checkWorkspace(time: time, rate: rate, volume: volume, muted: muted)
        return await videoPreviewReadback()
    }
    func markdownEditingReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled || AgentKnowledgePageHost.readbackEnabled || ["--markdown-edit-check", "--file-conflict-check", "--text-encoding-check", "--markdown-table-check", "--wiki-tree-check", "--wiki-plan-check", "--repo-wiki-overview-check"].contains(where: CommandLine.arguments.contains) else { return [:] }
        await markdown.waitForDiagrams()
        let data = try? fileData()
        var result: [String: Any] = ["draft": text.string, "encodedDraft": fileContent, "encodedDraftBase64": data?.base64EncodedString() ?? "", "draftHash": data.map(AgentFiles.hash) ?? "", "openedHash": openedHash ?? "", "dirty": dirty, "utf8BOM": fileBOM, "encoding": fileFormat.encoding.rawValue, "byteOrderMark": fileFormat.bom, "sourceEditable": text.isEditable, "preview": markdown.editingCheckState, "comparison": conflictWindow?.checkState ?? [:]]
        if CommandLine.arguments.contains("--file-conflict-check") { result["snapshotAllowsOverwrite"] = (try? conflictSnapshot().allowsOverwrite) ?? false }
        if CommandLine.arguments.contains("--text-encoding-check") { result["encodingMenuVisible"] = !encodingMenu.isHidden; result["state"] = state.stringValue; result["file"] = openedFile?.path ?? "" }
        if AgentKnowledgePageHost.readbackEnabled || CommandLine.arguments.contains("--wiki-tree-check") || CommandLine.arguments.contains("--wiki-plan-check") || CommandLine.arguments.contains("--repo-wiki-overview-check") { result["tree"] = wikiTree.checkState; result["wikiPlan"] = wikiPlanWindow?.checkState ?? [:]; result["wikiSharingBusy"] = wikiSharingTask != nil; result["wikiSharingConfirmation"] = wikiSharingAlert?.messageText ?? ""; result["wikiSharingSheetVisible"] = false; result["wikiSharingDialogVisible"] = wikiSharingAlert?.isVisible == true; result["state"] = state.stringValue; result["file"] = openedFile?.path ?? "" }
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
        guard AgentTaskWorkspace.readbackEnabled else { return }
        if let value, text.isEditable { displayMode.selectedSegment = 1; switchDocumentMode(); text.string = value; textDidChange(Notification(name: NSText.didChangeNotification, object: text)) }
        if action == "save" { saveFile(); await load?.value }
        else if action == "preview" || action == "source" { displayMode.selectedSegment = action == "preview" ? 0 : 1; switchDocumentMode() }
        else if action == "compare" { presentConflict() }
        else if action == "files" { toggleTaskFiles() }
    }
    func waitForDocumentCheck() async { if AgentTaskWorkspace.readbackEnabled { await load?.value } }
    func checkReloadDocument() {
        guard CommandLine.arguments.contains("--file-icons-check"), let file = openedFile, let task = store.task(taskID),
              let files = try? AgentFiles(workspace: task.workspace), let data = try? files.readData(file), let document = try? AgentTextFile.decode(data) else { return }
        loadText(document, data: data, file: file, task: task)
    }
    func checkOpenKnowledgePlan() { if ["--knowledge-page-check", "--knowledge-editor-recovery-check", "--knowledge-editor-recovery-ui"].contains(where: CommandLine.arguments.contains) { openWikiPlan() } }
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
