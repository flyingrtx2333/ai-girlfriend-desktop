import AppKit

@MainActor extension AppDelegate {
    func runAutomationImportCheck(_ output: URL) async {
        let profile = output.appendingPathComponent("profile")
        let credentials = PetKeychain(service: "com.xjs.bluefatfish.automation-import-fixture",
                                      configurationFile: output.appendingPathComponent("unused-credentials.json"), migrateLegacy: false)
        let store = AgentStore(directory: profile.appendingPathComponent("agent"), legacy: [],
                               extensionHome: output.appendingPathComponent("shared-home"), mcpKeychain: credentials)
        let runtime = AgentRuntime(store: store, keychain: credentials) { PetPreferences() }
        let automations = store.automations, imports = store.dataImport, fm = FileManager.default
        let original = automations.directory.appendingPathComponent("definitions.json")
        let cron = automations.directory.appendingPathComponent("cron-definitions.json")
        let harbor = output.appendingPathComponent("harbor"), other = output.appendingPathComponent("other")
        let qoder = harbor.appendingPathComponent(".qoder/scheduled_tasks.json")
        let offline = output.appendingPathComponent("temporarily-unavailable.json")
        let paused = output.appendingPathComponent("automation-import-paused.json")
        let report = output.appendingPathComponent("automation-import-report.json")
        var checks: [String: Bool] = [:], attempts = 0
        runtime.modelRequestCheck = { attempts += 1; throw PetError("定时任务迁移检查禁止模型传输") }
        defer { automations.stop(); runtime.stopAll() }

        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        func hash(_ url: URL) throws -> String { AgentFiles.hash(try Data(contentsOf: url)) }
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
                checks["cronOnlyImportKeepsLegacyBytesAndCreatesNoRunsOrTasks"] = try hash(original) == legacyHash
                    && automations.history().runs.isEmpty && store.tasks.isEmpty
                try await AgentAutomationDataImport.install(pending.record, root: harbor, store: store)
                let once = imported(pending.record)
                let expected = AgentAutomationSchedule(frequency: .cron, timeZone: TimeZone.current.identifier, date: Date(timeIntervalSince1970: (now + 86_400_000) / 1000), cronExpression: "37 * * * *")
                checks["qoderOnceUsesFirstCronTimeAndSkipsUncheckedRows"] = once?.schedule.frequency == .once
                    && once?.schedule.date == expected.next(after: expected.date) && once?.enabled == false && automations.values.count == 3
                checks["sourceBytesStayUnchanged"] = try hash(qoder) == qoderHash
                try fm.moveItem(at: qoder, to: offline)
                try write(["checks": checks, "pid": getpid(), "batch": batch.id, "qoder": qoderHash,
                           "cron": try hash(cron), "ordinary": try hash(original)], to: paused)
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
                let paths = try String(decoding: JSONEncoder().encode(workspaces), as: UTF8.self)
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
            _ = try codex("advanced", "月末工作日", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;BYHOUR=9;BYMINUTE=0", workspaces: [harbor.path])
            let sourceHashes = try [hash(multi), hash(cadence)]
            await imports.detect(.codex, root: multi, category: .automations, workspace: other.path)
            checks["explicitTargetMapsStandaloneAutomationOnce"] = imports.preview.count == 1 && imports.preview.first?.automation?.workspace == other.path && imports.preview.first?.issue == nil
            await imports.detect(.codex, root: exported, category: .automations)
            let rows = imports.preview
            checks["codexPreviewSplitsRegisteredProjectsAndSkipsNonportablePlans"] = rows.count == 7
                && rows.filter { $0.issue == nil }.count == 4 && rows.filter { $0.title.hasPrefix("Codex 多项目") }.count == 2
                && rows.contains { $0.issue?.contains("绑定对话") == true } && rows.contains { $0.issue?.contains("本机项目") == true }
                && rows.contains { $0.issue?.contains("暂不支持的条件") == true }
            try save(Data(String(decoding: Data(contentsOf: mutated), as: UTF8.self).replacingOccurrences(of: "BYMINUTE=15", with: "BYMINUTE=22").utf8), to: mutated)
            try imports.begin(.codex, root: exported, ids: Set(rows.filter { $0.issue == nil }.map(\.id)), category: .automations)
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
            checks["codexSourceFilesAndExistingQoderPausedStateArePreserved"] = try [hash(multi), hash(cadence)] == sourceHashes
                && automations.values.allSatisfy { !$0.enabled && $0.nextRun == nil && $0.current == nil }

            var newYork = Calendar(identifier: .gregorian); newYork.timeZone = TimeZone(identifier: "America/New_York")!
            let spring = try AgentCronSchedule("30 2 * * *"), autumn = try AgentCronSchedule("30 1 * * *")
            checks["cronSkipsNonexistentTimeAndVisitsBothRepeatedTimes"] = spring.next(after: date("2026-03-08T05:00:00Z"), calendar: newYork) == date("2026-03-09T06:30:00Z")
                && autumn.next(after: date("2026-11-01T05:31:00Z"), calendar: newYork) == date("2026-11-01T06:30:00Z")
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let or = try AgentCronSchedule("0 12 15 * 1"), leap = try AgentCronSchedule("0 9 29 2 *")
            checks["cronUsesDayOrWeekdayAndCrossesGregorianLeapGap"] = or.next(after: date("2027-01-12T00:00:00Z"), calendar: utc) == date("2027-01-15T12:00:00Z")
                && leap.next(after: date("2096-02-29T09:00:00Z"), calendar: utc) == date("2104-02-29T09:00:00Z")

            guard let legacy = automations.values.first(where: { $0.name == "原有每日计划" }) else { throw PetError("缺少原有每日计划") }
            let cronBefore = try Data(contentsOf: cron), legacyBefore = try hash(original)
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
            checks["verificationNeverCreatesTasksRunsOrModelRequests"] = try automations.history().runs.isEmpty && store.tasks.isEmpty && attempts == 0
            try write(["success": checks.values.allSatisfy { $0 }, "checks": checks, "pid": getpid(), "modelRequests": attempts], to: report)
        } catch {
            try? write(["success": false, "checks": checks, "pid": getpid(), "modelRequests": attempts, "error": error.localizedDescription], to: report)
        }
    }
}
