import AppKit

@MainActor extension AppDelegate {
    private struct AutomationFixture: Codable {
        let tasks: [String: String], windows: [String: String], existing: String, proposal: String, proposedPlan: String
        let alpha: String, beta: String, definitionsHash: String
    }

    func runAutomationRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let fixtureURL = output.appendingPathComponent("automation-fixture.json")
        let marker = "PUBLIC_AUTOMATION 中文😀"
        let instructions = (0..<65).map { $0 == 52 ? marker : "第 \($0) 行公开说明，核对 README。" }.joined(separator: "\n")
        let invalidTime = "上午??", invalidInterval = "尚未填写"
        let externalPrompt = "其他编辑者已保存的公开计划内容。"
        var checks: [String: Bool] = [:], requests = 0, failure: String?
        func find<T: NSView>(_ view: NSView, _ type: T.Type, _ match: (T) -> Bool) -> T? {
            if let control = view as? T, !control.isHiddenOrHasHiddenAncestor, match(control) { return control }
            for child in view.subviews {
                if let control = find(child, type, match) { return control }
            }
            return nil
        }
        func input<T: NSView>(_ window: ControlWindow, _ type: T.Type, _ label: String) throws -> T {
            guard let content = window.window?.contentView, let control = find(content, type, { $0.accessibilityLabel() == label }) else {
                throw PetError("缺少自动化控件 " + label)
            }
            return control
        }
        func button(_ window: ControlWindow, _ title: String) throws -> NSButton {
            guard let content = window.window?.contentView, let control = find(content, NSButton.self, { $0.isEnabled && $0.title == title }) else {
                throw PetError("缺少自动化操作 " + title)
            }
            return control
        }
        func text(_ window: ControlWindow, _ label: String, _ value: String) throws {
            let field = try input(window, NSTextField.self, label)
            field.stringValue = value
            window.automationWindow?.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
        }
        func prompt(_ window: ControlWindow, _ value: String) throws -> NSTextView {
            let view = try input(window, NSTextView.self, "自动化任务指令")
            view.string = value; view.didChangeText()
            return view
        }
        func focusSelection(_ view: NSTextView) {
            view.window?.contentView?.layoutSubtreeIfNeeded()
            if let layout = view.layoutManager, let container = view.textContainer, let scroll = view.enclosingScrollView {
                layout.ensureLayout(for: container)
                view.setFrameSize(.init(width: view.frame.width, height: max(scroll.contentSize.height, layout.usedRect(for: container).maxY + view.textContainerInset.height * 2)))
            }
            let range = (instructions as NSString).range(of: marker)
            view.window?.makeFirstResponder(view); view.setSelectedRange(range); view.scrollRangeToVisible(range)
            if let scroll = view.enclosingScrollView { scroll.scrollToVisible(scroll.bounds) }
        }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("自动化验收只允许独立目录")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("恢复验收禁止模型请求") }
            let service = tasks.automations
            service.start(store: tasks, runtime: runtime)
            guard service.isStarted else { throw PetError(service.error ?? "独立调度器未启动") }
            let definitions = service.directory.appendingPathComponent("definitions.json")
            if stage == "seed" {
                let alpha = output.appendingPathComponent("Alpha 公开项目"), beta = output.appendingPathComponent("Beta 公开项目")
                for folder in [alpha, beta] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    try Data("# 公开 README\n".utf8).write(to: folder.appendingPathComponent("README.md"))
                }
                let existingTask = tasks.create(title: "计划恢复 · 已有", workspace: alpha.path)
                let newTask = tasks.create(title: "计划恢复 · 新建", workspace: beta.path)
                let proposalTask = tasks.create(title: "计划恢复 · 会话提案", workspace: beta.path)
                let owners = ["existing": existingTask, "new": newTask, "proposal": proposalTask]
                for (role, task) in owners { tasks.update(task) { $0.draft = "PUBLIC_COMPOSER_" + role } }
                var saved = AgentAutomation(name: "公开的已有计划", prompt: "读取公开 README。", workspace: alpha.path)
                saved.notify = false
                try service.save(saved, expected: nil)
                let before = AgentFiles.hash(try Data(contentsOf: definitions))
                let proposed = AgentAutomation(name: "公开的会话提案", prompt: "只读核对公开标题。", workspace: beta.path)
                let draft = AgentAutomationDraft(taskID: proposalTask, callID: "automation-recovery-fixture", requestHash: AgentFiles.hash(Data("public proposal".utf8)), automation: proposed)
                tasks.update(proposalTask) { $0.automationDrafts = [draft] }

                control.showAgentTask(existingTask); control.showAutomations()
                let catalog = try input(control, NSTableView.self, "自动化列表")
                catalog.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                try text(control, "自动化名称", "公开的已有计划草稿")
                try text(control, "计划时间", invalidTime)
                focusSelection(try prompt(control, instructions))

                openTaskWindow(newTask, from: control)
                guard let manual = additionalTaskWindows.last else { throw PetError("缺少新建自动化窗口") }
                manual.showAutomations(); try button(manual, "新建自动化").performClick(nil)
                let frequency = try input(manual, NSPopUpButton.self, "计划频率")
                frequency.selectItem(withTitle: "固定间隔")
                guard let selectFrequency = frequency.action, NSApp.sendAction(selectFrequency, to: frequency.target, from: frequency) else {
                    throw PetError("缺少固定间隔操作")
                }
                try text(manual, "自动化名称", "")
                try text(manual, "间隔分钟", invalidInterval)
                _ = try prompt(manual, "公开的手动计划草稿。")
                for label in ["启用计划", "运行结果通知"] {
                    let toggle = try input(manual, NSSwitch.self, label)
                    toggle.state = .off
                    guard let action = toggle.action, NSApp.sendAction(action, to: toggle.target, from: toggle) else {
                        throw PetError("缺少自动化操作 " + label)
                    }
                }

                openTaskWindow(proposalTask, from: control)
                guard let proposalWindow = additionalTaskWindows.last else { throw PetError("缺少会话提案窗口") }
                try proposalWindow.configureAutomationDraft(draft.id, taskID: proposalTask)
                try text(proposalWindow, "自动化名称", "公开的会话提案草稿")
                try text(proposalWindow, "计划时间", invalidTime)
                let field = try input(proposalWindow, NSTextField.self, "计划时间")
                proposalWindow.window?.makeFirstResponder(field)
                (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 2))
                guard await flushWorkspaceWindows(), let a = control.workspaceSession?.id,
                      let b = manual.workspaceSession?.id, let c = proposalWindow.workspaceSession?.id else { throw PetError("自动化草稿未记录") }
                let windows = ["existing":a, "new":b, "proposal":c]
                checks["allOwnerWindowsCheckpointBeforeQuit"] = [control, manual, proposalWindow].allSatisfy { window in
                    guard let manager = window.automationWindow else { return false }
                    return window.workspaceSession?.preservedEditors.contains(ObjectIdentifier(manager)) == true
                }
                checks["checkpointNeitherRegistersNorRunsPlans"] = try AgentFiles.hash(Data(contentsOf: definitions)) == before &&
                    service.values.count == 1 && service.values.first?.enabled == false && service.history().total == 0
                let record = AutomationFixture(tasks: owners, windows: windows, existing: saved.id, proposal: draft.id, proposedPlan: proposed.id,
                    alpha: alpha.path, beta: beta.path, definitionsHash: before)
                try JSONEncoder().encode(record).write(to: fixtureURL, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(AutomationFixture.self, from: Data(contentsOf: fixtureURL))
                restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows() else { throw PetError("原自动化窗口未完成恢复") }
                func window(_ role: String) throws -> ControlWindow {
                    guard let result = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows[role] && $0.agentTaskID == fixture.tasks[role] }) else {
                        throw PetError("缺少原自动化窗口 " + role)
                    }
                    return result
                }
                let existing = try window("existing"), manual = try window("new"), proposalWindow = try window("proposal")
                checks["originalTasksAndComposersRemain"] = fixture.tasks.allSatisfy { role, id in
                    tasks.task(id)?.draft == "PUBLIC_COMPOSER_" + role && tasks.task(id)?.messages.isEmpty == true
                }
                if stage == "saved" {
                    checks["savedEditorsDoNotReappear"] = manual.automationWindow?.isVisible != true && proposalWindow.automationWindow?.isVisible != true
                    checks["conflictingDraftRemainsRecoverable"] = existing.automationWindow?.hasUnsavedChanges == true
                } else {
                    existing.window?.makeKeyAndOrderFront(nil); await wait(0.14)
                    let body = try input(existing, NSTextView.self, "自动化任务指令")
                    checks["existingDraftRestoresRawInvalidInputAndOwner"] = try input(existing, NSTextField.self, "计划时间").stringValue == invalidTime &&
                        input(existing, NSTextField.self, "自动化项目目录").stringValue == fixture.alpha && body.string == instructions
                    checks["existingPromptRestoresAtOriginalSelection"] = body.window?.firstResponder === body &&
                        body.selectedRange() == (instructions as NSString).range(of: marker) && (body.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0
                    if let host = body.window {
                        let selected = body.firstRect(forCharacterRange: body.selectedRange(), actualRange: nil)
                        let visible = host.convertToScreen(body.convert(body.visibleRect, to: nil))
                        checks["existingPromptSelectionVisibleInForm"] = selected.height > 0 &&
                            selected.minY < visible.maxY && visible.minY < selected.maxY
                    }
                    checks["manualDraftRestoresBlankNameAndInvalidInterval"] = try input(manual, NSTextField.self, "自动化名称").stringValue.isEmpty &&
                        input(manual, NSTextField.self, "间隔分钟").stringValue == invalidInterval &&
                        input(manual, NSTextField.self, "自动化项目目录").stringValue == fixture.beta
                    proposalWindow.window?.makeKeyAndOrderFront(nil); await wait(0.14)
                    let field = try input(proposalWindow, NSTextField.self, "计划时间")
                    checks["proposalRestoresLastFieldAndSelection"] = field.stringValue == invalidTime && field.currentEditor() === proposalWindow.window?.firstResponder &&
                        (field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 2)
                    if !interactive {
                        guard let before = service.values.first(where: { $0.id == fixture.existing }), before.prompt == externalPrompt else {
                            throw PetError("外部改动样例未载入")
                        }
                        let stale = AgentFiles.hash(try Data(contentsOf: definitions))
                        try text(existing, "计划时间", "10:05")
                        try button(existing, "保存").performClick(nil)
                        let showedConflict = existing.window?.contentView.map { content in
                            find(content, NSTextField.self, { $0.stringValue.contains("自动化已改变") }) != nil
                        } ?? false
                        checks["changedPlanRejectsSaveAndKeepsDraft"] = try AgentFiles.hash(Data(contentsOf: definitions)) == stale &&
                            existing.automationWindow?.hasUnsavedChanges == true && body.string == instructions && showedConflict
                        try button(manual, "创建").performClick(nil)
                        checks["invalidManualSavePreservesDraftAndOriginalFile"] = try AgentFiles.hash(Data(contentsOf: definitions)) == stale &&
                            input(manual, NSTextField.self, "间隔分钟").stringValue == invalidInterval
                        try text(manual, "自动化名称", "公开的手动恢复计划")
                        try text(manual, "间隔分钟", "90")
                        try button(manual, "创建").performClick(nil)
                        checks["manualExplicitSaveUsesOriginalProjectAndDisabledFlags"] = service.values.contains {
                            $0.name == "公开的手动恢复计划" && $0.workspace == fixture.beta && !$0.enabled && !$0.notify && $0.schedule.intervalMinutes == 90
                        }
                        guard let proposalTask = fixture.tasks["proposal"], let proposal = tasks.task(proposalTask)?.automationDrafts?.first else {
                            throw PetError("缺少原会话提案")
                        }
                        try text(proposalWindow, "计划时间", "10:05")
                        let beforeProposal = AgentFiles.hash(try Data(contentsOf: definitions))
                        tasks.update(proposalTask) { $0.automationDrafts?[0].requestHash = AgentFiles.hash(Data("another public proposal".utf8)) }
                        try button(proposalWindow, "创建").performClick(nil)
                        checks["replacedProposalCannotPublish"] = try AgentFiles.hash(Data(contentsOf: definitions)) == beforeProposal &&
                            proposalWindow.automationWindow?.hasUnsavedChanges == true && tasks.task(proposalTask)?.automationDrafts?.first?.savedAt == nil
                        tasks.update(proposalTask) { $0.automationDrafts = [proposal] }
                        try button(proposalWindow, "创建").performClick(nil)
                        checks["proposalExplicitSaveMarksOnlyOriginalTask"] = fixture.tasks["proposal"].flatMap(tasks.task)?.automationDrafts?.first.map {
                            $0.id == fixture.proposal && $0.savedAt != nil
                        } == true && service.values.contains { $0.id == fixture.proposedPlan && $0.name == "公开的会话提案草稿" && !$0.enabled }
                    }
                }
            }
            checks["noScheduledWorkOrRuns"] = try service.values.allSatisfy { !$0.enabled && $0.current == nil } && service.history().total == 0
            checks["finalRecordsCheckpoint"] = await flushWorkspaceWindows()
        } catch { failure = error.localizedDescription }
        checks["zeroModelRequests"] = requests == 0
        var report: [String: Any] = ["stage": stage, "success": failure == nil && checks.values.allSatisfy { $0 }, "checks": checks, "modelRequests": requests, "pid": getpid()]
        if let failure { report["error"] = failure }
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? bytes.write(to: output.appendingPathComponent("automation-recovery-\(stage).json"), options: .atomic)
        }
    }
}
