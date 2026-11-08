import AppKit

@MainActor final class AgentMarkdownReader: NSView, NSTextViewDelegate {
    let text = AgentMarkdownTextView()
    private let outline = NSPopUpButton(), scroll = NSScrollView()
    private let addSelection = NSButton(title: "加入任务", target: nil, action: nil)
    private let edit = NSButton(title: "编辑", target: nil, action: nil), edits = UndoManager()
    private var inlineEditor: AgentMarkdownInlineEditor?
    private(set) var isEditing = false
    var onSourceChanged: ((String) -> Void)? { didSet { updateEditingState() } }
    var canEdit: (() -> Bool)? { didSet { updateEditingState() } }
    var onEditError: ((String) -> Void)?
    private lazy var selectionAction = AgentMarkdownSelectionAction(text: text, button: addSelection) { [weak self] in guard let self, !self.isEditing, let file = self.file, let workspace = self.workspace else { return nil }; return (file, workspace) }
    var onAddSelection: ((AgentMarkdownSelection) throws -> Void)? { didSet { selectionAction.onAdd = onAddSelection } }
    var canAddSelection: (() -> Bool)? { didSet { selectionAction.canAdd = canAddSelection } }
    private(set) var document: AgentMarkdownDocument?
    private var file: URL?, source = "", workspace: String?, renderedWidth: CGFloat = 0
    private var pendingAnchor: NSRange?, revealScheduled = false
    private var diagramTask: Task<Void, Never>?, diagramRenderer: AgentMarkdownDiagrams?, generation = UUID()
    private(set) var drawings: [Int: AgentMarkdownDiagrams.Drawing] = [:], diagramErrors: [Int: String] = [:]
    private var diagramWindow: AgentMarkdownDiagramWindow?
    var onLink: ((URL) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.importsGraphics = false; text.delegate = self
        text.onDoubleClickAttachment = { [weak self] index in self?.openDiagram(index) ?? false }
        text.onPreviewEditClick = { [weak self] point in self?.beginEditing(at: point) ?? false }; text.previewUndoManager = edits; text.allowsUndo = true; edits.levelsOfUndo = 20
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 18, height: 16)
        text.setAccessibilityLabel("Markdown 预览")
        outline.target = self; outline.action = #selector(selectHeading); outline.setAccessibilityLabel("章节目录")
        edit.target = self; edit.action = #selector(toggleEditing); edit.bezelStyle = .texturedRounded; edit.controlSize = .small; edit.setAccessibilityLabel("编辑 Markdown 预览"); edit.toolTip = "就地编辑；Command+Return 完成，Esc 取消本次修改"
        scroll.documentView = text; scroll.hasVerticalScroller = true
        let toolbar = NSStackView(views: [outline, NSView(), edit, addSelection]); toolbar.spacing = 8
        for view in [toolbar, scroll] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), outline.widthAnchor.constraint(lessThanOrEqualToConstant: 380), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
        selectionAction.update(); updateEditingState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func clear() { inlineEditor?.removeFromSuperview(); inlineEditor = nil; isEditing = false; edits.removeAllActions(); cancelDiagrams(); diagramWindow?.close(); diagramWindow = nil; source = ""; file = nil; workspace = nil; document = nil; pendingAnchor = nil; outline.removeAllItems(); text.string = ""; selectionAction.update(); updateEditingState() }
    func show(_ source: String, file: URL, workspace: String, reuseIfUnchanged: Bool = false) {
        if reuseIfUnchanged, inlineEditor == nil, self.source == source, self.file == file, self.workspace == workspace, document != nil { isEditing = false; updateEditingState(); return }
        inlineEditor?.removeFromSuperview(); inlineEditor = nil; isEditing = false; edits.removeAllActions(); cancelDiagrams(); pendingAnchor = nil; self.source = source; self.file = file; self.workspace = workspace; outline.selectItem(at: 0); render(); updateEditingState()
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    override func layout() {
        super.layout()
        if !isHidden, abs(bounds.width - renderedWidth) > 8 { resizeImages() }
        positionEditor()
        scheduleReveal()
    }
    private func scheduleReveal() {
        guard pendingAnchor != nil, !revealScheduled else { return }; revealScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.revealScheduled = false
            guard let range = self.pendingAnchor, self.window?.isVisible == true, !self.isHidden, self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.pendingAnchor = nil; AgentMarkdownDocument.reveal(range, in: self.text)
        }
    }
    private func resizeImages() {
        renderedWidth = bounds.width
        guard let storage = text.textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image, image.size.width > 0 else { return }
            let scale = min(1, max(160, bounds.width - 36) / image.size.width)
            attachment.bounds.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        text.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
    }
    private func render(cachedImages: [String: NSImage] = [:], cachedDrawings: [String: AgentMarkdownDiagrams.Drawing] = [:]) {
        guard let file, let files = try? AgentFiles(workspace: workspace) else { return }
        let selected = outline.indexOfSelectedItem, origin = scroll.contentView.bounds.origin
        renderedWidth = bounds.width
        let result = AgentMarkdownDocument.render(source, document: file, files: files, width: max(220, bounds.width), cachedImages: cachedImages); document = result
        for diagram in result.diagrams { if let cached = cachedDrawings[diagram.source] { diagram.attachment.image = cached.image; drawings[diagram.range.location] = cached } }
        text.textStorage?.setAttributedString(result.body)
        outline.removeAllItems(); outline.addItem(withTitle: "章节")
        for heading in result.headings { outline.addItem(withTitle: String(repeating: "  ", count: max(0, heading.level - 1)) + heading.title) }
        outline.isEnabled = !result.headings.isEmpty
        outline.selectItem(at: min(max(0, selected), outline.numberOfItems - 1))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        resizeImages(); renderDiagrams(result.diagrams.filter { drawings[$0.range.location] == nil }); selectionAction.update()
    }
    private func updateEditingState() { edit.isHidden = onSourceChanged == nil || file == nil; edit.isEnabled = isEditing || canEdit?() == true; edit.title = isEditing ? "完成" : "编辑"; selectionAction.update() }
    @objc private func toggleEditing() {
        do {
            if isEditing { try finishEditing(); isEditing = false; window?.makeFirstResponder(text) }
            else { guard canEdit?() == true else { throw PetError("此文件当前只读") }; isEditing = true }
            updateEditingState()
            if isEditing, source.isEmpty, let region = document?.regions.first { try beginEditing(region) }
        } catch { onEditError?(error.localizedDescription) }
    }
    private func regionRect(_ region: AgentMarkdownEditing.Region) -> NSRect {
        guard let layout = text.layoutManager, let container = text.textContainer, NSMaxRange(region.display) <= (text.string as NSString).length else { return .zero }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: region.display, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        if region.isCell, region.display.location < (text.string as NSString).length,
           let style = text.textStorage?.attribute(.paragraphStyle, at: region.display.location, effectiveRange: nil) as? NSParagraphStyle, let block = style.textBlocks.first {
            rect = layout.boundsRect(for: block, glyphRange: glyphs)
        } else { rect.origin.x = 0; rect.size.width = max(160, text.bounds.width - 36); rect.size.height = max(36, rect.height + 6) }
        return rect.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }
    private func beginEditing(at point: NSPoint) -> Bool {
        guard isEditing else { return false }
        do {
            guard canEdit?() == true else { throw PetError("此文件当前只读，草稿已保留") }
            guard let target = document?.regions.first(where: { regionRect($0).contains(point) }) else { return false }
            if let active = inlineEditor {
                if active.region.source == target.source && active.region.kind == target.kind { active.focus(); return true }
                let delta = (source as NSString).length - (active.base as NSString).length
                let location = target.source.location + (target.source.location >= NSMaxRange(active.region.source) ? delta : 0)
                let kind: AgentMarkdownEditing.Region.Kind
                if case .cell(let table, let row, let column) = target.kind { kind = .cell(table: table + (table >= NSMaxRange(active.region.source) ? delta : 0), row: row, column: column) } else { kind = target.kind }
                try finishEditing()
                guard let refreshed = document?.regions.first(where: { $0.source.location == location && $0.kind == kind }) else { return true }
                try beginEditing(refreshed)
            } else { try beginEditing(target) }
        } catch { onEditError?(error.localizedDescription) }
        return true
    }
    private func beginEditing(_ region: AgentMarkdownEditing.Region) throws {
        let editor = try AgentMarkdownInlineEditor(region: region, source: source); inlineEditor = editor
        editor.onChange = { [weak self, weak editor] value in
            guard let self, let editor else { return }
            do { let next = try AgentMarkdownEditing.replacing(editor.region, in: editor.base, with: value); if source != next { source = next; onSourceChanged?(next) } }
            catch { onEditError?(error.localizedDescription) }
        }
        editor.onFinish = { [weak self] commit, direction in
            guard let self else { return }
            let old = inlineEditor?.region.kind
            do {
                try finishEditing(commit: commit)
                if direction != 0, let old, let cells = document?.regions.filter({ $0.isCell }), let index = cells.firstIndex(where: { $0.kind == old }), cells.indices.contains(index + direction), case .cell(let table, _, _) = old, case .cell(let nextTable, _, _) = cells[index + direction].kind, table == nextTable { try beginEditing(cells[index + direction]) }
            } catch { onEditError?(error.localizedDescription) }
        }
        text.addSubview(editor); text.previewEditor = editor; positionEditor(); _ = text.scrollToVisible(editor.frame); editor.focus(); selectionAction.update()
    }
    private func positionEditor() {
        guard let editor = inlineEditor else { return }
        var rect = regionRect(editor.region)
        rect.size.height = min(max(28, rect.height), max(60, scroll.contentSize.height - 16))
        editor.frame = rect
    }
    func finishEditing(commit: Bool = true) throws {
        guard let editor = inlineEditor else { return }; editor.commitInput()
        let previous = editor.base, next = commit ? try AgentMarkdownEditing.replacing(editor.region, in: previous, with: editor.value) : previous
        inlineEditor = nil; text.previewEditor = nil; editor.removeFromSuperview()
        if source != next { source = next; onSourceChanged?(next) }
        replacePreview()
        if commit && previous != next { edits.registerUndo(withTarget: self) { reader in reader.restoreSource(previous) }; edits.setActionName("编辑 Markdown") }
        window?.makeFirstResponder(text)
    }
    private func restoreSource(_ value: String) {
        let previous = source; source = value; onSourceChanged?(value); replacePreview()
        edits.registerUndo(withTarget: self) { reader in reader.restoreSource(previous) }
    }
    private func replacePreview() {
        let images = document?.images ?? [:]
        var cached: [String: AgentMarkdownDiagrams.Drawing] = [:]
        for diagram in document?.diagrams ?? [] { if let drawing = drawings[diagram.range.location] { cached[diagram.source] = drawing } }
        cancelDiagrams(); render(cachedImages: images, cachedDrawings: cached)
    }
    private func cancelDiagrams() { generation = UUID(); diagramTask?.cancel(); diagramTask = nil; diagramRenderer?.stop(); diagramRenderer = nil; drawings = [:]; diagramErrors = [:] }
    private func renderDiagrams(_ diagrams: [AgentMarkdownDocument.Diagram]) {
        guard !diagrams.isEmpty else { return }
        let renderer = AgentMarkdownDiagrams(), token = generation; diagramRenderer = renderer
        diagramTask = Task { [weak self] in
            for diagram in diagrams {
                if Task.isCancelled { break }
                let result: Result<AgentMarkdownDiagrams.Drawing, Error>
                do { result = .success(try await renderer.render(diagram.source, width: self?.bounds.width ?? 600)) } catch { result = .failure(error) }
                guard let self, self.generation == token, !Task.isCancelled else { break }
                // Keep the same one-character attachment, ranges, selection and
                // visible reading position while async diagram heights change.
                let visible = text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
                let layout = text.layoutManager!, container = text.textContainer!
                let glyph = layout.glyphIndex(for: visible.origin, in: container), character = layout.characterIndexForGlyph(at: min(glyph, max(0, layout.numberOfGlyphs - 1)))
                let oldRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: glyph < layout.numberOfGlyphs ? 1 : 0), in: container)
                let offset = scroll.contentView.bounds.minY - oldRect.minY
                switch result {
                case .success(let drawing): drawings[diagram.range.location] = drawing; diagram.attachment.image = drawing.image
                case .failure(let error):
                    let message = String(error.localizedDescription.prefix(160)); diagramErrors[diagram.range.location] = message
                    diagram.attachment.image = AgentMarkdownDiagrams.statusImage("图表无法预览 · 查看原文")
                    text.textStorage?.addAttribute(.toolTip, value: message, range: diagram.range)
                }
                resizeImages(); layout.ensureLayout(for: container)
                let height = max(scroll.contentSize.height, layout.usedRect(for: container).maxY + text.textContainerInset.height * 2)
                text.setFrameSize(NSSize(width: text.frame.width, height: height))
                let currentGlyph = layout.glyphIndexForCharacter(at: character), rect = layout.boundingRect(forGlyphRange: NSRange(location: currentGlyph, length: 1), in: container)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + offset))); scroll.reflectScrolledClipView(scroll.contentView)
                scheduleReveal()
            }
            renderer.stop()
            if let self, self.generation == token { self.diagramRenderer = nil; self.diagramTask = nil }
        }
    }
    func waitForDiagrams() async { await diagramTask?.value }
    var editingCheckState: [String: Any] {
        guard ["--markdown-edit-check", "--file-conflict-check", "--text-encoding-check"].contains(where: CommandLine.arguments.contains) else { return [:] }
        return ["canEdit": canEdit?() == true, "editButtonVisible": !edit.isHidden, "isEditing": isEditing, "activeEditor": inlineEditor != nil, "diagramImages": drawings.values.map { String(describing: ObjectIdentifier($0.image)) }.sorted(), "diagramErrors": diagramErrors.count]
    }
    func textViewDidChangeSelection(_ notification: Notification) { selectionAction.update() }
    func undoManager(for view: NSTextView) -> UndoManager? { edits }
    private func openDiagram(_ index: Int) -> Bool {
        guard let drawing = drawings[index] else { return false }; selectionAction.update(); diagramWindow = AgentMarkdownDiagramWindow(drawing); diagramWindow?.showWindow(nil); diagramWindow?.window?.makeKeyAndOrderFront(nil); return true
    }
    @objc private func selectHeading() {
        do { try finishEditing() } catch { onEditError?(error.localizedDescription); return }
        guard let headings = document?.headings, headings.indices.contains(outline.indexOfSelectedItem - 1) else { return }
        pendingAnchor = headings[outline.indexOfSelectedItem - 1].range; scheduleReveal()
    }
    @discardableResult func navigate(_ fragment: String?) -> Bool {
        guard let fragment, let headings = document?.headings, let index = headings.firstIndex(where: { $0.anchor == fragment }) else { return false }
        outline.selectItem(at: index + 1); pendingAnchor = headings[index].range; scheduleReveal(); return true
    }
    func checkHeadingVisible(_ anchor: String) -> Bool {
        guard let range = document?.headings.first(where: { $0.anchor == anchor })?.range, let layout = text.layoutManager, let container = text.textContainer else { return false }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return scroll.documentVisibleRect.contains(NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y))
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        if url.isFileURL, url.path == file?.path, navigate(AgentMarkdownDocument.fragment(url)) { return true }
        onLink?(url); return true
    }
}

// Source citations stay inside a read-only native viewer. Opening a document
// never grants a new workspace or executes a URL scheme from its contents.
@MainActor final class AgentMarkdownSourceWindow: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    private let files: AgentFiles, reader = AgentMarkdownReader(), text = AgentMarkdownTextView(), label = NSTextField(labelWithString: "")
    private let sourceAdd = NSButton(title: "加入任务", target: nil, action: nil)
    private lazy var sourceSelection = AgentMarkdownSelectionAction(text: text, button: sourceAdd) { [weak self] in guard let self, !self.scroll.isHidden, let file = self.file else { return nil }; return (file, self.files.root.path) }
    var onAddSelection: ((AgentMarkdownSelection) throws -> Void)? { didSet { reader.onAddSelection = onAddSelection; sourceSelection.onAdd = onAddSelection; switchMode() } }
    var canAddSelection: (() -> Bool)? { didSet { reader.canAddSelection = canAddSelection; sourceSelection.canAdd = canAddSelection } }
    private let back = NSButton(title: "返回", target: nil, action: nil), reload = NSButton(title: "刷新", target: nil, action: nil), mode = NSSegmentedControl(labels: ["预览", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private var history: [URL] = [], file: URL?
    private var videoWindow: AgentVideoWindow?
    private let encodingMenu = NSPopUpButton()
    private var encodings: [String: AgentTextEncoding] = [:], requestedEncoding: AgentTextEncoding?, currentFormat: AgentTextFormat?
    init(workspace: String, target: URL) throws {
        files = try AgentFiles(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "来源"; window.appearance = NSAppearance(named: .aqua); window.minSize = NSSize(width: 500, height: 350); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let view = NSView(); window.contentView = view
        text.isEditable = false; text.isRichText = false; text.delegate = self; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.textContainerInset = NSSize(width: 16, height: 14); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel("来源原文")
        scroll.documentView = text; scroll.hasVerticalScroller = true
        label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        back.target = self; back.action = #selector(goBack); mode.target = self; mode.action = #selector(switchMode); mode.selectedSegment = 0
        reload.target = self; reload.action = #selector(refreshFile)
        AgentTextEncoding.prepareMenu(encodingMenu); encodingMenu.target = self; encodingMenu.action = #selector(reopenEncoding)
        reader.onLink = { [weak self] url in self?.follow(url) }
        let toolbar = NSStackView(views: [back, label, NSView(), sourceAdd, reload, mode]); toolbar.spacing = 8; sourceSelection.update()
        for child in [toolbar, scroll, reader, encodingMenu] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), encodingMenu.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), encodingMenu.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: encodingMenu.topAnchor, constant: -8), reader.topAnchor.constraint(equalTo: scroll.topAnchor), reader.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), reader.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), reader.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)])
        try open(target)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func open(_ target: URL, remember: Bool = true) throws {
        let safe = try AgentMarkdownDocument.target(target, document: file ?? files.root.appendingPathComponent("index.md"), files: files)
        guard safe.isFileURL else { throw PetError("请选择项目文件") }
        let data = try files.readData(try files.resolve(safe.path))
        let document: AgentTextFile
        do { document = try AgentTextFile.decode(data, encoding: encodings[safe.path]) }
        catch {
            guard AgentTextEncoding.canReopen(safe) else { throw PetError("此文件不能作为文本预览") }
            if remember, let file { history.append(file) }; file = safe; requestedEncoding = encodings[safe.path]; currentFormat = nil
            text.string = ""; reader.clear(); mode.isHidden = true; window?.title = files.relative(safe); label.stringValue = error.localizedDescription; label.toolTip = safe.path; back.isEnabled = !history.isEmpty
            AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: nil); switchMode(); return
        }
        if remember, let file { history.append(file) }; file = safe; requestedEncoding = encodings[safe.path]
        showDocument(document, file: safe)
    }
    private func showDocument(_ document: AgentTextFile, file safe: URL) {
        let value = document.text; currentFormat = document.format; text.string = value
        AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: currentFormat)
        let fragment = AgentMarkdownDocument.fragment(safe)
        window?.title = files.relative(safe); label.stringValue = files.relative(safe) + (fragment.map { " · " + $0 } ?? ""); label.toolTip = safe.path
        back.isEnabled = !history.isEmpty; mode.isHidden = !["md", "markdown"].contains(safe.pathExtension.lowercased()); mode.selectedSegment = 0
        if mode.isHidden { reader.clear() } else { reader.show(value, file: safe, workspace: files.root.path) }; switchMode()
        if let range = AgentMarkdownDocument.lineRange(fragment, in: value) {
            mode.selectedSegment = 1; switchMode()
            DispatchQueue.main.async { [weak self] in guard let self, self.file == safe, self.text.string == value else { return }; self.text.setSelectedRange(range); AgentMarkdownDocument.reveal(range, in: self.text) }
        }
        else if !mode.isHidden { _ = reader.navigate(fragment) }
    }
    @objc private func reopenEncoding() {
        guard let file else { return }; let chosen = AgentTextEncoding.selection(encodingMenu)
        do {
            let safe = try files.resolve(file.path); guard safe.path == file.path else { throw PetError("文件位置已变化") }
            let data = try files.readData(safe), document = try AgentTextFile.decode(data, encoding: chosen)
            encodings[file.path] = chosen; requestedEncoding = chosen; showDocument(document, file: file)
        } catch { label.stringValue = error.localizedDescription; AgentTextEncoding.updateMenu(encodingMenu, requested: requestedEncoding, format: currentFormat) }
    }
    private func follow(_ url: URL) {
        do {
            if ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            else if AgentVideoSnapshot.supports(url) {
                let target = try AgentMarkdownDocument.target(url, document: file ?? files.root.appendingPathComponent("index.md"), files: files)
                videoWindow?.close(); videoWindow = AgentVideoWindow(file: target, files: files); videoWindow?.showWindow(nil); videoWindow?.window?.makeKeyAndOrderFront(nil)
            } else { try open(url) }
        }
        catch { label.stringValue = error.localizedDescription }
    }
    @objc private func switchMode() { let preview = !mode.isHidden && mode.selectedSegment == 0; reader.isHidden = !preview; scroll.isHidden = preview; sourceSelection.update(); sourceAdd.isHidden = preview || onAddSelection == nil }
    func textViewDidChangeSelection(_ notification: Notification) { sourceSelection.update(); sourceAdd.isHidden = scroll.isHidden || onAddSelection == nil }
    func windowWillClose(_ notification: Notification) { videoWindow?.close(); videoWindow = nil; reader.clear(); text.string = "" }
    @objc private func refreshFile() { guard let file else { return }; do { try open(file, remember: false) } catch { label.stringValue = error.localizedDescription } }
    var encodingCheckState: [String: Any] {
        guard CommandLine.arguments.contains("--text-encoding-check") else { return [:] }
        return ["editable": text.isEditable, "encoding": currentFormat?.encoding.rawValue ?? "", "byteOrderMark": currentFormat?.bom ?? false, "textHash": AgentFiles.hash(Data(text.string.utf8)), "file": file?.path ?? ""]
    }
    @objc private func goBack() {
        guard let previous = history.popLast() else { return }
        do { try open(previous, remember: false) }
        catch { history.append(previous); label.stringValue = error.localizedDescription }
    }
}
