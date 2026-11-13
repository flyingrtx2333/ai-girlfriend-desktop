import AppKit
import UserNotifications

enum AgentCompletionNotification: String, Codable, CaseIterable {
    case never, unfocused, always
    var title: String { switch self { case .never: return "从不"; case .unfocused: return "仅在未聚焦时"; case .always: return "始终" } }
    func allows(focused: Bool) -> Bool { self == .always || self == .unfocused && !focused }
}

enum AgentRunningInput: String, Codable, CaseIterable {
    case queue, interrupt
    var title: String { self == .queue ? "排队" : "插话" }
}

@MainActor final class AgentGeneralSettings {
    struct Settings: Codable, Equatable {
        var version = 1
        var completionNotifications = AgentCompletionNotification.unfocused
        var approvalNotifications = true, questionNotifications = true, menuBarIcon = true
        var runningInput = AgentRunningInput.queue
        var goalMaximumTurns = 20
        var slashMenuPresentation = AgentSlashPresentation.recent
        var artifactLocation = AgentArtifactLocation.workspace
        var questionAutoSkip = false
        var conversationDisplay = AgentConversationDisplay.Settings()
        static let goalTurnChoices = AgentGoalExecution.turnChoices
        private enum CodingKeys: String, CodingKey { case version, completionNotifications, approvalNotifications, questionNotifications, menuBarIcon, runningInput, goalMaximumTurns, slashMenuPresentation, artifactLocation, questionAutoSkip, conversationDisplay }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            completionNotifications = try values.decode(AgentCompletionNotification.self, forKey: .completionNotifications)
            approvalNotifications = try values.decode(Bool.self, forKey: .approvalNotifications)
            questionNotifications = try values.decode(Bool.self, forKey: .questionNotifications)
            menuBarIcon = try values.decode(Bool.self, forKey: .menuBarIcon)
            if values.contains(.runningInput) { runningInput = try values.decode(AgentRunningInput.self, forKey: .runningInput) }
            if values.contains(.goalMaximumTurns) { goalMaximumTurns = try values.decode(Int.self, forKey: .goalMaximumTurns) }
            if values.contains(.slashMenuPresentation) { slashMenuPresentation = try values.decode(AgentSlashPresentation.self, forKey: .slashMenuPresentation) }
            if values.contains(.artifactLocation) { artifactLocation = try values.decode(AgentArtifactLocation.self, forKey: .artifactLocation) }
            if values.contains(.questionAutoSkip) { questionAutoSkip = try values.decode(Bool.self, forKey: .questionAutoSkip) }
            if values.contains(.conversationDisplay) { conversationDisplay = try values.decode(AgentConversationDisplay.Settings.self, forKey: .conversationDisplay) }
        }
    }
    static let changed = Notification.Name("BlueFatFishGeneralSettingsChanged")
    let directory: URL
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    var onChange: (() -> Void)?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("general.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("general.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("常规配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 4096)
                let required: Set<String> = ["version", "completionNotifications", "approvalNotifications", "questionNotifications", "menuBarIcon"]
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], required.isSubset(of: Set(raw.keys)), Set(raw.keys).isSubset(of: required.union(["runningInput", "goalMaximumTurns", "slashMenuPresentation", "artifactLocation", "questionAutoSkip", "conversationDisplay"])),
                      !raw.keys.contains("conversationDisplay") || (raw["conversationDisplay"] as? [String: Any]).map({ Set($0.keys) == AgentConversationDisplay.Settings.keys }) == true,
                      let value = try? JSONDecoder().decode(Settings.self, from: data), value.version == 1, Settings.goalTurnChoices.contains(value.goalMaximumTurns) else { throw PetError("常规配置版本或选项无效") }
                settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "常规配置未载入：" + error.localizedDescription }
    }
    func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        guard value.version == 1, Settings.goalTurnChoices.contains(value.goalMaximumTurns) else { throw PetError("常规配置版本或目标轮次无效") }
        guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("general.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("常规配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "general.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "常规配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); apply()
    }
    func apply() { onChange?(); NotificationCenter.default.post(name: Self.changed, object: self) }
}

@MainActor final class AgentGeneralSettingsView: NSStackView {
    private let service: AgentGeneralSettings, notifications: AgentAutomationNotifications
    private let taskID: () -> String?
    private let completion = NSPopUpButton(), approval = NSSwitch(), question = NSSwitch(), menuBar = NSSwitch()
    private let runningInput = NSPopUpButton(), goalTurns = NSPopUpButton()
    private let slashMenu = NSPopUpButton(), artifactLocation = NSPopUpButton()
    private let questionAutoSkip = NSSwitch()
    private let overview = NSStackView(), conversationPage = NSStackView()
    private let conversationButton = NSButton(title: "设置", target: nil, action: nil), conversationBack = NSButton(title: "常规", target: nil, action: nil)
    private let readingStart = NSSwitch(), toolCount = NSSwitch(), expandTools = NSSwitch(), collapseProcess = NSSwitch(), durationFormat = NSPopUpButton()
    private(set) var conversationVisible = false
    var onConversationPage: ((Bool) -> Void)?
    private let permission = NSTextField(labelWithString: "正在检查…"), permissionButton = NSButton(title: "允许通知", target: nil, action: nil), test = NSButton(title: "发送测试通知", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: ""), reload = NSButton(title: "重新载入", target: nil, action: nil)
    private var authorization = UNAuthorizationStatus.notDetermined, updatingPermission = false
    init(service: AgentGeneralSettings, notifications: AgentAutomationNotifications, taskID: @escaping () -> String?) {
        self.service = service; self.notifications = notifications; self.taskID = taskID; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 22
        for page in [overview, conversationPage] {
            page.orientation = .vertical; page.alignment = .leading; page.spacing = 22; addArrangedSubview(page); page.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        conversationPage.isHidden = true
        runningInput.addItems(withTitles: AgentRunningInput.allCases.map(\.title)); runningInput.setAccessibilityLabel("运行中发送方式")
        goalTurns.addItems(withTitles: AgentGeneralSettings.Settings.goalTurnChoices.map { "\($0)" }); goalTurns.setAccessibilityLabel("目标驱动执行最大轮次")
        slashMenu.addItems(withTitles: AgentSlashPresentation.allCases.map(\.title)); slashMenu.setAccessibilityLabel("Slash 命令展示方式")
        artifactLocation.addItems(withTitles: AgentArtifactLocation.allCases.map(\.title)); artifactLocation.setAccessibilityLabel("产物文件默认打开位置")
        runningInput.toolTip = "插话会停止当前执行，再处理新输入；已执行的操作会保留。"
        goalTurns.toolTip = "每次开始或继续目标任务时生效；等待授权不会重置轮次。"
        for (control, id) in [(runningInput, "general-running-input"), (goalTurns, "general-goal-turns"), (slashMenu, "general-slash-menu"), (artifactLocation, "general-artifact-location")] {
            control.identifier = NSUserInterfaceItemIdentifier(id); control.target = self; control.action = #selector(change)
        }
        completion.addItems(withTitles: AgentCompletionNotification.allCases.map(\.title)); completion.setAccessibilityLabel("轮次完成通知")
        completion.identifier = NSUserInterfaceItemIdentifier("general-completion-notifications"); completion.target = self; completion.action = #selector(change)
        questionAutoSkip.toolTip = "开启后，当前任务前台无人操作 150 秒、后台 90 秒后，以空答案跳过未回答的问题；面板内交互会取消自动跳过。"
        for (control, label, id) in [(approval, "权限请求通知", "general-approval-notifications"), (question, "等待回答通知", "general-question-notifications"), (menuBar, "显示菜单栏图标", "general-menu-bar-icon"), (questionAutoSkip, "问答面板静默跳过", "general-question-auto-skip")] {
            control.setAccessibilityLabel(label); control.identifier = NSUserInterfaceItemIdentifier(id); control.target = self; control.action = #selector(change)
        }
        conversationButton.bezelStyle = .rounded; conversationButton.identifier = NSUserInterfaceItemIdentifier("general-conversation-display"); conversationButton.setAccessibilityLabel("对话显示设置"); conversationButton.target = self; conversationButton.action = #selector(openConversation)
        conversationBack.isBordered = false; conversationBack.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil); conversationBack.imagePosition = .imageLeading; conversationBack.target = self; conversationBack.action = #selector(closeConversation); conversationBack.setAccessibilityLabel("返回常规设置")
        conversationPage.addArrangedSubview(conversationBack)
        for (control, label, id) in [(readingStart, "新消息保持在阅读起点", "conversation-reading-start"), (toolCount, "显示工具调用次数", "conversation-tool-count"), (expandTools, "默认展开工具调用", "conversation-expand-tools"), (collapseProcess, "折叠回复过程", "conversation-collapse-process")] {
            control.setAccessibilityLabel(label); control.identifier = NSUserInterfaceItemIdentifier(id); control.target = self; control.action = #selector(change)
        }
        readingStart.toolTip = "发送后将新一轮定位到视口顶部，内容填满后继续贴底追随；手动滚动可离开起点。"
        toolCount.toolTip = "在折叠的处理过程上显示这一段的工具调用数量。"
        expandTools.toolTip = "工具调用卡片默认显示完整输入与响应。"
        collapseProcess.toolTip = "回复成功完成后，将最终正文前的过程文本、思考和工具调用收进处理过程。"
        durationFormat.addItems(withTitles: AgentConversationDisplay.DurationFormat.allCases.map(\.title)); durationFormat.setAccessibilityLabel("耗时显示格式"); durationFormat.identifier = NSUserInterfaceItemIdentifier("conversation-duration-format"); durationFormat.target = self; durationFormat.action = #selector(change)
        permission.font = .systemFont(ofSize: 12); permission.textColor = AgentWorkbenchTheme.secondaryText; permission.setAccessibilityLabel("系统通知状态")
        for button in [permissionButton, test, reload] { button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12); button.target = self }
        permissionButton.action = #selector(requestPermission); test.action = #selector(testNotification); reload.action = #selector(reloadSettings)
        let permissionActions = NSStackView(views: [permission, permissionButton, test]); permissionActions.spacing = 8
        group("任务与工具", rows: [("运行中发送方式", runningInput), ("Slash 命令展示方式", slashMenu), ("问答面板静默跳过", questionAutoSkip), ("产物文件默认打开位置", artifactLocation), ("对话显示", conversationButton), ("目标驱动执行", goalTurns)])
        group("通知", rows: [("轮次完成通知", completion), ("权限请求通知", approval), ("等待回答通知", question), ("系统通知", permissionActions)])
        group("托盘与菜单栏", rows: [("显示菜单栏图标", menuBar)])
        group("阅读", rows: [("新消息保持在阅读起点", readingStart)], in: conversationPage)
        group("过程展示", rows: [("显示工具调用次数", toolCount), ("默认展开工具调用", expandTools), ("折叠回复过程", collapseProcess), ("耗时显示格式", durationFormat)], in: conversationPage)
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText; status.setAccessibilityLabel("常规设置保存状态")
        let footer = NSStackView(views: [status, NSView(), reload]); footer.spacing = 12; insertArrangedSubview(footer, at: 0); footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentGeneralSettings.changed, object: service)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPermission), name: NSApplication.didBecomeActiveNotification, object: nil)
        refresh(); refreshPermission()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func group(_ title: String, rows: [(String, NSView)], in page: NSStackView? = nil) {
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 12, weight: .medium); heading.textColor = AgentWorkbenchTheme.secondaryText
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        for (title, control) in rows {
            if !body.arrangedSubviews.isEmpty { let rule = AgentWorkbenchTheme.rule(); body.addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
            let row = AgentSettingsStyle.formRow(title, control, trailing: true); body.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let card = AgentThemeView(fill: AgentWorkbenchTheme.surface, stroke: .separatorColor); card.layer?.cornerRadius = 9; card.layer?.borderWidth = 1
        body.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16), body.topAnchor.constraint(equalTo: card.topAnchor, constant: 12), body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)])
        let column = NSStackView(views: [heading, card]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        (page ?? overview).addArrangedSubview(column); column.widthAnchor.constraint(equalTo: widthAnchor).isActive = true; card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    @objc private func refresh() {
        let value = service.settings; completion.selectItem(at: AgentCompletionNotification.allCases.firstIndex(of: value.completionNotifications) ?? 1)
        runningInput.selectItem(at: AgentRunningInput.allCases.firstIndex(of: value.runningInput) ?? 0)
        goalTurns.selectItem(at: AgentGeneralSettings.Settings.goalTurnChoices.firstIndex(of: value.goalMaximumTurns) ?? 3)
        slashMenu.selectItem(at: AgentSlashPresentation.allCases.firstIndex(of: value.slashMenuPresentation) ?? 0)
        artifactLocation.selectItem(at: AgentArtifactLocation.allCases.firstIndex(of: value.artifactLocation) ?? 0)
        questionAutoSkip.state = value.questionAutoSkip ? .on : .off
        let display = value.conversationDisplay
        readingStart.state = display.readingStart ? .on : .off; toolCount.state = display.toolCount ? .on : .off
        expandTools.state = display.expandTools ? .on : .off; collapseProcess.state = display.collapseProcess ? .on : .off
        durationFormat.selectItem(at: AgentConversationDisplay.DurationFormat.allCases.firstIndex(of: display.durationFormat) ?? 0)
        approval.state = value.approvalNotifications ? .on : .off; question.state = value.questionNotifications ? .on : .off; menuBar.state = value.menuBarIcon ? .on : .off
        for control in [completion, approval, question, menuBar, runningInput, goalTurns, slashMenu, artifactLocation, questionAutoSkip, readingStart, toolCount, expandTools, collapseProcess, durationFormat] as [NSControl] { control.isEnabled = service.error == nil }
        if let error = service.error { status.stringValue = error }
        let hidden = status.stringValue.isEmpty || status.stringValue == "已保存"
        reload.isHidden = hidden; status.superview?.isHidden = hidden
        if !hidden, window?.isKeyWindow == true {
            DispatchQueue.main.async { [weak self] in guard let self, !status.isHiddenOrHasHiddenAncestor else { return }; window?.contentView?.layoutSubtreeIfNeeded(); status.scrollToVisible(status.bounds) }
        }
    }
    @objc private func change() {
        var value = service.settings; value.completionNotifications = AgentCompletionNotification.allCases[max(0, completion.indexOfSelectedItem)]
        value.approvalNotifications = approval.state == .on; value.questionNotifications = question.state == .on; value.menuBarIcon = menuBar.state == .on
        value.runningInput = AgentRunningInput.allCases[max(0, runningInput.indexOfSelectedItem)]
        value.goalMaximumTurns = AgentGeneralSettings.Settings.goalTurnChoices[max(0, goalTurns.indexOfSelectedItem)]
        value.slashMenuPresentation = AgentSlashPresentation.allCases[max(0, slashMenu.indexOfSelectedItem)]
        value.artifactLocation = AgentArtifactLocation.allCases[max(0, artifactLocation.indexOfSelectedItem)]
        value.questionAutoSkip = questionAutoSkip.state == .on
        value.conversationDisplay = .init(readingStart: readingStart.state == .on, toolCount: toolCount.state == .on, expandTools: expandTools.state == .on, collapseProcess: collapseProcess.state == .on, durationFormat: AgentConversationDisplay.DurationFormat.allCases[max(0, durationFormat.indexOfSelectedItem)])
        do { try service.save(value); status.stringValue = "已保存" } catch { status.stringValue = error.localizedDescription }; refresh()
    }
    func matchSearch(_ query: String) {
        let direct = !query.isEmpty && AgentConversationDisplay.searchTerms.lowercased().contains(query)
        conversationBack.isHidden = direct; showConversation(direct, focus: false)
    }
    func showConversation(_ visible: Bool, focus: Bool = true) {
        conversationVisible = visible; overview.isHidden = visible; conversationPage.isHidden = !visible; onConversationPage?(visible)
        if focus { window?.makeFirstResponder(visible ? readingStart : conversationButton); enclosingScrollView?.contentView.scroll(to: .zero) }
    }
    @objc private func openConversation() { showConversation(true) }
    @objc private func closeConversation() { showConversation(false) }
    @objc private func reloadSettings() { service.reload(); service.apply(); status.stringValue = service.error ?? "已重新载入"; refresh() }
    @objc private func refreshPermission() {
        guard !updatingPermission else { return }; updatingPermission = true
        Task { [weak self] in
            guard let self else { return }; defer { updatingPermission = false }
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            switch authorization {
            case .authorized, .provisional: permission.stringValue = "已允许"; permissionButton.title = "打开系统设置"
            case .denied: permission.stringValue = "已关闭"; permissionButton.title = "打开系统设置"
            case .notDetermined: permission.stringValue = "尚未允许"; permissionButton.title = "允许通知"
            @unknown default: permission.stringValue = "状态未知"; permissionButton.title = "打开系统设置"
            }
        }
    }
    @objc private func requestPermission() {
        if authorization != .notDetermined {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { status.stringValue = "无法打开系统设置"; refresh(); return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()); return
        }
        permissionButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }; defer { permissionButton.isEnabled = true; refreshPermission() }
            do { _ = try await notifications.request() } catch { status.stringValue = error.localizedDescription; refresh() }
        }
    }
    @objc private func testNotification() {
        test.isEnabled = false
        Task { [weak self] in
            guard let self else { return }; defer { test.isEnabled = true }
            do { try await notifications.test(taskID: taskID()); status.stringValue = "测试通知已发送" } catch { status.stringValue = error.localizedDescription }; refresh()
        }
    }
}
