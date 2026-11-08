import AppKit

@MainActor final class AgentMarkdownReader: NSView, NSTextViewDelegate {
    let text = NSTextView()
    private let outline = NSPopUpButton(), scroll = NSScrollView()
    private(set) var document: AgentMarkdownDocument?
    private var file: URL?, source = "", workspace: String?, renderedWidth: CGFloat = 0
    private var pendingAnchor: NSRange?, revealScheduled = false
    var onLink: ((URL) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.importsGraphics = false; text.delegate = self
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 18, height: 16)
        text.setAccessibilityLabel("Markdown 预览")
        outline.target = self; outline.action = #selector(selectHeading); outline.setAccessibilityLabel("章节目录")
        scroll.documentView = text; scroll.hasVerticalScroller = true
        for view in [outline, scroll] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([outline.topAnchor.constraint(equalTo: topAnchor, constant: 4), outline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), outline.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12), outline.widthAnchor.constraint(lessThanOrEqualToConstant: 380), scroll.topAnchor.constraint(equalTo: outline.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func clear() { source = ""; file = nil; workspace = nil; document = nil; pendingAnchor = nil; outline.removeAllItems(); text.string = "" }
    func show(_ source: String, file: URL, workspace: String) {
        pendingAnchor = nil; self.source = source; self.file = file; self.workspace = workspace; outline.selectItem(at: 0); render()
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    override func layout() {
        super.layout()
        if !isHidden, abs(bounds.width - renderedWidth) > 8 { resizeImages() }
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
    private func render() {
        guard let file, let files = try? AgentFiles(workspace: workspace) else { return }
        let selected = outline.indexOfSelectedItem, origin = scroll.contentView.bounds.origin
        renderedWidth = bounds.width
        let result = AgentMarkdownDocument.render(source, document: file, files: files, width: max(220, bounds.width)); document = result
        text.textStorage?.setAttributedString(result.body)
        outline.removeAllItems(); outline.addItem(withTitle: "章节")
        for heading in result.headings { outline.addItem(withTitle: String(repeating: "  ", count: max(0, heading.level - 1)) + heading.title) }
        outline.isEnabled = !result.headings.isEmpty
        outline.selectItem(at: min(max(0, selected), outline.numberOfItems - 1))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func selectHeading() {
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
@MainActor final class AgentMarkdownSourceWindow: NSWindowController {
    private let files: AgentFiles, reader = AgentMarkdownReader(), text = NSTextView(), label = NSTextField(labelWithString: "")
    private let back = NSButton(title: "返回", target: nil, action: nil), reload = NSButton(title: "刷新", target: nil, action: nil), mode = NSSegmentedControl(labels: ["预览", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private var history: [URL] = [], file: URL?
    init(workspace: String, target: URL) throws {
        files = try AgentFiles(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "来源"; window.appearance = NSAppearance(named: .aqua); window.minSize = NSSize(width: 500, height: 350); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        let view = NSView(); window.contentView = view
        text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.textContainerInset = NSSize(width: 16, height: 14); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel("来源原文")
        scroll.documentView = text; scroll.hasVerticalScroller = true
        label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize: 12)
        back.target = self; back.action = #selector(goBack); mode.target = self; mode.action = #selector(switchMode); mode.selectedSegment = 0
        reload.target = self; reload.action = #selector(refreshFile)
        reader.onLink = { [weak self] url in self?.follow(url) }
        let toolbar = NSStackView(views: [back, label, NSView(), reload, mode]); toolbar.spacing = 8
        for child in [toolbar, scroll, reader] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), reader.topAnchor.constraint(equalTo: scroll.topAnchor), reader.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), reader.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), reader.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)])
        try open(target)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func open(_ target: URL, remember: Bool = true) throws {
        let safe = try AgentMarkdownDocument.target(target, document: file ?? files.root.appendingPathComponent("index.md"), files: files)
        guard safe.isFileURL else { throw PetError("请选择项目文件") }
        let data = try files.readData(try files.resolve(safe.path))
        guard !data.contains(0), let value = String(data: data, encoding: .utf8) else { throw PetError("此文件不能作为文本预览") }
        if remember, let file { history.append(file) }; file = safe; text.string = value
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
    private func follow(_ url: URL) {
        do { if ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) } else { try open(url) } }
        catch { label.stringValue = error.localizedDescription }
    }
    @objc private func switchMode() { let preview = !mode.isHidden && mode.selectedSegment == 0; reader.isHidden = !preview; scroll.isHidden = preview }
    @objc private func refreshFile() { guard let file else { return }; do { try open(file, remember: false) } catch { label.stringValue = error.localizedDescription } }
    @objc private func goBack() {
        guard let previous = history.popLast() else { return }
        do { try open(previous, remember: false) }
        catch { history.append(previous); label.stringValue = error.localizedDescription }
    }
}
