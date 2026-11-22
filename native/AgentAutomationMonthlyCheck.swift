import AppKit

@MainActor extension AppDelegate {
    private struct MonthlyAutomationFixture: Codable {
        let pid: Int32
        let plan: String
        let task: String
        let workspace: String
        let originalHash: String
    }

    func runAutomationMonthlyCheck(_ output: URL) async {
        let fixtureFile = output.appendingPathComponent("monthly-fixture.json")
        let invalid = "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=0"
        let importedRule = "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0;BYSETPOS=-1"
        let prompt = "核对公开的月度计划样例。"
        let reply = "月度计划样例已完成。"
        let fm = FileManager.default
        var checks: [String: Bool] = [:], results: [String: Any] = [:], requests = 0
        let reopening = fm.fileExists(atPath: fixtureFile.path)
        defer { agentRuntime?.stopAll(); agentStore?.automations.stop() }

        func find<T: NSView>(_ root: NSView, _ type: T.Type, _ predicate: (T) -> Bool) -> T? {
            if let view = root as? T, !view.isHiddenOrHasHiddenAncestor, predicate(view) { return view }
            for child in root.subviews { if let found = find(child, type, predicate) { return found } }
            return nil
        }
        func controlWithLabel<T: NSView>(_ window: NSWindow, _ type: T.Type, _ label: String) throws -> T {
            guard let root = window.contentView, let view = find(root, type, { $0.accessibilityLabel() == label }) else {
                throw PetError("缺少自动化控件 " + label)
            }
            return view
        }
        func click(_ window: NSWindow, _ title: String) throws {
            guard let root = window.contentView, let button = find(root, NSButton.self, { $0.title == title && $0.isEnabled }) else {
                throw PetError("缺少自动化操作 " + title)
            }
            button.performClick(nil)
        }
        func change(_ value: String, field: NSTextField, manager: AgentAutomationWindow) {
            field.stringValue = value
            manager.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
        }
        do {
            let home = output.appendingPathComponent("shared-home").standardizedFileURL
            guard checkDirectory?.standardizedFileURL == output.standardizedFileURL,
                  store.directory.standardizedFileURL == output.appendingPathComponent("profile").standardizedFileURL,
                  !CommandLine.arguments.contains("--live-agent"),
                  let port = UInt16(try String(contentsOf: output.appendingPathComponent("stream-port.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
                throw PetError("月度计划验收需要独立目录与本机响应样例")
            }
            let endpoint = "http://127.0.0.1:\(port)/v1"
            store.preferences.endpoint = endpoint; store.preferences.model = "fixture-monthly"
            try store.keychain.write("public-monthly-fixture", account: "chat")
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, tasks.extensions.sharedHome?.standardizedFileURL == home else {
                throw PetError("月度计划验收未使用独立任务目录")
            }
            runtime.modelRequestCheck = {
                requests += 1
                guard self.store.preferences.endpoint == endpoint, reopening, requests == 1 else {
                    throw PetError("月度计划样例仅允许一次本机请求")
                }
            }
            let service = tasks.automations, imports = tasks.dataImport
            service.start(store: tasks, runtime: runtime)
            guard service.isStarted else { throw PetError(service.error ?? "独立调度器未启动") }
            let monthlyFile = service.directory.appendingPathComponent("monthly-definitions.json")
            func definitionHash() throws -> String { AgentFiles.hash(try Data(contentsOf: monthlyFile)) }

            if !reopening {
                let project = output.appendingPathComponent("project")
                let source = output.appendingPathComponent("codex-export/automations/monthly/automation.toml")
                for folder in [project, source.deletingLastPathComponent()] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
                try Data("# 月度计划公开样例\n".utf8).write(to: project.appendingPathComponent("README.md"))
                try tasks.organization.register(project.path, mode: .coding)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
                let paths = String(decoding: try encoder.encode([project.path]), as: UTF8.self)
                let toml = """
                id = "monthly"
                version = 1
                name = "月末工作日"
                status = "ACTIVE"
                prompt = "\(prompt)"
                rrule = "\(importedRule)"
                time_zone = "UTC"
                cwds = \(paths)
                """
                try Data(toml.utf8).write(to: source)
                await imports.detect(.codex, root: source, category: .automations)
                guard let row = imports.preview.first, row.issue == nil else {
                    throw PetError(imports.preview.first?.issue ?? "未找到可导入的月度计划")
                }
                try imports.begin(.codex, root: source, ids: [row.id], category: .automations)
                let deadline = Date().addingTimeInterval(10)
                while imports.active && Date() < deadline { await wait(0.03) }
                guard let plan = service.values.first(where: { $0.id == row.targetID }) else { throw PetError("月度计划未导入") }
                checks["importedActiveSourceDoesNotArmLocalTimer"] = !plan.enabled && plan.nextRun == nil && plan.current == nil
                    && plan.readOnly && !plan.network && plan.permission == .review
                let task = tasks.create(title: "月度计划设置验收", workspace: project.path)
                control.showAgentTask(task); control.showAutomations()
                guard let manager = control.automationWindow, let window = control.window else { throw PetError("未打开嵌入式自动化页") }
                try manager.selectImported(plan.id)
                let field = try controlWithLabel(window, NSTextField.self, "月内规则")
                let preview = try controlWithLabel(window, NSTextField.self, "下次运行时间")
                guard let expected = plan.schedule.next(after: Date()) else { throw PetError("导入计划没有未来运行时间") }
                checks["storedRuleAndNextRunAreReadInOriginalWorkbench"] = manager.presentingWindow === window
                    && field.stringValue == importedRule && preview.stringValue == AgentAutomations.dateText(expected, zone: "UTC") + " · 未启用"
                guard let content = window.contentView else { throw PetError("缺少自动化窗口内容") }
                checks["unboundedImportOffersOptionalStartWithoutShowingArtificialDate"] = find(content, NSButton.self, { $0.title == "设置开始时间" && $0.isEnabled }) != nil
                    && find(content, NSDatePicker.self, { $0.accessibilityLabel() == "计划起始日期和时间" }) == nil
                for size in [NSSize(width: 780, height: 540), NSSize(width: 1320, height: 800)] {
                    window.appearance = NSAppearance(named: size.width == 780 ? .darkAqua : .aqua)
                    window.setContentSize(size); content.layoutSubtreeIfNeeded(); await wait(0.08)
                    let menu = try controlWithLabel(window, NSPopUpButton.self, "月内规则预设")
                    guard let document = field.enclosingScrollView?.documentView, let menuFrame = menu.superview as? AgentSettingsPopupFrame else {
                        throw PetError("月度计划控件未使用页内表单")
                    }
                    let ruleArea = document.convert(field.bounds, from: field).union(document.convert(preview.bounds, from: preview))
                    document.scrollToVisible(ruleArea.insetBy(dx: 0, dy: -12))
                    content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let trailing = menuFrame.convert(menuFrame.bounds, to: field).minX - field.bounds.maxX
                    results["geometry\(Int(size.width))"] = ["width": content.bounds.width, "height": content.bounds.height,
                        "fieldWidth": field.bounds.width, "fieldVisibleHeight": field.visibleRect.height,
                        "presetWidth": menuFrame.bounds.width, "presetVisibleWidth": menuFrame.visibleRect.width, "spacing": trailing]
                    checks["monthlyControlsFitAt\(Int(size.width))"] = content.bounds.size == size && field.bounds.width >= 150
                        && menuFrame.bounds.width >= 68 && trailing >= 4 && field.visibleRect.height >= field.bounds.height - 1
                        && menuFrame.visibleRect.width >= menuFrame.bounds.width - 1
                    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw PetError("无法绘制月度计划窗口") }
                    bitmap.size = size; content.cacheDisplay(in: content.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("月度计划窗口图像无法编码") }
                    try png.write(to: output.appendingPathComponent("monthly-controls-\(Int(size.width)).png"), options: .atomic)
                }
                let originalHash = try definitionHash()
                change(invalid, field: field, manager: manager)
                checks["invalidRuleExplainsWhyNextRunCannotBeCalculated"] = preview.stringValue.contains("无效")
                try click(window, "保存")
                checks["invalidSaveLeavesStoredRuleAndPendingFormIntact"] = try definitionHash() == originalHash
                    && manager.hasUnsavedChanges && field.stringValue == invalid
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
                (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 6))
                guard await flushWorkspaceWindows(), control.workspaceSession?.preservedEditors.contains(ObjectIdentifier(manager)) == true else {
                    throw PetError("月度计划草稿未保存到窗口记录")
                }
                let fixture = MonthlyAutomationFixture(pid: getpid(), plan: plan.id, task: task, workspace: project.path, originalHash: originalHash)
                try JSONEncoder().encode(fixture).write(to: fixtureFile, options: .atomic)
                checks["importAndEditDoNotStartAnyRun"] = try service.history().total == 0 && requests == 0
            } else {
                let fixture = try JSONDecoder().decode(MonthlyAutomationFixture.self, from: Data(contentsOf: fixtureFile))
                restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(), let owner = taskControls.first(where: { $0.agentTaskID == fixture.task }),
                      let manager = owner.automationWindow, let window = owner.window else { throw PetError("原月度计划窗口未恢复") }
                window.makeKeyAndOrderFront(nil); await wait(0.14)
                let field = try controlWithLabel(window, NSTextField.self, "月内规则")
                checks["reopenRestoresRawRuleInOriginalWindowWithoutChangingSavedPlan"] = try fixture.pid != getpid()
                    && manager.hasUnsavedChanges && field.stringValue == invalid && definitionHash() == fixture.originalHash
                checks["reopenedRuleRetainsFieldFocusAndSelection"] = field.currentEditor() === window.firstResponder
                    && (field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 6)
                let presets = try controlWithLabel(window, NSPopUpButton.self, "月内规则预设")
                guard let lastDay = presets.item(withTitle: "每月最后一天"), let action = lastDay.action,
                      NSApp.sendAction(action, to: lastDay.target, from: lastDay) else { throw PetError("无法选择月末预设") }
                let preview = try controlWithLabel(window, NSTextField.self, "下次运行时间")
                checks["lastDayPresetReplacesInvalidRuleAndRefreshesPreview"] = field.stringValue == "FREQ=MONTHLY;BYMONTHDAY=-1"
                    && preview.stringValue.hasSuffix(" · 未启用") && !preview.stringValue.contains("无有效")
                try click(window, "保存")
                checks["validEditorSaveRetainsPausedStateAndWorkspace"] = !manager.hasUnsavedChanges && service.values.contains {
                    $0.id == fixture.plan && $0.workspace == fixture.workspace && !$0.enabled && $0.schedule.monthlyRule == field.stringValue
                }
                let now = Date().timeIntervalSince1970
                let scheduled = Date(timeIntervalSince1970: ceil((now + 7) / 60) * 60)
                var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
                let day = utc.component(.day, from: scheduled)
                try click(window, "设置开始时间")
                let start = try controlWithLabel(window, NSDatePicker.self, "计划起始日期和时间")
                start.dateValue = scheduled
                change("FREQ=MONTHLY;BYMONTHDAY=\(day);COUNT=1", field: field, manager: manager)
                let expected = AgentAutomations.dateText(scheduled, zone: "UTC")
                checks["pickedStartAndCountPreviewExactScheduledMinute"] = preview.stringValue == expected + " · 未启用"
                try click(window, "保存"); try click(window, "启用")
                checks["enablingArmsActualTimerWithNoPrematureRequest"] = try service.values.first(where: { $0.id == fixture.plan })?.nextRun == scheduled
                    && service.history(automationID: fixture.plan).total == 0 && requests == 0
                let deadline = scheduled.addingTimeInterval(22)
                while Date() < deadline {
                    if try service.history(automationID: fixture.plan).runs.first?.status.terminal == true { break }
                    await wait(0.16)
                }
                let runs = try service.history(automationID: fixture.plan).runs
                guard let run = runs.first, let task = run.taskID.flatMap(tasks.task) else { throw PetError(service.error ?? "实际计划运行未生成会话") }
                checks["timerLaunchesOnlyOnceAtScheduledTimeAndRecordsCompletedTask"] = runs.count == 1 && run.trigger == "schedule"
                    && run.scheduled == scheduled && run.created >= scheduled && run.created.timeIntervalSince(scheduled) < 5
                    && run.status == .completed && task.messages.contains { $0.role == "assistant" && $0.content.contains(reply) }
                    && task.automation?.readOnly == true && task.automation?.network == false && task.workspace == fixture.workspace && requests == 1
                service.stop(); service.start(store: tasks, runtime: runtime)
                checks["restartRetainsCompletedRunAndDoesNotRearmExhaustedPlan"] = try service.isStarted
                    && service.history(automationID: fixture.plan).runs.map(\.id) == [run.id]
                    && service.values.contains { $0.id == fixture.plan && !$0.enabled && $0.nextRun == nil && $0.current == nil }
                results["run"] = ["id": run.id, "task": task.id, "scheduled": expected, "status": run.status.rawValue, "elapsedSeconds": run.created.timeIntervalSince(scheduled)]
                if run.status != .completed { results["error"] = run.detail }
            }
        } catch { results["error"] = error.localizedDescription }
        results["success"] = results["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        results["checks"] = checks; results["pid"] = getpid(); results["loopbackRequests"] = requests; results["externalRequests"] = 0
        if let binary = Bundle.main.executableURL { results["binarySHA256"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        let file = output.appendingPathComponent(reopening ? "monthly-reopen.json" : "monthly-seed.json")
        try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
