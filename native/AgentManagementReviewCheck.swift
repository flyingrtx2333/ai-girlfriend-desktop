import AppKit

@MainActor enum AgentManagementReviewCheck {
    private static func find<T: NSView>(_ type: T.Type, in view: NSView?, matching: (T) -> Bool) -> T? {
        guard let view else { return nil }; if let value = view as? T, matching(value) { return value }
        for child in view.subviews { if let value = find(type, in: child, matching: matching) { return value } }; return nil
    }
    private static func control<T: NSView>(_ type: T.Type, _ label: String, page: AgentSettingsPageController) throws -> T {
        guard let value = find(type, in: page.pageContentView, matching: { $0.accessibilityLabel() == label }) else { throw PetError("缺少设置审阅控件：" + label) }; return value
    }
    private static func press(_ title: String, page: AgentSettingsPageController) throws {
        guard let value = find(NSButton.self, in: page.pageContentView, matching: { $0.title == title && $0.isEnabled }) else { throw PetError("缺少设置审阅操作：" + title) }; value.performClick(nil)
    }
    private static func edit(_ label: String, _ text: String, page: AgentSettingsPageController) throws {
        let value = try control(NSTextField.self, label, page: page); value.stringValue = text; value.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: value))
    }
    private static func bytes(_ url: URL) throws -> Data? { FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
    private static func object(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
    static func prepareFixtures(_ output: URL, tasks: AgentStore, workspace: String) throws {
        let scripts = URL(fileURLWithPath: workspace).appendingPathComponent(".bluefatfish/hooks")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("review.sh"), marker = URL(fileURLWithPath: workspace).appendingPathComponent("页内Hook结果.txt")
        try Data("#!/bin/sh\nprintf 'executed\\n' >> \"$1\"\n".utf8).write(to: script)
        let document = try tasks.hooks.document(project: false, workspace: workspace)
        var value = try JSONSerialization.jsonObject(with: Data(document.0.utf8)) as! [String: Any], groups = value["hooks"] as? [String: Any] ?? [:]
        let definitions: [[String: Any]] = [
            ["name": "页内命令审阅", "type": "command", "command": "/bin/sh", "args": [script.path, marker.path], "timeout": 5, "network": false],
            ["name": "页内HTTP审阅", "type": "http", "url": "https://example.com/hooks", "headers": [:], "allowedEnvVars": [], "timeout": 5],
            ["name": "页内模型审阅", "type": "prompt", "prompt": "只核对公开输入，不修改文件。", "timeout": 5],
            ["name": "页内Agent审阅", "type": "agent", "prompt": "只读取公开 README。", "tools": ["read_file"], "network": false, "maxTurns": 2, "timeout": 5],
            ["name": "页内后台审阅", "type": "command", "command": "/usr/bin/true", "args": [], "async": true, "asyncRewake": true, "rewakeMessage": "公开唤醒提示", "rewakeSummary": "公开唤醒摘要", "statusMessage": "页内后台状态", "timeout": 5]
        ]
        var handlers = groups["PreToolUse"] as? [[String: Any]] ?? []; handlers.append(["matcher": "PageReviewOnly", "hooks": definitions]); groups["PreToolUse"] = handlers; value["hooks"] = groups
        try tasks.hooks.save(object(value), project: false, workspace: workspace, expectedHash: document.1)
        let catalog = try tasks.hooks.catalog(workspace: workspace).filter { $0.name.hasPrefix("页内") }
        guard catalog.count == 5, catalog.allSatisfy({ $0.diagnostic == nil }) else { throw PetError("设置审阅检查配置无效：" + catalog.compactMap(\.diagnostic).joined(separator: ", ")) }
        let metadata: [String: Any] = ["hookIDs": Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0.id) }), "workspace": workspace, "script": script.path, "marker": marker.path, "modelRequests": 0]
        try Data(object(metadata).utf8).write(to: output.appendingPathComponent("management-review-fixtures.json"))
    }
    static func run(tasks: AgentStore, taskID: String, pane: AgentSettingsPageHost, host: NSWindow, output: URL) async throws -> [String: Bool] {
        guard let workspace = tasks.task(taskID)?.workspace else { throw PetError("缺少设置审阅项目") }
        try prepareFixtures(output, tasks: tasks, workspace: workspace)
        let service = tasks.hooks, source = try service.file(project: false, workspace: workspace), authorization = tasks.extensions.profile.appendingPathComponent("extensions/hook-settings.json")
        let initialSource = try bytes(source), initialAuthorization = try bytes(authorization), visible = NSApp.windows.filter(\.isVisible).count
        let manager = AgentHookWindow(service: service, workspace: workspace)
        guard pane.show(category: "hooks", identity: "inline-hook-review", scope: "设置项目", make: { _ in manager }) else { throw PetError("无法进入 Hook 审阅") }
        var checks: [String: Bool] = [:], measurements: [String: Any] = [:]
        let names = ["页内命令审阅", "页内HTTP审阅", "页内模型审阅", "页内Agent审阅", "页内后台审阅"]
        let expected = ["此命令将自动运行", "发送当前事件数据", "产生模型用量", "只读项目", "退出码为 2"]
        func hook(_ name: String) throws -> AgentHookDefinition { guard let value = try service.catalog(workspace: workspace).first(where: { $0.name == name }) else { throw PetError("缺少 Hook：" + name) }; return value }
        func layout(_ page: AgentSettingsReviewPage, key: String, multiple: Bool) throws {
            for (label, size) in [("normal", NSSize(width: 800, height: 540)), ("narrow", NSSize(width: 420, height: 360))] {
                host.setContentSize(size); pane.layoutSubtreeIfNeeded(); let detail = try control(NSTextView.self, "设置审阅正文", page: page)
                var valid = !detail.hasAmbiguousLayout && detail.bounds.width >= 140 && detail.bounds.height >= 100
                if multiple { valid = try valid && !control(NSTableView.self, "设置审阅列表", page: page).hasAmbiguousLayout }
                checks[key + "Layout-" + label] = valid; measurements[key + "-" + label] = ["previewSize": [detail.bounds.width, detail.bounds.height], "ambiguous": detail.hasAmbiguousLayout]
            }
            host.setContentSize(NSSize(width: 800, height: 540))
        }
        for (index, name) in names.enumerated() {
            let item = try hook(name); manager.selectHook(item.id); try press("启用", page: manager)
            guard let page = pane.currentController as? AgentSettingsReviewPage else { throw PetError("Hook 启用未进入设置子页") }
            let detail = try control(NSTextView.self, "设置审阅正文", page: page), notice = try control(NSTextField.self, "审阅操作影响", page: page)
            checks["hookReviewHostedWithoutSheet-\(index)"] = page.presentingWindow === host && page.window?.isVisible == false && host.attachedSheet == nil
            checks["hookReviewCompleteContentAndConsequence-\(index)"] = detail.string.contains(item.display) && detail.string.contains(item.source) && detail.string.contains("PageReviewOnly") && notice.stringValue.contains(expected[index])
            checks["hookReviewShowsRoundsOnlyForAgent-\(index)"] = item.type == "agent" ? detail.string.contains("最多 2 轮") : !detail.string.contains("最多 ")
            if index == 4 { checks["hookReviewPreservesAllBackgroundMessages"] = detail.string.contains("公开唤醒提示") && detail.string.contains("公开唤醒摘要") && detail.string.contains("页内后台状态") && notice.stringValue.contains("结果不改变审批或工具参数") }
            checks["hookReviewDoesNotEnableBeforeApply-\(index)"] = try !service.enabled(item) && bytes(authorization) == initialAuthorization
            if index == 0 || index == 1 { try layout(page, key: "hook\(index)", multiple: false) }
            try press("取消", page: page)
            checks["hookReviewCancelKeepsFilesAndFocus-\(index)"] = try pane.currentController === manager && bytes(source) == initialSource && bytes(authorization) == initialAuthorization && (host.firstResponder as? NSButton)?.accessibilityIdentifier() == "hook-handler-" + item.id
        }
        var command = try hook(names[0]); manager.selectHook(command.id); try press("启用", page: manager)
        guard let enabling = pane.currentController as? AgentSettingsReviewPage else { throw PetError("缺少 Hook 确认页") }; try press("启用", page: enabling)
        let reloaded = AgentHooks(profile: tasks.extensions.profile, sharedHome: output.appendingPathComponent("shared-home"), plugins: tasks.extensions.plugins)
        guard let stored = try reloaded.catalog(workspace: workspace).first(where: { $0.id == command.id }) else { throw PetError("启用记录未重读") }
        checks["hookReviewAppliesOriginalApprovalAndReloads"] = pane.currentController === manager && service.trusted(command) && reloaded.trusted(stored)
        checks["hookReviewApplyRestoresHandlerFocus"] = (host.firstResponder as? NSButton)?.accessibilityIdentifier() == "hook-handler-" + command.id
        let marker = URL(fileURLWithPath: workspace).appendingPathComponent("页内Hook结果.txt")
        _ = try await service.fire(.preTool, trigger: UUID().uuidString, store: tasks, taskID: taskID, value: "PageReviewOnly")
        let ran = try bytes(marker); checks["hookReviewApprovalExecutesActualPublicCommand"] = ran == Data("executed\n".utf8)
        try press("启用", page: manager)
        _ = try await service.fire(.preTool, trigger: UUID().uuidString, store: tasks, taskID: taskID, value: "PageReviewOnly")
        checks["hookReviewDisableNeedsNoReviewAndStopsExecution"] = try pane.currentController === manager && !service.enabled(command) && bytes(marker) == ran
        checks["hookReviewDisableRestoresHandlerFocus"] = (host.firstResponder as? NSButton)?.accessibilityIdentifier() == "hook-handler-" + command.id
        command = try hook(names[0]); manager.selectHook(command.id); try press("启用", page: manager)
        guard let stale = pane.currentController as? AgentSettingsReviewPage else { throw PetError("缺少过期 Hook 审阅") }
        let document = try service.document(project: false, workspace: workspace)
        var changed = try JSONSerialization.jsonObject(with: Data(document.0.utf8)) as! [String: Any], groups = changed["hooks"] as! [String: Any], entries = groups["PreToolUse"] as! [[String: Any]]
        var definitions = entries.last!["hooks"] as! [[String: Any]]; definitions[0]["timeout"] = 6; entries[entries.count - 1]["hooks"] = definitions; groups["PreToolUse"] = entries; changed["hooks"] = groups
        try service.save(object(changed), project: false, workspace: workspace, expectedHash: document.1)
        let approvedBefore = try bytes(authorization); try press("启用", page: stale)
        checks["hookStaleReviewRefusesApprovalAndKeepsPage"] = try pane.currentController === stale && control(NSTextField.self, "审阅操作错误", page: stale).stringValue.contains("Hook 已变化") && bytes(authorization) == approvedBefore
        try press("取消", page: stale); checks["hookReviewReturnRefreshesChangedDefinition"] = try pane.currentController === manager && !service.trusted(hook(names[0]))
        let teams = AgentTeamWindow(store: tasks, workspace: workspace)
        guard pane.show(category: "teams", identity: "inline-team-template", scope: "设置项目", make: { _ in teams }) else { throw PetError("无法进入团队模板") }
        let originalAgents = try tasks.agents.document(), originalTeams = try tasks.teams.document(), previousName = try control(NSTextField.self, "团队名称", page: teams).stringValue
        try press("审阅模板", page: teams)
        guard let template = pane.currentController as? AgentSettingsReviewPage else { throw PetError("团队模板未进入审阅子页") }
        let roles = try control(NSTableView.self, "设置审阅列表", page: template), content = try control(NSTextView.self, "设置审阅正文", page: template)
        checks["teamTemplateReviewHostedWithoutSheet"] = template.presentingWindow === host && template.window?.isVisible == false && host.attachedSheet == nil && roles.numberOfRows == 4 && host.firstResponder === roles
        let expectedBody = ["等待两名成员的实际结果", AgentTemplates.profiles[3].instructions, AgentTemplates.profiles[0].instructions, "不得修改文件或运行会改动项目的测试"]
        for index in 0..<4 { roles.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); checks["teamTemplateCompleteInstructions-\(index)"] = content.string.contains(expectedBody[index]) && (index == 0 || content.string.contains("只读项目") && content.string.contains("不联网") && content.string.contains("跟随任务")) }
        checks["teamTemplateReviewExplainsMemberCreation"] = try control(NSTextField.self, "审阅操作影响", page: template).stringValue.contains("保存时创建三个 Agent")
        try layout(template, key: "teamTemplate", multiple: true); try press("取消", page: template)
        checks["teamTemplateCancelWritesNothing"] = try pane.currentController === teams && tasks.agents.document().1 == originalAgents.1 && tasks.teams.document().1 == originalTeams.1 && control(NSTextField.self, "团队名称", page: teams).stringValue == previousName
        checks["teamTemplateCancelRestoresListFocus"] = try host.firstResponder === control(NSTableView.self, "Agent 团队列表", page: teams)
        try press("审阅模板", page: teams); guard let staleTeam = pane.currentController as? AgentSettingsReviewPage else { throw PetError("缺少过期团队预览") }
        let added = AgentProfile(name: "并发新增角色", description: "独立公开验收", instructions: "只读公开资料。", tools: ["read_file"])
        try tasks.agents.save(tasks.agents.encode(tasks.agents.decode(originalAgents.0) + [added]), expectedHash: originalAgents.1)
        let externalAgents = try tasks.agents.document(); try press("载入草稿", page: staleTeam)
        checks["teamStaleTemplateKeepsReviewAndExternalRecord"] = try pane.currentController === staleTeam && control(NSTextField.self, "审阅操作错误", page: staleTeam).stringValue.contains("角色或团队配置已改变") && tasks.agents.document().1 == externalAgents.1 && tasks.teams.document().1 == originalTeams.1
        try press("取消", page: staleTeam); try press("审阅模板", page: teams)
        guard let accepted = pane.currentController as? AgentSettingsReviewPage else { throw PetError("缺少可载入的团队模板") }; try press("载入草稿", page: accepted)
        let nameField = try control(NSTextField.self, "团队名称", page: teams), fieldEditor = nameField.currentEditor()
        let nameFocused = host.firstResponder === nameField || (fieldEditor != nil && host.firstResponder === fieldEditor)
        let sameRoles = try tasks.agents.document().1 == externalAgents.1, sameTeams = try tasks.teams.document().1 == originalTeams.1
        checks["teamTemplateLoadLeavesAllWritesForParentSave"] = pane.currentController === teams && sameRoles && sameTeams && nameFocused
        let transition: [String: Any] = ["parentDisplayed": pane.currentController === teams, "roleFileUnchanged": sameRoles, "teamFileUnchanged": sameTeams, "nameFocused": nameFocused, "firstResponder": host.firstResponder.map { String(describing: type(of: $0)) } ?? "nil", "fieldEditor": fieldEditor.map { String(describing: type(of: $0)) } ?? "nil"]
        try JSONSerialization.data(withJSONObject: transition, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("management-review-transitions.json"))
        try edit("团队名称", "", page: teams); try press("保存", page: teams)
        checks["teamTemplateInvalidSaveDoesNotCreateRoles"] = try tasks.agents.document().1 == externalAgents.1 && tasks.teams.document().1 == originalTeams.1
        try edit("团队名称", "页内团队验收", page: teams); try edit("团队职责", "保留审阅后编辑的职责", page: teams); try press("保存", page: teams)
        guard let saved = try tasks.teams.list().first(where: { $0.name == "页内团队验收" }) else { throw PetError("模板团队未保存") }
        let all = try tasks.agents.decode(tasks.agents.document().0), members = all.filter { Set([saved.leaderID] + saved.memberIDs).contains($0.id) }
        checks["teamTemplateParentSaveCreatesExactThreeDisabledRoles"] = members.count == 3 && members.allSatisfy { $0.readOnly && !$0.network && !$0.enabled } && !saved.enabled && saved.description == "保留审阅后编辑的职责"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        checks["teamTemplateSavePreservesAllExistingRoles"] = try tasks.agents.decode(externalAgents.0).allSatisfy { before in guard let after = all.first(where: { $0.id == before.id }) else { return false }; return try encoder.encode(before) == encoder.encode(after) }
        let noProject = AgentTeamWindow(store: tasks, workspace: nil)
        guard pane.show(category: "teams", identity: "team-template-no-project", scope: "用户设置", make: { _ in noProject }) else { throw PetError("无法进入无项目模板") }
        let finalAgents = try tasks.agents.document().1, finalTeams = try tasks.teams.document().1
        try press("审阅模板", page: noProject); guard let userTemplate = pane.currentController as? AgentSettingsReviewPage else { throw PetError("无项目模板未载入") }; try press("取消", page: userTemplate)
        checks["teamTemplateWorksWithoutWorkspaceAndCancelsCleanly"] = try pane.currentController === noProject && tasks.agents.document().1 == finalAgents && tasks.teams.document().1 == finalTeams
        checks["managementReviewCreatesNoVisibleWindows"] = NSApp.windows.filter(\.isVisible).count == visible
        checks["managementReviewLeavesNormally"] = pane.leave()
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("management-review-layout.json"))
        return checks
    }
}
