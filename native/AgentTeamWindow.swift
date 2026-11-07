import AppKit

@MainActor final class AgentTeamWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    let store: AgentStore
    let workspace: String?
    var onUse: ((String) -> Void)?
    private let table = NSTableView(), name = NSTextField(), purpose = NSTextField(), instructions = NSTextView()
    private let leader = NSPopUpButton(), members = NSPopUpButton(frame: .zero, pullsDown: true)
    private let enabled = NSButton(checkboxWithTitle: "启用团队及成员", target: nil, action: nil)
    private let save = NSButton(title: "保存", target: nil, action: nil), use = NSButton(title: "新建任务", target: nil, action: nil), state = NSTextField(labelWithString: "")
    private var values: [AgentTeam] = [], agents: [AgentProfile] = [], pendingAgents: [AgentProfile] = []
    private var selectedID: String?, openedHash: String?, dirty = false, loading = false, selectedMembers = Set<String>()
    private var agentWindow: AgentProfileWindow?
    init(store: AgentStore, workspace: String?) {
        self.store = store; self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent 团队"; window.minSize = NSSize(width: 760, height: 540); window.center(); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("teams")); table.addTableColumn(column); table.headerView = nil; table.rowHeight = 42; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("Agent 团队列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        let add = NSButton(title: "新建", target: self, action: #selector(create)), template = NSButton(title: "审阅模板", target: self, action: #selector(createTemplate))
        let actions = NSStackView(views: [add, template]); actions.spacing = 8
        name.placeholderString = "名称"; purpose.placeholderString = "职责"
        for (field, label) in [(name, "团队名称"), (purpose, "团队职责")] { field.delegate = self; field.setAccessibilityLabel(label); field.font = .systemFont(ofSize: 13) }
        leader.target = self; leader.action = #selector(leaderChanged); leader.setAccessibilityLabel("团队负责人"); members.setAccessibilityLabel("团队成员")
        enabled.target = self; enabled.action = #selector(changed)
        let manage = NSButton(title: "管理 Agent", target: self, action: #selector(manageAgents))
        let options = NSStackView(views: [enabled, NSView(), manage]); options.spacing = 8
        let grid = NSGridView(views: [[NSTextField(labelWithString: "名称"), name], [NSTextField(labelWithString: "职责"), purpose], [NSTextField(labelWithString: "负责人"), leader], [NSTextField(labelWithString: "成员"), members]])
        grid.columnSpacing = 12; grid.rowSpacing = 10; grid.column(at: 0).width = 52; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .fill
        instructions.isRichText = false; instructions.allowsUndo = true; instructions.delegate = self; instructions.font = .systemFont(ofSize: 13); instructions.textContainerInset = NSSize(width: 12, height: 12); instructions.isVerticallyResizable = true; instructions.autoresizingMask = [.width]; instructions.textContainer?.widthTracksTextView = true
        instructions.isAutomaticQuoteSubstitutionEnabled = false; instructions.isAutomaticTextReplacementEnabled = false; instructions.setAccessibilityLabel("团队协作指令")
        let editor = NSScrollView(); editor.documentView = instructions; editor.hasVerticalScroller = true; editor.borderType = .bezelBorder
        let label = NSTextField(labelWithString: "协作指令"); label.font = .systemFont(ofSize: 12, weight: .medium)
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail; state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        save.target = self; save.action = #selector(saveTeam); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; use.target = self; use.action = #selector(useTeam)
        let footer = NSStackView(views: [state, NSView(), use, save]); footer.spacing = 10
        for view in [list, actions, grid, options, label, editor, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), list.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), list.widthAnchor.constraint(equalToConstant: 190), list.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -10),
            actions.leadingAnchor.constraint(equalTo: list.leadingAnchor), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            grid.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 18), grid.topAnchor.constraint(equalTo: list.topAnchor), grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            options.leadingAnchor.constraint(equalTo: grid.leadingAnchor), options.trailingAnchor.constraint(equalTo: grid.trailingAnchor), options.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: grid.leadingAnchor), label.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 14),
            editor.leadingAnchor.constraint(equalTo: grid.leadingAnchor), editor.trailingAnchor.constraint(equalTo: grid.trailingAnchor), editor.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8), editor.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: grid.leadingAnchor), footer.trailingAnchor.constraint(equalTo: grid.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), footer.heightAnchor.constraint(equalToConstant: 28)
        ]); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func numberOfRows(in tableView: NSTableView) -> Int { values.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value = values[row], text = NSTextField(labelWithString: value.name + (value.enabled ? "" : " · 已停用")); text.font = .systemFont(ofSize: 12, weight: .medium); text.lineBreakMode = .byTruncatingTail; text.toolTip = value.description; return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading, values.indices.contains(table.selectedRow) else { return }
        if dirty { state.stringValue = "请先保存更改"; selectRow(); return }; open(values[table.selectedRow].id)
    }
    private func selectRow() { loading = true; defer { loading = false }; if let index = values.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } else { table.deselectAll(nil) } }
    private func reload() {
        do { let document = try store.teams.document(); values = try store.teams.decode(document.0); openedHash = document.1; agents = try store.agents.list(); loading = true; table.reloadData(); loading = false; open(values.first(where: { $0.id == selectedID })?.id ?? values.first?.id) }
        catch { state.stringValue = error.localizedDescription }
    }
    private func open(_ id: String?) {
        loading = true; selectedID = id; let value = values.first { $0.id == id }
        name.stringValue = value?.name ?? ""; purpose.stringValue = value?.description ?? ""; instructions.string = value?.instructions ?? ""; enabled.state = value?.enabled == true ? .on : .off
        selectedMembers = Set(value?.memberIDs ?? []); refreshRoles(leaderID: value?.leaderID)
        dirty = false; instructions.undoManager?.removeAllActions(); selectRow(); loading = false; updateControls(); state.stringValue = value == nil ? "暂无团队" : ""
    }
    private func refreshRoles(leaderID: String?) {
        leader.removeAllItems()
        for value in agents + pendingAgents { leader.addItem(withTitle: value.name + (value.enabled ? "" : " · 未启用")); leader.lastItem?.representedObject = value.id }
        if let id = leaderID, let item = leader.itemArray.first(where: { $0.representedObject as? String == id }) { leader.select(item) }
        else if let id = leaderID { leader.addItem(withTitle: "负责人不可用"); leader.lastItem?.representedObject = id; leader.select(leader.lastItem) }
        refreshMembers()
    }
    private func refreshMembers() {
        members.removeAllItems(); members.addItem(withTitle: "已选 \(selectedMembers.count) / 4")
        let leaderID = leader.selectedItem?.representedObject as? String
        let roles = agents + pendingAgents
        for value in roles where value.id != leaderID {
            let item = NSMenuItem(title: value.name + (value.enabled ? "" : " · 未启用"), action: #selector(toggleMember(_:)), keyEquivalent: ""); item.target = self; item.representedObject = value.id; item.state = selectedMembers.contains(value.id) ? .on : .off; members.menu?.addItem(item)
        }
        for id in selectedMembers where !roles.contains(where: { $0.id == id }) { let item = NSMenuItem(title: "成员不可用", action: #selector(toggleMember(_:)), keyEquivalent: ""); item.target = self; item.representedObject = id; item.state = .on; members.menu?.addItem(item) }
    }
    @objc private func leaderChanged() { if let id = leader.selectedItem?.representedObject as? String { selectedMembers.remove(id) }; refreshMembers(); changed() }
    @objc private func toggleMember(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if selectedMembers.contains(id) { selectedMembers.remove(id) } else { guard selectedMembers.count < 4 else { state.stringValue = "最多四名成员"; return }; selectedMembers.insert(id) }; refreshMembers(); changed()
    }
    private func updateControls() { let selected = selectedID != nil; for item in [name, purpose, leader, members, enabled] as [NSControl] { item.isEnabled = selected }; instructions.isEditable = selected; save.isEnabled = dirty; use.isEnabled = selected && !dirty && enabled.state == .on }
    func controlTextDidChange(_ obj: Notification) { changed() }
    func textDidChange(_ notification: Notification) { changed() }
    @objc private func changed() { guard !loading else { return }; dirty = true; state.stringValue = "未保存"; updateControls() }
    @objc private func create() {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        do { agents = try store.agents.list(); pendingAgents = []; let value = AgentTeam(name: "", description: "", instructions: "", leaderID: agents.first?.id ?? UUID().uuidString, memberIDs: []); values.append(value); table.reloadData(); open(value.id); changed(); window?.makeFirstResponder(name) } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func createTemplate() {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        let alert = NSAlert(); alert.messageText = "代码审阅团队"; alert.informativeText = "负责人协调代码审阅员与测试分析员，核对风险、证据和缺失测试，汇总实际结论。只读项目。\n\n保存时创建三个 Agent；启用团队时同时启用成员。"; alert.addButton(withTitle: "使用模板"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            agents = try store.agents.list(); var lead = AgentTemplates.profiles[3], reviewer = AgentTemplates.profiles[0], tester = AgentTemplates.profiles[0]
            tester.name = "测试分析员"; tester.description = "核对测试覆盖与可触发的回归风险"; tester.instructions = "只读相关源码与测试，核对边界条件和回归场景。仅报告有依据的缺口，给出触发输入、预期结果与建议验证。不得修改文件或运行会改动项目的测试。"
            pendingAgents = []
            for role in [lead, reviewer, tester] { var value = role; let base = value.name; var index = 2; while (agents + pendingAgents).contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) { value.name = base + " \(index)"; index += 1 }; pendingAgents.append(value) }
            lead = pendingAgents[0]; reviewer = pendingAgents[1]; tester = pendingAgents[2]
            var value = AgentTeam(name: "代码审阅团队", description: "分工核对代码风险与测试覆盖", instructions: "负责人按实际需要分派代码审阅与测试覆盖分析，等待两名成员的实际结果。核对证据、分歧和未知项，汇总可执行结论。只读分析，不修改项目。", leaderID: lead.id, memberIDs: [reviewer.id, tester.id])
            let base = value.name; var index = 2; while values.contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) { value.name = base + " \(index)"; index += 1 }
            values.append(value); table.reloadData(); open(value.id); changed(); state.stringValue = "待保存 · 将创建 3 个 Agent"
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func saveTeam() {
        do {
            guard let i = values.firstIndex(where: { $0.id == selectedID }), let leaderID = leader.selectedItem?.representedObject as? String else { throw PetError("请选择负责人") }
            values[i].name = name.stringValue; values[i].description = purpose.stringValue; values[i].instructions = instructions.string; values[i].leaderID = leaderID; values[i].memberIDs = selectedMembers.sorted(); values[i].enabled = enabled.state == .on
            let text = try store.teams.encode(values); _ = try store.teams.decode(text)
            let prior = try store.agents.document()
            if !pendingAgents.isEmpty { try store.agents.save(store.agents.encode(store.agents.decode(prior.0) + pendingAgents), expectedHash: prior.1) }
            do { try store.teams.save(text, expectedHash: openedHash, store: store, activating: selectedID) }
            catch { if !pendingAgents.isEmpty { try? store.agents.save(prior.0, expectedHash: store.agents.document().1) }; throw error }
            pendingAgents = []; dirty = false; reload(); state.stringValue = "已保存"
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc private func useTeam() { do { guard !dirty, let selectedID else { throw PetError("请先保存团队") }; let id = try store.teams.createTask(selectedID, store: store, workspace: workspace); onUse?(id); window?.orderOut(nil) } catch { state.stringValue = error.localizedDescription } }
    @objc private func manageAgents() { let manager = AgentProfileWindow(store: store, workspace: workspace); manager.onUse = onUse; agentWindow = manager; manager.showWindow(nil); manager.window?.makeKeyAndOrderFront(nil) }
    func windowDidBecomeKey(_ notification: Notification) {
        guard dirty else { reload(); return }
        let id = leader.selectedItem?.representedObject as? String
        do { agents = try store.agents.list(); refreshRoles(leaderID: id) } catch { state.stringValue = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if dirty { let alert = NSAlert(); alert.messageText = "放弃未保存的团队更改？"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃更改"); return alert.runModal() == .alertSecondButtonReturn }; return true
    }
}
