import AppKit

@MainActor extension AppDelegate {
    func runAgentTaskArchiveCheck(_ output: URL) async {
        if CommandLine.arguments.contains("--archive-scope-check") { await runArchiveScopeCheck(output); return }
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Actual local tasks, project files, checkpoint bytes and background shell process. No model requests, fabricated assistant messages or fabricated execution states."]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("归档检查不调用模型") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            var requests = 0; runtime.modelRequestCheck = { requests += 1; throw PetError("归档验收禁止模型请求") }
            let fm = FileManager.default, alpha = output.appendingPathComponent("projects/alpha"), beta = output.appendingPathComponent("projects/beta"), empty = output.appendingPathComponent("projects/empty"), organization = tasks.organization
            let defaults = tasks.tasks.map(\.id)
            let a = tasks.create(title: "查看项目说明", workspace: alpha.path), b = tasks.create(title: "核对配置", workspace: alpha.path), old = tasks.create(title: "旧归档", workspace: alpha.path), other = tasks.create(title: "终端调查", workspace: beta.path), none = tasks.create(title: "未关联任务"), general = tasks.create(title: "整理资料", workspace: alpha.path, workMode: .general)
            tasks.update(a) { $0.draft = "保留的编程草稿"; $0.pinned = true }; tasks.update(general) { $0.draft = "保留的通用草稿" }
            guard runtime.submit("只查看项目说明。", taskID: a, startImmediately: false) else { throw PetError("真实用户输入未保存") }
            for (path, mode) in [(alpha.path, AgentWorkMode.coding), (beta.path, .coding), (empty.path, .coding), (alpha.path, .general)] { try organization.register(path, mode: mode) }
            try organization.rename(alpha.path, mode: .coding, name: "Alpha 项目", tasks: tasks.tasks); try organization.rename(beta.path, mode: .coding, name: "Beta 项目", tasks: tasks.tasks)
            try tasks.setArchived(defaults + [old], archived: true)
            tasks.selectedID = a
            let original = tasks.task(a)!, generalBytes = try Data(contentsOf: tasks.directory.appendingPathComponent(general + ".json"))
            let checkpoint = try tasks.backupDirectory(a).appendingPathComponent("README-copy.md"), checkpointData = try Data(contentsOf: alpha.appendingPathComponent("README.md")); try checkpointData.write(to: checkpoint)
            try tasks.setArchived([a, b], archived: true)
            let archivedBytes = try Data(contentsOf: tasks.directory.appendingPathComponent(a + ".json"))
            var rejected = 0
            for text in ["归档后不能加入输入", "/compact"] { if !runtime.submit(text, taskID: a, startImmediately: false), runtime.submissionError?.contains("已归档") == true { rejected += 1 } }
            checks["archivedTaskRejectsNormalAndCommandInputsWithoutChangingBytes"] = try rejected == 2 && Data(contentsOf: tasks.directory.appendingPathComponent(a + ".json")) == archivedBytes && !runtime.isBusy(a) && requests == 0
            checks["bulkArchivePreservesDraftInputPinActivityAndCheckpointBytes"] = try tasks.task(a)?.archived == true && tasks.task(b)?.archived == true && tasks.task(a)?.draft == original.draft && tasks.task(a)?.messages.map(\.id) == original.messages.map(\.id) && tasks.task(a)?.messages.map(\.content) == original.messages.map(\.content) && tasks.task(a)?.pinned == true && tasks.task(a)?.activityAt == original.activityAt && Data(contentsOf: checkpoint) == checkpointData
            checks["archiveSwitchesSelectionToAnActiveTask"] = tasks.selected?.archived == false && tasks.selectedID != a && tasks.selectedID != b
            try tasks.setArchived([a, b], archived: false); tasks.update(a) { $0.pinned = false }
            try tasks.setWorkspaceArchived(alpha.path, mode: .coding, archived: true)
            let token = organization.archiveID(alpha.path, mode: .coding)
            checks["workspaceArchivesOnlyActiveTasksWithItsOwnRestoreToken"] = token != nil && tasks.task(a)?.workspaceArchiveID == token && tasks.task(b)?.workspaceArchiveID == token && tasks.task(old)?.workspaceArchiveID == nil && tasks.task(old)?.archived == true
            checks["workspaceDisappearsInCodingWhileGeneralScopeAndFileStayUntouched"] = try !organization.directories(.coding, tasks: tasks.tasks).contains(where: { $0.path == alpha.path }) && organization.directories(.general, tasks: tasks.tasks).contains(where: { $0.path == alpha.path }) && Data(contentsOf: tasks.directory.appendingPathComponent(general + ".json")) == generalBytes && AgentRepoWikiOverview.projects(tasks).first(where: { $0.workspace == alpha.path })?.mode == .general
            let reopened = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["reopenRetainsWorkspaceArchiveAndExactTaskRestoreMembership"] = reopened.organization.archiveID(alpha.path, mode: .coding) == token && reopened.task(a)?.workspaceArchiveID == token && reopened.task(old)?.workspaceArchiveID == nil
            try tasks.setWorkspaceArchived(alpha.path, mode: .coding, archived: false)
            checks["workspaceRestoreKeepsEarlierIndividualArchive"] = tasks.task(a)?.archived == false && tasks.task(b)?.archived == false && tasks.task(old)?.archived == true && organization.archiveID(alpha.path, mode: .coding) == nil
            try tasks.setWorkspaceArchived(alpha.path, mode: .coding, archived: true); try tasks.setArchived([a], archived: false)
            checks["individualRestoreReopensDirectoryWithoutRestoringOtherTasks"] = tasks.task(a)?.archived == false && tasks.task(b)?.archived == true && tasks.task(old)?.archived == true && organization.archiveID(alpha.path, mode: .coding) == nil
            try tasks.setArchived([b], archived: false); try tasks.setWorkspaceArchived(alpha.path, mode: .coding, archived: true); try tasks.setWorkspaceArchived(alpha.path, mode: .coding, archived: false)
            checks["aLaterWorkspaceArchiveCannotRestoreEarlierStandaloneArchives"] = tasks.task(a)?.archived == false && tasks.task(b)?.archived == false && tasks.task(old)?.archived == true
            let held = output.appendingPathComponent("disconnected-empty"); try fm.moveItem(at: empty, to: held)
            let count = tasks.tasks.count
            try tasks.setWorkspaceArchived(empty.path, mode: .coding, archived: true); try tasks.setWorkspaceArchived(empty.path, mode: .coding, archived: false)
            checks["disconnectedEmptyWorkspaceCanArchiveRestoreWithoutNewTasksOrFiles"] = tasks.tasks.count == count && !fm.fileExists(atPath: empty.path) && fm.fileExists(atPath: held.path)
            try fm.moveItem(at: held, to: empty)
            func snapshot(_ store: AgentStore) throws -> [String: Data] { try Dictionary(uniqueKeysWithValues: (store.tasks.map { $0.id + ".json" } + ["index.json"]).map { ($0, try Data(contentsOf: store.directory.appendingPathComponent($0))) }) }
            let beforeInvalid = try snapshot(tasks)
            for ids in [[a, a], [a, UUID().uuidString]] { do { try tasks.setArchived(ids, archived: true); checks["invalidSelectionRejectedWithoutPartialWrites"] = false } catch { checks["invalidSelectionRejectedWithoutPartialWrites"] = try (checks["invalidSelectionRejectedWithoutPartialWrites"] ?? true) && snapshot(tasks) == beforeInvalid } }
            let conflictProfile = output.appendingPathComponent("conflict-profile"); try fm.copyItem(at: output.appendingPathComponent("profile"), to: conflictProfile)
            let stale = AgentStore(directory: conflictProfile, legacy: [], extensionHome: output.appendingPathComponent("shared-home")), writer = AgentStore(directory: conflictProfile, legacy: [], extensionHome: output.appendingPathComponent("shared-home")); _ = stale.task(a); _ = stale.task(b)
            writer.update(a) { $0.title = "另一实例已修改" }; let external = try snapshot(writer)
            do { try stale.setArchived([a, b], archived: true); checks["staleTaskCannotOverwriteAnotherInstanceOrPartiallyArchive"] = false } catch { checks["staleTaskCannotOverwriteAnotherInstanceOrPartiallyArchive"] = try snapshot(writer) == external && stale.task(a)?.archived == false && stale.task(b)?.archived == false }
            let conflict = AgentStore(directory: conflictProfile, legacy: [], extensionHome: output.appendingPathComponent("shared-home")), editor = AgentStore(directory: conflictProfile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            try editor.organization.rename(alpha.path, mode: .coding, name: "外部工作区名称", tasks: editor.tasks); let settings = try Data(contentsOf: conflictProfile.appendingPathComponent("organization.json")), beforeConflict = try snapshot(conflict)
            do { try conflict.setWorkspaceArchived(alpha.path, mode: .coding, archived: true); checks["organizationConflictLeavesEveryTaskAndExternalSettingsIntact"] = false } catch { checks["organizationConflictLeavesEveryTaskAndExternalSettingsIntact"] = try snapshot(conflict) == beforeConflict && Data(contentsOf: conflictProfile.appendingPathComponent("organization.json")) == settings }
            let protectedFile = conflict.directory.appendingPathComponent(b + ".json"); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: protectedFile.path)
            let readonly = AgentStore(directory: conflictProfile, legacy: [], extensionHome: output.appendingPathComponent("shared-home")), readonlyBefore = try snapshot(readonly)
            do { try readonly.setArchived([a, b], archived: true); checks["readonlyTaskRejectsEntireBatch"] = false } catch { checks["readonlyTaskRejectsEntireBatch"] = try snapshot(readonly) == readonlyBefore }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: protectedFile.path)
            let release = beta.appendingPathComponent("archive-release"), pidFile = beta.appendingPathComponent("archive-shell.pid"), command = "umask 077; echo $$ > \"$2\"; while [ ! -f \"$1\" ]; do /bin/sleep 0.05; done"
            let hook: [String: Any] = ["hooks": ["Notification": [["matcher": "ArchiveCheck", "hooks": [["name": "归档后台检查", "type": "command", "command": "/bin/sh", "args": ["-c", command, "archive-check", release.path, pidFile.path], "async": true, "timeout": 15]]]]]]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: hook), as: UTF8.self)
            try tasks.hooks.save(text, project: true, workspace: beta.path, expectedHash: nil)
            guard let definition = try tasks.hooks.catalog(workspace: beta.path).first(where: { $0.name == "归档后台检查" }) else { throw PetError("真实后台检查未载入") }
            try tasks.hooks.setEnabled(definition, true, workspace: beta.path)
            _ = try await tasks.hooks.fire(.notification, trigger: "archive-busy", store: tasks, taskID: other, value: "ArchiveCheck")
            let startDeadline = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: pidFile.path), tasks.hooks.isRunning(other), Date() < startDeadline { await wait(0.05) }
            guard tasks.hooks.isRunning(other), let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, kill(pid, 0) == 0 else { throw PetError("未启动真实后台进程") }
            report["backgroundPID"] = pid
            let busyBefore = try snapshot(tasks)
            var busyRejected = 0
            do { try tasks.setArchived([a, other], archived: true) } catch { busyRejected += 1 }
            do { try tasks.setWorkspaceArchived(beta.path, mode: .coding, archived: true) } catch { busyRejected += 1 }
            checks["actualRunningShellRejectsBulkAndWorkspaceArchiveWithoutChanges"] = try busyRejected == 2 && snapshot(tasks) == busyBefore && organization.archiveID(beta.path, mode: .coding) == nil
            try Data().write(to: release); let deadline = Date().addingTimeInterval(10)
            while tasks.hooks.isRunning(other), Date() < deadline { await wait(0.05) }
            checks["actualBackgroundShellCompletesBeforeArchiving"] = !tasks.hooks.isRunning(other) && tasks.task(other)?.events.last?.status == "completed" && kill(pid, 0) != 0
            try tasks.setArchived([other], archived: true); try tasks.setArchived([other], archived: false)
            checks["taskCanArchiveAndRestoreAfterItsActualBackgroundWorkEnds"] = tasks.task(other)?.archived == false
            try organization.sort(.name, mode: .coding); tasks.selectedID = a; control.showAgentTask(a); control.show(tab: "chat")
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("归档原生检查未通过") }
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "tasks": ["alpha": a, "second": b, "old": old, "beta": other, "none": none, "general": general], "projects": ["alpha": alpha.path, "beta": beta.path, "empty": empty.path], "modelsCalled": false], "task-archive-ui-ready.json")
            let uiDeadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < uiDeadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-task-archive-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-task-archive-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var value = control.archiveReadback(); value["appPID"] = getpid(); try write(value, "native-task-archive-" + name + ".json")
                }; await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("task-archive-ui-acceptance.json")), let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], let values = ui["checks"] as? [String: Bool] { report["uiValidated"] = ui["appPID"] as? Int == Int(getpid()) && ui["binaryHash"] as? String == hash && !values.isEmpty && values.values.allSatisfy { $0 }; report["ui"] = ui }
            checks["originalDraftsCheckpointAndEarlierArchiveSurviveRealUIFlows"] = try tasks.task(a)?.draft == original.draft && tasks.task(general)?.draft == "保留的通用草稿" && tasks.task(old)?.archived == true && Data(contentsOf: checkpoint) == checkpointData
            checks["noModelCallsReceiptsOrAssistantReplies"] = requests == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.messages.contains(where: { $0.role == "assistant" }) }
            report["appPID"] = getpid(); report["binaryHash"] = hash
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "task-archive-report.json")
    }

    func runArchiveScopeCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        let final = CommandLine.arguments.contains("--archive-scope-final")
        let resume = CommandLine.arguments.contains("--archive-scope-resume")
        let fixtureURL = output.appendingPathComponent("archive-scope-fixture.json")
        func find<T: NSView>(_ root: NSView, _ type: T.Type, matching: (T) -> Bool) -> T? {
            if let view = root as? T, !view.isHiddenOrHasHiddenAncestor, matching(view) { return view }
            for child in root.subviews {
                if let match = find(child, type, matching: matching) { return match }
            }
            return nil
        }
        func choose(_ popup: NSPopUpButton, _ item: NSMenuItem) throws {
            if item.target is AgentArchivedTasksView, let menu = popup.menu, let index = menu.items.firstIndex(where: { $0 === item }) {
                menu.performActionForItem(at: index)
                return
            }
            popup.select(item)
            guard let action = popup.action, NSApp.sendAction(action, to: popup.target, from: popup) else { throw PetError("无法选择归档范围") }
        }
        func write(_ value: [String: Any], to file: String) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent(file), options: .atomic)
        }
        func picture(_ host: NSWindow, to name: String) throws {
            guard let content = host.contentView else { throw PetError("归档窗口内容不可用") }
            content.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw PetError("归档窗口图像不可用") }
            bitmap.size = content.bounds.size; content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("归档窗口图像编码失败") }
            try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
            report["size-" + name] = [content.bounds.width, content.bounds.height]
        }
        func state(_ owner: ControlWindow) -> [String: Any] { owner.archiveReadback()["archive"] as? [String: Any] ?? [:] }
        func rowIDs(_ value: [String: Any]) -> [String] { (value["rows"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        func showsEmpty(_ owner: ControlWindow, message: String) -> Bool {
            guard let content = owner.window?.contentView,
                  let card = find(content, AgentSettingsCatalogEmptyView.self, matching: { _ in true }) else { return false }
            return card.label.stringValue == message && card.bounds.height > 100 && state(owner)["controlsFit"] as? Bool == true &&
                find(content, NSTableView.self, matching: { $0.accessibilityLabel() == "归档列表" }) == nil &&
                find(content, NSButton.self, matching: { ["清空当前列表…", "永久删除…", "恢复任务", "恢复工作区"].contains($0.title) }) == nil
        }
        func selectScope(_ host: NSWindow, path: String?, mode: AgentWorkMode?) throws {
            guard let content = host.contentView, let menu = find(content, NSPopUpButton.self, matching: { $0.accessibilityLabel() == "筛选归档项目" }),
                  let item = menu.itemArray.first(where: { option in
                      guard let scope = option.representedObject as? AgentArchivedTaskNavigation.Scope else { return false }
                      return scope.path == path && scope.mode == mode
                  }) else { throw PetError("缺少指定的归档范围") }
            try choose(menu, item)
        }
        func selectTab(_ host: NSWindow, _ index: Int) throws {
            guard let content = host.contentView, let tabs = find(content, NSSegmentedControl.self, matching: { $0.accessibilityLabel() == "归档类型" }),
                  let action = tabs.action else { throw PetError("缺少归档页签") }
            tabs.selectedSegment = index
            guard NSApp.sendAction(action, to: tabs.target, from: tabs) else { throw PetError("无法切换归档页签") }
        }
        func button(_ host: NSWindow, _ title: String) throws -> NSButton {
            guard let content = host.contentView, let button = find(content, NSButton.self, matching: { $0.title == title }) else {
                throw PetError("缺少归档操作 " + title)
            }
            return button
        }
        func cancelBulkPreview(_ host: NSWindow) async throws -> String {
            let operation = try button(host, "清空当前列表…")
            guard operation.isEnabled else { throw PetError("筛选内批量操作不可用") }
            var preview: String?
            let deadline = Date().addingTimeInterval(5)
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if let dialog = host.agentDialog, let cancel = find(dialog.view, NSButton.self, matching: { $0.title == "取消" }) {
                        func text(_ view: NSView) -> [String] {
                            if let field = view as? NSTextField { return [field.stringValue] }
                            if let editor = view as? NSTextView { return [editor.string] }
                            return view.subviews.flatMap(text)
                        }
                        preview = text(dialog.view).joined(separator: "\n")
                        cancel.performClick(nil); timer.invalidate()
                    } else if Date() >= deadline { timer.invalidate(); NSApp.abortModal() }
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            operation.performClick(nil)
            while preview == nil || host.agentDialog != nil {
                guard Date() < deadline else { break }
                await wait(0.02)
            }
            guard let preview, host.agentDialog == nil else { throw PetError("未看到归档批量确认") }
            return preview
        }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, let host = control.window, let content = host.contentView,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("归档范围验收只允许独立资料")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("归档范围验收禁止模型请求") }
            if resume {
                guard let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any],
                      let mainID = seed["mainWindow"] as? String, let childID = seed["childWindow"] as? String,
                      let group = seed["group"] as? String, let general = seed["general"] as? String,
                      let standalone = seed["standalone"] as? String, let coding = seed["coding"] as? [String] else {
                    throw PetError("已保存的归档验收样例缺失")
                }
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(), let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == childID }) else {
                    throw PetError("已保存的归档窗口未打开")
                }
                for _ in 0..<30 {
                    if state(control)["visible"] as? Bool == true && state(child)["visible"] as? Bool == true { break }
                    await wait(0.02)
                }
                let main = state(control), other = state(child)
                checks["normalRestartReopensOriginalArchiveWindows"] = control.workspaceSession?.id == mainID &&
                    control.agentTaskID == seed["current"] as? String && child.agentTaskID == seed["childTask"] as? String &&
                    main["visible"] as? Bool == true && other["visible"] as? Bool == true
                checks["originalProjectSearchSelectionAndScrollRestore"] = main["project"] as? String == group &&
                    main["projectMode"] as? String == "coding" && main["query"] as? String == "甲编程归档 " &&
                    main["selected"] as? String == coding[7] && abs((main["scroll"] as? Double ?? 0) - (seed["scroll"] as? Double ?? 0)) < 1
                checks["otherWindowUsesItsOwnNoWorkspaceScope"] = rowIDs(other) == [standalone] && other["selected"] as? String == standalone
                host.makeKeyAndOrderFront(nil)
                let field = find(content, NSSearchField.self, matching: { $0.accessibilityLabel() == "搜索归档" })
                checks["searchFieldRestoresSelection"] = (field?.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 2)
                try picture(host, to: "archive-restored-dark")
                guard let field, let editor = field.currentEditor() as? NSTextView else { throw PetError("重开的归档搜索未获得焦点") }
                editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                try selectScope(host, path: group, mode: .general)
                let scoped = find(content, NSTableView.self, matching: { $0.accessibilityLabel() == "归档列表" })
                guard rowIDs(state(control)) == [general], let scoped else { throw PetError("通用归档范围不正确") }
                scoped.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                let codeBefore = try coding.map { try Data(contentsOf: tasks.directory.appendingPathComponent($0 + ".json")) }
                let restore = try button(host, "恢复任务")
                guard restore.isEnabled, host.makeFirstResponder(scoped) else { throw PetError("通用归档恢复不可用") }
                restore.performClick(nil)
                checks["restoreChangesOnlySelectedGeneralTask"] = try tasks.task(general)?.archived == false &&
                    coding.enumerated().allSatisfy { try Data(contentsOf: tasks.directory.appendingPathComponent($0.element + ".json")) == codeBefore[$0.offset] }
                let empty = state(control)
                checks["emptyScopeStaysSelectedAndActionsAreDisabled"] = rowIDs(empty).isEmpty && empty["projectMode"] as? String == "general" &&
                    empty["canClear"] as? Bool == false && empty["canRestore"] as? Bool == false
                checks["restoringLastRowShowsEmptyCardAndKeepsKeyboardInArchive"] = showsEmpty(control, message: "暂无归档的任务") &&
                    field.currentEditor() != nil && field.currentEditor() === host.firstResponder
                checks["otherWindowKeepsArchivedStandaloneTask"] = rowIDs(state(child)) == [standalone] && tasks.task(standalone)?.archived == true
                checks["finalCheckpoint"] = await flushWorkspaceWindows()
            } else {
                if final {
                    control.show(tab: "chat")
                    host.appearance = NSAppearance(named: .darkAqua); host.setContentSize(NSSize(width: 780, height: 540))
                    guard control.showSettingsCategory("archived") else { throw PetError("空归档设置入口不可用") }
                    try selectTab(host, 0)
                    try picture(host, to: "archive-empty-workspaces-compact-dark")
                    checks["workspaceEmptyUsesSharedCardWithoutListOrActions"] = showsEmpty(control, message: "暂无归档的工作区")
                    try selectTab(host, 1)
                    host.setContentSize(NSSize(width: 1320, height: 800))
                    try picture(host, to: "archive-empty-tasks-wide-dark")
                    checks["taskEmptyUsesSharedCardInDarkAppearance"] = showsEmpty(control, message: "暂无归档的任务")
                    host.appearance = NSAppearance(named: .aqua)
                    try picture(host, to: "archive-empty-tasks-wide-light")
                    checks["taskEmptyUsesSharedCardInLightAppearance"] = showsEmpty(control, message: "暂无归档的任务")
                }
                let first = output.appendingPathComponent("甲/Studio"), second = output.appendingPathComponent("乙/Studio")
                let primary = output.appendingPathComponent("当前主要源"), secondary = output.appendingPathComponent("此前主要源")
                for path in [first, second, primary, secondary] {
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                    try Data(("# Public " + path.lastPathComponent + "\n").utf8).write(to: path.appendingPathComponent("README.md"))
                }
                try tasks.organization.register(first.path, mode: .coding)
                try tasks.organization.register(first.path, mode: .general)
                try tasks.organization.register(second.path, mode: .coding)
                let folders = [primary.path, secondary.path]
                let scope = AgentWorkspaceScope(group: first.path, folders: folders, primary: primary.path)
                let oldScope = AgentWorkspaceScope(group: first.path, folders: folders, primary: secondary.path)
                let coding = (1...10).map { number in
                    tasks.create(title: "甲编程归档 " + String(format: "%02d", number), mode: .ask, workspaceScope: number.isMultiple(of: 2) ? scope : oldScope, draft: "PUBLIC_ARCHIVE_" + String(number))
                }
                let general = tasks.create(title: "甲通用归档", mode: .ask, workMode: .general, workspaceScope: scope, draft: "PUBLIC_GENERAL")
                let other = tasks.create(title: "乙编程归档", workspace: second.path, mode: .ask, draft: "PUBLIC_OTHER")
                let standalone = tasks.create(title: "无工作区归档", mode: .ask, workMode: .general, draft: "PUBLIC_STANDALONE")
                let current = tasks.create(title: "归档验收原任务", mode: .ask, workMode: .general, draft: "PUBLIC_ORIGINAL_TASK")
                try tasks.setArchived([general, other, standalone], archived: true)
                try tasks.setWorkspaceArchived(first.path, mode: .coding, archived: true)
                var fixture: [String: Any] = ["coding": coding, "general": general, "other": other, "standalone": standalone, "current": current,
                           "group": first.path, "otherGroup": second.path, "primary": primary.path, "secondary": secondary.path]

                control.showAgentTask(current); control.show(tab: "chat")
                host.appearance = NSAppearance(named: .darkAqua); host.setContentSize(NSSize(width: 780, height: 540))
                guard control.showSettingsCategory("archived"), let tabs = find(content, NSSegmentedControl.self, matching: { $0.accessibilityLabel() == "归档类型" }),
                      let tabAction = tabs.action else { throw PetError("原设置入口无法进入已归档") }
                tabs.selectedSegment = 1
                guard NSApp.sendAction(tabAction, to: tabs.target, from: tabs),
                      let menu = find(content, NSPopUpButton.self, matching: { $0.accessibilityLabel() == "筛选归档项目" }),
                      let table = find(content, NSTableView.self, matching: { $0.accessibilityLabel() == "归档列表" }) else {
                    throw PetError("归档筛选或列表不可用")
                }
                host.contentView?.layoutSubtreeIfNeeded()
                try picture(host, to: "archive-dark-all")
                checks["firstActualListShowsEveryArchivedTask"] = table.numberOfRows == coding.count + 3
                report["projectTitles"] = menu.itemTitles
                report["oldProjectPaths"] = menu.itemArray.compactMap { $0.representedObject as? String }
                if !final {
                    checks["oldMenuUsesSourceInsteadOfOwner"] = menu.itemArray.contains { ($0.representedObject as? String) == primary.path } &&
                        !menu.itemArray.contains { ($0.representedObject as? String) == first.path }
                    guard let source = menu.itemArray.first(where: { ($0.representedObject as? String) == primary.path }) else {
                        throw PetError("旧版未列出主要源目录")
                    }
                    try choose(menu, source)
                    report["rowsAfterOldSourceSelection"] = table.numberOfRows
                    checks["sameOwnerTasksMissingUnderSourceFilter"] = table.numberOfRows == 0
                    try picture(host, to: "archive-dark-unmatched")
                } else {
                    let all = state(control)
                    let options = all["scopes"] as? [[String: Any]] ?? []
                    checks["menuSeparatesSameNamesAndWorkModes"] = options.count == 5 &&
                        Set(options.compactMap { $0["title"] as? String }).count == options.count &&
                        options.contains { $0["path"] as? String == first.path && $0["mode"] as? String == "coding" } &&
                        options.contains { $0["path"] as? String == first.path && $0["mode"] as? String == "general" }
                    checks["actionsFitInFirstViewportWithLongList"] = all["controlsFit"] as? Bool == true &&
                        (all["tableHeight"] as? Double ?? 0) >= 250
                    report["darkListHeight"] = all["tableHeight"]
                    try selectScope(host, path: second.path, mode: .coding)
                    checks["sameNamedOtherProjectIsIndependent"] = rowIDs(state(control)) == [other]
                    try selectScope(host, path: first.path, mode: .general)
                    checks["sameFolderGeneralTasksAreIndependent"] = rowIDs(state(control)) == [general]
                    try selectScope(host, path: first.path, mode: .coding)
                    checks["historicalPrimaryFoldersFindAllTenTasks"] = Set(rowIDs(state(control))) == Set(coding)
                    guard let field = find(content, NSSearchField.self, matching: { $0.accessibilityLabel() == "搜索归档" }),
                          host.makeFirstResponder(field), let searchEditor = field.currentEditor() as? NSTextView else { throw PetError("归档搜索不可用") }
                    searchEditor.insertText("公开样例无匹配", replacementRange: searchEditor.selectedRange())
                    try picture(host, to: "archive-search-no-results-compact-dark")
                    checks["unmatchedSearchKeepsScopeAndFocusWithoutActions"] = showsEmpty(control, message: "未找到匹配的归档") &&
                        state(control)["project"] as? String == first.path && searchEditor === host.firstResponder
                    searchEditor.insertText("", replacementRange: NSRange(location: 0, length: searchEditor.string.utf16.count))
                    checks["clearingSearchRestoresRowsAndBulkActionInSameScope"] = Set(rowIDs(state(control))) == Set(coding) &&
                        state(control)["project"] as? String == first.path && (try? button(host, "清空当前列表…").isEnabled) == true
                    let before = try coding.map { try Data(contentsOf: tasks.directory.appendingPathComponent($0 + ".json")) }
                    let preview = try await cancelBulkPreview(host)
                    checks["bulkPreviewNamesOnlyExactFilteredScope"] = preview.contains("永久删除10项任务？") &&
                        (1...10).allSatisfy { preview.contains("甲编程归档 " + String(format: "%02d", $0)) } &&
                        !preview.contains("甲通用归档") && !preview.contains("乙编程归档") && !preview.contains("无工作区归档")
                    checks["cancelPreservesEveryScopedTaskByte"] = try coding.enumerated().allSatisfy {
                        try Data(contentsOf: tasks.directory.appendingPathComponent($0.element + ".json")) == before[$0.offset]
                    }
                    guard host.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
                          let scroll = table.enclosingScrollView else { throw PetError("归档过滤或列表滚动不可用") }
                    editor.insertText("甲编程归档 ", replacementRange: editor.selectedRange())
                    table.selectRowIndexes(IndexSet(integer: 7), byExtendingSelection: false)
                    AgentSettingsRecovery.restoreScroll(145, to: scroll)
                    let y = state(control)["scroll"] as? Double ?? 0
                    try selectTab(host, 0); try selectTab(host, 1)
                    checks["filtersSelectionAndScrollSurviveTabRoundTrip"] = y > 0 && state(control)["selected"] as? String == coding[7] &&
                        state(control)["projectMode"] as? String == "coding" && abs((state(control)["scroll"] as? Double ?? 0) - y) < 1
                    let childTask = tasks.create(title: "归档验收独立窗口", mode: .ask, workMode: .general, draft: "PUBLIC_SECOND_WINDOW")
                    openTaskWindow(childTask, from: control)
                    guard let child = additionalTaskWindows.last, let childHost = child.window, let childContent = childHost.contentView,
                          child.showSettingsCategory("archived") else { throw PetError("独立归档窗口未建立") }
                    childHost.appearance = NSAppearance(named: .aqua); childHost.setContentSize(NSSize(width: 1320, height: 800))
                    try selectTab(childHost, 1)
                    try selectScope(childHost, path: nil, mode: nil)
                    guard let childTable = find(childContent, NSTableView.self, matching: { $0.accessibilityLabel() == "归档列表" }) else {
                        throw PetError("独立窗口的归档列表不可用")
                    }
                    childTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    checks["wideWindowFiltersItsOwnStandaloneTask"] = rowIDs(state(child)) == [standalone] && state(child)["controlsFit"] as? Bool == true
                    try picture(childHost, to: "archive-light-standalone")
                    host.makeKeyAndOrderFront(nil)
                    host.makeFirstResponder(field)
                    (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 2))
                    guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let childID = child.workspaceSession?.id else {
                        throw PetError("两个归档窗口没有保存位置")
                    }
                    fixture["mainWindow"] = mainID; fixture["childWindow"] = childID; fixture["childTask"] = childTask
                    fixture["scroll"] = y
                    checks["searchSelectionIsRecordedBeforeQuit"] = control.captureArchivedTaskNavigation()?.selection?.range == NSRange(location: 0, length: 2)
                }
                try write(fixture, to: "archive-scope-fixture.json")
            }
            checks["noTaskWasDeleted"] = tasks.deletions.taskIDs.isEmpty && tasks.deletions.workspaceIDs.isEmpty
            checks["zeroModelRequests"] = requests == 0
        } catch { report["error"] = error.localizedDescription }
        report["pid"] = getpid(); report["checks"] = checks; report["modelRequests"] = requests
        if let executable = Bundle.main.executableURL {
            report["binarySHA256"] = try? AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
        }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? write(report, to: "archive-scope-report.json")
    }
}
