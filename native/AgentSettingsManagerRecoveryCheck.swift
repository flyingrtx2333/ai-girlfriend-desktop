import AppKit

@MainActor extension AppDelegate {
    private struct ManagerFixture: Codable {
        let general: String, multi: String, draft: String, profile: String, alpha: String, beta: String
        let hookHash: String, agentHash: String?, teamHash: String?, windows: [String: String]
    }

    func runSettingsManagerRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let fixtureFile = output.appendingPathComponent("manager-fixture.json")
        let marker = "PUBLIC_SELECT_746 中文😀"
        let longBody = (0..<64).map { $0 == 49 ? marker : "PUBLIC_DRAFT_\($0) 中文😀" }.joined(separator: "\n")
        let badHook = "{\n" + longBody
        var checks: [String: Bool] = [:], requests = 0, failure: String?
        func find<T: NSView>(_ view: NSView?, _ type: T.Type, _ match: (T) -> Bool) -> T? {
            guard let view else { return nil }
            if let item = view as? T, match(item), !item.isHiddenOrHasHiddenAncestor { return item }
            for child in view.subviews { if let item = find(child, type, match) { return item } }
            return nil
        }
        func input<T: NSView>(_ window: ControlWindow, _ type: T.Type, _ label: String) throws -> T {
            guard let value = find(window.window?.contentView, type, { $0.accessibilityLabel() == label }) else { throw PetError("缺少设置控件 " + label) }
            return value
        }
        func button(_ window: ControlWindow, _ title: String) throws -> NSButton {
            guard let value = find(window.window?.contentView, NSButton.self, { $0.isEnabled && (title == "返回 " ? $0.accessibilityLabel()?.hasPrefix(title) == true : $0.title == title) }) else {
                throw PetError("缺少设置操作 " + title)
            }
            return value
        }
        func field(_ window: ControlWindow, _ label: String, _ value: String, select: String? = nil) throws {
            let view = try input(window, NSTextField.self, label); view.stringValue = value
            let note = Notification(name: NSControl.textDidChangeNotification, object: view)
            for controller in window.settingsRecoveryControllers.reversed() {
                if let agent = controller as? AgentProfileWindow { agent.controlTextDidChange(note); break }
                if let team = controller as? AgentTeamWindow { team.controlTextDidChange(note); break }
            }
            if let select {
                window.window?.makeFirstResponder(view)
                (view.currentEditor() as? NSTextView)?.setSelectedRange((value as NSString).range(of: select))
            }
        }
        func text(_ window: ControlWindow, _ label: String, _ value: String) throws {
            let view = try input(window, NSTextView.self, label); view.string = value; view.didChangeText()
            window.window?.contentView?.layoutSubtreeIfNeeded()
            if let manager = view.layoutManager, let container = view.textContainer, let scroll = view.enclosingScrollView {
                manager.ensureLayout(for: container)
                view.setFrameSize(NSSize(width: view.frame.width, height: max(scroll.contentSize.height, manager.usedRect(for: container).maxY + view.textContainerInset.height * 2)))
            }
            window.window?.makeFirstResponder(view)
            let range = (value as NSString).range(of: marker)
            if range.location != NSNotFound { view.setSelectedRange(range); view.scrollRangeToVisible(range) }
        }
        func state(_ window: ControlWindow, _ label: String, _ expected: String) throws -> Bool {
            let view = try input(window, NSTextView.self, label)
            return view.string == expected && view.selectedRange() == (expected as NSString).range(of: marker) &&
                view.window?.firstResponder === view && (view.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0
        }
        func hook(_ name: String) -> String {
            """
            {"hooks":{"Stop":[{"hooks":[{"type":"prompt","name":"\(name)","prompt":"Public fixture"}]}]}}
            """
        }
        func openSettings(_ id: String, _ category: String) throws -> ControlWindow {
            openTaskWindow(id, from: control)
            guard let child = additionalTaskWindows.last, child.showSettingsCategory(category) else { throw PetError("缺少任务设置窗口 " + category) }
            return child
        }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("设置恢复检查禁止模型请求") }
            if stage == "seed" {
                guard !FileManager.default.fileExists(atPath: fixtureFile.path) else { throw PetError("已有验收资料，请使用新目录") }
                let alpha = output.appendingPathComponent("Alpha public"), beta = output.appendingPathComponent("Beta public")
                for folder in [alpha, beta] {
                    let path = folder.appendingPathComponent(".bluefatfish")
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                    try Data(hook(folder == alpha ? "公开 Alpha" : "公开 Beta").utf8).write(to: path.appendingPathComponent("hooks.json"))
                }
                guard let general = control.agentTaskID else { throw PetError("缺少主窗口任务") }
                let multi = tasks.create(title: "设置恢复 · 双来源", workspace: beta.path)
                tasks.update(multi) { $0.workspaceScope = .init(group: output.appendingPathComponent("Public group").path, folders: [alpha.path, beta.path], primary: beta.path); $0.draft = "PUBLIC_MULTI_COMPOSER" }
                let profile = AgentProfile(name: "公开验收 Agent", description: marker, instructions: longBody)
                let draft = AgentProfileDraft(taskID: general, callID: "public-manager-fixture", profile: profile)
                tasks.update(general) { $0.draft = "PUBLIC_GENERAL_COMPOSER"; $0.agentDrafts = [draft] }
                let agentHash = try tasks.agents.document().1, teamHash = try tasks.teams.document().1
                guard control.showSettingsCategory("agents"), let manager = control.settingsRecoveryControllers.first as? AgentProfileWindow else {
                    throw PetError("缺少原智能体设置")
                }
                try manager.configureDraft(draft)
                try field(control, "Agent 名称", ""); try field(control, "Agent 职责", marker, select: "中文😀")
                let team = try openSettings(multi, "teams")
                try button(team, "审阅模板").performClick(nil); try button(team, "载入草稿").performClick(nil)
                try field(team, "团队名称", "PUBLIC_TEAM_RECOVERY", select: "RECOVERY")
                let teamBody = try input(team, NSTextView.self, "团队协作指令")
                teamBody.string = "PUBLIC_TEAM_BODY"; teamBody.didChangeText()
                try button(team, "管理 Agent").performClick(nil); try button(team, "新建").performClick(nil)
                try field(team, "Agent 名称", "PUBLIC_NESTED_AGENT"); try text(team, "Agent 指令", longBody)
                let hooks = try openSettings(multi, "hooks")
                let folders = try input(hooks, NSPopUpButton.self, "设置源文件夹")
                guard let source = folders.itemArray.first(where: { $0.representedObject as? String == alpha.path }), let changeSource = folders.action else { throw PetError("缺少次源文件夹") }
                folders.select(source); NSApp.sendAction(changeSource, to: folders.target, from: folders)
                let scope = try input(hooks, NSPopUpButton.self, "Hooks 配置范围"); scope.selectItem(at: 1)
                try button(hooks, "编辑配置").performClick(nil); try text(hooks, "Hooks JSON 配置", badHook)
                guard await flushWorkspaceWindows(), let root = control.workspaceSession?.id,
                      let teamID = team.workspaceSession?.id, let hookID = hooks.workspaceSession?.id,
                      let hookHash = try tasks.hooks.document(project: true, workspace: alpha.path).1 else { throw PetError("原设置记录未落盘") }
                let fixture = ManagerFixture(general: general, multi: multi, draft: draft.id, profile: profile.id, alpha: alpha.path, beta: beta.path,
                    hookHash: hookHash, agentHash: agentHash, teamHash: teamHash, windows: ["agent": root, "team": teamID, "hook": hookID])
                try JSONEncoder().encode(fixture).write(to: fixtureFile, options: .atomic)
                checks["threeEditorsCanExitWithRecovery"] = [control, team, hooks].allSatisfy { $0.workspaceSession?.preservedEditors.isEmpty == false }
                checks["nestedTeamAndAgentBothJournaled"] = try team.captureSettingsRecovery()?.pages.map(\.kind) == ["teams", "agents"]
                checks["secondaryProjectHookScopeJournaled"] = try hooks.captureSettingsRecovery()?.context.workspace == alpha.path
                checks["checkpointDoesNotWriteSettings"] = try tasks.agents.document().1 == agentHash && tasks.teams.document().1 == teamHash &&
                    tasks.hooks.document(project: true, workspace: alpha.path).1 == AgentFiles.hash(Data(hook("公开 Alpha").utf8))
            } else {
                let fixture = try JSONDecoder().decode(ManagerFixture.self, from: Data(contentsOf: fixtureFile))
                restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows() else { throw PetError("设置窗口未完成恢复") }
                func window(_ role: String) throws -> ControlWindow {
                    guard let result = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows[role] }) else { throw PetError("缺少原窗口 " + role) }
                    return result
                }
                let agent = try window("agent"), team = try window("team"), hooks = try window("hook")
                checks["originalComposersAndMessagesExact"] = tasks.task(fixture.general)?.draft == "PUBLIC_GENERAL_COMPOSER" &&
                    tasks.task(fixture.multi)?.draft == "PUBLIC_MULTI_COMPOSER" && [fixture.general, fixture.multi].allSatisfy { tasks.task($0)?.messages.isEmpty == true }
                if stage == "closed" {
                    checks["closedHookDoesNotReappear"] = hooks.settingsRecoveryControllers.count == 1
                    checks["discardedNestedAgentDoesNotReappear"] = team.settingsRecoveryControllers.count == 2
                    checks["savedAgentReopensClean"] = try input(agent, NSTextField.self, "Agent 名称").stringValue == "PUBLIC_SAVED_AGENT"
                } else {
                    agent.window?.makeKeyAndOrderFront(nil); await wait(0.16)
                    let purpose = try input(agent, NSTextField.self, "Agent 职责")
                    checks["agentBlankNameAndFieldSelectionRestore"] = try input(agent, NSTextField.self, "Agent 名称").stringValue.isEmpty &&
                        (purpose.currentEditor() as? NSTextView)?.selectedRange() == (purpose.stringValue as NSString).range(of: "中文😀") && agent.window?.firstResponder === purpose.currentEditor()
                    team.window?.makeKeyAndOrderFront(nil); await wait(0.12)
                    checks["nestedAgentRestoresTextSelectionAndScroll"] = try state(team, "Agent 指令", longBody)
                    hooks.window?.makeKeyAndOrderFront(nil); await wait(0.12)
                    checks["hookRestoresInvalidTextSelectionAndScroll"] = try state(hooks, "Hooks JSON 配置", badHook)
                    checks["hookScopeAndOwnerRestore"] = try hooks.captureSettingsRecovery()?.context.workspace == fixture.alpha && hooks.captureSettingsRecovery()?.context.taskID == fixture.multi
                    if !interactive {
                        try button(hooks, "保存").performClick(nil)
                        checks["invalidHookKeepsExactDraftAndSource"] = try input(hooks, NSTextView.self, "Hooks JSON 配置").string == badHook && tasks.hooks.document(project: true, workspace: fixture.alpha).1 == fixture.hookHash
                        let original = try tasks.hooks.file(project: true, workspace: fixture.alpha)
                        let previous = try Data(contentsOf: original), external = Data(hook("公开外部改动").utf8)
                        try external.write(to: original)
                        try text(hooks, "Hooks JSON 配置", hook("公开续写 Hook")); try button(hooks, "保存").performClick(nil)
                        checks["staleHookCannotOverwriteOrRetarget"] = try Data(contentsOf: original) == external && input(hooks, NSTextView.self, "Hooks JSON 配置").string == hook("公开续写 Hook")
                        try previous.write(to: original); try button(hooks, "保存").performClick(nil)
                        checks["retryWritesOnlySecondaryHookSource"] = try tasks.hooks.document(project: true, workspace: fixture.alpha).0.contains("公开续写 Hook") &&
                            tasks.hooks.document(project: true, workspace: fixture.beta).0.contains("公开 Beta") && tasks.hooks.document(project: false, workspace: nil).1 == nil
                        try field(agent, "Agent 名称", "PUBLIC_SAVED_AGENT"); try button(agent, "保存").performClick(nil)
                        checks["savedAgentMarksOnlyOriginalTaskDraft"] = try AgentProfileDrafts.load(fixture.draft, taskID: fixture.general, store: tasks).savedAt != nil &&
                            tasks.agents.decode(tasks.agents.document().0).contains { $0.id == fixture.profile && $0.name == "PUBLIC_SAVED_AGENT" && $0.instructions == longBody } &&
                            (tasks.task(fixture.multi)?.agentDrafts ?? []).isEmpty
                        let back = try button(team, "返回 ")
                        try discardManagerFixtureChanges { back.performClick(nil) }
                        try button(team, "返回 ").performClick(nil); await wait(0.12)
                        checks["parentTeamKeepsEditedFieldsAndTemplateRoles"] = try input(team, NSTextField.self, "团队名称").stringValue == "PUBLIC_TEAM_RECOVERY" &&
                            input(team, NSTextView.self, "团队协作指令").string == "PUBLIC_TEAM_BODY" && input(team, NSPopUpButton.self, "团队成员").item(at: 0)?.title == "已选 2 / 4"
                        let changedHash = try tasks.agents.document().1
                        try button(team, "保存").performClick(nil)
                        checks["staleTemplateCannotWriteEitherConfiguration"] = try changedHash != fixture.agentHash && tasks.agents.document().1 == changedHash &&
                            tasks.teams.document().1 == fixture.teamHash && input(team, NSTextField.self, "团队名称").stringValue == "PUBLIC_TEAM_RECOVERY"
                    }
                }
            }
            let placeholder = AgentHookCredentials.placeholder
            checks["onlyMaskedCredentialMapsAreRecoverable"] = AgentHookCredentials.canPreserveDraft("{\"env\":{\"SECRET\":\"\(placeholder)\"}}") &&
                !AgentHookCredentials.canPreserveDraft("{\"env\":{\"SECRET\":\"PUBLIC_DUMMY\",\"SECRET\":\"\(placeholder)\"}}") &&
                !AgentHookCredentials.canPreserveDraft(#"{"h\u0065aders":{"Authorization":"PUBLIC_DUMMY""#) &&
                AgentHookCredentials.canPreserveDraft(badHook)
            checks["noModelRequests"] = requests == 0
            checks["allCurrentRecoveryStatesCheckpoint"] = await flushWorkspaceWindows()
        } catch { failure = error.localizedDescription }
        var report: [String: Any] = ["stage": stage, "success": failure == nil && checks.values.allSatisfy { $0 }, "checks": checks, "modelRequests": requests, "pid": ProcessInfo.processInfo.processIdentifier]
        if let failure { report["error"] = failure }
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: output.appendingPathComponent("manager-report-\(stage).json"), options: .atomic)
        }
    }

    private func discardManagerFixtureChanges(_ action: () -> Void) throws {
        var selected = false
        let deadline = Date().addingTimeInterval(5)
        func discard(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "放弃更改" { return button }
            return view.subviews.lazy.compactMap(discard).first
        }
        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in MainActor.assumeIsolated {
            if let dialog = NSApp.modalWindow?.agentDialog, let button = discard(dialog.view) { selected = true; timer.invalidate(); button.performClick(nil) }
            else if Date() > deadline { timer.invalidate(); NSApp.abortModal() }
        } }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }; action()
        guard selected else { throw PetError("缺少嵌套编辑器的放弃确认") }
    }
}
