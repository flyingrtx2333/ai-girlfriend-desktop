import AppKit

@MainActor final class AgentKnowledgeSourcePage: AgentSettingsPageController, NSWindowDelegate {
    struct RecoveryState: Codable, Equatable {
        var version = 1
        var taskID: String, root: String, path: String, hash: String
        var offset: Int, limit: Int, maximum: Int
        var citationHash: String?, line: Int?
        var presentation = "page"
        var frame: AgentWorkspaceRecovery.Frame?
        var viewport: AgentTextViewport?
        var valid: Bool {
            version == 1 && UUID(uuidString: taskID) != nil && root.hasPrefix("/") && !root.contains("\0") &&
            URL(fileURLWithPath: root).standardizedFileURL.path == root && root.utf8.count <= 8192 &&
            !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 8192 && !path.contains("\0") &&
            !path.split(separator: "/").contains("..") && !AgentFiles.sensitive(path) &&
            Self.digest(hash) && (citationHash.map(Self.digest) ?? true) && (1...1_000_000).contains(offset) &&
            (1...500).contains(limit) && [512_000, 2_000_000].contains(maximum) &&
            (line.map { (1...1_000_000).contains($0) } ?? true) && ["page", "window"].contains(presentation) &&
            frame?.valid != false && viewport?.valid != false && (presentation == "window" || frame == nil)
        }
        private static func digest(_ text: String) -> Bool { text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
        static func validateObject(_ raw: Any) throws {
            guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["version", "taskID", "root", "path", "hash", "offset", "limit", "maximum", "citationHash", "line", "presentation", "frame", "viewport"]) else { throw PetError("知识来源恢复格式不受支持，原记录已保留") }
            if let raw = value["viewport"], !(raw is NSNull) { try AgentTextViewport.validateObject(raw) }
            if let raw = value["frame"], !(raw is NSNull) { guard let frame = raw as? [String: Any], Set(frame.keys).isSubset(of: ["x", "y", "width", "height"]) else { throw PetError("知识来源窗口恢复格式不受支持") }; _ = frame }
        }
    }
    private let store: AgentStore
    private var saved: RecoveryState, pending: AgentTextViewport?
    private let text = NSTextView(), scroll = NSScrollView(), status = AgentSettingsStatusField("知识来源状态")
    private let open = NSButton(title: "在外部打开", target: nil, action: nil), retry = NSButton(title: "刷新", target: nil, action: nil), latest = NSButton(title: "打开当前版本", target: nil, action: nil)
    private var loaded = false, applying = false, scheduled = false, closed = false, rememberedFocus = false
    var onWorkspaceChange: (() -> Void)?, onClose: (() -> Void)?
    var needsHostedPresentation: Bool { !closed && saved.presentation == "page" && settingsHostWindow == nil }
    var isClosed: Bool { closed }

    convenience init(store: AgentStore, taskID: String, file: URL, offset: Int = 1, limit: Int = 500, maximum: Int = 2_000_000, citationHash: String? = nil, line: Int? = nil) throws {
        guard let task = store.task(taskID) else { throw PetError("知识来源所属任务不存在") }
        let files = try AgentFiles(workspace: task.workspace), safe = try files.resolve(file.path)
        let value = RecoveryState(taskID: taskID, root: files.root.path, path: files.relative(safe), hash: try files.fileHash(safe, maximum: maximum), offset: offset, limit: min(500, max(1, limit)), maximum: maximum, citationHash: citationHash, line: line)
        _ = try Self.read(value, store: store)
        try self.init(store: store, restoring: value)
    }
    init(store: AgentStore, restoring value: RecoveryState) throws {
        guard value.valid else { throw PetError("知识来源所属文件或位置无效，原记录已保留") }
        self.store = store; saved = value; pending = value.viewport; rememberedFocus = value.viewport?.focused ?? false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = value.path + (value.line.map { ":\($0)" } ?? ""); window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 500, height: 350); value.frame?.apply(to: window)
        super.init(window: window); window.delegate = self
        let content = AgentWorkspacePageView(); content.fill = AgentWorkbenchTheme.surface; content.onResize = { [weak self] in self?.pageDidLayout() }
        text.isEditable = false; text.isRichText = false; text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 12, height: 12)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.textColor = .labelColor; text.drawsBackground = false; text.setAccessibilityLabel("知识来源正文")
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; scroll.contentView.postsBoundsChangedNotifications = true
        for (button, action) in [(open, #selector(openFile)), (retry, #selector(refresh)), (latest, #selector(openLatest))] { button.target = self; button.action = action }
        let actions = NSStackView(views: [status, NSView(), retry, latest, open]), column = NSStackView(views: [scroll, actions]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        window.contentView = content; content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for child in [scroll, actions] { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor), column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: text)
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        restoreSource()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private static func read(_ value: RecoveryState, store: AgentStore) throws -> (String, String, URL) {
        guard value.valid, let task = store.task(value.taskID) else { throw PetError("知识来源所属任务不可用") }
        let files = try AgentFiles(workspace: task.workspace)
        guard files.root.path == value.root else { throw PetError("知识来源所属工作区已变化，原阅读记录已保留") }
        let file = try files.resolve(value.path)
        guard !AgentFiles.sensitive(files.relative(file)), try AgentProjectIndex(workspace: value.root, storage: store.directory).contains(value.path) else { throw PetError("来源不在当前项目索引中，原阅读记录已保留") }
        let hash = try files.fileHash(file, maximum: value.maximum), body = try files.read(file.path, offset: value.offset, limit: value.limit)
        guard hash == (try files.fileHash(file, maximum: value.maximum)) else { throw PetError("读取期间来源已变化，请重试") }
        return (body, hash, file)
    }
    private func restoreSource(adopting: Bool = false) {
        applying = true; defer { applying = false; scheduleViewport(); onWorkspaceChange?() }
        do {
            if loaded {
                var viewport = try pending ?? AgentTextViewport(text); viewport.focused = rememberedFocus
                saved.viewport = viewport; pending = viewport
            }
            let (body, hash, _) = try Self.read(saved, store: store)
            guard adopting || hash == saved.hash else { throw PetError("来源已变化，原阅读位置已保留") }
            text.string = body
            if adopting { saved.hash = hash; saved.viewport = nil; pending = nil; rememberedFocus = false; text.setSelectedRange(NSRange(location: 0, length: 0)); text.scroll(NSPoint.zero) }
            if let pending { guard pending.matches(text) else { throw PetError("来源显示内容已变化，原阅读位置已保留") } }
            window?.title = (saved.citationHash.map { $0 != hash } == true ? "来源已变化 · " : "") + saved.path + (saved.line.map { ":\($0)" } ?? "")
            loaded = true; status.stringValue = ""; latest.isHidden = true; open.isEnabled = true
        } catch {
            loaded = false; text.string = ""; status.stringValue = error.localizedDescription; open.isEnabled = false; latest.isHidden = false
        }
    }
    func captureWorkspaceRecovery() throws -> RecoveryState? {
        guard !closed else { return nil }
        var value = saved
        if loaded {
            var viewport = try pending ?? AgentTextViewport(text); viewport.focused = rememberedFocus; value.viewport = viewport
        }
        value.presentation = settingsHostWindow == nil ? "window" : "page"
        value.frame = value.presentation == "window" ? window.map { AgentWorkspaceRecovery.Frame($0) } : nil
        guard value.valid else { throw PetError("知识来源位置无效，原记录已保留") }; return value
    }
    func presentRecoveredWindow() { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    override func settingsDidAppear() { super.settingsDidAppear(); scheduleViewport() }
    override func pageDidLayout() { scheduleViewport() }
    func windowDidBecomeKey(_ notification: Notification) { scheduleViewport() }
    func windowDidResize(_ notification: Notification) { scheduleViewport(); onWorkspaceChange?() }
    func windowDidMove(_ notification: Notification) { onWorkspaceChange?() }
    private func scheduleViewport() {
        guard !scheduled, !applying, loaded, pending != nil else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; defer { scheduled = false }
            guard !closed, loaded, isPageVisible, let value = pending else { return }
            applying = true; presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            if value.apply(to: text) { pending = nil; rememberedFocus = value.focused }
            applying = false; onWorkspaceChange?()
        }
    }
    @objc private func viewChanged(_ notification: Notification) { guard !applying, pending == nil else { return }; if presentingWindow?.firstResponder === text { rememberedFocus = true }; onWorkspaceChange?() }
    @objc private func refresh() { restoreSource() }
    @objc private func openLatest() { restoreSource(adopting: true) }
    @objc private func openFile() {
        do { guard loaded else { return }; let (_, hash, file) = try Self.read(saved, store: store); guard hash == saved.hash else { throw PetError("来源已变化，请先刷新核对") }; NSWorkspace.shared.open(file) }
        catch { status.stringValue = error.localizedDescription }
    }
    private func finish() { guard !closed else { return }; closed = true; NotificationCenter.default.removeObserver(self); onClose?(); onClose = nil; onWorkspaceChange?() }
    func windowWillClose(_ notification: Notification) { finish() }
    override func settingsWillLeave() { finish() }
    override func close() { if settingsHostWindow == nil { finish() }; super.close() }
    var checkState: [String: Any] {
        guard AgentKnowledgePageHost.readbackEnabled else { return [:] }
        return ["taskID": saved.taskID, "root": saved.root, "path": saved.path, "hash": saved.hash, "text": text.string, "loaded": loaded, "editable": text.isEditable, "status": status.stringValue, "closed": closed, "title": window?.title ?? ""]
    }
    func checkView(target: String = "", y: Double? = nil, action: String = "") throws {
        guard ["--knowledge-reader-recovery-check", "--knowledge-reader-recovery-ui"].contains(where: CommandLine.arguments.contains) else { return }
        if action == "retry" { refresh() }; if action == "latest" { openLatest() }
        if !target.isEmpty { let range = (text.string as NSString).range(of: target); guard range.location != NSNotFound else { throw PetError("知识来源选文不存在") }; text.setSelectedRange(range); presentingWindow?.makeFirstResponder(text); rememberedFocus = true }
        if let y { text.scroll(NSPoint(x: 0, y: y)) }; onWorkspaceChange?()
    }
}
