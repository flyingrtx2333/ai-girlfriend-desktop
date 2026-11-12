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
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor; layer?.borderColor = stroke?.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer(); needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateLayer(); needsDisplay = true }
}

@MainActor final class AgentAppearanceSettingsView: NSStackView {
    private let service: AgentAppearance, theme = NSPopUpButton(), size = NSPopUpButton()
    private let status = NSTextField(labelWithString: ""), reload = NSButton(title: "重新载入", target: nil, action: nil)
    init(service: AgentAppearance) {
        self.service = service; super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 10
        theme.addItems(withTitles: AgentTheme.allCases.map(\.title)); theme.setAccessibilityLabel("界面主题")
        size.addItems(withTitles: AgentAppearance.textSizes.map { "\($0)" }); size.setAccessibilityLabel("对话字号")
        for (title, control) in [("主题", theme), ("对话字号", size)] {
            control.target = self; control.action = #selector(change); control.widthAnchor.constraint(equalToConstant: 160).isActive = true
            if !arrangedSubviews.isEmpty { let rule = AgentWorkbenchTheme.rule(); addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
            let row = AgentSettingsStyle.formRow(title, control, trailing: true); addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText
        reload.target = self; reload.action = #selector(reloadSettings)
        let footer = NSStackView(views: [status, NSView(), reload]); footer.spacing = 12; addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
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
        catch { status.stringValue = error.localizedDescription }
        refresh()
    }
    @objc private func reloadSettings() { service.reload(); service.apply(); status.stringValue = service.error ?? "已重新载入"; refresh() }
}
