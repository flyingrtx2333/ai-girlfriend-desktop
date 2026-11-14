import AppKit
import Darwin

@MainActor extension AppDelegate {
    private func workspaceSkillCall(_ name:String, _ object:[String:Any] = [:]) throws -> AgentToolCall {
        .init(id:UUID().uuidString,name:name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self))
    }
    @discardableResult func prepareWorkspaceSkillEvolutionUI(_ output:URL, seed:Bool) async throws -> [String:String] {
        ensureAgent(); guard let tasks = agentStore, let service = agentRuntime?.skillEvolution else { throw PetError("缺少独立多目录 Skill 环境") }
        let file = output.appendingPathComponent("workspace-skill-evolution-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:file))
            guard let id = ids["task"], tasks.task(id) != nil else { throw PetError("原多目录 Skill 资料不存在") }
            control.showAgentTask(id); control.show(tab:"chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath:file.path) else { throw PetError("公开样例已存在，请重开原目录") }
        var ids = try await prepareWorkspaceCapabilitiesUI(output,seed:true)
        let alpha = ids["alpha"]!, beta = ids["beta"]!, main = ids["task"]!, context = tasks.task(main)!
        let target = try tasks.extensions.item(ids["alphaSkill"]!,task:context), files = try AgentFiles(workspace:target.root.path)
        try files.writeData(Data([0,255,34,128]),to:files.resolve("assets/sample.bin"),permissions:0o640)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:target.root.appendingPathComponent("scripts/read-source.mjs").path)
        let betaConflict = try tasks.extensions.create(.skill,name:"public-workspace-flow",text:"---\nname: public-workspace-flow\ndescription: Existing Beta public workflow\n---\nBETA_CONFLICT_UNCHANGED\n",project:true,workspace:beta)
        let outside = try tasks.extensions.create(.skill,name:"outside-evolution",text:"---\nname: outside-evolution\ndescription: Unselected public source\n---\nOUTSIDE_SKILL_UNCHANGED\n",project:true,workspace:ids["outside"]!)
        ids["betaConflict"] = betaConflict.id; ids["outsideSkill"] = outside.id
        func prepareSource(_ id:String, title:String) async throws {
            let call = try workspaceSkillCall("read_file",["path":alpha + "/README.md"]), result = try await AgentTools(store:tasks,taskID:id).execute(call)
            guard !result.failed else { throw PetError("公开文件实际读取失败") }
            tasks.update(id) { task in
                task.title = title; task.status = .completed; task.draft = "保留多目录技能原始要求 🧭"
                task.messages = [.init(role:"user",content:"公开原生样例：核对两个已选目录，并保留各自可复用流程。"),.init(role:"assistant",content:"",toolCalls:[call]),.init(role:"tool",content:result.text,toolCallID:call.id),.init(role:"assistant",content:"原生界面样例，不是模型输出：已用实际工具读取 Alpha README；后续建议与草稿仅用于本机流程验收。")]
                task.events = [.init(kind:"tool",title:"read_file",status:"completed",toolCallID:call.id)]
            }
        }
        try await prepareSource(main,title:"多目录 Skill 建议公开验收")
        let drafts = tasks.create(title:"多目录原生草稿来源",workspace:beta,workspaceScope:context.workspaceScope)
        try await prepareSource(drafts,title:"多目录原生草稿来源")
        var preferences = store.preferences; preferences.contextTokens = 8192; preferences.replyTokens = 512
        func save(_ id:String, _ items:[AgentSkillEvolutionSuggestion]) throws {
            let task = tasks.task(id)!, brief = try AgentSkillEvolution.input(task,targets:service.targets(task),preferences:preferences,secret:"")
            try service.save(items,id:id,source:AgentSkillEvolution.source(task)!,model:"native-fixture",brief:brief)
        }
        func suggestion(_ id:String, _ title:String, target:AgentSkillEvolutionTarget? = nil) -> AgentSkillEvolutionSuggestion {
            .init(title:title,reason:"公开原生样例，核对实际来源与保存位置。",goal:title + "；先确认方案，再审阅实际文件变化。",target:target,evidence:[tasks.task(id)!.messages.last!.id])
        }
        let descriptors = try service.targets(tasks.task(main)!), a = descriptors.first{$0.id == ids["alphaSkill"]}!, b = descriptors.first{$0.id == ids["betaSkill"]}!
        try save(main,[suggestion(main,"改进 Alpha 核对步骤",target:a),suggestion(main,"改进 Beta 核对步骤",target:b),suggestion(main,"整理新的公开 Skill")])
        let update = suggestion(drafts,"原生 Alpha 更新草稿",target:a), create = suggestion(drafts,"原生多目录新建草稿")
        try save(drafts,[update,create]); _ = try service.curate([update.id,create.id],taskID:drafts,source:AgentSkillEvolution.source(tasks.task(drafts)!)!,adopt:true)
        func stage(_ id:String, updating:Bool) async throws {
            tasks.update(id) { task in
                task.messages = [.init(role:"user",content:task.skillEvolutionJob!.goal),.init(role:"assistant",content:"原生方案样例，不是模型输出：保留权限与旧资源，准备公开说明、资源和脚本，审阅后才保存。")]
                task.status = .completed; task.draft = ""
            }
            try AgentSkillDrafts.approvePlan(id,source:AgentSkillDrafts.planSource(tasks.task(id)!)!,store:tasks)
            tasks.update(id) { $0.messages.append(.init(role:"user",content:"确认此公开原生方案，仅准备待审阅草稿。")); $0.status = .ready }
            let task = tasks.task(id)!, original = try AgentSkillDrafts.base(task.skillEvolutionJob!,store:tasks,task:task)
            let document = updating ? String(decoding:original["SKILL.md"]!,as:UTF8.self) + "\n## PUBLIC_ALPHA_UPDATED\nRead the actual source and retain the original trigger settings.\n" : "---\nname: public-workspace-flow\ndescription: Public source workflow in an explicitly selected folder\n---\n# NEW_ALPHA_DOCUMENT\nRead references/source.txt and preserve the selected source.\n"
            let program = "import fs from 'node:fs';console.log(JSON.stringify({cwd:fs.realpathSync('.'),source:fs.readFileSync(new URL('../references/source.txt',import.meta.url),'utf8').trim(),marker:'\(updating ? "PUBLIC_ALPHA_UPDATED" : "NEW_ALPHA_FLOW")',pid:process.pid}));\n"
            let staged = ["SKILL.md":document,"references/source.txt":updating ? "ALPHA_LOCAL_SKILL_RESOURCE_V2\n" : "NEW_ALPHA_RESOURCE\n","scripts/read-source.mjs":program,"templates/result.txt":"Source:\nActual result:\n"]
            let tools = AgentTools(store:tasks,taskID:id)
            for path in staged.keys.sorted() {
                var args:[String:Any] = ["path":path,"content":staged[path]!]; if let old = original[path] { args["expected_hash"] = AgentFiles.hash(old) }
                _ = try await tools.execute(workspaceSkillCall("draft_skill",args))
            }
            tasks.update(id) { $0.messages.append(.init(role:"assistant",content:"原生草稿样例，不是模型输出：公开草稿已准备，尚未修改已安装 Skill。")); $0.status = .completed }
        }
        try await stage(update.id,updating:true); try await stage(create.id,updating:false)
        ids["draftSource"] = drafts; ids["update"] = update.id; ids["create"] = create.id; ids["modelOutputsCreated"] = "false"
        try JSONEncoder().encode(ids).write(to:file); control.showAgentTask(main); control.show(tab:"chat"); return ids
    }

    func workspaceSkillEvolutionReadback() -> [String:Any] {
        guard let tasks = agentStore, let service = agentRuntime?.skillEvolution else { return [:] }
        return ["records":tasks.tasks.compactMap{tasks.task($0.id)}.map { task in
            ["id":task.id,"primary":task.workspace ?? "","folders":task.workspacePaths,"draft":task.draft ?? "","source":AgentSkillEvolution.source(task) ?? "","titles":service.targetTitles(task,targets:service.items(task).compactMap(\.target)),"jobSource":task.skillEvolutionJob?.sourceTaskID ?? "","target":task.skillEvolutionJob?.target?.id ?? "","savedID":task.skillDraft?.savedID ?? ""] as [String:Any]
        }]
    }

    func runWorkspaceSkillEvolutionCheck(_ output:URL) async {
        var checks:[String:Bool] = [:], report:[String:Any] = [:], attempts = 0, pids:[Int32] = []
        func refused(_ action:() throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        func find<T:NSView>(_ type:T.Type, _ view:NSView?, _ matches:(T)->Bool) -> T? {
            guard let view else { return nil }; if let value = view as? T, matches(value) { return value }
            for child in view.subviews { if let value = find(type,child,matches) { return value } }; return nil
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            let service = runtime.skillEvolution
            runtime.modelRequestCheck = { attempts += 1; throw PetError("多目录 Skill 原生验收禁止模型请求") }
            service.requestCheck = { attempts += 1; throw PetError("多目录 Skill 原生验收禁止辅助请求") }
            defer { runtime.stopAll() }
            let ids = try await prepareWorkspaceSkillEvolutionUI(output,seed:true), main = ids["task"]!, alpha = ids["alpha"]!, beta = ids["beta"]!, outside = ids["outside"]!
            let original = tasks.task(main)!, scope = original.workspaceScope!, choices = try service.targets(original), source = AgentSkillEvolution.source(original)!
            let descriptors = choices.filter{$0.name == "source-probe"}, titles = service.targetTitles(original,targets:descriptors)
            checks["allSelectedSourcesExposeDistinctSameNamedEditableTargets"] = descriptors.count == 2 && Set(descriptors.map(\.id)) == Set([ids["alphaSkill"]!,ids["betaSkill"]!])
            checks["globalTargetsDeduplicateAndUnselectedOrPackagedTargetsStayOut"] = choices.filter{$0.name == "public-global"}.count == 1 && !choices.contains{$0.id == ids["outsideSkill"] || $0.name.contains(":")}
            checks["sameNamedTargetTitlesIdentifyTheirOwnReadableSources"] = titles[ids["alphaSkill"]!]?.contains("Alpha workspace") == true && titles[ids["betaSkill"]!]?.contains("Beta source") == true
            let input = try AgentSkillEvolution.input(original,targets:choices,preferences:store.preferences,secret:""), inputObject = try JSONSerialization.jsonObject(with:Data(input.utf8)) as! [String:Any], sent = inputObject["targets"] as! [[String:String]]
            checks["actualTargetDescriptorsDistinguishSourcesWithoutAbsoluteMachinePaths"] = sent.contains{$0["id"] == ids["alphaSkill"] && $0["description"]?.contains("Alpha workspace") == true} && sent.contains{$0["id"] == ids["betaSkill"] && $0["description"]?.contains("Beta source") == true} && !sent.flatMap{$0.values}.joined().contains(output.path)
            checks["nativeFixturesCannotTriggerUnrecordedModelAnalysis"] = !service.generate(main,preferences:store.preferences,key:"",replacing:true) && attempts == 0
            var changedScope = original; changedScope.workspaceScope?.folders = [beta]
            checks["sourceHashIncludesAllFrozenFoldersAndKeepsNewMultiSourceVersion"] = source.hasPrefix(AgentSkillEvolution.workspaceSourcePrefix) && AgentSkillEvolution.source(changedScope) != source
            var single = original; single.workspaceScope = nil
            let oldHash = AgentFiles.hash(try JSONEncoder().encode([AgentPromptSuggestions.source(single)!] + AgentSkillEvolution.sources(single).flatMap{[$0.id,$0.text]}))
            checks["legacySingleSourceHashRetainsItsExactOriginalFormat"] = AgentSkillEvolution.source(single) == oldHash && oldHash.count == 64
            let a = descriptors.first{$0.id == ids["alphaSkill"]}!, updateID = ids["update"]!, createID = ids["create"]!, child = tasks.task(updateID)!, creation = tasks.task(createID)!
            checks["adoptedChildrenKeepPrimaryFoldersPlanApprovalAndIndependentRoles"] = [child,creation].allSatisfy { record in
                let sourceMatches = record.workspace == beta && record.workspaceScope == scope && record.parentID == ids["draftSource"]
                let independent = record.agent == nil && record.team == nil && record.permission == .review
                return sourceMatches && independent && record.skillEvolutionJob?.workspace == beta
            }
            var dropped = creation; dropped.workspaceScope = nil
            var broadened = creation; broadened.workspaceScope?.folders.append(outside)
            checks["newJobsCannotDropOrBroadenTheirFrozenSourceSnapshot"] = refused{_ = try AgentSkillDrafts.job(dropped,store:tasks)} && refused{_ = try AgentSkillDrafts.job(broadened,store:tasks)}
            checks["secondaryTargetResolvesOnlyInsideItsActualTaskRoots"] = try AgentSkillDrafts.currentTarget(a,task:original,store:tasks).item.file.path.hasPrefix(alpha + "/") && refused{_ = try AgentSkillDrafts.currentTarget(a,workspace:beta,store:tasks)} && refused{_ = try AgentSkillDrafts.currentTarget(a,task:single,store:tasks)}
            let beforeTasks = tasks.tasks.count, sourceFile = tasks.directory.appendingPathComponent(main + ".json"), sourceBytes = try Data(contentsOf:sourceFile), external = try tasks.extensions.item(ids["outsideSkill"]!,workspace:outside)
            let invalid = try AgentSkillEvolutionSuggestion(title:"未选来源",reason:"公开边界检查",goal:"不得写入",target:.init(id:external.id,name:external.name,documentHash:external.sha256,bundleHash:AgentExtensions.digest(AgentExtensions.resourceData(AgentFiles(workspace:external.root.path)))),evidence:[original.messages.last!.id])
            checks["unselectedTargetCannotEnterSavedSuggestionsOrCreateRecords"] = try refused{try service.save([invalid],id:main,source:source,model:"native-fixture",brief:input)} && tasks.tasks.count == beforeTasks && Data(contentsOf:sourceFile) == sourceBytes
            let childTools = AgentTools(store:tasks,taskID:updateID), actualRead = try await childTools.execute(workspaceSkillCall("read_skill_source",["path":"references/source.txt"]))
            checks["improvementToolActuallyReadsSecondarySourceResource"] = !actualRead.failed && actualRead.text.contains("ALPHA_LOCAL_SKILL_RESOURCE") && !actualRead.text.contains("BETA_LOCAL_SKILL_RESOURCE")
            var outsideRead = ""
            do { outsideRead = try await childTools.execute(workspaceSkillCall("read_file",["path":outside + "/README.md"])).text }
            catch { outsideRead = error.localizedDescription }
            checks["actualFileReadCannotEscapeTheFrozenSourceFolders"] = outsideRead.contains("源文件夹") && !outsideRead.contains("OUTSIDE_PUBLIC")
            let forbidden = ["write_file","run_command","connect_mcp","delegate_task"]
            checks["multiSourceImprovementKeepsItsRestrictedToolSet"] = forbidden.allSatisfy { name in refused{try AgentSkillDrafts.check(workspaceSkillCall(name),task:child,store:tasks)} }
            let target = try tasks.extensions.item(ids["alphaSkill"]!,task:child), targetFiles = try AgentFiles(workspace:target.root.path), before = try AgentExtensions.resourceData(targetFiles), betaItem = try tasks.extensions.item(ids["betaSkill"]!,task:child), betaBefore = try AgentExtensions.resourceData(AgentFiles(workspace:betaItem.root.path))
            let draft = child.skillDraft!, draftFile = tasks.directory.appendingPathComponent(updateID + ".json"), draftBytes = try Data(contentsOf:draftFile), revision = AgentSkillDrafts.revision(draft)
            checks["preparingDraftHasNotChangedInstalledSecondaryFiles"] = before["references/source.txt"] == Data("ALPHA_LOCAL_SKILL_RESOURCE\n".utf8) && before["assets/sample.bin"] == Data([0,255,34,128])
            control.showAgentTask(updateID); control.show(tab:"chat"); try control.reviewSkillDraft(taskID:updateID)
            guard let host = control.window, let updateScope = find(NSPopUpButton.self,host.contentView,{$0.identifier?.rawValue == "skill-review-scope"}), let updateName = find(NSTextField.self,host.contentView,{$0.identifier?.rawValue == "skill-review-name"}) else { throw PetError("未打开实际 Alpha 改进审阅页") }
            checks["actualExistingReviewLocksNameAndExactSecondaryDestination"] = !updateScope.isEnabled && updateScope.selectedItem?.representedObject as? String == alpha && !updateName.isEditable && updateName.stringValue == target.name && control.settingsSourceReadback()["source"] as? String == alpha
            let normal = host.frame; host.setFrame(NSRect(origin:normal.origin,size:NSSize(width:780,height:540)),display:true); await wait(0.1); host.contentView?.layoutSubtreeIfNeeded()
            checks["actualMultiSourceReviewFits780PointWindow"] = abs(host.frame.width - 780) < 0.5 && updateScope.convert(updateScope.bounds,to:host.contentView).maxX <= 780
            host.setFrame(normal,display:true)
            checks["staleRevisionAndOtherSelectedDirectoryCannotRetargetUpdate"] = refused{_ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:"stale",name:target.name,project:true,store:tasks,workspace:alpha)} && refused{_ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:revision,name:target.name,project:true,store:tasks,workspace:beta)}
            try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:draftFile.path)
            let deniedReceipt = refused{_ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:revision,name:target.name,project:true,store:tasks,workspace:alpha)}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:draftFile.path)
            checks["unwritableTaskReceiptRollsBackEverySecondaryFile"] = try deniedReceipt && Data(contentsOf:draftFile) == draftBytes && AgentExtensions.resourceData(targetFiles) == before
            let resource = target.root.appendingPathComponent("references/source.txt"), conflict = Data("ACTUAL_EXTERNAL_RESOURCE_CHANGE\n".utf8)
            try conflict.write(to:resource)
            checks["secondaryResourceConflictPreservesExternalBytesAndOriginalDraft"] = try refused{_ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:revision,name:target.name,project:true,store:tasks,workspace:alpha)} && Data(contentsOf:resource) == conflict && Data(contentsOf:draftFile) == draftBytes
            try before["references/source.txt"]!.write(to:resource)
            guard let applyUpdate = find(NSButton.self,host.contentView,{$0.title == "应用改进" && $0.isEnabled}) else { throw PetError("实际改进应用按钮不可用") }; applyUpdate.performClick(nil)
            guard let saved = tasks.task(updateID)?.skillDraft?.savedID else { throw PetError("实际改进未保存") }
            let after = try AgentExtensions.resourceData(targetFiles)
            checks["explicitUpdateWritesOnlyOriginalSecondarySkillAndKeepsBinaryAndModes"] = try saved == target.id && after["references/source.txt"] == Data("ALPHA_LOCAL_SKILL_RESOURCE_V2\n".utf8) && after["assets/sample.bin"] == before["assets/sample.bin"] && (FileManager.default.attributesOfItem(atPath:target.root.appendingPathComponent("scripts/read-source.mjs").path)[.posixPermissions] as? NSNumber)?.intValue == 0o700 && AgentExtensions.resourceData(AgentFiles(workspace:betaItem.root.path)) == betaBefore
            checks["updatedTaskKeepsOriginalPrimaryAndFrozenGroup"] = tasks.task(updateID)?.workspace == beta && tasks.task(updateID)?.workspaceScope == scope && tasks.task(updateID)?.skillDraft?.savedID == target.id
            guard let draftSource = ids["draftSource"], let sourceTask = tasks.task(draftSource) else { throw PetError("缺少原建议来源") }
            checks["repeatedAdoptionReturnsOriginalChildrenWithoutDuplicates"] = try Set(service.curate([updateID,createID],taskID:draftSource,source:AgentSkillEvolution.source(sourceTask)!,adopt:true)) == Set([updateID,createID]) && tasks.tasks.count == beforeTasks
            let creationDraft = creation.skillDraft!, creationBytes = try Data(contentsOf:tasks.directory.appendingPathComponent(createID + ".json")), creationRevision = AgentSkillDrafts.revision(creationDraft), conflictItem = try tasks.extensions.item(ids["betaConflict"]!,task:creation), conflictBefore = try AgentExtensions.resourceData(AgentFiles(workspace:conflictItem.root.path))
            checks["outsideDestinationCannotSaveOrChangeDraft"] = refused{_ = try AgentSkillDrafts.apply(taskID:createID,draftID:creationDraft.id,revision:creationRevision,name:"public-workspace-flow",project:true,store:tasks,workspace:outside)}
            checks["defaultPrimaryCollisionAndGlobalShadowingAreRejected"] = refused{_ = try AgentSkillDrafts.apply(taskID:createID,draftID:creationDraft.id,revision:creationRevision,name:"public-workspace-flow",project:true,store:tasks)} && refused{_ = try AgentSkillDrafts.apply(taskID:createID,draftID:creationDraft.id,revision:creationRevision,name:"public-workspace-flow",project:false,store:tasks)}
            checks["rejectedDestinationsKeepOriginalDraftAndExistingPrimarySkill"] = try Data(contentsOf:tasks.directory.appendingPathComponent(createID + ".json")) == creationBytes && AgentExtensions.resourceData(AgentFiles(workspace:conflictItem.root.path)) == conflictBefore && !FileManager.default.fileExists(atPath:outside + "/.bluefatfish/skills/public-workspace-flow")
            control.showAgentTask(createID); control.show(tab:"chat"); try control.reviewSkillDraft(taskID:createID)
            guard let selector = find(NSPopUpButton.self,host.contentView,{$0.identifier?.rawValue == "skill-review-scope"}) else { throw PetError("缺少实际保存目录选择器") }
            checks["actualReviewOffersEveryFrozenDestinationAndDefaultsToPrimary"] = selector.itemArray.compactMap{$0.representedObject as? String} == scope.folders && selector.selectedItem?.representedObject as? String == beta && !selector.itemArray.contains{$0.representedObject as? String == outside}
            guard let alphaChoice = selector.itemArray.first(where:{$0.representedObject as? String == alpha}), let scopeAction = selector.action else { throw PetError("缺少 Alpha 保存目录") }
            selector.select(alphaChoice); NSApp.sendAction(scopeAction,to:selector.target,from:selector)
            guard let createButton = find(NSButton.self,host.contentView,{$0.title == "创建 Skill" && $0.isEnabled}) else { throw PetError("实际创建按钮不可用") }; createButton.performClick(nil)
            guard let created = tasks.task(createID)?.skillDraft?.savedID else { throw PetError("实际指定目录创建未保存") }
            let createdItem = try tasks.extensions.item(created,task:tasks.task(createID)!)
            checks["chosenSecondaryDestinationAllowsSameNameInIndependentSource"] = try createdItem.file.path.hasPrefix(alpha + "/") && createdItem.id != conflictItem.id && AgentExtensions.resourceData(AgentFiles(workspace:conflictItem.root.path)) == conflictBefore
            checks["creationPreservesPrimaryFoldersAndRecordsExactSavedTarget"] = tasks.task(createID)?.workspace == beta && tasks.task(createID)?.workspaceScope == scope && tasks.task(createID)?.skillEvolutionJob?.target?.id == created
            for (skillID,marker) in [(saved,"PUBLIC_ALPHA_UPDATED"),(created,"NEW_ALPHA_FLOW")] {
                let verifier = tasks.create(title:"实际 Skill 副本运行核对",workspace:beta,mode:.ask,workspaceScope:scope), tools = AgentTools(store:tasks,taskID:verifier)
                _ = try await tools.execute(workspaceSkillCall("read_skill",["id":skillID]))
                guard let snapshot = tasks.task(verifier)?.activeSkills?.last?.snapshot else { throw PetError("实际 Skill 副本未建立") }
                let result = try await tools.execute(workspaceSkillCall("run_command",["command":AgentGit.quote(ids["node"]!) + " " + AgentGit.quote(snapshot + "/scripts/read-source.mjs"),"timeout_seconds":15]))
                guard !result.failed, let value = try JSONSerialization.jsonObject(with:Data(result.stdout!.trimmingCharacters(in:.whitespacesAndNewlines).utf8)) as? [String:Any], let pid = value["pid"] as? Int else { throw PetError("已保存 Skill 的实际脚本未完成：" + result.text) }
                pids.append(Int32(pid)); checks["savedSkillActuallyRunsItsOwnSnapshotWithOriginalPrimary-" + marker] = value["marker"] as? String == marker && value["cwd"] as? String == beta && (value["source"] as? String)?.contains(marker == "PUBLIC_ALPHA_UPDATED" ? "ALPHA_LOCAL_SKILL_RESOURCE_V2" : "NEW_ALPHA_RESOURCE") == true
                report[marker + "ActualResult"] = value
            }
            let reopened = AgentStore(directory:store.directory,legacy:[],extensionHome:output.appendingPathComponent("shared-home"))
            checks["reopenedStoreResolvesSavedSecondaryTargetsAndOriginalScope"] = try reopened.task(updateID)?.workspaceScope == scope && AgentSkillDrafts.job(reopened.task(updateID)!,store:reopened).target?.id == saved && AgentSkillDrafts.job(reopened.task(createID)!,store:reopened).target?.id == created
            control.showAgentTask(createID); control.show(tab:"chat")
            guard let open = find(NSButton.self,control.window?.contentView,{$0.title == "查看技能"}), open.isEnabled else { throw PetError("缺少实际查看技能入口") }; open.performClick(nil)
            let readback = control.settingsSourceReadback()
            checks["actualSavedSkillActionOpensItsSecondaryManagementSource"] = readback["source"] as? String == alpha && readback["primary"] as? String == beta && readback["controller"] as? String == "AgentExtensionWindow"
            checks["actualSavedSkillEditorSelectsExactSecondaryDocument"] = find(NSTextView.self,control.window?.contentView,{$0.string.contains("NEW_ALPHA_DOCUMENT")}) != nil && find(NSTextView.self,control.window?.contentView,{$0.string.contains("BETA_CONFLICT_UNCHANGED")}) == nil
            checks["noModelsReceiptsOrUsageWereCreated"] = attempts == 0 && tasks.tasks.compactMap{tasks.task($0.id)}.allSatisfy{$0.inputTokens == 0 && $0.outputTokens == 0 && ($0.modelReceipts ?? []).isEmpty}
            checks["twoActualScriptProcessesExit"] = pids.count == 2 && pids.allSatisfy{kill($0,0) != 0}
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy{$0} && report["error"] == nil
        report["appPID"] = getpid(); report["actualCommandPIDs"] = pids; report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("workspace-skill-evolution-report.json"),options:.atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}
