import AppKit
import Darwin

@MainActor extension AppDelegate {
    @discardableResult func prepareWorkspaceRolesUI(_ output: URL, seed: Bool) async throws -> [String: String] {
        ensureAgent(); guard let tasks = agentStore else { throw PetError("缺少独立角色验收目录") }
        let file = output.appendingPathComponent("workspace-roles-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            guard let id = ids["task"], tasks.task(id) != nil else { throw PetError("原角色验收任务不存在") }
            control.showAgentTask(id); return ids
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("原验收目录已存在，请直接重开") }
        var ids = try await prepareWorkspaceCapabilitiesUI(output, seed: true)
        let alpha = ids["alpha"]!, beta = ids["beta"]!, outside = ids["outside"]!, id = ids["task"]!
        let source = output.appendingPathComponent("public-role-plugin")
        try FileManager.default.copyItem(at: output.appendingPathComponent("public-capabilities-plugin"), to: source)
        let files = try AgentFiles(workspace: source.path), manifestFile = try files.resolve(".qoder-plugin/plugin.json")
        var manifest = try JSONSerialization.jsonObject(with: files.readData(manifestFile, maximum: 65_536)) as! [String: Any]
        manifest["name"] = "workspace-roles"; manifest["displayName"] = "公开多源角色"
        try files.writeData(JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]), to: manifestFile)
        let definitions = [
            "coordinator": "---\nname: coordinator\ndescription: Coordinate public source checks\ntools: [list_agents, delegate_task, read_file, run_command]\npermissionMode: bypassPermissions\nreadOnly: false\nnetwork: false\n---\n只分派明确的公开文件核对，按实际证据汇总。\n",
            "reader": "---\nname: reader\ndescription: Read actual public files without edits\ntools: [read_file, run_command]\nreadOnly: true\nnetwork: false\n---\n只读取任务已选目录的真实文件，不修改项目。\n",
            "connector": "---\nname: connector\ndescription: Read the selected source through its own connector\ntools: [read_file]\nskills: [plugin-source]\nmcpServers: [public]\nreadOnly: false\nnetwork: true\n---\n读取当前角色明确分配的公开资料，保持原审批。\n"
        ]
        for (name, text) in definitions { try files.writeData(Data(text.utf8), to: files.resolve("agents/" + name + ".md")) }
        let package = try await tasks.extensions.plugins.inspect(source)
        for (root, key) in [(alpha, "alpha"), (beta, "beta"), (outside, "outside")] {
            let installed = try tasks.extensions.plugins.install(package, workspace: root)
            try tasks.extensions.plugins.setEnabled(installed, true); ids[key + "RolePlugin"] = installed.id
            for role in try tasks.agents.packagedProfiles(workspace: root) where role.pluginSource?.name == installed.id {
                ids[key + "-" + role.pluginSource!.key] = role.id
            }
            let server = tasks.mcp.availableServers(workspace: root).first { $0.plugin?.name == installed.id }!
            let saved = try tasks.mcp.save(tasks.mcp.document(server), id: server.id, expectedRevision: server.revision, workspace: root)
            try tasks.mcp.setEnabled(saved.id, true, workspace: root); ids[key + "RoleServer"] = saved.id
        }
        let lead = AgentProfile(name: "多源负责人", description: "协调已选源目录的公开核对", instructions: "只委派当前团队的明确成员，核对真实文件证据。", permission: .automatic, tools: ["list_agents", "delegate_task", "read_file", "run_command"], readOnly: false, network: false, enabled: true)
        let mixed = AgentProfile(name: "多源核对角色", description: "读取明确选择的两份资源", instructions: "只使用明确分配的 Skill 和连接器，保持原目录与审批。", tools: ["read_file", "run_command"], readOnly: false, network: true, enabled: true, skills: [ids["alphaSkill"]!, ids["betaSkill"]!], mcpServers: [ids["alphaServer"]!, ids["betaServer"]!])
        let legacy = AgentProfile(name: "通用只读核对", description: "保持单目录及无工作区使用", instructions: "仅核对实际输出，不修改项目。", tools: ["read_file", "run_command"], enabled: true)
        try tasks.agents.save(tasks.agents.encode([lead, mixed, legacy]), expectedHash: tasks.agents.document().1)
        ids["lead"] = lead.id; ids["mixedRole"] = mixed.id; ids["legacyRole"] = legacy.id
        let team = AgentTeam(name: "双目录审阅团队", description: "核对两个来源的实际文件", instructions: "负责人分别分派给所选成员，保留文件依据。", leaderID: lead.id, memberIDs: [ids["alpha-reader"]!, ids["beta-reader"]!], enabled: true)
        try tasks.teams.save(tasks.teams.encode([team]), expectedHash: tasks.teams.document().1, store: tasks, workspace: beta, task: tasks.task(id))
        ids["mixedTeam"] = team.id
        let single = AgentTeam(name: "Beta 独立团队", description: "独立核对主目录", instructions: "仅核对 Beta 的公开文件。", leaderID: lead.id, memberIDs: [ids["beta-reader"]!], enabled: true)
        try tasks.teams.save(tasks.teams.encode(tasks.teams.list() + [single]), expectedHash: tasks.teams.document().1, store: tasks, workspace: beta)
        ids["singleTeam"] = single.id
        let old = AgentTeam(name: "旧格式通用团队", description: "原七字段格式", instructions: "仅核对明确来源。", leaderID: lead.id, memberIDs: [legacy.id], enabled: true)
        try tasks.teams.save(tasks.teams.encode(tasks.teams.list() + [old]), expectedHash: tasks.teams.document().1, store: tasks)
        ids["legacyTeam"] = old.id
        tasks.update(id) { $0.title = "多源角色与团队公开验收"; $0.draft = "保留多源角色原始要求 🧭" }
        try JSONEncoder().encode(ids).write(to: file); control.showAgentTask(id); control.show(tab: "chat"); return ids
    }

    func workspaceRolesReadback() -> [String: Any] {
        guard let output = checkDirectory, FileManager.default.fileExists(atPath: output.appendingPathComponent("workspace-roles-fixtures.json").path), let tasks = agentStore else { return [:] }
        return ["records": tasks.tasks.compactMap { tasks.task($0.id) }.map { task in
            ["id": task.id, "primary": task.workspace ?? "", "folders": task.workspacePaths, "draft": task.draft ?? "", "role": task.agent?.profile.id ?? "", "roleSource": task.agent?.profile.pluginSource?.name ?? "", "team": task.team?.team.id ?? "", "availableRoles": (try? tasks.agents.list(task: task).map(\.id)) ?? []] as [String: Any]
        }]
    }

    func runWorkspaceRolesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0, pids: [Int32] = []
        func refused(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        func call(_ name: String, _ value: [String: Any] = [:]) throws -> AgentToolCall { .init(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)) }
        func find<T: NSView>(_ type: T.Type, _ view: NSView?, _ matches: (T) -> Bool) -> T? {
            guard let view else { return nil }; if let value = view as? T, matches(value) { return value }
            for child in view.subviews { if let value = find(type, child, matches) { return value } }; return nil
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("多源角色原生验收禁止模型请求") }
            defer { runtime.stopAll(); tasks.mcp.disconnect() }
            let ids = try await prepareWorkspaceRolesUI(output, seed: true), id = ids["task"]!, alpha = ids["alpha"]!, beta = ids["beta"]!, outside = ids["outside"]!
            let original = tasks.task(id)!, scope = original.workspaceScope!, originalTaskFiles = try Dictionary(uniqueKeysWithValues: tasks.tasks.filter { $0.id != id }.map { ($0.id, try Data(contentsOf: tasks.directory.appendingPathComponent($0.id + ".json"))) })
            let all = try tasks.agents.list(task: original)
            checks["allFrozenSourcesExposeDistinctProjectRolesAndDeduplicateUserRoles"] = all.filter { $0.pluginSource?.name == ids["alphaRolePlugin"] }.count == 3 && all.filter { $0.pluginSource?.name == ids["betaRolePlugin"] }.count == 3 && all.filter { $0.id == ids["lead"] }.count == 1 && !all.contains { $0.pluginSource?.name == ids["outsideRolePlugin"] }
            let alphaRole = try tasks.agents.profile(ids["alpha-reader"]!, task: original), betaRole = try tasks.agents.profile(ids["beta-reader"]!, task: original)
            checks["sameNamedRolesHaveReadableDistinctSourceTitles"] = alphaRole.name == betaRole.name && AgentProfiles.title(alphaRole, task: original).contains("Alpha workspace") && AgentProfiles.title(betaRole, task: original).contains("Beta source")
            checks["secondaryCurrentProfileValidatesItsOwnExactPluginSource"] = try tasks.agents.currentProfile(alphaRole, task: original).pluginSource == alphaRole.pluginSource
            let mainTools = AgentTools(store: tasks, taskID: id), directory = try await mainTools.execute(call("list_agents"))
            let actualDirectory = try JSONSerialization.jsonObject(with: Data(directory.text.utf8)) as! [String: Any], actualRoles = actualDirectory["agents"] as? [[String: Any]] ?? []
            report["actualRoleDirectory"] = actualDirectory
            checks["actualRoleDirectoryIncludesBothSourcesWithoutOutsideRole"] = actualRoles.contains { $0["id"] as? String == alphaRole.id && $0["source"] as? String == alpha } && actualRoles.contains { $0["id"] as? String == betaRole.id && $0["source"] as? String == beta } && !actualRoles.contains { $0["id"] as? String == ids["outside-reader"] }
            let mixedTeam = try tasks.teams.team(ids["mixedTeam"]!, store: tasks, task: original)
            checks["crossSourceTeamUsesExistingProvenanceFieldsWithoutNewSchema"] = try mixedTeam.workspace == nil && mixedTeam.roleSources?.count == 2 && tasks.teams.sourceWorkspaces(mixedTeam) == Set([alpha, beta])
            let oldTeam = try tasks.teams.team(ids["legacyTeam"]!, store: tasks)
            let oldObject = try JSONSerialization.jsonObject(with: Data(tasks.teams.encode([oldTeam]).utf8)) as! [String: [[String: Any]]]
            checks["legacyTeamStillHasItsOriginalSevenFields"] = oldObject["teams"]![0].keys.count == 7 && oldTeam.workspace == nil && oldTeam.roleSources == nil
            let narrowID = tasks.create(title: "独立单目录角色核对", workspace: beta), narrow = tasks.task(narrowID)!
            let narrowBefore = try Data(contentsOf: tasks.directory.appendingPathComponent(narrowID + ".json")), count = tasks.tasks.count
            checks["singleRootCannotAssignSecondaryRoleAndKeepsOriginalRecord"] = refused { try tasks.agents.configureDraft(alphaRole.id, taskID: narrowID, store: tasks) } && refused { _ = try tasks.agents.currentProfile(alphaRole, task: narrow) }
            checks["singleRootCannotUseCrossSourceTeamOrCreateItsChild"] = refused { _ = try tasks.teams.team(mixedTeam.id, store: tasks, task: narrow) } && refused { _ = try tasks.agents.createTask(alphaRole.id, store: tasks, workspace: beta, owner: narrow) }
            checks["rejectedAssignmentsCreateNoOrphansOrTaskChanges"] = try count == tasks.tasks.count && Data(contentsOf: tasks.directory.appendingPathComponent(narrowID + ".json")) == narrowBefore
            let teamBefore = try tasks.teams.document(), rolesBefore = try tasks.agents.document()
            var invalid = mixedTeam; invalid.id = UUID().uuidString; invalid.name = "未选目录成员"; invalid.workspace = nil; invalid.roleSources = nil; invalid.memberIDs = [ids["outside-reader"]!]
            checks["outsideMemberCannotEnterTeamEvenWhenItsPluginIsEnabled"] = refused { try tasks.teams.save(tasks.teams.encode(tasks.teams.list() + [invalid]), expectedHash: teamBefore.1, store: tasks, workspace: beta, task: original) }
            checks["failedTeamSavePreservesEveryRoleAndTeamByte"] = try tasks.teams.document() == teamBefore && tasks.agents.document() == rolesBefore
            checks["settingsContextRejectsUnselectedOrDeletedTask"] = refused { _ = try AgentWorkspaceScope.settingsSourceTask(id, workspace: outside, store: tasks) } && refused { _ = try AgentWorkspaceScope.settingsSourceTask(UUID().uuidString, workspace: beta, store: tasks) }
            let roleTask = try tasks.agents.createTask(ids["mixedRole"]!, store: tasks, workspace: beta, context: original)
            guard let assigned = tasks.task(roleTask), let a = assigned.activeSkills?.first(where: { $0.id == ids["alphaSkill"] }), let b = assigned.activeSkills?.first(where: { $0.id == ids["betaSkill"] }) else { throw PetError("多源 Skill 未载入角色任务") }
            checks["settingsCreatedRoleKeepsPrimaryFrozenRootsAndIndependentOwnership"] = assigned.workspace == beta && assigned.workspaceScope == scope && assigned.agent?.ownerID == nil && assigned.agent?.workspace == beta
            checks["roleActivationCopiesBothSelectedSkillResources"] = try tasks.extensions.readResource(a.id, path: "references/source.txt", offset: 1, store: tasks, taskID: roleTask).contains("ALPHA_LOCAL_SKILL_RESOURCE") && tasks.extensions.readResource(b.id, path: "references/source.txt", offset: 1, store: tasks, taskID: roleTask).contains("BETA_LOCAL_SKILL_RESOURCE")
            let roleTools = AgentTools(store: tasks, taskID: roleTask)
            for (key, marker) in [("alphaServer", "ALPHA_PUBLIC_7319"), ("betaServer", "BETA_PUBLIC_4086")] {
                let server = try tasks.mcp.server(ids[key]!, task: assigned), connect = try call("connect_mcp", ["server_id": server.id, "configuration": server.revision])
                checks["assignedSourceConnectorKeepsItsOriginalConnectApproval-" + key] = try roleTools.approvalReason(for: connect) != nil
                _ = try await roleTools.execute(connect)
                guard let token = tasks.mcp.token(server.id, owner: roleTask), let pid = await tasks.mcp.processID(server.id, owner: roleTask) else { throw PetError("角色连接器没有实际进程") }; pids.append(pid)
                _ = try tasks.mcp.catalog(server.id, owner: roleTask, token: token, offset: 0, query: "inspect_source")
                let actual = try await roleTools.execute(call("call_mcp_tool", ["server_id": server.id, "connection": token, "tool": "inspect_source", "arguments": [:]]))
                checks["assignedConnectorActuallyReadsItsOwnSource-" + key] = !actual.failed && actual.text.contains(marker); report[key + "ActualResult"] = actual.text
            }
            tasks.mcp.disconnect(owner: roleTask)
            let beforeDeniedChild = tasks.tasks.count
            checks["allTaskRootsDoNotBroadenParentsConnectorCeilingOrCreateOrphans"] = refused { _ = try tasks.agents.createTask(ids["alpha-connector"]!, store: tasks, workspace: beta, owner: tasks.task(roleTask), context: original) } && tasks.tasks.count == beforeDeniedChild
            let ownerID = tasks.create(title: "所属权限边界", workspace: beta, workspaceScope: scope)
            tasks.update(ownerID) { $0.mode = .ask; $0.permission = .review }
            let child = try tasks.agents.createTask(alphaRole.id, store: tasks, workspace: beta, owner: tasks.task(ownerID))
            checks["delegatedSecondaryRoleInheritsOriginalSourcesModeAndApproval"] = tasks.task(child)?.workspaceScope == scope && tasks.task(child)?.workspace == beta && tasks.task(child)?.mode == .ask && tasks.task(child)?.permission == .review && tasks.task(child)?.agent?.ownerID == ownerID
            let childTools = AgentTools(store: tasks, taskID: child)
            let read = try await childTools.execute(call("read_file", ["path": alpha + "/README.md"]))
            checks["secondaryChildActuallyReadsSelectedOtherRootFile"] = !read.failed && read.text.contains("ALPHA_PUBLIC_7319")
            let forbidden = alpha + "/role-must-not-write.txt", write = try await childTools.execute(call("run_command", ["command": "printf denied > " + AgentGit.quote(forbidden), "timeout_seconds": 10]))
            checks["delegatedSkillOrRoleDoesNotBroadenReadOnlyKernelScope"] = write.failed && !FileManager.default.fileExists(atPath: forbidden)
            let teamTask = try tasks.teams.createTask(mixedTeam.id, store: tasks, workspace: beta, context: original)
            let teamContext = try runtime.systemContext(tasks.task(teamTask)!)
            checks["teamSystemContextDistinguishesSameNamedSourceMembers"] = teamContext.contains(AgentProfiles.title(alphaRole, task: original)) && teamContext.contains(AgentProfiles.title(betaRole, task: original)) && teamContext.contains(alphaRole.id) && teamContext.contains(betaRole.id)
            let members = try await AgentTools(store: tasks, taskID: teamTask).execute(call("list_agents")), memberObject = try JSONSerialization.jsonObject(with: Data(members.text.utf8)) as! [String: Any]
            let memberIDs = Set((memberObject["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            checks["crossSourceTeamListsOnlyItsTwoExactMembers"] = memberIDs == Set(mixedTeam.memberIDs) && (memberObject["teams"] as? [Any])?.isEmpty == true
            let member = try tasks.agents.createTask(alphaRole.id, store: tasks, workspace: beta, owner: tasks.task(teamTask))
            checks["memberSystemContextNamesItsExactSource"] = try runtime.systemContext(tasks.task(member)!).contains("[自定义 Agent：" + AgentProfiles.title(alphaRole, task: original) + "]")
            checks["crossSourceTeamCreatesItsRealSecondaryMemberWithSameRoots"] = tasks.task(member)?.agent?.profile.pluginSource == alphaRole.pluginSource && tasks.task(member)?.workspaceScope == scope && tasks.task(member)?.workspace == beta
            checks["teamCannotDelegateOutsideRosterOrIntoAnotherTeam"] = refused { _ = try tasks.agents.createTask(ids["legacyRole"]!, store: tasks, workspace: beta, owner: tasks.task(teamTask)) } && refused { _ = try tasks.teams.createTask(ids["legacyTeam"]!, store: tasks, workspace: beta, owner: tasks.task(teamTask)) }
            let fork = tasks.fork(member)!
            let forkLimits = try tasks.agents.limits(tasks.task(fork)!, store: tasks)
            checks["forkRetainsTeamSourcesAndReadOnlyCeilingsWithoutOwnerLink"] = tasks.task(fork)?.workspaceScope == scope && tasks.task(fork)?.agent?.ownerID == nil && tasks.task(fork)?.agent?.teamCeiling?.roleSources == mixedTeam.roleSources && forkLimits.readOnly
            let legacyTask = try tasks.agents.createTask(ids["legacyRole"]!, store: tasks, workspace: nil)
            let query = try await AgentTools(store: tasks, taskID: legacyTask).execute(call("run_command", ["command": "printf global-role-no-workspace", "timeout_seconds": 10]))
            checks["noWorkspaceRoleRetainsActualReadOnlyTerminalWork"] = !query.failed && query.text.contains("global-role-no-workspace") && tasks.task(legacyTask)?.workspaceScope == nil
            let reused = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["persistedRoleAndCrossSourceTeamReopenWithExactProvenance"] = try reused.task(teamTask)?.workspaceScope == scope && reused.teams.team(mixedTeam.id, store: reused, task: reused.task(teamTask)!).roleSources == mixedTeam.roleSources && reused.agents.currentProfile(alphaRole, task: reused.task(member)!).pluginSource == alphaRole.pluginSource
            for (key, value) in control.checkExecutorSelection(taskID: id, agentID: alphaRole.id, teamID: mixedTeam.id) { checks[key] = value }
            guard let host = control.window, control.showSettingsCategory("agents"), let picker = find(NSPopUpButton.self, host.contentView, { $0.identifier?.rawValue == "settings-source-folder" }), let chosen = picker.itemArray.first(where: { $0.representedObject as? String == alpha }), let choose = picker.action else { throw PetError("缺少实际多源设置入口") }
            func verifyNarrowLayout(_ name: String, _ controls: [NSView]) async {
                let frame = host.frame
                host.setFrame(NSRect(origin: frame.origin, size: NSSize(width: 780, height: 540)), display: true)
                await wait(0.1); host.contentView?.layoutSubtreeIfNeeded()
                let bounds = host.contentView?.bounds ?? .zero
                let rectangles = controls.map { $0.convert($0.bounds, to: host.contentView) }
                checks[name] = abs(host.frame.width - 780) < 0.5 && rectangles.allSatisfy { $0.width >= 60 && $0.minX >= 0 && $0.maxX <= bounds.maxX + 1 }
                report[name + "Geometry"] = ["windowWidth": host.frame.width, "contentWidth": bounds.width, "controls": rectangles.map(NSStringFromRect)]
                host.setFrame(frame, display: true); await wait(0.05)
            }
            picker.select(chosen); NSApp.sendAction(choose, to: picker.target, from: picker)
            guard let manager = control.settingsControllerForCheck as? AgentProfileWindow else { throw PetError("角色设置页未打开") }
            manager.selectProfile(ids["mixedRole"]!)
            guard let skillMenu = find(NSPopUpButton.self, manager.pageContentView, { $0.accessibilityLabel() == "Agent Skills" }), let mcpMenu = find(NSPopUpButton.self, manager.pageContentView, { $0.accessibilityLabel() == "Agent MCP" }) else { throw PetError("缺少角色能力选择") }
            let skillRows = skillMenu.itemArray, mcpRows = mcpMenu.itemArray
            await verifyNarrowLayout("actualRoleEditorFits780PointWindowWithBothSourceChoices", [skillMenu, mcpMenu])
            checks["actualRoleEditorShowsBothSourceSkillsWithReadableLabels"] = skillRows.contains { $0.representedObject as? String == ids["alphaSkill"] && $0.title.contains("Alpha workspace") } && skillRows.contains { $0.representedObject as? String == ids["betaSkill"] && $0.title.contains("Beta source") }
            checks["actualRoleEditorShowsBothSourceConnectorsWithoutOutsideConnector"] = mcpRows.contains { $0.representedObject as? String == ids["alphaServer"] && $0.title.contains("Alpha workspace") } && mcpRows.contains { $0.representedObject as? String == ids["betaServer"] && $0.title.contains("Beta source") } && !mcpRows.contains { $0.representedObject as? String == ids["outsideRoleServer"] }
            guard let addRule = mcpMenu.itemArray.first(where: { $0.title == "添加工具规则…" }), let action = addRule.action else { throw PetError("缺少实际 MCP 规则入口") }
            NSApp.sendAction(action, to: addRule.target, from: addRule)
            guard let ruleServer = find(NSPopUpButton.self, host.contentView, { $0.accessibilityLabel() == "MCP 连接器" && !$0.isHiddenOrHasHiddenAncestor }), let toolName = find(NSTextField.self, host.contentView, { $0.accessibilityLabel() == "MCP 工具名" }), let rulePermission = find(NSPopUpButton.self, host.contentView, { $0.accessibilityLabel() == "MCP 工具权限" }), let apply = find(NSButton.self, host.contentView, { $0.title == "应用" && !$0.isHiddenOrHasHiddenAncestor }), let betaIndex = ruleServer.itemArray.firstIndex(where: { $0.title.contains("Beta source") }) else { throw PetError("缺少区分来源的 MCP 规则表单") }
            checks["actualRuleFormDisambiguatesSameNamedSourceConnectors"] = ruleServer.numberOfItems == 2 && Set(ruleServer.itemArray.map(\.title)).count == 2 && ruleServer.itemArray.contains { $0.title.contains("Alpha workspace") }
            await verifyNarrowLayout("actualSourceRuleFormFits780PointWindow", [ruleServer, toolName])
            ruleServer.selectItem(at: betaIndex); toolName.stringValue = "inspect_source"; rulePermission.selectItem(at: AgentToolPermission.allCases.firstIndex(of: .deny)!); apply.performClick(nil)
            guard let save = find(NSButton.self, manager.pageContentView, { $0.title == "保存" && $0.isEnabled }) else { throw PetError("角色规则未进入原草稿") }; save.performClick(nil)
            let savedRole = try tasks.agents.profile(ids["mixedRole"]!, task: original), savedRules = savedRole.mcpToolPermissions ?? []
            checks["actualRuleSavePersistsOnlyTheChosenSourceServerID"] = savedRules.count == 1 && savedRules[0].serverID == ids["betaServer"] && savedRules[0].tool == "inspect_source" && savedRules[0].permission == .deny
            let deniedBeta = try call("call_mcp_tool", ["server_id": ids["betaServer"]!, "tool": "inspect_source", "connection": "not-used", "arguments": [:]]), allowedAlpha = try call("call_mcp_tool", ["server_id": ids["alphaServer"]!, "tool": "inspect_source", "connection": "not-used", "arguments": [:]])
            checks["savedSourceRuleTightensExistingRoleWithoutAffectingOtherSource"] = try tasks.agents.permission(deniedBeta, task: tasks.task(roleTask)!, store: tasks) == .deny && tasks.agents.permission(allowedAlpha, task: tasks.task(roleTask)!, store: tasks) != .deny && refused { try tasks.agents.check(deniedBeta, task: tasks.task(roleTask)!, store: tasks) }
            guard control.showSettingsCategory("teams"), let teamPage = control.settingsControllerForCheck as? AgentTeamWindow, let leaders = find(NSPopUpButton.self, teamPage.pageContentView, { $0.accessibilityLabel() == "团队负责人" }), let membersMenu = find(NSPopUpButton.self, teamPage.pageContentView, { $0.accessibilityLabel() == "团队成员" }), let body = find(NSTextView.self, teamPage.pageContentView, { $0.accessibilityLabel() == "团队协作指令" }) else { throw PetError("多源团队设置未打开") }
            checks["actualTeamEditorOffersRolesFromEveryFrozenSource"] = leaders.itemArray.contains { $0.representedObject as? String == alphaRole.id && $0.title.contains("Alpha workspace") } && membersMenu.itemArray.contains { $0.representedObject as? String == betaRole.id && $0.title.contains("Beta source") } && !leaders.itemArray.contains { $0.representedObject as? String == ids["outside-reader"] }
            await verifyNarrowLayout("actualTeamEditorFits780PointWindowWithFullSourceMenuTitles", [leaders, membersMenu])
            body.string += "\nPUBLIC_TEAM_REVIEWED\n"; teamPage.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
            guard let teamSave = find(NSButton.self, teamPage.pageContentView, { $0.title == "保存" && $0.isEnabled }) else { throw PetError("团队保存不可用") }; teamSave.performClick(nil)
            let savedTeam = try tasks.teams.team(mixedTeam.id, store: tasks, task: original)
            checks["actualCrossSourceTeamSaveKeepsBothProvenanceRecordsAndOriginalTask"] = savedTeam.instructions.contains("PUBLIC_TEAM_REVIEWED") && savedTeam.roleSources == mixedTeam.roleSources && tasks.task(id)?.workspaceScope == scope && tasks.task(id)?.workspace == beta && tasks.task(id)?.draft == original.draft
            guard control.showSettingsCategory("agents"), let savedManager = control.settingsControllerForCheck as? AgentProfileWindow else { throw PetError("角色页未重开") }
            savedManager.selectProfile(ids["mixedRole"]!); var createdID: String?
            savedManager.onUse = { createdID = $0 }
            guard let newTask = find(NSButton.self, savedManager.pageContentView, { $0.title == "新建任务" && $0.isEnabled }) else { throw PetError("角色新建任务入口不可用") }; newTask.performClick(nil)
            checks["actualSettingsNewRoleTaskUsesFrozenGroupAndPrimaryInsteadOfManagementRoot"] = createdID.flatMap(tasks.task)?.workspaceScope == scope && createdID.flatMap(tasks.task)?.workspace == beta && createdID.flatMap(tasks.task)?.agent?.ownerID == nil && tasks.task(id)?.draft == original.draft
            control.showAgentTask(id); control.show(tab: "chat")
            checks["unrelatedOriginalTasksKeepEveryByte"] = try originalTaskFiles.allSatisfy { try Data(contentsOf: tasks.directory.appendingPathComponent($0.key + ".json")) == $0.value }

            var connectorTasks: [(String, String, String, String)] = []
            for (key, context, marker) in [("alpha", Optional(original), "ALPHA_PUBLIC_7319"), ("beta", Optional<AgentTaskRecord>.none, "BETA_PUBLIC_4086")] {
                let taskID = try tasks.agents.createTask(ids[key + "-connector"]!, store: tasks, workspace: beta, context: context), task = tasks.task(taskID)!, tools = AgentTools(store: tasks, taskID: taskID)
                let server = try tasks.mcp.server(ids[key + "RoleServer"]!, task: task)
                checks["pluginRoleKeepsSelectedSkillAndExactSource-" + key] = task.agent?.profile.pluginSource?.name == ids[key + "RolePlugin"] && task.activeSkills?.count == 1 && task.activeSkills?.first?.source.contains(key == "alpha" ? alpha : beta) == true
                _ = try await tools.execute(call("connect_mcp", ["server_id": server.id, "configuration": server.revision]))
                guard let token = tasks.mcp.token(server.id, owner: taskID), let pid = await tasks.mcp.processID(server.id, owner: taskID) else { throw PetError("插件角色的真实连接未启动") }; pids.append(pid)
                _ = try tasks.mcp.catalog(server.id, owner: taskID, token: token, offset: 0, query: "inspect_source")
                let result = try await tools.execute(call("call_mcp_tool", ["server_id": server.id, "connection": token, "tool": "inspect_source", "arguments": [:]]))
                checks["pluginRoleActuallyReadsItsOwnConnectorSource-" + key] = !result.failed && result.text.contains(marker)
                connectorTasks.append((key, taskID, server.id, token))
                if key == "alpha" {
                    let other = try tasks.mcp.server(ids["betaRoleServer"]!, task: task)
                    checks["broaderTaskDoesNotGrantOtherPluginRolesConnector"] = refused { _ = try tools.approvalReason(for: call("connect_mcp", ["server_id": other.id, "configuration": other.revision])) }
                }
            }
            let slow = URL(fileURLWithPath: beta).appendingPathComponent("public-role-process.cjs")
            try Data("const fs=require('node:fs'),cp=require('node:child_process');const child=cp.spawn('/bin/sleep',['90'],{stdio:'ignore'});fs.writeFileSync(process.argv[2],JSON.stringify({pid:process.pid,child:child.pid}));setTimeout(()=>console.log('actual public process finished'),90000);\n".utf8).write(to: slow)
            var jobs: [(String, String, URL)] = []
            for (key, teamID, context) in [("mixed", mixedTeam.id, Optional(original)), ("beta", ids["singleTeam"]!, Optional<AgentTaskRecord>.none)] {
                let taskID = try tasks.teams.createTask(teamID, store: tasks, workspace: beta, context: context), file = URL(fileURLWithPath: beta).appendingPathComponent("public-role-pids-" + taskID + ".json")
                guard runtime.submit("原生多源团队实际进程验收，不调用模型。", taskID: taskID, startImmediately: false) else { throw PetError(runtime.submissionError ?? "公开进程未准备") }
                let operation = try call("run_command", ["command": AgentGit.quote(ids["node"]!) + " " + AgentGit.quote(slow.path) + " " + AgentGit.quote(file.path), "timeout_seconds": 90])
                tasks.update(taskID) { $0.permission = .automatic; $0.pendingCalls = [operation] }; runtime.start(taskID); jobs.append((key, taskID, file))
            }
            for _ in 0..<250 { if jobs.allSatisfy({ FileManager.default.fileExists(atPath: $0.2.path) }) { break }; await wait(0.04) }
            var processGroups: [String: [Int32]] = [:]
            for (key, _, file) in jobs {
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Int]
                let actual = [Int32(value["pid"]!), Int32(value["child"]!)]; guard actual.allSatisfy({ kill($0, 0) == 0 }) else { throw PetError("实际父子进程已提前结束") }; pids += actual; processGroups[key] = actual
            }
            checks["bothCrossSourceAndLegacyTeamsRunActualParentAndChildProcesses"] = processGroups.count == 2 && jobs.allSatisfy { runtime.isRunning($0.1) }
            try tasks.extensions.plugins.setEnabled(tasks.extensions.plugins.installation(ids["alphaRolePlugin"]!), false)
            let alphaConnection = connectorTasks.first { $0.0 == "alpha" }!, betaConnection = connectorTasks.first { $0.0 == "beta" }!, mixedJob = jobs.first { $0.0 == "mixed" }!, betaJob = jobs.first { $0.0 == "beta" }!
            for _ in 0..<250 {
                let connectionPID = await tasks.mcp.processID(alphaConnection.2, owner: alphaConnection.1)
                if !runtime.isRunning(mixedJob.1) && processGroups["mixed"]!.allSatisfy({ kill($0, 0) != 0 }) && connectionPID == nil { break }
                await wait(0.04)
            }
            let revokedPID = await tasks.mcp.processID(alphaConnection.2, owner: alphaConnection.1)
            checks["secondaryRoleRevocationStopsItsTeamProcessGroupAndConnector"] = !runtime.isRunning(mixedJob.1) && processGroups["mixed"]!.allSatisfy { kill($0, 0) != 0 } && revokedPID == nil
            checks["otherSourceLegacyTeamAndConnectorKeepTheirActualProcesses"] = runtime.isRunning(betaJob.1) && processGroups["beta"]!.allSatisfy { kill($0, 0) == 0 } && tasks.mcp.token(betaConnection.2, owner: betaConnection.1) == betaConnection.3
            checks["revokedSecondaryRoleCannotResumeFromOldSnapshot"] = refused { _ = try tasks.agents.currentProfile(alphaRole, task: original) } && refused { try tasks.teams.check(tasks.task(teamTask)!, store: tasks) }
            runtime.cancel(betaJob.1); tasks.mcp.disconnect()
            for _ in 0..<250 { if pids.allSatisfy({ kill($0, 0) != 0 }) { break }; await wait(0.04) }
            checks["allEightActualServiceAndCommandProcessesExit"] = pids.count == 8 && pids.allSatisfy { kill($0, 0) != 0 }
            checks["noModelRequestsOrRecordedUsage"] = attempts == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.inputTokens == 0 && $0.outputTokens == 0 && ($0.modelReceipts ?? []).isEmpty }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["appPID"] = getpid(); report["actualServicePIDs"] = pids; report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workspace-roles-report.json"), options: .atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}
