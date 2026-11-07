import AppKit

@MainActor extension AppDelegate {
    func runAgentHookAsyncCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
        func object(_ file: URL) -> [String: Any] { ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
        func until(_ test: () -> Bool, seconds: Double = 5) async -> Bool { let deadline = Date().addingTimeInterval(seconds); while !test() && Date() < deadline { await wait(0.03) }; return test() }
        defer { agentRuntime?.stopAll(); phase("finished") }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            let service = tasks.hooks, workspace = output.appendingPathComponent("workspace"), cases = workspace.appendingPathComponent("native-cases"), shared = output.appendingPathComponent("shared-home")
            func definition(_ name: String) throws -> AgentHookDefinition { guard let item = try service.catalog(workspace: workspace.path).first(where: { $0.name == name }) else { throw PetError("未找到实际 Hook：" + name) }; return item }
            func enable(_ names: [String]) throws { for name in names { try service.setEnabled(definition(name), true, workspace: workspace.path) } }
            func owner(_ title: String) -> String {
                let id = tasks.create(title: title, workspace: workspace.path)
                tasks.update(id) { $0.permission = .review; $0.hookSession = UUID().uuidString; $0.messages = [AgentMessage(role: "user", content: "核对实际公开素材，public-token-marker 仅用于凭据遮蔽检查。")] }; return id
            }
            func fire(_ id: String, _ value: String, trigger: String? = nil, event: AgentHookEvent = .notification, fields: [String: Any] = [:]) async throws -> AgentHookEffect {
                try await service.fire(event, trigger: trigger ?? value, store: tasks, taskID: id, value: value, fields: fields, secret: "public-token-marker") { [weak self] in self?.control.scheduleRender() }
            }
            func idle(_ id: String) async -> Bool { await until { !service.isRunning(id) } }
            func processStopped(_ file: URL) async -> Bool {
                let info = object(file), pids = [info["pid"], info["child"]].compactMap { $0 as? Int }.map { pid_t($0) }
                guard !pids.isEmpty else { return false }; return await until { pids.allSatisfy { kill($0, 0) != 0 } }
            }
            let all = try service.catalog(workspace: workspace.path)
            checks["groupBackgroundAndEntryOverrideParsed"] = try definition("分组后台 A").runsInBackground && definition("分组后台 B").runsInBackground && !definition("显式同步覆盖").runsInBackground
            checks["invalidAsyncFieldsDiagnosed"] = try definition("无效后台字段").diagnostic != nil && definition("无效 HTTP 唤醒").diagnostic != nil
            checks["discoveryDoesNotEnableHooks"] = all.allSatisfy { !service.enabled($0) }
            try enable(["分组后台 A", "分组后台 B", "显式同步覆盖"])
            let group = owner("实际分组后台执行"), began = Date()
            _ = try await fire(group, "GroupCheck")
            checks["groupReturnsBeforeActualBackgroundCompletes"] = Date().timeIntervalSince(began) < 1 && service.isRunning(group) && FileManager.default.fileExists(atPath: cases.appendingPathComponent("override.finished").path) && !FileManager.default.fileExists(atPath: cases.appendingPathComponent("group-a.finished").path)
            _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("group-a.pid.json").path) && FileManager.default.fileExists(atPath: cases.appendingPathComponent("group-b.pid.json").path) }
            try Data().write(to: cases.appendingPathComponent("release-group")); checks["bothActualGroupProcessesFinish"] = await idle(group)
            let sourceData = try Data(contentsOf: workspace.appendingPathComponent("source.json")), sourceHash = AgentFiles.hash(sourceData)
            checks["actualBackgroundResultsQueuedWithHash"] = tasks.task(group)?.hookContexts?.count == 2 && tasks.task(group)?.hookContexts?.values.allSatisfy { $0.contains(sourceHash) } == true
            let beforeContexts = tasks.task(group)?.hookContextIDs?.count
            _ = try await fire(group, "GroupCheck")
            checks["sameTriggerDoesNotReplayBackgroundOrContext"] = !service.isRunning(group) && tasks.task(group)?.hookContextIDs?.count == beforeContexts
            try enable(["后台参数不能改写审批", "同步阻止仍生效"])
            let trap = owner("后台结果不改变审批"), started = Date()
            let immediate = try await fire(trap, "Trap", event: .preTool, fields: ["tool_name": "Trap", "public_marker": "public-token-marker"])
            checks["asyncPreToolCannotBlockOrRewrite"] = Date().timeIntervalSince(started) < 1 && immediate.deny == nil && immediate.halt == nil && immediate.updatedInput == nil && !immediate.ask
            _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("trap.pid.json").path) }
            _ = try await fire(trap, "Trap", event: .preTool)
            let call = AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: try json(["path": "native-trap-target.json", "content": "{\"actual\":true}\n"]))
            let tools = AgentTools(store: tasks, taskID: trap)
            checks["originalWriteStillRequiresReview"] = try tools.approvalReason(for: call) != nil
            _ = try await tools.execute(call)
            checks["originalToolExecutesWhileHookIsRunning"] = service.isRunning(trap) && FileManager.default.fileExists(atPath: workspace.appendingPathComponent("native-trap-target.json").path) && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("hijacked.json").path)
            try Data().write(to: cases.appendingPathComponent("release-trap")); _ = await idle(trap)
            let trapEvent = tasks.task(trap)?.events.last(where: { $0.kind == "hook" })
            checks["lateExitTwoHasNoPermissionEffect"] = trapEvent?.hook?.exitCode == 2 && trapEvent?.hook?.effect?.deny == nil && trapEvent?.hook?.effect?.halt == nil && trapEvent?.hook?.effect?.updatedInput == nil && tasks.task(trap)?.modelReceipts?.isEmpty != false
            let sync = try await fire(trap, "Sync", event: .preTool)
            checks["synchronousBlockingStillApplies"] = sync.deny?.contains("实际同步检查") == true
            let auditText = (try? String(contentsOf: cases.appendingPathComponent("audit.jsonl"), encoding: .utf8)) ?? ""
            let audit = auditText.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            checks["actualInputAndTranscriptAreRedacted"] = audit.filter { $0["kind"] as? String == "trap" }.allSatisfy { $0["redacted"] as? Bool == true && $0["transcriptExists"] as? Bool == true }
            checks["runningDuplicateDoesNotStartAnotherProcess"] = audit.filter { $0["kind"] as? String == "trap" }.count == 1
            for kind in ["cancel", "timeout", "scope", "recovery", "fork", "config", "limit", "new-input", "ui"] { try enable([kind]) }
            let cancel = owner("实际停止后台进程组")
            _ = try await fire(cancel, "cancel"); _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("cancel.pid.json").path) }
            runtime.cancel(cancel); _ = await idle(cancel)
            checks["stopKillsActualParentAndChild"] = await processStopped(cases.appendingPathComponent("cancel.pid.json"))
            checks["cancelledOutputNeverQueued"] = tasks.task(cancel)?.hookContexts?.isEmpty != false && tasks.task(cancel)?.events.last?.status == "stopped"
            let timeout = owner("实际后台超时")
            _ = try await fire(timeout, "timeout"); _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("timeout.pid.json").path) }; _ = await idle(timeout)
            checks["timeoutKillsActualParentAndChild"] = await processStopped(cases.appendingPathComponent("timeout.pid.json"))
            checks["timeoutDoesNotWakeOrDeliverPartialOutput"] = tasks.task(timeout)?.events.last?.status == "failed" && tasks.task(timeout)?.hookContexts?.isEmpty != false && tasks.task(timeout)?.modelReceipts?.isEmpty != false
            let scope = owner("后台执行范围改变")
            _ = try await fire(scope, "scope"); _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("scope.pid.json").path) }
            tasks.update(scope) { $0.mode = .ask }; _ = await idle(scope)
            checks["scopeChangeCancelsActualBackgroundProcess"] = await processStopped(cases.appendingPathComponent("scope.pid.json"))
            let recovery = owner("实际后台记录恢复")
            tasks.update(recovery) { $0.status = .completed }
            _ = try await fire(recovery, "recovery", trigger: "persisted-background-trigger")
            _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("recovery.pid.json").path) }
            for index in 0..<6 { _ = tasks.create(title: "缓存边界 \(index)", workspace: workspace.path) }
            checks["completedOwnerIsPinnedWhileBackgroundRuns"] = tasks.task(recovery)?.events.last?.status == "running" && service.isRunning(recovery)
            let copy = output.appendingPathComponent("recovered-profile")
            try FileManager.default.createDirectory(at: copy.appendingPathComponent("agent"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: copy.appendingPathComponent("extensions"), withIntermediateDirectories: true)
            for (source, target) in [(tasks.directory.appendingPathComponent("index.json"), copy.appendingPathComponent("agent/index.json")), (tasks.directory.appendingPathComponent(recovery + ".json"), copy.appendingPathComponent("agent/" + recovery + ".json")), (service.profile.appendingPathComponent("extensions/hook-settings.json"), copy.appendingPathComponent("extensions/hook-settings.json"))] { try FileManager.default.copyItem(at: source, to: target) }
            let restored = AgentStore(directory: copy, legacy: [], extensionHome: shared)
            checks["actualPersistedBackgroundRecoversWithoutChangingForegroundResult"] = restored.task(recovery)?.status == .completed && restored.task(recovery)?.events.last?.hook?.delivery == "interrupted" && !restored.hooks.isRunning(recovery)
            _ = try await restored.hooks.fire(.notification, trigger: "persisted-background-trigger", store: restored, taskID: recovery, value: "recovery")
            checks["restoredTriggerIsNotReplayed"] = !restored.hooks.isRunning(recovery)
            service.cancel(recovery); _ = await idle(recovery)
            let forkOwner = owner("分支不接管后台任务"); tasks.update(forkOwner) { $0.status = .completed }
            _ = try await fire(forkOwner, "fork"); _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("fork.pid.json").path) }
            let branch = tasks.fork(forkOwner)
            checks["forkKeepsHistoryWithoutOwningBackgroundWork"] = branch.flatMap(tasks.task)?.events.last?.hook?.delivery == "fork-history" && branch.map { !service.isRunning($0) } == true && service.isRunning(forkOwner)
            service.cancel(forkOwner); _ = await idle(forkOwner)
            try enable(["实际 HTTP 文件核对", "实际 HTTP 取消"])
            let http = owner("实际异步 HTTP 核对"), httpBegan = Date()
            _ = try await fire(http, "HTTPAsync", fields: ["file_path": workspace.appendingPathComponent("source.json").path, "delay": 0.8])
            checks["httpReturnsBeforeActualValidationFinishes"] = Date().timeIntervalSince(httpBegan) < 0.6 && service.isRunning(http)
            _ = await idle(http)
            checks["actualHTTPHashResultQueued"] = tasks.task(http)?.hookContexts?.values.contains(where: { $0.contains(sourceHash) }) == true
            let httpCancel = owner("实际取消 HTTP 请求")
            _ = try await fire(httpCancel, "HTTPCancel", fields: ["file_path": workspace.appendingPathComponent("source.json").path, "delay": 3])
            _ = await until { ((try? String(contentsOf: output.appendingPathComponent("http-audit.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").count >= 2 }
            service.cancel(httpCancel); _ = await idle(httpCancel)
            checks["cancelledHTTPResultNotDelivered"] = tasks.task(httpCancel)?.hookContexts?.isEmpty != false && tasks.task(httpCancel)?.events.last?.status == "stopped"
            var restricted = AgentProfile(name: "后台范围检查", description: "仅用于真实范围验收", instructions: "只读核对公开文件")
            restricted.enabled = true; restricted.readOnly = false; restricted.network = true
            try tasks.agents.save(tasks.agents.encode([restricted]), expectedHash: nil)
            let parent = tasks.create(title: "所属只读问答", workspace: workspace.path, mode: .ask), child = try tasks.agents.createTask(restricted.id, store: tasks, workspace: workspace.path, owner: tasks.task(parent))
            _ = try await fire(child, "HTTPAsync", fields: ["file_path": workspace.appendingPathComponent("source.json").path]); _ = await idle(child)
            checks["ancestorReadOnlyCannotGainAsyncExternalAccess"] = tasks.task(child)?.events.last?.status == "failed" && tasks.task(child)?.hookContexts?.isEmpty != false
            let limit = owner("恢复的唤醒次数边界")
            tasks.update(limit) { $0.status = .completed; $0.hookRewakePromptID = $0.messages.last?.id; $0.hookRewakeCount = 3 }
            _ = try await fire(limit, "limit"); _ = await idle(limit)
            checks["persistedRewakeLimitPreventsAnotherModelRequest"] = tasks.task(limit)?.status == .stopped && tasks.task(limit)?.events.last?.hook?.delivery == "rewake-limit" && tasks.task(limit)?.modelReceipts?.isEmpty != false
            let changed = owner("保存配置停止旧后台任务")
            _ = try await fire(changed, "config"); _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("config.pid.json").path) }
            let original = try service.document(project: true, workspace: workspace.path)
            var config = (try JSONSerialization.jsonObject(with: Data(original.0.utf8))) as! [String: Any]; config["acceptanceRevision"] = 2
            try service.save(json(config), project: true, workspace: workspace.path, expectedHash: original.1); _ = await idle(changed)
            let configStopped = await processStopped(cases.appendingPathComponent("config.pid.json")), configTrusted = try service.trusted(definition("config"))
            checks["savedConfigCancelsOldProcessAndInvalidatesTrust"] = configStopped && !configTrusted
            try service.save(original.0, project: true, workspace: workspace.path, expectedHash: service.document(project: true, workspace: workspace.path).1)
            for item in try service.catalog(workspace: workspace.path) where service.enabled(item) { try service.setEnabled(item, false, workspace: workspace.path) }
            let tempFiles = (try? FileManager.default.subpathsOfDirectory(atPath: tasks.directory.path)) ?? []
            checks["completedInputsAndTranscriptsAreRemoved"] = !tempFiles.contains { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("hook-") && $0.hasSuffix(".json") || URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("hook-transcript-") }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("相关实际进程或范围检查未通过，不调用模型") }
            if CommandLine.arguments.contains("--live-agent") {
                let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var preferences = PreferencesStore(directory: production).preferences; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; preferences.persona = ""; store.preferences = preferences
                report["model"] = preferences.model; report["contextLimit"] = preferences.contextLimit; report["outputLimit"] = preferences.outputLimit
                try enable(["后台素材审计", "后台输入校验", "后台只读复核"])
                let live = tasks.create(title: "真实后台素材核对", workspace: workspace.path)
                tasks.update(live) { $0.permission = .review; $0.toolGroups = ["files"] }
                let request = "完成素材核对的两阶段报告。先 read_file source.json，使用其中 edition,width,height,outputSha256 生成 asset-report.json 草稿，草稿只含 edition,width,height,sha256 四字段，sha256 使用 outputSha256。read_file 回读后简短报告初稿状态并结束初始阶段，不等待后台，不自行计算图片字节数，不用终端。后台审计完成后会用原任务的补充资料唤醒你；届时 read_file audit.json，按已预先授权的后续阶段在 asset-report.json 加入实际 imageBytes，形成 edition,width,height,sha256,imageBytes 五字段最终报告，再 read_file 回读确认。不要改其他文件，不询问已提供参数。"
                guard runtime.submit(request, taskID: live) else { throw PetError(runtime.submissionError ?? "真实任务未开始") }
                var approved = Set<String>()
                func approve() throws {
                    guard let review = runtime.pendingReview(live), let call = review.pendingCalls.first, !approved.contains(call.id) else { return }
                    guard approved.count < 4, ["write_file", "edit_file"].contains(call.name), ["asset-report.json", workspace.appendingPathComponent("asset-report.json").path].contains(call.object["path"] as? String ?? "") else { throw PetError("只批准两阶段素材报告修改，额外动作未执行：" + call.name) }
                    approved.insert(call.id); runtime.decide(taskID: review.id, callID: call.id, decision: "allow")
                }
                func awaitForeground(_ final: Bool) async throws {
                    let deadline = Date().addingTimeInterval(150)
                    while Date() < deadline {
                        try approve()
                        guard let record = tasks.task(live) else { throw PetError("真实任务不可用") }
                        if record.events.filter({ $0.kind == "tool" && ["completed", "failed"].contains($0.status) }).count > 24 { runtime.cancel(live); throw PetError("真实流程超过 24 次工具调用上限") }
                        if !runtime.isExecuting(live), record.status == .completed, !final || !service.isRunning(live) { return }
                        if !runtime.isExecuting(live), [.failed, .stopped].contains(record.status) { throw PetError(record.events.last?.detail ?? "真实后台流程未完成") }
                        await wait(0.05)
                    }; runtime.cancel(live); throw PetError("真实后台素材流程超时")
                }
                phase("real-initial-report"); try await awaitForeground(false)
                let initial = object(workspace.appendingPathComponent("asset-report.json"))
                checks["realForegroundCompletesWhileAuditProcessWaits"] = initial.count == 4 && service.isRunning(live) && FileManager.default.fileExists(atPath: workspace.appendingPathComponent("audit-started.json").path) && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("audit.json").path)
                if CommandLine.arguments.contains("--hook-async-ui-hold") {
                    control.show(tab: "chat"); control.showAgentTask(live); phase("ui-background-live")
                    _ = await until({ FileManager.default.fileExists(atPath: output.appendingPathComponent("release-background-ui").path) }, seconds: 100)
                }
                try Data().write(to: workspace.appendingPathComponent("release-asset-audit")); phase("real-background-rewake")
                try await awaitForeground(true)
                let complete = tasks.task(live)!, actual = object(workspace.appendingPathComponent("asset-report.json")), audit = object(workspace.appendingPathComponent("audit.json")), source = object(workspace.appendingPathComponent("source.json")), image = try Data(contentsOf: workspace.appendingPathComponent("character.png"))
                checks["realRewakeCompletesExactFiveFieldReport"] = actual.count == 5 && actual["edition"] as? Int == source["edition"] as? Int && actual["width"] as? Int == source["width"] as? Int && actual["height"] as? Int == source["height"] as? Int && actual["sha256"] as? String == AgentFiles.hash(image) && actual["imageBytes"] as? Int == image.count && audit["imageBytes"] as? Int == image.count
                checks["realRewakePreservesBothMutationApprovals"] = approved.count == 2 && complete.approvals.filter { ["write_file", "edit_file"].contains($0.call.name) && $0.decision == "allow" }.count == 2
                checks["realExitTwoWakesOnlyOnce"] = complete.hookRewakeCount == 1 && complete.events.filter { $0.hook?.rewakeRequested == true && $0.hook?.delivery == "woke-task" }.count == 1
                checks["realModelReadsActualAuditAndFinalReport"] = complete.events.contains { $0.title == "read_file" && $0.detail.contains("audit.json") && $0.status == "completed" } && complete.events.filter { $0.title == "read_file" && $0.detail.contains("asset-report.json") && $0.status == "completed" }.count >= 2
                let evaluations = complete.events.compactMap { event -> AgentTaskRecord? in guard let id = event.hook?.childTaskID else { return nil }; return tasks.task(id) }
                checks["actualAsyncPromptAndAgentModelsReturnVerdicts"] = evaluations.count >= 3 && evaluations.allSatisfy { $0.status == .completed && $0.summary.hasPrefix("通过：") && ($0.modelReceipts?.isEmpty == false) }
                checks["actualAsyncAgentUsesReadOnlyFileTool"] = evaluations.contains { $0.hookTools?.contains("read_file") == true && $0.events.contains { $0.title == "read_file" && $0.status == "completed" } }
                checks["asyncAgentDoesNotReceiveParentConversation"] = evaluations.filter { $0.hookTools?.contains("read_file") == true }.allSatisfy { $0.messages.first?.content.contains("结束初始阶段") == false }
                try enable(["new-input"])
                _ = try await fire(live, "new-input", trigger: "new-input-after-foreground")
                _ = await until { FileManager.default.fileExists(atPath: cases.appendingPathComponent("new-input.pid.json").path) }
                guard runtime.submit("追加素材核对：read_file 读取 asset-report.json，只回答 imageBytes 数值和完整 sha256，不改文件，不用其他工具。", taskID: live) else { throw PetError("后台期间补充要求未接收") }
                checks["newInputStartsForegroundDespiteBackgroundWork"] = runtime.isExecuting(live) && tasks.task(live)?.queuedCount == 0
                try await awaitForeground(false)
                checks["realNewInputProducesActualReadback"] = tasks.task(live)?.summary.contains(String(image.count)) == true && tasks.task(live)?.summary.contains(AgentFiles.hash(image)) == true
                try service.setEnabled(definition("new-input"), false, workspace: workspace.path); _ = await idle(live)
                checks["disableStopsBackgroundWithoutChangingCompletedReply"] = (await processStopped(cases.appendingPathComponent("new-input.pid.json"))) && tasks.task(live)?.status == .completed
                report["liveTaskID"] = live; report["artifact"] = actual; report["approvals"] = approved.count; report["evaluationTaskIDs"] = evaluations.map(\.id)
                report["inputTokens"] = tasks.task(live)?.inputTokens; report["outputTokens"] = tasks.task(live)?.outputTokens
                tasks.selectedID = live
            }
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }
            report["scope"] = "Actual local command process groups, actual HTTP service computing input-file hashes, real persisted running records, original permissions, plus optional saved-model two-stage asset report, asynchronous prompt/agent evaluation and actual background rewake. No simulated model, MCP or website replies."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("async-hook-report.json"), options: .atomic)
            if CommandLine.arguments.contains("--hook-async-ui-hold") {
                if !CommandLine.arguments.contains("--live-agent") {
                    try enable(["ui"]); let id = owner("实际后台 Hook 窗口"); _ = try await fire(id, "ui"); tasks.selectedID = id
                }
                control.show(tab: "chat"); control.showAgentTask(tasks.selectedID!); phase("ui-ready")
                _ = await until({ FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) }, seconds: 1200)
            }
        } catch { report["checks"] = checks; report["success"] = false; report["error"] = error.localizedDescription; try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("async-hook-report.json"), options: .atomic) }
    }
}
