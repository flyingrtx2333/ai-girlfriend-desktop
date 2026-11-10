import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentPluginScopeCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], attempts = 0, actualPIDs: [Int32] = []
        func call(_ name: String, _ values: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)) }
        func until(_ test: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(10); while !test() && Date() < end { await wait(0.03) }; return test() }
        func phase(_ name: String) throws { let value = try JSONSerialization.data(withJSONObject: ["phase": name, "appPID": getpid(), "at": Date().timeIntervalSince1970]); let file = output.appendingPathComponent("plugin-scope-phases.jsonl"); if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }; let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.seekToEnd(); try handle.write(contentsOf: value + Data([10])) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("项目插件检查禁止模型请求") }
            let plugins = tasks.extensions.plugins, a = try AgentFiles(workspace: output.appendingPathComponent("real project").path).root.path, b = try AgentFiles(workspace: output.appendingPathComponent("other project").path).root.path, c = try AgentFiles(workspace: output.appendingPathComponent("copied project").path).root.path
            let directoryMode = CommandLine.arguments.contains("--plugin-directory-check")
            let one = try await plugins.inspect(output.appendingPathComponent(directoryMode ? "directory-v1/目录 插件" : "lifecycle-v1.zip")), two = try await plugins.inspect(output.appendingPathComponent(directoryMode ? "directory-v2/目录 插件" : "lifecycle-v2.zip"))
            try phase("install-independent-user-and-project-packages")
            let user = try plugins.install(one); try plugins.setEnabled(user, true); let activeUser = try plugins.installation(user.id)
            let project = try plugins.install(two, workspace: a)
            checks["projectPackageIsStoredInsideActualProjectAndStartsLocallyDisabled"] = project.root.path.hasPrefix(a + "/.bluefatfish/plugins/") && project.workspace == a && project.locallyReviewed && !project.enabled && !project.receipt.enabled
            checks["sameNameUserAndProjectPackagesHaveIndependentIDsAndVersions"] = project.id != user.id && project.instanceID != activeUser.instanceID && project.metadata.version == "2.0.0" && activeUser.metadata.version == "1.0.0"
            checks["reviewedDisabledProjectOverrideDoesNotFallBackToUserVersion"] = try plugins.catalog(workspace: a).map(\.id) == [project.id] && tasks.extensions.catalog(workspace: a, includeDisabled: false).isEmpty
            checks["otherProjectAndNoWorkspaceKeepUserPlugin"] = try plugins.catalog(workspace: b).map(\.id) == [user.id] && plugins.catalog().map(\.id) == [user.id]
            try plugins.setEnabled(project, true); var active = try plugins.installation(project.id)
            let userBytes = try pluginUpdateHashes(activeUser.root), initialProjectBytes = try pluginUpdateHashes(active.root)
            let aTask = tasks.create(title: "项目 A 组件范围", workspace: a, mode: .agent, workMode: .general), bTask = tasks.create(title: "项目 B 用户组件", workspace: b, mode: .agent, workMode: .general), noProject = tasks.create(title: "无工作区用户组件", mode: .ask, workMode: .general)
            checks["automaticRulesUseActualProjectVersionOnly"] = try plugins.ruleContext(tasks.task(aTask)!).text.contains("PLUGIN_RULE_VERSION_2") && !plugins.ruleContext(tasks.task(aTask)!).text.contains("PLUGIN_RULE_VERSION_1") && plugins.ruleContext(tasks.task(bTask)!).text.contains("PLUGIN_RULE_VERSION_1") && plugins.ruleContext(tasks.task(noProject)!).text.contains("PLUGIN_RULE_VERSION_1")
            let skillA = try tasks.extensions.catalog(workspace: a).first { $0.kind == .skill }!, skillB = try tasks.extensions.catalog(workspace: b).first { $0.kind == .skill }!
            checks["identicalSkillTextUsesScopeSpecificIdentity"] = skillA.id != skillB.id && skillA.name == skillB.name && skillA.sha256 == skillB.sha256 && skillA.pluginName == project.id
            guard runtime.submit("/skill:lifecycle-tools:source 核对实际项目资源。", taskID: aTask, startImmediately: false) else { throw PetError(runtime.submissionError ?? "Skill 未载入") }
            let resource = try await AgentTools(store: tasks, taskID: aTask).execute(call("read_skill_resource", ["id": skillA.id, "path": "resources/version.json"]))
            checks["actualProjectSkillReadsPackagedVersionTwo"] = !resource.failed && resource.text.contains("version-2") && tasks.task(aTask)?.messages.last(where: \.isHumanInput)?.extensionReferences?.first?.pluginName == project.id
            let commandTask = tasks.create(title: "项目命令范围", workspace: a, mode: .ask, workMode: .general)
            guard runtime.submit("/command:lifecycle-tools:inspect 保留真实草稿", taskID: commandTask, startImmediately: false) else { throw PetError(runtime.submissionError ?? "命令未展开") }
            tasks.update(commandTask) { $0.workspace = b }
            do { _ = try runtime.systemContext(tasks.task(commandTask)!); checks["stoppedProjectCommandCannotResumeAfterWorkspaceChange"] = false } catch { checks["stoppedProjectCommandCannotResumeAfterWorkspaceChange"] = error.localizedDescription.contains("扩展") }
            tasks.update(commandTask) { $0.workspace = a }
            let roleA = try tasks.agents.list(workspace: a).first { $0.name == "lifecycle-tools:reviewer" }!, roleB = try tasks.agents.list(workspace: b).first { $0.name == "lifecycle-tools:reviewer" }!
            checks["packagedRolesHaveIndependentSkillsAndScope"] = roleA.id != roleB.id && roleA.skills == [skillA.id] && roleB.skills == [skillB.id]
            do { _ = try tasks.agents.profile(roleA.id, workspace: b); checks["projectRoleCannotBeSelectedInAnotherProject"] = false } catch { checks["projectRoleCannotBeSelectedInAnotherProject"] = true }
            try tasks.agents.savePluginModel(roleA, model: "project-scope-model", expectedHash: tasks.agents.pluginModelVersion())
            checks["localRoleModelOverrideDoesNotChangeUserRoleOrSharedPackage"] = try tasks.agents.profile(roleB.id, workspace: b).model != "project-scope-model" && pluginUpdateHashes(active.root) == initialProjectBytes
            let roleTask = try tasks.agents.createTask(roleA.id, store: tasks, workspace: a, workMode: .general); tasks.update(roleTask) { $0.draft = "保留项目角色原草稿" }
            let roleFile = tasks.directory.appendingPathComponent(roleTask + ".json"), roleBytes = try Data(contentsOf: roleFile)
            let rule = try plugins.ruleItems(workspace: a).first!
            do { _ = try plugins.currentRule(rule.id, workspace: b); checks["projectRuleIDCannotReadAnotherProject"] = false } catch { checks["projectRuleIDCannotReadAnotherProject"] = true }
            try phase("actual-hook-execution-and-private-configuration")
            for workspace in [a, b] {
                let reference = try plugins.hookReferences(workspace: workspace).first!, doc = try tasks.hooks.pluginDocument(reference)
                try tasks.hooks.savePluginDocument(doc.text, reference: reference, original: doc.original, expectedHash: doc.hash)
                let hook = try tasks.hooks.catalog(workspace: workspace).first { $0.plugin != nil }!
                try tasks.hooks.setEnabled(hook, true, workspace: workspace)
            }
            let hookA = try tasks.hooks.catalog(workspace: a).first { $0.plugin?.name == project.id }!
            let hookConfigA = try plugins.hookConfiguration(hookA.plugin!), privateRoot = try AgentFiles(workspace: store.directory.path).root.path
            checks["projectHooksHaveExactWorkspaceAndPrivateConfiguration"] = hookA.workspace == a && hookConfigA.file.path.hasPrefix(privateRoot + "/extensions/plugin-hooks/")
            do { try tasks.hooks.setEnabled(hookA, true, workspace: b); checks["projectHookApprovalCannotMoveToAnotherProject"] = false } catch { checks["projectHookApprovalCannotMoveToAnotherProject"] = true }
            let hookResultA = try await tasks.hooks.fire(.sessionStart, trigger: "actual-project-a", store: tasks, taskID: aTask), hookResultB = try await tasks.hooks.fire(.sessionStart, trigger: "actual-project-b", store: tasks, taskID: bTask)
            checks["actualHooksExecuteTheCorrectPackagedProgramInEachProject"] = hookResultA.context.contains("actual plugin source version 2") && !hookResultA.context.contains("actual plugin source version 1") && hookResultB.context.contains("actual plugin source version 1") && !hookResultB.context.contains("actual plugin source version 2")
            report["actualHookOutputs"] = ["project": hookResultA.context, "otherProject": hookResultB.context]
            try phase("actual-scope-specific-mcp-processes")
            func configured(_ workspace: String) throws -> AgentMCPServer {
                var server = tasks.mcp.availableServers(workspace: workspace).first { $0.plugin != nil }!
                var value = try JSONSerialization.jsonObject(with: Data(tasks.mcp.document(server).utf8)) as! [String: Any]
                value["env"] = ["RESOURCE_PATH": URL(fileURLWithPath: workspace).appendingPathComponent("source.txt").path]
                server = try tasks.mcp.save(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), id: server.id, expectedRevision: server.revision, workspace: workspace)
                try tasks.mcp.setEnabled(server.id, true, workspace: workspace); return try tasks.mcp.server(server.id, workspace: workspace)
            }
            let serverA = try configured(a), serverB = try configured(b)
            checks["sameNameConnectorsKeepIndependentConfigurationAndIdentity"] = serverA.id != serverB.id && serverA.plugin?.name == project.id && serverB.plugin?.name == user.id
            _ = try await tasks.mcp.connect(serverA.id, revision: serverA.revision, owner: aTask, workspace: a)
            _ = try await tasks.mcp.connect(serverB.id, revision: serverB.revision, owner: bTask, workspace: b)
            guard let tokenA = tasks.mcp.token(serverA.id, owner: aTask), let tokenB = tasks.mcp.token(serverB.id, owner: bTask), let mcpA = await tasks.mcp.processID(serverA.id, owner: aTask), let mcpB = await tasks.mcp.processID(serverB.id, owner: bTask) else { throw PetError("实际插件连接未启动") }
            actualPIDs += [mcpA, mcpB]
            _ = try tasks.mcp.catalog(serverA.id, owner: aTask, token: tokenA, offset: 0, query: "read_source")
            _ = try tasks.mcp.catalog(serverB.id, owner: bTask, token: tokenB, offset: 0, query: "read_source")
            let resultA = try await tasks.mcp.call(serverA.id, owner: aTask, token: tokenA, name: "read_source", arguments: [:]), resultB = try await tasks.mcp.call(serverB.id, owner: bTask, token: tokenB, name: "read_source", arguments: [:])
            let shaA = AgentFiles.hash(try Data(contentsOf: URL(fileURLWithPath: a).appendingPathComponent("source.txt"))), shaB = AgentFiles.hash(try Data(contentsOf: URL(fileURLWithPath: b).appendingPathComponent("source.txt")))
            checks["actualMCPProcessesReadIndependentPublicFilesAndVersions"] = !resultA.failed && !resultB.failed && resultA.text.contains(shaA) && resultA.text.contains("version-2") && resultB.text.contains(shaB) && resultB.text.contains("version-1") && shaA != shaB
            tasks.update(aTask) { $0.workspace = b }
            do { _ = try await AgentTools(store: tasks, taskID: aTask).execute(call("list_mcp_tools", ["server_id": serverA.id, "connection": tokenA, "query": "read_source"])); checks["existingConnectionTokenCannotCrossChangedWorkspace"] = false } catch { checks["existingConnectionTokenCannotCrossChangedWorkspace"] = error.localizedDescription.contains("项目") }
            do { _ = try runtime.systemContext(tasks.task(aTask)!); checks["existingProjectSkillCannotCrossChangedWorkspace"] = false } catch { checks["existingProjectSkillCannotCrossChangedWorkspace"] = error.localizedDescription.contains("扩展") }
            tasks.update(aTask) { $0.workspace = a }
            let schemas = try tasks.mcp.modelDefinitions(owner: aTask, mode: .agent, workspace: a)
            guard let modelTool = (schemas.first?["function"] as? [String: Any])?["name"] as? String else { throw PetError("实际MCP参数函数未载入") }
            checks["actualModelToolSchemaAndRoutingStayInProject"] = try tasks.mcp.routedCall(call(modelTool, [:]), owner: aTask, workspace: a)?.object["server_id"] as? String == serverA.id
            do { _ = try tasks.mcp.routedCall(call(modelTool, [:]), owner: aTask, workspace: b); checks["opaqueModelToolNameCannotBypassProjectScope"] = false } catch { checks["opaqueModelToolNameCannotBypassProjectScope"] = true }
            try phase("share-package-without-sharing-local-activation-or-secrets")
            let copyBase = URL(fileURLWithPath: c).appendingPathComponent(".bluefatfish/plugins"); try FileManager.default.createDirectory(at: copyBase, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: active.root, to: copyBase.appendingPathComponent(active.metadata.name))
            let shared = try plugins.catalog(workspace: c, onlyScope: true).first!
            checks["actualSharedCopyKeepsPackageBytesButNotLocalApprovalOrIdentity"] = try pluginUpdateHashes(shared.root) == initialProjectBytes && shared.requestedEnabled && !shared.locallyReviewed && !shared.enabled && shared.instanceID != active.instanceID
            checks["unreviewedSharedCopyDoesNotSuppressExistingUserPlugin"] = try plugins.catalog(workspace: c).map(\.id) == [user.id] && plugins.ruleContext(tasks.task(tasks.create(title: "共享副本未审阅", workspace: c, mode: .ask, workMode: .general))!).text.contains("PLUGIN_RULE_VERSION_1")
            let template = try plugins.content(".mcp.json", installation: shared)
            let sharedTree = try pluginUpdateHashes(URL(fileURLWithPath: a).appendingPathComponent(".bluefatfish"))
            checks["sharedFilesContainTemplatesAndNoLocalConnectorValues"] = String(decoding: template, as: UTF8.self).contains("${RESOURCE_PATH}") && !String(decoding: template, as: UTF8.self).contains(a) && Set(sharedTree.keys) == Set(initialProjectBytes.keys.map { "plugins/" + active.metadata.name + "/" + $0 })
            let fresh = AgentPlugins(profile: store.directory, sharedHome: plugins.sharedHome)
            checks["freshServiceRetainsExactLocalReviewAndKeepsSharedCopyUnapproved"] = try fresh.installation(active.id).enabled && !fresh.installation(shared.id).enabled && fresh.catalog(workspace: c).map(\.id) == [user.id]
            try phase("actual-project-update-cancels-only-own-processes")
            let node = try String(contentsOf: output.appendingPathComponent("node-path.txt"), encoding: .utf8)
            func start(_ workspace: String) throws -> String {
                let id = tasks.create(title: "实际项目进程隔离", workspace: workspace, mode: .agent, workMode: .general)
                guard runtime.submit("/skill:lifecycle-tools:source 核对实际取消范围。", taskID: id, startImmediately: false) else { throw PetError(runtime.submissionError ?? "Skill 未保存") }
                let pending = try call("run_command", ["command": AgentGit.quote(node) + " slow.cjs", "network": false, "timeout_seconds": 40])
                tasks.update(id) { $0.permission = .automatic; $0.pendingCalls = [pending] }; runtime.start(id); return id
            }
            let slowA = try start(a), slowB = try start(b), pidA = URL(fileURLWithPath: a).appendingPathComponent("slow-pids.json"), pidB = URL(fileURLWithPath: b).appendingPathComponent("slow-pids.json")
            guard await until({ FileManager.default.fileExists(atPath: pidA.path) && FileManager.default.fileExists(atPath: pidB.path) }) else { throw PetError("实际父子进程尚未启动") }
            let pa = try JSONSerialization.jsonObject(with: Data(contentsOf: pidA)) as! [String: Int], pb = try JSONSerialization.jsonObject(with: Data(contentsOf: pidB)) as! [String: Int]
            let aPIDs = [Int32(pa["pid"]!), Int32(pa["child"]!), mcpA], bPIDs = [Int32(pb["pid"]!), Int32(pb["child"]!), mcpB]; actualPIDs += Array(aPIDs.prefix(2)) + Array(bPIDs.prefix(2))
            active = try plugins.installation(active.id)
            if CommandLine.arguments.contains("--plugin-settings-check") {
                let document = try plugins.settingDocument(.local, workspace: a)
                try plugins.setPluginSetting(false, name: active.metadata.name, scope: .local, workspace: a, expectedHash: document.hash)
                checks["actualLocalSettingStopsOnlyOwnCommandsChildrenAndMCP"] = await until { !runtime.isRunning(slowA) && aPIDs.allSatisfy { kill($0, 0) != 0 } }
                checks["otherProjectProcessesStayAliveAfterActualLocalSettingChange"] = runtime.isRunning(slowB) && bPIDs.allSatisfy { kill($0, 0) == 0 } && tasks.mcp.token(serverB.id, owner: bTask) == tokenB
            }
            let updated = try plugins.update(one, replacing: active)
            checks[CommandLine.arguments.contains("--plugin-settings-check") ? "projectUpdateKeepsAlreadyStoppedProjectProcessesTerminal" : "actualProjectUpdateStopsOnlyProjectCommandsChildrenAndMCP"] = await until { !runtime.isRunning(slowA) && aPIDs.allSatisfy { kill($0, 0) != 0 } }
            checks["otherProjectCommandsAndMCPRemainActuallyAlive"] = runtime.isRunning(slowB) && bPIDs.allSatisfy { kill($0, 0) == 0 } && tasks.mcp.token(serverB.id, owner: bTask) == tokenB
            report["projectCancelledPIDs"] = aPIDs.map(Int.init); report["otherProjectSurvivingPIDs"] = bPIDs.map(Int.init)
            checks["projectUpdateRetainsUserPackageAndOriginalRoleTaskBytes"] = try pluginUpdateHashes(activeUser.root) == userBytes && Data(contentsOf: roleFile) == roleBytes && !updated.enabled && updated.locallyReviewed && updated.metadata.version == "1.0.0"
            guard let revision = updated.receipt.revisions?.last else { throw PetError("项目历史未保存") }
            checks["projectHistoryStaysInsideProjectAndRetainsOriginalBytes"] = try pluginUpdateHashes(plugins.revision(revision, of: updated).root) == initialProjectBytes
            var restored = try plugins.update(plugins.package(revision, of: updated), replacing: updated)
            checks["projectRestoreUsesOriginalResourcesWithFreshDisabledIdentity"] = restored.metadata.version == "2.0.0" && restored.receipt.hashes == two.receipt.hashes && !restored.enabled && restored.instanceID != active.instanceID && restored.receipt.revisions?.count == 2
            runtime.cancel(slowB); tasks.mcp.disconnect(owner: bTask)
            checks["otherProjectProcessesExitOnlyAfterExplicitOwnCleanup"] = await until { !runtime.isRunning(slowB) && bPIDs.allSatisfy { kill($0, 0) != 0 } }
            if CommandLine.arguments.contains("--plugin-settings-check") { checks.merge(try await checkAgentPluginSettings(output, tasks: tasks, runtime: runtime, a: a, b: b)) { _, new in new }; restored = try plugins.installation(restored.id) }
            if directoryMode { checks.merge(try await checkAgentPluginDirectory(output, tasks: tasks, runtime: runtime)) { _, new in new } }
            try phase("external-change-and-replayed-receipt-cannot-reactivate")
            try plugins.setEnabled(restored, true); let approved = try plugins.installation(restored.id), receiptFile = approved.root.appendingPathComponent("receipt.json"), approvedBytes = try Data(contentsOf: receiptFile)
            var changed = approved.receipt; changed.activationID = UUID().uuidString; try JSONEncoder().encode(changed).write(to: receiptFile, options: .atomic)
            do { _ = try plugins.ruleContext(tasks.task(aTask)!); checks["externalReceiptChangeStopsEffectiveContextBeforeModel"] = false } catch { checks["externalReceiptChangeStopsEffectiveContextBeforeModel"] = error.localizedDescription.contains("项目插件") }
            do { _ = try tasks.hooks.catalog(workspace: a); checks["externalReceiptChangeStopsHookDiscoveryBeforeExecution"] = false } catch { checks["externalReceiptChangeStopsHookDiscoveryBeforeExecution"] = error.localizedDescription.contains("项目插件") }
            let issues = try plugins.disableProject(a)
            try approvedBytes.write(to: receiptFile, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptFile.path)
            checks["disableAllRevokesOnlyProjectAndOldReceiptCannotResurrectGrant"] = try issues.isEmpty && !plugins.installation(approved.id).enabled && !plugins.hasProjectActivations(a) && plugins.installation(user.id).enabled && pluginUpdateHashes(activeUser.root) == userBytes
            _ = try plugins.ruleContext(tasks.task(aTask)!)
            checks["disabledProjectRemainsAReviewedOverrideWithoutBlockingUnrelatedWork"] = try plugins.catalog(workspace: a).map(\.id) == [approved.id] && plugins.catalog(workspace: b).map(\.id) == [user.id]
            checks["actualSharedCopyAndLocalRoleDraftRemainUnmodified"] = try pluginUpdateHashes(shared.root) == initialProjectBytes && Data(contentsOf: roleFile) == roleBytes
            checks["noModelReceiptOrSyntheticAssistantReplyWasCreated"] = attempts == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false && tasks.task($0.id)?.messages.contains(where: \.isReply) != true }
            report["sourceHashes"] = ["real project/source.txt": shaA, "other project/source.txt": shaB]; report["projectPluginID"] = approved.id; report["sharedPluginID"] = shared.id; report["roleTaskID"] = roleTask
        } catch { report["error"] = error.localizedDescription }
        agentRuntime?.stopAll(); let end = Date().addingTimeInterval(10)
        while Date() < end && (agentRuntime?.isWorking == true || actualPIDs.contains { kill($0, 0) == 0 }) { await wait(0.03) }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = getpid(); report["blockedModelAttempts"] = attempts; report["actualPIDs"] = actualPIDs.map(Int.init); report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-scope-result.json"), options: .atomic)
    }
    func runAgentPluginScopeCrashCheck(_ output: URL) async {
        do {
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
            agentRuntime?.modelRequestCheck = { throw PetError("项目中断检查禁止模型请求") }
            let plugins = tasks.extensions.plugins, workspace = try AgentFiles(workspace: output.appendingPathComponent("real project").path).root.path
            let installed = try plugins.catalog(workspace: workspace, onlyScope: true).first!
            try plugins.setEnabled(installed, true); let current = try plugins.installation(installed.id)
            guard current.enabled, current.metadata.version == "2.0.0" else { throw PetError("原项目版本未准备好") }
            let before = try pluginUpdateHashes(current.root), oldConfiguration = try pluginUpdateHashes(plugins.profile.appendingPathComponent("extensions")).filter { $0.key != "project-plugin-approvals.json" }, package = try await plugins.inspect(output.appendingPathComponent("lifecycle-v1.zip"))
            let siblings = Set(try FileManager.default.contentsOfDirectory(atPath: current.root.deletingLastPathComponent().path))
            _ = plugins.observeChanges { name in
                guard name == current.id, !plugins.hasProjectActivations(workspace) else { return }
                do {
                    let added = Set(try FileManager.default.contentsOfDirectory(atPath: current.root.deletingLastPathComponent().path)).subtracting(siblings).filter { $0.hasPrefix(".plugin-revision-") }
                    guard added.count == 1, let directory = added.first, try plugins.installation(current.id).receiptHash == current.receiptHash else { return }
                    let grant = plugins.profile.appendingPathComponent("extensions/project-plugin-approvals.json")
                    let marker: [String: Any] = ["appPID": getpid(), "projectPluginID": current.id, "visibleReceiptHash": current.receiptHash, "visibleFiles": before, "configurationFiles": oldConfiguration, "revokedGrantSHA256": AgentFiles.hash(try Data(contentsOf: grant)), "unpublishedDirectory": directory, "localActivationRevokedBeforePublication": true]
                    try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-scope-crash-prepared.json"), options: .atomic)
                    while true { Darwin.sleep(1) }
                } catch { try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]).write(to: output.appendingPathComponent("plugin-scope-crash-error.json")) }
            }
            _ = try plugins.update(package, replacing: current)
            throw PetError("中断检查未停在实际撤销与发布之间")
        } catch { try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]).write(to: output.appendingPathComponent("plugin-scope-crash-error.json")) }
    }
    func runAgentPluginScopeRecoveryCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], attempts = 0
        do {
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
            agentRuntime?.modelRequestCheck = { attempts += 1; throw PetError("项目恢复检查禁止模型请求") }
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("plugin-scope-crash-prepared.json"))) as! [String: Any]
            guard let pid = marker["appPID"] as? Int, kill(pid_t(pid), 0) != 0 else { throw PetError("原中断进程尚未结束") }
            let plugins = tasks.extensions.plugins, id = marker["projectPluginID"] as! String, current = try plugins.installation(id), visible = marker["visibleFiles"] as! [String: String]
            let grant = plugins.profile.appendingPathComponent("extensions/project-plugin-approvals.json")
            checks["actualKilledProjectUpdateRetainsVisibleOriginalBytes"] = try current.receiptHash == marker["visibleReceiptHash"] as? String && pluginUpdateHashes(current.root) == visible
            checks["actualRevocationSurvivesCrashWithoutReactivatingOldSharedFlag"] = try current.requestedEnabled && current.locallyReviewed && !current.enabled && AgentFiles.hash(try Data(contentsOf: grant)) == marker["revokedGrantSHA256"] as? String
            let directory = marker["unpublishedDirectory"] as! String, candidate = current.root.deletingLastPathComponent().appendingPathComponent(directory), candidateBytes = try pluginUpdateHashes(candidate)
            _ = try plugins.catalog(workspace: current.workspace, onlyScope: true)
            checks["unpublishedProjectCandidateRemainsUnlinkedAndReported"] = current.receipt.revisions?.contains { $0.directory == directory } != true && plugins.warnings.contains { $0.contains("未关联") }
            let one = try await plugins.inspect(output.appendingPathComponent("lifecycle-v1.zip")), updated = try plugins.update(one, replacing: current)
            checks["freshProjectReviewAfterCrashRetainsBothCopiesAndStartsDisabled"] = try updated.metadata.version == "1.0.0" && updated.locallyReviewed && !updated.enabled && pluginUpdateHashes(candidate) == candidateBytes && updated.receipt.revisions?.last.map { try pluginUpdateHashes(plugins.revision($0, of: updated).root) == visible } == true
            let configuration = try pluginUpdateHashes(plugins.profile.appendingPathComponent("extensions")).filter { $0.key != "project-plugin-approvals.json" }
            checks["userPluginsAndEveryExistingPrivateComponentConfigurationRemainOriginal"] = configuration == marker["configurationFiles"] as? [String: String]
            checks["recoveryDoesNotCreateModelReceipts"] = attempts == 0 && tasks.tasks.allSatisfy { tasks.task($0.id)?.modelReceipts?.isEmpty != false }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = getpid(); report["blockedModelAttempts"] = attempts; report["activeJobs"] = agentRuntime?.isWorking == true; report["activationCount"] = attachmentCheckActivations; report["applicationActive"] = NSApp.isActive; report["visibleWindowCount"] = NSApp.windows.filter(\.isVisible).count
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("plugin-scope-recovery-result.json"), options: .atomic)
    }
}
