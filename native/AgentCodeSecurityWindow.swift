import AppKit

@MainActor final class AgentCodeSecurityWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate {
    private let report: AgentSecurityReport
    private let table = NSTableView()
    private let detail = NSTextView(frame: .zero), detailScroll = NSScrollView(), list = NSScrollView()
    private let state = AgentSettingsStatusField("安全检查操作状态")
    private let locate = AgentDialogButton(title: "定位差异", target: nil, action: nil)
    private let copy = AgentDialogButton(title: "复制位置", target: nil, action: nil)
    private let flow = NSPopUpButton()
    private lazy var flowFrame = AgentSettingsPopupFrame(flow)
    private let fix = AgentDialogButton(title: "启用证书校验…", target: nil, action: nil)
    private let done = AgentDialogButton(title: "关闭", target: nil, action: nil)
    private var detailHeight: NSLayoutConstraint!
    private let onLocate: (AgentSecurityFinding) -> Void
    private let onFix: ((AgentSecurityFinding) throws -> Void)?
    private var finding: AgentSecurityFinding? { report.findings.indices.contains(table.selectedRow) ? report.findings[table.selectedRow] : nil }
    private var skipped: AgentSecurityReport.Skipped? {
        let row = table.selectedRow - report.findings.count
        return report.skipped.indices.contains(row) ? report.skipped[row] : nil
    }

    init(report: AgentSecurityReport, onLocate: @escaping (AgentSecurityFinding) -> Void, onFix: ((AgentSecurityFinding) throws -> Void)?) {
        self.report = report
        self.onLocate = onLocate
        self.onFix = onFix
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = report.mode == .semantic ? "轻量语义检查" : "代码安全检查"
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let heading = NSTextField(wrappingLabelWithString: report.summary)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.lineBreakMode = .byWordWrapping; heading.maximumNumberOfLines = 0; heading.toolTip = report.summary
        for (key, name, width) in [("risk", "风险", 52.0), ("issue", "发现", 220.0), ("path", "位置", 260.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = name
            column.width = width
            column.minWidth = 0
            table.addTableColumn(column)
        }
        table.rowHeight = 32
        table.style = .plain; table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("安全检查结果")
        list.documentView = table
        list.hasVerticalScroller = true
        list.hasHorizontalScroller = false; list.scrollerStyle = .overlay; list.drawsBackground = false; table.backgroundColor = .clear
        detail.isEditable = false; detail.isSelectable = true; detail.drawsBackground = false
        detail.font = .systemFont(ofSize: 13); detail.textColor = .labelColor
        detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]; detail.textContainerInset = NSSize(width: 0, height: 4)
        detail.textContainer?.widthTracksTextView = true
        detail.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        detail.setAccessibilityLabel("处理建议")
        detailScroll.documentView = detail; detailScroll.hasVerticalScroller = true
        detailScroll.scrollerStyle = .overlay; detailScroll.drawsBackground = false
        done.target = self; done.action = #selector(closeSheet)
        done.keyEquivalent = "\r"
        locate.target = self; locate.action = #selector(locateFinding)
        copy.target = self; copy.action = #selector(copyLocation)
        flow.setAccessibilityLabel("数据流位置")
        flow.target = self; flow.action = #selector(changeLocation)
        flow.font = .systemFont(ofSize: 13)
        fix.target = self; fix.action = #selector(fixFinding)
        flow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); flow.cell?.lineBreakMode = .byTruncatingMiddle
        for button in [locate, copy, fix, done] { AgentDialogStyle.action(button, prominent: button === done) }
        let actions = NSStackView(views: [locate, copy, fix, NSView(), done]); actions.spacing = 8
        let buttons = NSStackView(views: [flowFrame, state, actions]); buttons.orientation = .vertical; buttons.alignment = .leading; buttons.spacing = 8
        actions.widthAnchor.constraint(equalTo: buttons.widthAnchor).isActive = true
        flowFrame.widthAnchor.constraint(lessThanOrEqualTo: buttons.widthAnchor).isActive = true

        let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
        window.contentView = content
        for view in [heading, list, detailScroll, buttons] {
            content.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16).isActive = true
        }
        detailHeight = detailScroll.heightAnchor.constraint(equalToConstant: 120)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            list.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            list.bottomAnchor.constraint(equalTo: detailScroll.topAnchor, constant: -12),
            detailHeight,
            detailScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        content.onResize = { [weak self] in self?.pageDidLayout() }
        table.reloadData()
        if numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateSelection()
        let empty = NSTextField(wrappingLabelWithString: report.scannedFiles == 0 ? "没有可检查的文本文件" : "未发现匹配项")
        empty.identifier = .init("settings-list-empty")
        empty.font = .systemFont(ofSize: 13); empty.textColor = AgentWorkbenchTheme.secondaryText; empty.alignment = .center
        empty.isHidden = numberOfRows(in: table) > 0
        empty.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 12),
            empty.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -12),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor, constant: 10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func settingsDidAppear() {
        super.settingsDidAppear()
        done.title = settingsHostWindow == nil ? "关闭" : "返回审阅"
        done.prominent = true
        pageDidLayout()
    }
    override func pageDidLayout() {
        guard let content = pageContentView else { return }
        let width = list.contentSize.width
        if width > 0, table.tableColumns.count == 3 {
            let risk = min(52, width * 0.16), issue = floor((width - risk) * 0.52)
            for (column, value) in zip(table.tableColumns, [risk, issue, width - risk - issue]) { column.width = value }
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
        }
        detailHeight.constant = finding == nil && skipped == nil ? 0 : min(180, max(80, content.bounds.height * 0.26))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { report.findings.count + report.skipped.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let key = column?.identifier.rawValue
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingMiddle
        if report.findings.indices.contains(row) {
            let finding = report.findings[row]
            switch key {
            case "risk":
                field.stringValue = finding.highRisk ? "高" : "中"
                field.textColor = finding.highRisk ? AgentDialogStyle.error : .systemOrange
            case "issue": field.stringValue = finding.title
            default: field.stringValue = "\(finding.path):\(finding.line)"
            }
        } else {
            let skipped = report.skipped[row - report.findings.count]
            field.stringValue = key == "risk" ? "跳过" : key == "issue" ? skipped.reason : skipped.path
            field.textColor = AgentWorkbenchTheme.secondaryText
        }
        field.toolTip = field.stringValue
        field.stringValue = field.stringValue.replacingOccurrences(of: "\n", with: "↵")
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        state.stringValue = ""; state.textColor = AgentWorkbenchTheme.secondaryText
        locate.isEnabled = finding != nil
        copy.isEnabled = finding != nil || skipped != nil
        fix.isHidden = !(finding.map { report.canFix($0) } ?? false) || onFix == nil
        flow.removeAllItems()
        let trace = finding?.trace ?? []
        flowFrame.isHidden = trace.isEmpty
        flow.addItems(withTitles: trace.map { "\($0.label) · \($0.path):\($0.line)" })
        if !trace.isEmpty { flow.selectItem(at: trace.count - 1) }
        updateDetails()
        pageDidLayout()
    }
    @objc private func changeLocation() { updateDetails() }
    private func updateDetails() {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let value = NSMutableAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        if let finding {
            let location = selectedLocation
            let path = "\(location?.path ?? finding.path):\(location?.line ?? finding.line)"
            value.append(NSAttributedString(string: path + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: AgentWorkbenchTheme.secondaryText, .paragraphStyle: paragraph]))
            value.append(NSAttributedString(string: finding.advice + "\n" + finding.rule, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        } else if let skipped {
            value.append(NSAttributedString(string: skipped.path + "\n" + skipped.reason, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        detail.textStorage?.setAttributedString(value)
        detail.setSelectedRange(NSRange(location: 0, length: 0))
        detailScroll.contentView.scroll(to: .zero); detailScroll.reflectScrolledClipView(detailScroll.contentView)
    }
    private var selectedLocation: AgentSecurityLocation? {
        guard let trace = finding?.trace, trace.indices.contains(flow.indexOfSelectedItem) else { return nil }
        return trace[flow.indexOfSelectedItem]
    }

    @objc private func closeSheet() {
        if settingsHostWindow != nil { close() }
        else if let window, let parent = window.sheetParent { parent.endSheet(window) }
    }
    @objc private func locateFinding() {
        guard let finding else { return }
        closeSheet()
        onLocate(selectedLocation.map(finding.at) ?? finding)
    }
    @objc private func copyLocation() {
        guard finding != nil || skipped != nil else { return }
        NSPasteboard.general.clearContents()
        let location = selectedLocation
        let value = finding.map { "\(location?.path ?? $0.path):\(location?.line ?? $0.line)" } ?? skipped!.path
        NSPasteboard.general.setString(value, forType: .string)
        state.stringValue = "已复制文件位置"
    }
    @objc private func fixFinding() {
        guard let finding, let onFix else { return }
        let alert = AgentConfirmation()
        alert.messageText = "启用 TLS 证书校验？"
        alert.informativeText = "\(finding.path):\(finding.line)\nrejectUnauthorized: false → true\n仅写入工作区，可撤销。"
        alert.addButton(withTitle: "修复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal(for: presentingWindow) == .alertFirstButtonReturn else { return }
        do {
            try onFix(finding)
            closeSheet()
        } catch { state.textColor = AgentDialogStyle.error; state.stringValue = error.localizedDescription }
    }

    func workspaceReadback() -> [String: Any] {
        guard let content = pageContentView else { return [:] }
        return [
            "usesTaskWindow": settingsHostWindow != nil && content.window === settingsHostWindow,
            "nativeSheet": presentingWindow?.attachedSheet != nil,
            "size": [Double(content.bounds.width), Double(content.bounds.height)],
            "selectedRow": table.selectedRow, "rows": numberOfRows(in: table),
            "columnWidths": table.tableColumns.map { Double($0.width) }, "tableWidth": Double(table.bounds.width),
            "tableViewport": [Double(list.contentSize.width), Double(list.contentSize.height)],
            "detail": detail.string, "detailViewport": [Double(detailScroll.contentSize.width), Double(detailScroll.contentSize.height)],
            "detailDocument": [Double(detail.bounds.width), Double(detail.bounds.height)],
            "detailOrigin": [Double(detailScroll.contentView.bounds.origin.x), Double(detailScroll.contentView.bounds.origin.y)],
            "flowVisible": !flowFrame.isHidden, "flowValue": flow.titleOfSelectedItem ?? "",
            "state": state.stringValue,
            "actions": [locate, copy, fix, done].filter { !$0.isHidden }.map { button -> [String: Any] in
                let frame = button.convert(button.bounds, to: content)
                return ["title": button.title, "enabled": button.isEnabled, "inside": content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "visibleHeight": Double(button.visibleRect.height)]
            }
        ]
    }
}
