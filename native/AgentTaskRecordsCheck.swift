import AppKit

@MainActor extension AppDelegate {
    private func writeTaskRecordsProcess(_ output: URL, phase: String) throws {
        let file = Bundle.main.executableURL!, hash = try AgentFiles(workspace: file.deletingLastPathComponent().path).fileHash(file)
        try JSONSerialization.data(withJSONObject: ["appPID": getpid(), "binaryHash": hash, "phase": phase], options: [.sortedKeys]).write(to: output.appendingPathComponent("task-records-process-" + phase + ".json"), options: .atomic)
    }
    private func checkTaskRecordImports(_ output: URL, checks: inout [String: Bool]) async throws {
        let root = output.appendingPathComponent("import-profile"), shared = output.appendingPathComponent("shared-home"), imported = AgentStore(directory: root, legacy: [], extensionHome: shared), service = imported.dataImport
        let source = output.appendingPathComponent("import-source"); await service.detect(.qoder, root: source)
        guard let candidate = service.preview.first(where: { $0.issue == nil }) else { throw PetError(service.issue ?? "保留的实际Qoder记录不可读") }
        func finish() async throws { let deadline = Date().addingTimeInterval(15); while service.active && Date() < deadline { await wait(0.05) }; guard !service.active, service.batch?.items.last?.state == "imported" else { throw PetError(service.issue ?? service.batch?.items.last?.detail ?? "实际导入未完成") } }
        try service.begin(.qoder, root: source, ids: [candidate.id]); try await finish()
        guard let first = imported.task(candidate.targetID), let fork = imported.fork(first.id) else { throw PetError("实际导入记录或分支不可读") }
        let original = try Data(contentsOf: URL(fileURLWithPath: candidate.file)), local = try service.sourceURL(first.id)
        _ = try await imported.permanentlyDelete(imported.prepareDeletion([first.id]))
        checks["deletingImportPreservesSourceSnapshotStillUsedByFork"] = try imported.task(first.id) == nil && Data(contentsOf: service.sourceURL(fork)) == original && Data(contentsOf: URL(fileURLWithPath: candidate.file)) == original
        await service.detect(.qoder, root: source)
        guard let next = service.preview.first(where: { $0.id == candidate.id && $0.issue == nil }) else { throw PetError("删除后不能重新检测实际来源") }
        checks["explicitReimportUsesNewIDAndKeepsOldDeletion"] = next.targetID != first.id && next.targetID != fork && imported.deletions.taskIDs.contains(first.id)
        try service.begin(.qoder, root: source, ids: [next.id]); try await finish()
        checks["reimportedRecordPreservesActualFirstMessageAndSourceBytes"] = try imported.task(next.targetID)?.messages.first(where: \.isHumanInput)?.content == first.messages.first(where: \.isHumanInput)?.content && Data(contentsOf: service.sourceURL(next.targetID)) == original
        await service.detect(.qoder, root: source)
        checks["repeatImportTargetsNewCanonicalRecordInsteadOfFork"] = service.preview.first(where: { $0.id == candidate.id })?.targetID == next.targetID && service.preview.first(where: { $0.id == candidate.id })?.issue == "已经导入"
        _ = try await imported.permanentlyDelete(imported.prepareDeletion([fork, next.targetID]))
        checks["lastImportDeletionRemovesUnsharedCopyAndKeepsOriginal"] = try !FileManager.default.fileExists(atPath: local.path) && Data(contentsOf: URL(fileURLWithPath: candidate.file)) == original
    }
    private func prepareTaskRecordsUI(_ output: URL, role: AgentProfile) async throws -> [String: Any] {
        guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
        let alpha = output.appendingPathComponent("projects/alpha"), beta = output.appendingPathComponent("projects/beta"), worktree = output.appendingPathComponent("projects/worktree"), organization = tasks.organization
        let defaults = tasks.tasks.map(\.id)
        try tasks.agents.save(tasks.agents.encode([role]), expectedHash: nil)
        let parent = tasks.create(title: "将删除的父任务", workspace: alpha.path), attachment = try await AgentAttachments.importFile(alpha.appendingPathComponent("README.md"), store: tasks, taskID: parent)
        guard runtime.submit("只查看项目说明。", taskID: parent, attachmentIDs: [attachment.id], startImmediately: false) else { throw PetError("原生用户输入未保存") }
        tasks.update(parent) { $0.draft = "父任务未发送草稿" }
        guard let owner = tasks.task(parent), let fork = tasks.fork(parent) else { throw PetError("保留分支创建失败") }
        tasks.update(fork) { $0.title = "保留的分支任务"; $0.draft = "保留的分支草稿" }
        let child = try tasks.agents.createTask(role.id, store: tasks, workspace: alpha.path, owner: owner); tasks.update(child) { $0.title = "隶属的子任务" }
        let one = tasks.create(title: "待清理记录一", workspace: alpha.path), two = tasks.create(title: "待清理记录二", workspace: alpha.path)
        let projectOne = tasks.create(title: "工作区归档任务一", workspace: beta.path), projectTwo = tasks.create(title: "工作区归档任务二", workspace: beta.path), projectOld = tasks.create(title: "工作区原有归档", workspace: beta.path)
        let general = tasks.create(title: "保留的通用任务", workspace: beta.path, workMode: .general), keep = tasks.create(title: "保留的工作树任务", workspace: worktree.path)
        tasks.update(general) { $0.draft = "保留的通用草稿" }; tasks.update(keep) { $0.draft = "保留的工作树草稿" }
        for path in [alpha.path, beta.path, worktree.path] { try organization.register(path, mode: .coding) }; try organization.register(beta.path, mode: .general)
        try organization.rename(alpha.path, mode: .coding, name: "Alpha 项目", tasks: tasks.tasks); try organization.rename(beta.path, mode: .coding, name: "Beta 项目", tasks: tasks.tasks)
        try tasks.setArchived(defaults + [one, two, projectOld], archived: true); try tasks.setWorkspaceArchived(beta.path, mode: .coding, archived: true)
        let checkpoint = try tasks.backupDirectory(parent).appendingPathComponent("README-copy.md"); try Data(contentsOf: alpha.appendingPathComponent("README.md")).write(to: checkpoint)
        let binary = try JSONEncoder().encode(tasks.task(parent)!); try binary.write(to: output.appendingPathComponent("ui-parent-before.json"))
        try organization.sort(.name, mode: .coding); control.showAgentTask(parent); control.show(tab: "chat")
        return ["tasks": ["parent": parent, "child": child, "fork": fork, "clearOne": one, "clearTwo": two, "workspaceOne": projectOne, "workspaceTwo": projectTwo, "workspaceOld": projectOld, "general": general, "keep": keep], "projects": ["alpha": alpha.path, "beta": beta.path, "worktree": worktree.path], "workspaceArchiveID": organization.archiveID(beta.path, mode: .coding)!, "attachment": attachment.id]
    }
    func runAgentTaskRecordsCrashCheck(_ output: URL) async {
        do {
            try writeTaskRecordsProcess(output, phase: "crash")
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { throw PetError("删除恢复检查禁止模型请求") }
            let id = tasks.create(title: "中断清理的真实任务"), bytes = try Data(contentsOf: output.appendingPathComponent("README.md"))
            let folder = try tasks.backupDirectory(id); try bytes.write(to: folder.appendingPathComponent("README-copy.md"))
            let plan = try tasks.prepareDeletion([id]); try tasks.deletions.commit(plan.records, workspaces: [], expected: plan.deletionSignature)
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try JSONSerialization.data(withJSONObject: ["appPID": getpid(), "binaryHash": hash, "id": id, "sourceHash": AgentFiles.hash(bytes), "pending": tasks.deletions.pendingCount, "modelsCalled": false], options: [.sortedKeys]).write(to: output.appendingPathComponent("deletion-committed.json"), options: .atomic)
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline { await wait(0.25) }
            throw PetError("未在已提交记录与缓存清理之间停止实际进程")
        } catch { try? JSONSerialization.data(withJSONObject: ["success": false, "error": error.localizedDescription]).write(to: output.appendingPathComponent("task-records-recovery-report.json")) }
    }
    func runAgentTaskRecordsRecoveryCheck(_ output: URL) async {
        var report: [String: Any] = ["modelsCalled": false], checks: [String: Bool] = [:]
        do {
            try writeTaskRecordsProcess(output, phase: "recovery")
            let source = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("deletion-committed.json"))) as! [String: Any], id = source["id"] as! String
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            var calls = 0; runtime.modelRequestCheck = { calls += 1; throw PetError("恢复检查禁止模型请求") }
            checks["deletedRecordNeverLoadsAfterActualProcessTermination"] = tasks.task(id) == nil && !tasks.tasks.contains(where: { $0.id == id }) && tasks.deletions.taskIDs.contains(id)
            let deadline = Date().addingTimeInterval(10)
            while tasks.deletions.pendingCount > 0 && Date() < deadline { await wait(0.05) }
            checks["startupFinishesActualInterruptedPrivateCacheCleanup"] = tasks.deletions.pendingCount == 0 && !FileManager.default.fileExists(atPath: tasks.directory.appendingPathComponent(id).path) && !FileManager.default.fileExists(atPath: tasks.directory.appendingPathComponent(id + ".json").path)
            checks["recoveryPreservesActualInputAndDoesNotCallModel"] = try AgentFiles.hash(Data(contentsOf: output.appendingPathComponent("README.md"))) == source["sourceHash"] as? String && calls == 0
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            checks["sameSignedBinaryPerformsRecovery"] = hash == source["binaryHash"] as? String
            report["appPID"] = getpid(); report["binaryHash"] = hash
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-records-recovery-report.json"), options: .atomic)
    }
    func runAgentTaskRecordsCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Actual local tasks, role/child creation, imported Qoder conversation, retained real Wiki model history, file exports, Git repositories, private attachments and a real background shell. No fabricated assistant replies or execution states."]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            try writeTaskRecordsProcess(output, phase: "main")
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("任务记录检查不发送模型请求") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            var calls = 0; runtime.modelRequestCheck = { calls += 1; throw PetError("任务记录验收禁止模型请求") }
            let fm = FileManager.default, alpha = output.appendingPathComponent("projects/alpha"), beta = output.appendingPathComponent("projects/beta"), worktree = output.appendingPathComponent("projects/worktree"), shared = output.appendingPathComponent("shared-home")
            let coreRoot = output.appendingPathComponent("core-profile"), core = AgentStore(directory: coreRoot, legacy: [], extensionHome: shared), coreRuntime = AgentRuntime(store: core, keychain: store.keychain) { self.store.preferences }
            coreRuntime.modelRequestCheck = { calls += 1; throw PetError("本机删除检查禁止模型请求") }
            var role = AgentProfile(name: "资料核对", description: "核对实际项目文件", instructions: "只读检查项目文件，不更改内容。")
            role.enabled = true; role.readOnly = true; role.network = false; role.tools = ["read_file"]
            try core.agents.save(core.agents.encode([role]), expectedHash: nil)
            let parent = core.create(title: "保留真实分支的父任务", workspace: alpha.path), attachment = try await AgentAttachments.importFile(alpha.appendingPathComponent("README.md"), store: core, taskID: parent)
            guard coreRuntime.submit("只查看项目说明。", taskID: parent, attachmentIDs: [attachment.id], startImmediately: false) else { throw PetError("真实用户输入未保存") }
            core.update(parent) { $0.draft = "尚未发送的草稿" }
            guard let fork = core.fork(parent), let owner = core.task(parent) else { throw PetError("未创建实际分支") }
            let child = try core.agents.createTask(role.id, store: core, workspace: alpha.path, owner: owner)
            let group = try core.organization.saveCustomGroup(name: "保留分支", mode: .coding); try core.organization.assignTask(parent, group: group, mode: .coding, tasks: core.tasks); try core.organization.assignTask(fork, group: group, mode: .coding, tasks: core.tasks)
            let checkpoint = try core.backupDirectory(parent).appendingPathComponent("README-copy.md"), bytes = try Data(contentsOf: alpha.appendingPathComponent("README.md")); try bytes.write(to: checkpoint)
            let sourceTask = try Data(contentsOf: core.directory.appendingPathComponent(parent + ".json")), oldIndex = try Data(contentsOf: core.directory.appendingPathComponent("index.json"))
            let stale = AgentStore(directory: coreRoot, legacy: [], extensionHome: shared); _ = stale.task(parent)
            let plan = try core.prepareDeletion([parent]); checks["deleteScopeIncludesOwnedChildButPreservesIndependentFork"] = plan.ids == Set([parent, child]) && !plan.ids.contains(fork)
            let issue = try await core.permanentlyDelete(plan)
            checks["actualParentAndChildRecordsAttachmentsAndCheckpointsAreRemoved"] = issue == nil && core.task(parent) == nil && core.task(child) == nil && !fm.fileExists(atPath: core.directory.appendingPathComponent(parent).path) && !fm.fileExists(atPath: core.directory.appendingPathComponent(parent + ".json").path) && core.deletions.pendingCount == 0
            let forkSource = try AgentAttachments.source(store: core, taskID: fork, id: attachment.id)
            checks["forkHardLinkedAttachmentAndMessageRemainReadable"] = try Data(contentsOf: forkSource) == bytes && core.task(fork)?.messages.first?.content == "只查看项目说明。" && core.organization.customGroups(.coding, tasks: core.tasks).first?.taskIDs == [fork] && core.organization.lastTask(.coding, tasks: core.tasks) == fork
            stale.update(parent) { $0.title = "过期窗口中的修改" }; try stale.save(parent)
            checks["staleStoreCannotRecreateDeletedRecord"] = stale.task(parent) == nil && !fm.fileExists(atPath: core.directory.appendingPathComponent(parent + ".json").path)
            try sourceTask.write(to: core.directory.appendingPathComponent(parent + ".json")); try oldIndex.write(to: core.directory.appendingPathComponent("index.json"))
            let reopened = AgentStore(directory: coreRoot, legacy: [], extensionHome: shared)
            checks["replayingActualOldIndexAndRecordBytesCannotRestoreDeletedTasks"] = reopened.task(parent) == nil && reopened.task(child) == nil && !reopened.tasks.contains(where: { [parent, child].contains($0.id) }) && reopened.task(fork) != nil
            reopened.selectedID = fork
            let target = reopened.create(title: "确认后改动的任务", workspace: beta.path), review = try reopened.prepareDeletion([target])
            reopened.update(target) { $0.draft = "确认期间保存的真实草稿" }
            do { _ = try await reopened.permanentlyDelete(review); checks["changedConfirmationCannotDeleteUpdatedTask"] = false } catch { checks["changedConfirmationCannotDeleteUpdatedTask"] = reopened.task(target)?.draft == "确认期间保存的真实草稿" && !reopened.deletions.taskIDs.contains(target) }
            let ledger = reopened.directory.appendingPathComponent("deleted-records.json"); try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: ledger.path)
            let before = try Data(contentsOf: reopened.directory.appendingPathComponent(target + ".json"))
            do { _ = try await reopened.permanentlyDelete(reopened.prepareDeletion([target])); checks["readonlyLedgerRejectsDeletionBeforeAnyTaskBytesChange"] = false } catch { checks["readonlyLedgerRejectsDeletionBeforeAnyTaskBytesChange"] = try Data(contentsOf: reopened.directory.appendingPathComponent(target + ".json")) == before && !reopened.deletions.taskIDs.contains(target) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
            let blocked = reopened.create(title: "清理权限检查"), blockedFolder = try reopened.backupDirectory(blocked).deletingLastPathComponent(); try bytes.write(to: blockedFolder.appendingPathComponent("actual-source.md")); try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedFolder.path)
            let partial = try await reopened.permanentlyDelete(reopened.prepareDeletion([blocked]))
            checks["cleanupFailureRetainsDeletionAndReportsPendingPrivateData"] = partial != nil && reopened.task(blocked) == nil && reopened.deletions.pendingCount == 1
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedFolder.path); let cleanup = await reopened.deletions.cleanup()
            checks["retryFinishesSameDirectoryAfterPermissionRepair"] = cleanup == nil && reopened.deletions.pendingCount == 0 && !fm.fileExists(atPath: blockedFolder.path)
            let sentinel = output.appendingPathComponent("outside-sentinel"); try fm.createDirectory(at: sentinel, withIntermediateDirectories: true); try bytes.write(to: sentinel.appendingPathComponent("README.md"))
            let linked = reopened.create(title: "缓存链接检查"); try fm.createSymbolicLink(at: reopened.directory.appendingPathComponent(linked), withDestinationURL: sentinel)
            _ = try await reopened.permanentlyDelete(reopened.prepareDeletion([linked]))
            checks["privateDirectoryLinkIsRemovedWithoutFollowingItsTarget"] = try !fm.fileExists(atPath: reopened.directory.appendingPathComponent(linked).path) && Data(contentsOf: sentinel.appendingPathComponent("README.md")) == bytes
            let release = beta.appendingPathComponent("records-release"), pidFile = beta.appendingPathComponent("records-shell.pid"), command = "umask 077; echo $$ > \"$2\"; while [ ! -f \"$1\" ]; do /bin/sleep 0.05; done"
            let hook: [String: Any] = ["hooks": ["Notification": [["matcher": "DeleteCheck", "hooks": [["name": "删除前后台检查", "type": "command", "command": "/bin/sh", "args": ["-c", command, "records-check", release.path, pidFile.path], "async": true, "timeout": 15]]]]]]
            let hookText = String(decoding: try JSONSerialization.data(withJSONObject: hook), as: UTF8.self); try reopened.hooks.save(hookText, project: true, workspace: beta.path, expectedHash: nil)
            guard let definition = try reopened.hooks.catalog(workspace: beta.path).first(where: { $0.name == "删除前后台检查" }) else { throw PetError("实际后台检查未载入") }
            try reopened.hooks.setEnabled(definition, true, workspace: beta.path); let beforeHook = try reopened.prepareDeletion([target])
            _ = try await reopened.hooks.fire(.notification, trigger: "records-busy", store: reopened, taskID: target, value: "DeleteCheck")
            let started = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: pidFile.path), reopened.hooks.isRunning(target), Date() < started { await wait(0.05) }
            guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 else { throw PetError("实际后台进程未启动") }
            let busyBytes = try Data(contentsOf: reopened.directory.appendingPathComponent(target + ".json")); var busyRejected = 0
            do { _ = try reopened.prepareDeletion([target]) } catch { busyRejected += 1 }
            do { _ = try await reopened.permanentlyDelete(beforeHook) } catch { busyRejected += 1 }
            checks["actualRunningShellBlocksDeletionReviewAndCommit"] = try busyRejected == 2 && Data(contentsOf: reopened.directory.appendingPathComponent(target + ".json")) == busyBytes && reopened.task(target) != nil
            try Data().write(to: release); let stopped = Date().addingTimeInterval(10)
            while reopened.hooks.isRunning(target), Date() < stopped { await wait(0.05) }
            checks["actualShellCompletesBeforeDeletionCanContinue"] = !reopened.hooks.isRunning(target) && kill(pid, 0) != 0 && reopened.task(target)?.events.last?.status == "completed"
            let workspaceTask = reopened.create(title: "工作区内的任务", workspace: worktree.path), earlier = reopened.create(title: "工作区已有归档", workspace: worktree.path), general = reopened.create(title: "同路径通用任务", workspace: worktree.path, workMode: .general)
            try reopened.organization.register(worktree.path, mode: .coding); try reopened.organization.register(worktree.path, mode: .general); try reopened.setArchived([earlier], archived: true); try reopened.setWorkspaceArchived(worktree.path, mode: .coding, archived: true)
            let archiveID = reopened.organization.archiveID(worktree.path, mode: .coding)!, workspacePlan = try reopened.prepareDeletion([], workspaceIDs: [archiveID]); _ = try await reopened.permanentlyDelete(workspacePlan)
            checks["workspaceDeletionIncludesEarlierArchiveButPreservesOtherMode"] = workspacePlan.ids == Set([workspaceTask, earlier]) && reopened.task(workspaceTask) == nil && reopened.task(earlier) == nil && reopened.task(general) != nil && !reopened.organization.directories(.coding, tasks: reopened.tasks, includingArchived: true).contains(where: { $0.path == worktree.path })
            let count = reopened.tasks.count; try reopened.organization.register(worktree.path, mode: .coding)
            checks["deletedWorkspaceCanBeExplicitlyAddedAgainWithoutRestoringTasks"] = reopened.tasks.count == count && reopened.organization.directories(.coding, tasks: reopened.tasks).contains(where: { $0.path == worktree.path }) && reopened.task(workspaceTask) == nil
            reopened.selectedID = general; _ = try await reopened.permanentlyDelete(reopened.prepareDeletion([general]))
            checks["deletingLastGeneralTaskKeepsGeneralSelectionFallback"] = reopened.selectedID == nil && reopened.selectionFallbackMode == .general
            let replacement = reopened.create(workMode: reopened.selectionFallbackMode); checks["newTaskAfterGeneralDeletionRemainsInGeneralMode"] = reopened.task(replacement)?.organizationMode == .general
            let empty = output.appendingPathComponent("projects/empty"); try reopened.organization.register(empty.path, mode: .coding); try reopened.setWorkspaceArchived(empty.path, mode: .coding, archived: true)
            let emptyPlan = try reopened.prepareDeletion([], workspaceIDs: [reopened.organization.archiveID(empty.path, mode: .coding)!]); _ = try await reopened.permanentlyDelete(emptyPlan)
            checks["emptyWorkspaceDeletionCreatesNoTaskAndKeepsDirectory"] = emptyPlan.records.isEmpty && fm.fileExists(atPath: empty.path)
            let badRoot = output.appendingPathComponent("unreadable-deletion-profile"); try fm.copyItem(at: coreRoot, to: badRoot); let badLedger = badRoot.appendingPathComponent("agent/deleted-records.json"); try Data("{".utf8).write(to: badLedger)
            let invalid = AgentStore(directory: badRoot, legacy: [], extensionHome: shared), invalidBefore = try Data(contentsOf: badRoot.appendingPathComponent("agent/index.json"))
            do { _ = try invalid.prepareDeletion([fork]); checks["damagedDeletionLedgerStopsRecordAccessAndPreservesFiles"] = false } catch { checks["damagedDeletionLedgerStopsRecordAccessAndPreservesFiles"] = try invalid.task(fork) == nil && Data(contentsOf: badLedger) == Data("{".utf8) && Data(contentsOf: badRoot.appendingPathComponent("agent/index.json")) == invalidBefore }
            try await checkTaskRecordImports(output, checks: &checks)
            let realData = try Data(contentsOf: output.appendingPathComponent("retained-real-wiki.json")), real = try JSONDecoder().decode(AgentTaskRecord.self, from: realData), history = AgentTaskExport.snapshot(real)
            let json = try AgentTaskExport.data(history, format: .json), markdown = try AgentTaskExport.data(history, format: .markdown)
            try json.write(to: output.appendingPathComponent("native-real-history.json")); try markdown.write(to: output.appendingPathComponent("native-real-history.md"))
            checks["retainedRealModelHistoryExportsActualMessagesAndToolCalls"] = history.messages.map(\.id) == real.messages.filter({ $0.nativeContext != true }).map(\.id) && !history.messages.flatMap({ $0.toolCalls ?? [] }).isEmpty && history.messages.map(\.content) == real.messages.filter({ $0.nativeContext != true }).map(\.content)
            let raw = try JSONSerialization.jsonObject(with: json) as! [String: Any]
            checks["historyExportOmitsDraftAndExecutionConfiguration"] = raw["draft"] == nil && raw["agent"] == nil && raw["contextSummary"] == nil && raw["hookContexts"] == nil && (try? JSONDecoder().decode(AgentTaskRecord.self, from: json)) == nil
            let file = output.appendingPathComponent("existing-export.json"); try bytes.write(to: file); let destination = try AgentTaskExport.destination(file, profile: coreRoot, application: Bundle.main.bundleURL), otherBytes = try Data(contentsOf: beta.appendingPathComponent("README.md")); try otherBytes.write(to: file, options: .atomic)
            do { try destination.files.writeData(json, to: destination.url, expectedTarget: destination.signature); checks["exportCannotOverwriteAChangedDestination"] = false } catch { checks["exportCannotOverwriteAChangedDestination"] = try Data(contentsOf: file) == otherBytes }
            var rejected = 0
            for url in [core.directory.appendingPathComponent(fork + ".json"), Bundle.main.bundleURL.appendingPathComponent("history.json")] { do { _ = try AgentTaskExport.destination(url, profile: coreRoot, application: Bundle.main.bundleURL) } catch { rejected += 1 } }
            let link = output.appendingPathComponent("export-link.json"); try fm.createSymbolicLink(at: link, withDestinationURL: sentinel.appendingPathComponent("README.md"))
            do { _ = try AgentTaskExport.destination(link, profile: coreRoot, application: Bundle.main.bundleURL) } catch { rejected += 1 }
            checks["exportRejectsPrivateStorageApplicationAndSymbolicLinks"] = try rejected == 3 && Data(contentsOf: sentinel.appendingPathComponent("README.md")) == bytes
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("任务记录原生检查未通过") }
            let ui = try await prepareTaskRecordsUI(output, role: role)
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            var ready = ui; ready["appPID"] = getpid(); ready["binaryHash"] = hash; ready["checks"] = checks; ready["modelsCalled"] = false; try write(ready, "task-records-ui-ready.json")
            let deadline = Date().addingTimeInterval(7200); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-task-records-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-task-records-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; var value = control.archiveReadback(); value["appPID"] = getpid(); try write(value, "native-task-records-" + name + ".json")
                }; await wait(0.25)
            }
            if let data = try? Data(contentsOf: output.appendingPathComponent("task-records-ui-acceptance.json")), let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], let values = ui["checks"] as? [String: Bool] { report["uiValidated"] = ui["appPID"] as? Int == Int(getpid()) && ui["binaryHash"] as? String == hash && !values.isEmpty && values.values.allSatisfy { $0 }; report["ui"] = ui }
            checks["noUnexpectedModelRequestOrFabricatedReplyInUITasks"] = calls == 0 && tasks.tasks.compactMap({ tasks.task($0.id) }).allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.messages.contains(where: { $0.role == "assistant" }) }
            report["appPID"] = getpid(); report["binaryHash"] = hash
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "task-records-report.json")
    }
}
