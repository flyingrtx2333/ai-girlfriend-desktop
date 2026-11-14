import AppKit

struct AgentMonitorEntry: Equatable { let id: String, title: String, detail: String }
struct AgentMonitorContent {
    let task: AgentTaskRecord
    let toolNames: [String: String]
    let sources: [String]
    init(task: AgentTaskRecord) { self.task = task; sources = task.sourceReferences; toolNames = Dictionary(task.messages.flatMap { $0.toolCalls ?? [] }.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last }) }
    var settings = AgentTaskMonitor.Settings()
    var children: [AgentTaskRecord] = [], sideChats: [AgentTaskRecord] = []
    var terminals: [AgentMonitorEntry] = [], pages: [AgentMonitorEntry] = []
    var environment: [String] = []
    var missingArtifacts = Set<String>()
    var showChanges = true, canAnalyze = false, canAddSources = false
    var analysis: String?, analysisError: String?
    var previewTitle: String?, previewVisible = false
    var skillSuggestions: [AgentSkillEvolutionSuggestion] = []
    var skillTargetTitles: [String:String] = [:]
    var skillSource: String?, skillError: String?
    var skillGenerating = false, skillAnalyzed = false, canGenerateSkills = false
    func name(_ event: AgentEvent) -> String { event.toolCallID.flatMap { toolNames[$0] } ?? event.title }
    var processes: [AgentEvent] { task.events.filter { ["running", "waiting"].contains($0.status) && (name($0) == "run_command" || $0.kind == "hook") } }
    var capabilities: [AgentEvent] { task.events.filter { let n = name($0); return AgentMCP.tools.contains(n) || AgentMCP.isModelToolName(n) } }
    var knowledge: [AgentEvent] { task.events.filter { let n = name($0); return $0.kind == "tool" && (n.contains("knowledge") || n.contains("wiki")) } }
    var memory: [AgentEvent] { task.events.filter { $0.kind == "tool" && name($0) == "write_memory" && $0.status == "completed" } }
    var hasContent: Bool {
        let s = settings
        return s.shows(.recap) && (task.recap != nil || task.messages.contains(where: \.isHumanInput) || analysis != nil || analysisError != nil) || s.shows(.goal) && task.mode == .goal && task.messages.contains(where: \.isHumanInput) || s.shows(.plan) && !task.plan.isEmpty || s.shows(.agents) && !children.isEmpty || s.shows(.processes) && (!processes.isEmpty || !terminals.isEmpty) || s.shows(.sideChats) && !sideChats.isEmpty || s.shows(.capabilities) && (task.activeSkills?.isEmpty == false || !capabilities.isEmpty || !skillSuggestions.isEmpty || skillGenerating || skillAnalyzed || skillError != nil || canGenerateSkills) || s.shows(.outputs) && (!task.artifacts.isEmpty || task.canvases?.isEmpty == false) || s.shows(.web) && !pages.isEmpty || s.shows(.sources) && !sources.isEmpty || s.shows(.knowledge) && !knowledge.isEmpty || s.shows(.memory) && !memory.isEmpty || s.shows(.preview) && previewTitle != nil || showChanges && !task.changes.isEmpty
    }
    var signature: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let t = task, preferences = (try? encoder.encode(settings)).map(AgentFiles.hash) ?? ""
        let skills = [(try? encoder.encode(skillSuggestions)).map(AgentFiles.hash) ?? "", (try? encoder.encode(skillTargetTitles)).map(AgentFiles.hash) ?? "", skillSource ?? "", skillError ?? "", String(skillGenerating), String(skillAnalyzed), String(canGenerateSkills)].joined(separator: "|")
        return [t.id, preferences, skills, t.status.rawValue, String(t.goalAccepted ?? false), t.messages.first(where: \.isHumanInput)?.content ?? "", t.recap?.text ?? "", t.recap?.created.description ?? "", t.recap?.model ?? "", t.recap?.throughMessageID ?? "", t.messages.last?.id ?? "", t.plan.map { $0.id + $0.title + $0.status }.joined(), t.artifacts.joined(), missingArtifacts.sorted().joined(), sources.joined(), (t.canvases ?? []).map { $0.id + $0.hash }.joined(), t.changes.map { $0.id + ($0.restoredAt?.description ?? "") }.joined(), t.events.map { $0.id + $0.title + $0.status + String($0.duration ?? -1) }.joined(), (t.activeSkills ?? []).map { $0.id }.joined(), (children + sideChats).map { $0.id + $0.title + $0.statusTitle + String($0.sideTask?.retained ?? false) }.joined(), terminals.map { $0.id + $0.title + $0.detail }.joined(), pages.map { $0.id + $0.title + $0.detail }.joined(), environment.joined(), String(showChanges), String(canAnalyze), String(canAddSources), analysis ?? "", analysisError ?? "", previewTitle ?? "", String(previewVisible)].joined(separator: "|")
    }
}

@MainActor final class AgentTaskInspector: AgentThemeView {
    var onOpen: ((Int, String) -> Void)?, onShowAll: ((Int) -> Void)?, onSideTask: ((String) -> Void)?
    var onOpenIn: ((Int, String, AgentArtifactLocation) -> Void)?
    var onOpenTerminal: (() -> Void)?, onTerminal: ((String) -> Void)?, onPage: ((String) -> Void)?
    var onRecap: (() -> Void)?, onContext: ((Int) -> Void)?, onSettings: (() -> Void)?, onMemory: (() -> Void)?, onPreview: (() -> Void)?
    var onClose: (() -> Void)?, onPresentation: (() -> Void)?
    var onAddSource: ((NSButton) -> Void)?
    var onSkillCurate: ((Set<String>,String,Bool)->Void)?, onSkillTask: ((String)->Void)?, onSkillRetry: (()->Void)?, onSkillSource: (()->Void)?
    private var skillSelections: [String:Set<String>] = [:]
    var canOpenTerminal = true
    private let column = NSStackView(), scroll = NSScrollView(), pin = AgentWorkbenchButton()
    private final class Action: NSObject {
        let taskID: String?, generation: UUID, body: () -> Void
        init(taskID: String?, generation: UUID, body: @escaping () -> Void) { self.taskID = taskID; self.generation = generation; self.body = body }
    }
    private var content: AgentMonitorContent?, rendered = "", generation = UUID()
    private let actions = NSMapTable<NSButton, Action>.weakToStrongObjects()
    private var collapsed: [String: Set<String>] = [:], expanded: [String: Set<String>] = [:]
    var boundTaskID: String? { content?.task.id }
    override init(frame: NSRect) {
        super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false; fill = AgentWorkbenchTheme.surface; layer?.masksToBounds = true
        let title = NSTextField(labelWithString: "任务监控"); title.font = .systemFont(ofSize: 14, weight: .semibold)
        let more = AgentWorkbenchButton(), close = AgentWorkbenchButton()
        AgentWorkbenchTheme.toolbar(pin, title: "改为浮动", symbol: "rectangle.portrait.and.arrow.right"); pin.target = self; pin.action = #selector(changePresentation)
        AgentWorkbenchTheme.toolbar(more, title: "任务监控操作", symbol: "ellipsis"); more.target = self; more.action = #selector(showMenu(_:))
        AgentWorkbenchTheme.toolbar(close, title: "关闭任务监控", symbol: "xmark"); close.target = self; close.action = #selector(closeMonitor)
        let header = AgentTaskMonitorHeader(views: [title, NSView(), pin, more, close]); header.spacing = 3
        let line = AgentWorkbenchTheme.rule(), document = FormDocumentView(); column.orientation = .vertical; column.alignment = .leading; column.spacing = 20
        document.addSubview(column); document.translatesAutoresizingMaskIntoConstraints = false; column.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; scroll.setAccessibilityLabel("任务监控内容")
        for view in [header, line, scroll] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        let trailing = header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16); trailing.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), trailing, header.topAnchor.constraint(equalTo: topAnchor, constant: 10), header.heightAnchor.constraint(equalToConstant: 28), line.leadingAnchor.constraint(equalTo: header.leadingAnchor), line.trailingAnchor.constraint(equalTo: header.trailingAnchor), line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8), scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 14), scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), column.leadingAnchor.constraint(equalTo: document.leadingAnchor), column.trailingAnchor.constraint(equalTo: document.trailingAnchor), column.topAnchor.constraint(equalTo: document.topAnchor), column.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        setAccessibilityLabel("任务监控")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setPresentation(_ presentation: AgentMonitorPresentation) {
        pin.image = NSImage(systemSymbolName: presentation == .fixed ? "rectangle.portrait.and.arrow.right" : "pin", accessibilityDescription: nil)
        let title = presentation == .fixed ? "改为浮动" : "固定到任务右侧"; pin.setAccessibilityLabel(title); pin.toolTip = title
    }
    @objc private func closeMonitor() { onClose?() }
    @objc private func changePresentation() { onPresentation?() }
    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, key) in [("完整记录", "records"), ("上下文", "context"), ("任务监控设置", "settings")] {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: ""); item.representedObject = key; item.target = self; menu.addItem(item)
        }
        if canOpenTerminal { menu.addItem(.separator()); let item = NSMenuItem(title: "打开终端", action: #selector(menuAction(_:)), keyEquivalent: ""); item.representedObject = "terminal"; item.target = self; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        switch sender.representedObject as? String { case "records": onShowAll?(4); case "context": onContext?(0); case "settings": onSettings?(); case "terminal": onOpenTerminal?(); default: break }
    }
    private func button(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> NSButton {
        let value = AgentWorkbenchButton(title: title, target: self, action: #selector(invoke(_:)))
        actions.setObject(Action(taskID: boundTaskID, generation: generation, body: action), forKey: value)
        value.isBordered = false; value.alignment = .left; value.font = .systemFont(ofSize: 12); value.cell?.lineBreakMode = .byTruncatingMiddle; value.setAccessibilityLabel(title)
        if let symbol { value.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); value.imagePosition = .imageLeading; value.imageScaling = .scaleProportionallyDown }
        value.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true; return value
    }
    @objc private func invoke(_ sender: NSButton) { if let action = actions.object(forKey: sender), action.taskID == boundTaskID, action.generation == generation { action.body() } }
    private func label(_ value: String, secondary: Bool = false, lines: Int = 0) -> NSTextField {
        let text = NSTextField(wrappingLabelWithString: value); text.font = .systemFont(ofSize: 12); text.textColor = secondary ? AgentWorkbenchTheme.secondaryText : .labelColor; text.maximumNumberOfLines = lines; text.isSelectable = true; return text
    }
    private func section(_ key: String, _ title: String, views: [NSView], accessory: NSView? = nil) {
        guard !views.isEmpty || accessory != nil, let id = boundTaskID else { return }
        let hidden = collapsed[id, default: []].contains(key)
        let heading = button(title, symbol: hidden ? "chevron.right" : "chevron.down") { [weak self] in
            guard let self else { return }; if hidden { collapsed[id]?.remove(key) } else { collapsed[id, default: []].insert(key) }; rerender()
        }
        heading.font = .systemFont(ofSize: 12, weight: .medium); heading.contentTintColor = AgentWorkbenchTheme.secondaryText
        let header: NSView = accessory.map { NSStackView(views: [heading, $0]) } ?? heading
        header.identifier = NSUserInterfaceItemIdentifier("monitor-group-" + key)
        let group = NSStackView(views: [header] + (hidden ? [] : views)); group.orientation = .vertical; group.alignment = .leading; group.spacing = 7
        column.addArrangedSubview(group); group.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        for view in group.arrangedSubviews { view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
    }
    private func textRows(_ text: String, key: String) -> [NSView] {
        guard let id = boundTaskID else { return [] }; let full = expanded[id, default: []].contains(key), long = text.count > 180 || text.components(separatedBy: "\n").count > 5
        var rows: [NSView] = [label(text, lines: long && !full ? 5 : 0)]
        if long { rows.append(button(full ? "收起" : "展开全文") { [weak self] in guard let self else { return }; if full { expanded[id]?.remove(key) } else { expanded[id, default: []].insert(key) }; rerender() }) }; return rows
    }
    private func file(_ title: String, value: String, section: Int, symbol: String = "doc") -> NSView {
        let id = boundTaskID, token = generation, row = AgentInspectorFileButton(title: title, value: value, section: section, symbol: symbol); row.font = .systemFont(ofSize: 12)
        row.onOpen = { [weak self] section, value in guard let self, boundTaskID == id, generation == token else { return }; onOpen?(section, value) }
        if section == 1 { row.onOpenIn = { [weak self] location in guard let self, boundTaskID == id, generation == token else { return }; onOpenIn?(section, value, location) } }
        return row
    }
    private func events(_ events: [AgentEvent]) -> [NSView] {
        var rows = events.suffix(8).reversed().map { event -> NSView in let row = file(event.title + " · " + event.statusTitle, value: event.id, section: 4, symbol: event.status == "running" ? "clock" : "list.bullet.rectangle"); row.toolTip = event.detail; return row }
        if events.count > 8 { rows.append(button("全部记录（\(events.count)）") { [weak self] in self?.onShowAll?(4) }) }; return rows
    }
    private func taskRows(_ tasks: [AgentTaskRecord]) -> [NSView] {
        tasks.map { task in
            let retained = task.sideTask?.retained == true ? " · 已保留" : "", state = task.sideTask?.sessionID != nil && task.sideTask?.sessionID != AgentSideTasks.sessionID && task.sideTask?.retained == true ? "待继续" : task.statusTitle
            return button(task.title + " · " + state + retained, symbol: task.agent?.ownerID == nil ? "bubble.left.and.bubble.right" : "person.crop.circle") { [weak self] in self?.onSideTask?(task.id) }
        }
    }
    private func rerender() { guard let content else { return }; rendered = ""; update(content) }
    func update(_ value: AgentMonitorContent) {
        content = value; guard rendered != value.signature else { return }; rendered = value.signature
        let origin = scroll.contentView.bounds.origin; generation = UUID(); column.arrangedSubviews.forEach { column.removeArrangedSubview($0); $0.removeFromSuperview() }
        let task = value.task, settings = value.settings
        if settings.shows(.recap), task.recap != nil || value.analysis != nil || value.analysisError != nil {
            var rows: [NSView] = []
            if let recap = task.recap { rows += textRows(recap.text, key: "recap"); rows.append(label(recap.created.formatted(date: .abbreviated, time: .shortened) + (recap.throughMessageID == task.messages.last?.id ? "" : " · 有新记录"), secondary: true)) }
            if let analysis = value.analysis { rows.append(label(analysis, secondary: true)) }; if let error = value.analysisError { rows.append(label(error)) }
            let generate = button(task.recap == nil ? "生成回顾" : "更新回顾", symbol: "sparkles") { [weak self] in self?.onRecap?() }; generate.isEnabled = value.canAnalyze; rows.append(generate)
            section("recap", "任务回顾", views: rows)
        } else if settings.shows(.recap), task.messages.contains(where: \.isHumanInput) {
            let generate = button("生成任务回顾", symbol: "sparkles") { [weak self] in self?.onRecap?() }; generate.isEnabled = value.canAnalyze; section("recap", "任务回顾", views: [generate])
        }
        if settings.shows(.goal), task.mode == .goal, let goal = task.messages.first(where: \.isHumanInput)?.content { section("goal", "任务目标" + (task.goalAccepted == true ? " · 已验收" : ""), views: textRows(goal, key: "goal")) }
        if settings.shows(.plan), !task.plan.isEmpty {
            let done = task.plan.filter { $0.status == "completed" }.count
            var rows: [NSView] = task.plan.prefix(5).map { step in
                let image = NSImageView(image: NSImage(systemSymbolName: step.status == "completed" ? "checkmark.circle.fill" : step.status == "in_progress" ? "circle.dotted" : "circle", accessibilityDescription: step.status)!); image.contentTintColor = step.status == "completed" ? AgentWorkbenchTheme.accent : AgentWorkbenchTheme.secondaryText; image.widthAnchor.constraint(equalToConstant: 14).isActive = true
                let row = NSStackView(views: [image, label(step.title, lines: 3)]); row.spacing = 7; row.alignment = .top; return row
            }
            rows.append(button("完整计划", symbol: "list.bullet") { [weak self] in self?.onShowAll?(0) }); section("plan", "计划 \(done)/\(task.plan.count)", views: rows)
        }
        if !value.environment.isEmpty { section("environment", "环境信息", views: value.environment.map { label($0, secondary: true, lines: 3) }) }
        if settings.shows(.agents) { section("agents", "子智能体", views: taskRows(value.children)) }
        if settings.shows(.processes) {
            let terminals = value.terminals.map { terminal in button(terminal.title, symbol: "terminal") { [weak self] in self?.onTerminal?(terminal.id) } }
            section("processes", "后台进程", views: terminals + events(value.processes))
        }
        if settings.shows(.sideChats) { section("sideChats", "侧边聊天", views: taskRows(value.sideChats)) }
        if settings.shows(.capabilities) {
            let skills = (task.activeSkills ?? []).map { skill in button(skill.name, symbol: "puzzlepiece.extension") { [weak self] in self?.onContext?(0) } }
            var rows: [NSView] = skills + events(value.capabilities)
            if !value.skillSuggestions.isEmpty || value.skillGenerating || value.skillAnalyzed || value.skillError != nil || value.canGenerateSkills {
                let key = task.id + ":" + (value.skillSource ?? ""), token = generation
                let suggestions = AgentSkillSuggestionsView(items:value.skillSuggestions,selected:skillSelections[key] ?? [],generating:value.skillGenerating,issue:value.skillError,analyzed:value.skillAnalyzed,canGenerate:value.canGenerateSkills,targetTitles:value.skillTargetTitles)
                suggestions.onSelection = { [weak self] ids in guard let self, boundTaskID == task.id, generation == token else { return }; skillSelections[key] = ids }
                suggestions.onCurate = { [weak self] ids,adopt in guard let self, boundTaskID == task.id, generation == token else { return }; onSkillCurate?(ids,value.skillSource ?? "",adopt) }
                suggestions.onOpen = { [weak self] id in guard let self, boundTaskID == task.id, generation == token else { return }; onSkillTask?(id) }
                suggestions.onRetry = { [weak self] in guard let self, boundTaskID == task.id, generation == token else { return }; onSkillRetry?() }
                suggestions.onSource = { [weak self] in guard let self, boundTaskID == task.id, generation == token else { return }; onSkillSource?() }
                rows.append(suggestions)
            }
            section("capabilities", "Skill 与 MCP", views: rows)
        }
        if settings.shows(.outputs) {
            var rows: [NSView] = task.artifacts.prefix(8).map { path in
                let row = file(URL(fileURLWithPath: path).lastPathComponent, value: path, section: 1)
                if value.missingArtifacts.contains(path), let button = row as? NSButton {
                    button.isEnabled = false; button.attributedTitle = NSAttributedString(string: button.title, attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: AgentWorkbenchTheme.secondaryText, .font: NSFont.systemFont(ofSize: 12)])
                    button.toolTip = "文件已移动或删除：" + path; button.setAccessibilityLabel(button.title + "，文件已移动或删除")
                }
                return row
            }
            rows += (task.canvases ?? []).prefix(8).map { file($0.title, value: $0.reference, section: 1, symbol: "rectangle.3.group") }
            if task.artifacts.count + (task.canvases ?? []).count > 8 { rows.append(button("全部产出") { [weak self] in self?.onShowAll?(1) }) }; section("outputs", "产出", views: rows)
        }
        if settings.shows(.web) { section("web", "网页查阅", views: value.pages.map { page in let b = button(page.title, symbol: "globe") { [weak self] in self?.onPage?(page.id) }; b.toolTip = page.detail; return b }) }
        if settings.shows(.sources) {
            var seen = Set<String>(), rows: [NSView] = []
            for source in value.sources where seen.insert(source).inserted {
                let url = URL(string: source); var title = url?.isFileURL == true ? url!.lastPathComponent : url?.host ?? source
                if url?.scheme == "attachment", let host = url?.host, let item = task.attachments?.first(where: { $0.id.caseInsensitiveCompare(host) == .orderedSame }) { title = item.name }
                rows.append(file(title, value: source, section: 2, symbol: ["https", "http"].contains(url?.scheme) ? "globe" : "doc")); if rows.count == 10 { break }
            }
            if value.sources.count > 10 { rows.append(button("全部来源") { [weak self] in self?.onShowAll?(2) }) }
            var add: NSButton?
            if value.canAddSources {
                let control = AgentWorkbenchButton(); AgentWorkbenchTheme.toolbar(control, title: "添加来源", symbol: "plus"); control.target = self; control.action = #selector(invoke(_:))
                actions.setObject(Action(taskID: boundTaskID, generation: generation, body: { [weak self, weak control] in guard let control else { return }; self?.onAddSource?(control) }), forKey: control); add = control
            }
            section("sources", "来源", views: rows, accessory: add)
        }
        if settings.shows(.knowledge) { section("knowledge", "知识", views: events(value.knowledge)) }
        if settings.shows(.memory), !value.memory.isEmpty { section("memory", "记忆更新", views: [button("查看记忆", symbol: "brain") { [weak self] in self?.onMemory?() }]) }
        if settings.shows(.preview), let title = value.previewTitle { section("preview", "演示画面", views: [button((value.previewVisible ? "收起 " : "显示 ") + title, symbol: "rectangle.on.rectangle") { [weak self] in self?.onPreview?() }]) }
        if value.showChanges, !task.changes.isEmpty { section("changes", "变更", views: task.changes.prefix(6).map { file(URL(fileURLWithPath: $0.path).lastPathComponent, value: $0.id, section: 3, symbol: $0.restoredAt == nil ? "square.and.pencil" : "arrow.uturn.backward") }) }
        if column.arrangedSubviews.isEmpty { column.addArrangedSubview(label("暂无监控内容", secondary: true)) }
        layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)))); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func readback() -> [String: Any] {
        guard ["--task-monitor-check", "--manual-ui"].contains(where: CommandLine.arguments.contains) else { return [:] }
        func collect(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(collect) }
        return ["taskID": boundTaskID ?? "", "sections": column.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first?.identifier?.rawValue }, "text": collect(column).joined(separator: "\n"), "scrollY": scroll.contentView.bounds.origin.y]
    }
}

@MainActor private final class AgentTaskMonitorHeader: NSStackView {
    private var dragStart: (frame: NSRect, screen: NSPoint)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); toolTip = window is AgentTaskMonitorPanel ? "拖动移动任务监控" : nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), window is AgentTaskMonitorPanel else { return super.hitTest(point) }
        var candidate: NSView? = hit
        while let view = candidate { if view is NSButton { return hit }; if view === self { break }; candidate = view.superview }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard let window = window as? AgentTaskMonitorPanel else { super.mouseDown(with: event); return }
        dragStart = (window.frame, window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window = window as? AgentTaskMonitorPanel, let start = dragStart else { super.mouseDragged(with: event); return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: start.frame.minX + point.x - start.screen.x, y: start.frame.minY + point.y - start.screen.y))
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil }
}

@MainActor final class AgentTaskMonitorPanel: NSPanel, NSWindowDelegate {
    let inspector = AgentTaskInspector()
    var onDismiss: (() -> Void)?, onFrame: ((NSRect) -> Void)?
    override var canBecomeKey: Bool { true }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 560), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        title = "任务监控"; isMovable = true; isMovableByWindowBackground = true; isReleasedWhenClosed = false; hidesOnDeactivate = false; isFloatingPanel = false; level = .normal; minSize = NSSize(width: 280, height: 300); delegate = self
        let root = AgentThemeView(fill: AgentWorkbenchTheme.surface); contentView = root; root.addSubview(inspector)
        NSLayoutConstraint.activate([inspector.leadingAnchor.constraint(equalTo: root.leadingAnchor), inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor), inspector.topAnchor.constraint(equalTo: root.topAnchor), inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        inspector.setPresentation(.floating)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onDismiss?(); orderOut(nil); return false }
    func windowDidMove(_ notification: Notification) { onFrame?(frame) }
    func windowDidResize(_ notification: Notification) { onFrame?(frame) }
    override func cancelOperation(_ sender: Any?) { onDismiss?(); orderOut(nil) }
}
