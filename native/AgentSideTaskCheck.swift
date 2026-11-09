import AppKit

@MainActor extension AppDelegate {
    private func sideResult(_ output: URL, name: String, checks: [String: Bool], values: [String: Any], requests: Int, error: String?) {
        var value = values; value["checks"] = checks; value["success"] = error == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; value["appPID"] = getpid(); value["sessionID"] = AgentSideTasks.sessionID; value["blockedModelAttempts"] = requests
        if let error { value["error"] = error }
        if let binary = Bundle.main.executableURL { value["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic)
    }
    func runAgentSideTaskCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], values: [String: Any] = [:], requests = 0, failure: String?
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; await tasks.sideTasks.waitForStartup()
            runtime.modelRequestCheck = { requests += 1; throw PetError("侧任务检查禁止模型请求") }
            let service = tasks.sideTasks, fm = FileManager.default, workspace = output.appendingPathComponent("project-" + UUID().uuidString)
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true); let original = Data("公开来源 583\n".utf8); try original.write(to: workspace.appendingPathComponent("source.txt"))
            let parent = tasks.create(title: "侧任务实际文件检查", workspace: workspace.path, mode: .agent); tasks.update(parent) { $0.permission = .automatic; $0.modelOverride = "deepseek-flash" }
            guard runtime.submit("主任务公开要求 PARENT_ONLY_583，保持原件。", taskID: parent, startImmediately: false) else { throw PetError("主任务要求未保存") }
            func record(_ id: String) throws -> Data { try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) }
            func tool(_ id: String, _ name: String, _ arguments: [String: Any]) async throws -> AgentToolResult { try await AgentTools(store: tasks, taskID: id).execute(AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))) }
            let parentBefore = try record(parent), off = try service.create(parentID: parent)
            checks["missingSettingDefaultsToTemporarySideTask"] = !service.settings.recoverable && tasks.task(off)?.sideTask?.retained == false
            checks["newSideTaskKeepsScopeAndModelWithoutCopyingParentConversation"] = tasks.task(off)?.workspace == workspace.path && tasks.task(off)?.mode == .agent && tasks.task(off)?.permission == .automatic && tasks.task(off)?.modelOverride == "deepseek-flash" && tasks.task(off)?.messages.isEmpty == true && tasks.task(off)?.parentID == parent
            checks["creationDoesNotRewriteParentAndUsesParentMonitorInsteadOfSidebar"] = try record(parent) == parentBefore && service.children(of: parent).map(\.id) == [off] && !service.sidebarVisible(tasks.task(off)!)
            guard runtime.submit("侧任务只读取本任务的公开要求 SIDE_ONLY_583。", taskID: off, startImmediately: false) else { throw PetError("侧任务要求未保存") }
            let history = try await tool(off, "read_task_history", [:])
            checks["actualHistoryToolDoesNotExposeParentConversation"] = !history.failed && history.text.contains("SIDE_ONLY_583") && !history.text.contains("PARENT_ONLY_583")
            let read = try await tool(off, "read_file", ["path": "source.txt"]), written = try await tool(off, "write_file", ["path": "report.txt", "content": String(decoding: original, as: UTF8.self)])
            checks["sideTaskActuallyReadsAndWritesItsWorkspaceFiles"] = try !read.failed && read.text.contains("583") && !written.failed && Data(contentsOf: workspace.appendingPathComponent("report.txt")) == original && tasks.task(off)?.changeRounds?.first?.id == tasks.task(off)?.messages.last?.id
            runtime.start(parent); let live = runtime.isRunning(parent), runningParent = try record(parent), parallel = try service.create(parentID: parent)
            checks["sideTaskCanBeCreatedWhileParentRuntimeIsActive"] = try live && record(parent) == runningParent && tasks.task(parallel) != nil
            runtime.cancel(parent)
            checks["stoppingParentDoesNotCancelIndependentSideTask"] = tasks.task(parallel)?.status == .ready && tasks.task(parallel)?.agent?.ownerID == nil
            let oldRevision = service.revision; try service.saveSettings(recoverable: true, expectedRevision: oldRevision)
            let retained = try service.create(parentID: parent)
            guard runtime.submit("保留这份侧任务的文件和草稿。", taskID: retained, startImmediately: false) else { throw PetError("保留侧任务要求未保存") }
            tasks.update(retained) { $0.draft = "保留的侧任务草稿" }
            _ = try await tool(retained, "write_file", ["path": "retained-report.txt", "content": "retained-583\n"])
            checks["enablingRecoveryOnlyAffectsNewSideTasks"] = tasks.task(off)?.sideTask?.retained == false && tasks.task(parallel)?.sideTask?.retained == false && tasks.task(retained)?.sideTask?.retained == true
            let enabledRevision = service.revision; try service.saveSettings(recoverable: false, expectedRevision: enabledRevision)
            let onQuit = try service.create(parentID: parent)
            checks["disablingRecoveryDoesNotConvertExistingRetainedTask"] = tasks.task(retained)?.sideTask?.retained == true && tasks.task(onQuit)?.sideTask?.retained == false
            let settingsURL = tasks.directory.deletingLastPathComponent().appendingPathComponent("side-tasks/settings.json"), settingBytes = try Data(contentsOf: settingsURL)
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: settingsURL.path)
            do { try service.saveSettings(recoverable: true, expectedRevision: service.revision); checks["readonlySettingsSaveIsRejected"] = false } catch { checks["readonlySettingsSaveIsRejected"] = true }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            checks["failedSettingSaveKeepsActualBytesAndCurrentValue"] = try Data(contentsOf: settingsURL) == settingBytes && !service.settings.recoverable
            do { try service.saveSettings(recoverable: true, expectedRevision: enabledRevision); checks["staleSettingsRevisionIsRejected"] = false } catch { checks["staleSettingsRevisionIsRejected"] = true }
            let stoppedParent = try record(parent); _ = try await service.discard(off)
            checks["discardRemovesOnlyTemporaryHistoryAndPreservesProjectFiles"] = try tasks.task(off) == nil && tasks.deletions.taskIDs.contains(off) && Data(contentsOf: workspace.appendingPathComponent("report.txt")) == original && Data(contentsOf: workspace.appendingPathComponent("source.txt")) == original && record(parent) == stoppedParent
            guard let independent = tasks.fork(parallel) else { throw PetError(tasks.writeError ?? "未创建独立分支") }
            checks["explicitBranchIsAnOrdinaryPersistentTask"] = tasks.task(independent)?.sideTask == nil && service.sidebarVisible(tasks.task(independent)!)
            try service.keepAsTask(parallel)
            checks["explicitKeepPromotesTemporaryTaskWithoutLosingHistory"] = tasks.task(parallel)?.sideTask == nil && tasks.task(parallel)?.parentID == parent && service.sidebarVisible(tasks.task(parallel)!)
            let policyParent = tasks.create(title: "只读范围", workspace: workspace.path, mode: .agent); tasks.update(policyParent) { $0.inheritedLimits = AgentInheritedLimits(readOnly: true, network: false, permission: .review) }
            let limited = try service.create(parentID: policyParent)
            do { let result = try await tool(limited, "write_file", ["path": "denied.txt", "content": "denied"]); checks["sideTaskPreservesInheritedReadonlyLimit"] = result.failed } catch { checks["sideTaskPreservesInheritedReadonlyLimit"] = true }
            do { _ = try AgentTools(store: tasks, taskID: limited).approvalReason(for: AgentToolCall(id: UUID().uuidString, name: "fetch_url", arguments: "{\"url\":\"https://example.com\"}")); checks["sideTaskPreservesInheritedNetworkLimit"] = false } catch { checks["sideTaskPreservesInheritedNetworkLimit"] = true }
            let command = try await tool(limited, "run_command", ["command": "pwd", "network": false, "timeout_seconds": 3])
            checks["limitedSideTaskCanActuallyRunReadonlyTerminal"] = !command.failed && command.text.contains(workspace.lastPathComponent) && !fm.fileExists(atPath: workspace.appendingPathComponent("denied.txt").path)
            let generalParent = tasks.create(title: "无工作区主任务", mode: .ask, workMode: .general), general = try service.create(parentID: generalParent)
            let noWorkspace = try await tool(general, "run_command", ["command": "pwd", "network": false, "timeout_seconds": 3])
            checks["askSideTaskWithoutWorkspaceCanActuallyUseTerminal"] = !noWorkspace.failed && tasks.task(general)?.workspace == nil && tasks.task(general)?.mode == .ask && tasks.task(general)?.organizationMode == .general
            do { _ = try service.create(parentID: retained); checks["sideTaskCannotSilentlyCreateNestedSideTask"] = false } catch { checks["sideTaskCannotSilentlyCreateNestedSideTask"] = true }
            let index = tasks.directory.appendingPathComponent("index.json"), count = tasks.tasks.count, originalParent = try record(parent)
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: index.path)
            do { _ = try service.create(parentID: parent); checks["readonlyIndexPreventsHalfCreatedSideTask"] = false } catch { checks["readonlyIndexPreventsHalfCreatedSideTask"] = true }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
            checks["failedCreationKeepsParentAndTaskCount"] = try record(parent) == originalParent && tasks.tasks.count == count
            let orphanParent = tasks.create(title: "独立保留检查", workspace: workspace.path); try service.saveSettings(recoverable: true, expectedRevision: service.revision)
            let orphan = try service.create(parentID: orphanParent); _ = try await tasks.permanentlyDelete(tasks.prepareDeletion([orphanParent]))
            checks["deletingParentDoesNotDeleteRetainedSideConversation"] = tasks.task(orphan) != nil && service.sidebarVisible(tasks.task(orphan)!)
            try tasks.setArchived([orphan], archived: true); try tasks.setArchived([orphan], archived: false)
            checks["explicitArchiveAndRestorePreserveSideAsOrdinaryTask"] = tasks.task(orphan)?.sideTask == nil && tasks.task(orphan)?.archived == false
            try service.saveSettings(recoverable: false, expectedRevision: service.revision)
            let reloaded = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["secondStoreInSameProcessDoesNotExpireLiveTemporaryTask"] = reloaded.task(onQuit) != nil && reloaded.task(retained)?.draft == "保留的侧任务草稿"
            await wait(0.05)
            checks["noModelRequestsOrAssistantMessagesWereCreated"] = requests == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.messages.contains { $0.role == "assistant" } != true && tasks.task($0.id)?.modelReceipts?.isEmpty != false }
            tasks.selectedID = parent
            values = ["parentID": parent, "retainedID": retained, "temporaryOnQuitID": onQuit, "independentID": independent, "promotedID": parallel, "workspace": workspace.path, "retainedRecordHashBeforeQuit": AgentFiles.hash(try record(retained))]
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("side-task-before-quit.json"), options: .atomic)
        } catch { failure = error.localizedDescription }
        sideResult(output, name: "side-task-result.json", checks: checks, values: values, requests: requests, error: failure)
    }
    func runAgentSideTaskReopenCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], values: [String: Any] = [:], failure: String?, requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; await tasks.sideTasks.waitForStartup()
            runtime.modelRequestCheck = { requests += 1; throw PetError("侧任务重启检查禁止模型请求") }
            let facts = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("side-task-before-quit.json"))) as! [String: Any]
            let retained = facts["retainedID"] as! String, temporary = facts["temporaryOnQuitID"] as! String, parent = facts["parentID"] as! String
            let raw = try Data(contentsOf: tasks.directory.appendingPathComponent(retained + ".json"))
            checks["normalQuitRemovesUnretainedConversation"] = tasks.task(temporary) == nil && tasks.deletions.taskIDs.contains(temporary)
            checks["retainedConversationKeepsExactRecordBytesAcrossRealRestart"] = AgentFiles.hash(raw) == facts["retainedRecordHashBeforeQuit"] as? String
            checks["retainedConversationRemainsInParentMonitor"] = tasks.sideTasks.children(of: parent).contains { $0.id == retained }
            try tasks.sideTasks.open(retained)
            checks["reopenedRetainedTaskKeepsMessagesDraftAndExecutionScope"] = tasks.task(retained)?.draft == "保留的侧任务草稿" && tasks.task(retained)?.messages.count == 1 && tasks.task(retained)?.sideTask?.retained == true && tasks.task(retained)?.sideTask?.sessionID == AgentSideTasks.sessionID
            let workspace = URL(fileURLWithPath: facts["workspace"] as! String)
            checks["temporaryTaskCleanupKeepsActualProjectOutputs"] = try Data(contentsOf: workspace.appendingPathComponent("report.txt")) == Data("公开来源 583\n".utf8) && Data(contentsOf: workspace.appendingPathComponent("retained-report.txt")) == Data("retained-583\n".utf8)
            tasks.selectedID = parent; values = ["parentID": parent, "retainedID": retained]
        } catch { failure = error.localizedDescription }
        checks["noModelRequestDuringReopen"] = requests == 0
        sideResult(output, name: "side-task-reopen-result.json", checks: checks, values: values, requests: requests, error: failure)
    }
    func runAgentSideTaskSessionCheck(_ output: URL) async {
        var requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; await tasks.sideTasks.waitForStartup()
            runtime.modelRequestCheck = { requests += 1; try Data(String(requests).utf8).write(to: output.appendingPathComponent("side-session-blocked-model-attempts"), options: .atomic); throw PetError("侧任务中断检查禁止模型请求") }
            let workspace = output.appendingPathComponent("session-project-" + UUID().uuidString); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data("original\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
            let parent = tasks.create(title: "侧任务重启恢复", workspace: workspace.path); tasks.update(parent) { $0.permission = .automatic }
            func input(_ id: String, _ text: String) throws { guard runtime.submit(text, taskID: id, startImmediately: false) else { throw PetError(runtime.submissionError ?? "要求未保存") } }
            func write(_ id: String, _ path: String, _ content: String) async throws { let args = try JSONSerialization.data(withJSONObject: ["path": path, "content": content]); let result = try await AgentTools(store: tasks, taskID: id).execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: args, as: UTF8.self))); guard !result.failed else { throw PetError(result.text) } }
            try input(parent, "保留主任务的公开要求，不复制到侧任务。")
            try tasks.sideTasks.saveSettings(recoverable: true, expectedRevision: tasks.sideTasks.revision)
            let retained = try tasks.sideTasks.create(parentID: parent); try input(retained, "保留的侧任务公开要求。")
            tasks.update(retained) { $0.draft = "保留的侧任务草稿" }; try await write(retained, "retained-report.txt", "retained-session\n")
            try tasks.sideTasks.saveSettings(recoverable: false, expectedRevision: tasks.sideTasks.revision)
            let plain = try tasks.sideTasks.create(parentID: parent); try input(plain, "关闭后清理这份临时公开对话。")
            tasks.update(plain) { $0.draft = "临时侧任务草稿" }; try await write(plain, "temporary-report.txt", "temporary-session\n")
            let interrupted = try tasks.sideTasks.create(parentID: parent); try input(interrupted, "第一轮将 tracked.txt 改为第一版。")
            let first = tasks.task(interrupted)!.messages.last!.id; try await write(interrupted, "tracked.txt", "one\n")
            try input(interrupted, "第二轮通过终端新增 unfinished.txt 并等待，供真实中断检查。")
            let second = tasks.task(interrupted)!.messages.last!.id; tasks.update(interrupted) { $0.draft = "保留中断侧任务的草稿" }
            let command = "printf 'partial-session\\n' > unfinished.txt; /bin/sleep 45 & wait # " + output.path
            let facts: [String: Any] = ["appPID": getpid(), "parentID": parent, "retainedID": retained, "temporaryID": plain, "interruptedID": interrupted, "firstMessageID": first, "secondMessageID": second, "workspace": workspace.path, "sessionID": AgentSideTasks.sessionID, "commandMarker": output.path, "modelRequestsAtReady": requests, "retainedRecordHash": AgentFiles.hash(try Data(contentsOf: tasks.directory.appendingPathComponent(retained + ".json")))]
            try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("side-session-ready.json"), options: .atomic)
            let args = try JSONSerialization.data(withJSONObject: ["command": command, "network": false, "timeout_seconds": 90])
            let result = try await AgentTools(store: tasks, taskID: interrupted).execute(AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: String(decoding: args, as: UTF8.self)))
            try Data(("原进程未在执行中终止：" + result.text).utf8).write(to: output.appendingPathComponent("side-session-unexpected-completion"), options: .atomic)
        } catch { try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("side-session-error"), options: .atomic) }
    }
    func runAgentSideTaskSessionObserver(_ output: URL) async {
        var checks: [String: Bool] = [:], failure: String?, requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; await tasks.sideTasks.waitForStartup()
            runtime.modelRequestCheck = { requests += 1; throw PetError("观察进程禁止模型请求") }
            let facts = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("side-session-ready.json"))) as! [String: Any], before = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: output.appendingPathComponent("live-before-observer.json")))
            let id = facts["interruptedID"] as! String, parent = facts["parentID"] as! String
            guard let metadata = tasks.tasks.first(where: { $0.id == id }) else { throw PetError("运行中的侧任务记录不可用") }
            do { _ = try tasks.sideTasks.access(metadata); checks["actualOtherProcessSessionLeasePreventsAccess"] = false } catch { checks["actualOtherProcessSessionLeasePreventsAccess"] = error.localizedDescription.contains("另一个应用实例") }
            checks["otherLiveProcessCannotAcceptNewInputIntoOwnedSideTask"] = !runtime.submit("此输入不得保存到另一进程的侧任务。", taskID: id, startImmediately: false)
            try tasks.save(parent)
            checks["liveOwnerTaskRecordsRemainByteForByteUnchanged"] = try before.allSatisfy { name, hash in AgentFiles.hash(try Data(contentsOf: tasks.directory.appendingPathComponent(name))) == hash }
            checks["startupDoesNotPurgeAnotherLiveProcessTemporaryTasks"] = tasks.tasks.contains { $0.id == facts["temporaryID"] as? String } && tasks.tasks.contains { $0.id == id } && tasks.sideTasks.issue == nil
        } catch { failure = error.localizedDescription }
        checks["noModelRequestDuringObservation"] = requests == 0
        sideResult(output, name: "side-session-observer-result.json", checks: checks, values: [:], requests: requests, error: failure)
    }
    func runAgentSideTaskSessionRecovery(_ output: URL) async {
        var checks: [String: Bool] = [:], values: [String: Any] = [:], failure: String?, requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; await tasks.sideTasks.waitForStartup()
            runtime.modelRequestCheck = { requests += 1; throw PetError("恢复检查禁止模型请求") }
            let facts = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("side-session-ready.json"))) as! [String: Any]
            let retained = facts["retainedID"] as! String, plain = facts["temporaryID"] as! String, interrupted = facts["interruptedID"] as! String, parent = facts["parentID"] as! String, first = facts["firstMessageID"] as! String, second = facts["secondMessageID"] as! String, workspace = URL(fileURLWithPath: facts["workspace"] as! String)
            checks["actualKilledSessionOrdinaryTemporaryHistoryIsPurged"] = tasks.task(plain) == nil && tasks.deletions.taskIDs.contains(plain)
            let rawRetained = try Data(contentsOf: tasks.directory.appendingPathComponent(retained + ".json"))
            checks["retainedConversationHasExactBytesAfterKilledProcessRestart"] = AgentFiles.hash(rawRetained) == facts["retainedRecordHash"] as? String
            guard let preserved = tasks.task(interrupted) else { throw PetError("未完成文件记录的侧任务被错误清理") }
            checks["realInterruptedCaptureBecomesIncompleteRoundCheckpoint"] = preserved.pendingFileCapture == nil && preserved.sideTask?.needsReview == true && preserved.changeRounds?.first(where: { $0.id == second })?.warning != nil
            checks["unsafeTemporaryTaskAndItsActualBackupsArePreserved"] = try preserved.sideTask?.retained == false && !tasks.deletions.taskIDs.contains(interrupted) && FileManager.default.fileExists(atPath: tasks.backupDirectory(interrupted).path)
            let review = try AgentRoundRollback.review(taskID: interrupted, from: first, store: tasks)
            checks["incompleteLaterRoundBlocksEarlierWholeFileRollback"] = !review.canApply && review.issues.contains { $0.contains("执行中断") }
            checks["startupCleanupDoesNotOverwriteOrDeleteActualProjectOutputs"] = try Data(contentsOf: workspace.appendingPathComponent("tracked.txt")) == Data("one\n".utf8) && Data(contentsOf: workspace.appendingPathComponent("unfinished.txt")) == Data("partial-session\n".utf8) && Data(contentsOf: workspace.appendingPathComponent("temporary-report.txt")) == Data("temporary-session\n".utf8)
            let before = try Data(contentsOf: tasks.directory.appendingPathComponent(interrupted + ".json"))
            checks["restoredHistoryDoesNotAutomaticallyResumeExecution"] = !runtime.submit("未打开前不应接受这条输入。", taskID: interrupted, startImmediately: false) && !runtime.isWorking
            checks["rejectedUnopenedInputKeepsRecoveredRecordBytes"] = try Data(contentsOf: tasks.directory.appendingPathComponent(interrupted + ".json")) == before
            try tasks.sideTasks.open(retained); try tasks.sideTasks.open(interrupted)
            checks["openingRetainedAndProtectedTasksRebindsCurrentSessionWithoutConvertingRetention"] = tasks.task(retained)?.sideTask?.retained == true && tasks.task(retained)?.draft == "保留的侧任务草稿" && tasks.task(interrupted)?.sideTask?.retained == false && tasks.task(interrupted)?.sideTask?.sessionID == AgentSideTasks.sessionID
            checks["parentMonitorCanReturnToRetainedAndProtectedSideTasks"] = Set(tasks.sideTasks.children(of: parent).map(\.id)) == [retained, interrupted]
            tasks.selectedID = parent; values = ["parentID": parent, "retainedID": retained, "interruptedID": interrupted]
        } catch { failure = error.localizedDescription }
        checks["noModelRequestDuringRecovery"] = requests == 0
        sideResult(output, name: "side-session-recovery-result.json", checks: checks, values: values, requests: requests, error: failure)
    }
}
