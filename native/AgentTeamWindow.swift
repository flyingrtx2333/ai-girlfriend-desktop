import AppKit

@MainActor final class AgentTeamWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    let store: AgentStore
    let workspace: String?
    private let taskID: String?
    private let workMode: AgentWorkMode
    var onUse: ((String) -> Void)?
    private let table = AgentSettingsCatalogTable(), name = AgentDialogTextField(), purpose = AgentDialogTextField(), instructions = NSTextView()
    private let sections = NSSegmentedControl(labels: ["当前", "已归档"], trackingMode: .selectOne, target: nil, action: nil)
    private let leader = NSPopUpButton(), members = NSPopUpButton(frame: .zero, pullsDown: true)
    private let enabled = NSButton(checkboxWithTitle: "启用团队及成员", target: nil, action: nil)
    private let save = AgentDialogButton(title: "保存", target: nil, action: nil), use = AgentDialogButton(title: "新建任务", target: nil, action: nil), state = AgentSettingsStatusField("团队保存状态")
    private let more = AgentDialogButton(title: "更多", target: nil, action: nil), restore = AgentDialogButton(title: "恢复团队", target: nil, action: nil)
    private let roster = AgentSettingsStatusField("已选团队成员")
    private lazy var detailActions = AgentSettingsDetailActions([more, use, save, restore])
    private var archivedIDs: Set<String> = []
    private var archiveHash: String?
    private var showsArchive: Bool { sections.selectedSegment == 1 }
    private var selectedArchived: Bool { selectedID.map(archivedIDs.contains) == true }
    private var catalogValues: [AgentTeam] { values.filter { archivedIDs.contains($0.id) == showsArchive } }
    private var values: [AgentTeam] = [], agents: [AgentProfile] = [], pendingAgents: [AgentProfile] = []
    private var selectedID: String?, openedHash: String?, dirty = false, loading = false, selectedMembers = Set<String>()
    private var pendingAgentsHash: String?
    private var requestedDetail = false
    private var agentWindow: AgentProfileWindow?
    private var reviewPage: AgentSettingsReviewPage?
    private var catalogLayout: (toolbar: NSView, detail: NSView, actions: [NSView])?
    private var detailPage: AgentSettingsDetailPage?
    private let catalogState = AgentSettingsStatusField("团队列表状态")
    private lazy var draftViewport: AgentSettingsDraftViewport = {
        let viewport = AgentSettingsDraftViewport(text: instructions, fields: ["name": name, "purpose": purpose], catalog: table, host: { [weak self] in self?.presentingWindow })
        viewport.onChange = { [weak self] in self?.onSettingsRecoveryChange?() }
        return viewport
    }()
    override var minimumSettingsContentHeight: CGFloat { 220 }
    init(store: AgentStore, workspace: String?, workMode: AgentWorkMode? = nil, taskID: String? = nil) {
        self.store = store; self.workspace = workspace; self.taskID = taskID; self.workMode = workMode ?? store.selected?.organizationMode ?? .coding
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent 团队" + (workspace.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""); window.minSize = NSSize(width: 760, height: 540); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("teams")); table.addTableColumn(column); table.headerView = nil; table.rowHeight = 42; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("Agent 团队列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        let add = AgentDialogButton(title: "新建", target: self, action: #selector(create)), template = AgentDialogButton(title: "审阅模板", target: self, action: #selector(createTemplate))
        for button in [add, template] { AgentDialogStyle.action(button, prominent: button === add) }
        sections.selectedSegment = 0; sections.target = self; sections.action = #selector(switchCatalog)
        sections.setAccessibilityLabel("团队分组"); sections.controlSize = .regular; sections.segmentStyle = .roundRect
        sections.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let actions = NSStackView(views: [sections, add, template]); actions.spacing = 8; actions.alignment = .centerY
        name.placeholderString = "名称"; purpose.placeholderString = "职责"
        for (field, label) in [(name, "团队名称"), (purpose, "团队职责")] {
            AgentSettingsStyle.field(field)
            field.delegate = self; field.setAccessibilityLabel(label); field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for popup in [leader, members] { popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); popup.cell?.lineBreakMode = .byTruncatingTail }
        leader.target = self; leader.action = #selector(leaderChanged); leader.setAccessibilityLabel("团队负责人"); members.setAccessibilityLabel("团队成员")
        enabled.target = self; enabled.action = #selector(changed)
        let manage = AgentDialogButton(title: "管理 Agent", target: self, action: #selector(manageAgents))
        AgentDialogStyle.action(manage)
        instructions.isRichText = false; instructions.allowsUndo = true; instructions.delegate = self; instructions.font = .systemFont(ofSize: 13); instructions.textContainerInset = NSSize(width: 12, height: 12); instructions.isVerticallyResizable = true; instructions.autoresizingMask = [.width]; instructions.textContainer?.widthTracksTextView = true
        instructions.isAutomaticQuoteSubstitutionEnabled = false; instructions.isAutomaticTextReplacementEnabled = false; instructions.setAccessibilityLabel("团队协作指令")
        let editor = NSScrollView(); editor.documentView = instructions; editor.hasVerticalScroller = true; editor.borderType = .bezelBorder
        editor.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let chooser = AgentSettingsStyle.formRow("额外成员", members, trailing: true)
        roster.alignment = .right
        let memberSelection = NSStackView(views: [chooser, roster])
        memberSelection.orientation = .vertical; memberSelection.alignment = .leading; memberSelection.spacing = 2
        for row in [chooser, roster] { row.widthAnchor.constraint(equalTo: memberSelection.widthAnchor).isActive = true }
        let memberActions = NSStackView(views: [enabled, NSView(), manage])
        memberActions.alignment = .centerY; memberActions.spacing = 8
        let form = AgentSettingsStyle.form([
            AgentSettingsStyle.section("团队信息", id: "team-basic", rows: [AgentSettingsStyle.formRow("名称", name, trailing: false), AgentSettingsStyle.formRow("职责", purpose, trailing: false)]),
            AgentSettingsStyle.section("成员", id: "team-members", rows: [AgentSettingsStyle.formRow("负责人", leader, trailing: true), memberSelection, memberActions]),
            AgentSettingsStyle.section("协作指令", id: "team-instructions", rows: [editor])
        ], label: "团队配置")
        draftViewport.trackForm(form)
        save.target = self; save.action = #selector(saveTeam); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; use.target = self; use.action = #selector(useTeam)
        more.target = self; more.action = #selector(showTeamActions); more.setAccessibilityLabel("更多团队操作")
        restore.target = self; restore.action = #selector(restoreTeam)
        for button in [save, restore] { AgentSettingsStyle.primaryAction(button) }
        AgentDialogStyle.action(use)
        NSLayoutConstraint.activate([more.heightAnchor.constraint(equalToConstant: 28), more.widthAnchor.constraint(greaterThanOrEqualToConstant: 52)])
        let detail = NSStackView(views: [detailActions, state, form]); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 12
        catalogLayout = (actions, detail, [template, add])
        for view in [detailActions, state, form] { view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        for view in [list, actions, detail] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), actions.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), actions.heightAnchor.constraint(equalToConstant: 28),
            list.leadingAnchor.constraint(equalTo: actions.leadingAnchor), list.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 12), list.widthAnchor.constraint(equalToConstant: 190), list.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 18), detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), detail.topAnchor.constraint(equalTo: actions.topAnchor), detail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), form.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ]); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        if detailPage == nil, let content = window?.contentView, let layout = catalogLayout {
            AgentSettingsCatalog.detach(content)
            let title = "团队配置"
            let page = AgentSettingsDetailPage(title: title, content: AgentSettingsCatalog.detail(layout.detail))
            page.settingsContext = (title, "")
            page.detailActionRow = detailActions
            page.onCanLeave = { [weak self] in
                guard let self, let window, windowShouldClose(window) else { return false }
                if dirty { dirty = false; pendingAgents = []; pendingAgentsHash = nil; reload() }; return true
            }
            page.onAppear = { [weak self] in
                guard let self else { return }
                refreshAvailableRoles()
                draftViewport.appear(default: name)
            }
            detailPage = page; catalogLayout = nil
            state.onChange = { [weak self] value in self?.catalogState.stringValue = value; self?.onSettingsRecoveryChange?() }; catalogState.stringValue = state.stringValue
            table.target = self; table.action = #selector(openSelectedTeam); table.onOpen = { [weak self] in self?.showDetail() }
            window?.contentView = AgentSettingsCatalog.content(table: table, toolbar: layout.toolbar, status: catalogState, actions: layout.actions, symbol: "person.2"); table.reloadData(); selectRow(); updateControls()
        }
        return super.settingsContent(in: host, styled: styled)
    }
    override var usesInternalScrolling: Bool { detailPage != nil }
    override func canLeaveSettings() -> Bool { detailPage?.settingsHostWindow != nil ? true : super.canLeaveSettings() }
    @objc private func openSelectedTeam() { showDetail() }
    private func showDetail() {
        guard selectedID != nil, let detailPage else { return }
        if detailPage.settingsHostWindow == nil { presentSettingsChild(detailPage) } else { detailPage.settingsDidAppear() }
    }
    private func sourceTask() throws -> AgentTaskRecord? { try AgentWorkspaceScope.settingsSourceTask(taskID, workspace: workspace, store: store) }
    private func availableAgents() throws -> [AgentProfile] {
        if let task = try sourceTask() { return try store.agents.list(task: task) }
        return try store.agents.list(workspace: workspace)
    }
    private func usableTeam(_ id: String) throws -> AgentTeam { try store.teams.team(id, store: store, workspace: workspace, task: sourceTask()) }
    override func settingsDidAppear() {
        if requestedDetail { requestedDetail = false; showDetail() }
        else if detailPage?.settingsHostWindow == nil { draftViewport.appear(default: table) }
    }
    override func pageDidLayout() { draftViewport.schedule() }
    func numberOfRows(in tableView: NSTableView) -> Int { catalogValues.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value = catalogValues[row], sources = (try? store.teams.sourceWorkspaces(value).sorted()) ?? []
        let state = archivedIDs.contains(value.id) ? "已归档" : value.enabled ? "已启用" : "已停用"
        let suffix = value.workspace.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? (sources.count > 1 ? " · \(sources.count) 个来源" : "")
        if detailPage != nil {
            return AgentSettingsCatalogCell(title: (value.name.isEmpty ? "未命名团队" : value.name) + suffix, summary: value.description, symbol: "person.2", status: state, group: table.group(at: row)) { [weak self] in
                guard let self, !dirty else { return }; open(value.id); showDetail()
            }
        }
        let text = NSTextField(labelWithString: (value.name.isEmpty ? "未命名团队" : value.name) + suffix + " · " + state); text.font = .systemFont(ofSize: 12, weight: .medium); text.lineBreakMode = .byTruncatingTail; text.toolTip = ([value.description] + sources).joined(separator: "\n"); return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let catalog = catalogValues
        guard !loading, catalog.indices.contains(table.selectedRow) else { return }
        if dirty { state.stringValue = "请先保存更改"; selectRow(); return }; open(catalog[table.selectedRow].id)
    }
    private func selectRow() {
        let wasLoading = loading; loading = true; defer { loading = wasLoading }
        if let index = catalogValues.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
    }
    private func reload() {
        do {
            let document = try store.teams.document(), archived = try store.teams.archiveState()
            let teams = try store.teams.decode(document.0), available = try availableAgents()
            values = teams; agents = available; openedHash = document.1; archivedIDs = archived.ids; archiveHash = archived.hash
            loading = true; table.reloadData(); loading = false
            let current = catalogValues
            open(current.first(where: { $0.id == selectedID })?.id ?? current.first?.id)
        }
        catch { state.stringValue = error.localizedDescription }
    }
    @objc private func switchCatalog() {
        guard !dirty else { sections.selectedSegment = selectedArchived ? 1 : 0; state.stringValue = "请先保存更改"; return }
        reload(); onSettingsRecoveryChange?()
    }
    private func open(_ id: String?) {
        draftViewport.reset()
        loading = true; selectedID = id; let value = values.first { $0.id == id }
        name.stringValue = value?.name ?? ""; purpose.stringValue = value?.description ?? ""; instructions.string = value?.instructions ?? ""; enabled.state = value?.enabled == true ? .on : .off
        selectedMembers = Set(value?.memberIDs ?? []); refreshRoles(leaderID: value?.leaderID)
        dirty = false; instructions.undoManager?.removeAllActions(); selectRow(); loading = false; updateControls(); state.stringValue = ""
    }
    private func roleTitle(_ value: AgentProfile) -> String {
        let scope = value.pluginSource.map { (try? AgentPlugins.scope($0.name).workspace) != nil ? " · 项目插件" : " · 用户插件" } ?? ""
        return AgentProfiles.title(value, task: try? sourceTask()) + scope + (value.enabled ? "" : value.pluginSource == nil ? " · 未启用" : " · 请先启用插件")
    }
    private func refreshRoles(leaderID: String?) {
        leader.removeAllItems()
        for value in agents + pendingAgents { leader.addItem(withTitle: roleTitle(value)); leader.lastItem?.representedObject = value.id }
        if let id = leaderID, let item = leader.itemArray.first(where: { $0.representedObject as? String == id }) { leader.select(item) }
        else if let id = leaderID { leader.addItem(withTitle: "负责人不可用"); leader.lastItem?.representedObject = id; leader.select(leader.lastItem) }
        refreshMembers()
    }
    private func refreshMembers() {
        members.removeAllItems(); members.addItem(withTitle: "已选 \(selectedMembers.count) / 4")
        let leaderID = leader.selectedItem?.representedObject as? String
        let roles = agents + pendingAgents
        for value in roles where value.id != leaderID {
            let item = NSMenuItem(title: roleTitle(value), action: #selector(toggleMember(_:)), keyEquivalent: ""); item.target = self; item.representedObject = value.id; item.state = selectedMembers.contains(value.id) ? .on : .off; members.menu?.addItem(item)
        }
        let unavailable = selectedMembers.subtracting(roles.map(\.id))
        for id in unavailable.sorted() { let item = NSMenuItem(title: "成员不可用", action: #selector(toggleMember(_:)), keyEquivalent: ""); item.target = self; item.representedObject = id; item.state = .on; members.menu?.addItem(item) }
        var names = roles.filter { selectedMembers.contains($0.id) }.map(roleTitle)
        if !unavailable.isEmpty { names.append("\(unavailable.count) 名成员不可用") }
        roster.stringValue = names.joined(separator: "、")
    }
    @objc private func leaderChanged() { if let id = leader.selectedItem?.representedObject as? String { selectedMembers.remove(id) }; refreshMembers(); changed() }
    @objc private func toggleMember(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if selectedMembers.contains(id) { selectedMembers.remove(id) } else { guard selectedMembers.count < 4 else { state.stringValue = "最多四名成员"; return }; selectedMembers.insert(id) }; refreshMembers(); changed()
    }
    private func updateControls() {
        AgentSettingsStyle.listState(table, text: showsArchive ? "暂无已归档团队" : "暂无团队")
        let selected = selectedID != nil, archived = selectedArchived
        for item in [name, purpose, leader, members, enabled] as [NSControl] { item.isEnabled = selected && !archived }
        instructions.isEditable = selected && !archived
        save.isHidden = archived; save.isEnabled = dirty && !archived
        more.isHidden = !selected || archived; more.isEnabled = selected && !dirty && !archived
        restore.isHidden = !archived; restore.isEnabled = archived && !dirty
        use.isHidden = archived
        use.isEnabled = selected && !archived && !dirty && enabled.state == .on && (selectedID.map { (try? usableTeam($0)) != nil } ?? false)
        detailPage?.detailHeading = values.first { $0.id == selectedID }.map { team in
            let projects = ((try? store.teams.sourceWorkspaces(team)) ?? []).sorted()
            let scope: String
            if projects.count > 1 { scope = "跨项目 · \(projects.count) 个来源" }
            else if let project = projects.first { scope = "项目 · " + URL(fileURLWithPath: project).lastPathComponent }
            else { scope = "用户" }
            let title = team.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(title: title.isEmpty ? "新建团队" : title, scope: archived ? "已归档 · " + scope : scope,
                location: projects.isEmpty ? nil : projects.joined(separator: "\n"))
        }
    }
    func controlTextDidChange(_ obj: Notification) { changed() }
    func textDidChange(_ notification: Notification) { changed() }
    @objc private func changed() { guard !loading, !selectedArchived else { return }; dirty = true; draftViewport.changed(); state.stringValue = "未保存"; updateControls() }
    @objc private func create() {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        do { agents = try availableAgents(); pendingAgents = []; pendingAgentsHash = nil; let value = AgentTeam(name: "", description: "", instructions: "", leaderID: agents.first?.id ?? UUID().uuidString, memberIDs: []); sections.selectedSegment = 0; values.append(value); table.reloadData(); open(value.id); changed(); showDetail(); presentingWindow?.makeFirstResponder(name) } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func createTemplate() {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        do {
            let originalAgents = try store.agents.document(), originalTeams = try store.teams.document()
            guard originalTeams.1 == openedHash else { throw PetError("团队配置已改变，请重新打开后审阅") }
            let available = try availableAgents()
            var lead = AgentTemplates.profiles[3], reviewer = AgentTemplates.profiles[0], tester = AgentTemplates.profiles[0]
            tester.name = "测试分析员"; tester.description = "核对测试覆盖与可触发的回归风险"; tester.instructions = "只读相关源码与测试，核对边界条件和回归场景。仅报告有依据的缺口，给出触发输入、预期结果与建议验证。不得修改文件或运行会改动项目的测试。"
            var prepared: [AgentProfile] = []
            for role in [lead, reviewer, tester] { var value = role; let base = value.name; var index = 2; while (available + prepared).contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) { value.name = base + " \(index)"; index += 1 }; prepared.append(value) }
            lead = prepared[0]; reviewer = prepared[1]; tester = prepared[2]
            var value = AgentTeam(name: "代码审阅团队", description: "分工核对代码风险与测试覆盖", instructions: "负责人按实际需要分派代码审阅与测试覆盖分析，等待两名成员的实际结果。核对证据、分歧和未知项，汇总可执行结论。只读分析，不修改项目。", leaderID: lead.id, memberIDs: [reviewer.id, tester.id])
            let base = value.name; var index = 2; while values.contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) { value.name = base + " \(index)"; index += 1 }
            let team = value, profiles = prepared
            var previewSections = [("团队协作", team.description + "\n\n" + team.instructions)]
            previewSections += profiles.enumerated().map { index, profile in
                let access = profile.permission.title + (profile.readOnly ? " · 只读项目" : " · 可修改项目") + (profile.network ? " · 允许联网" : " · 不联网")
                let model = profile.model.isEmpty ? "跟随任务" : profile.model
                let body = profile.description + "\n\n" + access + "\n模型：" + model + "\n工具：" + profile.tools.joined(separator: ", ") + "\n\n" + profile.instructions
                return ((index == 0 ? "负责人 · " : "成员 · ") + profile.name, body)
            }
            let page = AgentSettingsReviewPage(title: "代码审阅团队", metadata: "1 名负责人 · 2 名成员", notice: "保存时创建三个 Agent；启用团队时同时启用成员。", sections: previewSections, applyTitle: "载入草稿")
            page.onApply = { [weak self] in
                guard let self else { throw PetError("团队页面已关闭，请重新打开") }
                guard !dirty, try store.agents.document().1 == originalAgents.1, try store.teams.document().1 == originalTeams.1 else { throw PetError("角色或团队配置已改变，请返回重新审阅") }
                agents = available; pendingAgents = profiles; pendingAgentsHash = originalAgents.1
                sections.selectedSegment = 0; values.append(team); table.reloadData(); open(team.id); changed(); state.stringValue = "待保存 · 将创建 3 个 Agent"
            }
            page.onApplied = { [weak self] in guard let self else { return }; showDetail(); presentingWindow?.makeFirstResponder(name) }
            reviewPage = page; presentSettingsChild(page)
        } catch { state.stringValue = error.localizedDescription }
    }
    private func editedValue() -> AgentTeam? {
        guard var value = values.first(where: { $0.id == selectedID }) else { return nil }
        value.name = name.stringValue; value.description = purpose.stringValue; value.instructions = instructions.string
        value.leaderID = leader.selectedItem?.representedObject as? String ?? value.leaderID
        value.memberIDs = selectedMembers.sorted(); value.enabled = enabled.state == .on
        return value
    }
    @objc private func saveTeam() {
        do {
            guard !selectedArchived else { throw PetError("请先恢复团队") }
            let context = try sourceTask()
            guard let value = editedValue(), leader.selectedItem?.representedObject is String else { throw PetError("请选择负责人") }
            let text = try store.teams.encode(values.map { $0.id == value.id ? value : $0 })
            if pendingAgents.isEmpty {
                try store.teams.save(text, expectedHash: openedHash, store: store, activating: selectedID, workspace: workspace, task: context)
            } else {
                _ = try store.teams.decode(text, draft: true)
                guard try store.teams.document().1 == openedHash else { throw PetError("团队配置已改变，请重新读取后保存") }
                let prior = try store.agents.document()
                guard prior.1 == pendingAgentsHash else { throw PetError("角色配置已改变，请返回重新审阅模板") }
                let prepared = try store.agents.encode(store.agents.decode(prior.0) + pendingAgents)
                try store.agents.save(prepared, expectedHash: pendingAgentsHash)
                do { try store.teams.save(text, expectedHash: openedHash, store: store, activating: selectedID, workspace: workspace, task: context) }
                catch { try? store.agents.save(prior.0, expectedHash: AgentFiles.hash(Data(prepared.utf8))); throw error }
            }
            pendingAgents = []; pendingAgentsHash = nil; dirty = false; reload(); state.stringValue = "已保存"
        } catch { state.showSaveFailure(error) }
    }
    @objc private func showTeamActions() {
        guard selectedID != nil, !dirty, !selectedArchived else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: "归档团队…", action: #selector(confirmArchive), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }
    @objc private func confirmArchive() {
        guard !dirty, !selectedArchived, let team = values.first(where: { $0.id == selectedID }), let window = presentingWindow else { return }
        let alert = AgentConfirmation(); alert.messageText = "归档“\(team.name)”？"
        alert.informativeText = "归档后团队停用，原配置和任务记录保留。"
        alert.primaryButtonIndex = 0; alert.cancellationButtonIndex = 0
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "归档团队").hasDestructiveAction = true
        alert.beginModal(in: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.changeArchive(team.id, archived: true) }
        }
    }
    @objc private func restoreTeam() {
        guard let selectedID, selectedArchived else { return }
        changeArchive(selectedID, archived: false)
    }
    private func changeArchive(_ id: String, archived: Bool) {
        guard id == selectedID, !dirty else { return }
        do {
            try store.teams.setArchived(id, archived: archived, expectedHash: openedHash, expectedArchiveHash: archiveHash,
                                       store: store, workspace: workspace, task: sourceTask())
            sections.selectedSegment = archived ? 1 : 0; reload()
            state.stringValue = archived ? "" : "已恢复，启用后可用于任务"
            onSettingsRecoveryChange?()
        } catch { state.showSaveFailure(error) }
    }
    @objc private func useTeam() { do { guard !dirty, let selectedID else { throw PetError("请先保存团队") }; let context = try sourceTask(); let id = try store.teams.createTask(selectedID, store: store, workspace: context == nil ? workspace : context?.workspace, workMode: workMode, context: context); onUse?(id); window?.orderOut(nil) } catch { state.stringValue = error.localizedDescription } }
    private func agentManager() -> AgentProfileWindow {
        let manager = AgentProfileWindow(store: store, workspace: workspace, workMode: workMode, taskID: taskID)
        manager.onUse = onUse; agentWindow = manager; return manager
    }
    @objc private func manageAgents() { presentSettingsChild(agentManager()) }
    func windowDidBecomeKey(_ notification: Notification) {
        guard dirty else { reload(); return }
        refreshAvailableRoles()
    }
    private func refreshAvailableRoles() {
        let id = leader.selectedItem?.representedObject as? String
        do { agents = try availableAgents(); refreshRoles(leaderID: id) } catch { state.stringValue = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if dirty { return AgentUnsavedChanges.discard("放弃未保存的团队更改？") }; return true
    }
    private struct Recovery: Codable {
        var version = 1
        var taskID: String?, workspace: String?
        var value: AgentTeam?, pendingAgents: [AgentProfile]
        var openedHash: String?, pendingAgentsHash: String?
        var showsDetail: Bool, dirty: Bool, status: String
        var viewport: AgentSettingsDraftViewport.State
        var archivedCatalog: Bool? = nil
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        try AgentSettingsRecovery.page("teams", Recovery(taskID: taskID, workspace: workspace, value: editedValue(),
            pendingAgents: pendingAgents, openedHash: openedHash, pendingAgentsHash: pendingAgentsHash,
            showsDetail: detailPage?.settingsHostWindow != nil, dirty: dirty, status: state.stringValue,
            viewport: try draftViewport.capture(), archivedCatalog: showsArchive ? true : nil))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "teams" else { throw PetError("设置草稿不属于团队") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "taskID", "workspace", "value", "pendingAgents", "openedHash", "pendingAgentsHash", "showsDetail", "dirty", "status", "viewport", "archivedCatalog"])
        if let viewport = raw["viewport"] { try AgentSettingsDraftViewport.validateObject(viewport) }
        let draft = try JSONDecoder().decode(Recovery.self, from: page.state)
        let reopen = draft.showsDetail || draft.dirty
        guard draft.version == 1, draft.taskID == taskID, draft.workspace == workspace, !reopen || draft.value != nil,
              draft.pendingAgents.isEmpty || draft.dirty && draft.pendingAgents.count == 3 && Set(draft.pendingAgents.map(\.id)).count == 3 && draft.pendingAgents.allSatisfy({ $0.pluginSource == nil }),
              AgentSettingsRecovery.validHash(draft.openedHash), AgentSettingsRecovery.validHash(draft.pendingAgentsHash) else {
            throw PetError("团队草稿范围或版本已变化")
        }
        let document = try store.teams.document(), archive = try store.teams.archiveState()
        let available = try availableAgents()
        var current = try store.teams.decode(document.0)
        let isArchived = draft.value.map { archive.ids.contains($0.id) } == true
        let liveReview = reopen && !draft.dirty && (isArchived || draft.archivedCatalog == true)
        if liveReview {
            guard current.contains(where: { $0.id == draft.value?.id }) else { throw PetError("原团队暂不可用") }
        } else if reopen, let value = draft.value {
            try draftViewport.validate(draft.viewport, text: value.instructions, fields: ["name": value.name, "purpose": value.description])
            if let index = current.firstIndex(where: { $0.id == value.id }) { current[index] = value } else { current.append(value) }
        }
        let stale = try reopen && !liveReview && (document.1 != draft.openedHash || !draft.pendingAgents.isEmpty && store.agents.document().1 != draft.pendingAgentsHash)
        values = current; agents = available; openedHash = reopen && !liveReview ? draft.openedHash : document.1
        archivedIDs = archive.ids; archiveHash = archive.hash
        sections.selectedSegment = (reopen ? isArchived : draft.archivedCatalog == true) ? 1 : 0
        pendingAgents = draft.pendingAgents; pendingAgentsHash = draft.pendingAgentsHash
        loading = true; table.reloadData(); loading = false
        open(catalogValues.first(where: { $0.id == draft.value?.id })?.id ?? catalogValues.first?.id)
        dirty = reopen && (draft.dirty || stale); updateControls()
        if reopen {
            if !liveReview || editedValue() == draft.value {
                var viewport = draft.viewport
                if viewport.focus == "catalog" { viewport.focus = "body" }
                try draftViewport.restore(viewport)
            }
            if isArchived && draft.dirty { state.stringValue = "团队已归档，草稿已保留" }
            else { state.stringValue = stale ? "原团队或角色配置已变化，草稿已保留" : draft.status }
            if settingsHostWindow != nil { showDetail() } else { requestedDetail = true }
        } else if let y = draft.viewport.catalogY {
            var viewport = try draftViewport.capture(); viewport.catalogY = y; viewport.focus = "catalog"
            try draftViewport.restore(viewport)
        }
    }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        page.kind == "agents" && detailPage?.settingsHostWindow != nil ? agentManager() : nil
    }
}
