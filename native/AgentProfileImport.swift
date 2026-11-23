import AppKit

enum AgentProfileImportSource: Codable, Equatable {
    case file(path: String, hash: String)
    case pasted(document: String)

    static let maximum = 512_000
    var path: String? { if case .file(let path, _) = self { return path }; return nil }
    var label: String { path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "粘贴的 JSON" }
    var valid: Bool {
        switch self {
        case .file(let path, let hash):
            return path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 16_384 && AgentSettingsRecovery.validHash(hash)
        case .pasted(let document): return Self.validDocument(document)
        }
    }
    static func validDocument(_ value: String) -> Bool { value.utf8.count <= maximum && !value.contains("\0") }
    static func read(_ url: URL) throws -> Self {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        return .file(path: file.path, hash: AgentFiles.hash(try readFile(file.path)))
    }
    private static func readFile(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path), files = try AgentFiles(workspace: url.deletingLastPathComponent().path, followParentLinks: false)
        guard try files.literalURL(url.path) == url.resolvingSymlinksInPath() else { throw PetError("智能体导入文件的位置已变化") }
        return try files.readData(url, maximum: maximum)
    }
    func document() throws -> String {
        guard valid else { throw PetError("智能体 JSON 需为不超过 512 KB 的文本") }
        switch self {
        case .pasted(let document): return document
        case .file(let path, let hash):
            let data = try Self.readFile(path)
            guard AgentFiles.hash(data) == hash else { throw PetError("来源文件已变化，请重新读取后审阅") }
            guard let document = String(data: data, encoding: .utf8) else { throw PetError("智能体 JSON 文件需要使用 UTF-8") }
            return document
        }
    }
    @MainActor func roles(in service: AgentProfiles) throws -> [AgentProfile] {
        let text = try document()
        _ = try AgentConfigurationJSON.object(Data(text.utf8))
        let roles = try service.decode(text, importing: true)
        guard !roles.isEmpty else { throw PetError("请在 agents 数组中提供至少一个智能体") }
        return roles
    }
}

@MainActor final class AgentProfileImportEditor: AgentSettingsPageController, NSTextViewDelegate {
    private struct Recovery: Codable {
        var version = 1
        let document: String
        let reading: AgentTextViewport
    }
    private let editor = NSTextView()
    private let scroll = NSScrollView()
    private lazy var feedback = AgentSettingsJSONFeedback("智能体 JSON 校验状态", editor: editor)
    private let previewButton = AgentDialogButton(title: "审阅", target: nil, action: nil)
    private var pending: AgentTextViewport?, scheduled = false
    var onReview: ((String) throws -> Void)?

    init(document: String = "") {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "粘贴智能体 JSON"; window.center()
        super.init(window: window)
        detailHeading = .init(title: "粘贴智能体 JSON", scope: "用户")
        editor.delegate = self; editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.string = document
        editor.isVerticallyResizable = true; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 14, height: 12); editor.autoresizingMask = [.width]
        editor.setAccessibilityLabel("智能体导入 JSON")
        scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        scroll.identifier = .init("agent-import-json")
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(readingChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        previewButton.target = self; previewButton.action = #selector(review)
        AgentSettingsStyle.primaryAction(previewButton)
        let cancel = AgentDialogButton(title: "取消", target: self, action: #selector(cancelImport))
        AgentDialogStyle.action(cancel); cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        let actions = AgentSettingsDetailActions([cancel, previewButton]); detailActionRow = actions
        let content = AgentThemeView(fill: AgentWorkbenchTheme.settings); window.contentView = content
        let layout = NSStackView(views: [feedback, scroll, actions])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 8
        content.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        for row in layout.arrangedSubviews { row.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 8), layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        updateActions()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var minimumSettingsContentHeight: CGFloat { 228 }
    override var usesInternalScrolling: Bool { true }
    override func settingsDidAppear() {
        if pending == nil { presentingWindow?.makeFirstResponder(editor) } else { scheduleRestore() }
    }
    override func pageDidLayout() { scheduleRestore() }
    private func scheduleRestore() {
        guard pending != nil, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { scheduled = false }
            guard isPageVisible, let pending else { return }
            if pending.apply(to: editor) { self.pending = nil }
        }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let original = textView.string as NSString
        let removedBytes = original.substring(with: affectedCharRange).utf8.count
        guard AgentProfileImportSource.validDocument(replacementString),
              textView.string.utf8.count - removedBytes + replacementString.utf8.count <= AgentProfileImportSource.maximum else {
            feedback.stringValue = "请输入不超过 512 KB 的 JSON 文本"
            return false
        }
        return true
    }
    func textDidChange(_ notification: Notification) { pending = nil; feedback.stringValue = ""; updateActions(); readingChanged() }
    func textViewDidChangeSelection(_ notification: Notification) { readingChanged() }
    @objc private func readingChanged() { if pending == nil { onSettingsRecoveryChange?() } }
    private func updateActions() {
        previewButton.isEnabled = !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @objc private func review() {
        do { try onReview?(editor.string) } catch { feedback.showSaveFailure(error) }
    }
    @objc private func cancelImport() { close() }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        guard AgentProfileImportSource.validDocument(editor.string) else { throw PetError("智能体 JSON 超过恢复上限，当前输入已保留") }
        let reading = try pending ?? AgentTextViewport(editor)
        return try AgentSettingsRecovery.page("agent-import-editor", Recovery(document: editor.string, reading: reading))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "agent-import-editor" else { throw PetError("设置草稿不属于智能体导入") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "document", "reading"])
        if let reading = raw["reading"] { try AgentTextViewport.validateObject(reading) }
        let saved = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard saved.version == 1, AgentProfileImportSource.validDocument(saved.document), saved.reading.valid else { throw PetError("智能体 JSON 草稿无效") }
        editor.string = saved.document
        guard saved.reading.matches(editor) else { throw PetError("智能体 JSON 草稿的阅读位置已变化") }
        pending = saved.reading; updateActions()
    }
}

@MainActor final class AgentProfileImportReview: AgentSettingsReviewPage {
    private struct Recovery: Codable {
        var version = 1
        let source: AgentProfileImportSource
        let targetHash: String?
        let reading: ReadingLocation
    }
    private let service: AgentProfiles
    private var source: AgentProfileImportSource, targetHash: String?
    private var roles: [AgentProfile] = []
    private var savedReading: ReadingLocation?
    private let alternative = AgentDialogButton(title: "", target: nil, action: nil)
    private let loadDraft = AgentDialogButton(title: "载入草稿", target: nil, action: nil)
    var requireDestination: (() throws -> Void)?
    var onDraft: ((AgentProfile, [AgentProfile], String?) throws -> Void)?
    var onDraftOpened: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var count: Int { roles.count }

    init(service: AgentProfiles, source: AgentProfileImportSource, targetHash: String?) {
        self.service = service; self.source = source; self.targetHash = targetHash
        super.init(title: "智能体导入审阅", metadata: "用户 · " + source.label, notice: "导入后停用", sections: [],
                   applyTitle: "导入", secondaryActions: [alternative, loadDraft])
        detailHeading = .init(title: "智能体导入审阅", scope: "用户 · " + source.label, location: source.path)
        alternative.title = source.path == nil ? "编辑 JSON" : "重新读取"
        alternative.target = self; alternative.action = #selector(changeSource)
        loadDraft.target = self; loadDraft.action = #selector(stageSelected)
        for button in [alternative, loadDraft] { AgentDialogStyle.action(button) }
        trackReviewReading()
        onApply = { [weak self] in
            guard let self else { return }
            try requireDestination?()
            _ = try self.source.document()
            let target = try currentTarget()
            try service.save(service.encode(target + roles), expectedHash: self.targetHash)
        }
    }
    convenience init(service: AgentProfiles, recovery: AgentSettingsRecovery.Page) throws {
        let saved = try Self.decodeRecovery(recovery)
        self.init(service: service, source: saved.source, targetHash: saved.targetHash)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func load(_ prepared: [AgentProfile]? = nil, reading: ReadingLocation? = nil) {
        do {
            roles = try prepared ?? source.roles(in: service)
            updateSections(roles.map { ($0.name, Self.reviewText($0)) })
            setApplyTitle("导入 \(roles.count) 项")
            if let reading { restoreReviewReading(reading) }
            savedReading = nil
            let target = try currentTarget()
            loadDraft.isEnabled = true
            _ = try service.decode(service.encode(target + roles))
        } catch {
            if roles.isEmpty || (try? source.document()) == nil || (try? currentTarget()) == nil {
                loadDraft.isEnabled = false
                savedReading = reading ?? savedReading
            }
            showPreviewFailure(error)
        }
    }
    private func currentTarget() throws -> [AgentProfile] {
        let value = try service.document()
        guard value.1 == targetHash else { throw PetError("用户智能体配置已变化，请重新核对后导入") }
        return try service.decode(value.0)
    }
    private static func reviewText(_ profile: AgentProfile) -> String {
        let tools = profile.tools.map(AgentProfileWindow.toolTitle).joined(separator: "、")
        var lines = [
            profile.description.isEmpty ? nil : profile.description,
            profile.model.isEmpty ? nil : "模型  " + profile.model,
            "审批方式  " + profile.permission.title,
            "项目访问  " + (profile.readOnly ? "只读" : "读写"),
            "外部连接  " + (profile.network ? "允许" : "关闭"),
            tools.isEmpty ? nil : "工具  " + tools
        ].compactMap { $0 }
        if let skills = profile.skills, !skills.isEmpty { lines.append("Skills  " + skills.joined(separator: "、")) }
        if let servers = profile.mcpServers, !servers.isEmpty { lines.append("MCP  " + servers.joined(separator: "、")) }
        if let rules = profile.toolPermissions {
            lines += rules.keys.sorted().map { AgentProfileWindow.toolTitle($0) + "  " + rules[$0]!.rawValue }
        }
        if let rules = profile.mcpToolPermissions {
            lines += rules.map { $0.serverID + " / " + $0.tool + "  " + $0.permission.rawValue }
        }
        return lines.joined(separator: "\n") + "\n\n工作指令\n" + profile.instructions
    }
    @objc private func changeSource() {
        if case .pasted(let document) = source { close(); onEdit?(document); return }
        guard let path = source.path else { return }
        do {
            try requireDestination?()
            let reading = try savedReading ?? captureReviewReading()
            let refreshed = try AgentProfileImportSource.read(URL(fileURLWithPath: path))
            let incoming = try refreshed.roles(in: service)
            targetHash = try service.document().1
            source = refreshed
            load(incoming, reading: reading)
            onSettingsRecoveryChange?()
        } catch { loadDraft.isEnabled = false; showPreviewFailure(error) }
    }
    @objc private func stageSelected() {
        guard loadDraft.isEnabled, let role = roles.first(where: { $0.name == selectedSection }) else { return }
        do {
            try requireDestination?()
            _ = try source.document()
            let target = try currentTarget()
            try onDraft?(role, target, targetHash)
            close(); onDraftOpened?()
        } catch { loadDraft.isEnabled = false; showPreviewFailure(error) }
    }
    private static func decodeRecovery(_ page: AgentSettingsRecovery.Page) throws -> Recovery {
        guard page.kind == "agent-import-review" else { throw PetError("设置草稿不属于智能体导入审阅") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "source", "targetHash", "reading"])
        if let reading = raw["reading"] { try ReadingLocation.validateObject(reading) }
        let value = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard value.version == 1, value.source.valid, AgentSettingsRecovery.validHash(value.targetHash), value.reading.valid else { throw PetError("智能体导入审阅记录无效") }
        return value
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        try AgentSettingsRecovery.page("agent-import-review",
            Recovery(source: source, targetHash: targetHash, reading: savedReading ?? captureReviewReading()))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        let value = try Self.decodeRecovery(page)
        guard value.source == source && value.targetHash == targetHash else { throw PetError("智能体导入审阅的来源已变化") }
        load(reading: value.reading)
    }
}
