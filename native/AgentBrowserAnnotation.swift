import AppKit

@MainActor final class AgentBrowserAnnotationView: NSView {
    let shot: AgentBrowserShot
    var kind = AgentBrowserMark.Kind.rectangle
    var isEnabled = true
    private(set) var marks: [AgentBrowserMark] = []
    private var current: AgentBrowserMark?
    var onChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageRect: NSRect {
        let size = shot.image.size, scale = min(bounds.width / max(1, size.width), bounds.height / max(1, size.height))
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
    init(shot: AgentBrowserShot) {
        self.shot = shot; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("网页标注画布")
        setAccessibilityHelp("选择框选、箭头或画笔，然后在图片上拖动。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        AgentWorkbenchTheme.surface.setFill(); bounds.fill()
        shot.image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        AgentBrowserMark.draw(marks + (current.map { [$0] } ?? []), in: imageRect)
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: min(1, max(0, (location.x - rect.minX) / max(1, rect.width))), y: min(1, max(0, (location.y - rect.minY) / max(1, rect.height))))
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self); beginMark(at: point(event))
    }
    override func mouseDragged(with event: NSEvent) { if isEnabled { continueMark(at: point(event)) } }
    override func mouseUp(with event: NSEvent) { if isEnabled { continueMark(at: point(event)); endMark() } }
    func beginMark(at point: CGPoint) {
        guard isEnabled, point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        current = AgentBrowserMark(kind: kind, points: [point]); needsDisplay = true
    }
    func continueMark(at point: CGPoint) {
        guard isEnabled, var mark = current, point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        if mark.kind == .pen { mark.points.append(point) }
        else { mark.points = [mark.points[0], point] }
        current = mark; needsDisplay = true
    }
    func endMark() {
        if let mark = current, mark.points.count > 1,
           let first = mark.points.first, let last = mark.points.last,
           mark.kind == .pen || hypot(first.x - last.x, first.y - last.y) > 0.005 { marks.append(mark) }
        current = nil; changed()
    }
    func undoMark() { current = nil; if !marks.isEmpty { marks.removeLast() }; changed() }
    func clearMarks() { current = nil; marks = []; changed() }
    func recoveryMarks() -> [AgentBrowserMark] {
        guard let current, current.points.count > 1, let first = current.points.first, let last = current.points.last,
              current.kind == .pen || hypot(first.x - last.x, first.y - last.y) > 0.005 else { return marks }; return marks + [current]
    }
    func restoreMarks(_ values: [AgentBrowserMark]) { current = nil; marks = values; changed() }
    private func changed() { needsDisplay = true; setAccessibilityValue("\(marks.count) 处标注"); onChange?() }
}

@MainActor final class AgentBrowserAnnotationWindow: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate {
    let canvas: AgentBrowserAnnotationView
    private let mode = NSSegmentedControl(labels: ["框选", "箭头", "画笔"], trackingMode: .selectOne, target: nil, action: nil)
    private let undo = NSButton(title: "撤销", target: nil, action: nil), clear = NSButton(title: "清除", target: nil, action: nil)
    private let copy = NSButton(title: "复制截图", target: nil, action: nil), cancel = NSButton(title: "取消", target: nil, action: nil), add = NSButton(title: "添加到对话", target: nil, action: nil)
    private let note = NSTextField(), state = NSTextField(labelWithString: "")
    private let onSubmit: ([AgentBrowserMark], String) async throws -> Void
    private var job: Task<Void, Never>?, closed = false, submitted = false, discardAccepted = false
    private var recoveryImage: Data?, restoredNoteSelection: AgentBrowserRecoveryState.Selection?
    private var restoreNoteFocus = false
    var onWorkspaceChange: (() -> Void)?
    var workspaceIsClosed: Bool { closed }
    var hasIndependentWindow: Bool { !closed && settingsHostWindow == nil }
    var canPreserveForQuit: Bool { !closed && job == nil && !submitted && !discardAccepted }
    var hasPendingChanges: Bool { !closed && !submitted && !discardAccepted && (!canvas.marks.isEmpty || !note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    init(shot: AgentBrowserShot, onSubmit: @escaping ([AgentBrowserMark], String) async throws -> Void) {
        canvas = AgentBrowserAnnotationView(shot: shot); self.onSubmit = onSubmit
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "标注 · " + String(shot.source.title.prefix(80)); window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(annotationToolChanged); mode.setAccessibilityLabel("标注工具")
        for (button, action) in [(undo, #selector(undoMark)), (clear, #selector(clearMarks)), (copy, #selector(copyImage)), (cancel, #selector(cancelEdit)), (add, #selector(addToTask))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = .command
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        note.placeholderString = "补充要求"; note.setAccessibilityLabel("标注补充要求"); note.delegate = self
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        if shot.source.method == "webkit-software" { state.stringValue = "软件快照可能缺少视频和 3D 内容" }
        let header = NSStackView(views: [mode, undo, clear, NSView(), copy]); header.spacing = 8
        let footer = NSStackView(views: [state, NSView(), cancel, add]); footer.spacing = 8
        for view in [header, canvas, note, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), header.heightAnchor.constraint(equalToConstant: 28),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), canvas.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), canvas.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -12),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), note.heightAnchor.constraint(equalToConstant: 24), note.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), footer.heightAnchor.constraint(equalToConstant: 28), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        canvas.onChange = { [weak self] in self?.updateControls() }; updateControls()
        NotificationCenter.default.addObserver(self, selector: #selector(noteSelectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreNoteFocusIfNeeded(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] { NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)), name: name, object: window) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func prepareWorkspaceNavigation() -> Bool {
        guard job == nil || closed else { state.stringValue = "正在添加标注，请稍候"; return false }; return true
    }
    override func canLeaveSettings() -> Bool {
        if closed || submitted || discardAccepted { return true }
        guard prepareWorkspaceNavigation(), presentingWindow?.hasBlockingDialog != true else { return false }
        guard hasPendingChanges else { return true }
        discardAccepted = AgentUnsavedChanges.discard("放弃未添加的网页标注？", detail: canvas.shot.source.title, discardTitle: "放弃标注"); return discardAccepted
    }
    override func settingsWillLeave() { finishClose() }
    override func close() { if canLeaveSettings() { super.close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeaveSettings() }
    func windowWillClose(_ notification: Notification) { finishClose() }
    func finishClose() { guard !closed else { return }; closed = true; NotificationCenter.default.removeObserver(self); job?.cancel(); onWorkspaceChange?() }
    @objc private func geometryChanged(_ notification: Notification) { if !closed { onWorkspaceChange?() } }
    func controlTextDidChange(_ obj: Notification) { restoredNoteSelection = nil; onWorkspaceChange?() }
    @objc private func noteSelectionChanged(_ notification: Notification) {
        guard !closed, let editor = notification.object as? NSTextView, note.currentEditor() === editor else { return }
        let range = editor.selectedRange(), selection = AgentBrowserRecoveryState.Selection(location: range.location, length: range.length)
        guard selection.valid(in: editor.string) else { return }
        restoredNoteSelection = selection; onWorkspaceChange?()
    }
    @objc private func restoreNoteFocusIfNeeded(_ notification: Notification) {
        guard restoreNoteFocus, notification.object as? NSWindow === presentingWindow else { return }; settingsDidAppear()
    }
    private func updateControls() {
        let enabled = job == nil
        canvas.isEnabled = enabled; mode.isEnabled = enabled; undo.isEnabled = enabled && !canvas.marks.isEmpty; clear.isEnabled = undo.isEnabled; copy.isEnabled = enabled; add.isEnabled = enabled; note.isEnabled = enabled
        add.title = enabled ? "添加到对话" : "添加中…"
        onWorkspaceChange?()
    }
    @objc private func annotationToolChanged() { canvas.kind = AgentBrowserMark.Kind(rawValue: mode.selectedSegment) ?? .rectangle; onWorkspaceChange?() }
    @objc private func undoMark() { canvas.undoMark() }
    @objc private func clearMarks() { canvas.clearMarks() }
    @objc private func cancelEdit() { close() }
    @objc private func copyImage() {
        do {
            guard let image = NSImage(data: try canvas.shot.png(marks: canvas.marks)) else { throw PetError("标注图片无法读取") }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]); state.stringValue = "已复制截图"
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func addToTask() {
        guard job == nil else { return }
        let marks = canvas.marks, text = note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        job = Task { [weak self] in
            guard let self else { return }; defer { job = nil; if !closed { updateControls() } }
            do { try await onSubmit(marks, text); submitted = true; onWorkspaceChange?(); close() }
            catch { if !closed { state.stringValue = Task.isCancelled ? "已取消添加" : error.localizedDescription; state.textColor = .systemRed } }
        }
        updateControls()
    }
    func checkLayout(_ output: URL) -> [String: Bool] {
        showWindow(nil); var checks: [String: Bool] = [:]
        for (name, size) in [("normal", NSSize(width: 1000, height: 760)), ("narrow", NSSize(width: 640, height: 480))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["annotationLayout-" + name] = !canvas.hasAmbiguousLayout && canvas.bounds.width > 500 && canvas.bounds.height > 250 && canvas.bounds.contains(canvas.imageRect) && !mode.hasAmbiguousLayout && add.frame.maxX <= (window?.contentView?.bounds.width ?? 0)
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("annotation-" + name + ".png")) }
        }
        return checks
    }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        return ["closed": closed, "visible": isPageVisible, "dirty": hasPendingChanges, "working": job != nil, "note": note.stringValue, "marks": canvas.marks.count, "url": canvas.shot.source.url, "sourceTab": canvas.shot.source.tabID, "captureMethod": canvas.shot.source.method ?? "", "canvasSize": [canvas.bounds.width, canvas.bounds.height], "checks": ["annotationUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow, "annotationHasNoFloatingWindow": window?.isVisible != true, "annotationHasUsableCanvas": canvas.bounds.width >= 400 && canvas.bounds.height >= 200 && canvas.bounds.contains(canvas.imageRect)]]
    }
    func checkWorkspace(note text: String? = nil, mark: Bool = false, submit: Bool = false, selection: NSRange? = nil) async {
        guard AgentTaskWorkspace.readbackEnabled else { return }
        if let text { note.stringValue = text; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: note)) }
        if mark { canvas.beginMark(at: CGPoint(x: 0.2, y: 0.2)); canvas.continueMark(at: CGPoint(x: 0.4, y: 0.4)); canvas.endMark() }
        if let selection, selection.location <= (note.stringValue as NSString).length, selection.length <= (note.stringValue as NSString).length - selection.location {
            presentingWindow?.makeKeyAndOrderFront(nil); presentingWindow?.makeFirstResponder(note)
            (note.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        }
        if submit { addToTask(); await job?.value }
    }
    func captureWorkspaceRecovery() throws -> AgentBrowserRecoveryState.Annotation {
        guard canPreserveForQuit else { throw PetError("网页标注尚在添加，请稍候") }
        if recoveryImage == nil { recoveryImage = try canvas.shot.png() }
        let editor = note.currentEditor() as? NSTextView
        let selected = editor.map { AgentBrowserRecoveryState.Selection(location: $0.selectedRange().location, length: $0.selectedRange().length) }
        return .init(source: canvas.shot.source, image: recoveryImage!, marks: canvas.recoveryMarks(), note: editor?.string ?? note.stringValue, tool: mode.selectedSegment,
                     focusNote: editor != nil && presentingWindow?.firstResponder === editor, selection: selected ?? restoredNoteSelection,
                     frame: hasIndependentWindow ? window.map { .init($0) } : nil)
    }
    func restoreWorkspaceRecovery(_ value: AgentBrowserRecoveryState.Annotation) {
        recoveryImage = value.image; mode.selectedSegment = value.tool; canvas.kind = AgentBrowserMark.Kind(rawValue: value.tool) ?? .rectangle
        canvas.restoreMarks(value.marks); note.stringValue = value.note; restoredNoteSelection = value.selection; restoreNoteFocus = value.focusNote; updateControls()
    }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        guard restoreNoteFocus, isPageVisible, let host = presentingWindow, host.isKeyWindow else { return }
        let selected = restoredNoteSelection
        host.makeFirstResponder(note)
        if let selection = selected, selection.valid(in: note.stringValue), let editor = note.currentEditor() as? NSTextView { editor.setSelectedRange(NSRange(location: selection.location, length: selection.length)) }
        restoreNoteFocus = false
    }
}
