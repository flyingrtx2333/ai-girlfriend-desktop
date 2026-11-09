import AppKit

@MainActor extension AppDelegate {
    func runAgentTaskViewCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Real local tasks, project directories, queued user input cancelled before execution, organization files and native windows. Calendar boundary checks do not represent fabricated conversation history."]
        func write(_ object: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("任务视图检查不调用模型") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            var blocked = 0; runtime.modelRequestCheck = { blocked += 1; throw PetError("任务视图验收禁止发送模型请求") }
            let fm = FileManager.default, rootA = output.appendingPathComponent("projects/alpha"), rootB = output.appendingPathComponent("projects/beta"), organization = tasks.organization
            let a = tasks.create(title: "查看项目说明", workspace: rootA.path), b = tasks.create(title: "核对运行时", workspace: rootB.path), none = tasks.create(title: "未关联任务"), general = tasks.create(title: "整理资料", workspace: rootA.path, workMode: .general)
            tasks.update(a) { $0.draft = "保留的编程草稿" }; tasks.update(general) { $0.draft = "保留的通用草稿" }
            try organization.register(rootA.path, mode: .coding); try organization.register(rootB.path, mode: .coding); try organization.register(rootA.path, mode: .general)
            try organization.rename(rootA.path, mode: .coding, name: "Alpha 项目", tasks: tasks.tasks); try organization.rename(rootB.path, mode: .coding, name: "Beta 项目", tasks: tasks.tasks)
            let originalFiles = try Dictionary(uniqueKeysWithValues: [a, b, none, general].map { id in (id, try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json"))) })
            func originalTasksUnchanged() -> Bool { originalFiles.allSatisfy { (try? Data(contentsOf: tasks.directory.appendingPathComponent($0.key + ".json"))) == $0.value } }
            checks["defaultsPreserveWorkspaceGroupingAndAllActivity"] = organization.taskView(.coding).grouping == .workspace && organization.taskView(.coding).workspace == nil && organization.taskView(.coding).activity == .all
            let legacyProfile = output.appendingPathComponent("legacy-organization"); try fm.createDirectory(at: legacyProfile, withIntermediateDirectories: true); try fm.copyItem(at: output.appendingPathComponent("legacy-organization.json"), to: legacyProfile.appendingPathComponent("organization.json"))
            let legacy = AgentOrganization(profile: legacyProfile)
            checks["actualOldOrganizationFileRemainsReadable"] = legacy.taskView(.coding).grouping == .workspace && legacy.taskView(.general).activity == .all && legacy.customGroups(.coding, tasks: []).isEmpty
            let groupA = try organization.saveCustomGroup(name: "开发", mode: .coding), groupB = try organization.saveCustomGroup(name: "资料", mode: .coding), generalGroup = try organization.saveCustomGroup(name: "开发", mode: .general)
            try organization.assignTask(a, group: groupA, mode: .coding, tasks: tasks.tasks); try organization.assignTask(b, group: groupB, mode: .coding, tasks: tasks.tasks); try organization.assignTask(general, group: generalGroup, mode: .general, tasks: tasks.tasks)
            _ = try organization.saveCustomGroup(groupA, name: "工程", mode: .coding)
            checks["groupsAndMembershipDoNotRewriteTaskScopeOrDraftFiles"] = originalTasksUnchanged() && organization.customGroups(.coding, tasks: tasks.tasks).first(where: { $0.id == groupA })?.taskIDs == [a]
            checks["sameGroupNameAndDirectoryRemainIndependentPerMode"] = organization.customGroups(.general, tasks: tasks.tasks).first?.taskIDs == [general] && tasks.task(general)?.workspace == rootA.path && tasks.task(a)?.workspace == rootA.path
            let settingsFile = output.appendingPathComponent("profile/organization.json"), settingsBeforeInvalid = try Data(contentsOf: settingsFile)
            var invalidRejected = 0
            for name in ["资料", "bad\nname", String(repeating: "名", count: 81)] { do { _ = try organization.saveCustomGroup(name: name, mode: .coding) } catch { invalidRejected += 1 } }
            do { try organization.assignTask(general, group: groupA, mode: .coding, tasks: tasks.tasks) } catch { invalidRejected += 1 }
            checks["invalidNamesAndCrossModeAssignmentPreserveSettings"] = try invalidRejected == 4 && Data(contentsOf: settingsFile) == settingsBeforeInvalid && originalTasksUnchanged()
            let disposable = try organization.saveCustomGroup(name: "暂存分组", mode: .coding); try organization.assignTask(none, group: disposable, mode: .coding, tasks: tasks.tasks); try organization.removeCustomGroup(disposable, mode: .coding)
            checks["removingGroupPreservesActualTaskAndClearsOnlyMembership"] = tasks.task(none) != nil && originalTasksUnchanged() && !organization.customGroups(.coding, tasks: tasks.tasks).contains(where: { $0.taskIDs.contains(none) })
            try organization.reorder(rootB.path, before: rootA.path, mode: .coding, grouping: .workspace, tasks: tasks.tasks)
            checks["manualWorkspaceOrderIsStoredWithoutChangingFiles"] = organization.sorting(.coding) == .manual && organization.directories(.coding, tasks: tasks.tasks).map(\.path).prefix(2) == [rootB.path, rootA.path] && originalTasksUnchanged()
            try organization.togglePinned(rootA.path, mode: .coding, tasks: tasks.tasks); let pinnedSettings = try Data(contentsOf: settingsFile)
            do { try organization.reorder(rootB.path, before: rootA.path, mode: .coding, grouping: .workspace, tasks: tasks.tasks); checks["manualReorderCannotSilentlyOverridePinnedDirectory"] = false } catch { checks["manualReorderCannotSilentlyOverridePinnedDirectory"] = try Data(contentsOf: settingsFile) == pinnedSettings && organization.directories(.coding, tasks: tasks.tasks).first?.path == rootA.path }
            try organization.togglePinned(rootA.path, mode: .coding, tasks: tasks.tasks)
            try organization.reorder(groupB, before: groupA, mode: .coding, grouping: .custom, tasks: tasks.tasks)
            checks["customGroupManualOrderIsIndependentOfWorkspaceOrder"] = organization.customGroups(.coding, tasks: tasks.tasks).first?.id == groupB && organization.directories(.coding, tasks: tasks.tasks).first?.path == rootB.path
            let filtered = AgentTaskView(grouping: .workspace, workspace: rootA.path, activity: .today), unassociated = AgentTaskView(grouping: .workspace, workspace: "", activity: .all)
            checks["workspaceAndActivityPredicatesCombineIncludingNoWorkspace"] = tasks.tasks.filter { $0.organizationMode == .coding && filtered.includes($0) }.map(\.id) == [a] && unassociated.includes(tasks.task(none)!) && !unassociated.includes(tasks.task(a)!)
            try organization.setTaskView(filtered, mode: .coding); try organization.setTaskView(AgentTaskView(grouping: .custom, activity: .week), mode: .general)
            checks["viewFiltersPersistSeparatelyPerWorkMode"] = organization.taskView(.coding).workspace == rootA.path && organization.taskView(.general).grouping == .custom && organization.taskView(.general).activity == .week
            try organization.setTaskView(AgentTaskView(grouping: .activity), mode: .coding)
            checks["activityGroupingSelectsRecentSorting"] = organization.sorting(.coding) == .recent
            try organization.resetTaskView(.coding)
            checks["resetClearsFiltersAndSortWithoutDeletingGroupsOrTasks"] = organization.taskView(.coding).workspace == nil && organization.taskView(.coding).activity == .all && organization.taskView(.coding).grouping == .workspace && organization.sorting(.coding) == .recent && organization.customGroups(.coding, tasks: tasks.tasks).count == 2 && originalTasksUnchanged()
            let activity = tasks.tasks.first(where: { $0.id == a })!.activityAt!
            tasks.update(a) { $0.draft = "保留的编程草稿"; $0.title = "查看项目说明" }
            checks["savingDraftAndRenamingDoesNotInventConversationActivity"] = tasks.tasks.first(where: { $0.id == a })?.activityAt == activity
            guard runtime.submit("读取项目说明，只查看，不修改文件。", taskID: a, startImmediately: false) else { throw PetError(runtime.submissionError ?? "用户输入未入队") }
            let submitted = tasks.tasks.first(where: { $0.id == a })!.activityAt!; runtime.cancel(a)
            checks["realQueuedUserInputAdvancesActivityWithoutModelTransmission"] = submitted > activity && tasks.task(a)?.messages.contains(where: { $0.isHumanInput && $0.content == "读取项目说明，只查看，不修改文件。" }) == true && !runtime.isExecuting(a) && blocked == 0
            let reopened = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["reopenPreservesGroupsOrdersFiltersActivityAndDrafts"] = reopened.organization.customGroups(.coding, tasks: reopened.tasks).count == 2 && reopened.organization.taskView(.general).activity == .week && reopened.tasks.first(where: { $0.id == a })?.activityAt == tasks.tasks.first(where: { $0.id == a })?.activityAt && reopened.task(a)?.draft == "保留的编程草稿" && reopened.task(general)?.draft == "保留的通用草稿"
            let conflict = output.appendingPathComponent("conflict-profile"); try fm.createDirectory(at: conflict, withIntermediateDirectories: true); try fm.copyItem(at: settingsFile, to: conflict.appendingPathComponent("organization.json")); let stale = AgentOrganization(profile: conflict), external = try Data(contentsOf: conflict.appendingPathComponent("organization.json")) + Data("\n".utf8); try external.write(to: conflict.appendingPathComponent("organization.json"), options: .atomic)
            do { try stale.setTaskView(AgentTaskView(grouping: .custom), mode: .coding); checks["anotherInstanceCannotOverwriteOrganizationChanges"] = false } catch { checks["anotherInstanceCannotOverwriteOrganizationChanges"] = try Data(contentsOf: conflict.appendingPathComponent("organization.json")) == external }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let boundary = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!, today = calendar.startOfDay(for: boundary)
            checks["calendarWindowsUseInclusiveLocalDaysAcrossDST"] = AgentTaskActivityWindow.today.cutoff(now: boundary, calendar: calendar) == today && AgentTaskActivityWindow.week.cutoff(now: boundary, calendar: calendar) == calendar.date(byAdding: .day, value: -6, to: today) && AgentTaskActivityWindow.month.cutoff(now: boundary, calendar: calendar) == calendar.date(byAdding: .day, value: -29, to: today)
            let oldRoot = output.appendingPathComponent("legacy-tasks"), oldFiles = oldRoot.appendingPathComponent("agent"); try fm.createDirectory(at: oldFiles, withIntermediateDirectories: true)
            var oldIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: tasks.directory.appendingPathComponent("index.json"))) as! [String: Any]; var metadata = oldIndex["tasks"] as! [[String: Any]]
            for i in metadata.indices { metadata[i]["activityAt"] = nil; let id = metadata[i]["id"] as! String; try fm.copyItem(at: tasks.directory.appendingPathComponent(id + ".json"), to: oldFiles.appendingPathComponent(id + ".json")) }; oldIndex["tasks"] = metadata; try JSONSerialization.data(withJSONObject: oldIndex).write(to: oldFiles.appendingPathComponent("index.json"))
            let actualOldBytes = try Dictionary(uniqueKeysWithValues: metadata.map { value in let id = value["id"] as! String; return (id, try Data(contentsOf: oldFiles.appendingPathComponent(id + ".json"))) })
            let backfill = AgentStore(directory: oldRoot, legacy: [], extensionHome: output.appendingPathComponent("shared-home")), filled = backfill.taskViewMetadata()
            checks["oldIndexActivityBackfillDoesNotRewriteIndividualTasks"] = filled.allSatisfy { $0.activityAt != nil } && actualOldBytes.allSatisfy { (try? Data(contentsOf: oldFiles.appendingPathComponent($0.key + ".json"))) == $0.value }
            try organization.resetTaskView(.general); try organization.sort(.name, mode: .coding)
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("任务视图原生检查未通过") }
            control.showAgentTask(a); control.show(tab: "chat")
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "tasks": ["alpha": a, "beta": b, "none": none, "general": general], "groups": ["engineering": groupA, "reference": groupB], "projects": [rootA.path, rootB.path], "modelsCalled": false], "task-views-ui-ready.json")
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-task-views-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-task-views-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var value = control.organizationSnapshot(); value["appPID"] = getpid(); value["groups"] = organization.customGroups(tasks.selected?.organizationMode ?? .coding, tasks: tasks.tasks).map { ["id": $0.id, "name": $0.name, "members": $0.taskIDs] }; value["activity"] = Dictionary(tasks.tasks.map { ($0.id, ($0.activityAt ?? $0.updated).timeIntervalSince1970) }, uniquingKeysWith: max); try write(value, "native-task-views-" + name + ".json")
                }; await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("task-views-ui-acceptance.json")), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ui = value["checks"] as? [String: Bool] { report["uiValidated"] = value["appPID"] as? Int == Int(getpid()) && value["binaryHash"] as? String == hash && !ui.isEmpty && ui.values.allSatisfy { $0 }; report["ui"] = value }
            checks["bothWorkModeDraftsAndOriginalProjectsRemain"] = tasks.task(a)?.draft == "保留的编程草稿" && tasks.task(general)?.draft == "保留的通用草稿" && tasks.task(a)?.workspace == rootA.path && tasks.task(b)?.workspace == rootB.path
            checks["noModelReceiptsAssistantRepliesOrUnexpectedTransmission"] = blocked == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.messages.contains(where: { $0.role == "assistant" }) }
            report["appPID"] = getpid(); report["binaryHash"] = hash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true; try? write(report, "task-views-report.json")
    }
}
