import AppKit

@MainActor final class AgentThinkingStatus {
    enum Loader: String, Codable, CaseIterable {
        case matrix, music, bird, fish, ascii, dots
        var title: String { self == .matrix ? "Matrix（默认）" : self == .ascii ? "ASCII" : rawValue.capitalized }
    }
    struct Caption: Codable, Equatable { var zh: String; var en: String }
    struct Settings: Codable, Equatable {
        var version = 1
        var loader = Loader.matrix
        var captions = AgentThinkingStatus.defaults
    }
    static let defaults: [Caption] = zip(
        ["思考中…", "处理中…", "正在分析…", "推理中…", "梳理思路中…", "斟酌中…", "深入思考中…", "探索思路中…", "考虑不同角度…", "理清问题中…", "整理信息中…", "理解上下文中…", "寻找思路中…", "推敲细节中…", "考虑其他可能…", "梳理关联中…", "权衡方案中…", "继续思考中…", "展开思路中…", "琢磨中…"],
        ["Thinking...", "Processing...", "Analyzing...", "Reasoning...", "Organizing thoughts...", "Deliberating...", "Thinking deeply...", "Exploring ideas...", "Considering different angles...", "Working through the problem...", "Organizing information...", "Making sense of the context...", "Looking for an approach...", "Thinking through the details...", "Considering alternatives...", "Connecting the dots...", "Weighing the options...", "Thinking further...", "Developing an idea...", "Mulling it over..."]
    ).map { Caption(zh: $0.0, en: $0.1) }
    static let changed = Notification.Name("BlueFatFishThinkingStatusChanged")
    static let searchTerms = "思考状态 加载动效 动画 文案 中文 English Matrix Music Bird Fish ASCII Dots Thinking Status Loader"
    let directory: URL
    private(set) var settings = Settings(), error: String?
    private var revision: String?
    init(directory: URL) { self.directory = directory; reload() }
    static func normalized(_ captions: [Caption]) throws -> [Caption] {
        guard captions.count == defaults.count else { throw PetError("思考文案须包含 20 组中英文内容") }
        return try captions.enumerated().map { index, caption in
            func checked(_ text: String, fallback: String) throws -> String {
                guard text.utf16.count <= 64, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }) else { throw PetError("文案最多 64 个字符，不能换行") }
                return text.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : text
            }
            return try Caption(zh: checked(caption.zh, fallback: defaults[index].zh), en: checked(caption.en, fallback: defaults[index].en))
        }
    }
    static func text(_ settings: Settings, index: Int, language: String = Locale.preferredLanguages.first ?? "zh") -> String {
        let caption = settings.captions[index % settings.captions.count]
        return language.lowercased().hasPrefix("en") ? caption.en : caption.zh
    }
    func reload() {
        do {
            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("thinking-status.json"), entry = try files.entryMetadata(file)
            guard try files.resolve("thinking-status.json") == file, ["missing", "file"].contains(entry.kind) else { throw PetError("思考状态配置必须是普通文件") }
            if entry.kind == "missing" { settings = Settings(); revision = nil }
            else {
                let data = try files.readData(file, maximum: 32_768)
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(raw.keys) == ["version", "loader", "captions"],
                      let captions = raw["captions"] as? [[String: Any]], captions.allSatisfy({ Set($0.keys) == ["zh", "en"] }),
                      var value = try? JSONDecoder().decode(Settings.self, from: data), value.version == 1 else { throw PetError("思考状态配置版本或选项无效") }
                value.captions = try Self.normalized(value.captions); settings = value; revision = AgentFiles.hash(data)
            }
            error = nil
        } catch { self.error = "思考状态配置未载入：" + error.localizedDescription }
    }
    func saveLoader(_ loader: Loader) throws { var value = settings; value.loader = loader; try save(value) }
    func saveCaptions(_ captions: [Caption], expected: [Caption]) throws {
        guard settings.captions == expected else { throw PetError("文案已在其他窗口修改，请重新载入后再编辑；当前填写内容仍保留") }
        var value = settings; value.captions = try Self.normalized(captions); try save(value)
    }
    private func save(_ value: Settings) throws {
        guard error == nil else { throw PetError(error! + "；请重新载入") }
        guard value != settings else { return }
        let files = try AgentFiles(workspace: directory.path), file = try files.literalURL("thinking-status.json"), entry = try files.entryMetadata(file)
        guard entry.kind == "missing" || entry.kind == "file" && (entry.permissions ?? 0) & 0o222 != 0 else { throw PetError("思考状态配置只读，未保存") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(value)
        let write = try AgentKnowledgeFileWrite(files: files, path: "thinking-status.json", data: data, expectedHash: revision, missing: revision == nil, permissions: 0o600, label: "思考状态配置")
        try write.requireCurrent(); try files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        settings = value; revision = AgentFiles.hash(data); NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

@MainActor final class AgentThinkingGlyph: NSView {
    var loader = AgentThinkingStatus.Loader.matrix { didSet { needsDisplay = true } }
    var frameNumber = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        AgentThemeContext.resolve(AgentWorkbenchTheme.secondaryText, in: self).set()
        let n = frameNumber, wave = { (offset: Int) in (sin(Double(n + offset) * 0.7) + 1) / 2 }
        switch loader {
        case .matrix:
            for i in 0..<9 {
                AgentThemeContext.resolve(AgentWorkbenchTheme.secondaryText, in: self).withAlphaComponent(i == n % 9 ? 1 : 0.18 + wave(i) * 0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(5 + (i % 3) * 5), y: CGFloat(4 + (i / 3) * 5), width: 3, height: 3)).fill()
            }
        case .music:
            for i in 0..<4 { let h = 4 + wave(i * 2) * 13; NSBezierPath(roundedRect: NSRect(x: 3 + Double(i) * 5, y: (22 - h) / 2, width: 3, height: h), xRadius: 1.5, yRadius: 1.5).fill() }
        case .bird:
            let path = NSBezierPath(); path.lineWidth = 1.6
            path.move(to: NSPoint(x: 3, y: 7 + wave(0) * 8)); path.curve(to: NSPoint(x: 12, y: 9), controlPoint1: NSPoint(x: 6, y: 18), controlPoint2: NSPoint(x: 8, y: 13))
            path.curve(to: NSPoint(x: 21, y: 7 + wave(0) * 8), controlPoint1: NSPoint(x: 16, y: 13), controlPoint2: NSPoint(x: 18, y: 18)); path.stroke()
        case .fish:
            let y = 8 + wave(0) * 4, path = NSBezierPath(); path.lineWidth = 1.3
            path.appendOval(in: NSRect(x: 3, y: y - 3, width: 13, height: 8)); path.move(to: NSPoint(x: 15, y: y + 1)); path.line(to: NSPoint(x: 22, y: y + 5 - wave(2) * 2)); path.line(to: NSPoint(x: 22, y: y - 3 + wave(2) * 2)); path.close(); path.stroke()
            NSBezierPath(ovalIn: NSRect(x: 6, y: y + 1, width: 1.5, height: 1.5)).fill()
        case .ascii:
            let text = ["|", "/", "—", "\\"][n % 4] as NSString
            text.draw(at: NSPoint(x: 6, y: 3), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium), .foregroundColor: AgentThemeContext.resolve(AgentWorkbenchTheme.secondaryText, in: self)])
        case .dots:
            for i in 0..<3 { AgentThemeContext.resolve(AgentWorkbenchTheme.secondaryText, in: self).withAlphaComponent(0.2 + wave(i * 3) * 0.8).setFill(); NSBezierPath(ovalIn: NSRect(x: CGFloat(3 + i * 7), y: 9, width: 4, height: 4)).fill() }
        }
    }
}

@MainActor final class AgentThinkingIndicator: NSStackView {
    private let glyph = AgentThinkingGlyph(), label = NSTextField(labelWithString: "")
    private var timer: Timer?, settings = AgentThinkingStatus.Settings(), active = false, tickCount = 0
    private var checkReducedMotion: Bool?
    init() {
        super.init(frame: .zero); orientation = .horizontal; alignment = .centerY; spacing = 8
        glyph.translatesAutoresizingMaskIntoConstraints = false; glyph.widthAnchor.constraint(equalToConstant: 24).isActive = true; glyph.heightAnchor.constraint(equalToConstant: 22).isActive = true
        label.font = .systemFont(ofSize: 13); label.textColor = AgentWorkbenchTheme.secondaryText; label.lineBreakMode = .byTruncatingTail; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(glyph); addArrangedSubview(label); label.setAccessibilityLabel("思考状态")
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSView.boundsDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshMotion), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshMotion), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshMotion() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); refreshMotion() }
    override func viewDidHide() { super.viewDidHide(); refreshMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshMotion() }
    override func layout() { super.layout(); refreshMotion() }
    func update(_ settings: AgentThinkingStatus.Settings, active: Bool) {
        if self.active != active { tickCount = 0 }
        self.settings = settings; self.active = active; glyph.loader = settings.loader; updateCaption(); refreshMotion()
    }
    private func updateCaption() {
        let text = AgentThinkingStatus.text(settings, index: (tickCount / 34) % 20)
        if label.stringValue != text { label.stringValue = text; label.toolTip = text }
    }
    @objc func refreshMotion() {
        let reduced = checkReducedMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let visible = window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty && NSApp.isActive
        if active && visible && !reduced {
            if timer == nil {
                let value = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
                value.tolerance = 0.025; timer = value; RunLoop.main.add(value, forMode: .common)
            }
        } else { timer?.invalidate(); timer = nil; if reduced { glyph.frameNumber = 0 } }
    }
    private func tick() { refreshMotion(); guard timer != nil else { return }; tickCount += 1; glyph.frameNumber = tickCount; updateCaption() }
    func readback() -> [String: Any] { ["active": active, "visible": !isHiddenOrHasHiddenAncestor && window?.isVisible == true, "animating": timer != nil, "frame": glyph.frameNumber, "ticks": tickCount, "loader": settings.loader.rawValue, "caption": label.stringValue, "reducedMotion": checkReducedMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion] }
    func checkMotion(_ reduced: Bool?) {
        guard CommandLine.arguments.contains("--thinking-status-check") else { return }; checkReducedMotion = reduced; refreshMotion()
    }
}
