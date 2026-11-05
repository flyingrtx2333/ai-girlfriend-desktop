import AppKit

final class ComposerView: NSTextView {
    var onSend: (() -> Void)?
    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText() && !NSEvent.modifierFlags.contains(.shift) { onSend?() }
        else { super.insertNewline(sender) }
    }
}

final class FormDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class ControlWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    weak var companion: AppDelegate?
    private let tabs = NSSegmentedControl(labels: ["对话", "设置"], trackingMode: .selectOne, target: nil, action: nil)
    private let chat = NSView(), settings = NSView()
    private let transcript = NSTextView(), composer = ComposerView()
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
    private let voiceEnabled = NSButton(checkboxWithTitle: "语音回复", target: nil, action: nil)
    private let onTop = NSButton(checkboxWithTitle: "窗口置顶", target: nil, action: nil)
    private let wakeEnabled = NSButton(checkboxWithTitle: "启用语音唤醒", target: nil, action: nil)
    private let wakePhrase = NSTextField(), wakeStatus = NSTextField(labelWithString: "未开启")
    private let performance = NSPopUpButton(), scale = NSSlider(value: 1, minValue: 0.5, maxValue: 1.5, target: nil, action: nil)
    private var removeChatKey = false, removeVoiceKey = false, busy = false
    private var pendingRender: DispatchWorkItem?

    init(companion: AppDelegate) {
        self.companion = companion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "蓝色大肥鱼"; window.minSize = NSSize(width: 580, height: 520)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 1)
        window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        build()
        refreshPreferences()
        renderMessages()
        companion.onScaleChange = { [weak self] in self?.scale.doubleValue = $0 }
        companion.onWakeChange = { [weak self] enabled, status in
            self?.wakeEnabled.state = enabled ? .on : .off; self?.wakeStatus.stringValue = status
        }
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
        field.font = .systemFont(ofSize: 14); field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    }
    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true; content.layer?.backgroundColor = window?.backgroundColor.cgColor
        let title = NSTextField(labelWithString: "小鲸"); title.font = .systemFont(ofSize: 20, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = NSColor(red: 0.28, green: 0.52, blue: 0.78, alpha: 1)
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true; icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let space = NSView(); space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabs.target = self; tabs.action = #selector(changeTab); tabs.selectedSegment = 0
        tabs.setWidth(72, forSegment: 0); tabs.setWidth(72, forSegment: 1)
        let header = stack([icon, title, space, tabs]); content.addSubview(header)
        let panels = NSView(); content.addSubview(panels); panels.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            panels.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            panels.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            panels.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            panels.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)])
        for panel in [chat, settings] { panels.addSubview(panel); pin(panel, to: panels) }
        buildChat(); buildSettings(); changeTab()
    }
    private func buildChat() {
        transcript.isEditable = false; transcript.isSelectable = true
        transcript.textContainerInset = NSSize(width: 16, height: 16)
        transcript.drawsBackground = true; transcript.backgroundColor = .textBackgroundColor
        transcript.isHorizontallyResizable = false; transcript.autoresizingMask = [.width]
        let history = NSScrollView(); history.documentView = transcript; history.hasVerticalScroller = true
        history.wantsLayer = true; history.layer?.cornerRadius = 12
        composer.font = .systemFont(ofSize: 14); composer.textContainerInset = NSSize(width: 12, height: 12)
        composer.isRichText = false; composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticTextReplacementEnabled = false; composer.autoresizingMask = [.width]
        composer.onSend = { [weak self] in self?.send() }
        let input = NSScrollView(); input.documentView = composer; input.hasVerticalScroller = true
        input.wantsLayer = true; input.layer?.cornerRadius = 8
        sendButton.bezelStyle = .rounded; sendButton.controlSize = .large
        sendButton.target = self; sendButton.action = #selector(send)
        sendButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let entry = stack([input, sendButton]); entry.heightAnchor.constraint(equalToConstant: 88).isActive = true
        clearButton.bezelStyle = .inline; clearButton.target = self; clearButton.action = #selector(clear)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let fill = NSView(); let footer = stack([status, fill, clearButton], spacing: 8)
        let column = stack([history, entry, footer], vertical: true, spacing: 12)
        chat.addSubview(column); pin(column, to: chat)
        for row in [history, entry, footer] { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        history.setContentHuggingPriority(.defaultLow, for: .vertical)
        history.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    }
    private func buildSettings() {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FormDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        let form = stack([], vertical: true, spacing: 12)
        document.addSubview(form); pin(form, to: document, inset: 4)
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 16, weight: .semibold)
            form.addArrangedSubview(label)
        }
        func row(_ text: String, _ control: NSView) {
            let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 14)
            label.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let line = stack([label, control], spacing: 12)
            form.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        func secret(_ input: NSSecureTextField, preview: NSButton, replace: NSButton, copy: Selector, edit: Selector, action: Selector) -> NSView {
            preview.target = self; preview.action = copy; preview.bezelStyle = .inline
            preview.font = .monospacedSystemFont(ofSize: 13, weight: .regular); preview.alignment = .left
            preview.toolTip = "点击复制"; preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
            input.setContentHuggingPriority(.defaultLow, for: .horizontal)
            replace.title = "更换"; replace.target = self; replace.action = edit; replace.bezelStyle = .inline
            let remove = NSButton(title: "移除", target: self, action: action); remove.bezelStyle = .inline
            remove.widthAnchor.constraint(equalToConstant: 48).isActive = true
            return stack([input, preview, replace, remove], spacing: 8)
        }
        for value in [endpoint, model, persona, apiKey, voiceKey, voiceEndpoint, voiceID, voiceModel, wakePhrase] { field(value) }
        heading("对话")
        endpoint.delegate = self; model.delegate = self; apiKey.delegate = self
        model.completes = false; model.numberOfVisibleItems = 8
        checkModelButton.bezelStyle = .rounded; checkModelButton.target = self; checkModelButton.action = #selector(checkModel)
        modelStatus.font = .systemFont(ofSize: 12); modelStatus.textColor = .secondaryLabelColor
        row("接口", endpoint); row("模型", stack([model, checkModelButton], spacing: 8))
        row("Token", secret(apiKey, preview: apiPreview, replace: apiReplace, copy: #selector(copyAPI), edit: #selector(replaceAPI), action: #selector(removeAPI)))
        row("连接", modelStatus)
        vision.addItems(withTitles: ["自动（未知）", "支持", "不支持"])
        vision.toolTip = "自动读取服务声明；手动设置不会改变模型本身的能力。"
        reasoning.addItems(withTitles: ["默认", "关闭", "最少", "低", "中", "高", "很高", "最高"])
        reasoning.menu?.autoenablesItems = false
        reasoning.target = self; reasoning.action = #selector(reasoningChanged)
        contextTokens.addItems(withObjectValues: ["自动", "4096", "8192", "16384", "32768", "65536", "131072", "262144", "524288", "1048576"])
        replyTokens.addItems(withObjectValues: ["512", "1024", "2048", "4096", "8192", "16384", "32768"])
        for value in [contextTokens, replyTokens] { field(value); value.delegate = self; value.widthAnchor.constraint(equalToConstant: 136).isActive = true }
        contextTokens.toolTip = "Token 预算；按 UTF-8 字节保守估算，超出时裁剪较早的完整对话轮次。"
        for label in [contextMaximum, replyMaximum] { label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor }
        row("视觉理解", vision); row("思考程度", reasoning)
        row("上下文", stack([contextTokens, NSTextField(labelWithString: "tokens"), contextMaximum], spacing: 8))
        row("回复上限", stack([replyTokens, NSTextField(labelWithString: "tokens"), replyMaximum], spacing: 8))
        persona.usesSingleLineMode = false; persona.lineBreakMode = .byWordWrapping
        persona.heightAnchor.constraint(equalToConstant: 72).isActive = true
        row("角色", persona)
        heading("MiniMax 语音")
        row("", voiceEnabled); row("接口", voiceEndpoint)
        row("Token", secret(voiceKey, preview: voicePreview, replace: voiceReplace, copy: #selector(copyVoice), edit: #selector(replaceVoice), action: #selector(removeVoice)))
        row("模型", voiceModel); row("音色", voiceID)
        heading("语音唤醒")
        row("", wakeEnabled); row("唤醒词", wakePhrase)
        wakeStatus.font = .systemFont(ofSize: 12); wakeStatus.textColor = .secondaryLabelColor
        row("状态", wakeStatus)
        heading("桌面")
        row("", onTop)
        performance.addItems(withTitles: ["自动节能", "流畅", "暂停"])
        row("动画", performance); row("大小", scale)
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings)); save.bezelStyle = .rounded
        save.controlSize = .large
        savedStatus.font = .systemFont(ofSize: 12); savedStatus.textColor = .secondaryLabelColor
        let fill = NSView(), bottom = stack([savedStatus, fill, save])
        let column = stack([scroll, bottom], vertical: true, spacing: 16)
        settings.addSubview(column); pin(column, to: settings)
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    func show(tab: String) {
        if window?.isVisible != true { refreshPreferences() }
        tabs.selectedSegment = tab == "settings" ? 1 : 0; changeTab()
        renderMessages(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if tab != "settings" { window?.makeFirstResponder(composer) }
    }
    @objc private func changeTab() {
        chat.isHidden = tabs.selectedSegment != 0; settings.isHidden = tabs.selectedSegment != 1
    }
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
        performance.selectItem(at: ["auto", "smooth", "paused"].firstIndex(of: p.performance) ?? 0)
        scale.doubleValue = p.scale
    }
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
    func controlTextDidChange(_ obj: Notification) { invalidateModelCheck() }
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
        if companion.send(composer.string) { composer.string = "" }
    }
    @objc private func clear() { companion?.clearConversation(); renderMessages() }
    func keepVoiceDraft(_ text: String) { composer.string = text }
    func setBusy(_ value: Bool) {
        busy = value; sendButton.title = value ? "停止" : "发送"; clearButton.isEnabled = !value
    }
    func setStatus(_ text: String, error: Bool = false) {
        status.stringValue = text; status.textColor = error ? .systemRed : .secondaryLabelColor
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
        let text = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        if companion.store.messages.isEmpty {
            text.append(NSAttributedString(string: "小鲸在这里。", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for message in companion.store.messages {
            let color = message.role == "assistant" ? NSColor(red: 0.22, green: 0.43, blue: 0.64, alpha: 1) : .secondaryLabelColor
            text.append(NSAttributedString(string: (message.role == "assistant" ? "小鲸" : "你") + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color]))
            text.append(NSAttributedString(string: message.content + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        transcript.textStorage?.setAttributedString(text)
        transcript.scrollToEndOfDocument(nil)
        clearButton.title = companion.undoMessages == nil ? "清空" : "撤销清空"
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if modelCheck != nil { invalidateModelCheck() }
        sender.orderOut(nil); return false
    }
}
