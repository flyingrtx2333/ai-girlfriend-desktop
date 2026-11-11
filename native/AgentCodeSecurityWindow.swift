import AppKit

@MainActor final class AgentCodeSecurityWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let report: AgentSecurityReport
    private let table = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let locate = NSButton(title: "定位差异", target: nil, action: nil)
    private let copy = NSButton(title: "复制位置", target: nil, action: nil)
    private let flow = NSPopUpButton()
    private let fix = NSButton(title: "启用证书校验…", target: nil, action: nil)
    private let onLocate: (AgentSecurityFinding) -> Void
    private let onFix: ((AgentSecurityFinding) throws -> Void)?
    private var finding: AgentSecurityFinding? { report.findings.indices.contains(table.selectedRow) ? report.findings[table.selectedRow] : nil }

    init(report: AgentSecurityReport, onLocate: @escaping (AgentSecurityFinding) -> Void, onFix: ((AgentSecurityFinding) throws -> Void)?) {
        self.report = report
        self.onLocate = onLocate
        self.onFix = onFix
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = report.mode == .semantic ? "轻量语义检查" : "代码安全检查"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let heading = NSTextField(labelWithString: report.summary)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        for (key, name, width) in [("risk", "风险", 60.0), ("issue", "发现", 176.0), ("path", "位置", 365.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = name
            column.width = width
            table.addTableColumn(column)
        }
        table.rowHeight = 29
        table.style = .inset
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("安全检查结果")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        detail.setAccessibilityLabel("处理建议")
        detail.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 12)
        state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingTail
        let done = NSButton(title: "关闭", target: self, action: #selector(closeSheet))
        done.keyEquivalent = "\r"
        locate.target = self; locate.action = #selector(locateFinding)
        copy.target = self; copy.action = #selector(copyLocation)
        flow.setAccessibilityLabel("数据流位置")
        flow.widthAnchor.constraint(lessThanOrEqualToConstant: 245).isActive = true
        fix.target = self; fix.action = #selector(fixFinding)
        let buttons = NSStackView(views: [flow, locate, copy, fix, NSView(), done])
        buttons.spacing = 8

        let content = NSView()
        window.contentView = content
        for view in [heading, scroll, detail, state, buttons] {
            content.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18).isActive = true
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -12),
            detail.heightAnchor.constraint(equalToConstant: 43),
            detail.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -6),
            state.heightAnchor.constraint(equalToConstant: 17),
            state.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        table.reloadData()
        if numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func numberOfRows(in tableView: NSTableView) -> Int { report.findings.count + report.skipped.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let key = column?.identifier.rawValue
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        if report.findings.indices.contains(row) {
            let finding = report.findings[row]
            switch key {
            case "risk":
                field.stringValue = finding.highRisk ? "高" : "中"
                field.textColor = finding.highRisk ? .systemRed : .systemOrange
            case "issue": field.stringValue = finding.title
            default: field.stringValue = "\(finding.path):\(finding.line)"
            }
        } else {
            let skipped = report.skipped[row - report.findings.count]
            field.stringValue = key == "risk" ? "跳过" : key == "issue" ? skipped.reason : skipped.path
            field.textColor = .secondaryLabelColor
        }
        field.toolTip = field.stringValue
        field.stringValue = field.stringValue.replacingOccurrences(of: "\n", with: "↵")
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        state.stringValue = ""
        locate.isEnabled = finding != nil
        copy.isEnabled = finding != nil
        fix.isHidden = !(finding.map { report.canFix($0) } ?? false) || onFix == nil
        flow.removeAllItems()
        let trace = finding?.trace ?? []
        flow.isHidden = trace.isEmpty
        flow.addItems(withTitles: trace.map { "\($0.label) · \($0.path):\($0.line)" })
        if !trace.isEmpty { flow.selectItem(at: trace.count - 1) }
        if let finding { detail.stringValue = finding.advice + "\n" + finding.rule }
        else { detail.stringValue = "" }
    }
    private var selectedLocation: AgentSecurityLocation? {
        guard let trace = finding?.trace, trace.indices.contains(flow.indexOfSelectedItem) else { return nil }
        return trace[flow.indexOfSelectedItem]
    }

    @objc private func closeSheet() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
    }
    @objc private func locateFinding() {
        guard let finding else { return }
        closeSheet()
        onLocate(selectedLocation.map(finding.at) ?? finding)
    }
    @objc private func copyLocation() {
        guard let finding else { return }
        NSPasteboard.general.clearContents()
        let location = selectedLocation
        NSPasteboard.general.setString("\(location?.path ?? finding.path):\(location?.line ?? finding.line)", forType: .string)
        state.stringValue = "已复制文件位置"
    }
    @objc private func fixFinding() {
        guard let finding, let onFix else { return }
        let alert = NSAlert()
        alert.messageText = "启用 TLS 证书校验？"
        alert.informativeText = "\(finding.path):\(finding.line)\nrejectUnauthorized: false → true\n仅写入工作区，可撤销。"
        alert.addButton(withTitle: "修复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try onFix(finding)
            closeSheet()
        } catch { state.stringValue = error.localizedDescription }
    }
}
