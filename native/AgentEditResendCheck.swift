import AppKit

@MainActor extension AppDelegate {
    func runAgentEditResendCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("编辑重发文件检查禁止模型请求") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            func receiptHashes() throws -> Set<String> { Set(try tasks.tasks.flatMap { record in try (tasks.task(record.id)?.modelReceipts ?? []).map { AgentFiles.hash(try encoder.encode($0)) } }) }
            let initialReceipts = try receiptHashes()
            let fm = FileManager.default, fixture = try await prepareRoundRollbackCheck(output, createdFile: true), id = fixture.taskID
            guard runtime.submit("第三轮：只将 a.txt 改为第三版。", taskID: id, startImmediately: false) else { throw PetError("未保存第三轮要求") }
            let result = try await AgentTools(store: tasks, taskID: id).execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: "{\"path\":\"a.txt\",\"content\":\"alpha-three\\n\"}"))
            guard !result.failed else { throw PetError(result.text) }
            let original = tasks.task(id)!
            func bytes(_ path: String) throws -> Data { try Data(contentsOf: fixture.workspace.appendingPathComponent(path)) }
            func rejected(_ name: String, _ operation: () throws -> Void) { do { try operation(); checks[name] = false } catch { checks[name] = true } }
            let review = try AgentEditResend.review(taskID: id, messageID: fixture.second, store: tasks)
            checks["reviewIncludesSelectedAndLaterRealFileRounds"] = review.canApply && review.rollback?.entries.count == 3 && review.rollback?.roundIDs.count == 2
            let index = tasks.directory.appendingPathComponent("index.json"), recordFile = tasks.directory.appendingPathComponent(id + ".json"), before = try Data(contentsOf: recordFile), count = tasks.tasks.count
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: index.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path) }
            rejected("actualReadonlySavePreventsReplacement") { _ = try AgentEditResend.apply(review, text: "修改后的第二轮要求。", store: tasks, runtime: runtime, startImmediately: false) }
            checks["failedReplacementKeepsOriginalTaskAndActualFiles"] = try Data(contentsOf: recordFile) == before && tasks.tasks.count == count && bytes("a.txt") == Data("alpha-three\n".utf8) && bytes("b space.txt") == Data("beta-two\n".utf8) && fm.fileExists(atPath: fixture.workspace.appendingPathComponent("created.txt").path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
            tasks.update(id) { $0.draft = "另一个窗口修改的草稿" }
            rejected("staleConversationVersionRejectsReplacement") { _ = try AgentEditResend.apply(review, text: "修改后的第二轮要求。", store: tasks, runtime: runtime, startImmediately: false) }
            tasks.update(id) { $0.draft = original.draft }
            try Data("later-user-edit\n".utf8).write(to: fixture.workspace.appendingPathComponent("b space.txt"))
            let conflict = try AgentEditResend.review(taskID: id, messageID: fixture.second, store: tasks)
            rejected("laterUserFileEditRejectsWholeReplacement") { _ = try AgentEditResend.apply(conflict, text: "修改后的第二轮要求。", store: tasks, runtime: runtime, startImmediately: false) }
            checks["conflictKeepsConversationAndOtherFiles"] = try !conflict.canApply && bytes("a.txt") == Data("alpha-three\n".utf8) && bytes("b space.txt") == Data("later-user-edit\n".utf8) && tasks.task(id)?.archived == false && tasks.tasks.count == count
            try Data("beta-two\n".utf8).write(to: fixture.workspace.appendingPathComponent("b space.txt"))
            let fresh = try AgentEditResend.review(taskID: id, messageID: fixture.second, store: tasks)
            rejected("emptyEditedInputIsRejectedBeforeAnyMutation") { _ = try AgentEditResend.apply(fresh, text: " \n", store: tasks, runtime: runtime, startImmediately: false) }
            rejected("contextMaintenanceIsNotSubmittedAsAnEditedRequirement") { _ = try AgentEditResend.apply(fresh, text: "/compact", store: tasks, runtime: runtime, startImmediately: false) }
            let revised = "/canvas 按新的第二轮要求核对文件，不沿用第三轮要求。", nextID = try AgentEditResend.apply(fresh, text: revised, store: tasks, runtime: runtime, startImmediately: false)
            guard let next = tasks.task(nextID), let archived = tasks.task(id) else { throw PetError("重新发送的记录不可用") }
            checks["replacementContainsOnlyOriginalPrefixAndNewExpandedInput"] = next.messages.count == 2 && next.messages.first?.id == original.messages.first?.id && next.messages.last?.content == revised && next.messages.last?.extensionInstructions?.contains("用户选择内置 /canvas") == true && next.parentID == id && next.id != id
            checks["actualFilesRevertedBeforeStartingEditedContinuation"] = try bytes("a.txt") == Data("alpha-one\n".utf8) && bytes("b space.txt") == Data("beta-one\n".utf8) && !fm.fileExists(atPath: fixture.workspace.appendingPathComponent("created.txt").path)
            checks["completeOriginalConversationIsRecoverableInArchive"] = try archived.archived && encoder.encode(archived.messages) == encoder.encode(original.messages) && archived.draft == original.draft && archived.title == original.title + " · 编辑前"
            checks["newContinuationKeepsDraftModeAndPermissionWithFreshCheckpoints"] = next.draft == original.draft && next.mode == original.mode && next.permission == original.permission && next.workspace == original.workspace && next.changeRounds?.isEmpty == true && next.pendingFileRollback == nil && next.status == .ready && tasks.selectedID == nextID
            let reloaded = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["replacementAndArchivedHistorySurviveNativeReload"] = reloaded.task(id)?.archived == true && reloaded.task(nextID)?.messages.last?.content == revised && reloaded.selectedID == nextID
            try tasks.setArchived([id], archived: false)
            checks["originalConversationRestoresThroughNormalArchiveAction"] = try tasks.task(id)?.archived == false && encoder.encode(tasks.task(id)!.messages) == encoder.encode(original.messages) && tasks.task(nextID) != nil
            let generalID = tasks.create(title: "无工作区问答编辑", mode: .ask, workMode: .general)
            guard runtime.submit("第一条公开问题。", taskID: generalID, startImmediately: false), runtime.submit("第二条公开问题。", taskID: generalID, startImmediately: false), let general = tasks.task(generalID), let first = general.messages.first else { throw PetError("无工作区要求未保存") }
            let generalReview = try AgentEditResend.review(taskID: generalID, messageID: first.id, store: tasks)
            let generalNext = try AgentEditResend.apply(generalReview, text: "修改后的公开问题。", store: tasks, runtime: runtime, startImmediately: false)
            checks["askModeWithoutWorkspaceCanReplaceInputAndRetainOldHistory"] = generalReview.rollback == nil && generalReview.notice.contains("只替换对话") && tasks.task(generalNext)?.workspace == nil && tasks.task(generalNext)?.mode == .ask && tasks.task(generalNext)?.messages.count == 1 && tasks.task(generalID)?.messages.count == 2 && tasks.task(generalID)?.archived == true
            if let flag = CommandLine.arguments.firstIndex(of: "--edit-resend-history-task"), CommandLine.arguments.indices.contains(flag + 1) {
                let sourceID = CommandLine.arguments[flag + 1]
                guard let source = tasks.task(sourceID), let old = source.messages.last(where: \.isHumanInput), let cut = source.messages.firstIndex(where: { $0.id == old.id }), let canvas = source.canvases?.first else { throw PetError("保留的真实对话或画布不可用") }
                let oldCanvasURL = try tasks.canvases.sourceURL(canvas.id, taskID: sourceID), oldCanvas = try Data(contentsOf: oldCanvasURL)
                let historyReview = try AgentEditResend.review(taskID: sourceID, messageID: old.id, store: tasks)
                let historyID = try AgentEditResend.apply(historyReview, text: "继续核对原销售画布的实际数据，保留原来的标题。", store: tasks, runtime: runtime, startImmediately: false)
                guard let history = tasks.task(historyID), let keptCanvas = history.canvases?.first else { throw PetError("历史画布未保留") }
                let historicalURL = try tasks.canvases.sourceURL(keptCanvas.id, taskID: historyID), historicalBytes = try Data(contentsOf: historicalURL), prefix = Array(source.messages.prefix(cut))
                checks["realOldAssistantMessagesAreRetainedOnlyBeforeEditedInput"] = try encoder.encode(Array(history.messages.dropLast())) == encoder.encode(prefix) && !history.messages.contains { $0.id == source.messages.last?.id } && prefix.contains { $0.role == "assistant" }
                checks["realOldReceiptsAreReducedToRetainedConversationPrefix"] = (history.modelReceipts?.count ?? 0) > 0 && (history.modelReceipts?.count ?? 0) < (source.modelReceipts?.count ?? 0) && history.modelReceipts?.allSatisfy { receipt in receipt.messageID.map { message in prefix.contains { $0.id == message } } == true } == true
                checks["historicalCanvasUsesActualEarlierImmutableSource"] = keptCanvas.hash == "494aad05e3b11f5b347cf9fd1681a5281d56eb36be24ab8208cb1a2ee61e1143" && AgentFiles.hash(historicalBytes) == keptCanvas.hash && historicalBytes != oldCanvas
                checks["archivedRealConversationAndLaterCanvasRemainRecoverable"] = try tasks.task(sourceID)?.archived == true && encoder.encode(tasks.task(sourceID)!.messages) == encoder.encode(source.messages) && Data(contentsOf: oldCanvasURL) == oldCanvas
                report["historicalContinuationID"] = historyID; report["historicalSourceID"] = sourceID
            }
            checks["noNewModelRequestsReceiptsOrAssistantOutputs"] = try requests == 0 && receiptHashes() == initialReceipts && tasks.task(nextID)?.messages.allSatisfy { $0.role == "user" } == true
            report["continuationID"] = nextID; report["sourceID"] = id; report["generalContinuationID"] = generalNext; report["workspace"] = fixture.workspace.path
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["blockedModelAttempts"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("edit-resend-result.json"), options: .atomic)
    }
}
