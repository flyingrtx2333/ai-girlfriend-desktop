import AppKit

@MainActor final class AgentDependencyWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let service: AgentDependencySecurity
    private let store: AgentStore, taskID: String, selectedPaths: [String]
    private let activity = UUID()
    private let table = NSTableView()
    private let source = NSPopUpButton()
    private let scope = NSPopUpButton()
    private let refreshDatabase = NSButton(checkboxWithTitle: "更新公告库", target: nil, action: nil)
    private let scanButton = NSButton(title: "开始检查", target: nil, action: nil)
    private let advisoryButton = NSButton(title: "查看公告", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let details = NSTextView()
    private var report: AgentDependencyReport?
    private var job: Task<Void, Never>?

    init(service: AgentDependencySecurity, store: AgentStore, taskID: String, defaultSource: AgentDependencyReport.Source, selectedPaths: [String]) {
        self.service = service; self.store = store; self.taskID = taskID; self.selectedPaths = selectedPaths
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "依赖漏洞 · " + service.files.root.lastPathComponent
        window.minSize = NSSize(width: 650, height: 430)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        super.init(window: window)
        window.delegate = self

        source.addItems(withTitles: service.supportsStaging ? ["工作区", "暂存区"] : ["工作区"])
        source.selectItem(at: defaultSource == .staged && service.supportsStaging ? 1 : 0)
        source.setAccessibilityLabel("依赖检查来源")
        scope.addItems(withTitles: selectedPaths.isEmpty ? ["整个项目"] : ["整个项目", "所选文件"])
        scope.setAccessibilityLabel("依赖检查范围")
        scanButton.target = self; scanButton.action = #selector(scanOrCancel)
        advisoryButton.target = self; advisoryButton.action = #selector(openAdvisory)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let controls = NSStackView(views: [source, scope, refreshDatabase, NSView(), progress, scanButton])
        controls.spacing = 8

        for (key, name, width) in [("risk", "风险", 54.0), ("package", "依赖", 185.0), ("version", "版本", 105.0), ("advisory", "公告", 175.0), ("path", "文件", 220.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = name; column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset; table.rowHeight = 28
        table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("依赖漏洞结果")
        let list = NSScrollView()
        list.documentView = table; list.hasVerticalScroller = true; list.hasHorizontalScroller = true

        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityLabel("依赖检查状态")
        details.isEditable = false
        details.isSelectable = true
        details.font = .systemFont(ofSize: 12)
        details.backgroundColor = .controlBackgroundColor
        details.textContainerInset = NSSize(width: 8, height: 8)
        details.setAccessibilityLabel("依赖漏洞详情")
        let detailScroll = NSScrollView()
        detailScroll.documentView = details; detailScroll.hasVerticalScroller = true
        let footer = NSStackView(views: [NSView(), advisoryButton])
        let content = NSView()
        window.contentView = content
        for view in [controls, status, list, detailScroll, footer] {
            content.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16).isActive = true
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            status.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            list.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 9),
            list.bottomAnchor.constraint(equalTo: detailScroll.topAnchor, constant: -10),
            detailScroll.heightAnchor.constraint(equalToConstant: 105),
            detailScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        show(service.previousReport(), previous: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { job?.cancel() }

    @objc private func scanOrCancel() {
        if let job {
            job.cancel()
            scanButton.isEnabled = false
            status.stringValue = "正在停止…"
            return
        }
        let origin: AgentDependencyReport.Source = source.indexOfSelectedItem == 1 ? .staged : .working
        let paths = scope.indexOfSelectedItem == 1 ? selectedPaths : nil
        let force = refreshDatabase.state == .on
        source.isEnabled = false; scope.isEnabled = false; refreshDatabase.isEnabled = false
        scanButton.title = "停止"; progress.startAnimation(nil)
        store.worktreeRetention.setNativeOperation(activity, taskID: taskID, busy: true)
        job = Task { [weak self] in
            guard let self else { return }
            defer {
                job = nil
                source.isEnabled = true; scope.isEnabled = true; refreshDatabase.isEnabled = true
                refreshDatabase.state = .off
                scanButton.title = "开始检查"; scanButton.isEnabled = true; progress.stopAnimation(nil)
                store.worktreeRetention.setNativeOperation(activity, taskID: taskID, busy: false)
            }
            do {
                let result = try await service.scan(source: origin, requested: paths, forceUpdate: force) { status.stringValue = $0 }
                show(result, previous: false)
            } catch is CancellationError {
                status.stringValue = "已停止检查"
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func show(_ result: AgentDependencyReport?, previous: Bool) {
        report = result
        let summary = result.map { (previous ? "上次 · " : "") + $0.summary } ?? "待检查"
        status.stringValue = summary
        status.toolTip = summary
        table.reloadData()
        table.deselectAll(nil)
        if numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateDetails()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { (report?.findings.count ?? 0) + (report?.skipped.count ?? 0) }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let report, let key = column?.identifier.rawValue else { return nil }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        if report.findings.indices.contains(row) {
            let item = report.findings[row]
            switch key {
            case "risk":
                field.stringValue = item.severity
                field.textColor = (item.score ?? 0) >= 7 ? .systemRed : .secondaryLabelColor
            case "package": field.stringValue = item.package
            case "version": field.stringValue = item.version
            case "advisory": field.stringValue = item.aliases.first(where: { $0.hasPrefix("CVE-") }) ?? item.advisory
            default: field.stringValue = item.path
            }
        } else {
            let item = report.skipped[row - report.findings.count]
            if key == "risk" { field.stringValue = "跳过" }
            if key == "package" { field.stringValue = item.reason }
            if key == "path" { field.stringValue = item.path }
            field.textColor = .secondaryLabelColor
        }
        field.toolTip = field.stringValue
        field.stringValue = field.stringValue.replacingOccurrences(of: "\n", with: "↵")
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetails() }
    private var selectedFinding: AgentDependencyFinding? {
        guard let report, report.findings.indices.contains(table.selectedRow) else { return nil }
        return report.findings[table.selectedRow]
    }
    private func updateDetails() {
        advisoryButton.isEnabled = selectedFinding?.advisoryURL != nil
        var lines: [String] = []
        if let finding = selectedFinding {
            lines.append("\(finding.ecosystem) · \(finding.package) \(finding.version) · \(finding.path)")
            if let summary = finding.summary, !summary.isEmpty { lines.append(summary) }
            let versions = finding.fixedVersions.isEmpty ? "公告未给出" : finding.fixedVersions.joined(separator: "、")
            lines.append("公告修复版本  " + versions)
        } else if let report, table.selectedRow >= report.findings.count, table.selectedRow - report.findings.count < report.skipped.count {
            let skipped = report.skipped[table.selectedRow - report.findings.count]
            lines.append(skipped.path + " · " + skipped.reason)
        }
        if let report {
            let date = report.created.formatted(date: .abbreviated, time: .shortened)
            lines.append("检查时间  " + date)
            if !report.databases.isEmpty {
                let sources = report.databases.map {
                    $0.ecosystem + " " + $0.publishedAt.formatted(date: .abbreviated, time: .omitted) + ($0.usedStaleCache ? "（更新失败，使用缓存）" : "")
                }
                lines.append("OSV 公告库  " + sources.joined(separator: " · "))
            }
        }
        details.string = lines.joined(separator: "\n")
        details.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    @objc private func openAdvisory() {
        if let url = selectedFinding?.advisoryURL { NSWorkspace.shared.open(url) }
    }
}
