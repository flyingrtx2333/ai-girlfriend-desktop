import AppKit

@MainActor final class AgentWikiPlanWindow: AgentSettingsPageController, NSWindowDelegate, NSTextViewDelegate {
    private let files: AgentFiles, storage: URL, editor = AgentMarkdownTextView(), status = NSTextField(labelWithString: ""), save = NSButton(title: "保存", target: nil, action: nil)
    private var snapshot: AgentWikiPlan.Snapshot, dirty = false
    private let canWrite: () -> Bool
    var hasUnsavedChanges: Bool { dirty }
    init(workspace: String, storage: URL, canWrite: @escaping () -> Bool) throws {
        files = try AgentFiles(workspace: workspace); self.storage = storage; self.canWrite = canWrite; snapshot = try AgentWikiPlan.load(files: files, validate: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 570), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Wiki 生成规划"; window.minSize = NSSize(width: 500, height: 360); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        editor.string = snapshot.text; editor.isRichText = false; editor.isEditable = canWrite(); editor.isSelectable = true; editor.allowsUndo = true; editor.previewUndoManager = UndoManager(); editor.delegate = self
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 14, height: 12); editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.setAccessibilityLabel("Wiki 规划 YAML")
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true
        editor.drawsBackground = false; editor.textColor = .labelColor; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        let reload = NSButton(title: "重新载入", target: self, action: #selector(reload)), close = NSButton(title: "关闭", target: self, action: #selector(closePlan))
        save.target = self; save.action = #selector(savePlan); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; save.isEnabled = canWrite()
        status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText; status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [status, NSView(), reload, close, save]); actions.spacing = 8
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        for child in [scroll, actions] { content.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12), actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        status.stringValue = snapshot.problem ?? snapshot.path ?? AgentWikiPlan.configurationPath
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func textDidChange(_ notification: Notification) { dirty = editor.string != snapshot.text; status.stringValue = dirty ? "未保存" : snapshot.path ?? AgentWikiPlan.configurationPath }
    @objc private func savePlan() {
        do {
            guard canWrite() else { throw PetError("此项目当前只读，规划草稿已保留") }
            _ = try AgentWikiPlan.parse(editor.string)
            let current = try AgentWikiPlan.load(files: files, validate: false)
            guard current.path == snapshot.path, current.hash == snapshot.hash, current.targetSignature == snapshot.targetSignature else { throw PetError("规划文件已在外部变化，草稿已保留；请先重新载入核对") }
            let target = try files.literalURL(AgentWikiPlan.configurationPath), data = try snapshot.format.encode(editor.string)
            if let path = snapshot.path, let expected = snapshot.hash {
                let original = try files.readData(files.literalURL(path), maximum: 128_000); guard AgentFiles.hash(original) == expected else { throw PetError("规划来源已变化，草稿已保留") }
                let index = try AgentProjectIndex(workspace: files.root.path, storage: storage), backups = index.directory.appendingPathComponent("wiki-plan-backups"); try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try AgentFiles(workspace: backups.path).writeData(original, to: backups.appendingPathComponent(UUID().uuidString + ".yaml"), permissions: 0o600)
            }
            guard canWrite() else { throw PetError("项目权限已变化，草稿已保留") }
            try files.writeData(data, to: target, expectedTarget: snapshot.targetSignature)
            snapshot = try AgentWikiPlan.load(files: files); dirty = false; status.stringValue = "已保存"
        } catch { status.stringValue = error.localizedDescription }
    }
    private func canLeave() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存的规划？"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃更改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        editor.string = snapshot.text; dirty = false; return true
    }
    @objc private func reload() {
        guard canLeave() else { return }
        do { snapshot = try AgentWikiPlan.load(files: files, validate: false); editor.string = snapshot.text; editor.undoManager?.removeAllActions(); dirty = false; status.stringValue = snapshot.problem ?? snapshot.path ?? AgentWikiPlan.configurationPath }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func closePlan() { if onSettingsClose != nil { close() } else { window?.performClose(nil) } }
    func confirmClosing() -> Bool { canLeave() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeave() }
    var checkState: [String: Any] { guard CommandLine.arguments.contains("--wiki-plan-check") || AgentKnowledgePageHost.readbackEnabled else { return [:] }; return ["draft": editor.string, "dirty": dirty, "state": status.stringValue, "source": snapshot.path ?? "", "openedHash": snapshot.hash ?? "", "editable": editor.isEditable, "saveEnabled": save.isEnabled] }
    func checkEdit(_ value: String, save: Bool = true) {
        guard CommandLine.arguments.contains("--knowledge-page-check") else { return }
        editor.string = value; textDidChange(Notification(name: NSText.didChangeNotification, object: editor)); if save { savePlan() }
    }
}
