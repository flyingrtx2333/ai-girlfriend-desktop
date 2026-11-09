import AppKit

@MainActor extension AppDelegate {
    func runAgentTaskArchiveCheck(_ output: URL) async {
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
}
