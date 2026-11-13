import AppKit

@MainActor class AgentSettingsReviewPage: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var sections: [(title: String, body: String)]
    private let list = NSTableView(), preview = NSTextView(), status = NSTextField(wrappingLabelWithString: "")
    private let apply = NSButton(), cancel = NSButton(title: "取消", target: nil, action: nil)
    private var working = false, finished = false
    var onApply: (() throws -> Void)? { didSet { apply.isEnabled = onApply != nil && !working && !finished } }
    var onApplied: (() -> Void)?

    init(title: String, metadata: String, notice: String, sections: [(String, String)], applyTitle: String?, controls: [NSView] = []) {
        self.sections = sections
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 420, height: 360); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        let heading = NSTextField(wrappingLabelWithString: title); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let context = NSTextField(labelWithString: metadata); context.font = .systemFont(ofSize: 12); context.textColor = AgentWorkbenchTheme.secondaryText; context.lineBreakMode = .byTruncatingMiddle; context.toolTip = metadata
        let consequence = NSTextField(wrappingLabelWithString: notice); consequence.font = .systemFont(ofSize: 12); consequence.textColor = AgentWorkbenchTheme.secondaryText; consequence.isHidden = notice.isEmpty; consequence.setAccessibilityLabel("审阅操作影响")
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("review"))); list.headerView = nil; list.rowHeight = 36; list.dataSource = self; list.delegate = self; list.setAccessibilityLabel("设置审阅列表")
        let index = NSScrollView(); index.documentView = list; index.hasVerticalScroller = true
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 12, height: 12); preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true; preview.setAccessibilityLabel("设置审阅正文")
        let detail = NSScrollView(); detail.documentView = preview; detail.hasVerticalScroller = true
        let split = NSStackView(views: sections.count > 1 ? [index, detail] : [detail]); split.spacing = 12; split.alignment = .top; split.distribution = .fill
        if sections.count > 1 { index.widthAnchor.constraint(equalToConstant: 180).isActive = true; index.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true }
        status.font = .systemFont(ofSize: 12); status.textColor = .systemRed; status.isHidden = true; status.setAccessibilityLabel("审阅操作错误")
        cancel.target = self; cancel.action = #selector(cancelReview); cancel.keyEquivalent = "\u{1b}"
        apply.title = applyTitle ?? ""; apply.target = self; apply.action = #selector(applyReview); apply.isEnabled = false; apply.isHidden = applyTitle == nil
        if applyTitle == nil { cancel.title = "返回" }
        let footer = NSStackView(views: [NSView(), cancel, apply]); footer.spacing = 10
        let layout = NSStackView(views: [heading, context, consequence] + controls + [split, status, footer]); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 10; layout.distribution = .fill
        let root = AgentThemeView(); window.contentView = root; root.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        for view in [heading, context, consequence, split, status, footer] + controls { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            detail.heightAnchor.constraint(equalTo: split.heightAnchor), split.heightAnchor.constraint(greaterThanOrEqualToConstant: 100), footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        list.reloadData(); if !sections.isEmpty { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; showSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsDidAppear() { super.settingsDidAppear(); presentingWindow?.makeFirstResponder(sections.count > 1 ? list : preview) }
    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sections.indices.contains(row) else { return nil }; let label = NSTextField(labelWithString: sections[row].title)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = label.stringValue; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
    func updateSections(_ values:[(String,String)]) { let row = list.selectedRow; sections = values; list.reloadData(); if !sections.isEmpty { list.selectRowIndexes(IndexSet(integer:min(max(0,row),sections.count - 1)),byExtendingSelection:false) }; showSelection() }
    private func showSelection() {
        guard sections.indices.contains(list.selectedRow) else { return }; preview.string = sections[list.selectedRow].body; preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    @objc private func cancelReview() { guard !working else { return }; close() }
    @objc private func applyReview() {
        guard !working, !finished, !sections.isEmpty, let onApply else { return }; working = true; apply.isEnabled = false; cancel.isEnabled = false
        do { try onApply(); working = false; finished = true; close(); onApplied?() }
        catch { status.stringValue = error.localizedDescription; status.isHidden = false; working = false; apply.isEnabled = true; cancel.isEnabled = true }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !working }
}
