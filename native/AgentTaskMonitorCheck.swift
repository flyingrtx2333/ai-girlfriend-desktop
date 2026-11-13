import AppKit

@MainActor extension AppDelegate {
    func prepareTaskMonitorUI(_ output: URL) async throws {
        guard !["--live-agent", "--attention-live-ui"].contains(where: CommandLine.arguments.contains), let tasks = agentStore,
              let index = CommandLine.arguments.firstIndex(of: "--task-monitor-source"), CommandLine.arguments.indices.contains(index + 1) else { throw PetError("任务监控验收需要公开源文件，不调用模型") }
        let project = output.appendingPathComponent("project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[index + 1]), bytes = try Data(contentsOf: source)
        try bytes.write(to: project.appendingPathComponent("README.md"))
        try await prepareTaskWindowCheck(output)
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("task-window-fixtures.json"))) as! [String: Any], ids = info["tasks"] as! [String: String], id = ids["primary"]!
        let call = AgentToolCall(id: UUID().uuidString, name: "read_file", arguments: "{\"path\":\"README.md\",\"limit\":40}")
        let read = try await AgentTools(store: tasks, taskID: id).execute(call)
        guard !read.failed else { throw PetError(read.text) }
        tasks.update(id) { value in
            value.mode = .goal; value.artifacts = [project.appendingPathComponent("README.md").path]
            value.sources = [project.appendingPathComponent("README.md").absoluteString]
            value.plan = [AgentPlanStep(title: "读取公开 README（本机工具已执行）", status: "completed"), AgentPlanStep(title: "核对任务监控展示", status: "in_progress")]
            value.events.append(AgentEvent(kind: "tool", title: "read_file", detail: read.text, status: "completed", toolCallID: call.id))
        }
        control.showAgentTask(id)
        try JSONSerialization.data(withJSONObject: ["tasks": ids, "sourceHash": AgentFiles.hash(bytes), "source": source.path, "backgroundPID": info["backgroundPID"]!, "backgroundRelease": info["backgroundRelease"]!, "modelRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-monitor-fixtures.json"))
    }
    func reopenTaskMonitorUI(_ output: URL) throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("task-monitor-fixtures.json"))) as? [String: Any]
        guard let ids = value?["tasks"] as? [String: String], let id = ids["primary"], agentStore?.task(id) != nil else { throw PetError("缺少原任务监控资料") }
        control.showAgentTask(id)
    }
    func runTaskMonitorCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        defer { control.checkTaskMonitor("stop-terminals"); agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime, usesAgent else { throw PetError("未进入独立任务监控验收") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("任务监控验收禁止模型请求") }
            try await prepareTaskMonitorUI(output)
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("task-monitor-fixtures.json"))) as! [String: Any], ids = fixture["tasks"] as! [String: String], a = ids["primary"]!, b = ids["background"]!
            let pid = (fixture["backgroundPID"] as! NSNumber).int32Value, service = taskMonitor, config = store.directory.appendingPathComponent("task-monitor.json")
            control.show(tab: "chat"); control.showAgentTask(b); control.showAgentTask(a)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let preferences = try encoder.encode(store.preferences), originals = try Dictionary(uniqueKeysWithValues: tasks.tasks.map { ($0.id, try encoder.encode(tasks.task($0.id)!)) })
            try JSONSerialization.data(withJSONObject: originals.mapValues { $0.base64EncodedString() }, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("original-task-checkpoint.json"))
            let oldNames = ["appearance.json", "theme-styles.json", "content-appearance.json", "file-icons.json", "mode-presentation.json", "sidebar.json"], oldBytes = oldNames.map { try? Data(contentsOf: store.directory.appendingPathComponent($0)) }
            checks["DefaultPreferencesNeedNoFileWrite"] = service.settings == AgentTaskMonitor.Settings() && service.error == nil && !FileManager.default.fileExists(atPath: config.path)
            control.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 774), display: false)
            let second = ControlWindow(companion: self, taskID: a, windowNumber: 2); additionalTaskWindows.append(second); second.show(tab: "chat")
            checks["ExistingTaskDefaultsToFixedMonitor"] = control.taskMonitorReadback()["dockedVisible"] as? Bool == true && control.taskMonitorReadback()["presentation"] as? String == "fixed"
            control.checkTaskMonitor("pin"); let frameA = NSRect(x: 160, y: 120, width: 340, height: 450); control.checkTaskMonitor("frame", frame: frameA)
            report["firstFloating"] = control.taskMonitorReadback()
            checks["PinOpensRealFloatingPanelWithoutChangingOtherWindow"] = control.taskMonitorReadback()["floatingVisible"] as? Bool == true && control.taskMonitorReadback()["dockedVisible"] as? Bool == false && second.taskMonitorReadback()["presentation"] as? String == "fixed" && second.taskMonitorReadback()["dockedVisible"] as? Bool == true
            control.showAgentTask(b); checks["AnotherTaskKeepsOwnDefaultAndActualBackgroundProcess"] = control.taskMonitorReadback()["presentation"] as? String == "fixed" && tasks.hooks.isRunning(b) && kill(pid, 0) == 0
            control.checkTaskMonitor("pin"); let frameB = NSRect(x: 600, y: 100, width: 320, height: 430); control.checkTaskMonitor("frame", frame: frameB)
            report["secondFloating"] = control.taskMonitorReadback()
            control.showAgentTask(a); checks["FirstTaskRestoresOwnFloatingPosition"] = control.taskMonitorReadback()["floatingFrame"] as? String == NSStringFromRect(frameA)
            control.showAgentTask(b); checks["SecondTaskRestoresDifferentFloatingPosition"] = control.taskMonitorReadback()["floatingFrame"] as? String == NSStringFromRect(frameB)
            var value = service.settings; value.sections.removeAll { $0 == .processes }; try service.save(value)
            let hiddenSections = (control.taskMonitorReadback()["floating"] as? [String: Any])?["sections"] as? [String] ?? []
            checks["HidingProcessModuleKeepsPinningAndRealProcessAlive"] = control.taskMonitorReadback()["presentation"] as? String == "floating" && !hiddenSections.contains("monitor-group-processes") && tasks.hooks.isRunning(b) && kill(pid, 0) == 0
            value.sections = AgentMonitorSection.allCases; try service.save(value)
            checks["ShowingModuleAgainUsesActualRunningHookRecord"] = ((control.taskMonitorReadback()["floating"] as? [String: Any])?["sections"] as? [String])?.contains("monitor-group-processes") == true && tasks.task(b)?.events.contains(where: { $0.kind == "hook" && $0.status == "running" }) == true
            control.showAgentTask(a); control.checkTaskMonitor("close"); checks["ClosingMonitorLeavesTaskAndHookRunning"] = control.taskMonitorReadback()["floatingVisible"] as? Bool == false && kill(pid, 0) == 0 && tasks.hooks.isRunning(b)
            control.checkTaskMonitor("toggle"); checks["ReopeningMonitorKeepsFrame"] = control.taskMonitorReadback()["floatingFrame"] as? String == NSStringFromRect(frameA) && control.taskMonitorReadback()["floatingVisible"] as? Bool == true
            control.checkTaskMonitor("pin"); control.checkTaskMonitor("terminal"); await wait(0.12)
            let terminal = control.taskMonitorReadback()["fixed"] as? [String: Any]
            checks["ActualInteractiveTerminalAppearsInMonitor"] = (terminal?["sections"] as? [String])?.contains("monitor-group-processes") == true
            control.window?.setFrame(NSRect(x: 0, y: 0, width: 780, height: 540), display: false)
            checks["ExplicitFixedMonitorFitsNarrowWindow"] = control.taskMonitorReadback()["dockedVisible"] as? Bool == true && control.taskMonitorReadback()["windowSize"] as? [CGFloat] == [780, 540]
            control.checkTaskMonitor("close"); control.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 774), display: false)
            value = service.settings; value.dockedDefaultVisible = false; try service.save(value)
            let new = tasks.create(title: "默认隐藏的任务", workspace: tasks.task(a)?.workspace); control.showAgentTask(new)
            checks["NewTaskHonorsDefaultHiddenPreference"] = control.taskMonitorReadback()["dockedVisible"] as? Bool == false
            control.checkTaskMonitor("toggle"); checks["EmptyTaskCanExplicitlyOpenAndCloseMonitor"] = control.taskMonitorReadback()["dockedVisible"] as? Bool == true; control.checkTaskMonitor("close")
            let before = try runtime.taskPreferences(a), inherited = try runtime.analysisPreferences(a, model: nil), custom = try runtime.analysisPreferences(a, model: "monitor-model-check")
            checks["RecapModelResolutionPreservesSessionPreferencesAndBudget"] = try inherited.model == before.model && custom.model == "monitor-model-check" && custom.contextLimit == before.contextLimit && custom.outputLimit == before.outputLimit && encoder.encode(store.preferences) == preferences && tasks.task(a)?.modelOverride == nil
            var refused = false; do { _ = try runtime.analysisPreferences(a, model: "bad\nmodel") } catch { refused = true }; checks["InvalidRecapModelRejectedBeforeTransmission"] = refused
            func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
            guard control.showSettingsCategory("monitor"), let root = control.window?.contentView else { throw PetError("任务监控设置不可见") }
            let popups = descendants(root).compactMap { $0 as? NSPopUpButton }
            guard let form = popups.first(where: { $0.identifier?.rawValue == "monitor-presentation" }), let visibility = popups.first(where: { $0.identifier?.rawValue == "monitor-default-visible" }) else { throw PetError("监控展示控件缺失") }
            let toggles = descendants(root).compactMap { $0 as? NSSwitch }.filter { $0.identifier?.rawValue.hasPrefix("monitor-section-") == true }
            checks["SettingsHaveBothPresentationsAndThirteenAccessibleModules"] = form.itemTitles == ["固定", "浮动"] && visibility.itemTitles == ["默认展示", "默认隐藏"] && toggles.count == 13 && toggles.allSatisfy { $0.accessibilityLabel()?.isEmpty == false }
            form.selectItem(at: 1); _ = form.sendAction(form.action, to: form.target)
            checks["FloatingPreferenceDisablesFixedDefaultControl"] = service.settings.presentation == .floating && !visibility.isEnabled
            let saved = service.settings, bytes = try Data(contentsOf: config)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config.path); form.selectItem(at: 0); _ = form.sendAction(form.action, to: form.target)
            checks["ReadOnlySaveRestoresControlAndKeepsBytes"] = try service.settings == saved && form.indexOfSelectedItem == 1 && Data(contentsOf: config) == bytes
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path); form.selectItem(at: 0); _ = form.sendAction(form.action, to: form.target)
            checks["SameControlSavesAfterPermissionRestored"] = service.settings.presentation == .fixed && visibility.isEnabled
            checks["PrivatePreferencesReloadExactly"] = try AgentTaskMonitor(directory: store.directory).settings == service.settings && (FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            var external = service.settings; external.presentation = .floating; let externalBytes = try encoder.encode(external); try externalBytes.write(to: config); refused = false
            do { try service.save(external) } catch { refused = true }; checks["ExternalEditCannotBeOverwrittenByStaleSettings"] = try refused && Data(contentsOf: config) == externalBytes && service.settings.presentation == .fixed
            service.reload(); service.apply(); checks["ExplicitReloadUpdatesExistingSettingsControls"] = service.error == nil && form.indexOfSelectedItem == 1
            let base: [String: Any] = ["version": 1, "presentation": "fixed", "dockedDefaultVisible": true, "sections": AgentMonitorSection.allCases.map(\.rawValue)]
            for key in ["version", "missing", "extra", "presentation", "boolean", "duplicate", "section", "model"] {
                var bad = base
                switch key { case "version": bad["version"] = 2; case "missing": bad.removeValue(forKey: "sections"); case "extra": bad["unknown"] = true; case "presentation": bad["presentation"] = "unknown"; case "boolean": bad["dockedDefaultVisible"] = "true"; case "duplicate": bad["sections"] = ["goal", "goal"]; case "section": bad["sections"] = ["unknown"]; default: bad["recapModel"] = "bad\nmodel" }
                let directory = output.appendingPathComponent("invalid-" + key); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false); let target = directory.appendingPathComponent("task-monitor.json"), data = try JSONSerialization.data(withJSONObject: bad); try data.write(to: target)
                let guarded = AgentTaskMonitor(directory: directory); refused = false; do { try guarded.save(.init()) } catch { refused = true }; checks["Invalid-" + key + "KeepsBytesAndRefusesSave"] = try guarded.error != nil && refused && Data(contentsOf: target) == data
            }
            let linked = output.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false); try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("task-monitor.json"), withDestinationURL: config); checks["SymlinkConfigurationRejected"] = AgentTaskMonitor(directory: linked).error != nil
            var sample = AgentTaskRecord(title: "组件固定样例"); sample.mode = .goal; sample.messages = [AgentMessage(role: "user", content: "组件字段样例")]; sample.recap = AgentTaskRecap(model: "component-fixture", text: "仅用于组件排版的固定样例，不是模型输出")
            sample.plan = [AgentPlanStep(title: "组件计划")]; sample.artifacts = ["README.md"]; sample.sources = ["https://example.com"]
            sample.events = [AgentEvent(kind: "tool", title: "list_mcp_servers", status: "completed"), AgentEvent(kind: "tool", title: "read_project_knowledge", status: "completed"), AgentEvent(kind: "tool", title: "write_memory", status: "completed")]
            let view = AgentTaskInspector(frame: NSRect(x: 0, y: 0, width: 300, height: 600)); var component = AgentMonitorContent(task: sample)
            component.children = [AgentTaskRecord(title: "子智能体字段")]; component.sideChats = [AgentTaskRecord(title: "侧聊字段")]; component.terminals = [.init(id: "component", title: "终端字段", detail: "组件样例")]; component.pages = [.init(id: "component", title: "网页字段", detail: "https://example.com")]; component.previewTitle = "浏览器"
            for section in AgentMonitorSection.allCases { component.settings.sections = [section]; view.update(component); checks["Module-" + section.rawValue + "ShowsOnlyItsActualFields"] = view.readback()["sections"] as? [String] == ["monitor-group-" + section.rawValue] }
            component.settings.sections = [.outputs]; var opens = 0; view.onOpen = { _, _ in opens += 1 }; view.update(component)
            guard let stale = descendants(view).compactMap({ $0 as? AgentInspectorFileButton }).first else { throw PetError("缺少产出操作") }; _ = stale.sendAction(stale.action, to: stale.target); let firstOpen = opens
            component.missingArtifacts = ["README.md"]; view.update(component)
            let missing = descendants(view).compactMap { $0 as? AgentInspectorFileButton }.first
            checks["MissingArtifactIsDisabledAndIdentified"] = missing?.isEnabled == false && missing?.accessibilityLabel()?.contains("文件已移动或删除") == true
            view.update(AgentMonitorContent(task: AgentTaskRecord(title: "另一组件任务"))); _ = stale.sendAction(stale.action, to: stale.target); checks["DetachedOldFileActionCannotAffectAnotherTask"] = firstOpen == 1 && opens == firstOpen
            checks["AllSixLegacyPreferenceFilesUnchanged"] = oldNames.map { try? Data(contentsOf: store.directory.appendingPathComponent($0)) } == oldBytes
            var changedFields: [String: [String]] = [:]
            for (id, data) in originals {
                let before = try JSONSerialization.jsonObject(with: data) as! [String: Any], after = try JSONSerialization.jsonObject(with: encoder.encode(tasks.task(id)!)) as! [String: Any]
                let keys = Set(before.keys).union(after.keys).filter { (try? JSONSerialization.data(withJSONObject: before[$0] ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])) != (try? JSONSerialization.data(withJSONObject: after[$0] ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])) }.sorted()
                if !keys.isEmpty { changedFields[id] = keys }
            }
            report["changedOriginalTaskFields"] = changedFields
            checks["AllOriginalTasksAndDraftsUnchangedByPreferences"] = try originals.allSatisfy { id, data in try encoder.encode(tasks.task(id)!) == data }
            try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: originals.keys.map { ($0, try encoder.encode(tasks.task($0)!).base64EncodedString()) }), options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("final-task-checkpoint.json"))
            checks["BackgroundProcessStillAliveAfterAllDisplayChanges"] = tasks.hooks.isRunning(b) && kill(pid, 0) == 0
            checks["ActualPublicSourceBytesRemainExact"] = try AgentFiles.hash(Data(contentsOf: URL(fileURLWithPath: tasks.task(a)!.workspace!).appendingPathComponent("README.md"))) == fixture["sourceHash"] as? String
            report["boundary"] = "Actual public file read, local background Hook and interactive terminal; fixed component fixtures verify module rendering only. No model-generated recap or assistant reply is claimed."
            report["states"] = [control.taskMonitorReadback(), second.taskMonitorReadback()]; report["backgroundPID"] = pid
            report["success"] = checks.count >= 40 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-monitor-report.json"))
    }
}
