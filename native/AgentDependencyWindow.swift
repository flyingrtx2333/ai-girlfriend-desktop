import AppKit

@MainActor final class AgentDependencyWindow: AgentSettingsPageController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let service: AgentDependencySecurity
    private let store: AgentStore, taskID: String, selectedPaths: [String]
    private let activity = UUID()
    private let table = NSTableView(), list = NSScrollView(), detailScroll = NSScrollView()
    private let source = NSPopUpButton()
    private let scope = NSPopUpButton()
    private lazy var sourceFrame = AgentSettingsPopupFrame(source)
    private lazy var scopeFrame = AgentSettingsPopupFrame(scope)
    private let refreshDatabase = NSButton(checkboxWithTitle: "更新公告库", target: nil, action: nil)
    private let scanButton = AgentDialogButton(title: "开始检查", target: nil, action: nil)
    private let advisoryButton = AgentDialogButton(title: "查看公告", target: nil, action: nil)
    private let done = AgentDialogButton(title: "关闭", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let status = AgentSettingsStatusField("依赖检查状态")
    private let details = NSTextView(frame: .zero)
    private let empty = NSTextField(wrappingLabelWithString: "尚无检查结果")
    private var detailHeight: NSLayoutConstraint!
    private var report: AgentDependencyReport?
    private var job: Task<Void, Never>?
    var hasPendingOperation: Bool { job != nil }

    init(service: AgentDependencySecurity, store: AgentStore, taskID: String, defaultSource: AgentDependencyReport.Source, selectedPaths: [String]) {
        self.service = service; self.store = store; self.taskID = taskID; self.selectedPaths = selectedPaths
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "依赖漏洞 · " + service.files.root.lastPathComponent
        window.minSize = NSSize(width: 480, height: 400)
        window.isReleasedWhenClosed = false
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
        done.target = self; done.action = #selector(closeReport)
        for button in [scanButton, advisoryButton, done] { AgentDialogStyle.action(button, prominent: button === scanButton) }
        refreshDatabase.font = .systemFont(ofSize: 13); refreshDatabase.controlSize = .regular
        refreshDatabase.heightAnchor.constraint(equalToConstant: 28).isActive = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let filters = NSStackView(views: [sourceFrame, scopeFrame, NSView()]), actions = NSStackView(views: [refreshDatabase, NSView(), progress, scanButton])
        filters.spacing = 8; actions.spacing = 8
        let controls = NSStackView(views: [filters, actions]); controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 8
        for row in [filters, actions] { row.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true }

        for (key, name, width) in [("risk", "风险", 52.0), ("package", "依赖 / 公告", 250.0), ("path", "文件", 260.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = name; column.width = width; column.minWidth = 0
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.autoresizingMask = [.width]
        table.style = .plain; table.rowHeight = 44; table.intercellSpacing = .zero
        table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("依赖漏洞结果")
        list.documentView = table; list.hasVerticalScroller = true; list.hasHorizontalScroller = false

        status.font = .systemFont(ofSize: 12, weight: .medium)
        details.isEditable = false
        details.isSelectable = true
        details.font = .systemFont(ofSize: 13)
        details.isVerticallyResizable = true; details.isHorizontallyResizable = false; details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        details.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        details.textContainerInset = NSSize(width: 0, height: 4)
        details.setAccessibilityLabel("依赖漏洞详情")
        detailScroll.documentView = details; detailScroll.hasVerticalScroller = true
        let footer = NSStackView(views: [advisoryButton, NSView(), done]); footer.spacing = 8
        list.drawsBackground = false; list.scrollerStyle = .overlay; table.backgroundColor = .clear
        detailScroll.drawsBackground = false; detailScroll.scrollerStyle = .overlay; details.drawsBackground = false; details.textColor = .labelColor
        let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface)
        window.contentView = content
        for view in [controls, status, list, detailScroll, footer] {
            content.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16).isActive = true
        }
        detailHeight = detailScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            status.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            list.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            list.bottomAnchor.constraint(equalTo: detailScroll.topAnchor, constant: -12),
            detailHeight,
            detailScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        empty.identifier = .init("dependency-list-empty"); empty.font = .systemFont(ofSize: 13)
        empty.textColor = AgentWorkbenchTheme.secondaryText; empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 12),
            empty.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -12),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor, constant: 10)
        ])
        content.onResize = { [weak self] in self?.pageDidLayout() }
        setScanning(false)
        show(service.previousReport(), previous: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { job?.cancel() }

    override func settingsDidAppear() {
        super.settingsDidAppear()
        done.title = settingsHostWindow == nil ? "关闭" : "返回审阅"
        pageDidLayout()
    }
    override func pageDidLayout() {
        guard let content = pageContentView else { return }
        let width = list.contentSize.width
        if width > 0, table.tableColumns.count == 3 {
            let risk = min(52, width * 0.18), package = floor((width - risk) * 0.56)
            for (column, value) in zip(table.tableColumns, [risk, package, width - risk - package]) { column.width = value }
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
        }
        detailHeight.constant = report == nil ? 0 : table.selectedRow < 0 ? 64 : min(180, max(80, content.bounds.height * 0.26))
    }
    private func setScanning(_ scanning: Bool) {
        source.isEnabled = !scanning && service.supportsStaging
        scope.isEnabled = !scanning && !selectedPaths.isEmpty
        sourceFrame.refreshEnabledState(); scopeFrame.refreshEnabledState()
        refreshDatabase.isEnabled = !scanning
        scanButton.title = scanning ? "停止" : "开始检查"; scanButton.isEnabled = true
        if scanning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }
    private func updateEmptyState() {
        empty.isHidden = numberOfRows(in: table) > 0
        empty.stringValue = report.map { $0.packages == 0 ? "没有可核对的依赖版本" : "未命中已知公告" } ?? (job == nil ? "尚无检查结果" : "正在检查…")
    }
    @objc private func closeReport() { close() }

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
        setScanning(true)
        status.textColor = AgentWorkbenchTheme.secondaryText; status.stringValue = "读取依赖文件…"
        store.worktreeRetention.setNativeOperation(activity, taskID: taskID, busy: true)
        job = Task { [weak self] in
            guard let self else { return }
            defer {
                job = nil
                setScanning(false)
                refreshDatabase.state = .off
                store.worktreeRetention.setNativeOperation(activity, taskID: taskID, busy: false)
                updateEmptyState()
            }
            do {
                let result = try await service.scan(source: origin, requested: paths, forceUpdate: force) { self.status.stringValue = $0 }
                show(result, previous: false)
            } catch is CancellationError {
                status.stringValue = "已停止检查"
            } catch {
                status.textColor = AgentDialogStyle.error
                status.stringValue = error.localizedDescription
            }
        }
        updateEmptyState()
    }

    private func show(_ result: AgentDependencyReport?, previous: Bool) {
        report = result
        let summary = result.map { (previous ? "上次 · " : "") + $0.summary } ?? "待检查"
        status.stringValue = summary
        status.textColor = AgentWorkbenchTheme.secondaryText
        table.reloadData()
        table.deselectAll(nil)
        if numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateDetails()
        updateEmptyState()
        pageDidLayout()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { (report?.findings.count ?? 0) + (report?.skipped.count ?? 0) }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let report, let key = column?.identifier.rawValue else { return nil }
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingMiddle
        if report.findings.indices.contains(row) {
            let item = report.findings[row]
            switch key {
            case "risk":
                field.stringValue = item.severity
                field.textColor = (item.score ?? 0) >= 7 ? AgentDialogStyle.error : AgentWorkbenchTheme.secondaryText
            case "package":
                field.stringValue = item.package + " " + item.version
                field.font = .systemFont(ofSize: 13, weight: .medium)
                let advisory = NSTextField(labelWithString: item.aliases.first(where: { $0.hasPrefix("CVE-") }) ?? item.advisory)
                advisory.font = .systemFont(ofSize: 11.5); advisory.textColor = AgentWorkbenchTheme.secondaryText
                advisory.lineBreakMode = .byTruncatingMiddle
                let cell = NSStackView(views: [field, advisory]); cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 2
                cell.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
                for label in [field, advisory] {
                    label.toolTip = label.stringValue
                    label.stringValue = label.stringValue.replacingOccurrences(of: "\n", with: "↵")
                    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    label.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
                }
                return cell
            default: field.stringValue = item.path
            }
        } else {
            let item = report.skipped[row - report.findings.count]
            if key == "risk" { field.stringValue = "跳过" }
            if key == "package" { field.stringValue = item.reason }
            if key == "path" { field.stringValue = item.path }
            field.textColor = AgentWorkbenchTheme.secondaryText
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
            lines.append("\(finding.package) \(finding.version) · \(finding.ecosystem)")
            lines.append(finding.path)
            lines.append(([finding.advisory] + finding.aliases.filter { $0 != finding.advisory }).joined(separator: " · "))
            if let summary = finding.summary, !summary.isEmpty { lines.append(summary) }
            if let score = finding.score { lines.append("CVSS " + String(format: "%.1f", score)) }
            lines.append(finding.fixedVersions.isEmpty ? "公告未给出修复版本" : "修复版本  " + finding.fixedVersions.joined(separator: "、"))
        } else if let report, table.selectedRow >= report.findings.count, table.selectedRow - report.findings.count < report.skipped.count {
            let skipped = report.skipped[table.selectedRow - report.findings.count]
            lines.append(skipped.path + "\n" + skipped.reason)
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
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        details.textStorage?.setAttributedString(NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        details.setSelectedRange(NSRange(location: 0, length: 0))
        detailScroll.contentView.scroll(to: .zero); detailScroll.reflectScrolledClipView(detailScroll.contentView)
        pageDidLayout()
    }

    @objc private func openAdvisory() {
        if let url = selectedFinding?.advisoryURL, !NSWorkspace.shared.open(url) {
            status.textColor = AgentDialogStyle.error; status.stringValue = "无法打开公告"
        }
    }

    func workspaceReadback() -> [String: Any] {
        guard let content = pageContentView else { return [:] }
        func frame(_ view: NSView) -> [Double] {
            let value = view.convert(view.bounds, to: content)
            return [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        return [
            "usesTaskWindow": settingsHostWindow != nil && content.window === settingsHostWindow,
            "nativeSheet": presentingWindow?.attachedSheet != nil, "busy": job != nil,
            "size": [Double(content.bounds.width), Double(content.bounds.height)],
            "source": source.titleOfSelectedItem ?? "", "sourceEnabled": source.isEnabled,
            "scope": scope.titleOfSelectedItem ?? "", "scopeEnabled": scope.isEnabled,
            "sourceFrame": frame(sourceFrame), "scopeFrame": frame(scopeFrame),
            "rows": numberOfRows(in: table), "selectedRow": table.selectedRow,
            "columnWidths": table.tableColumns.map { Double($0.width) }, "tableWidth": Double(table.bounds.width),
            "tableViewport": [Double(list.contentSize.width), Double(list.contentSize.height)],
            "detail": details.string, "detailViewport": [Double(detailScroll.contentSize.width), Double(detailScroll.contentSize.height)],
            "detailOrigin": [Double(detailScroll.contentView.bounds.origin.x), Double(detailScroll.contentView.bounds.origin.y)],
            "emptyText": empty.stringValue, "emptyVisible": !empty.isHidden, "emptyFrame": frame(empty),
            "state": status.stringValue, "scanTitle": scanButton.title,
            "report": report.map { value -> [String: Any] in ["source": value.source.rawValue, "selectedOnly": value.selectedOnly, "created": value.created.timeIntervalSince1970, "files": value.scannedFiles, "packages": value.packages, "findings": value.findings.count, "skipped": value.skipped.count] } ?? [:],
            "advisoryURL": selectedFinding?.advisoryURL?.absoluteString ?? "",
            "controls": [sourceFrame, scopeFrame, refreshDatabase, scanButton, advisoryButton, done].map { view -> [String: Any] in
                let value = view.convert(view.bounds, to: content)
                return ["frame": frame(view), "inside": content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(value)]
            }
        ]
    }
}
