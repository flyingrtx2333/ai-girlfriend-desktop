import AppKit

@MainActor class AgentSettingsReviewPage: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct ReadingLocation: Codable {
        var selected: String?
        var listY: Double
        var preview: AgentTextViewport?

        static func validateObject(_ value: Any) throws {
            let raw = try AgentSettingsRecovery.object(value, keys: ["selected", "listY", "preview"])
            if let preview = raw["preview"] { try AgentTextViewport.validateObject(preview) }
        }
        var valid: Bool {
            (selected?.count ?? 0) <= 60 && AgentSettingsRecovery.validScroll(listY) && preview?.valid != false
        }
    }
    private var sections: [(title: String, body: String)]
    private let list = NSTableView(), preview = NSTextView()
    private let index = NSScrollView(), detail = NSScrollView()
    private let chooser = NSPopUpButton()
    private lazy var compactChooser = AgentSettingsPopupFrame(chooser, outlined: true, maximumWidth: nil)
    private let header = NSStackView(), status = AgentSettingsStatusField("审阅操作错误")
    private let apply = AgentDialogButton(title: "", target: nil, action: nil)
    private var working = false, finished = false, contentReady = true, reloading = false
    private var displayedTitle: String?, positions: [String: AgentTextViewport] = [:]
    private var pendingReading: ReadingLocation?, readingScheduled = false
    var selectedSection: String? { displayedTitle }
    var onApply: (() throws -> Void)? { didSet { updateApply() } }
    var onApplied: (() -> Void)?
    override var minimumSettingsContentHeight: CGFloat { 228 }
    override var usesInternalScrolling: Bool { true }

    init(title: String, metadata: String, notice: String, sections: [(String, String)], applyTitle: String?, controls: [NSView] = [], secondaryActions: [NSView] = []) {
        self.sections = sections
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        detailHeading = .init(title: title, scope: metadata)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold); heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let context = NSTextField(labelWithString: metadata)
        context.font = .systemFont(ofSize: 12); context.textColor = AgentWorkbenchTheme.secondaryText
        context.lineBreakMode = .byTruncatingMiddle; context.toolTip = metadata; context.isHidden = metadata.isEmpty
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.alignment = .centerY; header.spacing = 12
        [heading, NSView(), context].forEach(header.addArrangedSubview)
        let consequence = AgentSettingsStatusField("审阅操作影响")
        consequence.font = .systemFont(ofSize: 12); consequence.stringValue = notice
        status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 3

        let column = NSTableColumn(identifier: .init("review"))
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column); list.headerView = nil; list.rowHeight = 34; list.dataSource = self; list.delegate = self
        list.style = .inset; list.backgroundColor = .clear; list.setAccessibilityLabel("设置审阅列表")
        index.documentView = list
        chooser.target = self; chooser.action = #selector(chooseSection)
        chooser.cell?.lineBreakMode = .byTruncatingMiddle; chooser.setAccessibilityLabel("选择审阅条目")
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 13, weight: .regular); preview.drawsBackground = false
        preview.textContainerInset = NSSize(width: 14, height: 14); preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("设置审阅正文")
        detail.documentView = preview
        for scroll in [index, detail] {
            scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; scroll.borderType = .noBorder
            scroll.wantsLayer = true; scroll.layer?.cornerRadius = 9; scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = AgentWorkbenchTheme.line.cgColor
        }
        let split = NSStackView(views: [index, detail]); split.spacing = 12; split.alignment = .centerY; split.distribution = .fill
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.setContentHuggingPriority(.defaultLow, for: .vertical)

        let cancel = AgentDialogButton(title: applyTitle == nil ? "返回" : "取消", target: self, action: #selector(cancelReview))
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        AgentDialogStyle.action(cancel)
        apply.title = applyTitle ?? ""; apply.target = self; apply.action = #selector(applyReview); apply.isHidden = applyTitle == nil
        AgentSettingsStyle.primaryAction(apply)
        let actions = AgentSettingsDetailActions([cancel] + secondaryActions + (applyTitle == nil ? [] : [apply]))
        detailActionRow = actions
        let layout = NSStackView(views: [header, consequence] + controls + [status, compactChooser, split, actions])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 10; layout.distribution = .fill
        let root = AgentWorkspacePageView(fill: AgentWorkbenchTheme.settings)
        window.contentView = root; root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        for view in layout.arrangedSubviews { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            index.widthAnchor.constraint(equalToConstant: 172), index.heightAnchor.constraint(equalTo: split.heightAnchor),
            detail.heightAnchor.constraint(equalTo: split.heightAnchor), split.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        root.onResize = { [weak self] in self?.updateReaderLayout() }
        reload(selectedTitle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func setSettingsActionsHost(_ host: NSStackView?) {
        super.setSettingsActionsHost(host); header.isHidden = host != nil
    }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        updateReaderLayout()
        if pendingReading != nil { scheduleReading(); return }
        let reader: NSView = sections.count < 2 ? preview : (compactChooser.isHidden ? list : chooser)
        presentingWindow?.makeFirstResponder(reader)
    }
    override func pageDidLayout() { scheduleReading() }
    private func updateReaderLayout() {
        let multiple = sections.count > 1, compact = (pageContentView?.bounds.width ?? 0) < 590
        let focus = presentingWindow?.firstResponder
        index.isHidden = !multiple || compact; compactChooser.isHidden = !multiple || !compact
        if multiple {
            if compact, focus === list { presentingWindow?.makeFirstResponder(chooser) }
            if !compact, focus === chooser { presentingWindow?.makeFirstResponder(list) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sections.indices.contains(row) else { return nil }
        let label = NSTextField(labelWithString: sections[row].title)
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = label.stringValue
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !reloading { showSelection() }
    }
    @objc private func chooseSection() {
        let row = chooser.indexOfSelectedItem
        guard sections.indices.contains(row) else { return }
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        showSelection()
    }
    private func reload(selectedTitle: String?) {
        reloading = true
        list.reloadData(); chooser.removeAllItems()
        chooser.addItems(withTitles: sections.map(\.title))
        if !sections.isEmpty {
            let row = sections.firstIndex { $0.title == selectedTitle } ?? 0
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        reloading = false
        updateReaderLayout(); showSelection(); updateApply()
    }
    func updateSections(_ values: [(String, String)]) {
        let selected = displayedTitle
        sections = values; contentReady = true; status.stringValue = ""
        reload(selectedTitle: selected)
    }
    func setApplyTitle(_ title: String) { apply.title = title }
    func showPreviewFailure(_ error: Error) {
        status.showSaveFailure(error); contentReady = false; updateApply()
    }
    private func showSelection() {
        let row = list.selectedRow
        let section = sections.indices.contains(row) ? sections[row] : nil
        if section != nil { chooser.selectItem(at: row); chooser.toolTip = section?.title }
        guard displayedTitle != section?.title || preview.string != (section?.body ?? "") else { return }
        if let displayedTitle { positions[displayedTitle] = try? AgentTextViewport(preview) }
        displayedTitle = section?.title
        preview.string = section?.body ?? ""
        preview.setSelectedRange(NSRange(location: 0, length: 0))
        AgentSettingsRecovery.restoreScroll(0, to: detail)
        if let displayedTitle { positions[displayedTitle]?.apply(to: preview, focus: false) }
        readingChanged()
    }
    func trackReviewReading() {
        for clip in [index.contentView, detail.contentView] {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(readingChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(readingChanged), name: NSTextView.didChangeSelectionNotification, object: preview)
    }
    func captureReviewReading() throws -> ReadingLocation {
        if let pendingReading { return pendingReading }
        let reading = displayedTitle == nil ? nil : try AgentTextViewport(preview)
        return .init(selected: displayedTitle, listY: max(0, index.contentView.bounds.minY), preview: reading)
    }
    func restoreReviewReading(_ value: ReadingLocation) {
        reload(selectedTitle: value.selected)
        pendingReading = value; scheduleReading()
    }
    private func scheduleReading() {
        guard pendingReading != nil, !readingScheduled else { return }
        readingScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { readingScheduled = false }
            guard isPageVisible, detail.contentSize.height > 0, let saved = pendingReading else { return }
            AgentSettingsRecovery.restoreScroll(saved.listY, to: index)
            let reader: NSView = sections.count < 2 ? preview : (compactChooser.isHidden ? list : chooser)
            if saved.selected != displayedTitle || saved.preview?.focused != true { presentingWindow?.makeFirstResponder(reader) }
            if saved.selected == displayedTitle, let reading = saved.preview, reading.apply(to: preview), reading.focused,
               let selection = reading.selections.first { preview.scrollRangeToVisible(selection.range) }
            pendingReading = nil; readingChanged()
        }
    }
    @objc private func readingChanged() { if pendingReading == nil, isPageVisible { onSettingsRecoveryChange?() } }
    private func updateApply() {
        apply.isEnabled = onApply != nil && !sections.isEmpty && contentReady && !working && !finished
    }
    @objc private func cancelReview() { guard !working else { return }; close() }
    @objc private func applyReview() {
        guard apply.isEnabled, let onApply else { return }
        working = true; updateApply()
        do { try onApply(); working = false; finished = true; updateApply(); close(); onApplied?() }
        catch { status.showSaveFailure(error); working = false; updateApply() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !working }
}
