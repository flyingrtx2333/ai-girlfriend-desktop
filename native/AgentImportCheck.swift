import AppKit
import SQLite3

@MainActor extension AppDelegate {
    func runAgentImportCheck(_ output: URL) async {
        var report: [String: Any] = [:]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("导入运行时未初始化") }
            let binary = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": binaryHash], "import-process.json")
            let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("import-fixtures.json"))) as! [String: Any]
            let codexRoot = URL(fileURLWithPath: fixtures["codexRoot"] as! String), qoderRoot = URL(fileURLWithPath: fixtures["qoderRoot"] as! String)
            let codex = fixtures["codex"] as! String, other = fixtures["codexOther"] as! String, qoder = fixtures["qoder"] as! String, qoderUI = fixtures["qoderUI"] as! String
            let service = tasks.dataImport
            func finishBatch() async throws {
                let deadline = Date().addingTimeInterval(90)
                while service.active && Date() < deadline { await wait(0.05) }
                guard !service.active else { throw PetError("原导入仍在运行，请保留原进程") }
            }
            func updateTitle(_ id: String, value: String) throws {
                var db: OpaquePointer?, query: OpaquePointer?
                guard sqlite3_open_v2(codexRoot.appendingPathComponent("state_5.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw PetError("隔离来源索引无法打开") }
                defer { sqlite3_finalize(query); sqlite3_close(db) }
                guard sqlite3_prepare_v2(db, "UPDATE threads SET title=? WHERE id=?", -1, &query, nil) == SQLITE_OK else { throw PetError("隔离来源索引无法修改") }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(query, 1, value, -1, transient); sqlite3_bind_text(query, 2, id, -1, transient)
                guard sqlite3_step(query) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw PetError("隔离来源条目未修改") }
            }
            if CommandLine.arguments.contains("--import-native-only") {
                let fm = FileManager.default, phaseURL = output.appendingPathComponent("import-phase.json"), nativeURL = output.appendingPathComponent("import-native.json")
                if fm.fileExists(atPath: nativeURL.path) { return }
                var checks: [String: Bool] = [:]
                if !fm.fileExists(atPath: phaseURL.path) {
                    let source = codexRoot.appendingPathComponent("sessions")
                    try Data("not-json\n".utf8).write(to: source.appendingPathComponent("rollout-broken.jsonl"))
                    let large = source.appendingPathComponent("rollout-oversized.jsonl"); fm.createFile(atPath: large.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: UInt64(AgentImportReaders.maximumBytes + 1)); try handle.close()
                    let originalRecords = fixtures["records"] as! [[String: Any]], genuine = originalRecords.first { $0["kind"] as? String == "codex" }!["source"] as! String
                    try fm.createSymbolicLink(atPath: source.appendingPathComponent("rollout-link.jsonl").path, withDestinationPath: genuine)
                    await service.detect(.codex, root: codexRoot)
                    let valid = service.preview.filter { $0.issue == nil }
                    checks["actualCodexRecordsDetected"] = valid.count == 2 && Set(valid.map(\.sourceID)) == Set([codex, other])
                    checks["invalidAndOversizedRecordsReported"] = service.preview.filter { $0.issue != nil }.count == 3
                    checks["inheritedParentHeaderDoesNotTurnSubagentIntoDuplicate"] = service.preview.contains { $0.issue?.contains("子代理") == true } && valid.count == 2
                    checks["sourceSymbolicLinkNotRead"] = !service.preview.contains { $0.file.hasSuffix("rollout-link.jsonl") }
                    let selection = tasks.selectedID
                    let notify = service.onChange
                    service.onChange = {
                        notify?()
                        if service.batch?.state == "running", service.batch?.items.filter({ $0.state == "imported" }).count == 1 { service.pause() }
                    }
                    try service.begin(.codex, root: codexRoot, ids: Set(valid.map(\.id)))
                    let contender = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
                    contender.dataImport.resume()
                    checks["anotherImporterCannotAcquireLiveLock"] = !contender.dataImport.active && contender.dataImport.issue?.contains("另一个") == true
                    try await finishBatch(); service.onChange = notify
                    checks["pauseKeepsSelectedSnapshotAndCompletedItem"] = service.batch?.state == "paused" && service.batch?.items.filter({ $0.state == "imported" }).count == 1 && service.batch?.items.filter({ $0.state == "pending" }).count == 1
                    checks["backgroundImportDoesNotChangeSelectedTask"] = tasks.selectedID == selection
                    guard checks.values.allSatisfy({ $0 }) else { throw PetError("导入暂停阶段检查失败：" + checks.filter { !$0.value }.map(\.key).joined(separator: ", ")) }
                    let legacyID = service.batch!.items.first { $0.state == "imported" }!.record.targetID
                    let legacyBoundary = tasks.task(legacyID)!.importOrigin!.historyThroughID!
                    tasks.update(legacyID) { $0.importOrigin?.historyThroughID = nil }
                    try write(["phase": "paused", "checks": checks, "binaryHash": binaryHash, "legacyID": legacyID, "legacyBoundary": legacyBoundary, "items": service.batch!.items.map { ["sourceID": $0.record.sourceID, "targetID": $0.record.targetID, "state": $0.state] }], "import-phase.json")
                    return
                }
                let phase = try JSONSerialization.jsonObject(with: Data(contentsOf: phaseURL)) as! [String: Any]; checks = phase["checks"] as! [String: Bool]
                checks["legacyImportBoundaryRecoveredOnActualRestart"] = (phase["legacyID"] as? String).flatMap { tasks.task($0)?.importOrigin?.historyThroughID } == phase["legacyBoundary"] as? String
                checks["actualAppRestartRecoversPausedBatch"] = service.batch?.state == "paused" && service.unfinished && !service.active && service.batch?.items.count == 2
                service.resume(); try await finishBatch()
                checks["resumeProcessesOnlyRemainingItem"] = service.batch?.state == "completed" && service.batch?.items.allSatisfy { $0.state == "imported" } == true && tasks.tasks.filter { $0.importOrigin?.source == .codex }.count == 2
                let records = tasks.tasks.filter { $0.importOrigin != nil }.compactMap { tasks.task($0.id) }
                checks["foreignPermissionsAndUsageNotInherited"] = records.allSatisfy { $0.permission == .review && $0.status == .stopped && $0.pendingCalls.isEmpty && $0.approvals.isEmpty && $0.modelReceipts == nil && $0.inputTokens == 0 && $0.messages.allSatisfy { $0.toolCalls == nil && $0.toolCallID == nil } }
                let target = records.first { $0.importOrigin?.sourceID == codex }!, untouched = records.first { $0.importOrigin?.sourceID == other }!
                checks["realUserTextSeparatedFromSourceInstructions"] = target.messages.contains { $0.isHumanInput && $0.content.contains("SWE-bench") } && !target.messages.contains { $0.isHumanInput && $0.content.hasPrefix("# AGENTS.md instructions") }
                await service.detect(.codex, root: codexRoot); checks["repeatedDetectionExcludesDuplicates"] = service.preview.filter { $0.issue == "已经导入" }.count == 2
                control.showAgentTask(target.id); control.keepVoiceDraft("IMPORT-LOCAL-DRAFT-2086"); control.persistAgentDraft()
                try updateTitle(codex, value: target.title + " · 来源更新"); try updateTitle(other, value: untouched.title + " · 来源更新")
                await service.detect(.codex, root: codexRoot)
                checks["continuedLocalTaskNotOverwrittenBySourceUpdate"] = service.preview.first(where: { $0.sourceID == codex })?.issue?.contains("本地") == true && tasks.task(target.id)?.draft == "IMPORT-LOCAL-DRAFT-2086"
                guard let update = service.preview.first(where: { $0.sourceID == other && $0.issue == nil }) else { throw PetError("原未修改记录没有可导入更新") }
                try service.begin(.codex, root: codexRoot, ids: [update.id]); try await finishBatch()
                checks["untouchedSourceUpdateUsesSameTaskAndSnapshot"] = tasks.task(untouched.id)?.title == untouched.title + " · 来源更新" && tasks.task(untouched.id)?.importOrigin?.snapshot == untouched.importOrigin?.snapshot && tasks.tasks.filter { $0.importOrigin?.source == .codex }.count == 2
                guard let sourceFork = tasks.fork(untouched.id), let forkRecord = tasks.task(sourceFork) else { throw PetError("原导入任务无法创建分支") }
                let forkHash = try AgentDataImport.taskHash(forkRecord)
                try updateTitle(other, value: untouched.title + " · 再次更新")
                await service.detect(.codex, root: codexRoot)
                guard let canonical = service.preview.first(where: { $0.sourceID == other && $0.issue == nil }) else { throw PetError("任务分支阻止了原记录接收更新") }
                try service.begin(.codex, root: codexRoot, ids: [canonical.id]); try await finishBatch()
                let finalForkHash = try AgentDataImport.taskHash(tasks.task(sourceFork)!)
                checks["forkDoesNotReplaceCanonicalImportTarget"] = canonical.targetID == untouched.id && tasks.task(untouched.id)?.title == untouched.title + " · 再次更新" && finalForkHash == forkHash
                await service.detect(.qoder, root: qoderRoot); guard let before = service.preview.first(where: { $0.sourceID == qoder && $0.issue == nil }) else { throw PetError("真实Qoder记录不可用") }
                let raw = try Data(contentsOf: URL(fileURLWithPath: before.file)), lines = raw.split(separator: 10).map(Data.init)
                guard let actualLeaf = lines.last(where: { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["type"] as? String == "active-leaf" }) else { throw PetError("真实Qoder记录缺少当前分支标记") }
                let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: before.file)); try writer.seekToEnd(); try writer.write(contentsOf: Data([10]) + actualLeaf + Data([10])); try writer.close()
                try service.begin(.qoder, root: qoderRoot, ids: [before.id]); try await finishBatch()
                checks["changedSourceAfterPreviewIsRejected"] = service.batch?.items.first?.state == "failed" && tasks.task(before.targetID) == nil
                await service.detect(.qoder, root: qoderRoot); guard let current = service.preview.first(where: { $0.sourceID == qoder && $0.issue == nil }) else { throw PetError("重新检测原Qoder记录失败") }
                try service.begin(.qoder, root: qoderRoot, ids: [current.id]); try await finishBatch()
                checks["actualQoderBranchAndHumanTextPreserved"] = tasks.task(current.targetID)?.messages.first(where: \.isHumanInput)?.content.trimmingCharacters(in: .whitespacesAndNewlines) == "hi"
                checks["sourceSnapshotPreservesActualBytes"] = try Data(contentsOf: service.sourceURL(current.targetID)) == Data(contentsOf: URL(fileURLWithPath: current.file))
                tasks.update(current.targetID) { $0.mode = .ask; $0.toolGroups = [] }
                let asking = tasks.task(current.targetID)!, system = try runtime.systemContext(asking)
                let toolData = try JSONSerialization.data(withJSONObject: AgentTools.definitions(mode: .ask, groups: []))
                let overhead = AgentContext.estimate(system) + AgentContext.estimate(String(decoding: toolData, as: UTF8.self)) + 200
                checks["askContextExcludesUnloadedBrowserAndDesktopInstructions"] = !system.contains("浏览器动作只用最新") && !system.contains("电脑操作先 desktop_status") && !system.contains("Canvas是本任务持久")
                checks["actualImportedHiFitsExisting8192Budget"] = overhead + 2048 + 400 + asking.messages.reduce(0, { $0 + AgentContext.estimate($1.content) + 20 }) < 8192
                var model = store.preferences; model.contextTokens = 8192; model.replyTokens = 2048; model.endpoint = "https://api.deepseek.com"; model.modelInfo = nil; model.reasoningEffort = "auto"
                let envelope = try AgentModel.requestBody(preferences: model, system: system, messages: asking.messages, tools: AgentTools.definitions(mode: .ask, groups: []))
                checks["agentEnvelopeUsesTokenBudgetWithoutLegacyByteGate"] = system.utf8.count + 2048 > 8192 && (envelope["messages"] as? [[String: Any]])?.first?["content"] as? String == system
                checks["agentEnvelopeKeepsGenerationOptions"] = envelope["model"] as? String == model.model && envelope["max_tokens"] as? Int == 2048 && (envelope["thinking"] as? [String: String])?["type"] == "disabled"
                let imported = tasks.task(target.id)!, window = AgentContext.window(imported)
                let sourceText = try service.sourceHistory(target.id, offset: 0, limit: 1, contentOffset: 0, contentLimit: 1000)
                checks["importedToolDetailsStayReadableWithoutFillingDefaultContext"] = imported.messages.contains(where: \.isImportedContext) && !window.contains(where: \.isImportedContext) && sourceText.contains("session_meta")
                checks["importedUserOriginalsRemainInHistoryDataBlock"] = window.first?.nativeContext == true && window.first?.content.contains("用户原文") == true && imported.messages.filter(\.isHumanInput).allSatisfy { window.first?.content.contains($0.content) == true }
                let search = try await AgentTools(store: tasks, taskID: target.id).execute(AgentToolCall(id: UUID().uuidString, name: "read_task_history", arguments: "{\"offset\":0,\"query\":\"SWE-bench\",\"role\":\"user\"}"))
                checks["historySearchSeparatesHumanTextFromAssistantSuggestion"] = search.text.contains("例如SWE-bench？") && !search.text.contains("SWE-bench Verified")
                let bounded = try service.sourceHistory(target.id, offset: 0, limit: 5, contentOffset: 0, contentLimit: 16000)
                checks["rawMetadataPagesHaveBoundedContextAndCursor"] = AgentContext.estimate(bounded) < 1600 && bounded.contains("content_offset=")
                let master = output.deletingLastPathComponent(), ownersURL = master.appendingPathComponent("import-live-tasks.json")
                let regressionURL = master.appendingPathComponent("import-continuation-failure.json")
                if let bytes = try? Data(contentsOf: ownersURL), let owners = try JSONSerialization.jsonObject(with: bytes) as? [String: String], let id = owners["codex"], let bytes = try? Data(contentsOf: FileManager.default.fileExists(atPath: regressionURL.path) ? regressionURL : master.appendingPathComponent("profile/agent/" + id + ".json")), let actual = try? JSONDecoder().decode(AgentTaskRecord.self, from: bytes), !(actual.modelReceipts ?? []).isEmpty {
                    let past = actual.messages.prefix(AgentContext.offset(actual)), calls = Dictionary(past.flatMap { $0.toolCalls ?? [] }.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
                    let historyReceipt = past.last { $0.role == "tool" && calls[$0.toolCallID ?? ""] == "read_task_history" }, fileReceipt = past.last { $0.role == "tool" && calls[$0.toolCallID ?? ""] == "read_file" }
                    let actualPreferences = try JSONDecoder().decode(PetPreferences.self, from: Data(contentsOf: master.appendingPathComponent("profile/settings.json"))), priorPreferences = store.preferences
                    store.preferences = actualPreferences; defer { store.preferences = priorPreferences }
                    let actualSystem = try runtime.systemContext(actual), actualTools = try runtime.toolDefinitions(actual, preferences: actualPreferences)
                    let actualOverhead = AgentContext.estimate(actualSystem) + AgentContext.estimate(String(decoding: try JSONSerialization.data(withJSONObject: actualTools), as: UTF8.self)) + 200
                    let retainedBudget = AgentContext.factBudget(actual, preferences: actualPreferences, overhead: actualOverhead, maximumImages: 0)
                    let actualWindow = AgentContext.window(actual, maximumImages: 0, archivedFactBudget: retainedBudget)
                    let envelope = try AgentModel.requestBody(preferences: actualPreferences, system: actualSystem, messages: actualWindow, tools: actualTools)
                    let snapshot = try AgentContext.snapshot(preferences: actualPreferences, system: actualSystem, skills: "", messages: actualWindow, tools: actualTools, loadedSkills: 0)
                    let frame = actualWindow.first { $0.content.hasPrefix("[历史工具原文摘录") }?.content ?? ""
                    checks["actualFailedContinuationRetainsHistoryAndFileReceiptsTogether"] = historyReceipt?.toolCallID.map { frame.contains($0) } == true && fileReceipt?.toolCallID.map { frame.contains($0) } == true && ["SWE-bench", "14.20", "8.35", "21.10"].allSatisfy { frame.contains($0) }
                    checks["actualFailedContinuationFitsUnchangedModelBudget"] = actualPreferences.contextLimit == 8192 && envelope["max_tokens"] as? Int == 2048 && snapshot.estimatedTokens + actualPreferences.outputLimit <= actualPreferences.contextLimit
                    report["actualContinuationBudget"] = ["overhead": actualOverhead, "retainedFacts": retainedBudget, "inputEstimate": snapshot.estimatedTokens, "outputReserve": actualPreferences.outputLimit, "limit": actualPreferences.contextLimit]
                }
                let fork = tasks.fork(current.targetID)!
                tasks.update(fork) { $0.importOrigin?.snapshot = "../settings.json" }
                do { _ = try service.sourceHistory(fork, offset: 0, limit: 1, contentOffset: 0, contentLimit: 1000); checks["foreignSnapshotPathCannotEscape"] = false } catch { checks["foreignSnapshotPathCannotEscape"] = true }
                tasks.update(fork) { $0.archived = true }
                let cancelled = AgentStore(directory: output.appendingPathComponent("cancel-profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home")), cancelService = cancelled.dataImport
                await cancelService.detect(.codex, root: codexRoot)
                cancelService.onChange = { if cancelService.batch?.state == "running", cancelService.batch?.items.filter({ $0.state == "imported" }).count == 1 { cancelService.cancel() } }
                try cancelService.begin(.codex, root: codexRoot, ids: Set(cancelService.preview.filter { $0.issue == nil }.map(\.id)))
                let deadline = Date().addingTimeInterval(90); while cancelService.active && Date() < deadline { await wait(0.05) }
                checks["cancelRetainsImportedItemsAndStopsRemainder"] = cancelService.batch?.state == "cancelled" && cancelService.batch?.items.filter({ $0.state == "imported" }).count == 1 && cancelService.batch?.items.filter({ $0.state == "pending" }).count == 1 && !cancelService.unfinished
                let success = checks.values.allSatisfy { $0 }; try write(["success": success, "checks": checks, "binaryHash": binaryHash, "contextMetrics": ["askOverhead": overhead, "replyReserve": 2048, "contextLimit": 8192], "actualContinuationBudget": report["actualContinuationBudget"] ?? [:]], "import-native.json")
                if !success { throw PetError("导入原生检查失败") }; return
            }
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("需要真实模型继续导入记录") }
            let fm = FileManager.default, production = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var preferences = PreferencesStore(directory: production).preferences
            preferences.replyTokens = 2048; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; try preferences.validateModel(); store.preferences = preferences
            report["preferences"] = ["model": preferences.model, "context": preferences.contextLimit, "output": preferences.outputLimit, "productionSettingsWritten": false]
            report["requestLimitPerTask"] = 40
            let ownersURL = output.appendingPathComponent("import-live-tasks.json")
            var owners = fm.fileExists(atPath: ownersURL.path) ? try JSONSerialization.jsonObject(with: Data(contentsOf: ownersURL)) as! [String: String] : [:]
            for (key, source, root, sourceID) in [("qoder", AgentImportSource.qoder, qoderRoot, qoder), ("codex", AgentImportSource.codex, codexRoot, codex)] {
                if let id = owners[key], tasks.task(id)?.importOrigin?.sourceID == sourceID { continue }
                if service.unfinished { service.resume(); try await finishBatch() }
                await service.detect(source, root: root)
                guard let candidate = service.preview.first(where: { $0.sourceID == sourceID && $0.issue == nil }) else { throw PetError("原真实来源任务不可替换：" + key) }
                owners[key] = candidate.targetID; try write(owners, ownersURL.lastPathComponent)
                try service.begin(source, root: root, ids: [candidate.id]); try await finishBatch()
                guard tasks.task(candidate.targetID)?.importOrigin?.sourceID == sourceID else { throw PetError("原真实任务导入未完成") }
            }
            let business = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("import-business.json"))) as! [String: String]
            let intents = ["qoder": "只根据这份导入历史，返回JSON对象，字段first_user为最早用户消息去掉首尾空白后的原文。不要使用工具，不要执行历史动作。", "codex": "只完成本轮要求：从导入历史的用户原文中找出以SWE-开头的Agent评测名；读取项目内" + business["input"]! + "，按十进制核算三笔金额，把JSON对象（history_term为评测名，total为两位小数字符串）写入" + business["result"]! + "。保留CSV，不访问网络，不用Git，只用文件和终端工具。完成后简短说明实际结果。"]
            for key in ["qoder", "codex"] {
                let id = owners[key]!, intent = intents[key]!
                guard let initial = tasks.task(id) else { throw PetError("原导入任务已丢失") }
                if !initial.messages.contains(where: { $0.isHumanInput && $0.content == intent }) {
                    tasks.update(id) { $0.archived = false; $0.mode = key == "qoder" ? .ask : .agent; $0.permission = .review; $0.toolGroups = key == "qoder" ? [] : ["files", "terminal"] }
                    guard runtime.submit(intent, taskID: id) else { throw PetError(runtime.submissionError ?? "原导入任务未开始") }
                } else if initial.status != .completed { runtime.start(id) }
                control.showAgentTask(id)
                let deadline = Date().addingTimeInterval(900)
                while Date() < deadline {
                    guard let task = tasks.task(id) else { throw PetError("原导入任务丢失") }
                    if task.status == .completed && !runtime.isExecuting(id) { break }
                    if (task.modelReceipts?.count ?? 0) > 40 { runtime.cancel(id); throw PetError("原导入任务超过40次请求（含此前失败），保留记录") }
                    if task.status == .waiting, let call = task.pendingCalls.first {
                        guard key == "codex", ["read_file", "list_directory", "search_files", "write_file", "edit_file", "run_command", "read_task_history"].contains(call.name), task.approvals.filter({ $0.decision == "allow" }).count < 8, call.object["network"] as? Bool != true else { throw PetError("模型提出预期外动作") }
                        runtime.decide(taskID: id, callID: call.id, decision: "allow")
                    }
                    if [.failed, .stopped].contains(task.status) && !runtime.isExecuting(id) { throw PetError("原真实任务已停止：" + (task.events.last?.detail ?? "")) }
                    await wait(0.2)
                }
                guard let task = tasks.task(id), task.status == .completed else { throw PetError("原真实任务尚未完成") }
                if key == "qoder" {
                    let text = task.messages.last(where: { $0.role == "assistant" })?.content ?? ""
                    guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), let value = try JSONSerialization.jsonObject(with: Data(text[first...last].utf8)) as? [String: Any], value["first_user"] as? String == "hi", !task.messages.contains(where: { $0.toolCalls?.isEmpty == false }) else { throw PetError("模型没有从原导入历史恢复hi，保留实际回答") }
                }
                report[key] = ["taskID": id, "requests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "status": task.status.rawValue, "completedBeforeResume": initial.status == .completed, "requestsAtResume": initial.modelReceipts?.count ?? 0, "requestsAbovePollingLimit": max(0, (task.modelReceipts?.count ?? 0) - 40)]
            }
            if !fm.fileExists(atPath: output.appendingPathComponent("import-ui-planned.json").path) {
                try updateTitle(codex, value: tasks.task(owners["codex"]!)!.title + " · 来源更新")
                await service.detect(.qoder, root: qoderRoot)
                guard let next = service.preview.first(where: { $0.sourceID == qoderUI && $0.issue == nil }) else { throw PetError("原界面导入记录不可替换") }
                try service.begin(.qoder, root: qoderRoot, ids: [next.id]); service.pause(); try await finishBatch()
                try write(["pausedSourceID": qoderUI, "pausedTargetID": next.targetID, "copiedMetadataUpdatedForProtectionCheck": true], "import-ui-planned.json")
            }
            control.showDataImportSettings()
            try write(["appPID": getpid(), "binaryHash": binaryHash, "tasks": owners], "import-ui-ready.json")
            let deadline = Date().addingTimeInterval(1200)
            while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-import-ui").path) { await wait(0.2) }
            let ui = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("import-ui-acceptance.json"))) as! [String: Any]
            let required = ["previewAndSourceSelection", "durableBatchControls", "importedHistoryAndOrigin", "repeatImportKeepsLocalChanges", "normalAndNarrowLayout"]
            guard ui["appPID"] as? Int == Int(getpid()), ui["binaryHash"] as? String == binaryHash, let checks = ui["checks"] as? [String: Bool], required.allSatisfy({ checks[$0] == true }) else { throw PetError("真实导入窗口验收未完成") }
            report["ui"] = ui; report["success"] = true; report["binaryHash"] = binaryHash; try write(report, "import-report.json")
        } catch {
            report["success"] = false; report["error"] = error.localizedDescription
            try? write(report, "import-report.json")
            if CommandLine.arguments.contains("--import-native-only"), !FileManager.default.fileExists(atPath: output.appendingPathComponent("import-native.json").path) { try? write(report, "import-native.json") }
        }
    }
}
