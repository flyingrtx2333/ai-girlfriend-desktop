import AppKit

@MainActor final class AgentBrowserAnnotationView: NSView {
    let shot: AgentBrowserShot
    var kind = AgentBrowserMark.Kind.rectangle
    var selectsElements = false
    var isEnabled = true
    var imageSize: NSSize = .zero { didSet { if oldValue != imageSize { needsDisplay = true } } }
    private(set) var marks: [AgentBrowserMark] = []
    private var current: AgentBrowserMark?
    var onChange: (() -> Void)?
    var onElementPick: ((AgentBrowserAnnotationTarget?) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageRect: NSRect {
        NSRect(x: (bounds.width - imageSize.width) / 2, y: (bounds.height - imageSize.height) / 2,
               width: imageSize.width, height: imageSize.height)
    }
    init(shot: AgentBrowserShot) {
        self.shot = shot; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("网页标注画布")
        setAccessibilityHelp("选择绘图工具后在图片上拖动。元素模式可点选截图里的按钮、链接或标题。")
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
        window?.makeFirstResponder(self)
        if selectsElements { onElementPick?(markElement(at: point(event))) }
        else { beginMark(at: point(event)) }
    }
    override func mouseDragged(with event: NSEvent) { if isEnabled && !selectsElements { continueMark(at: point(event)) } }
    override func mouseUp(with event: NSEvent) { if isEnabled && !selectsElements { continueMark(at: point(event)); endMark() } }
    func markElement(at point: CGPoint) -> AgentBrowserAnnotationTarget? {
        guard isEnabled, let target = shot.annotationTargets.filter({ $0.rect.contains(point) }).min(by: {
            $0.width * $0.height < $1.width * $1.height
        }) else { return nil }
        if !marks.contains(where: { $0.element == target }) {
            marks.append(AgentBrowserMark(kind: .rectangle, points: target.corners, element: target))
            changed()
        }
        return target
    }
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

@MainActor private final class AgentBrowserAnnotationScroll: NSScrollView {
    typealias Viewport = AgentBrowserRecoveryState.Annotation.Viewport
    private let canvas: AgentBrowserAnnotationView
    private(set) var viewport = Viewport()
    private var fittedTo: NSSize = .zero, applying = false
    var onChange: (() -> Void)?

    init(canvas: AgentBrowserAnnotationView) {
        self.canvas = canvas
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        scrollerStyle = .overlay
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        usesPredominantAxisScrolling = false
        documentView = canvas
        setAccessibilityLabel("标注视图")
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func tile() {
        super.tile()
        if fittedTo != contentView.bounds.size { fit() }
    }
    func setZoom(_ scale: Double) {
        setViewport(scale == 1 ? Viewport() : Viewport(scale: scale, x: viewport.x, y: viewport.y))
    }
    func setViewport(_ value: Viewport) {
        viewport = value
        fit()
        onChange?()
    }
    private func fit() {
        let clip = contentView, size = clip.bounds.size
        guard !applying, documentView === canvas, size.width > 0, size.height > 0 else { return }
        applying = true
        defer { applying = false }
        fittedTo = size
        let source = canvas.shot.image.size
        let scale = min(size.width / max(1, source.width), size.height / max(1, source.height)) * viewport.scale
        let image = NSSize(width: source.width * scale, height: source.height * scale)
        canvas.imageSize = image
        canvas.setFrameSize(NSSize(width: max(size.width, image.width), height: max(size.height, image.height)))
        // Keep the same point in the screenshot centered as the window changes.
        let rect = canvas.imageRect
        let center = canvas.convert(NSPoint(x: rect.minX + viewport.x * rect.width, y: rect.minY + viewport.y * rect.height), to: clip)
        let bounds = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(clip)
    }
    @objc private func scrolled() {
        let bounds = contentView.bounds, image = canvas.imageRect
        guard !applying, viewport.scale > 1, bounds.size == fittedTo, !image.isEmpty else { return }
        let center = contentView.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: canvas)
        let next = Viewport(scale: viewport.scale, x: min(1, max(0, (center.x - image.minX) / image.width)),
                           y: min(1, max(0, (center.y - image.minY) / image.height)))
        guard next != viewport else { return }
        viewport = next
        onChange?()
    }
}

@MainActor final class AgentBrowserAnnotationWindow: AgentSettingsPageController, NSWindowDelegate, NSTextFieldDelegate {
    private typealias Viewport = AgentBrowserRecoveryState.Annotation.Viewport
    private let elementSegment = AgentBrowserMark.Kind.allCases.count
    let canvas: AgentBrowserAnnotationView
    private let scroll: AgentBrowserAnnotationScroll
    private let mode = NSSegmentedControl(labels: ["框选", "箭头", "画笔"], trackingMode: .selectOne, target: nil, action: nil)
    private let zoom = NSPopUpButton()
    private lazy var zoomControl = AgentSettingsPopupFrame(zoom)
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
        let canvas = AgentBrowserAnnotationView(shot: shot)
        self.canvas = canvas; scroll = AgentBrowserAnnotationScroll(canvas: canvas); self.onSubmit = onSubmit
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "标注 · " + String(shot.source.title.prefix(80)); window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        if !shot.annotationTargets.isEmpty {
            mode.segmentCount += 1
            mode.setLabel("元素", forSegment: elementSegment)
        }
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(annotationToolChanged); mode.setAccessibilityLabel("标注工具")
        for index in 0..<mode.segmentCount { mode.setWidth(46, forSegment: index) }
        mode.setContentCompressionResistancePriority(.required, for: .horizontal)
        zoom.addItems(withTitles: Viewport.scales.map { $0 == 1 ? "适应窗口" : "\(Int($0 * 100))%" })
        zoom.target = self; zoom.action = #selector(changeZoom)
        zoom.setAccessibilityLabel("标注缩放")
        zoomControl.widthAnchor.constraint(equalToConstant: 90).isActive = true
        for (button, action) in [(undo, #selector(undoMark)), (clear, #selector(clearMarks)), (copy, #selector(copyImage)), (cancel, #selector(cancelEdit)), (add, #selector(addToTask))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = .command
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        note.placeholderString = "补充要求"; note.setAccessibilityLabel("标注补充要求"); note.delegate = self
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        if shot.source.method == "webkit-software" { state.stringValue = "软件快照可能缺少视频和 3D 内容" }
        let drawing = NSStackView(views: [mode, undo, clear]), imageActions = NSStackView(views: [zoomControl, copy])
        for group in [drawing, imageActions] {
            group.alignment = .centerY
            group.spacing = 8
            group.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        let spacer = NSView()
        let header = NSStackView(views: [drawing, spacer, imageActions])
        header.alignment = .centerY
        header.spacing = 6
        content.onResize = { [weak content, weak header, weak spacer] in
            guard let width = content?.bounds.width, let header, let spacer else { return }
            let compact = width < 550
            header.orientation = compact ? .vertical : .horizontal
            header.alignment = compact ? .leading : .centerY
            spacer.isHidden = compact
        }
        let footer = NSStackView(views: [state, NSView(), cancel, add]); footer.spacing = 8
        for view in [header, scroll, note, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -12),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), note.heightAnchor.constraint(equalToConstant: 24), note.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), footer.heightAnchor.constraint(equalToConstant: 28), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        canvas.onChange = { [weak self] in self?.updateControls() }; updateControls()
        canvas.onElementPick = { [weak self] target in
            self?.showElementStatus(target, whenEmpty: "此处没有可选元素")
        }
        scroll.onChange = { [weak self] in self?.onWorkspaceChange?() }
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
        zoom.isEnabled = enabled; zoomControl.refreshEnabledState()
        add.title = enabled ? "添加到对话" : "添加中…"
        onWorkspaceChange?()
    }
    private func showElementStatus(_ target: AgentBrowserAnnotationTarget?, whenEmpty: String = "点击截图中的按钮、链接或标题") {
        state.textColor = AgentWorkbenchTheme.secondaryText
        state.stringValue = target.map { "已标注\($0.role.title)「\($0.label)」" } ?? whenEmpty
    }
    private func applyTool() {
        canvas.selectsElements = mode.selectedSegment == elementSegment
        canvas.kind = AgentBrowserMark.Kind(rawValue: mode.selectedSegment) ?? .rectangle
        if canvas.selectsElements { showElementStatus(canvas.marks.last?.element) }
        else if state.textColor != .systemRed {
            state.stringValue = canvas.shot.source.method == "webkit-software" ? "软件快照可能缺少视频和 3D 内容" : ""
        }
    }
    @objc private func annotationToolChanged() { applyTool(); onWorkspaceChange?() }
    @objc private func changeZoom() {
        guard Viewport.scales.indices.contains(zoom.indexOfSelectedItem) else { return }
        scroll.setZoom(Viewport.scales[zoom.indexOfSelectedItem])
    }
    @objc private func undoMark() {
        canvas.undoMark()
        if canvas.selectsElements { showElementStatus(canvas.marks.last?.element) }
    }
    @objc private func clearMarks() {
        canvas.clearMarks()
        if canvas.selectsElements { showElementStatus(nil) }
    }
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
        let visible = canvas.visibleRect, image = canvas.imageRect
        return ["closed": closed, "visible": isPageVisible, "dirty": hasPendingChanges, "working": job != nil, "note": note.stringValue, "marks": canvas.marks.count, "url": canvas.shot.source.url, "sourceTab": canvas.shot.source.tabID, "captureMethod": canvas.shot.source.method ?? "", "canvasSize": [canvas.bounds.width, canvas.bounds.height],
                "zoom": scroll.viewport.scale, "visibleRect": [visible.minX, visible.minY, visible.width, visible.height], "imageRect": [image.minX, image.minY, image.width, image.height],
                "checks": ["annotationUsesTaskWindow": settingsHostWindow != nil && pageContentView?.window === settingsHostWindow, "annotationHasNoFloatingWindow": window?.isVisible != true, "annotationHasUsableCanvas": scroll.bounds.width >= 400 && scroll.bounds.height >= 200 && !image.isEmpty && canvas.bounds.contains(image)]]
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
        return .init(source: canvas.shot.source, image: recoveryImage!, marks: canvas.recoveryMarks(), note: editor?.string ?? note.stringValue,
                     tool: canvas.selectsElements ? AgentBrowserMark.Kind.rectangle.rawValue : mode.selectedSegment,
                     focusNote: editor != nil && presentingWindow?.firstResponder === editor, selection: selected ?? restoredNoteSelection,
                     frame: hasIndependentWindow ? window.map { .init($0) } : nil, viewport: scroll.viewport.scale > 1 ? scroll.viewport : nil,
                     elementTargets: canvas.shot.annotationTargets.isEmpty ? nil : canvas.shot.annotationTargets,
                     elementTool: canvas.selectsElements ? true : nil)
    }
    func restoreWorkspaceRecovery(_ value: AgentBrowserRecoveryState.Annotation) {
        recoveryImage = value.image; mode.selectedSegment = value.elementTool == true ? elementSegment : value.tool
        canvas.restoreMarks(value.marks); note.stringValue = value.note; restoredNoteSelection = value.selection; restoreNoteFocus = value.focusNote; updateControls()
        applyTool()
        let viewport = value.viewport ?? Viewport()
        zoom.selectItem(at: Viewport.scales.firstIndex(of: viewport.scale) ?? 0)
        scroll.setViewport(viewport)
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
