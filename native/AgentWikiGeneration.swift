import Foundation

struct AgentWikiGenerationState {
    var taskID: String?
    var action = "generate"
    var includesCards = false
    var title: String { switch action { case "pause": return "暂停生成"; case "resume": return "继续生成"; case "publishing": return "正在发布…"; case "preparing": return "正在核对项目…"; default: return includesCards ? "生成 Wiki 与卡片" : "生成 Wiki" } }
}

struct AgentWikiRegeneration: Equatable {
    let workspace: String, branch: String, language: String
    let generationID: String?, publishedID: String?, configurationHash: String?
    let documentCount: Int?
}

@MainActor extension AgentWiki {
    private static func generationSource(store: AgentStore, sourceID: String, language: String) throws -> AgentTaskRecord {
        guard ["zh", "en"].contains(language), let source = store.task(sourceID), !source.archived, source.kind != "hook", try !store.agents.limits(source, store: store).readOnly else { throw PetError("请选择可写的项目任务和生成语言") }
        return source
    }
    static func generationState(store: AgentStore, runtime: AgentRuntime, sourceID: String, language: String) throws -> AgentWikiGenerationState {
        let source = try generationSource(store: store, sourceID: sourceID, language: language), scope = try store.knowledgeCards.scope(source)
        if store.projectKnowledge.isPreparing(sourceID: sourceID, language: language) { return AgentWikiGenerationState(action: "preparing", includesCards: true) }
        let candidates = store.tasks.filter { $0.kind == "wiki" && $0.workspace == scope.root && $0.wikiJob?.branch == scope.branch && $0.wikiJob?.language == language && !$0.archived }.sorted { $0.created > $1.created }
        let active = candidates.first { isFinalizing($0.id) || runtime.isRunning($0.id) || $0.status == .waiting }
        guard let metadata = active ?? candidates.first, let task = store.task(metadata.id) else { return AgentWikiGenerationState(includesCards: try view(store: store, taskID: sourceID, language: language).pages.isEmpty) }
        if task.wikiJob?.knowledgeGeneration != nil { return try store.projectKnowledge.state(task, runtime: runtime) }
        if isFinalizing(task.id) { return AgentWikiGenerationState(taskID: task.id, action: "publishing") }
        if active != nil { return AgentWikiGenerationState(taskID: task.id, action: "pause") }
        return AgentWikiGenerationState(taskID: task.id, action: [.ready, .stopped, .failed].contains(task.status) ? "resume" : "generate")
    }
    static func pauseGeneration(store: AgentStore, runtime: AgentRuntime, sourceID: String, language: String, expectedID: String) throws {
        let state = try generationState(store: store, runtime: runtime, sourceID: sourceID, language: language)
        guard state.taskID == expectedID, state.action == "pause" else { throw PetError("Wiki 生成状态已变化，请刷新后重试") }
        if let task = store.task(expectedID), task.wikiJob?.knowledgeGeneration != nil { try store.projectKnowledge.pause(task, runtime: runtime); return }
        runtime.cancel(expectedID)
        store.update(expectedID) { $0.status = .stopped; $0.events.append(AgentEvent(kind: "wiki", title: "Wiki 生成已暂停", detail: "原任务、冻结规划和文档草稿已保留。", status: "stopped")) }
        if let error = store.writeError { throw PetError(error) }
    }
    static func resumeGeneration(store: AgentStore, runtime: AgentRuntime, sourceID: String, language: String, expectedID: String) throws -> String {
        let state = try generationState(store: store, runtime: runtime, sourceID: sourceID, language: language)
        guard state.taskID == expectedID, state.action == "resume", let task = store.task(expectedID), let job = task.wikiJob else { throw PetError("Wiki 生成状态已变化，请刷新后重试") }
        guard job.knowledgeGeneration == nil else { throw PetError("请从项目知识入口继续 Wiki 与卡片") }
        guard try !store.agents.limits(task, store: store).readOnly else { throw PetError("此 Wiki 任务为只读，请重新生成") }
        guard task.messages.contains(where: \.isHumanInput) else { throw PetError(task.wikiJob?.update == nil ? "任务初始准备未完成，请重新生成" : "更新草稿准备未完成，请重新执行增量更新") }
        try checkScope(task, store: store)
        guard try plannedManifest(store: store, taskID: sourceID, language: language)?.taskID == job.baseTaskID else { throw PetError("Wiki 已由另一操作更新，请重新生成；原草稿已保留") }
        let index = try AgentProjectIndex(workspace: task.workspace, storage: store.directory)
        guard task.wikiRevision == nil || index.snapshot()?.revision == task.wikiRevision,
              (task.knowledgeReads ?? [:]).allSatisfy({ (try? index.files.fileHash(index.files.resolve($0.key), maximum: 512_000)) == $0.value.sha256 }) else { throw PetError("已读取的源码或索引已变化，请重新生成；原草稿已保留") }
        runtime.start(expectedID)
        guard runtime.isExecuting(expectedID) else { throw PetError(store.writeError ?? "Wiki 任务未开始，请查看任务记录") }
        return expectedID
    }
    static func previewRegeneration(store: AgentStore, runtime: AgentRuntime, sourceID: String, language: String) throws -> AgentWikiRegeneration {
        let source = try generationSource(store: store, sourceID: sourceID, language: language), scope = try store.knowledgeCards.scope(source)
        let state = try generationState(store: store, runtime: runtime, sourceID: sourceID, language: language)
        guard !["publishing", "preparing"].contains(state.action) else { throw PetError("项目知识正在准备或发布，请稍后重试") }
        let config = try AgentWikiPlan.load(files: AgentFiles(workspace: scope.root))
        return AgentWikiRegeneration(workspace: scope.root, branch: scope.branch, language: language, generationID: state.taskID, publishedID: try plannedManifest(store: store, taskID: sourceID, language: language)?.taskID, configurationHash: config.hash, documentCount: config.plan.documents?.count)
    }
    static func regenerate(_ preview: AgentWikiRegeneration, store: AgentStore, runtime: AgentRuntime, sourceID: String) throws -> String {
        guard try previewRegeneration(store: store, runtime: runtime, sourceID: sourceID, language: preview.language) == preview else { throw PetError("项目、规划或 Wiki 版本已变化，请重新确认；原任务和文档已保留") }
        let state = try generationState(store: store, runtime: runtime, sourceID: sourceID, language: preview.language)
        if state.action == "pause", let id = state.taskID { try pauseGeneration(store: store, runtime: runtime, sourceID: sourceID, language: preview.language, expectedID: id) }
        return try startPlanned(store: store, runtime: runtime, sourceID: sourceID, language: preview.language)
    }
}
