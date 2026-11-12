import AppKit
import UniformTypeIdentifiers

private extension AgentHookEvent {
    var meaning: String {
        switch self {
        case .sessionStart: return "新任务开始时"
        case .sessionEnd: return "任务会话结束时"
        case .prompt: return "提交提示词时"
        case .preTool: return "工具执行前"
        case .postTool: return "工具执行成功后"
        case .toolFailure: return "工具执行失败后"
        case .permission: return "请求执行授权时"
        case .denied: return "执行授权被拒绝时"
        case .stop: return "Agent 结束本轮响应前"
        case .stopFailure: return "结束响应失败时"
        case .preCompact: return "压缩上下文前"
        case .postCompact: return "压缩上下文后"
        case .cwd: return "工作目录变化时"
        case .instructions: return "任务指令载入时"
        case .file: return "项目文件变化时"
        case .notification: return "任务通知产生时"
        case .subagentStart: return "子 Agent 开始时"
        case .subagentStop: return "子 Agent 结束时"
        case .worktreeCreate: return "工作树创建时"
        case .worktreeRemove: return "工作树回收时"
        }
    }
}

@MainActor final class AgentHookWindow: AgentSettingsPageController {
    private let service: AgentHooks
    private let workspace: String?
    private let command = NSTextView(), groups = NSStackView(), detail = NSStackView()
    private let enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let state = NSTextField(labelWithString: ""), location = NSTextField(labelWithString: ""), selectionState = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: ""), empty = NSTextField(labelWithString: "暂无 Hooks")
    private let scope = NSPopUpButton(), reveal = NSButton(title: "打开来源", target: nil, action: nil)
    private let clear = NSButton(title: "清除凭据", target: nil, action: nil)
    private let editSelected = NSButton(title: "编辑配置", target: nil, action: nil)
    private let card = AgentThemeView(fill: .textBackgroundColor, stroke: AgentWorkbenchTheme.line)
    private var items: [AgentHookDefinition] = [], selected: AgentHookDefinition?
    private var expanded: Set<AgentHookEvent> = []
    private var configWindow: AgentHookConfigWindow?
    private var reviewPage: AgentSettingsReviewPage?
    init(service: AgentHooks, workspace: String?) {
        self.service = service; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Hooks" + (workspace.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""); window.minSize = NSSize(width: 560, height: 420); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = AgentThemeView(fill: AgentWorkbenchTheme.surface); window.contentView = content
        scope.addItems(withTitles: ["全局", "当前项目"]); scope.item(at: 1)?.isEnabled = workspace != nil; scope.setAccessibilityLabel("Hooks 配置范围")
        let edit = NSButton(title: "编辑配置", target: self, action: #selector(editConfig)), importButton = NSButton(title: "导入", target: self, action: #selector(importConfig)), refresh = NSButton(title: "刷新", target: self, action: #selector(refreshList))
        edit.setAccessibilityLabel("编辑当前范围的 Hooks 配置")
        let header = NSStackView(views: [count, NSView(), scope, edit, importButton, refresh]); header.spacing = 8
        count.font = .systemFont(ofSize: 12); count.textColor = AgentWorkbenchTheme.secondaryText; count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let scroll = NSScrollView(), document = FormDocumentView(); scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        scroll.identifier = NSUserInterfaceItemIdentifier("hook-event-groups"); scroll.setAccessibilityLabel("Hooks 事件分组")
        document.translatesAutoresizingMaskIntoConstraints = false
        card.layer?.cornerRadius = 12; card.layer?.borderWidth = 1
        groups.orientation = .vertical; groups.alignment = .leading; groups.spacing = 0
        card.addSubview(groups); document.addSubview(card); document.addSubview(empty)
        for view in [groups, card, empty] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), document.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            card.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4), card.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4), card.topAnchor.constraint(equalTo: document.topAnchor, constant: 4), card.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            groups.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), groups.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16), groups.topAnchor.constraint(equalTo: card.topAnchor), groups.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), empty.topAnchor.constraint(equalTo: document.topAnchor, constant: 20)
        ])
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        reveal.target = self; reveal.action = #selector(revealSource)
        clear.target = self; clear.action = #selector(clearCredentials)
        command.isEditable = false; command.isRichText = false; command.font = .monospacedSystemFont(ofSize: 12, weight: .regular); command.textColor = .labelColor; command.textContainerInset = NSSize(width: 12, height: 12)
        command.isVerticallyResizable = true; command.autoresizingMask = [.width]; command.textContainer?.widthTracksTextView = true; command.setAccessibilityLabel("Hook 处理器")
        let viewer = NSScrollView(); viewer.documentView = command; viewer.hasVerticalScroller = true; viewer.borderType = .noBorder
        for label in [location, state, empty, selectionState] { label.font = .systemFont(ofSize: 12); label.textColor = AgentWorkbenchTheme.secondaryText; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        location.lineBreakMode = .byTruncatingMiddle; state.lineBreakMode = .byTruncatingTail
        editSelected.target = self; editSelected.action = #selector(editSelectedConfig); editSelected.setAccessibilityLabel("编辑所选 Hook 配置")
        let actions = NSStackView(views: [enabled, NSView(), clear, reveal, editSelected]); actions.spacing = 8
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 10
        for view in [actions, location, viewer, selectionState] { detail.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        viewer.heightAnchor.constraint(equalToConstant: 160).isActive = true
        detail.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 18, right: 0)
        for view in [header, scroll, state] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 4), header.heightAnchor.constraint(equalToConstant: 30),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), scroll.bottomAnchor.constraint(equalTo: state.topAnchor, constant: -8),
            state.leadingAnchor.constraint(equalTo: header.leadingAnchor), state.trailingAnchor.constraint(equalTo: header.trailingAnchor), state.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4), state.heightAnchor.constraint(equalToConstant: 18)
        ]); reload()
    }
    var scopeWorkspace: String? { workspace }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func disclosure(title: String, subtitle: String, symbol: String, badge: String = "", open: Bool, action: Selector, tag: Int) -> NSButton {
        let button = AgentWorkbenchButton(title: "", target: self, action: action); button.tag = tag; button.isBordered = false
        button.setAccessibilityLabel(title + (badge.isEmpty ? "" : "，\(badge) 个处理器") + "，" + subtitle); button.setAccessibilityValue(open ? "已展开" : "已收起")
        let emblem = AgentThemeView(fill: AgentWorkbenchTheme.subtle, stroke: AgentWorkbenchTheme.line); emblem.layer?.cornerRadius = 8; emblem.layer?.borderWidth = 1
        let icon = NSImageView(); icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil); icon.contentTintColor = AgentWorkbenchTheme.secondaryText
        let name = NSTextField(labelWithString: title); name.font = .systemFont(ofSize: 13); name.lineBreakMode = .byTruncatingTail; name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let number = NSTextField(labelWithString: badge); number.font = .systemFont(ofSize: 11); number.textColor = AgentWorkbenchTheme.secondaryText; number.isHidden = badge.isEmpty
        let top = NSStackView(views: [name, number, NSView()]); top.spacing = 8
        let note = NSTextField(labelWithString: subtitle); note.font = .systemFont(ofSize: 12); note.textColor = AgentWorkbenchTheme.secondaryText; note.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [top, note]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        let arrow = NSImageView(); arrow.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil); arrow.contentTintColor = AgentWorkbenchTheme.secondaryText
        for view in [emblem, text, arrow] { button.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; view.setAccessibilityElement(false) }
        emblem.addSubview(icon); icon.translatesAutoresizingMaskIntoConstraints = false
        for label in [name, number, note] { label.setAccessibilityElement(false) }
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 70), emblem.leadingAnchor.constraint(equalTo: button.leadingAnchor), emblem.centerYAnchor.constraint(equalTo: button.centerYAnchor), emblem.widthAnchor.constraint(equalToConstant: 28), emblem.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: emblem.centerXAnchor), icon.centerYAnchor.constraint(equalTo: emblem.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: emblem.trailingAnchor, constant: 12), text.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -12), text.centerYAnchor.constraint(equalTo: button.centerYAnchor), top.widthAnchor.constraint(equalTo: text.widthAnchor), note.widthAnchor.constraint(equalTo: text.widthAnchor),
            arrow.trailingAnchor.constraint(equalTo: button.trailingAnchor), arrow.centerYAnchor.constraint(equalTo: button.centerYAnchor), arrow.widthAnchor.constraint(equalToConstant: 12), arrow.heightAnchor.constraint(equalToConstant: 12)
        ]); return button
    }
    private func renderGroups() {
        detail.removeFromSuperview()
        for view in groups.arrangedSubviews { groups.removeArrangedSubview(view); view.removeFromSuperview() }
        let order: [AgentHookEvent] = [.sessionStart, .subagentStart] + AgentHookEvent.allCases.filter { ![.sessionStart, .subagentStart].contains($0) }
        let events = order.filter { event in items.contains { $0.event == event } }
        for (index, event) in events.enumerated() {
            if index > 0 { let rule = AgentWorkbenchTheme.rule(); groups.addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: groups.widthAnchor).isActive = true }
            let handlers = items.enumerated().filter { $0.element.event == event }
            let header = disclosure(title: event.rawValue, subtitle: event.meaning, symbol: "link", badge: String(handlers.count), open: expanded.contains(event), action: #selector(toggleEvent(_:)), tag: AgentHookEvent.allCases.firstIndex(of: event)!)
            header.setAccessibilityIdentifier("hook-event-" + event.rawValue)
            groups.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: groups.widthAnchor).isActive = true
            guard expanded.contains(event) else { continue }
            let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 0; body.edgeInsets = NSEdgeInsets(top: 0, left: 40, bottom: 0, right: 0)
            groups.addArrangedSubview(body); body.widthAnchor.constraint(equalTo: groups.widthAnchor).isActive = true
            for (row, item) in handlers {
                let label = !service.enabled(item) ? "已停用" : service.trusted(item) ? "已启用" : "待审核"
                let current = selected?.id == item.id
                let button = disclosure(title: item.name, subtitle: item.scope + " · " + item.type + " · " + label, symbol: item.type == "http" ? "network" : ["prompt", "agent"].contains(item.type) ? "sparkles" : "terminal", open: current, action: #selector(selectHandler(_:)), tag: row)
                button.setAccessibilityIdentifier("hook-handler-" + item.id); button.toolTip = item.matcher
                body.addArrangedSubview(button); button.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40).isActive = true
                if current { body.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40).isActive = true }
            }
        }
        card.isHidden = events.isEmpty; empty.isHidden = !events.isEmpty
        if let content = pageContentView, settingsHostWindow != nil { content.effectiveAppearance.performAsCurrentDrawingAppearance { AgentSettingsStyle.prepare(content) } }
    }
    @objc private func toggleEvent(_ sender: NSButton) {
        let event = AgentHookEvent.allCases[sender.tag]
        if expanded.contains(event) { expanded.remove(event) } else { expanded.insert(event) }
        renderGroups(); presentingWindow?.makeFirstResponder(disclosureButton("hook-event-" + event.rawValue))
    }
    @objc private func selectHandler(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        selected = selected?.id == items[sender.tag].id ? nil : items[sender.tag]
        showSelection(); renderGroups(); presentingWindow?.makeFirstResponder(disclosureButton("hook-handler-" + items[sender.tag].id))
    }
    private func disclosureButton(_ identifier: String) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
            for child in view.subviews { if let button = find(child) { return button } }; return nil
        }
        return find(groups)
    }
    private func showSelection() {
        enabled.isEnabled = selected != nil && selected?.pluginEnabled != false; reveal.isEnabled = selected != nil
        editSelected.isEnabled = canEditSelected
        editSelected.toolTip = canEditSelected ? nil : "共享配置请通过“打开来源”编辑。"
        clear.isHidden = !["http", "command"].contains(selected?.type ?? ""); clear.isEnabled = selected?.headerNames?.isEmpty == false || selected?.environmentNames?.isEmpty == false
        selectionState.stringValue = ""
        guard let item = selected else { command.string = ""; location.stringValue = ""; enabled.state = .off; return }
        enabled.state = service.enabled(item) ? .on : .off; command.string = item.display
        let timeout = item.timeout.isFinite && (1...600).contains(item.timeout) ? " · \(Int(item.timeout))s" : ""
        location.stringValue = item.type + " · " + item.event.rawValue + (item.matcher.isEmpty ? "" : " · " + item.matcher) + timeout + (item.runsInBackground ? item.asyncRewake == true ? " · 后台唤醒" : " · 后台" : "") + (item.network ? " · 联网" : ""); location.toolTip = item.source
        if item.pluginEnabled == false { selectionState.stringValue = "所属插件已停用，请先在插件管理中启用" }
        else if let diagnostic = item.diagnostic { selectionState.stringValue = diagnostic }
        else if service.enabled(item) && !service.trusted(item) { selectionState.stringValue = "配置或脚本已变化，重新启用前需审核" }
        selectionState.isHidden = selectionState.stringValue.isEmpty
    }
    private func reload(select id: String? = nil) {
        do {
            let previous = id ?? selected?.id; items = try service.catalog(workspace: workspace)
            selected = items.first { $0.id == previous }
            expanded = expanded.intersection(Set(items.map(\.event))); if let selected { expanded.insert(selected.event) }
            count.stringValue = "已配置的 Hooks  \(items.count)"
            state.stringValue = service.warnings.joined(separator: "\n"); state.toolTip = state.stringValue
            showSelection(); renderGroups()
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func refreshList() { reload() }
    func selectHook(_ id: String) {
        reload(select: id); pageContentView?.layoutSubtreeIfNeeded()
        if let button = disclosureButton("hook-handler-" + id) { button.scrollToVisible(button.bounds) }
    }
    func checkGroupedPresentation() throws -> [String: Bool] {
        guard CommandLine.arguments.contains("--settings-layout-check") else { return [:] }
        let catalog = try service.catalog(workspace: workspace)
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        func eventButton(_ event: AgentHookEvent) -> NSButton? { buttons(groups).first { $0.accessibilityIdentifier() == "hook-event-" + event.rawValue } }
        func handlers() -> [NSButton] { buttons(groups).filter { $0.accessibilityIdentifier().hasPrefix("hook-handler-") } }
        var checks: [String: Bool] = [:]
        let events = Set(catalog.map(\.event))
        checks["initialHookGroupsAreCollapsed"] = expanded.isEmpty && handlers().isEmpty && selected == nil
        checks["eventGroupsShowActualCatalogCounts"] = events.allSatisfy { event in
            eventButton(event)?.accessibilityLabel()?.contains("\(catalog.filter { $0.event == event }.count) 个处理器") == true
        } && buttons(groups).count == events.count && count.stringValue.contains(String(catalog.count))
        guard let stop = eventButton(.stop), let first = catalog.first(where: { $0.event == .stop }) else { throw PetError("缺少实际 Stop 分组") }
        stop.performClick(nil); pageContentView?.layoutSubtreeIfNeeded()
        checks["expandingEventShowsOnlyItsActualHandlers"] = handlers().count == catalog.filter { $0.event == .stop }.count && handlers().allSatisfy { button in catalog.contains { $0.event == .stop && button.accessibilityIdentifier() == "hook-handler-" + $0.id } }
        guard let handler = handlers().first else { throw PetError("分组没有显示处理器") }
        handler.performClick(nil); pageContentView?.layoutSubtreeIfNeeded()
        checks["handlerSelectionShowsActualCommandAndState"] = selected?.id == first.id && command.string == first.display && enabled.state == .off && detail.superview != nil
        eventButton(.stop)?.performClick(nil)
        checks["collapseHidesHandlerDetailsWithoutLosingSelection"] = handlers().isEmpty && detail.superview == nil && selected?.id == first.id
        eventButton(.stop)?.performClick(nil)
        checks["reexpansionRestoresSelectedDetails"] = detail.superview != nil && command.string == first.display
        guard let project = catalog.first(where: { $0.workspace != nil }) else { throw PetError("缺少项目处理器") }
        selectHook(project.id); pageContentView?.layoutSubtreeIfNeeded()
        checks["directHookSelectionExpandsCorrectEventAndScope"] = selected?.id == project.id && expanded.contains(project.event) && command.string == project.display && handlers().contains { $0.accessibilityIdentifier() == "hook-handler-" + project.id && $0.accessibilityLabel()?.contains("项目") == true }
        editSelected.performClick(nil)
        func text(_ view: NSView) -> String { (view as? NSTextView)?.string ?? view.subviews.map(text).joined(separator: "\n") }
        let editorText = configWindow?.pageContentView.map(text) ?? ""
        checks["projectHandlerEditorUsesActualProjectDocument"] = configWindow?.window?.title == "项目 Hooks" && editorText.contains("项目工具记录") && !editorText.contains("用户工具记录") && configWindow?.pageContentView?.window === presentingWindow
        configWindow?.close()
        checks["returnFromProjectEditorRetainsGroupedSelection"] = detail.superview != nil && selected?.id == project.id && scope.indexOfSelectedItem == 1
        guard let shared = catalog.first(where: { $0.scope == "共享全局" }) else { throw PetError("缺少实际共享来源") }
        selectHook(shared.id); editSelected.performClick(nil)
        checks["sharedHandlersDoNotOpenUnrelatedEditableConfig"] = selected?.id == shared.id && command.string == shared.display && !editSelected.isEnabled && configWindow?.settingsHostWindow == nil
        checks["browsingDoesNotEnableAnyHook"] = catalog.allSatisfy { !service.enabled($0) }
        return checks
    }
    override func settingsDidAppear() {
        super.settingsDidAppear(); reload()
        if let selected { presentingWindow?.makeFirstResponder(disclosureButton("hook-handler-" + selected.id)) }
    }
    @objc private func revealSource() { if let selected { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.source)]) } }
    @objc private func clearCredentials() {
        guard let selected, let window = presentingWindow else { return }
        let alert = AgentConfirmation(); alert.messageText = "清除已保存的 Hook 凭据？"; alert.informativeText = selected.name + "\n停用此处理器并清除钥匙串中的 " + (selected.type == "http" ? "Headers" : "env") + "。来源文件内直接填写的值可通过「打开来源」移除。"; alert.addButton(withTitle: "清除").hasDestructiveAction = true; alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in guard response == .alertFirstButtonReturn, let self else { return }; do { try service.clearCredentials(selected, workspace: workspace); reload(select: selected.id) } catch { state.stringValue = error.localizedDescription } }
    }
    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        if enabled.state == .off {
            do { try service.setEnabled(item, false, workspace: workspace); reload(select: item.id); presentingWindow?.makeFirstResponder(disclosureButton("hook-handler-" + item.id)) } catch { state.stringValue = error.localizedDescription }; return
        }
        enabled.state = service.enabled(item) ? .on : .off
        guard item.diagnostic == nil, presentingWindow != nil else { reload(select: item.id); return }
        let consequence: String
        switch item.type {
        case "http": consequence = "将自动向此地址发送当前事件数据。Header 可按 allowedEnvVars 引用应用环境；未指定白名单时允许所有变量。重定向不会跟随。"
        case "prompt": consequence = "将使用任务的模型连接独立判断当前事件，产生模型用量。"
        case "agent": consequence = "将创建独立模型校验任务，只读项目，按工具白名单执行，产生模型用量。" + (item.network ? "允许终端联网。" : "终端不联网。")
        default: consequence = "此命令将自动运行，可修改任务项目、读取应用进程环境。" + (item.network ? "允许访问网络。" : "不允许访问网络。")
        }
        let notice = consequence + (item.runsInBackground ? "\n在后台运行，结果不改变审批或工具参数。" : "") + (item.asyncRewake == true ? "退出码为 2 时可继续任务并产生模型用量。" : "")
        let timeout = item.timeout.isFinite && (1...600).contains(item.timeout) ? "\(Int(item.timeout)) 秒" : "无效"
        var definition = item.display + "\n\n匹配：" + (item.matcher.isEmpty ? "全部" : item.matcher) + "\n超时：" + timeout + "\n来源：" + item.source
        if item.type == "agent", let turns = item.maxTurns { definition += "\n最多 \(turns) 轮" }
        for (title, value) in [("状态", item.statusMessage), ("唤醒提示", item.rewakeMessage), ("唤醒摘要", item.rewakeSummary)] { if let value, !value.isEmpty { definition += "\n\n" + title + "\n" + value } }
        let page = AgentSettingsReviewPage(title: "启用「" + item.name + "」", metadata: item.event.rawValue + " · " + item.scope, notice: notice, sections: [("处理器", definition)], applyTitle: "启用")
        page.onApply = { [weak self] in
            guard let self else { throw PetError("Hooks 页面已关闭，请重新打开") }; try service.setEnabled(item, true, workspace: workspace)
        }
        page.onApplied = { [weak self] in
            guard let self else { return }; reload(select: item.id); state.stringValue = "已启用"
            presentingWindow?.makeFirstResponder(disclosureButton("hook-handler-" + item.id))
        }
        reviewPage = page; presentSettingsChild(page)
    }
    @objc private func editConfig() { openConfig(imported: nil) }
    private var canEditSelected: Bool {
        guard let selected else { return false }
        if selected.plugin != nil { return true }
        return (try? service.file(project: selected.workspace != nil, workspace: selected.workspace).path) == selected.source
    }
    @objc private func editSelectedConfig() {
        guard let selected, canEditSelected else { return }
        if let reference = selected.plugin { openPluginConfig(reference) }
        else { scope.selectItem(at: selected.workspace == nil ? 0 : 1); openConfig(imported: nil) }
    }
    private func openPluginConfig(_ reference: AgentPluginHookReference) {
        if let window = configWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        do {
            let document = try service.pluginDocument(reference)
            let editor = AgentHookConfigWindow(text: document.text, title: "插件 Hooks · " + (try AgentPlugins.scope(reference.name).name)) { [weak self] text in
                guard let self else { return }
                try service.savePluginDocument(text, reference: reference, original: document.original, expectedHash: document.hash); reload()
            }; configWindow = editor; presentSettingsChild(editor)
        } catch { state.stringValue = error.localizedDescription }
    }
    private func openConfig(imported: String?) {
        if let window = configWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        do {
            let project = scope.indexOfSelectedItem == 1, document = try service.document(project: project, workspace: workspace)
            let importedData = imported.map { Data($0.utf8) }
            let masked = try importedData.map { String(decoding: try service.credentials.mask($0), as: UTF8.self) }
            let editor = AgentHookConfigWindow(text: masked ?? document.0, title: project ? "项目 Hooks" : "全局 Hooks") { [weak self] text in
                guard let self else { return }
                let data = try importedData.map { try self.service.credentials.restoreImported(Data(text.utf8), original: $0, file: self.service.file(project: project, workspace: self.workspace)) } ?? Data(text.utf8)
                try service.save(String(decoding: data, as: UTF8.self), project: project, workspace: workspace, expectedHash: document.1); reload()
            }; configWindow = editor; presentSettingsChild(editor)
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func importConfig() {
        guard let window = presentingWindow else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let files = try AgentFiles(workspace: url.deletingLastPathComponent().path), data = try files.readData(files.resolve(url.lastPathComponent), maximum: 128_000)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let hooks = object["hooks"] as? [String: Any] else { throw PetError("文件中没有 hooks 对象") }
                openConfig(imported: String(decoding: try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            } catch { state.stringValue = error.localizedDescription }
        }
    }
}

@MainActor private final class AgentHookConfigWindow: AgentSettingsPageController, NSWindowDelegate {
    private let editor = NSTextView(), state = NSTextField(labelWithString: "")
    private let save: (String) throws -> Void
    private let original: String
    private var saved = false
    init(text: String, title: String, save: @escaping (String) throws -> Void) {
        self.save = save; original = text
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = NSSize(width: 560, height: 350); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        editor.string = text; editor.isRichText = false; editor.allowsUndo = true; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.setAccessibilityLabel("Hooks JSON 配置")
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let button = NSButton(title: "保存", target: self, action: #selector(saveConfig)); button.keyEquivalent = "s"; button.keyEquivalentModifierMask = .command
        state.font = .systemFont(ofSize: 11); state.textColor = AgentWorkbenchTheme.secondaryText; state.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [state, NSView(), button]); footer.spacing = 8
        let content = NSView(); window.contentView = content
        for view in [scroll, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10), footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), footer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12), footer.heightAnchor.constraint(equalToConstant: 28)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func saveConfig() { do { try save(editor.string); saved = true; close() } catch { state.stringValue = error.localizedDescription; state.toolTip = state.stringValue } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !saved, editor.string != original else { return true }
        return AgentUnsavedChanges.discard("放弃未保存的更改？", discardTitle: "放弃")
    }
}
