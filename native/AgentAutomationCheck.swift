import AppKit
import UserNotifications

@MainActor extension AppDelegate {
    func runAgentAutomationCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:]
        var manager: AgentAutomationWindow?
        func denied(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)) }
        defer { agentRuntime?.stopAll(); agentStore?.automations.stop(); manager?.close(); phase("finished") }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            let service = tasks.automations, workspace = output.appendingPathComponent("workspace").resolvingSymlinksInPath()
            var daily = AgentAutomationSchedule(); daily.frequency = .daily; daily.timeZone = "Asia/Shanghai"; daily.hour = 9; daily.minute = 30
            checks["dailyScheduleUsesSavedTimeZone"] = daily.next(after: date("2026-11-06T00:00:00Z")) == date("2026-11-06T01:30:00Z")
            var weekly = daily; weekly.frequency = .weekly; weekly.weekdays = [2, 6]
            checks["weeklyScheduleCrossesWeekend"] = weekly.next(after: date("2026-11-06T02:00:00Z")) == date("2026-11-09T01:30:00Z")
            var spring = daily; spring.timeZone = "America/New_York"; spring.hour = 2; spring.minute = 30
            checks["springDSTGapMovesToNextValidTime"] = spring.next(after: date("2026-03-08T05:00:00Z")) == date("2026-03-08T07:00:00Z")
            var fall = spring; fall.hour = 1; fall.minute = 30
            checks["fallDSTUsesFirstOccurrence"] = fall.next(after: date("2026-11-01T04:00:00Z")) == date("2026-11-01T05:30:00Z")
            checks["fallDSTDoesNotScheduleSameWallTimeTwice"] = fall.next(after: date("2026-11-01T05:30:01Z")) == date("2026-11-02T06:30:00Z")
            var interval = daily; interval.frequency = .interval; interval.date = date("2026-11-06T01:00:00Z"); interval.intervalMinutes = 15
            checks["intervalAdvancesPastMissedSlotsWithoutCatchup"] = interval.next(after: date("2026-11-06T01:46:00Z")) == date("2026-11-06T02:00:00Z")
            interval.expiration = date("2026-11-06T01:59:00Z")
            checks["expirationStopsFurtherRecurrence"] = interval.next(after: date("2026-11-06T01:46:00Z")) == nil
            var recovery = AgentAutomation(name: "中断预留记录", prompt: "核对公开素材", workspace: workspace.path)
            recovery.current = AgentAutomationRun(automationID: recovery.id, name: recovery.name, scheduled: Date(), trigger: "schedule")
            var missed = AgentAutomation(name: "错过的计划", prompt: "核对公开素材", workspace: workspace.path); missed.enabled = true; missed.schedule.frequency = .once; missed.schedule.date = Date().addingTimeInterval(-120); missed.nextRun = missed.schedule.date
            try FileManager.default.createDirectory(at: service.directory, withIntermediateDirectories: true)
            let entries = try [recovery, missed].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
            try JSONSerialization.data(withJSONObject: ["version": 1, "keepAwake": false, "automations": entries]).write(to: service.directory.appendingPathComponent("definitions.json"))
            var notices: [AgentAutomationRun] = []; let priorNotice = service.onNotice
            service.onNotice = { run in notices.append(run); priorNotice?(run) }; service.start(store: tasks, runtime: runtime)
            guard service.isStarted else { throw PetError(service.error ?? "自动化未启动") }
            let recovered = try service.history(automationID: recovery.id).runs
            checks["interruptedReservationRecordedWithoutReplay"] = recovered.count == 1 && recovered[0].status == .stopped && recovered[0].taskID == nil
            checks["missedScheduleRecordedWithoutCreatingTask"] = try service.history(automationID: missed.id).runs.first?.status == .missed && service.values.first(where: { $0.id == missed.id })?.enabled == false
            let other = AgentAutomations(profile: store.directory); other.start(store: tasks, runtime: runtime)
            checks["secondSchedulerCannotOwnSameProfile"] = !other.isStarted && other.error?.contains("另一应用实例") == true; other.stop()
            var paused = AgentAutomation(name: "暂停后不触发", prompt: "核对公开素材", workspace: workspace.path); paused.enabled = true; paused.schedule.frequency = .once; paused.schedule.date = Date().addingTimeInterval(2)
            try service.save(paused, expected: nil); try service.setPaused(paused.id, paused: true)
            await wait(2.4)
            checks["pausedActualTimerCreatesNoRun"] = try service.history(automationID: paused.id).total == 0
            let invalid = AgentAutomation(name: "待完善计划", prompt: "", workspace: workspace.path)
            denied("emptyAutomationPromptRejected") { try service.save(invalid, expected: nil) }
            var expiring = paused; expiring.id = UUID().uuidString; expiring.name = "无有效到期区间"; expiring.enabled = true; expiring.schedule.frequency = .interval; expiring.schedule.expiration = Date().addingTimeInterval(1)
            denied("expirationBeforeNextRunRejected") { try service.save(expiring, expected: nil) }
            let stale = service.values.first { $0.id == paused.id }!
            var edited = stale; edited.prompt = "核对文件内容"; try service.save(edited, expected: stale)
            denied("staleEditorCannotOverwriteDefinition") { try service.save(stale, expected: stale) }
            let vanished = output.appendingPathComponent("unavailable-project").resolvingSymlinksInPath(); try FileManager.default.createDirectory(at: vanished, withIntermediateDirectories: true)
            var unavailable = AgentAutomation(name: "项目不可用的计划", prompt: "核对公开素材", workspace: vanished.path); unavailable.enabled = true; unavailable.schedule.frequency = .once; unavailable.schedule.date = Date().addingTimeInterval(2)
            try service.save(unavailable, expected: nil); try FileManager.default.moveItem(at: vanished, to: output.appendingPathComponent("retained-unavailable-project"))
            await wait(2.5)
            let failure = try service.history(automationID: unavailable.id).runs
            checks["actualScheduledMissingWorkspaceIsFailedHistory"] = failure.count == 1 && failure[0].status == .failed && failure[0].taskID == nil && failure[0].trigger == "schedule" && !failure[0].detail.isEmpty
            try service.setPaused(unavailable.id, paused: true)
            checks["unavailablePlanCanStillBePaused"] = service.values.first(where: { $0.id == unavailable.id })?.enabled == false
            let policyTask = tasks.create(title: "自动化范围核对", workspace: workspace.path)
            tasks.update(policyTask) { $0.automation = AgentAutomationAssignment(automationID: paused.id, runID: UUID().uuidString, name: paused.name, workspace: workspace.path, permission: .review, readOnly: true, network: false); $0.permission = .automatic }
            let tools = AgentTools(store: tasks, taskID: policyTask)
            denied("automationReadonlyBlocksFileWrite") { _ = try tools.approvalReason(for: call("write_file", ["path": "blocked-automation.txt", "content": "blocked"])) }
            denied("automationNetworkCannotBeAddedByArguments") { _ = try tools.approvalReason(for: call("run_command", ["command": "true", "network": true])) }
            checks["automationReviewCeilingCannotBeExpandedInTask"] = try tools.approvalReason(for: call("run_command", ["command": "wc -c < character.png"])) != nil
            let readonlyShell = try await tools.execute(call("run_command", ["command": "printf blocked > blocked-automation.txt", "network": false]))
            checks["automationReadonlyTerminalEnforcedByKernel"] = readonlyShell.failed && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("blocked-automation.txt").path)
            tasks.update(policyTask) { $0.workspace = output.path }
            denied("automationCannotSwitchProject") { _ = try tools.approvalReason(for: call("read_file", ["path": "source.json"])) }
            try service.setKeepAwake(true); checks["keepAwakeCreatesActivityWithoutPolling"] = service.hasSleepActivity
            let power = Process(), pipe = Pipe(); power.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); power.arguments = ["-g", "assertions"]; power.standardOutput = pipe; try power.run(); let powerText = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); power.waitUntilExit()
            checks["keepAwakeHasActualSystemAssertion"] = powerText.contains("BlueFatFish scheduled automations") && powerText.contains("pid \(ProcessInfo.processInfo.processIdentifier)(BlueFatFish)")
            try service.setKeepAwake(false); checks["keepAwakeCanBeReleased"] = !service.hasSleepActivity
            let history = try service.history(limit: 1), secondPage = try service.history(offset: 1, limit: 1)
            checks["runHistoryPaginatesWithoutDroppingRecords"] = history.total >= 3 && history.runs.count == 1 && secondPage.runs.count == 1 && history.runs[0].id != secondPage.runs[0].id
            let firstUnread = try service.history(limit: Int.max).runs.first(where: \.unread)
            if let firstUnread { let count = service.unreadCount; try service.markRead(firstUnread); let saved = try service.history(limit: Int.max).runs.first { $0.id == firstUnread.id }; checks["readingRunClearsPersistedNotice"] = service.unreadCount == count - 1 && saved?.unread == false }
            report["desktopNotificationAuthorization"] = (await UNUserNotificationCenter.current().notificationSettings()).authorizationStatus.rawValue
            if CommandLine.arguments.contains("--live-agent") {
                guard checks.values.allSatisfy({ $0 }) else { throw PetError("原生调度检查未全部通过，不调用模型") }
                let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: production).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.persona = ""; store.preferences = p
                report["model"] = p.model; report["contextLimit"] = p.contextLimit; report["outputLimit"] = p.outputLimit
                var role = AgentProfile(name: "定时素材核对员", description: "实际读取公开素材并写入约定报告", instructions: "SCHEDULE_ROLE_VERSION_A。仅完成当前明确文件任务，使用真实读写结果核对，不扩大范围。")
                role.enabled = true; role.readOnly = false; role.tools = ["list_directory", "read_file", "write_file"]; role.permission = .review; role.model = p.model
                try tasks.agents.save(tasks.agents.encode([role]), expectedHash: tasks.agents.document().1)
                let selected = tasks.selectedID
                let request = "读取 source.json。若 scheduled-report.json 已存在，读取其中 runCount 并加1；若不存在从1开始。只写 scheduled-report.json，五个字段：edition、width、height 来自 source.json，runCount 为本次计数，format 固定 scheduled-v1。写完 read_file 回读核对，最后简短报告。不要改动 source.json 或 character.png，不用终端、网页或外部工具，不问已有参数。"
                var value = AgentAutomation(name: "定时素材报告", prompt: request, workspace: workspace.path); value.executor = "agent:" + role.id; value.output = .merged; value.permission = .review; value.readOnly = false; value.model = p.model; value.enabled = true; value.schedule.frequency = .once; value.schedule.date = Date().addingTimeInterval(3)
                try service.save(value, expected: nil); phase("waiting-real-scheduled-run")
                var approved = Set<String>(), sawWaiting = false
                func awaitCompletion(_ count: Int) async throws -> [AgentAutomationRun] {
                    let deadline = Date().addingTimeInterval(150)
                    while Date() < deadline {
                        let runs = try service.history(automationID: value.id, limit: 20).runs
                        if let failed = runs.first(where: { [.failed, .stopped].contains($0.status) }) { throw PetError("真实自动化未完成：" + failed.detail) }
                        if runs.filter({ $0.status == .completed }).count == count { return runs }
                        if let active = service.values.first(where: { $0.id == value.id })?.current?.taskID, let review = runtime.pendingReview(active), let pending = review.pendingCalls.first, !approved.contains(pending.id) {
                            guard approved.count < 5, pending.name == "write_file", ["scheduled-report.json", workspace.appendingPathComponent("scheduled-report.json").path].contains(pending.object["path"] as? String ?? "") else { throw PetError("验收只批准写入指定自动化报告") }
                            if !sawWaiting {
                                try service.runNow(value.id)
                                let overlap = try service.history(automationID: value.id).runs
                                checks["actualWaitingRunPreventsDuplicateExecution"] = overlap.filter { $0.status == .skipped && $0.taskID == nil }.count == 1 && service.values.first { $0.id == value.id }?.current?.taskID == active
                                let priorSelection = tasks.selectedID
                                if let fork = tasks.fork(active) { service.taskChanged(fork); checks["forkCannotHijackOriginalRunLedger"] = service.values.first { $0.id == value.id }?.current?.status == .waiting && service.values.first { $0.id == value.id }?.current?.taskID == active; tasks.update(fork) { $0.archived = true }; tasks.selectedID = priorSelection }
                            }
                            sawWaiting = true; approved.insert(pending.id); runtime.decide(taskID: review.id, callID: pending.id, decision: "allow")
                        }
                        await wait(0.08)
                    }
                    throw PetError("真实自动化超时")
                }
                let firstRuns = try await awaitCompletion(1); guard let firstRun = firstRuns.first(where: { $0.status == .completed }), let taskID = firstRun.taskID, let firstTask = tasks.task(taskID) else { throw PetError("缺少真实计划任务") }
                let firstMessageIDs = firstTask.messages.map(\.id), firstReport = try Data(contentsOf: workspace.appendingPathComponent("scheduled-report.json"))
                checks["actualTimerStartsConfiguredRealModel"] = firstRun.trigger == "schedule" && firstTask.model == p.model && firstTask.inputTokens > 0
                checks["actualScheduledRunUsesSelectedAgentScope"] = firstTask.agent?.profile.id == role.id && firstTask.agent?.profile.instructions.contains("SCHEDULE_ROLE_VERSION_A") == true && firstTask.events.allSatisfy { $0.kind != "tool" || role.tools.contains($0.title) || $0.title == "load_tools" }
                checks["backgroundAutomationPreservesSelectedTask"] = tasks.selectedID == selected
                role.instructions = "SCHEDULE_ROLE_VERSION_B。按当前要求读取实际输入与已有报告，完成最少必要修改并回读核对，保留其他文件。"
                try tasks.agents.save(tasks.agents.encode([role]), expectedHash: tasks.agents.document().1)
                phase("real-merged-rerun"); try service.runNow(value.id)
                let runs = try await awaitCompletion(2); guard let final = tasks.task(taskID) else { throw PetError("合并任务不可用") }
                let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("scheduled-report.json"))) as? [String: Any] ?? [:]
                let source = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("source.json"))) as? [String: Any] ?? [:]
                checks["actualMergedRunsReuseTaskAndPreservePriorMessages"] = Set(runs.compactMap(\.taskID)) == [taskID] && firstMessageIDs.allSatisfy { id in final.messages.contains { $0.id == id } } && final.messages.filter(\.isHumanInput).count == 2
                checks["mergedNextRunUsesCurrentRoleConfiguration"] = final.agent?.profile.instructions.contains("SCHEDULE_ROLE_VERSION_B") == true && !final.agent!.profile.instructions.contains("SCHEDULE_ROLE_VERSION_A")
                checks["actualMergedRunUpdatesAndReadsBackReport"] = actual.count == 5 && actual["runCount"] as? Int == 2 && actual["format"] as? String == "scheduled-v1" && ["edition", "width", "height"].allSatisfy { actual[$0] as? Int == source[$0] as? Int } && final.events.filter { $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("scheduled-report.json") }.count >= 2
                checks["actualAutomationApprovalAndNotificationsRecorded"] = sawWaiting && notices.contains { $0.automationID == value.id && $0.status == .waiting } && notices.filter { $0.automationID == value.id && $0.status == .completed }.count == 2
                checks["oneTimePlanDoesNotScheduleAgain"] = service.values.first { $0.id == value.id }?.enabled == false && service.values.first { $0.id == value.id }?.nextRun == nil
                report["live"] = ["automationID": value.id, "taskID": taskID, "runIDs": runs.map(\.id), "approvals": approved.count, "report": actual, "firstReport": String(decoding: firstReport, as: UTF8.self)]
                report["actualNoticeStatuses"] = notices.filter { $0.automationID == value.id }.map { $0.status.rawValue }
                service.stop(); service.start(store: tasks, runtime: runtime)
                checks["restartRetainsActualHistoryWithoutReplayingOneTimeRun"] = try service.history(automationID: value.id).total == 3 && service.values.first { $0.id == value.id }?.current == nil && !runtime.isRunning(taskID)
            }
            report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks; report["scope"] = "Native timezone/DST, real timers, pause, expired/missed reservation handling, ownership lock, actual missing workspace failure, kernel scopes, paged persistent history, and optional saved-model scheduled/merged file workflow. No simulated model responses. Desktop notification permission is only read; in-app notices are verified separately."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("automation-report.json"), options: .atomic)
            if CommandLine.arguments.contains("--automation-ui-hold") {
                control.show(tab: "chat"); manager = AgentAutomationWindow(store: tasks); manager?.onOpen = { [weak self] id in self?.control.showAgentTask(id); self?.control.show(tab: "chat") }; manager?.showWindow(nil); manager?.window?.makeKeyAndOrderFront(nil); phase("ui-ready")
                let deadline = Date().addingTimeInterval(1200); while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("automation-report.json")) }
    }
}
