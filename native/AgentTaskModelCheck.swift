import AppKit

@MainActor extension AppDelegate {
    func runAgentTaskModelCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func history(_ messages: [AgentMessage]) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(messages) }
        func rejected(_ name: String, _ body: () throws -> Void) { do { try body(); checks[name] = false } catch { checks[name] = true } }
        defer { agentRuntime?.stopAll(); phase("finished") }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            let workspace = output.appendingPathComponent("workspace")
            var id = tasks.create(title: "跨模型素材核对", workspace: workspace.path)
            tasks.update(id) { $0.permission = .workspace; $0.toolGroups = ["files"] }
            rejected("controlCharactersInModelIDRejected") { try runtime.chooseModel(id, model: "model\ninvalid") }
            checks["emptyTaskCannotCompact"] = AgentContext.compactUnavailable(tasks.task(id)!) != nil
            if CommandLine.arguments.contains("--live-agent") {
                let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: production).preferences
                p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.persona = ""
                store.preferences = p
                report["defaultModel"] = p.model; report["contextLimit"] = p.contextLimit; report["outputLimit"] = p.outputLimit
                let sourceIndex = CommandLine.arguments.firstIndex(of: "--reuse-real-task")
                if let sourceIndex, sourceIndex + 1 < CommandLine.arguments.count {
                    let file = URL(fileURLWithPath: CommandLine.arguments[sourceIndex + 1])
                    let data = try Data(contentsOf: file), previous = try JSONDecoder().decode(AgentTaskRecord.self, from: data)
                    guard previous.status == .completed, Set((previous.modelReceipts ?? []).filter { $0.purpose == "conversation" && $0.completed }.map(\.requestedModel)).count == 2 else { throw PetError("复用来源必须是已经完成的真实双模型任务") }
                    tasks.update(id) { record in
                        record = previous; record.id = id; record.workspace = workspace.path
                        record.contextSummary = nil; record.contextThroughID = nil; record.contextManualThroughID = nil; record.recap = nil
                    }
                    try await runtime.refreshTaskModels()
                    report["reusedRealTask"] = file.path; report["reusedRealTaskSHA256"] = AgentFiles.hash(data)
                    report["alternativeModel"] = previous.modelReceipts?.first(where: { $0.purpose == "conversation" && $0.requestedModel != p.model })?.requestedModel
                    report["returnedModels"] = Array(Set((previous.modelReceipts ?? []).compactMap(\.returnedModel))).sorted()
                    checks["reuseRetainsOriginalRealMessages"] = try history(tasks.task(id)!.messages) == history(previous.messages)
                } else {
                    phase("reading-real-provider-model-list"); try await runtime.refreshTaskModels()
                    let available = tasks.models.models(p).map(\.id)
                    try JSONSerialization.data(withJSONObject: available, options: [.prettyPrinted]).write(to: output.appendingPathComponent("provider-models.json"))
                    let preferred = ["gpt-4.1-mini", "gpt-4o-mini", "qwen3.5-flash", "qwen-plus", "gemini-2.5-flash", "deepseek-chat"]
                    guard let alternative = preferred.first(where: { $0 != p.model && available.contains($0) }) ?? available.first(where: { $0 != p.model && !$0.contains("embed") && !$0.contains("image") && !$0.contains("audio") && !$0.contains("tts") }) else { throw PetError("服务模型列表没有第二个可选模型，无法验证真实切换") }
                    report["alternativeModel"] = alternative; report["availableModelCount"] = available.count
                    checks["providerCatalogPersistsForSameEndpoint"] = AgentTaskModels(profile: store.directory).models(p).map(\.id) == available
                    var other = p; other.endpoint = "https://example.com/v1"
                    checks["providerCatalogCannotCrossEndpoint"] = tasks.models.models(other).isEmpty
                    func awaitTask() async throws {
                        let deadline = Date().addingTimeInterval(160)
                        while Date() < deadline {
                            guard let task = tasks.task(id) else { throw PetError("任务记录不可用") }
                            if !runtime.isRunning(id), [.completed, .failed, .stopped].contains(task.status) {
                                guard task.status == .completed else { throw PetError(task.events.last?.detail ?? "真实任务未完成") }; return
                            }
                            if let review = runtime.pendingReview(id), let call = review.pendingCalls.first {
                                guard call.name == "write_file", ["cross-model-report.json", workspace.appendingPathComponent("cross-model-report.json").path].contains(call.object["path"] as? String ?? "") else { throw PetError("真实验收出现额外审批：" + call.name) }
                                runtime.decide(taskID: review.id, callID: call.id, decision: "allow")
                            }
                            await wait(0.08)
                        }
                        runtime.cancel(id); throw PetError("真实模型任务超时")
                    }
                    phase("real-default-model-read")
                    guard runtime.submit("用 read_file 实际读取 source.json，核对 edition、width、height，最后只简短列出三个真实数值。不要修改文件，不用网页、终端或其他工具，不询问已有参数。", taskID: id) else { throw PetError(runtime.submissionError ?? "任务未开始") }
                    rejected("cannotSwitchModelDuringRealRun") { try runtime.chooseModel(id, model: alternative) }
                    try await awaitTask()
                    let first = tasks.task(id)!, originalIDs = first.messages.map(\.id)
                    checks["realDefaultModelReadsSource"] = first.events.contains { $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("source.json") } && first.model == p.model
                    checks["realResponseHasProviderModelAndUsage"] = first.modelReceipts?.contains { $0.requestedModel == p.model && $0.returnedModel != nil && ($0.inputTokens ?? 0) > 0 && ($0.outputTokens ?? 0) > 0 && $0.completed } == true
                    try runtime.chooseModel(id, model: alternative)
                    let alternativePreferences = try runtime.taskPreferences(id)
                    checks["taskChoiceDoesNotChangeGlobalDefault"] = store.preferences.model == p.model && alternativePreferences.model == alternative
                    phase("real-alternative-model-continuation")
                    guard runtime.submit("依据前文实际读到的 source.json，把 edition、width、height 这三个数值写入 cross-model-report.json，再加 format 固定 crossmodel-v1。只写这四个字段，用 read_file 回读核对。不要重新询问数值，不改动输入，不用终端或网页。", taskID: id) else { throw PetError(runtime.submissionError ?? "第二模型未开始") }
                    try await awaitTask()
                    let second = tasks.task(id)!
                    let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("cross-model-report.json"))) as? [String: Any] ?? [:]
                    let source = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("source.json"))) as? [String: Any] ?? [:]
                    checks["realAlternativeModelContinuesSameHistory"] = second.model == alternative && originalIDs.allSatisfy { old in second.messages.contains { $0.id == old } }
                    checks["realCrossModelReportMatchesOriginalSource"] = actual.count == 4 && actual["format"] as? String == "crossmodel-v1" && ["edition", "width", "height"].allSatisfy { actual[$0] as? Int == source[$0] as? Int }
                    checks["realSecondModelReadsBackArtifact"] = second.events.contains { $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("cross-model-report.json") }
                    checks["separateModelReceiptsRetained"] = Set((second.modelReceipts ?? []).filter { $0.purpose == "conversation" }.map(\.requestedModel)) == Set([p.model, alternative])
                    report["returnedModels"] = Array(Set((second.modelReceipts ?? []).compactMap(\.returnedModel))).sorted()
                }
                try runtime.chooseModel(id, model: nil)
                let restoredPreferences = try runtime.taskPreferences(id)
                checks["followDefaultRestoresConfiguredModel"] = tasks.task(id)?.modelOverride == nil && restoredPreferences.model == p.model
                if let contextIndex = CommandLine.arguments.firstIndex(of: "--context-source"), contextIndex + 1 < CommandLine.arguments.count {
                    let short = tasks.task(id)!, count = short.modelReceipts?.count ?? 0
                    guard runtime.analyze(id, recap: false) else { throw PetError(runtime.analysisErrors[id] ?? "短历史预检查未开始") }
                    while runtime.analysisTitle(id) != nil { await wait(0.08) }
                    checks["shortRealHistoryRejectedBeforePaidCompaction"] = runtime.analysisErrors[id]?.contains("压缩预计无法减少占用") == true && (tasks.task(id)?.modelReceipts?.count ?? 0) == count && tasks.task(id)?.contextSummary == nil
                    report["dualModelTaskID"] = id
                    let file = URL(fileURLWithPath: CommandLine.arguments[contextIndex + 1]), data = try Data(contentsOf: file)
                    let previous = try JSONDecoder().decode(AgentTaskRecord.self, from: data)
                    guard previous.status == .completed, previous.inputTokens > 0, previous.messages.count > short.messages.count else { throw PetError("压缩来源必须是已完成的较长真实任务记录") }
                    id = tasks.create(title: previous.title, workspace: workspace.path)
                    tasks.update(id) { record in
                        record = previous; record.id = id; record.workspace = workspace.path; record.agent = nil; record.team = nil; record.automation = nil; record.activeSkills = nil; record.kind = nil; record.toolGroups = ["files"]; record.modelOverride = nil
                        record.contextSummary = nil; record.contextThroughID = nil; record.contextManualThroughID = nil; record.recap = nil
                    }
                    report["contextSource"] = file.path; report["contextSourceSHA256"] = AgentFiles.hash(data)
                }
                let baseline = tasks.task(id)!, baselineCount = baseline.modelReceipts?.count ?? 0
                report["baselineInputTokens"] = baseline.inputTokens; report["baselineOutputTokens"] = baseline.outputTokens; report["baselineReceiptCount"] = baselineCount
                let beforeMessages = try history(tasks.task(id)!.messages), estimate = try runtime.contextEstimate(id)
                phase("real-manual-compaction")
                guard runtime.analyze(id, recap: false) else { throw PetError(runtime.analysisErrors[id] ?? "压缩未开始") }
                let compactDeadline = Date().addingTimeInterval(160)
                while runtime.analysisTitle(id) != nil && Date() < compactDeadline { await wait(0.08) }
                guard runtime.analysisTitle(id) == nil, runtime.analysisErrors[id] == nil else { throw PetError(runtime.analysisErrors[id] ?? "压缩超时") }
                let compacted = tasks.task(id)!, afterEstimate = try runtime.contextEstimate(id)
                checks["manualCompactionPreservesAllRawHistory"] = try history(compacted.messages) == beforeMessages
                checks["manualCompactionUsesRealModelAndReducesEstimate"] = compacted.contextSummary?.isEmpty == false && compacted.contextThroughID != nil && (compacted.modelReceipts ?? []).contains { $0.purpose == "compaction" && $0.requestedModel == p.model && $0.completed } && afterEstimate.estimatedTokens < estimate.estimatedTokens
                report["estimateBeforeCompaction"] = estimate.estimatedTokens; report["estimateAfterCompaction"] = afterEstimate.estimatedTokens
                phase("real-task-recap")
                guard runtime.analyze(id, recap: true) else { throw PetError(runtime.analysisErrors[id] ?? "回顾未开始") }
                let recapDeadline = Date().addingTimeInterval(120)
                while runtime.analysisTitle(id) != nil && Date() < recapDeadline { await wait(0.08) }
                guard runtime.analysisTitle(id) == nil, runtime.analysisErrors[id] == nil else { throw PetError(runtime.analysisErrors[id] ?? "回顾超时") }
                let complete = tasks.task(id)!, receipts = complete.modelReceipts ?? []
                let source = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("source.json"))) as? [String: Any] ?? [:]
                let finalMessages = try history(complete.messages)
                checks["realRecapKeepsTaskStatusAndHistory"] = complete.recap?.text.isEmpty == false && complete.recap?.model == p.model && complete.status == .completed && finalMessages == beforeMessages
                checks["realRecapIncludesVerifiedNumbers"] = complete.recap?.text.contains(String(source["edition"] as? Int ?? -1)) == true && complete.recap?.text.contains(String(source["width"] as? Int ?? -1)) == true
                let addedReceipts = receipts.dropFirst(baselineCount)
                checks["usageIncludesNewCompactionAndRecapOnce"] = Set(addedReceipts.map(\.purpose)) == Set(["compaction", "recap"]) && complete.inputTokens == baseline.inputTokens + addedReceipts.reduce(0) { $0 + ($1.inputTokens ?? 0) } && complete.outputTokens == baseline.outputTokens + addedReceipts.reduce(0) { $0 + ($1.outputTokens ?? 0) }
                let reloaded = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
                checks["newOptionalRecordsSurviveReload"] = reloaded.task(id)?.recap?.text == complete.recap?.text && reloaded.task(id)?.modelReceipts?.count == receipts.count
                let index = try String(contentsOf: tasks.directory.appendingPathComponent("index.json"), encoding: .utf8)
                checks["indexOmitsDetailedReceiptsAndRecap"] = !index.contains("requestedModel") && !index.contains(complete.recap!.text)
                report["taskID"] = id; report["recap"] = complete.recap?.text; report["artifact"] = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("cross-model-report.json"))); report["receiptCount"] = receipts.count
                report["inputTokens"] = complete.inputTokens; report["outputTokens"] = complete.outputTokens
            }
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }
            report["scope"] = "Real saved-provider catalog and two requested model IDs in one task, retained raw history, real file read/write/readback, forced model compaction, explicit generated recap and provider usage. Returned model IDs are reported separately; model catalogs do not prove distinct backend implementations. No simulated model replies."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-model-report.json"), options: .atomic)
            if CommandLine.arguments.contains("--task-model-ui-hold") {
                control.showAgentTask(id); control.show(tab: "chat"); phase("ui-ready")
                let deadline = Date().addingTimeInterval(1200)
                while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
        } catch {
            report["checks"] = checks; report["success"] = false; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-model-report.json"), options: .atomic)
        }
    }
}
