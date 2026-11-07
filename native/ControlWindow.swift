import AppKit

final class ComposerView: NSTextView {
    var placeholder = "发消息…" { didSet { needsDisplay = true } }
    var onSend: (() -> Void)?
    var onInputChanged: (() -> Void)?
    var onExtensionKey: ((UInt16) -> Bool)?
    var onEditingEnded: (() -> Void)?
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); if result { onEditingEnded?() }; return result
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), onExtensionKey?(event.keyCode) == true { return }; super.keyDown(with: event)
    }
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

@MainActor final class ControlWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSComboBoxDelegate {
    weak var companion: AppDelegate?
    private var selectedTab = "chat"
    private let chatNav = NSButton(title: "对话", target: nil, action: nil), settingsNav = NSButton(title: "设置", target: nil, action: nil)
    private let pageTitle = NSTextField(labelWithString: "对话"), modelCaption = NSTextField(labelWithString: "")
    private let sidebarWake = NSTextField(labelWithString: ""), listenButton = NSButton(title: "立即聆听", target: nil, action: nil)
    private let stopRecordingButton = NSButton(title: "停止录音", target: nil, action: nil), voiceStopButton = NSButton(title: "停止录音", target: nil, action: nil)
    private let chat = NSView(), settings = NSView()
    private let contentSurface = ContentSurface(), settingsSidebar = NSView(), settingsSearch = NSSearchField()
    private let settingsForm = NSStackView(), settingsScroll = NSScrollView(), settingsPageIcon = NSImageView()
    private let noSettings = NSTextField(labelWithString: "没有匹配设置"), sizeValue = NSTextField(labelWithString: "")
    private let settingsCategories = [("model", "模型", "cpu"), ("voice", "语音", "waveform"), ("screen", "屏幕陪伴", "eye"), ("computer", "电脑操作", "computermouse"), ("desktop", "桌面宠物", "fish"), ("persona", "角色", "person.crop.circle"), ("agent", "Agent", "sparkles"), ("worktrees", "工作树", "arrow.triangle.branch")]
    private var settingsCategory = "model", categoryButtons: [NSButton] = [], chatSidebarViews: [NSView] = []
    private var settingGroups: [(category: String, title: String, keywords: String, view: NSView)] = []
    private var titleLeading: NSLayoutConstraint!
    private let composer = ComposerView(), history = NSScrollView(), messageColumn = NSStackView()
    private var messageRows: [String: ChatMessageRow] = [:], renderedIDs: [String] = []
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
    private var draftSave: DispatchWorkItem?
    private var recordWindow: AgentRecordWindow?
    private var taskModelWindow: AgentTaskModelWindow?
    private var contextWindow: AgentContextWindow?
    private var mcpContentWindow: AgentMCPContentWindow?
    private let taskMCPContext = AgentWorkbenchButton()
    private let taskContext = AgentWorkbenchButton()
    private var gitWindow: AgentGitWindow?
    private var worktreeWindow: AgentWorktreeWindow?
    private var worktreeCreationWindow: AgentWorktreeCreationWindow?
    private var worktreePolicyPanel: AgentWorktreePolicyView?
    private var generalSettingsSave: NSButton?
    private let executionLocation = AgentWorkbenchButton()
    private var knowledgeWindow: AgentKnowledgeWindow?
    private var extensionWindow: AgentExtensionWindow?
    private var profileWindow: AgentProfileWindow?, teamWindow: AgentTeamWindow?
    private var automationWindow: AgentAutomationWindow?
    private let automationButton = AgentWorkbenchButton(title: "自动化", target: nil, action: nil)
    private let extensionPanel = AgentExtensionPanel(), extensionPicker = AgentExtensionPicker()
    private var extensionPickerTask: String?
    private let attachmentButton = NSButton(), draftAttachments = AgentAttachmentStrip()
    private var attachmentWindow: AgentAttachmentWindow?, attachmentImport: Task<Void, Never>?, importTaskID: String?
    private let workbenchBadge = AgentStatusBadge(), workbenchInspector = AgentTaskInspector()
    private let taskBack = AgentWorkbenchButton(), taskForward = AgentWorkbenchButton(), taskMore = AgentWorkbenchButton(), taskModel = AgentWorkbenchButton(), voiceInput = AgentWorkbenchButton()
    private let workbenchEmpty = NSStackView(), emptyBefore = NSView(), emptyAfter = NSView(), emptyProject = AgentWorkbenchButton()
    private let workbenchEmptyTitle = NSButton(title: "新的任务", target: nil, action: nil)
    private let workbenchLower = NSStackView()
    private let entryToolbar = NSView(), entryLeading = NSStackView(), entryTrailing = NSStackView(), inspectorRule = NSView(), headerInspectorRule = NSView()
    private var inspectorWidth: NSLayoutConstraint!, sidebarWidth: NSLayoutConstraint!, entryToolbarHeight: NSLayoutConstraint!, emptyBeforeHeight: NSLayoutConstraint!
    private var workbenchColumnLeading: NSLayoutConstraint!, workbenchColumnTrailing: NSLayoutConstraint!
    private var workbenchChrome: [NSView] = [], inspectorRequested = true
    private var taskNavigation: [String] = [], taskNavigationIndex = -1, navigatingTaskHistory = false
    private var lastInspectorTransitionDuration: TimeInterval = 0

    init(companion: AppDelegate) {
        self.companion = companion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: companion.usesAgent ? 1200 : 980, height: companion.usesAgent ? 774 : 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "蓝色大肥鱼"; window.minSize = NSSize(width: 780, height: 540)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 1)
        window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        if companion.usesAgent { companion.ensureAgent() }
        build()
        if companion.usesAgent { NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityDisplayChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil) }
        refreshPreferences()
        if let task = companion.agentStore?.selected { displayedTask = task.id; composer.string = task.draft ?? ""; taskNavigation = [task.id]; taskNavigationIndex = 0 }
        renderMessages()
        companion.onScaleChange = { [weak self] in self?.scale.doubleValue = $0; self?.sizeValue.stringValue = "\(Int(($0 * 100).rounded()))%" }
        companion.onWakeChange = { [weak self] enabled, status in
            self?.wakeEnabled.state = enabled ? .on : .off; self?.wakeStatus.stringValue = status
            self?.sidebarWake.stringValue = enabled ? status : "语音未开启"; self?.listenButton.title = enabled ? "立即聆听" : "开启语音"
            self?.stopRecordingButton.isEnabled = enabled; self?.voiceStopButton.isEnabled = enabled
            self?.updateWorkbenchVoice()
        }
        companion.screenCompanion.onChange = { [weak self] in self?.updateScreenStatus($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func accessibilityDisplayChanged() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let root = window?.contentView else { return }
        AgentWorkbenchTheme.cancelMotion(in: root); updateWorkbenchLayout()
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
        field.font = .systemFont(ofSize: 13); field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    }
    private func styleNavigation(_ button: NSButton, symbol: String) {
        button.isBordered = false; button.font = .systemFont(ofSize: 14, weight: .medium); button.alignment = .left
        button.imagePosition = .imageLeading; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.image?.size = NSSize(width: 17, height: 17); button.contentTintColor = NSColor(white: 0.18, alpha: 1)
        button.wantsLayer = true; button.layer?.cornerRadius = 9; button.heightAnchor.constraint(equalToConstant: 38).isActive = true
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
        sidebarWake.font = .systemFont(ofSize: 11); sidebarWake.textColor = .secondaryLabelColor
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
            taskSidebar.onNew = { [weak self] in self?.newAgentTask() }
            taskSidebar.onAction = { [weak self] id, action in self?.agentTaskAction(id, action: action) }
        }
        let main = contentSurface; main.translatesAutoresizingMaskIntoConstraints = false; main.wantsLayer = true
        main.layer?.backgroundColor = NSColor.white.cgColor; main.layer?.cornerRadius = 17; main.layer?.masksToBounds = true; content.addSubview(main)
        pageTitle.font = .systemFont(ofSize: 14, weight: .semibold); pageTitle.textColor = .secondaryLabelColor
        pageTitle.lineBreakMode = .byTruncatingTail; pageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageTitle.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(pageTitle)
        settingsPageIcon.translatesAutoresizingMaskIntoConstraints = false; settingsPageIcon.wantsLayer = true
        settingsPageIcon.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1).cgColor; settingsPageIcon.layer?.cornerRadius = 10
        settingsPageIcon.contentTintColor = NSColor(white: 0.25, alpha: 1); main.addSubview(settingsPageIcon)
        titleLeading = pageTitle.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28)
        let panels = NSView(); main.addSubview(panels); panels.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: content.topAnchor, constant: 65), brand.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 25),
            navigation.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 28), navigation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), navigation.widthAnchor.constraint(equalToConstant: 166),
            sideFooter.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 27), sideFooter.trailingAnchor.constraint(equalTo: content.leadingAnchor, constant: 182), sideFooter.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            main.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 200), main.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8), main.topAnchor.constraint(equalTo: content.topAnchor, constant: 8), main.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            pageTitle.topAnchor.constraint(equalTo: main.topAnchor, constant: 22), titleLeading, pageTitle.trailingAnchor.constraint(lessThanOrEqualTo: main.trailingAnchor, constant: -28),
            settingsPageIcon.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28), settingsPageIcon.centerYAnchor.constraint(equalTo: pageTitle.centerYAnchor), settingsPageIcon.widthAnchor.constraint(equalToConstant: 36), settingsPageIcon.heightAnchor.constraint(equalToConstant: 36),
            panels.topAnchor.constraint(equalTo: pageTitle.bottomAnchor, constant: 18), panels.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28), panels.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28), panels.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -24)])
        for panel in [chat, settings] { panels.addSubview(panel); pin(panel, to: panels) }
        buildChat(); buildSettingsSidebar(in: content); buildSettings(); changeTab()
    }
    private func buildWorkbench() {
        guard let window else { return }
        window.backgroundColor = AgentWorkbenchTheme.sidebar; window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        let content = SidebarBackground(); content.wantsLayer = true; window.contentView = content
        let icon = NSImageView(image: NSImage(systemSymbolName: "fish", accessibilityDescription: "小鲸")!)
        icon.contentTintColor = AgentWorkbenchTheme.accent; icon.imageScaling = .scaleProportionallyUpOrDown; icon.widthAnchor.constraint(equalToConstant: 33).isActive = true; icon.heightAnchor.constraint(equalToConstant: 25).isActive = true
        let title = NSTextField(labelWithString: "小鲸"); title.font = .systemFont(ofSize: 16, weight: .semibold)
        let brand = stack([icon, title], spacing: 9); content.addSubview(brand)
        taskSidebar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(taskSidebar)
        taskSidebar.onSelect = { [weak self] id in self?.selectAgentTask(id) }
        taskSidebar.onNew = { [weak self] in self?.newAgentTask() }
        taskSidebar.onNewWorkspace = { [weak self] in self?.chooseProject() }
        taskSidebar.onNewInWorkspace = { [weak self] path in
            guard let self, let tasks = self.companion?.agentStore else { return }; self.saveAgentDraft(); self.selectAgentTask(tasks.create(workspace: path))
        }
        taskSidebar.onAction = { [weak self] id, action in self?.agentTaskAction(id, action: action) }
        let knowledge = AgentWorkbenchButton(title: "项目知识", target: self, action: #selector(showAgentKnowledge))
        let extensions = AgentWorkbenchButton(title: "扩展", target: self, action: #selector(showAgentExtensions))
        settingsNav.tag = 1; settingsNav.target = self; settingsNav.action = #selector(selectTab(_:))
        automationButton.target = self; automationButton.action = #selector(showAutomations)
        for (button, symbol) in [(automationButton as NSButton, "clock.arrow.circlepath"), (knowledge as NSButton, "books.vertical"), (extensions as NSButton, "puzzlepiece.extension"), (settingsNav, "gearshape")] {
            AgentWorkbenchTheme.sidebarControl(button)
            button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 14)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading; button.contentTintColor = .labelColor
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        let footer = stack([AgentWorkbenchTheme.rule(), automationButton, knowledge, extensions, settingsNav], vertical: true, spacing: 6); content.addSubview(footer)
        for button in [automationButton as NSView, knowledge, extensions, settingsNav] { button.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }
        chatSidebarViews = [brand, taskSidebar, footer]
        let main = contentSurface; main.usesWorkbenchSurface = true; main.wantsLayer = true; main.layer?.backgroundColor = AgentWorkbenchTheme.surface.cgColor; main.layer?.cornerRadius = 0
        main.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(main)
        sidebarWidth = main.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 231)
        let leftRule = NSView(); leftRule.wantsLayer = true; leftRule.layer?.backgroundColor = AgentWorkbenchTheme.line.cgColor; content.addSubview(leftRule); leftRule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sidebarWidth, main.trailingAnchor.constraint(equalTo: content.trailingAnchor), main.topAnchor.constraint(equalTo: content.topAnchor), main.bottomAnchor.constraint(equalTo: content.bottomAnchor), leftRule.leadingAnchor.constraint(equalTo: main.leadingAnchor), leftRule.widthAnchor.constraint(equalToConstant: 1), leftRule.topAnchor.constraint(equalTo: content.topAnchor), leftRule.bottomAnchor.constraint(equalTo: content.bottomAnchor), brand.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), brand.topAnchor.constraint(equalTo: content.topAnchor, constant: 55), taskSidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), taskSidebar.trailingAnchor.constraint(equalTo: main.leadingAnchor, constant: -15), taskSidebar.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 22), taskSidebar.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -18), footer.leadingAnchor.constraint(equalTo: taskSidebar.leadingAnchor), footer.trailingAnchor.constraint(equalTo: taskSidebar.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -42)])
        for (button, label, symbol, action) in [(taskBack, "上一个任务", "chevron.left", #selector(previousAgentTask)), (taskForward, "下一个任务", "chevron.right", #selector(nextAgentTask)), (taskMore, "任务操作", "ellipsis", #selector(showTaskMenu(_:)))] {
            AgentWorkbenchTheme.toolbar(button, title: label, symbol: symbol); button.target = self; button.action = action
        }
        taskBack.keyEquivalent = "["; taskBack.keyEquivalentModifierMask = .command; taskForward.keyEquivalent = "]"; taskForward.keyEquivalentModifierMask = .command
        let navigation = stack([taskBack, taskForward], spacing: 2); main.addSubview(navigation)
        pageTitle.font = .systemFont(ofSize: 18, weight: .semibold); pageTitle.lineBreakMode = .byTruncatingTail; pageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageTitle.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(pageTitle); main.addSubview(workbenchBadge)
        titleLeading = pageTitle.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 94)
        projectButton.target = self; projectButton.action = #selector(chooseProject); AgentWorkbenchTheme.toolbar(projectButton, title: "选择项目", symbol: "folder")
        browserButton.target = self; browserButton.action = #selector(showAgentBrowser); AgentWorkbenchTheme.toolbar(browserButton, title: "浏览器", symbol: "rectangle.on.rectangle")
        desktopButton.target = self; desktopButton.action = #selector(showDesktopSettings); AgentWorkbenchTheme.toolbar(desktopButton, title: "电脑操作", symbol: "computermouse")
        gitButton.target = self; gitButton.action = #selector(showAgentGit); AgentWorkbenchTheme.toolbar(gitButton, title: "Git", symbol: "arrow.triangle.branch")
        resultsButton.target = self; resultsButton.action = #selector(toggleTaskInspector); AgentWorkbenchTheme.toolbar(resultsButton, title: "任务记录", symbol: "sidebar.right")
        let actions = stack([projectButton, browserButton, desktopButton, gitButton, resultsButton, taskMore], spacing: 4); main.addSubview(actions)
        let headerRule = AgentWorkbenchTheme.rule(); main.addSubview(headerRule)
        workbenchChrome = [navigation, actions, workbenchBadge]
        settingsPageIcon.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(settingsPageIcon)
        for panel in [chat, settings] { panel.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(panel) }
        buildWorkbenchConversation()
        headerInspectorRule.wantsLayer = true; headerInspectorRule.layer?.backgroundColor = AgentWorkbenchTheme.line.cgColor; headerInspectorRule.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(headerInspectorRule)
        NSLayoutConstraint.activate([headerInspectorRule.leadingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor), headerInspectorRule.widthAnchor.constraint(equalToConstant: 1), headerInspectorRule.topAnchor.constraint(equalTo: main.topAnchor), headerInspectorRule.bottomAnchor.constraint(equalTo: headerRule.topAnchor)])
        NSLayoutConstraint.activate([navigation.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 18), navigation.centerYAnchor.constraint(equalTo: main.topAnchor, constant: 30), titleLeading, pageTitle.centerYAnchor.constraint(equalTo: main.topAnchor, constant: 30), workbenchBadge.leadingAnchor.constraint(equalTo: pageTitle.trailingAnchor, constant: 10), workbenchBadge.centerYAnchor.constraint(equalTo: pageTitle.centerYAnchor), workbenchBadge.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -14), actions.trailingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor, constant: -16), actions.centerYAnchor.constraint(equalTo: pageTitle.centerYAnchor), headerRule.leadingAnchor.constraint(equalTo: main.leadingAnchor), headerRule.trailingAnchor.constraint(equalTo: main.trailingAnchor), headerRule.topAnchor.constraint(equalTo: main.topAnchor, constant: 59), chat.leadingAnchor.constraint(equalTo: main.leadingAnchor), chat.trailingAnchor.constraint(equalTo: main.trailingAnchor), chat.topAnchor.constraint(equalTo: headerRule.bottomAnchor), chat.bottomAnchor.constraint(equalTo: main.bottomAnchor), settings.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28), settings.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28), settings.topAnchor.constraint(equalTo: main.topAnchor, constant: 76), settings.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -24), settingsPageIcon.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28), settingsPageIcon.centerYAnchor.constraint(equalTo: pageTitle.centerYAnchor), settingsPageIcon.widthAnchor.constraint(equalToConstant: 36), settingsPageIcon.heightAnchor.constraint(equalToConstant: 36)])
        buildSettingsSidebar(in: content); buildSettings(); changeTab()
    }
    private func buildWorkbenchConversation() {
        let conversation = NSView(); conversation.translatesAutoresizingMaskIntoConstraints = false; chat.addSubview(conversation); chat.addSubview(workbenchInspector)
        inspectorWidth = workbenchInspector.widthAnchor.constraint(equalToConstant: 281)
        inspectorRule.wantsLayer = true; inspectorRule.layer?.backgroundColor = AgentWorkbenchTheme.line.cgColor; inspectorRule.translatesAutoresizingMaskIntoConstraints = false; chat.addSubview(inspectorRule)
        NSLayoutConstraint.activate([conversation.leadingAnchor.constraint(equalTo: chat.leadingAnchor), conversation.trailingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor), conversation.topAnchor.constraint(equalTo: chat.topAnchor), conversation.bottomAnchor.constraint(equalTo: chat.bottomAnchor), inspectorWidth, workbenchInspector.trailingAnchor.constraint(equalTo: chat.trailingAnchor), workbenchInspector.topAnchor.constraint(equalTo: chat.topAnchor), workbenchInspector.bottomAnchor.constraint(equalTo: chat.bottomAnchor), inspectorRule.leadingAnchor.constraint(equalTo: workbenchInspector.leadingAnchor), inspectorRule.widthAnchor.constraint(equalToConstant: 1), inspectorRule.topAnchor.constraint(equalTo: chat.topAnchor), inspectorRule.bottomAnchor.constraint(equalTo: chat.bottomAnchor)])
        workbenchInspector.onOpen = { [weak self] section, value in
            if value.hasPrefix("canvas://"), let id = self?.companion?.agentStore?.selectedID { self?.openCanvasReference(value, taskID: id) }
            else { self?.presentAgentRecords(section: section); self?.recordWindow?.selectItem(section: section, value: value) }
        }
        workbenchInspector.onShowAll = { [weak self] section in self?.presentAgentRecords(section: section) }
        history.hasVerticalScroller = true; history.drawsBackground = false; history.scrollerStyle = .overlay
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; history.documentView = document
        messageColumn.orientation = .vertical; messageColumn.alignment = .leading; messageColumn.spacing = 20; document.addSubview(messageColumn)
        messageColumn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: history.contentView.widthAnchor), messageColumn.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20), messageColumn.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20), messageColumn.topAnchor.constraint(equalTo: document.topAnchor, constant: 4), messageColumn.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)])
        composer.font = .systemFont(ofSize: 14); composer.textContainerInset = NSSize(width: 2, height: 8); composer.drawsBackground = false; composer.isRichText = false; composer.allowsUndo = true
        composer.isAutomaticQuoteSubstitutionEnabled = false; composer.isAutomaticTextReplacementEnabled = false; composer.autoresizingMask = [.width]; composer.setAccessibilityLabel("消息")
        composer.onSend = { [weak self] in self?.send() }; composer.onInputChanged = { [weak self] in self?.composerChanged() }; composer.onEditingEnded = { [weak self] in self?.dismissExtensionCandidates() }
        composer.onExtensionKey = { [weak self] key in
            guard let self, extensionPickerTask != nil, extensionPanel.isVisible else { return false }
            switch key { case 125: extensionPicker.move(1); case 126: extensionPicker.move(-1); case 36, 48, 76: extensionPicker.pick(); case 53: dismissExtensionCandidates(); default: return false }; return true
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
        entryLeading.orientation = .horizontal; entryLeading.spacing = 8; entryLeading.addArrangedSubview(attachmentButton); entryLeading.addArrangedSubview(taskMCPContext); entryLeading.addArrangedSubview(executionLocation); entryLeading.addArrangedSubview(modePopup); entryLeading.addArrangedSubview(permissionPopup)
        voiceInput.target = self; voiceInput.action = #selector(toggleWorkbenchVoice); AgentWorkbenchTheme.toolbar(voiceInput, title: "语音输入", symbol: "mic")
        entryTrailing.orientation = .horizontal; entryTrailing.spacing = 8; entryTrailing.addArrangedSubview(taskModel); entryTrailing.addArrangedSubview(taskContext); entryTrailing.addArrangedSubview(voiceInput); entryTrailing.addArrangedSubview(sendButton)
        for view in [entryLeading, entryTrailing] { entryToolbar.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        entryToolbarHeight = entryToolbar.heightAnchor.constraint(equalToConstant: 34)
        NSLayoutConstraint.activate([entryToolbarHeight, entryLeading.leadingAnchor.constraint(equalTo: entryToolbar.leadingAnchor), entryLeading.topAnchor.constraint(equalTo: entryToolbar.topAnchor), entryTrailing.trailingAnchor.constraint(equalTo: entryToolbar.trailingAnchor), entryTrailing.bottomAnchor.constraint(equalTo: entryToolbar.bottomAnchor)])
        let entry = NSView(); entry.wantsLayer = true; entry.layer?.cornerRadius = 12; entry.layer?.borderWidth = 1; entry.layer?.borderColor = AgentWorkbenchTheme.line.cgColor; entry.layer?.backgroundColor = AgentWorkbenchTheme.surface.cgColor
        for view in [draftAttachments, input, entryToolbar] { entry.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([draftAttachments.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), draftAttachments.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), draftAttachments.topAnchor.constraint(equalTo: entry.topAnchor, constant: 8), input.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), input.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), input.topAnchor.constraint(equalTo: draftAttachments.bottomAnchor), input.heightAnchor.constraint(equalToConstant: 44), entryToolbar.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 12), entryToolbar.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -10), entryToolbar.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 8), entryToolbar.bottomAnchor.constraint(equalTo: entry.bottomAnchor, constant: -10)])
        let heading = workbenchEmptyTitle; heading.font = .systemFont(ofSize: 24, weight: .semibold); heading.isBordered = false
        heading.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil); heading.imagePosition = .imageTrailing; heading.target = self; heading.action = #selector(chooseExecutor); heading.setAccessibilityLabel("任务执行者")
        emptyProject.title = "选择项目"; emptyProject.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); emptyProject.imagePosition = .imageLeading; emptyProject.isBordered = false; emptyProject.target = self; emptyProject.action = #selector(chooseProject); emptyProject.font = .systemFont(ofSize: 12)
        let add = AgentWorkbenchButton(title: "添加附件", target: self, action: #selector(addAttachments)); add.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil); add.imagePosition = .imageLeading; add.isBordered = false; add.font = .systemFont(ofSize: 12)
        let browse = AgentWorkbenchButton(title: "浏览器", target: self, action: #selector(showAgentBrowser)); browse.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil); browse.imagePosition = .imageLeading; browse.isBordered = false; browse.font = .systemFont(ofSize: 12)
        let shortcuts = stack([emptyProject, add, browse], spacing: 22); workbenchEmpty.orientation = .vertical; workbenchEmpty.alignment = .centerX; workbenchEmpty.spacing = 18; workbenchEmpty.addArrangedSubview(heading); workbenchEmpty.addArrangedSubview(shortcuts)
        emptyBeforeHeight = emptyBefore.heightAnchor.constraint(equalToConstant: 90); emptyBeforeHeight.isActive = true
        emptyAfter.setContentHuggingPriority(.defaultLow, for: .vertical)
        modelCaption.font = .systemFont(ofSize: 10); modelCaption.textColor = .tertiaryLabelColor; modelCaption.alignment = .right; modelCaption.lineBreakMode = .byTruncatingTail
        resumeButton.target = self; resumeButton.action = #selector(resumeAgentTask); resumeButton.bezelStyle = .inline; resumeButton.font = .systemFont(ofSize: 12)
        taskContext.title = ""; taskContext.isBordered = false; taskContext.font = .systemFont(ofSize: 11); taskContext.contentTintColor = .secondaryLabelColor; taskContext.image = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: nil); taskContext.image?.size = NSSize(width: 15, height: 15); taskContext.imagePosition = .imageOnly; taskContext.target = self; taskContext.action = #selector(showTaskContext)
        taskContext.heightAnchor.constraint(equalToConstant: 28).isActive = true; taskContext.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true; taskContext.setContentHuggingPriority(.required, for: .horizontal)
        let lower = workbenchLower; lower.orientation = .horizontal; lower.spacing = 8; lower.addArrangedSubview(resumeButton); lower.addArrangedSubview(NSView()); lower.addArrangedSubview(modelCaption)
        status.font = .systemFont(ofSize: 12); status.lineBreakMode = .byTruncatingTail; status.isHidden = true
        configureApprovalPanel()
        let column = stack([emptyBefore, workbenchEmpty, history, approvalPanel, status, entry, lower, emptyAfter], vertical: true, spacing: 14)
        conversation.addSubview(column)
        workbenchColumnLeading = column.leadingAnchor.constraint(equalTo: conversation.leadingAnchor, constant: 18)
        workbenchColumnTrailing = column.trailingAnchor.constraint(equalTo: conversation.trailingAnchor, constant: -18)
        NSLayoutConstraint.activate([workbenchColumnLeading, workbenchColumnTrailing, column.topAnchor.constraint(equalTo: conversation.topAnchor, constant: 28), column.bottomAnchor.constraint(equalTo: conversation.bottomAnchor, constant: -30)])
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        history.setContentHuggingPriority(.defaultLow, for: .vertical); history.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
    }
    private func updateWorkbenchLayout(animated: Bool = false) {
        guard companion?.usesAgent == true, inspectorWidth != nil, let task = companion?.agentStore?.selected else { return }
        let configuring = selectedTab == "settings", width = window?.contentView?.bounds.width ?? 1200
        let hasMessages = task.messages.contains { ["user", "assistant"].contains($0.role) && $0.nativeContext != true }
        let hasRecords = !task.events.isEmpty || !task.artifacts.isEmpty || !(task.canvases ?? []).isEmpty || !task.sources.isEmpty || !task.plan.isEmpty
        let showInspector = !configuring && hasRecords && inspectorRequested && width >= 1080
        let target: CGFloat = showInspector ? 281 : 0
        sidebarWidth.constant = width < 900 ? 218 : 231
        let columnInset: CGFloat = hasMessages ? 18 : max(18, (width - sidebarWidth.constant - target - 760) / 2)
        workbenchColumnLeading.constant = columnInset; workbenchColumnTrailing.constant = -columnInset
        workbenchInspector.isHidden = !showInspector; inspectorRule.isHidden = !showInspector; headerInspectorRule.isHidden = !showInspector
        pageTitle.isHidden = !configuring && !hasMessages
        workbenchBadge.isHidden = configuring || !hasMessages
        workbenchEmpty.isHidden = hasMessages; emptyBefore.isHidden = hasMessages; emptyAfter.isHidden = hasMessages; history.isHidden = !hasMessages
        emptyBeforeHeight.constant = max(22, min(120, ((window?.contentView?.bounds.height ?? 800) - 320) * 0.21))
        workbenchEmptyTitle.title = task.team?.team.name ?? task.agent?.profile.name ?? "新的任务"
        workbenchEmptyTitle.isEnabled = task.canChooseExecutor
        emptyProject.title = task.workspaceDisplayName ?? "选择项目"; emptyProject.toolTip = task.workspace
        composer.placeholder = hasMessages ? "添加要求…" : "描述任务…"
        workbenchBadge.update(task); workbenchInspector.update(task)
        taskBack.isEnabled = taskNavigationIndex > 0; taskForward.isEnabled = taskNavigationIndex >= 0 && taskNavigationIndex + 1 < taskNavigation.count
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
        let hasMCP = companion?.agentStore?.mcp.servers.contains { $0.enabled && (task.agent?.mcpServers.contains($0.id) ?? true) } == true
        taskMCPContext.isHidden = !hasMCP; taskMCPContext.isEnabled = !task.archived && !["hook", "wiki"].contains(task.kind ?? "")
        let preferred = entryLeading.fittingSize.width + entryTrailing.fittingSize.width + 18
        let available = width - sidebarWidth.constant - target - columnInset * 2 - 22
        entryToolbarHeight.constant = available < preferred ? 64 : 34
        updateWorkbenchVoice()
        lastInspectorTransitionDuration = AgentWorkbenchTheme.layout(in: window?.contentView, duration: 0.16, animated: animated && window?.inLiveResize != true) { self.inspectorWidth.constant = target }
        messageRows.values.forEach { $0.fit(width: history.contentView.bounds.width - 40) }
    }
    @objc private func toggleTaskInspector() {
        guard (window?.contentView?.bounds.width ?? 0) >= 1080 else { presentAgentRecords(section: 4); return }
        inspectorRequested.toggle(); updateWorkbenchLayout(animated: true)
    }
    @objc private func previousAgentTask() {
        guard taskNavigationIndex > 0 else { return }; taskNavigationIndex -= 1; navigatingTaskHistory = true; defer { navigatingTaskHistory = false }; selectAgentTask(taskNavigation[taskNavigationIndex])
    }
    @objc private func nextAgentTask() {
        guard taskNavigationIndex + 1 < taskNavigation.count else { return }; taskNavigationIndex += 1; navigatingTaskHistory = true; defer { navigatingTaskHistory = false }; selectAgentTask(taskNavigation[taskNavigationIndex])
    }
    @objc private func showTaskMenu(_ sender: NSButton) {
        guard let task = companion?.agentStore?.selected else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, action) in [("重命名", "rename"), (task.pinned ? "取消置顶" : "置顶", "pin"), ("创建分支", "fork"), (task.archived ? "恢复任务" : "归档任务", "archive")] {
            let item = NSMenuItem(title: title, action: #selector(taskMenuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = [task.id, action]; item.isEnabled = task.status != .running; menu.addItem(item)
        }
        menu.addItem(.separator())
        let records = NSMenuItem(title: "完整任务记录", action: #selector(showAgentRecords), keyEquivalent: ""); records.target = self; menu.addItem(records)
        let recap = NSMenuItem(title: "任务回顾", action: #selector(showTaskRecap), keyEquivalent: ""); recap.target = self; menu.addItem(recap)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func taskMenuAction(_ sender: NSMenuItem) { if let value = sender.representedObject as? [String], value.count == 2 { agentTaskAction(value[0], action: value[1]) } }
    @objc private func showTaskModelMenu(_ sender: NSButton) {
        guard let runtime = companion?.agentRuntime, let id = companion?.agentStore?.selectedID else { return }
        taskModelWindow?.window?.performClose(nil); taskModelWindow = AgentTaskModelWindow(runtime: runtime, taskID: id)
        taskModelWindow?.showWindow(nil); taskModelWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showTaskContext() { presentTaskContext(section: 0) }
    @objc private func showTaskRecap() { presentTaskContext(section: 1) }
    private func presentTaskContext(section: Int) {
        guard let runtime = companion?.agentRuntime, let id = companion?.agentStore?.selectedID else { return }
        contextWindow?.window?.performClose(nil); contextWindow = AgentContextWindow(runtime: runtime, taskID: id, section: section)
        contextWindow?.showWindow(nil); contextWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showTaskMCPContent() { if let id = companion?.agentStore?.selectedID { presentMCPContent(taskID: id) } }
    func presentMCPContent(taskID: String, serverID: String? = nil) {
        guard let store = companion?.agentStore, store.task(taskID) != nil else { return }
        if store.selectedID == taskID { saveAgentDraft() }
        mcpContentWindow?.window?.performClose(nil)
        mcpContentWindow = AgentMCPContentWindow(store: store, taskID: taskID, serverID: serverID) { [weak self] text, ids in
            guard let self, let previous = store.task(taskID), !previous.archived, !["wiki", "hook"].contains(previous.kind ?? "") else { throw PetError("任务已关闭，未加入草稿") }
            let visible = store.selectedID == taskID && self.displayedTask == taskID
            let draft = visible ? self.composer.string : previous.draft ?? ""
            let combined = draft + (text.isEmpty ? "" : (draft.isEmpty ? "" : "\n\n") + text)
            guard combined.utf8.count <= 100_000, (previous.draftAttachmentIDs?.count ?? 0) + ids.count <= 6,
                  ids.allSatisfy({ id in previous.attachments?.contains(where: { $0.id == id }) == true }) else { throw PetError("草稿超过 100KB 或附件超过 6 份，请先缩减草稿") }
            store.update(taskID, persist: false) { record in record.draft = combined.isEmpty ? nil : combined; if !ids.isEmpty { if record.draftAttachmentIDs == nil { record.draftAttachmentIDs = [] }; record.draftAttachmentIDs?.append(contentsOf: ids) } }
            do { try store.save(taskID) }
            catch { store.update(taskID, persist: false) { $0.draft = previous.draft; $0.draftAttachmentIDs = previous.draftAttachmentIDs }; throw error }
            if visible { self.composer.string = combined; self.composer.didChangeText() }; self.renderMessages()
        }
        mcpContentWindow?.showWindow(nil); mcpContentWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func openTaskModelSettings() { saveAgentDraft(); selectedTab = "settings"; settingsCategory = "model"; settingsSearch.stringValue = ""; changeTab() }
    @objc private func toggleWorkbenchVoice() { if companion?.store.preferences.wakeEnabled == true { companion?.stopRecording() } else { companion?.listenNow() } }
    private func updateWorkbenchVoice() {
        guard companion?.usesAgent == true else { return }
        let enabled = companion?.store.preferences.wakeEnabled == true
        voiceInput.image = NSImage(systemSymbolName: enabled ? "stop.circle" : "mic", accessibilityDescription: nil)
        voiceInput.contentTintColor = enabled ? .systemRed : .secondaryLabelColor; voiceInput.toolTip = enabled ? "停止录音" : "语音输入"; voiceInput.setAccessibilityLabel(voiceInput.toolTip)
    }
    private func buildSettingsSidebar(in content: NSView) {
        content.addSubview(settingsSidebar); settingsSidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([settingsSidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), settingsSidebar.widthAnchor.constraint(equalToConstant: companion?.usesAgent == true ? 231 : 200), settingsSidebar.topAnchor.constraint(equalTo: content.topAnchor), settingsSidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let back = NSButton(title: "返回对话", target: self, action: #selector(returnToChat))
        back.isBordered = false; back.alignment = .left; back.font = .systemFont(ofSize: 13)
        back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil); back.imagePosition = .imageLeading
        back.contentTintColor = .secondaryLabelColor
        settingsSearch.placeholderString = "搜索设置…"; settingsSearch.setAccessibilityLabel("搜索设置"); settingsSearch.delegate = self
        let caption = NSTextField(labelWithString: "偏好设置"); caption.font = .systemFont(ofSize: 11); caption.textColor = .tertiaryLabelColor
        let navigation = stack([], vertical: true, spacing: 5)
        for (index, item) in settingsCategories.enumerated() {
            let button = NSButton(title: item.1, target: self, action: #selector(selectSettingsCategory(_:)))
            button.tag = index; styleNavigation(button, symbol: item.2); navigation.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true; categoryButtons.append(button)
        }
        let column = stack([back, settingsSearch, caption, navigation], vertical: true, spacing: 18)
        settingsSidebar.addSubview(column)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: settingsSidebar.topAnchor, constant: 58), column.leadingAnchor.constraint(equalTo: settingsSidebar.leadingAnchor, constant: 16), column.trailingAnchor.constraint(equalTo: settingsSidebar.trailingAnchor, constant: -16), settingsSearch.widthAnchor.constraint(equalTo: column.widthAnchor), settingsSearch.heightAnchor.constraint(equalToConstant: 28), navigation.widthAnchor.constraint(equalTo: column.widthAnchor)])
    }
    @objc private func returnToChat() { companion?.screenCompanion.interaction(); selectedTab = "chat"; changeTab(); window?.makeFirstResponder(composer) }
    @objc private func selectSettingsCategory(_ sender: NSButton) {
        window?.makeFirstResponder(sender); settingsCategory = settingsCategories[sender.tag].0
        settingsSearch.stringValue = ""; updateSettingsSections()
    }
    private func updateSettingsSections() {
        let query = settingsSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selected = settingsCategories.first { $0.0 == settingsCategory } ?? settingsCategories[0]
        pageTitle.stringValue = query.isEmpty ? selected.1 : "搜索结果"
        settingsPageIcon.image = NSImage(systemSymbolName: query.isEmpty ? selected.2 : "magnifyingglass", accessibilityDescription: nil)
        settingsPageIcon.image?.size = NSSize(width: 21, height: 21)
        for (index, button) in categoryButtons.enumerated() {
            let active = query.isEmpty && settingsCategories[index].0 == settingsCategory
            button.state = active ? .on : .off; button.layer?.backgroundColor = active ? NSColor(white: 0, alpha: 0.07).cgColor : NSColor.clear.cgColor
        }
        let matches = settingGroups.filter { query.isEmpty ? $0.category == settingsCategory : ($0.title + " " + $0.keywords).lowercased().contains(query) }
        generalSettingsSave?.isHidden = !matches.isEmpty && matches.allSatisfy { ["worktrees", "computer"].contains($0.category) }
        settingsForm.arrangedSubviews.forEach { settingsForm.removeArrangedSubview($0); $0.removeFromSuperview() }
        for group in matches {
            settingsForm.addArrangedSubview(group.view); group.view.widthAnchor.constraint(equalTo: settingsForm.widthAnchor).isActive = true
        }
        if matches.isEmpty { settingsForm.addArrangedSubview(noSettings) }
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
            case 36, 48, 76: extensionPicker.pick()
            case 53: dismissExtensionCandidates()
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
        modelCaption.font = .systemFont(ofSize: 11); modelCaption.textColor = .secondaryLabelColor
        attachmentButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "添加附件"); attachmentButton.isBordered = false
        attachmentButton.target = self; attachmentButton.action = #selector(addAttachments); attachmentButton.toolTip = "添加附件"
        attachmentButton.widthAnchor.constraint(equalToConstant: 24).isActive = true; attachmentButton.isHidden = companion?.usesAgent != true
        let fill = NSView(); let entryBar = stack([attachmentButton, modelCaption, fill, sendButton], spacing: 8)
        let entry = NSView(); entry.translatesAutoresizingMaskIntoConstraints = false; entry.wantsLayer = true
        entry.layer?.backgroundColor = NSColor(white: 0.995, alpha: 1).cgColor; entry.layer?.cornerRadius = 16
        entry.layer?.borderWidth = 1; entry.layer?.borderColor = NSColor(white: 0.90, alpha: 1).cgColor
        entry.addSubview(draftAttachments); entry.addSubview(input); entry.addSubview(entryBar); input.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            draftAttachments.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), draftAttachments.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), draftAttachments.topAnchor.constraint(equalTo: entry.topAnchor, constant: 8),
            input.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), input.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), input.topAnchor.constraint(equalTo: draftAttachments.bottomAnchor, constant: 0), input.heightAnchor.constraint(equalToConstant: 60),
            entryBar.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 16), entryBar.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -10), entryBar.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 4), entryBar.bottomAnchor.constraint(equalTo: entry.bottomAnchor, constant: -10)])
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
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
            let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13, weight: .medium); heading.textColor = .secondaryLabelColor
            let card = NSView(); card.translatesAutoresizingMaskIntoConstraints = false; card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.white.cgColor; card.layer?.cornerRadius = 12
            card.layer?.borderColor = NSColor(white: 0.9, alpha: 1).cgColor; card.layer?.borderWidth = 1
            body = stack([], vertical: true, spacing: 0); body.alignment = .centerX
            card.addSubview(body); pin(body, to: card)
            let section = stack([heading, card], vertical: true, spacing: 9)
            card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            settingGroups.append((category, title, keywords, section))
        }
        func row(_ text: String, _ control: NSView) {
            if !body.arrangedSubviews.isEmpty {
                let rule = NSBox(); rule.boxType = .separator; body.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            }
            let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 13); label.textColor = NSColor(white: 0.32, alpha: 1)
            label.widthAnchor.constraint(equalToConstant: 88).isActive = true
            let items: [NSView] = text.isEmpty ? [control] : control is NSSwitch ? [label, NSView(), control] : [label, control]
            let line = stack(items, spacing: 12), wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(line); body.addArrangedSubview(wrap)
            NSLayoutConstraint.activate([wrap.widthAnchor.constraint(equalTo: body.widthAnchor),
                line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16), line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
                line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10), line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10), line.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)])
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
        group("model", "服务", "模型 接口 地址 URL Token 密钥 连接 检测 API")
        endpoint.delegate = self; model.delegate = self; apiKey.delegate = self
        model.completes = false; model.numberOfVisibleItems = 8
        checkModelButton.bezelStyle = .rounded; checkModelButton.target = self; checkModelButton.action = #selector(checkModel)
        modelStatus.font = .systemFont(ofSize: 12); modelStatus.textColor = .secondaryLabelColor
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
        for label in [contextMaximum, replyMaximum] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor }
        row("视觉理解", vision); row("思考程度", reasoning)
        row("上下文", stack([contextTokens, NSTextField(labelWithString: "tokens"), contextMaximum], spacing: 6))
        row("回复上限", stack([replyTokens, NSTextField(labelWithString: "tokens"), replyMaximum], spacing: 6))
        group("voice", "MiniMax", "语音 声音 回复 接口 Token 密钥 模型 音色 MiniMax API")
        row("语音回复", voiceEnabled); row("接口", voiceEndpoint)
        row("Token", secret(voiceKey, preview: voicePreview, replace: voiceReplace, copy: #selector(copyVoice), edit: #selector(replaceVoice), action: #selector(removeVoice)))
        row("模型", voiceModel); row("音色", voiceID)
        group("voice", "唤醒与聆听", "语音 唤醒 关键词 麦克风 聆听 停顿 等待 状态")
        row("语音唤醒", wakeEnabled); row("唤醒词", wakePhrase)
        pauseWait.addItems(withTitles: ["2 秒", "3 秒", "5 秒"]); row("停顿等待", pauseWait)
        wakeStatus.font = .systemFont(ofSize: 12); wakeStatus.textColor = .secondaryLabelColor; row("状态", wakeStatus)
        row("", voiceStopButton)
        group("screen", "闲置时陪你看看", "屏幕 陪伴 观察 视觉 视频 评论 自动 间隔 免打扰 授权 权限")
        screenEnabled.setAccessibilityLabel("闲置时观察屏幕"); row("自动观察", screenEnabled)
        screenInterval.addItems(withTitles: ["1 分钟", "3 分钟", "5 分钟", "10 分钟", "15 分钟"]); row("观察间隔", screenInterval)
        screenTarget.font = .systemFont(ofSize: 12); screenTarget.textColor = .secondaryLabelColor
        screenTarget.lineBreakMode = .byTruncatingMiddle; screenTarget.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row("图像发送至", screenTarget)
        screenStatus.font = .systemFont(ofSize: 12); screenStatus.textColor = .secondaryLabelColor
        screenStatus.lineBreakMode = .byTruncatingTail
        row("状态", screenStatus)
        for (button, action) in [(screenPermission, #selector(grantScreenPermission)), (screenNow, #selector(lookAtScreen)), (screenQuiet, #selector(quietScreen))] {
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12); button.target = self; button.action = action
        }
        row("", stack([screenNow, screenPermission, screenQuiet], spacing: 8))
        let screenScope = NSTextField(wrappingLabelWithString: "只看当前应用窗口的一帧，不保存截图。")
        screenScope.font = .systemFont(ofSize: 12); screenScope.textColor = .secondaryLabelColor; row("", screenScope)
        group("desktop", "显示与动画", "桌面 宠物 角色 置顶 动画 性能 节能 大小 缩放 复位 位置")
        row("窗口置顶", onTop); performance.addItems(withTitles: ["自动节能", "流畅", "暂停"]); row("动画", performance)
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); sizeValue.textColor = .secondaryLabelColor
        sizeValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        scale.target = self; scale.action = #selector(scaleChanged); row("大小", stack([scale, sizeValue], spacing: 12))
        let resetPosition = NSButton(title: "复位位置", target: companion, action: #selector(AppDelegate.resetPosition))
        row("", stack([resetPosition, NSView()], spacing: 8))
        group("persona", "人设", "角色 人设 性格 提示词 persona")
        persona.usesSingleLineMode = false; persona.lineBreakMode = .byWordWrapping
        persona.heightAnchor.constraint(equalToConstant: 120).isActive = true; row("", persona)
        group("agent", "记忆与指令", "Agent 记忆 全局 项目 指令 AGENTS 摘要 上下文 扩展 Skills 命令")
        let memory = NSButton(title: "管理记忆", target: self, action: #selector(openAgentMemory))
        let extensions = NSButton(title: "管理扩展", target: self, action: #selector(showAgentExtensions))
        let worktrees = NSButton(title: "工作树", target: self, action: #selector(showWorktrees))
        row("", stack([memory, extensions, worktrees, NSView()], spacing: 8))
        if let store = companion?.agentStore {
            group("computer", "电脑操作", "电脑操作 Computer Use 窗口 截图 辅助功能 屏幕录制 权限")
            let desktopPanel = AgentDesktopSettingsView(desktop: store.desktop); desktopSettings = desktopPanel; row("", desktopPanel)
            group("worktrees", "保留与回收", "工作树 保留 自动 回收 备份 恢复 项目")
            let panel = AgentWorktreePolicyView(store: store) { [weak self] id in self?.showAgentTask(id); self?.show(tab: "chat") }
            worktreePolicyPanel = panel; row("", panel)
        }
        noSettings.font = .systemFont(ofSize: 14); noSettings.textColor = .secondaryLabelColor
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings)); save.isBordered = false
        generalSettingsSave = save
        save.wantsLayer = true; save.layer?.cornerRadius = 9; save.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        save.contentTintColor = .white; save.font = .systemFont(ofSize: 13, weight: .medium)
        save.widthAnchor.constraint(equalToConstant: 76).isActive = true; save.heightAnchor.constraint(equalToConstant: 34).isActive = true
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        savedStatus.font = .systemFont(ofSize: 12); savedStatus.textColor = .secondaryLabelColor
        let bottom = stack([savedStatus, NSView(), save]), column = stack([settingsScroll, bottom], vertical: true, spacing: 18)
        settings.addSubview(column); pin(column, to: settings)
        settingsScroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    func show(tab: String) {
        if window?.isVisible != true { refreshPreferences() }
        selectedTab = tab == "settings" ? "settings" : "chat"; changeTab()
        renderMessages(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if tab != "settings" { window?.makeFirstResponder(composer) }
        companion?.updatePetWorkspaceOcclusion()
    }
    @objc private func selectTab(_ sender: NSButton) { companion?.screenCompanion.interaction(); selectedTab = sender.tag == 0 ? "chat" : "settings"; changeTab() }
    private func changeTab() {
        if selectedTab != "chat" { dismissExtensionCandidates() }
        chat.isHidden = selectedTab != "chat"; settings.isHidden = selectedTab != "settings"
        let configuring = selectedTab == "settings"
        settingsSidebar.isHidden = !configuring; chatSidebarViews.forEach { $0.isHidden = configuring }
        contentSurface.showsSettings = configuring; settingsPageIcon.isHidden = !configuring
        titleLeading.constant = configuring ? 80 : companion?.usesAgent == true ? 94 : 28
        pageTitle.font = .systemFont(ofSize: configuring ? 22 : companion?.usesAgent == true ? 18 : 14, weight: .semibold)
        pageTitle.textColor = companion?.usesAgent == true || configuring ? .labelColor : .secondaryLabelColor
        workbenchChrome.forEach { $0.isHidden = configuring }
        if configuring { updateSettingsSections() } else { pageTitle.stringValue = companion?.agentStore?.selected?.title ?? "对话" }
        chatNav.layer?.backgroundColor = selectedTab == "chat" ? NSColor(white: 0, alpha: 0.07).cgColor : NSColor.clear.cgColor
        settingsNav.layer?.backgroundColor = selectedTab == "settings" ? NSColor(white: 0, alpha: 0.07).cgColor : NSColor.clear.cgColor
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
            savedStatus.stringValue = "已复制"; savedStatus.textColor = .secondaryLabelColor
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
        modelStatus.stringValue = "未检测"; modelStatus.textColor = .secondaryLabelColor; modelStatus.toolTip = nil
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
            checkModelButton.title = "取消"; modelStatus.stringValue = "检测中"; modelStatus.textColor = .secondaryLabelColor
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
            refreshPreferences(); savedStatus.stringValue = "已保存"; savedStatus.textColor = .secondaryLabelColor
        } catch { savedStatus.stringValue = error.localizedDescription; savedStatus.textColor = .systemRed }
    }
    @objc private func send() {
        guard let companion else { return }
        guard importTaskID != companion.agentStore?.selectedID || attachmentImport == nil else { return }
        if let task = companion.agentStore?.selected, task.kind == "hook" { companion.agentRuntime?.cancel(task.id); return }
        let files = companion.agentStore?.selected?.draftAttachmentIDs ?? []
        if companion.usesAgent, files.isEmpty, composer.string.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
            if companion.agentRuntime?.submit(composer.string) == true { composer.string = ""; composer.undoManager?.removeAllActions(); composer.didChangeText(); saveAgentDraft(); renderMessages() }
            presentTaskContext(section: 0); return
        }
        if extensionPickerTask != nil && extensionPanel.isVisible { extensionPicker.pick(); return }
        if let pair = visibleApproval, pair.task != companion.agentStore?.selectedID,
           companion.agentStore?.task(pair.task)?.pendingCalls.first?.name == "ask_user" {
            guard files.isEmpty else { setStatus("请在子任务中添加答复附件", error: true); return }
            if companion.agentRuntime?.submit(composer.string, taskID: pair.task) == true { composer.string = ""; composer.didChangeText(); saveAgentDraft(); renderMessages() }
            return
        }
        if busy && (companion.usesAgent == false || (composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty)) { companion.cancelConversation(); return }
        if companion.send(composer.string, attachmentIDs: files) { composer.string = ""; composer.undoManager?.removeAllActions(); composer.didChangeText(); saveAgentDraft(); renderMessages() }
    }
    @objc private func clear() {
        if let id = companion?.agentStore?.selectedID { agentTaskAction(id, action: "archive") }
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
        status.stringValue = text; status.textColor = error ? .systemRed : .secondaryLabelColor
        status.isHidden = text.isEmpty
        if settings.isHidden == false {
            savedStatus.stringValue = text; savedStatus.textColor = error ? .systemRed : .secondaryLabelColor
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
    func windowDidMiniaturize(_ notification: Notification) { companion?.updatePetWorkspaceOcclusion() }
    func windowDidDeminiaturize(_ notification: Notification) { companion?.updatePetWorkspaceOcclusion() }
    func windowDidBecomeKey(_ notification: Notification) { companion?.updatePetWorkspaceOcclusion() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissExtensionCandidates()
        saveAgentDraft()
        if modelCheck != nil { invalidateModelCheck() }
        sender.orderOut(nil); companion?.updatePetWorkspaceOcclusion(); return false
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
        if companion?.agentStore?.selected?.kind == "hook" {
            sendButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止校验")
            sendButton.setAccessibilityLabel("停止校验"); sendButton.isEnabled = busy; return
        }
        let files = companion?.agentStore?.selected?.draftAttachmentIDs ?? []
        let stopping = busy && (companion?.usesAgent != true || (composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty))
        sendButton.image = NSImage(systemSymbolName: stopping ? "stop.fill" : "arrow.up", accessibilityDescription: stopping ? "停止任务" : busy ? "补充要求" : "发送")
        sendButton.setAccessibilityLabel(stopping ? "停止任务" : busy ? "补充要求" : "发送")
        sendButton.isEnabled = importTaskID != companion?.agentStore?.selectedID || attachmentImport == nil
    }
    @objc func addAttachments() {
        guard let store = companion?.agentStore, let task = store.selected, !task.archived, !["wiki", "hook"].contains(task.kind ?? ""), let window else { return }
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
    func beginAttachmentImport(_ urls: [URL], store: AgentStore, taskID: String) {
        importTaskID = taskID
        attachmentImport = Task { [weak self] in
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
        renderMessages()
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
        attachmentButton.isEnabled = !task.archived && task.kind != "wiki" && (attachmentImport == nil || importing)
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
    func saveAgentDraft() {
        draftSave?.cancel(); draftSave = nil
        guard let tasks = companion?.agentStore, let id = displayedTask, (tasks.task(id)?.draft ?? "") != composer.string else { return }
        tasks.update(id) { $0.draft = composer.string }
    }
    func selectAgentTask(_ id: String) {
        dismissExtensionCandidates()
        guard let tasks = companion?.agentStore, tasks.task(id) != nil else { return }
        if !navigatingTaskHistory, taskNavigationIndex < 0 || taskNavigation[taskNavigationIndex] != id {
            if taskNavigationIndex + 1 < taskNavigation.count { taskNavigation.removeSubrange((taskNavigationIndex + 1)..<taskNavigation.count) }
            taskNavigation.append(id); taskNavigationIndex = taskNavigation.count - 1
        }
        saveAgentDraft(); tasks.selectedID = id; displayedTask = id
        composer.string = tasks.task(id)?.draft ?? ""; composer.needsDisplay = true
        composer.undoManager?.removeAllActions()
        messageColumn.arrangedSubviews.forEach { messageColumn.removeArrangedSubview($0); $0.removeFromSuperview() }
        renderedIDs = []; messageRows = [:]; toolRows = [:]
        selectedTab = "chat"; changeTab(); renderAgentMessages(); window?.makeFirstResponder(composer)
        companion?.refreshAgentAnimation(); companion?.refreshVoiceBusy(); companion?.startPendingVoiceListen()
    }
    @objc func newAgentTask() {
        guard let tasks = companion?.agentStore else { return }; saveAgentDraft()
        let previous = tasks.selected
        let id = tasks.create(workspace: previous?.workspace, mode: .agent)
        selectAgentTask(id)
    }
    @objc private func chooseExecutor() {
        guard let store = companion?.agentStore, let task = store.selected, task.canChooseExecutor else { return }
        let menu = NSMenu()
        func item(_ title: String, _ value: String, selected: Bool = false, available: Bool = true) {
            let entry = NSMenuItem(title: title, action: #selector(selectExecutor(_:)), keyEquivalent: ""); entry.target = self; entry.representedObject = value; entry.state = selected ? .on : .off; entry.isEnabled = available; menu.addItem(entry)
        }
        item("小鲸", "default", selected: task.agent == nil)
        do {
            let profiles = try store.agents.list(enabledOnly: true), teams = try store.teams.list().filter(\.enabled)
            if !profiles.isEmpty { menu.addItem(.separator()); menu.addItem(NSMenuItem.sectionHeader(title: "自定义 Agent")) }
            for value in profiles { item(value.name, "agent:" + value.id, selected: task.team == nil && task.agent?.profile.id == value.id) }
            if !teams.isEmpty { menu.addItem(.separator()); menu.addItem(NSMenuItem.sectionHeader(title: "Agent 团队")) }
            for value in teams { let available = (try? store.teams.team(value.id, store: store)) != nil; item(value.name + (available ? "" : " · 成员不可用"), "team:" + value.id, selected: task.team?.team.id == value.id, available: available) }
        } catch { setStatus(error.localizedDescription, error: true) }
        menu.addItem(.separator()); item("管理 Agent…", "manage-agents"); item("管理团队…", "manage-teams")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: workbenchEmptyTitle.bounds.height + 4), in: workbenchEmptyTitle)
    }
    @objc private func selectExecutor(_ sender: NSMenuItem) {
        guard let store = companion?.agentStore, let task = store.selected, let value = sender.representedObject as? String else { return }
        saveAgentDraft()
        if value == "manage-agents" {
            let manager = AgentProfileWindow(store: store, workspace: task.workspace); manager.onUse = { [weak self] in self?.selectAgentTask($0) }; profileWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil); return
        }
        if value == "manage-teams" {
            let manager = AgentTeamWindow(store: store, workspace: task.workspace); manager.onUse = { [weak self] in self?.selectAgentTask($0) }; teamWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil); return
        }
        do {
            guard task.canChooseExecutor else { throw PetError("执行者只能在发送前选择") }
            if value.hasPrefix("team:") { try store.teams.configureDraft(String(value.dropFirst(5)), taskID: task.id, store: store) }
            else if value == "default" || value.hasPrefix("agent:") { try store.agents.configureDraft(value == "default" ? nil : String(value.dropFirst(6)), taskID: task.id, store: store) }
            renderAgentMessages()
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    func agentTaskAction(_ id: String, action: String) {
        guard let tasks = companion?.agentStore, let task = tasks.task(id), task.status != .running else { return }
        switch action {
        case "rename":
            let alert = NSAlert(); alert.messageText = "重命名任务"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
            let input = NSTextField(string: task.title); input.frame = NSRect(x: 0, y: 0, width: 280, height: 24); alert.accessoryView = input
            alert.window.initialFirstResponder = input
            if alert.runModal() == .alertFirstButtonReturn {
                let title = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { tasks.update(id) { $0.title = String(title.prefix(120)) } }
            }
        case "pin": tasks.update(id) { $0.pinned.toggle() }
        case "fork": saveAgentDraft(); if let next = tasks.fork(id) { selectAgentTask(next) }
        case "archive":
            saveAgentDraft(); tasks.update(id) { $0.archived.toggle() }
            if tasks.task(id)?.archived == true && tasks.selectedID == id {
                let next = tasks.tasks.first(where: { !$0.archived && $0.id != id })?.id ?? tasks.create()
                selectAgentTask(next)
            }
        default: break
        }
        renderAgentMessages()
    }
    @objc func chooseProject() {
        guard let tasks = companion?.agentStore, let task = tasks.selected, task.automation == nil, task.workspace == nil || (task.status != .running && task.status != .waiting) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.prompt = "选择项目"
        if let path = task.workspace { panel.directoryURL = URL(fileURLWithPath: path) }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if task.workspace == nil {
                self.companion?.agentRuntime?.cancel(task.id)
                tasks.update(task.id) { $0.workspace = url.resolvingSymlinksInPath().path }
                if !task.messages.isEmpty { self.companion?.agentRuntime?.submit("已选择项目：" + url.resolvingSymlinksInPath().path + "。继续原任务。", taskID: task.id) }
                self.renderAgentMessages()
            } else if (!task.messages.isEmpty || task.worktreeOrigin != nil) && task.workspace != url.path {
                self.saveAgentDraft(); let id = tasks.create(workspace: url.resolvingSymlinksInPath().path, mode: task.mode)
                do { try AgentAttachments.copyDraft(store: tasks, sourceID: task.id, targetID: id) }
                catch { self.selectAgentTask(task.id); self.setStatus(error.localizedDescription, error: true); return }
                tasks.update(id) { $0.draft = self.composer.string }
                self.selectAgentTask(id)
            } else { tasks.update(task.id) { $0.workspace = url.resolvingSymlinksInPath().path }; self.renderAgentMessages() }
        }
    }
    @objc func agentOptionsChanged() {
        guard let tasks = companion?.agentStore, let task = tasks.selected, task.automation == nil, task.status != .running && task.status != .waiting else { return }
        tasks.update(task.id) { $0.mode = AgentMode.allCases[max(0, modePopup.indexOfSelectedItem)]; $0.permission = AgentPermissionMode.allCases[max(0, permissionPopup.indexOfSelectedItem)] }
        renderAgentMessages()
    }
    @objc private func showExecutionLocation() {
        guard let tasks = companion?.agentStore, let task = tasks.selected, task.canChooseEnvironment else { return }
        saveAgentDraft()
        let menu = NSMenu(); menu.autoenablesItems = false
        let local = NSMenuItem(title: "本地", action: #selector(selectLocalEnvironment), keyEquivalent: ""); local.target = self; local.state = task.worktreeOrigin == nil ? .on : .off; local.isEnabled = task.worktreeOrigin != nil; menu.addItem(local)
        let worktree = NSMenuItem(title: "工作树…", action: #selector(createTaskWorktree), keyEquivalent: ""); worktree.target = self; worktree.state = task.worktreeOrigin == nil ? .off : .on; worktree.isEnabled = task.workspace != nil && task.worktreeOrigin == nil; menu.addItem(worktree)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: executionLocation.bounds.height + 4), in: executionLocation)
    }
    @objc func createTaskWorktree() {
        guard let tasks = companion?.agentStore, let task = tasks.selected, task.canChooseEnvironment, task.workspace != nil else { return }
        saveAgentDraft()
        do {
            let directory = try AgentGit.metadata(workspace: task.workspace)
            if !directory.path.hasPrefix((task.workspace ?? "") + "/"), task.gitDirectory != directory.path {
                let alert = NSAlert(); alert.messageText = "连接 Git 仓库元数据？"; alert.informativeText = directory.path; alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }; tasks.update(task.id) { $0.gitDirectory = directory.path }
            }
            let controller = try AgentWorktreeCreationWindow(store: tasks, taskID: task.id, directory: directory) { [weak self] id in self?.selectAgentTask(id); self?.show(tab: "chat") }
            worktreeCreationWindow = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    @objc private func selectLocalEnvironment() {
        guard let tasks = companion?.agentStore, let source = tasks.selected, source.canChooseEnvironment, let origin = source.worktreeOrigin else { return }
        saveAgentDraft(); let id = tasks.create(workspace: origin.root, mode: source.mode)
        do { try tasks.copyEnvironmentDraft(sourceID: source.id, targetID: id); selectAgentTask(id) }
        catch { tasks.selectedID = source.id; setStatus(error.localizedDescription, error: true) }
    }
    @objc func resumeAgentTask() { if let id = companion?.agentStore?.selectedID { companion?.agentRuntime?.start(id) } }
    @objc func showAgentRecords() { presentAgentRecords(section: 0) }
    @objc func showAgentBrowser() {
        guard let store = companion?.agentStore, let task = store.selected else { return }
        do { _ = try store.browser.show(taskID: task.id, title: task.title) }
        catch { setStatus(error.localizedDescription, error: true) }
    }
    @objc func showAgentGit() {
        guard let store = companion?.agentStore, let id = store.selectedID else { return }
        gitWindow?.window?.performClose(nil)
        gitWindow = AgentGitWindow(store: store, taskID: id) { [weak self] next in self?.selectAgentTask(next); self?.show(tab: "chat") }
        gitWindow?.showWindow(nil); gitWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func showAgentKnowledge() {
        guard let store = companion?.agentStore, let id = store.selectedID else { return }
        knowledgeWindow?.window?.performClose(nil); knowledgeWindow = AgentKnowledgeWindow(store: store, taskID: id)
        knowledgeWindow?.onOpenWiki = { [weak self] in self?.selectAgentTask(id); self?.presentAgentRecords(section: 6) }
        knowledgeWindow?.showWindow(nil); knowledgeWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func openAgentMemory() { companion?.ensureAgent(); presentAgentRecords(section: 5) }
    func presentAgentRecords(section: Int) {
        guard let store = companion?.agentStore, let id = store.selectedID else { return }
        if let existing = recordWindow {
            existing.window?.performClose(nil)
            if existing.window?.isVisible == true { return }
        }
        recordWindow = AgentRecordWindow(store: store, taskID: id, section: section)
        recordWindow?.enableWikiGeneration { [weak self] in self?.generateAgentWiki(sourceID: id) }
        recordWindow?.showWindow(nil); recordWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func generateAgentWiki(sourceID: String) {
        guard let store = companion?.agentStore, let runtime = companion?.agentRuntime else { return }
        do {
            let id = try AgentWiki.start(store: store, runtime: runtime, sourceID: sourceID)
            recordWindow?.window?.close(); knowledgeWindow?.window?.close(); selectAgentTask(id)
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    func configureApprovalPanel() {
        approvalPanel.orientation = .vertical; approvalPanel.alignment = .leading; approvalPanel.spacing = 7; approvalPanel.isHidden = true
        approvalTitle.font = .systemFont(ofSize: 12, weight: .medium); approvalTitle.textColor = .systemOrange; approvalTitle.lineBreakMode = .byTruncatingTail
        approvalText.isEditable = false; approvalText.isRichText = false; approvalText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        approvalText.isVerticallyResizable = true; approvalText.autoresizingMask = [.width]; approvalText.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = approvalText; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        approveButton.target = self; approveButton.action = #selector(allowAgentAction)
        denyButton.target = self; denyButton.action = #selector(denyAgentAction)
        let actions = stack([NSView(), denyButton, approveButton], spacing: 8)
        for view in [approvalTitle, scroll, actions] { approvalPanel.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: approvalPanel.widthAnchor).isActive = true }
    }
    @objc func allowAgentAction() { if let pair = visibleApproval { companion?.agentRuntime?.decide(taskID: pair.task, callID: pair.call, decision: "allow") } }
    @objc func denyAgentAction() { if let pair = visibleApproval { companion?.agentRuntime?.decide(taskID: pair.task, callID: pair.call, decision: "deny") } }
    func renderAgentMessages() {
        guard let tasks = companion?.agentStore, let task = tasks.selected else { return }
        if contextWindow?.window?.isVisible == true { contextWindow?.refresh() }
        if taskModelWindow?.window?.isVisible == true { taskModelWindow?.refreshState() }
        recordWindow?.refreshLiveRecords(task.id)
        refreshAutomationBadge()
        if displayedTask != task.id { selectAgentTask(task.id); return }
        taskSidebar.refresh(tasks.tasks, selected: task.id)
        if selectedTab == "chat" { pageTitle.stringValue = task.title }
        projectButton.title = ""; projectButton.imagePosition = .imageOnly; projectButton.toolTip = task.workspace ?? "选择项目"
        modePopup.selectItem(at: AgentMode.allCases.firstIndex(of: task.mode) ?? 2)
        permissionPopup.selectItem(at: AgentPermissionMode.allCases.firstIndex(of: task.permission) ?? 1)
        let running = companion?.agentRuntime?.isRunning(task.id) == true
        let managed = task.kind == "hook", delegated = task.agent?.ownerID != nil || task.automation != nil
        let locked = running || task.status == .waiting
        executionLocation.title = task.worktreeOrigin == nil ? "本地" : "工作树"
        executionLocation.toolTip = task.workspace ?? "未选择项目"; executionLocation.isEnabled = task.canChooseEnvironment && !running
        for view in [projectButton, modePopup, permissionPopup] as [NSControl] { view.isEnabled = !locked && !task.archived && !managed && !delegated }
        projectButton.isEnabled = (!locked || task.workspace == nil) && !task.archived && !managed && !delegated
        gitButton.isEnabled = task.workspace != nil && !managed
        browserButton.isEnabled = !managed
        resumeButton.isHidden = managed || running || ![.stopped, .failed, .ready].contains(task.status) || task.messages.isEmpty || task.archived
        resultsButton.title = ""; resultsButton.imagePosition = .imageOnly; resultsButton.toolTip = task.plan.isEmpty ? "任务记录" : "计划 \(task.plan.filter { $0.status == "completed" }.count)/\(task.plan.count)"
        resultsButton.isEnabled = !task.events.isEmpty || !task.artifacts.isEmpty || !(task.canvases ?? []).isEmpty || !task.plan.isEmpty
        renderDraftAttachments(task); setBusy(running); clearButton.title = task.archived ? "恢复任务" : "归档任务"
        composer.isEditable = !managed; attachmentButton.isEnabled = !managed
        let queueCount = task.queuedCount
        let state = tasks.writeError ?? (task.status == .failed ? task.events.last(where: { $0.status == "failed" })?.detail ?? "执行失败" : managed && task.status == .completed ? task.statusTitle : locked ? (running && task.status == .ready ? "排队中" : task.status.title) + (queueCount > 0 ? " · \(queueCount) 条补充待处理" : "") : "")
        setStatus(task.status == .failed || tasks.writeError != nil || queueCount > 0 ? state : tasks.hooks.backgroundTitle(task.id) ?? "", error: task.status == .failed || tasks.writeError != nil || (managed && task.statusTitle == "校验未通过"))
        let context = task.contextSize.map { used in " · 上下文 ~\(used) / \(companion?.store.preferences.contextLimit ?? 8192)" } ?? ""
        modelCaption.stringValue = task.agent.map { $0.profile.name + context } ?? (context.hasPrefix(" · ") ? String(context.dropFirst(3)) : context)
        modelCaption.isHidden = true
        updateWorkbenchLayout()
        let follow = renderedIDs.isEmpty || history.contentView.bounds.maxY >= (history.documentView?.bounds.height ?? 0) - 65
        let messages = task.messages.filter { ["user", "assistant"].contains($0.role) && $0.nativeContext != true }
        var ids: [String] = []
        for message in messages {
            if !message.content.isEmpty || ((message.toolCalls ?? []).isEmpty && task.status == .running && message.id == task.messages.last?.id) { ids.append(message.id) }
            ids += (message.toolCalls ?? []).filter { $0.name != "load_tools" }.map { "tool:" + $0.id }
        }
        if task.status == .completed { ids += task.artifacts.prefix(4).map { "artifact:" + $0 }; ids += (task.canvases ?? []).prefix(4).map { "canvas:" + $0.id + $0.hash } }
        if ids != renderedIDs {
            messageColumn.arrangedSubviews.forEach { messageColumn.removeArrangedSubview($0); $0.removeFromSuperview() }
            var next: [String: ChatMessageRow] = [:], nextTools: [String: AgentToolRow] = [:]
            for message in messages {
                if ids.contains(message.id) {
                    let row = messageRows[message.id] ?? ChatMessageRow(message: ChatMessage(id: message.id, role: message.role, content: message.content), workbench: true); next[message.id] = row
                    row.fit(width: history.contentView.bounds.width - 40); messageColumn.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
                }
                for call in (message.toolCalls ?? []).filter({ $0.name != "load_tools" }) {
                    let row = toolRows[call.id] ?? AgentToolRow(); row.useWorkbenchStyle(); nextTools[call.id] = row
                    messageColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
                    messageColumn.setCustomSpacing(8, after: row)
                }
            }
            if task.status == .completed {
                for path in task.artifacts.prefix(4) {
                    let row = AgentInspectorFileButton(title: URL(fileURLWithPath: path).lastPathComponent, value: path, section: 1, symbol: "doc", inline: true)
                    row.onOpen = { [weak self] section, value in guard self?.companion?.agentStore?.selectedID == task.id else { return }; self?.presentAgentRecords(section: section); self?.recordWindow?.selectItem(section: section, value: value) }
                    messageColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
                }
                for canvas in (task.canvases ?? []).prefix(4) {
                    let row = AgentInspectorFileButton(title: canvas.title, value: canvas.reference, section: 1, symbol: "rectangle.3.group", inline: true)
                    row.onOpen = { [weak self] _, value in self?.openCanvasReference(value, taskID: task.id) }
                    messageColumn.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: messageColumn.widthAnchor).isActive = true
                }
            }
            messageRows = next; toolRows = nextTools; renderedIDs = ids
        }
        let events = Dictionary(task.events.compactMap { event in event.toolCallID.map { ($0, event) } }, uniquingKeysWith: { _, latest in latest })
        let fileMap = Dictionary((task.attachments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), owner = task.id
        for message in messages {
            let streaming = task.status == .running && message.id == task.messages.last?.id && (message.toolCalls ?? []).isEmpty
            messageRows[message.id]?.update(message.content, markdown: !streaming)
            messageRows[message.id]?.setAttachments((message.attachmentIDs ?? []).compactMap { fileMap[$0] }, onOpen: { [weak self] id in self?.openAttachment(taskID: owner, id: id) })
            for call in message.toolCalls ?? [] {
                var visibleCall = call
                if call.name == "delegate_task", let child = (events[call.id]?.childTaskID).flatMap({ tasks.task($0) }) { visibleCall.displayName = "委派 · " + (child.team?.team.name ?? child.agent?.profile.name ?? child.title) }
                toolRows[call.id]?.update(call: visibleCall, event: events[call.id])
                let image = task.messages.first(where: { $0.role == "tool" && $0.toolCallID == call.id })?.visuals?.compactMap { fileMap[$0.id] }.first(where: { $0.browserCapture != nil || $0.desktopCapture != nil || $0.canvasCapture != nil })
                toolRows[call.id]?.setCapture(image) { [weak self] in if let image { self?.openAttachment(taskID: owner, id: image.id) } }
                if let childID = events[call.id]?.childTaskID, let child = tasks.task(childID) { toolRows[call.id]?.setSubtask(child) { [weak self] in self?.selectAgentTask(childID) } }
            }
        }
        if let review = companion?.agentRuntime?.pendingReview(task.id), let call = review.pendingCalls.first, let approval = review.approvals.last(where: { $0.call.id == call.id && $0.decision == nil }) {
            if visibleApproval?.task != review.id || visibleApproval?.call != call.id {
                visibleApproval = (review.id, call.id)
                approvalTitle.stringValue = (review.id != task.id ? (review.agent?.profile.name ?? "子任务") + " · " : "") + (approval.reason.components(separatedBy: "\n").first ?? approval.reason)
                let mcpCall = AgentMCP.tools.contains(call.name) || AgentMCP.isModelToolName(call.name)
                let approvalArguments = AgentMCP.tools.contains(call.name) ? call.object["arguments"] as? [String: Any] ?? [:] : call.object
                approvalText.string = (try? JSONSerialization.data(withJSONObject: approvalArguments, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? call.arguments
                if mcpCall { approvalText.string = approval.reason + (approvalArguments.isEmpty ? "" : "\n\n" + approvalText.string) }
                else if AgentBrowser.tools.contains(call.name) { approvalText.string = approval.reason + "\n\n" + approvalText.string }
                if call.name == "git_commit", let diff = review.gitReview, diff.hash == call.object["review_hash"] as? String { approvalText.string += "\n\n" + diff.diff }
                approvalTitle.toolTip = approval.reason
            }
            approveButton.isHidden = call.name == "ask_user"; approveButton.isEnabled = !review.archived; denyButton.isEnabled = !review.archived; approvalPanel.isHidden = false
        } else { visibleApproval = nil; approvalPanel.isHidden = true }
        composer.isEditable = !task.archived && !managed
        window?.contentView?.layoutSubtreeIfNeeded()
        if follow, let document = history.documentView {
            history.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - history.contentView.bounds.height))); history.reflectScrolledClipView(history.contentView)
        }
    }
}

@MainActor extension ControlWindow {
    @objc private func showWorktrees() {
        showWorktreePolicySettings()
    }
    func showWorktreePolicySettings() { settingsCategory = "worktrees"; show(tab: "settings") }
    @objc func showDesktopSettings() { desktopSettings?.refreshState(); settingsCategory = "computer"; show(tab: "settings") }
    func refreshWorktreeRetention() { worktreePolicyPanel?.refreshState(); if companion?.usesAgent == true { scheduleRender() } }
    func refreshAutomationBadge() { let count = companion?.agentStore?.automations.unreadCount ?? 0; automationButton.title = "自动化" + (count > 0 ? " · \(count)" : "") }
    @objc func showAutomations() {
        guard let store = companion?.agentStore else { return }; saveAgentDraft()
        if let window = automationWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let manager = AgentAutomationWindow(store: store)
        manager.onOpen = { [weak self] id in self?.selectAgentTask(id); self?.show(tab: "chat"); self?.refreshAutomationBadge() }
        manager.onRequestNotifications = { [weak self] in guard let self else { throw PetError("应用已关闭") }; return try await self.companion?.automationNotifications.request() ?? false }
        automationWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil); refreshAutomationBadge()
    }
    private func dismissExtensionCandidates() { extensionPickerTask = nil; extensionPanel.parent?.removeChildWindow(extensionPanel); extensionPanel.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { dismissExtensionCandidates() }
    @objc func showAgentExtensions() {
        guard let store = companion?.agentStore, let id = store.selectedID else { return }
        extensionWindow?.window?.performClose(nil)
        if extensionWindow?.window?.isVisible == true { return }
        let manager = AgentExtensionWindow(store: store, taskID: id)
        manager.onStartAgent = { [weak self] taskID in self?.selectAgentTask(taskID) }
        manager.onBrowseMCP = { [weak self] server in self?.presentMCPContent(taskID: id, serverID: server) }
        if store.task(id)?.kind != "hook" { manager.onInsert = { [weak self] item in try self?.insertExtension(item, taskID: id) } }
        extensionWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil)
    }
    private func insertExtension(_ item: AgentExtensionItem, taskID: String) throws {
        guard let store = companion?.agentStore, let task = store.task(taskID), !task.archived, task.kind != "hook" else { throw PetError("原任务已归档或为独立校验任务") }
        let current = try store.extensions.item(item.id, workspace: task.workspace)
        dismissExtensionCandidates(); saveAgentDraft()
        if displayedTask != taskID { selectAgentTask(taskID) }
        let previous = composer.string
        if previous.hasPrefix("/"), let first = previous.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first {
            let tail = String(previous.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            composer.string = "/" + current.invocation + " " + tail
        } else { composer.string = "/" + current.invocation + " " + previous }
        composer.setSelectedRange(NSRange(location: (composer.string as NSString).length, length: 0)); composer.didChangeText()
        show(tab: "chat"); window?.makeFirstResponder(composer)
    }
    private func updateExtensionCandidates() {
        guard selectedTab == "chat", let store = companion?.agentStore, let task = store.selected, task.id == displayedTask, !["wiki", "hook"].contains(task.kind ?? ""),
              composer.string.hasPrefix("/"), !composer.string.contains(where: { $0.isWhitespace }), !composer.hasMarkedText(), window?.isVisible == true else { dismissExtensionCandidates(); return }
        do {
            let query = String(composer.string.dropFirst())
            let items = try store.extensions.catalog(workspace: task.workspace, includeDisabled: false).filter { query.isEmpty || $0.invocation.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }.prefix(12)
            guard !items.isEmpty else { dismissExtensionCandidates(); return }
            extensionPickerTask = task.id; extensionPicker.setItems(Array(items))
            extensionPicker.onPick = { [weak self] item in
                guard let self, let id = extensionPickerTask, id == displayedTask else { return }
                do { try insertExtension(item, taskID: id) } catch { dismissExtensionCandidates(); setStatus(error.localizedDescription, error: true) }
            }
            guard let window else { dismissExtensionCandidates(); return }
            extensionPanel.contentViewController = extensionPicker
            let anchor = window.convertToScreen(composer.convert(composer.visibleRect, to: nil))
            let bounds = window.screen?.visibleFrame ?? window.frame, width = min(420, bounds.width), height = CGFloat(min(264, items.count * 44 + 4))
            let x = min(bounds.maxX - width, max(bounds.minX, anchor.minX)), y = min(bounds.maxY - height, max(bounds.minY, anchor.maxY + 6))
            extensionPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            extensionPanel.contentView?.wantsLayer = true; extensionPanel.contentView?.layer?.cornerRadius = 8; extensionPanel.contentView?.layer?.masksToBounds = true
            if extensionPanel.parent !== window { window.addChildWindow(extensionPanel, ordered: .above) }; extensionPanel.orderFront(nil)
        } catch { dismissExtensionCandidates(); setStatus(error.localizedDescription, error: true) }
    }
    func attachBrowserCapture(_ shot: AgentBrowserShot, marks: [AgentBrowserMark], note: String, taskID: String) async throws {
        try await attachTaskCapture(taskID: taskID, note: note) { tasks in _ = try await shot.attach(store: tasks, taskID: taskID, draft: true, marks: marks) }
    }
    func attachCanvasCapture(_ shot: AgentCanvasShot, marks: [AgentBrowserMark], note: String, taskID: String) async throws {
        let context = "画布「" + shot.capture.title + "」的批注（源码版本 " + String(shot.capture.sourceHash.prefix(12)) + "）：" + note
        try await attachTaskCapture(taskID: taskID, note: context) { tasks in _ = try await shot.attach(store: tasks, taskID: taskID, draft: true, marks: marks) }
    }
    private func attachTaskCapture(taskID: String, note: String, importing: (AgentStore) async throws -> Void) async throws {
        guard let tasks = companion?.agentStore, tasks.task(taskID) != nil else { throw PetError("任务不存在") }
        saveAgentDraft()
        try await importing(tasks)
        defer { renderMessages() }
        try Task.checkCancellation()
        // Preserve edits made in either composer while the image was imported.
        saveAgentDraft()
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
    private func openCanvasReference(_ value: String, taskID: String) {
        guard let url = URL(string: value), url.scheme == "canvas", let id = url.host.flatMap({ UUID(uuidString: $0)?.uuidString }), let tasks = companion?.agentStore else { return }
        Task { @MainActor [weak self] in do { _ = try await tasks.canvases.show(id, taskID: taskID) } catch { self?.setStatus(error.localizedDescription, error: true) } }
    }
}

extension ControlWindow {
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
        checks["managerInsertionPreservesBothTaskDrafts"] = store.selectedID == taskID && store.task(taskID)?.draft == "/" + item.invocation + " 保留原草稿" && store.task(other)?.draft == "另一个原草稿"
        composer.string = "/"; composer.didChangeText(); selectAgentTask(other)
        try await Task.sleep(nanoseconds: 50_000_000)
        checks["taskSwitchClosesSlashCandidates"] = extensionPickerTask == nil && !extensionPanel.isVisible
        let observations: [String: Any] = ["selectedText": selectedText, "selectedTaskMessages": store.task(taskID)?.messages.count ?? -1, "candidateOwnerAfterSwitch": extensionPickerTask ?? "none", "panelShownAfterSwitch": extensionPanel.isVisible]
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("extension-composer-report.json"))
        selectAgentTask(taskID); composer.string = ""; composer.didChangeText(); saveAgentDraft()
        if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("extension-entry.png")) }
        return checks
    }
    func checkBrowserCaptureDraft(_ shot: AgentBrowserShot, marks: [AgentBrowserMark], note: String, taskID: String) async throws -> [String: Bool] {
        guard let tasks = companion?.agentStore else { throw PetError("任务未初始化") }
        selectAgentTask(taskID); composer.string = "保留的原有草稿"; saveAgentDraft()
        let other = tasks.create(title: "另一个未发送草稿", mode: .ask)
        selectAgentTask(other); composer.string = "独立草稿"; saveAgentDraft()
        try await attachBrowserCapture(shot, marks: marks, note: note, taskID: taskID)
        return ["captureReturnsToOwningTask": tasks.selectedID == taskID && displayedTask == taskID,
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
        guard let tasks = companion?.agentStore, let originalID = tasks.selectedID else { return ["nativeAgentLayout": false] }
        let draft = composer.string
        composer.string = "尚未发送的 Agent 草稿"; composer.didChangeText(); saveAgentDraft()
        let second = tasks.create(title: "另一项任务"); selectAgentTask(second); composer.string = "另一份草稿"; composer.didChangeText()
        selectAgentTask(originalID)
        var checks = ["draftsAreIsolatedAndPersistent": composer.string == "尚未发送的 Agent 草稿" && tasks.task(second)?.draft == "另一份草稿"]
        selectedTab = "settings"; changeTab(); selectedTab = "chat"; changeTab()
        checks["settingsReturnPreservesTaskDraft"] = composer.string == "尚未发送的 Agent 草稿" && tasks.selectedID == originalID
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
    func checkExecutorSelection(taskID: String, agentID: String, teamID: String) -> [String: Bool] {
        guard let store = companion?.agentStore, let before = store.task(taskID) else { return ["executorDraftFound": false] }
        selectAgentTask(taskID)
        let count = store.tasks.count, draft = composer.string, files = before.draftAttachmentIDs
        func select(_ value: String) { let item = NSMenuItem(); item.representedObject = value; selectExecutor(item) }
        func preserved() -> Bool { store.tasks.count == count && composer.string == draft && store.task(taskID)?.draft == before.draft && store.task(taskID)?.draftAttachmentIDs == files && store.selectedID == taskID }
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
        newAgentTask(); let emptyID = tasks.selectedID!
        composer.string = "尚未发送的工作台草稿"; composer.didChangeText(); saveAgentDraft()
        await capture("workbench-empty")
        checks["emptyTaskHasOwnStartingState"] = !workbenchEmpty.isHidden && history.isHidden && workbenchInspector.isHidden
        checks["emptyTaskDoesNotDisplayPriorMessages"] = messageColumn.arrangedSubviews.isEmpty && tasks.task(emptyID)?.messages.isEmpty == true
        selectAgentTask(actualTask); selectAgentTask(emptyID)
        checks["draftSurvivesTaskSwitch"] = composer.string == "尚未发送的工作台草稿" && tasks.task(emptyID)?.messages.isEmpty == true
        selectAgentTask(actualTask); previousAgentTask(); checks["backReturnsToPriorTask"] = tasks.selectedID == emptyID
        nextAgentTask(); checks["forwardRestoresTask"] = tasks.selectedID == actualTask
        setSize(NSSize(width: 900, height: 640)); await capture("workbench-narrow")
        checks["narrowCollapsesInspector"] = workbenchInspector.isHidden && history.contentView.bounds.width > 550
        checks["composerControlsDoNotOverlapNarrow"] = !entryLeading.convert(entryLeading.bounds, to: entryToolbar).intersects(entryTrailing.convert(entryTrailing.bounds, to: entryToolbar))
        setSize(NSSize(width: 780, height: 540)); await capture("workbench-minimum")
        checks["minimumActuallyReachesRequestedWidth"] = abs(window.frame.width - 780) < 1
        checks["minimumKeepsUsableComposer"] = entryToolbar.bounds.width > 440 && !entryLeading.convert(entryLeading.bounds, to: entryToolbar).intersects(entryTrailing.convert(entryTrailing.bounds, to: entryToolbar))
        if let stoppedTask, tasks.task(stoppedTask) != nil {
            setSize(NSSize(width: 1200, height: 800)); selectAgentTask(stoppedTask); await capture("workbench-stopped")
            checks["actualStoppedTaskHasResumeAndStoppedState"] = tasks.task(stoppedTask)?.status == .stopped && !resumeButton.isHidden && !workbenchBadge.isHidden
            if let binding = tasks.task(stoppedTask)?.agent, (try? tasks.agents.profile(binding.profile.id)) == nil {
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
