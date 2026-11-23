import AppKit

private final class AgentContextDocument: NSView { override var isFlipped: Bool { true } }

@MainActor final class AgentContextWindow: AgentSettingsPageController {
    private enum Mode: String, CaseIterable { case estimate, sent, recap, receipts }
    private struct Position: Codable, Equatable {
        var anchor: String?
        var y: Double, offset: Double
        var valid: Bool {
            AgentSettingsRecovery.validScroll(y) && offset.isFinite && abs(offset) <= 1_000_000_000 &&
                anchor.map { !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0") } != false
        }
    }
    private struct ReadingState: Codable {
        var version = 1
        var section: Int, source: Int
        var positions: [String: Position]
        var valid: Bool {
            version == 1 && (0...2).contains(section) && (0...1).contains(source) &&
                positions.allSatisfy { Mode(rawValue: $0.key) != nil && $0.value.valid }
        }
    }

    private let runtime: AgentRuntime, taskID: String
    private let tabs = NSSegmentedControl(labels: ["上下文", "任务回顾", "请求记录"], trackingMode: .selectOne, target: nil, action: nil)
    private let source = NSPopUpButton()
    private lazy var sourceFrame = AgentSettingsPopupFrame(source)
    private let body = NSStackView(), scroll = NSScrollView(), footer = NSStackView()
    private let state = AgentSettingsStatusField("任务详情状态")
    private let action = AgentDialogButton(title: "压缩上下文", target: nil, action: nil)
    private let stop = AgentDialogButton(title: "停止", target: nil, action: nil)
    private var rendered: String?, displayedMode: Mode?
    private var anchors: [(String, NSView)] = []
    private var positions: [String: Position] = [:]
    private var pendingPosition: Position?
    private var updatingViewport = false
    var recapModel: (() -> String?)?

    init(runtime: AgentRuntime, taskID: String, section: Int = 0) {
        self.runtime = runtime; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "任务详情"; window.minSize = NSSize(width: 490, height: 440); window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = AgentWorkspacePageView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        tabs.selectedSegment = min(2, max(0, section)); tabs.target = self; tabs.action = #selector(changeSection)
        tabs.setAccessibilityLabel("任务详情页签")
        tabs.font = .systemFont(ofSize: 13, weight: .medium)
        tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
        source.addItems(withTitles: ["当前估算", "上次请求"]); source.target = self; source.action = #selector(changeSection)
        source.autoenablesItems = false
        source.setAccessibilityLabel("上下文来源")
        let header = NSStackView(views: [tabs, NSView(), sourceFrame])
        header.alignment = .centerY; header.spacing = 8; header.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let document = AgentContextDocument()
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 18
        body.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(body)
        scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay; scroll.setAccessibilityLabel("任务详情内容")
        scroll.contentView.postsBoundsChangedNotifications = true
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)
        ])

        action.target = self; action.action = #selector(performAction); AgentSettingsStyle.primaryAction(action)
        stop.target = self; stop.action = #selector(cancelAction); AgentDialogStyle.action(stop)
        let actions = NSStackView(views: [NSView(), stop, action]); actions.alignment = .centerY; actions.spacing = 8
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 8
        for item in [state, actions] {
            footer.addArrangedSubview(item); item.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        let column = NSStackView(views: [header, scroll, footer])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 10
        content.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        for item in column.arrangedSubviews { item.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let preferredWidth = column.widthAnchor.constraint(equalToConstant: 760)
        preferredWidth.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor), preferredWidth,
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        content.onResize = { [weak self, weak column] in self?.state.preferredMaxLayoutWidth = column?.bounds.width ?? 0 }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private var mode: Mode {
        switch tabs.selectedSegment {
        case 1: return .recap
        case 2: return .receipts
        default: return source.indexOfSelectedItem == 1 ? .sent : .estimate
        }
    }
    @objc private func changeSection() { refresh(); onSettingsRecoveryChange?() }
    override func settingsDidAppear() {
        tabs.selectedSegmentBezelColor = AgentWorkbenchTheme.accent
        source.font = .systemFont(ofSize: 13)
        refresh()
        restoreReadingPosition()
    }
    override func settingsWillLeave() { rememberReadingPosition() }
    func selectSection(_ section: Int) {
        let value = min(2, max(0, section))
        guard tabs.selectedSegment != value else { return }
        tabs.selectedSegment = value; changeSection()
    }
    var boundTaskID: String { taskID }

    private func top(of view: NSView) -> Double {
        Double(scroll.documentView?.convert(view.bounds, from: view).minY ?? 0)
    }
    private func currentPosition() -> Position? {
        guard isPageVisible, scroll.contentView.bounds.height > 0, pendingPosition == nil else { return nil }
        let y = max(0, scroll.contentView.bounds.minY)
        let anchor = y > 0 ? anchors.last(where: { top(of: $0.1) <= y }) : nil
        return Position(anchor: anchor?.0, y: y, offset: anchor.map { y - top(of: $0.1) } ?? 0)
    }
    @objc private func scrolled(_ notification: Notification) { rememberReadingPosition() }
    private func rememberReadingPosition() {
        guard !updatingViewport, let displayedMode, let position = currentPosition(),
              position != positions[displayedMode.rawValue] else { return }
        positions[displayedMode.rawValue] = position; onSettingsRecoveryChange?()
    }
    private func restoreReadingPosition() {
        guard let position = pendingPosition, isPageVisible else { return }
        pageContentView?.layoutSubtreeIfNeeded()
        guard scroll.contentView.bounds.height > 0 else { return }
        let anchor = anchors.first(where: { $0.0 == position.anchor })?.1
        let y = anchor.map { top(of: $0) + position.offset } ?? position.y
        AgentSettingsRecovery.restoreScroll(max(0, y), to: scroll)
        pendingPosition = nil
    }
    func captureWorkspaceRecovery() throws -> AgentWorkspaceRecovery.Page {
        var saved = positions
        if let current = currentPosition() { saved[mode.rawValue] = current }
        let value = ReadingState(section: tabs.selectedSegment, source: source.indexOfSelectedItem, positions: saved)
        guard value.valid else { throw PetError("任务详情阅读位置无效") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(taskID: taskID, kind: "context-position", state: try encoder.encode(value), dirty: false, asset: nil)
    }
    func restoreWorkspaceRecovery(_ page: AgentWorkspaceRecovery.Page) throws {
        guard page.kind == "context-position", page.taskID == taskID, !page.dirty, page.asset == nil else {
            throw PetError("任务详情位置与原任务不符")
        }
        let object = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "section", "source", "positions"])
        if let positions = object["positions"] as? [String: Any] {
            for position in positions.values {
                _ = try AgentSettingsRecovery.object(position, keys: ["anchor", "y", "offset"])
            }
        }
        let value = try JSONDecoder().decode(ReadingState.self, from: page.state)
        guard value.valid else { throw PetError("任务详情位置无效，原记录已保留") }
        positions = value.positions; tabs.selectedSegment = value.section; source.selectItem(at: value.source)
        displayedMode = nil; rendered = nil
        refresh()
    }

    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled, let content = pageContentView else { return [:] }
        func text(in view: NSView) -> [String] {
            if let field = view as? NSTextField { return [field.stringValue] }
            return view.subviews.flatMap { text(in: $0) }
        }
        let position = currentPosition()
        func fits(_ view: NSView) -> Bool {
            view.isHiddenOrHasHiddenAncestor || content.bounds.insetBy(dx: -1, dy: -1).contains(view.convert(view.bounds, to: content))
        }
        return ["taskID": taskID, "section": tabs.selectedSegment, "source": source.indexOfSelectedItem,
                "text": text(in: body).joined(separator: "\n"), "actionEnabled": action.isEnabled, "action": action.title,
                "state": state.stringValue, "mainWindow": content.window === presentingWindow && settingsHostWindow != nil,
                "scroll": position?.y ?? 0, "anchor": position?.anchor ?? "", "anchorOffset": position?.offset ?? 0,
                "controlsFit": fits(tabs) && (sourceFrame.isHidden || fits(sourceFrame)) &&
                    (footer.isHidden || fits(action) && fits(stop) && fits(state)),
                "footerVisible": !footer.isHidden, "readingHeight": Double(scroll.contentSize.height)]
    }

    @objc private func performAction() { _ = runtime.analyze(taskID, recap: mode == .recap, model: recapModel?()); refresh() }
    @objc private func cancelAction() {
        if runtime.analysisTitle(taskID) != nil { runtime.interrupt(taskID) }
        refresh()
    }
    private func label(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = secondary ? AgentWorkbenchTheme.secondaryText : .labelColor
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func group(_ id: String, _ title: String, _ rows: [NSView], separatesRows: Bool = false) {
        let section = AgentSettingsStyle.section(title, id: id, rows: rows, separatesRows: separatesRows)
        body.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if id != "requests" { anchors.append((id, section)) }
    }
    private func number(_ value: Int) -> String { value.formatted(.number) }
    private func date(_ value: Date) -> String { value.formatted(date: .abbreviated, time: .standard) }
    private func usage(_ input: String, _ output: String) -> String { "输入 " + input + " · 输出 " + output + " tokens" }

    private func analysisUnavailable(_ task: AgentTaskRecord, recap: Bool, busy: Bool) -> String? {
        if task.archived { return "任务已归档" }
        if task.kind == "hook" { return "钩子任务不支持分析" }
        if busy { return "请先停止执行" }
        if !task.pendingCalls.isEmpty || task.status == .waiting { return "请先处理待确认操作" }
        if recap { return task.messages.isEmpty ? "任务尚无对话记录" : nil }
        return AgentContext.compactUnavailable(task)
    }

    func refresh() {
        guard let task = runtime.store.task(taskID) else { return }
        let busy = runtime.isBusy(taskID), analysis = runtime.analysisTitle(taskID)
        source.item(at: 1)?.isEnabled = task.contextSnapshot != nil
        if source.indexOfSelectedItem == 1 && task.contextSnapshot == nil { source.selectItem(at: 0) }
        sourceFrame.isHidden = tabs.selectedSegment != 0
        let mode = mode, recap = mode == .recap
        action.isHidden = mode == .receipts; action.title = recap ? (task.recap == nil ? "生成回顾" : "更新回顾") : "压缩上下文"
        let reason = analysisUnavailable(task, recap: recap, busy: busy)
        action.isEnabled = !action.isHidden && reason == nil
        action.toolTip = reason
        stop.isHidden = analysis == nil
        let problem = action.isHidden ? nil : runtime.analysisError(taskID, recap: recap)
        let interrupted = !recap && task.events.last(where: { $0.kind == "context" })?.status == "stopped"
        let lastCompactionStatus = interrupted ? "上次压缩已中断" : nil
        let status = analysis ?? (action.isHidden ? "" : problem ?? reason ?? lastCompactionStatus ?? "")
        if state.stringValue != status { state.stringValue = status }
        state.textColor = problem != nil && analysis == nil ? AgentDialogStyle.error : AgentWorkbenchTheme.secondaryText
        footer.isHidden = action.isHidden && stop.isHidden && state.isHidden

        // Receipts are appended only after a request reports its outcome.
        // Streaming changes elsewhere in the record must not rebuild this list.
        let receipts = task.modelReceipts ?? []
        let fingerprint = mode == .receipts
            ? "\(mode.rawValue):\(receipts.count):\(receipts.last?.id ?? ""):\(task.inputTokens):\(task.outputTokens)"
            : "\(mode.rawValue):\(task.updated.timeIntervalSinceReferenceDate):\(analysis ?? "")"
        guard rendered != fingerprint else { return }
        if let displayedMode, let previous = currentPosition() { positions[displayedMode.rawValue] = previous }
        updatingViewport = true; defer { updatingViewport = false }
        rendered = fingerprint; displayedMode = mode
        anchors.removeAll()
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        switch mode {
        case .estimate, .sent: renderContext(task, mode: mode)
        case .recap: renderRecap(task)
        case .receipts: renderReceipts(task, receipts: receipts)
        }
        pendingPosition = positions[mode.rawValue] ?? Position(y: 0, offset: 0)
        restoreReadingPosition()
    }
    private func renderContext(_ task: AgentTaskRecord, mode: Mode) {
        do {
            let snapshot: AgentContextSnapshot
            if mode == .sent, let saved = task.contextSnapshot { snapshot = saved }
            else { snapshot = try runtime.contextEstimate(taskID) }
            let percent = Int((Double(snapshot.estimatedTokens) / Double(max(1, snapshot.limit)) * 100).rounded(.up))
            var rows: [NSView] = [
                label(snapshot.model, size: 16, weight: .semibold),
                label("估算 \(number(snapshot.estimatedTokens)) / \(number(snapshot.limit)) tokens · \(percent)%", weight: .medium),
                label("回复预留 \(number(snapshot.outputReserve)) tokens" + (mode == .sent ? " · " + date(snapshot.created) : ""), size: 12, secondary: true)
            ]
            rows.append(AgentSettingsStyle.divider())
            for part in snapshot.parts {
                let title = label(part.title + (part.title == "Skills" ? " · \(snapshot.loadedSkills) 项" : ""), size: 12)
                title.widthAnchor.constraint(equalToConstant: 132).isActive = true
                let bar = NSProgressIndicator(); bar.style = .bar; bar.isIndeterminate = false
                bar.minValue = 0; bar.maxValue = Double(max(1, snapshot.limit)); bar.doubleValue = Double(part.tokens)
                bar.setAccessibilityLabel(part.title + "估算")
                let value = NSTextField(labelWithString: number(part.tokens))
                value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); value.alignment = .right
                value.widthAnchor.constraint(equalToConstant: 64).isActive = true
                let row = NSStackView(views: [title, bar, value]); row.alignment = .centerY; row.spacing = 10
                rows.append(row)
            }
            group("estimate", "上下文占用", rows)
        } catch {
            let issue = label(error.localizedDescription); issue.textColor = AgentDialogStyle.error
            group("estimate", "上下文占用", [issue])
        }
        group("usage", "累计已报告用量", [label(usage(number(task.inputTokens), number(task.outputTokens)))])
        if let summary = task.contextSummary { group("summary", "当前工作记忆", [label(summary)]) }
    }
    private func renderRecap(_ task: AgentTaskRecord) {
        let tools = task.events.filter { $0.kind == "tool" }
        group("task", "", [label(task.title, size: 17, weight: .semibold),
             label(task.statusTitle + " · \(tools.filter { $0.status == "completed" }.count) 次工具成功 · \(tools.filter { $0.status == "failed" }.count) 次失败"),
             label("创建 " + date(task.created) + " · 更新 " + date(task.updated), size: 12, secondary: true)])
        if let recap = task.recap {
            group("recap", "回顾", [label(recap.text),
                label(recap.model + " · " + date(recap.created) + (recap.throughMessageID != task.messages.last?.id ? " · 有新记录，待更新" : ""), size: 12, secondary: true)])
        }
        if !task.plan.isEmpty { group("plan", "计划", [label(task.plan.map { ($0.status == "completed" ? "✓ " : "○ ") + $0.title }.joined(separator: "\n"))]) }
        let children = runtime.store.tasks.filter { $0.agent?.ownerID == taskID }
        if !children.isEmpty { group("children", "子任务", [label(children.map { $0.title + " · " + $0.statusTitle }.joined(separator: "\n"))]) }
        if !task.artifacts.isEmpty { group("artifacts", "产物", [label(task.artifacts.joined(separator: "\n"))]) }
        if !task.sources.isEmpty { group("sources", "来源", [label(task.sources.joined(separator: "\n"))]) }
    }
    private func renderReceipts(_ task: AgentTaskRecord, receipts: [AgentModelReceipt]) {
        var totals = [label(usage(number(task.inputTokens), number(task.outputTokens)), weight: .medium)]
        let missing = receipts.filter { $0.inputTokens == nil || $0.outputTokens == nil }.count
        if missing > 0 { totals.append(label("\(missing) 次请求未返回完整用量", size: 12, secondary: true)) }
        let legacyInput = max(0, task.inputTokens - receipts.reduce(0) { $0 + ($1.inputTokens ?? 0) })
        let legacyOutput = max(0, task.outputTokens - receipts.reduce(0) { $0 + ($1.outputTokens ?? 0) })
        if legacyInput > 0 || legacyOutput > 0 {
            totals.append(label("未分模型的历史用量 · " + usage(number(legacyInput), number(legacyOutput)), size: 12, secondary: true))
        }
        group("totals", "累计已报告用量", totals)
        if receipts.isEmpty { group("requests", "", [label("暂无分次记录", secondary: true)]); return }
        let rows = receipts.reversed().map { receipt in
            let title = label(receipt.requestedModel + " · " + receipt.purposeTitle, weight: .semibold)
            let returned = label("服务返回 " + (receipt.returnedModel ?? "未提供模型标识"), size: 12, secondary: true)
            let counts = label(usage(receipt.inputTokens.map(number) ?? "未报告", receipt.outputTokens.map(number) ?? "未报告"))
            let status = label(date(receipt.created) + " · " + String(format: "%.1f", receipt.duration) + " 秒 · " + receipt.finishReason + (receipt.completed ? "" : " · 响应未完成"), size: 12, secondary: true)
            if !receipt.completed { status.textColor = AgentDialogStyle.error }
            let row = NSStackView(views: [title, returned, counts, status]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
            for view in row.arrangedSubviews { view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
            anchors.append((receipt.id, row))
            return row
        }
        group("requests", "", rows, separatesRows: true)
    }
}

@MainActor final class AgentImportSourcePage: AgentSettingsPageController {
    let taskID: String
    private let store: AgentStore, origin: AgentImportOrigin
    private let status = NSTextField(wrappingLabelWithString: "")

    init(store: AgentStore, taskID: String, origin: AgentImportOrigin) {
        self.store = store
        self.taskID = taskID
        self.origin = origin
        let bounds = NSRect(x: 0, y: 0, width: 620, height: 500)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "导入来源"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface)
        window.contentView = content
        let heading = NSTextField(labelWithString: origin.source.title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let reveal = AgentDialogButton(title: "在访达中显示", target: self, action: #selector(revealSource))
        reveal.setAccessibilityIdentifier("import-source-reveal")
        AgentDialogStyle.action(reveal)
        let header = NSStackView(views: [heading, NSView(), reveal])
        header.alignment = .centerY
        header.spacing = 8
        status.font = .systemFont(ofSize: 12)
        status.textColor = AgentDialogStyle.error
        status.isHidden = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fields = NSStackView()
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 10
        fields.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 14, right: 2)
        func label(_ text: String, heading: Bool = false) {
            let line = NSTextField(wrappingLabelWithString: text)
            line.font = .systemFont(ofSize: 13, weight: heading ? .semibold : .regular)
            line.isSelectable = !heading
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fields.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -2).isActive = true
        }
        label("原工作目录", heading: true)
        label(origin.originalWorkspace ?? "无")
        label("来源文件", heading: true)
        label(origin.sshHost.map { $0 + ":" + origin.sourceFile } ?? origin.sourceFile)
        if !origin.warnings.isEmpty {
            label("导入提示", heading: true)
            origin.warnings.forEach { label($0) }
        }

        let document = AgentContextDocument(), scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel("导入来源内容")
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(fields)
        fields.translatesAutoresizingMaskIntoConstraints = false
        let layout = NSStackView(views: [header, status, scroll])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 12
        content.addSubview(layout)
        layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: layout.widthAnchor),
            status.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            fields.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            fields.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            fields.topAnchor.constraint(equalTo: document.topAnchor),
            fields.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func settingsDidAppear() { _ = currentSource() }

    @objc private func revealSource() {
        if let url = currentSource() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func currentSource() -> URL? {
        do {
            guard let current = store.task(taskID)?.importOrigin, current.key == origin.key, current.snapshot == origin.snapshot else {
                throw PetError("导入来源已变化，请关闭此标签页后重新打开")
            }
            let url = try store.dataImport.sourceURL(taskID)
            status.isHidden = true
            return url
        } catch {
            status.stringValue = error.localizedDescription
            status.isHidden = false
            return nil
        }
    }
}
