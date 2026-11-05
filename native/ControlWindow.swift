import AppKit

final class ComposerView: NSTextView {
    var onSend: (() -> Void)?
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("发消息…" as NSString).draw(at: NSPoint(x: textContainerInset.width + 4, y: textContainerInset.height),
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
    private let settingsCategories = [("model", "模型", "cpu"), ("voice", "语音", "waveform"), ("screen", "屏幕陪伴", "eye"), ("desktop", "桌面宠物", "fish"), ("persona", "角色", "person.crop.circle")]
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

    init(companion: AppDelegate) {
        self.companion = companion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "蓝色大肥鱼"; window.minSize = NSSize(width: 780, height: 540)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 1)
        window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        build()
        refreshPreferences()
        renderMessages()
        companion.onScaleChange = { [weak self] in self?.scale.doubleValue = $0; self?.sizeValue.stringValue = "\(Int(($0 * 100).rounded()))%" }
        companion.onWakeChange = { [weak self] enabled, status in
            self?.wakeEnabled.state = enabled ? .on : .off; self?.wakeStatus.stringValue = status
            self?.sidebarWake.stringValue = enabled ? status : "语音未开启"; self?.listenButton.title = enabled ? "立即聆听" : "开启语音"
            self?.stopRecordingButton.isEnabled = enabled; self?.voiceStopButton.isEnabled = enabled
        }
        companion.screenCompanion.onChange = { [weak self] in self?.updateScreenStatus($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        let sideFooter = stack([listenButton, stopRecordingButton, sidebarWake, clearButton], vertical: true, spacing: 13); content.addSubview(sideFooter)
        chatSidebarViews = [brand, navigation, sideFooter]
        let main = contentSurface; main.translatesAutoresizingMaskIntoConstraints = false; main.wantsLayer = true
        main.layer?.backgroundColor = NSColor.white.cgColor; main.layer?.cornerRadius = 17; main.layer?.masksToBounds = true; content.addSubview(main)
        pageTitle.font = .systemFont(ofSize: 14, weight: .semibold); pageTitle.textColor = .secondaryLabelColor
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
            pageTitle.topAnchor.constraint(equalTo: main.topAnchor, constant: 22), titleLeading,
            settingsPageIcon.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28), settingsPageIcon.centerYAnchor.constraint(equalTo: pageTitle.centerYAnchor), settingsPageIcon.widthAnchor.constraint(equalToConstant: 36), settingsPageIcon.heightAnchor.constraint(equalToConstant: 36),
            panels.topAnchor.constraint(equalTo: pageTitle.bottomAnchor, constant: 18), panels.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28), panels.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28), panels.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -24)])
        for panel in [chat, settings] { panels.addSubview(panel); pin(panel, to: panels) }
        buildChat(); buildSettingsSidebar(in: content); buildSettings(); changeTab()
    }
    private func buildSettingsSidebar(in content: NSView) {
        content.addSubview(settingsSidebar); settingsSidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([settingsSidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), settingsSidebar.widthAnchor.constraint(equalToConstant: 200), settingsSidebar.topAnchor.constraint(equalTo: content.topAnchor), settingsSidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
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
        composer.isRichText = false; composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticTextReplacementEnabled = false; composer.autoresizingMask = [.width]
        composer.onSend = { [weak self] in self?.send() }
        let input = NSScrollView(); input.documentView = composer; input.hasVerticalScroller = true
        input.drawsBackground = false; input.borderType = .noBorder
        sendButton.isBordered = false; sendButton.title = ""; sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "发送")
        sendButton.imagePosition = .imageOnly; sendButton.contentTintColor = .white; sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor; sendButton.layer?.cornerRadius = 11
        sendButton.setAccessibilityLabel("发送")
        sendButton.target = self; sendButton.action = #selector(send)
        sendButton.widthAnchor.constraint(equalToConstant: 34).isActive = true; sendButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        modelCaption.font = .systemFont(ofSize: 11); modelCaption.textColor = .secondaryLabelColor
        let fill = NSView(); let entryBar = stack([modelCaption, fill, sendButton], spacing: 8)
        let entry = NSView(); entry.translatesAutoresizingMaskIntoConstraints = false; entry.wantsLayer = true
        entry.layer?.backgroundColor = NSColor(white: 0.995, alpha: 1).cgColor; entry.layer?.cornerRadius = 16
        entry.layer?.borderWidth = 1; entry.layer?.borderColor = NSColor(white: 0.90, alpha: 1).cgColor
        entry.addSubview(input); entry.addSubview(entryBar); input.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 14), input.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -14), input.topAnchor.constraint(equalTo: entry.topAnchor, constant: 8), input.heightAnchor.constraint(equalToConstant: 60),
            entryBar.leadingAnchor.constraint(equalTo: entry.leadingAnchor, constant: 16), entryBar.trailingAnchor.constraint(equalTo: entry.trailingAnchor, constant: -10), entryBar.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 4), entryBar.bottomAnchor.constraint(equalTo: entry.bottomAnchor, constant: -10)])
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.isHidden = true
        let column = stack([history, status, entry], vertical: true, spacing: 14)
        chat.addSubview(column); pin(column, to: chat)
        for row in [history, status, entry] { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        history.setContentHuggingPriority(.defaultLow, for: .vertical)
        history.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
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
        group("desktop", "显示与动画", "桌面 宠物 角色 置顶 动画 性能 节能 大小 缩放")
        row("窗口置顶", onTop); performance.addItems(withTitles: ["自动节能", "流畅", "暂停"]); row("动画", performance)
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); sizeValue.textColor = .secondaryLabelColor
        sizeValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        scale.target = self; scale.action = #selector(scaleChanged); row("大小", stack([scale, sizeValue], spacing: 12))
        group("persona", "人设", "角色 人设 性格 提示词 persona")
        persona.usesSingleLineMode = false; persona.lineBreakMode = .byWordWrapping
        persona.heightAnchor.constraint(equalToConstant: 120).isActive = true; row("", persona)
        noSettings.font = .systemFont(ofSize: 14); noSettings.textColor = .secondaryLabelColor
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings)); save.isBordered = false
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
    }
    @objc private func selectTab(_ sender: NSButton) { companion?.screenCompanion.interaction(); selectedTab = sender.tag == 0 ? "chat" : "settings"; changeTab() }
    private func changeTab() {
        chat.isHidden = selectedTab != "chat"; settings.isHidden = selectedTab != "settings"
        let configuring = selectedTab == "settings"
        settingsSidebar.isHidden = !configuring; chatSidebarViews.forEach { $0.isHidden = configuring }
        contentSurface.showsSettings = configuring; settingsPageIcon.isHidden = !configuring
        titleLeading.constant = configuring ? 80 : 28
        pageTitle.font = .systemFont(ofSize: configuring ? 22 : 14, weight: .semibold)
        pageTitle.textColor = configuring ? .labelColor : .secondaryLabelColor
        if configuring { updateSettingsSections() } else { pageTitle.stringValue = "对话" }
        chatNav.layer?.backgroundColor = selectedTab == "chat" ? NSColor(white: 0, alpha: 0.07).cgColor : NSColor.clear.cgColor
        settingsNav.layer?.backgroundColor = selectedTab == "settings" ? NSColor(white: 0, alpha: 0.07).cgColor : NSColor.clear.cgColor
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
        if busy { companion.cancelConversation(); return }
        if companion.send(composer.string) { composer.string = ""; composer.didChangeText() }
    }
    @objc private func clear() { companion?.clearConversation(); renderMessages() }
    func keepVoiceDraft(_ text: String) { composer.string = text; composer.didChangeText() }
    func keepInterruptedVoiceDraft(_ text: String) {
        composer.string = composer.string.isEmpty ? text : composer.string + "\n" + text; composer.didChangeText()
    }
    func setBusy(_ value: Bool) {
        busy = value; sendButton.image = NSImage(systemSymbolName: value ? "stop.fill" : "arrow.up", accessibilityDescription: value ? "停止" : "发送")
        sendButton.setAccessibilityLabel(value ? "停止" : "发送"); clearButton.isEnabled = !value
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
        let width = (window?.contentView?.bounds.width ?? 980) - 272
        messageRows.values.forEach { $0.fit(width: width) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if modelCheck != nil { invalidateModelCheck() }
        sender.orderOut(nil); return false
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
