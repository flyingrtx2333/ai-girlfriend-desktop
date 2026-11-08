import AppKit
import UniformTypeIdentifiers

@MainActor final class AgentProfileWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    let store: AgentStore
    let workspace: String?
    private let workMode: AgentWorkMode
    var onUse: ((String) -> Void)?
    private let table = NSTableView(), name = NSTextField(), purpose = NSTextField(), model = NSTextField(), instructions = NSTextView()
    private let permission = NSPopUpButton(), tools = NSPopUpButton(frame: .zero, pullsDown: true)
    private let skills = NSPopUpButton(frame: .zero, pullsDown: true), mcp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let readOnly = NSButton(checkboxWithTitle: "只读项目", target: nil, action: nil), network = NSButton(checkboxWithTitle: "允许联网与外部连接", target: nil, action: nil), enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let save = NSButton(title: "保存", target: nil, action: nil), use = NSButton(title: "新建任务", target: nil, action: nil), state = NSTextField(labelWithString: "")
    private var values: [AgentProfile] = [], selectedID: String?, openedHash: String?, dirty = false, loading = false, selectedTools = Set<String>()
    private var selectedSkills = Set<String>(), selectedMCP = Set<String>(), toolPermissions: [String: AgentToolPermission] = [:], mcpPermissions: [AgentMCPToolPermission] = []
    init(store: AgentStore, workspace: String?, workMode: AgentWorkMode? = nil) {
        self.store = store; self.workspace = workspace; self.workMode = workMode ?? store.selected?.organizationMode ?? .coding
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "自定义 Agent"; window.minSize = NSSize(width: 760, height: 540); window.center(); window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agents")); table.addTableColumn(column); table.headerView = nil; table.rowHeight = 42
        table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("自定义 Agent 列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        let add = NSButton(title: "新建", target: self, action: #selector(create)), importButton = NSButton(title: "导入", target: self, action: #selector(importProfiles))
        let template = NSButton(title: "模板", target: self, action: #selector(chooseTemplate))
        let listActions = NSStackView(views: [add, template, importButton]); listActions.spacing = 6
        name.placeholderString = "名称"; purpose.placeholderString = "职责"; model.placeholderString = "跟随当前模型"
        for (field, label) in [(name, "Agent 名称"), (purpose, "Agent 职责"), (model, "Agent 模型")] { field.delegate = self; field.font = .systemFont(ofSize: 13); field.setAccessibilityLabel(label) }
        permission.addItems(withTitles: AgentPermissionMode.allCases.map(\.title)); permission.target = self; permission.action = #selector(changed)
        permission.setAccessibilityLabel("Agent 审批方式")
        tools.setAccessibilityLabel("Agent 工具权限"); skills.setAccessibilityLabel("Agent Skills"); mcp.setAccessibilityLabel("Agent MCP")
        mcp.toolTip = "只列出实际配置的连接器。MCP 在项目隔离外运行，需关闭只读项目并允许外部连接；建立连接须确认，调用按工具规则和所属任务权限处理。"
        for button in [readOnly, network, enabled] { button.target = self; button.action = #selector(changed) }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "名称"), name], [NSTextField(labelWithString: "职责"), purpose], [NSTextField(labelWithString: "模型"), model]])
        grid.columnSpacing = 12; grid.rowSpacing = 10; grid.column(at: 0).width = 52; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .fill
        let execution = NSStackView(views: [permission, tools, NSView()]); execution.spacing = 10
        let extensions = NSStackView(views: [skills, mcp, NSView()]); extensions.spacing = 10
        let limits = NSStackView(views: [readOnly, network, NSView(), enabled]); limits.spacing = 10
        let options = NSStackView(views: [execution, extensions, limits]); options.orientation = .vertical; options.alignment = .leading; options.spacing = 10
        for row in [execution, extensions, limits] { row.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true }
        instructions.isRichText = false; instructions.allowsUndo = true; instructions.delegate = self; instructions.font = .systemFont(ofSize: 13); instructions.textContainerInset = NSSize(width: 12, height: 12)
        instructions.isVerticallyResizable = true; instructions.autoresizingMask = [.width]; instructions.textContainer?.widthTracksTextView = true
        instructions.isAutomaticQuoteSubstitutionEnabled = false; instructions.isAutomaticTextReplacementEnabled = false; instructions.setAccessibilityLabel("Agent 指令")
        let editor = NSScrollView(); editor.documentView = instructions; editor.hasVerticalScroller = true; editor.borderType = .bezelBorder
        let label = NSTextField(labelWithString: "指令"); label.font = .systemFont(ofSize: 12, weight: .medium)
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor; state.lineBreakMode = .byTruncatingTail; state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        save.target = self; save.action = #selector(saveProfile); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        use.target = self; use.action = #selector(useProfile)
        let footer = NSStackView(views: [state, NSView(), use, save]); footer.spacing = 10
        for view in [list, listActions, grid, options, label, editor, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), list.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), list.widthAnchor.constraint(equalToConstant: 190), list.bottomAnchor.constraint(equalTo: listActions.topAnchor, constant: -10),
            listActions.leadingAnchor.constraint(equalTo: list.leadingAnchor), listActions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            grid.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 18), grid.topAnchor.constraint(equalTo: list.topAnchor), grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            options.leadingAnchor.constraint(equalTo: grid.leadingAnchor), options.trailingAnchor.constraint(equalTo: grid.trailingAnchor), options.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: grid.leadingAnchor), label.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 14),
            editor.leadingAnchor.constraint(equalTo: grid.leadingAnchor), editor.trailingAnchor.constraint(equalTo: grid.trailingAnchor), editor.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8), editor.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: grid.leadingAnchor), footer.trailingAnchor.constraint(equalTo: grid.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14), footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private static func toolTitle(_ name: String) -> String {
        let names = ["list_directory": "浏览文件", "read_file": "读取文件", "search_files": "搜索文件", "write_file": "写入文件", "edit_file": "编辑文件", "run_command": "终端命令", "web_search": "联网搜索", "fetch_url": "读取网页", "list_agents": "查找 Agent", "delegate_task": "委派子任务", "update_plan": "执行计划", "ask_user": "向用户提问", "read_task_history": "读取本任务历史", "read_memory": "读取记忆", "write_memory": "保存记忆", "search_project": "项目检索", "index_project": "更新项目索引", "project_wiki": "读取项目 Wiki", "git_status": "Git 状态", "git_diff": "Git 差异", "git_commit": "Git 提交", "git_init": "初始化 Git", "git_create_worktree": "创建工作树", "list_attachments": "列出附件", "read_attachment": "读取附件", "search_attachment": "搜索附件", "browser_open": "打开网页", "browser_tabs": "浏览器标签页", "browser_read": "读取页面", "browser_screenshot": "网页截图", "browser_action": "网页操作", "browser_close": "关闭浏览器", "load_tools": "按需载入工具", "list_skills": "查找 Skills", "read_skill": "载入 Skill", "read_skill_resource": "读取 Skill 资源", "unload_skill": "移出 Skill", "list_mcp_servers": "列出 MCP", "connect_mcp": "连接 MCP", "list_mcp_tools": "MCP 工具目录", "call_mcp_tool": "调用 MCP 工具", "disconnect_mcp": "断开 MCP"]
        let desktopNames = ["desktop_status": "电脑操作状态", "desktop_windows": "查找应用窗口", "desktop_connect": "连接指定窗口", "desktop_read": "读取指定窗口", "desktop_screenshot": "截取指定窗口", "desktop_action": "操作指定窗口", "desktop_disconnect": "断开窗口连接"]
        let canvasNames = ["canvas_create": "生成画布", "canvas_read": "读取画布", "canvas_update": "更新画布", "canvas_edit": "编辑画布", "canvas_restore": "恢复画布版本", "canvas_inspect": "核对画布", "canvas_screenshot": "截取画布", "canvas_list": "任务画布"]
        return names[name] ?? desktopNames[name] ?? canvasNames[name] ?? name
    }
    func numberOfRows(in tableView: NSTableView) -> Int { values.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value = values[row], text = NSTextField(labelWithString: value.name + (value.enabled ? "" : " · 已停用")); text.font = .systemFont(ofSize: 12, weight: .medium); text.lineBreakMode = .byTruncatingTail; text.toolTip = value.description; return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading, values.indices.contains(table.selectedRow) else { return }
        let next = values[table.selectedRow].id
        if dirty { state.stringValue = "请先保存更改"; selectRow(selectedID); return }
        open(next)
    }
    private func selectRow(_ id: String?) { loading = true; defer { loading = false }; if let index = values.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } else { table.deselectAll(nil) } }
    private func reload() {
        do { let (text, hash) = try store.agents.document(); values = try store.agents.decode(text); openedHash = hash; loading = true; table.reloadData(); loading = false; open(values.first(where: { $0.id == selectedID })?.id ?? values.first?.id) }
        catch { state.stringValue = error.localizedDescription }
    }
    private func open(_ id: String?) {
        loading = true; defer { loading = false }; selectedID = id
        let value = values.first { $0.id == id }; name.stringValue = value?.name ?? ""; purpose.stringValue = value?.description ?? ""; model.stringValue = value?.model ?? ""; instructions.string = value?.instructions ?? ""
        permission.selectItem(at: AgentPermissionMode.allCases.firstIndex(of: value?.permission ?? .review) ?? 0); readOnly.state = value?.readOnly == false ? .off : .on; network.state = value?.network == true ? .on : .off; enabled.state = value?.enabled == true ? .on : .off; selectedTools = Set(value?.tools ?? [])
        selectedSkills = Set(value?.skills ?? []); selectedMCP = Set(value?.mcpServers ?? []); toolPermissions = value?.toolPermissions ?? [:]; mcpPermissions = value?.mcpToolPermissions ?? []
        refreshMenus()
        dirty = false; instructions.undoManager?.removeAllActions(); selectRow(id); updateControls(); state.stringValue = value == nil ? "暂无 Agent" : ""
    }
    private func capture() {
        guard let i = values.firstIndex(where: { $0.id == selectedID }) else { return }
        values[i].name = name.stringValue; values[i].description = purpose.stringValue; values[i].model = model.stringValue; values[i].instructions = instructions.string
        values[i].permission = AgentPermissionMode.allCases[max(0, permission.indexOfSelectedItem)]; values[i].readOnly = readOnly.state == .on; values[i].network = network.state == .on; values[i].enabled = enabled.state == .on; values[i].tools = selectedTools.sorted()
        values[i].skills = selectedSkills.isEmpty ? nil : selectedSkills.sorted(); values[i].mcpServers = selectedMCP.isEmpty ? nil : selectedMCP.sorted(); values[i].toolPermissions = toolPermissions.isEmpty ? nil : toolPermissions; values[i].mcpToolPermissions = mcpPermissions.isEmpty ? nil : mcpPermissions
    }
    private func updateControls() { let hasValue = selectedID != nil; for item in [name, purpose, model, permission, tools, skills, mcp, readOnly, network, enabled] as [NSControl] { item.isEnabled = hasValue }; instructions.isEditable = hasValue; save.isEnabled = dirty; use.isEnabled = !dirty && enabled.state == .on && hasValue }
    func controlTextDidChange(_ obj: Notification) { changed() }
    func textDidChange(_ notification: Notification) { changed() }
    @objc private func changed() { guard !loading else { return }; dirty = true; state.stringValue = "未保存"; updateControls() }
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
        let available = (try? store.extensions.catalog(workspace: workspace))?.filter { $0.kind == .skill } ?? []
        for item in available {
            let row = NSMenuItem(title: item.name + (item.enabled ? "" : " · 已停用"), action: #selector(toggleSkill(_:)), keyEquivalent: ""); row.target = self; row.representedObject = item.id; row.state = selectedSkills.contains(item.id) ? .on : .off; row.isEnabled = item.enabled || selectedSkills.contains(item.id); row.toolTip = item.description; skills.menu?.addItem(row)
        }
        for id in selectedSkills.subtracting(available.map(\.id)).sorted() { let row = NSMenuItem(title: "不可用 Skill · " + id.prefix(8), action: #selector(toggleSkill(_:)), keyEquivalent: ""); row.target = self; row.representedObject = id; row.state = .on; skills.menu?.addItem(row) }
        mcp.removeAllItems(); mcp.addItem(withTitle: "MCP（\(selectedMCP.count)）")
        for item in store.mcp.servers {
            let row = NSMenuItem(title: item.name + (item.enabled ? "" : " · 已停用"), action: #selector(toggleMCP(_:)), keyEquivalent: ""); row.target = self; row.representedObject = item.id; row.state = selectedMCP.contains(item.id) ? .on : .off; row.isEnabled = item.enabled || selectedMCP.contains(item.id); mcp.menu?.addItem(row)
        }
        for id in selectedMCP.subtracting(store.mcp.servers.map(\.id)).sorted() { let row = NSMenuItem(title: "不可用 MCP · " + id.prefix(8), action: #selector(toggleMCP(_:)), keyEquivalent: ""); row.target = self; row.representedObject = id; row.state = .on; mcp.menu?.addItem(row) }
        if !selectedMCP.isEmpty {
            mcp.menu?.addItem(.separator())
            for rule in mcpPermissions {
                let row = NSMenuItem(title: (store.mcp.servers.first { $0.id == rule.serverID }?.name ?? "MCP") + " / " + rule.tool, action: nil, keyEquivalent: ""), menu = NSMenu()
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
        let servers = store.mcp.servers.filter { selectedMCP.contains($0.id) }; guard !servers.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "MCP 工具权限"; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        let server = NSPopUpButton(), tool = NSTextField(), rule = NSPopUpButton()
        server.addItems(withTitles: servers.map(\.name)); tool.placeholderString = "实际工具名"; tool.setAccessibilityLabel("MCP 工具名"); rule.addItems(withTitles: AgentToolPermission.allCases.map(\.title)); rule.selectItem(at: AgentToolPermission.allCases.firstIndex(of: .ask)!)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "连接器"), server], [NSTextField(labelWithString: "工具"), tool], [NSTextField(labelWithString: "权限"), rule]]); grid.rowSpacing = 10; grid.columnSpacing = 12; grid.frame.size = NSSize(width: 390, height: 100); alert.accessoryView = grid
        guard alert.runModal() == .alertFirstButtonReturn else { return }; let name = tool.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { state.stringValue = "请输入有效的实际工具名"; return }
        let id = servers[server.indexOfSelectedItem].id; mcpPermissions.removeAll { $0.serverID == id && $0.tool == name }; mcpPermissions.append(AgentMCPToolPermission(serverID: id, tool: name, permission: AgentToolPermission.allCases[rule.indexOfSelectedItem])); refreshMenus(); changed()
    }
    @objc private func create() { guard !dirty else { state.stringValue = "请先保存更改"; return }; let value = AgentProfile(name: "", description: "", instructions: ""); values.append(value); table.reloadData(); open(value.id); changed(); window?.makeFirstResponder(name) }
    @objc private func chooseTemplate() {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        let menu = NSMenu()
        for (index, value) in AgentTemplates.profiles.enumerated() { let item = NSMenuItem(title: value.name, action: #selector(useTemplate(_:)), keyEquivalent: ""); item.target = self; item.tag = index; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 14, y: 55), in: window?.contentView)
    }
    @objc private func useTemplate(_ sender: NSMenuItem) {
        guard !dirty, AgentTemplates.profiles.indices.contains(sender.tag) else { return }
        var value = AgentTemplates.profiles[sender.tag]
        let alert = NSAlert(); alert.messageText = value.name; alert.informativeText = value.instructions + "\n\n" + (value.readOnly ? "只读项目" : "可修改项目") + " · " + value.permission.title + (value.network ? " · 允许联网" : "")
        alert.addButton(withTitle: "使用模板"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let base = value.name; var suffix = 2
        while values.contains(where: { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) { value.name = base + " \(suffix)"; suffix += 1 }
        values.append(value); table.reloadData(); open(value.id); changed(); window?.makeFirstResponder(name)
    }
    @objc private func saveProfile() { do { capture(); try store.agents.save(store.agents.encode(values), expectedHash: openedHash); dirty = false; reload(); state.stringValue = "已保存" } catch { state.stringValue = error.localizedDescription } }
    @objc private func useProfile() { do { guard !dirty, let selectedID else { throw PetError("请先保存 Agent") }; let id = try store.agents.createTask(selectedID, store: store, workspace: workspace, workMode: workMode); onUse?(id); window?.orderOut(nil) } catch { state.stringValue = error.localizedDescription } }
    @objc private func importProfiles() {
        guard !dirty else { state.stringValue = "请先保存更改"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = try Data(contentsOf: url, options: .mappedIfSafe); guard data.count <= 512_000, let text = String(data: data, encoding: .utf8) else { throw PetError("请选择不超过512KB的 UTF-8 JSON") }; let imported = try store.agents.decode(text, importing: true); guard !imported.isEmpty else { throw PetError("没有可导入的 Agent") }; values += imported; table.reloadData(); open(imported.first?.id); changed(); state.stringValue = "导入待保存，默认停用" }
        catch { state.stringValue = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if dirty { let alert = NSAlert(); alert.messageText = "放弃未保存的 Agent 更改？"; alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃更改"); guard alert.runModal() == .alertSecondButtonReturn else { return false } }
        return true
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
