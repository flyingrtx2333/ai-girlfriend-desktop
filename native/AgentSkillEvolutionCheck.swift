import AppKit
import Darwin

@MainActor extension AppDelegate {
    private func skillCheckCall(_ name:String, _ object:[String:Any], id:String = UUID().uuidString) throws -> AgentToolCall {
        .init(id:id,name:name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self))
    }
    @discardableResult func prepareSkillEvolutionUI(_ output:URL, seed:Bool) throws -> [String:String] {
        ensureAgent(); guard let tasks = agentStore, let service = agentRuntime?.skillEvolution else { throw PetError("缺少 Skill 改进验收环境") }
        let file = output.appendingPathComponent("skill-evolution-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:file))
            guard let id = ids["source"], tasks.task(id) != nil else { throw PetError("原生公开样例不可用") }; control.showAgentTask(id); control.show(tab:"chat"); return ids
        }
        guard !FileManager.default.fileExists(atPath:file.path) else { throw PetError("公开样例已存在，请重开原目录") }
        let project = output.appendingPathComponent("public-project"); try FileManager.default.createDirectory(at:project,withIntermediateDirectories:false)
        try Data("# Public Skill fixture\n\nNative acceptance data, not a model response.\nRead the actual README and cite its lines.\n".utf8).write(to:project.appendingPathComponent("README.md"))
        func skill(_ name:String) throws -> AgentExtensionItem {
            let item = try tasks.extensions.create(.skill,name:name,text:"---\nname: " + name + "\ndescription: Native public fixture\ndisable-model-invocation: true\n---\n# Public verification\nRead README.md and quote only actual facts.\n",project:false,workspace:project.path)
            let files = try AgentFiles(workspace:item.root.path)
            try files.writeData(Data("print('public fixture v1')\n".utf8),to:files.resolve("scripts/check.py"),permissions:0o700)
            try files.writeData(Data([0,255,17,128]),to:files.resolve("assets/sample.bin"),permissions:0o640); return item
        }
        let target = try skill("public-check"), staleTarget = try skill("stale-public-check"), unrelated = try skill("unrelated-public-check")
        func source(_ title:String, english:Bool = false) throws -> String {
            let id = tasks.create(title:title,workspace:english ? nil : project.path,mode:english ? .ask : .agent,workMode:english ? .general : .coding)
            let call = try skillCheckCall("read_file",["path":"README.md"])
            tasks.update(id) { task in
                task.messages = [AgentMessage(role:"user",content:english ? "Native fixture: capture a reusable disk inspection procedure." : "公开原生样例：核对 README 并保留可复用步骤。"),
                    AgentMessage(role:"assistant",content:"",toolCalls:english ? nil : [call])]
                if !english { task.messages.append(AgentMessage(role:"tool",content:(try? String(contentsOf:project.appendingPathComponent("README.md"),encoding:.utf8)) ?? "",toolCallID:call.id)); task.events = [.init(kind:"tool",title:"read_file",status:"completed",toolCallID:call.id)] }
                task.messages.append(AgentMessage(role:"assistant",content:english ? "Native UI fixture, not a model response: use df -h for disk space and distinguish it from memory usage." : "原生界面样例，不是模型输出：README 第3行标明此数据用于原生验收，第4行要求读取实际文件并引用行号。"))
                task.status = .completed; task.draft = english ? "Keep my unsent draft 🧭" : "保留未发送草稿 🧭"
            }; return id
        }
        var preferences = store.preferences; preferences.contextTokens = 8192; preferences.replyTokens = 512
        func save(_ id:String, _ items:[AgentSkillEvolutionSuggestion]) throws {
            let task = tasks.task(id)!, choices = try service.targets(task), brief = try AgentSkillEvolution.input(task,targets:choices,preferences:preferences,secret:"")
            try service.save(items,id:id,source:AgentSkillEvolution.source(task)!,model:"native-fixture",brief:brief)
        }
        func item(_ id:String, _ title:String, _ goal:String, target:AgentSkillEvolutionTarget? = nil) -> AgentSkillEvolutionSuggestion {
            .init(title:title,reason:"原生公开样例，可重复核对来源与结果。",goal:goal,target:target,evidence:[tasks.task(id)!.messages.last!.id])
        }
        let main = try source("Skill 建议公开样例"), english = try source("No-workspace Skill suggestions",english:true), stale = try source("过期 Skill 来源样例"), drafts = try source("原生草稿来源（非模型）")
        let descriptor = try service.targets(tasks.task(main)!).first{$0.id == target.id}!, staleDescriptor = try service.targets(tasks.task(stale)!).first{$0.id == staleTarget.id}!
        let suggestions = [item(main,"整理 README 核对流程","创建从实际 README 核对事实、引用行号的可复用技能。"),item(main,"补充公开核对技能","保留原触发配置，增加复核结果与脚本。",target:descriptor),item(main,"复用检查结果摘要","生成简洁的核对结果模板。")]
        try save(main,suggestions); try save(english,[item(english,"Capture disk inspection steps","Create an English skill to inspect disk space without a workspace.")]); try save(stale,[item(stale,"更新已变化的技能","核对资源版本后再更新。",target:staleDescriptor)])
        try Data("print('changed after suggestion')\n".utf8).write(to:staleTarget.root.appendingPathComponent("scripts/check.py"))
        let update = item(drafts,"原生更新草稿","保留权限与二进制资源，补全核对脚本和模板。",target:descriptor), create = item(drafts,"Native new Skill draft","Create a reusable English README verification skill with a template.")
        try save(drafts,[update,create]); _ = try service.curate([update.id,create.id],taskID:drafts,source:AgentSkillEvolution.source(tasks.task(drafts)!)!,adopt:true)
        func stage(_ id:String, new:Bool) throws {
            tasks.update(id) { task in task.messages = [AgentMessage(role:"user",content:task.skillEvolutionJob!.goal),AgentMessage(role:"assistant",content:new ? "Native plan fixture, not model output: create a README inspection skill and result template." : "原生方案样例，不是模型输出：保留触发配置，修改说明与公开脚本，增加结果模板；未保存前不改技能目录。")]; task.draft = ""; task.status = .completed }
            try AgentSkillDrafts.approvePlan(id,source:AgentSkillDrafts.planSource(tasks.task(id)!)!,store:tasks)
            tasks.update(id) { $0.messages.append(AgentMessage(role:"user",content:"确认原生验收方案，仅准备公开草稿。")); $0.status = .ready }
            let original = new ? nil : try AgentSkillDrafts.base(tasks.task(id)!.skillEvolutionJob!,store:tasks)["SKILL.md"]
            let document = original.map { String(decoding:$0,as:UTF8.self) + "\n## Recheck\nCompare the actual README and record exact line numbers.\n" } ?? "---\nname: readme-inspection\ndescription: Verify a public README and cite actual lines\n---\n# README inspection\nRead README.md, verify the requested fact and cite actual lines.\nUse templates/result.txt for the result.\n"
            var args: [String:Any] = ["path":"SKILL.md","content":document]; if let original { args["expected_hash"] = AgentFiles.hash(original) }
            _ = try AgentSkillDrafts.stage(skillCheckCall("draft_skill",args),taskID:id,store:tasks)
            _ = try AgentSkillDrafts.stage(skillCheckCall("draft_skill",["path":"templates/result.txt","content":"Fact:\nREADME lines:\nChecked result:\n"]),taskID:id,store:tasks)
            if !new {
                let old = try AgentSkillDrafts.base(tasks.task(id)!.skillEvolutionJob!,store:tasks)["scripts/check.py"]!
                _ = try AgentSkillDrafts.stage(skillCheckCall("draft_skill",["path":"scripts/check.py","expected_hash":AgentFiles.hash(old),"old_text":"v1","new_text":"v2"]),taskID:id,store:tasks)
            }
            tasks.update(id) { $0.messages.append(AgentMessage(role:"assistant",content:"原生草稿样例，不是模型输出：草稿保存在本任务，尚未修改已安装 Skill。")); $0.status = .completed }
        }
        try stage(update.id,new:false); try stage(create.id,new:true)
        let ids = ["source":main,"english":english,"stale":stale,"draftSource":drafts,"update":update.id,"create":create.id,"target":target.id,"unrelated":unrelated.id,"modelOutputsCreated":"false"]
        try JSONEncoder().encode(ids).write(to:file); control.showAgentTask(main); control.show(tab:"chat"); return ids
    }
    func skillEvolutionReadback() -> [String:Any] {
        guard CommandLine.arguments.contains("--manual-ui"), let tasks = agentStore else { return [:] }
        let records = tasks.tasks.compactMap { tasks.task($0.id) }
        return ["enabled":generalSettings.settings.skillEvolutionSuggestions,"records":records.map { task in
            ["id":task.id,"title":task.title,"status":task.status.rawValue,"mode":task.mode.rawValue,"draft":task.draft ?? "","suggestions":agentRuntime?.skillEvolution.items(task).map { ["id":$0.id,"title":$0.title,"state":$0.state.rawValue,"taskID":$0.taskID ?? ""] } ?? [],"jobSource":task.skillEvolutionJob?.sourceTaskID ?? "","approvedPlan":task.skillEvolutionJob?.approvedPlan ?? "","draftFiles":task.skillDraft?.files.keys.sorted() ?? [],"savedID":task.skillDraft?.savedID ?? "","savedVersion":task.skillDraft?.savedVersion ?? ""] as [String:Any]
        }]
    }
    func runSkillEvolutionCheck(_ output:URL) async {
        var checks: [String:Bool] = [:], report: [String:Any] = [:], attempts = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少 Skill 验收环境") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("Skill 原生验收禁止模型请求") }; defer { runtime.stopAll() }
            let ids = try prepareSkillEvolutionUI(output,seed:true), id = ids["source"]!, service = runtime.skillEvolution, original = tasks.task(id)!, source = AgentSkillEvolution.source(original)!, items = service.items(original)
            let target = try tasks.extensions.item(ids["target"]!,workspace:original.workspace), unrelated = try tasks.extensions.item(ids["unrelated"]!,workspace:original.workspace)
            let targetBefore = try AgentExtensions.resourceData(AgentFiles(workspace:target.root.path)), unrelatedBefore = try AgentExtensions.resourceData(AgentFiles(workspace:unrelated.root.path))
            checks["independentProfileAndSystemDeliveryBlocked"] = tasks.hooks.sharedHome == output.appendingPathComponent("shared-home") && !automationNotifications.allowsSystemDelivery
            checks["defaultEnabledWithoutConfigurationWrite"] = generalSettings.settings.skillEvolutionSuggestions && !FileManager.default.fileExists(atPath:store.directory.appendingPathComponent("general.json").path)
            checks["actualSourcesIncludeOnlyCompletedToolAndVisibleReply"] = AgentSkillEvolution.sources(original).count == 2 && AgentSkillEvolution.sources(original).contains{$0.text.contains("Native acceptance data")}
            let choices = try service.targets(original), evidence = Set(AgentSkillEvolution.sources(original).map(\.id)), replyID = original.messages.last!.id
            func json(_ rows:[[String:Any]]) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:["suggestions":rows]),as:UTF8.self) }
            let valid: [String:Any] = ["title":"Reusable fact check","reason":"Verify public evidence","goal":"Read the README and cite its actual lines.","target_id":NSNull(),"evidence":[replyID]]
            checks["strictBilingualAndEmptySuggestionsDecode"] = try AgentSkillEvolution.parse(json([valid]),targets:choices,evidence:evidence).count == 1 && AgentSkillEvolution.parse(json([]),targets:choices,evidence:evidence).isEmpty
            var badRows: [(String,[[String:Any]])] = [("count",Array(repeating:valid,count:4)),("duplicate",[valid,valid])]
            for (key,value) in [("title",String(repeating:"🐳",count:31) as Any),("reason","a\nb" as Any),("goal",1 as Any),("target_id","unlisted" as Any),("evidence",["invented"] as Any),("extra",true as Any)] { var row = valid; row[key] = value; badRows.append((key,[row])) }
            func refused(_ body:() throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
            for (name,rows) in badRows { checks["invalid-" + name + "-rejected"] = refused { _ = try AgentSkillEvolution.parse(json(rows),targets:choices,evidence:evidence) } }
            checks["markdownAndExtraTopLevelRejected"] = refused { _ = try AgentSkillEvolution.parse("```json\n" + json([valid]) + "\n```",targets:choices,evidence:evidence) } && refused { _ = try AgentSkillEvolution.parse("{\"suggestions\":[],\"extra\":true}",targets:choices,evidence:evidence) }
            var p = store.preferences; p.contextTokens = 8192; p.replyTokens = 512
            var huge = original; huge.messages[0].content = String(repeating:"PUBLIC_TEST_SECRET 中文 fact ",count:4000); huge.messages[huge.messages.count - 1].content = String(repeating:"actual public fact ",count:8000)
            let input = try AgentSkillEvolution.input(huge,targets:choices,preferences:p,secret:"PUBLIC_TEST_SECRET"), body = try AgentModel.requestBody(preferences:p,system:AgentSkillEvolution.system,messages:[.init(role:"user",content:input)],tools:[])
            checks["bounded8192_512InputRedactsSecretAndHasNoTools"] = !input.contains("PUBLIC_TEST_SECRET") && input.contains("[隐藏]") && body["tools"] == nil && body["tool_choice"] == nil
            huge.messages[0].content = "a" + String(repeating:"\u{301}",count:20000)
            checks["oversizedSingleGraphemeTerminates"] = try AgentSkillEvolution.input(huge,targets:choices,preferences:p,secret:"").utf8.count < 50000
            checks["nativeFixturesCannotTriggerAutomaticAnalysis"] = !service.generate(id,preferences:p,key:"") && !service.generate(ids["update"]!,preferences:p,key:"") && attempts == 0
            checks["metadataReopensAndStaysOutOfModelWire"] = try JSONDecoder().decode(AgentTaskRecord.self,from:JSONEncoder().encode(original)).messages.last?.skillEvolution?.items.count == 3 && original.messages.last?.wire["skillEvolution"] == nil
            var legacy = original; legacy.messages[legacy.messages.count - 1].skillEvolution = nil
            checks["legacyRecordsDecodeWithoutNewMetadata"] = try JSONDecoder().decode(AgentTaskRecord.self,from:JSONEncoder().encode(legacy)).messages.last?.skillEvolution == nil
            let index = tasks.directory.appendingPathComponent("index.json"), parentFile = tasks.directory.appendingPathComponent(id + ".json"), indexBefore = try Data(contentsOf:index), parentBefore = try Data(contentsOf:parentFile), count = tasks.tasks.count, adoptedIDs = Set(items.prefix(2).map(\.id))
            try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:index.path)
            checks["readOnlyIndexRejectsBatchWithoutOrphansOrMarkers"] = try refused { _ = try service.curate(adoptedIDs,taskID:id,source:source,adopt:true) } && tasks.tasks.count == count && Data(contentsOf:index) == indexBefore && Data(contentsOf:parentFile) == parentBefore && adoptedIDs.allSatisfy { !FileManager.default.fileExists(atPath:tasks.directory.appendingPathComponent($0 + ".json").path) }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:index.path)
            let children = try service.curate(adoptedIDs,taskID:id,source:source,adopt:true)
            checks["batchAdoptCreatesSeparatePlanTasksWithoutSendingOrChangingSkill"] = try children.count == 2 && children.allSatisfy { child in guard let task = tasks.task(child) else { return false }; return task.kind == AgentSkillEvolution.kind && task.parentID == id && task.mode == .plan && task.messages.isEmpty && task.skillEvolutionJob?.approvedPlan == nil && task.draft?.isEmpty == false } && (try AgentExtensions.resourceData(AgentFiles(workspace:target.root.path))) == targetBefore
            checks["parentAnswerAndUnsentDraftPreserved"] = tasks.task(id)?.messages.map(\.content) == original.messages.map(\.content) && tasks.task(id)?.draft == original.draft
            let afterAdopt = tasks.tasks.count
            checks["adoptingAgainReusesSameTasks"] = try Set(service.curate(adoptedIDs,taskID:id,source:source,adopt:true)) == adoptedIDs && tasks.tasks.count == afterAdopt
            _ = try service.curate([items[2].id],taskID:id,source:source,adopt:false)
            checks["ignorePersistsWithoutTaskOrFileCreation"] = try service.items(tasks.task(id)!).last?.state == .dismissed && tasks.tasks.count == afterAdopt && (try AgentExtensions.resourceData(AgentFiles(workspace:target.root.path))) == targetBefore
            let stale = tasks.task(ids["stale"]!)!, staleItems = service.items(stale)
            checks["resourceOnlyTargetChangeRejectsAdopt"] = refused { _ = try service.curate(Set(staleItems.map(\.id)),taskID:stale.id,source:AgentSkillEvolution.source(stale)!,adopt:true) } && tasks.tasks.count == afterAdopt
            let planID = items[0].id
            let planTools = AgentTools(store:tasks,taskID:planID), forbidden = ["draft_skill","write_file","run_command","delegate_task","load_tools","call_mcp_tool"]
            for name in forbidden {
                let call = try skillCheckCall(name,["path":"should-not-exist.txt","content":"refused","command":"true","groups":["files"]]); var executed = false
                do { _ = try await planTools.execute(call); executed = true } catch {}
                checks["plan-" + name + "-refusedAtApprovalAndExecution"] = !executed && refused { _ = try planTools.approvalReason(for:call) }
            }
            checks["planAndOrdinaryDefinitionsRespectToolScope"] = !AgentTools.definitions(mode:.plan,kind:AgentSkillEvolution.kind).contains { ($0["function"] as? [String:Any])?["name"] as? String == "draft_skill" } && !AgentTools.definitions(mode:.agent).contains { ($0["function"] as? [String:Any])?["name"] as? String == "read_skill_source" }
            tasks.update(planID) { $0.messages = [.init(role:"user",content:"原生计划验收"),.init(role:"assistant",content:"原生方案样例，不是模型输出：创建一个公开的核对技能。")]; $0.status = .completed }
            let planHash = AgentSkillDrafts.planSource(tasks.task(planID)!)!
            checks["stalePlanCannotBeApproved"] = refused { try AgentSkillDrafts.approvePlan(planID,source:"stale",store:tasks) } && tasks.task(planID)?.skillEvolutionJob?.approvedPlan == nil
            control.showAgentTask(planID); control.show(tab:"chat"); try control.confirmSkillPlan(taskID:planID,source:planHash,start:false)
            checks["explicitNativePlanConfirmationPreparesGenerationWithoutModelCall"] = tasks.task(planID)?.mode == .agent && tasks.task(planID)?.skillEvolutionJob?.approvedPlan == planHash && tasks.task(planID)?.messages.last?.isHumanInput == true && attempts == 0
            let updateID = ids["update"]!, updateTask = tasks.task(updateID)!, draft = updateTask.skillDraft!, job = updateTask.skillEvolutionJob!, revision = AgentSkillDrafts.revision(draft), tools = AgentTools(store:tasks,taskID:updateID)
            checks["stagingMultipleFilesNeverChangesInstalledSkill"] = try draft.files.count == 3 && draft.savedAt == nil && (try AgentExtensions.resourceData(AgentFiles(workspace:target.root.path))) == targetBefore
            let result = try await tools.execute(skillCheckCall("read_skill_source",["path":"scripts/check.py","limit":8])), read = try JSONSerialization.jsonObject(with:Data(result.text.utf8)) as! [String:Any]
            checks["sourceReadReturnsActualHashAndBoundedContinuation"] = read["sha256"] as? String == AgentFiles.hash(targetBefore["scripts/check.py"]!) && read["next_offset"] as? Int == 8 && (read["content"] as? String)?.unicodeScalars.count == 8
            checks["unsafePathsRefused"] = ["../x","/tmp/x","a/./x",".env","a//b","skill.md","a\\b","a:b","node_modules/x"].allSatisfy { !AgentSkillDrafts.validPath($0) }
            let beforeInvalid = AgentSkillDrafts.revision(tasks.task(updateID)!.skillDraft!)
            checks["resourceCaseAndFileDirectoryConflictsRefusedBeforeSaving"] = refused { _ = try AgentSkillDrafts.stage(skillCheckCall("draft_skill",["path":"Scripts/check.py","content":"collision"]),taskID:updateID,store:tasks) } && refused { _ = try AgentSkillDrafts.stage(skillCheckCall("draft_skill",["path":"templates/result.txt/nested","content":"collision"]),taskID:updateID,store:tasks) } && AgentSkillDrafts.revision(tasks.task(updateID)!.skillDraft!) == beforeInvalid
            let replay = try skillCheckCall("draft_skill",["path":"templates/result.txt","expected_hash":AgentFiles.hash(Data(draft.files["templates/result.txt"]!.utf8)),"old_text":"Checked result:","new_text":"Checked result:"],id:"public-idempotent-call")
            _ = try AgentSkillDrafts.stage(replay,taskID:updateID,store:tasks); let replayBytes = try Data(contentsOf:tasks.directory.appendingPathComponent(updateID + ".json")); _ = try AgentSkillDrafts.stage(replay,taskID:updateID,store:tasks)
            checks["replayedToolCallDoesNotWriteAgainOrChangeDraftVersion"] = try Data(contentsOf:tasks.directory.appendingPathComponent(updateID + ".json")) == replayBytes && AgentSkillDrafts.revision(tasks.task(updateID)!.skillDraft!) == beforeInvalid
            let inspector = AgentTaskInspector(frame:.zero); var monitored = AgentMonitorContent(task:original); monitored.skillSuggestions = items; monitored.skillSource = source; var callbacks = 0; inspector.onSkillCurate = { _,_,_ in callbacks += 1 }; inspector.update(monitored)
            func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let detached = descendants(inspector).compactMap{$0 as? AgentSkillSuggestionsView}.first; inspector.update(AgentMonitorContent(task:tasks.task(ids["english"]!)!)); detached?.onCurate?(Set(items.map(\.id)),true)
            checks["detachedInspectorCallbacksCannotActOnAnotherTask"] = detached != nil && callbacks == 0 && monitored.signature == monitored.signature
            checks["existingTextRequiresVersionAndBinaryCannotBeOverwritten"] = refused { _ = try AgentSkillDrafts.stage(skillCheckCall("draft_skill",["path":"SKILL.md","content":"unsafe"]),taskID:updateID,store:tasks) } && refused { _ = try AgentSkillDrafts.stage(skillCheckCall("draft_skill",["path":"assets/sample.bin","expected_hash":AgentFiles.hash(targetBefore["assets/sample.bin"]!),"content":"unsafe"]),taskID:updateID,store:tasks) }
            var protected = draft; protected.files["SKILL.md"] = protected.files["SKILL.md"]!.replacingOccurrences(of:"disable-model-invocation: true",with:"disable-model-invocation: false")
            checks["draftCannotChangeExistingTriggerOrPermissions"] = refused { _ = try AgentSkillDrafts.proposed(protected,job:job,store:tasks) }
            checks["staleReviewRevisionCannotApply"] = refused { _ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:"stale",name:target.name,project:false,store:tasks) }
            let draftFile = tasks.directory.appendingPathComponent(updateID + ".json"), draftBytes = try Data(contentsOf:draftFile)
            try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:draftFile.path)
            checks["readOnlyTaskReceiptCannotLeaveInstalledFilesChanged"] = try refused { _ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:revision,name:target.name,project:false,store:tasks) } && Data(contentsOf:draftFile) == draftBytes && AgentExtensions.resourceData(AgentFiles(workspace:target.root.path)) == targetBefore
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:draftFile.path)
            let executable = target.root.appendingPathComponent("scripts/check.py"), oldMode = try FileManager.default.attributesOfItem(atPath:executable.path)[.posixPermissions] as! NSNumber
            try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:executable.path)
            checks["readOnlyTargetKeepsAllFilesAndDraftUnapplied"] = try refused { _ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:revision,name:target.name,project:false,store:tasks) } && tasks.task(updateID)?.skillDraft?.savedAt == nil && (try AgentExtensions.resourceData(AgentFiles(workspace:target.root.path))) == targetBefore
            try FileManager.default.setAttributes([.posixPermissions:oldMode],ofItemAtPath:executable.path)
            let conflict = Data("print('external modification')\n".utf8); try conflict.write(to:executable)
            checks["resourceConflictRejectsApplyWithoutOverwritingExternalBytes"] = try refused { _ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:revision,name:target.name,project:false,store:tasks) } && Data(contentsOf:executable) == conflict
            try targetBefore["scripts/check.py"]!.write(to:executable)
            let sourceTask = tasks.task(ids["draftSource"]!)!; tasks.update(sourceTask.id) { $0.messages = [] }
            checks["missingSourceRejectsDraftOperation"] = refused { _ = try AgentSkillDrafts.job(tasks.task(updateID)!,store:tasks) }; tasks.update(sourceTask.id) { $0 = sourceTask }
            let savedID = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:revision,name:target.name,project:false,store:tasks), saved = try tasks.extensions.item(savedID,workspace:original.workspace), actual = try AgentExtensions.resourceData(AgentFiles(workspace:saved.root.path))
            checks["explicitApplyWritesReviewedFilesAndPreservesOtherResourcesAndModes"] = try actual["scripts/check.py"] == Data("print('public fixture v2')\n".utf8) && actual["templates/result.txt"] == Data("Fact:\nREADME lines:\nChecked result:\n".utf8) && actual["assets/sample.bin"] == targetBefore["assets/sample.bin"] && (try FileManager.default.attributesOfItem(atPath:executable.path)[.posixPermissions] as? NSNumber) == oldMode
            checks["savedReceiptAndJobTrackActualInstalledVersion"] = tasks.task(updateID)?.skillDraft?.savedID == saved.id && tasks.task(updateID)?.skillDraft?.savedVersion == AgentExtensions.digest(actual) && tasks.task(updateID)?.skillEvolutionJob?.target?.bundleHash == AgentExtensions.digest(actual)
            checks["secondApplyCannotDuplicateOrOverwrite"] = refused { _ = try AgentSkillDrafts.apply(taskID:updateID,draftID:draft.id,revision:revision,name:target.name,project:false,store:tasks) }
            checks["unrelatedSkillBytesPreserved"] = try AgentExtensions.resourceData(AgentFiles(workspace:unrelated.root.path)) == unrelatedBefore
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3"); process.arguments = [executable.path]; process.standardOutput = pipe; process.standardError = pipe; process.environment = ["PATH":"/usr/bin:/bin","PYTHONDONTWRITEBYTECODE":"1","TMPDIR":output.appendingPathComponent("tmp").path]; try process.run(); process.waitUntilExit()
            checks["nativeFixtureScriptActuallyRunsAfterApply"] = process.terminationStatus == 0 && String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self) == "public fixture v2\n"
            let fresh = AgentStore(directory:tasks.directory.deletingLastPathComponent(),legacy:[],extensionHome:output.appendingPathComponent("shared-home"))
            checks["appliedRecordReopensWithFullDraftAndSource"] = fresh.task(updateID)?.skillDraft?.savedVersion == AgentExtensions.digest(actual) && fresh.task(updateID)?.skillEvolutionJob?.target?.id == saved.id
            checks["newHumanRoundKeepsAppliedHistoryAndRequiresNewPlan"] = runtime.submit("继续完善公开流程",taskID:updateID,startImmediately:false) && tasks.task(updateID)?.mode == .plan && tasks.task(updateID)?.skillDraft == nil && tasks.task(updateID)?.skillDraftHistory?.last?.savedID == saved.id && tasks.task(updateID)?.skillEvolutionJob?.approvedPlan == nil
            let fork = tasks.fork(updateID)
            checks["ordinaryForkCannotInheritSkillApprovalOrDraft"] = fork.flatMap(tasks.task)?.skillEvolutionJob == nil && fork.flatMap(tasks.task)?.skillDraft == nil && fork.flatMap(tasks.task)?.skillDraftHistory == nil && fork != nil
            let createID = ids["create"]!, creation = tasks.task(createID)!, creationDraft = creation.skillDraft!
            control.showAgentTask(createID); control.show(tab:"chat"); try control.reviewSkillDraft(taskID:createID); control.window?.contentView?.layoutSubtreeIfNeeded()
            let views = control.window?.contentView.map(descendants) ?? [], tables = views.compactMap{$0 as? NSTableView}.filter{$0.accessibilityLabel() == "设置审阅列表" && !$0.isHiddenOrHasHiddenAncestor}
            checks["multiFileDraftOpensInsideSettingsWithRealFileList"] = control.window?.attachedSheet == nil && tables.contains{$0.numberOfRows == 2} && views.contains{$0.identifier?.rawValue == "skill-review-name"}
            let newID = try AgentSkillDrafts.apply(taskID:createID,draftID:creationDraft.id,revision:AgentSkillDrafts.revision(creationDraft),name:"reviewed-readme",project:true,store:tasks), new = try tasks.extensions.item(newID,workspace:original.workspace)
            checks["newProjectSkillUsesReviewedNameScopeAndResources"] = try new.scope == "项目" && new.name == "reviewed-readme" && new.file.path.hasPrefix(original.workspace! + "/.bluefatfish/skills/") && (try String(contentsOf:new.file,encoding:.utf8)).contains("name: \"reviewed-readme\"") && FileManager.default.fileExists(atPath:new.root.appendingPathComponent("templates/result.txt").path)
            let english = tasks.task(ids["english"]!)!, englishItem = service.items(english)[0], englishChildren = try service.curate([englishItem.id],taskID:english.id,source:AgentSkillEvolution.source(english)!,adopt:true), englishID = englishChildren[0]
            checks["askWithoutWorkspaceCanCreateIndependentImprovementTask"] = tasks.task(englishID)?.workspace == nil && tasks.task(englishID)?.workMode == .general && tasks.task(englishID)?.mode == .plan
            tasks.update(englishID) { $0.messages = [.init(role:"user",content:"Native English fixture"),.init(role:"assistant",content:"Native plan fixture: create a user skill.")]; $0.status = .completed }
            try AgentSkillDrafts.approvePlan(englishID,source:AgentSkillDrafts.planSource(tasks.task(englishID)!)!,store:tasks)
            _ = try AgentSkillDrafts.stage(skillCheckCall("draft_skill",["path":"SKILL.md","content":"---\nname: disk-inspection\ndescription: Inspect disk space\n---\nUse df -h for disk space. Distinguish it from memory usage.\n"]),taskID:englishID,store:tasks)
            let englishDraft = tasks.task(englishID)!.skillDraft!
            checks["noWorkspaceRejectsProjectScope"] = refused { _ = try AgentSkillDrafts.apply(taskID:englishID,draftID:englishDraft.id,revision:AgentSkillDrafts.revision(englishDraft),name:"disk-inspection",project:true,store:tasks) }
            let englishSaved = try AgentSkillDrafts.apply(taskID:englishID,draftID:englishDraft.id,revision:AgentSkillDrafts.revision(englishDraft),name:"disk-inspection",project:false,store:tasks)
            checks["noWorkspaceCreatesActualUserSkill"] = try tasks.extensions.item(englishSaved,workspace:nil).scope == "全局"
            var setting = generalSettings.settings; setting.skillEvolutionSuggestions = false; try generalSettings.save(setting)
            checks["disableStopsNewAnalysisButRetainsSuggestionsAndAdoptedLinks"] = !service.generate(id,preferences:p,key:"") && service.items(tasks.task(id)!).count == 3 && service.items(tasks.task(id)!).prefix(2).allSatisfy{$0.state == .adopted}
            let generalFile = store.directory.appendingPathComponent("general.json"), oldDir = output.appendingPathComponent("legacy-general"); try FileManager.default.createDirectory(at:oldDir,withIntermediateDirectories:false)
            var old = try JSONSerialization.jsonObject(with:Data(contentsOf:generalFile)) as! [String:Any]; old.removeValue(forKey:"skillEvolutionSuggestions"); let oldBytes = try JSONSerialization.data(withJSONObject:old); try oldBytes.write(to:oldDir.appendingPathComponent("general.json"))
            checks["legacyPreferenceDefaultsOnWithoutRewriting"] = try AgentGeneralSettings(directory:oldDir).settings.skillEvolutionSuggestions && Data(contentsOf:oldDir.appendingPathComponent("general.json")) == oldBytes
            old["skillEvolutionSuggestions"] = "yes"; try JSONSerialization.data(withJSONObject:old).write(to:oldDir.appendingPathComponent("general.json")); checks["nonBooleanPreferenceRejected"] = AgentGeneralSettings(directory:oldDir).error != nil
            control.showSettingsCategory("general"); control.window?.contentView?.layoutSubtreeIfNeeded()
            let generalViews = control.window?.contentView.map(descendants) ?? [], toggle = generalViews.first{$0.identifier?.rawValue == "general-skill-evolution"} as? NSSwitch
            toggle?.state = .on; if let toggle { _ = toggle.sendAction(toggle.action,to:toggle.target) }
            checks["nativeGeneralTogglePersistsAndNoModalIsPresented"] = toggle != nil && generalSettings.settings.skillEvolutionSuggestions && AgentGeneralSettings(directory:store.directory).settings.skillEvolutionSuggestions && control.window?.attachedSheet == nil
            checks["generalHasFourteenControls"] = generalViews.filter{$0 is NSControl && $0.identifier?.rawValue.hasPrefix("general-") == true}.count == 14
            checks["noModelRequestsOrForgedUsage"] = attempts == 0 && tasks.tasks.compactMap{tasks.task($0.id)}.allSatisfy{($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0}
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy{$0} && report["error"] == nil; report["appPID"] = getpid(); report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("skill-evolution-report.json"),options:.atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}
