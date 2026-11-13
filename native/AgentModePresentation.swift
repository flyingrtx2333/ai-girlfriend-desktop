import AppKit

@MainActor final class AgentModePresentation {
    struct Presentation: Codable, Equatable {
        var projectEntry: Bool
        var inputEnvironment: Bool
        var changeReview: Bool
        static func defaults(_ mode: AgentWorkMode) -> Self {
            let visible = mode == .coding
            return Self(projectEntry: visible, inputEnvironment: visible, changeReview: visible)
        }
    }
    struct Settings: Codable, Equatable {
        var version = 1
        var coding = Presentation.defaults(.coding), general = Presentation.defaults(.general)
        subscript(_ mode: AgentWorkMode) -> Presentation {
            get { mode == .coding ? coding : general }
            set { if mode == .coding { coding = newValue } else { general = newValue } }
        }
    }
    static let changed = Notification.Name("BlueFatFishModePresentationChanged")
    let directory: URL
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    var onChange: (() -> Void)?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("mode-presentation.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("mode-presentation.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("模式配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 4096)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "coding", "general"],
                      ["coding", "general"].allSatisfy({ key in
                          guard let value = raw[key] as? [String: Any] else { return false }
                          return Set(value.keys) == ["projectEntry", "inputEnvironment", "changeReview"]
                      }) else { throw PetError("模式配置包含不支持或缺少的字段") }
                let value = try JSONDecoder().decode(Settings.self, from: data)
                guard value.version == 1 else { throw PetError("模式配置版本无效") }
                settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "模式配置未载入：" + error.localizedDescription }
    }
    func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        guard value.version == 1 else { throw PetError("模式配置版本无效") }
        guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("mode-presentation.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("模式配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "mode-presentation.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "模式配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); publish()
    }
    func publish() { onChange?(); NotificationCenter.default.post(name: Self.changed, object: self) }
}

@MainActor final class AgentModeSettingsView: NSStackView {
    private let service: AgentModePresentation, mode: AgentWorkMode
    private let project = NSSwitch(), environment = NSSwitch(), changes = NSSwitch()
    private let status = NSTextField(wrappingLabelWithString: ""), reload = NSButton(title: "重新载入", target: nil, action: nil)
    init(service: AgentModePresentation, mode: AgentWorkMode) {
        self.service = service; self.mode = mode; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 0
        for (index, pair) in [("项目选择入口", project), ("输入区运行环境", environment), ("变更审阅", changes)].enumerated() {
            let (title, control) = pair
            control.tag = index; control.target = self; control.action = #selector(change(_:))
            control.setAccessibilityLabel(mode.title + "：" + title)
            control.identifier = NSUserInterfaceItemIdentifier("mode-\(mode.rawValue)-\(index)")
            if !arrangedSubviews.isEmpty { let rule = AgentWorkbenchTheme.rule(); addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
            let row = AgentSettingsStyle.formRow(title, control, trailing: true)
            addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        project.toolTip = "显示任务顶部和新任务中的项目或文件夹选择入口"
        environment.toolTip = "显示输入区的本地、工作树和 Git 分支入口"
        changes.toolTip = "显示 Git 审阅入口和记录侧栏中的文件变更；已打开的审阅与执行记录继续保留"
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText
        reload.target = self; reload.action = #selector(reloadSettings)
        let restore = NSButton(title: "恢复展示默认", target: self, action: #selector(restoreDefaults)); restore.toolTip = "恢复" + mode.title + "模式的展示偏好"
        let footer = NSStackView(views: [status, NSView(), reload, restore]); footer.spacing = 12
        addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        setCustomSpacing(12, after: arrangedSubviews[arrangedSubviews.count - 2])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentModePresentation.changed, object: service)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func refresh() {
        let value = service.settings[mode]
        project.state = value.projectEntry ? .on : .off; environment.state = value.inputEnvironment ? .on : .off; changes.state = value.changeReview ? .on : .off
        for control in [project, environment, changes] { control.isEnabled = service.error == nil }
        if let error = service.error { status.stringValue = error }
        reload.isHidden = status.stringValue.isEmpty || status.stringValue == "已保存"
    }
    private func save(_ value: AgentModePresentation.Presentation) {
        var settings = service.settings; settings[mode] = value
        do { try service.save(settings); status.stringValue = "已保存" }
        catch { status.stringValue = error.localizedDescription }
        refresh()
    }
    @objc private func change(_ sender: NSSwitch) {
        var value = service.settings[mode]
        switch sender.tag { case 0: value.projectEntry = sender.state == .on; case 1: value.inputEnvironment = sender.state == .on; case 2: value.changeReview = sender.state == .on; default: return }
        save(value)
    }
    @objc private func restoreDefaults() { save(.defaults(mode)) }
    @objc private func reloadSettings() { service.reload(); service.publish(); status.stringValue = service.error ?? "已重新载入"; refresh() }
}
