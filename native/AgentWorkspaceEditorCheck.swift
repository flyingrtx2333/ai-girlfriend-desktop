import AppKit
import Darwin

@MainActor extension AppDelegate {
    @discardableResult func prepareWorkspaceEditorUI(_ output:URL, seed:Bool) async throws -> [String:String] {
        ensureAgent(); guard checkDirectory != nil, let tasks = agentStore else { throw PetError("缺少独立工作区编辑环境") }
        let fixture = output.appendingPathComponent("workspace-editor-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:fixture)); guard let id = ids["task"], tasks.task(id) != nil else { throw PetError("原工作区样例不可用") }; control.showAgentTask(id); control.show(tab:"chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath:fixture.path) else { throw PetError("公开样例已存在，请重开原目录") }
        let alpha = output.appendingPathComponent("Alpha workspace"), beta = output.appendingPathComponent("Beta source"), outside = output.appendingPathComponent("Outside project")
        for (folder,marker) in [(alpha,"ALPHA_PUBLIC_7319"),(beta,"BETA_PUBLIC_4086"),(outside,"OUTSIDE_PUBLIC_9264")] {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            try Data(("# Public workspace fixture\n" + marker + "\nNative acceptance data, not a model response.\n").utf8).write(to:folder.appendingPathComponent("README.md"))
        }
        for (folder,marker) in [(alpha,"ALPHA"),(beta,"BETA")] {
            let initialized = try await AgentCommand().run(command:AgentGit.executablePath(),workspace:folder,scratch:output.appendingPathComponent("tmp"),network:false,timeout:15,gitWrite:true,protectedData:store.directory,arguments:["init","--quiet","--initial-branch=main"])
            guard !initialized.failed else { throw PetError("公开 Git 边界未初始化：" + initialized.text) }
            let files = try AgentFiles(workspace:folder.path)
            try files.writeData(Data((marker + "_PROJECT_INSTRUCTION\nRead only actual public fixture facts.\n").utf8),to:files.resolve("AGENTS.md"))
            try files.writeData(Data((marker + "_NESTED_INSTRUCTION\n").utf8),to:files.resolve("notes/AGENTS.md"))
            try files.writeData(Data((marker + " public note\n").utf8),to:files.resolve("notes/public.txt"),permissions:0o640)
            try files.writeData(Data(AgentRuleDocument.text(name:"source-check",trigger:.glob,description:"",patterns:["notes/*.txt"],body:marker + "_LOCAL_SOURCE_RULE").utf8),to:files.resolve(".bluefatfish/rules/source-check.md"),permissions:0o600)
        }
        let source = output.appendingPathComponent("public-workspace-plugin")
        let pluginFiles = try [".qoder-plugin/plugin.json":Data("{\"name\":\"workspace-source\",\"version\":\"1.0.0\"}".utf8),"rules/public.md":Data(AgentRuleDocument.text(name:"public",trigger:.glob,description:"",patterns:["notes/*.txt"],body:"PLUGIN_PUBLIC_SOURCE_RULE").utf8)]
        for (path,data) in pluginFiles { let url = source.appendingPathComponent(path); try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:url) }
        let package = try await tasks.extensions.plugins.inspect(source)
        let first = try tasks.extensions.plugins.install(package,workspace:alpha.path), second = try tasks.extensions.plugins.install(package,workspace:beta.path)
        for plugin in [first,second] { try tasks.extensions.plugins.setEnabled(tasks.extensions.plugins.installation(plugin.id),true) }
        try tasks.organization.register(alpha.path,mode:.coding); try tasks.organization.register(alpha.path,mode:.general); try tasks.organization.register(outside.path,mode:.coding)
        let old = tasks.create(title:"原工作区任务（保持原范围）",workspace:alpha.path), id = tasks.create(title:"工作区编辑公开样例",workspace:alpha.path), other = tasks.create(title:"另一个项目原草稿",workspace:outside.path), general = tasks.create(title:"通用模式原文件夹",workspace:alpha.path,mode:.ask,workMode:.general)
        tasks.update(old) { $0.messages = [.init(role:"user",content:"原生公开记录：保留原范围与草稿，不请求模型。")]; $0.status = .completed; $0.draft = "保留已有任务草稿 🧭" }
        tasks.update(id) { $0.draft = "保留工作区编辑输入 🧭" }; tasks.update(other) { $0.draft = "另一项原始草稿" }; tasks.update(general) { $0.draft = "通用模式原输入" }
        let ids = ["task":id,"old":old,"other":other,"general":general,"alpha":alpha.path,"beta":beta.path,"outside":outside.path,"alphaPlugin":first.id,"betaPlugin":second.id]
        try JSONEncoder().encode(ids).write(to:fixture); control.showAgentTask(id); control.show(tab:"chat"); return ids
    }
    func workspaceEditorReadback() -> [String:Any] {
        guard checkDirectory != nil, let tasks = agentStore else { return [:] }
        return ["entries":AgentWorkMode.allCases.flatMap { mode in tasks.organization.directories(mode,tasks:tasks.tasks,includingArchived:true).map { ["group":$0.path,"mode":mode.rawValue,"name":$0.title,"folders":$0.sourceFolders,"primary":$0.primary,"icon":($0.icon ?? .folder).rawValue,"color":($0.color ?? .forest).rawValue] as [String:Any] } },"tasks":tasks.tasks.compactMap{tasks.task($0.id)}.map{["id":$0.id,"group":$0.organizationWorkspace ?? "","primary":$0.workspace ?? "","folders":$0.workspacePaths,"draft":$0.draft ?? "","messages":$0.messages.count] as [String:Any]}]
    }
    func runWorkspaceEditorCheck(_ output:URL) async {
        var checks:[String:Bool] = [:], report:[String:Any] = [:], attempts = 0
        func refused(_ body:() throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        func call(_ name:String,_ object:[String:Any]) throws -> AgentToolCall { .init(id:UUID().uuidString,name:name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self)) }
        func find<T:NSView>(_ type:T.Type,_ view:NSView?,_ predicate:(T)->Bool) -> T? { guard let view else { return nil }; if let value = view as? T, predicate(value) { return value }; for child in view.subviews { if let value = find(type,child,predicate) { return value } }; return nil }
        func button(_ label:String,_ sheet:NSWindow) throws -> NSButton { guard let value = find(NSButton.self,sheet.contentView,{$0.title == label || $0.accessibilityLabel() == label}) else { throw PetError("缺少操作：" + label) }; return value }
        func closed(_ host:NSWindow) async throws { for _ in 0..<100 { if host.attachedSheet == nil { return }; await wait(0.02) }; throw PetError("工作区表单未关闭") }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime, let host = control.window else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("工作区编辑原生验收禁止模型请求") }; defer { runtime.stopAll(); if let sheet = host.attachedSheet { host.endSheet(sheet) } }
            let ids = try await prepareWorkspaceEditorUI(output,seed:true), alpha = ids["alpha"]!, beta = ids["beta"]!, outside = ids["outside"]!, original = tasks.task(ids["old"]!)!
            checks["independentWorkspaceCheckUsesOnlyItsOwnProfile"] = usesAgent && tasks.extensions.sharedHome?.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").resolvingSymlinksInPath()
            let oldFile = tasks.directory.appendingPathComponent(original.id + ".json"), oldBytes = try Data(contentsOf:oldFile), otherFile = tasks.directory.appendingPathComponent(ids["other"]! + ".json"), otherBytes = try Data(contentsOf:otherFile)
            let sourceA = URL(fileURLWithPath:alpha).appendingPathComponent("notes/public.txt"), sourceB = URL(fileURLWithPath:beta).appendingPathComponent("notes/public.txt"), beforeA = try Data(contentsOf:sourceA), beforeB = try Data(contentsOf:sourceB)
            let entry = tasks.organization.entry(alpha,mode:.coding,tasks:tasks.tasks)!
            checks["legacyWorkspaceHasOneDefaultSourceAndNoTaskMigration"] = entry.sourceFolders == [alpha] && entry.primary == alpha && entry.scope == nil && original.workspaceScope == nil
            for (name,paths,main) in [("empty",[String](),alpha),("duplicate",[alpha,alpha],alpha),("missing-main",[alpha,beta],outside),("nested",[alpha,alpha + "/notes"],alpha),("filesystem-root",["/"],"/")] { checks["invalidSourcesRejected-" + name] = refused { _ = try AgentWorkspaceScope.validateFolders(paths,primary:main) } }
            try tasks.organization.editWorkspace(entry,name:"公开双目录工作区",icon:.cup,color:.blue,folders:[alpha,beta],primary:beta,tasks:tasks.tasks)
            let configured = tasks.organization.entry(alpha,mode:.coding,tasks:tasks.tasks)!, id = try tasks.createWorkspaceTask(alpha,mode:.coding,title:"双目录实际工具检查"), tools = AgentTools(store:tasks,taskID:id)
            checks["newTaskUsesPrimaryWithStableGroupAndAllSources"] = tasks.task(id)?.workspace == beta && tasks.task(id)?.organizationWorkspace == alpha && tasks.task(id)?.workspacePaths == [alpha,beta]
            checks["oldTasksKeepTheirExactRecordsAndOriginalBounds"] = try Data(contentsOf:oldFile) == oldBytes && original.workspaceScope == nil && refused { _ = try AgentWorkspaceScope.location(original,path:sourceB.path) }
            checks["generalModeConfigurationIsIndependent"] = tasks.organization.entry(alpha,mode:.general,tasks:tasks.tasks)?.sourceFolders == [alpha] && tasks.task(ids["general"]!)?.workspaceScope == nil
            checks["staleEditorCannotOverwriteNewConfiguration"] = refused { try tasks.organization.editWorkspace(entry,name:"stale",icon:.folder,color:.red,folders:[alpha],primary:alpha,tasks:tasks.tasks) }
            try tasks.organization.register(beta,mode:.coding); try tasks.setWorkspaceArchived(beta,mode:.coding,archived:true)
            tasks.update(id) { $0.draft = "主目录独立归档不影响当前工作区" }
            let relatedBranch = tasks.fork(id), side = try tasks.sideTasks.create(parentID:id)
            checks["archivedIndependentPrimaryDoesNotArchiveOrBlockRelatedWorkspace"] = tasks.task(id)?.archived == false && relatedBranch != nil && tasks.task(side)?.archived == false
            checks["sideTaskKeepsTheFrozenGroupAndSourceFolders"] = tasks.task(side)?.workspaceScope == tasks.task(id)?.workspaceScope && tasks.task(side)?.organizationWorkspace == alpha
            try tasks.setWorkspaceArchived(beta,mode:.coding,archived:false)
            tasks.update(id) { $0.messages = [.init(role:"user",content:"原生双目录读写验收，不请求模型。")]; $0.status = .completed }
            let context = try runtime.systemContext(tasks.task(id)!)
            checks["modelContextListsEveryRootAndBothProjectInstructions"] = context.contains(alpha) && context.contains(beta) && context.contains("ALPHA_PROJECT_INSTRUCTION") && context.contains("BETA_PROJECT_INSTRUCTION")
            let relative = try await tools.execute(call("read_file",["path":"README.md"]))
            let secondary = try await tools.execute(call("read_file",["path":sourceA.path]))
            checks["relativeReadUsesPrimaryAndAbsoluteReadUsesSecondary"] = relative.text.contains("BETA_PUBLIC_4086") && secondary.text.contains("ALPHA public note") && !secondary.text.contains("未载入") && !secondary.text.contains("未保存")
            checks["secondaryNestedInstructionsAndLocalPluginRulesLoad"] = try runtime.systemContext(tasks.task(id)!).contains("ALPHA_NESTED_INSTRUCTION") && runtime.systemContext(tasks.task(id)!).contains("ALPHA_LOCAL_SOURCE_RULE") && runtime.systemContext(tasks.task(id)!).contains("PLUGIN_PUBLIC_SOURCE_RULE")
            checks["outsideRootAndSymlinkCannotExpandTask"] = refused { _ = try AgentWorkspaceScope.location(tasks.task(id)!,path:outside + "/README.md") }
            let link = URL(fileURLWithPath:alpha).appendingPathComponent("outside-link"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:URL(fileURLWithPath:outside))
            checks["actualOutsideSymlinkIsRejected"] = refused { _ = try AgentWorkspaceScope.location(tasks.task(id)!,path:link.appendingPathComponent("README.md").path) }
            let command = "pwd; cat " + AgentGit.quote(sourceA.path) + "; cat " + AgentGit.quote(sourceB.path)
            let terminal = try await tools.execute(call("run_command",["command":command,"timeout_seconds":15]))
            checks["actualTerminalStartsInPrimaryAndReadsBothSources"] = !terminal.failed && terminal.text.contains(beta) && terminal.text.contains("ALPHA public note") && terminal.text.contains("BETA public note")
            report["actualTerminal"] = terminal.text
            let denied = try await tools.execute(call("run_command",["command":"cat " + AgentGit.quote(outside + "/README.md"),"timeout_seconds":10]))
            checks["actualTerminalDeniesUnselectedDirectory"] = denied.failed && !denied.text.contains("OUTSIDE_PUBLIC_9264")
            _ = try await tools.execute(call("write_file",["path":sourceA.path,"content":"changed alpha\n"]))
            _ = try await tools.execute(call("write_file",["path":sourceB.path,"content":"changed beta\n"]))
            checks["bothActualWritesHaveCheckpoints"] = try tasks.task(id)?.changes.filter{$0.beforeHash != nil && $0.afterHash != nil}.count == 2 && Data(contentsOf:sourceA) == Data("changed alpha\n".utf8) && Data(contentsOf:sourceB) == Data("changed beta\n".utf8)
            let turn = tasks.task(id)!.messages.first!.id, review = try AgentRoundRollback.review(taskID:id,from:turn,store:tasks)
            checks["oneReviewCoversBothSourceDirectories"] = review.canApply && Set(review.paths) == [sourceA.path,sourceB.path]
            try AgentRoundRollback.apply(review,store:tasks)
            checks["actualRoundRollbackRestoresBothFilesAndPermissions"] = try Data(contentsOf:sourceA) == beforeA && Data(contentsOf:sourceB) == beforeB && FileManager.default.attributesOfItem(atPath:sourceA.path)[.posixPermissions] as? NSNumber == 0o640
            tasks.update(id) { $0.mode = .ask }
            checks["askModeStillRejectsFileWritesInSecondary"] = refused { _ = try tools.approvalReason(for:call("write_file",["path":sourceA.path,"content":"blocked"])) }
            let readOnly = try await tools.execute(call("run_command",["command":"printf blocked > " + AgentGit.quote(sourceA.path),"timeout_seconds":10]))
            checks["actualReadOnlyTerminalCannotWriteSecondary"] = try readOnly.failed && Data(contentsOf:sourceA) == beforeA
            tasks.update(id) { $0.mode = .agent }
            let fork = tasks.fork(id)
            checks["branchKeepsFrozenFolderSetAndGroup"] = fork.flatMap(tasks.task)?.workspaceScope == tasks.task(id)?.workspaceScope && fork.flatMap(tasks.task)?.organizationWorkspace == alpha
            let scoped = tasks.task(id)!.workspaceScope!, privateMarker = store.directory.appendingPathComponent("private-public-marker.txt"); try Data("PRIVATE_APP_FIXTURE_5718".utf8).write(to:privateMarker)
            var privateScope = scoped; privateScope.folders = [beta,store.directory.path]
            let privateID = tasks.create(title:"应用资料保护",workspace:beta,workspaceScope:privateScope), privateTools = AgentTools(store:tasks,taskID:privateID)
            checks["selectedFolderDoesNotAuthorizePrivateApplicationFiles"] = refused { _ = try privateTools.approvalReason(for:call("read_file",["path":privateMarker.path])) }
            let privateCommand = try await privateTools.execute(call("run_command",["command":"cat " + AgentGit.quote(privateMarker.path),"timeout_seconds":10]))
            checks["actualTerminalKeepsPrivateDataDenyAcrossAdditionalRoots"] = privateCommand.failed && !privateCommand.text.contains("PRIVATE_APP_FIXTURE_5718")
            try tasks.setWorkspaceArchived(alpha,mode:.coding,archived:true)
            checks["archiveUsesStableGroupIncludingOtherPrimaryFolders"] = tasks.task(id)?.archived == true && tasks.task(original.id)?.archived == true && tasks.task(ids["general"]!)?.archived == false
            try tasks.setWorkspaceArchived(alpha,mode:.coding,archived:false)
            checks["restorePreservesFrozenScopeAndGeneralMode"] = tasks.task(id)?.workspaceScope == scoped && tasks.task(id)?.archived == false && tasks.task(ids["general"]!)?.archived == false
            let reopened = AgentStore(directory:store.directory,legacy:[],extensionHome:output.appendingPathComponent("shared-home"))
            checks["workspaceAppearanceSourcesAndTaskScopeReopen"] = reopened.organization.entry(alpha,mode:.coding,tasks:reopened.tasks) == configured && reopened.task(id)?.workspaceScope == scoped
            control.showAgentTask(ids["task"]!); control.checkNameEditor("directory",id:alpha)
            guard let sheet = host.attachedSheet, let name = find(NSTextField.self,sheet.contentView,{$0.accessibilityLabel() == "工作区名称"}) else { throw PetError("完整工作区编辑表单未打开") }
            checks["nativeEditorUsesOwnedStyledSheet"] = sheet.isVisible && sheet.contentView is AgentThemeView && NSApp.modalWindow == nil && name.currentEditor() != nil
            sheet.contentView?.layoutSubtreeIfNeeded()
            checks["shortFormStartsAtTopAndHasUsableWidth"] = name.bounds.width >= 420 && name.superview?.superview?.isFlipped == true && abs(name.superview?.frame.minY ?? -100) < 1 && !name.hasAmbiguousLayout
            checks["parentCannotCloseOverWorkspaceEditor"] = !control.windowShouldClose(host)
            let dataBeforeCancel = try Data(contentsOf:store.directory.appendingPathComponent("organization.json"))
            try button("设为主文件夹：" + alpha,sheet).performClick(nil); name.stringValue = "未保存工作区"
            try button("取消",sheet).performClick(nil); try await closed(host)
            checks["cancelKeepsConfigurationAndOriginalTaskDraft"] = try Data(contentsOf:store.directory.appendingPathComponent("organization.json")) == dataBeforeCancel && tasks.task(ids["task"]!)?.draft == "保留工作区编辑输入 🧭"
            control.checkNameEditor("directory",id:alpha)
            guard let saved = host.attachedSheet, let field = find(NSTextField.self,saved.contentView,{$0.accessibilityLabel() == "工作区名称"}) else { throw PetError("表单未能重开") }
            field.stringValue = "原生表单保存的工作区"; try button("图标：帆船",saved).performClick(nil); try button("颜色：橙色",saved).performClick(nil); try button("设为主文件夹：" + alpha,saved).performClick(nil)
            let profile = store.directory, profileMode = try FileManager.default.attributesOfItem(atPath:profile.path)[.posixPermissions] as! NSNumber
            let beforeFailure = try Data(contentsOf:profile.appendingPathComponent("organization.json"))
            try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:profile.path)
            do {
                defer { try? FileManager.default.setAttributes([.posixPermissions:profileMode],ofItemAtPath:profile.path) }
                try button("保存",saved).performClick(nil)
                let error = find(NSTextField.self,saved.contentView,{$0.accessibilityLabel() == "工作区保存状态"})
                checks["failedSaveKeepsEveryFieldAndOriginalConfiguration"] = try host.attachedSheet === saved && error?.stringValue.isEmpty == false && field.stringValue == "原生表单保存的工作区" && Data(contentsOf:profile.appendingPathComponent("organization.json")) == beforeFailure && tasks.organization.entry(alpha,mode:.coding,tasks:tasks.tasks) == configured
            }
            try button("保存",saved).performClick(nil); try await closed(host)
            checks["nativeSavePersistsAllFieldsWithoutChangingOldTaskScope"] = tasks.organization.entry(alpha,mode:.coding,tasks:tasks.tasks)?.icon == .sailboat && tasks.organization.entry(alpha,mode:.coding,tasks:tasks.tasks)?.color == .orange && tasks.organization.entry(alpha,mode:.coding,tasks:tasks.tasks)?.primary == alpha && tasks.task(id)?.workspaceScope == scoped
            let next = try tasks.createWorkspaceTask(alpha,mode:.coding)
            checks["newTaskUsesEditedPrimaryAndOldTaskRetainsPreviousPrimary"] = tasks.task(next)?.workspace == alpha && tasks.task(next)?.workspacePaths == [alpha,beta] && tasks.task(id)?.workspace == beta
            checks["unrelatedTaskAndPublicSourceFilesPreserved"] = try Data(contentsOf:otherFile) == otherBytes && Data(contentsOf:sourceA) == beforeA && Data(contentsOf:sourceB) == beforeB
            checks["noModelRequestsOrFabricatedUsage"] = attempts == 0 && tasks.tasks.compactMap{tasks.task($0.id)}.allSatisfy{($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 && !$0.messages.contains{$0.role == "assistant"}}
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy{$0} && report["error"] == nil; report["appPID"] = getpid(); report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("workspace-editor-report.json"),options:.atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}
