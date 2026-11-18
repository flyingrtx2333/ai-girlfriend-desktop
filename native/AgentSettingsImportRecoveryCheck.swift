import AppKit

@MainActor extension AppDelegate {
    private struct ImportFixture: Codable {
        var task: String, primary: String, secondary: String
        var pluginWindow: String, hookWindow: String, userHash: String?, projectHash: String?
    }

    func runSettingsImportRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let fixtureFile = output.appendingPathComponent("import-fixture.json")
        let source = output.appendingPathComponent("公开导入原件.json")
        let heldSource = output.appendingPathComponent("公开导入原件暂存.json")
        let pluginID = "zz-settings-demo@local", marker = "PUBLIC_IMPORT 中文😀", dummy = "PUBLIC_FAKE_ENV_VALUE_51629"
        let invalid = "{\n" + (0..<64).map { $0 == 51 ? marker : "公开草稿 \($0)" }.joined(separator: "\n")
        let externalSetting = Data(#"{"publicUnrelatedSetting":true}"#.utf8)
        var checks: [String: Bool] = [:], requests = 0, failure: String?
        func hook(_ name: String, environment: String = "") -> String {
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","name":"\#(name)","command":"/usr/bin/true"\#(environment)}]}]}}"#
        }
        let originalSource = Data(hook("公开导入来源", environment: #","env":{"PUBLIC_FIXTURE":"\#(dummy)"}"#).utf8)
        let originalDestination = Data(hook("公开原目标").utf8)
        let revisedHook = hook("公开完成导入")
        func find<T: NSView>(_ view: NSView, _ type: T.Type, _ match: (T) -> Bool) -> T? {
            if let item = view as? T, !item.isHiddenOrHasHiddenAncestor, match(item) { return item }
            for child in view.subviews {
                if let item = find(child, type, match) { return item }
            }
            return nil
        }
        func input<T: NSView>(_ window: ControlWindow, _ type: T.Type, _ label: String) throws -> T {
            guard let content = window.window?.contentView, let control = find(content, type, { $0.accessibilityLabel() == label }) else {
                throw PetError("缺少设置控件 " + label)
            }
            return control
        }
        func button(_ window: ControlWindow, _ title: String) throws -> NSButton {
            guard let content = window.window?.contentView, let control = find(content, NSButton.self, { $0.isEnabled && $0.title == title }) else {
                throw PetError("缺少设置操作 " + title)
            }
            return control
        }
        func send(_ item: NSControl) throws {
            guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else { throw PetError("设置操作未送达") }
        }
        func selectPluginScope(_ window: ControlWindow, _ scope: AgentPluginSettingScope) throws -> NSPopUpButton {
            let scopes = try input(window, NSSegmentedControl.self, "插件设置范围")
            scopes.selectedSegment = scope.rawValue
            try send(scopes)
            return try input(window, NSPopUpButton.self, "插件启用声明")
        }
        func editHook(_ editor: NSTextView, _ text: String) {
            editor.string = text
            editor.didChangeText()
        }
        func revealDraft(_ editor: NSTextView) {
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            if let manager = editor.layoutManager, let container = editor.textContainer, let scroll = editor.enclosingScrollView {
                manager.ensureLayout(for: container)
                editor.setFrameSize(NSSize(width: editor.frame.width, height: max(scroll.contentSize.height, manager.usedRect(for: container).maxY + editor.textContainerInset.height * 2)))
            }
            let range = (invalid as NSString).range(of: marker)
            editor.window?.makeFirstResponder(editor)
            editor.setSelectedRange(range)
            editor.scrollRangeToVisible(range)
        }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("本机配置验收禁止模型请求") }
            let plugins = tasks.extensions.plugins
            guard plugins.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("设置验收只允许独立目录")
            }
            if stage == "seed" {
                let task = try await prepareSettingsPagesCheck(output, tasks: tasks)
                guard let primary = tasks.task(task)?.workspace else { throw PetError("缺少主要源文件夹") }
                let secondary = output.appendingPathComponent("第二来源").path
                try FileManager.default.createDirectory(atPath: secondary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let files = try AgentFiles(workspace: secondary), target = try files.literalURL(".bluefatfish/hooks.json")
                try files.writeData(originalDestination, to: target, permissions: 0o600)
                try originalSource.write(to: source, options: .atomic)
                tasks.update(task) { $0.workspaceScope = .init(group: output.path, folders: [primary, secondary], primary: primary); $0.draft = "PUBLIC_IMPORT_COMPOSER" }
                control.showAgentTask(task)
                guard control.showSettingsCategory("extensions"), control.settingsRecoveryControllers.first is AgentPluginWindow else {
                    throw PetError("缺少插件目录")
                }
                try input(control, NSButton.self, "配置 zz-settings-demo").performClick(nil)
                let more = try input(control, NSPopUpButton.self, "插件更多操作")
                guard let item = more.itemArray.first(where: { $0.title == "启用设置" && $0.isEnabled }),
                      let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else { throw PetError("缺少插件启用设置入口") }
                let user = try plugins.settingDocument(.user, workspace: primary), project = try plugins.settingDocument(.project, workspace: primary)
                for scope in AgentPluginSettingScope.allCases {
                    let choice = try selectPluginScope(control, scope)
                    guard choice.indexOfSelectedItem == 0 else { throw PetError("验收插件状态应为继承") }
                    choice.selectItem(at: 2)
                    try send(choice)
                }
                openTaskWindow(task, from: control)
                guard let hookWindow = additionalTaskWindows.last, hookWindow.showSettingsCategory("hooks") else { throw PetError("缺少 Hooks 设置窗口") }
                let sources = try input(hookWindow, NSPopUpButton.self, "设置源文件夹")
                guard let sourceFolder = sources.itemArray.first(where: { $0.representedObject as? String == secondary }) else { throw PetError("缺少第二来源") }
                sources.select(sourceFolder); try send(sources)
                guard let hooks = hookWindow.settingsRecoveryControllers.first as? AgentHookWindow else { throw PetError("缺少 Hooks 管理页") }
                let area = try input(hookWindow, NSPopUpButton.self, "Hooks 配置范围")
                area.selectItem(at: 1); try send(area)
                try hooks.reviewImport(source)
                let editor = try input(hookWindow, NSTextView.self, "Hooks JSON 配置")
                checks["previewShowsOriginalAndMasksValues"] = editor.string.contains("公开导入来源") &&
                    editor.string.contains(AgentHookCredentials.placeholder) && !editor.string.contains(dummy) &&
                    hookWindow.settingsRecoveryControllers.last?.detailHeading?.title == "导入 Hooks · " + source.lastPathComponent
                if !interactive {
                    editHook(editor, revisedHook)
                    try Data(hook("公开原件已变").utf8).write(to: source, options: .atomic)
                    try button(hookWindow, "保存").performClick(nil)
                    checks["sameProcessRereadsOriginalBeforeWriting"] = try input(hookWindow, NSTextField.self, "Hooks 配置保存状态").stringValue.contains("导入原件已变化") &&
                        Data(contentsOf: target) == originalDestination && editor.string == revisedHook
                    try originalSource.write(to: source, options: .atomic)
                }
                editHook(editor, invalid)
                revealDraft(editor)
                guard await flushWorkspaceWindows(), let pluginID = control.workspaceSession?.id, let hookID = hookWindow.workspaceSession?.id,
                      let pluginEditor = control.settingsRecoveryControllers.last, let hookEditor = hookWindow.settingsRecoveryControllers.last else {
                    throw PetError("原设置窗口未记住")
                }
                checks["bothEditorsPreservedOnQuit"] = control.workspaceSession?.preservedEditors.contains(ObjectIdentifier(pluginEditor)) == true &&
                    hookWindow.workspaceSession?.preservedEditors.contains(ObjectIdentifier(hookEditor)) == true
                checks["quitCheckpointDoesNotApplyAnyDraft"] = try plugins.settingDocument(.user, workspace: primary).hash == user.hash &&
                    plugins.settingDocument(.project, workspace: primary).hash == project.hash && plugins.settingDocument(.local, workspace: primary).hash == nil &&
                    Data(contentsOf: target) == originalDestination
                let fixture = ImportFixture(task: task, primary: primary, secondary: secondary, pluginWindow: pluginID, hookWindow: hookID, userHash: user.hash, projectHash: project.hash)
                try JSONEncoder().encode(fixture).write(to: fixtureFile, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(ImportFixture.self, from: Data(contentsOf: fixtureFile))
                restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows() else { throw PetError("原设置窗口未完成恢复") }
                guard let plugin = taskControls.first(where: { $0.workspaceSession?.id == fixture.pluginWindow }),
                      let hooks = taskControls.first(where: { $0.workspaceSession?.id == fixture.hookWindow }) else { throw PetError("缺少原设置窗口") }
                let primary = fixture.primary, secondary = fixture.secondary
                let target = try tasks.hooks.file(project: true, workspace: secondary)
                checks["originalOwnerAndComposerRemain"] = plugin.agentTaskID == fixture.task && hooks.agentTaskID == fixture.task &&
                    tasks.task(fixture.task)?.draft == "PUBLIC_IMPORT_COMPOSER" && tasks.task(fixture.task)?.messages.isEmpty == true
                if stage == "closed" {
                    checks["savedEditorsDoNotReappear"] = plugin.settingsRecoveryControllers.last is AgentSettingsDetailPage &&
                        hooks.settingsRecoveryControllers.last is AgentHookWindow
                } else {
                    plugin.window?.makeKeyAndOrderFront(nil); await wait(0.16)
                    let selected = try input(plugin, NSPopUpButton.self, "插件启用声明")
                    checks["pluginDetailAndLastScopeReopen"] = try plugin.settingsRecoveryControllers.count == 3 && selected.indexOfSelectedItem == 2 &&
                        input(plugin, NSSegmentedControl.self, "插件设置范围").selectedSegment == AgentPluginSettingScope.local.rawValue
                    for area in AgentPluginSettingScope.allCases {
                        checks["restoresPluginChoiceFor" + area.title] = try selectPluginScope(plugin, area).indexOfSelectedItem == 2
                    }
                    hooks.window?.makeKeyAndOrderFront(nil); await wait(0.16)
                    let editor = try input(hooks, NSTextView.self, "Hooks JSON 配置")
                    checks["originalImportAndProjectScopeRestore"] = try hooks.captureSettingsRecovery()?.context.workspace == secondary &&
                        hooks.settingsRecoveryControllers.last?.detailHeading?.title == "导入 Hooks · " + source.lastPathComponent
                    checks["invalidImportTextFocusAndSelectionRestore"] = editor.string == invalid && editor.window?.firstResponder === editor &&
                        editor.selectedRange() == (invalid as NSString).range(of: marker) && (editor.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0
                    if !interactive {
                        editHook(editor, revisedHook)
                        try FileManager.default.moveItem(at: source, to: heldSource)
                        try button(hooks, "保存").performClick(nil)
                        checks["missingImportLeavesDestinationAndDraft"] = try input(hooks, NSTextField.self, "Hooks 配置保存状态").stringValue.contains("导入原件无法读取") &&
                            Data(contentsOf: target) == originalDestination && editor.string == revisedHook
                        try FileManager.default.moveItem(at: heldSource, to: source)
                        let outside = Data(hook("公开外部改动").utf8)
                        try outside.write(to: target, options: .atomic)
                        try button(hooks, "保存").performClick(nil)
                        checks["editedDestinationIsNeverOverwritten"] = try Data(contentsOf: target) == outside && editor.string == revisedHook
                        try originalDestination.write(to: target, options: .atomic)
                        try button(hooks, "保存").performClick(nil)
                        checks["validImportPublishesOnlyToOriginalTarget"] = try String(contentsOf: target, encoding: .utf8).contains("公开完成导入") &&
                            Data(contentsOf: source) == originalSource && tasks.hooks.document(project: true, workspace: primary).1 == nil &&
                            hooks.settingsRecoveryControllers.last is AgentHookWindow

                        let local = try plugins.settingDocument(.local, workspace: primary)
                        try local.files.writeData(externalSetting, to: local.file, permissions: 0o600)
                        plugin.window?.makeKeyAndOrderFront(nil)
                        try button(plugin, "保存").performClick(nil)
                        checks["newlyCreatedFileBlocksStalePluginSave"] = try Data(contentsOf: local.file) == externalSetting &&
                            selected.indexOfSelectedItem == 2 && input(plugin, NSTextField.self, "插件设置保存状态").stringValue.contains("请刷新")
                        try button(plugin, "刷新").performClick(nil)
                        try button(plugin, "保存").performClick(nil)
                        let saved = try plugins.settingDocument(.local, workspace: primary)
                        checks["refreshThenSaveTouchesOnlyLocalScope"] = try saved.values[pluginID] == false &&
                            saved.object["publicUnrelatedSetting"] as? Bool == true &&
                            plugins.settingDocument(.user, workspace: primary).hash == fixture.userHash &&
                            plugins.settingDocument(.project, workspace: primary).hash == fixture.projectHash &&
                            plugins.settingDocument(.local, workspace: secondary).hash == nil
                        for area in [AgentPluginSettingScope.user, .project] {
                            _ = try selectPluginScope(plugin, area)
                            try button(plugin, "保存").performClick(nil)
                        }
                        plugin.settingsRecoveryControllers.last?.close()
                        checks["savingAllScopesAllowsLeavingEditor"] = plugin.settingsRecoveryControllers.last is AgentSettingsDetailPage
                    }
                }
            }
            checks["allSettingsStateCheckpointed"] = await flushWorkspaceWindows()
        } catch { failure = error.localizedDescription }
        checks["zeroModelRequests"] = requests == 0
        var report: [String: Any] = ["stage": stage, "success": failure == nil && checks.values.allSatisfy { $0 }, "checks": checks, "modelRequests": requests, "pid": getpid()]
        if let failure { report["error"] = failure }
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? bytes.write(to: output.appendingPathComponent("import-report-\(stage).json"), options: .atomic)
        }
    }
}
