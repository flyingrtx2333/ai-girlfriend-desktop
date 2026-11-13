import AppKit

enum AgentContentFont: String, Codable, CaseIterable {
    case sans, serif
    var title: String { self == .sans ? "无衬线" : "衬线" }
    @MainActor func font(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard self == .serif, let descriptor = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }
}
enum AgentContentWidth: String, Codable, CaseIterable {
    case standard, wide
    var title: String { self == .standard ? "标准" : "宽" }
    var maximum: CGFloat { self == .standard ? 760 : 1040 }
}

@MainActor final class AgentContentAppearance {
    struct Settings: Codable, Equatable { var version = 1; var fontStyle = AgentContentFont.sans; var contentWidth = AgentContentWidth.standard }
    static let changed = Notification.Name("BlueFatFishContentAppearanceChanged")
    static private(set) var fontStyle = AgentContentFont.sans
    static func font(size: CGFloat) -> NSFont { fontStyle.font(size: size) }
    let directory: URL
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    var onChange: (() -> Void)?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("content-appearance.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("content-appearance.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("内容外观配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 4096)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "fontStyle", "contentWidth"] else { throw PetError("内容外观配置包含不支持或缺少的字段") }
                guard let value = try? JSONDecoder().decode(Settings.self, from: data), value.version == 1 else { throw PetError("内容外观配置版本或选项无效") }
                settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "内容外观未载入：" + error.localizedDescription }
    }
    func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        guard value.version == 1 else { throw PetError("内容外观配置版本无效") }
        guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("content-appearance.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("内容外观配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "content-appearance.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "内容外观配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); apply()
    }
    func apply() { Self.fontStyle = settings.fontStyle; onChange?(); NotificationCenter.default.post(name: Self.changed, object: self) }
}

@MainActor final class AgentContentAppearanceSettingsView: NSStackView {
    private let service: AgentContentAppearance, fontStyle = NSPopUpButton(), width = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: ""), reload = NSButton(title: "重新载入", target: nil, action: nil)
    init(service: AgentContentAppearance) {
        self.service = service; super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 10
        fontStyle.addItems(withTitles: AgentContentFont.allCases.map(\.title)); fontStyle.setAccessibilityLabel("字体风格"); fontStyle.identifier = NSUserInterfaceItemIdentifier("content-font-style")
        width.addItems(withTitles: AgentContentWidth.allCases.map(\.title)); width.setAccessibilityLabel("内容宽度"); width.identifier = NSUserInterfaceItemIdentifier("content-width")
        for (title, control) in [("字体风格", fontStyle), ("内容宽度", width)] {
            control.target = self; control.action = #selector(change); control.widthAnchor.constraint(equalToConstant: 160).isActive = true
            if !arrangedSubviews.isEmpty { let rule = AgentWorkbenchTheme.rule(); addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
            let row = AgentSettingsStyle.formRow(title, control, trailing: true); addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        status.font = .systemFont(ofSize: 12); status.textColor = AgentWorkbenchTheme.secondaryText
        reload.target = self; reload.action = #selector(reloadSettings)
        let footer = NSStackView(views: [status, NSView(), reload]); footer.spacing = 12; addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AgentContentAppearance.changed, object: service); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func refresh() {
        fontStyle.selectItem(at: AgentContentFont.allCases.firstIndex(of: service.settings.fontStyle) ?? 0)
        width.selectItem(at: AgentContentWidth.allCases.firstIndex(of: service.settings.contentWidth) ?? 0)
        for control in [fontStyle, width] { control.isEnabled = service.error == nil }
        if let error = service.error { status.stringValue = error }
        reload.isHidden = status.stringValue.isEmpty || status.stringValue == "已保存"; status.superview?.isHidden = status.stringValue.isEmpty
    }
    @objc private func change() {
        var value = service.settings; value.fontStyle = AgentContentFont.allCases[max(0, fontStyle.indexOfSelectedItem)]; value.contentWidth = AgentContentWidth.allCases[max(0, width.indexOfSelectedItem)]
        do { try service.save(value); status.stringValue = "已保存" } catch { status.stringValue = error.localizedDescription }
        refresh()
    }
    @objc private func reloadSettings() { service.reload(); service.apply(); status.stringValue = service.error ?? "已重新载入"; refresh() }
}
