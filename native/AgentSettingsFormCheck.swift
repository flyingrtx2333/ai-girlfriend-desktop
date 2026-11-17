import AppKit

@MainActor enum AgentSettingsFormCheck {
    private static func find<T: NSView>(_ type: T.Type, in view: NSView?, matching: (T) -> Bool) -> T? {
        guard let view else { return nil }
        if let value = view as? T, matching(value) { return value }
        for child in view.subviews { if let value = find(type, in: child, matching: matching) { return value } }
        return nil
    }
    private static func field(_ label: String, in page: AgentSettingsPageController) throws -> NSTextField {
        guard let value = find(NSTextField.self, in: page.pageContentView, matching: { $0.accessibilityLabel() == label }) else { throw PetError("缺少字段：" + label) }; return value
    }
    private static func menu(_ label: String, in page: AgentSettingsPageController) throws -> NSPopUpButton {
        guard let value = find(NSPopUpButton.self, in: page.pageContentView, matching: { $0.accessibilityLabel() == label }) else { throw PetError("缺少选项：" + label) }; return value
    }
    private static func edit(_ label: String, _ text: String, in page: AgentSettingsPageController) throws {
        let value = try field(label, in: page); value.stringValue = text
        value.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: value))
    }
    private static func press(_ title: String, in page: AgentSettingsPageController) throws {
        guard let value = find(NSButton.self, in: page.pageContentView, matching: { $0.title == title && $0.isEnabled }) else { throw PetError("缺少可用按钮：" + title) }; value.performClick(nil)
    }
    private static func text(_ view: NSView?) -> String {
        guard let view else { return "" }
        return (view as? NSTextField)?.stringValue ?? (view as? NSTextView)?.string ?? view.subviews.map { text($0) }.joined(separator: "\n")
    }
    static func run(tasks: AgentStore, taskID: String, pane: AgentSettingsPageHost, host: NSWindow) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let workspace = tasks.task(taskID)?.workspace
        let visibleWindows = NSApp.windows.filter(\.isVisible).count
        func headerActions(_ page: AgentSettingsFormPage, submit title: String) throws -> Bool {
            guard let root = page.pageContentView,
                  let submit = find(NSButton.self, in: root, matching: { $0.title == title }),
                  let cancel = find(NSButton.self, in: root, matching: { $0.title == "取消" }) else { return false }
            let destination = NSStackView(), original = submit.superview
            page.setSettingsActionsHost(destination); page.setSettingsActionsHost(destination)
            let attached = destination.arrangedSubviews.count == 2 && submit.superview === destination && cancel.superview === destination && submit.target === page && cancel.target === page && submit.keyEquivalent == "s" && submit.keyEquivalentModifierMask.contains(.command)
            submit.performClick(nil)
            let rejected = pane.currentController === page && find(AgentSettingsStatusField.self, in: root, matching: { !$0.stringValue.isEmpty }) != nil
            page.setSettingsActionsHost(nil); page.setSettingsActionsHost(nil)
            return attached && rejected && destination.arrangedSubviews.isEmpty && submit.superview === original && cancel.superview === original
        }
        func layout(_ page: AgentSettingsPageController, fields: [String]) throws -> Bool {
            var fits = true
            for size in [NSSize(width: 680, height: 420), NSSize(width: 360, height: 360)] {
                host.setContentSize(size); pane.layoutSubtreeIfNeeded()
                for label in fields {
                    let input: NSView = try find(NSView.self, in: page.pageContentView, matching: { $0.accessibilityLabel() == label }) ?? { throw PetError("缺少布局字段：" + label) }()
                    fits = fits && !input.hasAmbiguousLayout && host.contentView!.bounds.contains(input.convert(input.bounds, to: host.contentView))
                }
            }
            host.setContentSize(NSSize(width: 800, height: 540)); return fits
        }
        for kind in [AgentExtensionKind.skill, .command] {
            let key = kind == .skill ? "skill" : "command", manager = AgentExtensionWindow(store: tasks, taskID: taskID); manager.prepareSettings(kind: kind)
            guard pane.show(category: key, identity: key + "-creation", scope: "设置项目", make: { _ in manager }) else { throw PetError("无法进入扩展创建检查") }
            let before = try tasks.extensions.catalog(workspace: workspace).filter { $0.kind == kind }
            pane.layoutSubtreeIfNeeded()
            if let list = find(AgentSettingsCatalogTable.self, in: manager.pageContentView, matching: { _ in true }) {
                let cells = (0..<list.numberOfRows).compactMap { list.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView }
                let names = cells.compactMap { $0.textField?.stringValue }
                let sources = cells.compactMap { find(NSTextField.self, in: $0, matching: { $0.identifier?.rawValue == "settings-catalog-group" })?.stringValue }
                checks[key + "GroupedCatalogKeepsStoredEntriesSourcesAndOriginalFirstSelection"] = list.numberOfRows == before.count && names.sorted() == before.map(\.name).sorted() && sources.sorted() == Set(before.map(\.scope)).sorted() && list.selectedRow == 0 && names.first == before.first?.name
            } else { checks[key + "GroupedCatalogKeepsStoredEntriesSourcesAndOriginalFirstSelection"] = false }
            try press("新建", in: manager)
            guard let page = pane.currentController as? AgentExtensionCreationPage else { throw PetError("新建扩展未进入设置子页") }
            checks[key + "CreationHostedWithoutModal"] = page.presentingWindow === host && page.window?.isVisible == false && host.attachedSheet == nil
            checks[key + "CreationNormalAndNarrowLayout"] = try layout(page, fields: ["扩展名称", "扩展范围"])
            checks[key + "HeaderActionsKeepOriginalDispatchAndReturn"] = try headerActions(page, submit: "创建") && tasks.extensions.catalog(workspace: workspace).filter { $0.kind == kind }.map(\.id) == before.map(\.id)
            try edit("扩展名称", kind == .skill ? "settings-skill" : "settings-command", in: page); try press("创建", in: page)
            checks[key + "DuplicateKeepsFormAndOriginalFile"] = try pane.currentController === page && text(page.pageContentView).contains("同名扩展已存在") && tasks.extensions.catalog(workspace: workspace).filter { $0.kind == kind }.map(\.id) == before.map(\.id)
            let name = kind == .skill ? "inline-settings-skill" : "inline:settings-command"
            try edit("扩展名称", name, in: page)
            let scope = try menu("扩展范围", in: page); scope.selectItem(at: kind == .skill ? 0 : 1)
            try press("创建", in: page)
            let created = try tasks.extensions.catalog(workspace: workspace).first { $0.kind == kind && $0.name == name }
            let actual = try created.map { try tasks.extensions.document($0).0 }
            let expected = kind == .skill ? tasks.extensions.profile.appendingPathComponent("extensions/skills/" + name + "/SKILL.md") : URL(fileURLWithPath: workspace!).appendingPathComponent(".bluefatfish/commands/" + name.replacingOccurrences(of: ":", with: "/") + ".md")
            checks[key + "CreationWritesRequestedScope"] = created?.file.standardizedFileURL == expected.standardizedFileURL && FileManager.default.fileExists(atPath: expected.path)
            guard let editor = pane.currentController as? AgentSettingsDetailPage else { throw PetError("扩展创建后未进入配置页") }
            checks[key + "CreationReturnsToActualEditor"] = editor.presentingWindow === host && find(NSTextView.self, in: editor.pageContentView, matching: { $0.accessibilityLabel() == "扩展说明" })?.string == actual && host.firstResponder is NSTextView
            editor.close()
            try press("新建", in: manager)
            guard let cancelled = pane.currentController as? AgentExtensionCreationPage else { throw PetError("缺少取消创建页") }
            let afterCreate = try tasks.extensions.catalog(workspace: workspace).map(\.id); try press("取消", in: cancelled)
            checks[key + "CancelReturnsWithoutCreatingFile"] = try pane.currentController === manager && tasks.extensions.catalog(workspace: workspace).map(\.id) == afterCreate
            guard let created, let actual else { throw PetError("缺少扩展保存保护原件") }
            let fm = FileManager.default, originalData = try Data(contentsOf: expected), oldHash = AgentFiles.hash(originalData)
            let originalMode = (try fm.attributesOfItem(atPath: expected.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            defer { try? fm.setAttributes([.posixPermissions: originalMode], ofItemAtPath: expected.path) }
            let changedText = actual + "\n公开的权限保护验收。\n"
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: expected.path)
            var denied = false
            do { _ = try tasks.extensions.save(created, text: changedText, expectedHash: oldHash, workspace: workspace) }
            catch { denied = error.localizedDescription.contains("只读") }
            checks[key + "ReadOnlySaveKeepsOriginalBytesAndMode"] = try denied && Data(contentsOf: expected) == originalData && (fm.attributesOfItem(atPath: expected.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400
            try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: expected.path)
            let saved = try tasks.extensions.save(created, text: changedText, expectedHash: oldHash, workspace: workspace), changedData = Data(changedText.utf8)
            checks[key + "WritableSaveKeepsExactBodyAndOriginalMode"] = try Data(contentsOf: expected) == changedData && (fm.attributesOfItem(atPath: expected.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640
            var stale = false
            do { _ = try tasks.extensions.save(saved, text: actual, expectedHash: oldHash, workspace: workspace) } catch { stale = true }
            checks[key + "StaleSaveKeepsCurrentBytesAndMode"] = try stale && Data(contentsOf: expected) == changedData && (fm.attributesOfItem(atPath: expected.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640
        }
        let noProject = AgentExtensionCreationPage(service: tasks.extensions, kind: .skill, workspace: nil)
        checks["CreationWithoutWorkspaceDisablesProjectScope"] = try menu("扩展范围", in: noProject).item(at: 1)?.isEnabled == false
        let manager = AgentProfileWindow(store: tasks, workspace: workspace)
        guard pane.show(category: "agents", identity: "inline-agent-forms", scope: "设置项目", make: { _ in manager }), let role = try tasks.agents.list(workspace: workspace).first(where: { $0.name == "设置审阅员" }), let connector = tasks.mcp.availableServers(workspace: workspace).first else { throw PetError("缺少智能体配置检查资料") }
        manager.selectProfile(role.id)
        guard let profile = pane.currentController as? AgentSettingsDetailPage else { throw PetError("智能体未进入配置页") }
        let selection = NSMenuItem(); selection.representedObject = connector.id
        NSApp.sendAction(NSSelectorFromString("toggleMCP:"), to: manager, from: selection)
        for (title, value) in [("只读项目", NSControl.StateValue.off), ("允许联网与外部连接", .on)] {
            guard let button = find(NSButton.self, in: profile.pageContentView, matching: { $0.title == title }) else { throw PetError("缺少权限选项") }
            button.state = value; NSApp.sendAction(button.action!, to: button.target, from: button)
        }
        let beforeRule = try tasks.agents.document().1
        NSApp.sendAction(NSSelectorFromString("addMCPRule"), to: manager, from: nil)
        guard let page = pane.currentController as? AgentMCPToolRulePage else { throw PetError("MCP 规则未进入设置子页") }
        checks["MCPRuleHostedWithoutModal"] = page.presentingWindow === host && page.window?.isVisible == false && host.attachedSheet == nil
        checks["MCPRuleNormalAndNarrowLayout"] = try layout(page, fields: ["MCP 连接器", "MCP 工具名", "MCP 工具权限"])
        checks["MCPRuleHeaderActionsKeepOriginalDispatchAndReturn"] = try headerActions(page, submit: "应用") && tasks.agents.document().1 == beforeRule
        try press("应用", in: page)
        checks["MCPRuleEmptyInputKeepsForm"] = try pane.currentController === page && text(page.pageContentView).contains("请输入有效的实际工具名") && tasks.agents.document().1 == beforeRule
        try edit("MCP 工具名", String(repeating: "x", count: 129), in: page); try press("应用", in: page)
        checks["MCPRuleOversizedInputKeepsDraft"] = try pane.currentController === page && field("MCP 工具名", in: page).stringValue.count == 129
        try edit("MCP 工具名", "echo", in: page); try menu("MCP 工具权限", in: page).selectItem(at: AgentToolPermission.allCases.firstIndex(of: .deny)!)
        try press("应用", in: page)
        checks["MCPRuleReturnsToUnsavedParent"] = try pane.currentController === profile && tasks.agents.document().1 == beforeRule
        checks["MCPRulePreservesParentFieldsAndFocus"] = try field("Agent 名称", in: profile).stringValue == role.name && text(profile.pageContentView).contains(role.instructions) && host.firstResponder === menu("Agent MCP", in: profile)
        try press("保存", in: profile)
        let saved = try tasks.agents.list(workspace: workspace).first { $0.id == role.id }
        checks["MCPRuleParentSavePersistsExactRule"] = saved?.mcpToolPermissions == [AgentMCPToolPermission(serverID: connector.id, tool: "echo", permission: .deny)] && saved?.readOnly == false && saved?.network == true
        let beforeTemplate = try tasks.agents.document().1, template = AgentTemplates.profiles[0], item = NSMenuItem(); item.tag = 0
        NSApp.sendAction(NSSelectorFromString("useTemplate:"), to: manager, from: item)
        checks["TemplateOpensEditableParentWithoutModal"] = try pane.currentController === profile && host.attachedSheet == nil && field("Agent 名称", in: profile).stringValue == template.name && text(profile.pageContentView).contains(template.instructions)
        checks["TemplateRemainsUnsavedUntilSave"] = try tasks.agents.document().1 == beforeTemplate
        try press("保存", in: profile)
        checks["TemplateSavePersistsOriginalInstructions"] = try tasks.agents.list(workspace: workspace).contains { $0.name == template.name && $0.instructions == template.instructions }
        checks["InlineFormsCreateNoVisibleManagementWindows"] = NSApp.windows.filter(\.isVisible).count == visibleWindows
        checks["InlineFormsLeaveNormallyAfterSave"] = pane.leave()
        let draftManager = AgentProfileWindow(store: tasks, workspace: workspace)
        guard pane.show(category: "agents", identity: "already-hosted-agent-draft", scope: "设置项目", make: { _ in draftManager }) else { throw PetError("无法进入已有 Agent 草稿检查") }
        let profileBefore = try tasks.agents.document().1
        let draft = AgentProfileDraft(taskID: taskID, callID: "public-hosted-draft", profile: AgentProfile(name: "页内草稿核对员", description: "核对公开文档", instructions: "完整保留的公开草稿指令。"))
        try draftManager.configureDraft(draft)
        guard let draftPage = pane.currentController as? AgentSettingsDetailPage else { throw PetError("已有草稿未直接进入配置页") }
        let draftName = try field("Agent 名称", in: draftPage)
        checks["AlreadyHostedAgentDraftOpensActualFullWidthEditor"] = try draftPage.presentingWindow === host && draftName.stringValue == draft.profile.name && text(draftPage.pageContentView).contains(draft.profile.instructions) && tasks.agents.document().1 == profileBefore
        try edit("Agent 名称", "页内草稿核对员修改", in: draftPage); try draftManager.configureDraft(draft)
        checks["ReopeningSameAgentDraftKeepsUnsavedInput"] = pane.currentController === draftPage && draftName.stringValue == "页内草稿核对员修改"
        try press("保存", in: draftPage)
        let savedDraft = try tasks.agents.list(workspace: workspace).first { $0.id == draft.profile.id }
        checks["HostedDraftSavePreservesInstructionsAndDisabledPermissions"] = savedDraft?.name == "页内草稿核对员修改" && savedDraft?.instructions == draft.profile.instructions && savedDraft?.enabled == false && savedDraft?.readOnly == true && savedDraft?.network == false
        checks["HostedDraftLeavesNormallyAfterSave"] = pane.leave()
        let emptyRoot = tasks.directory.appendingPathComponent("empty-catalog"), home = emptyRoot.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let emptyStore = AgentStore(directory: emptyRoot.appendingPathComponent("profile"), legacy: [], extensionHome: home), emptyTask = emptyStore.create(title: "空列表验收")
        let emptySkill = AgentExtensionWindow(store: emptyStore, taskID: emptyTask); emptySkill.prepareSettings(kind: .skill)
        let emptyCommand = AgentExtensionWindow(store: emptyStore, taskID: emptyTask); emptyCommand.prepareSettings(kind: .command)
        let emptyManagers: [(String, AgentSettingsPageController)] = [("agents", AgentProfileWindow(store: emptyStore, workspace: nil)), ("teams", AgentTeamWindow(store: emptyStore, workspace: nil)), ("skills", emptySkill), ("commands", emptyCommand), ("plugins", AgentPluginWindow(store: emptyStore, workspace: nil))]
        for (key, manager) in emptyManagers {
            guard pane.show(category: key, identity: "empty-" + key, scope: "用户设置", make: { _ in manager }) else { throw PetError("无法进入空列表：" + key) }
            pane.layoutSubtreeIfNeeded()
            let table = find(AgentSettingsCatalogTable.self, in: manager.pageContentView, matching: { _ in true }), empty = find(NSTextField.self, in: manager.pageContentView, matching: { $0.identifier?.rawValue == "settings-list-empty" })
            checks[key + "EmptyCatalogShowsMessageAndCreationWithoutEditor"] = table?.numberOfRows == 0 && empty?.isHidden == false && !(empty?.stringValue.isEmpty ?? true) && pane.currentController === manager && manager.isPageVisible
            for width in [CGFloat(800), CGFloat(528)] {
                host.setContentSize(NSSize(width: width, height: 540)); pane.layoutSubtreeIfNeeded()
                let root = manager.pageContentView
                let actions = find(NSStackView.self, in: root, matching: { $0.identifier?.rawValue == "settings-catalog-actions" })
                let filters = find(NSStackView.self, in: root, matching: { $0.identifier?.rawValue == "settings-catalog-filters" })
                let card = find(AgentSettingsCatalogEmptyView.self, in: root, matching: { _ in true })
                if let root, let actions, let filters, let card {
                    let actionRect = actions.convert(actions.bounds, to: root), filterRect = filters.convert(filters.bounds, to: root), cardRect = card.convert(card.bounds, to: root)
                    checks[key + "CreationFiltersAndEmptyCardFitAtWidth" + String(Int(width))] = !actions.arrangedSubviews.isEmpty && !actions.hasAmbiguousLayout && root.bounds.contains(actionRect) && root.bounds.contains(cardRect) && !actionRect.intersects(cardRect) && (filters.isHidden || (!actionRect.intersects(filterRect) && !filterRect.intersects(cardRect))) && !card.isHidden
                } else { checks[key + "CreationFiltersAndEmptyCardFitAtWidth" + String(Int(width))] = false }
            }
            host.setContentSize(NSSize(width: 800, height: 540))
            if ["skills", "commands"].contains(key) {
                for width in [CGFloat(800), CGFloat(528)] {
                    host.setContentSize(NSSize(width: width, height: 540)); pane.layoutSubtreeIfNeeded()
                    let search = find(NSSearchField.self, in: manager.pageContentView, matching: { _ in true })
                    checks[key + "SearchRemainsWritableAtWidth" + String(Int(width))] = search.map { field in
                        guard let root = manager.pageContentView else { return false }
                        return field.bounds.width >= 120 && !field.hasAmbiguousLayout && root.bounds.contains(field.convert(field.bounds, to: root))
                    } ?? false
                    if let search {
                        search.stringValue = "no-matching-public-extension"
                        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
                        pane.layoutSubtreeIfNeeded()
                        let message = find(NSTextField.self, in: manager.pageContentView, matching: { $0.identifier?.rawValue == "settings-list-empty" })
                        checks[key + "LongEmptyMessageFitsAtWidth" + String(Int(width))] = message.map { label in
                            guard let root = manager.pageContentView else { return false }
                            return !label.isHidden && label.stringValue == "未找到匹配项" && label.bounds.width >= label.intrinsicContentSize.width && root.bounds.contains(label.convert(label.bounds, to: root))
                        } ?? false
                        search.stringValue = ""
                        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
                    }
                }
                host.setContentSize(NSSize(width: 800, height: 540))
                try press("新建", in: manager)
                guard let creation = pane.currentController as? AgentExtensionCreationPage else { throw PetError("无工作区新建未进入原表单") }
                let scope = try menu("扩展范围", in: creation); scope.menu?.update()
                checks[key + "NoWorkspaceCreationKeepsProjectDisabledAfterMenuUpdate"] = scope.indexOfSelectedItem == 0 && scope.menu?.autoenablesItems == false && scope.item(at: 1)?.isEnabled == false
                try press("取消", in: creation)
                checks[key + "CancelCreationKeepsSameEmptyCatalog"] = pane.currentController === manager && find(AgentSettingsCatalogTable.self, in: manager.pageContentView, matching: { _ in true })?.numberOfRows == 0
            }
            guard pane.leave() else { throw PetError("空列表未正常退出：" + key) }
        }
        return checks
    }
}
