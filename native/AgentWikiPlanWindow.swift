import AppKit

@MainActor final class AgentWikiPlanWindow: AgentSettingsPageController, NSWindowDelegate, NSTextViewDelegate {
    private let store: AgentStore, taskID: String, root: String, editor = AgentMarkdownTextView(), status = NSTextField(labelWithString: ""), save = NSButton(title: "保存", target: nil, action: nil)
    private var snapshot: AgentWikiPlan.Snapshot, dirty = false
    private var pendingViewport: AgentTextViewport?, applyingRecovery = false, viewportScheduled = false, rememberedFocus = false, closed = false
    private(set) var needsHostedPresentation = false
    var onWorkspaceChange: (() -> Void)?, onClose: (() -> Void)?
    var hasUnsavedChanges: Bool { dirty }
    var hasIndependentWindow: Bool { !closed && (window?.isVisible == true || restoredFrame != nil) && !needsHostedPresentation && settingsHostWindow == nil }
    var canPreserveForQuit: Bool { !closed && store.task(taskID).map { $0.sideTask?.retained != false } == true }
    private var restoredFrame: AgentWorkspaceRecovery.Frame?
    init(store: AgentStore, taskID: String, restoring value: RecoveryState? = nil) throws {
        self.store = store; self.taskID = taskID
        guard let task = store.task(taskID) else { throw PetError("规划所属任务不存在") }
        if let value {
            guard value.valid, value.taskID == taskID else { throw PetError("Wiki 规划恢复范围无效，原草稿已保留") }
            root = value.root
            snapshot = .init(plan: .init(), text: value.source, path: value.path, hash: value.hash, targetSignature: value.targetSignature, format: .init(encoding: AgentTextEncoding(rawValue: value.encoding)!, bom: value.bom), problem: value.problem)
        } else {
            let files = try AgentFiles(workspace: task.workspace); root = files.root.path; snapshot = try AgentWikiPlan.load(files: files, validate: false)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 570), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Wiki 生成规划"; window.minSize = NSSize(width: 500, height: 360); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        editor.string = value?.draft ?? snapshot.text; editor.isRichText = false; editor.isEditable = canWrite(); editor.isSelectable = true; editor.allowsUndo = true; editor.previewUndoManager = UndoManager(); editor.delegate = self
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 14, height: 12); editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.setAccessibilityLabel("Wiki 规划 YAML")
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        editor.drawsBackground = false; editor.textColor = .labelColor; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        let reload = NSButton(title: "重新载入", target: self, action: #selector(reload)), close = NSButton(title: "关闭", target: self, action: #selector(closePlan))
        save.target = self; save.action = #selector(savePlan); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; save.isEnabled = canWrite()
        status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText; status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [status, NSView(), reload, close, save]); actions.spacing = 8
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        for child in [scroll, actions] { content.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12), actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
        status.stringValue = snapshot.problem ?? snapshot.path ?? AgentWikiPlan.configurationPath
        if let value {
            dirty = value.dirty; pendingViewport = value.viewport; rememberedFocus = value.viewport?.focused == true
            needsHostedPresentation = value.presentation == "page"; restoredFrame = value.frame
            status.stringValue = value.status
            if !originalScopeMatches { status.stringValue = "原项目暂不可用或范围已变化，规划草稿只读保留" }
            else if !canWrite() { status.stringValue = "已恢复规划草稿，当前项目只读" }
            else if (try? AgentWikiPlan.load(files: AgentFiles(workspace: root), validate: false)).map({ $0.path != snapshot.path || $0.hash != snapshot.hash || $0.targetSignature != snapshot.targetSignature }) == true { status.stringValue = "规划来源已变化，草稿已保留；重新载入后再保存" }
        }
        status.toolTip = root
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var originalScopeMatches: Bool { store.task(taskID).flatMap { try? AgentFiles(workspace: $0.workspace).root.path } == root }
    private func canWrite() -> Bool {
        guard originalScopeMatches, let task = store.task(taskID), !task.archived, task.kind != "hook", (try? store.agents.limits(task, store: store).readOnly) == false else { return false }
        let target = URL(fileURLWithPath: root).appendingPathComponent(AgentWikiPlan.configurationPath).path
        return FileManager.default.isWritableFile(atPath: FileManager.default.fileExists(atPath: target) ? target : root)
    }
    func textDidChange(_ notification: Notification) { guard !applyingRecovery else { return }; pendingViewport = nil; dirty = editor.string != snapshot.text; status.stringValue = dirty ? "未保存" : snapshot.path ?? AgentWikiPlan.configurationPath; onWorkspaceChange?() }
    func textViewDidChangeSelection(_ notification: Notification) { guard !applyingRecovery else { return }; if presentingWindow?.firstResponder === editor { rememberedFocus = true }; onWorkspaceChange?() }
    @objc private func viewportChanged(_ notification: Notification) { if !applyingRecovery { onWorkspaceChange?() } }
    @objc private func savePlan() {
        do {
            guard canWrite() else { throw PetError("此项目当前只读，规划草稿已保留") }
            let files = try AgentFiles(workspace: root)
            _ = try AgentWikiPlan.parse(editor.string)
            let current = try AgentWikiPlan.load(files: files, validate: false)
            guard current.path == snapshot.path, current.hash == snapshot.hash, current.targetSignature == snapshot.targetSignature else { throw PetError("规划文件已在外部变化，草稿已保留；请先重新载入核对") }
            let target = try files.literalURL(AgentWikiPlan.configurationPath), data = try snapshot.format.encode(editor.string)
            if let path = snapshot.path, let expected = snapshot.hash {
                let original = try files.readData(files.literalURL(path), maximum: 128_000); guard AgentFiles.hash(original) == expected else { throw PetError("规划来源已变化，草稿已保留") }
                let index = try AgentProjectIndex(workspace: files.root.path, storage: store.directory), backups = index.directory.appendingPathComponent("wiki-plan-backups"); try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try AgentFiles(workspace: backups.path).writeData(original, to: backups.appendingPathComponent(UUID().uuidString + ".yaml"), permissions: 0o600)
            }
            guard canWrite() else { throw PetError("项目权限已变化，草稿已保留") }
            try files.writeData(data, to: target, expectedTarget: snapshot.targetSignature)
            snapshot = try AgentWikiPlan.load(files: files); dirty = false; status.stringValue = "已保存"
        } catch { status.stringValue = error.localizedDescription }
        onWorkspaceChange?()
    }
    private func canLeave() -> Bool {
        guard dirty else { return true }
        guard AgentUnsavedChanges.discard("放弃未保存的规划？") else { return false }
        editor.string = snapshot.text; pendingViewport = nil; editor.undoManager?.removeAllActions(); dirty = false; onWorkspaceChange?(); return true
    }
    @objc private func reload() {
        guard canLeave() else { return }
        do { guard originalScopeMatches else { throw PetError("原项目暂不可用或范围已变化") }; snapshot = try AgentWikiPlan.load(files: AgentFiles(workspace: root), validate: false); editor.string = snapshot.text; editor.undoManager?.removeAllActions(); dirty = false; status.stringValue = snapshot.problem ?? snapshot.path ?? AgentWikiPlan.configurationPath }
        catch { status.stringValue = error.localizedDescription }
        onWorkspaceChange?()
    }
    @objc private func closePlan() { if onSettingsClose != nil { close() } else { window?.performClose(nil) } }
    func confirmClosing() -> Bool { canLeave() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeave() }
    func prepareWorkspaceNavigation() -> Bool { presentingWindow?.hasBlockingDialog != true }
    struct RecoveryState: Codable {
        var version = 1
        var taskID: String, root: String, source: String, draft: String, targetSignature: String, encoding: String, status: String
        var path: String?, hash: String?, problem: String?
        var bom: Bool, dirty: Bool, viewport: AgentTextViewport?, presentation: String, frame: AgentWorkspaceRecovery.Frame?
        var valid: Bool {
            guard version == 1, UUID(uuidString: taskID) != nil, root.hasPrefix("/"), !root.contains("\0"), root.utf8.count <= 8192, URL(fileURLWithPath: root).standardizedFileURL.path == root,
                  let encoding = AgentTextEncoding(rawValue: encoding), source.utf8.count <= 512_000, draft.utf8.count <= 20_000_000,
                  dirty == (draft != source), ["page", "window"].contains(presentation), frame?.valid != false, presentation == "window" || frame == nil,
                  targetSignature.utf8.count <= 4096, !targetSignature.contains("\0"), status.utf8.count <= 100_000, (problem?.utf8.count ?? 0) <= 100_000,
                  viewport?.valid != false, viewport.map({ $0.hash == AgentFiles.hash(Data(draft.utf8)) && $0.count == (draft as NSString).length }) ?? true else { return false }
            if let path {
                guard let data = try? AgentTextFormat(encoding: encoding, bom: bom).encode(source), data.count <= 128_000 else { return false }
                return [AgentWikiPlan.configurationPath, AgentWikiPlan.compatiblePath].contains(path) && hash == AgentFiles.hash(data)
            }
            return hash == nil && source == AgentWikiPlan.initialYAML && encoding == .utf8 && !bom
        }
        static func validateObject(_ raw: Any) throws {
            guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["version", "taskID", "root", "source", "draft", "targetSignature", "encoding", "status", "path", "hash", "problem", "bom", "dirty", "viewport", "presentation", "frame"]) else { throw PetError("Wiki 规划恢复格式不受支持，原记录已保留") }
            if let viewport = value["viewport"], !(viewport is NSNull) { try AgentTextViewport.validateObject(viewport) }
            if let frame = value["frame"], !(frame is NSNull) { guard let frame = frame as? [String: Any], Set(frame.keys).isSubset(of: ["x", "y", "width", "height"]) else { throw PetError("规划窗口恢复位置无效") } }
        }
    }
    func captureWorkspaceRecovery() throws -> RecoveryState? {
        guard !closed, needsHostedPresentation || settingsHostWindow != nil || isPageVisible || window?.isVisible == true else { return nil }
        guard prepareWorkspaceNavigation() else { throw PetError("请先完成当前规划操作") }
        var viewport = try pendingViewport ?? AgentTextViewport(editor); viewport.focused = viewport.focused || rememberedFocus
        let presentation = needsHostedPresentation || settingsHostWindow != nil ? "page" : "window"
        let value = RecoveryState(taskID: taskID, root: root, source: snapshot.text, draft: editor.string, targetSignature: snapshot.targetSignature, encoding: snapshot.format.encoding.rawValue, status: status.stringValue,
            path: snapshot.path, hash: snapshot.hash, problem: snapshot.problem, bom: snapshot.format.bom, dirty: dirty, viewport: viewport, presentation: presentation, frame: presentation == "window" ? window.map(AgentWorkspaceRecovery.Frame.init) : nil)
        guard value.valid else { throw PetError("Wiki 规划草稿或位置无效，原记录已保留") }; return value
    }
    private func scheduleViewport() {
        guard !closed, !viewportScheduled, !applyingRecovery, pendingViewport != nil else { return }; viewportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { viewportScheduled = false }
            guard isPageVisible, let value = pendingViewport else { return }
            applyingRecovery = true; presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            if value.apply(to: editor) { pendingViewport = nil }; applyingRecovery = false
        }
    }
    override func settingsDidAppear() { needsHostedPresentation = false; super.settingsDidAppear(); scheduleViewport() }
    override func pageDidLayout() { scheduleViewport() }
    func windowDidBecomeKey(_ notification: Notification) { scheduleViewport() }
    func windowDidMove(_ notification: Notification) { onWorkspaceChange?() }
    func windowDidResize(_ notification: Notification) { scheduleViewport(); onWorkspaceChange?() }
    func windowWillClose(_ notification: Notification) { finishClose() }
    func presentRecoveredWindow() { guard !needsHostedPresentation else { return }; restoredFrame?.apply(to: window); restoredFrame = nil; showWindow(nil); window?.makeKeyAndOrderFront(nil); scheduleViewport() }
    private func finishClose() { guard !closed else { return }; closed = true; NotificationCenter.default.removeObserver(self); onClose?(); onClose = nil; onWorkspaceChange?() }
    override func close() { if settingsHostWindow == nil { finishClose() }; super.close() }
    override func settingsWillLeave() { finishClose() }
    var checkState: [String: Any] { guard CommandLine.arguments.contains("--wiki-plan-check") || AgentKnowledgePageHost.readbackEnabled else { return [:] }; return ["draft": editor.string, "dirty": dirty, "state": status.stringValue, "source": snapshot.path ?? "", "openedHash": snapshot.hash ?? "", "editable": editor.isEditable, "saveEnabled": save.isEnabled] }
    func checkEdit(_ value: String, save: Bool = true) {
        guard CommandLine.arguments.contains("--knowledge-page-check") else { return }
        editor.string = value; textDidChange(Notification(name: NSText.didChangeNotification, object: editor)); if save { savePlan() }
    }
    func checkRecovery(action: String = "", text: String? = nil, selection: NSRange? = nil, y: CGFloat? = nil) throws {
        guard ["--knowledge-editor-recovery-check", "--knowledge-editor-recovery-ui"].contains(where: CommandLine.arguments.contains) else { throw PetError("仅用于规划恢复验收") }
        if let text { editor.string = text; textDidChange(Notification(name: NSText.didChangeNotification, object: editor)) }
        if let selection { presentingWindow?.makeFirstResponder(editor); editor.setSelectedRange(selection) }
        if let y, let scroll = editor.enclosingScrollView { editor.layoutManager?.ensureLayout(for: editor.textContainer!); editor.setFrameSize(NSSize(width: editor.frame.width, height: max(editor.frame.height, (editor.layoutManager?.usedRect(for: editor.textContainer!).maxY ?? 0) + 24))); scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
        if action == "save" { savePlan() } else if action == "reload" { reload() } else if action == "close" { closePlan() }
    }
}
