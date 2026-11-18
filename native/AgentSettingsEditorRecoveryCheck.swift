import AppKit

@MainActor extension AppDelegate {
    private struct SettingsEditorFixture: Codable {
        var multi: String, general: String, creationTask: String, alpha: String, beta: String
        var rule: String, skill: String, command: String
        var windows: [String: String], sources: [String: String]
    }
    func runSettingsEditorRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
        let fixtureFile = output.appendingPathComponent("settings-editor-fixture.json")
        func find<T: NSView>(_ type: T.Type, _ view: NSView?, _ predicate: (T) -> Bool) -> T? {
            guard let view else { return nil }; if let typed = view as? T, predicate(typed) { return typed }
            for child in view.subviews { if let found = find(type, child, predicate) { return found } }; return nil
        }
        func input<T: NSView>(_ type: T.Type, _ label: String, _ window: ControlWindow) throws -> T {
            guard let value = find(type, window.window?.contentView, { $0.accessibilityLabel() == label }) else { throw PetError("缺少设置恢复控件：" + label) }; return value
        }
        func click(_ title: String, _ window: ControlWindow) throws {
            guard let button = find(NSButton.self, window.window?.contentView, { $0.title == title && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }) else { throw PetError("缺少设置恢复操作：" + title) }; button.performClick(nil)
        }
        func field(_ label: String, _ value: String, _ window: ControlWindow) throws {
            let input = try input(NSTextField.self, label, window); input.stringValue = value
            if let page = window.settingsRecoveryControllers.last as? AgentExtensionCreationPage { page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input)) }
            else if let page = window.settingsRecoveryControllers.compactMap({ $0 as? AgentRuleWindow }).last { page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input)) }
        }
        func body(_ window: ControlWindow, _ value: String, marker: String = "MARKER") throws {
            let label = window.settingsRecoveryControllers.contains(where: { $0 is AgentRuleWindow }) ? "规则正文" : "扩展说明"
            let text = try input(NSTextView.self, label, window); text.string = value
            if let rule = window.settingsRecoveryControllers.compactMap({ $0 as? AgentRuleWindow }).last { rule.textDidChange(Notification(name: NSText.didChangeNotification, object: text)) }
            if let extensionPage = window.settingsRecoveryControllers.compactMap({ $0 as? AgentExtensionWindow }).last { extensionPage.textDidChange(Notification(name: NSText.didChangeNotification, object: text)) }
            window.window?.contentView?.layoutSubtreeIfNeeded(); text.layoutManager?.ensureLayout(for: text.textContainer!)
            if let scroll = text.enclosingScrollView, let layout = text.layoutManager, let container = text.textContainer {
                text.setFrameSize(NSSize(width: text.frame.width, height: max(scroll.contentSize.height, layout.usedRect(for: container).maxY + text.textContainerInset.height * 2)))
            }
            window.window?.makeFirstResponder(text)
            let range = (value as NSString).range(of: marker); if range.location != NSNotFound { text.setSelectedRange(range); text.scrollRangeToVisible(range) }
        }
        func choosePopup(_ label: String, _ value: Int, _ window: ControlWindow) throws {
            let popup = try input(NSPopUpButton.self, label, window); popup.selectItem(at: value)
            if let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
        }
        func editor(_ title: String, _ taskID: String, category: String, key: String) throws -> ControlWindow {
            openTaskWindow(taskID, from: control)
            guard let child = additionalTaskWindows.last, child.showSettingsCategory(category) else { throw PetError("设置任务窗口未打开：" + title) }
            try child.checkSelectSettingsRecoveryPage(key); return child
        }
        func choose(_ title: String, _ action: () async -> Bool) async throws -> Bool {
            var pressed = false, expired = false
            let deadline = Date().addingTimeInterval(5)
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if let dialog = NSApp.modalWindow?.agentDialog,
                       let button = find(NSButton.self, dialog.view, { $0.title == title }) { pressed = true; timer.invalidate(); button.performClick(nil) }
                    else if Date() > deadline { expired = true; timer.invalidate(); NSApp.abortModal() }
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel); defer { timer.invalidate() }
            let result = await action(); guard pressed, !expired else { throw PetError("未找到退出保护选项：" + title) }; return result
        }
        let long = (0..<90).map { $0 == 74 ? "PUBLIC_SETTINGS_MARKER_582 中文😀" : "PUBLIC_SETTINGS_LINE_\($0) 中文😀" }.joined(separator: "\n") + "\n"
        let invalidSkill = "---\nname: invalid-unclosed\ndescription: retain whole draft\n" + long
        let invalidCommand = "---\nPUBLIC_COMMAND_UNCLOSED_491\n" + long
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("设置编辑恢复检查禁止模型请求") }
            let fixture: SettingsEditorFixture
            if stage == "seed" {
                guard !FileManager.default.fileExists(atPath: fixtureFile.path) else { throw PetError("此目录已有恢复记录，请重开而不是覆盖") }
                let alpha = output.appendingPathComponent("Alpha source"), beta = output.appendingPathComponent("Beta source")
                for path in [alpha, beta] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); try Data("PUBLIC_SETTINGS_SOURCE_718\n".utf8).write(to: path.appendingPathComponent("README.md")) }
                let userSkill = try tasks.extensions.create(.skill, name: "public-user-skill", text: "---\nname: public-user-skill\ndescription: public fixture\n---\n\nPUBLIC_USER_SKILL_286\n", project: false, workspace: nil)
                let command = try tasks.extensions.create(.command, name: "public-command", text: "---\ndescription: public command\n---\n\nPUBLIC_COMMAND_SOURCE_928\n", project: false, workspace: nil)
                guard let creationTask = control.agentTaskID, let initialTask = tasks.task(creationTask) else { throw PetError("初始设置所属任务不可用") }
                checks["initialSettingsHaveNoWorkspace"] = initialTask.workspace == nil && initialTask.workspaceScope == nil
                let emptyContext = AgentSettingsRecovery.Context(task: nil, workspace: nil)
                let decodedEmptyContext = try JSONDecoder().decode(AgentSettingsRecovery.Context.self, from: JSONEncoder().encode(emptyContext))
                checks["emptySettingsContextRemainsValidWithoutInventingATask"] = emptyContext.valid && decodedEmptyContext == emptyContext
                if !interactive {
                    let before = try tasks.hooks.document(project: false, workspace: nil).1
                    guard control.showSettingsCategory("hooks") else { throw PetError("退出保护检查未打开 Hooks 页") }
                    try click("编辑配置", control)
                    let body = try input(NSTextView.self, "Hooks JSON 配置", control)
                    let literal = #"{"hooks":{"Stop":[{"hooks":[{"type":"http","headers":{"Authorization":"PUBLIC_DUMMY_215"}}]}]}}"#
                    body.string = literal; body.didChangeText()
                    let flushed = await control.flushWorkspaceRecovery()
                    checks["unmaskedHookEditorIsNotMarkedAsPreserved"] = flushed && control.workspaceSession?.preservedEditors.isEmpty == true
                    checks["quitProtectsUnmaskedHooksWithoutWritingTheDraft"] = !(try await choose("继续编辑", { await self.control.prepareOwnedTaskPanels(preservingRecovery: true) })) && body.string == literal
                    checks["cancelQuitLeavesHookSourceExact"] = try tasks.hooks.document(project: false, workspace: nil).1 == before
                    checks["explicitDiscardReturnsFromUnmaskedHookEditor"] = try await choose("放弃", { self.control.showSettingsCategory("extensions") }) && tasks.hooks.document(project: false, workspace: nil).1 == before
                }
                guard control.showSettingsCategory("extensions") else { throw PetError("无任务设置未打开") }; try control.checkSelectSettingsRecoveryPage("skills")
                guard let parent = control.settingsRecoveryControllers.first as? AgentExtensionWindow,
                      let create = parent.creationMenu()?.items.first(where: { $0.identifier?.rawValue == "skill-create-manual" }), let action = create.action else { throw PetError("手动新建入口不可用") }
                NSApp.sendAction(action, to: create.target, from: create)
                try field("扩展名称", "PUBLIC_INVALID_NAME/😀", control)
                let name = try input(NSTextField.self, "扩展名称", control); control.window?.makeFirstResponder(name)
                (name.currentEditor() as? NSTextView)?.setSelectedRange((name.stringValue as NSString).range(of: "INVALID"))
                let multi = tasks.create(title: "设置恢复 · 双来源", workspace: beta.path), general = tasks.create(title: "设置恢复 · 无工作区", workMode: .general)
                tasks.update(multi) { $0.workspaceScope = .init(group: output.appendingPathComponent("Public group").path, folders: [alpha.path, beta.path], primary: beta.path); $0.draft = "PUBLIC_ORIGINAL_MULTI_DRAFT_594" }
                tasks.update(general) { $0.draft = "PUBLIC_ORIGINAL_GENERAL_DRAFT_386" }
                let alphaTask = try AgentWorkspaceScope.settingsTask(tasks.task(multi)!, workspace: alpha.path)
                let rule = try tasks.rules.create(name: "public-alpha-rule", text: "---\nname: public-alpha-rule\ntrigger: manual\n---\n\nPUBLIC_RULE_SOURCE_194\n", project: true, task: alphaTask)
                let skill = try tasks.extensions.create(.skill, name: "public-beta-skill", text: "---\nname: public-beta-skill\ndescription: public fixture\n---\n\nPUBLIC_BETA_SKILL_514\n", project: true, workspace: beta.path)
                let rules = try editor("项目规则", multi, category: "memory", key: "rules")
                let sources = try input(NSPopUpButton.self, "设置源文件夹", rules)
                guard let alphaItem = sources.itemArray.first(where: { $0.representedObject as? String == alpha.path }) else { throw PetError("原次源文件夹不可用") }
                sources.select(alphaItem); if let action = sources.action { NSApp.sendAction(action, to: sources.target, from: sources) }
                let ruleList = try input(NSTableView.self, "规则列表", rules)
                guard let openRule = ruleList.action else { throw PetError("恢复验收的原规则目录不可用") }
                NSApp.sendAction(openRule, to: ruleList.target, from: ruleList)
                try field("规则名称", "", rules); try choosePopup("规则触发方式", 3, rules); try field("规则匹配模式", "src/**/*.swift\n!vendor/**\n[", rules); try body(rules, long)
                let commands = try editor("用户命令", general, category: "extensions", key: "commands")
                guard let commandsPage = commands.settingsRecoveryControllers.first as? AgentExtensionWindow else { throw PetError("命令编辑器不可用") }; commandsPage.selectItem(command.id); try body(commands, invalidCommand)
                let newRule = try editor("新建用户规则", general, category: "memory", key: "rules")
                try click("新建规则", newRule); try choosePopup("规则触发方式", 2, newRule); try body(newRule, "PUBLIC_NEW_RULE_DRAFT_648\n" + long)
                let skills = try editor("项目技能", multi, category: "extensions", key: "skills")
                guard let skillsPage = skills.settingsRecoveryControllers.first as? AgentExtensionWindow else { throw PetError("技能编辑器不可用") }; skillsPage.selectItem(skill.id); try body(skills, invalidSkill)
                guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let rulesID = rules.workspaceSession?.id,
                      let commandsID = commands.workspaceSession?.id, let newRuleID = newRule.workspaceSession?.id, let skillsID = skills.workspaceSession?.id else { throw PetError("设置草稿未保存") }
                let sourcesMap = [rule.source.path, skill.file.path, command.file.path, userSkill.file.path, alpha.appendingPathComponent("README.md").path, beta.appendingPathComponent("README.md").path]
                fixture = .init(multi: multi, general: general, creationTask: creationTask, alpha: alpha.path, beta: beta.path, rule: rule.id, skill: skill.id, command: command.id,
                    windows: ["creation": mainID, "rule": rulesID, "command": commandsID, "newRule": newRuleID, "skill": skillsID],
                    sources: Dictionary(uniqueKeysWithValues: try sourcesMap.map { ($0, AgentFiles.hash(try Data(contentsOf: URL(fileURLWithPath: $0)))) }))
                try JSONEncoder().encode(fixture).write(to: fixtureFile, options: .atomic)
                checks["noWorkspaceCreationRetainsOriginalTaskAndUserScopeAfterOtherWindowsOpen"] = try control.captureSettingsRecovery()?.context.taskID == creationTask && control.captureSettingsRecovery()?.context.workspace == nil
                checks["secondaryRuleKeepsItsOwnOriginalFolder"] = try rules.captureSettingsRecovery()?.context.workspace == alpha.path
                checks["allFiveWindowsCheckpointTheirOwnSettings"] = taskControls.count == 5 && taskControls.allSatisfy { $0.workspaceSession?.preservedEditors.isEmpty == false }
            } else {
                fixture = try JSONDecoder().decode(SettingsEditorFixture.self, from: Data(contentsOf: fixtureFile))
                restoreAdditionalWorkspaceWindows(); guard await flushWorkspaceWindows() else { throw PetError("设置窗口恢复未结束") }
                guard let creation = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows["creation"] }),
                      let commands = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows["command"] }),
                      let newRule = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows["newRule"] }),
                      let rules = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows["rule"] }),
                      let skills = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows["skill"] }) else { throw PetError("原五个设置窗口未完整恢复") }
                if stage != "observe" {
                    creation.window?.makeKeyAndOrderFront(nil); creation.settingsRecoveryControllers.last?.settingsDidAppear(); await wait(0.08)
                    let name = try input(NSTextField.self, "扩展名称", creation), popup = try input(NSPopUpButton.self, "扩展范围", creation)
                    checks["noWorkspaceCreationNameAndScopeRestoreExactly"] = name.stringValue == "PUBLIC_INVALID_NAME/😀" && popup.indexOfSelectedItem == 0 && popup.item(at: 1)?.isEnabled == false
                    checks["noWorkspaceCreationRestoresUTF16SelectionAndFocus"] = (name.currentEditor() as? NSTextView)?.selectedRange() == (name.stringValue as NSString).range(of: "INVALID") && creation.window?.firstResponder === name.currentEditor()
                    let commandBody = try input(NSTextView.self, "扩展说明", commands)
                    checks["generalTaskRestoresWholeInvalidCommandDraft"] = commandBody.string == invalidCommand && commandBody.selectedRange() == (invalidCommand as NSString).range(of: "MARKER") && commands.window?.firstResponder === commandBody
                    let newRuleBody = try input(NSTextView.self, "规则正文", newRule)
                    checks["newUserRuleRetainsInvalidFieldsAndWholeBody"] = try input(NSTextField.self, "规则名称", newRule).stringValue == "" && input(NSPopUpButton.self, "规则触发方式", newRule).indexOfSelectedItem == 2 && newRuleBody.string == "PUBLIC_NEW_RULE_DRAFT_648\n" + long
                    if stage == "unavailable" {
                        checks["changedSourceScopeDoesNotRedirectEitherProjectEditor"] = rules.settingsRecoveryControllers.isEmpty && skills.settingsRecoveryControllers.isEmpty
                    } else {
                        let ruleBody = try input(NSTextView.self, "规则正文", rules), skillBody = try input(NSTextView.self, "扩展说明", skills)
                        checks["projectRuleRestoresBlankNameGlobAndCompleteDraft"] = try input(NSTextField.self, "规则名称", rules).stringValue == "" && input(NSTextField.self, "规则匹配模式", rules).stringValue == "src/**/*.swift\n!vendor/**\n[" && ruleBody.string == long
                        checks["projectSkillRestoresWholeInvalidDraft"] = skillBody.string == invalidSkill
                        checks["separateProjectWindowsRestoreOwnSelectionsAndFocus"] = [ruleBody, skillBody].allSatisfy { $0.selectedRange() == ($0.string as NSString).range(of: "MARKER") && $0.window?.firstResponder === $0 }
                        checks["projectSourceRemainsOriginalSecondaryFolder"] = try rules.captureSettingsRecovery()?.context.workspace == fixture.alpha && skills.captureSettingsRecovery()?.context.workspace == fixture.beta
                        if !interactive {
                            let original = try rules.settingsRecoveryControllers.compactMap { $0 as? AgentRuleWindow }.first!.captureSettingsRecovery()!
                            func rejected(_ label: String, change: (inout [String: Any]) -> Void) throws {
                                var object = try JSONSerialization.jsonObject(with: original.state) as! [String: Any]; change(&object)
                                do { try rules.settingsRecoveryControllers.compactMap { $0 as? AgentRuleWindow }.first!.restoreSettingsRecovery(.init(kind: "rules", state: JSONSerialization.data(withJSONObject: object))); checks[label] = false } catch { checks[label] = true }
                            }
                            try rejected("futureRuleDraftVersionRejected") { $0["version"] = 2 }
                            try rejected("unknownRuleDraftFieldRejected") { $0["future"] = true }
                            try rejected("wrongTaskRuleDraftRejected") { $0["taskID"] = UUID().uuidString }
                            try rejected("wrongSourceRuleDraftRejected") { $0["workspace"] = fixture.beta }
                            try rejected("wrongTextViewportHashRejected") { value in var view = value["viewport"] as! [String: Any], text = view["text"] as! [String: Any]; text["hash"] = String(repeating: "0", count: 64); view["text"] = text; value["viewport"] = view }
                            checks["rejectedDraftsLeaveCurrentRuleTextAndSelection"] = ruleBody.string == long && ruleBody.selectedRange() == (long as NSString).range(of: "MARKER")
                            var earlierRule = try JSONSerialization.jsonObject(with: original.state) as! [String: Any]
                            earlierRule.removeValue(forKey: "showsDetail"); earlierRule.removeValue(forKey: "catalogY")
                            let stackBefore = rules.settingsRecoveryControllers.map(ObjectIdentifier.init)
                            try rules.settingsRecoveryControllers.compactMap { $0 as? AgentRuleWindow }.first!.restoreSettingsRecovery(
                                .init(kind: "rules", state: JSONSerialization.data(withJSONObject: earlierRule)))
                            await wait(0.08)
                            checks["earlierRuleDraftKeepsEditorAndSelectionWithoutDuplicatingDetail"] = rules.settingsRecoveryControllers.map(ObjectIdentifier.init) == stackBefore && ruleBody.string == long && ruleBody.selectedRange() == (long as NSString).range(of: "MARKER")
                            let sourceRule = try tasks.rules.current(fixture.rule, task: AgentWorkspaceScope.settingsTask(tasks.task(fixture.multi)!, workspace: fixture.alpha), enabledOnly: false)
                            let sourceSkill = try tasks.extensions.item(fixture.skill, workspace: fixture.beta, enabled: false)
                            let oldRule = try Data(contentsOf: sourceRule.source), oldSkill = try Data(contentsOf: sourceSkill.file)
                            try click("保存", rules); checks["invalidRuleSaveKeepsSourceAndDraft"] = try Data(contentsOf: sourceRule.source) == oldRule && ruleBody.string == long
                            try click("保存", skills); checks["invalidSkillSaveKeepsSourceAndDraft"] = try Data(contentsOf: sourceSkill.file) == oldSkill && skillBody.string == invalidSkill
                            let savedSkill = "---\nname: public-beta-skill\ndescription: saved public recovery\n---\n\nPUBLIC_SAVED_SKILL_784 中文😀\n"
                            try body(skills, savedSkill, marker: "PUBLIC_SAVED")
                            let attributes = try FileManager.default.attributesOfItem(atPath: sourceSkill.file.path), permissions = attributes[.posixPermissions]!
                            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sourceSkill.file.path)
                            try click("保存", skills); checks["readOnlySkillSavePreservesPreviousBytesAndNewInput"] = try Data(contentsOf: sourceSkill.file) == oldSkill && skillBody.string == savedSkill
                            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: sourceSkill.file.path); try click("保存", skills)
                            checks["sameSkillDraftSavesAfterPermissionRestores"] = try String(contentsOf: sourceSkill.file, encoding: .utf8) == savedSkill
                            let external = "---\nname: public-alpha-rule\ntrigger: manual\n---\n\nPUBLIC_EXTERNAL_RULE_UPDATE_814\n"
                            try Data(external.utf8).write(to: sourceRule.source)
                            try field("规则名称", "public-alpha-rule", rules); try choosePopup("规则触发方式", 1, rules); try field("规则匹配模式", "", rules); try click("保存", rules)
                            checks["staleRuleSaveDoesNotOverwriteExternalRevision"] = try String(contentsOf: sourceRule.source, encoding: .utf8) == external && ruleBody.string == long
                            guard let form = creation.settingsRecoveryControllers.last as? AgentExtensionCreationPage else { throw PetError("原新建表单未恢复") }
                            form.submit(); checks["invalidCreationDoesNotWriteAnySkill"] = try tasks.extensions.catalog(workspace: nil).allSatisfy { $0.name != "PUBLIC_INVALID_NAME/😀" }
                            try field("扩展名称", "public-created-skill", creation); form.submit()
                            checks["noWorkspaceCreationSavesOnlyIntoOriginalUserScope"] = try tasks.extensions.catalog(workspace: nil).contains { $0.name == "public-created-skill" && $0.scope == "全局" } && !tasks.extensions.catalog(workspace: fixture.beta).contains { $0.name == "public-created-skill" && $0.scope != "全局" }
                            try field("规则名称", "public-created-rule", newRule); try choosePopup("规则触发方式", 1, newRule); try body(newRule, "PUBLIC_CREATED_USER_RULE_747\n", marker: "PUBLIC_CREATED"); try click("保存", newRule)
                            checks["newRuleSavesOnlyIntoOriginalUserScope"] = try tasks.rules.catalog(workspace: nil, directories: []).contains { $0.name == "public-created-rule" && !$0.project }
                            guard await flushWorkspaceWindows(), let windowID = commands.workspaceSession?.id else { throw PetError("命令窗口未保存") }
                            let layout = store.directory.appendingPathComponent("workspace-recovery/" + windowID + "/layout.json"), previous = try Data(contentsOf: layout)
                            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: layout.path); try body(commands, invalidCommand + "LAST_EDIT_PUBLIC_842\n")
                            checks["readOnlyJournalRejectsCheckpointWithoutDroppingLastEdit"] = !(await commands.flushWorkspaceRecovery()) && commandBody.string.hasSuffix("LAST_EDIT_PUBLIC_842\n")
                            checks["failedJournalLeavesPreviousRecordBytesExact"] = try Data(contentsOf: layout) == previous
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.path)
                            checks["lastEditRetriesAfterJournalPermissionRestores"] = await commands.flushWorkspaceRecovery()
                        }
                    }
                }
                checks["allSourceReadmesRemainExact"] = try [fixture.alpha, fixture.beta].allSatisfy { try String(contentsOf: URL(fileURLWithPath: $0).appendingPathComponent("README.md"), encoding: .utf8) == "PUBLIC_SETTINGS_SOURCE_718\n" }
            }
            checks["originalTaskComposerInputsRemainExact"] = tasks.task(fixture.multi)?.draft == "PUBLIC_ORIGINAL_MULTI_DRAFT_594" && tasks.task(fixture.general)?.draft == "PUBLIC_ORIGINAL_GENERAL_DRAFT_386"
            checks["allCurrentRecoveryStatesCheckpoint"] = await flushWorkspaceWindows()
            checks["noModelRequests"] = requests == 0
            if interactive {
                let focus = CommandLine.arguments.firstIndex(of: "--editor-focus").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "creation"
                taskControls.first(where: { $0.workspaceSession?.id == fixture.windows[focus] })?.window?.makeKeyAndOrderFront(nil)
            }
            report["fixture"] = fixtureFile.path; report["windows"] = fixture.windows
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["stage"] = stage; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "settings-editor-ui-ready.json" : "settings-editor-report.json"))
    }
}
