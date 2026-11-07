import AppKit

@MainActor extension AppDelegate {
    func runAgentTeamCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        var manager: AgentTeamWindow?
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        func call(_ name: String, _ value: [String: Any] = [:]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: try json(value)) }
        func denied(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        defer { agentRuntime?.stopAll(); manager?.close(); phase("finished") }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统未初始化") }
            let workspace = output.appendingPathComponent("workspace")
            var reader = AgentProfile(name: "来源核对员", description: "读取 source.json 核对素材版本与尺寸", instructions: "独立职责标记 SOURCE_ROLE_7291。只用 read_file 读取 source.json，返回 JSON 对象 edition、width、height，值必须来自实际文件。不读 character.png、不执行命令、不写文件。")
            reader.tools = ["read_file"]; reader.permission = .automatic
            var verifier = AgentProfile(name: "文件校验员", description: "用真实终端核对 character.png 的字节与 SHA256", instructions: "独立职责标记 HASH_ROLE_8253。只用 run_command 执行 wc -c < character.png && shasum -a 256 character.png，依据实际输出返回 JSON 对象 imageBytes、sha256。不读 source.json、不写文件。")
            verifier.tools = ["run_command"]; verifier.permission = .automatic
            var lead = AgentProfile(name: "素材负责人", description: "让两名成员分别读取来源和核对实际图片，再汇总真实结果", instructions: "你是团队负责人。先 list_agents，分别 delegate_task 给来源核对员和文件校验员，明确两者各自的分工，不向成员传递主任务的历史标记。必须等待两名成员真实完成。合并实际结果为五字段 JSON：edition、width、height、imageBytes、sha256。write_file 写 team-report.json，再 read_file 回读，最后简短报告。不自行读取两份输入或执行命令，不代替成员的职责，不修改输入。")
            lead.tools = ["list_agents", "delegate_task", "read_file", "write_file", "run_command"]; lead.readOnly = false; lead.permission = .automatic
            var outsider = AgentProfile(name: "团队外角色", description: "不属于本次团队", instructions: "只核对明确要求。")
            outsider.enabled = true
            try tasks.agents.save(tasks.agents.encode([lead, reader, verifier, outsider]), expectedHash: nil)
            let templateText = try tasks.agents.encode(AgentTemplates.profiles)
            checks["templatesValidateAndStartDisabled"] = try tasks.agents.decode(templateText).count == 4 && AgentTemplates.profiles.allSatisfy { !$0.enabled && ($0.skills ?? []).isEmpty && ($0.mcpServers ?? []).isEmpty }
            var team = AgentTeam(name: "素材核对团队", description: "分工核对公开素材", instructions: "负责人把来源读取交给来源核对员，把图片字节与 SHA256 核对交给文件校验员。等待两名成员实际完成后合并，报告必须与真实输入一致。", leaderID: lead.id, memberIDs: [reader.id, verifier.id])
            let disabledText = try tasks.teams.encode([team]); try tasks.teams.save(disabledText, expectedHash: nil, store: tasks)
            checks["disabledTeamDoesNotEnableRoles"] = try tasks.agents.list().filter { $0.id != outsider.id }.allSatisfy { !$0.enabled }
            team.enabled = true; try tasks.teams.save(tasks.teams.encode([team]), expectedHash: tasks.teams.document().1, store: tasks)
            checks["enablingTeamEnablesLeaderAndMembers"] = try [lead.id, reader.id, verifier.id].allSatisfy { try tasks.agents.profile($0).enabled }
            denied("staleTeamSaveRejected") { try tasks.teams.save(disabledText, expectedHash: "stale", store: tasks) }
            var bad = team; bad.memberIDs = [lead.id]
            denied("leaderCannotAlsoBeMember") { _ = try tasks.teams.decode(tasks.teams.encode([bad])) }
            bad.memberIDs = [reader.id, reader.id]
            denied("duplicateMembersRejected") { _ = try tasks.teams.decode(tasks.teams.encode([bad])) }
            bad.memberIDs = []
            denied("emptyTeamRejected") { _ = try tasks.teams.decode(tasks.teams.encode([bad])) }
            denied("unknownTeamFieldsRejected") { _ = try tasks.teams.decode("{\"teams\":[],\"future\":true}") }
            let id = try tasks.teams.createTask(team.id, store: tasks, workspace: workspace.path)
            let tools = AgentTools(store: tasks, taskID: id)
            let listed = try await tools.execute(call("list_agents"))
            checks["teamCatalogOnlyListsConfiguredMembers"] = listed.text.contains(reader.id) && listed.text.contains(verifier.id) && !listed.text.contains(outsider.id) && !listed.text.contains(lead.id)
            denied("teamCannotDelegateOutsideRoster") { _ = try tasks.agents.createTask(outsider.id, store: tasks, workspace: workspace.path, owner: tasks.task(id)) }
            denied("teamCannotDelegateToAnotherTeam") { _ = try tasks.teams.createTask(team.id, store: tasks, workspace: workspace.path, owner: tasks.task(id)) }
            tasks.update(id) { $0.permission = .review }
            let child = try tasks.agents.createTask(verifier.id, store: tasks, workspace: workspace.path, owner: tasks.task(id))
            checks["teamMemberRetainsParentReviewCeiling"] = try AgentTools(store: tasks, taskID: child).approvalReason(for: call("run_command", ["command": "wc -c < character.png"])) != nil
            checks["teamMemberKeepsOwnRoleContext"] = try runtime.systemContext(tasks.task(child)!).contains("HASH_ROLE_8253") && !runtime.systemContext(tasks.task(child)!).contains("SOURCE_ROLE_7291")
            try tasks.agents.setEnabled(reader.id, false)
            denied("unavailableMemberBlocksTeamResume") { _ = try tools.approvalReason(for: call("read_file", ["path": "team-report.json"])) }
            try tasks.teams.save(tasks.teams.encode([team]), expectedHash: tasks.teams.document().1, store: tasks, activating: team.id)
            team.enabled = false; try tasks.teams.save(tasks.teams.encode([team]), expectedHash: tasks.teams.document().1, store: tasks)
            checks["disablingTeamPreservesEnabledRoles"] = try [lead.id, reader.id, verifier.id].allSatisfy { try tasks.agents.profile($0).enabled }
            denied("disabledTeamCannotRunExistingTools") { _ = try tools.approvalReason(for: call("read_file", ["path": "source.json"])) }
            team.enabled = true; try tasks.teams.save(tasks.teams.encode([team]), expectedHash: tasks.teams.document().1, store: tasks)
            let draft = tasks.create(workspace: workspace.path)
            let attachment = try await AgentAttachments.importFile(workspace.appendingPathComponent("source.json"), store: tasks, taskID: draft)
            tasks.update(draft) { $0.draft = "保留草稿和附件 · 三方核对" }
            checks.merge(control.checkExecutorSelection(taskID: draft, agentID: reader.id, teamID: team.id)) { _, new in new }
            checks["selectedDraftAttachmentStillReadable"] = try AgentFiles.hash(Data(contentsOf: AgentAttachments.source(store: tasks, taskID: draft, id: attachment.id))) == attachment.sha256
            tasks.update(draft) { $0.messages.append(AgentMessage(role: "user", content: "已有实际输入")) }
            denied("executorCannotChangeAfterFirstMessage") { try tasks.agents.configureDraft(reader.id, taskID: draft, store: tasks) }
            let (agentDoc, _) = try tasks.agents.document()
            report["configuration"] = try JSONSerialization.jsonObject(with: Data(agentDoc.utf8)); report["teamConfiguration"] = try JSONSerialization.jsonObject(with: Data(tasks.teams.document().0.utf8))
            if CommandLine.arguments.contains("--live-agent") {
                let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: production).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.persona = ""; store.preferences = p
                report["model"] = p.model; report["contextLimit"] = p.contextLimit; report["outputLimit"] = p.outputLimit
                let parent = tasks.create(title: "真实团队委派", workspace: workspace.path)
                tasks.update(parent) { $0.permission = .review; $0.toolGroups = ["agents"]; $0.messages.append(AgentMessage(role: "user", content: "主任务私有上下文隔离标记 TEAM_PARENT_ONLY_6392，不转发到团队。", nativeContext: true)) }
                phase("real-team-delegation")
                guard runtime.submit("用 list_agents 找到素材核对团队，然后通过 delegate_task 的 team_id 将完整核对交给该团队。要求其负责人让两位成员分别核对 source.json 的 edition/width/height 与 character.png 的实际字节/SHA256，等待成员完成后合并为 team-report.json（仅 edition、width、height、imageBytes、sha256 五字段）并回读。不要转发先前历史标记，不自行代替团队做工具核对；拿到团队真实最终结果后简短交付。输入不可改动，项目目录：\(workspace.path)。", taskID: parent) else { throw PetError(runtime.submissionError ?? "真实团队未开始") }
                var approved = Set<String>(), memberApprovalSeen = false
                let deadline = Date().addingTimeInterval(300)
                while Date() < deadline {
                    if let value = tasks.task(parent), [.completed, .failed, .stopped].contains(value.status), !runtime.isRunning(parent) { break }
                    if let review = runtime.pendingReview(parent), let pending = review.pendingCalls.first, !approved.contains(pending.id) {
                        guard approved.count < 10, ["run_command", "write_file"].contains(pending.name), pending.object["network"] as? Bool != true else { throw PetError("团队验收出现未授权动作：" + pending.name) }
                        if pending.name == "write_file", !["team-report.json", workspace.appendingPathComponent("team-report.json").path].contains(pending.object["path"] as? String ?? "") { throw PetError("只允许写团队报告") }
                        if pending.name == "run_command" {
                            let suffixes = ["wc -c < character.png && shasum -a 256 character.png", "wc -c character.png && shasum -a 256 character.png", "wc -c < character.png", "wc -c character.png", "shasum -a 256 character.png"]
                            let prefixes = ["", "cd " + workspace.path + " && ", "cd '" + workspace.path + "' && ", "cd \"" + workspace.path + "\" && "]
                            let allowed = prefixes.flatMap { prefix in suffixes.map { prefix + $0 } }
                            guard allowed.contains((pending.object["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else { throw PetError("验收只批准明确的只读文件校验命令") }
                            memberApprovalSeen = review.agent?.profile.id == verifier.id
                        }
                        approved.insert(pending.id); runtime.decide(taskID: review.id, callID: pending.id, decision: "allow")
                    }
                    await wait(0.08)
                }
                guard !runtime.isRunning(parent), let final = tasks.task(parent), final.status == .completed,
                      let leaderMeta = tasks.tasks.first(where: { $0.team?.team.id == team.id && $0.agent?.ownerID == parent }), let leaderTask = tasks.task(leaderMeta.id) else { runtime.cancel(parent); throw PetError("真实团队未完成：" + (tasks.task(parent)?.events.last?.detail ?? "超时")) }
                let members = tasks.tasks.filter { $0.agent?.ownerID == leaderTask.id }.compactMap { tasks.task($0.id) }
                let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("team-report.json"))) as? [String: Any] ?? [:]
                let source = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("source.json"))) as? [String: Any] ?? [:], image = try Data(contentsOf: workspace.appendingPathComponent("character.png"))
                checks["actualTeamRunsTwoDistinctMemberContexts"] = Set(members.compactMap { $0.agent?.profile.id }) == [reader.id, verifier.id] && members.allSatisfy { $0.status == .completed && $0.inputTokens > 0 && $0.outputTokens > 0 }
                checks["actualMemberToolsRecorded"] = members.contains { $0.agent?.profile.id == reader.id && $0.events.contains { $0.title == "read_file" && $0.status == "completed" } } && members.contains { $0.agent?.profile.id == verifier.id && $0.events.contains { $0.title == "run_command" && $0.status == "completed" } }
                checks["actualTeamFinalWaitsForMemberResults"] = leaderTask.status == .completed && leaderTask.events.filter { $0.title == "delegate_task" && $0.status == "completed" && $0.childTaskID != nil }.count == 2 && final.events.contains { $0.title == "delegate_task" && $0.childTaskID == leaderTask.id && $0.status == "completed" }
                checks["actualMemberApprovalReachedOuterTask"] = memberApprovalSeen
                checks["teamDoesNotReceiveOuterHistory"] = ([leaderTask] + members).allSatisfy { !$0.messages.contains { $0.content.contains("TEAM_PARENT_ONLY_6392") } }
                checks["actualTeamReportMatchesIndependentInputs"] = actual.count == 5 && ["edition", "width", "height"].allSatisfy { actual[$0] as? Int == source[$0] as? Int } && actual["imageBytes"] as? Int == image.count && actual["sha256"] as? String == AgentFiles.hash(image)
                checks["leaderReadBackActualArtifact"] = leaderTask.events.contains { $0.title == "read_file" && $0.status == "completed" && $0.detail.contains("team-report.json") }
                report["live"] = ["parentID": parent, "leaderID": leaderTask.id, "memberIDs": members.map(\.id), "approvals": approved.count, "report": actual]
                tasks.selectedID = parent
            }
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }
            report["scope"] = "Actual native draft assignment, saved local team lifecycle, scope/roster boundaries, and optional saved-model three-level delegation with two independent members and file readback. No simulated model replies; public repository assets and independent profile."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("agent-team-report.json"), options: .atomic)
            if CommandLine.arguments.contains("--custom-agent-ui-hold") {
                control.showAgentTask(draft); manager = AgentTeamWindow(store: tasks, workspace: workspace.path); manager?.onUse = { [weak self] in self?.control.showAgentTask($0) }; manager?.showWindow(nil); manager?.window?.makeKeyAndOrderFront(nil); phase("ui-ready")
                let deadline = Date().addingTimeInterval(1200)
                while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
        } catch {
            report["error"] = error.localizedDescription; report["checks"] = checks; report["success"] = false
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("agent-team-report.json"), options: .atomic)
        }
    }
}
