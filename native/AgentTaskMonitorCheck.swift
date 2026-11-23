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
    func prepareWorkbenchStates(_ output: URL) async throws -> [String: String] {
        let data = try Data(contentsOf: output.appendingPathComponent("task-monitor-fixtures.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tasks = agentStore, let runtime = agentRuntime, let ids = fixture?["tasks"] as? [String: String],
              let primary = ids["primary"], let running = ids["background"], runtime.isRunning(running),
              let workspace = tasks.task(primary)?.workspace else { throw PetError("缺少独立监控样例") }
        let project = URL(fileURLWithPath: workspace, isDirectory: true)
        let command = AgentCommand()
        let branch = "review/public-readme-check-with-a-long-descriptive-branch-name"
        let git = try await command.run(command: try AgentGit.executablePath(), workspace: project, scratch: output, network: false, timeout: 5, gitWrite: true, arguments: ["init", "--quiet", "--initial-branch", branch])
        guard !git.failed else { throw PetError(git.text) }
        let empty = tasks.tasks.first(where: { $0.title == "新的任务" && $0.workspace == nil && $0.status == .ready })?.id ?? tasks.create()
        let waiting = tasks.create(title: "确认公开说明核对命令", workspace: workspace)
        let longApproval = tasks.create(title: "审阅长命令和完整参数", workspace: workspace)
        let question = tasks.create(title: "选择要核对的说明章节", workspace: workspace)
        let browserApproval = tasks.create(title: "核对待审批的网页链接", workspace: workspace)
        let failed = tasks.create(title: "逐项核对公开说明的安装章节、依赖版本和示例命令是否齐全", workspace: workspace)
        let completed = tasks.create(title: "已读取公开项目说明", workspace: workspace)
        let read = AgentToolCall(id: UUID().uuidString, name: "read_file", arguments: "{\"path\":\"README.md\",\"limit\":2}")
        let proof = try await AgentTools(store: tasks, taskID: completed).execute(read)
        guard !proof.failed, proof.text.contains("README.md") else { throw PetError("未读到公开 README") }
        let missing = AgentToolCall(id: UUID().uuidString, name: "read_file", arguments: "{\"path\":\"missing-readme.md\"}")
        let failure: String
        do {
            let result = try await AgentTools(store: tasks, taskID: failed).execute(missing)
            failure = result.failed ? result.text : ""
        } catch { failure = error.localizedDescription }
        guard !failure.isEmpty else { throw PetError("缺失文件样例未返回错误") }
        let approval = AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: "{\"command\":\"/usr/bin/wc -c README.md\",\"network\":false}")
        let longCommand = (1...14).map { "/usr/bin/wc -c README.md # 核对公开样例的第 \($0) 行" }.joined(separator: "\n")
        let longArguments = try JSONSerialization.data(withJSONObject: ["command": longCommand + "\n# 格式字符\u{202E}", "network": true,
                                                                       "timeout_seconds": 17], options: [.sortedKeys])
        let longCall = AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: String(decoding: longArguments, as: UTF8.self))
        let questionCall = AgentToolCall(id: UUID().uuidString, name: "ask_user", arguments: "{\"question\":\"请确认要核对 README 的安装、运行还是许可章节。\"}")
        let browserCall = AgentToolCall(id: UUID().uuidString, name: "browser_open", arguments: "{\"url\":\"https://example.test/notes\"}")
        tasks.update(running) { task in
            task.status = .running; task.draft = ""
            task.messages = [AgentMessage(role: "user", content: "继续核对公开 README 的后台记录。")]
        }
        tasks.update(waiting) { task in
            task.status = .waiting; task.pendingCalls = [approval]
            task.approvals = [AgentApproval(call: approval, reason: "确认后统计 README.md 的字节数", workspace: workspace)]
            task.messages = [AgentMessage(role: "user", content: "统计公开 README 的字节数，执行前先确认。")]
        }
        tasks.update(longApproval) { task in
            task.status = .waiting; task.pendingCalls = [longCall]
            task.approvals = [AgentApproval(call: longCall, reason: "核对多行终端命令\n所有命令只读取公开 README。", workspace: workspace)]
            task.messages = [AgentMessage(role: "user", content: "请先完整展示命令和超时设置。")]
            task.draft = "这段补充还未发送。"
        }
        tasks.update(question) { task in
            task.status = .waiting; task.pendingCalls = [questionCall]
            task.approvals = [AgentApproval(call: questionCall, reason: "选择章节", workspace: workspace)]
            task.messages = [AgentMessage(role: "user", content: "先问我需要核对哪个章节。")]
        }
        tasks.update(browserApproval) { task in
            task.status = .waiting; task.pendingCalls = [browserCall]
            task.approvals = [AgentApproval(call: browserCall, reason: "仅在确认后打开 " + String(repeating: "公开路径/", count: 40) + "最终页面", workspace: workspace)]
            task.messages = [AgentMessage(role: "user", content: "先审阅完整的访问地址。")]
        }
        tasks.update(failed) { task in
            task.status = .failed; task.events = [AgentEvent(kind: "tool", title: "read_file", detail: failure, status: "failed", toolCallID: missing.id)]
            task.messages = [AgentMessage(role: "user", content: "读取项目补充说明 missing-readme.md。"), AgentMessage(role: "assistant", content: "", toolCalls: [missing])]
        }
        tasks.update(completed) { task in
            task.status = .completed; task.events = [AgentEvent(kind: "tool", title: "read_file", detail: proof.text, status: "completed", toolCallID: read.id)]
            task.messages = [AgentMessage(role: "user", content: "读取公开 README 的头两行。"), AgentMessage(role: "assistant", content: "", toolCalls: [read]), AgentMessage(role: "assistant", content: "已读到 README.md。\n\n```text\n\(proof.text.trimmingCharacters(in: .whitespacesAndNewlines))\n```")]
        }
        if let issue = tasks.writeError { throw PetError(issue) }
        let states = ["primary": primary, "empty": empty, "running": running, "waiting": waiting, "failed": failed,
                      "completed": completed, "longApproval": longApproval, "question": question, "browserApproval": browserApproval]
        let report: [String: Any] = ["tasks": states, "appPID": getpid(), "branch": branch, "sourceHash": fixture?["sourceHash"] as? String ?? "", "modelRequests": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workbench-state-fixtures.json"), options: .atomic)
        control.showAgentTask(primary)
        return states
    }
    func runTaskMonitorCheck(_ output: URL) async {
        if CommandLine.arguments.contains("--task-monitor-recovery-check") {
            await runTaskMonitorRecoveryCheck(output)
            return
        }
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
            checks["MonitorCheckUsesIndependentSharedHome"] = tasks.extensions.sharedHome?.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").resolvingSymlinksInPath()
            checks["DefaultPreferencesNeedNoFileWrite"] = service.settings == AgentTaskMonitor.Settings() && service.error == nil && !FileManager.default.fileExists(atPath: config.path)
            control.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 774), display: false)
            let second = ControlWindow(companion: self, taskID: a, windowNumber: 2); additionalTaskWindows.append(second); second.show(tab: "chat")
            checks["ExistingTaskDefaultsToFixedMonitor"] = control.taskMonitorReadback()["dockedVisible"] as? Bool == true && control.taskMonitorReadback()["presentation"] as? String == "fixed"
            control.checkTaskMonitor("pin"); let frameA = NSRect(x: 160, y: 120, width: 340, height: 450); control.checkTaskMonitor("frame", frame: frameA)
            report["firstFloating"] = control.taskMonitorReadback()
            checks["PinOpensRealFloatingPanelWithoutChangingOtherWindow"] = control.taskMonitorReadback()["floatingVisible"] as? Bool == true && control.taskMonitorReadback()["dockedVisible"] as? Bool == false && second.taskMonitorReadback()["presentation"] as? String == "fixed" && second.taskMonitorReadback()["dockedVisible"] as? Bool == true
            _ = control.showSettingsCategory("monitor"); control.show(tab: "chat"); await wait(0.1)
            let returned = control.taskMonitorReadback()
            checks["FloatingMonitorReattachesToOwnerAfterSettingsReturn"] = returned["floatingOwner"] as? Int == returned["ownerNumber"] as? Int && returned["floatingVisible"] as? Bool == true && returned["floatingFrame"] as? String == NSStringFromRect(frameA)
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
            checks["ImmediateSettingsHaveNoUnrelatedGlobalSaveButton"] = !descendants(root).contains { ($0 as? NSButton)?.title == "保存" && !$0.isHiddenOrHasHiddenAncestor }
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
            control.checkTaskMonitor("stop-terminals")
            try service.save(.init())
            let workbenchStates = try await prepareWorkbenchStates(output)
            let layout = await control.checkWorkbenchStates(workbenchStates)
            checks.merge(layout.checks) { _, new in new }
            report["workbenchGeometry"] = layout.frames
            checks["WorkbenchProcessRemainsLiveAcrossTaskNavigation"] = runtime.isRunning(b) && kill(pid, 0) == 0
            for (key, pass) in try await checkMonitorSources(output) { checks["Source-" + key] = pass }
            report["boundary"] = "Actual public file read, local background Hook and interactive terminal; fixed component fixtures verify module rendering only. No model-generated recap or assistant reply is claimed."
            report["states"] = [control.taskMonitorReadback(), second.taskMonitorReadback()]; report["backgroundPID"] = pid
            report["success"] = checks.count >= 40 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-monitor-report.json"))
    }

    private struct TaskMonitorFixture: Codable {
        let first: String, other: String, primaryWindow: String, secondaryWindow: String
        let primary: AgentTaskMonitor.DisplayState, secondary: AgentTaskMonitor.DisplayState
        let readmeHash: String
    }

    private func runTaskMonitorRecoveryCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, let host = control.window else { throw PetError("任务工作台不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("监控恢复验收禁止模型请求") }
            let storage = AgentWorkspaceRecovery(profile: store.directory)
            let stage = CommandLine.arguments.last
            let workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path)
            let readme = try files.resolve("README.md"), source = try String(contentsOf: readme, encoding: .utf8)
            let fixtureFile = output.appendingPathComponent("monitor-fixture.json"), draft = "保留待发送的任务输入"
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func pane(_ window: NSWindow) throws -> AgentTaskInspector {
                window.contentView?.layoutSubtreeIfNeeded()
                guard let root = window.contentView, let pane = descendants(root).compactMap({ $0 as? AgentTaskInspector }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else {
                    throw PetError("原窗口的监控面板不可见")
                }
                return pane
            }
            func floating(_ owner: ControlWindow) throws -> AgentTaskMonitorPanel {
                guard let panel = owner.window?.childWindows?.compactMap({ $0 as? AgentTaskMonitorPanel }).first(where: \.isVisible) else {
                    throw PetError("原窗口的浮动监控不可见")
                }
                return panel
            }
            func click(_ name: String, in pane: AgentTaskInspector) throws {
                guard let button = descendants(pane).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == name && !$0.isHiddenOrHasHiddenAncestor }),
                      button.isEnabled else { throw PetError("找不到监控操作 " + name) }
                button.performClick(nil)
                pane.window?.contentView?.layoutSubtreeIfNeeded()
            }
            func geometry(_ group: String, in pane: AgentTaskInspector) throws -> (NSScrollView, NSRect) {
                pane.window?.contentView?.layoutSubtreeIfNeeded()
                let children = descendants(pane)
                guard let scroll = children.compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView,
                      let heading = children.first(where: { $0.identifier?.rawValue == "monitor-group-" + group }) else {
                    throw PetError("监控分组不可见 " + group)
                }
                return (scroll, heading.convert(heading.bounds, to: document))
            }
            func scrollTo(_ group: String, in pane: AgentTaskInspector) throws {
                let (scroll, frame) = try geometry(group, in: pane)
                let clip = scroll.contentView
                var bounds = clip.bounds
                bounds.origin.y = frame.minY + 4
                clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(clip)
            }
            func isReading(_ group: String, in pane: AgentTaskInspector) throws -> Bool {
                let (scroll, frame) = try geometry(group, in: pane)
                return abs(scroll.contentView.bounds.minY - frame.minY - 4) < 12
            }
            func screenshot(_ window: NSWindow, _ name: String) throws {
                guard let view = window.contentView, window.isVisible, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw PetError("无法读取监控窗口")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("监控窗口无法绘制") }
                try png.write(to: output.appendingPathComponent(name + ".png"))
            }
            let fixture: TaskMonitorFixture
            control.show(tab: "chat")
            if stage == "seed" {
                let artifacts = try ["README.md", "docs/AGENT-READING.md", "docs/AGENT-PLAN.md", "docs/DEVELOPMENT.md",
                                     "docs/REPO-WIKI.md", "docs/ROADMAP.md", "docs/QODER-UI-SPEC.md", "package.json"].map { try files.resolve($0).path }
                let a = tasks.create(title: "核对公开项目说明的交付项", workspace: workspace.path, mode: .goal)
                let b = tasks.create(title: "检查任务之间的监控位置", workspace: workspace.path, mode: .goal)
                for id in [a, b] {
                    tasks.update(id) { task in
                        task.messages = [AgentMessage(role: "user", content: String(source.prefix(880)))]
                        task.plan = ["核对项目入口", "检查运行方式", "核对构建参数", "定位安装说明", "核对示例与许可"].map { AgentPlanStep(title: $0) }
                        task.artifacts = artifacts
                        task.sources = (1...10).map { "https://example.test/guide/\($0)" }
                        task.draft = draft
                    }
                }
                host.appearance = NSAppearance(named: .darkAqua)
                host.setContentSize(NSSize(width: 780, height: 540))
                control.showAgentTask(a)
                control.checkTaskMonitor("toggle")
                let fixed = try pane(host)
                try click("展开全文", in: fixed)
                try click("计划 0/5", in: fixed)
                try scrollTo("plan", in: fixed)
                checks["fixingAndScrollingShowsTheActualPlanGroup"] = try isReading("plan", in: fixed)
                checks["previouslyExpandedTextAndCollapsedPlanAreRecorded"] = control.captureTaskMonitorStates()[a]?.reading.expanded == ["goal"] &&
                    control.captureTaskMonitorStates()[a]?.reading.collapsed == ["plan"]
                control.showAgentTask(b)
                control.checkTaskMonitor("toggle")
                checks["newTaskOpensMonitorAtItsOwnStart"] = try (pane(host).readback()["scrollY"] as? CGFloat ?? -1) == 0
                control.checkTaskMonitor("close")
                control.showAgentTask(a)
                checks["switchingBackReturnsToOriginalPlanGroup"] = try isReading("plan", in: pane(host))
                tasks.update(a) { $0.messages[0].content += "\n\n" + String(source.prefix(420)) }
                control.scheduleRender()
                await wait(0.25)
                checks["insertingRowsAboveDoesNotMoveTheViewedGroup"] = try isReading("plan", in: pane(host))
                try screenshot(host, "monitor-fixed-narrow")
                openTaskWindow(a, from: control)
                guard let second = additionalTaskWindows.last, let secondWindow = second.window else { throw PetError("第二个任务窗口未打开") }
                secondWindow.appearance = NSAppearance(named: .aqua)
                secondWindow.setContentSize(NSSize(width: 1320, height: 800))
                second.checkTaskMonitor("pin")
                let panel = try floating(second)
                let frame = NSRect(x: panel.frame.minX - 70, y: panel.frame.minY, width: panel.frame.width, height: 420)
                panel.setFrame(frame, display: true)
                try click("任务目标", in: pane(panel))
                try scrollTo("outputs", in: pane(panel))
                checks["monitorReadingAndPresentationAreIndependentInTheSecondWindow"] = try isReading("outputs", in: pane(panel)) &&
                    second.captureTaskMonitorStates()[a]?.reading.collapsed == ["goal"] &&
                    control.captureTaskMonitorStates()[a]?.reading.collapsed == ["plan"]
                guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let secondID = second.workspaceSession?.id,
                      let mainRecord = try storage.loadTaskMonitor(windowID: mainID), let secondRecord = try storage.loadTaskMonitor(windowID: secondID),
                      let primary = mainRecord.value.tasks[a], let secondary = secondRecord.value.tasks[a] else {
                    throw PetError("两扇窗口的任务监控位置没有保存")
                }
                checks["fixedAndFloatingRecordsContainTheirOwnAnchorsAndTheClosedTask"] = primary.reading.position?.row == "plan" &&
                    secondary.reading.position?.row == "outputs" && secondary.frame?.rect == panel.frame &&
                    mainRecord.value.tasks[b]?.explicitVisibility == true && mainRecord.value.tasks[b]?.visible == false
                let file = store.directory.appendingPathComponent("workspace-recovery/" + mainID + "/task-monitor.json")
                let original = try Data(contentsOf: file), manager = FileManager.default
                guard let layout = try storage.loadWindow(mainID) else { throw PetError("缺少原窗口布局") }
                try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
                do {
                    _ = try storage.saveTaskMonitor(mainRecord.value, layoutHash: layout.hash, expected: mainRecord.hash)
                    checks["readOnlyMonitorRecordRetainsBytes"] = false
                } catch { checks["readOnlyMonitorRecordRetainsBytes"] = try Data(contentsOf: file) == original }
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                fixture = .init(first: a, other: b, primaryWindow: mainID, secondaryWindow: secondID,
                                primary: primary, secondary: secondary, readmeHash: try files.fileHash(readme))
                try JSONEncoder().encode(fixture).write(to: fixtureFile, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(TaskMonitorFixture.self, from: Data(contentsOf: fixtureFile))
                restoreAdditionalWorkspaceWindows()
                guard let second = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.secondaryWindow }),
                      control.workspaceSession?.id == fixture.primaryWindow, control.agentTaskID == fixture.first, second.agentTaskID == fixture.first else {
                    throw PetError("原任务窗口没有恢复")
                }
                host.appearance = NSAppearance(named: .darkAqua)
                report["reopenedWindows"] = [control.taskMonitorReadback(), second.taskMonitorReadback()]
                let fixed = try pane(host)
                let panel = try floating(second)
                second.window?.appearance = NSAppearance(named: .aqua)
                panel.appearance = NSAppearance(named: .aqua)
                checks["fixedMonitorReopensAtOriginalGroupInTheNarrowWindow"] = try isReading("plan", in: fixed) && host.frame.width == 780 &&
                    control.captureTaskMonitorStates()[fixture.first]?.reading == fixture.primary.reading
                checks["secondaryFloatingMonitorRestoresFrameAndDifferentReadingPosition"] = try isReading("outputs", in: pane(panel)) &&
                    fixture.secondary.frame?.rect == panel.frame && second.captureTaskMonitorStates()[fixture.first]?.reading == fixture.secondary.reading
                try screenshot(panel, "monitor-floating-reopened")
                try screenshot(host, "monitor-fixed-reopened")
                try click("改为浮动", in: fixed)
                checks["changingPresentationKeepsTheGroupAndFoldedSections"] = try isReading("plan", in: pane(floating(control))) &&
                    control.captureTaskMonitorStates()[fixture.first]?.reading.collapsed == ["plan"]
                try click("固定到任务右侧", in: pane(floating(control)))
                checks["returningToFixedKeepsTheSameReadingPosition"] = try isReading("plan", in: pane(host))
                control.showAgentTask(fixture.other)
                host.setContentSize(NSSize(width: 1320, height: 800))
                checks["explicitlyClosedMonitorStaysClosedEvenInWideWindow"] = control.taskMonitorReadback()["dockedVisible"] as? Bool == false &&
                    control.taskMonitorReadback()["floatingVisible"] as? Bool == false && control.captureTaskMonitorStates()[fixture.other]?.visible == false
                control.showAgentTask(fixture.first)
                checks["wideFixedMonitorPreservesTheSamePlanGroup"] = try isReading("plan", in: pane(host))
                try screenshot(host, "monitor-fixed-wide")
            }
            checks["originalPublicReadmeAndDraftsAreUnchanged"] = try files.fileHash(readme) == fixture.readmeHash &&
                [fixture.first, fixture.other].allSatisfy { tasks.task($0)?.draft == draft && (tasks.task($0)?.modelReceipts ?? []).isEmpty }
            checks["globalMonitorDefaultsWereNotWritten"] = !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("task-monitor.json").path)
            checks["allWindowStatesCheckpointed"] = await flushWorkspaceWindows()
        } catch { report["error"] = error.localizedDescription }
        report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["modelRequests"] = requests; report["checks"] = checks
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && requests == 0
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-monitor-report.json"))
    }
}

@MainActor private extension AppDelegate {
    func checkMonitorSources(_ output: URL) async throws -> [String: Bool] {
        guard let tasks = agentStore, let runtime = agentRuntime, let host = control.window else { throw PetError("来源验收缺少任务窗口") }
        var checks: [String: Bool] = [:]
        defer { host.cancelAgentDialog() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func field(_ name: String, _ form: AgentDialogController) throws -> NSTextField {
            guard let value = descendants(form.view).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == name }) else { throw PetError("缺少来源字段：" + name) }; return value
        }
        func click(_ title: String, _ form: AgentDialogController) throws {
            guard let button = descendants(form.view).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw PetError("缺少来源操作：" + title) }; _ = button.sendAction(button.action, to: button.target)
        }
        func waitForClose() async throws {
            let deadline = Date().addingTimeInterval(3)
            while host.agentDialog != nil, Date() < deadline { await wait(0.03) }
            guard host.agentDialog == nil else { throw PetError("来源表单没有关闭") }; await wait(0.05)
        }
        let id = tasks.create(title: "无工作区来源验收", mode: .ask), draft = "保留原有中文草稿 🧭"
        tasks.update(id) { $0.draft = draft }; control.showAgentTask(id); control.show(tab: "chat")
        let file = tasks.directory.appendingPathComponent(id + ".json"), before = try Data(contentsOf: file)
        control.checkTaskMonitor("source-link")
        guard let sheet = host.agentDialog else { throw PetError("链接表单没有打开") }
        let input = try field("链接地址", sheet)
        checks["LinkUsesStyledOwnedFormAndAddAction"] = sheet.isVisible && sheet.view is AgentThemeView && sheet.view.window === host && host.attachedSheet == nil && NSApp.modalWindow == nil
        for invalid in ["file:///tmp/local", "javascript:alert(1)", "https://user:pass@example.com/", "https://", "https://example.com/line\nbreak"] {
            input.stringValue = invalid; try click("添加", sheet)
            checks["InvalidLink-" + String(checks.count)] = try host.agentDialog === sheet && input.stringValue == invalid && !field("链接状态", sheet).stringValue.isEmpty && Data(contentsOf: file) == before && tasks.task(id)?.sourceReferences.isEmpty == true
        }
        input.stringValue = "https://example.com/cancelled"; try click("取消", sheet); try await waitForClose()
        checks["CancelKeepsTaskBytesAndDraftExact"] = try Data(contentsOf: file) == before && tasks.task(id)?.draft == draft
        let link = "https://example.com/notes?lang=zh#part"
        control.checkTaskMonitor("source-link"); guard let added = host.agentDialog else { throw PetError("无法重开链接表单") }
        try field("链接地址", added).stringValue = "  " + link + "  "; try click("添加", added); try await waitForClose()
        checks["LinkAppendsOnlyToOriginalUnsentDraft"] = tasks.task(id)?.draft == draft + "\n\n" + link && tasks.task(id)?.messages.isEmpty == true && tasks.task(id)?.sourceReferences.isEmpty == true
        let once = try Data(contentsOf: file); try control.appendSourceLink(link, taskID: id)
        checks["DuplicateLinkDoesNotWriteOrDuplicateDraft"] = try Data(contentsOf: file) == once && tasks.task(id)?.draft == draft + "\n\n" + link
        control.checkTaskMonitor("source-link"); guard let retry = host.agentDialog else { throw PetError("缺少来源保存重试表单") }
        let second = "https://example.com/retained"
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        try field("链接地址", retry).stringValue = second; try click("添加", retry)
        checks["ReadOnlySaveKeepsDiskAndRetainsPendingDraft"] = try Data(contentsOf: file) == once && host.agentDialog === retry && tasks.task(id)?.draft?.hasSuffix(second) == true && field("链接状态", retry).stringValue.contains("尚未保存")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); try click("添加", retry); try await waitForClose()
        let expected = draft + "\n\n" + link + "\n\n" + second
        checks["RetrySavesRetainedLinkOnlyOnce"] = tasks.task(id)?.draft == expected && tasks.task(id)?.sourceReferences.isEmpty == true
        let attachment = try await AgentAttachments.importFile(output.appendingPathComponent("project/README.md"), store: tasks, taskID: id)
        checks["DraftFileIsNotYetAConversationSource"] = tasks.task(id)?.sourceReferences.isEmpty == true
        guard runtime.submit(expected, taskID: id, attachmentIDs: [attachment.id], startImmediately: false), let sent = tasks.task(id) else { throw PetError("来源验收的本地用户输入未保存") }
        checks["SentLinksAndActualFileReceiptBecomeSourcesWithoutModelCall"] = sent.sourceReferences.contains(link) && sent.sourceReferences.contains(second) && sent.sourceReferences.contains("attachment://" + attachment.id + "/part/1") && sent.messages.count == 1 && sent.messages[0].isHumanInput && sent.sources.isEmpty
        var rejected = sent; rejected.messages[0].hookRejected = true; var context = sent; context.messages[0].nativeContext = true; var assistant = sent; assistant.messages[0].role = "assistant"
        checks["RejectedContextAndAssistantTextAreNotInputSources"] = rejected.sourceReferences.isEmpty && context.sourceReferences.isEmpty && assistant.sourceReferences.isEmpty
        checks["HTTPParserKeepsOnlyExplicitValidLinks"] = try AgentSourceLinks.inText("参考 https://example.com/a 以及 ftp://example.com/other") == ["https://example.com/a"] && AgentSourceLinks.url("HTTPS://example.com/a").scheme == "https"
        var readonly = sent; readonly.archived = true; var managed = sent; managed.kind = "hook"
        checks["UnavailableTasksCannotAddSources"] = !readonly.canAddSources && !managed.canAddSources && sent.canAddSources && sent.workspace == nil
        let sentBytes = try Data(contentsOf: file); var refused = false
        do { try control.appendSourceLink("https://example.com/wrong-task", taskID: "not-the-selected-task") } catch { refused = true }
        checks["StaleTaskCannotReceiveLink"] = try refused && Data(contentsOf: file) == sentBytes
        return checks
    }
}
