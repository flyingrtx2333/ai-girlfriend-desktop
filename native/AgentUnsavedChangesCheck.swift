import AppKit

@MainActor extension AppDelegate {
    func prepareUnsavedChangesUI(_ output: URL, seed: Bool) async throws {
        guard !CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--attention-live-ui") else { throw PetError("未保存确认验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务系统不可用") }
        if seed {
            let id = try await prepareSettingsPagesCheck(output, tasks: tasks)
            tasks.update(id) { $0.draft = "保留未保存确认验收输入" }
        }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("settings-fixtures.json"))) as? [String: Any]
        guard let id = value?["taskID"] as? String, tasks.task(id) != nil else { throw PetError("未找到原确认验收任务") }
        control.showAgentTask(id)
    }

    func runUnsavedChangesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], dialogs: [[String: Any]] = [], requests = 0
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let pane = AgentSettingsPageHost(); host.contentView = pane; host.isReleasedWhenClosed = false
        defer { pane.finish(); host.close(); agentRuntime?.stopAll() }
        func find<T: NSView>(_ type: T.Type, in view: NSView?, matching predicate: (T) -> Bool) -> T? {
            guard let view else { return nil }; if let value = view as? T, predicate(value) { return value }
            for child in view.subviews { if let value = find(type, in: child, matching: predicate) { return value } }; return nil
        }
        func control<T: NSView>(_ type: T.Type, _ label: String, _ page: AgentSettingsPageController) throws -> T {
            guard let value = find(type, in: page.pageContentView, matching: { $0.accessibilityLabel() == label }) else { throw PetError("缺少确认验收控件：" + label) }; return value
        }
        func button(_ title: String, _ page: AgentSettingsPageController) throws -> NSButton {
            guard let value = find(NSButton.self, in: page.pageContentView, matching: { $0.title == title && $0.isEnabled }) else { throw PetError("缺少确认验收操作：" + title) }; return value
        }
        func choose(_ title: String, _ action: () -> Bool) throws -> Bool {
            var clicked = false, expired = false
            let deadline = Date().addingTimeInterval(5)
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard !clicked else { return }
                    if let window = NSApp.modalWindow, let button = find(NSButton.self, in: window.contentView, matching: { $0.title == title }) {
                        clicked = true
                        var titles: [String] = []
                        func collect(_ view: NSView) { if let button = view as? NSButton, !button.title.isEmpty { titles.append(button.title) }; view.subviews.forEach(collect) }
                        if let view = window.contentView { collect(view) }
                        let scroll = find(NSScrollView.self, in: window.contentView, matching: { $0.documentView is NSTextView }), text = scroll?.documentView as? NSTextView
                        dialogs.append(["choice": title, "buttons": titles, "styled": window.contentView is AgentThemeView, "default": window.defaultButtonCell?.title ?? "", "ambiguous": window.contentView?.hasAmbiguousLayout == true, "width": window.frame.width, "height": window.frame.height, "detail": text?.string ?? "", "detailHeight": scroll?.bounds.height ?? 0, "documentHeight": text?.bounds.height ?? 0, "detailFits": scroll.map { window.contentView!.bounds.contains($0.convert($0.bounds, to: window.contentView)) } ?? true])
                        button.performClick(nil)
                    } else if Date() >= deadline { expired = true; timer.invalidate(); NSApp.abortModal() }
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            let result = action()
            guard clicked, !expired else { throw PetError("未找到确认选项：" + title) }; return result
        }
        func show(_ page: AgentSettingsPageController, _ key: String) throws {
            guard pane.show(category: key, identity: key, scope: "确认验收", make: { _ in page }) else { throw PetError("无法进入确认验收页面") }
            host.makeKeyAndOrderFront(nil)
        }
        do {
            try await prepareUnsavedChangesUI(output, seed: true)
            guard let tasks = agentStore, let runtime = agentRuntime, let id = tasks.selectedID else { throw PetError("缺少确认验收任务") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("未保存确认验收禁止模型请求") }
            checks["isolatedProfileAndModelBlock"] = usesAgent && tasks.extensions.sharedHome?.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").resolvingSymlinksInPath()
            let form = AgentExtensionCreationPage(service: tasks.extensions, kind: .skill, workspace: tasks.task(id)?.workspace)
            try show(form, "skill")
            let name = try control(NSTextField.self, "扩展名称", form), originalCatalog = try tasks.extensions.catalog(workspace: tasks.task(id)?.workspace).map(\.id)
            name.stringValue = "保留尚未创建的 Skill"; form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
            checks["continueRetainsHostedFormAndInput"] = try !choose("继续编辑", { pane.leave() }) && pane.currentController === form && name.stringValue == "保留尚未创建的 Skill"
            checks["continueDoesNotCreateExtension"] = try tasks.extensions.catalog(workspace: tasks.task(id)?.workspace).map(\.id) == originalCatalog
            checks["discardLeavesFormWithoutCreatingExtension"] = try choose("放弃更改", { pane.leave() }) && pane.currentController == nil && tasks.extensions.catalog(workspace: tasks.task(id)?.workspace).map(\.id) == originalCatalog
            let parent = AgentExtensionWindow(store: tasks, taskID: id); parent.prepareSettings(kind: .skill); try show(parent, "skill-parent")
            try button("新建", parent).performClick(nil)
            guard let child = pane.currentController as? AgentExtensionCreationPage,
                  let back = find(NSButton.self, in: pane, matching: { $0.title.hasPrefix("返回 ") && !$0.isHidden }) else { throw PetError("缺少实际扩展创建返回入口") }
            let childName = try control(NSTextField.self, "扩展名称", child); childName.stringValue = "保留返回焦点检查"; child.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: childName))
            checks["discardChildReturnsKeyboardToParentList"] = try choose("放弃更改", { back.performClick(nil); return pane.currentController === parent }) && host.firstResponder === control(NSTableView.self, "扩展列表", parent) && tasks.extensions.catalog(workspace: tasks.task(id)?.workspace).map(\.id) == originalCatalog
            guard pane.leave() else { throw PetError("扩展返回检查未能结束") }
            let mcp = AgentMCPWindow(service: tasks.mcp, workspace: tasks.task(id)?.workspace)
            try show(mcp, "mcp")
            let add = try control(NSPopUpButton.self, "新建 MCP 连接器", mcp)
            guard let item = add.menu?.items.first(where: { ($0.representedObject as? String) == "stdio" }), let action = item.action else { throw PetError("缺少本机连接器草稿入口") }
            NSApp.sendAction(action, to: item.target, from: item)
            let editor = try control(NSTextView.self, "MCP 配置 JSON", mcp), draft = editor.string, config = tasks.extensions.profile.appendingPathComponent("extensions/mcp.json"), originalConfig = try Data(contentsOf: config)
            checks["reversedLegacyButtonsContinuePreservesMCPDraft"] = try !choose("继续编辑", { pane.leave() }) && pane.currentController === mcp && editor.string == draft && Data(contentsOf: config) == originalConfig
            checks["reversedLegacyButtonsDiscardLeavesWithoutSaving"] = try choose("放弃", { pane.leave() }) && pane.currentController == nil && Data(contentsOf: config) == originalConfig
            let rules = AgentRuleWindow(store: tasks, taskID: id)
            try show(rules, "rules"); try button("新建规则", rules).performClick(nil)
            let ruleName = try control(NSTextField.self, "规则名称", rules), body = try control(NSTextView.self, "规则正文", rules)
            ruleName.stringValue = ""; body.string = "公开的未保存规则正文"; rules.textDidChange(Notification(name: NSText.didChangeNotification, object: body))
            let beforeRules = try tasks.rules.catalog(workspace: tasks.task(id)?.workspace).map(\.id)
            checks["saveFailureKeepsRulePageAndOriginalFiles"] = try !choose("保存", { pane.leave() }) && pane.currentController === rules && body.string == "公开的未保存规则正文" && tasks.rules.catalog(workspace: tasks.task(id)?.workspace).map(\.id) == beforeRules
            ruleName.stringValue = "unsaved-confirm-rule"; rules.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: ruleName))
            checks["saveChoiceUsesOriginalRuleServiceAndLeaves"] = try choose("保存", { pane.leave() }) && pane.currentController == nil && tasks.rules.catalog(workspace: tasks.task(id)?.workspace).contains { $0.name == "unsaved-confirm-rule" && $0.definition?.body == "公开的未保存规则正文" }
            let existing = AgentRuleWindow(store: tasks, taskID: id); try show(existing, "existing-rule")
            let oldBody = try control(NSTextView.self, "规则正文", existing), savedBody = oldBody.string, selectedName = try control(NSTextField.self, "规则名称", existing).stringValue
            guard let source = try tasks.rules.catalog(workspace: tasks.task(id)?.workspace).first(where: { $0.name == selectedName })?.source else { throw PetError("缺少规则源文件") }
            let bytes = try Data(contentsOf: source); oldBody.string = "保留修改后未保存的规则"; existing.textDidChange(Notification(name: NSText.didChangeNotification, object: oldBody))
            checks["threeChoiceContinuePreservesActualRuleDraft"] = try !choose("继续编辑", { pane.leave() }) && oldBody.string == "保留修改后未保存的规则" && Data(contentsOf: source) == bytes
            checks["threeChoiceDiscardRestoresSavedRuleWithoutWriting"] = try choose("放弃更改", { pane.leave() }) && oldBody.string == savedBody && Data(contentsOf: source) == bytes
            let filenames = (1...80).map { "公开文件-\($0)-未保存的办公内容.docx" }.joined(separator: "\n")
            let longResult = try choose("继续编辑", { AgentUnsavedChanges.discard("仍有未保存的办公文档", detail: filenames, discardTitle: "放弃更改并退出") })
            let longDialog = dialogs.last ?? [:]
            checks["longFileListRemainsCompleteAndScrollable"] = longDialog["detail"] as? String == filenames && (longDialog["detailHeight"] as? CGFloat ?? 0) <= 160 && (longDialog["documentHeight"] as? CGFloat ?? 0) > 160 && longDialog["detailFits"] as? Bool == true && (longDialog["height"] as? CGFloat ?? 1000) < host.frame.height
            checks["longFileListContinueUsesSafeDefault"] = !longResult && longDialog["default"] as? String == "继续编辑"
            checks["originalConversationDraftAndReceiptsPreserved"] = requests == 0 && tasks.task(id)?.draft == "保留未保存确认验收输入" && tasks.task(id)?.modelReceipts?.isEmpty != false
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["dialogs"] = dialogs; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("unsaved-changes-report.json"))
    }
}
