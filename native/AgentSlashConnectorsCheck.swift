import AppKit
import Darwin

@MainActor extension AppDelegate {
    @discardableResult func prepareSlashConnectorsUI(_ output:URL, seed:Bool) async throws -> [String:String] {
        ensureAgent(); guard checkDirectory != nil, let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少独立连接器菜单环境") }
        let file = output.appendingPathComponent("slash-connectors-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:file))
            guard let id = ids["task"], tasks.task(id) != nil else { throw PetError("原连接器任务不可用") }; control.showAgentTask(id); control.show(tab:"chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath:file.path) else { throw PetError("公开样例已存在，请重开原目录") }
        let dependencies = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:output.appendingPathComponent("dependencies.json")))
        guard let node = dependencies["node"], let entry = dependencies["serverEntry"] else { throw PetError("缺少已安装的官方文件连接器") }
        let project = output.appendingPathComponent("public-project"), other = output.appendingPathComponent("other-project")
        for root in [project,other] { try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false) }
        try Data("# Public connector fixture\n\nNative acceptance data, not a model response.\nEdition: coral-7319\nRead only the configured public directory.\n".utf8).write(to:project.appendingPathComponent("README.md"))
        func json(_ object:[String:Any]) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self) }
        func stdio(_ name:String) throws -> AgentMCPServer { try tasks.mcp.save(json(["name":name,"type":"stdio","command":node,"args":[entry,project.path],"env":[:],"timeoutSeconds":20])) }
        let primary = try stdio("Public README \"公开\" 🧭"), second = try stdio("另一份公开文档"), disabled = try stdio("已停用的连接器")
        try tasks.mcp.setEnabled(disabled.id,false)
        let remote = try tasks.mcp.save(json(["name":"Remote docs","type":"http","url":"https://example.invalid/mcp","bearerToken":"","headers":[:],"timeoutSeconds":20]))
        let source = output.appendingPathComponent("public-plugin-source"), metadata = source.appendingPathComponent(".qoder-plugin")
        try FileManager.default.createDirectory(at:metadata,withIntermediateDirectories:true)
        let manifest:[String:Any] = ["name":"public-connectors","version":"1.0.0","displayName":"公开文档插件","mcpServers":["docs":["command":node,"args":[entry,project.path],"env":[:]],"unconfigured":["command":node,"args":[entry,project.path],"env":[:]]]]
        try Data(json(manifest).utf8).write(to:metadata.appendingPathComponent("plugin.json"))
        let package = try await tasks.extensions.plugins.inspect(source)
        let userPlugin = try tasks.extensions.plugins.install(package), projectPlugin = try tasks.extensions.plugins.install(package,workspace:project.path)
        for plugin in [userPlugin,projectPlugin] { try tasks.extensions.plugins.setEnabled(tasks.extensions.plugins.installation(plugin.id),true) }
        func configure(_ workspace:String?) throws -> AgentMCPServer {
            let server = tasks.mcp.availableServers(workspace:workspace).first{$0.plugin?.key == "docs"}!
            let saved = try tasks.mcp.save(tasks.mcp.document(server),id:server.id,expectedRevision:server.revision,workspace:workspace)
            try tasks.mcp.setEnabled(saved.id,true,workspace:workspace); return try tasks.mcp.server(saved.id,workspace:workspace)
        }
        let userServer = try configure(nil), projectServer = try configure(project.path)
        let id = tasks.create(title:"连接器菜单公开样例",workspace:project.path), noWorkspace = tasks.create(title:"无工作区连接器",mode:.agent,workMode:.general), ask = tasks.create(title:"问答模式原记录",mode:.ask,workMode:.general), otherID = tasks.create(title:"另一个项目原草稿",workspace:other.path)
        tasks.update(id) { $0.draft = "保留公开核对要求 🧭" }; tasks.update(noWorkspace) { $0.draft = "Read the actual public README 🧭" }
        tasks.update(otherID) { $0.draft = "另一项未发送草稿"; $0.messages = [.init(role:"user",content:"原生公开样例：保留此项记录。")]; $0.status = .completed }
        let historySeed = tasks.create(title:"连接器原生输入准备（未请求模型）",mode:.agent,workMode:.general)
        guard runtime.submit("/" + (try AgentMCPSelection.invocation(primary)) + " 核对公开 README。",taskID:historySeed,startImmediately:false) else { throw PetError(runtime.submissionError ?? "原生最近使用输入未接受") }
        tasks.update(historySeed) { $0.status = .stopped }
        let ids = ["task":id,"noWorkspace":noWorkspace,"ask":ask,"other":otherID,"historySeed":historySeed,"server":primary.id,"second":second.id,"disabled":disabled.id,"remote":remote.id,"userServer":userServer.id,"projectServer":projectServer.id,"userPlugin":userPlugin.id,"projectPlugin":projectPlugin.id,"node":node,"serverEntry":entry]
        try JSONEncoder().encode(ids).write(to:file); control.showAgentTask(id); control.show(tab:"chat"); return ids
    }
    func slashConnectorsReadback() -> [String:Any] {
        guard checkDirectory != nil, let tasks = agentStore else { return [:] }
        return ["records":tasks.tasks.compactMap{tasks.task($0.id)}.map { task in
            ["id":task.id,"mode":task.mode.rawValue,"draft":task.draft ?? "","messages":task.messages.count,"toolGroups":task.toolGroups ?? [],"selected":task.messages.last(where:\.isHumanInput)?.mcpSelection?.id ?? "","candidates":AgentMCPSelection.candidates(task:task,store:tasks).map(\.id)] as [String:Any]
        },"recentIDs":tasks.slashMenu.recentIDs,"configurationError":tasks.mcp.loadError ?? ""]
    }
    func runSlashConnectorsCheck(_ output:URL) async {
        var checks:[String:Bool] = [:], report:[String:Any] = [:], attempts = 0
        func refused(_ body:() throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        func call(_ name:String,_ object:[String:Any]) throws -> AgentToolCall { .init(id:UUID().uuidString,name:name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self)) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("连接器菜单原生验收禁止模型请求") }; defer { runtime.stopAll(); tasks.mcp.disconnect() }
            let ids = try await prepareSlashConnectorsUI(output,seed:true), id = ids["task"]!, original = tasks.task(id)!, primary = try tasks.mcp.server(ids["server"]!), reference = try AgentMCPSelection.reference(primary)
            let otherBefore = try Data(contentsOf:tasks.directory.appendingPathComponent(ids["other"]! + ".json")), source = URL(fileURLWithPath:original.workspace!).appendingPathComponent("README.md"), sourceBefore = try Data(contentsOf:source)
            checks["independentHomeAndNotificationsBlocked"] = tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            let candidates = AgentMCPSelection.candidates(task:original,store:tasks), currentIDs = Set(candidates.map(\.id))
            checks["onlyConfiguredEnabledCurrentScopeConnectors"] = currentIDs == Set([primary.id,ids["second"]!,ids["remote"]!,ids["projectServer"]!])
            checks["noWorkspaceUsesUserPluginAndSharedConnectors"] = Set(AgentMCPSelection.candidates(task:tasks.task(ids["noWorkspace"]!)!,store:tasks).map(\.id)) == Set([primary.id,ids["second"]!,ids["remote"]!,ids["userServer"]!])
            for mode in [AgentMode.ask,.plan] { var task = original; task.mode = mode; checks[mode.rawValue + "CannotSelectExternalConnector"] = AgentMCPSelection.candidates(task:task,store:tasks).isEmpty }
            var limited = original; limited.inheritedLimits = .init(readOnly:false,network:false,permission:.automatic)
            checks["inheritedNetworkRestrictionFiltersAndRejects"] = AgentMCPSelection.candidates(task:limited,store:tasks).isEmpty && refused { _ = try AgentMCPSelection.current(reference,task:limited,store:tasks) }
            limited.inheritedLimits = .init(readOnly:true,network:true,permission:.automatic)
            checks["inheritedReadOnlyRestrictionFiltersAndRejects"] = AgentMCPSelection.candidates(task:limited,store:tasks).isEmpty && refused { _ = try AgentMCPSelection.current(reference,task:limited,store:tasks) }
            let role = AgentProfile(name:"仅允许指定连接器",description:"公开菜单范围",instructions:"仅读取已选公开来源。",readOnly:false,network:true,enabled:true,mcpServers:[primary.id])
            let document = try tasks.agents.document(); try tasks.agents.save(tasks.agents.encode([role]),expectedHash:document.1)
            let roleID = try tasks.agents.createTask(role.id,store:tasks,workspace:original.workspace)
            checks["assignedRoleOnlySeesItsAllowedServer"] = AgentMCPSelection.candidates(task:tasks.task(roleID)!,store:tasks).map(\.id) == [primary.id]
            var deniedRole = role; deniedRole.toolPermissions = ["connect_mcp":.deny]
            try tasks.agents.save(tasks.agents.encode([deniedRole]),expectedHash:tasks.agents.document().1)
            checks["currentRoleDenialInvalidatesOldAssignment"] = AgentMCPSelection.candidates(task:tasks.task(roleID)!,store:tasks).isEmpty && refused { _ = try AgentMCPSelection.current(reference,task:tasks.task(roleID)!,store:tasks) }
            try tasks.agents.save(tasks.agents.encode([role]),expectedHash:tasks.agents.document().1)
            let invocation = "/" + (try AgentMCPSelection.invocation(primary)), raw = invocation + " 逐行核对 README 🧭"
            checks["quotedUnicodeNamesRoundTripWithoutLosingArguments"] = try AgentMCPSelection.command(raw)?.name == AgentMCPSelection.title(primary) && AgentMCPSelection.command(raw)?.arguments == "逐行核对 README 🧭"
            for (index,value) in ["/mcp","/mcp name","/mcp \"\"","/mcp \"unterminated","/mcp \"name\"tail","/mcp \"bad\\q\""].enumerated() { checks["malformedConnectorCommandRejected-\(index)"] = refused { _ = try AgentMCPSelection.command(value) } }
            checks["otherSlashCommandsAreNotIntercepted"] = try AgentMCPSelection.command("/command:mcp public args") == nil && AgentMCPSelection.command("/skill:mcp public args") == nil
            for (key,value) in try await control.checkSlashConnectors(output,ids:ids) { checks[key] = value }
            tasks.update(id) { $0.toolGroups = ["browser"]; $0.permission = .automatic }
            checks["acceptedInputCapturesCurrentSelectionAndKeepsOriginal"] = runtime.submit(raw,taskID:id,startImmediately:false) && tasks.task(id)?.messages.last?.content == raw && tasks.task(id)?.messages.last?.mcpSelection == reference
            let accepted = tasks.task(id)!, message = accepted.messages.last!
            checks["selectionLoadsMCPWithoutChangingPermissionModeOrOtherGroups"] = Set(accepted.toolGroups ?? []) == ["browser","mcp"] && accepted.permission == .automatic && accepted.mode == original.mode
            checks["intentContainsOnlyServiceIdentityNotLaunchOrEndpoint"] = message.extensionInstructions?.contains(primary.revision) == true && message.extensionInstructions?.contains(primary.command!) == false && message.extensionInstructions?.contains(ids["serverEntry"]!) == false && message.wire["mcpSelection"] == nil
            checks["acceptedSelectionRecordsRecentWithoutDeletingOldKinds"] = tasks.slashMenu.recentIDs.first == "connector." + primary.id && tasks.slashMenu.recentIDs.contains("mode.plan")
            var legacy = message; legacy.mcpSelection = nil
            checks["oldMessagesRemainReadable"] = try JSONDecoder().decode(AgentMessage.self,from:JSONEncoder().encode(legacy)).mcpSelection == nil
            var queued = original; queued.queuedMessages = [message]; queued.flushQueuedInputs()
            checks["queuedInputKeepsSelectionAndLoadsToolGroup"] = queued.messages.last?.mcpSelection == reference && queued.toolGroups?.contains("mcp") == true
            let reopened = AgentStore(directory:store.directory,legacy:[],extensionHome:output.appendingPathComponent("shared-home"))
            checks["selectionConfigurationAndHistorySurviveReopen"] = reopened.task(id)?.messages.last?.mcpSelection == reference && reopened.slashMenu.recentIDs == tasks.slashMenu.recentIDs && (try? AgentMCPSelection.current(reference,task:reopened.task(id)!,store:reopened)) != nil
            let tools = AgentTools(store:tasks,taskID:id), connect = try call("connect_mcp",["server_id":primary.id,"configuration":primary.revision])
            let beforeConnectPID = await tasks.mcp.processID(primary.id,owner:id)
            checks["selectionDoesNotConnectBeforeActualApprovedExecution"] = try beforeConnectPID == nil && tasks.mcp.token(primary.id,owner:id) == nil && tools.approvalReason(for:connect) != nil
            let handshake = try await tools.execute(connect)
            guard let token = tasks.mcp.token(primary.id,owner:id), let pid = await tasks.mcp.processID(primary.id,owner:id) else { throw PetError("实际官方文件服务未启动") }
            checks["originalConnectorHandshakeStartsActualProcess"] = !handshake.failed && kill(pid,0) == 0 && handshake.text.contains("tool_count")
            let catalog = try tasks.mcp.catalog(primary.id,owner:id,token:token,offset:0,query:"read_text_file")
            checks["actualCatalogLoadsOriginalReadSchema"] = (catalog["tools"] as? [[String:Any]])?.contains{$0["name"] as? String == "read_text_file" && $0["inputSchema"] is [String:Any]} == true
            let read = try call("call_mcp_tool",["server_id":primary.id,"connection":token,"tool":"read_text_file","arguments":["path":source.path]])
            checks["readKeepsOriginalApprovalEvenInAutomaticTask"] = try tools.approvalReason(for:read) != nil
            let actual = try await tools.execute(read), expected = String(decoding:sourceBefore,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            checks["actualOfficialToolReadsIndependentPublicFile"] = !actual.failed && actual.text.contains(expected)
            report["actualRead"] = ["processID":pid,"serverID":primary.id,"source":source.path,"sourceHash":AgentFiles.hash(sourceBefore),"result":actual.text,"handshake":handshake.text]
            checks["actualConnectionTokenCannotCrossTasks"] = refused { _ = try tasks.mcp.catalog(primary.id,owner:ids["noWorkspace"]!,token:token,offset:0) }
            let noWorkspace = ids["noWorkspace"]!
            guard runtime.submit(raw,taskID:noWorkspace,startImmediately:false) else { throw PetError(runtime.submissionError ?? "无工作区连接器输入未接受") }
            let noWorkspaceTools = AgentTools(store:tasks,taskID:noWorkspace)
            _ = try await noWorkspaceTools.execute(connect)
            guard let secondToken = tasks.mcp.token(primary.id,owner:noWorkspace), let secondPID = await tasks.mcp.processID(primary.id,owner:noWorkspace) else { throw PetError("无工作区连接未建立") }
            _ = try tasks.mcp.catalog(primary.id,owner:noWorkspace,token:secondToken,offset:0,query:"read_text_file")
            let secondRead = try call("call_mcp_tool",["server_id":primary.id,"connection":secondToken,"tool":"read_text_file","arguments":["path":source.path]])
            let noWorkspaceResult = try await noWorkspaceTools.execute(secondRead)
            checks["noWorkspaceExecutesActualConnectorWithinConfiguredRoot"] = !noWorkspaceResult.failed && noWorkspaceResult.text.contains(expected) && secondToken != token && secondPID != pid && kill(secondPID,0) == 0
            report["noWorkspaceRead"] = ["processID":secondPID,"result":noWorkspaceResult.text,"sourceHash":AgentFiles.hash(sourceBefore)]
            let projectServer = try tasks.mcp.server(ids["projectServer"]!,workspace:original.workspace)
            checks["projectSelectionCannotMoveToAnotherWorkspace"] = refused { _ = try AgentMCPSelection.current(AgentMCPSelection.reference(projectServer),task:tasks.task(ids["other"]!)!,store:tasks) }
            try tasks.mcp.setEnabled(primary.id,false)
            checks["disabledSelectionBlocksDefinitionsAndSystemContext"] = refused { _ = try runtime.toolDefinitions(tasks.task(id)!,preferences:store.preferences) } && refused { _ = try runtime.systemContext(tasks.task(id)!) }
            checks["disabledSelectionBlocksPendingApproval"] = refused { _ = try tools.approvalReason(for:read) }
            let messageCount = tasks.task(id)!.messages.count; runtime.start(id)
            checks["resumeRejectsStaleSelectionBeforeStartingOrReadingCredentials"] = !runtime.isRunning(id) && runtime.submissionError != nil && tasks.task(id)?.messages.count == messageCount && attempts == 0
            do { _ = try await tools.execute(read); checks["disabledSelectionBlocksPendingExecution"] = false } catch { checks["disabledSelectionBlocksPendingExecution"] = true }
            checks["disabledRecentIsHiddenWithoutErasingHistory"] = !tasks.slashMenu.visible(tasks.slashMenu.entries([],task:tasks.task(id)!,idle:true,canChangeMode:true,connectors:AgentMCPSelection.candidates(task:tasks.task(id)!,store:tasks)),presentation:.recent,category:.recent,query:"",plugin:nil).contains{$0.id == "connector." + primary.id} && tasks.slashMenu.recentIDs.contains("connector." + primary.id)
            try tasks.mcp.setEnabled(primary.id,true); let updated = try tasks.mcp.server(primary.id)
            checks["reenablingDoesNotReviveOldSelectionOrToken"] = updated.revision != reference.revision && refused { _ = try AgentMCPSelection.current(reference,task:accepted,store:tasks) } && tasks.mcp.token(primary.id,owner:id) == nil
            for _ in 0..<30 { if kill(pid,0) != 0 { break }; await wait(0.1) }
            checks["disabledConnectorReapsActualProcess"] = kill(pid,0) != 0
            let changed = try tasks.mcp.save(tasks.mcp.document(updated),id:updated.id,expectedRevision:updated.revision)
            checks["configurationSaveInvalidatesCapturedRevision"] = changed.revision != updated.revision && refused { _ = try AgentMCPSelection.current(AgentMCPSelection.reference(updated),task:accepted,store:tasks) }
            let configuration = store.directory.appendingPathComponent("extensions/mcp.json"), originalConfig = try Data(contentsOf:configuration)
            var altered = try JSONDecoder().decode([AgentMCPServer].self,from:originalConfig); let position = altered.firstIndex{$0.id == primary.id}!; altered[position].command = "/bin/echo"
            try JSONEncoder().encode(altered).write(to:configuration)
            let alteredStore = AgentStore(directory:store.directory,legacy:[],extensionHome:output.appendingPathComponent("shared-home"))
            checks["sameRevisionMetadataChangeStillRejectsSelection"] = refused { _ = try AgentMCPSelection.current(AgentMCPSelection.reference(changed),task:accepted,store:alteredStore) }
            try originalConfig.write(to:configuration)
            checks["newOrdinaryInputCanSteerAwayWithoutErasingHistory"] = runtime.submit("保留旧记录，接下来只整理已提供的文字。",taskID:id,startImmediately:false) && (try? runtime.toolDefinitions(tasks.task(id)!,preferences:store.preferences)) != nil && tasks.task(id)?.messages.contains{$0.mcpSelection == reference} == true
            let history = store.directory.appendingPathComponent("slash-history.json"); try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:history.path)
            let second = try tasks.mcp.server(ids["second"]!), secondInput = "/" + (try AgentMCPSelection.invocation(second)) + " Read public text."
            checks["readOnlyRecentDoesNotRejectAcceptedInput"] = runtime.submit(secondInput,taskID:ids["noWorkspace"]!,startImmediately:false) && tasks.slashMenu.issue != nil && tasks.task(ids["noWorkspace"]!)?.messages.last?.mcpSelection?.id == second.id
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:history.path)
            checks["recentRetryPersistsWithoutRewritingOldMessages"] = runtime.submit(secondInput + " Retry.",taskID:ids["noWorkspace"]!,startImmediately:false) && tasks.slashMenu.issue == nil && tasks.slashMenu.recentIDs.first == "connector." + second.id
            checks["otherTaskAndPublicFilePreserved"] = try Data(contentsOf:tasks.directory.appendingPathComponent(ids["other"]! + ".json")) == otherBefore && Data(contentsOf:source) == sourceBefore
            checks["noModelRequestsOrFabricatedUsage"] = attempts == 0 && tasks.tasks.compactMap{tasks.task($0.id)}.allSatisfy{($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0}
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy{$0} && report["error"] == nil; report["appPID"] = getpid(); report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("slash-connectors-report.json"),options:.atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}
