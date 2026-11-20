import AppKit

@MainActor final class AgentMemorySettingsPage: AgentSettingsPageController {
    private let store: AgentStore, taskID: String?, workspace: String?
    private let service: AgentGeneralSettings
    private let global = NSSwitch(), project = NSSwitch()
    private let state = AgentSettingsStatusField("记忆保存状态")
    private let feedback = NSStackView()
    private let reload = NSButton(title: "重新载入", target: nil, action: nil)
    private let clearGlobal = AgentDialogButton(title: "清空…", target: nil, action: nil)
    private let clearProjects = AgentDialogButton(title: "清空项目记忆…", target: nil, action: nil)
    private var states: [String: NSTextField] = [:], buttons: [NSButton] = []
    private let projectSearch = NSSearchField(), projectRows = NSStackView()
    private let emptyProjects = NSTextField(labelWithString: "")
    private var allProjects: [AgentMemoryProjectSource] = []
    private var projectSources: [AgentMemoryProjectSource] = [], projectButtons: [NSButton] = [], projectStates: [NSTextField] = []
    private var saveFailed = false
    private weak var lastOpened: NSButton?
    private struct Recovery: Codable {
        var version = 1
        let query: String
        let y: Double
        let selection: AgentTextViewport.Selection?
        let searchFocused: Bool
        let openedButton: String?
    }
    private var pendingRecovery: Recovery?, recoveryScheduled = false
    override var minimumSettingsContentHeight: CGFloat { 220 }
    override var usesInternalScrolling: Bool { true }

    init(store: AgentStore, taskID: String?, workspace: String?, service: AgentGeneralSettings) {
        self.store = store; self.taskID = taskID; self.workspace = workspace; self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "记忆与指令"; window.minSize = NSSize(width: 650, height: 450); window.isReleasedWhenClosed = false
        super.init(window: window)
        for (index, control) in [global, project].enumerated() {
            control.tag = index; control.target = self; control.action = #selector(changeMemory)
            control.setAccessibilityLabel(index == 0 ? "全局记忆" : "项目记忆")
            control.identifier = .init(index == 0 ? "memory-global-enabled" : "memory-project-enabled")
            control.toolTip = "关闭后不自动加入上下文，记忆工具停止读取和写入；已有内容仍可手动管理。"
        }
        reload.target = self; reload.action = #selector(reloadSettings); reload.bezelStyle = .rounded
        clearGlobal.target = self; clearGlobal.action = #selector(reviewCleanup(_:))
        clearProjects.target = self; clearProjects.action = #selector(reviewCleanup(_:))
        clearGlobal.setAccessibilityLabel("清空全局记忆")
        clearGlobal.setAccessibilityIdentifier("memory-clear-global")
        clearProjects.setAccessibilityIdentifier("memory-clear-projects")
        for button in [clearGlobal, clearProjects] { button.hasDestructiveAction = true; AgentDialogStyle.action(button) }
        [state, NSView(), reload].forEach { feedback.addArrangedSubview($0) }; feedback.spacing = 8
        let behavior = AgentSettingsStyle.section("记忆行为", id: "memory-behavior", rows: [AgentSettingsStyle.formRow("全局记忆", global, trailing: true), AgentSettingsStyle.formRow("项目记忆", project, trailing: true)])
        func source(_ scope: AgentMemoryScope) -> NSView {
            let title = NSTextField(labelWithString: scope.title); title.font = .systemFont(ofSize: 13)
            let status = NSTextField(labelWithString: ""); status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText
            status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let labels = NSStackView(views: [title, status]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
            let button = NSButton(title: "管理", target: self, action: #selector(openMemory)); button.bezelStyle = .rounded
            button.tag = AgentMemoryScope.allCases.firstIndex(of: scope)!; button.identifier = .init("memory-manage-" + scope.rawValue); button.setAccessibilityLabel("管理" + scope.title)
            let row = NSStackView(views: [labels, NSView(), button] + (scope == .global ? [clearGlobal] : []))
            row.alignment = .centerY; row.spacing = 12
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            states[scope.rawValue] = status; buttons.append(button); return row
        }
        let memory = AgentSettingsStyle.section("记忆内容", id: "memory-content", rows: [source(.global)])
        projectSearch.placeholderString = "搜索项目名称或路径"; projectSearch.setAccessibilityLabel("搜索记忆项目")
        projectSearch.identifier = .init("memory-project-search"); projectSearch.target = self; projectSearch.action = #selector(filterProjects); projectSearch.sendsSearchStringImmediately = true
        projectRows.orientation = .vertical; projectRows.alignment = .leading; projectRows.spacing = 10
        emptyProjects.textColor = AgentWorkbenchTheme.secondaryText
        emptyProjects.identifier = .init("memory-project-empty")
        let projectResults = NSStackView(views: [projectRows, emptyProjects])
        projectResults.orientation = .vertical; projectResults.alignment = .leading
        projectRows.widthAnchor.constraint(equalTo: projectResults.widthAnchor).isActive = true
        let projectToolbar = NSStackView(views: [projectSearch, clearProjects]); projectToolbar.alignment = .centerY; projectToolbar.spacing = 12
        let projectSection = AgentSettingsStyle.section("全部项目记忆", id: "memory-projects", rows: [projectToolbar, projectResults])
        let instructions = AgentSettingsStyle.section("指令", id: "memory-instructions", rows: [.userInstructions, .instructions, .localInstructions, .effectiveInstructions].map(source))
        let summary = AgentSettingsStyle.section("当前任务", id: "memory-summary", rows: [source(.summary)])
        var sections: [NSView] = [behavior, feedback, memory, projectSection, instructions]
        if taskID != nil { sections.append(summary) }
        let content = AgentSettingsStyle.form(sections, label: "记忆与指令设置")
        window.contentView = content; update()
        content.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: content.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func settingsDidAppear() {
        service.reload(); update()
        if pendingRecovery != nil { scheduleRecovery(); return }
        if isPageVisible, let lastOpened, lastOpened.window === presentingWindow, lastOpened.isEnabled { presentingWindow?.makeFirstResponder(lastOpened) }
    }
    override func pageDidLayout() { scheduleRecovery() }
    @objc private func scrolled(_ note: Notification) { if pendingRecovery == nil { onSettingsRecoveryChange?() } }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        if let pendingRecovery { return try AgentSettingsRecovery.page("memory", pendingRecovery) }
        guard let scroll = pageContentView as? NSScrollView else { return nil }
        let field = projectSearch.currentEditor() as? NSTextView
        let selection = field.map { editor in
            let range = editor.selectedRange()
            return AgentTextViewport.Selection(location: range.location, length: range.length)
        }
        let saved = Recovery(query: projectSearch.stringValue, y: max(0, scroll.contentView.bounds.minY), selection: selection,
                             searchFocused: field != nil && presentingWindow?.firstResponder === field,
                             openedButton: lastOpened?.identifier?.rawValue)
        return try AgentSettingsRecovery.page("memory", saved)
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "memory" else { throw PetError("设置记录不属于记忆目录") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state),
            keys: ["version", "query", "y", "selection", "searchFocused", "openedButton"])
        if let selection = raw["selection"] { _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"]) }
        let saved = try JSONDecoder().decode(Recovery.self, from: page.state)
        guard saved.version == 1, AgentSettingsRecovery.validScroll(saved.y), !saved.query.contains("\0"),
              saved.selection?.valid(in: saved.query.utf16.count) != false,
              saved.openedButton.map({ $0.utf8.count <= 96 && $0.hasPrefix("memory-") }) != false else { throw PetError("记忆目录位置无效，原记录已保留") }
        pendingRecovery = saved
        projectSearch.stringValue = saved.query
        filterProjects(); scheduleRecovery()
    }
    private func scheduleRecovery() {
        guard pendingRecovery != nil, !recoveryScheduled else { return }
        recoveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { recoveryScheduled = false }
            guard let saved = pendingRecovery, isPageVisible, let scroll = pageContentView as? NSScrollView else { return }
            presentingWindow?.contentView?.layoutSubtreeIfNeeded()
            AgentSettingsRecovery.restoreScroll(saved.y, to: scroll)
            let candidates = buttons + projectButtons + [clearGlobal, clearProjects]
            lastOpened = saved.openedButton.flatMap { id in
                candidates.first { $0.identifier?.rawValue == id }
            }
            if saved.searchFocused, presentingWindow?.makeFirstResponder(projectSearch) == true, let range = saved.selection?.range {
                (projectSearch.currentEditor() as? NSTextView)?.setSelectedRange(range)
            } else if let lastOpened, lastOpened.isEnabled { presentingWindow?.makeFirstResponder(lastOpened) }
            pendingRecovery = nil; onSettingsRecoveryChange?()
        }
    }
    private func update() {
        global.state = service.settings.globalMemory ? .on : .off; project.state = service.settings.projectMemory ? .on : .off
        global.isEnabled = service.error == nil; project.isEnabled = service.error == nil
        if let error = service.error { state.stringValue = error; saveFailed = true }
        feedback.isHidden = state.stringValue.isEmpty
        reload.isHidden = !saveFailed
        clearGlobal.isEnabled = false
        for button in buttons {
            let scope = AgentMemoryScope.allCases[button.tag]
            do {
                if scope.hasTopics {
                    let catalog = try AgentMemory.catalog(scope, store: store, taskID: taskID, workspace: workspace)
                    states[scope.rawValue]?.stringValue = countAndDate(catalog)
                    states[scope.rawValue]?.toolTip = catalog.topicError ?? store.directory.path
                    if scope == .global { clearGlobal.isEnabled = catalog.count > 0 || catalog.topicError != nil }
                } else {
                    let value = try AgentMemory.snapshot(scope, store: store, taskID: taskID, workspace: workspace)
                    let text = value.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    states[scope.rawValue]?.stringValue = text.isEmpty ? "暂无内容" : "\(text.count) 字"
                    states[scope.rawValue]?.toolTip = value.location
                }
                button.isEnabled = true
            } catch {
                states[scope.rawValue]?.stringValue = error.localizedDescription; states[scope.rawValue]?.toolTip = error.localizedDescription; button.isEnabled = false
            }
        }
        allProjects = AgentMemory.projects(store: store, preferredTaskID: taskID)
        filterProjects()
    }
    private func countAndDate(_ value: AgentMemoryCatalog) -> String {
        let count = "\(value.count) 个文件"
        return count + (value.latest.map { " · " + $0.formatted(date: .numeric, time: .shortened) } ?? "")
    }
    @objc private func filterProjects() {
        defer { onSettingsRecoveryChange?() }
        let query = projectSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = allProjects.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.workspace.localizedStandardContains(query)
        }
        if sources != projectSources {
            projectRows.arrangedSubviews.forEach { projectRows.removeArrangedSubview($0); $0.removeFromSuperview() }
            projectSources = sources; projectButtons = []; projectStates = []
            for (index, source) in sources.enumerated() {
                let title = NSTextField(labelWithString: source.title); title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingMiddle
                title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let status = NSTextField(labelWithString: ""); status.font = .systemFont(ofSize: 11); status.textColor = AgentWorkbenchTheme.secondaryText
                status.lineBreakMode = .byTruncatingMiddle; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let labels = NSStackView(views: [title, status]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
                let button = NSButton(title: "管理", target: self, action: #selector(openProjectMemory)); button.bezelStyle = .rounded; button.tag = index
                button.identifier = .init("memory-project-" + AgentFiles.hash(Data(source.workspace.utf8))); button.setAccessibilityLabel("管理" + source.title + "项目记忆")
                let row = NSStackView(views: [labels, NSView(), button]); row.alignment = .centerY; row.spacing = 12
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
                projectRows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: projectRows.widthAnchor).isActive = true
                projectButtons.append(button); projectStates.append(status)
            }
        }
        projectRows.isHidden = sources.isEmpty
        clearProjects.isEnabled = !sources.isEmpty
        emptyProjects.isHidden = !sources.isEmpty
        emptyProjects.stringValue = query.isEmpty ? "暂无项目" : "未找到项目"
        for (index, source) in sources.enumerated() {
            do {
                let files = try AgentFiles(workspace: source.workspace)
                guard source.taskID != nil || files.root.path == source.workspace else { throw PetError("项目目录位置已变化") }
                let catalog = try AgentMemory.catalog(.project, store: store, taskID: source.taskID, workspace: source.workspace)
                let detail = countAndDate(catalog) + " · " + source.workspace
                projectStates[index].stringValue = detail
                projectStates[index].toolTip = detail + (catalog.topicError.map { "\n" + $0 } ?? ""); projectButtons[index].isEnabled = true
            } catch {
                projectStates[index].stringValue = error.localizedDescription + " · " + source.workspace; projectStates[index].toolTip = source.workspace + "\n" + error.localizedDescription
                projectButtons[index].isEnabled = false
            }
        }
    }
    @objc private func changeMemory(_ sender: NSSwitch) {
        var value = service.settings
        if sender === global { value.globalMemory = sender.state == .on } else { value.projectMemory = sender.state == .on }
        do { try service.save(value); saveFailed = false; state.stringValue = "已保存" }
        catch { saveFailed = true; state.stringValue = error.localizedDescription }
        update()
    }
    @objc private func reloadSettings() {
        service.reload(); saveFailed = false; state.stringValue = ""; update()
    }
    @objc private func reviewCleanup(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        lastOpened = sender
        presentSettingsChild(AgentMemoryCleanupPage(store: store, projects: sender === clearGlobal ? nil : projectSources))
    }
    @objc private func openMemory(_ sender: NSButton) {
        guard sender.isEnabled, AgentMemoryScope.allCases.indices.contains(sender.tag) else { return }
        lastOpened = sender
        let scope = AgentMemoryScope.allCases[sender.tag]
        presentSettingsChild(makeEditor(.init(entry: scope, context: context(taskID: taskID, workspace: workspace))))
    }
    func openInstruction(_ scope: AgentMemoryScope) throws {
        guard let button = buttons.first(where: { AgentMemoryScope.allCases[$0.tag] == scope }), button.isEnabled else {
            throw PetError("指令设置页不可用")
        }
        openMemory(button)
    }
    @objc private func openProjectMemory(_ sender: NSButton) {
        guard sender.isEnabled, projectButtons.contains(sender), projectSources.indices.contains(sender.tag) else { return }
        let source = projectSources[sender.tag]
        do { _ = try AgentMemory.catalog(.project, store: store, taskID: source.taskID, workspace: source.workspace) }
        catch {
            projectStates[sender.tag].stringValue = error.localizedDescription
            projectStates[sender.tag].toolTip = source.workspace + "\n" + error.localizedDescription
            return
        }
        lastOpened = sender
        presentSettingsChild(makeEditor(.init(entry: .project, context: context(taskID: source.taskID, workspace: source.workspace))))
    }
    private func context(taskID: String?, workspace: String?) -> AgentSettingsRecovery.Context {
        if taskID == nil, let workspace { return .init(managedWorkspace: workspace) }
        return .init(task: taskID.flatMap(store.task), workspace: workspace)
    }
    private func makeEditor(_ target: AgentRecordWindow.MemorySettingsTarget) -> AgentRecordWindow {
        let scope = target.entry
        let editor = AgentRecordWindow(store: store, taskID: target.context.taskID, section: 5, memoryOnly: true,
            memoryWorkspace: target.context.workspace, memoryCatalogScope: scope.hasTopics ? scope : nil, memorySettingsTarget: target)
        editor.window?.title = scope.title; editor.selectItem(section: 5, value: scope.rawValue)
        if scope == .global { editor.settingsContext = (scope.title, store.directory.path) }
        if scope == .project, let workspace = target.context.workspace {
            let title = allProjects.first(where: { $0.workspace == workspace })?.title ?? URL(fileURLWithPath: workspace).lastPathComponent
            editor.window?.title = title + " · 项目记忆"; editor.settingsContext = ("项目 · " + title, workspace)
        }
        editor.onWorkspaceChange = { [weak editor] in editor?.onSettingsRecoveryChange?() }
        return editor
    }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        guard page.kind == "memory-editor" else { return nil }
        let target = try AgentRecordWindow.MemorySettingsRecovery.decode(page).target
        if target.entry == .project {
            guard allProjects.contains(where: { $0.workspace == target.context.workspace }) else { throw PetError("原记忆项目暂不可用，草稿已保留") }
        } else if target.context != context(taskID: taskID, workspace: workspace) {
            throw PetError("记忆编辑所属任务或来源已变化，草稿已保留")
        }
        try target.context.requireCurrent(store)
        return makeEditor(target)
    }
}
