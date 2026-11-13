import Foundation

@MainActor enum AgentSkillDrafts {
    static let readTools: Set<String> = ["read_skill_source","read_task_history","read_file","list_directory","search_files","ask_user","update_plan","finish_task"]
    static let tools = readTools.union(["draft_skill"])
    static func revision(_ draft:AgentSkillDraft) -> String { AgentExtensions.digest(draft.files.mapValues { Data($0.utf8) }) }
    static func currentTarget(_ target:AgentSkillEvolutionTarget, workspace:String?, store:AgentStore) throws -> (item:AgentExtensionItem, files:[String:Data]) {
        let item = try store.extensions.item(target.id,workspace:workspace)
        guard item.kind == .skill, item.managed, item.pluginName == nil, item.name == target.name, item.sha256 == target.documentHash else { throw PetError("目标 Skill 已变化、停用或不可编辑，请重新生成建议") }
        let resources = try AgentExtensions.resourceData(AgentFiles(workspace:item.root.path))
        guard AgentExtensions.digest(resources) == target.bundleHash else { throw PetError("目标 Skill 的资源已变化，请重新生成建议") }; return (item,resources)
    }
    static func job(_ task:AgentTaskRecord, store:AgentStore) throws -> AgentSkillEvolutionJob {
        guard task.kind == AgentSkillEvolution.kind, let job = task.skillEvolutionJob, !task.archived, task.workspace == job.workspace,
              task.agent == nil, task.team == nil, task.automation == nil, UUID(uuidString:job.sourceTaskID) != nil, UUID(uuidString:job.suggestionID) != nil else { throw PetError("Skill 改进任务的范围已变化，请从原建议重新创建") }
        guard let source = store.task(job.sourceTaskID)?.messages.first(where: { $0.id == job.sourceMessageID && $0.isReply }),
              ([source.skillEvolution].compactMap { $0 } + (source.skillEvolutionHistory ?? [])).contains(where: { set in
                  set.source == job.sourceHash && set.items.contains { $0.id == job.suggestionID && $0.taskID == task.id && $0.state == .adopted }
              }) else { throw PetError("原建议已不可用，请从原任务重新生成") }
        if let target = job.target { _ = try currentTarget(target,workspace:task.workspace,store:store) }; return job
    }
    static func check(_ call:AgentToolCall, task:AgentTaskRecord, store:AgentStore) throws {
        guard task.kind == AgentSkillEvolution.kind || task.skillEvolutionJob != nil else { return }
        let job = try job(task,store:store)
        guard tools.contains(call.name) else { throw PetError("Skill 改进任务只读取来源并生成待审阅草稿") }
        if call.name == "draft_skill" { guard job.approvedPlan != nil, ![.ask,.plan].contains(task.mode) else { throw PetError("请先在会话中确认 Skill 方案") } }
    }
    static func planSource(_ task:AgentTaskRecord) -> String? {
        guard task.kind == AgentSkillEvolution.kind, task.skillEvolutionJob?.approvedPlan == nil, task.mode == .plan, task.status == .completed, task.pendingCalls.isEmpty, task.queuedCount == 0,
              let human = task.messages.lastIndex(where:\.isHumanInput), let reply = task.messages.lastIndex(where:\.isReply), reply > human else { return nil }
        return AgentFiles.hash(Data((task.messages[reply].id + "\0" + task.messages[reply].content).utf8))
    }
    static func approvePlan(_ id:String, source:String, store:AgentStore) throws {
        guard var task = store.task(id), planSource(task) == source else { throw PetError("方案已变化，请核对当前方案") }; _ = try job(task,store:store)
        let expected = try store.recordVersion(id); task.skillEvolutionJob?.approvedPlan = source; task.mode = .agent
        _ = try store.commitTaskRecord(task,expectedHash:expected,transaction:transaction(store,"plan"),label:"确认 Skill 方案")
    }
    static func prepareNewRound(_ task:inout AgentTaskRecord, message:AgentMessage) throws {
        guard message.isHumanInput, let draft = task.skillDraft, draft.savedAt != nil, task.skillEvolutionJob != nil else { return }
        guard (task.skillDraftHistory ?? []).count < 20 else { throw PetError("此任务已有20次技能版本记录，请在新任务继续") }
        if task.skillDraftHistory == nil { task.skillDraftHistory = [] }; task.skillDraftHistory?.append(draft); task.skillDraft = nil
        task.skillEvolutionJob?.approvedPlan = nil; task.skillEvolutionJob?.goal = message.content; task.mode = .plan
    }
    static func validPath(_ path:String) -> Bool {
        let parts = path.split(separator:"/",omittingEmptySubsequences:false)
        return !path.isEmpty && path.utf8.count <= 300 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !AgentFiles.sensitive(path) &&
            !path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && $0 != "node_modules" && $0 != "__pycache__" } &&
            (path.lowercased() != "skill.md" || path == "SKILL.md")
    }
    static func base(_ job:AgentSkillEvolutionJob, store:AgentStore) throws -> [String:Data] { try job.target.map { try currentTarget($0,workspace:job.workspace,store:store).files } ?? [:] }
    static func read(_ call:AgentToolCall, task:AgentTaskRecord, store:AgentStore) throws -> AgentToolResult {
        let job = try job(task,store:store), args = call.object
        guard Set(args.keys).isSubset(of:["path","offset","limit","draft"]), args["path"] == nil || args["path"] is String, args["draft"] == nil || args["draft"] is Bool else { throw PetError("Skill 来源读取参数无效") }
        let staged = args["draft"] as? Bool == true, resources = staged ? (task.skillDraft?.files ?? [:]).mapValues { Data($0.utf8) } : try base(job,store:store)
        let path = args["path"] as? String ?? "."
        if path == "." {
            let object: [String:Any] = ["goal":job.goal,"source_task":job.sourceTitle,"experience":job.brief,"target":job.target?.name ?? "创建新 Skill","draft":staged,"files":resources.keys.sorted()]
            return .init(text:String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self))
        }
        guard validPath(path), let data = resources[path], let text = String(data:data,encoding:.utf8) else { throw PetError("此 Skill 来源中没有可读取的 UTF-8 文件") }
        let units = Array(text.unicodeScalars), start = min(units.count,max(0,args["offset"] as? Int ?? 0)), end = min(units.count,start + min(1600,max(1,args["limit"] as? Int ?? 800)))
        let content = String(String.UnicodeScalarView(units[start..<end]))
        let object: [String:Any] = ["path":path,"sha256":AgentFiles.hash(data),"content":content,"total_characters":units.count,"next_offset":end < units.count ? end : NSNull()]
        return .init(text:String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self))
    }
    static func stage(_ call:AgentToolCall, taskID:String, store:AgentStore) throws -> AgentToolResult {
        guard var task = store.task(taskID) else { throw PetError("任务不存在") }; try check(call,task:task,store:store)
        let job = try job(task,store:store), args = call.object
        guard Set(args.keys).isSubset(of:["path","content","old_text","new_text","expected_hash"]), let path = args["path"] as? String, validPath(path), !call.id.isEmpty, call.id.utf8.count <= 200 else { throw PetError("Skill 草稿文件参数无效") }
        var draft = task.skillDraft ?? .init(); guard draft.savedAt == nil else { throw PetError("此草稿已应用，请从新建议继续改进") }
        if draft.baseVersion == nil { draft.baseVersion = job.target?.bundleHash }
        let payload = AgentFiles.hash(try JSONSerialization.data(withJSONObject:args,options:[.sortedKeys]))
        if let saved = draft.calls[call.id] { guard saved == payload else { throw PetError("此调用已保存另一项改动") }; return try receipt(draft,path:path,job:job,store:store) }
        let original = try base(job,store:store), current = draft.files[path].map { Data($0.utf8) } ?? original[path]
        guard current == nil || String(data:current!,encoding:.utf8) != nil else { throw PetError("二进制资源不能由文字草稿覆盖") }
        let expected = args["expected_hash"] as? String
        guard current == nil ? expected == nil || expected == "missing" : expected == AgentFiles.hash(current!) else { throw PetError("先读取当前文件，并传入相同 expected_hash") }
        let value:String
        if let content = args["content"] as? String {
            guard args["old_text"] == nil, args["new_text"] == nil else { throw PetError("整段内容与局部替换不能混用") }; value = content
        } else {
            guard let old = args["old_text"] as? String, !old.isEmpty, let new = args["new_text"] as? String, let data = current, let text = String(data:data,encoding:.utf8), text.components(separatedBy:old).count == 2 else { throw PetError("局部替换需要唯一匹配的 old_text 和 new_text") }
            value = text.replacingOccurrences(of:old,with:new)
        }
        guard !value.contains("\0"), value.utf8.count <= (path == "SKILL.md" ? 65_536 : 256_000) else { throw PetError("Skill 草稿文件超过上限或包含无效字符") }
        draft.files[path] = value; draft.calls[call.id] = payload
        guard draft.files.count <= 32, draft.calls.count <= 64, draft.files.values.reduce(0,{$0 + $1.utf8.count}) <= 1_000_000,
              Set(draft.files.keys.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == draft.files.count else { throw PetError("Skill 草稿过大或路径重复") }
        var resources = original; for (path,text) in draft.files { resources[path] = Data(text.utf8) }; try validateResources(resources)
        let expectedTask = try store.recordVersion(taskID); task.skillDraft = draft
        _ = try store.commitTaskRecord(task,expectedHash:expectedTask,transaction:transaction(store,"draft"),label:"Skill 草稿")
        return try receipt(draft,path:path,job:job,store:store)
    }
    private static func receipt(_ draft:AgentSkillDraft, path:String, job:AgentSkillEvolutionJob, store:AgentStore) throws -> AgentToolResult {
        let ready = (try? proposed(draft,job:job,store:store)) != nil
        let object: [String:Any] = ["draft_id":draft.id,"path":path,"sha256":AgentFiles.hash(Data((draft.files[path] ?? "").utf8)),"files":draft.files.keys.sorted(),"ready_for_review":ready,"applied":false,"next_action":"继续生成所需资源；完成后请用户在本会话选择审阅技能。草稿未创建或修改已安装 Skill。"]
        return .init(text:String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self))
    }
    static func proposed(_ draft:AgentSkillDraft, job:AgentSkillEvolutionJob, store:AgentStore, name:String? = nil) throws -> [String:Data] {
        guard !draft.files.isEmpty, draft.files.count <= 32, draft.files.keys.allSatisfy(validPath), draft.baseVersion == job.target?.bundleHash,
              draft.files.allSatisfy({ !$0.value.contains("\0") && $0.value.utf8.count <= ($0.key == "SKILL.md" ? 65_536 : 256_000) }),
              draft.files.values.reduce(0,{$0 + $1.utf8.count}) <= 1_000_000,
              Set(draft.files.keys.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == draft.files.count else { throw PetError("Skill 草稿文件或来源版本无效") }
        var resources = try base(job,store:store); for (path,text) in draft.files { resources[path] = Data(text.utf8) }
        guard let data = resources["SKILL.md"], let text = String(data:data,encoding:.utf8) else { throw PetError("Skill 草稿缺少 SKILL.md") }
        let document = try AgentExtensionDocument(text), chosen = name ?? job.target?.name ?? document.metadata["name"] ?? ""
        guard AgentExtensions.validName(chosen), !chosen.contains(":"), chosen.count <= 64 else { throw PetError("Skill 名称使用64字以内的文字、数字、连字符或下划线") }
        if let target = job.target {
            guard chosen == target.name else { throw PetError("改进现有 Skill 时保留原名称") }
            let previous = try AgentExtensionDocument(String(decoding:base(job,store:store)["SKILL.md"]!,as:UTF8.self))
            let protected: (String)->Bool = { !["name","description"].contains($0) }
            guard previous.metadata.filter({protected($0.key)}) == document.metadata.filter({protected($0.key)}) else { throw PetError("Skill 改进不能改变原权限与触发配置") }
        }
        resources["SKILL.md"] = Data(try named(text,chosen).utf8); try validateResources(resources); return resources
    }
    private static func validateResources(_ resources:[String:Data]) throws {
        let paths = Set(resources.keys.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        guard paths.count == resources.count, resources.values.reduce(0,{$0 + $1.count}) <= 20_000_000 else { throw PetError("Skill 资源路径重复或总量超过20MB") }
        var entries = paths
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty { guard !paths.contains(parent) else { throw PetError("Skill 文件与资源目录重名") }; entries.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        }
        guard entries.count <= 2000 else { throw PetError("Skill 文件与目录超过2000项") }
    }
    static func named(_ text:String, _ name:String) throws -> String {
        _ = try AgentExtensionDocument(text); var lines = text.components(separatedBy:"\n")
        if try AgentExtensionDocument(text).metadata["name"] == name { return text }
        let value = String(String(decoding:try JSONSerialization.data(withJSONObject:[name]),as:UTF8.self).dropFirst().dropLast())
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of:"---") {
            if let index = (1..<end).first(where:{ lines[$0].hasPrefix("name:") }) { lines[index] = "name: " + value }
            else { lines.insert("name: " + value,at:1) }
        } else { lines = ["---","name: " + value,"---",""] + lines }
        return lines.joined(separator:"\n")
    }
    static func apply(taskID:String, draftID:String, revision:String, name:String, project:Bool, store:AgentStore) throws -> String {
        guard var task = store.task(taskID), let draft = task.skillDraft, draft.id == draftID, self.revision(draft) == revision, draft.savedAt == nil, task.status != .running, task.pendingCalls.isEmpty, task.queuedCount == 0 else { throw PetError("Skill 草稿已变化或仍在生成，请重新审阅") }
        let job = try job(task,store:store); guard job.approvedPlan != nil else { throw PetError("请先确认 Skill 方案") }
        let proposed = try proposed(draft,job:job,store:store,name:name), original = try base(job,store:store)
        let files: AgentFiles, prefix:String
        if let target = job.target { files = try AgentFiles(workspace:currentTarget(target,workspace:task.workspace,store:store).item.root.path); prefix = "" }
        else {
            guard !project || task.workspace != nil else { throw PetError("项目 Skill 需要原任务的项目文件夹") }
            guard try !store.extensions.catalog(workspace:task.workspace).contains(where:{$0.kind == .skill && $0.name.lowercased() == name.lowercased()}) else { throw PetError("同名 Skill 已存在，请更改名称") }
            files = try AgentFiles(workspace:project ? task.workspace : store.extensions.profile.path); prefix = (project ? ".bluefatfish/skills/" : "extensions/skills/") + name + "/"
            guard try files.entryMetadata(files.literalURL(String(prefix.dropLast()))).kind == "missing" else { throw PetError("同名目录已存在，请更改名称") }
        }
        var writes: [AgentKnowledgeFileWrite] = []
        for path in proposed.keys.sorted() where proposed[path] != original[path] {
            writes.append(try .init(files:files,path:prefix + path,data:proposed[path],expectedHash:original[path].map(AgentFiles.hash),missing:original[path] == nil,permissions:original[path] == nil ? 0o600 : nil,label:"应用 Skill 改进"))
        }
        guard !writes.isEmpty else { throw PetError("草稿与当前 Skill 一致，无需应用") }
        let expected = try store.recordVersion(taskID), targetFile = try files.literalURL(prefix + "SKILL.md"), id = String(AgentFiles.hash(Data(targetFile.path.utf8)).prefix(24)), originalTask = task
        let bundleHash = AgentExtensions.digest(proposed)
        task.skillDraft?.savedAt = Date(); task.skillDraft?.savedID = id; task.skillDraft?.savedVersion = bundleHash
        task.skillEvolutionJob?.target = .init(id:id,name:name,documentHash:AgentFiles.hash(proposed["SKILL.md"]!),bundleHash:bundleHash)
        _ = try store.commitTaskRecord(task,expectedHash:expected,transaction:transaction(store,"apply"),label:"应用 Skill 改进",additionalWrites:writes) {
            _ = try self.job(originalTask,store:store)
            if job.target == nil { guard try !store.extensions.catalog(workspace:task.workspace).contains(where:{$0.kind == .skill && $0.name.lowercased() == name.lowercased()}) else { throw PetError("同名 Skill 在审阅后出现，未覆盖") } }
        }
        return id
    }
    private static func transaction(_ store:AgentStore, _ suffix:String) -> URL { store.directory.deletingLastPathComponent().appendingPathComponent("skill-evolution-transactions/" + suffix + "-" + UUID().uuidString) }
}
