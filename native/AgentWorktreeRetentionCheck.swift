import AppKit

@MainActor extension AppDelegate {
    func checkWorktreeRetention(_ output: URL, parentID: String, initialPath: String, associated: [String]) async throws -> (checks: [String: Bool], values: [String: Any]) {
        guard let tasks = agentStore else { throw PetError("任务存储不可用") }
        let service = tasks.worktreeRetention, fm = FileManager.default, repo = output.appendingPathComponent("repo"), scratch = output.appendingPathComponent("tmp")
        var checks: [String: Bool] = [:], values: [String: Any] = [:]
        func git(_ args: [String], at root: URL? = nil) async throws -> String {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: scratch, network: false, timeout: 30, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", (root ?? repo).path] + args)
            guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
        }
        func until(_ seconds: Double, _ body: () throws -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if try body() { return true }; await wait(0.05) }; return try body()
        }
        let helper = try AgentGit(store: tasks, taskID: parentID, directory: AgentGit.metadata(workspace: repo.path))
        let active = try await helper.createWorktree(branch: "retention-active"), locked = try await helper.createWorktree(branch: "retention-locked"), pinned = try await helper.createWorktree(branch: "retention-pinned")
        let activeURL = URL(fileURLWithPath: active.workspace)
        try Data("staged-public\n".utf8).write(to: activeURL.appendingPathComponent("public.txt")); _ = try await git(["add", "public.txt"], at: activeURL)
        try Data("working-public\n".utf8).write(to: activeURL.appendingPathComponent("public.txt")); try Data("ignored-public-marker\n".utf8).write(to: activeURL.appendingPathComponent("local-only.txt"))
        let activeIndexPath = try await git(["rev-parse", "--git-path", "index"], at: activeURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let activeIndex = try Data(contentsOf: URL(fileURLWithPath: activeIndexPath)), initialURL = URL(fileURLWithPath: initialPath)
        let originalTree = try AgentWorktreeSnapshot.read(initialURL), initialIndexPath = try await git(["rev-parse", "--git-path", "index"], at: initialURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let initialIndex = try Data(contentsOf: URL(fileURLWithPath: initialIndexPath)), sourceIndex = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        for id in associated + [locked.taskID, pinned.taskID, parentID] { tasks.update(id) { $0.archived = true } }
        tasks.update(pinned.taskID) { $0.pinned = true }
        _ = try await git(["worktree", "lock", "--reason", "real retention acceptance lock", locked.workspace])
        let local = tasks.create(title: "无项目的设置入口", mode: .ask); tasks.selectedID = local
        service.start(store: tasks)
        checks["defaultOffCreatesNoPolicyOrScheduler"] = !service.policy.enabled && !fm.fileExists(atPath: service.directory.appendingPathComponent("policy.json").path) && !fm.fileExists(atPath: service.directory.appendingPathComponent("scheduler.lock").path)
        await wait(2.2)
        checks["actualIdleTimeWithPolicyOffDoesNotRecycle"] = try fm.fileExists(atPath: initialPath) && service.receipts().isEmpty
        var policy = AgentWorktreeRetentionPolicy(); policy.enabled = true; policy.idleSeconds = 2
        do { try service.save(policy, expectedRevision: service.revision); checks["enablingRequiresExplicitPolicyConsent"] = false } catch { checks["enablingRequiresExplicitPolicyConsent"] = true }
        try service.save(policy, expectedRevision: service.revision, consent: true)
        guard try await until(12, { let receipts = try service.receipts(); return !fm.fileExists(atPath: initialPath) && receipts.contains { $0.path == initialPath && $0.backupID != nil } }) else { throw PetError("真实到期计时未回收已归档工作树：" + service.status) }
        let first = try service.receipts().first { $0.path == initialPath && $0.backupID != nil }!
        checks["realTimerRecyclesArchivedCheckoutWithoutManualTick"] = !fm.fileExists(atPath: initialPath)
        checks["unarchivedLockedAndPinnedCheckoutsRemain"] = fm.fileExists(atPath: active.workspace) && fm.fileExists(atPath: locked.workspace) && fm.fileExists(atPath: pinned.workspace)
        checks["globalInventoryWorksWithArchivedSourceAndNoProjectSelection"] = tasks.selected?.workspace == nil && service.roots().contains { $0.taskID == parentID } && tasks.task(parentID)?.archived == true
        policy.enabled = false; try service.save(policy, expectedRevision: service.revision)
        let archivedHelper = try AgentGit(store: tasks, taskID: parentID, directory: helper.directory, allowsArchivedWorktreeSource: true)
        _ = try await git(["gc", "--prune=now"])
        let restored = try await archivedHelper.restoreWorktree(backupID: first.backupID!)
        let restoredIndexPath = try await git(["rev-parse", "--git-path", "index"], at: initialURL).trimmingCharacters(in: .whitespacesAndNewlines)
        checks["automaticBackupRestoresExactFilesAndRawIndexAfterGC"] = try AgentWorktreeSnapshot.read(initialURL).hash == originalTree.hash && Data(contentsOf: URL(fileURLWithPath: restoredIndexPath)) == initialIndex && restored.state == "restored"
        checks["restoredOriginallyArchivedTasksStayArchived"] = associated.allSatisfy { tasks.task($0)?.archived == true }
        for id in associated { tasks.update(id) { $0.pinned = true } }
        tasks.selectedID = active.taskID; policy.enabled = true; policy.archivedOnly = false
        try service.save(policy, expectedRevision: service.revision, consent: true)
        await wait(2.3)
        let selectionReceipts = try service.receipts()
        checks["actualSelectedIdleTaskIsProtected"] = fm.fileExists(atPath: active.workspace) && !selectionReceipts.contains { $0.path == active.workspace && $0.backupID != nil }
        let secondService = AgentWorktreeRetention(profile: store.directory); secondService.start(store: tasks)
        await wait(0.5)
        checks["secondSchedulerCannotAcquireSameProfileLock"] = secondService.status.contains("另一个应用实例")
        secondService.stop()
        let captureTools = AgentTools(store: tasks, taskID: active.taskID)
        let captureCall = AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: "{\"command\":\"printf actual-capture > capture-marker.txt; /bin/sleep 3\"}")
        let captured = Task { try await captureTools.execute(captureCall) }
        guard try await until(5, { tasks.task(active.taskID)?.pendingFileCapture != nil && fm.fileExists(atPath: activeURL.appendingPathComponent("capture-marker.txt").path) }) else { throw PetError("实际文件变更记录未开始") }
        tasks.selectedID = local
        await wait(2.3)
        checks["actualFileCaptureProtectsUnselectedIdleCheckoutBeyondDeadline"] = fm.fileExists(atPath: active.workspace) && tasks.task(active.taskID)?.pendingFileCapture != nil
        let captureResult = try await captured.value
        checks["actualFileCaptureCompletesBeforeCheckoutBecomesEligibleAgain"] = !captureResult.failed && tasks.task(active.taskID)?.pendingFileCapture == nil && tasks.task(active.taskID)?.changes.contains { $0.path.hasSuffix("/capture-marker.txt") && $0.afterKind == "file" } == true
        tasks.selectedID = active.taskID
        let operation = UUID(); service.setNativeOperation(operation, taskID: active.taskID, busy: true); tasks.selectedID = local
        let operationStarted = Date()
        let heldGit = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: activeURL, scratch: scratch, network: false, timeout: 10, readOnly: true, gitDirectory: helper.directory, protectedData: store.directory, arguments: ["-c", "alias.retention-hold=!/bin/sleep 3", "retention-hold"])
        checks["actualLongGitOperationIsProtectedBeyondRetentionDeadline"] = !heldGit.failed && Date().timeIntervalSince(operationStarted) >= policy.idleSeconds && fm.fileExists(atPath: active.workspace)
        service.setNativeOperation(operation, taskID: active.taskID, busy: false)
        let freshText = "recent-ignored-marker\n"
        try Data(freshText.utf8).write(to: activeURL.appendingPathComponent("local-only.txt"))
        let modified = Date(); tasks.selectedID = local
        await wait(0.7)
        checks["recentActualIgnoredFileEditPostponesRecycle"] = fm.fileExists(atPath: active.workspace) && Date().timeIntervalSince(modified) < policy.idleSeconds
        guard try await until(10, { let receipts = try service.receipts(); return !fm.fileExists(atPath: active.workspace) && receipts.contains { $0.path == active.workspace && $0.backupID != nil } }) else { throw PetError("文件闲置后真实计时未回收：" + service.status) }
        let second = try service.receipts().first { $0.path == active.workspace && $0.backupID != nil }!
        checks["realFileIdleDeadlineEventuallyRecyclesAndArchivesTask"] = Date().timeIntervalSince(modified) >= policy.idleSeconds && tasks.task(active.taskID)?.archived == true
        policy.enabled = false; try service.save(policy, expectedRevision: service.revision)
        let oldRevision = service.revision; policy.idleSeconds = 3; try service.save(policy, expectedRevision: service.revision)
        do { try service.save(policy, expectedRevision: oldRevision); checks["stalePolicyRevisionCannotOverwriteNewSettings"] = false } catch { checks["stalePolicyRevisionCannotOverwriteNewSettings"] = true }
        try Data("{".utf8).write(to: service.directory.appendingPathComponent("policy.json")); service.reload()
        checks["invalidPolicyStopsAutomaticProcessing"] = !service.policy.enabled && service.error != nil
        policy.idleSeconds = 2; try service.save(policy, expectedRevision: service.revision)
        checks["invalidPolicyCanBeExplicitlyRepaired"] = service.error == nil && !service.policy.enabled
        var uiPath = active.workspace, uiBackup = second.backupID!, uiTask = active.taskID
        if CommandLine.arguments.contains("--live-agent") {
            tasks.update(parentID) { $0.archived = false }
            let child = try await helper.createWorktree(branch: "retention-real-model"), childURL = URL(fileURLWithPath: child.workspace)
            tasks.update(parentID) { $0.archived = true }; tasks.selectedID = local
            var preferences = PreferencesStore(directory: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")).preferences
            preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
            guard let runtime = agentRuntime else { throw PetError("模型运行时不可用") }
            policy.enabled = true; policy.archivedOnly = false; try service.save(policy, expectedRevision: service.revision, consent: true)
            runtime.submit("先用ask_user询问审阅人，收到答复后只读取当前工作树source.json，在当前目录写asset-report.json并回读。JSON只含edition、width、height、reviewer四字段，前三项来自实际source.json，reviewer来自答复。不执行命令、不创建工作树、不提交或推送，不修改输入。", taskID: child.taskID)
            guard try await until(90, { tasks.task(child.taskID)?.status == .waiting }) else { throw PetError("真实模型未询问审阅人") }
            guard tasks.task(child.taskID)?.pendingCalls.first?.name == "ask_user" else { throw PetError("模型提出了预期外审批") }
            await wait(2.3)
            checks["realModelWaitingTaskSurvivesActualRetentionPeriod"] = fm.fileExists(atPath: child.workspace) && tasks.task(child.taskID)?.status == .waiting
            guard runtime.submit("海盐-7319", taskID: child.taskID) else { throw PetError("真实审阅答复未提交") }
            guard try await until(90, { tasks.task(child.taskID)?.status == .completed }) else { runtime.cancel(child.taskID); throw PetError("真实模型未完成素材报告") }
            let task = tasks.task(child.taskID)!, source = try JSONSerialization.jsonObject(with: Data(contentsOf: childURL.appendingPathComponent("source.json"))) as! [String: Any]
            let artifact = try Data(contentsOf: childURL.appendingPathComponent("asset-report.json")), actual = try JSONSerialization.jsonObject(with: artifact) as? [String: Any]
            checks["realModelReportMatchesActualAssetMetadataAndAnswer"] = actual?.count == 4 && ["edition", "width", "height"].allSatisfy { key in guard let expected = source[key] as? NSNumber, let received = actual?[key] as? NSNumber else { return false }; return expected == received } && actual?["reviewer"] as? String == "海盐-7319"
            guard try await until(12, { let receipts = try service.receipts(); return !fm.fileExists(atPath: child.workspace) && receipts.contains { $0.path == child.workspace && $0.backupID != nil } }) else { throw PetError("真实模型完成后未自动备份回收：" + service.status) }
            let receipt = try service.receipts().first { $0.path == child.workspace && $0.backupID != nil }!
            let backedReport = tasks.directory.appendingPathComponent("worktrees/" + receipt.backupID! + "/files/asset-report.json")
            checks["realCompletedTaskAutoRecyclesWithExactActualModelArtifact"] = try Data(contentsOf: backedReport) == artifact && tasks.task(child.taskID)?.archived == true && tasks.task(child.taskID)?.status == .completed
            policy.enabled = false; try service.save(policy, expectedRevision: service.revision)
            uiPath = child.workspace; uiBackup = receipt.backupID!; uiTask = child.taskID
            values["live"] = ["taskID": child.taskID, "workspace": child.workspace, "backupID": uiBackup, "artifactSHA256": AgentFiles.hash(artifact), "model": preferences.model, "contextLimit": preferences.contextLimit, "outputLimit": preferences.outputLimit, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens]
        }
        let savedPolicy = service.policy, policyURL = service.directory.appendingPathComponent("policy.json")
        let legacyPolicy = try Data(contentsOf: policyURL)
        checks["agePolicyKeepsTheOriginalFileFormat"] = try (JSONSerialization.jsonObject(with: legacyPolicy) as? [String: Any]).map { Set($0.keys) } == ["version", "enabled", "archivedOnly", "idleSeconds"]
        let secondRoot = output.appendingPathComponent("second-project")
        try fm.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        _ = try await git(["init", "-b", "main"], at: secondRoot)
        try Data("independent public project\n".utf8).write(to: secondRoot.appendingPathComponent("public.txt"))
        _ = try await git(["add", "--", "public.txt"], at: secondRoot)
        _ = try await git(["-c", "user.name=Public Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Independent baseline"], at: secondRoot)
        let secondParent = tasks.create(title: "按数量回收的另一项目", workspace: secondRoot.path)
        let otherHelper = try AgentGit(store: tasks, taskID: secondParent, directory: AgentGit.metadata(workspace: secondRoot.path))
        let other = try await otherHelper.createWorktree(branch: "count-other")
        tasks.update(other.taskID) { $0.archived = true }
        tasks.update(parentID) { $0.archived = false }
        let oldest = try await helper.createWorktree(branch: "count-oldest"), oldestURL = URL(fileURLWithPath: oldest.workspace)
        try Data("staged count sample\n".utf8).write(to: oldestURL.appendingPathComponent("public.txt"))
        _ = try await git(["add", "--", "public.txt"], at: oldestURL)
        try Data("working count sample\n".utf8).write(to: oldestURL.appendingPathComponent("public.txt"))
        try Data("ignored count sample\n".utf8).write(to: oldestURL.appendingPathComponent("local-only.txt"))
        let oldestTree = try AgentWorktreeSnapshot.read(oldestURL)
        let oldestIndexURL = URL(fileURLWithPath: try await git(["rev-parse", "--git-path", "index"], at: oldestURL).trimmingCharacters(in: .whitespacesAndNewlines))
        let oldestIndex = try Data(contentsOf: oldestIndexURL)
        tasks.update(oldest.taskID) { $0.archived = true }
        tasks.selectedID = local
        let beforeCount = try service.receipts().filter { $0.backupID != nil }.count
        var countPolicy = savedPolicy; countPolicy.maximumCount = 4; countPolicy.idleSeconds = 31_536_000
        countPolicy.archivedOnly = true; countPolicy.enabled = true
        do { try service.save(countPolicy, expectedRevision: service.revision); checks["countPolicyRequiresConsent"] = false }
        catch { checks["countPolicyRequiresConsent"] = true }
        try service.save(countPolicy, expectedRevision: service.revision, consent: true)
        let reread = try AgentWorktreeRetentionPolicy.read(Data(contentsOf: policyURL))
        checks["countPolicyRoundTripsThroughSchedulerStorage"] = reread == countPolicy && AgentWorktreeRetention(profile: store.directory).policy == countPolicy
        service.checkNow()
        guard try await until(12, { !service.isChecking && service.status.hasPrefix("已检查") }) else { throw PetError("按项目检查保留数量未结束：" + service.status) }
        checks["oneFullProjectAndSeparateCheckoutDoNotTriggerGlobalRecycle"] = try fm.fileExists(atPath: oldest.workspace) && fm.fileExists(atPath: other.workspace) && service.receipts().filter { $0.backupID != nil }.count == beforeCount

        let newest = try await helper.createWorktree(branch: "count-newest")
        tasks.update(newest.taskID) { $0.archived = true }; tasks.selectedID = local
        guard try await until(20, { try service.receipts().contains { $0.path == oldest.workspace && $0.backupID != nil } }) else { throw PetError("超额后未按数量回收旧工作树：" + service.status) }
        guard let countBackupID = try service.receipts().first(where: { $0.path == oldest.workspace && $0.backupID != nil })?.backupID else { throw PetError("未读取到按数量回收的备份") }
        let survivors = [initialPath, locked.workspace, pinned.workspace, newest.workspace, other.workspace]
        guard try await until(12, { !service.isChecking }) else { throw PetError("超额回收未收尾") }
        checks["countRecyclesOnlyOldestEligibleAndStopsAtPerProjectLimit"] = try !fm.fileExists(atPath: oldest.workspace) && survivors.allSatisfy { fm.fileExists(atPath: $0) } && service.receipts().filter { $0.backupID != nil }.count == beforeCount + 1
        try service.save(savedPolicy, expectedRevision: service.revision)
        let countRestored = try await helper.restoreWorktree(backupID: countBackupID)
        let restoredCountIndex = URL(fileURLWithPath: try await git(["rev-parse", "--git-path", "index"], at: oldestURL).trimmingCharacters(in: .whitespacesAndNewlines))
        checks["countBackupRestoresFilesAndRawIndex"] = try AgentWorktreeSnapshot.read(oldestURL).hash == oldestTree.hash && Data(contentsOf: restoredCountIndex) == oldestIndex && countRestored.state == "restored"
        checks["switchingBackWritesByteIdenticalLegacyPolicy"] = try Data(contentsOf: policyURL) == legacyPolicy
        values["countRetention"] = ["checkout": oldest.workspace, "backupID": countBackupID, "restoredIndexSHA256": AgentFiles.hash(oldestIndex),
            "survivors": survivors, "project": repo.path, "secondProject": secondRoot.path, "limit": 4]
        checks["originalMainIndexRemainsExact"] = try Data(contentsOf: repo.appendingPathComponent(".git/index")) == sourceIndex
        checks["finalPolicyIsDisabledWithoutDiscardingBackups"] = try !service.policy.enabled && service.receipts().filter { $0.backupID != nil }.count >= 2
        values["retention"] = ["restorePath": uiPath, "backupID": uiBackup, "taskID": uiTask, "parentID": parentID, "noProjectTaskID": local, "initialPath": initialPath, "initialBackupID": first.backupID!, "secondPath": active.workspace, "secondBackupID": second.backupID!, "secondIndexSHA256": AgentFiles.hash(activeIndex), "secondIgnoredText": freshText, "policyFile": service.directory.appendingPathComponent("policy.json").path, "mainIndexSHA256": AgentFiles.hash(sourceIndex)]
        control.showWorktreePolicySettings()
        guard checks.values.allSatisfy({ $0 }) else { throw PetError("工作树保留设置检查失败") }
        return (checks, values)
    }
}
