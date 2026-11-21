import AppKit

@MainActor final class AgentMarkdownReader: NSView, NSTextViewDelegate, NSMenuDelegate {
    let text = AgentMarkdownTextView()
    private let outline = NSPopUpButton(), scroll = NSScrollView()
    private let addSelection = NSButton(title: "加入任务", target: nil, action: nil)
    private let retryImages = NSButton(title: "重试图片", target: nil, action: nil)
    private let edit = NSButton(title: "编辑", target: nil, action: nil), edits = UndoManager()
    private let tableActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private var tableCell: (table: Int, row: Int, column: Int)?
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
    var onViewportChange: (() -> Void)?
    private var pendingViewRecovery: ViewRecovery?, applyingViewRecovery = false, viewRecoveryScheduled = false
    private var rememberedPreviewFocus = false, rememberedEditorFocus = false
    private var viewActivationScheduled = false, forceViewActivation = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.importsGraphics = false; text.delegate = self
        text.onDoubleClickAttachment = { [weak self] index in self?.openDiagram(index) ?? false }
        text.onPreviewEditClick = { [weak self] point in self?.beginEditing(at: point) ?? false }; text.previewUndoManager = edits; text.allowsUndo = true; edits.levelsOfUndo = 20
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 18, height: 16)
        text.setAccessibilityLabel("Markdown 预览")
        outline.target = self; outline.action = #selector(selectHeading); outline.setAccessibilityLabel("章节目录")
        outline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outline.cell?.lineBreakMode = .byTruncatingTail
        edit.target = self; edit.action = #selector(toggleEditing); edit.bezelStyle = .texturedRounded; edit.controlSize = .small; edit.setAccessibilityLabel("编辑 Markdown 预览"); edit.toolTip = "就地编辑；Command+Return 完成，Esc 取消本次修改"
        retryImages.target = self; retryImages.action = #selector(reloadImages); retryImages.bezelStyle = .texturedRounded; retryImages.controlSize = .small
        tableActions.addItem(withTitle: "表格"); tableActions.controlSize = .small; tableActions.bezelStyle = .texturedRounded; tableActions.setAccessibilityLabel("表格操作")
        tableActions.menu?.autoenablesItems = false; tableActions.menu?.delegate = self
        for action in AgentMarkdownEditing.TableAction.allCases {
            if action == .columnBefore || action == .alignLeft { tableActions.menu?.addItem(.separator()) }
            let item = NSMenuItem(title: action.title, action: #selector(changeTable(_:)), keyEquivalent: ""); item.target = self; item.tag = action.rawValue
            tableActions.menu?.addItem(item)
        }
        scroll.documentView = text; scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        let toolbar = NSStackView(views: [outline, NSView(), retryImages, tableActions, edit, addSelection]); toolbar.spacing = 8
        for view in [toolbar, scroll] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), outline.widthAnchor.constraint(lessThanOrEqualToConstant: 380), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
        selectionAction.update(); updateEditingState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func clear() { pendingViewRecovery = nil; rememberedPreviewFocus = false; rememberedEditorFocus = false; inlineEditor?.removeFromSuperview(); inlineEditor = nil; tableCell = nil; isEditing = false; edits.removeAllActions(); cancelDiagrams(); diagramWindow?.close(); diagramWindow = nil; source = ""; file = nil; workspace = nil; document = nil; pendingAnchor = nil; outline.removeAllItems(); text.string = ""; selectionAction.update(); updateEditingState() }
    func show(_ source: String, file: URL, workspace: String, reuseIfUnchanged: Bool = false) {
        if reuseIfUnchanged, inlineEditor == nil, self.source == source, self.file == file, self.workspace == workspace, document != nil { isEditing = false; updateEditingState(); return }
        pendingViewRecovery = nil; inlineEditor?.removeFromSuperview(); inlineEditor = nil; tableCell = nil; isEditing = false; edits.removeAllActions(); cancelDiagrams(); pendingAnchor = nil; self.source = source; self.file = file; self.workspace = workspace; outline.selectItem(at: 0); render(); updateEditingState()
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    override func layout() {
        super.layout()
        if !isHidden, abs(bounds.width - renderedWidth) > 8 { resizeImages() }
        positionEditor()
        scheduleReveal()
        scheduleViewRecovery()
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
        retryImages.isHidden = !result.canRetryImages
        for diagram in result.diagrams { if let cached = cachedDrawings[diagram.source] { diagram.attachment.image = cached.image; drawings[diagram.range.location] = cached } }
        text.textStorage?.setAttributedString(result.body)
        AgentFileIcons.track(text)
        outline.removeAllItems(); outline.addItem(withTitle: "章节")
        for heading in result.headings { outline.addItem(withTitle: String(repeating: "  ", count: max(0, heading.level - 1)) + heading.title) }
        outline.isEnabled = !result.headings.isEmpty
        outline.selectItem(at: min(max(0, selected), outline.numberOfItems - 1))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        resizeImages(); renderDiagrams(result.diagrams.filter { drawings[$0.range.location] == nil }); selectionAction.update()
    }
    private func updateEditingState() {
        edit.isHidden = onSourceChanged == nil || file == nil; edit.isEnabled = isEditing || canEdit?() == true; edit.title = isEditing ? "完成" : "编辑"; selectionAction.update()
        retryImages.isHidden = document?.canRetryImages != true
        updateTableActions()
    }
    @objc private func reloadImages() {
        guard var document, let file, let files = try? AgentFiles(workspace: workspace) else { return }
        rememberViewportFocus()
        let viewport = try? AgentTextViewport(text)
        let editorWasVisible = inlineEditor.map { scroll.documentVisibleRect.intersects($0.frame) } ?? false
        applyingViewRecovery = true
        let changed = document.retryImages(document: file, files: files)
        self.document = document
        retryImages.isHidden = !document.canRetryImages
        if changed {
            resizeImages()
            _ = viewport?.apply(to: text, focus: false)
            positionEditor()
            if editorWasVisible, let editor = inlineEditor { _ = text.scrollToVisible(editor.frame) }
        }
        applyingViewRecovery = false
        if (changed || window?.firstResponder === retryImages) && (rememberedEditorFocus || rememberedPreviewFocus) {
            activateRememberedView()
        }
        viewChanged()
    }
    private func updateTableActions() {
        let table = tableCell.flatMap { try? AgentMarkdownEditing.table(in: source, at: $0.table) }
        if table == nil { tableCell = nil }
        tableActions.isHidden = !isEditing || tableCell == nil; tableActions.isEnabled = isEditing && canEdit?() == true
        guard let table, var cell = tableCell else { return }
        cell.row = min(cell.row, table.rows.count - 1); cell.column = min(cell.column, table.columns - 1); tableCell = cell
        for item in tableActions.itemArray.dropFirst() where !item.isSeparatorItem {
            guard let action = AgentMarkdownEditing.TableAction(rawValue: item.tag) else { continue }
            item.isEnabled = tableActions.isEnabled && (!(action == .rowBefore || action == .deleteRow) || cell.row > 0) && (action != .deleteColumn || table.columns > 1)
            let alignment = table.alignment[cell.column]
            item.state = (action == .alignLeft && alignment == .left || action == .alignCenter && alignment == .center || action == .alignRight && alignment == .right) ? .on : .off
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === tableActions.menu { updateTableActions() } }
    @objc private func changeTable(_ sender: NSMenuItem) {
        do {
            guard isEditing, canEdit?() == true, let cell = tableCell, let action = AgentMarkdownEditing.TableAction(rawValue: sender.tag) else { throw PetError("此文件当前只读，草稿已保留") }
            try finishEditing()
            guard canEdit?() == true else { throw PetError("此文件当前只读，草稿已保留") }
            let previous = source, change = try AgentMarkdownEditing.changingTable(in: source, at: cell.table, row: cell.row, column: cell.column, action: action)
            guard change.source != previous else { return }
            source = change.source; tableCell = (cell.table, change.row, change.column); onSourceChanged?(source); replacePreview()
            edits.registerUndo(withTarget: self) { reader in reader.restoreSource(previous) }; edits.setActionName(action.title)
            if let target = document?.regions.first(where: { $0.kind == .cell(table: cell.table, row: change.row, column: change.column) }) { text.setSelectedRange(target.display); text.scrollRangeToVisible(target.display) }
            window?.makeFirstResponder(text)
        } catch { onEditError?(error.localizedDescription) }
    }
    @objc private func toggleEditing() {
        defer { viewChanged() }
        do {
            if isEditing { try finishEditing(); isEditing = false; window?.makeFirstResponder(text) }
            else { guard canEdit?() == true else { throw PetError("此文件当前只读") }; isEditing = true }
            updateEditingState()
            if isEditing, source.isEmpty, let region = document?.regions.first { try beginEditing(region) }
        } catch { onEditError?(error.localizedDescription) }
    }
    private func tableBlock(for region: AgentMarkdownEditing.Region) -> NSTextBlock? {
        guard region.isCell, let storage = text.textStorage, region.display.location < storage.length,
              let style = storage.attribute(.paragraphStyle, at: region.display.location, effectiveRange: nil) as? NSParagraphStyle else { return nil }
        return style.textBlocks.first
    }
    private func regionRect(_ region: AgentMarkdownEditing.Region) -> NSRect {
        guard let layout = text.layoutManager, let container = text.textContainer, NSMaxRange(region.display) <= (text.string as NSString).length else { return .zero }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: region.display, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        if let block = tableBlock(for: region) {
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
    private func beginEditing(_ region: AgentMarkdownEditing.Region, base: String? = nil, restoring: Bool = false) throws {
        let editor = try AgentMarkdownInlineEditor(region: region, source: base ?? source); inlineEditor = editor
        editor.onViewportChange = { [weak self] in self?.viewChanged() }
        if case .cell(let table, let row, let column) = region.kind { tableCell = (table, row, column) } else { tableCell = nil }
        editor.onChange = { [weak self, weak editor] value in
            guard let self, let editor else { return }
            do { let next = try AgentMarkdownEditing.replacing(editor.region, in: editor.base, with: value); if source != next { pendingViewRecovery = nil; source = next; onSourceChanged?(next) } }
            catch { onEditError?(error.localizedDescription) }
            if editor.region.isCell, inlineEditor === editor {
                positionEditor()
                _ = text.scrollToVisible(editor.frame)
            }
        }
        editor.onFinish = { [weak self] commit, direction in
            guard let self else { return }
            let old = inlineEditor?.region.kind
            do {
                try finishEditing(commit: commit)
                if direction != 0, let old, let cells = document?.regions.filter({ $0.isCell }), let index = cells.firstIndex(where: { $0.kind == old }), cells.indices.contains(index + direction), case .cell(let table, _, _) = old, case .cell(let nextTable, _, _) = cells[index + direction].kind, table == nextTable { try beginEditing(cells[index + direction]) }
            } catch { onEditError?(error.localizedDescription) }
        }
        text.addSubview(editor); text.previewEditor = editor; positionEditor()
        if !restoring { _ = text.scrollToVisible(editor.frame); editor.focus() }
        selectionAction.update(); updateTableActions()
        viewChanged()
    }
    private func positionEditor() {
        guard let editor = inlineEditor else { return }
        let availableHeight = max(60, scroll.contentSize.height - 16)
        var rect = regionRect(editor.region)
        if case .cell(let table, _, _) = editor.region.kind, let block = tableBlock(for: editor.region), let layout = text.layoutManager {
            if editor.frame.width != rect.width {
                editor.setFrameSize(NSSize(width: rect.width, height: min(max(28, rect.height), availableHeight)))
            }
            let limit = min(160, max(60, availableHeight / 2))
            let insets = [NSRectEdge.minY, .maxY].reduce(CGFloat.zero) {
                $0 + block.width(for: .padding, edge: $1) + block.width(for: .border, edge: $1)
            }
            let height = max(0, min(limit, editor.fittingHeight) - insets)
            if block.value(for: .height) != height {
                // TextKit caches row geometry at the start of the table.
                block.setValue(height, type: .absoluteValueType, for: .height)
                let first = document?.regions.first(where: { $0.kind == .cell(table: table, row: 0, column: 0) })
                let range = NSUnionRange(first?.display ?? editor.region.display, editor.region.display)
                layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                rect = regionRect(editor.region)
            }
        }
        rect.size.height = min(max(28, rect.height), availableHeight)
        if editor.frame != rect { editor.frame = rect }
    }
    func finishEditing(commit: Bool = true) throws {
        guard let editor = inlineEditor else { return }; editor.commitInput()
        pendingViewRecovery = nil
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
        cancelDiagrams(); render(cachedImages: images, cachedDrawings: cached); updateTableActions()
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
                positionEditor(); scheduleReveal(); scheduleViewRecovery()
            }
            renderer.stop()
            if let self, self.generation == token { self.diagramRenderer = nil; self.diagramTask = nil }
        }
    }
    struct ViewRecovery: Codable, Equatable, Sendable {
        struct Editor: Codable, Equatable, Sendable {
            var base: String, value: String
            var location: Int, length: Int
            var table: Int?, row: Int?, column: Int?
            var viewport: AgentTextViewport
            var valid: Bool {
                let count = (base as NSString).length
                let cell = table == nil && row == nil && column == nil || table.map { (0...count).contains($0) } == true && row.map { (0...2_000_000).contains($0) } == true && column.map { (0...2_000_000).contains($0) } == true
                return base.utf8.count <= 2_000_000 && value.utf8.count <= 2_000_000 && !value.contains("\0") &&
                    location >= 0 && length >= 0 && location <= count && length <= count - location && cell && viewport.valid &&
                    viewport.count == (value as NSString).length && viewport.hash == AgentFiles.hash(Data(value.utf8))
            }
            var kind: AgentMarkdownEditing.Region.Kind {
                if let table, let row, let column { return .cell(table: table, row: row, column: column) }; return .block
            }
        }
        var version = 1
        var sourceHash: String
        var viewport: AgentTextViewport
        var editing: Bool
        var editor: Editor?
        var heading: Int? = nil
        var valid: Bool {
            version == 1 && sourceHash.count == 64 && sourceHash.allSatisfy { $0.isHexDigit && !$0.isUppercase } && viewport.valid &&
                editor?.valid != false && (editor == nil || editing) && (heading.map { (0...20_000).contains($0) } ?? true)
        }
        static func validateObject(_ raw: Any) throws {
            guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["version", "sourceHash", "viewport", "editing", "editor", "heading"]) else { throw PetError("Markdown 位置恢复格式不受支持，原记录已保留") }
            try AgentTextViewport.validateObject(value["viewport"] ?? NSNull())
            if let raw = value["editor"], !(raw is NSNull) {
                guard let editor = raw as? [String: Any], Set(editor.keys).isSubset(of: ["base", "value", "location", "length", "table", "row", "column", "viewport"]) else { throw PetError("Markdown 编辑位置恢复格式不受支持，原草稿已保留") }
                try AgentTextViewport.validateObject(editor["viewport"] ?? NSNull())
            }
        }
    }
    // Autosave reads the active editor. It must not turn a user's editing
    // pause into an implicit press of the Done button.
    func captureViewRecovery(source expected: String) throws -> ViewRecovery? {
        guard document != nil, source == expected else { return nil }
        rememberViewportFocus()
        if let editor = inlineEditor {
            let next = try AgentMarkdownEditing.replacing(editor.region, in: editor.base, with: editor.value)
            if source != next { pendingViewRecovery = nil; source = next; onSourceChanged?(next) }
        }
        if let pendingViewRecovery { return pendingViewRecovery }
        var editorState: ViewRecovery.Editor?
        if let editor = inlineEditor {
            var table: Int?, row: Int?, column: Int?
            if case .cell(let t, let r, let c) = editor.region.kind { table = t; row = r; column = c }
            var viewport = try editor.captureViewport(); viewport.focused = rememberedEditorFocus
            editorState = .init(base: editor.base, value: editor.value, location: editor.region.source.location, length: editor.region.source.length,
                table: table, row: row, column: column, viewport: viewport)
        }
        var viewport = try AgentTextViewport(text); viewport.focused = rememberedPreviewFocus
        let result = ViewRecovery(sourceHash: AgentFiles.hash(Data(source.utf8)), viewport: viewport, editing: isEditing, editor: editorState, heading: max(0, outline.indexOfSelectedItem))
        guard result.valid else { throw PetError("Markdown 编辑位置无效，原草稿已保留") }; return result
    }
    func restoreViewRecovery(_ value: ViewRecovery) throws {
        guard value.valid, value.sourceHash == AgentFiles.hash(Data(source.utf8)) else { throw PetError("Markdown 正文已变化，原阅读位置已保留") }
        applyingViewRecovery = true
        defer { applyingViewRecovery = false; scheduleViewRecovery() }
        if let saved = value.editor {
            let current = source; cancelDiagrams(); pendingAnchor = nil; source = saved.base; render(); source = current
            guard let region = document?.regions.first(where: { $0.source == NSRange(location: saved.location, length: saved.length) && $0.kind == saved.kind }),
                  try AgentMarkdownEditing.replacing(region, in: saved.base, with: saved.value) == current else { throw PetError("Markdown 原编辑段落已变化，原草稿已保留") }
            try beginEditing(region, base: saved.base, restoring: true)
            inlineEditor?.restoreValue(saved.value); inlineEditor?.setEditable(canEdit?() == true)
        }
        var restored = value
        if !value.viewport.matches(text) {
            if let viewport = try document?.migrateImageViewport(value.viewport, to: text) {
                restored.viewport = viewport
            } else {
                guard value.editor != nil, let region = inlineEditor?.region else {
                    throw PetError("Markdown 预览已变化，原阅读位置已保留")
                }
                // Missing images can change the preview text while the original edit still matches.
                var viewport = try AgentTextViewport(text)
                viewport.anchor = region.display.location
                viewport.offset = -16
                viewport.x = 0
                viewport.selections = [.init(location: viewport.anchor, length: 0)]
                viewport.focused = value.viewport.focused && value.editor?.viewport.focused != true
                restored.viewport = viewport
            }
        }
        if let heading = value.heading { guard heading < outline.numberOfItems else { throw PetError("Markdown 章节已变化，原阅读位置已保留") }; outline.selectItem(at: heading) }
        rememberedPreviewFocus = value.viewport.focused; rememberedEditorFocus = value.editor?.viewport.focused ?? false
        isEditing = value.editing; updateEditingState(); pendingViewRecovery = restored
    }
    func rememberViewportFocus() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor, pendingViewRecovery == nil, !viewActivationScheduled else { return }
        // Navigation controls can take focus before the page is captured.
        // Keep the last content target until another content target is focused.
        if inlineEditor?.hasInputFocus == true { rememberedPreviewFocus = false; rememberedEditorFocus = true }
        else if window?.firstResponder === text { rememberedPreviewFocus = true; rememberedEditorFocus = false }
    }
    func activateRememberedView(force: Bool = false) {
        forceViewActivation = forceViewActivation || force
        scheduleViewRecovery()
        guard forceViewActivation || rememberedPreviewFocus || rememberedEditorFocus, !viewActivationScheduled else { return }
        viewActivationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; let force = forceViewActivation; forceViewActivation = false
            defer { viewActivationScheduled = false }
            guard document != nil, window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
            window?.contentView?.layoutSubtreeIfNeeded(); positionEditor()
            applyPendingViewRecovery()
            guard pendingViewRecovery == nil, var viewport = try? AgentTextViewport(text) else { return }
            applyingViewRecovery = true
            defer { applyingViewRecovery = false }
            if let editor = inlineEditor, force || rememberedEditorFocus, var input = try? editor.captureViewport() {
                input.focused = true; _ = editor.restoreViewport(input)
                viewport.focused = false; _ = viewport.apply(to: text, focus: false); rememberedEditorFocus = true
            } else if force || rememberedPreviewFocus {
                viewport.focused = true; _ = viewport.apply(to: text); rememberedPreviewFocus = true
            }
            onViewportChange?()
        }
    }
    func prepareWorkspaceNavigation() throws {
        rememberViewportFocus()
        guard let editor = inlineEditor else { return }; editor.commitInput()
        let next = try AgentMarkdownEditing.replacing(editor.region, in: editor.base, with: editor.value)
        if source != next { source = next; onSourceChanged?(next) }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleViewRecovery() }
    func scheduleViewRecovery() {
        guard pendingViewRecovery != nil, !viewRecoveryScheduled, !applyingViewRecovery else { return }; viewRecoveryScheduled = true
        DispatchQueue.main.async { [weak self] in self?.viewRecoveryScheduled = false; self?.applyPendingViewRecovery() }
    }
    private func applyPendingViewRecovery() {
        guard let value = pendingViewRecovery, !applyingViewRecovery, window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0 else { return }
        applyingViewRecovery = true
        defer { applyingViewRecovery = false }
        window?.contentView?.layoutSubtreeIfNeeded(); positionEditor()
        guard value.editor.map({ inlineEditor?.restoreViewport($0.viewport) == true }) ?? true, value.viewport.apply(to: text) else { return }
        if let editor = inlineEditor, editor.region.isCell, value.editor?.viewport.focused == true,
           scroll.documentVisibleRect.intersects(editor.frame) { _ = text.scrollToVisible(editor.frame) }
        pendingViewRecovery = nil; onViewportChange?()
    }
    @objc private func viewportChanged(_ notification: Notification) { viewChanged() }
    private func viewChanged() { if !applyingViewRecovery, pendingViewRecovery == nil { rememberViewportFocus(); onViewportChange?() } }
    func waitForDiagrams() async { await diagramTask?.value }
    func checkViewRecovery(action: String, target: String, input: String?, selection: NSRange?, y: Double?, cell: Bool) throws {
        guard ["--workspace-text-viewport-check", "--workspace-text-viewport-ui"].contains(where: CommandLine.arguments.contains) else { return }
        if action == "retry-images" { reloadImages(); return }
        if action == "begin" {
            guard canEdit?() == true, let region = document?.regions.first(where: { $0.isCell == cell && (try? AgentMarkdownEditing.value($0, in: source).contains(target)) == true }) else { throw PetError("未找到公开编辑段落") }
            isEditing = true; try beginEditing(region); updateEditingState()
        }
        if let inlineEditor { try inlineEditor.checkRecoveryInput(input, insert: action == "insert", selection: selection, y: y) }
        else {
            let range = selection ?? (target.isEmpty ? nil : (text.string as NSString).range(of: target))
            if let range { guard range.location != NSNotFound else { throw PetError("未找到公开预览选区") }; text.setSelectedRange(range); window?.makeFirstResponder(text) }
            window?.contentView?.layoutSubtreeIfNeeded()
            if let y { scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
        }
    }
    func checkSourceHeading(_ title: String) throws {
        guard ["--workspace-source-recovery-check", "--workspace-source-recovery-ui"].contains(where: CommandLine.arguments.contains) else { return }
        guard let index = document?.headings.firstIndex(where: { $0.title == title }) else { throw PetError("公开来源章节未找到") }
        outline.selectItem(at: index + 1); selectHeading()
    }
    var viewportReadback: [String: Any] {
        ["location": text.selectedRange().location, "length": text.selectedRange().length, "y": Double(scroll.contentView.bounds.minY),
         "focused": window?.firstResponder === text, "editor": inlineEditor?.viewportReadback ?? [:], "editing": isEditing,
         "pending": pendingViewRecovery != nil]
    }
    var editingCheckState: [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled || ["--markdown-edit-check", "--file-conflict-check", "--text-encoding-check", "--markdown-table-check", "--wiki-tree-check", "--wiki-plan-check"].contains(where: CommandLine.arguments.contains) else { return [:] }
        return ["canEdit": canEdit?() == true, "editButtonVisible": !edit.isHidden, "isEditing": isEditing, "activeEditor": inlineEditor != nil, "tableMenuVisible": !tableActions.isHidden, "tableRow": tableCell?.row ?? -1, "tableColumn": tableCell?.column ?? -1, "tableActions": tableActions.itemArray.filter { !$0.isSeparatorItem }.map { ["title": $0.title, "enabled": $0.isEnabled, "checked": $0.state == .on] }, "diagramImages": drawings.values.map { String(describing: ObjectIdentifier($0.image)) }.sorted(), "diagramErrors": diagramErrors.count]
    }
    func textViewDidChangeSelection(_ notification: Notification) { selectionAction.update(); viewportChanged(notification) }
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
