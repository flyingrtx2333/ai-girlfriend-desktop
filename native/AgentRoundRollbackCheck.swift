import AppKit

@MainActor extension AppDelegate {
    func prepareRoundRollbackCheck(_ output: URL, createdFile: Bool = false, name: String = "按回合撤回实际文件") async throws -> (taskID: String, first: String, second: String, workspace: URL) {
        ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
        let workspace = output.appendingPathComponent("project-" + UUID().uuidString), fm = FileManager.default
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("alpha-original\n".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        try Data("beta-original\n".utf8).write(to: workspace.appendingPathComponent("b space.txt"))
        let id = tasks.create(title: name, workspace: workspace.path, mode: .agent); tasks.update(id) { $0.permission = .automatic }
        func write(_ path: String, _ value: String) async throws {
            let args = try JSONSerialization.data(withJSONObject: ["path": path, "content": value], options: [.sortedKeys])
            let result = try await AgentTools(store: tasks, taskID: id).execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: args, as: UTF8.self)))
            guard !result.failed else { throw PetError(result.text) }
        }
        guard runtime.submit("第一轮：将 a.txt 和 b space.txt 改为各自的第一版。", taskID: id, startImmediately: false) else { throw PetError(runtime.submissionError ?? "未保存第一轮要求") }
        let first = tasks.task(id)!.messages.last!.id
        try await write("a.txt", "alpha-one\n"); try await write("b space.txt", "beta-one\n")
        guard runtime.submit("第二轮：将两个文件改为第二版。" + (createdFile ? "另创建 created.txt。" : "保留已有草稿。"), taskID: id, startImmediately: false) else { throw PetError(runtime.submissionError ?? "未保存第二轮要求") }
        let second = tasks.task(id)!.messages.last!.id
        try await write("a.txt", "alpha-two\n"); try await write("b space.txt", "beta-two\n")
        if createdFile { try await write("created.txt", "created-in-second-round\n") }
        tasks.update(id) { $0.draft = "保留这份未发送草稿" }
        let facts: [String: Any] = ["taskID": id, "first": first, "second": second, "workspace": workspace.path, "modelOutputsCreated": false]
        try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("round-rollback-fixture-" + id + ".json"), options: .atomic)
        return (id, first, second, workspace)
    }
    func runAgentRoundRollbackCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("文件撤回检查禁止模型请求") }
            let fm = FileManager.default, fixture = try await prepareRoundRollbackCheck(output, createdFile: true), id = fixture.taskID
            func bytes(_ path: String) throws -> Data { try Data(contentsOf: fixture.workspace.appendingPathComponent(path)) }
            func rejected(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
            let record = tasks.task(id)!, history = record.messages
            checks["twoRealFileRoundsRecordedWithoutMergingBoundaries"] = record.changeRounds?.count == 2 && record.changeRounds?[0].changes.count == 2 && record.changeRounds?[1].changes.count == 3 && record.changes.filter { $0.path.hasSuffix("/a.txt") }.count == 1
            let reopened = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["roundCheckpointsSurviveNativeReload"] = reopened.task(id)?.changeRounds?.map(\.id) == [fixture.first, fixture.second]
            var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]; old.removeValue(forKey: "changeRounds")
            let legacy = try JSONDecoder().decode(AgentTaskRecord.self, from: JSONSerialization.data(withJSONObject: old))
            checks["legacyRecordDoesNotClaimCompleteRoundCoverage"] = legacy.changeRounds == nil && !AgentRoundRollback.available(legacy, from: fixture.first)
            let review = try AgentRoundRollback.review(taskID: id, from: fixture.second, store: tasks)
            checks["reviewContainsOnlySelectedAndLaterFileStates"] = review.canApply && review.entries.count == 3 && review.roundIDs == [fixture.second]
            try Data("later-user-edit\n".utf8).write(to: fixture.workspace.appendingPathComponent("b space.txt"))
            rejected("laterUserEditBlocksWholeBatch") { try AgentRoundRollback.apply(review, store: tasks) }
            checks["conflictDoesNotPartiallyRestoreOtherFiles"] = try bytes("a.txt") == Data("alpha-two\n".utf8) && bytes("b space.txt") == Data("later-user-edit\n".utf8) && fm.fileExists(atPath: fixture.workspace.appendingPathComponent("created.txt").path) && tasks.task(id)?.pendingFileRollback == nil
            try Data("beta-two\n".utf8).write(to: fixture.workspace.appendingPathComponent("b space.txt"))
            let refreshed = try AgentRoundRollback.review(taskID: id, from: fixture.second, store: tasks)
            guard let target = refreshed.entries.first(where: { $0.path.hasSuffix("/a.txt") })?.desired.backup else { throw PetError("实际检查点缺失") }
            let checkpoint = URL(fileURLWithPath: target), originalBackup = try Data(contentsOf: checkpoint)
            try Data("damaged-checkpoint".utf8).write(to: checkpoint)
            checks["damagedCheckpointDisablesWholeRollback"] = try !AgentRoundRollback.review(taskID: id, from: fixture.second, store: tasks).canApply
            try originalBackup.write(to: checkpoint)
            let index = tasks.directory.appendingPathComponent("index.json"), before = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json"))
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: index.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path) }
            rejected("readonlyTaskIndexPreventsStartingRollback") { try AgentRoundRollback.apply(try AgentRoundRollback.review(taskID: id, from: fixture.second, store: tasks), store: tasks) }
            checks["failedPersistenceKeepsFilesAndTaskBytes"] = try bytes("a.txt") == Data("alpha-two\n".utf8) && Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) == before
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
            try AgentRoundRollback.apply(AgentRoundRollback.review(taskID: id, from: fixture.second, store: tasks), store: tasks)
            checks["secondRoundRestoresActualFirstVersionAndRemovesItsNewFile"] = try bytes("a.txt") == Data("alpha-one\n".utf8) && bytes("b space.txt") == Data("beta-one\n".utf8) && !fm.fileExists(atPath: fixture.workspace.appendingPathComponent("created.txt").path)
            checks["fileRollbackRetainsHumanMessagesAndDraft"] = tasks.task(id)?.messages.map(\.id) == history.map(\.id) && tasks.task(id)?.draft == "保留这份未发送草稿" && tasks.task(id)?.pendingFileRollback == nil
            checks["onlySelectedRoundMarkedRestored"] = tasks.task(id)?.changeRounds?[0].changes.allSatisfy { $0.restoredAt == nil } == true && tasks.task(id)?.changeRounds?[1].changes.allSatisfy { $0.restoredAt != nil } == true
            guard let remaining = tasks.task(id)?.changes.last(where: { $0.path.hasSuffix("/a.txt") && $0.restoredAt == nil }) else { throw PetError("剩余修改未保留") }
            try AgentChanges.restore(remaining, taskID: id, store: tasks)
            checks["existingSingleFileRestoreUpdatesRoundHistory"] = try bytes("a.txt") == Data("alpha-original\n".utf8) && tasks.task(id)?.changeRounds?[0].changes.first(where: { $0.path.hasSuffix("/a.txt") })?.restoredAt != nil
            try AgentRoundRollback.apply(AgentRoundRollback.review(taskID: id, from: fixture.first, store: tasks), store: tasks)
            checks["earlierRoundRestoresRemainingFileAndKeepsHistory"] = try bytes("b space.txt") == Data("beta-original\n".utf8) && tasks.task(id)?.messages.map(\.id) == history.map(\.id)
            checks["allCompletedRoundActionsNowUnavailable"] = !AgentRoundRollback.available(tasks.task(id)!, from: fixture.first) && !AgentRoundRollback.available(tasks.task(id)!, from: fixture.second)
            checks["noModelRequestsOrAssistantOutputsCreated"] = requests == 0 && tasks.tasks.allSatisfy { (tasks.task($0.id)?.modelReceipts ?? []).isEmpty && tasks.task($0.id)?.messages.contains { $0.role == "assistant" } == false }
            report["taskID"] = id; report["workspace"] = fixture.workspace.path
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["blockedModelAttempts"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("round-rollback-result.json"), options: .atomic)
    }
    func runAgentRoundRollbackCrashCheck(_ output: URL) async {
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { throw PetError("中断检查禁止模型请求") }
            let fixture = try await prepareRoundRollbackCheck(output, createdFile: true, name: "中断撤回恢复实际文件")
            let sizeIndex = CommandLine.arguments.firstIndex(of: "--round-crash-bytes")
            let size = sizeIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 134_217_728
            guard (16_777_216...536_870_912).contains(size) else { throw PetError("中断检查文件大小超出范围") }
            let file = fixture.workspace.appendingPathComponent("z-large.bin")
            try Data(repeating: 65, count: size).write(to: file)
            guard runtime.submit("第三轮：将 z-large.bin 的全部 A 字节改为 B，保留其他文件。", taskID: fixture.taskID, startImmediately: false) else { throw PetError("未保存大文件要求") }
            let args: [String: Any] = ["command": "/usr/bin/tr A B < z-large.bin > z-large-next.bin && /bin/mv -f z-large-next.bin z-large.bin", "network": false, "timeout_seconds": 30]
            let call = AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
            let result = try await AgentTools(store: tasks, taskID: fixture.taskID).execute(call); guard !result.failed else { throw PetError(result.text) }
            let files = try AgentFiles(workspace: fixture.workspace.path), names = ["a.txt", "b space.txt", "created.txt", "z-large.bin"]
            var hashes: [String: String] = [:]; for name in names { hashes[name] = try files.fileHash(files.literalURL(name)) }
            let value: [String: Any] = ["appPID": getpid(), "taskID": fixture.taskID, "messageID": fixture.second, "workspace": fixture.workspace.path, "projectHashesBefore": hashes, "largeBytes": size, "noModelRequests": true]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("round-crash-ready.json"), options: .atomic)
            let deadline = Date().addingTimeInterval(120)
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("start-round-crash").path), Date() < deadline { await wait(0.05) }
            guard FileManager.default.fileExists(atPath: output.appendingPathComponent("start-round-crash").path) else { throw PetError("中断检查未开始") }
            try AgentRoundRollback.apply(AgentRoundRollback.review(taskID: fixture.taskID, from: fixture.second, store: tasks), store: tasks)
            try Data("实际撤回已完成，未在中途终止".utf8).write(to: output.appendingPathComponent("round-crash-unexpected-completion"), options: .atomic)
        } catch { try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("round-crash-error"), options: .atomic) }
    }
    func runAgentRoundRollbackRecoveryCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("恢复检查禁止模型请求") }
            let facts = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("round-crash-ready.json"))) as! [String: Any]
            guard let id = facts["taskID"] as? String, let message = facts["messageID"] as? String, let record = tasks.task(id), record.pendingFileRollback != nil else { throw PetError("没有真实中断留下的撤回记录") }
            checks["actualInterruptedRollbackSurvivesNativeRestart"] = true
            let before = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json"))
            checks["newInputRejectedWithoutChangingTask"] = !runtime.submit("此输入不应进入未恢复的任务。", taskID: id, startImmediately: false)
            checks["rejectedInputKeepsActualTaskBytes"] = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) == before
            do { _ = try tasks.prepareDeletion([id]); checks["pendingRecoveryProtectsTaskAndCheckpointsFromDeletion"] = false } catch { checks["pendingRecoveryProtectsTaskAndCheckpointsFromDeletion"] = true }
            checks["pendingRecoveryRejectsForkWithoutCreatingTask"] = tasks.fork(id) == nil
            let other = tasks.create(title: "同项目隔离检查", workspace: record.workspace, mode: .agent)
            let call = AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: "{\"path\":\"should-not-exist.txt\",\"content\":\"blocked\"}")
            do { _ = try AgentTools(store: tasks, taskID: other).approvalReason(for: call); checks["pendingRecoveryBlocksOtherTaskToolsInSameProject"] = false } catch { checks["pendingRecoveryBlocksOtherTaskToolsInSameProject"] = true }
            let review = try AgentRoundRollback.review(taskID: id, from: message, store: tasks)
            checks["actualPartialFileStatesCanBeReviewedForRecovery"] = review.recovery && review.canApply && review.entries.count == 4
            checks["noModelTransmissionDuringRecoveryInspection"] = requests == 0 && tasks.tasks.allSatisfy { (tasks.task($0.id)?.modelReceipts ?? []).isEmpty }
            tasks.selectedID = id; report["taskID"] = id
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = getpid(); report["modelAttempts"] = requests
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("round-rollback-recovery-result.json"), options: .atomic)
    }
}
