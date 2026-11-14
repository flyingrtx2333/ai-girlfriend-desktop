import AppKit
import Darwin

@MainActor extension AppDelegate {
    @discardableResult func prepareWorkspaceExtensionsUI(_ output: URL, seed: Bool) async throws -> [String: String] {
        ensureAgent(); guard checkDirectory != nil, let tasks = agentStore else { throw PetError("缺少独立源文件夹验收环境") }
        let file = output.appendingPathComponent("workspace-extensions-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            guard let id = ids["task"], tasks.task(id) != nil else { throw PetError("原源文件夹样例不可用") }
            control.showAgentTask(id); return ids
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("公开样例已存在，请重开原目录") }
        var ids = try await prepareWorkspaceEditorUI(output, seed: true)
        let alpha = ids["alpha"]!, beta = ids["beta"]!, entry = tasks.organization.entry(alpha, mode: .coding, tasks: tasks.tasks)!
        try tasks.organization.editWorkspace(entry, name: "双目录设置公开样例", icon: .cup, color: .blue, folders: [alpha, beta], primary: beta, tasks: tasks.tasks)
        let id = try tasks.createWorkspaceTask(alpha, mode: .coding, title: "多源文件夹设置验收")
        tasks.update(id) { $0.draft = "保留设置切换前的任务草稿 🧭" }
        ids["task"] = id
        for (path, marker) in [(alpha, "ALPHA"), (beta, "BETA")] {
            for kind in AgentExtensionKind.allCases {
                _ = try tasks.extensions.create(kind, name: "source-probe", text: "---\nname: source-probe\ndescription: Public source fixture\n---\n" + marker + "_" + kind.rawValue.uppercased() + "_PUBLIC\n", project: true, workspace: path)
            }
            let memory = try AgentMemory.snapshot(.project, store: tasks, taskID: id, workspace: path)
            _ = try AgentMemory.save(.project, content: marker + "_MEMORY_PUBLIC\n", expectedHash: memory.hash, store: tasks, taskID: id, workspace: path)
            let hook = try tasks.hooks.document(project: true, workspace: path)
            let config = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/usr/bin/printf " + marker + "_HOOK_PUBLIC\"}]}]}}"
            try tasks.hooks.save(config, project: true, workspace: path, expectedHash: hook.1)
        }
        try JSONEncoder().encode(ids).write(to: file)
        control.showAgentTask(id); control.show(tab: "chat"); return ids
    }

    func runWorkspaceExtensionsCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        func refused(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        func find<T: NSView>(_ type: T.Type, _ view: NSView?, _ predicate: (T) -> Bool) -> T? {
            guard let view else { return nil }; if let value = view as? T, predicate(value) { return value }
            for child in view.subviews { if let value = find(type, child, predicate) { return value } }; return nil
        }
        func choose(_ title: String, _ action: () -> Void) throws {
            var clicked = false, expired = false; let deadline = Date().addingTimeInterval(5)
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard !clicked else { return }
                    if let window = NSApp.modalWindow, let button = find(NSButton.self, window.contentView, { $0.title == title }) { clicked = true; button.performClick(nil) }
                    else if Date() >= deadline { expired = true; timer.invalidate(); NSApp.abortModal() }
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel); defer { timer.invalidate() }
            action(); guard clicked, !expired else { throw PetError("未找到确认选项：" + title) }
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime, let host = control.window else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("源文件夹原生验收禁止模型请求") }; defer { runtime.stopAll() }
            let ids = try await prepareWorkspaceExtensionsUI(output, seed: true), id = ids["task"]!, alpha = ids["alpha"]!, beta = ids["beta"]!, outside = ids["outside"]!
            let task = tasks.task(id)!, taskFile = tasks.directory.appendingPathComponent(id + ".json"), original = try Data(contentsOf: taskFile)
            checks["independentProfileAndFrozenTwoRootTask"] = usesAgent && tasks.extensions.sharedHome?.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").resolvingSymlinksInPath() && task.workspace == beta && task.workspacePaths == [alpha, beta]
            func source(_ path: String) throws {
                guard let popup = find(NSPopUpButton.self, host.contentView, { $0.identifier?.rawValue == "settings-source-folder" }), let item = popup.itemArray.first(where: { $0.representedObject as? String == path }), let action = popup.action else { throw PetError("缺少源文件夹切换入口") }
                popup.select(item); NSApp.sendAction(action, to: popup.target, from: popup)
            }
            func tab(_ label: String) throws {
                guard let tabs = find(NSSegmentedControl.self, host.contentView, { $0.accessibilityLabel() == "设置页面类型" }), let index = (0..<tabs.segmentCount).first(where: { tabs.label(forSegment: $0) == label }), let action = tabs.action else { throw PetError("缺少设置页面：" + label) }
                tabs.selectedSegment = index; NSApp.sendAction(action, to: tabs.target, from: tabs)
            }
            func button(_ label: String) throws -> NSButton {
                guard let value = find(NSButton.self, control.settingsControllerForCheck?.pageContentView, { $0.title == label && $0.isEnabled }) else { throw PetError("缺少设置操作：" + label) }; return value
            }
            func extensionEditor() throws -> (AgentExtensionWindow, NSTextView) {
                guard let page = control.settingsControllerForCheck as? AgentExtensionWindow, let editor = find(NSTextView.self, page.pageContentView, { $0.accessibilityLabel() == "扩展说明" }) else { throw PetError("扩展编辑器未打开") }; return (page, editor)
            }
            guard control.showSettingsCategory("extensions") else { throw PetError("设置未打开") }
            let popup = find(NSPopUpButton.self, host.contentView, { $0.identifier?.rawValue == "settings-source-folder" })
            checks["settingsOffersEveryFrozenSourceAndDefaultsToPrimary"] = popup?.numberOfItems == 2 && popup?.selectedItem?.representedObject as? String == beta && popup?.isHiddenOrHasHiddenAncestor == false
            try tab("指令"); let (betaPage, betaEditor) = try extensionEditor()
            checks["primaryCommandEditorReadsActualPrimaryFile"] = betaEditor.string.contains("BETA_COMMAND_PUBLIC") && !betaEditor.string.contains("ALPHA_COMMAND_PUBLIC")
            let betaItem = try tasks.extensions.catalog(workspace: beta).first { $0.kind == .command }!, betaBytes = try Data(contentsOf: betaItem.file)
            betaEditor.string += "UNSAVED_BETA\n"; betaPage.textDidChange(Notification(name: NSText.didChangeNotification, object: betaEditor))
            try choose("继续编辑") { try? source(alpha) }
            checks["continueRestoresPickerAndRetainsEditorAndDraft"] = control.settingsControllerForCheck === betaPage && betaEditor.string.contains("UNSAVED_BETA") && popup?.selectedItem?.representedObject as? String == beta && tasks.task(id)?.draft == task.draft
            try choose("放弃更改") { try? source(alpha) }
            let (alphaPage, alphaEditor) = try extensionEditor()
            checks["discardSwitchesSourceAndPreservesSelectedTab"] = control.settingsSourceReadback()["page"] as? String == "commands" && alphaEditor.string.contains("ALPHA_COMMAND_PUBLIC") && !alphaEditor.string.contains("UNSAVED_BETA")
            let alphaItem = try tasks.extensions.catalog(workspace: alpha).first { $0.kind == .command }!
            alphaEditor.string += "ALPHA_EDITED_PUBLIC\n"; alphaPage.textDidChange(Notification(name: NSText.didChangeNotification, object: alphaEditor)); try button("保存").performClick(nil)
            checks["actualCommandSaveTargetsOnlyChosenSecondary"] = try String(contentsOf: alphaItem.file, encoding: .utf8).contains("ALPHA_EDITED_PUBLIC") && Data(contentsOf: betaItem.file) == betaBytes
            alphaEditor.string += "UNSAVED_CONFLICT\n"; alphaPage.textDidChange(Notification(name: NSText.didChangeNotification, object: alphaEditor))
            let external = Data((try String(contentsOf: alphaItem.file, encoding: .utf8) + "EXTERNAL_CHANGE_PUBLIC\n").utf8); try external.write(to: alphaItem.file, options: .atomic)
            try button("保存").performClick(nil)
            checks["saveConflictPreservesExternalFileAndUnsavedEditor"] = try Data(contentsOf: alphaItem.file) == external && alphaEditor.string.contains("UNSAVED_CONFLICT") && button("保存").isEnabled
            try choose("放弃更改") { try? source(beta) }; try source(alpha)
            for (category, expected) in [("hooks", "AgentHookWindow"), ("agents", "AgentProfileWindow"), ("teams", "AgentTeamWindow")] {
                guard control.showSettingsCategory(category) else { throw PetError("无法进入：" + category) }
                let page = control.settingsControllerForCheck
                let root = (page as? AgentHookWindow)?.scopeWorkspace ?? (page as? AgentProfileWindow)?.scopeWorkspace ?? (page as? AgentTeamWindow)?.workspace
                checks["sourceSelectionCarriesInto-" + category] = root == alpha && control.settingsSourceReadback()["controller"] as? String == expected
            }
            guard control.showSettingsCategory("extensions") else { throw PetError("扩展未重开") }; try tab("连接器")
            checks["connectorManagerUsesChosenSource"] = (control.settingsControllerForCheck as? AgentMCPWindow)?.scopeWorkspace == alpha
            guard control.showSettingsCategory("memory") else { throw PetError("规则未打开") }; try tab("规则")
            guard let rulePage = control.settingsControllerForCheck as? AgentRuleWindow, let body = find(NSTextView.self, rulePage.pageContentView, { $0.accessibilityLabel() == "规则正文" }) else { throw PetError("规则正文未打开") }
            checks["secondaryRuleEditorReadsActualSecondaryRule"] = body.string.contains("ALPHA_LOCAL_SOURCE_RULE") && !body.string.contains("BETA_LOCAL_SOURCE_RULE")
            body.string += "\nALPHA_RULE_EDITED_PUBLIC"; rulePage.textDidChange(Notification(name: NSText.didChangeNotification, object: body)); try button("保存").performClick(nil)
            checks["actualRuleSaveTargetsOnlyChosenSource"] = try tasks.rules.catalog(workspace: alpha).contains { $0.text?.contains("ALPHA_RULE_EDITED_PUBLIC") == true } && !tasks.rules.catalog(workspace: beta).contains { $0.text?.contains("ALPHA_RULE_EDITED_PUBLIC") == true }
            let beforeMemory = try AgentMemory.snapshot(.project, store: tasks, taskID: id, workspace: beta)
            let memory = try AgentMemory.snapshot(.project, store: tasks, taskID: id, workspace: alpha)
            _ = try AgentMemory.save(.project, content: "ALPHA_MEMORY_EDITED_PUBLIC\n", expectedHash: memory.hash, store: tasks, taskID: id, workspace: alpha)
            checks["secondaryMemorySavePreservesPrimaryAndRejectsStaleHash"] = try AgentMemory.snapshot(.project, store: tasks, taskID: id, workspace: beta).hash == beforeMemory.hash && refused { _ = try AgentMemory.save(.project, content: "stale", expectedHash: memory.hash, store: tasks, taskID: id, workspace: alpha) }
            checks["settingsContextRejectsUnselectedSource"] = refused { _ = try AgentWorkspaceScope.settingsTask(task, workspace: outside) } && refused { _ = try AgentMemory.snapshot(.project, store: tasks, taskID: id, workspace: outside) }
            checks["effectiveInstructionsRemainTaskWide"] = try AgentMemory.snapshot(.effectiveInstructions, store: tasks, taskID: id, workspace: alpha).content == AgentMemory.snapshot(.effectiveInstructions, store: tasks, taskID: id, workspace: beta).content
            let betaInstructions = try AgentMemory.snapshot(.instructions, store: tasks, taskID: id, workspace: beta)
            let alphaInstructions = try AgentMemory.snapshot(.instructions, store: tasks, taskID: id, workspace: alpha)
            var changedRoots: [String?] = []; let previousChange = tasks.instructions.onChange
            tasks.instructions.onChange = { source, workspace in changedRoots.append(workspace); previousChange?(source, workspace) }
            defer { tasks.instructions.onChange = previousChange }
            _ = try AgentMemory.save(.instructions, content: alphaInstructions.content + "ALPHA_INSTRUCTION_EDITED_PUBLIC\n", expectedHash: alphaInstructions.hash, store: tasks, taskID: id, workspace: alpha)
            checks["secondaryInstructionSaveNotifiesOnlyChosenRoot"] = try changedRoots == [alpha] && AgentMemory.snapshot(.instructions, store: tasks, taskID: id, workspace: beta).hash == betaInstructions.hash
            checks["taskContextUsesActuallySavedSecondaryInstructions"] = try runtime.systemContext(tasks.task(id)!).contains("ALPHA_INSTRUCTION_EDITED_PUBLIC")
            let local = try tasks.rules.catalog(task: task).filter { $0.invocation == "project/source-check" }
            let plugins = try tasks.extensions.plugins.ruleItems(task: task)
            checks["duplicateRuleNamesStayDistinctBySource"] = local.count == 2 && plugins.count == 2 && Set(local.map(AgentRuleSelection.title)).count == 2 && Set(plugins.map(AgentRuleSelection.title)).count == 2
            for item in local {
                let text = try AgentRuleSelection.invocation(AgentRuleSelection.title(item)) + " 保留原始要求 🧭"
                let message = try runtime.prepareInput(text, attachmentIDs: [], task: task)
                let reference = try tasks.rules.selection(item.id, task: task)
                checks["quotedLocalSelectsExactSource-" + URL(fileURLWithPath: item.owner.path).lastPathComponent] = message.content == text && message.localRuleReferences == [reference] && message.ruleReferences == nil
            }
            for item in plugins {
                let text = try AgentRuleSelection.invocation(AgentRuleSelection.title(item)) + " 按实际来源核对"
                let message = try runtime.prepareInput(text, attachmentIDs: [], task: task)
                checks["quotedPluginSelectsExactSource-" + URL(fileURLWithPath: item.reference.workspace!).lastPathComponent] = message.ruleReferences == [item.reference] && message.localRuleReferences == nil
            }
            let ruleTask = try tasks.createWorkspaceTask(alpha, mode: .coding, title: "规则实际上下文验收")
            let chosenLocal = local.first { $0.owner.path == alpha }!, chosenPlugin = plugins.first { $0.reference.workspace == beta }!
            guard try runtime.submit(AgentRuleSelection.invocation(AgentRuleSelection.title(chosenLocal)) + " 核对所选来源", taskID: ruleTask, startImmediately: false) else { throw PetError(runtime.submissionError ?? "所选规则未保存") }
            let localContext = try runtime.systemContext(tasks.task(ruleTask)!)
            checks["selectedSecondaryLocalRuleEntersActualTaskContextOnly"] = localContext.contains("ALPHA_LOCAL_SOURCE_RULE") && !localContext.contains("BETA_LOCAL_SOURCE_RULE") && tasks.task(ruleTask)?.activeLocalRules?.first?.workspace == alpha
            guard try runtime.submit(AgentRuleSelection.invocation(AgentRuleSelection.title(chosenPlugin)) + " 保留所属来源", taskID: ruleTask, startImmediately: false) else { throw PetError(runtime.submissionError ?? "所选插件规则未保存") }
            checks["selectedPluginRuleKeepsExactSourceInActualTaskContext"] = try runtime.systemContext(tasks.task(ruleTask)!).contains("PLUGIN_PUBLIC_SOURCE_RULE") && tasks.task(ruleTask)?.activeRules?.first?.workspace == beta
            checks["ambiguousShortRuleNamesRejectInsteadOfPickingFirst"] = refused { _ = try runtime.prepareInput("@rule:project/source-check", attachmentIDs: [], task: task) } && refused { _ = try runtime.prepareInput("@rule:workspace-source:public", attachmentIDs: [], task: task) }
            checks["quotedRuleRejectsMalformedUnknownAndOutsideSources"] = refused { _ = try AgentRuleSelection.command("@rule \"unfinished") } && refused { _ = try AgentRuleSelection.command("@rule \"name\"suffix") } && refused { _ = try runtime.prepareInput("@rule \"project/source-check · " + outside + "/rule.md\"", attachmentIDs: [], task: task) }
            let selected = local.first { $0.owner.path == alpha }!, quoted = try AgentRuleSelection.invocation(AgentRuleSelection.title(selected))
            try tasks.rules.setEnabled(selected, false, task: task)
            checks["disabledQuotedRuleCannotBeSelected"] = refused { _ = try runtime.prepareInput(quoted, attachmentIDs: [], task: task) }
            try tasks.rules.setEnabled(try tasks.rules.current(selected.id, task: task, enabledOnly: false), true, task: task)
            var narrowed = task; narrowed.workspaceScope = nil
            checks["quotedSourceCannotExpandNarrowTaskOrArchivedTask"] = refused { _ = try runtime.prepareInput(quoted, attachmentIDs: [], task: narrowed) }
            var archived = task; archived.archived = true
            checks["archivedTaskCannotAcquireQuotedRules"] = refused { _ = try runtime.prepareInput(quoted, attachmentIDs: [], task: archived) }
            checks["connectorQuotedParsingPreservesEscapesAndArguments"] = try AgentMCPSelection.command("/mcp \"用户 · public \\\"echo\\\"\" 继续核对")?.name == "用户 · public \"echo\"" && AgentMCPSelection.command("/mcp \"echo\" 后续要求")?.arguments == "后续要求" && refused { _ = try AgentMCPSelection.command("/mcp \"echo\"tail") }
            checks["settingsChangesNeverRewriteTaskBoundsPermissionsOrDraft"] = try Data(contentsOf: taskFile) == original && tasks.task(id)?.workspaceScope == task.workspaceScope && tasks.task(id)?.draft == task.draft && tasks.task(id)?.permission == task.permission
            let reopened = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["savedSourceContentAndOriginalTaskSurviveReopen"] = try reopened.task(id)?.workspaceScope == task.workspaceScope && reopened.task(id)?.draft == task.draft && AgentMemory.snapshot(.project, store: reopened, taskID: id, workspace: alpha).content == "ALPHA_MEMORY_EDITED_PUBLIC\n" && Data(contentsOf: betaItem.file) == betaBytes
            let selectionID = try tasks.createWorkspaceTask(alpha, mode: .coding, title: "规则来源选择草稿")
            tasks.update(selectionID) { $0.draft = "保留原始要求与输入 🧭" }; control.showAgentTask(selectionID)
            guard control.showSettingsCategory("memory") else { throw PetError("引用选择设置未打开") }; try tab("规则"); try source(alpha)
            try button("在任务中使用").performClick(nil)
            let inserted = control.organizationSnapshot()["draft"] as? String ?? "", command = try AgentRuleSelection.command(inserted)
            checks["actualRuleUseAddsReadableExactSourceAndPreservesInput"] = command?.name.contains(alpha) == true && command?.arguments == "保留原始要求与输入 🧭" && !inserted.contains("\\/")
            guard control.showSettingsCategory("memory") else { throw PetError("引用替换设置未打开") }; try tab("规则"); try source(beta); try button("在任务中使用").performClick(nil)
            let replaced = try AgentRuleSelection.command(control.organizationSnapshot()["draft"] as? String ?? "")
            checks["actualSourceReplacementPreservesUserTailWithoutDuplicateDirective"] = replaced?.name.contains(beta) == true && replaced?.arguments == "保留原始要求与输入 🧭"
            checks["noModelsOrFabricatedUsage"] = attempts == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 && !$0.messages.contains { $0.role == "assistant" } }
            report["settings"] = control.settingsSourceReadback()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["appPID"] = getpid(); report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workspace-extensions-report.json"), options: .atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}
