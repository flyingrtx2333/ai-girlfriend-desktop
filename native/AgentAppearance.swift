import AppKit

enum AgentTheme: String, Codable, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    var appearance: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) } }
}

@MainActor final class AgentAppearance {
    struct Settings: Codable, Equatable { var version = 1; var theme = AgentTheme.system; var textSize = 14 }
    static let changed = Notification.Name("BlueFatFishAppearanceChanged")
    static private(set) var messageSize: CGFloat = 14
    static let textSizes = [12, 14, 16, 18]
    let directory: URL
    lazy var terminalDefaults = AgentTerminalAppearanceDefaults(directory: directory)
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    var onChange: (() -> Void)?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("appearance.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("appearance.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("外观配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 4096)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "theme", "textSize"] else { throw PetError("外观配置包含不支持的字段") }
                let value = try JSONDecoder().decode(Settings.self, from: data)
                try validate(value); settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "外观配置未载入：" + error.localizedDescription }
    }
    private func validate(_ value: Settings) throws {
        guard value.version == 1, Self.textSizes.contains(value.textSize) else { throw PetError("外观配置版本或字号无效") }
    }
    func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        try validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: AgentFiles(workspace: directory.path), path: "appearance.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "外观配置")
        try write.requireCurrent(); try write.files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); apply()
    }
    func apply() {
        Self.messageSize = CGFloat(settings.textSize)
        NSApp.appearance = settings.theme.appearance
        onChange?(); NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

// CALayer keeps resolved CGColors. Resolve them again when AppKit changes the
// view's appearance, including a system theme change while following macOS.
@MainActor class AgentThemeView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    convenience init(fill: NSColor, stroke: NSColor? = nil) { self.init(frame: .zero); self.fill = fill; self.stroke = stroke }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = AgentThemeContext.resolve(fill, in: self).cgColor
            layer?.borderColor = stroke.map { AgentThemeContext.resolve($0, in: self).cgColor }
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer(); needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateLayer(); needsDisplay = true }
}

@MainActor final class AgentAppearanceSettingsView: NSStackView {
    private let service: AgentAppearance, theme = NSPopUpButton(), size = NSPopUpButton()
    private let status = AgentSettingsStatusField("外观保存状态"), reload = AgentDialogButton(title: "重新载入", target: nil, action: nil)
    init(service: AgentAppearance, styles: AgentThemeStyles? = nil, content: AgentContentAppearance? = nil, fileIcons: AgentFileIcons? = nil, sidebarMenu: NSButton? = nil, terminalDefaults: AgentTerminalAppearanceDefaults? = nil, mode: @escaping () -> AgentWorkMode = { .coding }) {
        self.service = service; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 20
        theme.addItems(withTitles: AgentTheme.allCases.map(\.title)); theme.setAccessibilityLabel("界面主题")
        size.addItems(withTitles: AgentAppearance.textSizes.map { "\($0)" }); size.setAccessibilityLabel("对话字号")
        for control in [theme, size] { control.target = self; control.action = #selector(change) }
        reload.target = self; reload.action = #selector(reloadSettings); AgentDialogStyle.action(reload)
        let feedback = NSStackView(views: [status, NSView(), reload]); feedback.alignment = .centerY; feedback.spacing = 8
        addArrangedSubview(feedback)

        var themeRows: [NSView] = [AgentSettingsStyle.formRow("明暗模式", theme, trailing: true)]
        if let styles { themeRows.append(AgentThemeStyleSelectionView(service: styles, gallery: true, mode: mode)) }
        if let terminalDefaults { themeRows += [AgentSettingsStyle.divider(), AgentTerminalAppearanceRow(service: terminalDefaults)] }
        addArrangedSubview(AgentSettingsStyle.section("主题", id: "appearance-theme", rows: themeRows, separatesRows: false))

        var conversationRows: [NSView] = [AgentSettingsStyle.formRow("对话字号", size, trailing: true)]
        if let content { conversationRows.append(AgentContentAppearanceSettingsView(service: content)) }
        addArrangedSubview(AgentSettingsStyle.section("对话", id: "appearance-conversation", rows: conversationRows))

        var interfaceRows: [NSView] = []
        if let fileIcons { interfaceRows.append(AgentFileIconsSettingsView(service: fileIcons)) }
        if let sidebarMenu { interfaceRows.append(AgentSettingsStyle.formRow("侧栏菜单", sidebarMenu, trailing: true)) }
        if !interfaceRows.isEmpty {
            addArrangedSubview(AgentSettingsStyle.section("界面", id: "appearance-interface", rows: interfaceRows))
        }
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentAppearance.changed, object: service)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func refresh() {
        theme.selectItem(at: AgentTheme.allCases.firstIndex(of: service.settings.theme) ?? 0)
        size.selectItem(at: AgentAppearance.textSizes.firstIndex(of: service.settings.textSize) ?? 1)
        theme.isEnabled = service.error == nil; size.isEnabled = service.error == nil
        if let error = service.error { status.stringValue = error }
        reload.isHidden = status.stringValue.isEmpty || status.stringValue == "已保存"
        status.superview?.isHidden = status.stringValue.isEmpty
    }
    @objc private func change() {
        var value = service.settings
        value.theme = AgentTheme.allCases[max(0, theme.indexOfSelectedItem)]
        value.textSize = AgentAppearance.textSizes[max(0, size.indexOfSelectedItem)]
        do { try service.save(value); status.stringValue = "已保存" }
        catch { status.showSaveFailure(error) }
        refresh()
    }
    @objc private func reloadSettings() { service.reload(); service.apply(); status.stringValue = service.error ?? "已重新载入"; refresh() }
}

@MainActor private final class AgentTerminalAppearanceRow: NSStackView {
    private let service: AgentTerminalAppearanceDefaults
    private let picker = NSPopUpButton()
    private let status = AgentSettingsStatusField("终端外观状态")
    private let reload = AgentDialogButton(title: "重新载入", target: nil, action: nil)

    init(service: AgentTerminalAppearanceDefaults) {
        self.service = service
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        picker.addItems(withTitles: AgentTerminalAppearance.allCases.map(\.title))
        picker.setAccessibilityLabel("默认终端外观")
        picker.toolTip = "新窗口和使用默认设置的终端"
        picker.target = self; picker.action = #selector(change)
        reload.target = self; reload.action = #selector(reloadPreference)
        AgentDialogStyle.action(reload)
        let row = AgentSettingsStyle.formRow("终端外观", picker, trailing: true)
        let feedback = NSStackView(views: [status, NSView(), reload]); feedback.alignment = .centerY; feedback.spacing = 8
        for view in [row, feedback] { addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        status.onChange = { [weak feedback] message in feedback?.isHidden = message.isEmpty }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentTerminalAppearanceDefaults.changed, object: service)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func refresh() {
        picker.selectItem(withTitle: service.appearance.title)
        picker.isEnabled = service.error == nil
        (picker.superview as? AgentSettingsPopupFrame)?.refreshEnabledState()
        status.stringValue = service.error ?? ""
    }

    @objc private func change() {
        guard AgentTerminalAppearance.allCases.indices.contains(picker.indexOfSelectedItem) else { return }
        do { try service.save(AgentTerminalAppearance.allCases[picker.indexOfSelectedItem]) }
        catch { refresh(); status.showSaveFailure(error) }
    }

    @objc private func reloadPreference() { service.reload() }
}
