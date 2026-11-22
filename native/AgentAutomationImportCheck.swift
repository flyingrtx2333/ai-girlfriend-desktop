import AppKit

@MainActor extension AppDelegate {
    func runAutomationImportCheck(_ output: URL) async {
        let profile = output.appendingPathComponent("profile")
        let credentials = PetKeychain(service: "com.xjs.bluefatfish.automation-import-fixture",
                                      configurationFile: output.appendingPathComponent("unused-credentials.json"), migrateLegacy: false)
        let store = AgentStore(directory: profile, legacy: [],
                               extensionHome: output.appendingPathComponent("shared-home"), mcpKeychain: credentials)
        let runtime = AgentRuntime(store: store, keychain: credentials) { PetPreferences() }
        let automations = store.automations, imports = store.dataImport, fm = FileManager.default
        let original = automations.directory.appendingPathComponent("definitions.json")
        let cron = automations.directory.appendingPathComponent("cron-definitions.json")
        let monthlyFile = automations.directory.appendingPathComponent("monthly-definitions.json")
        let harbor = output.appendingPathComponent("harbor"), other = output.appendingPathComponent("other")
        let qoder = harbor.appendingPathComponent(".qoder/scheduled_tasks.json")
        let offline = output.appendingPathComponent("temporarily-unavailable.json")
        let paused = output.appendingPathComponent("automation-import-paused.json")
        let report = output.appendingPathComponent("automation-import-report.json")
        var checks: [String: Bool] = [:], attempts = 0
        let initialTaskIDs = store.tasks.map(\.id)
        runtime.modelRequestCheck = { attempts += 1; throw PetError("定时任务迁移检查禁止模型传输") }
        defer { automations.stop(); runtime.stopAll() }

        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        func hash(_ url: URL) throws -> String { AgentFiles.hash(try Data(contentsOf: url)) }
        func definitions(_ url: URL) throws -> Set<Data> {
            let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            guard let entries = document?["automations"] as? [[String: Any]] else { throw PetError("计划验收文件结构无效") }
            return Set(try entries.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
        }
        func save(_ data: Data, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        func write(_ value: [String: Any], to url: URL) throws {
            try save(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), to: url)
        }
        func idle() async throws {
            let deadline = Date().addingTimeInterval(15)
            while imports.active && Date() < deadline { await wait(0.04) }
            guard !imports.active else { throw PetError("定时任务导入仍在运行") }
        }
        func rejects(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        func imported(_ row: AgentImportCandidate) -> AgentAutomation? { automations.values.first { $0.id == row.targetID } }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("定时任务迁移检查禁止模型传输") }
            automations.start(store: store, runtime: runtime)
            guard automations.isStarted else { throw PetError(automations.error ?? "自动化未启动") }
            if !fm.fileExists(atPath: paused.path) {
                for project in [harbor, other] {
                    try fm.createDirectory(at: project, withIntermediateDirectories: true)
                    try store.organization.register(project.path, mode: .coding)
                }
                let legacy = AgentAutomation(name: "原有每日计划", prompt: "核对公开项目目录", workspace: harbor.path)
                try automations.save(legacy, expected: nil)
                let legacyHash = try hash(original), now = Date().timeIntervalSince1970 * 1000
                let expression = "0,30 9-11 * * 1-5", created = now - 3_600_000
                try write(["tasks": [
                    ["id": "ce123abc", "name": "工作日项目排程", "cron": expression, "prompt": "查阅公开 README", "createdAt": created, "recurring": true, "lastFiredAt": now - 60_000],
                    ["id": "ab123abc", "cron": "37 * * * *", "prompt": "一次性目录核对", "createdAt": now + 86_400_000],
                    ["id": "ba123abc", "cron": "0 12 15 * 1", "prompt": "/public-check", "createdAt": now - 12 * 86_400_000, "recurring": true],
                    ["id": "aa123abc", "cron": "0 9 * 13 *", "prompt": "无效计划", "createdAt": now, "recurring": true]
                ]], to: qoder)
                let qoderHash = try hash(qoder)
                await imports.detect(.qoder, root: harbor, category: .automations)
                let rows = imports.preview
                checks["qoderProjectRootPreviewOffersThreePlansAndExplainsInvalidRow"] = rows.count == 4
                    && rows.filter { $0.issue == nil }.count == 3 && rows.contains { $0.issue?.contains("Cron") == true }
                checks["keepsSourceProjectAndShowsExpressionLastRunAndExpiredSlashCommand"] = rows.filter { $0.issue == nil }.allSatisfy { $0.automation?.workspace == harbor.path }
                    && rows.contains { $0.preview.contains(expression) && $0.preview.contains("来源最近运行") }
                    && rows.contains { $0.warnings.count == 2 && $0.preview.contains("/public-check") }
                let selected = Set(rows.filter { ["工作日项目排程", "一次性目录核对"].contains($0.title) }.map(\.id))
                checks["confirmationFreezesSelectionAndDestination"] = selected.count == 2 && rejects {
                    try imports.begin(.qoder, root: harbor, ids: selected, category: .automations, workspace: other.path)
                }
                imports.onChange = { [weak imports] in
                    if imports?.batch?.state == "running", imports?.batch?.items.filter({ $0.state == "imported" }).count == 1 { imports?.pause() }
                }
                try imports.begin(.qoder, root: harbor, ids: selected, category: .automations)
                try await idle(); imports.onChange = nil
                guard let batch = imports.batch, let saved = batch.items.first(where: { $0.state == "imported" }),
                      let pending = batch.items.first(where: { $0.state == "pending" }), let primary = imported(saved.record) else {
                    throw PetError("缺少暂停前已保存和等待处理的计划")
                }
                checks["exactRecurringDefinitionIsSavedPausedWithSourceExpiration"] = primary.schedule.cronExpression == expression
                    && primary.schedule.expiration == Date(timeIntervalSince1970: created / 1000 + 7 * 86_400)
                    && primary.schedule.date == Date(timeIntervalSince1970: created / 1000)
                    && primary.workspace == harbor.path && primary.prompt == "查阅公开 README"
                    && !primary.enabled && primary.nextRun == nil && primary.current == nil
                    && primary.readOnly && !primary.network && primary.permission == .review
                checks["cronOnlyImportKeepsLegacyDefinitionBytes"] = try hash(original) == legacyHash
                checks["pausedImportLeavesExistingTasksAndCreatesNoRuns"] = try automations.history().runs.isEmpty && store.tasks.map(\.id) == initialTaskIDs
                try await AgentAutomationDataImport.install(pending.record, root: harbor, store: store)
                let once = imported(pending.record)
                let expected = AgentAutomationSchedule(frequency: .cron, timeZone: TimeZone.current.identifier, date: Date(timeIntervalSince1970: (now + 86_400_000) / 1000), cronExpression: "37 * * * *")
                checks["qoderOnceUsesFirstCronTimeAndSkipsUncheckedRows"] = once?.schedule.frequency == .once
                    && once?.schedule.date == expected.next(after: expected.date) && once?.enabled == false && automations.values.count == 3
                checks["sourceBytesStayUnchanged"] = try hash(qoder) == qoderHash
                try fm.moveItem(at: qoder, to: offline)
                try write(["checks": checks, "pid": getpid(), "batch": batch.id, "qoder": qoderHash,
                           "cron": try hash(cron), "ordinary": try hash(original), "taskIDs": initialTaskIDs], to: paused)
                return
            }

            let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: paused)) as! [String: Any]
            checks = seed["checks"] as! [String: Bool]
            checks["restartRestoresFrozenBatchAndPausedState"] = seed["pid"] as? Int != Int(getpid())
                && imports.batch?.id == seed["batch"] as? String && imports.batch?.state == "paused"
                && imports.batch?.category == .automations && imports.batch?.targetWorkspace == nil
            imports.resume(); try await idle()
            checks["resumingAlreadySavedScheduleDoesNotNeedSourceOrRewriteBytes"] = try imports.batch?.items.allSatisfy { $0.state == "imported" } == true
                && hash(cron) == seed["cron"] as? String && hash(original) == seed["ordinary"] as? String
            try fm.moveItem(at: offline, to: qoder)
            await imports.detect(.qoder, root: qoder, category: .automations)
            checks["directFileDetectsPreviousImportsWithoutDuplicates"] = try imports.preview.filter { $0.issue == "已经导入" }.count == 2
                && hash(qoder) == seed["qoder"] as? String

            let exported = output.appendingPathComponent("codex-export")
            func codex(_ id: String, _ name: String, _ rrule: String, workspaces: [String], extra: String = "") throws -> URL {
                let file = exported.appendingPathComponent("automations/\(id)/automation.toml")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
                let paths = try String(decoding: encoder.encode(workspaces), as: UTF8.self)
                let rule = rrule.replacingOccurrences(of: "\n", with: "\\n")
                let data = """
                id = "\(id)"
                version = 1
                name = "\(name)"
                status = "ACTIVE"
                prompt = "检查公开工作目录"
                rrule = "\(rule)"
                cwds = \(paths)
                \(extra)
                """
                try save(Data(data.utf8), to: file); return file
            }
            let portable = "RRULE:FREQ=WEEKLY;BYDAY=MO,FR;BYHOUR=9;BYMINUTE=15;UNTIL=20360101T000000Z"
            let multi = try codex("multi", "Codex 多项目", portable, workspaces: [harbor.path, other.path], extra: "kind = \"cron\"\nexecution_environment = \"local\"\ntime_zone = \"Asia/Shanghai\"")
            let beat = "DTSTART:20300101T010300Z\nRRULE:FREQ=MINUTELY;INTERVAL=12"
            let cadence = try codex("cadence", "Codex 固定间隔", beat, workspaces: [harbor.path])
            let mutated = try codex("mutable", "Codex 来源改动", portable, workspaces: [harbor.path])
            _ = try codex("thread", "绑定任务", portable, workspaces: [harbor.path], extra: "target_thread_id = \"thread-fixture\"")
            _ = try codex("worktree", "工作树任务", portable, workspaces: [harbor.path], extra: "execution_environment = \"worktree\"")
            let lastWeekdayRule = "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"
            let advanced = try codex("advanced", "月末工作日", lastWeekdayRule + ";BYHOUR=9;BYMINUTE=0",
                                     workspaces: [harbor.path], extra: "time_zone = \"Asia/Shanghai\"")
            let sourceHashes = try [hash(multi), hash(cadence), hash(advanced)]
            await imports.detect(.codex, root: multi, category: .automations, workspace: other.path)
            checks["explicitTargetMapsStandaloneAutomationOnce"] = imports.preview.count == 1 && imports.preview.first?.automation?.workspace == other.path && imports.preview.first?.issue == nil
            await imports.detect(.codex, root: exported, category: .automations)
            let rows = imports.preview
            checks["codexPreviewSplitsRegisteredProjectsAndSkipsNonportablePlans"] = rows.count == 7
                && rows.filter { $0.issue == nil }.count == 5 && rows.filter { $0.title.hasPrefix("Codex 多项目") }.count == 2
                && rows.contains { $0.issue?.contains("绑定对话") == true } && rows.contains { $0.issue?.contains("本机项目") == true }
                && rows.contains { $0.title == "月末工作日" && $0.issue == nil && $0.preview.contains("BYSETPOS=-1") }
            try save(Data(String(decoding: Data(contentsOf: mutated), as: UTF8.self).replacingOccurrences(of: "BYMINUTE=15", with: "BYMINUTE=22").utf8), to: mutated)
            try imports.begin(.codex, root: exported, ids: Set(rows.filter { $0.issue == nil && $0.title != "月末工作日" }.map(\.id)), category: .automations)
            try await idle()
            checks["sourceChangesStopOnlyTheStaleSelection"] = imports.batch?.items.filter { $0.state == "imported" }.count == 3
                && imports.batch?.items.contains { $0.record.title == "Codex 来源改动" && $0.state == "failed" && $0.detail.contains("已变化") } == true
            let codexValues = rows.compactMap(imported)
            let cadenceValue = codexValues.first { $0.name == "Codex 固定间隔" }
            let weekly = codexValues.filter { $0.name.hasPrefix("Codex 多项目") }
            checks["codexRollsForwardExplicitCadenceAndEffectiveWeekdayTime"] = cadenceValue?.schedule.frequency == .interval
                && cadenceValue?.schedule.date == date("2030-01-01T01:03:00Z") && cadenceValue?.schedule.intervalMinutes == 12
                && cadenceValue?.schedule.next(after: date("2030-01-01T01:19:00Z")) == date("2030-01-01T01:27:00Z")
                && Set(weekly.map(\.workspace)) == [harbor.path, other.path]
                && weekly.allSatisfy { $0.schedule.cronExpression == "15 9 * * 1,5" && $0.schedule.expiration == date("2036-01-01T00:00:00Z")
                    && $0.schedule.next(after: date("2027-01-01T01:16:00Z")) == date("2027-01-04T01:15:00Z") }
            let oldPartitionHashes = try [hash(original), hash(cron)]
            await imports.detect(.codex, root: advanced, category: .automations)
            guard let monthly = imports.preview.first, monthly.issue == nil else { throw PetError("月度计划未进入导入预览") }
            try imports.begin(.codex, root: advanced, ids: [monthly.id], category: .automations)
            try await idle()
            guard let monthlyValue = imported(monthly) else { throw PetError("月度计划未保存") }
            checks["monthlyImportPreservesRuleZoneAndExactNextRun"] = monthlyValue.schedule.frequency == .monthly
                && monthlyValue.schedule.timeZone == "Asia/Shanghai" && monthlyValue.schedule.monthlyRule?.contains("BYSETPOS=-1") == true
                && monthlyValue.schedule.next(after: date("2027-01-01T00:00:00Z")) == date("2027-01-29T01:00:00Z")
                && monthlyValue.schedule.next(after: date("2027-01-29T01:00:00Z")) == date("2027-02-26T01:00:00Z")
            checks["monthlyImportLeavesLegacyPartitionsUnchanged"] = try [hash(original), hash(cron)] == oldPartitionHashes
                && fm.fileExists(atPath: monthlyFile.path)
            checks["codexSourceFilesAndExistingQoderPausedStateArePreserved"] = try [hash(multi), hash(cadence), hash(advanced)] == sourceHashes
                && automations.values.allSatisfy { !$0.enabled && $0.nextRun == nil && $0.current == nil }

            let counted = try AgentAutomationRecurrence.codex("DTSTART:20270129T090000Z\nRRULE:" + lastWeekdayRule + ";INTERVAL=2;COUNT=3", created: nil, zone: nil)
            checks["monthlyIntervalAndCountIncludeStartAndStopAfterLastOccurrence"] = counted.next(after: date("2027-01-01T00:00:00Z")) == date("2027-01-29T09:00:00Z")
                && counted.next(after: date("2027-01-29T09:00:00Z")) == date("2027-03-31T09:00:00Z")
                && counted.next(after: date("2027-03-31T09:00:00Z")) == date("2027-05-31T09:00:00Z")
                && counted.next(after: date("2027-05-31T09:00:00Z")) == nil
            let ending = try AgentAutomationRecurrence.codex("FREQ=MONTHLY;BYMONTHDAY=-1;BYHOUR=9;BYMINUTE=0;UNTIL=20280229T090000Z", created: nil, zone: "UTC")
            let every31st = try AgentAutomationRecurrence.codex("FREQ=MONTHLY;BYMONTHDAY=31;BYHOUR=9;BYMINUTE=0", created: nil, zone: "UTC")
            checks["monthlyUsesLeapDayAndSkipsAbsentDaysWithInclusiveExpiry"] = ending.next(after: date("2028-01-31T09:00:00Z")) == date("2028-02-29T09:00:00Z")
                && ending.next(after: date("2028-02-29T09:00:00Z")) == nil
                && every31st.next(after: date("2027-01-31T09:00:00Z")) == date("2027-03-31T09:00:00Z")
            let slots = try AgentAutomationRecurrence.codex("FREQ=MONTHLY;BYDAY=-1TU;BYMONTHDAY=-7,-6,-5,-4,-3,-2,-1;BYHOUR=9,12;BYMINUTE=0,30;BYSETPOS=-2", created: nil, zone: "UTC")
            checks["monthlyIntersectsOrdinalWeekdaysAndDaysBeforeSelectingClockSlot"] = slots.next(after: date("2027-02-01T00:00:00Z")) == date("2027-02-23T12:00:00Z")
            let springMonthly = try AgentAutomationRecurrence.codex("DTSTART;TZID=America/New_York:20260208T023000\nRRULE:FREQ=MONTHLY;BYDAY=2SU;COUNT=2", created: nil, zone: nil)
            let autumnMonthly = try AgentAutomationRecurrence.codex("DTSTART;TZID=America/New_York:20261101T013000\nRRULE:FREQ=MONTHLY;BYDAY=1SU;COUNT=1", created: nil, zone: nil)
            checks["monthlySkipsSpringGapWithoutCountingItAndStartsAtFirstFallTime"] = springMonthly.next(after: date("2026-02-08T07:30:00Z")) == date("2026-04-12T06:30:00Z")
                && springMonthly.next(after: date("2026-04-12T06:30:00Z")) == nil
                && autumnMonthly.next(after: date("2026-11-01T04:00:00Z")) == date("2026-11-01T05:30:00Z")
                && autumnMonthly.next(after: date("2026-11-01T05:30:00Z")) == nil
            let rejected = [lastWeekdayRule + ";COUNT=1;BYHOUR=9;BYMINUTE=0",
                            "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=0;BYHOUR=9;BYMINUTE=0",
                            "FREQ=WEEKLY;BYDAY=MO;BYSETPOS=-1;BYHOUR=9;BYMINUTE=0"]
            checks["invalidOrAmbiguousRulesAreNeverReinterpreted"] = rejected.allSatisfy { rule in
                rejects { _ = try AgentAutomationRecurrence.codex(rule, created: nil, zone: "UTC") }
            }

            var newYork = Calendar(identifier: .gregorian); newYork.timeZone = TimeZone(identifier: "America/New_York")!
            let spring = try AgentCronSchedule("30 2 * * *"), autumn = try AgentCronSchedule("30 1 * * *")
            checks["cronSkipsNonexistentTimeAndVisitsBothRepeatedTimes"] = spring.next(after: date("2026-03-08T05:00:00Z"), calendar: newYork) == date("2026-03-09T06:30:00Z")
                && autumn.next(after: date("2026-11-01T05:31:00Z"), calendar: newYork) == date("2026-11-01T06:30:00Z")
            let repeated = try AgentAutomationRecurrence.codex("FREQ=DAILY;BYHOUR=1;BYMINUTE=30", created: nil, zone: "America/New_York")
            checks["codexCalendarSchedulesVisitFirstRepeatedTimeOnly"] = repeated.next(after: date("2026-11-01T05:31:00Z")) == date("2026-11-02T06:30:00Z")
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let or = try AgentCronSchedule("0 12 15 * 1"), leap = try AgentCronSchedule("0 9 29 2 *")
            checks["cronUsesDayOrWeekdayAndCrossesGregorianLeapGap"] = or.next(after: date("2027-01-12T00:00:00Z"), calendar: utc) == date("2027-01-15T12:00:00Z")
                && leap.next(after: date("2096-02-29T09:00:00Z"), calendar: utc) == date("2104-02-29T09:00:00Z")

            guard let legacy = automations.values.first(where: { $0.name == "原有每日计划" }) else { throw PetError("缺少原有每日计划") }
            let cronBefore = try Data(contentsOf: cron), legacyBefore = try hash(original)
            let originalDefinitions = try definitions(original)
            var converted = legacy
            converted.schedule = AgentAutomationSchedule(frequency: .cron, timeZone: "UTC", date: date("2030-01-01T00:00:00Z"), cronExpression: "0 0 * * *")
            try automations.save(converted, expected: legacy)
            let cronAfter = try Data(contentsOf: cron), originalAfter = try Data(contentsOf: original)
            let transition = automations.directory.appendingPathComponent("schedule-transition.json")
            checks["manualFrequencyChangeMovesDefinitionOnce"] = try automations.values.filter { $0.id == legacy.id }.count == 1
                && hash(original) != legacyBefore && !fm.fileExists(atPath: transition.path)
            automations.stop()
            try save(cronBefore, to: cron)
            let interrupted: [[String: Any]] = [
                ["cron": false, "previous": legacyBefore, "contents": originalAfter.base64EncodedString()],
                ["cron": true, "previous": AgentFiles.hash(cronBefore), "contents": cronAfter.base64EncodedString()]
            ]
            try save(JSONSerialization.data(withJSONObject: interrupted), to: transition)
            automations.start(store: store, runtime: runtime)
            checks["startupFinishesInterruptedCrossFileFrequencyChange"] = automations.isStarted
                && automations.values.filter { $0.id == legacy.id }.map(\.schedule.cronExpression) == ["0 0 * * *"]
                && !fm.fileExists(atPath: transition.path)
            try automations.setPaused(legacy.id, paused: false)
            checks["explicitEnableUsesFutureCronAnchorThenCanPause"] = automations.values.first { $0.id == legacy.id }?.nextRun == date("2030-01-01T00:00:00Z")
            try automations.setPaused(legacy.id, paused: true)
            guard let oldCron = automations.values.first(where: { $0.id == legacy.id }) else { throw PetError("缺少转换后的 Cron 计划") }
            let monthlyBefore = try Data(contentsOf: monthlyFile), previousCronHash = try hash(cron), previousOriginalHash = try hash(original)
            var newMonthly = oldCron; newMonthly.schedule = monthlyValue.schedule
            try automations.save(newMonthly, expected: oldCron)
            let monthlyAfter = try Data(contentsOf: monthlyFile), convertedCron = try Data(contentsOf: cron)
            let monthlyTransition = automations.directory.appendingPathComponent("monthly-transition.json")
            automations.stop()
            try save(monthlyBefore, to: monthlyFile)
            let interruptedMonthly: [[String: Any]] = [
                ["cron": true, "previous": previousCronHash, "contents": convertedCron.base64EncodedString()],
                ["cron": false, "monthly": true, "previous": AgentFiles.hash(monthlyBefore), "contents": monthlyAfter.base64EncodedString()]
            ]
            try save(JSONSerialization.data(withJSONObject: interruptedMonthly), to: monthlyTransition)
            automations.start(store: store, runtime: runtime)
            guard let recovered = automations.values.first(where: { $0.id == legacy.id }), recovered.schedule.frequency == .monthly else {
                throw PetError(automations.error ?? "月度转换记录未恢复")
            }
            checks["startupCompletesMonthlyTransitionWithoutDuplicatesOrLegacyRewrite"] = try hash(original) == previousOriginalHash
                && hash(monthlyFile) == AgentFiles.hash(monthlyAfter) && !fm.fileExists(atPath: monthlyTransition.path)
                && automations.values.filter { $0.id == legacy.id }.count == 1 && !recovered.enabled
            try automations.save(legacy, expected: recovered)
            checks["movingBackToDailyPreservesOtherMonthlyAndCronDefinitions"] = try hash(monthlyFile) == AgentFiles.hash(monthlyBefore)
                && hash(cron) == AgentFiles.hash(convertedCron) && definitions(original) == originalDefinitions
                && !fm.fileExists(atPath: monthlyTransition.path)
            checks["verificationLeavesOriginalTasksAndCreatesNoRunsOrModelRequests"] = try automations.history().runs.isEmpty
                && store.tasks.map(\.id) == initialTaskIDs && initialTaskIDs == seed["taskIDs"] as? [String] && attempts == 0
            try write(["success": checks.values.allSatisfy { $0 }, "checks": checks, "pid": getpid(), "modelRequests": attempts], to: report)
        } catch {
            try? write(["success": false, "checks": checks, "pid": getpid(), "modelRequests": attempts, "error": error.localizedDescription], to: report)
        }
    }
}
