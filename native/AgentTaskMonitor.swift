import AppKit

enum AgentMonitorPresentation: String, Codable, CaseIterable {
    case fixed, floating
    var title: String { self == .fixed ? "固定" : "浮动" }
}

enum AgentMonitorSection: String, Codable, CaseIterable, Hashable {
    case recap, goal, plan, agents, processes, sideChats, capabilities, outputs, web, sources, knowledge, memory, preview
    var title: String {
        switch self {
        case .recap: return "任务回顾"; case .goal: return "任务目标"; case .plan: return "计划"
        case .agents: return "子智能体"; case .processes: return "后台进程"; case .sideChats: return "侧边聊天"; case .capabilities: return "Skill 与 MCP"
        case .outputs: return "产出"; case .web: return "网页查阅"; case .sources: return "来源"; case .knowledge: return "知识"
        case .memory: return "记忆更新"; case .preview: return "演示画面"
        }
    }
    static let groups: [(String, [Self])] = [("进度与上下文", [.recap, .goal, .plan]), ("执行活动", [.agents, .processes, .sideChats, .capabilities]), ("结果与来源", [.outputs, .web, .sources, .knowledge]), ("辅助入口", [.memory, .preview])]
}

@MainActor final class AgentTaskMonitor {
    struct Settings: Codable, Equatable {
        var version = 1
        var presentation = AgentMonitorPresentation.fixed
        var dockedDefaultVisible = true
        var sections = AgentMonitorSection.allCases
        var recapModel: String?
        func shows(_ section: AgentMonitorSection) -> Bool { sections.contains(section) }
    }
    struct DisplayState {
        var presentation: AgentMonitorPresentation, visible: Bool
        var explicitVisibility = false
        var frame: NSRect?
        init(_ settings: Settings) { presentation = settings.presentation; visible = settings.presentation == .fixed && settings.dockedDefaultVisible }
    }
    static let changed = Notification.Name("BlueFatFishTaskMonitorChanged")
    let directory: URL
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    var onChange: (() -> Void)?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("task-monitor.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("task-monitor.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("任务监控配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 8192)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys).subtracting(["recapModel"]) == ["version", "presentation", "dockedDefaultVisible", "sections"],
                      let value = try? JSONDecoder().decode(Settings.self, from: data) else { throw PetError("任务监控配置版本或选项无效") }
                try validate(value); settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "任务监控未载入：" + error.localizedDescription }
    }
    private func validate(_ value: Settings) throws {
        guard value.version == 1, Set(value.sections).count == value.sections.count else { throw PetError("任务监控配置版本或分区无效") }
        if let model = value.recapModel, !AgentTaskModels.validID(model) { throw PetError("请输入有效的回顾模型 ID") }
    }
    func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        try validate(value); guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("task-monitor.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("任务监控配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "task-monitor.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "任务监控配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); apply()
    }
    func apply() { onChange?(); NotificationCenter.default.post(name: Self.changed, object: self) }
}

@MainActor final class AgentTaskMonitorSettingsView: NSStackView, NSMenuDelegate {
    private let service: AgentTaskMonitor, presentation = NSPopUpButton(), visible = NSPopUpButton(), model = NSPopUpButton()
    private let modelChoices: () -> [String]
    private var switches: [AgentMonitorSection: NSSwitch] = [:]
    private let status = NSTextField(wrappingLabelWithString: ""), reload = NSButton(title: "重新载入", target: nil, action: nil)
    init(service: AgentTaskMonitor, models: @escaping () -> [String]) {
        self.service = service; self.modelChoices = models; super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 18
        presentation.addItems(withTitles: AgentMonitorPresentation.allCases.map(\.title)); presentation.setAccessibilityLabel("任务监控形式"); presentation.identifier = NSUserInterfaceItemIdentifier("monitor-presentation")
        visible.addItems(withTitles: ["默认展示", "默认隐藏"]); visible.setAccessibilityLabel("固定模式默认展示"); visible.identifier = NSUserInterfaceItemIdentifier("monitor-default-visible")
        for choice in [presentation, visible] { choice.target = self; choice.action = #selector(change); choice.widthAnchor.constraint(equalToConstant: 170).isActive = true }
        group("展示方式", rows: [AgentSettingsStyle.formRow("任务监控形式", presentation, trailing: true), AgentSettingsStyle.formRow("固定模式默认展示", visible, trailing: true)])
        model.target = self; model.action = #selector(changeModel); model.menu?.delegate = self
        model.setAccessibilityLabel("回顾模型"); model.identifier = NSUserInterfaceItemIdentifier("monitor-recap-model"); model.widthAnchor.constraint(equalToConstant: 220).isActive = true
        for (title, sections) in AgentMonitorSection.groups {
            var rows: [NSView] = []
            for section in sections {
                let toggle = NSSwitch(); toggle.target = self; toggle.action = #selector(change); toggle.setAccessibilityLabel(section.title); toggle.identifier = NSUserInterfaceItemIdentifier("monitor-section-" + section.rawValue); switches[section] = toggle
                rows.append(AgentSettingsStyle.formRow(section.title, toggle, trailing: true))
                if section == .recap { rows.append(AgentSettingsStyle.formRow("回顾模型", model, trailing: true)) }
            }
            group(title, rows: rows)
        }
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText; reload.target = self; reload.action = #selector(reloadSettings)
        let footer = NSStackView(views: [status, NSView(), reload]); footer.spacing = 12; addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentTaskMonitor.changed, object: service); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func group(_ title: String, rows: [NSView]) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = AgentWorkbenchTheme.secondaryText; addArrangedSubview(label)
        for (index, row) in rows.enumerated() {
            if index > 0 { let rule = AgentWorkbenchTheme.rule(); addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
            addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
    @objc private func refresh() {
        presentation.selectItem(at: AgentMonitorPresentation.allCases.firstIndex(of: service.settings.presentation) ?? 0); visible.selectItem(at: service.settings.dockedDefaultVisible ? 0 : 1)
        presentation.isEnabled = service.error == nil; visible.isEnabled = service.error == nil && service.settings.presentation == .fixed
        for (section, toggle) in switches { toggle.state = service.settings.shows(section) ? .on : .off; toggle.isEnabled = service.error == nil }
        refreshModels(); model.isEnabled = service.error == nil && service.settings.shows(.recap)
        if let error = service.error { status.stringValue = error }; reload.isHidden = status.stringValue.isEmpty || status.stringValue == "已保存"; status.superview?.isHidden = status.stringValue.isEmpty
    }
    private func save(_ value: AgentTaskMonitor.Settings) {
        do { try service.save(value); status.stringValue = "已保存" } catch { status.stringValue = error.localizedDescription }; refresh()
    }
    @objc private func change() {
        var value = service.settings; value.presentation = AgentMonitorPresentation.allCases[max(0, presentation.indexOfSelectedItem)]; value.dockedDefaultVisible = visible.indexOfSelectedItem == 0
        value.sections = AgentMonitorSection.allCases.filter { switches[$0]?.state == .on }; save(value)
    }
    private func refreshModels() {
        let values = Set(modelChoices() + [service.settings.recapModel].compactMap { $0 }).filter(AgentTaskModels.validID).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        model.removeAllItems(); model.addItem(withTitle: "跟随会话")
        for id in values { model.addItem(withTitle: id); model.lastItem?.representedObject = id }
        model.selectItem(at: service.settings.recapModel.flatMap { values.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
    }
    func menuWillOpen(_ menu: NSMenu) { if menu === model.menu { refreshModels() } }
    @objc private func changeModel() { var value = service.settings; value.recapModel = model.selectedItem?.representedObject as? String; save(value) }
    @objc private func reloadSettings() { service.reload(); service.apply(); status.stringValue = service.error ?? "已重新载入"; refresh() }
}
