import AppKit

@MainActor extension AppDelegate {
    func runAgentProfileCheck(_ output: URL) async {
        if CommandLine.arguments.contains("--teams-only") { await runAgentTeamCheck(output); return }
        if CommandLine.arguments.contains("--scopes-only") { await runAgentProfileScopeCheck(output); return }
        if CommandLine.arguments.contains("--nested-only") { await runAgentNestedCheck(output); return }
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        var manager: AgentProfileWindow?
        func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: try json(args)) }
        func rejected(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        defer { agentRuntime?.stopAll(); manager?.close() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let workspace = output.appendingPathComponent("workspace")
            var audit = AgentProfile(name: "素材核对员", description: "读取实际角色素材与来源，返回实际尺寸、字节与 SHA256。", instructions: "职责标记 AGENT_RULE_PUBLIC_4831。只读 source.json 和 character.png。先用 read_file 读 source.json，再用 run_command 实际执行 wc -c < character.png 与 shasum -a 256 character.png，可合成一条命令。不写文件，不读其他内容。最后只返回 JSON 对象，字段 edition、width、height、imageBytes、sha256，数值来自实际读取或命令，不推测。")
            audit.permission = .automatic; audit.tools = ["list_directory", "read_file", "search_files", "run_command", "write_file"]; audit.enabled = true
            var writer = AgentProfile(name: "文件实施员", description: "按要求修改项目文件", instructions: "先读取实际文件，再按明确要求修改并核对。")
            writer.readOnly = false; writer.permission = .automatic; writer.tools = ["read_file", "write_file", "run_command"]; writer.enabled = true
            var slow = AgentProfile(name: "长说明核对员", description: "用于实际输出中的停止验收", instructions: "不用工具。用中文逐项解释素材核对的依据、来源、尺寸、字节、校验、未知项，分十二段详细叙述，说明没有工具证据时哪些信息不能确认。")
            slow.tools = []; slow.enabled = true
            try tasks.agents.save(tasks.agents.encode([audit, writer, slow]), expectedHash: nil)
            checks["profilesPersistAndReload"] = try tasks.agents.list().count == 3
            let before = try tasks.agents.document(), imported = try tasks.agents.decode(before.0, importing: true)
            checks["importsAreDisabledWithNewIdentities"] = imported.allSatisfy { !$0.enabled && ![audit.id, writer.id, slow.id].contains($0.id) }
            rejected("staleEditorSaveRejected") { try tasks.agents.save(before.0, expectedHash: "stale") }
            rejected("unknownConfigFieldsRejected") { _ = try tasks.agents.decode("{\"agents\":[],\"futurePermission\":true}") }
            let owner = tasks.create(title: "独立权限检查", workspace: workspace.path)
            tasks.update(owner) { $0.permission = .review }
            let readonly = try tasks.agents.createTask(audit.id, store: tasks, workspace: workspace.path, owner: tasks.task(owner))
            let native = AgentTools(store: tasks, taskID: readonly)
            do { _ = try await native.execute(call("write_file", ["path": "blocked-agent.md", "content": "禁止写入"])); checks["readonlyWriteToolRejected"] = false } catch { checks["readonlyWriteToolRejected"] = true }
            let shell = try await native.execute(call("run_command", ["command": "printf forbidden > readonly-shell-blocked.txt", "network": false]))
            checks["readonlyShellEnforcedByKernel"] = shell.failed && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("readonly-shell-blocked.txt").path)
            rejected("toolWhitelistCheckedAtExecutionBoundary") { _ = try native.approvalReason(for: call("fetch_url", ["url": "https://example.com"])) }
            rejected("networkCannotBeAddedByToolArguments") { _ = try native.approvalReason(for: call("run_command", ["command": "true", "network": true])) }
            tasks.update(readonly) { $0.permission = .automatic }
            checks["parentReviewCeilingCannotBeExpanded"] = try native.approvalReason(for: call("run_command", ["command": "true"])) != nil
            tasks.update(readonly) { $0.workspace = output.path }
            rejected("delegatedWorkspaceCannotBeChanged") { _ = try native.approvalReason(for: call("read_file", ["path": "source.json"])) }
            tasks.update(readonly) { $0.workspace = workspace.path; $0.status = .completed }
            tasks.update(owner) { $0.mode = .ask }
            let askChild = try tasks.agents.createTask(writer.id, store: tasks, workspace: workspace.path, owner: tasks.task(owner))
            rejected("askModeCannotDelegateProjectWrites") { _ = try AgentTools(store: tasks, taskID: askChild).approvalReason(for: call("write_file", ["path": "ask-blocked.md", "content": "禁止写入"])) }
            tasks.update(askChild) { $0.status = .completed }
            checks["scopedSchemaHidesWriteTools"] = !AgentProfiles.definitions(AgentTools.definitions(mode: .agent, groups: ["files", "terminal"]), task: tasks.task(readonly)!).contains { ($0["function"] as? [String: Any])?["name"] as? String == "write_file" }
            let configuration = try tasks.agents.document().0
            let restored = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["taskProfileSnapshotSurvivesReload"] = restored.task(readonly)?.agent?.profile.instructions == audit.instructions
            checks["indexDoesNotDuplicateLongInstructions"] = !(try String(contentsOf: tasks.directory.appendingPathComponent("index.json"), encoding: .utf8)).contains("AGENT_RULE_PUBLIC_4831")
            let archivedChild = try tasks.agents.createTask(audit.id, store: tasks, workspace: workspace.path, owner: tasks.task(owner))
            tasks.update(archivedChild) { $0.status = .waiting }
            tasks.update(archivedChild) { $0.archived = true }
            checks["archivingWaitingChildEndsItsLifecycle"] = tasks.task(archivedChild)?.status == .stopped && tasks.task(archivedChild)?.archived == true
            if CommandLine.arguments.contains("--live-agent") {
                let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: production).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.persona = ""
                store.preferences = p
                report["model"] = p.model; report["contextLimit"] = p.contextLimit; report["outputLimit"] = p.outputLimit
                phase("real-model-delegation")
                let parent = tasks.create(title: "真实模型委派素材核对", workspace: workspace.path)
                tasks.update(parent) {
                    $0.permission = .review
                    $0.messages.append(AgentMessage(role: "user", content: "主任务历史隔离标记 PARENT_ONLY_PUBLIC_9182，不转发到子任务。", nativeContext: true))
                }
                let request = "使用已启用的自定义 Agent“素材核对员”完成素材核对：先 load_tools 的 agents 组，list_agents 找到它，再 delegate_task。只给子任务传明确的素材核对要求，不转发先前标记。子任务必须实际读取 source.json 和用终端核对 character.png 的字节与 SHA256，返回 edition、width、height、imageBytes、sha256。拿到真实最终结果后，主任务用 write_file 写 delegated-report.json，只保留这五个字段并回读确认。项目目录：\(workspace.path)。不修改两份输入，不使用网页或外部工具，不询问用户已有的参数。"
                guard runtime.submit(request, taskID: parent) else { throw PetError(runtime.submissionError ?? "真实主任务未开始") }
                var approved = Set<String>(), childApprovalSeenInParent = false
                let deadline = Date().addingTimeInterval(240)
                while Date() < deadline {
                    guard let current = tasks.task(parent) else { throw PetError("主任务记录不可用") }
                    if [.completed, .failed, .stopped].contains(current.status) && !runtime.isRunning(parent) { break }
                    if let review = runtime.pendingReview(parent), let pending = review.pendingCalls.first, !approved.contains(pending.id) {
                        guard pending.name == "run_command" || pending.name == "write_file" else { throw PetError("验收出现未授权动作：" + pending.name) }
                        if pending.name == "write_file", pending.object["path"] as? String != "delegated-report.json", pending.object["path"] as? String != workspace.appendingPathComponent("delegated-report.json").path { throw PetError("验收不批准额外文件写入") }
                        guard pending.object["network"] as? Bool != true else { throw PetError("验收不允许联网命令") }
                        if review.id != parent { childApprovalSeenInParent = true }
                        approved.insert(pending.id); runtime.decide(taskID: review.id, callID: pending.id, decision: "allow")
                    }
                    await wait(0.08)
                }
                guard !runtime.isRunning(parent), let complete = tasks.task(parent), complete.status == .completed,
                      let childMeta = tasks.tasks.first(where: { $0.agent?.ownerID == parent }), let child = tasks.task(childMeta.id) else { runtime.cancel(parent); throw PetError("真实委派未完成：" + (tasks.task(parent)?.events.last?.detail ?? "超时")) }
                let data = try Data(contentsOf: workspace.appendingPathComponent("delegated-report.json")), actual = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let source = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("source.json"))) as? [String: Any] ?? [:], image = try Data(contentsOf: workspace.appendingPathComponent("character.png"))
                checks["realParentCompletesAfterDelegateResult"] = complete.events.contains { $0.title == "delegate_task" && $0.status == "completed" && $0.childTaskID == child.id }
                checks["realChildCompletesWithIndependentUsage"] = child.status == .completed && child.inputTokens > 0 && child.outputTokens > 0 && complete.inputTokens > 0
                checks["actualChildReadAndCommandRecorded"] = child.events.contains { $0.title == "read_file" && $0.status == "completed" } && child.events.contains { $0.title == "run_command" && $0.status == "completed" }
                checks["childApprovalExposedInParent"] = childApprovalSeenInParent
                checks["childDidNotReceiveParentHistory"] = !child.messages.contains { $0.content.contains("PARENT_ONLY_PUBLIC_9182") }
                checks["childUsesItsOwnInstructions"] = try runtime.systemContext(child).contains("AGENT_RULE_PUBLIC_4831")
                checks["actualReportMatchesSourceAndImage"] = ["edition", "width", "height"].allSatisfy { (actual[$0] as? Int) == (source[$0] as? Int) } && actual["sha256"] as? String == AgentFiles.hash(image) && actual["imageBytes"] as? Int == image.count
                checks["parentReadBackActualReport"] = complete.events.contains { $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("delegated-report.json") }
                report["live"] = ["parentID": parent, "childID": child.id, "parentStatus": complete.status.rawValue, "childStatus": child.status.rawValue, "childModel": child.model, "childInputTokens": child.inputTokens, "childOutputTokens": child.outputTokens, "approvals": approved.count, "report": actual]
                phase("real-delegation-cancellation")
                let cancelParent = tasks.create(title: "实际输出中停止委派", workspace: workspace.path)
                var sawChildOutput = false, cancelledChild: String?
                let priorChange = runtime.onChange
                runtime.onChange = { id in
                    priorChange?(id)
                    guard !sawChildOutput, let child = tasks.task(id), child.agent?.ownerID == cancelParent,
                          child.messages.last?.role == "assistant", child.messages.last?.content.isEmpty == false else { return }
                    sawChildOutput = true; cancelledChild = id; runtime.cancel(cancelParent)
                }
                tasks.update(cancelParent) { $0.permission = .automatic; $0.toolGroups = ["agents"] }
                guard runtime.submit("调用 list_agents 找到长说明核对员，然后 delegate_task 请它详细解释素材核对规则；等待实际结果。", taskID: cancelParent) else { throw PetError("取消验收未开始") }
                let cancelDeadline = Date().addingTimeInterval(90)
                while Date() < cancelDeadline, runtime.isRunning(cancelParent) { await wait(0.08) }
                runtime.onChange = priorChange
                checks["actualChildStreamingObservedBeforeCancel"] = sawChildOutput
                checks["parentCancelStopsOwnedChild"] = tasks.task(cancelParent)?.status == .stopped && cancelledChild.flatMap { tasks.task($0) }?.status == .stopped
                checks["cancelLeavesNoActiveParentOrChild"] = !runtime.isRunning(cancelParent) && cancelledChild.map { !runtime.isRunning($0) } == true
                phase("real-agent-disable")
                let disableTask = try tasks.agents.createTask(slow.id, store: tasks, workspace: workspace.path)
                var disabledDuringOutput = false
                runtime.onChange = { id in
                    priorChange?(id)
                    guard !disabledDuringOutput, id == disableTask, tasks.task(id)?.messages.last?.role == "assistant", tasks.task(id)?.messages.last?.content.isEmpty == false else { return }
                    disabledDuringOutput = true; try? tasks.agents.setEnabled(slow.id, false)
                }
                guard runtime.submit("详细解释素材核对的规则与限制。", taskID: disableTask) else { throw PetError("停用验收未开始") }
                let disableDeadline = Date().addingTimeInterval(60)
                while Date() < disableDeadline, runtime.isRunning(disableTask) { await wait(0.08) }
                runtime.onChange = priorChange
                checks["disableCancelsActualStreamingTask"] = disabledDuringOutput && tasks.task(disableTask)?.status == .stopped && !runtime.isRunning(disableTask)
                rejected("disabledAgentCannotStartNewTask") { _ = try tasks.agents.createTask(slow.id, store: tasks, workspace: workspace.path) }
                report["cancelledChildID"] = cancelledChild
                tasks.selectedID = parent
            }
            checks["blockedFilesNotCreated"] = !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("blocked-agent.md").path) && !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ask-blocked.md").path)
            report["configurationBeforeLive"] = try JSONSerialization.jsonObject(with: Data(configuration.utf8))
            report["scope"] = CommandLine.arguments.contains("--live-agent") ? "Actual saved model performs parent delegation, independent child reads and terminal verification, parent artifact write/readback, native approval routing, real streaming cancellation and disable. No simulated model responses. Independent profile and public repository assets." : "Native profile persistence, scoped tools, readonly kernel, parent ceilings and recovery. No model calls."
            report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("custom-agent-report.json"), options: .atomic)
            if CommandLine.arguments.contains("--custom-agent-ui-hold") {
                control.show(tab: "chat"); manager = AgentProfileWindow(store: tasks, workspace: workspace.path); manager?.showWindow(nil); manager?.window?.makeKeyAndOrderFront(nil)
                phase("ui-ready")
                let limit = Date().addingTimeInterval(600)
                while Date() < limit, !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
        } catch {
            report["error"] = error.localizedDescription; report["checks"] = checks; report["success"] = false
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("custom-agent-report.json"), options: .atomic)
        }
        phase("finished")
    }
}

@MainActor extension AppDelegate {
    private func runAgentNestedCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:]
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let workspace = output.appendingPathComponent("workspace")
            let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var p = PreferencesStore(directory: production).preferences
            p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.persona = ""; store.preferences = p
            var leaf = AgentProfile(name: "只读复核员", description: "实际读取项目数据并返回三字段 JSON", instructions: "实际用 read_file 读取 source.json，随后 run_command 执行 sleep 2 && shasum -a 256 source.json，network=false。最终只返回 JSON，字段 edition、width、height 来自实际文件。不修改文件，不联网，不委派。")
            leaf.tools = ["read_file", "run_command"]; leaf.permission = .automatic; leaf.enabled = true
            var coordinator = AgentProfile(name: "复核协调员", description: "把只读素材核对交给复核员", instructions: "必须 delegate_task 给 agent_id=\(leaf.id)，prompt 必须明确写出：实际读取 source.json 并按职责核对，最终 JSON 必须只含 edition、width、height 三个整数键，三个值来自文件；不能把字段名替换成结论、问题或建议。等待真实结果，最终只转述这三个实际数值。不自己读取文件，不再创建其他委派。")
            coordinator.tools = ["list_agents", "delegate_task", "read_file", "run_command"]; coordinator.permission = .automatic; coordinator.enabled = true
            try tasks.agents.save(tasks.agents.encode([leaf, coordinator]), expectedHash: nil)
            let roots = (1...2).map { tasks.create(title: "并行复核 \($0)", workspace: workspace.path) }
            var overlappingWaits = false
            let priorChange = runtime.onChange
            runtime.onChange = { id in
                priorChange?(id)
                let waiting = tasks.tasks.filter { record in record.agent?.profile.id == coordinator.id && tasks.task(record.id)?.events.contains { $0.title == "delegate_task" && $0.status == "running" && $0.childTaskID != nil } == true }
                if waiting.count == 2 { overlappingWaits = true }
            }
            defer { runtime.onChange = priorChange; runtime.stopAll() }
            for root in roots {
                tasks.update(root) { $0.permission = .automatic; $0.toolGroups = ["agents"] }
                guard runtime.submit("只调用一次 delegate_task，agent_id=\(coordinator.id)，prompt=按职责委派只读素材复核，明确要求复核员 JSON 只含 edition、width、height 三个整数键及文件中的实际值。等待真实结果，最终只返回这三个键，不做其他操作。", taskID: root) else { throw PetError("并行委派未开始") }
            }
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline, roots.contains(where: runtime.isRunning) { await wait(0.1) }
            let coordinators = tasks.tasks.filter { $0.agent?.profile.id == coordinator.id }, leaves = tasks.tasks.filter { $0.agent?.profile.id == leaf.id }
            checks["bothRootsComplete"] = roots.allSatisfy { tasks.task($0)?.status == .completed }
            checks["bothCoordinatorsComplete"] = coordinators.count == 2 && coordinators.allSatisfy { $0.status == .completed }
            checks["bothLeavesComplete"] = leaves.count == 2 && leaves.allSatisfy { $0.status == .completed }
            checks["coordinatorWaitsActuallyOverlapped"] = overlappingWaits
            checks["eachLeafReadActualFileAndCommand"] = leaves.count == 2 && leaves.allSatisfy { meta in
                guard let task = tasks.task(meta.id) else { return false }
                return ["read_file", "run_command"].allSatisfy { name in task.events.contains { $0.title == name && $0.status == "completed" } }
            }
            checks["descendantScopesRemainReadOnlyAndOffline"] = coordinators.count == 2 && leaves.count == 2 && (coordinators + leaves).allSatisfy { $0.agent?.readOnly == true && $0.agent?.network == false && $0.workspace == workspace.path }
            checks["noRunningTaskRemains"] = !runtime.isWorking
            report["rootIDs"] = roots; report["coordinatorIDs"] = coordinators.map(\.id); report["leafIDs"] = leaves.map(\.id)
            report["model"] = p.model; report["contextLimit"] = p.contextLimit; report["outputLimit"] = p.outputLimit
            report["scope"] = "Two actual saved-model root tasks each delegate a coordinator, which delegates an actual readonly file audit. No simulated replies. Overlapping coordinator waits must finish without child-slot deadlock. Independent Node verifies each leaf result against the file."
        } catch { report["error"] = error.localizedDescription; agentRuntime?.stopAll() }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("custom-agent-report.json"), options: .atomic)
    }
}
