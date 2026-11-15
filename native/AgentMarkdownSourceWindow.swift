import AppKit

// Source citations stay inside a read-only native viewer. Opening a document
// never grants a new workspace or executes a URL scheme from its contents.
@MainActor final class AgentMarkdownSourceWindow: AgentSettingsPageController, NSTextViewDelegate, NSWindowDelegate {
    private let sourceRoot: String, reader = AgentMarkdownReader(), text = AgentMarkdownTextView(), label = NSTextField(labelWithString: "")
    private let sourceAdd = NSButton(title: "加入任务", target: nil, action: nil)
    private lazy var sourceSelection = AgentMarkdownSelectionAction(text: text, button: sourceAdd) { [weak self] in guard let self, !self.scroll.isHidden, let file = self.file else { return nil }; return (file, self.sourceRoot) }
    var onAddSelection: ((AgentMarkdownSelection) throws -> Void)? { didSet { reader.onAddSelection = onAddSelection; sourceSelection.onAdd = onAddSelection; switchMode() } }
    var canAddSelection: (() -> Bool)? { didSet { reader.canAddSelection = canAddSelection; sourceSelection.canAdd = canAddSelection } }
    private let back = NSButton(title: "返回", target: nil, action: nil), reload = NSButton(title: "刷新", target: nil, action: nil), mode = NSSegmentedControl(labels: ["预览", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private var history: [URL] = [], file: URL?
    private var videoWindow: AgentVideoWindow?
    private let encodingMenu = NSPopUpButton()
    private var encodings: [String: AgentTextEncoding] = [:], requestedEncoding: AgentTextEncoding?, currentFormat: AgentTextFormat?
    private var sourceHash: String?, pendingRecovery: RecoveryState?, pendingVideo: AgentVideoWindow.RecoveryState?
    private var pendingRaw: AgentTextViewport?, applyingView = false, viewScheduled = false, rawFocused = false, rawFocusRequested = false
    private var pendingPage = false, presentingVideo = false
    private let validateScope: (() throws -> Void)?
    private let latest = NSButton(title: "打开当前版本", target: nil, action: nil)
    private(set) var workspaceIsClosed = false
    var onWorkspaceChange: (() -> Void)?, onClose: (() -> Void)?
    var hasIndependentWindow: Bool { !workspaceIsClosed && !pendingPage && settingsHostWindow == nil }
    var hasIndependentVideoWindow: Bool { videoWindow?.hasIndependentWindow == true || pendingVideo != nil && hasIndependentWindow }
    var hasVideoPlayback: Bool { !workspaceIsClosed && (videoWindow != nil || pendingVideo != nil) }
    convenience init(workspace: String, target: URL, validate: (() throws -> Void)? = nil) throws {
        try self.init(workspace: workspace, target: target, restoring: nil, validate: validate)
    }
    convenience init(restoring value: RecoveryState, validate: @escaping () throws -> Void) throws {
        guard value.valid, let target = URL(string: value.target) else { throw PetError("来源阅读记录无效，原记录已保留") }
        try self.init(workspace: value.root, target: target, restoring: value, validate: validate)
    }
    private init(workspace: String, target: URL, restoring value: RecoveryState?, validate: (() throws -> Void)?) throws {
        sourceRoot = try value?.root ?? AgentFiles(workspace: workspace).root.path
        validateScope = validate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "来源"; window.minSize = NSSize(width: 500, height: 350); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let view = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface); window.contentView = view
        view.onResize = { [weak self] in self?.pageDidLayout() }
        text.isEditable = false; text.isRichText = false; text.delegate = self; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.textContainerInset = NSSize(width: 16, height: 14); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel("来源原文")
        scroll.documentView = text; scroll.hasVerticalScroller = true
        text.drawsBackground = false; text.textColor = .labelColor; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        back.target = self; back.action = #selector(goBack); back.setAccessibilityLabel("上一处来源")
        mode.target = self; mode.action = #selector(switchMode(_:)); mode.selectedSegment = 0; mode.setAccessibilityLabel("来源显示方式")
        reload.target = self; reload.action = #selector(refreshFile)
        latest.target = self; latest.action = #selector(openLatest); latest.isHidden = true
        AgentTextEncoding.prepareMenu(encodingMenu); encodingMenu.target = self; encodingMenu.action = #selector(reopenEncoding)
        reader.onLink = { [weak self] url in self?.follow(url) }
        reader.onViewportChange = { [weak self] in self?.changed() }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rawViewChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] { NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)), name: name, object: window) }
        let location = NSStackView(views: [back, label, NSView(), latest, reload]), actions = NSStackView(views: [mode, NSView(), sourceAdd])
        let toolbar = NSStackView(views: [location, actions]); toolbar.orientation = .vertical; toolbar.alignment = .leading; toolbar.spacing = 8
        for row in [location, actions] { row.spacing = 8; row.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true }; sourceSelection.update()
        for child in [toolbar, scroll, reader, encodingMenu] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), encodingMenu.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), encodingMenu.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: encodingMenu.topAnchor, constant: -8), reader.topAnchor.constraint(equalTo: scroll.topAnchor), reader.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), reader.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), reader.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)])
        if let value {
            pendingRecovery = value; pendingPage = value.presentation == "page"; pendingVideo = value.video
            value.frame?.apply(to: window); restoreSource()
        } else { try open(target) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func open(_ target: URL, remember: Bool = true, encoding: AgentTextEncoding? = nil, restoring: Bool = false, expectedHash: String? = nil) throws {
        let files = try currentFiles()
        let safe = try AgentMarkdownDocument.target(target, document: file ?? files.root.appendingPathComponent("index.md"), files: files)
        guard safe.isFileURL else { throw PetError("请选择项目文件") }
        let data = try files.readData(try files.resolve(safe.path))
        let hash = AgentFiles.hash(data)
        if let expectedHash, hash != expectedHash { throw PetError("来源正文已变化，原阅读位置已保留") }
        let document: AgentTextFile
        do { document = try AgentTextFile.decode(data, encoding: encoding ?? encodings[safe.path]) }
        catch {
            if restoring { throw error }
            guard AgentTextEncoding.canReopen(safe) else { throw PetError("此文件不能作为文本预览") }
            if remember, let file { history.append(file) }; file = safe; requestedEncoding = encodings[safe.path]; currentFormat = nil
            sourceHash = hash; pendingRaw = nil; rawFocused = false
            text.string = ""; reader.clear(); mode.isHidden = true; window?.title = relative(safe); label.stringValue = error.localizedDescription; label.toolTip = safe.path; back.isEnabled = !history.isEmpty
            AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: nil); switchMode(); return
        }
        if remember, let file { history.append(file) }; file = safe; requestedEncoding = encodings[safe.path]
        sourceHash = hash; showDocument(document, file: safe, reveal: !restoring)
    }
    private func showDocument(_ document: AgentTextFile, file safe: URL, reveal: Bool = true) {
        pendingRaw = nil; rawFocused = false
        let value = document.text; currentFormat = document.format; text.string = value
        AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: currentFormat)
        let fragment = AgentMarkdownDocument.fragment(safe)
        window?.title = relative(safe); label.stringValue = relative(safe) + (fragment.map { " · " + $0 } ?? ""); label.toolTip = safe.path
        back.isEnabled = !history.isEmpty; mode.isHidden = !["md", "markdown"].contains(safe.pathExtension.lowercased()); mode.selectedSegment = 0
        if mode.isHidden { reader.clear() } else { reader.show(value, file: safe, workspace: sourceRoot) }; switchMode()
        if reveal, let range = AgentMarkdownDocument.lineRange(fragment, in: value) {
            mode.selectedSegment = 1; switchMode()
            DispatchQueue.main.async { [weak self] in guard let self, self.file == safe, self.text.string == value else { return }; self.text.setSelectedRange(range); AgentMarkdownDocument.reveal(range, in: self.text) }
        }
        else if reveal, !mode.isHidden { _ = reader.navigate(fragment) }
    }
    @objc private func reopenEncoding() {
        guard let file else { return }; let chosen = AgentTextEncoding.selection(encodingMenu)
        do {
            let files = try currentFiles()
            let safe = try files.resolve(file.path); guard safe.path == file.path else { throw PetError("文件位置已变化") }
            let data = try files.readData(safe), document = try AgentTextFile.decode(data, encoding: chosen)
            encodings[file.path] = chosen; requestedEncoding = chosen; sourceHash = AgentFiles.hash(data)
            pendingRecovery = nil; latest.isHidden = true; showDocument(document, file: file); changed()
        } catch { label.stringValue = error.localizedDescription; AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: currentFormat) }
    }
    private func follow(_ url: URL) {
        do {
            if ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            else if AgentVideoSnapshot.supports(url) {
                let files = try currentFiles()
                let target = try AgentMarkdownDocument.target(url, document: file ?? files.root.appendingPathComponent("index.md"), files: files)
                let next = AgentVideoWindow(file: target, files: files) { [weak self] in guard let self else { throw PetError("来源窗口已关闭") }; _ = try currentFiles() }
                retainVideo(next); presentSettingsChild(next); changed()
            } else { try open(url); pendingRecovery = nil; latest.isHidden = true; changed() }
        }
        catch { label.stringValue = error.localizedDescription }
    }
    @objc private func switchMode(_ sender: Any? = nil) {
        if presentingWindow?.firstResponder === text { rawFocused = true }; reader.rememberViewportFocus()
        let preview = !mode.isHidden && mode.selectedSegment == 0; reader.isHidden = !preview; scroll.isHidden = preview; sourceSelection.update(); sourceAdd.isHidden = preview || onAddSelection == nil
        if preview { reader.activateRememberedView(force: sender != nil) }
        scheduleRaw(force: sender != nil && !preview); changed()
    }
    func textViewDidChangeSelection(_ notification: Notification) { sourceSelection.update(); sourceAdd.isHidden = scroll.isHidden || onAddSelection == nil; rawViewChanged(notification) }
    func windowWillClose(_ notification: Notification) { finishClose() }
    @objc private func refreshFile() {
        if pendingRecovery != nil { restoreSource(); changed(); return }
        guard let file else { return }; do { try open(file, remember: false); changed() } catch { label.stringValue = error.localizedDescription }
    }
    @objc private func openLatest() {
        guard let pendingRecovery, let target = URL(string: pendingRecovery.target) else { return }
        do { try open(target, remember: false); self.pendingRecovery = nil; latest.isHidden = true; changed() } catch { label.stringValue = error.localizedDescription }
    }
    var encodingCheckState: [String: Any] {
        guard CommandLine.arguments.contains("--text-encoding-check") || AgentKnowledgePageHost.readbackEnabled || AgentTaskWorkspace.readbackEnabled else { return [:] }
        return ["editable": text.isEditable, "encoding": currentFormat?.encoding.rawValue ?? "", "byteOrderMark": currentFormat?.bom ?? false, "textHash": AgentFiles.hash(Data(text.string.utf8)), "file": file?.path ?? ""]
    }
    func checkVideoLink(_ url: URL) { if CommandLine.arguments.contains("--knowledge-video-check") { follow(url) } }
    @objc private func goBack() {
        guard let previous = history.popLast() else { return }
        do { try open(previous, remember: false); pendingRecovery = nil; latest.isHidden = true }
        catch { history.append(previous); label.stringValue = error.localizedDescription }
        changed()
    }
    struct RecoveryState: Codable, Equatable, Sendable {
        var version = 1
        var root: String, target: String, hash: String
        var history: [String], encodings: [String: String]
        var encoding: String?, mode: Int, presentation: String
        var frame: AgentWorkspaceRecovery.Frame?
        var raw: AgentTextViewport?, preview: AgentMarkdownReader.ViewRecovery?
        var video: AgentVideoWindow.RecoveryState?
        private func pathValid(_ path: String) -> Bool {
            path.hasPrefix("/") && path.utf8.count < 8192 && !path.contains("\0") && URL(fileURLWithPath: path).standardizedFileURL.path == path &&
                (root == "/" || path.hasPrefix(root + "/"))
        }
        private func targetValid(_ value: String) -> Bool {
            guard value.utf8.count < 8192, !value.contains("\0"), let url = URL(string: value), url.isFileURL,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.query == nil,
                  url.host == nil || url.host == "" || url.host == "localhost", pathValid(url.path) else { return false }
            let relative = root == "/" ? String(url.path.dropFirst()) : String(url.path.dropFirst(root.count + 1))
            return !AgentFiles.sensitive(relative)
        }
        var valid: Bool {
            version == 1 && root.hasPrefix("/") && root.utf8.count < 8192 && !root.contains("\0") && URL(fileURLWithPath: root).standardizedFileURL.path == root &&
                targetValid(target) && hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase } &&
                history.count <= 256 && history.allSatisfy(targetValid) && encodings.count <= 256 && encodings.allSatisfy({ pathValid($0.key) && AgentTextEncoding(rawValue: $0.value) != nil }) &&
                (encoding.map({ AgentTextEncoding(rawValue: $0) != nil }) ?? true) && [0, 1].contains(mode) && ["page", "window"].contains(presentation) &&
                frame?.valid != false && (presentation == "window" || frame == nil) && raw?.valid != false && preview?.valid != false &&
                (raw == nil) == (encoding == nil) && preview?.editor == nil && preview?.editing != true && video?.valid != false &&
                (video == nil || video?.sourceRoot == root) && (preview == nil || ["md", "markdown"].contains(URL(string: target)?.pathExtension.lowercased() ?? "") && preview?.sourceHash == raw?.hash)
        }
        static func validateObject(_ raw: Any) throws {
            guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["version", "root", "target", "hash", "history", "encodings", "encoding", "mode", "presentation", "frame", "raw", "preview", "video"]) else { throw PetError("来源阅读恢复格式不受支持，原记录已保留") }
            if let raw = value["frame"], !(raw is NSNull) { guard let frame = raw as? [String: Any], Set(frame.keys).isSubset(of: ["x", "y", "width", "height"]) else { throw PetError("来源窗口位置格式不受支持") } }
            if let raw = value["raw"], !(raw is NSNull) { try AgentTextViewport.validateObject(raw) }
            if let raw = value["preview"], !(raw is NSNull) { try AgentMarkdownReader.ViewRecovery.validateObject(raw) }
            if let raw = value["video"], !(raw is NSNull) { try AgentVideoWindow.validateRecoveryObject(raw) }
        }
    }
    var needsHostedPresentation: Bool { pendingPage && !workspaceIsClosed && settingsHostWindow == nil }
    func prepareWorkspaceNavigation() {
        if presentingWindow?.firstResponder === text { rawFocused = true }
        reader.rememberViewportFocus(); videoWindow?.preview.pause()
    }
    func presentRecoveredWindow() { guard !pendingPage, !workspaceIsClosed else { return }; showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func captureWorkspaceRecovery() async throws -> RecoveryState? {
        guard !workspaceIsClosed else { return nil }
        var child = pendingVideo
        while let current = videoWindow {
            let value = try await current.captureWorkspaceRecovery(includingHosted: true)
            guard videoWindow === current else { continue }; child = value; break
        }
        guard !workspaceIsClosed else { return nil }
        let presentation = pendingPage || settingsHostWindow != nil ? "page" : "window"
        let frame = presentation == "window" ? window.map { AgentWorkspaceRecovery.Frame($0) } : nil
        if var value = pendingRecovery {
            value.presentation = presentation; value.frame = frame; value.video = child
            return value
        }
        guard let file, let sourceHash else { throw PetError("来源阅读缺少原始版本，原记录已保留") }
        if presentingWindow?.firstResponder === text { rawFocused = true }
        var raw: AgentTextViewport?
        if currentFormat != nil {
            if let pendingRaw { raw = pendingRaw } else { raw = try AgentTextViewport(text) }; raw?.focused = rawFocused
        }
        let value = RecoveryState(root: sourceRoot, target: file.absoluteString, hash: sourceHash, history: history.map(\.absoluteString), encodings: encodings.mapValues(\.rawValue),
            encoding: currentFormat?.encoding.rawValue, mode: mode.selectedSegment, presentation: presentation, frame: frame, raw: raw, preview: try reader.captureViewRecovery(source: text.string), video: child)
        guard value.valid else { throw PetError("来源阅读位置或历史无效，原记录已保留") }; return value
    }
    private func currentFiles() throws -> AgentFiles {
        guard !workspaceIsClosed else { throw PetError("来源窗口已关闭") }; try validateScope?()
        let files = try AgentFiles(workspace: sourceRoot)
        guard files.root.path == sourceRoot else { throw PetError("来源目录已变化，原阅读记录已保留") }; return files
    }
    private func relative(_ file: URL) -> String { sourceRoot == "/" ? String(file.path.dropFirst()) : String(file.path.dropFirst(sourceRoot.count + 1)) }
    private func restoreSource() {
        guard let value = pendingRecovery, let target = URL(string: value.target) else { return }
        applyingView = true
        defer { applyingView = false; scheduleRaw() }
        history = value.history.compactMap(URL.init(string:)); encodings = value.encodings.compactMapValues(AgentTextEncoding.init(rawValue:)); file = target; sourceHash = value.hash
        do {
            let files = try currentFiles(), safe = try AgentMarkdownDocument.target(target, document: target, files: files)
            guard safe == target else { throw PetError("来源位置已变化，原阅读位置已保留") }
            try open(target, remember: false, encoding: value.encoding.flatMap(AgentTextEncoding.init(rawValue:)), restoring: value.encoding != nil, expectedHash: value.hash)
            if let raw = value.raw { guard raw.matches(text) else { throw PetError("来源原文已变化，原选区已保留") }; pendingRaw = raw; rawFocused = raw.focused }
            if let preview = value.preview { try reader.restoreViewRecovery(preview) }
            mode.selectedSegment = value.mode; switchMode(); pendingRecovery = nil; latest.isHidden = true
        } catch {
            pendingRaw = nil; currentFormat = nil; reader.clear(); reader.isHidden = true; text.string = ""; scroll.isHidden = false; mode.isHidden = true
            window?.title = relative(target); label.stringValue = "来源尚未恢复：" + error.localizedDescription; label.toolTip = target.path; back.isEnabled = !history.isEmpty; latest.isHidden = false
            AgentTextEncoding.updateMenu(encodingMenu, requested: value.encodings[target.path].flatMap(AgentTextEncoding.init(rawValue:)), format: nil)
        }
    }
    private func retainVideo(_ next: AgentVideoWindow) {
        videoWindow?.onClose = nil; videoWindow?.close(); pendingVideo = nil; videoWindow = next
        next.onWorkspaceChange = { [weak self] in self?.changed() }
        next.onClose = { [weak self, weak next] in guard let self, videoWindow === next else { return }; videoWindow = nil; changed() }
    }
    private func presentPendingVideo() {
        guard !workspaceIsClosed, !presentingVideo, let value = pendingVideo else { return }
        presentingVideo = true; defer { presentingVideo = false }
        let next = AgentVideoWindow(restoring: value) { [weak self] in
            guard let self else { throw PetError("来源窗口已关闭") }
            let files = try currentFiles(), target = try AgentMarkdownDocument.target(URL(fileURLWithPath: value.file), document: file ?? files.root.appendingPathComponent("index.md"), files: files)
            guard files.root.path == value.sourceRoot, target.path == value.file else { throw PetError("来源视频位置已变化，原进度已保留") }; return (files, target)
        }
        retainVideo(next); presentSettingsChild(next); changed()
    }
    private func changed() { guard !workspaceIsClosed, !applyingView else { return }; if presentingWindow?.firstResponder === text { rawFocused = true }; onWorkspaceChange?() }
    @objc private func rawViewChanged(_ notification: Notification) { if !applyingView, pendingRaw == nil { changed() } }
    @objc private func geometryChanged(_ notification: Notification) { pageDidLayout(); changed() }
    private func scheduleRaw(force: Bool = false) {
        rawFocusRequested = rawFocusRequested || force
        guard !applyingView, !viewScheduled, pendingRaw != nil || rawFocusRequested else { return }; viewScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; let force = rawFocusRequested; rawFocusRequested = false; defer { viewScheduled = false }
            guard !workspaceIsClosed, pendingRecovery == nil, isPageVisible, !scroll.isHidden, var value = pendingRaw ?? (try? AgentTextViewport(text)) else { return }
            applyingView = true; presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            if force { value.focused = true }
            if value.apply(to: text) { pendingRaw = nil; rawFocused = value.focused }
            applyingView = false; changed()
        }
    }
    override func pageDidLayout() { scheduleRaw(); reader.scheduleViewRecovery() }
    override func settingsDidAppear() {
        pendingPage = false; super.settingsDidAppear()
        scheduleRaw(force: !scroll.isHidden && rawFocused); reader.activateRememberedView(); presentPendingVideo()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        scheduleRaw(force: !scroll.isHidden && rawFocused); reader.activateRememberedView()
        if settingsHostWindow == nil, !pendingPage { presentPendingVideo() }
    }
    override func canLeaveSettings() -> Bool { guard super.canLeaveSettings() else { return false }; prepareWorkspaceNavigation(); return true }
    private func finishClose() {
        guard !workspaceIsClosed else { return }; workspaceIsClosed = true; NotificationCenter.default.removeObserver(self)
        videoWindow?.close(); videoWindow = nil; pendingVideo = nil; pendingRecovery = nil; pendingRaw = nil; reader.clear(); text.string = ""
        onClose?(); onClose = nil; onWorkspaceChange?()
    }
    override func close() { if settingsHostWindow == nil { finishClose() }; super.close() }
    override func settingsWillLeave() { finishClose() }

    private var sourceCheckEnabled: Bool { ["--workspace-source-recovery-check", "--workspace-source-recovery-ui"].contains(where: CommandLine.arguments.contains) }
    var recoveryVideoForCheck: AgentVideoWindow? { sourceCheckEnabled ? videoWindow : nil }
    func checkSourceLink(_ url: URL) { if sourceCheckEnabled { follow(url) } }
    func checkSourceAction(_ action: String) {
        guard sourceCheckEnabled || action == "back" && CommandLine.arguments.contains("--knowledge-video-check") else { return }
        switch action { case "back": goBack(); case "retry": refreshFile(); case "latest": openLatest(); case "close": close(); default: break }
    }
    func checkSourceView(preview: Bool, target: String = "", y: Double? = nil, encoding: AgentTextEncoding? = nil, heading: String? = nil) throws {
        guard sourceCheckEnabled else { return }
        if let encoding {
            guard let index = AgentTextEncoding.allCases.firstIndex(of: encoding) else { throw PetError("未找到来源编码选项") }
            encodingMenu.selectItem(at: index + 1); reopenEncoding()
        }
        mode.selectedSegment = preview ? 0 : 1; switchMode(mode)
        if let heading { try reader.checkSourceHeading(heading) }
        let field = preview ? reader.text : text
        if !target.isEmpty {
            let range = (field.string as NSString).range(of: target); guard range.location != NSNotFound else { throw PetError("未找到公开来源选文") }
            field.setSelectedRange(range); presentingWindow?.makeFirstResponder(field)
        }
        presentingWindow?.contentView?.layoutSubtreeIfNeeded()
        if let y, let view = field.enclosingScrollView { view.contentView.scroll(to: NSPoint(x: 0, y: y)); view.reflectScrolledClipView(view.contentView) }
    }
    var sourceRecoveryReadback: [String: Any] {
        guard sourceCheckEnabled else { return [:] }
        return ["file": file?.absoluteString ?? "", "history": history.map(\.absoluteString), "mode": mode.selectedSegment, "editable": text.isEditable,
                "encoding": currentFormat?.encoding.rawValue ?? "", "hash": sourceHash ?? "", "pending": pendingRecovery != nil,
                "bodyHash": AgentFiles.hash(Data(text.string.utf8)), "raw": ["location": text.selectedRange().location, "length": text.selectedRange().length, "y": Double(scroll.contentView.bounds.minY), "focused": presentingWindow?.firstResponder === text, "pending": pendingRaw != nil], "preview": reader.viewportReadback,
                "independent": hasIndependentWindow, "videoIndependent": hasIndependentVideoWindow, "closed": workspaceIsClosed, "error": label.stringValue]
    }
}
