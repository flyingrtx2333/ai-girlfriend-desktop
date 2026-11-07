import AppKit

@MainActor extension AppDelegate {
    func runAgentContextCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("上下文验收需要真实模型，请加 --live-agent") }
            let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var p = PreferencesStore(directory: profile).preferences
            p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false
            p.contextTokens = 12_288; p.replyTokens = 1536; p.reasoningEffort = "auto"; store.preferences = p
            let workspace = output.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let csv = Data("item,quantity,unit_price\ntea,2,12.50\ncake,3,8.00\n".utf8); try csv.write(to: workspace.appendingPathComponent("sales.csv"))
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let id = tasks.create(title: "长任务 · 历史更正", workspace: workspace.path, mode: .goal)
            let original = "任务：读取 sales.csv，按数量乘单价统计销售额，最终只写 retained.md。标题必须是『鲸鱼长记忆』。报告必须含口令『珊瑚-7319』；保持 sales.csv 完全不变。"
            var fixture = [AgentMessage(role: "user", content: original)]
            let background = String(repeating: "潮涨潮落，海风掠过灯塔。这是公开的背景材料，不代表新的执行要求。", count: 28)
            for i in 0..<6 {
                fixture.append(AgentMessage(role: "user", content: "公开历史背景 \(i + 1)：" + background, nativeContext: true))
                if i == 1 { fixture.append(AgentMessage(role: "user", content: "更正前面的约束：口令『珊瑚-7319』已作废，最终口令必须改为『潮汐-4086』，报告不得出现作废口令。其他要求不变，只写 retained.md。")) }
            }
            // This protocol fixture uses an actual native read, not a model
            // response presented as real historical AI work.
            let seed = AgentToolCall(id: UUID().uuidString, name: "read_file", arguments: "{\"path\":\"sales.csv\"}")
            let read = try await AgentTools(store: tasks, taskID: id).execute(seed)
            fixture.append(AgentMessage(role: "assistant", content: "[受控历史记录：本地文件读取]", toolCalls: [seed]))
            fixture.append(AgentMessage(role: "tool", content: read.text, toolCallID: seed.id))
            let originalIDs = fixture.map(\.id)
            tasks.update(id) { $0.messages = fixture; $0.permission = .automatic }
            control.show(tab: "chat")
            runtime.submit("按之前的最终约束完成销售汇总，读取 sales.csv 并只写 retained.md。不要执行命令或联网；完成前重新读取报告核对。先列计划，完成后引用实际证据。", taskID: id)
            let deadline = Date().addingTimeInterval(160)
            while Date() < deadline, let task = tasks.task(id), runtime.isRunning(id) {
                if task.status == .waiting { throw PetError("完整资料已提供，任务仍在请求额外信息") }
                await wait(0.1)
            }
            guard let task = tasks.task(id) else { throw PetError("任务记录丢失") }
            if runtime.isRunning(id) { runtime.cancel(id) }
            let files = try AgentFiles(workspace: workspace.path), result = try files.readData(files.resolve("retained.md")), text = String(decoding: result, as: UTF8.self)
            checks["actualModelCompletesLongTask"] = task.status == .completed && task.goalAccepted == true
            checks["realSummaryCreated"] = task.events.contains { $0.kind == "context" && $0.status == "completed" } && task.contextThroughID != nil
            checks["latestHistoricalCorrectionSurvives"] = text.contains("潮汐-4086") && !text.contains("珊瑚-7319") && (task.contextSummary ?? "").contains("潮汐-4086")
            checks["originalGoalAndActualTotalSurvive"] = text.contains("鲸鱼长记忆") && text.contains("49")
            checks["sourceFileUnchanged"] = try files.readData(files.resolve("sales.csv")) == csv
            checks["allOriginalRecordsRetained"] = Array(task.messages.prefix(originalIDs.count)).map(\.id) == originalIDs && task.messages.first?.content == original
            checks["onlyRequestedOutputWritten"] = task.artifacts == [workspace.appendingPathComponent("retained.md").path] && !task.events.contains { ["run_command", "web_search", "fetch_url"].contains($0.title) }
            let history = try await AgentTools(store: tasks, taskID: id).execute(AgentToolCall(id: UUID().uuidString, name: "read_task_history", arguments: "{\"offset\":0,\"limit\":1}"))
            checks["originalHistoryRemainsReadable"] = history.text.contains(original)
            let wire = AgentContext.window(task); var pending = Set<String>(), paired = true
            checks["compactedUserRequirementsStayVerbatim"] = wire.filter(\.isHumanInput).map(\.id) == task.messages.filter(\.isHumanInput).map(\.id)
            for message in wire {
                if let calls = message.toolCalls { if !pending.isEmpty { paired = false }; pending = Set(calls.map(\.id)) }
                else if message.role == "tool" { if let id = message.toolCallID, pending.remove(id) != nil {} else { paired = false } }
                else if !pending.isEmpty { paired = false }
            }
            checks["compactedToolMessagesStayPaired"] = paired && pending.isEmpty
            let reloaded = AgentStore(directory: store.directory, legacy: [])
            checks["summaryAndFullHistoryPersist"] = reloaded.task(id)?.contextThroughID == task.contextThroughID && reloaded.task(id)?.messages.count == task.messages.count
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
            let rendered = NativeMarkdown.render("**总计**：`49.00`\n[来源](https://example.com)\n```sh\necho 49\n```", font: .systemFont(ofSize: 15), color: .labelColor, paragraph: paragraph)
            checks["nativeMarkdownRendersTextAndLinks"] = rendered.string.contains("总计：49.00") && !rendered.string.contains("**") && !rendered.string.contains("```") && rendered.string.contains("echo 49")
            let sourceRange = (rendered.string as NSString).range(of: "来源")
            checks["nativeMarkdownPreservesClickableURL"] = sourceRange.location != NSNotFound && (rendered.attribute(.link, at: sourceRange.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com"
            let memoryID = tasks.create(title: "保存昵称", workspace: workspace.path, mode: .ask)
            runtime.submit("请把我的昵称『星浪』保存到全局记忆，只保存这条昵称信息。", taskID: memoryID)
            let rememberDeadline = Date().addingTimeInterval(90); var approved = false, blockedUntilApproval = false
            while Date() < rememberDeadline, let memoryTask = tasks.task(memoryID), [.ready, .running, .waiting].contains(memoryTask.status) {
                if memoryTask.status == .waiting, let call = memoryTask.pendingCalls.first {
                    guard call.name == "write_memory", call.object["scope"] as? String == "global", (call.object["content"] as? String ?? "").contains("星浪") else { throw PetError("记忆任务提出了预期外动作") }
                    blockedUntilApproval = !(try AgentMemory.snapshot(.global, store: tasks, taskID: memoryID)).content.contains("星浪")
                    approved = true; runtime.decide(taskID: memoryID, callID: call.id, decision: "allow")
                }
                await wait(0.1)
            }
            let remembered = try AgentMemory.snapshot(.global, store: tasks, taskID: memoryID)
            checks["realModelWritesMemoryAfterApproval"] = approved && blockedUntilApproval && remembered.content.contains("星浪") && tasks.task(memoryID)?.status == .completed
            let project = try AgentMemory.snapshot(.project, store: tasks, taskID: id)
            _ = try AgentMemory.save(.project, content: "本项目的主色是海蓝色。", expectedHash: project.hash, store: tasks, taskID: id)
            do { _ = try AgentMemory.save(.project, content: "错误覆盖", expectedHash: project.hash, store: tasks, taskID: id); checks["memoryEditConflictProtected"] = false }
            catch { checks["memoryEditConflictProtected"] = (try AgentMemory.snapshot(.project, store: tasks, taskID: id)).content.contains("海蓝色") }
            let rules = try AgentMemory.snapshot(.instructions, store: tasks, taskID: id)
            _ = try AgentMemory.save(.instructions, content: "回答本项目问题时必须带上项目标识『灯塔-22』。", expectedHash: rules.hash, store: tasks, taskID: id)
            let recallID = tasks.create(title: "新任务验证记忆", workspace: workspace.path, mode: .ask)
            runtime.submit("我的昵称和这个项目的主色分别是什么？用一句话回答。", taskID: recallID)
            let recallDeadline = Date().addingTimeInterval(60)
            while Date() < recallDeadline && runtime.isRunning(recallID) { await wait(0.1) }
            let recall = tasks.task(recallID)?.summary ?? ""
            checks["actualNewTaskUsesGlobalProjectMemoryAndRules"] = tasks.task(recallID)?.status == .completed && recall.contains("星浪") && recall.contains("海蓝色") && recall.contains("灯塔-22")
            let steerID = tasks.create(title: "执行前更正", workspace: workspace.path, mode: .agent)
            tasks.update(steerID) { $0.permission = .automatic }
            let previousOnChange = runtime.onChange; var injected = false, answered = false
            runtime.onChange = { [weak runtime] changed in
                previousOnChange?(changed)
                guard changed == steerID, !injected, let call = tasks.task(steerID)?.pendingCalls.first,
                      call.name == "write_file", (call.object["path"] as? String ?? "").hasSuffix("discard.md") else { return }
                injected = true; runtime?.submit("更正：不要创建 discard.md；只用 write_file 创建 kept.md，内容严格为 B，不加其他内容。", taskID: steerID)
            }
            runtime.submit("先用 ask_user 问我要文件名和内容，收到答复后用 write_file 创建文件。", taskID: steerID)
            let steerDeadline = Date().addingTimeInterval(100)
            while Date() < steerDeadline, let steering = tasks.task(steerID), [.ready, .running, .waiting].contains(steering.status) {
                if steering.status == .waiting, let call = steering.pendingCalls.first {
                    guard call.name == "ask_user", !answered else { runtime.onChange = previousOnChange; throw PetError("更正任务重复请求信息") }
                    answered = true; runtime.decide(taskID: steerID, callID: call.id, decision: "answer:文件名 discard.md，内容 A。")
                }
                await wait(0.1)
            }
            runtime.onChange = previousOnChange
            let kept = (try? files.readData(files.resolve("kept.md"))).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            checks["actualSteeringSkipsSupersededWrite"] = injected && tasks.task(steerID)?.status == .completed && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("discard.md").path) && kept == "B"
            checks["userAnswerVisibleAndToolPairsValid"] = answered && tasks.task(steerID)?.messages.contains { $0.role == "user" && $0.content == "文件名 discard.md，内容 A。" } == true
            let stopID = tasks.create(title: "文字停止", workspace: workspace.path)
            runtime.start(stopID); runtime.submit("停止任务", taskID: stopID)
            checks["typedStopCancelsBeforeModelStarts"] = tasks.task(stopID)?.status == .stopped && !runtime.isRunning(stopID)
            let interruptedID = tasks.create(title: "中断恢复", workspace: workspace.path)
            let interruptedCall = AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: "{\"path\":\"replay.txt\",\"content\":\"should not run\"}")
            tasks.update(interruptedID) {
                $0.status = .running; $0.messages = [AgentMessage(role: "user", content: "受控恢复检查"), AgentMessage(role: "assistant", content: "", toolCalls: [interruptedCall])]
                $0.pendingCalls = [interruptedCall]; $0.approvals = [AgentApproval(call: interruptedCall, reason: "受控测试", workspace: workspace.path, decision: "allow")]
            }
            let recovered = AgentStore(directory: store.directory, legacy: []).task(interruptedID)
            checks["recoveryDoesNotReplayUnknownAction"] = recovered?.status == .stopped && recovered?.pendingCalls.isEmpty == true && recovered?.messages.last?.toolCallID == interruptedCall.id && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("replay.txt").path)
            if let recovered { tasks.update(interruptedID) { $0 = recovered } }
            tasks.selectedID = id; control.renderMessages()
            checks.merge(await control.checkAgentLayout(output)) { _, latest in latest }
            report["live"] = ["model": p.model, "status": task.status.rawValue, "compactions": task.events.filter { $0.kind == "context" && $0.status == "completed" }.count, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "contextEstimate": task.contextSize ?? 0, "result": text, "summary": task.contextSummary ?? "", "newTaskRecall": recall]
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["scope"] = "Controlled public historical text and one actual native-read protocol fixture. Summarization and final file task use the configured real model. Actual output, source integrity, later correction, original history and native rendering checked. Independent profile; no production writes, microphone or TTS."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("context-report.json")) }
    }
}
