import AppKit

private final class AgentContextDocument: NSView { override var isFlipped: Bool { true } }

@MainActor final class AgentContextWindow: AgentSettingsPageController {
    private let runtime: AgentRuntime, taskID: String
    private let tabs = NSSegmentedControl(labels: ["上下文", "任务回顾", "请求记录"], trackingMode: .selectOne, target: nil, action: nil)
    private let source = NSPopUpButton(), body = NSStackView(), state = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let action = NSButton(title: "压缩上下文", target: nil, action: nil), stop = NSButton(title: "取消", target: nil, action: nil)
    private var rendered = ""
    init(runtime: AgentRuntime, taskID: String, section: Int = 0) {
        self.runtime = runtime; self.taskID = taskID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "任务详情"; window.minSize = NSSize(width: 490, height: 440); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        tabs.selectedSegment = min(2, max(0, section)); tabs.target = self; tabs.action = #selector(changeSection)
        source.addItems(withTitles: ["当前估算", "上次请求"]); source.target = self; source.action = #selector(changeSection); source.setAccessibilityLabel("上下文来源")
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12; body.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 20, right: 4)
        let document = AgentContextDocument(); body.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(body)
        scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), body.leadingAnchor.constraint(equalTo: document.leadingAnchor), body.trailingAnchor.constraint(equalTo: document.trailingAnchor), body.topAnchor.constraint(equalTo: document.topAnchor), body.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail; state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        action.target = self; action.action = #selector(performAction); stop.target = self; stop.action = #selector(cancelAction)
        let top = NSStackView(views: [tabs, NSView(), source]); top.spacing = 10
        let buttons = NSStackView(views: [NSView(), stop, action]); buttons.spacing = 10
        let footer = NSStackView(views: [state, buttons]); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 8
        for row in [state, buttons] { row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }
        for view in [top, scroll, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([top.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), scroll.leadingAnchor.constraint(equalTo: top.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: top.trailingAnchor), scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 18), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14), footer.leadingAnchor.constraint(equalTo: top.leadingAnchor), footer.trailingAnchor.constraint(equalTo: top.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func changeSection() { rendered = ""; refresh(); pageContentView?.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
    override func settingsDidAppear() { refresh() }
    func selectSection(_ section: Int) { tabs.selectedSegment = min(2, max(0, section)); changeSection() }
    var boundTaskID: String { taskID }
    func workspaceReadback() -> [String: Any] {
        guard AgentTaskWorkspace.readbackEnabled else { return [:] }
        return ["taskID": taskID, "section": tabs.selectedSegment, "source": source.indexOfSelectedItem, "text": body.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n"), "actionEnabled": action.isEnabled, "action": action.title, "state": state.stringValue, "mainWindow": pageContentView?.window === presentingWindow && settingsHostWindow != nil]
    }
    @objc private func performAction() { _ = runtime.analyze(taskID, recap: tabs.selectedSegment == 1); refresh() }
    @objc private func cancelAction() { runtime.cancel(taskID); refresh() }
    private func label(_ value: String, size: CGFloat = 13, bold: Bool = false, secondary: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: value); label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular); label.textColor = secondary ? AgentWorkbenchTheme.secondaryText : .labelColor; label.isSelectable = true
        body.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -8).isActive = true
    }
    private func rule() { let view = NSBox(); view.boxType = .separator; body.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -8).isActive = true }
    private func number(_ value: Int) -> String { value.formatted(.number) }
    private func date(_ value: Date) -> String { value.formatted(date: .abbreviated, time: .standard) }
    func refresh() {
        guard let task = runtime.store.task(taskID) else { return }
        let busy = runtime.isBusy(taskID), analysis = runtime.analysisTitle(taskID)
        source.isHidden = tabs.selectedSegment != 0
        source.item(at: 1)?.isEnabled = task.contextSnapshot != nil
        if source.indexOfSelectedItem == 1 && task.contextSnapshot == nil { source.selectItem(at: 0) }
        action.isHidden = tabs.selectedSegment == 2; action.title = tabs.selectedSegment == 1 ? (task.recap == nil ? "生成回顾" : "更新回顾") : "压缩上下文"
        let reason = tabs.selectedSegment == 0 ? AgentContext.compactUnavailable(task) : task.messages.isEmpty ? "任务尚无对话记录" : nil
        action.isEnabled = !busy && reason == nil && !task.archived && task.pendingCalls.isEmpty && task.kind != "hook"
        action.toolTip = busy ? "请先停止执行" : reason
        stop.isHidden = analysis == nil
        state.stringValue = analysis ?? (action.isHidden ? "" : runtime.analysisError(taskID, recap: tabs.selectedSegment == 1) ?? reason ?? "")
        state.toolTip = state.stringValue
        // Runtime changes drive refreshes; no polling or extra model requests.
        let fingerprint = [String(tabs.selectedSegment), String(source.indexOfSelectedItem), String(task.updated.timeIntervalSince1970), analysis ?? ""].joined(separator: ":")
        guard rendered != fingerprint else { return }; rendered = fingerprint
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        if tabs.selectedSegment == 0 {
            do {
                let snapshot: AgentContextSnapshot
                if source.indexOfSelectedItem == 1, let saved = task.contextSnapshot { snapshot = saved }
                else { snapshot = try runtime.contextEstimate(taskID) }
                label(snapshot.model, size: 20, bold: true)
                let percent = Int((Double(snapshot.estimatedTokens) / Double(max(1, snapshot.limit)) * 100).rounded(.up))
                label("约 \(number(snapshot.estimatedTokens)) / \(number(snapshot.limit)) tokens · \(percent)%", size: 15, bold: true)
                label("回复预留 \(number(snapshot.outputReserve)) tokens" + (source.indexOfSelectedItem == 1 ? " · " + date(snapshot.created) : ""), secondary: true)
                for part in snapshot.parts {
                    let title = NSTextField(labelWithString: part.title + (part.title == "Skills" ? " · \(snapshot.loadedSkills) 项已载入" : ""))
                    title.font = .systemFont(ofSize: 12); title.widthAnchor.constraint(equalToConstant: 144).isActive = true
                    let bar = NSProgressIndicator(); bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = Double(max(1, snapshot.limit)); bar.doubleValue = Double(part.tokens); bar.setAccessibilityLabel(part.title + "估算")
                    let value = NSTextField(labelWithString: number(part.tokens)); value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); value.alignment = .right; value.widthAnchor.constraint(equalToConstant: 64).isActive = true
                    let row = NSStackView(views: [title, bar, value]); row.spacing = 12; body.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -8).isActive = true
                }
                rule(); label("累计已报告用量", bold: true)
                label("输入 \(number(task.inputTokens)) · 输出 \(number(task.outputTokens)) tokens")
                label("上下文占用为估算；实际用量见请求记录。", size: 11, secondary: true)
                if let summary = task.contextSummary { rule(); label("当前工作记忆", bold: true); label(summary) }
            } catch { label(error.localizedDescription) }
        } else if tabs.selectedSegment == 1 {
            label(task.title, size: 20, bold: true)
            let tools = task.events.filter { $0.kind == "tool" }
            label(task.statusTitle + " · \(tools.filter { $0.status == "completed" }.count) 次工具成功 · \(tools.filter { $0.status == "failed" }.count) 次失败", secondary: true)
            label("创建 " + date(task.created) + "\n更新 " + date(task.updated), size: 11, secondary: true)
            if let recap = task.recap {
                rule(); label(recap.text)
                label(recap.model + " · " + date(recap.created) + (recap.throughMessageID != task.messages.last?.id ? " · 有新记录，待更新" : ""), size: 11, secondary: true)
            }
            if !task.plan.isEmpty { rule(); label("计划", bold: true); label(task.plan.map { ($0.status == "completed" ? "✓ " : "○ ") + $0.title }.joined(separator: "\n")) }
            let children = runtime.store.tasks.filter { $0.agent?.ownerID == taskID }
            if !children.isEmpty { rule(); label("子任务", bold: true); label(children.map { $0.title + " · " + $0.statusTitle }.joined(separator: "\n")) }
            if !task.artifacts.isEmpty { rule(); label("产物", bold: true); label(task.artifacts.joined(separator: "\n")) }
            if !task.sources.isEmpty { rule(); label("来源", bold: true); label(task.sources.joined(separator: "\n")) }
        } else {
            let receipts = task.modelReceipts ?? []
            label("请求记录", size: 20, bold: true)
            label("输入 \(number(task.inputTokens)) · 输出 \(number(task.outputTokens)) tokens", secondary: true)
            let missing = receipts.filter { $0.inputTokens == nil || $0.outputTokens == nil }.count
            if missing > 0 { label("\(missing) 次请求未返回完整用量", size: 11, secondary: true) }
            let legacyInput = max(0, task.inputTokens - receipts.reduce(0) { $0 + ($1.inputTokens ?? 0) }), legacyOutput = max(0, task.outputTokens - receipts.reduce(0) { $0 + ($1.outputTokens ?? 0) })
            if legacyInput > 0 || legacyOutput > 0 { label("未分模型的历史用量：输入 \(number(legacyInput)) · 输出 \(number(legacyOutput))", size: 11, secondary: true) }
            if receipts.isEmpty { label("暂无分次记录", secondary: true) }
            for receipt in receipts.reversed() {
                rule(); label(receipt.requestedModel + " · " + receipt.purposeTitle, bold: true)
                label("服务返回：" + (receipt.returnedModel ?? "未提供模型标识"), size: 12)
                label("输入 \(receipt.inputTokens.map(number) ?? "未报告") · 输出 \(receipt.outputTokens.map(number) ?? "未报告") tokens", size: 12)
                label(date(receipt.created) + " · \(String(format: "%.1f", receipt.duration)) 秒 · " + receipt.finishReason + (receipt.completed ? "" : " · 响应未完成"), size: 11, secondary: true)
            }
        }
    }
}
