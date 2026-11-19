import AppKit

struct AgentGitPreferences {
    struct Values: Codable, Equatable {
        var branchPrefix = "agent/"
        var commitInstructions = ""
    }

    struct Snapshot {
        var values = Values()
        var revision: String?
    }

    let profile: URL
    private let filename = "git-preferences.json"

    func read() throws -> Snapshot {
        let files = try AgentFiles(workspace: profile.path)
        let url = try files.literalURL(filename), entry = try files.entryMetadata(url)
        guard try files.resolve(filename) == url, ["missing", "file"].contains(entry.kind) else {
            throw PetError("Git 设置必须是普通文件")
        }
        if entry.kind == "missing" { return Snapshot() }
        let data = try files.readData(url, maximum: 128_000)
        _ = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: data), keys: ["branchPrefix", "commitInstructions"])
        let values = try JSONDecoder().decode(Values.self, from: data)
        try Self.validate(values)
        return Snapshot(values: values, revision: AgentFiles.hash(data))
    }

    func save(_ values: Values, replacing revision: String?) throws -> Snapshot {
        try Self.validate(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        let files = try AgentFiles(workspace: profile.path)
        let write = try AgentKnowledgeFileWrite(files: files, path: filename, data: data, expectedHash: revision,
                                                missing: revision == nil, permissions: 0o600, label: "Git 设置")
        try write.requireCurrent()
        try write.files.writeData(data, to: write.url, permissions: 0o600, expectedTarget: write.signature)
        return Snapshot(values: values, revision: AgentFiles.hash(data))
    }

    func suggestedBranch() -> String {
        let prefix = (try? read().values.branchPrefix) ?? Values().branchPrefix
        return prefix + String(UUID().uuidString.lowercased().prefix(8))
    }

    static func validate(_ values: Values) throws {
        let prefix = values.branchPrefix
        guard prefix.utf8.count <= 180, !prefix.contains("\0"), !prefix.hasPrefix("-") else { throw PetError("请输入有效的分支前缀，最多 180 字节") }
        if !prefix.isEmpty, prefix != Values().branchPrefix {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: try AgentGit.executablePath())
            git.arguments = ["check-ref-format", "refs/heads/" + prefix + "00000000"]
            git.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice
            try git.run(); git.waitUntilExit()
            guard git.terminationStatus == 0 else { throw PetError("分支前缀会生成无效的 Git 分支名") }
        }
        guard values.commitInstructions.utf8.count <= 16_384, !values.commitInstructions.contains("\0") else {
            throw PetError("提交说明指令最多 16384 字节")
        }
    }
}

@MainActor final class AgentGitPreferencesPage: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private let preferences: AgentGitPreferences
    private let prefix = AgentDialogTextField(), instructions = NSTextView()
    private let status = AgentSettingsStatusField("Git 设置保存状态")
    private let save = AgentDialogButton(title: "保存", target: nil, action: nil)
    private var saved: AgentGitPreferences.Snapshot?
    private lazy var viewport: AgentSettingsDraftViewport = {
        let value = AgentSettingsDraftViewport(text: instructions, fields: ["prefix": prefix], catalog: instructions, host: { [weak self] in self?.presentingWindow })
        value.onChange = { [weak self] in self?.onSettingsRecoveryChange?() }
        return value
    }()

    init(preferences: AgentGitPreferences) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git"; window.minSize = NSSize(width: 480, height: 340); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        prefix.setAccessibilityLabel("分支前缀"); prefix.placeholderString = "留空不加前缀"; prefix.delegate = self
        prefix.outlined = true; prefix.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let field = AgentSettingsStyle.labeledField("分支前缀", prefix)
        let branches = AgentSettingsStyle.section("工作树", id: "git-branches", rows: [field])

        instructions.setAccessibilityLabel("提交说明指令"); instructions.delegate = self
        instructions.isRichText = false; instructions.allowsUndo = true; instructions.isVerticallyResizable = true
        instructions.autoresizingMask = [.width]; instructions.textContainer?.widthTracksTextView = true
        instructions.font = .systemFont(ofSize: 13); instructions.textContainerInset = NSSize(width: 8, height: 9)
        instructions.isAutomaticQuoteSubstitutionEnabled = false; instructions.isAutomaticTextReplacementEnabled = false
        let editor = NSScrollView(); editor.documentView = instructions; editor.hasVerticalScroller = true
        editor.scrollerStyle = .overlay; editor.identifier = .init("form-input")
        editor.heightAnchor.constraint(equalToConstant: 132).isActive = true
        let message = AgentSettingsStyle.section("提交说明指令", id: "git-commit-instructions", rows: [editor])

        save.target = self; save.action = #selector(saveValues)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; AgentSettingsStyle.primaryAction(save)
        let actions = AgentSettingsDetailActions([save]); detailActionRow = actions
        let content = AgentThemeView(), column = NSStackView(views: [branches, message, status, actions])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 14
        window.contentView = content; content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 4), column.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12)
        ])
        do { load(try preferences.read()); status.stringValue = "" }
        catch { showFailure(error); prefix.isEnabled = false; instructions.isEditable = false; save.isEnabled = false }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var values: AgentGitPreferences.Values {
        .init(branchPrefix: (prefix.currentEditor() as? NSTextView)?.string ?? prefix.stringValue, commitInstructions: instructions.string)
    }
    private var dirty: Bool { saved.map { values != $0.values } == true }

    private func load(_ snapshot: AgentGitPreferences.Snapshot) {
        saved = snapshot; prefix.isEnabled = true; instructions.isEditable = true
        prefix.stringValue = snapshot.values.branchPrefix; instructions.string = snapshot.values.commitInstructions
        save.isEnabled = false
    }
    private func showFailure(_ error: Error) { status.stringValue = error.localizedDescription; status.textColor = AgentDialogStyle.error }
    private func changed() { save.isEnabled = dirty; status.stringValue = dirty ? "未保存" : ""; viewport.changed() }
    func controlTextDidChange(_ notification: Notification) { changed() }
    func textDidChange(_ notification: Notification) { changed() }
    override func settingsDidAppear() { super.settingsDidAppear(); viewport.appear(default: prefix) }
    override func pageDidLayout() { viewport.schedule() }

    @objc private func saveValues() {
        guard let saved, dirty else { return }
        do {
            self.saved = try preferences.save(values, replacing: saved.revision)
            save.isEnabled = false; status.stringValue = "已保存"; onSettingsRecoveryChange?()
        } catch { showFailure(error) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !dirty || AgentUnsavedChanges.discard("放弃未保存的 Git 设置？", discardTitle: "放弃修改", owner: presentingWindow)
    }

    private struct Recovery: Codable {
        var version = 1
        var base: AgentGitPreferences.Values
        var revision: String?
        var draft: AgentGitPreferences.Values
        var viewport: AgentSettingsDraftViewport.State
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        guard let saved, dirty else { return nil }
        prefix.validateEditing()
        let draft = values
        guard Self.validDraft(draft) else { return nil }
        return try AgentSettingsRecovery.page("git", Recovery(base: saved.values, revision: saved.revision, draft: draft, viewport: viewport.capture()))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "base", "revision", "draft", "viewport"])
        for key in ["base", "draft"] { _ = try AgentSettingsRecovery.object(raw[key] ?? NSNull(), keys: ["branchPrefix", "commitInstructions"]) }
        if let value = raw["viewport"] { try AgentSettingsDraftViewport.validateObject(value) }
        let recovery = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard page.kind == "git", recovery.version == 1, AgentSettingsRecovery.validHash(recovery.revision), Self.validDraft(recovery.draft) else {
            throw PetError("Git 设置恢复格式无效，原记录已保留")
        }
        try AgentGitPreferences.validate(recovery.base)
        try viewport.validate(recovery.viewport, text: recovery.draft.commitInstructions, fields: ["prefix": recovery.draft.branchPrefix])
        load(.init(values: recovery.base, revision: recovery.revision)); prefix.stringValue = recovery.draft.branchPrefix
        instructions.string = recovery.draft.commitInstructions; try viewport.restore(recovery.viewport)
        save.isEnabled = dirty; status.stringValue = dirty ? "未保存" : ""
    }
    private static func validDraft(_ value: AgentGitPreferences.Values) -> Bool {
        value.branchPrefix.utf8.count <= 65_536 && value.commitInstructions.utf8.count <= 65_536 &&
            !value.branchPrefix.contains("\0") && !value.commitInstructions.contains("\0")
    }
}
