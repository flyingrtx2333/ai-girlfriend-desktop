import AppKit
import Quartz

@MainActor final class AgentAttachmentStrip: NSView {
    private let rows = NSStackView(), scroll = NSScrollView()
    private var height: NSLayoutConstraint!, files: [AgentAttachment] = [], signature = ""
    var onOpen: ((String) -> Void)?, onRemove: ((String) -> Void)?
    var maximumRows = 3
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
        isHidden = files.isEmpty; height.constant = CGFloat(min(maximumRows, files.count) * 26); invalidateIntrinsicContentSize()
    }
    @objc private func openFile(_ sender: NSButton) { if files.indices.contains(sender.tag) { onOpen?(files[sender.tag].id) } }
    @objc private func removeFile(_ sender: NSButton) { if files.indices.contains(sender.tag) { onRemove?(files[sender.tag].id) } }
}

private final class AgentPreviewItem: NSObject, QLPreviewItem {
    let url: URL, title: String
    init(url: URL, title: String) { self.url = url; self.title = title }
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}

@MainActor final class AgentAttachmentWindow: NSWindowController, NSWindowDelegate {
    private let store: AgentStore, taskID: String, file: AgentAttachment
    private let mode = NSSegmentedControl(labels: ["预览", "文字"], trackingMode: .selectOne, target: nil, action: nil)
    private let number = NSTextField(string: "1"), stepper = NSStepper(), title = NSTextField(labelWithString: ""), state = NSTextField(labelWithString: "")
    private let body = NSView(), text = NSTextView(), textScroll = NSScrollView()
    private var preview: QLPreviewView?, item: AgentPreviewItem?, job: Task<Void, Never>?
    init(store: AgentStore, taskID: String, id: String, part: Int = 1) throws {
        self.store = store; self.taskID = taskID; file = try AgentAttachments.record(store: store, taskID: taskID, id: id)
        _ = try AgentAttachments.source(store: store, taskID: taskID, id: id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = file.name; window.minSize = NSSize(width: 640, height: 450); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        mode.selectedSegment = AgentDocument.textTypes.contains(file.fileExtension) ? 1 : 0; mode.target = self; mode.action = #selector(loadPart); mode.isHidden = AgentDocument.textTypes.contains(file.fileExtension)
        number.integerValue = min(max(1, part), max(1, file.totalParts)); number.alignment = .center; number.widthAnchor.constraint(equalToConstant: 54).isActive = true; number.target = self; number.action = #selector(numberChanged)
        stepper.minValue = 1; stepper.maxValue = Double(max(1, file.totalParts)); stepper.integerValue = number.integerValue; stepper.target = self; stepper.action = #selector(stepChanged)
        number.isEnabled = file.totalParts > 1; stepper.isEnabled = number.isEnabled
        title.font = .systemFont(ofSize: 12); title.lineBreakMode = .byTruncatingMiddle
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 14, height: 14)
        textScroll.documentView = text; textScroll.hasVerticalScroller = true; body.addSubview(textScroll); textScroll.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [mode, NSView(), title, number, NSTextField(labelWithString: "/ \(file.totalParts)"), stepper]); header.spacing = 8
        for view in [header, body, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), body.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -10), state.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), state.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12), textScroll.leadingAnchor.constraint(equalTo: body.leadingAnchor), textScroll.trailingAnchor.constraint(equalTo: body.trailingAnchor), textScroll.topAnchor.constraint(equalTo: body.topAnchor), textScroll.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
        loadPart()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { job?.cancel(); preview?.close(); preview = nil; item = nil; text.string = "" }
    @objc private func numberChanged() { number.integerValue = min(max(1, number.integerValue), max(1, file.totalParts)); stepper.integerValue = number.integerValue; mode.selectedSegment = 1; loadPart() }
    @objc private func stepChanged() { number.integerValue = stepper.integerValue; mode.selectedSegment = 1; loadPart() }
    @objc private func loadPart() {
        job?.cancel(); let selected = number.integerValue
        do {
            let url = try AgentAttachments.source(store: store, taskID: taskID, id: file.id)
            title.stringValue = file.partTitles?.indices.contains(selected - 1) == true ? file.partTitles![selected - 1] : "第 \(selected) 部分"
            state.stringValue = file.partial ? "部分内容已提取" : ""
            if mode.selectedSegment == 0 {
                if preview == nil, let view = QLPreviewView(frame: body.bounds, style: .normal) {
                    preview = view; view.autostarts = true; view.shouldCloseWithWindow = true; body.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: body.leadingAnchor), view.trailingAnchor.constraint(equalTo: body.trailingAnchor), view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
                }
                if let preview { item = AgentPreviewItem(url: url, title: file.name); preview.previewItem = item; preview.isHidden = false; textScroll.isHidden = true; return }
                mode.selectedSegment = 1; state.stringValue = "系统预览不可用"
            }
            preview?.close(); preview?.removeFromSuperview(); preview = nil; item = nil
            textScroll.isHidden = false; text.string = "读取中…"
            job = Task { [weak self] in
                guard let self else { return }
                do { let part = try await AgentAttachments.part(store: store, taskID: taskID, id: file.id, number: selected); guard !Task.isCancelled else { return }; text.string = part.text.isEmpty ? "未提取到文字" : part.text; title.stringValue = part.title; state.stringValue = part.ocr == true ? "本机 OCR" : (file.notes ?? []).joined(separator: " · ") }
                catch { if !Task.isCancelled { text.string = ""; state.stringValue = error.localizedDescription } }
            }
        } catch { state.stringValue = error.localizedDescription }
    }
    func checkText(_ expected: String, output: URL) async -> Bool {
        mode.selectedSegment = 1; loadPart(); await job?.value
        window?.contentView?.layoutSubtreeIfNeeded()
        if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("attachment-preview.png")) }
        return text.string.contains(expected) && !textScroll.isHidden && !text.isEditable
    }
    func captureQuickLook(_ output: URL) async {
        showWindow(nil); mode.selectedSegment = 0; loadPart()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("attachment-quicklook.png")) }
    }
}
