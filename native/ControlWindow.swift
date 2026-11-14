import AppKit
import UniformTypeIdentifiers
import CoreText

final class ComposerView: NSTextView {
    var placeholder = "发消息…" { didSet { needsDisplay = true } }
    var onSend: (() -> Void)?
    var onInputChanged: (() -> Void)?
    var onExtensionKey: ((UInt16) -> Bool)?
    var onShortcut: ((NSEvent) -> Bool)?
    var onEditingEnded: (() -> Void)?
    var attachmentOwner: (() -> String?)?
    var onImportFiles: (([URL], String) -> Bool)?
    private(set) var dragOwner: String?
    private(set) var fileIngressDiagnostics: [String: Int] = [:]
    private func noteFileIngress(_ value: String) {
        guard CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--attachment-drop-check") else { return }
        fileIngressDiagnostics[value, default: 0] += 1
    }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.fileURL] + super.readablePasteboardTypes.filter { $0 != .fileURL } }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.fileURL] + super.acceptableDragTypes.filter { $0 != .fileURL } }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let result = super.draggingEntered(sender); noteFileIngress("entered:\(result.rawValue)"); return result
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let result = super.draggingUpdated(sender); noteFileIngress("updated:\(result.rawValue)"); return result
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = super.prepareForDragOperation(sender); noteFileIngress("prepare:\(result)"); return result
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = super.performDragOperation(sender); noteFileIngress("perform:\(result)"); return result
    }
    override func dragOperation(for draggingInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        noteFileIngress("drag:" + type.rawValue)
        guard type == .fileURL else { return super.dragOperation(for: draggingInfo, type: type) }
        guard isEditable, let owner = attachmentOwner?(), dragOwner == nil || dragOwner == owner else { return [] }
        dragOwner = owner; _ = super.dragOperation(for: draggingInfo, type: type); return .copy
    }
    override func cleanUpAfterDragOperation() { noteFileIngress("cleanup"); dragOwner = nil; super.cleanUpAfterDragOperation() }
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        noteFileIngress("read:" + type.rawValue)
        guard type == .fileURL else { return super.readSelection(from: pasteboard, type: type) }
        // Consume recognized files even when rejected, so AppKit cannot retry their names as text.
        guard isEditable, let owner = attachmentOwner?(), dragOwner == nil || dragOwner == owner,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { noteFileIngress("rejected"); return true }
        let accepted = onImportFiles?(urls, owner) ?? false; noteFileIngress(accepted ? "accepted" : "rejected"); return true
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); if result { onEditingEnded?() }; return result
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), onShortcut?(event) == true { return }
        if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, onExtensionKey?(event.keyCode) == true { return }; super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText(), onShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    override func didChangeText() { super.didChangeText(); needsDisplay = true; onInputChanged?() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 4, y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText() && !NSEvent.modifierFlags.contains(.shift) { onSend?() }
        else { super.insertNewline(sender) }
    }
}

final class FormDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class ControlWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSComboBoxDelegate {
    weak var companion: AppDelegate?
    private var selectedTab = "chat"
    var hasTaskFocus: Bool { selectedTab == "chat" && window?.isVisible == true && (window?.isKeyWindow == true || window?.childWindows?.contains(where: \.isKeyWindow) == true) }
    private var settingsReturnTab = "chat", settingsBackButton: NSButton?
    private let chatNav = NSButton(title: "对话", target: nil, action: nil), settingsNav = NSButton(title: "设置", target: nil, action: nil)
    private let pageTitle = NSTextField(labelWithString: "对话"), modelCaption = NSTextField(labelWithString: "")
    private let sidebarWake = NSTextField(labelWithString: ""), listenButton = NSButton(title: "立即聆听", target: nil, action: nil)
    private let stopRecordingButton = NSButton(title: "停止录音", target: nil, action: nil), voiceStopButton = NSButton(title: "停止录音", target: nil, action: nil)
    private let chat = NSView(), settings = NSView(), attentionContent = NSView(), automationContent = NSView(), knowledgeContent = NSView()
    private(set) var knowledgePageHost = AgentKnowledgePageHost()
    private let libraryButton = AgentWorkbenchButton(title: "知识库", target: nil, action: nil), projectKnowledgeButton = AgentWorkbenchButton(title: "项目知识", target: nil, action: nil)
    private(set) var attentionPageController: AgentAttentionWindow?
    private let contentSurface = ContentSurface(), settingsSidebar = NSView(), settingsSearch = NSSearchField()
    private let settingsForm = NSStackView(), settingsScroll = NSScrollView(), settingsHeading = NSTextField(labelWithString: "模型")
    private let settingsPageHost = AgentSettingsPageHost(), settingsBody = NSView()
    private var settingsSourceFolders: [String: String] = [:]
    private var settingsSidebarWidth: NSLayoutConstraint!
    private let noSettings = NSTextField(labelWithString: "没有匹配设置"), sizeValue = NSTextField(labelWithString: "")
    private let settingsCategories = [("model", "模型", "cpu"), ("general", "常规", "gearshape"), ("modes", "模式配置", "square.stack.3d.up"), ("monitor", "任务监控", "checklist"), ("appearance", "外观", "circle.lefthalf.filled"), ("shortcuts", "快捷键", "keyboard"), ("voice", "语音", "waveform"), ("screen", "屏幕陪伴", "eye"), ("desktop", "桌面宠物", "fish"), ("persona", "角色", "person.crop.circle"), ("attention", "需要我", "bell"), ("memory", "记忆与规则", "brain"), ("imports", "数据导入", "square.and.arrow.down"), ("extensions", "扩展管理", "puzzlepiece.extension"), ("agents", "智能体", "person.crop.square"), ("teams", "智能体团队", "person.3"), ("hooks", "Hooks", "link"), ("computer", "电脑操作", "computermouse"), ("worktrees", "工作树", "arrow.triangle.branch"), ("experiments", "实验", "flask"), ("archived", "归档", "archivebox")]
    private let managedSettings = Set(["extensions", "agents", "teams", "hooks", "memory", "worktrees"])
    private var shortcutSettings: AgentShortcutSettingsView?
    private var settingsCategory = "model", categoryButtons: [NSButton] = [], chatSidebarViews: [NSView] = []
    private var settingGroups: [(category: String, title: String, keywords: String, view: NSView)] = []
    private var titleLeading: NSLayoutConstraint!
    private let composer = ComposerView(), history = AgentConversationHistory(), messageColumn = NSStackView()
    private var messageRows: [String: ChatMessageRow] = [:], renderedIDs: [String] = []
    private var reasoningRows: [String: ChatMessageRow] = [:], processRows: [String: AgentReplyProcessRow] = [:]
    private var readingTaskID: String?, lastHumanMessageID: String?, readingAnchorID: String?, readingSpace: NSLayoutConstraint?
    private struct MessageSearch {
        var taskID: String, messageID: String, query: String
        var displayRange: NSRange? = nil, displayText: String? = nil
    }
    private var messageSearch: MessageSearch?, pendingMessageReveal = false
    private let taskFind = AgentTaskFindBar()
    private let mcpInputRow = NSStackView(), mcpInputButton = NSButton()
    private var mcpInputPanel: AgentMCPUserInputPanel?
    private let status = NSTextField(labelWithString: "")
    private let savedStatus = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let clearButton = NSButton(title: "清空", target: nil, action: nil)
    private let endpoint = NSTextField(), persona = NSTextField(), model = NSComboBox()
    private let apiKey = NSSecureTextField(), voiceKey = NSSecureTextField()
    private let apiPreview = NSButton(), voicePreview = NSButton(), apiReplace = NSButton(), voiceReplace = NSButton()
    private let checkModelButton = NSButton(title: "检测", target: nil, action: nil)
    private let modelStatus = NSTextField(labelWithString: "未检测")
    private let vision = NSPopUpButton(), reasoning = NSPopUpButton()
    private let contextTokens = NSComboBox(), replyTokens = NSComboBox()
    private let contextMaximum = NSTextField(labelWithString: ""), replyMaximum = NSTextField(labelWithString: "")
    private var modelCatalog: [ModelInfo] = [], storedModelInfo: ModelInfo?
    private var modelCheck: Task<Void, Never>?, modelCheckGeneration = 0
    private var updatingModelChoices = false
    private let effortValues = ["auto", "off", "minimal", "low", "medium", "high", "xhigh", "max"]
    private let voiceEndpoint = NSTextField(), voiceID = NSTextField(), voiceModel = NSTextField()
    private let voiceEnabled = NSSwitch(), onTop = NSSwitch(), wakeEnabled = NSSwitch()
    private let wakePhrase = NSTextField(), wakeStatus = NSTextField(labelWithString: "未开启")
    private let pauseWait = NSPopUpButton()
    private let screenEnabled = NSSwitch(), screenInterval = NSPopUpButton()
    private let screenStatus = NSTextField(labelWithString: ""), screenTarget = NSTextField(labelWithString: "")
    private let screenPermission = NSButton(title: "授权", target: nil, action: nil)
    private let screenNow = NSButton(title: "看看屏幕", target: nil, action: nil), screenQuiet = NSButton(title: "免打扰30分钟", target: nil, action: nil)
    private let performance = NSPopUpButton(), scale = NSSlider(value: 1, minValue: 0.5, maxValue: 1.5, target: nil, action: nil)
    private var removeChatKey = false, removeVoiceKey = false, busy = false
    private var pendingRender: DispatchWorkItem?
    private let taskSidebar = AgentTaskSidebar(), projectButton = NSButton(), modePopup = NSPopUpButton(), permissionPopup = NSPopUpButton()
    private let resumeButton = NSButton(title: "继续", target: nil, action: nil), resultsButton = NSButton(title: "记录", target: nil, action: nil)
    private let gitButton = NSButton(title: "Git", target: nil, action: nil)
    private let browserButton = NSButton(title: "浏览器", target: nil, action: nil)
    private let desktopButton = NSButton(title: "电脑操作", target: nil, action: nil)
    private var desktopSettings: AgentDesktopSettingsView?
    private let approvalPanel = NSStackView(), approvalTitle = NSTextField(labelWithString: ""), approvalText = NSTextView()
    private let approveButton = NSButton(title: "允许一次", target: nil, action: nil), denyButton = NSButton(title: "拒绝", target: nil, action: nil)
    private var visibleApproval: (task: String, call: String)?
    private var toolRows: [String: AgentToolRow] = [:], displayedTask: String?
    var agentTaskID: String? { displayedTask ?? companion?.agentStore?.selectedID }
    private var currentAgentTask: AgentTaskRecord? { agentTaskID.flatMap { companion?.agentStore?.task($0) } }
    private var displayedWorkMode = AgentWorkMode.coding
    let taskWindowNumber: Int
    var sideTaskTabID: String?
    private var closingSideTask = false, discardingSideTask = false
    private var closeWindowTask: Task<Void, Never>?, windowCloseApproved = false
    private var windowDraft: AgentWindowDraft?
    private var draftSave: DispatchWorkItem?
    private var recordWindow: AgentRecordWindow?
    private var artifactDocuments: [AgentRecordWindow] = []
    private var taskModelWindow: AgentTaskModelWindow?
    private var contextWindow: AgentContextWindow?
    private let taskMCPContext = AgentWorkbenchButton()
    private let taskContext = AgentWorkbenchButton()
    private var worktreeWindow: AgentWorktreeWindow?
    private var worktreeCreationWindow: AgentWorktreeCreationWindow?
    private weak var worktreePolicyPanel: AgentWorktreePolicyView?
    private var dataImportView: AgentDataImportView?
    private var taskSwitcher: AgentTaskSwitcher?
    private var nameEditor: AgentNameEditor?
    private var workspaceEditor: AgentWorkspaceEditor?
    private var archivedTasksView: AgentArchivedTasksView?
    private var generalSettingsSave: NSButton?
    private var generalSettingsPanel: AgentGeneralSettingsView?
    private var settingsFooter: NSStackView?
    private let executionLocation = AgentWorkbenchButton()
    private let branchControl = AgentWorkbenchButton()
    private var branchTask: Task<Void, Never>?, branchKey: String?
    private var knowledgeWindow: AgentKnowledgeWindow?
    private var repoWikiWindow: AgentRepoWikiWindow?
    private var knowledgeCardWindow: AgentKnowledgeCardWindow?
    private var knowledgeLibraryWindow: AgentKnowledgeLibraryWindow?
    private var extensionWindow: AgentExtensionWindow?
    private var profileWindow: AgentProfileWindow?, teamWindow: AgentTeamWindow?
    private(set) var automationWindow: AgentAutomationWindow?
    private let automationButton = AgentWorkbenchButton(title: "自动化", target: nil, action: nil)
    private let sidebarExtensions = AgentWorkbenchButton(title: "扩展", target: nil, action: nil)
    private let sidebarLower = AgentSidebarNavigationList(), sidebarMore = AgentWorkbenchButton(title: "更多", target: nil, action: nil)
    private var displayedSidebarLayout: AgentSidebarLayout.Settings?
    private let extensionPanel = AgentExtensionPanel(), extensionPicker = AgentExtensionPicker()
    private var extensionPickerTask: String?
    private let attachmentButton = NSButton(), draftAttachments = AgentAttachmentStrip()
    private var attachmentWindow: AgentAttachmentWindow?, attachmentImport: Task<Void, Never>?, importTaskID: String?
    private let workbenchBadge = AgentStatusBadge(), workbenchInspector = AgentTaskInspector()
    private let thinkingIndicator = AgentThinkingIndicator()
    private var monitorPanel: AgentTaskMonitorPanel?, monitorPanelTaskID: String?
    private var monitorStates: [String: AgentTaskMonitor.DisplayState] = [:]
    private var appliedMonitorSettings: AgentTaskMonitor.Settings?
    private let terminalButton = AgentWorkbenchButton(), terminalSplit = AgentTerminalSplitView()
    private(set) var taskWorkspace = AgentTaskWorkspace()
    private var taskDocumentOpenState: [String: Any] = [:]
    private var conversationTrailing: NSLayoutConstraint!, fullConversationTrailing: NSLayoutConstraint!
    private var headerActionsTrailing: NSLayoutConstraint!, fullHeaderActionsTrailing: NSLayoutConstraint!
    private var terminalPanel: AgentTerminalPanel?
    private let taskBack = AgentWorkbenchButton(), taskForward = AgentWorkbenchButton(), taskMore = AgentWorkbenchButton(), taskModel = AgentWorkbenchButton(), voiceInput = AgentWorkbenchButton(), sidebarToggle = AgentWorkbenchButton()
    private let workbenchSidebar = NSView()
    private let workbenchEmpty = NSStackView(), emptyBefore = NSView(), emptyAfter = NSView(), emptyProject = AgentWorkbenchButton()
    private var homeGamesView: AgentHomeGamesView?
    private let workbenchEmptyTitle = NSButton(title: "新的任务", target: nil, action: nil)
    private let workbenchLower = NSStackView()
    private let entryToolbar = NSView(), entryLeading = NSStackView(), entryTrailing = NSStackView(), inspectorRule = AgentThemeView(fill: AgentWorkbenchTheme.line), headerInspectorRule = AgentThemeView(fill: AgentWorkbenchTheme.line)
    private var inspectorWidth: NSLayoutConstraint!, inspectorPreferredWidth: NSLayoutConstraint!, sidebarWidth: NSLayoutConstraint!, entryToolbarHeight: NSLayoutConstraint!, emptyBeforeHeight: NSLayoutConstraint!
    private var workbenchSidebarWidth: NSLayoutConstraint!, navigationLeading: NSLayoutConstraint!, sidebarRequested = true
    private var workbenchColumnLeading: NSLayoutConstraint!, workbenchColumnTrailing: NSLayoutConstraint!
    private var workbenchChrome: [NSView] = [], inspectorRequested = true
    private var taskNavigation: [String] = [], taskNavigationIndex = -1, navigatingTaskHistory = false
    private var lastInspectorTransitionDuration: TimeInterval = 0

    init(companion: AppDelegate, taskID: String? = nil, windowNumber: Int = 1) {
        self.companion = companion
        taskWindowNumber = windowNumber; displayedTask = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: companion.usesAgent ? 1200 : 980, height: companion.usesAgent ? 774 : 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "蓝色大肥鱼"; window.minSize = NSSize(width: 780, height: 540)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = AgentWorkbenchTheme.sidebar
        window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        if companion.usesAgent { companion.ensureAgent() }
        build()
        contentSurface.onAppearanceChange = { [weak self] in self?.refreshAppearancePreferences() }
        composer.onShortcut = { [weak self] event in
            guard let self, self.canPerformShortcut(.planMode), self.companion?.shortcuts.binding(.planMode).matches(event) == true else { return false }
            self.performShortcut(.planMode); return true
        }
        composer.attachmentOwner = { [weak self] in
            guard let self, selectedTab == "chat", attachmentImport == nil, let task = currentAgentTask,
                  !task.archived, !task.isProjectDocumentation, task.kind != "hook" else { return nil }
            return task.id
        }
        composer.onImportFiles = { [weak self] urls, owner in
            guard let self, let tasks = self.companion?.agentStore, self.agentTaskID == owner, self.saveAgentDraft() else { return false }
            return self.beginAttachmentImport(urls, store: tasks, taskID: owner) != nil
        }
        taskSidebar.onOpenSearch = { [weak self] id, query, message in self?.selectAgentTask(id, searchQuery: query, messageID: message) }
        taskSidebar.onSearchQueryChanged = { [weak self] in self?.taskFind.reset(); self?.clearMessageSearchHighlight() }
        taskSidebar.onSearchVisibilityChanged = { [weak self] in self?.refreshSidebarMoreSelection() }
        taskFind.onMatch = { [weak self] query, match in
            guard let self, let id = agentTaskID, taskFind.taskID == id else { return }
            clearMessageSearchHighlight()
            if let match, !taskFind.isHidden, messageRows[match.source.messageID]?.label.stringValue == match.source.text {
                messageSearch = MessageSearch(taskID: id, messageID: match.source.messageID, query: query, displayRange: match.range, displayText: match.source.text); pendingMessageReveal = true
            }
            renderAgentMessages()
        }
        taskFind.onClose = { [weak self] in guard let self, selectedTab == "chat" else { return }; self.window?.makeFirstResponder(composer) }
        taskSidebar.onSearchVersion = { [weak companion] id in companion?.agentStore?.taskSearchRevisions[id] ?? 0 }
        taskSidebar.onSearch = { [weak companion] query, candidates in
            guard let directory = companion?.agentStore?.directory else { return AgentTaskSearch.Result(checked: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.version) }), issues: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, "任务系统尚未初始化") })) }
            return await AgentTaskSearch.find(query, candidates: candidates, directory: directory)
        }
        if companion.usesAgent { NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityDisplayChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil) }
        if companion.usesAgent { NotificationCenter.default.addObserver(self, selector: #selector(automationDefinitionsChanged), name: AgentAutomations.changed, object: companion.agentStore?.automations) }
        if companion.usesAgent { NotificationCenter.default.addObserver(self, selector: #selector(conversationDisplayChanged), name: AgentGeneralSettings.changed, object: companion.generalSettings) }
        if companion.usesAgent { NotificationCenter.default.addObserver(self, selector: #selector(thinkingStatusChanged), name: AgentThinkingStatus.changed, object: companion.thinkingStatus) }
        refreshPreferences(); refreshShortcutControls(); refreshAppearancePreferences()
        if let task = currentAgentTask { displayedTask = task.id; displayedWorkMode = task.organizationMode; bindAgentDraft(task); taskNavigation = [task.id]; taskNavigationIndex = 0 }
        refreshThemeStyle()
        renderMessages()
        if windowNumber == 1 {
            companion.onScaleChange = { [weak companion] value in for window in companion?.taskControls ?? [] { window.scale.doubleValue = value; window.sizeValue.stringValue = "\(Int((value * 100).rounded()))%" } }
            companion.onWakeChange = { [weak companion] enabled, status in
                for window in companion?.taskControls ?? [] {
                    window.wakeEnabled.state = enabled ? .on : .off; window.wakeStatus.stringValue = status
                    window.sidebarWake.stringValue = enabled ? status : "语音未开启"; window.listenButton.title = enabled ? "立即聆听" : "开启语音"
                    window.stopRecordingButton.isEnabled = enabled; window.voiceStopButton.isEnabled = enabled; window.updateWorkbenchVoice()
                }
            }
            companion.screenCompanion.onChange = { [weak companion] state in for window in companion?.taskControls ?? [] { window.updateScreenStatus(state) } }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func sidebarButton(_ item: AgentSidebarItem) -> NSButton {
        if let button = taskSidebar.navigationButton(item) { return button }
        switch item { case .automation: return automationButton; case .extensions: return sidebarExtensions; case .library: return libraryButton; case .wiki: return projectKnowledgeButton; default: preconditionFailure("Missing sidebar control") }
    }
    func refreshSidebarLayout() {
        guard companion?.usesAgent == true, settingsNav.superview != nil, let service = companion?.sidebarLayout else { return }
        let layout = service.settings
        if displayedSidebarLayout != layout {
            displayedSidebarLayout = layout
            let focused = window?.firstResponder as? NSView
            taskSidebar.setUpperNavigation([]); sidebarLower.configure([])
            for item in AgentSidebarItem.allCases { sidebarButton(item).identifier = NSUserInterfaceItemIdentifier("sidebar-" + item.rawValue) }
            taskSidebar.setUpperNavigation(layout.upper.map(sidebarButton)); sidebarLower.configure(layout.lower.map(sidebarButton))
            sidebarMore.isHidden = layout.more.isEmpty
            window?.contentView?.layoutSubtreeIfNeeded()
            if let focused, focused.window === window { window?.makeFirstResponder(focused) }
            else if let focused, AgentSidebarItem.allCases.contains(where: { sidebarButton($0) === focused }) { window?.makeFirstResponder(sidebarMore) }
        }
        refreshSidebarMoreSelection()
    }
    private var selectedSidebarItem: AgentSidebarItem? {
        switch selectedTab {
        case "attention": return .attention
        case "automation": return .automation
        case "knowledge": return knowledgePageHost.selectedRoot == "wiki" ? .wiki : .library
        case "chat": return taskSidebar.isSearchPresented ? .search : nil
        default: return nil
        }
    }
    private func refreshSidebarMoreSelection() {
        let active = selectedSidebarItem.map { companion?.sidebarLayout.settings.more.contains($0) == true } ?? false
        AgentWorkbenchTheme.color(sidebarMore.layer, active ? AgentWorkbenchTheme.navigationSelection : .clear, animated: false)
    }
    private func sidebarMoreMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for item in companion?.sidebarLayout.settings.more ?? [] {
            let button = sidebarButton(item), entry = NSMenuItem(title: button.title, action: #selector(openSidebarItem(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = item.rawValue; entry.image = button.image; entry.isEnabled = button.isEnabled; entry.state = selectedSidebarItem == item ? .on : .off; menu.addItem(entry)
        }
        return menu
    }
    @objc private func showSidebarMore() { sidebarMoreMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sidebarMore.bounds.maxY + 4), in: sidebarMore) }
    @objc private func openSidebarItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let item = AgentSidebarItem(rawValue: raw), companion?.sidebarLayout.settings.more.contains(item) == true else { return }
        sidebarButton(item).performClick(nil); refreshSidebarMoreSelection()
    }
    func sidebarLayoutReadback() -> [String: Any] {
        let layout = companion?.sidebarLayout.settings ?? AgentSidebarLayout.Settings()
        var result = taskSidebar.navigationReadback()
        result["upper"] = layout.upper.map(\.rawValue); result["lower"] = layout.lower.map(\.rawValue); result["more"] = layout.more.map(\.rawValue)
        result["actualLower"] = sidebarLower.buttons.map { $0.identifier?.rawValue ?? "" }
        result["moreVisible"] = !sidebarMore.isHidden; result["moreMenu"] = sidebarMoreMenu().items.map { $0.representedObject as? String ?? "" }
        result["settingsFixed"] = settingsNav.superview != nil && settingsNav.window === window
        result["lowerHeight"] = sidebarLower.frame.height; result["lowerDocumentHeight"] = sidebarLower.documentView?.frame.height ?? 0
        result["mainPage"] = selectedTab; result["activeMore"] = selectedSidebarItem.map { layout.more.contains($0) } ?? false
        result["moreHighlighted"] = (sidebarMore.layer?.backgroundColor?.alpha ?? 0) > 0
        return result
    }

    func refreshAppearancePreferences() {
        guard let window else { return }
        refreshSidebarLayout()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor = AgentThemeContext.resolve(AgentWorkbenchTheme.sidebar, window: window)
            sendButton.layer?.backgroundColor = AgentThemeContext.resolve(companion?.usesAgent == true ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.primary, window: window).cgColor
            sendButton.contentTintColor = AgentThemeContext.resolve(companion?.usesAgent == true ? AgentWorkbenchTheme.accentText : AgentWorkbenchTheme.primaryText, window: window)
            generalSettingsSave?.layer?.backgroundColor = AgentWorkbenchTheme.primary.cgColor
            generalSettingsSave?.contentTintColor = AgentWorkbenchTheme.primaryText
            for (index, button) in categoryButtons.enumerated() {
                let active = settingsSearch.stringValue.isEmpty && settingsCategories[index].0 == settingsCategory
                button.layer?.backgroundColor = (active ? AgentWorkbenchTheme.navigationSelection : .clear).cgColor
            }
            for (button, active) in [(chatNav, selectedTab == "chat"), (settingsNav, selectedTab == "settings"), (automationButton, selectedTab == "automation"), (libraryButton, selectedTab == "knowledge" && knowledgePageHost.selectedRoot == "library"), (projectKnowledgeButton, selectedTab == "knowledge" && knowledgePageHost.selectedRoot == "wiki")] {
                button.layer?.backgroundColor = (active ? AgentWorkbenchTheme.navigationSelection : .clear).cgColor
            }
        }
        composer.font = AgentContentAppearance.font(size: AgentAppearance.messageSize)
        messageRows.values.forEach { $0.refreshAppearance() }
        settingsPageHost.refreshAppearance()
        attentionPageController?.refreshAppearance()
        contentSurface.needsDisplay = true
        if let root = window.contentView { AgentThemeContext.refresh(root, invalidate: true) }
    }
    func refreshThemeStyle() {
        guard let window, let companion, companion.usesAgent else { return }
        AgentThemeContext.bind(window, service: companion.themeStyles, mode: currentAgentTask?.organizationMode ?? displayedWorkMode)
        refreshAppearancePreferences()
    }
    func refreshContentAppearance() {
        composer.font = AgentContentAppearance.font(size: AgentAppearance.messageSize)
        messageRows.values.forEach { $0.refreshAppearance() }
        updateWorkbenchLayout()
    }
    func contentAppearanceReadback() -> [String: Any] {
        guard CommandLine.arguments.contains("--content-appearance-check") || CommandLine.arguments.contains("--manual-ui"), let window else { return [:] }
        window.contentView?.layoutSubtreeIfNeeded()
        let rows: [[String: Any]] = messageRows.map { id, row in
            var fonts = Set<String>()
            row.label.attributedStringValue.enumerateAttribute(.font, in: NSRange(location: 0, length: row.label.attributedStringValue.length)) { value, _, _ in if let font = value as? NSFont { fonts.insert(font.fontName) } }
            return ["id": id, "source": row.text, "display": row.label.stringValue, "fonts": fonts.sorted()]
        }
        var glyphFonts: [String: String] = [:]
        for (script, pattern) in [("cjk", "\\p{Han}+"), ("latin", "[A-Za-z]+") ] {
            if let range = composer.string.range(of: pattern, options: .regularExpression), let font = composer.textStorage?.attribute(.font, at: NSRange(range, in: composer.string).location, effectiveRange: nil) as? NSFont {
                let token = String(composer.string[range]); let resolved = CTFontCreateForString(font as CTFont, token as CFString, CFRange(location: 0, length: (token as NSString).length))
                glyphFonts[script] = CTFontCopyPostScriptName(resolved) as String
            }
        }
        return ["taskID": agentTaskID as Any? ?? NSNull(), "fontStyle": AgentContentAppearance.fontStyle.rawValue, "contentWidth": companion?.contentAppearance.settings.contentWidth.rawValue ?? "standard", "columnWidth": (workbenchColumnLeading?.firstItem as? NSView)?.bounds.width ?? 0, "composerWidth": composer.enclosingScrollView?.superview?.bounds.width ?? 0, "composerFont": composer.font?.fontName ?? "", "composerGlyphFonts": glyphFonts, "composerSize": composer.font?.pointSize ?? 0, "draft": composer.string, "messages": rows, "windowSize": [window.frame.width, window.frame.height]]
    }
    func fileIconsReadback() -> [String: Any] {
        guard let content = window?.contentView else { return [:] }; return AgentFileIcons.readback(in: content)
    }
    func themeStylesReadback() -> [String: Any] {
        guard CommandLine.arguments.contains("--theme-styles-check") || CommandLine.arguments.contains("--manual-ui"), let window else { return [:] }
        window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded()
        var send: [CGFloat] = [], sidebar: [CGFloat] = []
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let color = sendButton.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB) { send = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent] }
            if let color = window.backgroundColor.usingColorSpace(.sRGB) { sidebar = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent] }
        }
        return ["taskID": agentTaskID as Any? ?? NSNull(), "mode": currentAgentTask?.organizationMode.rawValue ?? displayedWorkMode.rawValue, "style": AgentThemeContext.style(for: window)?.rawValue ?? "unbound", "sendColor": send, "sidebarColor": sidebar, "selectedTaskColor": taskSidebar.appearanceSelectionColor() ?? [], "draft": composer.string, "page": selectedTab]
    }
    func checkAppearanceComposerSize() -> CGFloat? {
        guard CommandLine.arguments.contains("--appearance-check") else { return nil }; return composer.font?.pointSize
    }
    func checkAppearanceSelectionColor() -> [CGFloat]? {
        guard CommandLine.arguments.contains("--appearance-check") else { return nil }
        window?.contentView?.layoutSubtreeIfNeeded()
        return taskSidebar.appearanceSelectionColor()
    }
    func checkAppearanceLayout() -> [String: Bool] {
        guard CommandLine.arguments.contains("--appearance-check"), let window else { return [:] }
        let original = window.contentView?.bounds.size ?? .zero
        selectedTab = "settings"; settingsCategory = "appearance"; changeTab()
        var result: [String: Bool] = [:]
        for (name, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 806, height: 550))] {
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
            guard let scroll = settingsSidebar.subviews.compactMap({ $0 as? NSScrollView }).first else { result[name + "SettingsCategoryScrollerExists"] = false; continue }
            let before = settingsSearch.convert(settingsSearch.bounds, to: settingsSidebar)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView); window.contentView?.layoutSubtreeIfNeeded()
            let after = settingsSearch.convert(settingsSearch.bounds, to: settingsSidebar)
            result[name + "SettingsSearchStaysPinnedAndVisible"] = before == after && settingsSidebar.bounds.contains(after) && after.width >= 140 && after.height >= 26 && !after.intersects(scroll.frame)
        }
        result["ExistingComposerUsesCurrentTextSize"] = composer.font?.pointSize == AgentAppearance.messageSize
        window.setContentSize(original); selectedTab = "chat"; changeTab()
        return result
    }

    @objc private func accessibilityDisplayChanged() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let root = window?.contentView else { return }
        AgentWorkbenchTheme.cancelMotion(in: root); updateWorkbenchLayout()
    }

    func checkSettingsPageLayout() async -> [String: Any] {
        guard CommandLine.arguments.contains("--settings-layout-check"), let window else { return [:] }
        let original = window.contentView?.bounds.size ?? .zero, draft = composer.string
        var checks: [String: Bool] = [:], frames: [String: [String: Double]] = [:]
        window.makeKeyAndOrderFront(nil)
        for (name, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
            for category in ["model", "appearance", "extensions", "agents", "teams", "hooks", "memory"] {
                guard let index = settingsCategories.firstIndex(where: { $0.0 == category }) else { continue }
                returnToChat(); window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 100_000_000)
                selectedTab = "settings"; settingsCategory = category; settingsSearch.stringValue = ""; changeTab()
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 100_000_000)
                let column = settings.convert(settings.bounds, to: contentSurface), body = settingsBody.convert(settingsBody.bounds, to: contentSurface)
                let alignment = settingsHeading.alignmentRect(forFrame: settingsHeading.frame)
                let heading = settingsHeading.superview!.convert(alignment, to: contentSurface)
                let key = name + "-" + category, centerError = abs(column.midX - contentSurface.bounds.midX)
                let actualWidth = window.contentView?.bounds.width ?? 0
                frames[key] = ["width": column.width, "windowWidth": actualWidth, "windowHeight": Double(window.contentView?.bounds.height ?? 0), "inspectorWidth": workbenchInspector.bounds.width, "centerError": centerError, "headingX": heading.minX - column.minX, "headingTop": contentSurface.bounds.height - heading.maxY, "bodyGap": heading.minY - body.maxY, "leadingGutter": column.minX, "trailingGutter": contentSurface.bounds.width - column.maxX]
                // AppKit snaps view frames to the pixel grid and gives labels
                // alignment insets. Check layout anchors and the actual window.
                let fitsWindow = abs(actualWidth - size.width) < 0.5 && column.width >= 500 && column.width <= 764.5 && column.minX >= 27.5 && column.maxX <= contentSurface.bounds.width - 27.5
                let aligned = centerError <= 0.5 && abs(heading.minX - column.minX - 16) < 0.5 && (50...64).contains(contentSurface.bounds.height - heading.maxY) && heading.minY > body.maxY
                checks[key + "CenteredColumnAndContentHeading"] = fitsWindow && aligned && settingsHeading.stringValue == settingsCategories[index].1 && pageTitle.isHidden && workbenchChrome.allSatisfy(\.isHidden)
                checks[key + "VisibleWindowRetainsRequestedSize"] = window.isVisible && window.contentView?.bounds.size == size
                if category == "appearance", let group = settingGroups.first(where: { $0.category == category })?.view {
                    func find(_ view: NSView) -> AgentAppearanceSettingsView? { (view as? AgentAppearanceSettingsView) ?? view.subviews.lazy.compactMap(find).first }
                    let width = find(group)?.bounds.width ?? 0
                    checks[key + "AppearanceControlsFillContentColumn"] = width >= group.bounds.width - 32.5
                    frames[key]?["appearanceControlWidth"] = width
                }
            }
        }
        returnToChat(); window.setContentSize(original); window.contentView?.layoutSubtreeIfNeeded()
        checks["settingsPageChangesPreserveUnsentComposer"] = composer.string == draft && settingsSidebar.isHidden && settings.isHidden
        checks["settingsDoNotReserveHiddenInspectorWidth"] = frames.values.allSatisfy { $0["inspectorWidth"] == 0 }
        return ["checks": checks, "frames": frames]
    }

    private func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 12) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = vertical ? .vertical : .horizontal
        s.alignment = vertical ? .leading : .centerY; s.spacing = spacing; s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    private func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
    }
    private func field(_ field: NSTextField) {
        AgentSettingsStyle.field(field); field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
    }
    private func styleNavigation(_ button: NSButton, symbol: String, compact: Bool = false) {
        button.isBordered = false; button.font = .systemFont(ofSize: compact ? 13 : 14, weight: .medium); button.alignment = .left
        button.imagePosition = .imageLeading; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.image?.size = NSSize(width: compact ? 14 : 17, height: compact ? 14 : 17); button.contentTintColor = .labelColor
        button.wantsLayer = true; button.layer?.cornerRadius = compact ? 6 : 9; button.heightAnchor.constraint(equalToConstant: compact ? 30 : 38).isActive = true
    }
    private func build() {
        guard let window else { return }
        if companion?.usesAgent == true { buildWorkbench(); return }
        let content = SidebarBackground(); window.contentView = content
        let title = NSTextField(labelWithString: "小鲸"); title.font = .systemFont(ofSize: 19, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = NSColor(red: 0.28, green: 0.52, blue: 0.78, alpha: 1)
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true; icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let brand = stack([icon, title], spacing: 10); content.addSubview(brand)
        for (index, button) in [chatNav, settingsNav].enumerated() {
            button.tag = index; button.target = self; button.action = #selector(selectTab(_:))
            styleNavigation(button, symbol: index == 0 ? "bubble.left.and.bubble.right" : "slider.horizontal.3")
        }
        let navigation = stack([chatNav, settingsNav], vertical: true, spacing: 6); content.addSubview(navigation)
        for button in [chatNav, settingsNav] { button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true }
        listenButton.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil); listenButton.imagePosition = .imageLeading
        listenButton.isBordered = false; listenButton.font = .systemFont(ofSize: 13); listenButton.alignment = .left
        listenButton.target = self; listenButton.action = #selector(listen)
        stopRecordingButton.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil); stopRecordingButton.imagePosition = .imageLeading
        stopRecordingButton.isBordered = false; stopRecordingButton.font = .systemFont(ofSize: 13); stopRecordingButton.alignment = .left
        for button in [stopRecordingButton, voiceStopButton] { button.target = companion; button.action = #selector(AppDelegate.stopRecording); button.contentTintColor = .systemRed }
        sidebarWake.font = .systemFont(ofSize: 11); sidebarWake.textColor = AgentWorkbenchTheme.secondaryText
        clearButton.isBordered = false; clearButton.font = .systemFont(ofSize: 12); clearButton.alignment = .left
        clearButton.target = self; clearButton.action = #selector(clear)
        let knowledge = NSButton(title: "项目知识", target: self, action: #selector(showAgentKnowledge)); knowledge.isBordered = false; knowledge.font = .systemFont(ofSize: 12); knowledge.alignment = .left
        knowledge.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: nil); knowledge.imagePosition = .imageLeading; knowledge.isHidden = companion?.usesAgent != true
        let extensions = NSButton(title: "扩展", target: self, action: #selector(showAgentExtensions)); extensions.isBordered = false; extensions.font = .systemFont(ofSize: 12); extensions.alignment = .left
        extensions.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil); extensions.imagePosition = .imageLeading; extensions.isHidden = companion?.usesAgent != true
        let sideFooter = stack([extensions, knowledge, listenButton, stopRecordingButton, sidebarWake, clearButton], vertical: true, spacing: 13); content.addSubview(sideFooter)
        chatSidebarViews = [brand, navigation, sideFooter]
        if companion?.usesAgent == true {
            taskSidebar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(taskSidebar); chatSidebarViews.append(taskSidebar)
            NSLayoutConstraint.activate([taskSidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), taskSidebar.trailingAnchor.constraint(equalTo: content.leadingAnchor, constant: 184), taskSidebar.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 18), taskSidebar.bottomAnchor.constraint(equalTo: sideFooter.topAnchor, constant: -20)])
            taskSidebar.onSelect = { [weak self] id in self?.selectAgentTask(id) }
            taskSidebar.onAttention = { [weak self] in self?.showAttentionPage() }
            taskSidebar.onNew = { [weak self] in self?.newAgentTask() }
            taskSidebar.onAction = { [weak self] id, action in self?.agentTaskAction(id, action: action) }
        }
        let main = contentSurface; main.translatesAutoresizingMaskIntoConstraints = false; main.wantsLayer = true
        main.layer?.backgroundColor = NSColor.clear.cgColor; main.layer?.cornerRadius = 17; main.layer?.masksToBounds = true; content.addSubview(main)
        pageTitle.font = .systemFont(ofSize: 14, weight: .semibold); pageTitle.textColor = AgentWorkbenchTheme.secondaryText
        pageTitle.lineBreakMode = .byTruncatingTail; pageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageTitle.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(pageTitle)
        titleLeading = pageTitle.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28)
        let panels = NSView(); main.addSubview(panels); panels.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: content.topAnchor, constant: 65), brand.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 25),
            navigation.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 28), navigation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), navigation.widthAnchor.constraint(equalToConstant: 166),
            sideFooter.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 27), sideFooter.trailingAnchor.constraint(equalTo: content.leadingAnchor, constant: 182), sideFooter.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            main.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 200), main.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8), main.topAnchor.constraint(equalTo: content.topAnchor, constant: 8), main.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            pageTitle.topAnchor.constraint(equalTo: main.topAnchor, constant: 22), titleLeading, pageTitle.trailingAnchor.constraint(lessThanOrEqualTo: main.trailingAnchor, constant: -28),
            panels.topAnchor.constraint(equalTo: pageTitle.bottomAnchor, constant: 18), panels.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28), panels.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28), panels.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -24)])
        for panel in [chat, settings, attentionContent, automationContent, knowledgeContent] { panels.addSubview(panel); pin(panel, to: panels) }
        knowledgeContent.addSubview(knowledgePageHost); pin(knowledgePageHost, to: knowledgeContent)
        buildChat(); buildSettingsSidebar(in: content); buildSettings(); changeTab()
    }
    private func buildWorkbench() {
        guard let window else { return }
        window.backgroundColor = AgentWorkbenchTheme.sidebar; window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        let content = SidebarBackground(); content.wantsLayer = true; window.contentView = content
        workbenchSidebar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(workbenchSidebar)
        workbenchSidebarWidth = workbenchSidebar.widthAnchor.constraint(equalToConstant: 231)
        NSLayoutConstraint.activate([workbenchSidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), workbenchSidebar.topAnchor.constraint(equalTo: content.topAnchor), workbenchSidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor), workbenchSidebarWidth])
        let icon = NSImageView(image: NSImage(systemSymbolName: "fish", accessibilityDescription: "小鲸")!)
        icon.contentTintColor = AgentWorkbenchTheme.accent; icon.imageScaling = .scaleProportionallyUpOrDown; icon.widthAnchor.constraint(equalToConstant: 33).isActive = true; icon.heightAnchor.constraint(equalToConstant: 25).isActive = true
        let title = NSTextField(labelWithString: "小鲸"); title.font = .systemFont(ofSize: 16, weight: .semibold)
        let brand = stack([icon, title], spacing: 9); workbenchSidebar.addSubview(brand)
        taskSidebar.translatesAutoresizingMaskIntoConstraints = false; workbenchSidebar.addSubview(taskSidebar)
        taskSidebar.onSelect = { [weak self] id in self?.selectAgentTask(id) }
        taskSidebar.onAttention = { [weak self] in self?.showAttentionPage() }
        taskSidebar.onNew = { [weak self] in self?.newAgentTask() }
        taskSidebar.onNewWorkspace = { [weak self] in self?.chooseProjectDirectory() }
        taskSidebar.onNewInWorkspace = { [weak self] path, mode in
            guard let self, let tasks = self.companion?.agentStore, self.saveAgentDraft() else { return }
            do { self.selectAgentTask(try tasks.createWorkspaceTask(path,mode:mode)) } catch { self.setStatus(error.localizedDescription,error:true) }
        }
        taskSidebar.onAction = { [weak self] id, action in self?.agentTaskAction(id, action: action) }
        taskSidebar.onBulkArchive = { [weak self] ids, archived in self?.archiveTasks(ids, archived: archived) == true }
        taskSidebar.onWorkMode = { [weak self] mode in self?.switchWorkMode(mode) }
        taskSidebar.onDirectoryAction = { [weak self] path, mode, action in self?.directoryAction(path, mode: mode, action: action) }
        taskSidebar.onDirectorySort = { [weak self] sort, mode in
            guard let self, let tasks = self.companion?.agentStore else { return }
            do { try tasks.organization.sort(sort, mode: mode); self.renderAgentMessages() } catch { self.setStatus(error.localizedDescription, error: true) }
        }
        taskSidebar.onTaskView = { [weak self] view, mode in
            guard let self, let tasks = self.companion?.agentStore else { return }
            do { if let view { try tasks.organization.setTaskView(view, mode: mode) } else { try tasks.organization.resetTaskView(mode) }; self.renderAgentMessages() } catch { self.setStatus(error.localizedDescription, error: true) }
        }
        taskSidebar.onCustomGroup = { [weak self] id, mode, action in self?.customTaskGroup(id, mode: mode, action: action) }
        taskSidebar.onAssignGroup = { [weak self] task, group, mode in
            guard let self, let tasks = self.companion?.agentStore else { return false }
            do { try tasks.organization.assignTask(task, group: group, mode: mode, tasks: tasks.tasks); self.renderAgentMessages(); return true } catch { self.setStatus(error.localizedDescription, error: true); return false }
        }
        taskSidebar.onReorderGroup = { [weak self] id, target, mode, grouping in
            guard let self, let tasks = self.companion?.agentStore else { return false }
            do { try tasks.organization.reorder(id, before: target, mode: mode, grouping: grouping, tasks: tasks.tasks); self.renderAgentMessages(); return true } catch { self.setStatus(error.localizedDescription, error: true); return false }
        }
        let knowledge = projectKnowledgeButton, library = libraryButton
        knowledge.target = self; knowledge.action = #selector(showAgentKnowledge); library.target = self; library.action = #selector(showKnowledgeLibrary)
        let extensions = sidebarExtensions; extensions.target = self; extensions.action = #selector(showAgentExtensions)
        settingsNav.tag = 1; settingsNav.target = self; settingsNav.action = #selector(selectTab(_:))
        automationButton.target = self; automationButton.action = #selector(showAutomations)
        sidebarMore.target = self; sidebarMore.action = #selector(showSidebarMore)
        for (button, symbol) in [(automationButton as NSButton, "clock.arrow.circlepath"), (library as NSButton, "tray.full"), (knowledge as NSButton, "books.vertical"), (extensions as NSButton, "puzzlepiece.extension"), (sidebarMore as NSButton, "ellipsis"), (settingsNav, "gearshape")] {
            AgentWorkbenchTheme.sidebarControl(button)
            button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 14)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading; button.contentTintColor = .labelColor
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        sidebarLower.setAccessibilityLabel("侧栏下方入口")
        let footer = stack([AgentWorkbenchTheme.rule(), sidebarLower, sidebarMore, settingsNav], vertical: true, spacing: 6); workbenchSidebar.addSubview(footer)
        for view in [sidebarLower as NSView, sidebarMore, settingsNav] { view.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }
        chatSidebarViews = [workbenchSidebar]
        let main = contentSurface; main.usesWorkbenchSurface = true; main.wantsLayer = true; main.layer?.backgroundColor = NSColor.clear.cgColor; main.layer?.cornerRadius = 0
        main.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(main)
        sidebarWidth = main.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 231)
        let leftRule = AgentThemeView(fill: AgentWorkbenchTheme.line); content.addSubview(leftRule); leftRule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sidebarWidth, main.trailingAnchor.constraint(equalTo: content.trailingAnchor), main.topAnchor.constraint(equalTo: content.topAnchor), main.bottomAnchor.constraint(equalTo: content.bottomAnchor), leftRule.leadingAnchor.constraint(equalTo: main.leadingAnchor), leftRule.widthAnchor.constraint(equalToConstant: 1), leftRule.topAnchor.constraint(equalTo: content.topAnchor), leftRule.bottomAnchor.constraint(equalTo: content.bottomAnchor), brand.leadingAnchor.constraint(equalTo: workbenchSidebar.leadingAnchor, constant: 20), brand.topAnchor.constraint(equalTo: workbenchSidebar.topAnchor, constant: 55), taskSidebar.leadingAnchor.constraint(equalTo: workbenchSidebar.leadingAnchor, constant: 16), taskSidebar.trailingAnchor.constraint(equalTo: workbenchSidebar.trailingAnchor, constant: -15), taskSidebar.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 22), taskSidebar.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12), footer.leadingAnchor.constraint(equalTo: taskSidebar.leadingAnchor), footer.trailingAnchor.constraint(equalTo: taskSidebar.trailingAnchor), footer.bottomAnchor.constraint(equalTo: workbenchSidebar.bottomAnchor, constant: -24)])
        for (button, label, symbol, action) in [(taskBack, "上一个任务", "chevron.left", #selector(previousAgentTask)), (taskForward, "下一个任务", "chevron.right", #selector(nextAgentTask)), (taskMore, "任务操作", "ellipsis", #selector(showTaskMenu(_:)))] {
            AgentWorkbenchTheme.toolbar(button, title: label, symbol: symbol); button.target = self; button.action = action
        }
        AgentWorkbenchTheme.toolbar(sidebarToggle, title: "收起左侧栏", symbol: "sidebar.left"); sidebarToggle.target = self; sidebarToggle.action = #selector(toggleLeftSidebar)
        let navigation = stack([sidebarToggle, taskBack, taskForward], spacing: 2); main.addSubview(navigation)
        pageTitle.font = .systemFont(ofSize: 18, weight: .semibold); pageTitle.lineBreakMode = .byTruncatingTail; pageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageTitle.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(pageTitle); main.addSubview(workbenchBadge)
        titleLeading = pageTitle.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 126)
        projectButton.target = self; projectButton.action = #selector(chooseProject); AgentWorkbenchTheme.toolbar(projectButton, title: "选择项目", symbol: "folder")
        browserButton.target = self; browserButton.action = #selector(showAgentBrowser); AgentWorkbenchTheme.toolbar(browserButton, title: "浏览器", symbol: "rectangle.on.rectangle")
        terminalButton.target = self; terminalButton.action = #selector(toggleTaskTerminal)
        AgentWorkbenchTheme.toolbar(terminalButton, title: "打开终端", symbol: "terminal")
        desktopButton.target = self; desktopButton.action = #selector(showDesktopSettings); AgentWorkbenchTheme.toolbar(desktopButton, title: "电脑操作", symbol: "computermouse")
        gitButton.target = self; gitButton.action = #selector(showAgentGit); AgentWorkbenchTheme.toolbar(gitButton, title: "Git", symbol: "arrow.triangle.branch")
        resultsButton.target = self; resultsButton.action = #selector(toggleTaskInspector); AgentWorkbenchTheme.toolbar(resultsButton, title: "任务监控", symbol: "checklist")
        let actions = stack([projectButton, browserButton, terminalButton, desktopButton, gitButton, resultsButton, taskMore], spacing: 4); main.addSubview(actions)
        let headerRule = AgentWorkbenchTheme.rule(); main.addSubview(headerRule)
        workbenchChrome = [navigation, actions, workbenchBadge, headerRule]
        for panel in [chat, settings] { panel.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(panel) }
        main.addSubview(attentionContent); pin(attentionContent, to: main)
        main.addSubview(automationContent); pin(automationContent, to: main)
        main.addSubview(knowledgeContent); pin(knowledgeContent, to: main)
        knowledgeContent.addSubview(knowledgePageHost); pin(knowledgePageHost, to: knowledgeContent)
        knowledgePageHost.onRootChange = { [weak self] _ in self?.refreshKnowledgeNavigation() }
        buildWorkbenchConversation()
        headerInspectorRule.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(headerInspectorRule)
        NSLayoutConstraint.activate([headerInspectorRule.leadingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor), headerInspectorRule.widthAnchor.constraint(equalToConstant: 1), headerInspectorRule.topAnchor.constraint(equalTo: main.topAnchor), headerInspectorRule.bottomAnchor.constraint(equalTo: headerRule.topAnchor)])
        navigationLeading = navigation.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 18)
        headerActionsTrailing = actions.trailingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor, constant: -16)
        fullHeaderActionsTrailing = actions.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -16)
        NSLayoutConstraint.activate([navigationLeading, navigation.centerYAnchor.constraint(equalTo: main.topAnchor, constant: 30), titleLeading, pageTitle.centerYAnchor.constraint(equalTo: main.topAnchor, constant: 30), workbenchBadge.leadingAnchor.constraint(equalTo: pageTitle.trailingAnchor, constant: 10), workbenchBadge.centerYAnchor.constraint(equalTo: pageTitle.centerYAnchor), workbenchBadge.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -14), headerActionsTrailing, actions.centerYAnchor.constraint(equalTo: pageTitle.centerYAnchor), headerRule.leadingAnchor.constraint(equalTo: main.leadingAnchor), headerRule.trailingAnchor.constraint(equalTo: main.trailingAnchor), headerRule.topAnchor.constraint(equalTo: main.topAnchor, constant: 59), chat.leadingAnchor.constraint(equalTo: main.leadingAnchor), chat.trailingAnchor.constraint(equalTo: main.trailingAnchor), chat.topAnchor.constraint(equalTo: headerRule.bottomAnchor), chat.bottomAnchor.constraint(equalTo: main.bottomAnchor), settings.centerXAnchor.constraint(equalTo: main.centerXAnchor), settings.widthAnchor.constraint(lessThanOrEqualToConstant: 764), settings.leadingAnchor.constraint(greaterThanOrEqualTo: main.leadingAnchor, constant: 28), settings.trailingAnchor.constraint(lessThanOrEqualTo: main.trailingAnchor, constant: -28), settings.topAnchor.constraint(equalTo: main.topAnchor, constant: 52), settings.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -24)])
        let columnWidth = settings.widthAnchor.constraint(equalToConstant: 764)
        // Keep the wide layout preferred while allowing the user to shrink it.
        columnWidth.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1); columnWidth.isActive = true
        buildSettingsSidebar(in: content); buildSettings(); changeTab()
    }
    private func buildWorkbenchConversation() {
        let conversation = terminalSplit.conversation
        terminalSplit.translatesAutoresizingMaskIntoConstraints = false
        chat.addSubview(terminalSplit); chat.addSubview(workbenchInspector); chat.addSubview(taskWorkspace)
        taskWorkspace.translatesAutoresizingMaskIntoConstraints = false
        taskWorkspace.onLayoutChange = { [weak self] in
            guard let self else { return }
            let wasInWorkspace = (window?.firstResponder as? NSView)?.isDescendant(of: taskWorkspace) == true
            updateWorkbenchLayout()
            guard !taskWorkspace.requested, selectedTab == "chat", composer.isEditable, !composer.isHiddenOrHasHiddenAncestor,
                  wasInWorkspace || window?.firstResponder === window else { return }
            window?.contentView?.layoutSubtreeIfNeeded(); window?.makeFirstResponder(composer)
        }
        taskWorkspace.onOpenRoot = { [weak self] root in
            switch root { case .review: self?.showAgentGit(); case .records: self?.presentAgentRecords(section: 4); case .context: self?.presentTaskContext(section: 0); case .browser: self?.showAgentBrowser(); case .mcpContent: self?.showTaskMCPContent(); case .document(let path): self?.showTaskDocument(path); case .canvas(let id): if let taskID = self?.agentTaskID { self?.openCanvasReference("canvas://" + id, taskID: taskID, location: .workspace) }; case .rollback(let id): if let taskID = self?.agentTaskID { self?.presentRoundRollback(taskID: taskID, messageID: id) }; case .editResend(let id): if let taskID = self?.agentTaskID { self?.presentEditResend(taskID: taskID, messageID: id) } }
        }
        taskWorkspace.onOpenDocument = { [weak self] in self?.chooseTaskDocument() }
        taskWorkspace.onOpenTerminal = { [weak self] in self?.openTaskTerminal() }
        conversationTrailing = terminalSplit.trailingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor)
        fullConversationTrailing = terminalSplit.trailingAnchor.constraint(equalTo: chat.trailingAnchor)
        inspectorWidth = workbenchInspector.widthAnchor.constraint(lessThanOrEqualToConstant: 281)
        inspectorPreferredWidth = workbenchInspector.widthAnchor.constraint(equalToConstant: 281)
        // Let live resizing reach the folding breakpoint before the old pane
        // width can clamp the window. The required maximum still makes a hidden pane zero width.
        inspectorPreferredWidth.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        inspectorRule.translatesAutoresizingMaskIntoConstraints = false; chat.addSubview(inspectorRule)
        NSLayoutConstraint.activate([terminalSplit.leadingAnchor.constraint(equalTo: chat.leadingAnchor), conversationTrailing, terminalSplit.topAnchor.constraint(equalTo: chat.topAnchor), terminalSplit.bottomAnchor.constraint(equalTo: chat.bottomAnchor), inspectorWidth, inspectorPreferredWidth, workbenchInspector.trailingAnchor.constraint(equalTo: chat.trailingAnchor), workbenchInspector.topAnchor.constraint(equalTo: chat.topAnchor), workbenchInspector.bottomAnchor.constraint(equalTo: chat.bottomAnchor), inspectorRule.leadingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor), inspectorRule.widthAnchor.constraint(equalToConstant: 1), inspectorRule.topAnchor.constraint(equalTo: chat.topAnchor), inspectorRule.bottomAnchor.constraint(equalTo: chat.bottomAnchor), taskWorkspace.leadingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor), taskWorkspace.trailingAnchor.constraint(equalTo: workbenchInspector.trailingAnchor), taskWorkspace.topAnchor.constraint(equalTo: workbenchInspector.topAnchor), taskWorkspace.bottomAnchor.constraint(equalTo: workbenchInspector.bottomAnchor)])
        configureTaskMonitor(workbenchInspector)
        history.hasVerticalScroller = true; history.drawsBackground = false; history.scrollerStyle = .overlay
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; history.documentView = document
        messageColumn.orientation = .vertical; messageColumn.alignment = .leading; messageColumn.spacing = 20; document.addSubview(messageColumn)
        messageColumn.translatesAutoresizingMaskIntoConstraints = false
        let readingTail = NSView(); readingTail.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(readingTail)
        let tailHeight = readingTail.heightAnchor.constraint(equalToConstant: 0); readingSpace = tailHeight
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: history.contentView.widthAnchor), messageColumn.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20), messageColumn.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20), messageColumn.topAnchor.constraint(equalTo: document.topAnchor, constant: 4), readingTail.topAnchor.constraint(equalTo: messageColumn.bottomAnchor), readingTail.leadingAnchor.constraint(equalTo: document.leadingAnchor), readingTail.trailingAnchor.constraint(equalTo: document.trailingAnchor), readingTail.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4), tailHeight])
        history.onUserScroll = { [weak self] in
            guard let self, readingAnchorID != nil else { return }; readingAnchorID = nil; readingSpace?.constant = 0; window?.contentView?.layoutSubtreeIfNeeded()
        }
        composer.font = .systemFont(ofSize: 14); composer.textContainerInset = NSSize(width: 2, height: 8); composer.drawsBackground = false; composer.isRichText = false; composer.allowsUndo = true
        composer.isAutomaticQuoteSubstitutionEnabled = false; composer.isAutomaticTextReplacementEnabled = false; composer.autoresizingMask = [.width]; composer.setAccessibilityLabel("消息")
        composer.onSend = { [weak self] in self?.send() }; composer.onInputChanged = { [weak self] in self?.composerChanged() }; composer.onEditingEnded = { [weak self] in self?.dismissExtensionCandidates() }
        composer.onExtensionKey = { [weak self] key in
            guard let self, extensionPickerTask != nil, extensionPanel.isVisible else { return false }
            switch key { case 125: extensionPicker.move(1); case 126: extensionPicker.move(-1); case 123, 124: return extensionPicker.moveCategory(key == 124 ? 1 : -1); case 36, 48, 76: extensionPicker.pick(); case 53: if !extensionPicker.goBack() { dismissExtensionCandidates() }; default: return false }; return true
        }
        let input = NSScrollView(); input.documentView = composer; input.hasVerticalScroller = true; input.drawsBackground = false; input.borderType = .noBorder
        for mode in AgentMode.allCases { modePopup.addItem(withTitle: mode.title) }; for mode in AgentPermissionMode.allCases { permissionPopup.addItem(withTitle: mode.title) }
        for popup in [modePopup, permissionPopup] { popup.controlSize = .small; popup.font = .systemFont(ofSize: 13); popup.isBordered = false; popup.target = self; popup.action = #selector(agentOptionsChanged) }
        modePopup.setAccessibilityLabel("任务模式"); permissionPopup.setAccessibilityLabel("审批方式")
        AgentWorkbenchTheme.toolbar(attachmentButton, title: "添加附件", symbol: "paperclip"); attachmentButton.target = self; attachmentButton.action = #selector(addAttachments)
        AgentWorkbenchTheme.toolbar(taskMCPContext, title: "MCP 资料与提示词", symbol: "server.rack"); taskMCPContext.target = self; taskMCPContext.action = #selector(showTaskMCPContent); taskMCPContext.isHidden = true
        taskModel.title = ""; taskModel.isBordered = false; taskModel.font = .systemFont(ofSize: 13); taskModel.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil); taskModel.imagePosition = .imageTrailing; taskModel.target = self; taskModel.action = #selector(showTaskModelMenu(_:)); taskModel.cell?.lineBreakMode = .byTruncatingMiddle
        taskModel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); taskModel.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        sendButton.title = ""; sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil); sendButton.imagePosition = .imageOnly; sendButton.isBordered = false; sendButton.contentTintColor = .white; sendButton.wantsLayer = true; sendButton.layer?.backgroundColor = AgentWorkbenchTheme.accent.cgColor; sendButton.layer?.cornerRadius = 8; sendButton.setAccessibilityLabel("发送"); sendButton.target = self; sendButton.action = #selector(send)
        sendButton.widthAnchor.constraint(equalToConstant: 34).isActive = true; sendButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        executionLocation.isBordered = false; executionLocation.font = .systemFont(ofSize: 13); executionLocation.target = self; executionLocation.action = #selector(showExecutionLocation); executionLocation.imagePosition = .imageTrailing; executionLocation.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        executionLocation.setAccessibilityLabel("执行位置")
        branchControl.isBordered = false; branchControl.font = .systemFont(ofSize: 12); branchControl.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil); branchControl.imagePosition = .imageLeading; branchControl.target = self; branchControl.action = #selector(showAgentGit); branchControl.setAccessibilityLabel("当前分支"); branchControl.cell?.lineBreakMode = .byTruncatingMiddle; branchControl.widthAnchor.constraint(lessThanOrEqualToConstant: 155).isActive = true
        entryLeading.orientation = .horizontal; entryLeading.spacing = 8; entryLeading.addArrangedSubview(attachmentButton); entryLeading.addArrangedSubview(taskMCPContext); entryLeading.addArrangedSubview(executionLocation); entryLeading.addArrangedSubview(branchControl); entryLeading.addArrangedSubview(modePopup); entryLeading.addArrangedSubview(permissionPopup)
        voiceInput.target = self; voiceInput.action = #selector(toggleWorkbenchVoice); AgentWorkbenchTheme.toolbar(voiceInput, title: "语音输入", symbol: "mic")
        entryTrailing.orientation = .horizontal; entryTrailing.spacing = 8; entryTrailing.addArrangedSubview(taskModel); entryTrailing.addArrangedSubview(taskContext); entryTrailing.addArrangedSubview(voiceInput); entryTrailing.addArrangedSubview(sendButton)
        for view in [entryLeading, entryTrailing] { entryToolbar.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        entryToolbarHeight = entryToolbar.heightAnchor.constraint(equalToConstant: 34)
        NSLayoutConstraint.activate([entryToolbarHeight, entryLeading.leadingAnchor.constraint(equalTo: entryToolbar.leadingAnchor), entryLeading.topAnchor.constraint(equalTo: entryToolbar.topAnchor), entryTrailing.trailingAnchor.constraint(equalTo: entryToolbar.trailingAnchor), entryTrailing.bottomAnchor.constraint(equalTo: entryToolbar.bottomAnchor)])
        let entry = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line); entry.layer?.cornerRadius = 12; entry.layer?.borderWidth = 1
        for view in [draftAttachments, input, entryToolbar] { entry.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([draftAttachments.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), draftAttachments.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), draftAttachments.topAnchor.constraint(equalTo: entry.topAnchor, constant: 8), input.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), input.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), input.topAnchor.constraint(equalTo: draftAttachments.bottomAnchor), input.heightAnchor.constraint(equalToConstant: 44), entryToolbar.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 12), entryToolbar.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -10), entryToolbar.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 8), entryToolbar.bottomAnchor.constraint(equalTo: entry.bottomAnchor, constant: -10)])
        let heading = workbenchEmptyTitle; heading.font = .systemFont(ofSize: 24, weight: .semibold); heading.isBordered = false
        heading.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil); heading.imagePosition = .imageTrailing; heading.target = self; heading.action = #selector(chooseExecutor); heading.setAccessibilityLabel("任务执行者")
        emptyProject.title = "选择项目"; emptyProject.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); emptyProject.imagePosition = .imageLeading; emptyProject.isBordered = false; emptyProject.target = self; emptyProject.action = #selector(chooseProject); emptyProject.font = .systemFont(ofSize: 12)
        let add = AgentWorkbenchButton(title: "添加附件", target: self, action: #selector(addAttachments)); add.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil); add.imagePosition = .imageLeading; add.isBordered = false; add.font = .systemFont(ofSize: 12)
        let browse = AgentWorkbenchButton(title: "浏览器", target: self, action: #selector(showAgentBrowser)); browse.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil); browse.imagePosition = .imageLeading; browse.isBordered = false; browse.font = .systemFont(ofSize: 12)
        let shortcuts = stack([emptyProject, add, browse], spacing: 22); workbenchEmpty.orientation = .vertical; workbenchEmpty.alignment = .centerX; workbenchEmpty.spacing = 18; workbenchEmpty.addArrangedSubview(heading); workbenchEmpty.addArrangedSubview(shortcuts)
        if let companion {
            let games = AgentHomeGamesView(service: companion.homeGames, choice: { [weak companion] in companion?.generalSettings.settings.homeGame ?? .random })
            homeGamesView = games; workbenchEmpty.addArrangedSubview(games); games.widthAnchor.constraint(equalTo: workbenchEmpty.widthAnchor).isActive = true
        }
        emptyBeforeHeight = emptyBefore.heightAnchor.constraint(equalToConstant: 90); emptyBeforeHeight.isActive = true
        emptyAfter.setContentHuggingPriority(.defaultLow, for: .vertical)
        modelCaption.font = .systemFont(ofSize: 10); modelCaption.textColor = .tertiaryLabelColor; modelCaption.alignment = .right; modelCaption.lineBreakMode = .byTruncatingTail
        resumeButton.target = self; resumeButton.action = #selector(resumeAgentTask); resumeButton.bezelStyle = .inline; resumeButton.font = .systemFont(ofSize: 12)
        taskContext.title = ""; taskContext.isBordered = false; taskContext.font = .systemFont(ofSize: 11); taskContext.contentTintColor = AgentWorkbenchTheme.secondaryText; taskContext.image = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: nil); taskContext.image?.size = NSSize(width: 15, height: 15); taskContext.imagePosition = .imageOnly; taskContext.target = self; taskContext.action = #selector(showTaskContext)
        taskContext.heightAnchor.constraint(equalToConstant: 28).isActive = true; taskContext.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true; taskContext.setContentHuggingPriority(.required, for: .horizontal)
        let lower = workbenchLower; lower.orientation = .horizontal; lower.spacing = 8; lower.addArrangedSubview(resumeButton); lower.addArrangedSubview(NSView()); lower.addArrangedSubview(modelCaption)
        status.font = .systemFont(ofSize: 12); status.lineBreakMode = .byTruncatingTail; status.isHidden = true
        configureApprovalPanel()
        mcpInputRow.orientation = .horizontal; mcpInputRow.addArrangedSubview(mcpInputButton); mcpInputRow.addArrangedSubview(NSView()); mcpInputRow.isHidden = true
        mcpInputButton.target = self; mcpInputButton.action = #selector(showMCPUserInput); mcpInputButton.setAccessibilityLabel("回答连接器问询")
        mcpInputButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = stack([taskFind, emptyBefore, workbenchEmpty, history, approvalPanel, mcpInputRow, status, entry, lower, emptyAfter], vertical: true, spacing: 14)
        conversation.addSubview(column)
        workbenchColumnLeading = column.leadingAnchor.constraint(equalTo: conversation.leadingAnchor, constant: 18)
        workbenchColumnTrailing = column.trailingAnchor.constraint(equalTo: conversation.trailingAnchor, constant: -18)
        NSLayoutConstraint.activate([workbenchColumnLeading, workbenchColumnTrailing, column.topAnchor.constraint(equalTo: conversation.topAnchor, constant: 28), column.bottomAnchor.constraint(equalTo: conversation.bottomAnchor, constant: -30)])
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        history.setContentHuggingPriority(.defaultLow, for: .vertical); history.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
    }
    private func updateWorkbenchLayout(animated: Bool = false) {
        guard companion?.usesAgent == true, inspectorWidth != nil, let task = currentAgentTask else { return }
        taskSwitcher?.refresh()
        let keepSearchHitVisible = isMessageSearchVisible
        let configuring = selectedTab == "settings", chatting = selectedTab == "chat", width = window?.contentView?.bounds.width ?? 1200
        terminalPanel?.selectTask(chatting ? task : nil)
        terminalButton.isEnabled = AgentTerminalPanel.available(task) && companion?.agentStore?.organization.archiveID(task.organizationWorkspace, mode: task.organizationMode) == nil
        workbenchInspector.canOpenTerminal = terminalButton.isEnabled
        updateTerminalDock()
        let hasMessages = task.messages.contains { ["user", "assistant"].contains($0.role) && $0.nativeContext != true } || !(task.agentDrafts ?? []).isEmpty || !(task.automationDrafts ?? []).isEmpty || task.skillEvolutionJob != nil
        let monitorContent = makeMonitorContent(task), monitorState = taskMonitorState(task.id)
        let hasRecords = monitorContent.hasContent
        workbenchSidebarWidth.constant = width < 900 ? 218 : 231
        let settingsWidth: CGFloat = width < 980 ? 180 : 231
        sidebarWidth.constant = configuring ? settingsWidth : sidebarRequested ? workbenchSidebarWidth.constant : 0
        taskWorkspace.selectTask(task.id)
        let showWorkspace = chatting && taskWorkspace.requested, remaining = width - sidebarWidth.constant
        let fullWorkspace = showWorkspace && (taskWorkspace.expanded || remaining < 920)
        let showInspector = chatting && !showWorkspace && monitorState.presentation == .fixed && monitorState.visible && (hasRecords || monitorState.explicitVisibility) && (width >= 1080 || monitorState.explicitVisibility)
        let fullMonitor = showInspector && width < 1080
        let target: CGFloat = showWorkspace ? (fullWorkspace ? remaining : min(560, max(470, floor(remaining * 0.51)))) : showInspector ? (fullMonitor ? remaining : 281) : 0
        if fullWorkspace || fullMonitor {
            conversationTrailing.isActive = false; fullConversationTrailing.isActive = true
        } else {
            fullConversationTrailing.isActive = false; conversationTrailing.isActive = true
        }
        if showWorkspace { headerActionsTrailing.isActive = false; fullHeaderActionsTrailing.isActive = true }
        else { fullHeaderActionsTrailing.isActive = false; headerActionsTrailing.isActive = true }
        terminalSplit.isHidden = fullWorkspace || fullMonitor
        if !showWorkspace { taskWorkspace.setVisible(false) }
        taskWorkspace.updateHeader(full: fullWorkspace, canSplit: remaining >= 920)
        settingsSidebarWidth?.constant = settingsWidth
        workbenchSidebar.isHidden = configuring || !sidebarRequested
        navigationLeading.constant = sidebarRequested ? 18 : 82
        titleLeading.constant = configuring ? 80 : sidebarRequested ? 126 : 190
        sidebarToggle.setAccessibilityLabel(sidebarRequested ? "收起左侧栏" : "显示左侧栏")
        let maximum = companion?.contentAppearance.settings.contentWidth.maximum ?? AgentContentWidth.standard.maximum
        let columnInset = max(18, (width - sidebarWidth.constant - (fullWorkspace || fullMonitor ? 0 : target) - maximum) / 2)
        workbenchColumnLeading.constant = columnInset; workbenchColumnTrailing.constant = -columnInset
        workbenchInspector.isHidden = !showInspector; inspectorRule.isHidden = !(showInspector || showWorkspace); headerInspectorRule.isHidden = !showInspector
        pageTitle.isHidden = !chatting || !(hasMessages || showWorkspace)
        workbenchBadge.isHidden = !chatting || !(hasMessages || showWorkspace)
        workbenchEmpty.isHidden = hasMessages; emptyBefore.isHidden = hasMessages; emptyAfter.isHidden = hasMessages; history.isHidden = !hasMessages
        emptyBeforeHeight.constant = max(0, min(80, ((window?.contentView?.bounds.height ?? 800) - 560) * 0.18))
        let gamesVisible = chatting && !hasMessages && !fullWorkspace && !fullMonitor && !task.archived && task.kind != "hook" && !task.isProjectDocumentation
        homeGamesView?.show(gamesVisible, context: task.id + ":" + task.organizationMode.rawValue)
        if gamesVisible, let store = companion?.agentStore { companion?.homeGames.refreshActivity(store) }
        workbenchEmptyTitle.title = task.team?.team.name ?? task.agent?.profile.name ?? "新的任务"
        workbenchEmptyTitle.isEnabled = task.canChooseExecutor
        emptyProject.title = companion?.agentStore?.organization.name(task.organizationWorkspace, mode: task.organizationMode) ?? "选择" + task.organizationMode.directoryTitle; emptyProject.toolTip = task.workspace
        if let entry = companion?.agentStore?.organization.entry(task.organizationWorkspace ?? "",mode:task.organizationMode,tasks:companion?.agentStore?.tasks ?? []) { emptyProject.image = NSImage(systemSymbolName:(entry.icon ?? .folder).rawValue,accessibilityDescription:nil); emptyProject.contentTintColor = (entry.color ?? .forest).nsColor } else { emptyProject.image = NSImage(systemSymbolName:"folder",accessibilityDescription:nil); emptyProject.contentTintColor = AgentWorkbenchTheme.secondaryText }
        composer.placeholder = hasMessages ? "添加要求…" : "描述任务…"
        let presentation = companion?.modePresentation.settings[task.organizationMode] ?? .defaults(task.organizationMode)
        projectButton.isHidden = !presentation.projectEntry; emptyProject.isHidden = !presentation.projectEntry
        executionLocation.isHidden = !presentation.inputEnvironment; gitButton.isHidden = !presentation.changeReview
        workbenchBadge.update(task)
        workbenchInspector.update(monitorContent); workbenchInspector.setPresentation(.fixed)
        updateFloatingMonitor(monitorContent, state: monitorState, show: chatting && monitorState.presentation == .floating && monitorState.visible)
        taskBack.isEnabled = sideTaskTabID == nil && taskNavigationIndex > 0; taskForward.isEnabled = sideTaskTabID == nil && taskNavigationIndex >= 0 && taskNavigationIndex + 1 < taskNavigation.count
        let modelName = (try? companion?.agentRuntime?.taskPreferences(task.id).model) ?? task.modelOverride ?? companion?.store.preferences.model ?? ""
        taskModel.title = modelName; taskModel.setAccessibilityLabel("模型：" + modelName)
        taskModel.isEnabled = task.kind != "hook" && !task.archived && companion?.agentRuntime?.isBusy(task.id) != true && task.pendingCalls.isEmpty
        taskModel.toolTip = taskModel.isEnabled ? "选择任务模型" : "请先停止执行或处理待确认操作"
        if let snapshot = task.contextSnapshot {
            taskContext.title = "\(Int((Double(snapshot.estimatedTokens) / Double(max(1, snapshot.limit)) * 100).rounded(.up)))%"; taskContext.imagePosition = .imageLeading
            taskContext.toolTip = "上次请求占用估算 · " + snapshot.model
        } else { taskContext.title = ""; taskContext.imagePosition = .imageOnly; taskContext.toolTip = "查看上下文估算与任务回顾" }
        taskContext.setAccessibilityLabel("上下文" + (taskContext.title.isEmpty ? "" : " " + taskContext.title))
        workbenchLower.isHidden = resumeButton.isHidden && modelCaption.isHidden
        let hasMCP = companion?.agentStore?.mcp.availableServers(workspace: task.workspace).contains { $0.enabled && (task.agent?.mcpServers.contains($0.id) ?? true) } == true
        taskMCPContext.isHidden = !hasMCP; taskMCPContext.isEnabled = !task.archived && !["hook", "wiki"].contains(task.kind ?? "")
        let preferred = entryLeading.fittingSize.width + entryTrailing.fittingSize.width + 18
        let available = width - sidebarWidth.constant - target - columnInset * 2 - 22
        entryToolbarHeight.constant = available < preferred ? 64 : 34
        updateWorkbenchVoice()
        lastInspectorTransitionDuration = AgentWorkbenchTheme.layout(in: window?.contentView, duration: 0.16, animated: animated && window?.inLiveResize != true) { self.inspectorWidth.constant = target; self.inspectorPreferredWidth.constant = target }
        if showWorkspace { taskWorkspace.setVisible(true) }
        let monitorVisible = showInspector || monitorPanel?.isVisible == true
        resultsButton.state = monitorVisible ? .on : .off; resultsButton.setAccessibilityLabel(monitorVisible ? "隐藏任务监控" : "显示任务监控"); resultsButton.toolTip = monitorVisible ? "隐藏任务监控" : "显示任务监控"
        (Array(messageRows.values) + Array(reasoningRows.values)).forEach { $0.fit(width: history.contentView.bounds.width - 40) }
        revealMessageSearch(keepingVisible: keepSearchHitVisible)
    }
    @objc private func toggleTaskInspector() {
        guard selectedTab == "chat", let id = agentTaskID else { return }
        var state = taskMonitorState(id)
        if state.presentation == .fixed, taskWorkspace.requested { taskWorkspace.hideForNavigation(); guard !taskWorkspace.requested else { return }; state.visible = true }
        else { state.visible = !(state.presentation == .fixed ? !workbenchInspector.isHidden : monitorPanel?.isVisible == true) }
        state.explicitVisibility = true; monitorStates[id] = state; inspectorRequested = state.visible; updateWorkbenchLayout(animated: true)
    }
    private func taskMonitorState(_ id: String) -> AgentTaskMonitor.DisplayState {
        if let state = monitorStates[id] { return state }
        let settings = companion?.taskMonitor.settings ?? .init(); if appliedMonitorSettings == nil { appliedMonitorSettings = settings }
        let state = AgentTaskMonitor.DisplayState(settings); monitorStates[id] = state; return state
    }
    func refreshTaskMonitorPreferences() {
        guard let settings = companion?.taskMonitor.settings else { return }
        for id in Array(monitorStates.keys) {
            guard var state = monitorStates[id] else { continue }
            if appliedMonitorSettings?.presentation != settings.presentation { state.presentation = settings.presentation }
            if !state.explicitVisibility { state.visible = settings.presentation == .fixed && settings.dockedDefaultVisible }
            monitorStates[id] = state
        }
        appliedMonitorSettings = settings; updateWorkbenchLayout()
    }
    private func makeMonitorContent(_ task: AgentTaskRecord) -> AgentMonitorContent {
        var value = AgentMonitorContent(task: task)
        guard let companion, let store = companion.agentStore else { return value }
        value.settings = companion.taskMonitor.settings
        value.canAddSources = task.canAddSources
        if let files = try? AgentFiles(workspace: task.workspace) {
            for path in task.artifacts.prefix(8) {
                if let url = try? files.resolve(path), let entry = try? files.entryMetadata(url), entry.kind == "missing" { value.missingArtifacts.insert(path) }
            }
        }
        let presentation = companion.modePresentation.settings[task.organizationMode]
        value.showChanges = presentation.changeReview
        value.children = store.tasks.filter { $0.agent?.ownerID == task.id && !$0.archived }.sorted { $0.updated > $1.updated }
        value.sideChats = store.sideTasks.children(of: task.id) + store.tasks.filter { $0.parentID == task.id && $0.branchMessageID != nil && $0.sideTask == nil && !$0.archived }
        value.terminals = terminalPanel?.monitorEntries(taskID: task.id) ?? []
        value.pages = store.browser.sessions[task.id]?.monitorEntries ?? []
        if presentation.inputEnvironment, let workspace = task.workspace { value.environment = [store.organization.name(task.organizationWorkspace, mode: task.organizationMode), workspace].compactMap { $0 } }
        value.canAnalyze = companion.agentRuntime?.isBusy(task.id) == false && !task.archived && task.kind != "hook" && task.pendingCalls.isEmpty && task.status != .waiting && task.messages.contains(where: \.isHumanInput)
        value.analysis = companion.agentRuntime?.analysisTitle(task.id); value.analysisError = companion.agentRuntime?.analysisError(task.id, recap: true)
        if let service = companion.agentRuntime?.skillEvolution {
            value.skillSuggestions = service.items(task).filter { $0.state != .dismissed }; value.skillSource = AgentSkillEvolution.source(task)
            value.skillGenerating = service.isGenerating(task.id); value.skillError = service.error(task)
            value.skillAnalyzed = AgentSkillEvolution.reply(task)?.skillEvolution?.source == value.skillSource && value.skillSource != nil
            value.canGenerateSkills = companion.generalSettings.settings.skillEvolutionSuggestions && value.skillSource != nil && companion.agentRuntime?.isBusy(task.id) == false && task.modelReceipts?.contains(where: { $0.purpose == "conversation" && $0.completed && $0.messageID == AgentSkillEvolution.reply(task)?.id }) == true
        }
        switch taskWorkspace.selectedRoot {
        case .canvas(let id) where (task.canvases ?? []).contains(where: { $0.id == id }): value.previewTitle = "画布"; value.previewVisible = taskWorkspace.requested
        default: if store.browser.sessions[task.id]?.monitorAvailable == true { value.previewTitle = "浏览器"; value.previewVisible = taskWorkspace.requested && taskWorkspace.selectedRoot == .browser }
        }
        return value
    }
    private func configureTaskMonitor(_ view: AgentTaskInspector) {
        view.onOpen = { [weak self] section, value in
            guard let self else { return }; if value.hasPrefix("canvas://"), let id = agentTaskID { openCanvasReference(value, taskID: id) } else { openAgentRecordItem(section: section, value: value) }
        }
        view.onOpenIn = { [weak self] section, value, location in self?.openAgentRecordItem(section: section, value: value, location: location) }
        view.onShowAll = { [weak self] section in self?.presentAgentRecords(section: section) }
        view.onOpenTerminal = { [weak self] in self?.openTaskTerminal() }
        view.onTerminal = { [weak self] entry in guard let self, let id = agentTaskID else { return }; do { try terminalPanel?.openMonitorEntry(entry, taskID: id); updateTerminalDock() } catch { setStatus(error.localizedDescription, error: true) } }
        view.onSideTask = { [weak self] id in
            guard let self, let task = companion?.agentStore?.task(id) else { return }
            if task.sideTask != nil { companion?.openSideTask(id, from: self) } else { selectAgentTask(id) }
        }
        view.onPage = { [weak self] id in guard let self, let taskID = agentTaskID else { return }; do { guard let browser = companion?.agentStore?.browser.sessions[taskID] else { throw PetError("此任务的浏览器已关闭") }; guard browser.prepareWorkspaceNavigation() else { return }; _ = try browser.manageTabs(["action": "switch", "tab_id": id]); showAgentBrowser() } catch { setStatus(error.localizedDescription, error: true) } }
        view.onContext = { [weak self] section in self?.presentTaskContext(section: section) }
        view.onRecap = { [weak self] in guard let self, let id = agentTaskID else { return }; _ = companion?.agentRuntime?.analyze(id, recap: true, model: companion?.taskMonitor.settings.recapModel) }
        view.onSettings = { [weak self] in _ = self?.showSettingsCategory("monitor") }
        view.onMemory = { [weak self] in self?.openAgentMemory() }
        view.onPreview = { [weak self] in self?.toggleMonitorPreview() }
        view.onClose = { [weak self] in self?.closeTaskMonitor() }
        view.onPresentation = { [weak self] in self?.pinTaskMonitor() }
        view.onAddSource = { [weak self] sender in self?.showSourceMenu(sender) }
        view.onSkillCurate = { [weak self] ids,source,adopt in
            guard let self, let id = agentTaskID, let service = companion?.agentRuntime?.skillEvolution else { return }
            do { let created = try service.curate(ids,taskID:id,source:source,adopt:adopt); if let first = created.first { selectAgentTask(first) } else { renderAgentMessages() } }
            catch { setStatus(error.localizedDescription,error:true) }
        }
        view.onSkillTask = { [weak self, weak view] id in guard let self, let owner = view?.boundTaskID, agentTaskID == owner, companion?.agentStore?.tasks.contains(where: { $0.id == id && $0.skillEvolutionJob?.sourceTaskID == owner }) == true else { return }; selectAgentTask(id) }
        view.onSkillRetry = { [weak self, weak view] in guard let self, agentTaskID == view?.boundTaskID, let id = agentTaskID else { return }; companion?.agentRuntime?.retrySkillEvolution(id) }
        view.onSkillSource = { [weak self, weak view] in
            guard let self, let id = agentTaskID, view?.boundTaskID == id, let task = companion?.agentStore?.task(id), let source = AgentSkillEvolution.source(task) else { return }
            do { try presentSkillSources(taskID:id,source:source) } catch { setStatus(error.localizedDescription,error:true) }
        }
    }
    private func showSourceMenu(_ sender: NSButton) {
        guard let task = currentAgentTask, task.canAddSources else { return }
        let menu = NSMenu()
        for (title, kind) in [("添加文件", "file"), ("添加链接", "link")] {
            let item = NSMenuItem(title: title, action: #selector(sourceMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = ["task": task.id, "kind": kind]; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func sourceMenuAction(_ item: NSMenuItem) {
        guard let value = item.representedObject as? [String: String], let id = value["task"], agentTaskID == id, currentAgentTask?.canAddSources == true else { return }
        if value["kind"] == "file" { addAttachments() }
        else { presentSourceLink(id) }
    }
    private func presentSourceLink(_ id: String) {
        guard let window, agentTaskID == id, currentAgentTask?.canAddSources == true, nameEditor == nil, window.attachedSheet == nil, saveAgentDraft() else { return }
        nameEditor = AgentNameEditor(title: "添加链接", label: "链接地址", value: "", actionTitle: "添加", note: "HTTP／HTTPS 链接会加入草稿，发送后显示为来源。", statusLabel: "链接状态", save: { [weak self] text in
            guard let self else { throw PetError("任务窗口已关闭") }; try appendSourceLink(text, taskID: id)
        }, onClose: { [weak self] in
            guard let self else { return }; nameEditor = nil; renderMessages()
            self.window?.contentView?.layoutSubtreeIfNeeded(); composer.scrollRangeToVisible(composer.selectedRange())
        })
        nameEditor?.begin(in: window); updateWorkbenchLayout()
    }
    func appendSourceLink(_ text: String, taskID: String) throws {
        let link = try AgentSourceLinks.url(text).absoluteString
        guard agentTaskID == taskID, currentAgentTask?.canAddSources == true, composer.isEditable else { throw PetError("请回到可以编辑的原任务后添加链接") }
        guard saveAgentDraft(), companion?.persistTaskDrafts(taskID) != false else { throw PetError("请先保存当前草稿") }
        if !AgentSourceLinks.inText(composer.string).contains(link) {
            let addition = (composer.string.isEmpty ? "" : "\n\n") + link
            guard (composer.string + addition).utf8.count <= 100_000 else { throw PetError("草稿超过 100KB，请先缩减草稿") }
            composer.insertText(addition, replacementRange: NSRange(location: (composer.string as NSString).length, length: 0)); composer.didChangeText()
        }
        guard saveAgentDraft() else { throw PetError("链接已加入草稿，但尚未保存；请恢复写入后重试") }
        renderMessages()
        let end = NSRange(location: (composer.string as NSString).length, length: 0)
        composer.setSelectedRange(end); composer.scrollRangeToVisible(end)
    }
    private func closeTaskMonitor() {
        guard let id = agentTaskID else { return }; var state = taskMonitorState(id); state.visible = false; state.explicitVisibility = true; monitorStates[id] = state; inspectorRequested = false; updateWorkbenchLayout(animated: true)
    }
    private func pinTaskMonitor() {
        guard let id = agentTaskID else { return }; var state = taskMonitorState(id)
        if state.presentation == .floating, taskWorkspace.requested { taskWorkspace.hideForNavigation(); guard !taskWorkspace.requested else { return } }
        state.presentation = state.presentation == .fixed ? .floating : .fixed; state.visible = true; state.explicitVisibility = true; monitorStates[id] = state; updateWorkbenchLayout(animated: true)
    }
    private func toggleMonitorPreview() {
        if taskWorkspace.requested, taskWorkspace.selectedRoot == .browser || { if case .canvas = taskWorkspace.selectedRoot { return true }; return false }() { taskWorkspace.hideForNavigation(); updateWorkbenchLayout(); return }
        if let id = agentTaskID, companion?.agentStore?.browser.sessions[id] != nil { showAgentBrowser() }
        else if case .canvas(let canvas) = taskWorkspace.selectedRoot, let id = agentTaskID { openCanvasReference("canvas://" + canvas, taskID: id, location: .workspace) }
    }
    private func updateFloatingMonitor(_ content: AgentMonitorContent, state: AgentTaskMonitor.DisplayState, show: Bool) {
        guard show, let owner = window, owner.isVisible, !owner.isMiniaturized, owner.attachedSheet == nil else { monitorPanel?.orderOut(nil); return }
        if monitorPanel == nil {
            let panel = AgentTaskMonitorPanel(); configureTaskMonitor(panel.inspector)
            panel.onDismiss = { [weak self] in self?.closeTaskMonitor() }
            panel.onFrame = { [weak self] frame in guard let self, let id = monitorPanelTaskID, var value = monitorStates[id] else { return }; value.frame = frame; monitorStates[id] = value }
            monitorPanel = panel
        }
        guard let panel = monitorPanel else { return }
        if monitorPanelTaskID != content.task.id {
            monitorPanelTaskID = content.task.id
            let screen = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? owner.frame
            var frame = state.frame ?? NSRect(x: owner.frame.maxX - 360, y: owner.frame.maxY - min(620, owner.frame.height), width: 340, height: min(560, screen.height - 60))
            frame.size.width = min(frame.width, screen.width); frame.size.height = min(frame.height, screen.height)
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width); frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height); panel.setFrame(frame, display: false)
        }
        panel.title = "任务监控 · " + content.task.title.replacingOccurrences(of: "\n", with: " "); AgentThemeContext.inherit(panel, from: owner)
        panel.inspector.canOpenTerminal = terminalButton.isEnabled; panel.inspector.update(content)
        if panel.parent !== owner { panel.parent?.removeChildWindow(panel); owner.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
    func taskMonitorReadback() -> [String: Any] {
        guard ["--task-monitor-check", "--manual-ui"].contains(where: CommandLine.arguments.contains), let id = agentTaskID else { return [:] }
        let state = taskMonitorState(id)
        return ["taskID": id, "presentation": state.presentation.rawValue, "requested": state.visible, "dockedVisible": !workbenchInspector.isHidden, "floatingVisible": monitorPanel?.isVisible == true, "applicationActive": NSApp.isActive, "floatingOnScreen": monitorPanel?.occlusionState.contains(.visible) == true, "floatingKey": monitorPanel?.isKeyWindow == true, "floatingMovable": monitorPanel?.isMovable == true, "floatingBackgroundMovable": monitorPanel?.isMovableByWindowBackground == true, "floatingOwner": monitorPanel?.parent?.windowNumber ?? -1, "ownerNumber": window?.windowNumber ?? -1, "floatingTaskID": monitorPanelTaskID ?? "", "floatingFrame": monitorPanel.map { NSStringFromRect($0.frame) } ?? "", "windowSize": window.map { [$0.frame.width, $0.frame.height] } ?? [], "fixed": workbenchInspector.readback(), "floating": monitorPanel?.inspector.readback() ?? [:], "taskStates": monitorStates.mapValues { ["presentation": $0.presentation.rawValue, "visible": $0.visible, "frame": $0.frame.map(NSStringFromRect) ?? ""] as [String: Any] }]
    }
    func checkTaskMonitor(_ action: String, frame: NSRect? = nil) {
        guard ["--task-monitor-check", "--browser-workspace-check"].contains(where: CommandLine.arguments.contains) else { return }
        switch action { case "toggle": toggleTaskInspector(); case "pin": pinTaskMonitor(); case "close": closeTaskMonitor(); case "frame": if let frame { monitorPanel?.setFrame(frame, display: false) }; case "terminal": openTaskTerminal(); case "stop-terminals": stopTaskTerminals(); case "source-link": if let id = agentTaskID { presentSourceLink(id) }; default: break }
    }
    @objc private func toggleLeftSidebar() {
        guard selectedTab == "chat" else { return }
        if sidebarRequested { window?.makeFirstResponder(composer) }
        sidebarRequested.toggle(); updateWorkbenchLayout(); refreshShortcutControls()
    }
    private func showTaskSwitcher() {
        guard let tasks = companion?.agentStore, let window, taskSwitcher == nil, saveAgentDraft() else { return }
        show(tab: "chat")
        taskSwitcher = AgentTaskSwitcher(store: tasks, selected: agentTaskID, onSelect: { [weak self] id in self?.selectAgentTask(id) }, onClose: { [weak self] in self?.taskSwitcher = nil })
        taskSwitcher?.begin(in: window)
    }
    private func taskFindSources(_ task: AgentTaskRecord) -> [AgentTaskFind.Source] {
        task.messages.compactMap { message in
            guard !message.content.isEmpty, ["user", "assistant"].contains(message.role), message.nativeContext != true, let row = messageRows[message.id] else { return nil }
            return AgentTaskFind.Source(messageID: message.id, text: row.label.stringValue)
        }
    }
    private func showTaskFind() {
        guard let task = currentAgentTask else { return }
        if taskFind.isHidden { taskSidebar.dismissSearch(); clearMessageSearchHighlight(); renderAgentMessages() }
        taskFind.open(taskID: task.id, sources: taskFindSources(task))
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    func refreshShortcutControls() {
        guard let shortcuts = companion?.shortcuts else { return }
        taskSidebar.refreshShortcuts(shortcuts); shortcutSettings?.refresh()
        for (button, command) in [(taskBack, AgentShortcutCommand.previousTask), (taskForward, .nextTask)] {
            let value = shortcuts.binding(command); button.toolTip = command.title + (value == .cleared ? "" : " · " + value.display)
        }
        let value = shortcuts.binding(.leftSidebar)
        sidebarToggle.toolTip = (sidebarRequested ? "收起左侧栏" : "显示左侧栏") + (value == .cleared ? "" : " · " + value.display)
    }
    func canPerformShortcut(_ command: AgentShortcutCommand) -> Bool {
        guard companion?.usesAgent == true, window?.attachedSheet == nil else { return false }
        switch command {
        case .settings: return true
        case .newTask, .searchTasks: return true
        case .switchTask: return currentAgentTask != nil
        case .leftSidebar: return selectedTab == "chat"
        case .findInTask: return selectedTab == "chat" && currentAgentTask != nil
        case .newWindow: return currentAgentTask != nil
        case .previousTask: return selectedTab == "chat" && sideTaskTabID == nil && taskNavigationIndex > 0
        case .nextTask: return selectedTab == "chat" && sideTaskTabID == nil && taskNavigationIndex >= 0 && taskNavigationIndex + 1 < taskNavigation.count
        case .taskInspector: return selectedTab == "chat" && currentAgentTask != nil
        case .planMode: return selectedTab == "chat" && currentAgentTask != nil && window?.firstResponder === composer && modePopup.isEnabled && currentAgentTask?.automation == nil && currentAgentTask?.status != .running && currentAgentTask?.status != .waiting
        }
    }
    func performShortcut(_ command: AgentShortcutCommand) {
        guard canPerformShortcut(command) else { return }
        switch command {
        case .settings: show(tab: "settings")
        case .newTask: newAgentTask()
        case .searchTasks: taskFind.reset(); clearMessageSearchHighlight(); sidebarRequested = true; show(tab: "chat"); refreshShortcutControls(); taskSidebar.focusSearch()
        case .findInTask: showTaskFind()
        case .switchTask: showTaskSwitcher()
        case .leftSidebar: toggleLeftSidebar()
        case .previousTask: previousAgentTask()
        case .nextTask: nextAgentTask()
        case .taskInspector: toggleTaskInspector()
        case .newWindow: if let id = agentTaskID { companion?.openTaskWindow(id, from: self) }
        case .planMode:
            let mode: AgentMode = currentAgentTask?.mode == .plan ? .agent : .plan
            modePopup.selectItem(at: AgentMode.allCases.firstIndex(of: mode)!); agentOptionsChanged()
        }
    }
    @objc private func previousAgentTask() {
        guard taskNavigationIndex > 0 else { return }; taskNavigationIndex -= 1; navigatingTaskHistory = true; defer { navigatingTaskHistory = false }; selectAgentTask(taskNavigation[taskNavigationIndex])
    }
    @objc private func nextAgentTask() {
        guard taskNavigationIndex + 1 < taskNavigation.count else { return }; taskNavigationIndex += 1; navigatingTaskHistory = true; defer { navigatingTaskHistory = false }; selectAgentTask(taskNavigation[taskNavigationIndex])
    }
    @objc private func showTaskMenu(_ sender: NSButton) {
        guard let task = currentAgentTask else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, action) in [("重命名", "rename"), (task.pinned ? "取消置顶" : "置顶", "pin"), ("创建分支", "fork"), (task.archived ? "恢复任务" : "归档任务", "archive")] {
            let item = NSMenuItem(title: title, action: #selector(taskMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, action]; item.isEnabled = task.status != .running && (task.pendingFileRollback == nil || !["fork", "archive"].contains(action)); menu.addItem(item)
        }
        if task.pendingFileRollback != nil { let item = NSMenuItem(title: "恢复撤回前文件…", action: #selector(taskMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, "recover-round-files"]; menu.addItem(item) }
        if AgentSideTasks.supported(task) { let item = NSMenuItem(title: "开始侧任务", action: #selector(taskMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, "side-task"]; item.isEnabled = companion?.agentStore?.sideTasks.cleaning != true; menu.addItem(item) }
        if let side = task.sideTask {
            for (title, action) in [("返回主任务", "side-parent"), ("保留为独立任务", "side-keep")] { let item = NSMenuItem(title: title, action: #selector(taskMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, action]; item.isEnabled = action != "side-parent" || companion?.agentStore?.tasks.contains(where: { $0.id == side.parentID }) == true; menu.addItem(item) }
        }
        if task.agent?.ownerID == nil, task.automation == nil, task.kind != "hook", !task.isProjectDocumentation {
            let item = NSMenuItem(title: task.organizationMode == .coding ? "移至通用" : "移至编程", action: #selector(taskMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, "work-mode"]; item.isEnabled = ![.running, .waiting].contains(task.status); menu.addItem(item)
        }
        if task.importOrigin != nil { let item = NSMenuItem(title: "导入来源…", action: #selector(taskMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, "import-source"]; menu.addItem(item) }
        let unread = companion?.agentStore?.organization.isTaskUnread(task.id) == true, read = NSMenuItem(title: unread ? "标记已读" : "标记未读", action: #selector(taskMenuAction(_:)), keyEquivalent: "")
        read.target = self; read.representedObject = [task.id, unread ? "read" : "unread"]; menu.addItem(read)
        let newWindow = NSMenuItem(title: "在新窗口打开", action: #selector(taskMenuAction(_:)), keyEquivalent: ""); newWindow.target = self; newWindow.representedObject = [task.id, "new-window"]; menu.addItem(newWindow)
        menu.addItem(.separator())
        let records = NSMenuItem(title: "完整任务记录", action: #selector(showAgentRecords), keyEquivalent: ""); records.target = self; menu.addItem(records)
        let recap = NSMenuItem(title: "任务回顾", action: #selector(showTaskRecap), keyEquivalent: ""); recap.target = self; menu.addItem(recap)
        let export = NSMenuItem(title: "导出历史", action: nil, keyEquivalent: ""), formats = NSMenu(); formats.autoenablesItems = false
        for format in AgentTaskExport.Format.allCases { let item = NSMenuItem(title: format.title, action: #selector(taskMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, "export:" + format.rawValue]; formats.addItem(item) }; export.submenu = formats; menu.addItem(export)
        let copyID = NSMenuItem(title: "复制任务编号", action: #selector(taskMenuAction(_:)), keyEquivalent: ""); copyID.target = self; copyID.representedObject = [task.id, "copy-id"]; menu.addItem(copyID)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "永久删除…", action: #selector(taskMenuAction(_:)), keyEquivalent: ""); remove.target = self; remove.representedObject = [task.id, "delete"]; remove.isEnabled = task.status != .running; menu.addItem(remove)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func taskMenuAction(_ sender: NSMenuItem) { if let value = sender.representedObject as? [String], value.count == 2 { agentTaskAction(value[0], action: value[1]) } }
    @objc private func showTaskModelMenu(_ sender: NSButton) {
        guard let runtime = companion?.agentRuntime, let id = agentTaskID else { return }
        taskModelWindow?.window?.performClose(nil); taskModelWindow = AgentTaskModelWindow(runtime: runtime, taskID: id)
        taskModelWindow?.showWindow(nil); taskModelWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showTaskContext() { presentTaskContext(section: 0) }
    @objc private func showTaskRecap() { presentTaskContext(section: 1) }
    internal func presentTaskContext(section: Int) {
        guard let runtime = companion?.agentRuntime, let id = agentTaskID, saveAgentDraft() else { return }
        if selectedTab != "chat" { guard canLeaveMainPage() else { return }; show(tab: "chat") }
        guard taskWorkspace.show(taskID: id, root: .context, make: { let page = AgentContextWindow(runtime: runtime, taskID: id, section: section); page.recapModel = { [weak self] in self?.companion?.taskMonitor.settings.recapModel }; return page }) else { return }
        (taskWorkspace.rootController(.context) as? AgentContextWindow)?.selectSection(section)
        updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    @objc private func showTaskMCPContent() { if let id = agentTaskID { presentMCPContent(taskID: id) } }
    func presentMCPContent(taskID: String, serverID: String? = nil) {
        guard let store = companion?.agentStore, store.task(taskID) != nil else { return }
        if agentTaskID != taskID { selectAgentTask(taskID) }
        guard agentTaskID == taskID, saveAgentDraft() else { return }
        if selectedTab != "chat" { guard canLeaveMainPage() else { return }; show(tab: "chat") }
        guard taskWorkspace.show(taskID: taskID, root: .mcpContent, make: { AgentMCPContentWindow(store: store, taskID: taskID, serverID: serverID) { [weak self] text, ids in
            guard let self, companion?.persistTaskDrafts(taskID) != false else { throw PetError("请先保存此任务的草稿") }
            guard let previous = store.task(taskID), !previous.archived, !["wiki", "hook"].contains(previous.kind ?? "") else { throw PetError("任务已关闭，未加入草稿") }
            let visible = agentTaskID == taskID && self.displayedTask == taskID
            let draft = visible ? self.composer.string : previous.draft ?? ""
            let combined = draft + (text.isEmpty ? "" : (draft.isEmpty ? "" : "\n\n") + text)
            guard combined.utf8.count <= 100_000, (previous.draftAttachmentIDs?.count ?? 0) + ids.count <= 6,
                  ids.allSatisfy({ id in previous.attachments?.contains(where: { $0.id == id }) == true }) else { throw PetError("草稿超过 100KB 或附件超过 6 份，请先缩减草稿") }
            store.update(taskID, persist: false) { record in record.draft = combined.isEmpty ? nil : combined; if !ids.isEmpty { if record.draftAttachmentIDs == nil { record.draftAttachmentIDs = [] }; record.draftAttachmentIDs?.append(contentsOf: ids) } }
            do { try store.save(taskID) }
            catch { store.update(taskID, persist: false) { $0.draft = previous.draft; $0.draftAttachmentIDs = previous.draftAttachmentIDs }; throw error }
            if visible { self.composer.string = combined; self.composer.didChangeText() }; self.renderMessages()
        } }) else { return }
        if let serverID { (taskWorkspace.rootController(.mcpContent) as? AgentMCPContentWindow)?.selectRequestedServer(serverID) }
        updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
        (taskWorkspace.rootController(.mcpContent) as? AgentMCPContentWindow)?.settingsDidAppear()
    }
    @objc private func openTaskModelSettings() { saveAgentDraft(); showSettingsCategory("model") }
    @objc private func toggleWorkbenchVoice() { if companion?.store.preferences.wakeEnabled == true { companion?.stopRecording() } else { companion?.listenNow() } }
    private func updateWorkbenchVoice() {
        guard companion?.usesAgent == true else { return }
        let enabled = companion?.store.preferences.wakeEnabled == true
        voiceInput.image = NSImage(systemSymbolName: enabled ? "stop.circle" : "mic", accessibilityDescription: nil)
        voiceInput.contentTintColor = enabled ? .systemRed : AgentWorkbenchTheme.secondaryText; voiceInput.toolTip = enabled ? "停止录音" : "语音输入"; voiceInput.setAccessibilityLabel(voiceInput.toolTip)
    }
    func showAttentionPreferences() { showSettingsCategory("attention") }
    func showAttentionPage() {
        guard saveAgentDraft(), canLeaveMainPage() else { return }
        companion?.ensureAgent()
        guard let tasks = companion?.agentStore, let runtime = companion?.agentRuntime, let host = window else { return }
        if attentionPageController == nil {
            let page = AgentAttentionWindow(attention: tasks.attention, runtime: runtime)
            page.onOpenTask = { [weak self] id in self?.showAgentTask(id); self?.show(tab: "chat") }
            page.onOpenSettings = { [weak self] in self?.showAttentionPreferences() }
            guard let view = page.content(in: host) else { return }
            attentionContent.addSubview(view); pin(view, to: attentionContent)
            attentionPageController = page
        }
        sidebarRequested = true
        show(tab: "attention"); tasks.attention.refresh(); attentionPageController?.refresh()
    }
    private func canLeaveMainPage() -> Bool {
        guard taskWorkspace.prepareToNavigate() else { return false }
        guard attentionPageController?.prepareToClose() != false else { return false }
        if selectedTab == "automation", automationWindow?.prepareToLeave() == false { return false }
        if selectedTab == "knowledge", !knowledgePageHost.prepareToLeave() { return false }
        return settingsPageHost.leave()
    }
    @discardableResult internal func showSettingsCategory(_ key: String) -> Bool {
        guard settingsCategories.contains(where: { $0.0 == key }), canLeaveMainPage() else { return false }
        companion?.ensureAgent(); settingsCategory = key; settingsSearch.stringValue = ""
        show(tab: "settings"); return true
    }
    @objc private func openManagedSettingsResult(_ sender: NSButton) {
        guard settingsCategories.indices.contains(sender.tag), showSettingsCategory(settingsCategories[sender.tag].0), let key = sender.identifier?.rawValue else { return }
        settingsPageHost.selectPage(key)
    }
    private func makeSettingsManager(_ key: String, taskID: String?, workspace: String?, selection: String? = nil) -> AgentSettingsPageController? {
        guard let store = companion?.agentStore else { return nil }
        let mode = taskID.flatMap(store.task)?.organizationMode
        let use: (String) -> Void = { [weak self] id in self?.selectAgentTask(id); self?.show(tab: "chat") }
        switch key {
        case "plugins":
            let manager = AgentPluginWindow(store: store, workspace: workspace)
            if let taskID {
                manager.onInsert = { [weak self] in try self?.insertExtension($0, taskID: taskID) }
                manager.onInsertRule = { [weak self] in try self?.insertRule($0, taskID: taskID) }
            }
            manager.onConfigureMCP = { [weak self, weak manager] id, scope in
                if let child = self?.makeSettingsManager("mcp", taskID: taskID, workspace: scope, selection: id) { manager?.presentSettingsChild(child) }
            }
            manager.onConfigureAgent = { [weak self, weak manager] id, scope in
                if let child = self?.makeSettingsManager("agents", taskID: taskID, workspace: scope, selection: id) { manager?.presentSettingsChild(child) }
            }
            manager.onConfigureHook = { [weak self, weak manager] id, scope in
                if let child = self?.makeSettingsManager("hooks", taskID: taskID, workspace: scope, selection: id) { manager?.presentSettingsChild(child) }
            }
            return manager
        case "skills", "commands":
            let manager = AgentExtensionWindow(store: store, taskID: taskID ?? "", managementWorkspace: workspace)
            manager.prepareSettings(kind: key == "commands" ? .command : .skill); manager.onStartAgent = use
            if let taskID {
                manager.onInsert = { [weak self] in try self?.insertExtension($0, taskID: taskID) }
                manager.onInsertRule = { [weak self] in try self?.insertRule($0, taskID: taskID) }
                manager.onInsertLocalRule = { [weak self] in try self?.insertLocalRule($0, taskID: taskID) }
                manager.onBrowseMCP = { [weak self] in self?.presentMCPContent(taskID: taskID, serverID: $0) }
            }
            return manager
        case "mcp":
            let manager = AgentMCPWindow(service: store.mcp, workspace: workspace)
            if let taskID { manager.onBrowseContent = { [weak self] in self?.presentMCPContent(taskID: taskID, serverID: $0) } }
            if let selection { manager.selectServer(selection) }; return manager
        case "hooks":
            let manager = AgentHookWindow(service: store.hooks, workspace: workspace)
            if let selection { manager.selectHook(selection) }; return manager
        case "agents":
            let manager = AgentProfileWindow(store: store, workspace: workspace, workMode: mode); manager.onUse = use
            if let selection { manager.selectProfile(selection) }; return manager
        case "teams":
            let manager = AgentTeamWindow(store: store, workspace: workspace, workMode: mode); manager.onUse = use; return manager
        case "worktrees":
            let manager = AgentWorktreeSettingsWindow(store: store) { [weak self] id in
                guard let self, self.canLeaveMainPage() else { return }; self.showAgentTask(id); self.show(tab: "chat")
            }
            worktreePolicyPanel = manager.policy; return manager
        case "memory":
            guard let taskID else { return nil }
            return AgentRecordWindow(store: store, taskID: taskID, section: 5, memoryOnly: true, memoryWorkspace: workspace)
        case "rules":
            guard let taskID else { return nil }
            let manager = AgentRuleWindow(store: store, taskID: taskID, managementWorkspace: workspace)
            manager.onInsert = { [weak self] in try self?.insertLocalRule($0, taskID: taskID) }; return manager
        default: return nil
        }
    }
    private func buildSettingsSidebar(in content: NSView) {
        content.addSubview(settingsSidebar); settingsSidebar.translatesAutoresizingMaskIntoConstraints = false
        settingsSidebarWidth = settingsSidebar.widthAnchor.constraint(equalToConstant: companion?.usesAgent == true ? 231 : 200)
        NSLayoutConstraint.activate([settingsSidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), settingsSidebarWidth, settingsSidebar.topAnchor.constraint(equalTo: content.topAnchor), settingsSidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let back = NSButton(title: "返回对话", target: self, action: #selector(returnToChat))
        settingsBackButton = back
        back.isBordered = false; back.alignment = .left; back.font = .systemFont(ofSize: 13)
        back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil); back.imagePosition = .imageLeading
        back.contentTintColor = AgentWorkbenchTheme.secondaryText
        settingsSearch.placeholderString = "搜索设置…"; settingsSearch.setAccessibilityLabel("搜索设置"); settingsSearch.delegate = self
        var previousGroup = ""
        let navigation = stack([], vertical: true, spacing: 0)
        for (index, item) in settingsCategories.enumerated() {
            let group = ["extensions", "agents", "teams", "hooks", "computer"].contains(item.0) ? "集成" : item.0 == "worktrees" ? "编码" : ["experiments", "archived"].contains(item.0) ? "其他" : "个人"
            if group != previousGroup {
                if let previous = navigation.arrangedSubviews.last { navigation.setCustomSpacing(12, after: previous) }
                let label = NSTextField(labelWithString: group); label.font = .systemFont(ofSize: 11); label.textColor = AgentWorkbenchTheme.secondaryText
                navigation.addArrangedSubview(label); navigation.setCustomSpacing(4, after: label); previousGroup = group
            }
            let button = NSButton(title: item.1, target: self, action: #selector(selectSettingsCategory(_:)))
            button.tag = index; styleNavigation(button, symbol: item.2, compact: true); navigation.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true; categoryButtons.append(button)
        }
        let fixed = stack([back, settingsSearch], vertical: true, spacing: 18)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document; document.addSubview(navigation)
        settingsSidebar.addSubview(fixed); settingsSidebar.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("设置分类")
        NSLayoutConstraint.activate([fixed.topAnchor.constraint(equalTo: settingsSidebar.topAnchor, constant: 58), fixed.leadingAnchor.constraint(equalTo: settingsSidebar.leadingAnchor, constant: 16), fixed.trailingAnchor.constraint(equalTo: settingsSidebar.trailingAnchor, constant: -16), settingsSearch.widthAnchor.constraint(equalTo: fixed.widthAnchor), settingsSearch.heightAnchor.constraint(equalToConstant: 28), scroll.topAnchor.constraint(equalTo: fixed.bottomAnchor, constant: 18), scroll.leadingAnchor.constraint(equalTo: settingsSidebar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: settingsSidebar.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: settingsSidebar.bottomAnchor, constant: -12), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), navigation.topAnchor.constraint(equalTo: document.topAnchor), navigation.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16), navigation.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16), navigation.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)])
    }
    @objc private func returnToChat() { companion?.screenCompanion.interaction(); show(tab: settingsReturnTab) }
    @objc private func selectSettingsCategory(_ sender: NSButton) {
        guard settingsPageHost.leave() else { return }
        window?.makeFirstResponder(sender); settingsCategory = settingsCategories[sender.tag].0
        settingsSearch.stringValue = ""; updateSettingsSections()
    }
    private func updateSettingsSections() {
        archivedTasksView?.refresh()
        let query = settingsSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selected = settingsCategories.first { $0.0 == settingsCategory } ?? settingsCategories[0]
        settingsHeading.stringValue = query.isEmpty ? selected.1 : "搜索结果"
        pageTitle.stringValue = settingsHeading.stringValue
        for (index, button) in categoryButtons.enumerated() {
            let active = query.isEmpty && settingsCategories[index].0 == settingsCategory
            button.state = active ? .on : .off; AgentWorkbenchTheme.color(button.layer, active ? AgentWorkbenchTheme.navigationSelection : .clear, animated: false)
        }
        let matches = settingGroups.filter { query.isEmpty ? $0.category == settingsCategory : ($0.title + " " + $0.keywords).lowercased().contains(query) }
        let managed = query.isEmpty && managedSettings.contains(settingsCategory)
        settingsFooter?.isHidden = managed
        settingsPageHost.isHidden = !managed; settingsScroll.isHidden = managed
        if managed {
            generalSettingsSave?.isHidden = true
            let id = agentTaskID ?? companion?.agentStore?.selectedID
            let task = id.flatMap { companion?.agentStore?.task($0) }
            let folders = settingsCategory == "worktrees" ? [] : task?.workspacePaths ?? []
            let remembered = id.flatMap { settingsSourceFolders[$0] }
            let workspace = remembered.flatMap { folders.contains($0) ? $0 : nil } ?? task?.workspace
            let identity = ([id ?? "", workspace ?? "", task?.organizationWorkspace ?? ""] + folders).joined(separator: "\0")
            guard settingsPageHost.show(category: settingsCategory, identity: identity, scope: settingsCategory == "worktrees" ? "所有项目" : workspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "用户设置", make: { [weak self] kind in
                self?.makeSettingsManager(kind, taskID: id, workspace: workspace)
            }) else { return }
            settingsPageHost.setSourceFolders(folders, selected: workspace, primary: task?.workspace) { [weak self] path in
                guard let self, let id, (agentTaskID ?? companion?.agentStore?.selectedID) == id,
                      companion?.agentStore?.task(id)?.workspacePaths == folders, folders.contains(path) else { return false }
                let page = settingsPageHost.selectedPageKey
                guard settingsPageHost.leave() else { return false }
                settingsSourceFolders[id] = path; updateSettingsSections()
                if let page { settingsPageHost.selectPage(page) }; return true
            }
            return
        }
        generalSettingsSave?.isHidden = matches.isEmpty || matches.allSatisfy { ["general", "appearance", "modes", "monitor", "shortcuts", "worktrees", "computer", "imports", "experiments", "archived", "attention"].contains($0.category) }
        settingsFooter?.isHidden = generalSettingsSave?.isHidden == true
        settingsForm.arrangedSubviews.forEach { settingsForm.removeArrangedSubview($0); $0.removeFromSuperview() }
        for group in matches {
            (group.view as? NSStackView)?.arrangedSubviews.first?.isHidden = query.isEmpty && group.title == selected.1
            settingsForm.addArrangedSubview(group.view); group.view.widthAnchor.constraint(equalTo: settingsForm.widthAnchor).isActive = true
        }
        if matches.isEmpty { settingsForm.addArrangedSubview(noSettings) }
        if matches.contains(where: { $0.category == "general" }) { generalSettingsPanel?.matchSearch(query) }
        settingsScroll.contentView.scroll(to: .zero); settingsScroll.reflectScrolledClipView(settingsScroll.contentView)
    }
    private func buildChat() {
        history.hasVerticalScroller = true; history.drawsBackground = false; history.scrollerStyle = .overlay
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; history.documentView = document
        messageColumn.orientation = .vertical; messageColumn.alignment = .leading; messageColumn.spacing = 25
        document.addSubview(messageColumn); pin(messageColumn, to: document, inset: 4)
        document.widthAnchor.constraint(equalTo: history.contentView.widthAnchor).isActive = true
        composer.font = .systemFont(ofSize: 15); composer.textContainerInset = NSSize(width: 2, height: 8)
        composer.drawsBackground = false; composer.setAccessibilityLabel("消息")
        composer.isRichText = false; composer.allowsUndo = true; composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticTextReplacementEnabled = false; composer.autoresizingMask = [.width]
        composer.onSend = { [weak self] in self?.send() }
        composer.onInputChanged = { [weak self] in self?.composerChanged() }
        composer.onExtensionKey = { [weak self] key in
            guard let self, extensionPickerTask != nil, extensionPanel.isVisible else { return false }
            switch key {
            case 125: extensionPicker.move(1)
            case 126: extensionPicker.move(-1)
            case 123, 124: return extensionPicker.moveCategory(key == 124 ? 1 : -1)
            case 36, 48, 76: extensionPicker.pick()
            case 53: if !extensionPicker.goBack() { dismissExtensionCandidates() }
            default: return false
            }; return true
        }
        composer.onEditingEnded = { [weak self] in self?.dismissExtensionCandidates() }
        let input = NSScrollView(); input.documentView = composer; input.hasVerticalScroller = true
        input.drawsBackground = false; input.borderType = .noBorder
        sendButton.isBordered = false; sendButton.title = ""; sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "发送")
        sendButton.imagePosition = .imageOnly; sendButton.contentTintColor = .white; sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor; sendButton.layer?.cornerRadius = 11
        sendButton.setAccessibilityLabel("发送")
        sendButton.target = self; sendButton.action = #selector(send)
        sendButton.widthAnchor.constraint(equalToConstant: 34).isActive = true; sendButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        modelCaption.font = .systemFont(ofSize: 11); modelCaption.textColor = AgentWorkbenchTheme.secondaryText
        attachmentButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "添加附件"); attachmentButton.isBordered = false
        attachmentButton.target = self; attachmentButton.action = #selector(addAttachments); attachmentButton.toolTip = "添加附件"
        attachmentButton.widthAnchor.constraint(equalToConstant: 24).isActive = true; attachmentButton.isHidden = companion?.usesAgent != true
        let fill = NSView(); let entryBar = stack([attachmentButton, modelCaption, fill, sendButton], spacing: 8)
        let entry = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: AgentWorkbenchTheme.line); entry.translatesAutoresizingMaskIntoConstraints = false; entry.layer?.cornerRadius = 16; entry.layer?.borderWidth = 1
        entry.addSubview(draftAttachments); entry.addSubview(input); entry.addSubview(entryBar); input.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            draftAttachments.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), draftAttachments.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), draftAttachments.topAnchor.constraint(equalTo: entry.topAnchor, constant: 8),
            input.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), input.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), input.topAnchor.constraint(equalTo: draftAttachments.bottomAnchor, constant: 0), input.heightAnchor.constraint(equalToConstant: 60),
            entryBar.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 16), entryBar.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -10), entryBar.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 4), entryBar.bottomAnchor.constraint(equalTo: entry.bottomAnchor, constant: -10)])
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        status.isHidden = true
        var contents: [NSView] = [history, status, entry]
        if companion?.usesAgent == true {
            projectButton.title = "选择项目"; projectButton.target = self; projectButton.action = #selector(chooseProject)
            projectButton.bezelStyle = .inline; projectButton.font = .systemFont(ofSize: 11)
            projectButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); projectButton.imagePosition = .imageLeading
            projectButton.cell?.lineBreakMode = .byTruncatingMiddle; projectButton.widthAnchor.constraint(lessThanOrEqualToConstant: 145).isActive = true
            for mode in AgentMode.allCases { modePopup.addItem(withTitle: mode.title) }
            for mode in AgentPermissionMode.allCases { permissionPopup.addItem(withTitle: mode.title) }
            for popup in [modePopup, permissionPopup] { popup.controlSize = .small; popup.font = .systemFont(ofSize: 11); popup.target = self; popup.action = #selector(agentOptionsChanged) }
            modePopup.setAccessibilityLabel("任务模式"); permissionPopup.setAccessibilityLabel("审批方式")
            for button in [resumeButton, browserButton, gitButton, resultsButton] { button.bezelStyle = .inline; button.font = .systemFont(ofSize: 11); button.target = self }
            resumeButton.action = #selector(resumeAgentTask); resultsButton.action = #selector(showAgentRecords)
            gitButton.action = #selector(showAgentGit)
            browserButton.action = #selector(showAgentBrowser)
            let toolbar = stack([projectButton, modePopup, permissionPopup, NSView(), resumeButton, browserButton, gitButton, resultsButton], spacing: 6)
            configureApprovalPanel(); contents = [toolbar, history, approvalPanel, status, entry]
        }
        let column = stack(contents, vertical: true, spacing: 14)
        chat.addSubview(column); pin(column, to: chat)
        for row in contents { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        history.setContentHuggingPriority(.defaultLow, for: .vertical)
        history.heightAnchor.constraint(greaterThanOrEqualToConstant: companion?.usesAgent == true ? 60 : 160).isActive = true
    }
    private func buildSettings() {
        settingsScroll.hasVerticalScroller = true; settingsScroll.drawsBackground = false; settingsScroll.scrollerStyle = .overlay
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        settingsForm.orientation = .vertical; settingsForm.alignment = .leading; settingsForm.spacing = 22
        document.addSubview(settingsForm); pin(settingsForm, to: document, inset: 4); settingsScroll.documentView = document
        document.widthAnchor.constraint(equalTo: settingsScroll.contentView.widthAnchor).isActive = true
        var body: NSStackView!
        func group(_ category: String, _ title: String, _ keywords: String) {
            let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13, weight: .medium); heading.textColor = AgentWorkbenchTheme.secondaryText
            let framed = category != "general"
            let card = AgentThemeView(fill: framed ? .textBackgroundColor : .clear, stroke: framed ? AgentWorkbenchTheme.line : nil); card.translatesAutoresizingMaskIntoConstraints = false
            card.layer?.cornerRadius = 12; card.layer?.borderWidth = framed ? 1 : 0
            body = stack([], vertical: true, spacing: 0); body.alignment = .centerX
            card.addSubview(body); pin(body, to: card)
            let section = stack([heading, card], vertical: true, spacing: 9)
            card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            settingGroups.append((category, title, keywords, section))
        }
        func row(_ text: String, _ control: NSView, trailing: Bool = false) {
            if !body.arrangedSubviews.isEmpty {
                let rule = NSBox(); rule.boxType = .separator; body.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            }
            let line = AgentSettingsStyle.formRow(text, control, trailing: trailing || control is NSSwitch || control is NSPopUpButton), wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(line); body.addArrangedSubview(wrap)
            NSLayoutConstraint.activate([wrap.widthAnchor.constraint(equalTo: body.widthAnchor),
                line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16), line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
                line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10), line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10)])
        }
        func secret(_ input: NSSecureTextField, preview: NSButton, replace: NSButton, copy: Selector, edit: Selector, action: Selector) -> NSView {
            preview.target = self; preview.action = copy; preview.bezelStyle = .inline
            preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular); preview.alignment = .left
            preview.toolTip = "点击复制"; preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
            preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            input.setContentHuggingPriority(.defaultLow, for: .horizontal)
            replace.title = "更换"; replace.target = self; replace.action = edit; replace.bezelStyle = .inline
            let remove = NSButton(title: "移除", target: self, action: action); remove.bezelStyle = .inline
            remove.widthAnchor.constraint(equalToConstant: 42).isActive = true
            return stack([input, preview, replace, remove], spacing: 8)
        }
        for value in [endpoint, model, persona, apiKey, voiceKey, voiceEndpoint, voiceID, voiceModel, wakePhrase] { field(value) }
        for (control, label) in [(voiceEnabled, "语音回复"), (wakeEnabled, "启用语音唤醒"), (onTop, "窗口置顶")] { control.setAccessibilityLabel(label) }
        if let shortcuts = companion?.shortcuts {
            group("shortcuts", "键盘快捷键", "快捷键 键盘 shortcuts keyboard 按键 组合 导航 新建 搜索 计划")
            let panel = AgentShortcutSettingsView(shortcuts: shortcuts); shortcutSettings = panel; row("", panel)
            panel.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
        }
        group("model", "服务", "模型 接口 地址 URL Token 密钥 连接 检测 API")
        endpoint.delegate = self; model.delegate = self; apiKey.delegate = self
        model.completes = false; model.numberOfVisibleItems = 8
        checkModelButton.bezelStyle = .rounded; checkModelButton.controlSize = .large; checkModelButton.font = .systemFont(ofSize: 13); checkModelButton.target = self; checkModelButton.action = #selector(checkModel)
        modelStatus.font = .systemFont(ofSize: 12); modelStatus.textColor = AgentWorkbenchTheme.secondaryText
        row("接口", endpoint); row("模型", stack([model, checkModelButton], spacing: 8))
        row("Token", secret(apiKey, preview: apiPreview, replace: apiReplace, copy: #selector(copyAPI), edit: #selector(replaceAPI), action: #selector(removeAPI)))
        row("状态", modelStatus)
        group("model", "能力与预算", "模型 视觉 图片 理解 思考 上下文 tokens 回复 上限 预算")
        vision.addItems(withTitles: ["自动（未知）", "支持", "不支持"])
        vision.toolTip = "自动读取服务声明；手动设置不会改变模型本身的能力。"
        reasoning.addItems(withTitles: ["默认", "关闭", "最少", "低", "中", "高", "很高", "最高"])
        reasoning.menu?.autoenablesItems = false; reasoning.target = self; reasoning.action = #selector(reasoningChanged)
        contextTokens.addItems(withObjectValues: ["自动", "4096", "8192", "16384", "32768", "65536", "131072", "262144", "524288", "1048576"])
        replyTokens.addItems(withObjectValues: ["512", "1024", "2048", "4096", "8192", "16384", "32768"])
        for value in [contextTokens, replyTokens] { field(value); value.delegate = self; value.widthAnchor.constraint(equalToConstant: 118).isActive = true }
        contextTokens.toolTip = "Token 预算；按 UTF-8 字节保守估算，超出时裁剪较早的完整对话轮次。"
        for label in [contextMaximum, replyMaximum] { label.font = .systemFont(ofSize: 11); label.textColor = AgentWorkbenchTheme.secondaryText }
        row("视觉理解", vision); row("思考程度", reasoning)
        row("上下文", stack([contextTokens, NSTextField(labelWithString: "tokens"), contextMaximum], spacing: 6), trailing: true)
        row("回复上限", stack([replyTokens, NSTextField(labelWithString: "tokens"), replyMaximum], spacing: 6), trailing: true)
        group("voice", "MiniMax", "语音 声音 回复 接口 Token 密钥 模型 音色 MiniMax API")
        row("语音回复", voiceEnabled); row("接口", voiceEndpoint)
        row("Token", secret(voiceKey, preview: voicePreview, replace: voiceReplace, copy: #selector(copyVoice), edit: #selector(replaceVoice), action: #selector(removeVoice)))
        row("模型", voiceModel); row("音色", voiceID)
        group("voice", "唤醒与聆听", "语音 唤醒 关键词 麦克风 聆听 停顿 等待 状态")
        row("语音唤醒", wakeEnabled); row("唤醒词", wakePhrase)
        pauseWait.addItems(withTitles: ["2 秒", "3 秒", "5 秒"]); row("停顿等待", pauseWait)
        wakeStatus.font = .systemFont(ofSize: 12); wakeStatus.textColor = AgentWorkbenchTheme.secondaryText; row("状态", wakeStatus)
        row("", voiceStopButton)
        group("screen", "闲置时陪你看看", "屏幕 陪伴 观察 视觉 视频 评论 自动 间隔 免打扰 授权 权限")
        screenEnabled.setAccessibilityLabel("闲置时观察屏幕"); row("自动观察", screenEnabled)
        screenInterval.addItems(withTitles: ["1 分钟", "3 分钟", "5 分钟", "10 分钟", "15 分钟"]); row("观察间隔", screenInterval)
        screenTarget.font = .systemFont(ofSize: 12); screenTarget.textColor = AgentWorkbenchTheme.secondaryText
        screenTarget.lineBreakMode = .byTruncatingMiddle; screenTarget.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row("图像发送至", screenTarget)
        screenStatus.font = .systemFont(ofSize: 12); screenStatus.textColor = AgentWorkbenchTheme.secondaryText
        screenStatus.lineBreakMode = .byTruncatingTail
        row("状态", screenStatus)
        for (button, action) in [(screenPermission, #selector(grantScreenPermission)), (screenNow, #selector(lookAtScreen)), (screenQuiet, #selector(quietScreen))] {
            button.bezelStyle = .rounded; button.controlSize = .large; button.font = .systemFont(ofSize: 13); button.target = self; button.action = action
        }
        row("", stack([screenNow, screenPermission, screenQuiet], spacing: 8))
        let screenScope = NSTextField(wrappingLabelWithString: "只看当前应用窗口的一帧，不保存截图。")
        screenScope.font = .systemFont(ofSize: 12); screenScope.textColor = AgentWorkbenchTheme.secondaryText; row("", screenScope)
        group("desktop", "显示与动画", "桌面 宠物 角色 置顶 动画 性能 节能 大小 缩放 复位 位置")
        row("窗口置顶", onTop); performance.addItems(withTitles: ["自动节能", "流畅", "暂停"]); row("动画", performance)
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); sizeValue.textColor = AgentWorkbenchTheme.secondaryText
        sizeValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        scale.target = self; scale.action = #selector(scaleChanged); row("大小", stack([scale, sizeValue], spacing: 12))
        let resetPosition = NSButton(title: "复位位置", target: companion, action: #selector(AppDelegate.resetPosition))
        resetPosition.controlSize = .large; resetPosition.font = .systemFont(ofSize: 13)
        row("", stack([resetPosition, NSView()], spacing: 8))
        if let companion {
            if companion.usesAgent {
                group("general", "常规", "常规 任务与工具 运行中发送方式 排队 插话 Slash 命令展示方式 最近使用与分类 全部展开 收起插件内容 问答面板静默跳过 产物文件默认打开位置 在右侧栏查看 新窗口查看 目标驱动执行 最大轮次 目标驱动执行最大轮次 通知 轮次完成通知 权限请求通知 等待回答通知 系统通知 显示菜单栏图标 托盘 测试通知 General Notification Menu Bar Queue Interrupt Goal Turns Artifact Window " + AgentConversationDisplay.searchTerms + " " + AgentThinkingStatus.searchTerms + " " + AgentPromptSuggestions.searchTerms + " " + AgentHomeGames.searchTerms + " " + AgentSkillEvolution.searchTerms)
                let panel = AgentGeneralSettingsView(service: companion.generalSettings, thinking: companion.thinkingStatus, notifications: companion.automationNotifications, taskID: { [weak self] in self?.agentTaskID })
                generalSettingsPanel = panel
                panel.onPage = { [weak self] title in
                    guard let self, selectedTab == "settings", settingsCategory == "general", settingsSearch.stringValue.isEmpty else { return }
                    settingsHeading.stringValue = title; pageTitle.stringValue = title
                }
                row("", panel); panel.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            }
            if companion.usesAgent {
                for mode in AgentWorkMode.allCases {
                    group("modes", mode.title, "模式配置 编程 通用 绑定主题 森林 薄荷 蜜蜂 羊皮纸 项目选择入口 输入区运行环境 变更审阅 项目 文件夹 运行位置 运行环境 本地 工作树 分支 Git Mode Environment")
                    let binding = AgentThemeStyleSelectionView(service: companion.themeStyles, gallery: false, mode: { mode })
                    row("", binding); binding.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
                    let panel = AgentModeSettingsView(service: companion.modePresentation, mode: mode)
                    row("", panel); panel.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
                }
            }
            if companion.usesAgent {
                group("monitor", "任务监控", "任务监控 固定 浮动 浮层 默认展示 默认隐藏 回顾 模型 目标 计划 子智能体 后台进程 侧边聊天 Skill MCP 产出 网页 来源 知识 记忆更新 演示画面 Task Monitor Recap")
                let panel = AgentTaskMonitorSettingsView(service: companion.taskMonitor, models: { [weak self] in guard let self, let id = agentTaskID else { return [] }; return companion.agentRuntime?.modelChoices(id) ?? [] })
                row("", panel); panel.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            }
            group("appearance", "外观", "外观 主题 配色 森林 薄荷 蜜蜂 羊皮纸 深色 浅色 系统 字号 字体风格 无衬线 衬线 内容宽度 标准 宽 侧栏 菜单 上方 下方 更多 排序 Theme Appearance Font Width Sidebar 文件图标 Material File Icons 小鲸")
            let panel = AgentAppearanceSettingsView(service: companion.appearance, sidebar: companion.usesAgent ? companion.sidebarLayout : nil, styles: companion.usesAgent ? companion.themeStyles : nil, content: companion.usesAgent ? companion.contentAppearance : nil, fileIcons: companion.usesAgent ? companion.fileIcons : nil, mode: { [weak self] in self?.currentAgentTask?.organizationMode ?? .coding })
            row("", panel); panel.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
        }
        group("persona", "人设", "角色 人设 性格 提示词 persona")
        persona.usesSingleLineMode = false; persona.lineBreakMode = .byWordWrapping
        persona.heightAnchor.constraint(equalToConstant: 120).isActive = true; row("", persona)
        for (category, key, title, keywords) in [
            ("extensions", "plugins", "插件", "Plugin 安装 更新 扩展"),
            ("extensions", "skills", "技能", "Skills Skill 扩展"),
            ("extensions", "commands", "指令", "Command Slash 自定义命令 扩展"),
            ("extensions", "mcp", "连接器", "MCP 工具 配置 连接"),
            ("agents", "agents", "智能体", "Agent 角色 模型 工具权限"),
            ("teams", "teams", "智能体团队", "Team 团队 成员 负责人"),
            ("hooks", "hooks", "Hooks", "钩子 事件 自动执行"),
            ("memory", "memory", "记忆与指令", "AGENTS 全局 项目记忆 用户指令"),
            ("memory", "rules", "规则", "Rules 触发 适用场景 匹配模式"),
            ("worktrees", "worktrees", "保留与回收", "工作树 保留 自动 回收 备份 恢复 项目")
        ] {
            guard let index = settingsCategories.firstIndex(where: { $0.0 == category }) else { continue }
            group(category, title, keywords)
            let button = NSButton(title: title, target: self, action: #selector(openManagedSettingsResult(_:))); button.tag = index; button.identifier = NSUserInterfaceItemIdentifier(key); row("", button)
        }
        if let store = companion?.agentStore {
            group("attention", "需要我", "需要我 待办 问题 审批 结果 已处理 来源 通知")
            row("", AgentAttentionSettingsView(attention: store.attention))
            group("computer", "AppShot", "AppShot 窗口快照 前台 截图 可访问文字 全局 快捷键")
            let appShot = AgentAppShotSettingsView(service: companion!.appShot); row("", appShot); appShot.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            group("computer", "电脑操作", "电脑操作 Computer Use 窗口 截图 辅助功能 屏幕录制 权限")
            let desktopPanel = AgentDesktopSettingsView(desktop: store.desktop); desktopSettings = desktopPanel; row("", desktopPanel)
            group("imports", "本机任务", "数据 导入 Codex Qoder 历史 来源")
            let imports = AgentDataImportView(store: store); imports.onOpen = { [weak self] id in self?.selectAgentTask(id); self?.show(tab: "chat") }; dataImportView = imports; row("", imports)
            imports.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            group("experiments", "侧任务", "实验 侧任务 保留 可恢复 对话 标签页 主任务")
            let sides = AgentSideTaskSettingsView(service: store.sideTasks); row("", sides); sides.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            group("archived", "已归档", "归档 恢复 工作区 任务 项目")
            let archive = AgentArchivedTasksView(store: store); archivedTasksView = archive
            archive.onWillChange = { [weak self] in self?.saveAgentDraft() }
            archive.onChange = { [weak self] in self?.renderAgentMessages() }
            archive.onDelete = { [weak self] ids, workspaces in try await self?.deleteAgentTasks(ids, workspaceIDs: workspaces) }
            row("", archive); archive.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
        }
        noSettings.font = .systemFont(ofSize: 14); noSettings.textColor = AgentWorkbenchTheme.secondaryText
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings)); save.isBordered = false
        generalSettingsSave = save
        save.wantsLayer = true; save.layer?.cornerRadius = 9; save.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        save.contentTintColor = .white; save.font = .systemFont(ofSize: 13, weight: .medium)
        save.widthAnchor.constraint(equalToConstant: 76).isActive = true; save.heightAnchor.constraint(equalToConstant: 34).isActive = true
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        savedStatus.font = .systemFont(ofSize: 12); savedStatus.textColor = AgentWorkbenchTheme.secondaryText
        for view in [settingsScroll, settingsPageHost] { settingsBody.addSubview(view); pin(view, to: settingsBody) }
        settingsPageHost.isHidden = true
        let title = NSView(); title.translatesAutoresizingMaskIntoConstraints = false
        settingsHeading.font = .systemFont(ofSize: 20, weight: .semibold); settingsHeading.textColor = .labelColor
        settingsHeading.lineBreakMode = .byTruncatingTail; settingsHeading.translatesAutoresizingMaskIntoConstraints = false; title.addSubview(settingsHeading)
        NSLayoutConstraint.activate([title.heightAnchor.constraint(equalToConstant: 28), settingsHeading.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 16), settingsHeading.trailingAnchor.constraint(lessThanOrEqualTo: title.trailingAnchor, constant: -16), settingsHeading.centerYAnchor.constraint(equalTo: title.centerYAnchor)])
        let bottom = stack([savedStatus, NSView(), save]), column = stack([title, settingsBody, bottom], vertical: true, spacing: 24)
        settingsFooter = bottom
        settings.addSubview(column); pin(column, to: settings)
        title.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        settingsBody.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    func show(tab: String) {
        if selectedTab != tab, !canLeaveMainPage() { return }
        if window?.isVisible != true { refreshPreferences() }
        if tab == "settings", selectedTab != "settings" {
            settingsReturnTab = selectedTab
            settingsBackButton?.title = selectedTab == "attention" ? "返回需要我" : selectedTab == "automation" ? "返回自动化" : selectedTab == "knowledge" ? "返回知识中心" : "返回对话"
        }
        selectedTab = ["settings", "attention", "automation", "knowledge"].contains(tab) ? tab : "chat"; changeTab()
        renderMessages()
        if companion?.usesBackgroundAttachmentCheck == true { if tab != "settings" { focusTaskInput() }; return }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if selectedTab == "chat" { focusTaskInput() }
        if selectedTab == "knowledge" { knowledgePageHost.focusCurrentPage() }
        if selectedTab == "attention" { attentionPageController?.refresh(); attentionPageController?.focusSearch() }
        companion?.updatePetWorkspaceOcclusion()
    }
    private func focusTaskInput() {
        if !taskWorkspace.isHiddenOrHasHiddenAncestor, let page = taskWorkspace.currentController, page is AgentEditResendWindow || page is AgentRoundRollbackWindow { page.settingsDidAppear() }
        else { window?.makeFirstResponder(composer) }
    }
    @objc private func selectTab(_ sender: NSButton) { companion?.screenCompanion.interaction(); show(tab: sender.tag == 0 ? "chat" : "settings") }
    private func changeTab() {
        if selectedTab != "chat" { taskFind.close(notify: false); clearMessageSearchHighlight(); dismissExtensionCandidates() }
        chat.isHidden = selectedTab != "chat"; settings.isHidden = selectedTab != "settings"; attentionContent.isHidden = selectedTab != "attention"; automationContent.isHidden = selectedTab != "automation"; knowledgeContent.isHidden = selectedTab != "knowledge"
        taskSidebar.setMainPage(selectedTab)
        refreshKnowledgeNavigation()
        AgentWorkbenchTheme.color(automationButton.layer, selectedTab == "automation" ? AgentWorkbenchTheme.navigationSelection : .clear, animated: false)
        let configuring = selectedTab == "settings"
        settingsSidebar.isHidden = !configuring; chatSidebarViews.forEach { $0.isHidden = configuring }
        contentSurface.showsSettings = configuring; pageTitle.isHidden = configuring
        titleLeading.constant = configuring ? 80 : companion?.usesAgent == true ? (sidebarRequested ? 126 : 190) : 28
        pageTitle.font = .systemFont(ofSize: configuring ? 22 : companion?.usesAgent == true ? 18 : 14, weight: .semibold)
        pageTitle.textColor = companion?.usesAgent == true || configuring ? .labelColor : AgentWorkbenchTheme.secondaryText
        workbenchChrome.forEach { $0.isHidden = selectedTab != "chat" }
        if configuring { updateSettingsSections() } else { pageTitle.stringValue = currentAgentTask?.title ?? "对话" }
        AgentWorkbenchTheme.color(chatNav.layer, selectedTab == "chat" ? AgentWorkbenchTheme.navigationSelection : .clear, animated: false)
        AgentWorkbenchTheme.color(settingsNav.layer, selectedTab == "settings" ? AgentWorkbenchTheme.navigationSelection : .clear, animated: false)
        updateWorkbenchLayout()
    }
    @objc private func listen() { companion?.listenNow() }
    func refreshPreferences() {
        guard let companion else { return }
        let p = companion.store.preferences
        endpoint.stringValue = p.endpoint; model.stringValue = p.model; persona.stringValue = p.persona
        voiceEndpoint.stringValue = p.voiceEndpoint; voiceModel.stringValue = p.voiceModel; voiceID.stringValue = p.voiceID
        refreshToken(apiKey, preview: apiPreview, replace: apiReplace, account: "chat")
        refreshToken(voiceKey, preview: voicePreview, replace: voiceReplace, account: "voice")
        removeChatKey = false; removeVoiceKey = false
        storedModelInfo = p.currentModelInfo
        vision.selectItem(at: ["auto", "on", "off"].firstIndex(of: p.visionMode) ?? 0)
        reasoning.selectItem(at: effortValues.firstIndex(of: p.reasoningEffort) ?? 0)
        contextTokens.stringValue = p.contextTokens == 0 ? "自动" : String(p.contextTokens)
        replyTokens.stringValue = String(p.replyTokens); updateModelOptions()
        voiceEnabled.state = p.voiceEnabled ? .on : .off; onTop.state = p.alwaysOnTop ? .on : .off
        wakeEnabled.state = p.wakeEnabled ? .on : .off; wakePhrase.stringValue = p.wakePhrase
        wakeStatus.stringValue = companion.wakeStatus
        sidebarWake.stringValue = p.wakeEnabled ? companion.wakeStatus : "语音未开启"; listenButton.title = p.wakeEnabled ? "立即聆听" : "开启语音"
        stopRecordingButton.isEnabled = p.wakeEnabled; voiceStopButton.isEnabled = p.wakeEnabled
        modelCaption.stringValue = p.model; pauseWait.selectItem(at: [2.0, 3.0, 5.0].firstIndex(of: p.voicePauseSeconds) ?? 1)
        performance.selectItem(at: ["auto", "smooth", "paused"].firstIndex(of: p.performance) ?? 0)
        scale.doubleValue = p.scale
        sizeValue.stringValue = "\(Int((p.scale * 100).rounded()))%"
        screenEnabled.state = p.screenObservationEnabled ? .on : .off
        screenInterval.selectItem(at: [60.0, 180.0, 300.0, 600.0, 900.0].firstIndex(of: p.screenObservationInterval) ?? 2)
        screenTarget.stringValue = (try? CompanionService.endpoint(p.endpoint).host) ?? "未配置"
        screenTarget.toolTip = p.model
        updateScreenStatus(companion.screenCompanion.status)
    }
    private func updateScreenStatus(_ value: String) {
        screenStatus.stringValue = value; screenStatus.toolTip = value
        screenPermission.isEnabled = !CGPreflightScreenCaptureAccess()
        screenQuiet.title = (companion?.store.preferences.screenQuietUntil ?? .distantPast) > Date() ? "继续观察" : "免打扰30分钟"
    }
    @objc private func grantScreenPermission() { companion?.screenCompanion.requestPermission() }
    @objc private func lookAtScreen() { companion?.screenCompanion.observe() }
    @objc private func quietScreen() { companion?.pauseScreenObservation() }
    private func refreshToken(_ input: NSSecureTextField, preview: NSButton, replace: NSButton, account: String) {
        input.stringValue = ""; input.placeholderString = "API Key"
        let text = companion?.store.keychain.preview(account)
        preview.title = text ?? ""; preview.isHidden = text == nil; replace.isHidden = text == nil
        input.isHidden = text != nil
    }
    private func editToken(_ input: NSSecureTextField, preview: NSButton, replace: NSButton) {
        input.isHidden = false; preview.isHidden = true; replace.isHidden = true; input.placeholderString = "新 Token"
        window?.makeFirstResponder(input)
    }
    private func copyToken(_ account: String) {
        do {
            guard let key = try companion?.store.keychain.read(account), !key.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
            savedStatus.stringValue = "已复制"; savedStatus.textColor = AgentWorkbenchTheme.secondaryText
        } catch { savedStatus.stringValue = error.localizedDescription; savedStatus.textColor = .systemRed }
    }
    @objc private func copyAPI() { copyToken("chat") }
    @objc private func copyVoice() { copyToken("voice") }
    @objc private func replaceAPI() { editToken(apiKey, preview: apiPreview, replace: apiReplace) }
    @objc private func replaceVoice() { editToken(voiceKey, preview: voicePreview, replace: voiceReplace) }
    @objc private func removeAPI() {
        editToken(apiKey, preview: apiPreview, replace: apiReplace); apiKey.stringValue = ""
        apiKey.placeholderString = "保存后移除"; removeChatKey = true; invalidateModelCheck()
    }
    @objc private func removeVoice() {
        editToken(voiceKey, preview: voicePreview, replace: voiceReplace); voiceKey.stringValue = ""
        voiceKey.placeholderString = "保存后移除"; removeVoiceKey = true
    }
    private var selectedModelInfo: ModelInfo? {
        let url = try? CompanionService.endpoint(endpoint.stringValue, chat: true).absoluteString
        let name = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (modelCatalog + [storedModelInfo].compactMap { $0 }).first { $0.endpoint == url && $0.id == name }
    }
    private func updateModelOptions() {
        let info = selectedModelInfo
        reasoning.item(at: 0)?.title = (try? CompanionService.endpoint(endpoint.stringValue).host) == "api.deepseek.com" ? "自动（快速）" : "服务默认"
        let visionText = info?.vision.map { $0 ? "支持" : "不支持" } ?? "未知"
        vision.item(at: 0)?.title = "自动（\(visionText)）"
        for (index, value) in effortValues.enumerated() {
            reasoning.item(at: index)?.isEnabled = ["auto", "off"].contains(value) || info?.reasoningLevels?.contains(value) != false
        }
        contextMaximum.stringValue = info?.contextWindow.map { "上限 \($0)" } ?? ""
        replyMaximum.stringValue = info?.maxOutputTokens.map { "上限 \($0)" } ?? ""
        contextMaximum.toolTip = "服务声明的模型上限"; replyMaximum.toolTip = "服务声明的输出上限"
    }
    private func invalidateModelCheck() {
        modelCheckGeneration += 1; modelCheck?.cancel(); modelCheck = nil; checkModelButton.title = "检测"
        modelStatus.stringValue = "未检测"; modelStatus.textColor = AgentWorkbenchTheme.secondaryText; modelStatus.toolTip = nil
        updateModelOptions()
    }
    func controlTextDidChange(_ obj: Notification) {
        if let search = obj.object as? NSSearchField, search === settingsSearch { updateSettingsSections(); return }
        invalidateModelCheck()
    }
    @objc private func scaleChanged() { sizeValue.stringValue = "\(Int((scale.doubleValue * 100).rounded()))%" }
    func comboBoxSelectionDidChange(_ notification: Notification) { if !updatingModelChoices { invalidateModelCheck() } }
    @objc private func reasoningChanged() { invalidateModelCheck() }

    private func chatPreferences() throws -> PetPreferences {
        guard var p = companion?.store.preferences else { throw PetError("设置不可用。") }
        p.endpoint = endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        p.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); p.persona = persona.stringValue
        p.visionMode = ["auto", "on", "off"][max(0, vision.indexOfSelectedItem)]
        p.reasoningEffort = effortValues[max(0, reasoning.indexOfSelectedItem)]
        let context = contextTokens.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let window = context == "自动" ? 0 : Int(context), let output = Int(replyTokens.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PetError("上下文和回复上限请填写 Token 数。")
        }
        p.contextTokens = window; p.replyTokens = output; p.modelInfo = selectedModelInfo
        try p.validateModel(); return p
    }
    @objc private func checkModel() {
        if modelCheck != nil { invalidateModelCheck(); modelStatus.stringValue = "已取消"; return }
        do {
            var p = try chatPreferences()
            let input = apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = removeChatKey || !input.isEmpty ? input : try companion?.store.keychain.read("chat") ?? ""
            let host = try CompanionService.endpoint(p.endpoint).host ?? ""
            if key.isEmpty && !CompanionService.isLocal(host) { throw PetError("请先填写 Token。") }
            modelCheckGeneration += 1; let generation = modelCheckGeneration
            checkModelButton.title = "取消"; modelStatus.stringValue = "检测中"; modelStatus.textColor = AgentWorkbenchTheme.secondaryText
            modelCheck = Task { [weak self] in
                guard let self else { return }
                do {
                    // Catalog metadata is optional on compatible gateways. The
                    // completion itself still has to succeed before green.
                    let catalog = try? await CompanionService.models(endpoint: p.endpoint, key: key)
                    try Task.checkCancellation(); guard generation == self.modelCheckGeneration else { return }
                    if let catalog {
                        self.modelCatalog = catalog; let name = self.model.stringValue
                        self.updatingModelChoices = true
                        self.model.removeAllItems(); self.model.addItems(withObjectValues: catalog.map(\.id)); self.model.stringValue = name
                        self.updatingModelChoices = false
                        p.modelInfo = self.selectedModelInfo; self.updateModelOptions()
                    }
                    let result = try await CompanionService.probe(preferences: p, key: key)
                    try Task.checkCancellation(); guard generation == self.modelCheckGeneration else { return }
                    self.modelStatus.stringValue = result.thinkingBudgetReached ? "已连接 · 思考达到检测预算" : "已连通 · \(result.milliseconds) ms"
                    self.modelStatus.textColor = result.thinkingBudgetReached ? .systemOrange : .systemGreen
                    let source = p.currentModelInfo == nil ? "能力未声明，可手动设置。" : "能力来自服务的模型列表。"
                    self.modelStatus.toolTip = source + (result.reply.isEmpty ? "" : " 回复：" + result.reply)
                } catch {
                    guard generation == self.modelCheckGeneration else { return }
                    self.modelStatus.stringValue = Task.isCancelled ? "已取消" : error.localizedDescription
                    self.modelStatus.textColor = .systemRed; self.modelStatus.toolTip = error.localizedDescription
                }
                self.modelCheck = nil; self.checkModelButton.title = "检测"
            }
        } catch { modelStatus.stringValue = error.localizedDescription; modelStatus.textColor = .systemRed }
    }
    @objc private func saveSettings() {
        guard let companion else { return }
        do {
            var p = try chatPreferences()
            p.voiceEnabled = voiceEnabled.state == .on
            p.voiceEndpoint = voiceEndpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try CompanionService.endpoint(p.voiceEndpoint)
            p.voiceModel = voiceModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            p.voiceID = voiceID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            p.wakeEnabled = wakeEnabled.state == .on; p.wakePhrase = wakePhrase.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            p.voicePauseSeconds = [2.0, 3.0, 5.0][max(0, pauseWait.indexOfSelectedItem)]
            p.screenObservationEnabled = screenEnabled.state == .on
            p.screenObservationInterval = [60.0, 180.0, 300.0, 600.0, 900.0][max(0, screenInterval.indexOfSelectedItem)]
            if p.screenObservationEnabled && p.visionSupported != true { throw PetError("请在模型页确认视觉理解能力") }
            guard (2...12).contains(p.wakePhrase.filter({ $0.isLetter || $0.isNumber }).count) else { throw PetError("唤醒词请用 2–12 个字") }
            if p.wakeEnabled, let directory = Bundle.main.resourceURL?.appendingPathComponent("wake-model") {
                _ = try SherpaWake.tokenLine(p.wakePhrase, directory: directory)
            }
            guard !p.model.isEmpty, p.model.count < 200, p.persona.count < 8000,
                  !p.voiceID.isEmpty, !p.voiceModel.isEmpty else { throw PetError("请检查模型、音色和角色设置。") }
            if p.voiceEnabled && voiceKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (removeVoiceKey || !companion.store.keychain.contains("voice")) {
                throw PetError("请先填写 MiniMax 密钥。")
            }
            p.alwaysOnTop = onTop.state == .on; p.performance = ["auto", "smooth", "paused"][max(0, performance.indexOfSelectedItem)]
            p.scale = scale.doubleValue
            if removeChatKey || !apiKey.stringValue.isEmpty { try companion.store.keychain.write(apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), account: "chat") }
            if removeVoiceKey || !voiceKey.stringValue.isEmpty { try companion.store.keychain.write(voiceKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), account: "voice") }
            companion.store.preferences = p; try companion.store.savePreferences(); companion.applyPreferences()
            refreshPreferences(); savedStatus.stringValue = "已保存"; savedStatus.textColor = AgentWorkbenchTheme.secondaryText
        } catch { savedStatus.stringValue = error.localizedDescription; savedStatus.textColor = .systemRed }
    }
    @objc private func send() {
        guard let companion else { return }
        guard currentAgentTask?.archived != true else { setStatus("任务已归档，请先恢复", error: true); return }
        guard importTaskID != agentTaskID || attachmentImport == nil else { return }
        if let task = currentAgentTask, task.kind == "hook" { companion.agentRuntime?.cancel(task.id); return }
        let files = currentAgentTask?.draftAttachmentIDs ?? []
        if companion.usesAgent, files.isEmpty, composer.string.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
            if companion.agentRuntime?.submit(composer.string, taskID: agentTaskID) == true { composer.string = ""; composer.undoManager?.removeAllActions(); composer.didChangeText(); saveAgentDraft(); renderMessages() }
            presentTaskContext(section: 0); return
        }
        if extensionPickerTask != nil && extensionPanel.isVisible { extensionPicker.pick(); return }
        if let pair = visibleApproval, pair.task != agentTaskID,
           companion.agentStore?.task(pair.task)?.pendingCalls.first?.name == "ask_user" {
            guard files.isEmpty else { setStatus("请在子任务中添加答复附件", error: true); return }
            if companion.agentRuntime?.submit(composer.string, taskID: pair.task) == true { composer.string = ""; composer.didChangeText(); saveAgentDraft(); renderMessages() }
            return
        }
        if busy && (companion.usesAgent == false || (composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty)) { companion.cancelConversation(taskID: agentTaskID); return }
        if companion.send(composer.string, attachmentIDs: files, taskID: agentTaskID) { composer.string = ""; composer.undoManager?.removeAllActions(); composer.didChangeText(); saveAgentDraft(); renderMessages() }
        else if companion.usesAgent, let error = companion.agentRuntime?.submissionError { setStatus(error, error: true) }
    }
    @objc private func clear() {
        if let id = agentTaskID { agentTaskAction(id, action: "archive") }
        else { companion?.clearConversation(); renderMessages() }
    }
    func keepVoiceDraft(_ text: String) { composer.string = text; composer.didChangeText() }
    func keepInterruptedVoiceDraft(_ text: String) {
        composer.string = composer.string.isEmpty ? text : composer.string + "\n" + text; composer.didChangeText()
    }
    func setBusy(_ value: Bool) {
        busy = value; updateSendButton(); clearButton.isEnabled = !value
    }
    func setStatus(_ text: String, error: Bool = false) {
        status.stringValue = text; status.textColor = error ? .systemRed : AgentWorkbenchTheme.secondaryText
        status.isHidden = text.isEmpty
        if settings.isHidden == false {
            savedStatus.stringValue = text; savedStatus.textColor = error ? .systemRed : AgentWorkbenchTheme.secondaryText
        }
    }
    func scheduleRender() {
        guard window?.isVisible == true, pendingRender == nil else { return }
        let job = DispatchWorkItem { [weak self] in self?.pendingRender = nil; self?.renderMessages() }
        pendingRender = job; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: job)
    }
    func renderMessages() {
        pendingRender?.cancel(); pendingRender = nil
        guard let companion else { return }
        if companion.agentStore != nil { renderAgentMessages(); return }
        let shouldFollow = messageRows.isEmpty || history.contentView.bounds.maxY >= (history.documentView?.bounds.height ?? 0) - 60
        let messages = companion.store.messages, ids = messages.map(\.id)
        if ids != renderedIDs {
            messageColumn.arrangedSubviews.forEach { messageColumn.removeArrangedSubview($0); $0.removeFromSuperview() }
            var next: [String: ChatMessageRow] = [:]
            for message in messages {
                let row = messageRows[message.id] ?? ChatMessageRow(message: message); next[message.id] = row
                row.fit(width: (window?.contentView?.bounds.width ?? 980) - 272)
                messageColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
            }
            messageRows = next; renderedIDs = ids
        }
        for message in messages { messageRows[message.id]?.update(message.content) }
        window?.contentView?.layoutSubtreeIfNeeded()
        if shouldFollow, let document = history.documentView {
            history.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - history.contentView.bounds.height))); history.reflectScrolledClipView(history.contentView)
        }
        clearButton.title = companion.undoMessages == nil ? "清空" : "撤销清空"
    }
    func windowDidResize(_ notification: Notification) {
        dismissExtensionCandidates()
        updateWorkbenchLayout(); companion?.updatePetWorkspaceOcclusion()
        let width = companion?.usesAgent == true ? history.contentView.bounds.width - 40 : (window?.contentView?.bounds.width ?? 980) - 272
        messageRows.values.forEach { $0.fit(width: width) }
    }
    func windowDidMove(_ notification: Notification) { companion?.updatePetWorkspaceOcclusion() }
    func windowDidMiniaturize(_ notification: Notification) { monitorPanel?.orderOut(nil); companion?.updatePetWorkspaceOcclusion() }
    func windowDidDeminiaturize(_ notification: Notification) { updateWorkbenchLayout(); companion?.updatePetWorkspaceOcclusion() }
    func windowDidBecomeKey(_ notification: Notification) {
        companion?.updatePetWorkspaceOcclusion()
        companion?.focusedTaskControl = self
        updateWorkbenchLayout()
        if let task = currentAgentTask {
            if companion?.agentStore?.selectedID != task.id { companion?.agentStore?.selectedID = task.id }
            refreshBranch(task, force: true)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if windowCloseApproved { return true }
        if let editor = nameEditor { editor.window?.makeKeyAndOrderFront(nil); return false }
        if let editor = workspaceEditor { editor.window?.makeKeyAndOrderFront(nil); return false }
        guard closeWindowTask == nil else { return false }
        guard generalSettingsPanel?.prepareToClose() != false, canLeaveMainPage() else { return false }
        dismissExtensionCandidates()
        guard saveAgentDraft() else { return false }
        closeWindowTask = Task { @MainActor [weak self] in
            guard let self else { return }; defer { closeWindowTask = nil }
            if await prepareWindowClose(sender) { windowCloseApproved = true; sender.performClose(nil); windowCloseApproved = false }
        }
        return false
    }
    private func prepareWindowClose(_ sender: NSWindow) async -> Bool {
        if let id = sideTaskTabID, let task = companion?.agentStore?.task(id), let side = task.sideTask, !side.retained,
           companion?.taskControls.contains(where: { $0 !== self && $0.agentTaskID == id && $0.window != nil }) != true {
            guard !closingSideTask, await closeOwnedTaskPanels() else { return false }
            let unsafe = task.pendingFileRollback != nil || task.sideTask?.needsReview == true || task.gitTurn?.warning != nil || task.changeRounds?.contains { $0.warning != nil } == true
            let alert = AgentConfirmation(); alert.messageText = unsafe ? "保留这个侧任务后再关闭？" : "关闭临时侧任务？"
            alert.informativeText = unsafe ? "文件记录尚未完成，请保留任务以便检查和恢复。" : "这份侧任务及其子任务的对话、草稿、附件不会保留。项目文件保持当前状态。"
            if !unsafe { alert.addButton(withTitle: "关闭并移除").hasDestructiveAction = true }; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "保留为任务")
            let answer = alert.runModal()
            if answer == (unsafe ? .alertSecondButtonReturn : .alertThirdButtonReturn) {
                do { try companion?.agentStore?.sideTasks.keepAsTask(id); sideTaskTabID = nil; return true } catch { setStatus(error.localizedDescription, error: true); return false }
            }
            if !unsafe, answer == .alertFirstButtonReturn { closingSideTask = true; companion?.agentRuntime?.cancel(id); finishClosingSideTask() }
            return false
        }
        if taskWindowNumber != 1 { guard await closeOwnedTaskPanels() else { return false }; return true }
        if modelCheck != nil { invalidateModelCheck() }
        stopTaskTerminals()
        monitorPanel?.orderOut(nil); sender.orderOut(nil); companion?.updatePetWorkspaceOcclusion(); return false
    }
    private func finishClosingSideTask() {
        guard closingSideTask, !discardingSideTask, let id = sideTaskTabID, let tasks = companion?.agentStore else { return }
        guard companion?.agentRuntime?.isBusy(id) != true, tasks.task(id)?.pendingFileCapture == nil else { setStatus("正在停止并保存文件记录…"); return }
        discardingSideTask = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { let issue = try await tasks.sideTasks.discard(id); closingSideTask = false; discardingSideTask = false; sideTaskTabID = nil; if let issue { companion?.inputControl.setStatus(issue, error: true) }; window?.close() }
            catch { closingSideTask = false; discardingSideTask = false; setStatus(error.localizedDescription, error: true) }
        }
    }
    func windowWillClose(_ notification: Notification) {
        monitorPanel?.orderOut(nil); if let monitorPanel { window?.removeChildWindow(monitorPanel) }; monitorPanel = nil
        settingsPageHost.finish()
        knowledgePageHost.finish()
        taskWorkspace.finish()
        for record in Array(artifactDocuments) { record.window?.close() }
        stopTaskTerminals()
        if let panel = mcpInputPanel {
            try? companion?.agentStore?.mcp.userInputs.respond(taskID: panel.request.taskID, id: panel.request.id, action: .cancel)
            panel.dismiss(); mcpInputPanel = nil
        }
        taskFind.reset()
        taskSwitcher?.cancel()
        nameEditor?.cancel()
        workspaceEditor?.cancel()
        pendingRender?.cancel(); draftSave?.cancel(); branchTask?.cancel(); invalidateModelCheck(); dismissExtensionCandidates()
        if let manager = composer.layoutManager { manager.textStorage?.removeLayoutManager(manager) }
        composer.delegate = nil; windowDraft = nil
        companion?.removeTaskWindow(self); companion?.updatePetWorkspaceOcclusion()
    }
    func stopTaskTerminals() {
        terminalPanel?.stopAll()
        updateTerminalDock()
    }
    func closeOwnedTaskPanels() async -> Bool {
        guard generalSettingsPanel?.prepareToClose() != false else { return false }
        guard attentionPageController?.prepareToClose() != false else { return false }
        guard automationWindow?.prepareToLeave() != false else { return false }
        guard knowledgePageHost.prepareToLeave() else { return false }
        guard await taskWorkspace.canFinish() else { return false }
        guard attachmentImport == nil, window?.attachedSheet == nil else { setStatus("请先完成或取消当前对话框／附件导入", error: true); return false }
        for record in Array(artifactDocuments) {
            guard record.canLeaveSettings() else { record.showWindow(nil); record.window?.makeKeyAndOrderFront(nil); return false }
            record.window?.close()
        }
        let panels: [NSWindowController?] = [recordWindow, taskModelWindow, contextWindow, worktreeWindow, worktreeCreationWindow, extensionWindow, profileWindow, teamWindow, attachmentWindow]
        for panel in panels { if let child = panel?.window, child.isVisible { child.performClose(nil); if child.isVisible { return false } } }
        knowledgePageHost.finish()
        taskWorkspace.finish()
        return true
    }
    func requireTaskDeletionAllowed(_ ids: Set<String>, ignoring controller: AgentSettingsPageController? = nil) throws {
        try attentionPageController?.requireDeletionAllowed(ids); try recordWindow?.requireDeletionAllowed(ids)
        for record in artifactDocuments { try record.requireDeletionAllowed(ids) }
        try taskWorkspace.requireDeletionAllowed(ids, ignoring: controller)
        if settingsPageHost.controllers.contains(where: { ($0 as? AgentWorktreeWindow)?.hasPendingOperation == true }) { throw PetError("请先完成工作树操作") }
        for page in knowledgePageHost.controllers {
            if let record = page as? AgentRecordWindow { try record.requireDeletionAllowed(ids) }
            if let cards = page as? AgentKnowledgeCardWindow, ids.contains(cards.taskID), cards.dirty || cards.busy || cards.reviewWindow?.hasPendingOperation == true { throw PetError("请先保存知识卡片编辑或等待当前操作结束") }
            if let library = page as? AgentKnowledgeLibraryWindow, library.boundTaskID.map(ids.contains) == true, library.hasPendingChanges { throw PetError("请先保存知识库名称或等待文件操作结束") }
        }
    }
    func closeDeletedTaskRecords(_ ids: Set<String>) {
        recordWindow?.closeDeletedTask(ids)
        for record in Array(artifactDocuments) { record.closeDeletedTask(ids) }
        taskWorkspace.finish(tasks: ids)
        if let manager = settingsPageHost.currentController as? AgentWorktreeWindow, ids.contains(manager.boundTaskID) { manager.close() }
        worktreePolicyPanel?.refreshState()
        if knowledgePageHost.controllers.contains(where: { ($0 as? AgentRecordWindow)?.belongsToTasks(ids) == true || ($0 as? AgentKnowledgeCardWindow).map { ids.contains($0.taskID) } == true || ($0 as? AgentKnowledgeLibraryWindow)?.boundTaskID.map(ids.contains) == true }) { knowledgePageHost.finish() }
    }
    func checkAttentionNavigation() throws -> [String: Any] {
        guard CommandLine.arguments.contains("--attention-page-check"), let window, let page = attentionPageController, let tasks = companion?.agentStore, let id = agentTaskID else { throw PetError("需要我页面未初始化") }
        var checks: [String: Bool] = [:], frames: [String: Any] = [:]
        let original = window.contentView!.bounds.size, draft = tasks.task(id)?.draft
        for (name, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
            let geometry = page.checkPageGeometry(); frames[name] = geometry
            for (key, value) in geometry["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + key] = value }
            checks[name + "-actualWindowSize"] = abs(window.contentView!.bounds.width - size.width) < 0.5 && abs(window.contentView!.bounds.height - size.height) < 0.5
        }
        window.setContentSize(original); window.contentView?.layoutSubtreeIfNeeded()
        let state = page.checkState()
        checks["sameWindowSidebarAndPage"] = page.presentingWindow === window && page.isVisible && !workbenchSidebar.isHidden && workbenchChrome.allSatisfy(\.isHidden) && taskSidebar.checkAttentionSelected()
        show(tab: "chat")
        checks["returnToTaskPreservesDraft"] = selectedTab == "chat" && agentTaskID == id && tasks.task(id)?.draft == draft && !chat.isHidden && attentionContent.isHidden
        showAttentionPage()
        checks["pageReturnPreservesSelectionFilterAndReply"] = page.checkState()["selected"] as? String == state["selected"] as? String && page.checkState()["query"] as? String == state["query"] as? String && page.checkState()["reply"] as? String == state["reply"] as? String
        page.showSettings()
        checks["pageSettingsUsesSameWindowWithoutSheet"] = selectedTab == "settings" && settingsCategory == "attention" && window.attachedSheet == nil && settingsBackButton?.title == "返回需要我"
        returnToChat()
        checks["settingsReturnRestoresInbox"] = selectedTab == "attention" && page.isVisible && page.checkState()["selected"] as? String == state["selected"] as? String && page.checkState()["reply"] as? String == state["reply"] as? String
        return ["checks": checks, "frames": frames]
    }
    func checkAttentionNavigationSelection() -> Bool {
        CommandLine.arguments.contains("--attention-page-check") && selectedTab == "attention" && taskSidebar.checkAttentionSelected()
    }
    func checkAutomationNavigation(_ id: String) throws -> [String: Any] {
        guard CommandLine.arguments.contains("--automation-page-check"), let window, let manager = automationWindow, let tasks = companion?.agentStore, let taskID = agentTaskID else { throw PetError("自动化主页面未初始化") }
        var checks: [String: Bool] = [:], frames: [String: Any] = [:]
        let size = window.contentView!.bounds.size, draft = tasks.task(taskID)?.draft
        for (name, target) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
            window.setContentSize(target)
            for editing in [false, true] {
                manager.checkShowCatalog()
                if editing { guard manager.checkSelect(id) else { throw PetError("计划未进入编辑") } }
                window.contentView?.layoutSubtreeIfNeeded()
                let geometry = manager.checkPageGeometry(), key = name + (editing ? "-editor" : "-catalog"); frames[key] = geometry
                for (name, value) in geometry["checks"] as? [String: Bool] ?? [:] { checks[key + "-" + name] = value }
                checks[key + "-actualWindowSize"] = abs(window.contentView!.bounds.width - target.width) < 0.5 && abs(window.contentView!.bounds.height - target.height) < 0.5
            }
        }
        manager.checkShowCatalog(); window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
        checks["sameWindowNavigationAndMainContent"] = manager.presentingWindow === window && manager.isVisible && selectedTab == "automation" && !workbenchSidebar.isHidden && workbenchChrome.allSatisfy(\.isHidden) && (automationButton.layer?.backgroundColor?.alpha ?? 0) > 0
        showSettingsCategory("appearance")
        checks["settingsRemembersAutomationReturn"] = selectedTab == "settings" && settingsBackButton?.title == "返回自动化"
        returnToChat()
        checks["settingsReturnsToSameAutomationPage"] = selectedTab == "automation" && automationWindow === manager && manager.isVisible
        show(tab: "chat")
        checks["returnToTaskPreservesUnsentDraft"] = selectedTab == "chat" && agentTaskID == taskID && tasks.task(taskID)?.draft == draft
        showAutomations()
        return ["checks": checks, "frames": frames]
    }
    func checkAttentionSaveFailure() async -> [String: Bool] {
        guard CommandLine.arguments.contains("--attention-page-check"), let window, let page = attentionPageController, let tasks = companion?.agentStore else { return [:] }
        let originalID = agentTaskID, count = tasks.tasks.count, saved = page.checkState()["reply"] as? String ?? ""
        let oversized = String(repeating: "a", count: 65_537); page.checkSetReply(oversized)
        show(tab: "chat")
        var checks = ["failedReplySaveBlocksNavigationWithoutTruncation": selectedTab == "attention" && page.isVisible && page.checkState()["reply"] as? String == oversized]
        newAgentTask()
        if let other = tasks.tasks.first(where: { $0.id != originalID }) { selectAgentTask(other.id) }
        checks["failedReplySaveBlocksTaskCreationAndSelection"] = tasks.tasks.count == count && agentTaskID == originalID && selectedTab == "attention"
        let panelsCanClose = await closeOwnedTaskPanels()
        checks["failedReplySaveBlocksCloseAndQuitPreparation"] = !windowShouldClose(window) && !panelsCanClose
        page.checkSetReply(saved)
        checks["correctedReplyCanSaveAndLeave"] = page.prepareToClose()
        show(tab: "chat"); checks["correctedReplyRestoresNormalNavigation"] = selectedTab == "chat"
        return checks
    }
    func checkSettings(_ output: URL) async -> [String: Any] {
        guard companion?.checkDirectory != nil else { return ["success": false] }
        var checks: [String: Bool] = [:], sizes: [String: [Double]] = [:]
        func titles() -> [String] { settingGroups.filter { $0.view.superview === settingsForm }.map(\.title) }
        func capture(_ name: String) async {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let view = window?.contentView else { return }; view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            }
        }
        window?.setContentSize(NSSize(width: 980, height: 700)); show(tab: "settings")
        await capture("settings-model")
        checks["modelGroups"] = titles() == ["服务", "能力与预算"] && pageTitle.stringValue == "模型"
        let originalEndpoint = endpoint.stringValue
        endpoint.stringValue = "https://example.invalid/unsaved"; composer.string = "尚未发送的草稿"
        selectSettingsCategory(categoryButtons[1])
        await capture("settings-voice")
        checks["voiceGroups"] = titles() == ["MiniMax", "唤醒与聆听"] && pageTitle.stringValue == "语音"
        let generation = modelCheckGeneration
        settingsSearch.stringValue = "停顿"; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: settingsSearch))
        checks["searchFindsListening"] = titles() == ["唤醒与聆听"]
        settingsSearch.stringValue = "Token"; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: settingsSearch))
        checks["searchAcrossCategories"] = titles() == ["服务", "能力与预算", "MiniMax"] && pageTitle.stringValue == "搜索结果"
        checks["searchKeepsConnectionStatus"] = modelCheckGeneration == generation
        settingsSearch.stringValue = "不存在的设置"; updateSettingsSections()
        checks["emptySearch"] = titles().isEmpty && noSettings.superview === settingsForm
        selectSettingsCategory(categoryButtons[0])
        checks["unsavedInputSurvivesNavigation"] = endpoint.stringValue == "https://example.invalid/unsaved"
        endpoint.stringValue = originalEndpoint
        window?.setContentSize(NSSize(width: 780, height: 540))
        for (index, item) in settingsCategories.enumerated() {
            selectSettingsCategory(categoryButtons[index]); await capture("settings-\(item.0)-narrow")
            let groups = settingGroups.filter { $0.view.superview === settingsForm }
            checks[item.0 + "FitsNarrowWindow"] = groups.allSatisfy { $0.view.bounds.width > 450 && $0.view.frame.maxX <= settingsForm.bounds.width + 1 }
                && settingsScroll.bounds.height > 300 && !settingsForm.hasAmbiguousLayout
            sizes[item.0] = [settingsScroll.bounds.width, settingsScroll.bounds.height]
        }
        scale.doubleValue = 0.75; scaleChanged(); checks["scaleShowsPercent"] = sizeValue.stringValue == "75%"
        returnToChat()
        checks["backPreservesDraft"] = composer.string == "尚未发送的草稿" && !chat.isHidden && settingsSidebar.isHidden
        checks["nativeSettings"] = settingsSidebar.subviews.count == 1 && settingsScroll.documentView != nil
        return ["success": checks.values.allSatisfy { $0 }, "checks": checks, "narrowScrollSizes": sizes,
                "scope": "Independent profile; native settings navigation, cross-category search, draft retention and normal/narrow layout. No keychain writes, microphone, online model or TTS calls."]
    }
    func checkLayout(_ output: URL) async -> [String: Any] {
        func capture(_ name: String) {
            guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
        }
        window?.setContentSize(NSSize(width: 980, height: 700)); show(tab: "chat")
        composer.string = "周末想出去走走"; composer.didChangeText()
        try? await Task.sleep(nanoseconds: 250_000_000); window?.contentView?.layoutSubtreeIfNeeded(); capture("chat")
        let normal = composer.bounds.width > 500 && messageRows.count == companion?.store.messages.count
            && messageRows.values.allSatisfy { $0.frame.height >= 20 && $0.label.bounds.width > 10 }
        show(tab: "settings"); try? await Task.sleep(nanoseconds: 100_000_000); capture("settings")
        let settingsWork = !settings.isHidden && chat.isHidden && pauseWait.indexOfSelectedItem == 1
        window?.setContentSize(NSSize(width: 780, height: 540)); show(tab: "chat")
        try? await Task.sleep(nanoseconds: 200_000_000); window?.contentView?.layoutSubtreeIfNeeded(); capture("chat-narrow")
        let compact = composer.bounds.width > 350 && sendButton.bounds.width == 34
            && messageRows.values.allSatisfy { $0.frame.height >= 20 && !$0.hasAmbiguousLayout }
        return ["normalLayout": normal, "settingsReachable": settingsWork, "narrowLayout": compact,
                "messageCount": messageRows.count, "renderedRows": messageRows.values.map { ["width": $0.frame.width, "height": $0.frame.height, "labelWidth": $0.label.bounds.width] }]
    }
}

@MainActor private extension ControlWindow {
    func updateSendButton() {
        sendButton.toolTip = nil
        if let task = currentAgentTask, task.pendingFileRollback != nil || task.workspace.map({ companion?.agentStore?.hasFileRollback(in: $0) == true }) == true {
            sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "发送"); sendButton.setAccessibilityLabel("发送")
            sendButton.isEnabled = false; sendButton.toolTip = "请先恢复此项目未完成的文件撤回"; return
        }
        if currentAgentTask?.archived == true {
            sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "发送"); sendButton.setAccessibilityLabel("发送")
            sendButton.isEnabled = false; sendButton.toolTip = "任务已归档，请先恢复"; return
        }
        if currentAgentTask?.kind == "hook" {
            sendButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止校验")
            sendButton.setAccessibilityLabel("停止校验"); sendButton.isEnabled = busy; return
        }
        let files = currentAgentTask?.draftAttachmentIDs ?? []
        let stopping = busy && (companion?.usesAgent != true || (composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty))
        sendButton.image = NSImage(systemSymbolName: stopping ? "stop.fill" : "arrow.up", accessibilityDescription: stopping ? "停止任务" : busy ? "补充要求" : "发送")
        sendButton.setAccessibilityLabel(stopping ? "停止任务" : busy ? "补充要求" : "发送")
        sendButton.isEnabled = importTaskID != agentTaskID || attachmentImport == nil
    }
    @objc func addAttachments() {
        guard let store = companion?.agentStore, let task = currentAgentTask, !task.archived, !["wiki", "hook"].contains(task.kind ?? ""), let window else { return }
        if attachmentImport != nil { if importTaskID == task.id { attachmentImport?.cancel() }; return }
        guard (task.draftAttachmentIDs?.count ?? 0) < 6 else { setStatus("每条消息最多 6 个附件", error: true); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.prompt = "添加"
        let owner = task.id
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, self.attachmentImport == nil else { return }
            let urls = panel.urls
            guard urls.count + (store.task(owner)?.draftAttachmentIDs?.count ?? 0) <= 6 else { self.setStatus("每条消息最多 6 个附件", error: true); return }
            self.beginAttachmentImport(urls, store: store, taskID: owner)
        }
    }
    func renderDraftAttachments(_ task: AgentTaskRecord) {
        let owner = task.id, importing = importTaskID == owner && attachmentImport != nil
        let ids = task.draftAttachmentIDs ?? [], values = (task.attachments ?? []).filter { ids.contains($0.id) }
        draftAttachments.onOpen = { [weak self] id in self?.openAttachment(taskID: owner, id: id) }
        draftAttachments.onRemove = { [weak self] id in
            guard let self, let store = companion?.agentStore else { return }
            do { try AgentAttachments.removeDraft(store: store, taskID: owner, id: id); renderMessages() }
            catch { setStatus(error.localizedDescription, error: true) }
        }
        draftAttachments.update(values, removable: true, enabled: !importing)
        attachmentButton.image = NSImage(systemSymbolName: importing ? "xmark.circle" : "paperclip", accessibilityDescription: importing ? "取消添加" : "添加附件")
        attachmentButton.toolTip = importing ? "取消添加" : "添加附件"
        attachmentButton.isEnabled = !task.archived && !task.isProjectDocumentation && (attachmentImport == nil || importing)
    }
    func openAttachment(taskID: String, id: String, part: Int = 1) {
        guard let store = companion?.agentStore else { return }
        do { attachmentWindow?.window?.performClose(nil); attachmentWindow = try AgentAttachmentWindow(store: store, taskID: taskID, id: id, part: part); attachmentWindow?.showWindow(nil); attachmentWindow?.window?.makeKeyAndOrderFront(nil) }
        catch { setStatus(error.localizedDescription, error: true) }
    }
    func composerChanged() {
        updateSendButton(); draftSave?.cancel(); updateExtensionCandidates()
        guard companion?.agentStore != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveAgentDraft() }
        draftSave = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    @discardableResult func saveAgentDraft() -> Bool {
        draftSave?.cancel(); draftSave = nil
        guard let tasks = companion?.agentStore, let id = displayedTask, let task = tasks.task(id) else { return true }
        windowDraft?.refresh(task.draft ?? "", attributes: composer.typingAttributes)
        let value = composer.string
        guard (task.draft ?? "") != value || windowDraft?.saved != value || windowDraft?.pendingSave == true || tasks.writeError != nil else { return true }
        windowDraft?.pendingSave = true
        if (task.draft ?? "") != value { tasks.update(id, persist: false) { $0.draft = value } }
        do { try tasks.save(id); windowDraft?.saved = value; windowDraft?.pendingSave = false; return true }
        catch { setStatus("草稿未保存：" + error.localizedDescription, error: true); return false }
    }
    private func bindAgentDraft(_ task: AgentTaskRecord) {
        guard let value = companion?.windowDraft(task.id, attributes: composer.typingAttributes) else { return }
        if let manager = composer.layoutManager, manager.textStorage !== value.storage {
            manager.textStorage?.removeLayoutManager(manager); value.storage.addLayoutManager(manager)
        }
        windowDraft = value; composer.delegate = self; composer.needsDisplay = true
    }
    private func clearMessageSearchHighlight() {
        if let messageSearch { messageRows[messageSearch.messageID]?.clearSearchHighlight() }
        messageSearch = nil; pendingMessageReveal = false
    }
    private func messageSearchRect() -> NSRect? {
        guard let search = messageSearch, search.taskID == agentTaskID, let row = messageRows[search.messageID], let local = row.searchMatchRect(), let document = history.documentView else { return nil }
        return row.convert(local, to: document)
    }
    private var isMessageSearchVisible: Bool { messageSearchRect().map { history.contentView.bounds.intersects($0) } ?? false }
    private func revealMessageSearch(keepingVisible: Bool = false) {
        guard pendingMessageReveal || keepingVisible else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let target = messageSearchRect(), let document = history.documentView, pendingMessageReveal || !history.contentView.bounds.intersects(target) else { return }
        history.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, target.minY - 24), max(0, document.bounds.height - history.contentView.bounds.height))))
        history.reflectScrolledClipView(history.contentView); pendingMessageReveal = false
    }
    func selectAgentTask(_ id: String, searchQuery: String? = nil, messageID: String? = nil) {
        dismissExtensionCandidates()
        guard let tasks = companion?.agentStore, let record = tasks.task(id), saveAgentDraft(), canLeaveMainPage() else { return }
        if let sideTaskTabID, sideTaskTabID != id {
            if record.sideTask != nil && record.parentID == sideTaskTabID { self.sideTaskTabID = id }
            else { companion?.showTaskInMainWindow(id); return }
        } else if sideTaskTabID == nil, record.sideTask != nil { companion?.openSideTask(id, from: self); return }
        if taskFind.isHidden || id != agentTaskID || searchQuery != nil { clearMessageSearchHighlight() }
        if id != agentTaskID || searchQuery != nil { taskFind.reset() }
        if let searchQuery, let message = AgentTaskSearch.message(in: record, query: searchQuery, preferredID: messageID) {
            messageSearch = MessageSearch(taskID: id, messageID: message.id, query: searchQuery); pendingMessageReveal = true
        }
        if !navigatingTaskHistory, taskNavigationIndex < 0 || taskNavigation[taskNavigationIndex] != id {
            if taskNavigationIndex + 1 < taskNavigation.count { taskNavigation.removeSubrange((taskNavigationIndex + 1)..<taskNavigation.count) }
            taskNavigation.append(id); taskNavigationIndex = taskNavigation.count - 1
        }
        var readIssue: String?
        do { try tasks.setTaskUnread(id, false) } catch { readIssue = error.localizedDescription }
        tasks.selectedID = id; displayedTask = id; displayedWorkMode = tasks.task(id)?.organizationMode ?? displayedWorkMode
        refreshThemeStyle()
        if let task = tasks.task(id) { bindAgentDraft(task) }
        messageColumn.arrangedSubviews.forEach { messageColumn.removeArrangedSubview($0); $0.removeFromSuperview() }
        renderedIDs = []; messageRows = [:]; toolRows = [:]; reasoningRows = [:]; processRows = [:]
        readingTaskID = nil; lastHumanMessageID = nil; readingAnchorID = nil; readingSpace?.constant = 0
        selectedTab = "chat"; changeTab(); renderAgentMessages(); focusTaskInput()
        if let readIssue { setStatus(readIssue, error: true) }
        companion?.refreshAgentAnimation(); companion?.refreshVoiceBusy(); companion?.startPendingVoiceListen()
    }
    @objc func newAgentTask() {
        guard let tasks = companion?.agentStore, saveAgentDraft(), canLeaveMainPage() else { return }
        let previous = currentAgentTask
        do {
            let id:String
            if let previous, !previous.archived, let group = previous.organizationWorkspace { id = try tasks.createWorkspaceTask(group,mode:previous.organizationMode) }
            else { id = tasks.create(mode:.agent,workMode:previous?.organizationMode) }
            selectAgentTask(id)
        } catch { setStatus(error.localizedDescription,error:true) }
    }
    private func editName(title: String, label: String, value: String, save: @escaping (String) throws -> Void) {
        guard let window, nameEditor == nil, window.attachedSheet == nil else { return }
        nameEditor = AgentNameEditor(title: title, label: label, value: value, save: save, onClose: { [weak self] in self?.nameEditor = nil; self?.renderAgentMessages() })
        nameEditor?.begin(in: window)
    }
    private func directoryAction(_ path: String, mode: AgentWorkMode, action: String) {
        guard let tasks = companion?.agentStore else { return }
        do {
            if action == "archive" || action == "restore" {
                saveAgentDraft(); try tasks.setWorkspaceArchived(path, mode: mode, archived: action == "archive")
                finishArchive(mode); return
            }
            if action == "pin" { try tasks.organization.togglePinned(path, mode: mode, tasks: tasks.tasks) }
            else if action == "open" {
                guard let entry = tasks.organization.entry(path,mode:mode,tasks:tasks.tasks) else { throw PetError("工作区已变化，请重新选择") }
                let folder = try AgentFiles(workspace:entry.primary).root
                guard NSWorkspace.shared.open(folder) else { throw PetError("主文件夹未能打开") }; return
            }
            else if action == "rename" {
                guard let window, window.attachedSheet == nil, workspaceEditor == nil, nameEditor == nil, saveAgentDraft(), let entry = tasks.organization.entry(path,mode:mode,tasks:tasks.tasks) else { return }
                let revision = tasks.organization.revision
                workspaceEditor = AgentWorkspaceEditor(entry:entry,save:{ name,icon,color,folders,primary in
                    guard tasks.organization.revision == revision else { throw PetError("任务分组已变化，请重新打开后重试") }
                    try tasks.organization.editWorkspace(entry,name:name,icon:icon,color:color,folders:folders,primary:primary,tasks:tasks.tasks)
                },archive:{ [weak self] in
                    guard tasks.organization.revision == revision else { throw PetError("工作区已变化，请重新打开后重试") }
                    try tasks.setWorkspaceArchived(path,mode:mode,archived:true); self?.finishArchive(mode)
                },onClose:{ [weak self] in self?.workspaceEditor = nil; self?.renderAgentMessages() })
                workspaceEditor?.begin(in:window); return
            }
            renderAgentMessages()
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    private func customTaskGroup(_ id: String?, mode: AgentWorkMode, action: String) {
        guard let tasks = companion?.agentStore else { return }
        do {
            let existing = tasks.organization.customGroups(mode, tasks: tasks.tasks).first { $0.id == id }
            guard id == nil || existing != nil else { throw PetError("分组已变化，请刷新后重试") }
            if action == "remove", let id {
                let alert = AgentConfirmation(); alert.addButton(withTitle: "删除分组").hasDestructiveAction = true; alert.addButton(withTitle: "取消")
                alert.messageText = "删除“\(existing!.name)”分组？"; alert.informativeText = "任务会保留在未分组会话中。"
                guard alert.runModal() == .alertFirstButtonReturn else { return }; try tasks.organization.removeCustomGroup(id, mode: mode)
            } else {
                let revision = tasks.organization.revision
                editName(title: id == nil ? "新建分组" : "重命名分组", label: "分组名称", value: existing?.name ?? "") { name in
                    guard tasks.organization.revision == revision else { throw PetError("任务分组已变化，请重新打开后重试") }
                    _ = try tasks.organization.saveCustomGroup(id, name: name, mode: mode, showInTaskView: id == nil)
                }; return
            }
            renderAgentMessages()
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    @objc private func chooseExecutor() {
        guard let store = companion?.agentStore, let task = currentAgentTask, task.canChooseExecutor else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ value: String, selected: Bool = false, available: Bool = true) {
            let entry = NSMenuItem(title: title, action: #selector(selectExecutor(_:)), keyEquivalent: ""); entry.target = self; entry.representedObject = value; entry.state = selected ? .on : .off; entry.isEnabled = available; menu.addItem(entry)
        }
        item("小鲸", "default", selected: task.agent == nil)
        do {
            let profiles = try store.agents.list(enabledOnly: true, workspace: task.workspace), teams = try store.teams.list().filter(\.enabled)
            if !profiles.isEmpty { menu.addItem(.separator()); menu.addItem(NSMenuItem.sectionHeader(title: "自定义 Agent")) }
            for value in profiles { item(value.name, "agent:" + value.id, selected: task.team == nil && task.agent?.profile.id == value.id) }
            if !teams.isEmpty { menu.addItem(.separator()); menu.addItem(NSMenuItem.sectionHeader(title: "Agent 团队")) }
            for value in teams {
                let available = (try? store.teams.team(value.id, store: store, workspace: task.workspace)) != nil
                let sameProject = value.workspace.map { (try? AgentFiles(workspace: task.workspace).root.path) == $0 } ?? true
                item(value.name + (sameProject ? (available ? "" : " · 成员不可用") : " · 其他项目"), "team:" + value.id, selected: task.team?.team.id == value.id, available: available)
            }
        } catch { setStatus(error.localizedDescription, error: true) }
        menu.addItem(.separator()); item("管理 Agent…", "manage-agents"); item("管理团队…", "manage-teams")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: workbenchEmptyTitle.bounds.height + 4), in: workbenchEmptyTitle)
    }
    @objc private func selectExecutor(_ sender: NSMenuItem) {
        guard let store = companion?.agentStore, let task = currentAgentTask, let value = sender.representedObject as? String else { return }
        saveAgentDraft()
        if value == "manage-agents" {
            showSettingsCategory("agents"); return
        }
        if value == "manage-teams" {
            showSettingsCategory("teams"); return
        }
        do {
            guard task.canChooseExecutor else { throw PetError("执行者只能在发送前选择") }
            if value.hasPrefix("team:") { try store.teams.configureDraft(String(value.dropFirst(5)), taskID: task.id, store: store) }
            else if value == "default" || value.hasPrefix("agent:") { try store.agents.configureDraft(value == "default" ? nil : String(value.dropFirst(6)), taskID: task.id, store: store) }
            renderAgentMessages()
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    func configureAgentProfileDraft(_ id: String, taskID: String) throws {
        guard let store = companion?.agentStore, currentAgentTask?.id == taskID else { throw PetError("请在原任务打开 Agent 草稿") }
        let draft = try AgentProfileDrafts.load(id, taskID: taskID, store: store)
        let manager: AgentProfileWindow
        if let existing = settingsPageHost.currentController as? AgentProfileWindow, selectedTab == "settings" {
            guard existing.workspace == store.task(taskID)?.workspace else { throw PetError("请先完成已打开项目的 Agent 配置") }; manager = existing
        } else {
            guard showSettingsCategory("agents"), let embedded = settingsPageHost.currentController as? AgentProfileWindow else { throw PetError("请先完成当前设置编辑") }
            manager = embedded
        }
        try manager.configureDraft(draft)
        if try store.agents.decode(store.agents.document().0).contains(where: { $0.id == draft.profile.id }) { try AgentProfileDrafts.markSaved(id, taskID: taskID, profileID: draft.profile.id, store: store) }
        manager.onSaved = { [weak self, weak store] profileID in
            guard let store, profileID == draft.profile.id else { return }
            try AgentProfileDrafts.markSaved(id, taskID: taskID, profileID: profileID, store: store); self?.renderAgentMessages()
        }
        profileWindow = manager
        window?.makeKeyAndOrderFront(nil)
    }
    internal func confirmSkillPlan(taskID:String, source:String, start:Bool = true) throws {
        guard agentTaskID == taskID, let store = companion?.agentStore, let runtime = companion?.agentRuntime, !runtime.isBusy(taskID) else { throw PetError("请在原任务确认当前方案") }
        try AgentSkillDrafts.approvePlan(taskID,source:source,store:store)
        guard runtime.submit("按已确认方案生成可审阅的 Skill 草稿，内容语言遵循原目标。",taskID:taskID,startImmediately:start) else { throw PetError(runtime.submissionError ?? "生成请求未提交") }; renderAgentMessages()
    }
    internal func presentSkillSources(taskID:String, source:String) throws {
        guard agentTaskID == taskID, let task = companion?.agentStore?.task(taskID), AgentSkillEvolution.source(task) == source else { throw PetError("建议来源已变化，请回到当前任务") }
        presentTaskContext(section:0)
        guard taskWorkspace.taskID == taskID, taskWorkspace.selectedRoot == .context, let parent = taskWorkspace.currentController else { throw PetError("请先完成当前页面编辑") }
        if let page = parent as? AgentSkillSourcesPage, page.source == source { return }
        parent.presentSettingsChild(AgentSkillSourcesPage(task:task,source:source)); updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    internal func reviewSkillDraft(taskID:String) throws {
        guard agentTaskID == taskID, let store = companion?.agentStore, companion?.agentRuntime?.isBusy(taskID) == false else { throw PetError("请在原任务等待草稿生成完成") }
        let page = try AgentSkillDraftReviewPage(store:store,taskID:taskID)
        guard showSettingsCategory("extensions") else { throw PetError("请先完成当前编辑") }; settingsPageHost.selectPage("skills")
        guard let parent = settingsPageHost.currentController else { throw PetError("技能设置页不可用") }
        page.onApplied = { [weak self] in guard let self else { return }; show(tab:"chat"); renderAgentMessages() }; parent.presentSettingsChild(page)
    }
    private func openSavedSkill(taskID:String) throws {
        guard agentTaskID == taskID, let store = companion?.agentStore, let id = store.task(taskID)?.skillDraft?.savedID else { throw PetError("技能尚未保存") }
        guard showSettingsCategory("extensions") else { throw PetError("请先完成当前编辑") }; settingsPageHost.selectPage("skills")
        guard let manager = settingsPageHost.currentController as? AgentExtensionWindow else { throw PetError("技能设置页不可用") }; manager.selectItem(id)
    }
    func configureAutomationDraft(_ id: String, taskID: String) throws {
        guard let store = companion?.agentStore, currentAgentTask?.id == taskID else { throw PetError("请在原任务打开自动化草稿") }
        let draft = try AgentAutomationDrafts.load(id, taskID: taskID, store: store)
        if selectedTab != "automation" { guard canLeaveMainPage() else { throw PetError("请先完成当前页面编辑") } }
        let manager = preparedAutomationWindow(store)
        try manager.configureDraft(draft)
        if store.automations.values.contains(where: { $0.id == draft.automation.id }) { try AgentAutomationDrafts.markSaved(id, taskID: taskID, automationID: draft.automation.id, store: store) }
        manager.onSaved = { [weak self, weak store] automationID in
            guard let store, automationID == draft.automation.id else { return }
            try AgentAutomationDrafts.markSaved(id, taskID: taskID, automationID: automationID, store: store); self?.renderAgentMessages()
        }
        showAutomations()
    }
    func agentTaskAction(_ id: String, action: String) {
        guard let tasks = companion?.agentStore, let task = tasks.task(id), task.status != .running || action.hasPrefix("export:") || ["copy-id", "read", "unread", "new-window", "side-task", "side-parent", "side-keep"].contains(action) else { return }
        if action.hasPrefix("export:"), let format = AgentTaskExport.Format(rawValue: String(action.dropFirst(7))) { exportAgentTask(id, format: format); return }
        switch action {
        case "side-task":
            do { guard saveAgentDraft() else { return }; let child = try tasks.sideTasks.create(parentID: id); companion?.openSideTask(child, from: self) } catch { setStatus(error.localizedDescription, error: true) }; return
        case "side-parent": if let parent = task.sideTask?.parentID { companion?.showTaskInMainWindow(parent) }; return
        case "side-keep":
            do { try tasks.sideTasks.keepAsTask(id); sideTaskTabID = nil; renderAgentMessages() } catch { setStatus(error.localizedDescription, error: true) }; return
        case "new-window": companion?.openTaskWindow(id, from: self); return
        case "read", "unread":
            do { try tasks.setTaskUnread(id, action == "unread"); renderAgentMessages() } catch { setStatus(error.localizedDescription, error: true) }; return
        case "copy-id": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
        case "delete":
            Task { @MainActor [weak self] in
                do { if let issue = try await self?.deleteAgentTasks([id], workspaceIDs: []) { self?.setStatus(issue, error: true) } }
                catch { self?.setStatus(error.localizedDescription, error: true) }
            }; return
        case "rename":
            guard saveAgentDraft() else { return }
            do {
                let hash = try tasks.recordVersion(id)
                editName(title: "重命名任务", label: "任务名称", value: tasks.task(id)?.title ?? task.title) { [weak self] name in
                    guard self?.companion?.agentRuntime?.isExecuting(id) != true else { throw PetError("任务正在运行，请结束后重试") }
                    try tasks.renameTask(id, title: name, expectedHash: hash)
                }
            } catch { setStatus(error.localizedDescription, error: true) }; return
        case "pin": tasks.update(id) { $0.pinned.toggle() }
        case "recover-round-files": if let pending = task.pendingFileRollback { presentRoundRollback(taskID: id, messageID: pending.messageID) }
        case "work-mode":
            guard task.status != .waiting, companion?.agentRuntime?.isExecuting(id) != true, task.agent?.ownerID == nil, task.automation == nil, task.kind != "hook", !task.isProjectDocumentation else { return }
            saveAgentDraft(); tasks.update(id) { $0.workMode = task.organizationMode == .coding ? .general : nil }
            if agentTaskID == id { selectAgentTask(id) }
        case "import-source":
            guard let origin = task.importOrigin else { return }
            let alert = AgentConfirmation(); alert.messageText = origin.source.title + "导入记录"
            alert.informativeText = "原工作目录：" + (origin.originalWorkspace ?? "无") + "\n来源：" + origin.sourceFile + (origin.warnings.isEmpty ? "" : "\n" + origin.warnings.joined(separator: "\n"))
            alert.addButton(withTitle: "来源副本"); alert.addButton(withTitle: "关闭")
            if alert.runModal() == .alertFirstButtonReturn {
                do { NSWorkspace.shared.activateFileViewerSelecting([try tasks.dataImport.sourceURL(id)]) } catch { setStatus(error.localizedDescription, error: true) }
            }
        case "fork":
            guard saveAgentDraft() else { return }
            if let next = tasks.fork(id) { selectAgentTask(next) } else if let issue = tasks.writeError { setStatus(issue, error: true) }
        case "archive":
            _ = archiveTasks([id], archived: !task.archived); return
        default: break
        }
        renderAgentMessages()
    }
    private func archiveTasks(_ ids: [String], archived: Bool) -> Bool {
        guard let store = companion?.agentStore else { return false }
        let mode = currentAgentTask?.organizationMode ?? .coding
        do { saveAgentDraft(); try store.setArchived(ids, archived: archived); finishArchive(mode); return true }
        catch { setStatus(error.localizedDescription, error: true); return false }
    }
    private func finishArchive(_ mode: AgentWorkMode) {
        guard let store = companion?.agentStore else { return }
        let id = currentAgentTask.flatMap { $0.archived ? nil : $0.id } ?? store.tasks.first(where: { !$0.archived && $0.organizationMode == mode })?.id ?? store.create(workMode: mode)
        if displayedTask != id { selectAgentTask(id) } else { renderAgentMessages() }
        archivedTasksView?.refresh()
    }
    private func deleteAgentTasks(_ ids: [String], workspaceIDs: [String]) async throws -> String? {
        guard let store = companion?.agentStore else { throw PetError("任务未初始化") }
        saveAgentDraft(); let mode = currentAgentTask?.organizationMode ?? .coding, plan = try store.prepareDeletion(ids, workspaceIDs: workspaceIDs)
        try companion?.requireTaskDeletionAllowed(plan.ids)
        let alert = AgentConfirmation()
        alert.messageText = workspaceIDs.isEmpty ? "永久删除\(plan.records.count)项任务？" : "永久删除\(workspaceIDs.count)个工作区及\(plan.records.count)项任务？"
        let names = plan.workspaceTitles + plan.titles
        alert.informativeText = names.joined(separator: "\n") + "\n\n对话、草稿、任务附件和检查点将不可恢复。项目文件和 Git 工作树保留。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "永久删除"); alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        try companion?.requireTaskDeletionAllowed(plan.ids)
        let issue = try await store.permanentlyDelete(plan)
        companion?.closeDeletedTaskWindows(plan.ids)
        taskNavigation.removeAll { plan.ids.contains($0) }; taskNavigationIndex = agentTaskID.flatMap { taskNavigation.firstIndex(of: $0) } ?? taskNavigation.count - 1
        finishArchive(mode); return issue
    }
    private func exportAgentTask(_ id: String, format: AgentTaskExport.Format) {
        guard let store = companion?.agentStore, let task = store.task(id), let window else { return }
        let history = AgentTaskExport.snapshot(task), panel = NSSavePanel()
        panel.title = "导出任务历史"; panel.allowedContentTypes = [format == .json ? .json : UTType(filenameExtension: "md") ?? .plainText]
        let title = task.title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = String((title.isEmpty ? "任务历史" : title).prefix(100)) + "." + format.suffix
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    guard store.task(id) != nil else { throw PetError("任务已永久删除，未导出") }
                    let target = try AgentTaskExport.destination(url, profile: store.directory.deletingLastPathComponent(), application: Bundle.main.bundleURL)
                    let data = try await Task.detached(priority: .utility) { try AgentTaskExport.data(history, format: format) }.value
                    guard store.task(id) != nil else { throw PetError("任务已永久删除，未导出") }
                    try target.files.writeData(data, to: target.url, permissions: 0o600, expectedTarget: target.signature)
                    self?.setStatus("已导出 " + target.url.lastPathComponent)
                } catch { self?.setStatus(error.localizedDescription, error: true) }
            }
        }
    }
    @objc func chooseProject() {
        guard let task = currentAgentTask, let tasks = companion?.agentStore else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        let choose = NSMenuItem(title:"新建" + task.organizationMode.directoryTitle + "…",action:#selector(chooseProjectDirectory),keyEquivalent:""); choose.target = self; menu.addItem(choose)
        let entries = tasks.organization.directories(task.organizationMode,tasks:tasks.tasks)
        if !entries.isEmpty { menu.addItem(.separator()) }
        for entry in entries {
            let item = NSMenuItem(title:entry.title,action:#selector(selectWorkspaceEntry(_:)),keyEquivalent:""); item.target = self; item.representedObject = [entry.path,entry.mode.rawValue]
            item.state = task.organizationWorkspace == entry.path ? .on : .off; item.toolTip = entry.sourceFolders.joined(separator:"\n")
            item.image = NSImage(systemSymbolName:(entry.icon ?? .folder).rawValue,accessibilityDescription:nil); menu.addItem(item)
        }
        if task.organizationMode == .general {
            menu.addItem(.separator()); let none = NSMenuItem(title:"不关联文件夹",action:#selector(clearGeneralDirectory),keyEquivalent:""); none.target = self; none.isEnabled = task.workspace != nil && ![.running,.waiting].contains(task.status) && task.automation == nil; menu.addItem(none)
        }
        let anchor = emptyProject.isHiddenOrHasHiddenAncestor ? projectButton : emptyProject
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:anchor.bounds.height+4),in:anchor)
    }
    @objc private func selectWorkspaceEntry(_ sender:NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2, let mode = AgentWorkMode(rawValue:values[1]), let task = currentAgentTask, mode == task.organizationMode, let tasks = companion?.agentStore,
              let entry = tasks.organization.entry(values[0],mode:mode,tasks:tasks.tasks) else { return }
        do { try applyWorkspaceSelection(entry,original:task) } catch { setStatus(error.localizedDescription,error:true) }
    }
    private func applyWorkspaceSelection(_ entry:AgentDirectoryEntry, original task:AgentTaskRecord) throws {
        guard let tasks = companion?.agentStore, agentTaskID == task.id, let current = tasks.task(task.id), current.workspace == task.workspace, current.workspaceScope == task.workspaceScope,
              current.organizationMode == task.organizationMode, current.automation == nil, current.agent?.ownerID == nil, !current.archived, !current.isProjectDocumentation, current.kind != "hook",
              current.workspace == nil || ![.running,.waiting].contains(current.status), saveAgentDraft() else { throw PetError("原任务已变化，请重新选择工作区") }
        let folders = try AgentWorkspaceScope.validateFolders(entry.sourceFolders,primary:entry.primary)
        guard folders == entry.sourceFolders else { throw PetError("源文件夹指向已变化，请重新编辑工作区") }
        let changed = task.workspace != entry.primary || task.workspaceScope != entry.scope
        if task.workspace == nil {
            companion?.agentRuntime?.cancel(task.id)
            tasks.update(task.id) { $0.workspace = entry.primary; $0.workspaceScope = entry.scope; $0.gitDirectory = nil; $0.agent?.workspace = entry.primary }
            if !task.messages.isEmpty { companion?.agentRuntime?.submit("已选择项目：" + entry.primary + "。继续原任务。",taskID:task.id) }
            renderAgentMessages()
        } else if changed && (!task.messages.isEmpty || task.worktreeOrigin != nil) {
            let id = try tasks.createWorkspaceTask(entry.path,mode:task.organizationMode,taskMode:task.mode)
            do { try AgentAttachments.copyDraft(store:tasks,sourceID:task.id,targetID:id) }
            catch { selectAgentTask(task.id); throw error }
            tasks.update(id) { $0.draft = self.composer.string; $0.permission = task.permission; $0.model = task.model; $0.modelOverride = task.modelOverride; $0.agent = task.agent; $0.agent?.workspace = entry.primary; $0.team = task.team }
            selectAgentTask(id)
        } else if changed {
            tasks.update(task.id) { $0.workspace = entry.primary; $0.workspaceScope = entry.scope; $0.gitDirectory = nil; $0.agent?.workspace = entry.primary }; renderAgentMessages()
        }
    }
    @objc private func clearGeneralDirectory() {
        guard let tasks = companion?.agentStore, let task = currentAgentTask, task.organizationMode == .general, task.workspace != nil, task.automation == nil, task.agent?.ownerID == nil, !task.archived, !["hook", "wiki"].contains(task.kind ?? ""), ![.running, .waiting].contains(task.status) else { return }
        saveAgentDraft()
        if !task.messages.isEmpty || task.worktreeOrigin != nil {
            let id = tasks.create(mode:task.mode,workMode:.general)
            do { try AgentAttachments.copyDraft(store:tasks,sourceID:task.id,targetID:id) }
            catch { selectAgentTask(task.id); setStatus(error.localizedDescription,error:true); return }
            tasks.update(id) { $0.draft = self.composer.string; $0.permission = task.permission; $0.model = task.model; $0.modelOverride = task.modelOverride; $0.agent = task.agent; $0.agent?.workspace = nil; $0.team = task.team }; selectAgentTask(id)
        } else { tasks.update(task.id) { $0.workspace = nil; $0.workspaceScope = nil; $0.gitDirectory = nil; $0.agent?.workspace = nil }; renderAgentMessages() }
    }
    @objc private func chooseProjectDirectory() {
        guard let tasks = companion?.agentStore, let task = currentAgentTask, task.automation == nil, task.agent?.ownerID == nil, !task.archived, !task.isProjectDocumentation, task.kind != "hook", task.workspace == nil || ![.running,.waiting].contains(task.status), let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.prompt = "选择" + task.organizationMode.directoryTitle
        if let path = task.workspace { panel.directoryURL = URL(fileURLWithPath:path) }
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try tasks.organization.register(url.path,mode:task.organizationMode)
                guard let entry = tasks.organization.entry(url.resolvingSymlinksInPath().path,mode:task.organizationMode,tasks:tasks.tasks) else { throw PetError("工作区未登记") }
                try applyWorkspaceSelection(entry,original:task)
            } catch { setStatus(error.localizedDescription,error:true) }
        }
    }
    @objc func agentOptionsChanged() {
        guard let tasks = companion?.agentStore, let task = currentAgentTask, task.automation == nil, task.status != .running && task.status != .waiting else { return }
        tasks.update(task.id) { $0.mode = AgentMode.allCases[max(0, modePopup.indexOfSelectedItem)]; $0.permission = AgentPermissionMode.allCases[max(0, permissionPopup.indexOfSelectedItem)] }
        renderAgentMessages()
    }
    @objc private func showExecutionLocation() {
        guard let tasks = companion?.agentStore, let task = currentAgentTask, task.canChooseEnvironment else { return }
        saveAgentDraft()
        let menu = NSMenu(); menu.autoenablesItems = false
        let local = NSMenuItem(title: "本地", action: #selector(selectLocalEnvironment), keyEquivalent: ""); local.target = self; local.state = task.worktreeOrigin == nil ? .on : .off; local.isEnabled = task.worktreeOrigin != nil; menu.addItem(local)
        let worktree = NSMenuItem(title: "工作树…", action: #selector(createTaskWorktree), keyEquivalent: ""); worktree.target = self; worktree.state = task.worktreeOrigin == nil ? .off : .on; worktree.isEnabled = task.workspace != nil && task.worktreeOrigin == nil; menu.addItem(worktree)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: executionLocation.bounds.height + 4), in: executionLocation)
    }
    @objc internal func createTaskWorktree() {
        guard let tasks = companion?.agentStore, let task = currentAgentTask, task.canChooseEnvironment, task.workspace != nil else { return }
        guard saveAgentDraft() else { return }
        do {
            let directory = try AgentGit.metadata(workspace: task.workspace)
            if !directory.path.hasPrefix((task.workspace ?? "") + "/"), task.gitDirectory != directory.path {
                let alert = AgentConfirmation(); alert.messageText = "连接 Git 仓库元数据？"; alert.informativeText = directory.path; alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }; tasks.update(task.id) { $0.gitDirectory = directory.path }
            }
            showAgentGit()
            guard taskWorkspace.taskID == task.id, taskWorkspace.selectedRoot == .review, taskWorkspace.prepareToNavigate(), let parent = taskWorkspace.currentController else { return }
            if parent is AgentWorktreeCreationWindow { return }
            let controller = try AgentWorktreeCreationWindow(store: tasks, taskID: task.id, directory: directory) { [weak self] id in self?.selectAgentTask(id); self?.show(tab: "chat") }
            worktreeCreationWindow = controller; parent.presentSettingsChild(controller)
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    @objc private func selectLocalEnvironment() {
        guard let tasks = companion?.agentStore, let source = currentAgentTask, source.canChooseEnvironment, let origin = source.worktreeOrigin else { return }
        saveAgentDraft(); let id = tasks.create(workspace: origin.root, mode: source.mode, workMode: source.organizationMode)
        do { try tasks.copyEnvironmentDraft(sourceID: source.id, targetID: id); selectAgentTask(id) }
        catch { tasks.selectedID = source.id; setStatus(error.localizedDescription, error: true) }
    }
    @objc func resumeAgentTask() { if let id = agentTaskID { companion?.agentRuntime?.start(id) } }
    @objc func showAgentRecords() { presentAgentRecords(section: 0) }
    @objc func showAgentBrowser() {
        guard let store = companion?.agentStore, let task = currentAgentTask else { return }
        do { _ = try store.browser.show(taskID: task.id, title: task.title) }
        catch { setStatus(error.localizedDescription, error: true) }
    }
    @objc private func toggleTaskTerminal() {
        if terminalSplit.isHidden && taskWorkspace.requested {
            taskWorkspace.hideForNavigation()
            if terminalPanel?.isShown == true { terminalPanel?.focus(); return }
        }
        if terminalPanel?.isShown == true { terminalPanel?.hidePanel() }
        else { openTaskTerminal() }
    }
    private func openTaskTerminal() {
        guard selectedTab == "chat", let companion, let store = companion.agentStore, let task = currentAgentTask else { return }
        if terminalSplit.isHidden && taskWorkspace.requested { taskWorkspace.hideForNavigation() }
        let panel = terminalPanel ?? AgentTerminalPanel(store: store, checkHome: companion.checkDirectory)
        terminalPanel = panel
        panel.onMonitorChange = { [weak self] in self?.scheduleRender() }
        panel.onHide = { [weak self] in
            guard let self else { return }
            updateTerminalDock()
            window?.makeFirstResponder(composer)
        }
        panel.selectTask(task)
        do {
            try panel.open()
            updateTerminalDock()
            window?.contentView?.layoutSubtreeIfNeeded()
            panel.focus()
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    private func updateTerminalDock() {
        let shown = selectedTab == "chat" && terminalPanel?.isShown == true
        terminalSplit.showTerminal(shown ? terminalPanel : nil)
        let title = shown ? "收起终端" : "打开终端"
        terminalButton.setAccessibilityLabel(title)
        terminalButton.toolTip = title
    }
    @objc internal func showAgentGit() {
        guard let store = companion?.agentStore, let id = agentTaskID, saveAgentDraft() else { return }
        if selectedTab != "chat" { guard canLeaveMainPage() else { return }; show(tab: "chat") }
        taskWorkspace.show(taskID: id) { AgentGitWindow(store: store, taskID: id) { [weak self] next in self?.selectAgentTask(next); self?.show(tab: "chat") } }
        updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    internal func gitWorkspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        var value = taskWorkspace.checkState(); value["selectedTask"] = agentTaskID ?? ""; value["draft"] = composer.string
        value["conversationVisible"] = !terminalSplit.isHiddenOrHasHiddenAncestor; value["conversationWidth"] = Double(terminalSplit.bounds.width); value["mainPage"] = selectedTab
        value["composerFocused"] = window?.firstResponder === composer
        value["windowSize"] = [Double(window?.contentView?.bounds.width ?? 0), Double(window?.contentView?.bounds.height ?? 0)]
        value["inspectorWidth"] = Double(workbenchInspector.bounds.width)
        value["taskTitle"] = pageTitle.stringValue; value["taskTitleVisible"] = !pageTitle.isHidden
        for page in taskWorkspace.controllers {
            if let git = page as? AgentGitWindow { value["git-" + git.boundTaskID] = git.workspaceReadback() }
            if let push = page as? AgentGitPushWindow, push.isPageVisible { value["push"] = push.workspaceReadback() }
        }
        return value
    }
    internal func taskWorkspaceReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        var value = gitWorkspaceReadback(), documents: [[String: Any]] = [], offices: [[String: Any]] = [], canvases: [[String: Any]] = [], browsers: [[String: Any]] = []
        for page in taskWorkspace.controllers {
            if let context = page as? AgentContextWindow, context.isPageVisible { value["context"] = context.workspaceReadback() }
            if let record = page as? AgentRecordWindow { documents.append(await record.workspaceReadback()) }
            if let comparison = page as? AgentFileConflictWindow, comparison.isPageVisible { value["comparison"] = comparison.checkState }
            if let office = page as? AgentOfficeWindow { offices.append(await office.workspaceReadback()) }
            if let canvas = page as? AgentCanvasWindow { canvases.append(canvas.workspaceReadback()) }
            if let browser = page as? AgentBrowserWindow { browsers.append(browser.workspaceReadback()); if browser.isPageVisible { value["browser"] = browser.workspaceReadback() } }
            if let annotation = page as? AgentBrowserAnnotationWindow, annotation.isPageVisible { value["browserAnnotation"] = annotation.workspaceReadback() }
            if let creation = page as? AgentWorktreeCreationWindow, creation.isPageVisible { value["worktreeCreation"] = creation.workspaceReadback() }
            if let manager = page as? AgentWorktreeWindow, manager.isPageVisible { value["worktrees"] = manager.workspaceReadback() }
            if let rollback = page as? AgentRoundRollbackWindow, rollback.isPageVisible { value["rollback"] = rollback.workspaceReadback() }
            if let editor = page as? AgentEditResendWindow { value["edit-resend-" + editor.boundTaskID] = editor.workspaceReadback(); if editor.isPageVisible { value["editResend"] = editor.workspaceReadback() } }
        }
        if selectedTab == "settings", settingsCategory == "worktrees" {
            value["settingsWorktrees"] = worktreePolicyPanel?.workspaceReadback() ?? [:]
            value["settingsController"] = settingsPageHost.currentController.map { String(describing: type(of: $0)) } ?? ""
            if let manager = settingsPageHost.currentController as? AgentWorktreeWindow { value["settingsWorktreeManager"] = manager.workspaceReadback() }
        }
        value["documents"] = documents; value["offices"] = offices; value["canvases"] = canvases; value["browsers"] = browsers; value["documentOpen"] = taskDocumentOpenState; return value
    }
    internal func checkWorktreeSettingsPage(open: Bool = true) -> AgentSettingsPageController? {
        guard AgentTaskWorkspace.readbackEnabled else { return nil }
        if open, !showSettingsCategory("worktrees") { return nil }; return settingsPageHost.currentController
    }
    private func refreshKnowledgeNavigation() {
        AgentWorkbenchTheme.color(libraryButton.layer, selectedTab == "knowledge" && knowledgePageHost.selectedRoot == "library" ? AgentWorkbenchTheme.navigationSelection : .clear, animated: false)
        AgentWorkbenchTheme.color(projectKnowledgeButton.layer, selectedTab == "knowledge" && knowledgePageHost.selectedRoot == "wiki" ? AgentWorkbenchTheme.navigationSelection : .clear, animated: false)
        refreshSidebarMoreSelection()
    }
    internal func knowledgePageReadback() async -> [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled else { return [:] }
        var value = knowledgePageHost.checkState(); value["selectedTask"] = agentTaskID ?? ""; value["mainPage"] = selectedTab
        for controller in knowledgePageHost.controllers {
            if let library = controller as? AgentKnowledgeLibraryWindow { value["library"] = library.checkState() }
            if let catalog = controller as? AgentRepoWikiWindow { value["wikiCatalog"] = catalog.checkState }
            if let cards = controller as? AgentKnowledgeCardWindow { value["cards"] = cards.checkState() }
            if let index = controller as? AgentKnowledgeWindow { value["index"] = index.checkState() }
            if let reader = controller as? AgentRecordWindow { value["wikiReader"] = await reader.markdownEditingReadback() }
            if let plan = controller as? AgentWikiPlanWindow { value["wikiPlan"] = plan.checkState }
            if let review = controller as? AgentKnowledgeReviewWindow { value["knowledgeReview"] = review.checkState }
            if let source = controller as? AgentMarkdownSourceWindow { value["source"] = source.encodingCheckState }
            if let video = controller as? AgentVideoWindow { value["video"] = await video.preview.checkState() }
        }; return value
    }
    @discardableResult private func showKnowledgeCenter(root: String) -> Bool {
        guard let store = companion?.agentStore, saveAgentDraft() else { return false }
        if selectedTab != "knowledge", !canLeaveMainPage() { return false }
        let sourceID = agentTaskID
        guard knowledgePageHost.show(root: root, identity: sourceID ?? "standalone", make: { [weak self, weak store] kind in
            guard let self, let store else { return nil }
            if kind == "library" { let manager = AgentKnowledgeLibraryWindow(store: store, taskID: sourceID); self.knowledgeLibraryWindow = manager; return manager }
            let manager = AgentRepoWikiWindow(store: store)
            manager.onOpen = { [weak self] project, language, action in guard let self else { throw PetError("任务窗口已关闭") }; try self.openRepoWikiProject(project, language: language, action: action) }
            self.repoWikiWindow = manager; return manager
        }) else { return false }
        sidebarRequested = true; show(tab: "knowledge"); return true
    }
    @objc internal func showAgentKnowledge() { _ = showKnowledgeCenter(root: "wiki") }
    private func openRepoWikiProject(_ project: AgentRepoWikiProject, language: String, action: String) throws {
        guard let store = companion?.agentStore, ["wiki", "cards", "search"].contains(action), ["zh", "en"].contains(language) else { throw PetError("项目操作无效") }
        let files = try AgentFiles(workspace: project.workspace)
        _ = try AgentProjectIndex(workspace: files.root.path, storage: store.directory)
        let candidates = store.tasks.filter { task in !task.archived && task.agent == nil && task.team == nil && task.automation == nil && !task.isProjectDocumentation && task.kind != "hook" && task.workspace.map { URL(fileURLWithPath: $0).standardizedFileURL.path == files.root.path } == true }
        let preferred = candidates.first { $0.id == project.taskID } ?? candidates.max { $0.updated < $1.updated }
        let id: String
        if let source = preferred.flatMap({ store.task($0.id) }), try AgentFiles(workspace: source.workspace).root == files.root { id = source.id }
        else {
            guard saveAgentDraft() else { throw PetError("请先保存当前任务草稿") }; if let displayedTask { try store.save(displayedTask) }
            let previous = store.selectedID
            id = store.create(title: "项目知识 · " + project.name, workspace: files.root.path, workMode: project.mode)
            store.selectedID = previous
            if let previous = previous.flatMap(store.task) { try store.organization.remember(previous) }
            try store.save(id)
        }
        switch action {
        case "wiki":
            if store.task(id)?.wikiLanguage != language { store.update(id) { $0.wikiLanguage = language }; try store.save(id) }
            pushKnowledgeWiki(taskID: id)
        case "cards": showKnowledgeCards(taskID: id, language: language)
        default: showProjectIndex(taskID: id)
        }
    }
    private func showProjectIndex(taskID id: String) {
        guard let store = companion?.agentStore, store.task(id) != nil, showKnowledgeCenter(root: "wiki") else { return }
        let manager = AgentKnowledgeWindow(store: store, taskID: id)
        manager.onOpenWiki = { [weak self] in self?.pushKnowledgeWiki(taskID: id) }
        manager.onOpenCards = { [weak self] in self?.showKnowledgeCards(taskID: id) }
        manager.onOpenSource = { [weak self, weak store] url in
            guard let self, let store else { throw PetError("任务窗口已关闭") }
            let files = try AgentFiles(workspace: store.task(id)?.workspace), safe = try files.resolve(url.path)
            guard !AgentFiles.sensitive(files.relative(safe)) else { throw PetError("不能打开受保护的来源") }
            let text = try files.read(safe.path, offset: 1, limit: 10_000)
            knowledgePageHost.push(AgentKnowledgeSourcePage(title: files.relative(safe), text: text, file: safe))
        }
        knowledgeWindow = manager; knowledgePageHost.push(manager)
    }
    private func pushKnowledgeWiki(taskID id: String) {
        guard let store = companion?.agentStore, showKnowledgeCenter(root: "wiki") else { return }
        let manager = preparedRecord(store: store, taskID: id, section: 6, wikiOnly: true)
        manager.window?.title = (store.task(id)?.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "项目") + " · Repo Wiki"
        knowledgePageHost.push(manager)
    }
    internal func showKnowledgeCards(taskID: String, language: String? = nil) {
        guard let store = companion?.agentStore, store.task(taskID)?.workspace != nil, showKnowledgeCenter(root: "wiki") else { return }
        if let language, let workspace = store.task(taskID)?.workspace {
            do { var options = try store.knowledgeCards.options(workspace: workspace); if options.language != language { options.language = language; try store.knowledgeCards.setOptions(options, workspace: workspace, expected: store.knowledgeCards.settings().1) } }
            catch { setStatus(error.localizedDescription, error: true); return }
        }
        let manager = AgentKnowledgeCardWindow(store: store, taskID: taskID)
        manager.onOpenTask = { [weak self] id in self?.showAgentTask(id); self?.show(tab: "chat") }
        knowledgeCardWindow = manager; knowledgePageHost.push(manager)
    }
    internal func refreshKnowledgeCards(workspace: String) {
        knowledgePageHost.controllers.compactMap { $0 as? AgentKnowledgeCardWindow }.forEach { $0.refresh(workspace: workspace) }; scheduleRender()
    }
    @objc internal func showKnowledgeLibrary() { _ = showKnowledgeCenter(root: "library") }
    @objc func openAgentMemory() { companion?.ensureAgent(); showSettingsCategory("memory") }
    @objc func openAttentionSettings() { showSettingsCategory("attention") }
    internal func openAgentRecordItem(section: Int, value: String, location: AgentArtifactLocation? = nil) {
        if section == 1 {
            if value.hasPrefix("canvas://"), let id = agentTaskID { openCanvasReference(value, taskID: id, location: location) }
            else { showTaskDocument(value, location: location ?? companion?.generalSettings.settings.artifactLocation ?? .workspace) }
            return
        }
        presentAgentRecords(section: section)
        if section == 6 { (knowledgePageHost.currentController as? AgentRecordWindow)?.selectItem(section: section, value: value) }
        else { (taskWorkspace.rootController(.records) as? AgentRecordWindow)?.selectItem(section: section, value: value) }
    }
    internal func presentAgentRecords(section: Int, taskID: String? = nil) {
        guard let store = companion?.agentStore, let id = taskID ?? agentTaskID else { return }
        if section == 6 { pushKnowledgeWiki(taskID: id); return }
        if agentTaskID != id { selectAgentTask(id) }
        guard agentTaskID == id, saveAgentDraft() else { return }
        if selectedTab != "chat" { guard canLeaveMainPage() else { return }; show(tab: "chat") }
        guard taskWorkspace.show(taskID: id, root: .records, make: { preparedRecord(store: store, taskID: id, section: section, taskHosted: true) }) else { return }
        (taskWorkspace.rootController(.records) as? AgentRecordWindow)?.selectSection(section)
        updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    internal func showTaskDocument(_ path: String, location: AgentArtifactLocation = .workspace) {
        guard window?.attachedSheet == nil, let store = companion?.agentStore, let id = agentTaskID, let task = store.task(id), saveAgentDraft() else { return }
        if AgentOffice.supports(path) {
            Task { @MainActor [weak self] in do { _ = try await store.offices.show(path, taskID: id, location: location) } catch { self?.setStatus(error.localizedDescription, error: true) } }; return
        }
        do {
            let (files,file) = try AgentWorkspaceScope.location(task,path:path)
            guard !AgentFiles.sensitive(files.relative(file)) else { throw PetError("不能打开受保护的文件") }
            let key = AgentTaskWorkspace.Root.document(file.path)
            let existing = taskWorkspace.rootController(key) as? AgentRecordWindow ?? (taskWorkspace.controllers.compactMap { $0 as? AgentRecordWindow } + artifactDocuments).first { $0.belongsToTasks([id]) && $0.workspaceDocumentURL?.path == file.path }
            if existing == nil {
                if AgentVideoSnapshot.supports(file) { guard try files.entryMetadata(file).kind == "file" else { throw PetError("视频不存在或不是普通文件") } }
                else { _ = try files.readData(file, maximum: 2_000_000) }
            }
            if let existing, !(try existing.openWorkspaceDocument(file.path)) { return }
            if location == .window {
                let editor = existing ?? preparedRecord(store: store, taskID: id, section: 1, taskHosted: true, documentOnly: true)
                if existing == nil { _ = try editor.openWorkspaceDocument(file.path) }
                try presentArtifactWindow(editor, taskID: id)
                if !artifactDocuments.contains(where: { $0 === editor }) { artifactDocuments.append(editor) }
                editor.onWindowClose = { [weak self, weak editor] in self?.artifactDocuments.removeAll { $0 === editor } }
                return
            }
            if selectedTab != "chat" { guard canLeaveMainPage() else { return }; show(tab: "chat") }
            let root = existing.flatMap { taskWorkspace.root(for: $0, taskID: id) } ?? key
            guard taskWorkspace.show(taskID: id, root: root, make: { existing ?? preparedRecord(store: store, taskID: id, section: 1, taskHosted: true, documentOnly: true) }), let editor = taskWorkspace.rootController(root) as? AgentRecordWindow else { return }
            artifactDocuments.removeAll { $0 === editor }; editor.onWindowClose = nil; editor.window?.orderOut(nil)
            if existing == nil { _ = try editor.openWorkspaceDocument(file.path) }
            updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    private func chooseTaskDocument() {
        guard let window, window.attachedSheet == nil, let task = currentAgentTask else { return }
        do {
            let files = try AgentFiles(workspace: task.workspace), panel = NSOpenPanel(), id = task.id
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.directoryURL = files.root
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if AgentTaskWorkspace.readbackEnabled { self.taskDocumentOpenState = ["accepted": response == .OK, "file": panel.url?.path ?? "", "sheetAttachedAtCompletion": window.attachedSheet != nil] }
                guard response == .OK, let file = panel.url else { return }
                // AppKit finishes detaching the sheet after its completion block.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.agentTaskID == id else { return }
                    if AgentTaskWorkspace.readbackEnabled { self.taskDocumentOpenState["sheetAttachedBeforeOpening"] = window.attachedSheet != nil }
                    self.showTaskDocument(file.path)
                }
            }
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    private func preparedRecord(store: AgentStore, taskID id: String, section: Int, wikiOnly: Bool = false, taskHosted: Bool = false, documentOnly: Bool = false) -> AgentRecordWindow {
        let record = AgentRecordWindow(store: store, taskID: id, section: section, wikiOnly: wikiOnly, taskHosted: taskHosted, documentOnly: documentOnly)
        record.onAddSelection = { [weak self] selection in
            guard let self else { throw PetError("任务窗口已关闭") }; try self.addDocumentSelection(selection, taskID: id)
        }
        if taskHosted {
            record.onOpenVideo = { [weak self] file in
                guard let self, self.agentTaskID == id else { throw PetError("请在原任务打开视频") }; self.showTaskDocument(file.path)
            }
            record.onChooseWorkspaceFile = { [weak self] in guard let self, self.agentTaskID == id else { return }; self.chooseTaskDocument() }
        }
        record.enableWikiGeneration { [weak self] language in self?.generateAgentWiki(sourceID: id, language: language) }
        record.onOpenKnowledgeCards = { [weak self] language in self?.showKnowledgeCards(taskID: id, language: language) }
        if let runtime = companion?.agentRuntime { record.configureWikiRuntime(runtime) { [weak self] taskID in self?.selectAgentTask(taskID); self?.show(tab: "chat") } }
        return record
    }
    internal func presentOfficeWorkspace(_ editor: AgentOfficeWindow) throws {
        guard saveAgentDraft(), canLeaveMainPage() else { throw PetError("请先完成当前操作") }
        if agentTaskID != editor.taskID { selectAgentTask(editor.taskID) }
        guard agentTaskID == editor.taskID else { throw PetError("办公文件所属任务未打开") }
        show(tab: "chat")
        guard taskWorkspace.show(taskID: editor.taskID, root: .document(editor.file.path), make: { editor }) else { throw PetError("请先完成当前工作区操作") }
        editor.window?.orderOut(nil)
        updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    internal func presentBrowserWorkspace(_ browser: AgentBrowserWindow) throws {
        guard saveAgentDraft(), canLeaveMainPage() else { throw PetError("请先完成当前操作") }
        if agentTaskID != browser.taskID { selectAgentTask(browser.taskID) }
        guard agentTaskID == browser.taskID else { throw PetError("浏览器所属任务未打开") }
        show(tab: "chat")
        guard taskWorkspace.show(taskID: browser.taskID, root: .browser, make: { browser }) else { throw PetError("请先完成当前工作区操作") }
        updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    internal func detachBrowserWorkspace(_ browser: AgentBrowserWindow) throws {
        guard taskWorkspace.detachBrowser(browser) else { throw PetError("请先返回浏览器并完成当前操作") }
    }
    internal func presentCanvasWorkspace(_ editor: AgentCanvasWindow, id: String) throws {
        guard saveAgentDraft(), canLeaveMainPage() else { throw PetError("请先完成当前操作") }
        if agentTaskID != editor.taskID { selectAgentTask(editor.taskID) }
        guard agentTaskID == editor.taskID else { throw PetError("画布所属任务未打开") }
        show(tab: "chat")
        guard taskWorkspace.show(taskID: editor.taskID, root: .canvas(id), make: { editor }) else { throw PetError("请先完成当前工作区操作") }
        editor.window?.orderOut(nil)
        updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    internal func presentArtifactWindow(_ editor: AgentSettingsPageController, taskID: String) throws {
        guard saveAgentDraft(), window?.attachedSheet == nil else { throw PetError("请先完成当前操作") }
        if let host = editor.settingsHostWindow {
            guard host === window, taskWorkspace.detach(editor, taskID: taskID) else { throw PetError("请先返回文件并完成当前操作，再切换打开位置") }
        }
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
    }
    func addDocumentSelection(_ selection: AgentMarkdownSelection, taskID: String) throws {
        guard let store = companion?.agentStore, let task = store.task(taskID), !task.archived, task.kind != "hook", !task.isProjectDocumentation,
              task.agent?.ownerID == nil, task.automation == nil else { throw PetError("此任务不能接收选文") }
        let files = try AgentWorkspaceScope.files(task,path:selection.file.path), selectedFiles = try AgentFiles(workspace:selection.workspace)
        guard files.root == selectedFiles.root, selection.text.utf8.count <= 16_384, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PetError("文档所属工作区已改变，或选文超过 16KB") }
        let safe = try files.resolve(selection.file.path)
        guard !AgentFiles.sensitive(files.relative(safe)) else { throw PetError("不能加入受保护文件的内容") }
        guard saveAgentDraft(), companion?.persistTaskDrafts(taskID) != false else { throw PetError("请先保存此任务的草稿") }
        if let displayedTask { try store.save(displayedTask) }
        guard let previous = store.task(taskID) else { throw PetError("任务已关闭") }
        let draft = previous.draft ?? "", combined = draft + (draft.isEmpty ? "" : "\n\n") + selection.draftText
        guard combined.utf8.count <= 100_000 else { throw PetError("草稿超过 100KB，请先缩减草稿") }
        store.update(taskID, persist: false) { $0.draft = combined }
        do { try store.save(taskID) }
        catch { store.update(taskID, persist: false) { $0.draft = previous.draft }; throw error }
        if displayedTask == taskID { composer.string = combined }
        selectAgentTask(taskID); show(tab: "chat"); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(composer)
    }
    func generateAgentWiki(sourceID: String, language: String? = nil) {
        guard let store = companion?.agentStore, let runtime = companion?.agentRuntime else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let id = try await store.projectKnowledge.start(sourceID: sourceID, language: language ?? store.task(sourceID)?.wikiLanguage ?? "zh", runtime: runtime)
                recordWindow?.window?.close(); knowledgeWindow?.window?.close(); selectAgentTask(id)
            } catch { setStatus(error.localizedDescription, error: true) }
        }
    }
    func configureApprovalPanel() {
        approvalPanel.orientation = .vertical; approvalPanel.alignment = .leading; approvalPanel.spacing = 7; approvalPanel.isHidden = true
        approvalTitle.font = .systemFont(ofSize: 12, weight: .medium); approvalTitle.textColor = .systemOrange; approvalTitle.lineBreakMode = .byTruncatingTail
        approvalText.isEditable = false; approvalText.isRichText = false; approvalText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        approvalText.setAccessibilityLabel("待处理请求详情")
        approvalText.isVerticallyResizable = true; approvalText.autoresizingMask = [.width]; approvalText.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = approvalText; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        approveButton.target = self; approveButton.action = #selector(allowAgentAction)
        denyButton.target = self; denyButton.action = #selector(denyAgentAction)
        let actions = stack([NSView(), denyButton, approveButton], spacing: 8)
        for view in [approvalTitle, scroll, actions] { approvalPanel.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: approvalPanel.widthAnchor).isActive = true }
    }
    internal func questionFocused(_ id: String) -> Bool {
        if selectedTab == "attention" { return attentionPageController?.questionFocused(id) == true }
        return hasTaskFocus && (agentTaskID == id || visibleApproval?.task == id)
    }
    internal func questionInteraction(_ event: NSEvent) -> String? {
        if selectedTab == "attention" { return attentionPageController?.questionInteraction(event) }
        guard selectedTab == "chat", event.window === window, !approvalPanel.isHidden, let pair = visibleApproval,
              companion?.agentStore?.task(pair.task)?.pendingCalls.first?.name == "ask_user" else { return nil }
        let views: [NSView] = [approvalPanel, composer.enclosingScrollView?.superview, entryToolbar, attachmentButton, draftAttachments].compactMap { $0 }
        return AgentQuestionAutoSkip.containsInteraction(event, views: views) ? pair.task : nil
    }
    @objc func allowAgentAction() { if let pair = visibleApproval { companion?.agentRuntime?.decide(taskID: pair.task, callID: pair.call, decision: "allow") } }
    @objc func denyAgentAction() { if let pair = visibleApproval { companion?.agentRuntime?.decide(taskID: pair.task, callID: pair.call, decision: "deny") } }
    @objc private func showMCPUserInput() {
        guard let window, window.attachedSheet == nil, let id = agentTaskID,
              let inputs = companion?.agentStore?.mcp.userInputs, let request = inputs.first(taskID: id) else { return }
        let panel = AgentMCPUserInputPanel(request: request, inputs: inputs)
        mcpInputPanel = panel
        panel.onClose = { [weak self, weak panel] in if self?.mcpInputPanel === panel { self?.mcpInputPanel = nil } }
        panel.present(in: window)
    }
    internal func presentRoundRollback(taskID: String, messageID: String) {
        guard agentTaskID == taskID, let store = companion?.agentStore, saveAgentDraft() else { return }
        if selectedTab != "chat" { guard canLeaveMainPage() else { return }; show(tab: "chat") }
        let root = AgentTaskWorkspace.Root.rollback(messageID), panel = taskWorkspace.rootController(.rollback(messageID)) as? AgentRoundRollbackWindow ?? AgentRoundRollbackWindow(store: store, taskID: taskID, messageID: messageID)
        panel.beforeApply = { [weak self, weak panel] in guard let companion = self?.companion, let panel else { throw PetError("所属任务窗口已关闭") }; try companion.requireTaskDeletionAllowed([taskID], ignoring: panel) }
        panel.onComplete = { [weak self] in self?.renderAgentMessages() }
        taskWorkspace.show(taskID: taskID, root: root) { panel }; updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded(); focusTaskInput()
    }
    internal func presentEditResend(taskID: String, messageID: String) {
        guard agentTaskID == taskID, let store = companion?.agentStore, let runtime = companion?.agentRuntime, saveAgentDraft() else { return }
        if selectedTab != "chat" { guard canLeaveMainPage() else { return }; show(tab: "chat") }
        do {
            let root = AgentTaskWorkspace.Root.editResend(messageID), panel = try taskWorkspace.rootController(.editResend(messageID)) as? AgentEditResendWindow ?? AgentEditResendWindow(store: store, runtime: runtime, taskID: taskID, messageID: messageID)
            panel.beforeApply = { [weak self, weak panel] in guard let companion = self?.companion, let panel else { throw PetError("所属任务窗口已关闭") }; try companion.requireTaskDeletionAllowed([taskID], ignoring: panel) }
            panel.onSent = { [weak self] id in self?.selectAgentTask(id) }
            taskWorkspace.show(taskID: taskID, root: root) { panel }; updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded(); focusTaskInput()
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    private func replyAction(_ action: String, taskID: String, messageID: String, hash: String) -> Bool {
        guard agentTaskID == taskID, let tasks = companion?.agentStore else { return false }
        do {
            let message = try tasks.replyMessage(taskID: taskID, messageID: messageID, expectedHash: hash, allowStreaming: action == "copy")
            if action == "copy" {
                NSPasteboard.general.clearContents(); guard NSPasteboard.general.setString(message.content, forType: .string) else { throw PetError("回复未能复制，请重试") }; return true
            }
            if action == "branch" {
                guard saveAgentDraft() else { return false }
                guard let id = tasks.fork(taskID, through: messageID, expectedHash: hash) else { throw PetError(tasks.writeError ?? "分支未创建") }
                selectAgentTask(id); return true
            }
            let previous = tasks.organization.replyFeedback(taskID: taskID, message: message)
            try tasks.setReplyFeedback(taskID: taskID, messageID: messageID, expectedHash: hash, value: previous == action ? nil : action)
            renderAgentMessages(); return true
        } catch { renderAgentMessages(); setStatus(error.localizedDescription, error: true); return false }
    }
    @discardableResult internal func usePromptSuggestion(_ text: String, taskID: String, source: String) -> Bool {
        guard agentTaskID == taskID, let task = currentAgentTask, let runtime = companion?.agentRuntime,
              !runtime.isBusy(taskID), AgentPromptSuggestions.source(task) == source, runtime.promptSuggestions.items(task).contains(text), composer.isEditable else { return false }
        let suffix = (composer.string.isEmpty || composer.string.hasSuffix("\n") ? "" : "\n") + text
        let input = NSAttributedString(string: suffix, attributes: [.font: AgentContentAppearance.font(size: AgentAppearance.messageSize), .foregroundColor: composer.textColor ?? .textColor])
        composer.insertText(input, replacementRange: NSRange(location: (composer.string as NSString).length, length: 0))
        composer.didChangeText(); composerChanged(); _ = saveAgentDraft(); window?.makeFirstResponder(composer)
        let end = NSRange(location: (composer.string as NSString).length, length: 0)
        composer.setSelectedRange(end); composer.scrollRangeToVisible(end); return true
    }
    internal func promptSuggestionsReadback() -> [String: Any] {
        guard let task = currentAgentTask, let service = companion?.agentRuntime?.promptSuggestions else { return [:] }
        var result: [String: Any] = ["taskID": task.id, "items": service.items(task), "generating": service.isGenerating(task.id), "error": service.error(task) ?? "", "draft": composer.string, "caretAtEnd": composer.selectedRange() == NSRange(location: (composer.string as NSString).length, length: 0), "rowVisible": messageColumn.arrangedSubviews.contains { $0.identifier?.rawValue == "prompt-suggestions-row" }]
        if CommandLine.arguments.contains("--prompt-suggestions-check") || CommandLine.arguments.contains("--manual-ui"), let storage = composer.textStorage, let layout = composer.layoutManager, let container = composer.textContainer {
            layout.ensureLayout(for: container)
            var fonts = Set<String>(), advances: [CGFloat] = []
            let text = storage.string as NSString
            for i in 0..<text.length where text.character(at: i) == 32 {
                if let font = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont { fonts.insert(font.fontName) }
                guard i + 1 < text.length else { continue }
                let a = layout.glyphIndexForCharacter(at: i), b = layout.glyphIndexForCharacter(at: i + 1)
                let first = layout.lineFragmentRect(forGlyphAt: a, effectiveRange: nil), next = layout.lineFragmentRect(forGlyphAt: b, effectiveRange: nil)
                if first.minY == next.minY { advances.append(layout.location(forGlyphAt: b).x - layout.location(forGlyphAt: a).x) }
            }
            result["spaceFonts"] = fonts.sorted(); result["spaceAdvances"] = advances
            result["expectedSpaceAdvance"] = (" " as NSString).size(withAttributes: [.font: AgentContentAppearance.font(size: AgentAppearance.messageSize)]).width
        }
        return result
    }
    func renderAgentMessages() {
        guard let tasks = companion?.agentStore else { return }
        if closingSideTask { finishClosingSideTask(); return }
        if let id = sideTaskTabID, tasks.task(id) == nil { sideTaskTabID = nil; window?.close(); return }
        let keepSearchHitVisible = isMessageSearchVisible
        guard tasks.refreshDeletedRecords() else { composer.isEditable = false; sendButton.isEnabled = false; setStatus(tasks.deletions.issue ?? "永久删除记录无法读取，请检查配置并重新打开应用", error: true); return }
        guard let task = currentAgentTask else {
            let id = tasks.tasks.first(where: { !$0.archived && $0.sideTask == nil && $0.organizationMode == displayedWorkMode })?.id ?? tasks.create(workMode: displayedWorkMode)
            selectAgentTask(id); return
        }
        bindAgentDraft(task)
        window?.title = (task.sideTask != nil && task.title == "新的任务" ? "新的侧任务" : task.title) + " · 小鲸" + (taskWindowNumber == 1 ? "" : "（\(taskWindowNumber)）")
        if contextWindow?.window?.isVisible == true { contextWindow?.refresh() }
        taskWorkspace.controllers.compactMap { $0 as? AgentContextWindow }.filter(\.isPageVisible).forEach { $0.refresh() }
        if taskModelWindow?.window?.isVisible == true { taskModelWindow?.refreshState() }
        recordWindow?.refreshLiveRecords(task.id)
        for record in artifactDocuments { record.refreshLiveRecords(task.id) }
        taskWorkspace.controllers.compactMap { $0 as? AgentRecordWindow }.forEach { $0.refreshLiveRecords(task.id) }
        knowledgePageHost.controllers.compactMap { $0 as? AgentRecordWindow }.forEach { $0.refreshLiveRecords(task.id) }
        repoWikiWindow?.refreshLiveState()
        archivedTasksView?.refresh()
        refreshAutomationBadge()
        if displayedTask != task.id { selectAgentTask(task.id); return }
        let taskView = tasks.organization.taskView(task.organizationMode)
        let listing = taskView.grouping != .workspace || taskView.activity != .all ? tasks.taskViewMetadata() : tasks.tasks
        var hidden = Set(listing.filter { !tasks.sideTasks.sidebarVisible($0) }.map(\.id)), previous = Set<String>()
        while previous != hidden { previous = hidden; for item in listing where item.agent?.ownerID.map(hidden.contains) == true || item.kind == "hook" && item.parentID.map(hidden.contains) == true { hidden.insert(item.id) } }
        let sidebarSelection = task.sideTask.flatMap { side in tasks.tasks.contains { $0.id == side.parentID && !$0.archived } ? side.parentID : nil } ?? task.id
        taskSidebar.refresh(listing.filter { !hidden.contains($0.id) }, selected: sidebarSelection, organization: tasks.organization, searchRevision: tasks.taskSearchRevision)
        if selectedTab == "chat" { pageTitle.stringValue = task.title }
        projectButton.title = ""; projectButton.imagePosition = .imageOnly; projectButton.toolTip = tasks.organization.name(task.organizationWorkspace, mode: task.organizationMode) ?? "选择" + task.organizationMode.directoryTitle
        if let entry = tasks.organization.entry(task.organizationWorkspace ?? "",mode:task.organizationMode,tasks:tasks.tasks) { projectButton.image = NSImage(systemSymbolName:(entry.icon ?? .folder).rawValue,accessibilityDescription:nil); projectButton.contentTintColor = (entry.color ?? .forest).nsColor } else { projectButton.image = NSImage(systemSymbolName:"folder",accessibilityDescription:nil); projectButton.contentTintColor = AgentWorkbenchTheme.secondaryText }
        modePopup.selectItem(at: AgentMode.allCases.firstIndex(of: task.mode) ?? 2)
        permissionPopup.selectItem(at: AgentPermissionMode.allCases.firstIndex(of: task.permission) ?? 1)
        let running = companion?.agentRuntime?.isRunning(task.id) == true
        let managed = task.kind == "hook" || task.isProjectDocumentation, delegated = task.agent?.ownerID != nil || task.automation != nil
        let rollbackBlocked = task.pendingFileRollback != nil || task.workspace.map { tasks.hasFileRollback(in: $0) } == true
        let locked = running || task.status == .waiting || rollbackBlocked
        executionLocation.title = task.worktreeOrigin == nil ? "本地" : "工作树"
        refreshBranch(task)
        executionLocation.toolTip = task.workspace ?? "终端使用当前任务目录"; executionLocation.isEnabled = task.canChooseEnvironment && !running
        for view in [projectButton, modePopup, permissionPopup] as [NSControl] { view.isEnabled = !locked && !task.archived && !managed && !delegated }
        projectButton.isEnabled = (!locked || task.workspace == nil) && !task.archived && !managed && !delegated
        gitButton.isEnabled = task.workspace != nil && !managed
        browserButton.isEnabled = !managed
        resumeButton.isHidden = (managed && task.kind != AgentKnowledgeCards.kind) || running || rollbackBlocked || ![.stopped, .failed, .ready].contains(task.status) || task.messages.isEmpty || task.archived
        resultsButton.title = ""; resultsButton.imagePosition = .imageOnly; resultsButton.toolTip = task.plan.isEmpty ? "任务记录" : "计划 \(task.plan.filter { $0.status == "completed" }.count)/\(task.plan.count)"
        resultsButton.isEnabled = !task.events.isEmpty || !task.artifacts.isEmpty || !(task.canvases ?? []).isEmpty || !task.plan.isEmpty
        renderDraftAttachments(task); setBusy(running); clearButton.title = task.archived ? "恢复任务" : "归档任务"
        composer.isEditable = !managed; attachmentButton.isEnabled = !managed
        let queueCount = task.queuedCount
        let state = tasks.writeError ?? (task.status == .failed ? task.events.last(where: { $0.status == "failed" })?.detail ?? "执行失败" : managed && task.status == .completed ? task.statusTitle : locked ? (running && task.status == .ready ? "排队中" : task.status.title) + (queueCount > 0 ? " · \(queueCount) 条补充待处理" : "") : "")
        setStatus(task.status == .failed || tasks.writeError != nil || queueCount > 0 ? state : tasks.hooks.backgroundTitle(task.id) ?? "", error: task.status == .failed || tasks.writeError != nil || (managed && task.statusTitle == "校验未通过"))
        if rollbackBlocked { clearButton.isEnabled = false; setStatus(task.pendingFileRollback == nil ? "此项目有未完成的文件撤回，请在所属任务恢复" : "文件撤回未完成，请从任务操作恢复撤回前文件", error: true) }
        let context = task.contextSize.map { used in " · 上下文 ~\(used) / \(companion?.store.preferences.contextLimit ?? 8192)" } ?? ""
        modelCaption.stringValue = task.agent.map { $0.profile.name + context } ?? (context.hasPrefix(" · ") ? String(context.dropFirst(3)) : context)
        modelCaption.isHidden = true
        updateWorkbenchLayout()
        var follow = messageSearch == nil && taskFind.isHidden && (renderedIDs.isEmpty || history.contentView.bounds.maxY >= (history.documentView?.bounds.height ?? 0) - 65)
        let messages = task.messages.filter { ["user", "assistant"].contains($0.role) && $0.nativeContext != true }
        let display = companion?.generalSettings.settings.conversationDisplay ?? .init()
        let latestHuman = messages.last(where: \.isHumanInput)?.id
        let newInput = readingTaskID == task.id && latestHuman != lastHumanMessageID && latestHuman != nil
        if readingTaskID != task.id { readingAnchorID = nil; readingSpace?.constant = 0 }
        if newInput { readingAnchorID = display.readingStart ? latestHuman : nil; follow = !display.readingStart }
        readingTaskID = task.id; lastHumanMessageID = latestHuman
        if !display.readingStart || messageSearch != nil || !taskFind.isHidden { readingAnchorID = nil; readingSpace?.constant = 0 }
        let processes = AgentConversationDisplay.processes(task)
        let processOwner = Dictionary(processes.flatMap { process in process.messageIDs.map { ($0, process.replyID) } }, uniquingKeysWith: { _, latest in latest })
        let processStarts = Dictionary(processes.compactMap { process in process.messageIDs.first.map { ($0, process) } }, uniquingKeysWith: { _, latest in latest })
        let fileRollbackMessages = AgentRoundRollback.availableMessages(task)
        let fileMap = Dictionary((task.attachments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let snapshotCalls = Set(task.messages.flatMap { $0.toolCalls ?? [] }.filter { $0.name == "canvas_screenshot" }.suffix(4).map(\.id))
        var inlineSnapshots: [String: AgentAttachment] = [:]
        for result in task.messages where result.role == "tool" {
            if let callID = result.toolCallID, snapshotCalls.contains(callID), let file = result.visuals?.compactMap({ fileMap[$0.id] }).first(where: { $0.canvasCapture != nil }) { inlineSnapshots[callID] = file }
        }
        var ids: [String] = []
        let agentDrafts = Array((task.agentDrafts ?? []).prefix(8))
        let automationDrafts = Array((task.automationDrafts ?? []).prefix(8))
        let profileDocument = agentDrafts.isEmpty ? nil : try? tasks.agents.document()
        let profiles = profileDocument.flatMap { try? tasks.agents.decode($0.0) } ?? []
        for draft in agentDrafts { ids.append("agent-draft:" + draft.id + ":" + AgentFiles.hash((try? JSONEncoder().encode(draft)) ?? Data()) + ":" + (profileDocument?.1 ?? "missing") + ":" + String(task.archived)) }
        for draft in automationDrafts {
            let saved = tasks.automations.values.first { $0.id == draft.automation.id }
            ids.append("automation-draft:" + draft.id + ":" + AgentFiles.hash((try? JSONEncoder().encode(draft)) ?? Data()) + ":" + AgentFiles.hash((try? JSONEncoder().encode(saved)) ?? Data()) + ":" + String(task.archived) + ":" + String(tasks.automations.isStarted))
        }
        if task.skillEvolutionJob != nil { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; ids.append("skill-job:" + AgentFiles.hash((try? encoder.encode(task.skillEvolutionJob)) ?? Data()) + ":" + AgentFiles.hash((try? encoder.encode(task.skillDraft)) ?? Data()) + ":" + task.status.rawValue) }
        let thinking = companion?.agentRuntime?.isExecuting(task.id) == true && task.status == .running && companion?.agentRuntime?.pendingReview(task.id) == nil && tasks.mcp.userInputs.first(taskID: task.id) == nil
        let suggestions = companion?.agentRuntime?.promptSuggestions
        let suggestionItems = suggestions?.items(task) ?? [], suggestionError = suggestions?.error(task)
        let suggesting = companion?.generalSettings.settings.promptSuggestions == true && suggestions?.isGenerating(task.id) == true
        if !suggestionItems.isEmpty || suggestionError != nil || suggesting { ids.append("suggestions:" + (AgentPromptSuggestions.source(task) ?? "") + ":" + suggestionItems.joined(separator: "|") + ":" + String(suggesting) + ":" + (suggestionError ?? "")) }
        for message in messages {
            if !message.content.isEmpty || ((message.toolCalls ?? []).isEmpty && task.status == .running && message.id == task.messages.last?.id && !(thinking && message.role == "assistant")) { ids.append(message.id) }
            if message.reasoning?.isEmpty == false { ids.append("reasoning:" + message.id) }
            ids += (message.toolCalls ?? []).filter { $0.name != "load_tools" }.map { "tool:" + $0.id }
        }
        ids += processes.map { "process:" + $0.replyID }
        if task.status == .completed { ids += task.artifacts.prefix(4).map { "artifact:" + $0 }; ids += (task.canvases ?? []).prefix(4).map { "canvas:" + $0.id + $0.hash + tasks.canvases.previewSignature($0, taskID: task.id) } }
        ids += inlineSnapshots.keys.sorted().map { "snapshot:" + $0 + ":" + inlineSnapshots[$0]!.id }
        thinkingIndicator.update(companion?.thinkingStatus.settings ?? .init(), active: thinking)
        if thinking { ids.append("thinking:" + task.id) }
        if ids != renderedIDs {
            for process in processRows.values { process.body.arrangedSubviews.forEach { process.body.removeArrangedSubview($0); $0.removeFromSuperview() } }
            messageColumn.arrangedSubviews.forEach { messageColumn.removeArrangedSubview($0); $0.removeFromSuperview() }
            var next: [String: ChatMessageRow] = [:], nextTools: [String: AgentToolRow] = [:]
            var nextReasoning: [String: ChatMessageRow] = [:], nextProcesses: [String: AgentReplyProcessRow] = [:]
            func append(_ view: NSView, to column: NSStackView) { column.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            var shownCanvases: Set<String> = []
            for message in messages {
                if let process = processStarts[message.id] {
                    let row = processRows[process.replyID] ?? AgentReplyProcessRow(); nextProcesses[process.replyID] = row; append(row, to: messageColumn)
                }
                let processID = processOwner[message.id], processBody = processID.flatMap { nextProcesses[$0]?.body } ?? messageColumn
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    let row = reasoningRows[message.id] ?? ChatMessageRow(message: ChatMessage(id: "reasoning-" + message.id, role: "assistant", content: reasoning), workbench: true, reasoning: true)
                    nextReasoning[message.id] = row; row.fit(width: history.contentView.bounds.width - 40); append(row, to: processBody)
                }
                if ids.contains(message.id) {
                    let row = messageRows[message.id] ?? ChatMessageRow(message: ChatMessage(id: message.id, role: message.role, content: message.content), workbench: true); next[message.id] = row
                    row.fit(width: history.contentView.bounds.width - 40); append(row, to: processID == message.id ? messageColumn : processBody)
                }
                for call in (message.toolCalls ?? []).filter({ $0.name != "load_tools" }) {
                    let row = toolRows[call.id] ?? AgentToolRow(); row.useWorkbenchStyle(); nextTools[call.id] = row
                    append(row, to: processBody); processBody.setCustomSpacing(8, after: row)
                    if let file = inlineSnapshots[call.id], let capture = file.canvasCapture {
                        let image = AgentCanvas.capturePreviewImage(file, store: tasks, taskID: task.id)
                        if image != nil { shownCanvases.insert(capture.canvasID + capture.sourceHash) }
                        let record = AgentCanvasRecord(id: capture.canvasID, title: capture.title, hash: capture.sourceHash)
                        let snapshot = AgentCanvasPreviewRow(record: record, image: image, actionTitle: "查看快照")
                        snapshot.onOpen = { [weak self] in guard self?.agentTaskID == task.id else { return }; self?.openAttachment(taskID: task.id, id: file.id) }
                        append(snapshot, to: processBody)
                    }
                }
            }
            if thinking { append(thinkingIndicator, to: messageColumn) }
            if let job = task.skillEvolutionJob {
                var issue: String?, ready = false
                if task.skillDraft?.savedAt == nil, task.status != .running {
                    do { _ = try AgentSkillDrafts.job(task,store:tasks); if let draft = task.skillDraft { _ = try AgentSkillDrafts.proposed(draft,job:job,store:tasks); ready = true } }
                    catch { issue = error.localizedDescription }
                }
                let row = AgentSkillJobRow(task:task,ready:ready,issue:issue)
                let plan = AgentSkillDrafts.planSource(task)
                row.onConfirm = { [weak self] in guard let source = plan else { return }; do { try self?.confirmSkillPlan(taskID:task.id,source:source) } catch { self?.setStatus(error.localizedDescription,error:true) } }
                row.onReview = { [weak self] in do { try self?.reviewSkillDraft(taskID:task.id) } catch { self?.setStatus(error.localizedDescription,error:true) } }
                row.onOpen = { [weak self] in do { try self?.openSavedSkill(taskID:task.id) } catch { self?.setStatus(error.localizedDescription,error:true) } }
                row.onSource = { [weak self] in guard let self, agentTaskID == task.id, tasks.tasks.contains(where:{$0.id == job.sourceTaskID}) else { return }; selectAgentTask(job.sourceTaskID) }
                append(row,to:messageColumn)
            }
            if !suggestionItems.isEmpty || suggestionError != nil || suggesting {
                let source = AgentPromptSuggestions.source(task) ?? ""
                let row = AgentPromptSuggestionsRow(items: suggestionItems, generating: suggesting, error: suggestionError, choose: { [weak self] text in _ = self?.usePromptSuggestion(text, taskID: task.id, source: source) }, retry: { [weak self] in self?.companion?.agentRuntime?.retryPromptSuggestions(task.id) })
                append(row, to: messageColumn)
            }
            for draft in agentDrafts {
                let saved = draft.savedAt != nil || profiles.contains { $0.id == draft.profile.id }
                let issue: String?
                if draft.taskID != task.id { issue = "原任务的 Agent 草稿" }
                else if profileDocument == nil { issue = "Agent 配置无法读取" }
                else { do { _ = try AgentProfileDrafts.checked(draft, taskID: task.id, agents: tasks.agents); issue = task.archived ? "请先恢复原任务" : nil } catch { issue = "Agent 草稿无法读取" } }
                let row = AgentProfileDraftRow(draft, saved: saved, available: profiles.contains { $0.id == draft.profile.id }, issue: issue)
                row.onConfigure = { [weak self] in do { try self?.configureAgentProfileDraft(draft.id, taskID: task.id) } catch { self?.setStatus(error.localizedDescription, error: true) } }
                messageColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
            }
            for draft in automationDrafts {
                let issue: String?
                if draft.taskID != task.id { issue = "原任务的自动化草稿" }
                else if !tasks.automations.isStarted { issue = "自动化调度未启动" }
                else { do { _ = try AgentAutomationDrafts.checked(draft, taskID: task.id, service: tasks.automations); issue = task.archived ? "请先恢复原任务" : nil } catch { issue = "自动化草稿无法读取" } }
                let row = AgentAutomationDraftRow(draft, saved: tasks.automations.values.first { $0.id == draft.automation.id }, issue: issue)
                row.onConfigure = { [weak self] in do { try self?.configureAutomationDraft(draft.id, taskID: task.id) } catch { self?.setStatus(error.localizedDescription, error: true) } }
                messageColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
            }
            if task.status == .completed {
                for path in task.artifacts.prefix(4) {
                    let row = AgentInspectorFileButton(title: URL(fileURLWithPath: path).lastPathComponent, value: path, section: 1, symbol: "doc", inline: true)
                    row.onOpen = { [weak self] section, value in guard self?.agentTaskID == task.id else { return }; self?.openAgentRecordItem(section: section, value: value) }
                    row.onOpenIn = { [weak self] location in guard self?.agentTaskID == task.id else { return }; self?.openAgentRecordItem(section: 1, value: path, location: location) }
                    messageColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
                }
                for canvas in (task.canvases ?? []).prefix(4) {
                    let row = AgentCanvasPreviewRow(record: canvas, image: shownCanvases.contains(canvas.id + canvas.hash) ? nil : tasks.canvases.previewImage(canvas, taskID: task.id))
                    row.onOpen = { [weak self] in guard self?.agentTaskID == task.id else { return }; self?.openCanvasReference(canvas.reference, taskID: task.id) }
                    row.onOpenIn = { [weak self] location in guard self?.agentTaskID == task.id else { return }; self?.openCanvasReference(canvas.reference, taskID: task.id, location: location) }
                    messageColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
                }
            }
            messageRows = next; toolRows = nextTools; reasoningRows = nextReasoning; processRows = nextProcesses; renderedIDs = ids
        }
        let events = Dictionary(task.events.compactMap { event in event.toolCallID.map { ($0, event) } }, uniquingKeysWith: { _, latest in latest })
        let responses = Dictionary(task.messages.filter { $0.role == "tool" }.compactMap { message in message.toolCallID.map { ($0, message.content) } }, uniquingKeysWith: { _, latest in latest })
        for process in processes {
            processRows[process.replyID]?.update(collapsed: display.collapseProcess, toolCount: process.toolCount, showCount: display.toolCount)
            if let search = messageSearch, search.taskID == task.id, process.messageIDs.contains(search.messageID) { processRows[process.replyID]?.setExpanded(true) }
        }
        let owner = task.id
        for message in messages {
            let streaming = task.status == .running && message.id == task.messages.last?.id && (message.toolCalls ?? []).isEmpty
            let search = messageSearch?.taskID == task.id && messageSearch?.messageID == message.id ? messageSearch : nil
            messageRows[message.id]?.update(message.content, markdown: !streaming, searchQuery: search?.query, searchDisplayRange: search?.displayRange, searchDisplayText: search?.displayText)
            reasoningRows[message.id]?.update(message.reasoning ?? "", markdown: false)
            messageRows[message.id]?.setAttachments((message.attachmentIDs ?? []).compactMap { fileMap[$0] }, onOpen: { [weak self] id in self?.openAttachment(taskID: owner, id: id) })
            if let row = messageRows[message.id] {
                let eligible = message.isReply, hash = AgentFiles.hash(Data(message.content.utf8))
                row.setDuration(eligible && !streaming ? display.durationFormat.text(message.duration) : nil)
                let canBranch = eligible && !running && task.pendingFileCapture == nil && task.pendingFileRollback == nil && !task.isProjectDocumentation && task.kind != "hook" && tasks.organization.archiveID(task.organizationWorkspace, mode: task.organizationMode) == nil
                row.setReplyActions(binding: eligible ? owner + ":" + message.id + ":" + hash : nil, feedback: tasks.organization.replyFeedback(taskID: owner, message: message), canFeedback: eligible && !streaming, canBranch: canBranch,
                    copy: { [weak self] in self?.replyAction("copy", taskID: owner, messageID: message.id, hash: hash) ?? false },
                    mark: { [weak self] value in _ = self?.replyAction(value, taskID: owner, messageID: message.id, hash: hash) },
                    branch: { [weak self] in _ = self?.replyAction("branch", taskID: owner, messageID: message.id, hash: hash) })
                row.setRoundRollback(visible: message.isHumanInput && fileRollbackMessages.contains(message.id), enabled: !running && !task.archived && task.pendingFileCapture == nil && task.pendingCalls.isEmpty, recovery: task.pendingFileRollback != nil,
                    action: { [weak self] in self?.presentRoundRollback(taskID: owner, messageID: message.id) },
                    edit: message.isHumanInput && AgentEditResend.supported(task) ? { [weak self] in self?.presentEditResend(taskID: owner, messageID: message.id) } : nil,
                    canEdit: !running && task.pendingFileCapture == nil && task.pendingFileRollback == nil && task.pendingCalls.isEmpty && task.queuedCount == 0)
            }
            for call in message.toolCalls ?? [] {
                var visibleCall = call
                if call.name == "delegate_task", let child = (events[call.id]?.childTaskID).flatMap({ tasks.task($0) }) { visibleCall.displayName = "委派 · " + (child.team?.team.name ?? child.agent?.profile.name ?? child.title) }
                toolRows[call.id]?.applyDefaultExpanded(display.expandTools)
                toolRows[call.id]?.update(call: visibleCall, event: events[call.id], response: responses[call.id], durationFormat: display.durationFormat)
                let image = task.messages.first(where: { $0.role == "tool" && $0.toolCallID == call.id })?.visuals?.compactMap { fileMap[$0.id] }.first(where: { $0.browserCapture != nil || $0.desktopCapture != nil || $0.canvasCapture != nil })
                toolRows[call.id]?.setCapture(image) { [weak self] in if let image { self?.openAttachment(taskID: owner, id: image.id) } }
                if let childID = events[call.id]?.childTaskID, let child = tasks.task(childID) { toolRows[call.id]?.setSubtask(child) { [weak self] in self?.selectAgentTask(childID) } }
            }
        }
        if let review = companion?.agentRuntime?.pendingReview(task.id), let call = review.pendingCalls.first, let approval = review.approvals.last(where: { $0.call.id == call.id && $0.decision == nil }) {
            if visibleApproval?.task != review.id || visibleApproval?.call != call.id {
                visibleApproval = (review.id, call.id)
                approvalTitle.stringValue = (review.id != task.id ? (review.agent?.profile.name ?? "子任务") + " · " : "") + (call.name == "ask_user" ? "需要补充信息" : approval.reason.components(separatedBy: "\n").first ?? approval.reason)
                let mcpCall = AgentMCP.tools.contains(call.name) || AgentMCP.isModelToolName(call.name)
                let approvalArguments = AgentMCP.tools.contains(call.name) ? call.object["arguments"] as? [String: Any] ?? [:] : call.object
                approvalText.string = (try? JSONSerialization.data(withJSONObject: approvalArguments, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? call.arguments
                if mcpCall { approvalText.string = approval.reason + (approvalArguments.isEmpty ? "" : "\n\n" + approvalText.string) }
                else if AgentBrowser.tools.contains(call.name) { approvalText.string = approval.reason + "\n\n" + approvalText.string }
                if call.name == "git_commit", let diff = review.gitReview, diff.hash == call.object["review_hash"] as? String { approvalText.string += "\n\n" + diff.diff }
                approvalTitle.toolTip = approval.reason
            }
            if call.name == "ask_user" {
                let body = (call.object["question"] as? String ?? approval.reason) + (companion?.agentRuntime?.questionSkipError(review.id).map { "\n\n" + $0 } ?? "")
                if approvalText.string != body { approvalText.string = body }
            }
            approveButton.isHidden = call.name == "ask_user"; approveButton.isEnabled = !review.archived; denyButton.isEnabled = !review.archived; approvalPanel.isHidden = false
        } else { visibleApproval = nil; approvalPanel.isHidden = true }
        let mcpRequest = task.archived ? nil : tasks.mcp.userInputs.first(taskID: task.id)
        mcpInputRow.isHidden = mcpRequest == nil
        if let mcpRequest { mcpInputButton.title = "回答 " + String(mcpRequest.serverName.prefix(32)) }
        if let panel = mcpInputPanel, panel.request.id != mcpRequest?.id { panel.dismiss(); mcpInputPanel = nil }
        composer.isEditable = !task.archived && !managed
        taskFind.update(taskID: task.id, sources: taskFindSources(task))
        window?.contentView?.layoutSubtreeIfNeeded()
        if let anchorID = readingAnchorID, let row = messageRows[anchorID], let document = history.documentView, history.contentView.bounds.height > 0 {
            let y = row.convert(row.bounds, to: document).minY
            let remaining = messageColumn.frame.maxY + 4 - y
            let space = max(0, history.contentView.bounds.height - remaining)
            readingSpace?.constant = space; window?.contentView?.layoutSubtreeIfNeeded()
            if space > 0 {
                history.contentView.scroll(to: NSPoint(x: 0, y: y)); history.reflectScrolledClipView(history.contentView); follow = false
            } else { readingAnchorID = nil; follow = true }
        }
        revealMessageSearch(keepingVisible: keepSearchHitVisible)
        if follow, let document = history.documentView {
            history.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - history.contentView.bounds.height))); history.reflectScrolledClipView(history.contentView)
        }
    }
}

@MainActor extension ControlWindow {
    var isImportingAttachments: Bool { attachmentImport != nil }
    @discardableResult func beginAttachmentImport(_ urls: [URL], store: AgentStore, taskID: String) -> Task<Void, Never>? {
        do {
            guard attachmentImport == nil else { throw PetError("请先等待当前附件添加完成") }
            try AgentAttachments.validateImportFiles(urls, store: store, taskID: taskID)
        } catch { setStatus(error.localizedDescription, error: true); return nil }
        importTaskID = taskID
        let job = Task { @MainActor [weak self] in
            guard let self else { return }; var failure: String?
            do {
                for url in urls {
                    try Task.checkCancellation(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    _ = try await AgentAttachments.importFile(url, store: store, taskID: taskID)
                }
            } catch { failure = Task.isCancelled ? "已取消添加" : error.localizedDescription }
            attachmentImport = nil; importTaskID = nil; renderMessages()
            if let failure { setStatus(failure, error: true) }
        }
        attachmentImport = job; renderMessages(); return job
    }
    @objc private func showWorktrees() {
        showWorktreePolicySettings()
    }
    func showWorktreePolicySettings() { showSettingsCategory("worktrees") }
    @objc func showDesktopSettings() { desktopSettings?.refreshState(); showSettingsCategory("computer") }
    func refreshWorktreeRetention() { worktreePolicyPanel?.refreshState(); if companion?.usesAgent == true { scheduleRender() } }
    func refreshAutomationBadge() { let count = companion?.agentStore?.automations.unreadCount ?? 0; automationButton.title = "自动化" + (count > 0 ? " · \(count)" : "") }
    @objc private func automationDefinitionsChanged() { refreshAutomationBadge(); scheduleRender() }
    @objc private func conversationDisplayChanged() {
        if companion?.generalSettings.settings.conversationDisplay.readingStart != true { readingAnchorID = nil; readingSpace?.constant = 0 }
        scheduleRender()
    }
    @objc private func thinkingStatusChanged() { scheduleRender() }
    @discardableResult func showThinkingStatusSettings() -> Bool {
        guard showSettingsCategory("general"), let panel = generalSettingsPanel else { return false }; panel.showThinking(); return true
    }
    func thinkingStatusReadback() -> [String: Any] {
        ["settingsPageVisible": generalSettingsPanel?.thinkingVisible == true && selectedTab == "settings", "heading": settingsHeading.stringValue, "settings": generalSettingsPanel?.thinkingReadback() ?? [:], "indicator": thinkingIndicator.readback(), "taskID": agentTaskID ?? "", "runtimeExecuting": agentTaskID.map { companion?.agentRuntime?.isExecuting($0) == true } ?? false]
    }
    func checkThinkingMotion(_ reduced: Bool?) { thinkingIndicator.checkMotion(reduced) }
    @discardableResult func showConversationDisplaySettings() -> Bool {
        guard showSettingsCategory("general"), let panel = generalSettingsPanel else { return false }; panel.showConversation(true); return true
    }
    func conversationDisplayReadback() -> [String: Any] {
        let document = history.documentView
        let rows = messageRows.mapValues { row -> [String: Any] in
            ["text": row.text, "visible": !row.isHiddenOrHasHiddenAncestor, "duration": row.visibleDuration ?? "", "frame": NSStringFromRect(document.map { row.convert(row.bounds, to: $0) } ?? .zero)]
        }
        return ["settingsPageVisible": generalSettingsPanel?.conversationVisible == true && selectedTab == "settings", "heading": settingsHeading.stringValue,
                "processes": processRows.mapValues { $0.readback() }, "tools": toolRows.mapValues { $0.readback() }, "messages": rows, "reasoning": reasoningRows.mapValues { $0.text },
                "readingAnchor": readingAnchorID ?? "", "readingSpace": Double(readingSpace?.constant ?? 0), "viewport": NSStringFromRect(history.contentView.bounds), "documentHeight": Double(document?.bounds.height ?? 0),
                "draft": composer.string, "modelRequests": currentAgentTask?.modelReceipts?.count ?? 0]
    }
    func checkConversationDisplay(_ action: String, id: String = "", query: String = "") {
        guard CommandLine.arguments.contains("--conversation-display-check") else { return }
        switch action {
        case "collapseTool": toolRows[id]?.setExpanded(false, animated: false)
        case "expandProcess": processRows[id]?.setExpanded(true)
        case "cancelReading": history.onUserScroll?()
        case "scrollTop": history.contentView.scroll(to: .zero); history.reflectScrolledClipView(history.contentView)
        case "search": if let taskID = agentTaskID { selectAgentTask(taskID, searchQuery: query, messageID: id) }
        default: break
        }
    }
    private func preparedAutomationWindow(_ store: AgentStore) -> AgentAutomationWindow {
        if let existing = automationWindow { return existing }
        let manager = AgentAutomationWindow(store: store)
        manager.onOpen = { [weak self] id in self?.selectAgentTask(id); self?.show(tab: "chat"); self?.refreshAutomationBadge() }
        manager.onRequestNotifications = { [weak self] in guard let self else { throw PetError("应用已关闭") }; return try await self.companion?.automationNotifications.request() ?? false }
        manager.onCreateWithAssistant = { [weak self, weak store] in
            guard let self, let store, saveAgentDraft() else { throw PetError("请先保存当前会话草稿") }
            let id = try AgentAutomationDrafts.createConversation(store: store, sourceID: currentAgentTask?.id)
            selectAgentTask(id); show(tab: "chat"); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(composer)
        }
        automationWindow = manager
        if let host = window, let view = manager.content(in: host) { automationContent.addSubview(view); pin(view, to: automationContent) }
        return manager
    }
    @objc func showAutomations() {
        guard let store = companion?.agentStore, saveAgentDraft() else { return }
        if selectedTab != "automation", !canLeaveMainPage() { return }
        let manager = preparedAutomationWindow(store)
        manager.sourceTaskID = agentTaskID; manager.refresh(); sidebarRequested = true
        show(tab: "automation"); refreshAutomationBadge()
    }
    private func dismissExtensionCandidates() { extensionPickerTask = nil; extensionPanel.parent?.removeChildWindow(extensionPanel); extensionPanel.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { dismissExtensionCandidates(); homeGamesView?.pause() }
    internal func homeGamesReadback() -> [String:Any] { homeGamesView?.readback() ?? [:] }
    private func refreshBranch(_ task: AgentTaskRecord, force: Bool = false) {
        branchControl.isHidden = companion?.modePresentation.settings[task.organizationMode].inputEnvironment != true || task.workspace == nil
        guard !branchControl.isHidden, let tasks = companion?.agentStore, let workspace = task.workspace else { branchTask?.cancel(); branchTask = nil; branchKey = nil; return }
        let key = task.id + "\n" + workspace + "\n" + (task.gitDirectory ?? "")
        guard force || branchKey != key else { return }
        branchKey = key; branchTask?.cancel(); branchControl.title = "分支…"; branchControl.toolTip = workspace
        branchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = try AgentGit.metadata(workspace: workspace)
                guard AgentWorktreeRetention.within(directory.path, workspace) || task.gitDirectory == directory.path else { branchControl.title = "连接分支…"; branchControl.toolTip = "连接共享 Git 元数据后查看分支"; return }
                let git = try AgentGit(store: tasks, taskID: task.id, directory: directory)
                let result = try await git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], maximumOutput: 4096, timeout: 5)
                var fallback = result
                if result.failed { fallback = try await git.run(["rev-parse", "--short", "HEAD"], maximumOutput: 4096, timeout: 5) }
                guard !Task.isCancelled, branchKey == key, agentTaskID == task.id else { return }
                let value = (fallback.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                branchControl.title = fallback.failed || value.isEmpty ? "未提交" : value; branchControl.toolTip = fallback.failed ? "当前仓库尚无提交" : value
                updateWorkbenchLayout()
            } catch {
                guard !Task.isCancelled, branchKey == key else { return }
                branchControl.title = "Git"; branchControl.toolTip = error.localizedDescription
            }
        }
    }
    @objc func showAgentExtensions() { showSettingsCategory("extensions") }
    private func insertExtension(_ item: AgentExtensionItem, taskID: String) throws {
        guard let store = companion?.agentStore, let task = store.task(taskID), !task.archived, task.kind != "hook" else { throw PetError("原任务已归档或为独立校验任务") }
        let current = try store.extensions.item(item.id, task: task)
        guard current.file == item.file, current.sha256 == item.sha256 else { throw PetError("扩展来源已变化，请刷新后重新选择") }
        if current.kind == .skill { try store.agents.checkSkill(current.id, task: task) }
        try insertSlashInvocation(task.workspaceScope == nil ? current.invocation : AgentExtensionSelection.invocation(current), taskID: taskID)
    }
    private func insertSlashInvocation(_ invocation: String, taskID: String) throws {
        guard saveAgentDraft() else { throw PetError("原任务草稿未保存，请重试") }; dismissExtensionCandidates()
        if displayedTask != taskID { selectAgentTask(taskID) }
        guard displayedTask == taskID else { throw PetError("原任务未打开，未添加指令") }
        let previous = composer.string
        if previous.hasPrefix("/"), let first = previous.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first {
            let tail = try AgentMCPSelection.command(previous)?.arguments ?? AgentExtensionSelection.command(previous)?.arguments ?? String(previous.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            composer.string = "/" + invocation + " " + tail
        } else { composer.string = "/" + invocation + " " + previous }
        composer.setSelectedRange(NSRange(location: (composer.string as NSString).length, length: 0)); composer.didChangeText()
        show(tab: "chat"); window?.makeFirstResponder(composer)
    }
    private func selectSlashEntry(_ entry: AgentSlashEntry, taskID: String) throws {
        guard let store = companion?.agentStore, let task = store.task(taskID), displayedTask == taskID, !task.archived, !task.isProjectDocumentation, task.kind != "hook" else { throw PetError("原任务已不可用") }
        switch entry {
        case .item(let item): try insertExtension(item, taskID: taskID)
        case .builtin(let value):
            let current = store.slashMenu.entries([], task: task, idle: companion?.agentRuntime?.isBusy(taskID) == false, canChangeMode: false)
            guard current.contains(where: { $0.id == entry.id }) else { throw PetError("当前任务不能使用此命令") }
            try insertSlashInvocation(value.rawValue, taskID: taskID)
        case .mode(let mode):
            guard modePopup.isEnabled, companion?.agentRuntime?.isBusy(taskID) == false, ![.running, .waiting].contains(task.status), task.automation == nil, task.agent?.ownerID == nil, task.pendingCalls.isEmpty, saveAgentDraft() else { throw PetError("请先处理当前执行或未保存内容，再切换模式") }
            permissionPopup.selectItem(at: AgentPermissionMode.allCases.firstIndex(of: task.permission) ?? 1)
            modePopup.selectItem(at: AgentMode.allCases.firstIndex(of: mode) ?? 2); agentOptionsChanged()
            guard store.writeError == nil, store.task(taskID)?.mode == mode else { throw PetError(store.writeError ?? "任务模式未保存") }
            dismissExtensionCandidates(); composer.string = ""; composer.didChangeText(); guard saveAgentDraft() else { throw PetError("任务草稿未保存") }
            store.slashMenu.recordMode(mode); window?.makeFirstResponder(composer)
        case .plugin: break
        case .connector(let server):
            let current = try AgentMCPSelection.current(AgentMCPSelection.reference(server),task:task,store:store)
            try insertSlashInvocation(AgentMCPSelection.invocation(current),taskID:taskID)
        }
    }
    private func insertRule(_ item: AgentPluginRuleItem, taskID: String) throws {
        guard let store = companion?.agentStore, let task = store.task(taskID), !task.archived, !task.isProjectDocumentation, task.kind != "hook" else { throw PetError("请在原普通任务中选择规则") }
        let current = try store.extensions.plugins.currentRule(item.id, task: task)
        var unbound = current.reference; unbound.workspace = item.reference.workspace
        guard unbound == item.reference, current.source == item.source else { throw PetError("规则来源已变化，请刷新插件") }
        try insertRuleInvocation(AgentRuleSelection.invocation(AgentRuleSelection.title(current)), taskID: taskID)
    }
    private func insertLocalRule(_ item: AgentLocalRuleItem, taskID: String) throws {
        guard let store = companion?.agentStore, let task = store.task(taskID), !task.archived, !task.isProjectDocumentation, task.kind != "hook" else { throw PetError("请在原普通任务中选择规则") }
        let current = try store.rules.current(item.id, task: task)
        guard current.definition != nil, current.sha256 == item.sha256, current.signature == item.signature else { throw PetError("规则来源已变化，请刷新规则") }
        try insertRuleInvocation(AgentRuleSelection.invocation(AgentRuleSelection.title(current)), taskID: taskID)
    }
    private func insertRuleInvocation(_ invocation: String, taskID: String) throws {
        guard saveAgentDraft() else { throw PetError("原任务草稿未保存，请重试") }; dismissExtensionCandidates()
        if displayedTask != taskID { selectAgentTask(taskID) }
        guard displayedTask == taskID else { throw PetError("原任务未打开，未添加规则") }
        let previous = composer.string
        let tail: String
        if let command = try AgentRuleSelection.command(previous) { tail = command.arguments }
        else if let first = previous.split(maxSplits: 1, whereSeparator: \.isWhitespace).first, first.hasPrefix("@rule:") { tail = previous.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines) }
        else { tail = previous }
        composer.string = invocation + " " + tail
        composer.setSelectedRange(NSRange(location: (composer.string as NSString).length, length: 0)); composer.didChangeText()
        show(tab: "chat"); window?.makeFirstResponder(composer)
    }
    private func updateExtensionCandidates() {
        guard selectedTab == "chat", let store = companion?.agentStore, let task = currentAgentTask, task.id == displayedTask, !task.archived, !task.isProjectDocumentation, task.kind != "hook",
              composer.string.hasPrefix("/"), !composer.string.contains(where: { $0.isWhitespace }), !composer.hasMarkedText(), window?.isVisible == true else { dismissExtensionCandidates(); return }
        do {
            let query = String(composer.string.dropFirst())
            guard !query.contains("/") else { dismissExtensionCandidates(); return }
            let items = try store.extensions.catalog(task: task, includeDisabled: false)
            let entries = store.slashMenu.entries(items, task: task, idle: companion?.agentRuntime?.isBusy(task.id) == false, canChangeMode: modePopup.isEnabled, connectors:AgentMCPSelection.candidates(task:task,store:store))
            guard !entries.isEmpty else { dismissExtensionCandidates(); return }
            let opening = extensionPickerTask != task.id || !extensionPanel.isVisible
            extensionPickerTask = task.id
            extensionPicker.onLayoutChanged = { [weak self] in self?.positionExtensionCandidates() }
            extensionPicker.setEntries(entries, service: store.slashMenu, presentation: companion?.generalSettings.settings.slashMenuPresentation ?? .recent, query: query, reset: opening, connectorIssue:store.mcp.loadError)
            extensionPicker.onPick = { [weak self] entry in
                guard let self, let id = extensionPickerTask, id == displayedTask else { return }
                do { try selectSlashEntry(entry, taskID: id) } catch { dismissExtensionCandidates(); setStatus(error.localizedDescription, error: true) }
            }
            guard let window else { dismissExtensionCandidates(); return }
            extensionPanel.contentViewController = extensionPicker
            positionExtensionCandidates()
            if extensionPanel.parent !== window { window.addChildWindow(extensionPanel, ordered: .above) }; extensionPanel.orderFront(nil)
        } catch { dismissExtensionCandidates(); setStatus(error.localizedDescription, error: true) }
    }
    private func positionExtensionCandidates() {
        guard extensionPickerTask != nil, let window else { return }
        let anchor = window.convertToScreen(composer.convert(composer.visibleRect, to: nil)), bounds = (window.screen?.visibleFrame ?? window.frame).intersection(window.frame)
        let width = min(560, max(320, anchor.width), bounds.width)
        let height = extensionPicker.fitHeight(min(bounds.height - 24, max(0, bounds.maxY - anchor.maxY - 6)))
        let x = min(bounds.maxX - width, max(bounds.minX, anchor.minX)), y = min(bounds.maxY - height, max(bounds.minY, anchor.maxY + 6))
        extensionPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        extensionPanel.contentView?.wantsLayer = true; extensionPanel.contentView?.layer?.cornerRadius = 8; extensionPanel.contentView?.layer?.masksToBounds = true
    }
    func slashMenuReadback() -> [String: Any] {
        guard companion?.checkDirectory != nil else { return [:] }
        let composerFrame = window?.convertToScreen(composer.convert(composer.visibleRect, to: nil)) ?? .zero
        return ["visible": extensionPanel.isVisible, "taskID": extensionPickerTask as Any? ?? NSNull(), "category": extensionPicker.category.rawValue,
                "selectedID": extensionPicker.selectedID as Any? ?? NSNull(), "geometry": extensionPicker.layoutReadback(),
                "panelFrame": NSStringFromRect(extensionPanel.frame), "composerFrame": NSStringFromRect(composerFrame), "overlapsComposer": extensionPanel.isVisible && extensionPanel.frame.intersects(composerFrame),
                "entries": extensionPicker.entries.map { ["id": $0.id, "title": $0.title, "scope": $0.scope] }, "recentIDs": companion?.agentStore?.slashMenu.recentIDs ?? [],
                "issue": companion?.agentStore?.slashMenu.issue as Any? ?? NSNull(), "composerHasKeyFocus": window?.firstResponder === composer && window?.isKeyWindow == true,
                "panelIsKey": extensionPanel.isKeyWindow, "panelWidth": extensionPanel.frame.width, "panelHeight": extensionPanel.frame.height]
    }
    func attachBrowserCapture(_ shot: AgentBrowserShot, marks: [AgentBrowserMark], note: String, taskID: String) async throws {
        try await attachTaskCapture(taskID: taskID, note: note) { tasks in _ = try await shot.attach(store: tasks, taskID: taskID, draft: true, marks: marks) }
    }
    func prepareAppShot() throws -> String {
        guard let task = currentAgentTask, window?.isVisible == true, composer.isEditable, !task.archived, !task.isProjectDocumentation, task.kind != "hook", attachmentImport == nil else { throw PetError("请先打开一个可以添加附件的任务") }
        guard (task.draftAttachmentIDs?.count ?? 0) < 6 else { throw PetError("每条消息最多 6 个附件") }
        guard saveAgentDraft() else { throw PetError("请先保存任务草稿") }; return task.id
    }
    func attachAppShot(_ shot: AgentAppShotCapture, taskID: String) async throws -> AgentAttachment {
        var file: AgentAttachment?
        try await attachTaskCapture(taskID: taskID, note: "") { tasks in file = try await shot.attach(store: tasks, taskID: taskID) }
        guard let file else { throw PetError("窗口快照未添加") }; return file
    }
    func attachCanvasCapture(_ shot: AgentCanvasShot, marks: [AgentBrowserMark], note: String, taskID: String) async throws {
        let context = "画布「" + shot.capture.title + "」的批注（源码版本 " + String(shot.capture.sourceHash.prefix(12)) + "）：" + note
        try await attachTaskCapture(taskID: taskID, note: context) { tasks in _ = try await shot.attach(store: tasks, taskID: taskID, draft: true, marks: marks) }
    }
    private func attachTaskCapture(taskID: String, note: String, importing: (AgentStore) async throws -> Void) async throws {
        guard let tasks = companion?.agentStore, tasks.task(taskID) != nil else { throw PetError("任务不存在") }
        guard saveAgentDraft(), companion?.persistTaskDrafts(taskID) != false else { throw PetError("请先保存此任务的草稿") }
        try await importing(tasks)
        defer { renderMessages() }
        try Task.checkCancellation()
        // Preserve edits made in either composer while the image was imported.
        guard saveAgentDraft(), companion?.persistTaskDrafts(taskID) != false else { throw PetError("请先保存此任务的草稿") }
        if !note.isEmpty {
            tasks.update(taskID) { record in
                let previous = record.draft ?? ""
                record.draft = previous + (previous.isEmpty ? "" : "\n") + note
            }
            if let error = tasks.writeError { throw PetError("标注要求未保存：" + error) }
        }
        if displayedTask == taskID { composer.string = tasks.task(taskID)?.draft ?? ""; composer.needsDisplay = true }
        else { selectAgentTask(taskID) }
        show(tab: "chat"); window?.makeFirstResponder(composer)
    }
    private func openCanvasReference(_ value: String, taskID: String, location: AgentArtifactLocation? = nil) {
        guard let url = URL(string: value), url.scheme == "canvas", let id = url.host.flatMap({ UUID(uuidString: $0)?.uuidString }), let tasks = companion?.agentStore else { return }
        let destination = location ?? companion?.generalSettings.settings.artifactLocation ?? .workspace
        Task { @MainActor [weak self] in do { _ = try await tasks.canvases.show(id, taskID: taskID, location: destination) } catch { self?.setStatus(error.localizedDescription, error: true) } }
    }
}

extension ControlWindow {
    func checkArtifactDocument(_ file: URL, taskID: String) -> AgentRecordWindow? {
        guard companion?.checkDirectory != nil, AgentTaskWorkspace.readbackEnabled else { return nil }
        return (artifactDocuments + taskWorkspace.controllers.compactMap { $0 as? AgentRecordWindow }).first { $0.belongsToTasks([taskID]) && $0.workspaceDocumentURL?.path == file.path }
    }
    func artifactOpeningReadback() async -> [String: Any] {
        guard companion?.checkDirectory != nil else { return [:] }
        var records: [[String: Any]] = [], offices: [[String: Any]] = []
        for record in artifactDocuments { records.append(await record.workspaceReadback()) }
        for editor in companion?.agentStore?.offices.windows.values.filter({ $0.settingsHostWindow == nil }) ?? [] { offices.append(await editor.workspaceReadback()) }
        let canvases = companion?.agentStore?.canvases.windows.values.filter { $0.settingsHostWindow == nil }.map { $0.workspaceReadback() } ?? []
        return ["location": companion?.generalSettings.settings.artifactLocation.rawValue ?? "workspace", "documents": records, "offices": offices, "canvases": canvases]
    }
    func checkAddDocumentSelection(_ selection: AgentMarkdownSelection, taskID: String) throws {
        guard companion?.checkDirectory != nil else { throw PetError("仅用于独立验收配置") }
        try addDocumentSelection(selection, taskID: taskID)
    }
    func prepareMarkdownCheck(taskID: String, section: Int = 6, value: String? = nil) -> AgentRecordWindow? {
        guard companion?.checkDirectory != nil else { return nil }
        selectAgentTask(taskID); show(tab: "chat")
        guard let store = companion?.agentStore else { return nil }
        recordWindow?.window?.performClose(nil)
        if recordWindow?.window?.isVisible == true { return nil }
        recordWindow = preparedRecord(store: store, taskID: taskID, section: section); recordWindow?.showWindow(nil); recordWindow?.window?.makeKeyAndOrderFront(nil)
        if let value { recordWindow?.selectItem(section: section, value: value) }; return recordWindow
    }
    func prepareExtensionCheckWindow(taskID: String, manager: Bool) {
        selectAgentTask(taskID); show(tab: "chat"); if manager { showAgentExtensions() }
    }
    func checkExtensionComposer(_ output: URL, taskID: String, item: AgentExtensionItem) async throws -> [String: Bool] {
        guard let store = companion?.agentStore, companion?.checkDirectory != nil else { return ["extensionCheckProfile": false] }
        selectAgentTask(taskID); show(tab: "chat"); composer.string = "/handoff"; composer.didChangeText()
        try await Task.sleep(nanoseconds: 50_000_000)
        var checks = ["slashSearchShowsNativeCandidates": extensionPanel.isVisible && extensionPicker.items.contains(where: { $0.id == item.id }), "selectingEmptyTaskClearsRenderedHistory": messageColumn.arrangedSubviews.isEmpty]
        checks["slashCandidatesKeepComposerKeyFocus"] = window?.isKeyWindow == true && window?.firstResponder === composer && !extensionPanel.isKeyWindow
        _ = composer.onExtensionKey?(48)
        try await Task.sleep(nanoseconds: 50_000_000)
        let selectedText = composer.string
        checks["tabSelectsWithoutSubmitting"] = selectedText == "/" + item.invocation + " " && store.task(taskID)?.messages.isEmpty == true && extensionPickerTask == nil && !extensionPanel.isVisible
        composer.string = "保留原草稿"; saveAgentDraft()
        let other = store.create(title: "另一个扩展草稿", workspace: store.task(taskID)?.workspace)
        selectAgentTask(other); composer.string = "另一个原草稿"; saveAgentDraft()
        try insertExtension(item, taskID: taskID); saveAgentDraft()
        checks["managerInsertionPreservesBothTaskDrafts"] = agentTaskID == taskID && store.task(taskID)?.draft == "/" + item.invocation + " 保留原草稿" && store.task(other)?.draft == "另一个原草稿"
        composer.string = "/"; composer.didChangeText(); selectAgentTask(other)
        try await Task.sleep(nanoseconds: 50_000_000)
        checks["taskSwitchClosesSlashCandidates"] = extensionPickerTask == nil && !extensionPanel.isVisible
        let observations: [String: Any] = ["selectedText": selectedText, "selectedTaskMessages": store.task(taskID)?.messages.count ?? -1, "candidateOwnerAfterSwitch": extensionPickerTask ?? "none", "panelShownAfterSwitch": extensionPanel.isVisible]
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("extension-composer-report.json"))
        selectAgentTask(taskID); composer.string = ""; composer.didChangeText(); saveAgentDraft()
        if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("extension-entry.png")) }
        return checks
    }
    func checkSlashConnectors(_ output:URL, ids:[String:String]) async throws -> [String:Bool] {
        guard let app = companion, app.checkDirectory != nil, let tasks = app.agentStore, let window, let id = ids["task"] else { throw PetError("缺少连接器菜单窗口") }
        var checks:[String:Bool] = [:]
        func open(_ query:String = "/", owner:String? = nil) async throws {
            selectAgentTask(owner ?? id); show(tab:"chat"); NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(composer)
            composer.string = query; composer.didChangeText(); try await Task.sleep(nanoseconds:50_000_000)
        }
        let seed = tasks.create(title:"原生最近使用的模式记录",mode:.agent)
        try await open(owner:seed); try selectSlashEntry(.mode(.plan),taskID:seed)
        let history = app.store.directory.appendingPathComponent("slash-history.json"), before = try Data(contentsOf:history)
        try await open()
        for _ in 0..<AgentSlashCategory.allCases.count where extensionPicker.category != .connectors { _ = composer.onExtensionKey?(124) }
        checks["connectorCategoryUsesKeyboardWithoutTakingInputFocus"] = extensionPanel.isVisible && extensionPicker.category == .connectors && window.firstResponder === composer && !extensionPanel.isKeyWindow
        checks["categoryContainsOnlyActualConnectorRows"] = extensionPicker.entries.count == 4 && extensionPicker.entries.allSatisfy{if case .connector = $0 { return true }; return false}
        checks["sixCategoryLabelsAndRowsFitPalette"] = extensionPicker.layoutReadback()["categoriesFit"] as? Bool == true && extensionPicker.layoutReadback()["categoryCount"] as? Int == 6 && extensionPicker.layoutReadback()["shortListFits"] as? Bool == true
        try await open("/README")
        checks["searchFindsConfiguredConnectorByActualName"] = extensionPicker.entries.count == 1 && extensionPicker.entries.first?.id == "connector." + ids["server"]!
        _ = composer.onExtensionKey?(48); _ = saveAgentDraft()
        let primary = try tasks.mcp.server(ids["server"]!), invocation = "/" + (try AgentMCPSelection.invocation(primary))
        checks["tabOnlyInsertsQuotedDraftWithoutSendingOrRecordingUse"] = try composer.string == invocation + " " && tasks.task(id)?.draft == composer.string && tasks.task(id)?.messages.isEmpty == true && !extensionPanel.isVisible && Data(contentsOf:history) == before
        let font = composer.font?.pointSize, otherDraft = tasks.task(ids["other"]!)?.draft
        composer.string = "保留原始要求 🧭"; _ = saveAgentDraft(); try selectSlashEntry(.connector(primary),taskID:id); _ = saveAgentDraft()
        checks["insertionPreservesOriginalTextFontAndOtherTaskDraft"] = composer.string == invocation + " 保留原始要求 🧭" && composer.font?.pointSize == font && tasks.task(ids["other"]!)?.draft == otherDraft
        let second = try tasks.mcp.server(ids["second"]!)
        composer.string = "/" + (try AgentMCPSelection.invocation(second)) + " 保留后续参数 🧭"; _ = saveAgentDraft()
        try selectSlashEntry(.connector(primary),taskID:id)
        checks["replacingConnectorDoesNotKeepOldQuotedNameAsGoal"] = composer.string == invocation + " 保留后续参数 🧭"
        _ = try tasks.mcp.save(tasks.mcp.document(second),id:second.id,expectedRevision:second.revision)
        let currentDraft = composer.string
        do { try selectSlashEntry(.connector(second),taskID:id); checks["stalePopupRowCannotSelectChangedConfiguration"] = false } catch { checks["stalePopupRowCannotSelectChangedConfiguration"] = composer.string == currentDraft && tasks.task(id)?.messages.isEmpty == true }
        try await open(); selectAgentTask(ids["ask"]!)
        checks["taskSwitchDismissesOldConnectorPopup"] = !extensionPanel.isVisible && extensionPickerTask == nil
        try await open()
        let entries = tasks.slashMenu.entries([],task:tasks.task(id)!,idle:true,canChangeMode:true)
        extensionPicker.setEntries(entries,service:tasks.slashMenu,presentation:.recent,query:"",reset:true,connectorIssue:"公开配置读取失败")
        for _ in 0..<AgentSlashCategory.allCases.count where extensionPicker.category != .connectors { _ = extensionPicker.moveCategory(1) }
        checks["connectorLoadIssueIsVisibleWithoutDisablingCommands"] = extensionPicker.category == .connectors && (extensionPicker.layoutReadback()["footer"] as? String)?.contains("公开配置读取失败") == true && entries.contains{if case .builtin = $0 { return true }; return false}
        dismissExtensionCandidates(); composer.string = "保留公开核对要求 🧭"; _ = saveAgentDraft()
        try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("slash-connectors-composer.json"))
        return checks
    }
    func checkSlashMenu(_ output: URL, fixture: AgentSlashMenuFixture) async throws -> [String: Bool] {
        guard let app = companion, app.checkDirectory != nil, let tasks = app.agentStore, let runtime = app.agentRuntime, let window else { throw PetError("缺少命令菜单窗口") }
        let service = tasks.slashMenu, history = app.store.directory.appendingPathComponent("slash-history.json")
        var checks: [String: Bool] = [:]
        func open(_ query: String = "/", _ style: AgentSlashPresentation = .recent, owner: String? = nil) async throws {
            var value = app.generalSettings.settings; value.slashMenuPresentation = style; try app.generalSettings.save(value)
            selectAgentTask(owner ?? fixture.taskID); show(tab: "chat"); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(composer)
            composer.string = query; composer.didChangeText(); try await Task.sleep(nanoseconds: 50_000_000)
        }
        func select(_ id: String) throws {
            guard let index = extensionPicker.entries.firstIndex(where: { $0.id == id }) else { throw PetError("菜单缺少真实候选：" + id) }
            extensionPicker.move(-10_000); extensionPicker.move(index); extensionPicker.pick()
        }
        try await open()
        checks["RecentComesFromActualAcceptedInput"] = extensionPicker.entries.first?.id == "item." + fixture.commands.last! && tasks.task(fixture.seedID)?.messages.last?.content == "/command:slash-command-18 公开的最近使用参数"
        checks["MenuKeepsComposerKeyFocus"] = window.isKeyWindow && window.firstResponder === composer && !extensionPanel.isKeyWindow
        checks["SingleRecentRowIsFullyVisible"] = extensionPicker.layoutReadback()["shortListFits"] as? Bool == true
        try await open("/", .expanded)
        checks["ExpandedMenuContainsMoreThanTwelveAndLastCommand"] = extensionPicker.candidateCount > 12 && extensionPicker.entries.contains { $0.id == "item." + fixture.commands.last! }
        let pluginItems = try tasks.extensions.catalog(workspace: tasks.task(fixture.taskID)?.workspace, includeDisabled: false).filter { $0.pluginName == fixture.pluginID }
        checks["ExpandedMenuIncludesEveryEnabledPluginChild"] = pluginItems.count == 3 && pluginItems.allSatisfy { item in extensionPicker.entries.contains { $0.id == "item." + item.id } }
        let oldHistory = try Data(contentsOf: history), picked = fixture.commands[16]
        try select("item." + picked)
        checks["PickingBeyondTwelveOnlyInsertsDraft"] = try composer.string == "/command:slash-command-17 " && tasks.task(fixture.taskID)?.messages.isEmpty == true && !extensionPanel.isVisible && Data(contentsOf: history) == oldHistory
        checks["ActualRuntimeAcceptanceRecordsRecentAndOriginalArguments"] = runtime.submit(composer.string + "公开参数", taskID: fixture.taskID, startImmediately: false) && service.recentIDs.first == "item." + picked && tasks.task(fixture.taskID)?.messages.last?.content == "/command:slash-command-17 公开参数" && tasks.task(fixture.taskID)?.messages.last?.extensionReferences?.first?.id == picked
        try await open("/", .collapsed)
        checks["CollapsedMenuRetainsPluginRootAndHidesChildren"] = extensionPicker.entries.contains { $0.pluginKey == fixture.pluginID } && !extensionPicker.entries.contains { $0.extensionItem?.pluginName == fixture.pluginID }
        let pluginSkill = pluginItems.first { $0.kind == .skill }!
        try await open("/" + pluginSkill.invocation, .collapsed)
        checks["ExplicitSearchFindsCollapsedPluginChild"] = extensionPicker.entries.contains { $0.id == "item." + pluginSkill.id }
        try await open("/菜单示例插件", .collapsed)
        guard let searchedRoot = extensionPicker.entries.first(where: { $0.pluginKey == fixture.pluginID }) else { throw PetError("搜索未找到插件分组") }
        let searchHistory = try Data(contentsOf: history)
        try select(searchedRoot.id)
        checks["SearchedPluginGroupShowsOnlyItsActualChildren"] = extensionPicker.candidateCount == 3 && extensionPicker.entries.allSatisfy { $0.extensionItem?.pluginName == fixture.pluginID }
        _ = composer.onExtensionKey?(53)
        checks["SearchedPluginBackRestoresQueryAndResultsWithoutRecordingUse"] = try extensionPanel.isVisible && extensionPicker.entries.contains { $0.id == searchedRoot.id } && composer.string == "/菜单示例插件" && Data(contentsOf: history) == searchHistory
        try await open()
        _ = composer.onExtensionKey?(124)
        checks["RightArrowChangesCategoryWithoutMovingInputFocus"] = extensionPicker.category == .modes && window.firstResponder === composer
        let oldPermission = tasks.task(fixture.taskID)!.permission, oldMessages = tasks.task(fixture.taskID)!.messages.count
        try select("mode.goal")
        checks["ModeEntryUsesActualModeWithoutSubmittingOrChangingPermission"] = tasks.task(fixture.taskID)?.mode == .goal && tasks.task(fixture.taskID)?.permission == oldPermission && tasks.task(fixture.taskID)?.messages.count == oldMessages && service.recentIDs.first == "mode.goal" && composer.string.isEmpty
        try await open()
        for _ in 0..<5 where extensionPicker.category != .plugins { _ = composer.onExtensionKey?(124) }
        guard let root = extensionPicker.entries.first(where: { $0.pluginKey == fixture.pluginID }) else { throw PetError("缺少已启用的插件分组") }
        let historyBeforeBrowsing = try Data(contentsOf: history)
        try select(root.id)
        checks["PluginGroupOpensActualChildrenWithoutRecordingUse"] = try extensionPicker.candidateCount == 3 && extensionPicker.entries.allSatisfy { $0.extensionItem?.pluginName == fixture.pluginID } && Data(contentsOf: history) == historyBeforeBrowsing
        checks["EveryPluginChildRowIsFullyVisible"] = extensionPicker.layoutReadback()["shortListFits"] as? Bool == true
        _ = composer.onExtensionKey?(123)
        checks["LeftArrowReturnsToPluginList"] = extensionPanel.isVisible && extensionPicker.entries.contains { $0.pluginKey == fixture.pluginID }
        try select(root.id); try select("item." + pluginSkill.id)
        checks["ManualPluginSkillSelectionOnlyAddsDraft"] = try composer.string == "/" + pluginSkill.invocation + " " && Data(contentsOf: history) == historyBeforeBrowsing
        checks["ActualExplicitPluginSkillAcceptanceKeepsSnapshotAndRecent"] = runtime.submit(composer.string + "公开参数", taskID: fixture.taskID, startImmediately: false) && service.recentIDs.first == "item." + pluginSkill.id && tasks.task(fixture.taskID)?.messages.last?.extensionReferences?.first?.snapshot?.contains(fixture.taskID) == true
        try tasks.extensions.plugins.setEnabled(tasks.extensions.plugins.installation(fixture.pluginID), false)
        try await open()
        checks["DisabledPluginDisappearsFromRecentWithoutErasingHistory"] = !extensionPicker.entries.contains { $0.extensionItem?.pluginName == fixture.pluginID } && service.recentIDs.contains("item." + pluginSkill.id)
        let disabledBytes = try Data(contentsOf: history)
        checks["DisabledInvocationCannotBeAcceptedOrBecomeRecent"] = try !runtime.submit("/" + pluginSkill.invocation, taskID: fixture.taskID, startImmediately: false) && Data(contentsOf: history) == disabledBytes
        var staleRefused = false; do { try selectSlashEntry(.item(pluginSkill), taskID: fixture.taskID) } catch { staleRefused = true }
        checks["StalePickerEntryCannotBypassPluginDisable"] = staleRefused
        try tasks.extensions.plugins.setEnabled(tasks.extensions.plugins.installation(fixture.pluginID), true)
        checks["ProjectCommandCanBeAcceptedInItsOwnScope"] = runtime.submit("/command:project-palette 公开项目参数", taskID: fixture.taskID, startImmediately: false)
        try await open("/", .recent, owner: fixture.otherID)
        checks["NoWorkspaceRecentHidesForeignProjectButKeepsGlobalCommand"] = !extensionPicker.entries.contains { $0.id == "item." + fixture.projectID } && extensionPicker.entries.contains { $0.id == "item." + picked }
        try await open("/", .expanded)
        let beforeReadOnly = try Data(contentsOf: history); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: history.path)
        checks["HistoryFailureDoesNotRejectAnAcceptedCommand"] = runtime.submit("/command:slash-command-16 公开只读检查", taskID: fixture.taskID, startImmediately: false)
        checks["ReadOnlyRecentFailureKeepsBytesAndShowsIssue"] = try Data(contentsOf: history) == beforeReadOnly && service.issue?.contains("未保存") == true
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
        _ = runtime.submit("/command:slash-command-16 公开重试", taskID: fixture.taskID, startImmediately: false)
        checks["RecentRetrySavesPrivatelyAndReloads"] = try service.issue == nil && service.recentIDs.first == "item." + fixture.commands[15] && AgentSlashMenu(profile: app.store.directory).recentIDs == service.recentIDs && (FileManager.default.attributesOfItem(atPath: history.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
        for index in 0..<15 { _ = runtime.submit(String(format: "/command:slash-command-%02d 公开记录", index + 1), taskID: fixture.taskID, startImmediately: false) }
        _ = runtime.submit("/command:slash-command-15 重复使用", taskID: fixture.taskID, startImmediately: false)
        checks["AcceptedRecentHistoryIsBoundedAndDeduplicated"] = service.recentIDs.count == 12 && Set(service.recentIDs).count == 12 && service.recentIDs.first == "item." + fixture.commands[14]
        for (label, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 780, height: 540))] {
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); try await open("/", .expanded, owner: fixture.otherID)
            let intersection = window.frame.intersection(extensionPanel.frame)
            checks["PopupFitsOwnerAndKeepsKeyFocus-" + label] = extensionPanel.isVisible && intersection == extensionPanel.frame && window.firstResponder === composer && !extensionPicker.view.hasAmbiguousLayout
            let inputFrame = window.convertToScreen(composer.convert(composer.visibleRect, to: nil))
            checks["EmptyTaskPopupStaysAboveComposerWithoutCoveringInput-" + label] = tasks.task(fixture.otherID)?.messages.isEmpty == true && extensionPanel.frame.minY >= inputFrame.maxY + 5.5
        }
        try await open("/no-such-slash-native")
        checks["EmptySearchShowsNoSelectableEntry"] = extensionPanel.isVisible && extensionPicker.candidateCount == 0
        _ = composer.onExtensionKey?(48); checks["EmptySelectionDoesNotSubmit"] = tasks.task(fixture.taskID)?.messages.last?.content == "/command:slash-command-15 重复使用"
        _ = composer.onExtensionKey?(53); checks["EscapeClosesMenuAndKeepsQuery"] = !extensionPanel.isVisible && composer.string == "/no-such-slash-native"
        try await open(); selectAgentTask(fixture.otherID)
        checks["TaskSwitchClosesOwnedMenu"] = extensionPickerTask == nil && !extensionPanel.isVisible
        let invalid = output.appendingPathComponent("invalid-slash-history"); try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        let invalidFile = invalid.appendingPathComponent("slash-history.json"), invalidBytes = Data("{\"version\":1,\"ids\":[\"item.invalid\"]}".utf8); try invalidBytes.write(to: invalidFile)
        let invalidService = AgentSlashMenu(profile: invalid); invalidService.recordBuiltin(.canvas)
        checks["InvalidRecentHistoryIsPreserved"] = try invalidService.issue != nil && Data(contentsOf: invalidFile) == invalidBytes
        let linked = output.appendingPathComponent("linked-slash-history"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true); try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("slash-history.json"), withDestinationURL: history)
        let targetBytes = try Data(contentsOf: history), linkedService = AgentSlashMenu(profile: linked); linkedService.recordBuiltin(.canvas)
        checks["SymlinkRecentHistoryCannotOverwriteTarget"] = try linkedService.issue != nil && Data(contentsOf: history) == targetBytes
        selectAgentTask(fixture.taskID); composer.string = "命令菜单原草稿 🧭"; composer.didChangeText(); guard saveAgentDraft() else { throw PetError("命令菜单原草稿未保存") }
        let report: [String: Any] = ["checks": checks, "fixture": try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)), "modelRequests": 0, "boundary": "Actual local extension/plugin catalog, native picker events, accepted input preparation and persisted metadata. No provider call or generated model answer."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("slash-menu-report.json"))
        return checks
    }
    func checkBrowserCaptureDraft(_ shot: AgentBrowserShot, marks: [AgentBrowserMark], note: String, taskID: String) async throws -> [String: Bool] {
        guard let tasks = companion?.agentStore else { throw PetError("任务未初始化") }
        selectAgentTask(taskID); composer.string = "保留的原有草稿"; saveAgentDraft()
        let other = tasks.create(title: "另一个未发送草稿", mode: .ask)
        selectAgentTask(other); composer.string = "独立草稿"; saveAgentDraft()
        try await attachBrowserCapture(shot, marks: marks, note: note, taskID: taskID)
        return ["captureReturnsToOwningTask": agentTaskID == taskID && displayedTask == taskID,
                "capturePreservesBothComposerDrafts": tasks.task(taskID)?.draft == "保留的原有草稿\n" + note && tasks.task(other)?.draft == "独立草稿",
                "captureAppearsInComposerBeforeSending": tasks.task(taskID)?.draftAttachmentIDs?.count == 1 && !draftAttachments.isHidden && !composer.string.isEmpty && tasks.task(taskID)?.messages.isEmpty == true]
    }
    func checkAgentBrowserEntry(_ output: URL, taskID: String) async -> [String: Bool] {
        selectAgentTask(taskID); showWindow(nil)
        var checks: [String: Bool] = [:]
        for (name, size) in [("normal", NSSize(width: 980, height: 700)), ("narrow", NSSize(width: 780, height: 540))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["browserEntryLayout-" + name] = browserButton.window != nil && !browserButton.isHidden && browserButton.bounds.width > 25 && !browserButton.hasAmbiguousLayout && !projectButton.hasAmbiguousLayout
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("browser-entry-" + name + ".png")) }
        }
        return checks
    }
    func persistAgentDraft() { attachmentImport?.cancel(); saveAgentDraft() }
    func saveWindowDraft() -> Bool { saveAgentDraft() }
    func refreshAttention() { if let attention = companion?.agentStore?.attention { taskSidebar.setAttentionCount(attention.pendingCount, enabled: attention.settings.enabled); attentionPageController?.refresh() } }
    func undoManager(for view: NSTextView) -> UndoManager? { view === composer ? windowDraft?.undo : nil }
    func checkAttachmentUI(_ output: URL, taskID: String, fileID: String) async -> [String: Bool] {
        guard let store = companion?.agentStore else { return ["attachmentUI": false] }
        selectAgentTask(taskID); showWindow(nil); composer.string = "附件草稿"; composer.didChangeText(); saveAgentDraft()
        beginAttachmentImport([output.appendingPathComponent("sample.pdf"), output.appendingPathComponent("cached.xlsx")], store: store, taskID: taskID)
        let another = store.create(title: "另一份附件草稿", mode: .ask); selectAgentTask(another)
        await attachmentImport?.value; selectAgentTask(taskID)
        var checks = ["nativeImportStaysWithOriginalTask": store.task(taskID)?.draftAttachmentIDs?.count == 2 && (store.task(another)?.attachments ?? []).isEmpty,
                      "nativeAttachmentDraftSurvivesTaskSwitch": composer.string == "附件草稿" && !draftAttachments.isHidden,
                      "nativeSubmittedAttachmentHasHistoryRow": messageRows.values.contains { $0.text == "公开附件" }]
        composer.string = ""; setBusy(true)
        checks["fileOnlyInputDoesNotBecomeStopAction"] = sendButton.accessibilityLabel() == "补充要求"
        setBusy(false)
        for (name, size) in [("normal", NSSize(width: 980, height: 700)), ("narrow", NSSize(width: 780, height: 540))] {
            window?.setContentSize(size); renderAgentMessages(); window?.contentView?.layoutSubtreeIfNeeded()
            checks["nativeAttachmentLayout-" + name] = draftAttachments.bounds.width > 350 && draftAttachments.bounds.height > 40 && !draftAttachments.hasAmbiguousLayout && composer.bounds.width > 350
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("attachments-" + name + ".png")) }
        }
        do {
            let preview = try AgentAttachmentWindow(store: store, taskID: taskID, id: fileID)
            await preview.captureQuickLook(output)
            checks["nativePreviewReadsActualWordCopy"] = await preview.checkText("1499.00", output: output); preview.close()
        } catch { checks["nativePreviewReadsActualWordCopy"] = false }
        return checks
    }
    func checkAgentLayout(_ output: URL, includeArtifacts: Bool = true) async -> [String: Bool] {
        guard let tasks = companion?.agentStore, let originalID = agentTaskID else { return ["nativeAgentLayout": false] }
        let draft = composer.string
        composer.string = "尚未发送的 Agent 草稿"; composer.didChangeText(); saveAgentDraft()
        let second = tasks.create(title: "另一项任务"); selectAgentTask(second); composer.string = "另一份草稿"; composer.didChangeText()
        selectAgentTask(originalID)
        var checks = ["draftsAreIsolatedAndPersistent": composer.string == "尚未发送的 Agent 草稿" && tasks.task(second)?.draft == "另一份草稿"]
        selectedTab = "settings"; changeTab(); selectedTab = "chat"; changeTab()
        checks["settingsReturnPreservesTaskDraft"] = composer.string == "尚未发送的 Agent 草稿" && agentTaskID == originalID
        func capture(_ name: String) {
            guard let view = window?.contentView else { return }; view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png")) }
        }
        for (name, size) in [("normal", NSSize(width: 980, height: 700)), ("narrow", NSSize(width: 780, height: 540))] {
            window?.setContentSize(size); renderAgentMessages(); try? await Task.sleep(nanoseconds: 100_000_000); capture("agent-" + name)
            checks["nativeAgentLayout-" + name] = taskSidebar.bounds.width > 150 && taskSidebar.bounds.height > 100 && composer.bounds.width > 350 && sendButton.bounds.width == 34 && !chat.hasAmbiguousLayout && !modePopup.hasAmbiguousLayout && messageRows.values.allSatisfy { !$0.hasAmbiguousLayout && $0.label.bounds.width > 100 }
        }
        window?.setContentSize(NSSize(width: 980, height: 700)); composer.string = draft; composer.didChangeText(); saveAgentDraft(); renderAgentMessages()
        if includeArtifacts {
            let records = AgentRecordWindow(store: tasks, taskID: originalID)
            checks.merge(await records.checkPreview(output)) { _, value in value }; records.close()
        }
        return checks
    }
}

@MainActor extension ControlWindow {
    func showAgentTask(_ id: String) { selectAgentTask(id) }
    func prepareRepoWikiOverviewCheck() { showAgentKnowledge() }
    func repoWikiOverviewReadback() async -> [String: Any] {
        guard CommandLine.arguments.contains("--repo-wiki-overview-check") else { return [:] }
        var value = repoWikiWindow?.checkState ?? [:]
        value["selectedTask"] = agentTaskID as Any? ?? NSNull(); value["draft"] = composer.string
        value["tasks"] = companion?.agentStore?.tasks.map { ["id": $0.id, "workspace": $0.workspace as Any? ?? NSNull(), "kind": $0.kind as Any? ?? NSNull()] as [String: Any] } ?? []
        value["projectSearchOpen"] = knowledgeWindow?.isPageVisible == true
        if let record = knowledgePageHost.currentController as? AgentRecordWindow { value["document"] = await record.markdownEditingReadback() }
        else if let recordWindow, recordWindow.window?.isVisible == true { value["document"] = await recordWindow.markdownEditingReadback() }
        return value
    }
    func refreshDataImport() { dataImportView?.refresh() }
    func refreshModePresentation() {
        guard companion?.usesAgent == true, let task = currentAgentTask else { return }
        refreshBranch(task); updateWorkbenchLayout(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    func checkModeSettingsSearch() -> [String: Bool] {
        guard CommandLine.arguments.contains("--mode-presentation-check") else { return [:] }
        let query = settingsSearch.stringValue, category = settingsCategory
        defer { settingsSearch.stringValue = query; settingsCategory = category; updateSettingsSections() }
        let groups = settingGroups.filter { $0.category == "modes" }.map(\.view)
        var checks: [String: Bool] = [:]
        for (text, key) in [("项目选择入口", "projectEntry"), ("运行环境", "environment"), ("变更审阅", "changeReview")] {
            settingsSearch.stringValue = text; updateSettingsSections(); window?.contentView?.layoutSubtreeIfNeeded()
            checks["search-" + key + "ShowsBothModeFormsWithoutExtraSave"] = groups.count == 2 && groups.allSatisfy { $0.superview === settingsForm && !$0.isHiddenOrHasHiddenAncestor } && settingsHeading.stringValue == "搜索结果" && generalSettingsSave?.isHidden == true
        }
        settingsSearch.stringValue = "不存在的设置-a7k2m9v4"; updateSettingsSections()
        checks["emptySettingsSearchHasNoSaveAction"] = noSettings.superview === settingsForm && generalSettingsSave?.isHidden == true && settingsFooter?.isHidden == true
        return checks
    }
    func modePresentationReadback() -> [String: Any] {
        func changeRows(_ view: NSView) -> Int {
            (view as? AgentInspectorFileButton).map { $0.section == 3 ? 1 : 0 } ?? view.subviews.reduce(0) { $0 + changeRows($1) }
        }
        let mode = currentAgentTask?.organizationMode ?? displayedWorkMode
        return ["mode": mode.rawValue, "projectEntryHidden": projectButton.isHidden, "emptyProjectHidden": emptyProject.isHidden,
                "inputEnvironmentHidden": executionLocation.isHidden, "branchHidden": branchControl.isHidden, "gitEntryHidden": gitButton.isHidden,
                "inspectorChangeRows": changeRows(workbenchInspector), "draft": composer.string,
                "taskID": agentTaskID as Any? ?? NSNull(), "settingsCategory": settingsCategory]
    }
    func archiveReadback() -> [String: Any] {
        guard CommandLine.arguments.contains("--task-archive-check") || CommandLine.arguments.contains("--task-records-check"), let store = companion?.agentStore else { return [:] }
        return ["sidebar": taskSidebar.organizationSnapshot(), "archive": archivedTasksView?.checkState() ?? [:], "selected": agentTaskID as Any? ?? NSNull(), "displayed": displayedTask as Any? ?? NSNull(), "composer": composer.string, "sendEnabled": sendButton.isEnabled, "composerEditable": composer.isEditable, "settingsCategory": settingsCategory,
                "tasks": store.tasks.compactMap { store.task($0.id) }.map { ["id": $0.id, "title": $0.title, "workspace": $0.workspace as Any? ?? NSNull(), "mode": $0.organizationMode.rawValue, "archived": $0.archived, "archiveID": $0.workspaceArchiveID as Any? ?? NSNull(), "draft": $0.draft ?? ""] },
                "directories": AgentWorkMode.allCases.flatMap { store.organization.directories($0, tasks: store.tasks, includingArchived: true) }.map { ["path": $0.path, "mode": $0.mode.rawValue, "archived": $0.archiveID != nil] },
                "deletions": ["ids": store.deletions.taskIDs.sorted(), "workspaces": store.deletions.workspaceIDs.sorted(), "pending": store.deletions.pendingCount, "working": store.deletions.working, "issue": store.deletions.issue as Any? ?? NSNull()]]
    }
    func showDataImportSettings() { showSettingsCategory("imports") }
    func settingsSourceReadback() -> [String: Any] {
        guard companion?.checkDirectory != nil else { return [:] }
        return ["category": settingsCategory, "page": settingsPageHost.selectedPageKey ?? "", "source": agentTaskID.flatMap { settingsSourceFolders[$0] } ?? currentAgentTask?.workspace ?? "", "folders": currentAgentTask?.workspacePaths ?? [], "primary": currentAgentTask?.workspace ?? "", "taskID": agentTaskID ?? "", "draft": composer.string, "controller": settingsPageHost.currentController.map { String(describing: type(of: $0)) } ?? ""]
    }
    var settingsControllerForCheck: AgentSettingsPageController? {
        guard ["--workspace-extensions-check", "--workspace-capabilities-check"].contains(where: CommandLine.arguments.contains), companion?.checkDirectory != nil else { return nil }
        return settingsPageHost.currentController
    }
    func switchWorkMode(_ mode: AgentWorkMode) {
        guard let tasks = companion?.agentStore, currentAgentTask?.organizationMode != mode else { return }
        saveAgentDraft()
        do {
            if let current = currentAgentTask { try tasks.organization.remember(current) }
            let id = tasks.organization.lastTask(mode, tasks: tasks.tasks) ?? tasks.create(workMode: mode)
            selectAgentTask(id)
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    func checkNameEditor(_ kind: String, id: String?, mode: AgentWorkMode = .coding) {
        guard ["--name-editor-check","--workspace-editor-check"].contains(where:CommandLine.arguments.contains) else { return }
        switch kind {
        case "task": if let id { agentTaskAction(id, action: "rename") }
        case "group": customTaskGroup(id, mode: mode, action: id == nil ? "new" : "rename")
        case "directory": if let id { directoryAction(id, mode: mode, action: "rename") }
        default: break
        }
    }
    func checkOperationDeletion(_ ids: [String]) async throws -> String? {
        guard CommandLine.arguments.contains("--operation-confirmation-check"), companion?.checkDirectory != nil else { throw PetError("仅供独立操作确认验收") }
        return try await deleteAgentTasks(ids, workspaceIDs: [])
    }
    func organizationSnapshot() -> [String: Any] {
        var value = taskSidebar.organizationSnapshot()
        value["selected"] = agentTaskID ?? ""; value["draft"] = composer.string
        value["focusedTask"] = companion?.agentStore?.selectedID ?? ""
        value["windowNumber"] = taskWindowNumber; value["windowTitle"] = window?.title ?? ""; value["windowVisible"] = window?.isVisible == true
        value["nativeWindowNumber"] = window?.windowNumber ?? 0
        if CommandLine.arguments.contains("--manual-ui") {
            value["leftSidebar"] = ["requested": sidebarRequested, "visible": !workbenchSidebar.isHidden, "mainLeading": sidebarWidth?.constant ?? 0, "navigationLeading": navigationLeading?.constant ?? 0]
            value["taskSwitcher"] = taskSwitcher?.checkState() ?? ["visible": false]
            value["nameEditor"] = workspaceEditor?.checkState() ?? nameEditor?.checkState() ?? ["visible": false]
            value["workspaceEditor"] = workspaceEditor?.checkState() ?? ["visible":false]
            value["unsavedConfirmation"] = AgentUnsavedChanges.checkState()
            value["taskFind"] = taskFind.checkState()
            value["mcpUserInput"] = ["visible": !mcpInputRow.isHidden, "requestID": agentTaskID.flatMap { companion?.agentStore?.mcp.userInputs.first(taskID: $0)?.id } as Any? ?? NSNull(), "sheet": mcpInputPanel?.window?.isVisible == true] as [String: Any]
            if companion?.checkDirectory != nil {
                value["terminalPanel"] = terminalPanel?.verificationSnapshot() ?? ["shown": false, "states": []]
            }
            value["shortcutBindings"] = Dictionary(uniqueKeysWithValues: AgentShortcutCommand.allCases.map { ($0.rawValue, companion?.shortcuts.binding($0).display ?? "") })
            value["shortcutContext"] = ["tab": selectedTab, "category": settingsCategory, "mode": currentAgentTask?.mode.rawValue ?? "", "composerFocused": window?.firstResponder === composer, "planEnabled": canPerformShortcut(.planMode)] as [String: Any]
            value["appShot"] = companion?.appShot.checkState() ?? [:]
            value["appShotDraftAttachments"] = (currentAgentTask?.attachments ?? []).filter { (currentAgentTask?.draftAttachmentIDs ?? []).contains($0.id) && $0.desktopCapture?.appShot == true }.map { ["id": $0.id, "name": $0.name, "textHash": $0.desktopCapture?.textHash ?? "", "sourceWindowID": $0.desktopCapture?.windowID ?? 0] as [String: Any] }
            value["fileIngress"] = composer.fileIngressDiagnostics; value["fileDragTypes"] = composer.registeredDraggedTypes.map(\.rawValue); value["fileDropOwner"] = composer.dragOwner as Any? ?? NSNull()
            if let window {
                let rect = composer.convert(composer.bounds, to: nil), drag = NSPasteboard(name: .drag)
                value["fileDropGeometry"] = ["windowFrame": NSStringFromRect(window.frame), "composerInWindow": NSStringFromRect(rect), "composerOnScreen": NSStringFromRect(window.convertToScreen(rect)), "mouseInWindow": NSStringFromPoint(window.mouseLocationOutsideOfEventStream), "mouseButtons": NSEvent.pressedMouseButtons, "composerFirstResponder": window.firstResponder === composer, "windowKey": window.isKeyWindow, "backingScale": window.backingScaleFactor, "dragPasteboardTypes": drag.types?.map(\.rawValue) ?? [], "dragPasteboardChangeCount": drag.changeCount] as [String: Any]
            }
            value["draftUndoAvailable"] = windowDraft?.undo.canUndo == true; value["draftRedoAvailable"] = windowDraft?.undo.canRedo == true
            value["composerUsesSharedUndo"] = windowDraft.map { composer.undoManager === $0.undo } ?? false
            value["draftPendingSave"] = windowDraft?.pendingSave == true
            value["historyViewport"] = NSStringFromRect(history.contentView.bounds)
            if let search = messageSearch, let row = messageRows[search.messageID], let local = row.searchMatchRect(), let document = history.documentView {
                let rect = row.convert(local, to: document)
                value["messageSearch"] = ["taskID": search.taskID, "messageID": search.messageID, "query": search.query, "matchRect": NSStringFromRect(rect), "visible": history.contentView.bounds.intersects(rect), "rangeLocation": row.searchRange?.location ?? -1, "rangeLength": row.searchRange?.length ?? 0, "rawSourceShown": row.searchUsesSource] as [String: Any]
            } else { value["messageSearch"] = NSNull() }
        }
        value["inspectorRequested"] = inspectorRequested; value["inspectorVisible"] = !workbenchInspector.isHidden
        value["locationHidden"] = executionLocation.isHidden; value["branchHidden"] = branchControl.isHidden; value["branch"] = branchControl.title
        return value
    }
    func checkOrganizationMove(_ id: String) { agentTaskAction(id, action: "work-mode") }
    func checkExecutorSelection(taskID: String, agentID: String, teamID: String) -> [String: Bool] {
        guard let store = companion?.agentStore, let before = store.task(taskID) else { return ["executorDraftFound": false] }
        selectAgentTask(taskID)
        let count = store.tasks.count, draft = composer.string, files = before.draftAttachmentIDs
        func select(_ value: String) { let item = NSMenuItem(); item.representedObject = value; selectExecutor(item) }
        func preserved() -> Bool { store.tasks.count == count && composer.string == draft && store.task(taskID)?.draft == before.draft && store.task(taskID)?.draftAttachmentIDs == files && agentTaskID == taskID }
        select("agent:" + agentID)
        let agent = store.task(taskID)?.agent?.profile.id == agentID && preserved() && workbenchEmptyTitle.title == store.task(taskID)?.agent?.profile.name
        select("team:" + teamID)
        let team = store.task(taskID)?.team?.team.id == teamID && preserved() && workbenchEmptyTitle.title == store.task(taskID)?.team?.team.name
        select("default")
        return ["executorAgentSelectionPreservesDraftAndAttachment": agent, "executorTeamSelectionPreservesDraftAndAttachment": team,
                "executorDefaultRestoresInSameDraft": preserved() && store.task(taskID)?.agent == nil && store.task(taskID)?.team == nil]
    }
    func checkWorkbenchMotion() -> [String: Any] {
        guard let root = window?.contentView else { return ["success": false, "error": "原生工作台不可用"] }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var checks: [String: Bool] = [:], result: [String: Any] = ["systemReduceMotion": reduced]
        taskMore.wantsLayer = true
        if let layer = taskMore.layer {
            let saved = layer.backgroundColor; layer.backgroundColor = NSColor.clear.cgColor
            AgentWorkbenchTheme.color(layer, AgentWorkbenchTheme.selection)
            let animation = layer.animation(forKey: "selection")
            checks["selectionAnimationMatchesActualSystemSetting"] = reduced ? animation == nil : animation?.duration == 0.12
            result["selectionAnimationDuration"] = animation?.duration ?? 0
            if animation != nil { AgentWorkbenchTheme.cancelMotion(in: root); checks["cancellationClearsActualRunningSelection"] = layer.animation(forKey: "selection") == nil }
            AgentWorkbenchTheme.color(layer, .clear, animated: false)
            checks["immediateSelectionLeavesNoOldAnimation"] = layer.animation(forKey: "selection") == nil; layer.backgroundColor = saved
        }
        if root.bounds.width >= 1080 {
            let original = inspectorRequested
            toggleTaskInspector(); let duration = lastInspectorTransitionDuration; toggleTaskInspector()
            checks["inspectorTransitionMatchesActualSystemSetting"] = duration == (reduced ? 0 : 0.16) && inspectorRequested == original
            result["inspectorTransitionDuration"] = duration
        }
        if let row = toolRows.sorted(by: { $0.key < $1.key }).first?.value {
            let original = row.expanded; row.setExpanded(!original)
            let duration = row.lastTransitionDuration; row.setExpanded(original, animated: false)
            checks["toolTransitionMatchesActualSystemSetting"] = duration == (reduced ? 0 : 0.14) && row.expanded == original
            result["toolTransitionDuration"] = duration
        }
        AgentWorkbenchTheme.cancelMotion(in: root)
        result["checks"] = checks; result["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
        result["scope"] = "Actual NSWorkspace setting, live workbench layers, inspector actions and tool expansion; system setting is never overridden by this check."
        return result
    }
    func checkWorkbench(_ output: URL, actualTask: String, stoppedTask: String?) async -> [String: Any] {
        guard let tasks = companion?.agentStore, let window else { return ["success": false, "error": "原生窗口不可用"] }
        var checks: [String: Bool] = [:], frames: [String: Any] = [:]
        func capture(_ name: String) async {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let root = window.contentView else { return }
            func rect(_ view: NSView) -> [Double] { let value = root.convert(view.bounds, from: view); return [value.minX, root.bounds.height - value.maxY, value.width, value.height].map(Double.init) }
            let views: [String: Any] = ["root": [root.bounds.width, root.bounds.height], "history": rect(history), "inspector": rect(workbenchInspector), "composer": rect(entryToolbar.superview!), "leadingControls": rect(entryLeading), "trailingControls": rect(entryTrailing), "contextControl": rect(taskContext), "contextLabel": taskContext.accessibilityLabel() ?? "", "contextVisibleTitle": taskContext.title, "resumeRowVisible": !workbenchLower.isHidden, "systemReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "inspectorVisible": !workbenchInspector.isHidden, "sidebarWidth": sidebarWidth.constant, "backingScale": window.backingScaleFactor, "windowFrame": NSStringFromRect(window.frame), "windowMinimum": NSStringFromSize(window.minSize), "contentMinimum": NSStringFromSize(window.contentMinSize), "rootFitting": NSStringFromSize(root.fittingSize), "chatFitting": NSStringFromSize(chat.fittingSize), "settingsFitting": NSStringFromSize(settings.fittingSize)]
            frames[name] = views
            if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width.rounded()), pixelsHigh: Int(root.bounds.height.rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                bitmap.size = root.bounds.size; root.cacheDisplay(in: root.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
            }
        }
        func setSize(_ size: NSSize) {
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 1000)
            window.setFrame(NSRect(x: max(screen.minX, screen.midX - size.width / 2), y: max(screen.minY, screen.maxY - size.height), width: size.width, height: size.height), display: true)
            updateWorkbenchLayout(); renderAgentMessages()
        }
        show(tab: "chat"); setSize(NSSize(width: 1200, height: 800)); selectAgentTask(actualTask); inspectorRequested = true; updateWorkbenchLayout()
        await capture("workbench-completed")
        checks["wideMatchesReferenceViewport"] = abs(window.frame.width - 1200) < 1 && abs(window.frame.height - 800) < 1
        checks["wideUsesSelectedThreeColumnLayout"] = abs(sidebarWidth.constant - 231) < 1 && abs(workbenchInspector.bounds.width - 281) < 1 && !workbenchInspector.isHidden
        checks["completedShowsActualArtifactAndSources"] = !tasks.task(actualTask)!.artifacts.isEmpty && workbenchInspector.subviews.count >= 3 && messageColumn.arrangedSubviews.contains { $0 is AgentInspectorFileButton }
        checks["actualToolRowsRetained"] = !toolRows.isEmpty
        if tasks.task(actualTask)!.events.contains(where: { $0.childTaskID != nil }) { checks["actualChildRowsRetained"] = toolRows.values.contains { $0.subviews.contains { ($0 as? NSButton)?.title == "打开子任务" && !$0.isHidden } } }
        checks["contextControlStaysInsideComposer"] = taskContext.superview === entryTrailing
        checks["completedComposerDoesNotReserveBlankFooter"] = workbenchLower.isHidden
        if let root = window.contentView {
            let frame = root.convert(entryToolbar.superview!.bounds, from: entryToolbar.superview!)
            checks["composerBottomMatchesSelectedReference"] = abs(frame.minY - 30) < 1
        }
        checks["composerControlsDoNotOverlapWide"] = !entryLeading.convert(entryLeading.bounds, to: entryToolbar).intersects(entryTrailing.convert(entryTrailing.bounds, to: entryToolbar))
        if let pet = companion?.pet {
            let saved = pet.frame
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            pet.setFrameOrigin(NSPoint(x: window.frame.maxX - 180, y: window.frame.minY + 40))
            companion?.updatePetWorkspaceOcclusion()
            let lowered = pet.level.rawValue
            checks["petIsBelowOverlappingWorkbench"] = pet.frame.intersects(window.frame) && lowered < window.level.rawValue
            window.orderOut(nil); companion?.updatePetWorkspaceOcclusion()
            let restored = pet.level.rawValue, expected = companion?.store.preferences.alwaysOnTop == true ? NSWindow.Level.floating.rawValue : NSWindow.Level.normal.rawValue
            checks["petLevelRestoresAfterWorkspaceHides"] = restored == expected
            frames["petLayering"] = ["loweredLevel": lowered, "restoredLevel": restored, "expectedRestoredLevel": expected, "workbenchLevel": window.level.rawValue, "overlapWasForcedInIsolatedProfile": true]
            pet.setFrame(saved, display: false); window.makeKeyAndOrderFront(nil); companion?.updatePetWorkspaceOcclusion()
        }
        toggleTaskInspector(); checks["recordPaneCanClose"] = workbenchInspector.isHidden
        toggleTaskInspector(); checks["recordPaneCanReopen"] = !workbenchInspector.isHidden
        newAgentTask(); let emptyID = agentTaskID!
        composer.string = "尚未发送的工作台草稿"; composer.didChangeText(); saveAgentDraft()
        await capture("workbench-empty")
        checks["emptyTaskHasOwnStartingState"] = !workbenchEmpty.isHidden && history.isHidden && workbenchInspector.isHidden
        checks["emptyTaskDoesNotDisplayPriorMessages"] = messageColumn.arrangedSubviews.isEmpty && tasks.task(emptyID)?.messages.isEmpty == true
        selectAgentTask(actualTask); selectAgentTask(emptyID)
        checks["draftSurvivesTaskSwitch"] = composer.string == "尚未发送的工作台草稿" && tasks.task(emptyID)?.messages.isEmpty == true
        selectAgentTask(actualTask); previousAgentTask(); checks["backReturnsToPriorTask"] = agentTaskID == emptyID
        nextAgentTask(); checks["forwardRestoresTask"] = agentTaskID == actualTask
        setSize(NSSize(width: 900, height: 640)); await capture("workbench-narrow")
        checks["narrowCollapsesInspector"] = workbenchInspector.isHidden && history.contentView.bounds.width > 550
        checks["composerControlsDoNotOverlapNarrow"] = !entryLeading.convert(entryLeading.bounds, to: entryToolbar).intersects(entryTrailing.convert(entryTrailing.bounds, to: entryToolbar))
        setSize(NSSize(width: 780, height: 540)); await capture("workbench-minimum")
        checks["minimumActuallyReachesRequestedWidth"] = abs(window.frame.width - 780) < 1
        checks["minimumKeepsUsableComposer"] = entryToolbar.bounds.width > 440 && !entryLeading.convert(entryLeading.bounds, to: entryToolbar).intersects(entryTrailing.convert(entryTrailing.bounds, to: entryToolbar))
        if let stoppedTask, tasks.task(stoppedTask) != nil {
            setSize(NSSize(width: 1200, height: 800)); selectAgentTask(stoppedTask); await capture("workbench-stopped")
            checks["actualStoppedTaskHasResumeAndStoppedState"] = tasks.task(stoppedTask)?.status == .stopped && !resumeButton.isHidden && !workbenchBadge.isHidden
            if let binding = tasks.task(stoppedTask)?.agent, (try? tasks.agents.profile(binding.profile.id, workspace: tasks.task(stoppedTask)?.workspace)) == nil {
                resumeAgentTask()
                for _ in 0..<40 { if tasks.task(stoppedTask)?.status == .failed { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
                renderAgentMessages(); await capture("workbench-real-disabled-error")
                checks["disabledAgentProducesActualActionableError"] = tasks.task(stoppedTask)?.status == .failed && !status.isHidden && status.stringValue.contains("未启用")
            }
        }
        selectAgentTask(actualTask); setSize(NSSize(width: 1200, height: 800)); updateWorkbenchLayout()
        await capture("workbench-final")
        return ["success": !checks.isEmpty && checks.values.allSatisfy { $0 }, "checks": checks, "frames": frames, "actualTask": actualTask, "emptyTask": emptyID, "screen": NSScreen.screens.map { ["frame": NSStringFromRect($0.frame), "visibleFrame": NSStringFromRect($0.visibleFrame), "backingScale": $0.backingScaleFactor] }]
    }
}
