import AppKit

@MainActor extension AppDelegate {
    func runSettingsManagementReviewCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, let executable = Bundle.main.executableURL else { throw PetError("缺少设置验收工作台") }
            report["binaryHash"] = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
            runtime.modelRequestCheck = { requests += 1; throw PetError("设置审阅检查禁止模型请求") }
            let task = try await prepareSettingsPagesCheck(output, tasks: tasks)
            let plugins = tasks.extensions.plugins, samples = try AgentPluginReviewCheck.prepareSources(output)
            _ = try plugins.install(await plugins.inspect(samples[0]))
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let pane = AgentSettingsPageHost(); host.contentView = pane; host.makeKeyAndOrderFront(nil)
            defer { host.close() }
            checks = try await AgentManagementReviewCheck.run(tasks: tasks, taskID: task, pane: pane, host: host, output: output)
        } catch { report["error"] = error.localizedDescription }
        report["appPID"] = getpid(); report["checks"] = checks; report["modelRequests"] = requests
        report["success"] = report["error"] == nil && requests == 0 && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("settings-pages-report.json"))
    }
}

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
            ["name": "页内模型审阅", "type": "prompt", "prompt": (1...48).map { "第 \($0) 项公开验收字段" }.joined(separator: "\n"), "timeout": 5],
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
        let context = AgentSettingsRecovery.Context(task: tasks.task(taskID), workspace: workspace)
        guard pane.show(category: "hooks", identity: "inline-hook-review", scope: "设置项目", recoveryContext: context, make: { _ in manager }) else {
            throw PetError("无法进入 Hook 审阅")
        }
        var checks: [String: Bool] = [:], measurements: [String: Any] = [:]
        let names = ["页内命令审阅", "页内HTTP审阅", "页内模型审阅", "页内Agent审阅", "页内后台审阅"]
        let expected = ["此命令将自动运行", "发送当前事件数据", "产生模型用量", "只读项目", "退出码为 2"]
        func hook(_ name: String) throws -> AgentHookDefinition { guard let value = try service.catalog(workspace: workspace).first(where: { $0.name == name }) else { throw PetError("缺少 Hook：" + name) }; return value }
        func layout(_ page: AgentSettingsReviewPage, key: String, multiple: Bool) throws {
            for (label, size) in [("normal", NSSize(width: 800, height: 540)), ("narrow", NSSize(width: 420, height: 360))] {
                host.setContentSize(size); pane.layoutSubtreeIfNeeded(); let detail = try control(NSTextView.self, "设置审阅正文", page: page)
                var valid = !detail.hasAmbiguousLayout && detail.bounds.width >= 140 && detail.bounds.height >= 100
                if multiple {
                    if label == "narrow" {
                        let picker = try control(NSPopUpButton.self, "选择审阅条目", page: page)
                        valid = valid && !picker.isHiddenOrHasHiddenAncestor && detail.bounds.width >= 380
                    } else { valid = try valid && !control(NSTableView.self, "设置审阅列表", page: page).hasAmbiguousLayout }
                }
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
        guard let hookState = try pane.captureRecovery(active: true), let hookReview = hookState.pages.last else { throw PetError("缺少 Hook 启用恢复记录") }
        checks["hookReviewRecordsOriginalRouteAndScope"] = hookState.context == context && hookState.pages.map(\.kind) == ["hooks", "hook-enable-review"]
        let document = try service.document(project: false, workspace: workspace)
        var changed = try JSONSerialization.jsonObject(with: Data(document.0.utf8)) as! [String: Any], groups = changed["hooks"] as! [String: Any], entries = groups["PreToolUse"] as! [[String: Any]]
        var definitions = entries.last!["hooks"] as! [[String: Any]]; definitions[0]["timeout"] = 6; entries[entries.count - 1]["hooks"] = definitions; groups["PreToolUse"] = entries; changed["hooks"] = groups
        try service.save(object(changed), project: false, workspace: workspace, expectedHash: document.1)
        let approvedBefore = try bytes(authorization); try press("启用", page: stale)
        checks["hookStaleReviewRefusesApprovalAndKeepsPage"] = try pane.currentController === stale && control(NSTextField.self, "审阅操作错误", page: stale).stringValue.contains("Hook 已变化") && bytes(authorization) == approvedBefore
        if let recovered = try manager.makeSettingsRecoveryChild(hookReview) as? AgentSettingsReviewPage {
            try recovered.restoreSettingsRecovery(hookReview)
            checks["restoredChangedHookCannotBeEnabled"] = try find(NSButton.self, in: recovered.pageContentView, matching: { $0.title == "启用" })?.isEnabled == false &&
                control(NSTextField.self, "审阅操作错误", page: recovered).stringValue.contains("Hook 已变化") && bytes(authorization) == approvedBefore
        } else { checks["restoredChangedHookCannotBeEnabled"] = false }
        try press("取消", page: stale); checks["hookReviewReturnRefreshesChangedDefinition"] = try pane.currentController === manager && !service.trusted(hook(names[0]))
        let configBefore = try bytes(source), grantsBefore = try bytes(authorization)
        let editConfig = try control(NSButton.self, "编辑当前范围的 Hooks 配置", page: manager); editConfig.performClick(nil)
        guard let configuration = pane.currentController, configuration !== manager else { throw PetError("Hooks 配置未进入设置子页") }
        let editor = try control(NSTextView.self, "Hooks JSON 配置", page: configuration), feedback = try control(NSTextField.self, "Hooks 配置保存状态", page: configuration)
        let originalConfig = editor.string
        checks["hookConfigHostedAndEditorFocused"] = configuration.presentingWindow === host && configuration.window?.isVisible == false && host.firstResponder === editor && host.attachedSheet == nil
        checks["hookConfigIdentifiesGlobalScopeInsideEditor"] = configuration.detailHeading?.title == "编辑 Hooks" && configuration.detailHeading?.scope == "全局 Hooks"
        checks["hookConfigEmptyFeedbackCollapses"] = feedback.isHidden
        let invalid = "{\n" + String(repeating: "\n", count: 80) + #"  "hooks": @{}"# + "\n}"
        editor.string = invalid; try press("保存", page: configuration)
        checks["hookConfigInvalidSaveKeepsDraftSourceAndGrant"] = try pane.currentController === configuration && editor.string == invalid && feedback.stringValue.contains("第 82 行，第 12 列") && bytes(source) == configBefore && bytes(authorization) == grantsBefore
        try press("定位错误", page: configuration)
        checks["hookConfigJumpFocusesTheActualParsePosition"] = host.firstResponder === editor && editor.selectedRange() == NSRange(location: (invalid as NSString).range(of: "@").location, length: 0)
        editor.string = originalConfig + String(repeating: "\n", count: 200)
        let sourceMode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as! NSNumber
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: sourceMode], ofItemAtPath: source.path) }
        try press("保存", page: configuration)
        checks["hookConfigReadOnlySaveKeepsDraftSourceModeAndGrant"] = try pane.currentController === configuration && editor.string.hasSuffix(String(repeating: "\n", count: 200)) && feedback.stringValue.contains("只读") && bytes(source) == configBefore && FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int == 0o400 && bytes(authorization) == grantsBefore
        checks["hookConfigPermissionErrorDoesNotOfferASyntaxJump"] = find(NSButton.self, in: configuration.pageContentView, matching: { $0.title == "定位错误" && !$0.isHiddenOrHasHiddenAncestor }) == nil
        for (label, size) in [("normal", NSSize(width: 800, height: 540)), ("narrow", NSSize(width: 420, height: 360))] {
            host.setContentSize(size); pane.layoutSubtreeIfNeeded(); editor.layoutManager?.ensureLayout(for: editor.textContainer!)
            guard let scroll = editor.enclosingScrollView, let save = find(NSButton.self, in: configuration.pageContentView, matching: { $0.title == "保存" }), let page = configuration.pageContentView else { throw PetError("缺少 Hooks 配置编辑区域") }
            editor.scrollRangeToVisible(NSRange(location: editor.string.utf16.count, length: 0))
            let viewport = scroll.documentVisibleRect, buttonFrame = save.convert(save.bounds, to: page)
            // NSTextField's transparent frame extends outside its aligned text rectangle.
            let feedbackFrame = feedback.superview!.convert(feedback.alignmentRect(forFrame: feedback.frame), to: page)
            let rawFeedbackFrame = feedback.convert(feedback.bounds, to: page)
            checks["hookConfigLongEditorScrollsAndSaveStaysVisible-" + label] = !scroll.hasAmbiguousLayout && viewport.width >= 140 && viewport.height >= 80 && viewport.minY > 0 && page.visibleRect.contains(buttonFrame)
            checks["hookConfigErrorWrapsWithoutClipping-" + label] = !feedback.isHidden && feedback.isSelectable && !feedback.usesSingleLineMode && feedback.maximumNumberOfLines == 0 && page.visibleRect.contains(feedbackFrame) && feedbackFrame.height >= feedback.intrinsicContentSize.height - 1
            measurements["hookConfig-" + label] = ["editorViewport": [viewport.width, viewport.height], "saveVisible": page.visibleRect.contains(buttonFrame), "feedbackHeight": feedbackFrame.height, "feedbackTextBounds": [feedbackFrame.minX, feedbackFrame.maxX], "feedbackRawBounds": [rawFeedbackFrame.minX, rawFeedbackFrame.maxX], "pageWidth": page.bounds.width]
        }
        try FileManager.default.setAttributes([.posixPermissions: sourceMode], ofItemAtPath: source.path)
        host.setContentSize(NSSize(width: 800, height: 540)); editor.string = originalConfig; try press("保存", page: configuration)
        checks["hookConfigValidRetryKeepsEditorAndPreservesDefinition"] = try pane.currentController === configuration && feedback.stringValue == "已保存" &&
            service.document(project: false, workspace: workspace).0 == originalConfig && bytes(authorization) == grantsBefore
        configuration.close()
        func refusesReadOnly(_ file: URL, operation: () throws -> Void) throws -> Bool {
            let before = try Data(contentsOf: file), grants = try bytes(authorization), mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
            do { try operation(); return false }
            catch { return try error.localizedDescription.contains("只读") && Data(contentsOf: file) == before && FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o400 && bytes(authorization) == grants }
        }
        let projectDocument = try service.document(project: true, workspace: workspace)
        try service.save(projectDocument.0, project: true, workspace: workspace, expectedHash: projectDocument.1)
        let projectFile = try service.file(project: true, workspace: workspace), projectSaved = try service.document(project: true, workspace: workspace)
        checks["hookProjectConfigRefusesReadOnlySource"] = try refusesReadOnly(projectFile) { try service.save(projectSaved.0, project: true, workspace: workspace, expectedHash: projectSaved.1) }
        let plugins = tasks.extensions.plugins
        guard let plugin = try plugins.catalog(workspace: workspace).first(where: { $0.metadata.name == "review-inline" }),
              let userReference = try plugins.hookReferences().first(where: { $0.name == "review-inline" }),
              let pluginHook = try service.catalog(workspace: workspace).first(where: {
                  $0.plugin?.name == plugin.id && $0.plugin?.installationID == plugin.instanceID
              }),
              let reference = pluginHook.plugin else { throw PetError("缺少当前范围的公开插件 Hook") }
        let userFile = try plugins.hookConfiguration(userReference).file
        let userBefore = try bytes(userFile)
        let pluginDocument = try service.pluginDocument(reference)
        manager.selectHook(pluginHook.id)
        try control(NSButton.self, "编辑所选 Hook 配置", page: manager).performClick(nil)
        guard let pluginEditor = pane.currentController, pluginEditor !== manager else { throw PetError("缺少公开插件 Hook 编辑器") }
        try press("保存", page: pluginEditor)
        let pluginFile = try plugins.hookConfiguration(reference).file, pluginSaved = try service.pluginDocument(reference)
        checks["hookPluginFirstSaveKeepsEditorAndCreatesOverride"] = pane.currentController === pluginEditor && pluginSaved.hash != pluginDocument.hash &&
            pluginSaved.text == pluginDocument.text
        checks["hookPluginConfigRefusesReadOnlySource"] = try refusesReadOnly(pluginFile) { try service.savePluginDocument(pluginSaved.text, reference: reference, original: pluginSaved.original, expectedHash: pluginSaved.hash) }
        try service.save(projectSaved.0, project: true, workspace: workspace, expectedHash: projectSaved.1)
        let pluginInput = try control(NSTextView.self, "Hooks JSON 配置", page: pluginEditor)
        let pluginDraft = pluginInput.string + "\n\n"
        pluginInput.string = pluginDraft; pluginInput.didChangeText()
        try press("保存", page: pluginEditor)
        checks["hookProjectAndPluginConfigRetryAfterRestoringPermissions"] = try service.document(project: true, workspace: workspace).0 == projectSaved.0 &&
            service.pluginDocument(reference).text == pluginSaved.text && pluginInput.string == pluginDraft &&
            control(NSTextField.self, "Hooks 配置保存状态", page: pluginEditor).stringValue == "已保存"
        checks["hookPluginSaveStaysInEffectiveScope"] = try pluginHook.workspace == plugin.workspace &&
            (plugin.workspace == nil ? pluginFile == userFile : pluginFile != userFile && bytes(userFile) == userBefore)
        pluginEditor.close()
        let sourceBeforeGrantFailure = try bytes(source), currentDocument = try service.document(project: false, workspace: workspace), currentHook = try hook(names[0]), wasEnabled = service.enabled(currentHook)
        checks["hookReadOnlyGrantRejectsConfigSave"] = try refusesReadOnly(authorization) { try service.save(currentDocument.0, project: false, workspace: workspace, expectedHash: currentDocument.1) }
        checks["hookReadOnlyGrantRejectsEnableChange"] = try refusesReadOnly(authorization) { try service.setEnabled(currentHook, !wasEnabled, workspace: workspace) }
        checks["hookReadOnlyGrantKeepsSourceRuntimeAndCatalogUsable"] = try bytes(source) == sourceBeforeGrantFailure && service.enabled(currentHook) == wasEnabled && service.catalog(workspace: workspace).contains(where: { $0.id == currentHook.id })
        let teams = AgentTeamWindow(store: tasks, workspace: workspace)
        guard pane.show(category: "teams", identity: "inline-team-template", scope: "设置项目", recoveryContext: context, make: { _ in teams }) else {
            throw PetError("无法进入团队模板")
        }
        let originalAgents = try tasks.agents.document(), originalTeams = try tasks.teams.document(), previousSelection = try control(NSTableView.self, "Agent 团队列表", page: teams).selectedRow
        try press("审阅模板", page: teams)
        guard let template = pane.currentController as? AgentSettingsReviewPage else { throw PetError("团队模板未进入审阅子页") }
        let roles = try control(NSTableView.self, "设置审阅列表", page: template), content = try control(NSTextView.self, "设置审阅正文", page: template)
        checks["teamTemplateReviewHostedWithoutSheet"] = template.presentingWindow === host && template.window?.isVisible == false && host.attachedSheet == nil && roles.numberOfRows == 4 && host.firstResponder === roles
        let expectedBody = ["等待两名成员的实际结果", AgentTemplates.profiles[3].instructions, AgentTemplates.profiles[0].instructions, "不得修改文件或运行会改动项目的测试"]
        for index in 0..<4 { roles.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); checks["teamTemplateCompleteInstructions-\(index)"] = content.string.contains(expectedBody[index]) && (index == 0 || content.string.contains("只读项目") && content.string.contains("不联网") && content.string.contains("跟随任务")) }
        checks["teamTemplateReviewExplainsMemberCreation"] = try control(NSTextField.self, "审阅操作影响", page: template).stringValue.contains("保存时创建三个 Agent")
        try layout(template, key: "teamTemplate", multiple: true); try press("取消", page: template)
        checks["teamTemplateCancelWritesNothing"] = try pane.currentController === teams && tasks.agents.document().1 == originalAgents.1 && tasks.teams.document().1 == originalTeams.1 && control(NSTableView.self, "Agent 团队列表", page: teams).selectedRow == previousSelection
        checks["teamTemplateCancelRestoresListFocus"] = try host.firstResponder === control(NSTableView.self, "Agent 团队列表", page: teams)
        try press("审阅模板", page: teams); guard let staleTeam = pane.currentController as? AgentSettingsReviewPage else { throw PetError("缺少过期团队预览") }
        guard let teamState = try pane.captureRecovery(active: true), let teamReview = teamState.pages.last else { throw PetError("缺少团队模板恢复记录") }
        checks["teamReviewRecordsOriginalRouteAndScope"] = teamState.context == context && teamState.pages.map(\.kind) == ["teams", "team-template-review"]
        let added = AgentProfile(name: "并发新增角色", description: "独立公开验收", instructions: "只读公开资料。", tools: ["read_file"])
        try tasks.agents.save(tasks.agents.encode(tasks.agents.decode(originalAgents.0) + [added]), expectedHash: originalAgents.1)
        let externalAgents = try tasks.agents.document(); try press("载入草稿", page: staleTeam)
        checks["teamStaleTemplateKeepsReviewAndExternalRecord"] = try pane.currentController === staleTeam && control(NSTextField.self, "审阅操作错误", page: staleTeam).stringValue.contains("角色或团队配置已改变") && tasks.agents.document().1 == externalAgents.1 && tasks.teams.document().1 == originalTeams.1
        if let recovered = try teams.makeSettingsRecoveryChild(teamReview) as? AgentSettingsReviewPage {
            try recovered.restoreSettingsRecovery(teamReview)
            checks["restoredChangedTeamCannotLoadDraft"] = try find(NSButton.self, in: recovered.pageContentView, matching: { $0.title == "载入草稿" })?.isEnabled == false &&
                control(NSTextField.self, "审阅操作错误", page: recovered).stringValue.contains("角色或团队配置已改变") &&
                tasks.agents.document().1 == externalAgents.1 && tasks.teams.document().1 == originalTeams.1
        } else { checks["restoredChangedTeamCannotLoadDraft"] = false }
        try press("取消", page: staleTeam); try press("审阅模板", page: teams)
        guard let accepted = pane.currentController as? AgentSettingsReviewPage else { throw PetError("缺少可载入的团队模板") }; try press("载入草稿", page: accepted)
        guard let teamEditor = pane.currentController as? AgentSettingsDetailPage else { throw PetError("团队草稿未进入配置页") }
        let nameField = try control(NSTextField.self, "团队名称", page: teamEditor), fieldEditor = nameField.currentEditor()
        let nameFocused = host.firstResponder === nameField || (fieldEditor != nil && host.firstResponder === fieldEditor)
        let sameRoles = try tasks.agents.document().1 == externalAgents.1, sameTeams = try tasks.teams.document().1 == originalTeams.1
        checks["teamTemplateLoadLeavesAllWritesForParentSave"] = pane.currentController === teamEditor && sameRoles && sameTeams && nameFocused
        let transition: [String: Any] = ["parentDisplayed": pane.currentController === teamEditor, "roleFileUnchanged": sameRoles, "teamFileUnchanged": sameTeams, "nameFocused": nameFocused, "firstResponder": host.firstResponder.map { String(describing: type(of: $0)) } ?? "nil", "fieldEditor": fieldEditor.map { String(describing: type(of: $0)) } ?? "nil"]
        try JSONSerialization.data(withJSONObject: transition, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("management-review-transitions.json"))
        try edit("团队名称", "", page: teamEditor); try press("保存", page: teamEditor)
        checks["teamTemplateInvalidSaveDoesNotCreateRoles"] = try tasks.agents.document().1 == externalAgents.1 && tasks.teams.document().1 == originalTeams.1
        try edit("团队名称", "页内团队验收", page: teamEditor); try edit("团队职责", "保留审阅后编辑的职责", page: teamEditor); try press("保存", page: teamEditor)
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

    static func runWindow(owner: ControlWindow, tasks: AgentStore, taskID: String, output: URL) async throws -> [String: Bool] {
        guard let window = owner.window, let root = window.contentView,
              let pane = find(AgentSettingsPageHost.self, in: root, matching: { _ in true }),
              let actions = find(NSStackView.self, in: root, matching: { $0.identifier?.rawValue == "settings-window-actions" }),
              let workspace = tasks.task(taskID)?.workspace else { throw PetError("缺少设置工作台") }
        let originalSize = root.bounds.size, appearance = window.appearance
        defer { window.appearance = appearance; window.setContentSize(originalSize); owner.show(tab: "chat") }
        owner.showAgentTask(taskID); window.makeKeyAndOrderFront(nil)
        func render(_ size: NSSize, _ appearance: NSAppearance.Name, named label: String) async throws {
            window.appearance = NSAppearance(named: appearance); window.setContentSize(size)
            await Task.yield(); root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard root.bounds.size == size, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                throw PetError("设置审阅窗口尺寸不符")
            }
            bitmap.size = root.bounds.size; root.cacheDisplay(in: root.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("设置审阅窗口无法编码") }
            try png.write(to: output.appendingPathComponent("settings-review-" + label + ".png"), options: .atomic)
        }
        func pressAction(_ title: String) throws {
            guard let button = actions.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == title && $0.isEnabled }) else {
                throw PetError("缺少设置页头操作 " + title)
            }
            button.performClick(nil)
        }
        func titleCount(_ title: String) -> Int {
            func count(_ view: NSView) -> Int {
                if view.isHiddenOrHasHiddenAncestor { return 0 }
                let current = (view as? NSTextField)?.stringValue == title ? 1 : 0
                return current + view.subviews.reduce(0) { $0 + count($1) }
            }
            return count(root)
        }

        var checks: [String: Bool] = [:]
        let compact = NSSize(width: 780, height: 540), wide = NSSize(width: 1320, height: 800)
        guard owner.showSettingsCategory("hooks"), let hooks = pane.currentController as? AgentHookWindow,
              let hook = try tasks.hooks.catalog(workspace: workspace).first(where: { $0.name == "页内模型审阅" }) else { throw PetError("未打开实际 Hooks 列表") }
        hooks.selectHook(hook.id); try press("启用", page: hooks)
        guard let review = pane.currentController as? AgentSettingsReviewPage else { throw PetError("未打开实际 Hooks 审阅") }
        try await render(compact, .darkAqua, named: "hook-compact")
        let preview = try control(NSTextView.self, "设置审阅正文", page: review), headline = "启用「页内模型审阅」"
        checks["reviewWorkbenchHookShowsSingleTitleAndHeaderActions"] = titleCount(headline) == 1 && review.presentingWindow === window &&
            window.attachedSheet == nil && actions.arrangedSubviews.count == 2 && review.window?.isVisible == false
        let tail = (preview.string as NSString).range(of: "第 48 项公开验收字段")
        guard tail.location != NSNotFound else { throw PetError("Hooks 末段内容缺失") }
        preview.scrollRangeToVisible(tail)
        root.layoutSubtreeIfNeeded()
        checks["reviewWorkbenchLongHookReachesTailWithActionsVisible"] = tail.location != NSNotFound &&
            (preview.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0 && !actions.isHiddenOrHasHiddenAncestor &&
            preview.enclosingScrollView.map { root.bounds.contains($0.convert($0.bounds, to: root)) } == true
        try pressAction("取消")
        checks["reviewWorkbenchCancelPreservesHookAndFocus"] = pane.currentController === hooks && !tasks.hooks.enabled(hook) &&
            (window.firstResponder as? NSButton)?.accessibilityIdentifier() == "hook-handler-" + hook.id

        guard owner.showSettingsCategory("teams"), pane.currentController is AgentTeamWindow else { throw PetError("未打开实际团队列表") }
        let rolesBefore = try tasks.agents.document().1, teamsBefore = try tasks.teams.document().1
        try pressAction("审阅模板")
        guard let team = pane.currentController as? AgentSettingsReviewPage else { throw PetError("未打开实际模板审阅") }
        try await render(wide, .aqua, named: "team-wide")
        let list = try control(NSTableView.self, "设置审阅列表", page: team), body = try control(NSTextView.self, "设置审阅正文", page: team)
        checks["reviewWorkbenchWideTeamShowsIndexAndSingleTitle"] = titleCount("代码审阅团队") == 1 &&
            !list.isHiddenOrHasHiddenAncestor && list.numberOfRows == 4
        list.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        let role = body.string, selectedText = (role as NSString).range(of: "不得修改文件")
        body.setSelectedRange(selectedText)
        try await render(compact, .darkAqua, named: "team-compact")
        let picker = try control(NSPopUpButton.self, "选择审阅条目", page: team)
        checks["reviewWorkbenchCompactTeamKeepsSelectedRoleAndExpandsBody"] = picker.indexOfSelectedItem == 3 &&
            body.string == role && body.selectedRange() == selectedText && body.bounds.width >= 480
        func choose(_ row: Int) throws {
            picker.selectItem(at: row)
            guard let action = picker.action, NSApp.sendAction(action, to: picker.target, from: picker) else {
                throw PetError("无法切换团队审阅条目")
            }
        }
        try choose(0)
        checks["reviewWorkbenchCompactTeamPickerReadsFullTeam"] = body.string.contains("等待两名成员的实际结果")
        try choose(3)
        checks["reviewWorkbenchCompactTeamRestoresRoleSelection"] = body.string == role && body.selectedRange() == selectedText
        try pressAction("载入草稿")
        checks["reviewWorkbenchLoadDraftReturnsToActualTeamEditor"] = try pane.currentController is AgentSettingsDetailPage &&
            tasks.agents.document().1 == rolesBefore && tasks.teams.document().1 == teamsBefore && window.attachedSheet == nil
        // Finish the isolated draft through the normal settings action.
        try pressAction("保存")
        checks["reviewWorkbenchExplicitSaveCreatesTeam"] = try tasks.teams.list().contains { $0.name.hasPrefix("代码审阅团队") && !$0.enabled }
        return checks
    }
}
