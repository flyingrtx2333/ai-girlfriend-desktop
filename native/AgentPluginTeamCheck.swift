import Foundation
import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentPluginTeamCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0, actualPIDs: [Int32] = []
        func call(_ name: String, _ object: [String: Any] = [:]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)) }
        func denied(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
        func until(_ condition: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(10); while Date() < end { if condition() { return true }; await wait(0.04) }; return condition() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("团队原生验收禁止模型请求") }
            let plugins = tasks.extensions.plugins, a = try AgentFiles(workspace: output.appendingPathComponent("real project").path).root.path, b = try AgentFiles(workspace: output.appendingPathComponent("other project").path).root.path, c = try AgentFiles(workspace: output.appendingPathComponent("copied project").path).root.path
            let one = try await plugins.inspect(output.appendingPathComponent("directory-v1/目录 插件")), two = try await plugins.inspect(output.appendingPathComponent("directory-v2/目录 插件"))
            let user = try plugins.install(one), project = try plugins.install(one, workspace: a), other = try plugins.install(one, workspace: b)
            let originalShared = try pluginUpdateHashes(project.root)
            var lead = AgentProfile(name: "本机负责人", description: "协调实际成员", instructions: "仅委派选定团队成员，按实际文件证据汇总。", tools: ["list_agents", "delegate_task", "read_file", "run_command", "write_file"], readOnly: false)
            var reader = AgentProfile(name: "本机核对员", description: "只读实际文件", instructions: "只读取明确指定的实际文件。", tools: ["read_file"])
            let outsider = AgentProfile(name: "团队外角色", description: "独立任务", instructions: "仅处理明确职责。", tools: ["read_file"], enabled: true)
            lead.permission = .automatic
            try tasks.agents.save(tasks.agents.encode([lead, reader, outsider]), expectedHash: nil)
            let legacy = AgentTeam(name: "旧格式本机团队", description: "保留旧资料", instructions: "按实际文件核对。", leaderID: lead.id, memberIDs: [reader.id], enabled: true)
            let legacyText = try tasks.teams.encode([legacy]); let legacyObject = try JSONSerialization.jsonObject(with: Data(legacyText.utf8)) as! [String: [[String: Any]]]
            checks["legacySevenFieldTeamStillDecodesAndEnablesOrdinaryRoles"] = try Set(legacyObject["teams"]![0].keys).count == 7 && tasks.teams.decode(legacyText).count == 1
            try tasks.teams.save(legacyText, expectedHash: nil, store: tasks)
            lead = try tasks.agents.profile(lead.id); reader = try tasks.agents.profile(reader.id)
            let legacyTask = try tasks.teams.createTask(legacy.id, store: tasks, workspace: c); try tasks.teams.check(tasks.task(legacyTask)!, store: tasks)
            checks["legacyTaskSnapshotRemainsUsableWithoutNewFields"] = tasks.task(legacyTask)?.team?.team.roleSources == nil && lead.enabled && reader.enabled
            func profile(_ key: String, _ workspace: String?) throws -> AgentProfile { guard let value = try tasks.agents.list(workspace: workspace).first(where: { $0.pluginSource?.key == key }) else { throw PetError("插件角色不可用") }; return value }
            func save(_ value: AgentTeam, _ workspace: String?) throws -> AgentTeam {
                var values = try tasks.teams.list(); values.removeAll { $0.id == value.id }; values.append(value)
                try tasks.teams.save(tasks.teams.encode(values), expectedHash: tasks.teams.document().1, store: tasks, activating: value.id, workspace: workspace)
                return try tasks.teams.list().first { $0.id == value.id }!
            }
            let coordinatorA = try profile("coordinator", a), reviewerA = try profile("reviewer", a)
            var teamA = AgentTeam(name: "Alpha 插件团队", description: "项目角色与资源", instructions: "协调项目核对，保留实际依据。", leaderID: coordinatorA.id, memberIDs: [reviewerA.id])
            teamA = try save(teamA, a); let beforeEnable = try tasks.teams.document(), beforeRoles = try tasks.agents.document()
            teamA.enabled = true
            denied("teamCannotSilentlyApproveOrEnableDisabledProjectPlugin") { _ = try save(teamA, a) }
            checks["failedTeamEnableLeavesPrivateRolesSharedPackageAndConfigurationOriginal"] = try tasks.teams.document().0 == beforeEnable.0 && tasks.agents.document().0 == beforeRoles.0 && pluginUpdateHashes(project.root) == originalShared && !plugins.installation(project.id).enabled
            try plugins.setEnabled(project, true); try plugins.setEnabled(other, true); try plugins.setEnabled(user, true)
            teamA = try save(teamA, a)
            checks["projectTeamStoresExactWorkspaceAndEveryPluginRoleReference"] = try teamA.workspace == a && teamA.roleSources?.count == 2 && teamA.roleSources?[coordinatorA.id] == profile("coordinator", a).pluginSource
            let teamTask = try tasks.teams.createTask(teamA.id, store: tasks, workspace: a), draft = tasks.create(workspace: a)
            let attachment = try await AgentAttachments.importFile(URL(fileURLWithPath: a).appendingPathComponent("source.txt"), store: tasks, taskID: draft)
            tasks.update(draft) { $0.draft = "保留项目团队草稿与真实附件" }; try tasks.teams.configureDraft(teamA.id, taskID: draft, store: tasks)
            checks["draftSelectionKeepsTaskDraftAttachmentAndProjectLeaderSnapshot"] = tasks.task(draft)?.draft == "保留项目团队草稿与真实附件" && tasks.task(draft)?.attachments?.first?.sha256 == attachment.sha256 && tasks.task(draft)?.agent?.profile.pluginSource?.name == project.id && tasks.task(draft)?.team?.team == teamA
            let member = try tasks.agents.createTask(reviewerA.id, store: tasks, workspace: a, owner: tasks.task(teamTask))
            let source = try String(contentsOf: URL(fileURLWithPath: a).appendingPathComponent("source.txt"), encoding: .utf8).split(separator: "\n").first!
            let read = try await AgentTools(store: tasks, taskID: member).execute(call("read_file", ["path": "source.txt", "limit": 4]))
            checks["actualProjectTeamMemberReadsActualPublicFileWithOwnRoleAndSkill"] = read.text.contains(String(source)) && tasks.task(member)?.agent?.profile.pluginSource?.name == project.id && tasks.task(member)?.activeSkills?.count == 1
            checks["teamMemberKeepsReadOnlyNetworkAndApprovalCeilings"] = try tasks.agents.limits(tasks.task(member)!, store: tasks).readOnly && !tasks.agents.limits(tasks.task(member)!, store: tasks).network && tasks.agents.executionPermission(tasks.task(member)!, store: tasks) == .review
            denied("teamTaskCannotMoveToOtherProject") { var changed = tasks.task(teamTask)!; changed.workspace = b; try tasks.teams.check(changed, store: tasks) }
            denied("teamCannotStartWithoutOriginalProject") { _ = try tasks.teams.createTask(teamA.id, store: tasks, workspace: nil) }
            denied("teamCannotStartInDifferentProject") { _ = try tasks.teams.createTask(teamA.id, store: tasks, workspace: b) }
            denied("teamCannotDelegateOutsideOriginalRoster") { _ = try tasks.agents.createTask(outsider.id, store: tasks, workspace: a, owner: tasks.task(teamTask)) }
            denied("teamChildCannotSelectDifferentWorkspaceEvenForOrdinaryRole") { _ = try tasks.agents.createTask(reader.id, store: tasks, workspace: b, owner: tasks.task(legacyTask)) }
            var escaped = teamA; escaped.workspace = nil
            denied("saveCannotDropOriginalProjectBindingFromAnotherWorkspace") { _ = try save(escaped, b) }
            let reviewerB = try profile("reviewer", b), reviewerUser = try profile("reviewer", c)
            var teamB = AgentTeam(name: "Beta 混合团队", description: "普通负责人和项目成员", instructions: "仅核对选定成员。", leaderID: lead.id, memberIDs: [reviewerB.id], enabled: true)
            teamB = try save(teamB, b)
            var teamUser = AgentTeam(name: "用户混合团队", description: "普通负责人和用户插件成员", instructions: "仅核对选定成员。", leaderID: lead.id, memberIDs: [reviewerUser.id], enabled: true)
            teamUser = try save(teamUser, c)
            checks["mixedTeamsKeepIndependentUserAndProjectMemberOrigins"] = teamUser.workspace == nil && teamUser.roleSources?[reviewerUser.id]?.name == user.id && teamB.workspace == b && teamB.roleSources?[reviewerB.id]?.name == other.id
            let listed = try await AgentTools(store: tasks, taskID: teamTask).execute(call("list_agents"))
            checks["teamDiscoveryContainsOnlyItsActualRoster"] = listed.text.contains(reviewerA.id) && !listed.text.contains(reviewerB.id) && !listed.text.contains(outsider.id) && !listed.text.contains(coordinatorA.id)
            let offline = output.appendingPathComponent("temporarily offline project")
            try FileManager.default.moveItem(at: URL(fileURLWithPath: a), to: offline)
            do { let originalA = teamA; teamB.instructions += " 保留其他项目。"; teamB = try save(teamB, b); checks["editingCurrentTeamPreservesOfflineForeignProjectTeam"] = try tasks.teams.list().first(where: { $0.id == originalA.id }) == originalA; try FileManager.default.moveItem(at: offline, to: URL(fileURLWithPath: a)) }
            catch { try? FileManager.default.moveItem(at: offline, to: URL(fileURLWithPath: a)); throw error }
            let oldTeamText = try tasks.teams.document(), node = try String(contentsOf: output.appendingPathComponent("node-path.txt"), encoding: .utf8), teamFile = tasks.teams.directory.appendingPathComponent("extensions/teams.json")
            let writer = Process(); writer.executableURL = URL(fileURLWithPath: node); writer.arguments = ["-e", "const f=require('fs');f.appendFileSync(process.argv[1],'\\n');", teamFile.path]; try writer.run(); writer.waitUntilExit()
            report["independentWriterPID"] = writer.processIdentifier
            let external = try Data(contentsOf: teamFile)
            denied("actualIndependentTeamChangeRejectsStaleSave") { try tasks.teams.save(oldTeamText.0, expectedHash: oldTeamText.1, store: tasks, workspace: b) }
            checks["staleSaveKeepsEveryIndependentWriterByte"] = try writer.terminationStatus == 0 && kill(writer.processIdentifier, 0) != 0 && Data(contentsOf: teamFile) == external
            let boundary = output.appendingPathComponent("team-file-boundary-profile"); try FileManager.default.createDirectory(at: boundary, withIntermediateDirectories: true)
            let target = boundary.appendingPathComponent("actual.json"); try Data(legacyText.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: boundary.appendingPathComponent("extensions"), withDestinationURL: boundary)
            let linkedTeams = AgentTeams(profile: boundary)
            denied("teamConfigurationParentLinkIsRejectedBeforeRead") { _ = try linkedTeams.document() }
            try FileManager.default.removeItem(at: boundary.appendingPathComponent("extensions")); try FileManager.default.createDirectory(at: boundary.appendingPathComponent("extensions"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: boundary.appendingPathComponent("extensions/teams.json"), withDestinationURL: target)
            denied("teamConfigurationFileLinkIsRejectedBeforeRead") { _ = try linkedTeams.document() }
            checks["rejectedLinksLeaveTargetOriginal"] = try Data(contentsOf: target) == Data(legacyText.utf8)
            func configured(_ workspace: String) throws -> AgentMCPServer {
                var server = tasks.mcp.availableServers(workspace: workspace).first { $0.plugin != nil }!
                var value = try JSONSerialization.jsonObject(with: Data(tasks.mcp.document(server).utf8)) as! [String: Any]; value["env"] = ["RESOURCE_PATH": URL(fileURLWithPath: workspace).appendingPathComponent("source.txt").path]
                server = try tasks.mcp.save(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), id: server.id, expectedRevision: server.revision, workspace: workspace); try tasks.mcp.setEnabled(server.id, true, workspace: workspace); return try tasks.mcp.server(server.id, workspace: workspace)
            }
            func start(_ team: AgentTeam, _ workspace: String) throws -> String {
                let id = try tasks.teams.createTask(team.id, store: tasks, workspace: workspace)
                guard runtime.submit("运行本次明确批准的实际进程，保持等待。", taskID: id, startImmediately: false) else { throw PetError(runtime.submissionError ?? "任务未保存") }
                let pending = try call("run_command", ["command": AgentGit.quote(node) + " slow.cjs", "network": false, "timeout_seconds": 40]); tasks.update(id) { $0.permission = .automatic; $0.pendingCalls = [pending] }; runtime.start(id); return id
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: b).appendingPathComponent("slow.cjs"), to: URL(fileURLWithPath: c).appendingPathComponent("slow.cjs"))
            let serverUser = try configured(c), serverB = try configured(b), slowUser = try start(teamUser, c), slowB = try start(teamB, b)
            _ = try await tasks.mcp.connect(serverUser.id, revision: serverUser.revision, owner: slowUser, workspace: c); _ = try await tasks.mcp.connect(serverB.id, revision: serverB.revision, owner: slowB, workspace: b)
            guard let mcpUser = await tasks.mcp.processID(serverUser.id, owner: slowUser), let mcpB = await tasks.mcp.processID(serverB.id, owner: slowB), let tokenUser = tasks.mcp.token(serverUser.id, owner: slowUser), let tokenB = tasks.mcp.token(serverB.id, owner: slowB) else { throw PetError("实际连接未启动") }; actualPIDs += [mcpUser, mcpB]
            for (id, server, token) in [(slowUser, serverUser, tokenUser), (slowB, serverB, tokenB)] {
                _ = try tasks.mcp.catalog(server.id, owner: id, token: token, offset: 0, query: "read_source"); let result = try await tasks.mcp.call(server.id, owner: id, token: token, name: "read_source", arguments: [:]); let workspace = tasks.task(id)!.workspace!; let hash = AgentFiles.hash(try Data(contentsOf: URL(fileURLWithPath: workspace).appendingPathComponent("source.txt"))); checks["actualConnectorReadsPublicFile-" + id] = !result.failed && result.text.contains(hash)
            }
            let pidUser = URL(fileURLWithPath: c).appendingPathComponent("slow-pids.json"), pidB = URL(fileURLWithPath: b).appendingPathComponent("slow-pids.json")
            guard await until({ FileManager.default.fileExists(atPath: pidUser.path) && FileManager.default.fileExists(atPath: pidB.path) }) else { throw PetError("实际父子进程未就绪") }
            let pu = try JSONSerialization.jsonObject(with: Data(contentsOf: pidUser)) as! [String: Int], pb = try JSONSerialization.jsonObject(with: Data(contentsOf: pidB)) as! [String: Int]
            let userPIDs = [Int32(pu["pid"]!), Int32(pu["child"]!), mcpUser], bPIDs = [Int32(pb["pid"]!), Int32(pb["child"]!), mcpB]; actualPIDs += Array(userPIDs.prefix(2)) + Array(bPIDs.prefix(2))
            checks["actualMixedLeaderDependsOnlyOnTeamRosterNotPluginRulesOrOwnRole"] = tasks.task(slowUser)?.agent?.profile.pluginSource == nil && tasks.task(slowUser)?.activeSkills?.isEmpty != false && user.rules.isEmpty
            try plugins.setEnabled(try plugins.installation(user.id), false)
            checks["memberPluginDisableActuallyStopsOrdinaryLeaderChildProcessAndConnector"] = await until { !runtime.isRunning(slowUser) && userPIDs.allSatisfy { kill($0, 0) != 0 } }
            checks["otherProjectTeamActuallyKeepsItsOwnProcessesAndConnectorAlive"] = runtime.isRunning(slowB) && bPIDs.allSatisfy { kill($0, 0) == 0 } && tasks.mcp.token(serverB.id, owner: slowB) == tokenB
            report["cancelledUserTeamPIDs"] = userPIDs.map(Int.init); report["survivingProjectTeamPIDs"] = bPIDs.map(Int.init)
            runtime.cancel(slowB); tasks.mcp.disconnect(owner: slowB)
            checks["otherTeamProcessesEndOnlyAfterExplicitOwnCleanup"] = await until { !runtime.isRunning(slowB) && bPIDs.allSatisfy { kill($0, 0) != 0 } }
            try plugins.setEnabled(try plugins.installation(user.id), true)
            denied("pluginReenableDoesNotReactivatePreviouslySavedTeam") { _ = try tasks.teams.team(teamUser.id, store: tasks, workspace: c) }
            teamUser = try save(teamUser, c)
            denied("freshTeamReviewCannotResurrectOldTaskRosterAuthorization") { try tasks.teams.check(tasks.task(slowUser)!, store: tasks) }
            do { _ = try await AgentTools(store: tasks, taskID: slowUser).execute(call("list_agents")); checks["oldTaskCannotDiscoverReactivatedPluginMembers"] = false } catch { checks["oldTaskCannotDiscoverReactivatedPluginMembers"] = true }
            let fresh = try tasks.teams.createTask(teamUser.id, store: tasks, workspace: c); try tasks.teams.check(tasks.task(fresh)!, store: tasks)
            checks["freshReviewedTeamTaskUsesCurrentMemberEpoch"] = tasks.task(fresh)?.team?.team.roleSources == teamUser.roleSources
            let updated = try plugins.update(two, replacing: plugins.installation(project.id)); try plugins.setEnabled(updated, true)
            denied("pluginUpdateLeavesOldTeamUnavailableUntilMembersAreSelectedAgain") { _ = try tasks.teams.team(teamA.id, store: tasks, workspace: a) }
            teamA.leaderID = try profile("coordinator", a).id; teamA.memberIDs = [try profile("implementer", a).id]; teamA = try save(teamA, a)
            denied("updatedTeamCannotResumePreviousVersionTask") { try tasks.teams.check(tasks.task(teamTask)!, store: tasks) }
            let askParent = try tasks.teams.createTask(teamA.id, store: tasks, workspace: a); tasks.update(askParent) { $0.mode = .ask }
            let editor = try tasks.agents.createTask(teamA.memberIDs[0], store: tasks, workspace: a, owner: tasks.task(askParent))
            denied("writeCapableNewMemberCannotExpandAskModeParent") { _ = try AgentTools(store: tasks, taskID: editor).approvalReason(for: call("write_file", ["path": "source.txt", "content": "must not be written"])) }
            var disabledA = teamA; disabledA.enabled = false; try plugins.setEnabled(try plugins.installation(project.id), false); _ = try save(disabledA, nil)
            checks["unavailableProjectTeamCanBeDisabledWithoutReenablingPlugin"] = try tasks.teams.list().first(where: { $0.id == teamA.id })?.enabled == false && !plugins.installation(project.id).enabled
            checks["allRecordsKeepActualInputsAndNoModelReceiptOrInventedAssistantReply"] = attempts == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false && tasks.task($0.id)?.messages.contains(where: \.isReply) != true }
            report["sourceHashes"] = ["real project/source.txt": AgentFiles.hash(try Data(contentsOf: URL(fileURLWithPath: a).appendingPathComponent("source.txt"))), "other project/source.txt": AgentFiles.hash(try Data(contentsOf: URL(fileURLWithPath: b).appendingPathComponent("source.txt")))]
            report["teamConfiguration"] = try JSONSerialization.jsonObject(with: Data(tasks.teams.document().0.utf8))
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); _ = await until { self.agentRuntime?.isWorking != true && actualPIDs.allSatisfy { kill($0, 0) != 0 } }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["actualPIDs"] = actualPIDs.map(Int.init); report["appPID"] = getpid(); report["blockedModelAttempts"] = attempts; report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-team-result.json"), options: .atomic)
    }
}
