import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentProfileWindow: AgentSettingsPageController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    let store: AgentStore
    let workspace: String?
    let taskID: String?
    private let workMode: AgentWorkMode
    var onUse: ((String) -> Void)?
    var onSaved: ((String) throws -> Void)?
    private let table = AgentSettingsCatalogTable(), name = AgentDialogTextField(), purpose = AgentDialogTextField(), model = AgentDialogTextField(), instructions = NSTextView()
    private let permission = NSPopUpButton(), tools = NSPopUpButton(frame: .zero, pullsDown: true)
    private let skills = NSPopUpButton(frame: .zero, pullsDown: true), mcp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let readOnly = NSButton(checkboxWithTitle: "只读项目", target: nil, action: nil), network = NSButton(checkboxWithTitle: "允许联网与外部连接", target: nil, action: nil), enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let save = AgentDialogButton(title: "保存", target: nil, action: nil), use = AgentDialogButton(title: "新建任务", target: nil, action: nil), state = AgentSettingsStatusField("Agent 保存状态")
    private lazy var detailActions = AgentSettingsDetailActions([use, save])
    private var values: [AgentProfile] = [], selectedID: String?, openedHash: String?, dirty = false, loading = false, selectedTools = Set<String>()
    private var openedPluginModelHash: String?, openedProjectHash: String?
    private var storedIDs = Set<String>()
    private var draftOrigin: DraftOrigin?
    private var catalogLayout: (toolbar: NSView, detail: NSView)?
    private var detailPage: AgentSettingsDetailPage?
    private let catalogState = AgentSettingsStatusField("智能体列表状态")
    private var requestedDetail = false
    private var selectedSkills = Set<String>(), selectedMCP = Set<String>(), toolPermissions: [String: AgentToolPermission] = [:], mcpPermissions: [AgentMCPToolPermission] = []
    private lazy var draftViewport: AgentSettingsDraftViewport = {
        let viewport = AgentSettingsDraftViewport(text: instructions, fields: ["name": name, "purpose": purpose, "model": model], catalog: table, host: { [weak self] in self?.presentingWindow })
        viewport.onChange = { [weak self] in self?.onSettingsRecoveryChange?() }; return viewport
    }()
    override var minimumSettingsContentHeight: CGFloat { 220 }
    init(store: AgentStore, workspace: String?, workMode: AgentWorkMode? = nil, taskID: String? = nil) {
        self.store = store; self.workspace = workspace; self.taskID = taskID; self.workMode = workMode ?? store.selected?.organizationMode ?? .coding
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "自定义 Agent" + (workspace.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""); window.minSize = NSSize(width: 760, height: 540); window.center(); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agents")); table.addTableColumn(column); table.headerView = nil; table.rowHeight = 42
        table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("自定义 Agent 列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        let add = AgentDialogButton(title: "新建", target: self, action: #selector(create)), importButton = AgentDialogButton(title: "导入", target: self, action: #selector(importProfiles))
        let template = AgentDialogButton(title: "模板", target: self, action: #selector(chooseTemplate(_:)))
        for button in [add, template, importButton] { AgentDialogStyle.action(button, prominent: button === add) }
        let listActions = NSStackView(views: [add, template, importButton]); listActions.spacing = 6
        name.placeholderString = "名称"; purpose.placeholderString = "职责"; model.placeholderString = "跟随当前模型"
        for (field, label) in [(name, "Agent 名称"), (purpose, "Agent 职责"), (model, "Agent 模型")] {
            AgentSettingsStyle.field(field)
            field.delegate = self; field.setAccessibilityLabel(label); field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        permission.addItems(withTitles: AgentPermissionMode.allCases.map(\.title)); permission.target = self; permission.action = #selector(changed)
        permission.setAccessibilityLabel("Agent 审批方式")
        tools.setAccessibilityLabel("Agent 工具权限"); skills.setAccessibilityLabel("Agent Skills"); mcp.setAccessibilityLabel("Agent MCP")
        mcp.toolTip = "只列出实际配置的连接器。MCP 在项目隔离外运行，需关闭只读项目并允许外部连接；建立连接须确认，调用按工具规则和所属任务权限处理。"
        for button in [readOnly, network, enabled] { button.target = self; button.action = #selector(changed) }
        for popup in [permission, tools, skills, mcp] { popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); popup.cell?.lineBreakMode = .byTruncatingTail }
        instructions.isRichText = false; instructions.allowsUndo = true; instructions.delegate = self; instructions.font = .systemFont(ofSize: 13); instructions.textContainerInset = NSSize(width: 12, height: 12)
        instructions.isVerticallyResizable = true; instructions.autoresizingMask = [.width]; instructions.textContainer?.widthTracksTextView = true
        instructions.isAutomaticQuoteSubstitutionEnabled = false; instructions.isAutomaticTextReplacementEnabled = false; instructions.setAccessibilityLabel("Agent 指令")
        let editor = NSScrollView(); editor.documentView = instructions; editor.hasVerticalScroller = true; editor.borderType = .bezelBorder
        editor.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let form = AgentSettingsStyle.form([
            AgentSettingsStyle.section("基本信息", id: "agent-basic", rows: [AgentSettingsStyle.formRow("名称", name, trailing: false), AgentSettingsStyle.formRow("职责", purpose, trailing: false), AgentSettingsStyle.formRow("", enabled, trailing: true)]),
            AgentSettingsStyle.section("工作指令", id: "agent-instructions", rows: [editor]),
            AgentSettingsStyle.section("执行配置", id: "agent-execution", rows: [AgentSettingsStyle.labeledField("模型", model), AgentSettingsStyle.formRow("审批方式", permission, trailing: true), AgentSettingsStyle.formRow("", readOnly, trailing: true), AgentSettingsStyle.formRow("", network, trailing: true)]),
            AgentSettingsStyle.section("可选能力", id: "agent-capabilities", rows: [AgentSettingsStyle.formRow("Skills", skills, trailing: true), AgentSettingsStyle.formRow("MCP", mcp, trailing: true), AgentSettingsStyle.formRow("工具权限", tools, trailing: true)])
        ], label: "智能体配置")
        draftViewport.trackForm(form)
        save.target = self; save.action = #selector(saveProfile); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        AgentSettingsStyle.primaryAction(save); AgentDialogStyle.action(use)
        use.target = self; use.action = #selector(useProfile)
        let detail = NSStackView(views: [detailActions, state, form]); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 12
        catalogLayout = (listActions, detail)
        for view in [detailActions, state, form] { view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        for view in [list, listActions, detail] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            listActions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), listActions.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), listActions.heightAnchor.constraint(equalToConstant: 28),
            list.leadingAnchor.constraint(equalTo: listActions.leadingAnchor), list.topAnchor.constraint(equalTo: listActions.bottomAnchor, constant: 12), list.widthAnchor.constraint(equalToConstant: 190), list.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 18), detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), detail.topAnchor.constraint(equalTo: listActions.topAnchor), detail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), form.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        reload()
    }
    var scopeWorkspace: String? { workspace }
    private func sourceTask() throws -> AgentTaskRecord? { try AgentWorkspaceScope.settingsSourceTask(taskID, workspace: workspace, store: store) }
    private func availableSkills() throws -> [AgentExtensionItem] {
        if let project = values.first(where: { $0.id == selectedID })?.sourceWorkspace {
            return try store.extensions.catalog(workspace: project).filter { $0.kind == .skill }
        }
        if let task = try sourceTask() { return try store.extensions.catalog(task: task).filter { $0.kind == .skill } }
        return try store.extensions.catalog(workspace: workspace).filter { $0.kind == .skill }
    }
    private func availableServers() throws -> [AgentMCPServer] {
        if let project = values.first(where: { $0.id == selectedID })?.sourceWorkspace {
            return store.mcp.availableServers(workspace: project)
        }
        if let task = try sourceTask() { return try store.mcp.availableServers(task: task) }
        return store.mcp.availableServers(workspace: workspace)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func settingsContent(in host: NSWindow, styled: Bool = true) -> NSView? {
        if detailPage == nil, let content = window?.contentView, let layout = catalogLayout {
            AgentSettingsCatalog.detach(content)
            let title = "智能体配置"
            let page = AgentSettingsDetailPage(title: title, content: AgentSettingsCatalog.detail(layout.detail))
            page.settingsContext = (title, "")
            page.detailActionRow = detailActions
            page.onCanLeave = { [weak self] in
                guard let self, let window, windowShouldClose(window) else { return false }
                if dirty { dirty = false; reload() }; return true
            }
            page.onAppear = { [weak self] in guard let self else { return }; draftViewport.appear(default: name.isEnabled ? name : model) }
            detailPage = page; catalogLayout = nil
            state.onChange = { [weak self] value in self?.catalogState.stringValue = value; self?.onSettingsRecoveryChange?() }; catalogState.stringValue = state.stringValue
            table.target = self; table.action = #selector(openSelectedProfile); table.onOpen = { [weak self] in self?.showDetail() }
            var actions = (layout.toolbar as? NSStackView)?.arrangedSubviews ?? []
            if !actions.isEmpty { actions.append(actions.removeFirst()) }
            window?.contentView = AgentSettingsCatalog.content(table: table, toolbar: layout.toolbar, status: catalogState, actions: actions, symbol: "person.crop.square"); table.reloadData(); selectRow(selectedID); updateControls()
        }
        return super.settingsContent(in: host, styled: styled)
    }
    override var usesInternalScrolling: Bool { detailPage != nil }
    override func canLeaveSettings() -> Bool { detailPage?.settingsHostWindow != nil ? true : super.canLeaveSettings() }
    override func settingsDidAppear() {
        super.settingsDidAppear()
        if requestedDetail { requestedDetail = false; showDetail() }
        else if detailPage?.settingsHostWindow == nil { draftViewport.appear(default: table) }
    }
    override func pageDidLayout() { draftViewport.schedule() }
    @objc private func openSelectedProfile() { showDetail() }
    private func showDetail() {
        guard selectedID != nil, let detailPage else { return }
        if detailPage.settingsHostWindow == nil { presentSettingsChild(detailPage) } else { detailPage.settingsDidAppear() }
    }
    private static func toolTitle(_ name: String) -> String {
        let names = ["list_directory": "浏览文件", "read_file": "读取文件", "search_files": "搜索文件", "write_file": "写入文件", "edit_file": "编辑文件", "run_command": "终端命令", "web_search": "联网搜索", "fetch_url": "读取网页", "list_agents": "查找 Agent", "delegate_task": "委派子任务", "draft_agent": "生成 Agent 草稿", "update_plan": "执行计划", "ask_user": "向用户提问", "read_task_history": "读取本任务历史", "read_memory": "读取记忆", "write_memory": "保存记忆", "search_project": "项目检索", "index_project": "更新项目索引", "project_wiki": "读取项目 Wiki", "git_status": "Git 状态", "git_diff": "Git 差异", "git_commit": "Git 提交", "git_init": "初始化 Git", "git_create_worktree": "创建工作树", "list_attachments": "列出附件", "read_attachment": "读取附件", "search_attachment": "搜索附件", "browser_open": "打开网页", "browser_tabs": "浏览器标签页", "browser_read": "读取页面", "browser_screenshot": "网页截图", "browser_action": "网页操作", "browser_close": "关闭浏览器", "load_tools": "按需载入工具", "list_skills": "查找 Skills", "read_skill": "载入 Skill", "read_skill_resource": "读取 Skill 资源", "unload_skill": "移出 Skill", "list_mcp_servers": "列出 MCP", "connect_mcp": "连接 MCP", "list_mcp_tools": "MCP 工具目录", "call_mcp_tool": "调用 MCP 工具", "disconnect_mcp": "断开 MCP"]
        let desktopNames = ["desktop_status": "电脑操作状态", "desktop_windows": "查找应用窗口", "desktop_connect": "连接指定窗口", "desktop_read": "读取指定窗口", "desktop_screenshot": "截取指定窗口", "desktop_action": "操作指定窗口", "desktop_disconnect": "断开窗口连接"]
        let canvasNames = ["canvas_create": "生成画布", "canvas_read": "读取画布", "canvas_update": "更新画布", "canvas_edit": "编辑画布", "canvas_restore": "恢复画布版本", "canvas_inspect": "核对画布", "canvas_screenshot": "截取画布", "canvas_list": "任务画布"]
        let knowledgeNames = ["list_knowledge": "列出知识库", "search_knowledge": "检索知识库", "read_knowledge": "读取知识文件", "read_project_knowledge": "读取知识卡片", "edit_project_knowledge": "更新知识卡片", "save_knowledge_card": "保存卡片草稿"]
        return name == "draft_automation" ? "起草自动化" : names[name] ?? desktopNames[name] ?? canvasNames[name] ?? knowledgeNames[name] ?? name
    }
    func numberOfRows(in tableView: NSTableView) -> Int { values.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value = values[row]
        if detailPage != nil {
            let title = value.name.isEmpty ? "未命名智能体" : AgentProfiles.title(value, task: try? sourceTask())
            let source = value.pluginSource.map { "插件 · " + ((try? AgentPlugins.scope($0.name).name) ?? $0.name) }
                ?? value.sourceWorkspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return AgentSettingsCatalogCell(title: title, summary: [value.description, source].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "person.crop.square", status: value.enabled ? "已启用" : "已停用", group: table.group(at: row)) { [weak self] in self?.selectProfile(value.id) }
        }
        let text = NSTextField(labelWithString: (value.name.isEmpty ? "未命名智能体" : value.name) + (value.enabled ? "" : " · 已停用")); text.font = .systemFont(ofSize: 12, weight: .medium); text.lineBreakMode = .byTruncatingTail; text.toolTip = value.description; return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading, values.indices.contains(table.selectedRow) else { return }
        let next = values[table.selectedRow].id
        if dirty { state.stringValue = "请先保存更改"; selectRow(selectedID); return }
        open(next)
    }
    private func selectRow(_ id: String?) { loading = true; defer { loading = false }; if let index = values.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } else { table.deselectAll(nil) } }
    private func reload() {
        do {
            openedHash = try store.agents.document().1
            openedProjectHash = try workspace.flatMap { try store.agents.document(workspace: $0).1 }
            openedPluginModelHash = try store.agents.pluginModelVersion()
            values = try store.agents.list(workspace: workspace); storedIDs = Set(values.map(\.id))
            loading = true; table.reloadData(); loading = false
            open(values.first(where: { $0.id == selectedID })?.id ?? values.first?.id)
        }
        catch { state.stringValue = error.localizedDescription }
    }
    private func open(_ id: String?) {
        draftViewport.reset()
        if draftOrigin?.profileID != id { draftOrigin = nil }
        loading = true; defer { loading = false }; selectedID = id
        let value = values.first { $0.id == id }; name.stringValue = value?.name ?? ""; purpose.stringValue = value?.description ?? ""; model.stringValue = value?.model ?? ""; instructions.string = value?.instructions ?? ""
        permission.selectItem(at: AgentPermissionMode.allCases.firstIndex(of: value?.permission ?? .review) ?? 0); readOnly.state = value?.readOnly == false ? .off : .on; network.state = value?.network == true ? .on : .off; enabled.state = value?.enabled == true ? .on : .off; selectedTools = Set(value?.tools ?? [])
        selectedSkills = Set(value?.skills ?? []); selectedMCP = Set(value?.mcpServers ?? []); toolPermissions = value?.toolPermissions ?? [:]; mcpPermissions = value?.mcpToolPermissions ?? []
        refreshMenus()
        dirty = false; instructions.undoManager?.removeAllActions(); selectRow(id); updateControls()
        state.stringValue = value?.pluginSource.map { "由插件管理 · " + ((try? AgentPlugins.scope($0.name).name) ?? "") }
            ?? (detailPage == nil ? value?.sourceWorkspace.map { "项目 · " + URL(fileURLWithPath: $0).lastPathComponent } : nil) ?? ""
    }
    private func editedValue() -> AgentProfile? {
        guard var value = values.first(where: { $0.id == selectedID }) else { return nil }
        value.model = model.stringValue
        guard value.pluginSource == nil else { return value }
        value.name = name.stringValue; value.description = purpose.stringValue; value.instructions = instructions.string
        value.permission = AgentPermissionMode.allCases[max(0, permission.indexOfSelectedItem)]; value.readOnly = readOnly.state == .on; value.network = network.state == .on; value.enabled = enabled.state == .on; value.tools = selectedTools.sorted()
        value.skills = selectedSkills.isEmpty ? nil : selectedSkills.sorted(); value.mcpServers = selectedMCP.isEmpty ? nil : selectedMCP.sorted(); value.toolPermissions = toolPermissions.isEmpty ? nil : toolPermissions; value.mcpToolPermissions = mcpPermissions.isEmpty ? nil : mcpPermissions
        return value
    }
    private func updateControls() {
        AgentSettingsStyle.listState(table, text: "暂无智能体")
        let value = values.first { $0.id == selectedID }
        let hasValue = selectedID != nil, packaged = value?.pluginSource != nil
        for item in [name, purpose, permission, tools, skills, mcp, readOnly, network, enabled] as [NSControl] { item.isEnabled = hasValue && !packaged }
        model.isEnabled = hasValue; instructions.isEditable = hasValue && !packaged; save.isEnabled = dirty; use.isEnabled = !dirty && enabled.state == .on && hasValue
        detailPage?.detailHeading = value.map { profile in
            let project = profile.sourceWorkspace ?? profile.pluginSource.flatMap { (try? AgentPlugins.scope($0.name))?.workspace }
            let location = project.map { URL(fileURLWithPath: $0).lastPathComponent }
            let source = packaged ? (project == nil ? "用户插件" : "项目插件") : (project == nil ? "用户" : "项目")
            let title = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(title: title.isEmpty ? "新建智能体" : title,
                scope: [source, location].compactMap { $0 }.joined(separator: " · "), location: project)
        }
    }
    func selectProfile(_ id: String) { guard !dirty else { state.stringValue = "请先保存 Agent 更改"; return }; selectedID = id; reload(); if settingsHostWindow != nil { showDetail() } else { requestedDetail = true } }
    func configureDraft(_ draft: AgentProfileDraft) throws {
        _ = try AgentProfileDrafts.checked(draft, taskID: draft.taskID, agents: store.agents)
        if dirty { guard selectedID == draft.profile.id else { throw PetError("请先保存或关闭已打开的 Agent 更改") }; if detailPage?.isPageVisible != true { showDetail() }; return }
        let document = try store.agents.document(), current = try store.agents.list(workspace: workspace)
        let existing = current.first { $0.id == draft.profile.id && $0.pluginSource == nil }
        guard draft.savedAt == nil || existing != nil else { throw PetError("此草稿保存的 Agent 已移除，原草稿保留") }
        openedHash = document.1; openedPluginModelHash = try store.agents.pluginModelVersion(); values = current; storedIDs = Set(current.map(\.id))
        openedProjectHash = try workspace.flatMap { try store.agents.document(workspace: $0).1 }
        draftOrigin = DraftOrigin(id: draft.id, taskID: draft.taskID, profileID: draft.profile.id)
        if existing == nil { values.append(draft.profile) }
        loading = true; table.reloadData(); loading = false; open(draft.profile.id)
        if existing == nil { changed(); presentingWindow?.makeFirstResponder(name) }
        if settingsHostWindow != nil { showDetail() } else { requestedDetail = true }
    }
    func controlTextDidChange(_ obj: Notification) { changed() }
    func textDidChange(_ notification: Notification) { changed() }
    @objc private func changed() { guard !loading else { return }; dirty = true; draftViewport.changed(); state.stringValue = "未保存"; updateControls() }
    private func refreshMenus() {
        tools.removeAllItems(); tools.addItem(withTitle: "工具权限")
        for key in AgentProfiles.toolNames.sorted() {
            let item = NSMenuItem(title: Self.toolTitle(key), action: nil, keyEquivalent: ""), menu = NSMenu()
            let implicit = !selectedSkills.isEmpty && AgentProfiles.skillTools.contains(key) || !selectedMCP.isEmpty && AgentMCP.tools.contains(key)
            for (title, value) in (implicit ? [] : [("未启用", "off")]) + AgentToolPermission.allCases.map({ ($0.title, $0.rawValue) }) {
                let option = NSMenuItem(title: title, action: #selector(changeTool(_:)), keyEquivalent: ""); option.target = self; option.representedObject = [key, value]
                option.state = (!selectedTools.contains(key) && !implicit ? value == "off" : value == (toolPermissions[key] ?? .inherit).rawValue) ? .on : .off; menu.addItem(option)
            }
            item.submenu = menu; item.toolTip = key; tools.menu?.addItem(item)
        }
        skills.removeAllItems(); skills.addItem(withTitle: "Skills（\(selectedSkills.count)）")
        let available = (try? availableSkills()) ?? [], multipleSources = (try? sourceTask())?.workspaceScope != nil
        for item in available {
            let row = NSMenuItem(title: item.name + (multipleSources ? " · " + item.scope : "") + (item.enabled ? "" : " · 已停用"), action: #selector(toggleSkill(_:)), keyEquivalent: ""); row.target = self; row.representedObject = item.id; row.state = selectedSkills.contains(item.id) ? .on : .off; row.isEnabled = item.enabled || selectedSkills.contains(item.id); row.toolTip = item.description + "\n" + item.file.path; skills.menu?.addItem(row)
        }
        for id in selectedSkills.subtracting(available.map(\.id)).sorted() { let row = NSMenuItem(title: "不可用 Skill · " + id.prefix(8), action: #selector(toggleSkill(_:)), keyEquivalent: ""); row.target = self; row.representedObject = id; row.state = .on; skills.menu?.addItem(row) }
        mcp.removeAllItems(); mcp.addItem(withTitle: "MCP（\(selectedMCP.count)）")
        let servers = (try? availableServers()) ?? []
        for item in servers {
            let row = NSMenuItem(title: (multipleSources ? AgentMCPSelection.title(item) : item.name) + (item.enabled ? "" : " · 已停用"), action: #selector(toggleMCP(_:)), keyEquivalent: ""); row.target = self; row.representedObject = item.id; row.state = selectedMCP.contains(item.id) ? .on : .off; row.isEnabled = item.enabled || selectedMCP.contains(item.id); row.toolTip = AgentMCPSelection.selectionTitle(item); mcp.menu?.addItem(row)
        }
        for id in selectedMCP.subtracting(servers.map(\.id)).sorted() { let row = NSMenuItem(title: "不可用 MCP · " + id.prefix(8), action: #selector(toggleMCP(_:)), keyEquivalent: ""); row.target = self; row.representedObject = id; row.state = .on; mcp.menu?.addItem(row) }
        if !selectedMCP.isEmpty {
            mcp.menu?.addItem(.separator())
            for rule in mcpPermissions {
                let selected = servers.first { $0.id == rule.serverID }
                let row = NSMenuItem(title: (selected.map { multipleSources ? AgentMCPSelection.title($0) : $0.name } ?? "MCP") + " / " + rule.tool, action: nil, keyEquivalent: ""), menu = NSMenu()
                for (title, value) in [("移除规则", "remove")] + AgentToolPermission.allCases.map({ ($0.title, $0.rawValue) }) {
                    let option = NSMenuItem(title: title, action: #selector(changeMCPRule(_:)), keyEquivalent: ""); option.target = self; option.representedObject = [rule.serverID, rule.tool, value]; option.state = rule.permission.rawValue == value ? .on : .off; menu.addItem(option)
                }; row.submenu = menu; mcp.menu?.addItem(row)
            }
            let add = NSMenuItem(title: "添加工具规则…", action: #selector(addMCPRule), keyEquivalent: ""); add.target = self; mcp.menu?.addItem(add)
        }
    }
    @objc private func changeTool(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String], value.count == 2 else { return }
        if let rule = AgentToolPermission(rawValue: value[1]) { selectedTools.insert(value[0]); toolPermissions[value[0]] = rule == .inherit ? nil : rule }
        else { selectedTools.remove(value[0]); toolPermissions[value[0]] = nil }
        refreshMenus(); changed()
    }
    @objc private func toggleSkill(_ sender: NSMenuItem) { guard let id = sender.representedObject as? String else { return }; if !selectedSkills.insert(id).inserted { selectedSkills.remove(id) }; refreshMenus(); changed() }
    @objc private func toggleMCP(_ sender: NSMenuItem) { guard let id = sender.representedObject as? String else { return }; if !selectedMCP.insert(id).inserted { selectedMCP.remove(id); mcpPermissions.removeAll { $0.serverID == id } }; refreshMenus(); changed() }
    @objc private func changeMCPRule(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String], value.count == 3 else { return }
        mcpPermissions.removeAll { $0.serverID == value[0] && $0.tool == value[1] }
        if let rule = AgentToolPermission(rawValue: value[2]) { mcpPermissions.append(AgentMCPToolPermission(serverID: value[0], tool: value[1], permission: rule)) }; refreshMenus(); changed()
    }
    @objc private func addMCPRule() {
        guard let profile = editedValue(), profile.pluginSource == nil else { return }
        let servers = ((try? availableServers()) ?? []).filter { selectedMCP.contains($0.id) }
        guard !servers.isEmpty else { return }
        presentSettingsChild(makeMCPRulePage(profile: profile, servers: servers))
    }
    private func makeMCPRulePage(profile: AgentProfile, servers: [AgentMCPServer]) -> AgentMCPToolRulePage {
        let profileID = profile.id
        let page = AgentMCPToolRulePage(servers: servers, profileID: profileID, profileName: profile.name)
        page.onApply = { [weak self] rule, revision in
            guard let self, selectedID == profileID, selectedMCP.contains(rule.serverID),
                  try availableServers().contains(where: { $0.id == rule.serverID && $0.revision == revision }) else {
                throw PetError("连接器配置已变化，请返回后重新选择")
            }
            mcpPermissions.removeAll { $0.serverID == rule.serverID && $0.tool == rule.tool }; mcpPermissions.append(rule); refreshMenus(); changed()
        }
        page.onApplied = { [weak self] in guard let self else { return }; presentingWindow?.makeFirstResponder(mcp) }
        return page
    }
    override func makeSettingsRecoveryChild(_ page: AgentSettingsRecovery.Page) throws -> AgentSettingsPageController? {
        guard page.kind == "mcp-tool-rule", detailPage?.settingsHostWindow != nil,
              let profile = editedValue(), profile.pluginSource == nil else { return nil }
        return makeMCPRulePage(profile: profile, servers: try availableServers().filter { selectedMCP.contains($0.id) })
    }
    @objc private func create() { guard !dirty else { state.stringValue = "请先保存更改"; return }; let value = AgentProfile(name: "", description: "", instructions: ""); values.append(value); table.reloadData(); open(value.id); changed(); showDetail(); presentingWindow?.makeFirstResponder(name) }
    @objc private func chooseTemplate(_ sender: NSButton) {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        let menu = NSMenu()
        for (index, value) in AgentTemplates.profiles.enumerated() { let item = NSMenuItem(title: value.name, action: #selector(useTemplate(_:)), keyEquivalent: ""); item.target = self; item.tag = index; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    @objc private func useTemplate(_ sender: NSMenuItem) {
        guard !dirty, AgentTemplates.profiles.indices.contains(sender.tag) else { return }
        var value = AgentTemplates.profiles[sender.tag]
        let base = value.name; var suffix = 2
        while values.contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) { value.name = base + " \(suffix)"; suffix += 1 }
        values.append(value); table.reloadData(); open(value.id); changed(); showDetail(); presentingWindow?.makeFirstResponder(name)
    }
    @objc private func saveProfile() {
        do {
            _ = try sourceTask()
            guard let value = editedValue() else { return }
            let updated = values.map { $0.id == value.id ? value : $0 }
            if value.pluginSource != nil { try store.agents.savePluginModel(value, model: value.model, expectedHash: openedPluginModelHash) }
            else if let project = value.sourceWorkspace {
                guard project == workspace else { throw PetError("Agent 所属项目已变化") }
                try AgentMCPDataImport.requireDestination(project, store: store)
                try store.agents.save(store.agents.encode(updated, workspace: project), expectedHash: openedProjectHash, workspace: project)
            } else { try store.agents.save(store.agents.encode(updated), expectedHash: openedHash) }
            dirty = false; reload(); state.stringValue = "已保存"
            do {
                if let origin = draftOrigin, origin.profileID == value.id {
                    try AgentProfileDrafts.markSaved(origin.id, taskID: origin.taskID, profileID: value.id, store: store); draftOrigin = nil
                }
                try onSaved?(value.id)
            } catch { state.stringValue = "Agent 已保存；" + error.localizedDescription }
        } catch { state.showSaveFailure(error) }
    }
    @objc private func useProfile() { do { guard !dirty, let selectedID else { throw PetError("请先保存 Agent") }; let context = try sourceTask(); let id = try store.agents.createTask(selectedID, store: store, workspace: context == nil ? workspace : context?.workspace, workMode: workMode, context: context); onUse?(id); window?.orderOut(nil) } catch { state.stringValue = error.localizedDescription } }
    @objc private func importProfiles() {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = try Data(contentsOf: url, options: .mappedIfSafe); guard data.count <= 512_000, let text = String(data: data, encoding: .utf8) else { throw PetError("请选择不超过512KB的 UTF-8 JSON") }; let imported = try store.agents.decode(text, importing: true); guard !imported.isEmpty else { throw PetError("没有可导入的 Agent") }; values += imported; table.reloadData(); open(imported.first?.id); changed(); state.stringValue = "导入待保存，默认停用"; showDetail() }
        catch { state.stringValue = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if dirty { guard AgentUnsavedChanges.discard("放弃未保存的 Agent 更改？") else { return false } }
        return true
    }
    private struct DraftOrigin: Codable { var id: String, taskID: String, profileID: String }
    private struct Recovery: Codable {
        var version = 1
        var taskID: String?, workspace: String?
        var value: AgentProfile?, staged: [AgentProfile], origin: DraftOrigin?
        var openedHash: String?, pluginHash: String?, projectHash: String?
        var showsDetail: Bool, dirty: Bool, status: String
        var viewport: AgentSettingsDraftViewport.State
    }
    override func captureSettingsRecovery() throws -> AgentSettingsRecovery.Page? {
        let value = editedValue()
        return try AgentSettingsRecovery.page("agents", Recovery(taskID: taskID, workspace: workspace, value: value,
            staged: dirty ? values.filter { !storedIDs.contains($0.id) && $0.pluginSource == nil } : [], origin: draftOrigin?.profileID == value?.id ? draftOrigin : nil,
            openedHash: openedHash, pluginHash: openedPluginModelHash, projectHash: openedProjectHash, showsDetail: detailPage?.settingsHostWindow != nil,
            dirty: dirty, status: state.stringValue, viewport: try draftViewport.capture()))
    }
    override func restoreSettingsRecovery(_ page: AgentSettingsRecovery.Page) throws {
        guard page.kind == "agents" else { throw PetError("设置草稿不属于智能体") }
        let raw = try AgentSettingsRecovery.object(JSONSerialization.jsonObject(with: page.state), keys: ["version", "taskID", "workspace", "value", "staged", "origin", "openedHash", "pluginHash", "projectHash", "showsDetail", "dirty", "status", "viewport"])
        if let viewport = raw["viewport"] { try AgentSettingsDraftViewport.validateObject(viewport) }
        let draft = try JSONDecoder().decode(Recovery.self, from: page.state)
        let reopen = draft.showsDetail || draft.dirty
        guard draft.version == 1, draft.taskID == taskID, draft.workspace == workspace,
              !reopen || draft.value != nil, draft.staged.count <= 64, Set(draft.staged.map(\.id)).count == draft.staged.count,
              draft.staged.allSatisfy({ $0.pluginSource == nil && $0.sourceWorkspace == nil }), AgentSettingsRecovery.validHash(draft.openedHash),
              AgentSettingsRecovery.validHash(draft.pluginHash), AgentSettingsRecovery.validHash(draft.projectHash),
              draft.value?.sourceWorkspace.map({ $0 == workspace && draft.projectHash != nil }) != false else { throw PetError("智能体草稿范围或版本已变化") }
        _ = try sourceTask()
        if let origin = draft.origin {
            guard origin.profileID == draft.value?.id,
                  try AgentWorkspaceScope.settingsSourceTask(origin.taskID, workspace: workspace, store: store) != nil,
                  try AgentProfileDrafts.load(origin.id, taskID: origin.taskID, store: store).profile.id == origin.profileID else { throw PetError("原任务的智能体草稿已变化") }
        }
        let currentHash = try store.agents.document().1, pluginHash = try store.agents.pluginModelVersion()
        let projectHash = try workspace.flatMap { try store.agents.document(workspace: $0).1 }
        let current = try store.agents.list(workspace: workspace)
        let stored = current.first { $0.id == draft.value?.id }
        let stale: Bool
        if draft.value?.pluginSource != nil { stale = pluginHash != draft.pluginHash || stored?.pluginSource != draft.value?.pluginSource }
        else if draft.value?.sourceWorkspace != nil { stale = projectHash != draft.projectHash || stored?.sourceWorkspace != draft.value?.sourceWorkspace }
        else { stale = currentHash != draft.openedHash }
        if reopen {
            let value = draft.value
            try draftViewport.validate(draft.viewport, text: value?.instructions ?? "", fields: ["name": value?.name ?? "", "purpose": value?.description ?? "", "model": value?.model ?? ""])
        }
        values = current; storedIDs = Set(current.map(\.id)); openedHash = currentHash; openedPluginModelHash = pluginHash; openedProjectHash = projectHash
        if reopen {
            for value in draft.staged where !storedIDs.contains(value.id) { values.append(value) }
            if let value = draft.value {
                if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
                else { values.append(value) }
            }
            openedHash = draft.openedHash; openedPluginModelHash = draft.pluginHash; openedProjectHash = draft.projectHash
        }
        loading = true; table.reloadData(); loading = false; open(draft.value?.id)
        dirty = reopen && (draft.dirty || stale); draftOrigin = draft.origin; updateControls()
        if reopen {
            var viewport = draft.viewport
            if viewport.focus == "catalog" { viewport.focus = draft.value?.pluginSource == nil ? "body" : "model" }
            try draftViewport.restore(viewport)
            state.stringValue = stale ? "原智能体配置已变化，草稿已保留" : draft.status
            if settingsHostWindow != nil { showDetail() } else { requestedDetail = true }
        } else if let y = draft.viewport.catalogY {
            var viewport = try draftViewport.capture(); viewport.catalogY = y; viewport.focus = "catalog"
            try draftViewport.restore(viewport)
        }
    }
    func checkScopeLayout(_ output: URL) async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for (name, size) in [("normal", NSSize(width: 1000, height: 660)), ("narrow", NSSize(width: 760, height: 540))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["scopeLayout-" + name] = instructions.bounds.height > 120 && instructions.bounds.width > 400 && !skills.hasAmbiguousLayout && !mcp.hasAmbiguousLayout && !permission.hasAmbiguousLayout
            if let view = window?.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: image); try? image.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("agent-scopes-" + name + ".png")) }
        }
        window?.setContentSize(NSSize(width: 1000, height: 660)); return checks
    }
}
