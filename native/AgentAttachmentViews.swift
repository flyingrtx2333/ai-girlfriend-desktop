import AppKit
import Quartz

@MainActor final class AgentAttachmentStrip: NSView {
    private let rows = NSStackView(), scroll = NSScrollView()
    private var height: NSLayoutConstraint!, files: [AgentAttachment] = [], signature = ""
    var onOpen: ((String) -> Void)?, onRemove: ((String) -> Void)?
    var maximumRows = 3 {
        didSet {
            if maximumRows != oldValue { updateHeight() }
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 2
        let document = FormDocumentView(); document.addSubview(rows); rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false; document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), rows.leadingAnchor.constraint(equalTo: document.leadingAnchor), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor), rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        height = heightAnchor.constraint(equalToConstant: 0); height.isActive = true; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: files.isEmpty ? NSView.noIntrinsicMetric : 220, height: NSView.noIntrinsicMetric) }
    func update(_ values: [AgentAttachment], removable: Bool, enabled: Bool = true) {
        let next = values.map { $0.id + "|" + $0.name }.joined(separator: "\n") + "|\(removable)|\(enabled)"
        guard next != signature else { return }; signature = next; files = values
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, file) in files.enumerated() {
            let open = NSButton(title: file.name.replacingOccurrences(of: "\n", with: "↵"), target: self, action: #selector(openFile(_:)))
            open.tag = index; open.isBordered = false; open.font = .systemFont(ofSize: 11); open.alignment = .left; open.cell?.lineBreakMode = .byTruncatingMiddle
            AgentFileIcons.bind(open, filename: file.name); open.toolTip = file.name
            open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除附件")!, target: self, action: #selector(removeFile(_:)))
            remove.isBordered = false; remove.tag = index; remove.isHidden = !removable; remove.isEnabled = enabled; remove.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let row = NSStackView(views: [open, remove]); row.spacing = 4; rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true; row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        isHidden = files.isEmpty; updateHeight(); invalidateIntrinsicContentSize()
    }
    private func updateHeight() { height.constant = CGFloat(min(maximumRows, files.count) * 26) }
    @objc private func openFile(_ sender: NSButton) { if files.indices.contains(sender.tag) { onOpen?(files[sender.tag].id) } }
    @objc private func removeFile(_ sender: NSButton) { if files.indices.contains(sender.tag) { onRemove?(files[sender.tag].id) } }
}

private final class AgentPreviewItem: NSObject, QLPreviewItem {
    let url: URL, title: String
    init(url: URL, title: String) { self.url = url; self.title = title }
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}

struct AgentAttachmentReadingTarget {
    let part: Int
    let line: Int?
}

@MainActor final class AgentAttachmentWindow: AgentSettingsPageController, NSWindowDelegate, NSTextViewDelegate {
    private struct ReadingState: Codable {
        var version = 1
        let attachmentID: String
        let hash: String
        let part: Int
        let showsText: Bool
        let viewport: AgentTextViewport?
    }

    private let store: AgentStore, file: AgentAttachment
    let taskID: String
    var attachmentID: String { file.id }
    var filename: String { file.name }
    private let mode = NSSegmentedControl(labels: ["预览", "文字"], trackingMode: .selectOne, target: nil, action: nil)
    private let number = AgentDialogTextField(string: "1"), stepper = NSStepper()
    private let title = NSTextField(labelWithString: ""), state = AgentSettingsStatusField("附件状态")
    private let partControls = NSStackView()
    private let body = NSView(), text = NSTextView(), textScroll = NSScrollView()
    private var preview: QLPreviewView?, item: AgentPreviewItem?, job: Task<Void, Never>?
    private var pdfPreview: PDFView?, pendingPDFPage: Int?
    private var started = false, textReady = false, applyingPosition = false
    private var pendingViewport: AgentTextViewport?, pendingLine: Int?
    private var textOnly: Bool { AgentDocument.textTypes.contains(file.fileExtension) }
    private var showsText: Bool { mode.selectedSegment == 1 }

    init(store: AgentStore, taskID: String, id: String, target: AgentAttachmentReadingTarget? = nil) throws {
        self.store = store; self.taskID = taskID; file = try AgentAttachments.record(store: store, taskID: taskID, id: id)
        _ = try AgentAttachments.source(store: store, taskID: taskID, id: id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = file.name; window.minSize = NSSize(width: 410, height: 370); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        mode.selectedSegment = textOnly ? 1 : 0; mode.target = self; mode.action = #selector(modeChanged)
        mode.controlSize = .small; mode.isHidden = textOnly; mode.setAccessibilityLabel("附件显示方式")
        number.integerValue = 1; number.alignment = .center; number.font = .systemFont(ofSize: 12); number.outlined = true
        number.widthAnchor.constraint(equalToConstant: 44).isActive = true; number.target = self; number.action = #selector(numberChanged)
        number.setAccessibilityLabel("附件部分编号")
        stepper.minValue = 1; stepper.maxValue = Double(max(1, file.totalParts)); stepper.integerValue = 1
        stepper.target = self; stepper.action = #selector(stepChanged); stepper.setAccessibilityLabel("切换附件部分")
        title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.drawsBackground = false
        text.textColor = .labelColor; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 2, height: 8); text.delegate = self; text.setAccessibilityLabel("附件正文")
        textScroll.documentView = text; textScroll.hasVerticalScroller = true; textScroll.drawsBackground = false
        textScroll.borderType = .noBorder; textScroll.scrollerStyle = .overlay
        textScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: textScroll.contentView)
        body.addSubview(textScroll); textScroll.translatesAutoresizingMaskIntoConstraints = false
        let count = NSTextField(labelWithString: "/ \(file.totalParts)")
        count.font = .systemFont(ofSize: 12); count.textColor = AgentWorkbenchTheme.secondaryText
        for control in [title, number, count, stepper] { partControls.addArrangedSubview(control) }
        partControls.spacing = 8; partControls.alignment = .centerY
        let header = NSStackView(views: [mode, NSView(), partControls]); header.spacing = 8
        header.isHidden = textOnly && file.totalParts <= 1
        let column = NSStackView(views: [header, body, state]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 8
        content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for row in [header, body, state] { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            textScroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            textScroll.topAnchor.constraint(equalTo: body.topAnchor),
            textScroll.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        if let target { open(target) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func settingsDidAppear() {
        if !started { started = true; loadPart() }
        pageDidLayout()
    }
    func windowDidBecomeKey(_ notification: Notification) { settingsDidAppear() }
    func windowWillClose(_ notification: Notification) { releaseReader() }
    override func settingsWillLeave() { releaseReader() }
    private func releaseReader() {
        job?.cancel(); job = nil; textReady = false
        closePreview(); text.string = ""; pendingViewport = nil; pendingLine = nil
    }
    private func closePreview() {
        preview?.close(); preview?.removeFromSuperview(); preview = nil; item = nil
        if let pdfPreview {
            NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: pdfPreview)
            pdfPreview.removeFromSuperview(); self.pdfPreview = nil
        }
        pendingPDFPage = nil
    }
    private func setPart(_ part: Int) {
        number.integerValue = min(max(1, part), max(1, file.totalParts)); stepper.integerValue = number.integerValue
    }
    func open(_ target: AgentAttachmentReadingTarget) {
        pendingViewport = nil; pendingLine = target.line
        setPart(target.part)
        mode.selectedSegment = 1
        if started { loadPart() }
    }
    private func choosePart(_ part: Int) {
        if pdfPreview != nil {
            setPart(part); pendingPDFPage = number.integerValue; pageDidLayout()
        } else { open(.init(part: part, line: nil)) }
    }
    @objc private func numberChanged() { choosePart(number.integerValue) }
    @objc private func stepChanged() { choosePart(stepper.integerValue) }
    @objc private func modeChanged() { pendingViewport = nil; pendingLine = nil; loadPart() }
    @objc private func scrolled() { if textReady && !applyingPosition { onSettingsRecoveryChange?() } }
    func textViewDidChangeSelection(_ notification: Notification) { scrolled() }

    private func loadPart() {
        job?.cancel(); textReady = false
        let selected = number.integerValue
        onSettingsRecoveryChange?()
        do {
            let url = try AgentAttachments.source(store: store, taskID: taskID, id: file.id)
            updatePartTitle(selected)
            partControls.isHidden = file.totalParts <= 1 || !showsText && file.fileExtension != "pdf"
            state.stringValue = file.partial ? "部分内容已提取" : ""
            if !showsText {
                if file.fileExtension == "pdf" {
                    try showPDF(url, page: selected)
                    return
                }
                if preview == nil, let view = QLPreviewView(frame: body.bounds, style: .normal) {
                    preview = view; view.autostarts = true; view.shouldCloseWithWindow = true
                    installPreview(view)
                }
                if let preview {
                    item = AgentPreviewItem(url: url, title: file.name); preview.previewItem = item
                    textScroll.isHidden = true; return
                }
                mode.selectedSegment = 1
                partControls.isHidden = file.totalParts <= 1
            }
            closePreview(); textScroll.isHidden = false; text.string = ""; state.stringValue = "读取中…"
            job = Task { [weak self] in
                guard let self else { return }
                do {
                    let part = try await AgentAttachments.part(store: store, taskID: taskID, id: file.id, number: selected)
                    try Task.checkCancellation()
                    text.string = part.text.isEmpty ? "未提取到文字" : part.text
                    text.setSelectedRange(NSRange(location: 0, length: 0))
                    textScroll.contentView.scroll(to: .zero); textScroll.reflectScrolledClipView(textScroll.contentView)
                    title.stringValue = part.title; title.toolTip = part.title
                    let notes = [part.ocr == true ? "本机 OCR" : nil, file.partial || part.partial ? "部分内容已提取" : nil].compactMap { $0 }
                    state.stringValue = (notes + (file.notes ?? [])).joined(separator: " · ")
                    textReady = true
                    presentingWindow?.contentView?.layoutSubtreeIfNeeded(); pageDidLayout(); onSettingsRecoveryChange?()
                } catch { if !Task.isCancelled { showError(error) } }
            }
        } catch { showError(error) }
    }
    private func updatePartTitle(_ part: Int) {
        title.stringValue = file.partTitles?.indices.contains(part - 1) == true ? file.partTitles![part - 1] : "第 \(part) 部分"
        title.toolTip = title.stringValue
    }
    private func installPreview(_ view: NSView) {
        body.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor), view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
    }
    private func showPDF(_ url: URL, page part: Int) throws {
        guard let document = PDFDocument(url: url), !document.isLocked, document.page(at: part - 1) != nil else { throw PetError("PDF 无法读取或页码无效") }
        closePreview(); textScroll.isHidden = true
        let view = PDFView(); view.displayMode = .singlePage; view.autoScales = true
        view.setAccessibilityLabel("附件 PDF 预览")
        pdfPreview = view; pendingPDFPage = part
        NotificationCenter.default.addObserver(self, selector: #selector(pdfPageChanged), name: .PDFViewPageChanged, object: view)
        view.document = document; installPreview(view)
        presentingWindow?.contentView?.layoutSubtreeIfNeeded(); pageDidLayout()
    }
    @objc private func pdfPageChanged() {
        guard pendingPDFPage == nil, let view = pdfPreview, let document = view.document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        guard (0..<max(1, file.totalParts)).contains(index), index + 1 != number.integerValue else { return }
        let part = index + 1
        setPart(part); updatePartTitle(part); onSettingsRecoveryChange?()
    }
    private func showError(_ error: Error) {
        closePreview(); text.string = ""; textScroll.isHidden = false; textReady = false
        state.stringValue = error.localizedDescription; state.textColor = AgentDialogStyle.error
    }

    override func pageDidLayout() {
        if isPageVisible, let part = pendingPDFPage, let view = pdfPreview, view.bounds.width > 0, view.bounds.height > 0,
           let target = view.document?.page(at: part - 1) {
            view.go(to: target); pendingPDFPage = nil
            updatePartTitle(part); onSettingsRecoveryChange?()
        }
        guard textReady, showsText, isPageVisible, textScroll.contentSize.width > 0, textScroll.contentSize.height > 0,
              pendingViewport != nil || pendingLine != nil else { return }
        applyingPosition = true
        defer { applyingPosition = false }
        if let viewport = pendingViewport {
            if viewport.apply(to: text) { pendingViewport = nil }
            else if !viewport.matches(text) { state.stringValue = "附件文字已变化，原阅读位置无法应用" }
        }
        if let line = pendingLine {
            pendingLine = nil
            let lines = text.string.components(separatedBy: "\n")
            guard lines.indices.contains(line - 1) else { return }
            let location = lines.prefix(line - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
            let range = NSRange(location: location, length: (lines[line - 1] as NSString).length)
            text.window?.makeFirstResponder(text); text.setSelectedRange(range); text.scrollRangeToVisible(range)
        }
    }
    func captureWorkspaceRecovery() throws -> AgentWorkspaceRecovery.Page {
        let viewport = try pendingViewport ?? (textReady && showsText ? AgentTextViewport(text) : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = ReadingState(attachmentID: file.id, hash: file.sha256, part: number.integerValue, showsText: showsText, viewport: viewport)
        return .init(taskID: taskID, kind: "attachment", state: try encoder.encode(value), dirty: false, asset: nil)
    }
    func restoreWorkspaceRecovery(_ page: AgentWorkspaceRecovery.Page) throws {
        guard page.kind == "attachment", page.taskID == taskID, !page.dirty, page.asset == nil,
              let raw = try JSONSerialization.jsonObject(with: page.state) as? [String: Any],
              Set(raw.keys).isSubset(of: ["version", "attachmentID", "hash", "part", "showsText", "viewport"]) else {
            throw PetError("附件阅读状态与原任务不符")
        }
        if let viewport = raw["viewport"] { try AgentTextViewport.validateObject(viewport) }
        let value = try JSONDecoder().decode(ReadingState.self, from: page.state)
        guard value.version == 1, value.attachmentID == file.id, value.hash == file.sha256,
              (1...max(1, file.totalParts)).contains(value.part), value.viewport?.valid != false,
              value.viewport == nil || value.showsText, !textOnly || value.showsText else {
            throw PetError("附件内容或阅读位置已变化")
        }
        setPart(value.part); mode.selectedSegment = value.showsText ? 1 : 0; pendingViewport = value.viewport
    }

    func workspaceReadback() async -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        await job?.value
        presentingWindow?.contentView?.layoutSubtreeIfNeeded(); pageDidLayout()
        let range = text.selectedRange(), raw = text.string as NSString
        let selected = NSMaxRange(range) <= raw.length ? raw.substring(with: range) : ""
        let pdfPart = pdfPreview.flatMap { view in view.currentPage.flatMap { view.document?.index(for: $0) }.map { $0 + 1 } }
        return ["part": number.integerValue, "mode": showsText ? "text" : "preview", "text": String(text.string.prefix(1000)),
                "selection": selected, "scrollY": Double(textScroll.contentView.bounds.minY), "readingWidth": Double(body.bounds.width), "readingHeight": Double(body.bounds.height),
                "previewPDFPart": pdfPart as Any? ?? NSNull(), "previewPDFText": pdfPreview?.currentPage?.string ?? "",
                "visible": isPageVisible, "readOnly": !text.isEditable, "status": state.stringValue]
    }

    func checkChoosePart(_ part: Int) {
        guard AgentTaskWorkspace.readbackEnabled else { return }
        number.integerValue = part; numberChanged()
    }

    func checkText(_ expected: String, output: URL) async -> Bool {
        mode.selectedSegment = 1; loadPart(); await job?.value
        saveView(output.appendingPathComponent("attachment-preview.png"))
        return text.string.contains(expected) && !textScroll.isHidden && !text.isEditable
    }
    func captureQuickLook(_ output: URL) async {
        mode.selectedSegment = 0; loadPart()
        try? await Task.sleep(for: .milliseconds(1200))
        saveView(output.appendingPathComponent("attachment-quicklook.png"))
    }
    private func saveView(_ output: URL) {
        presentingWindow?.contentView?.layoutSubtreeIfNeeded()
        if let view = pageContentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
    }
}
