import Foundation

struct AgentProjectKnowledgeJob: Codable {
    var cardTaskID: String?
    var identity: String, revision: String
}
struct AgentProjectKnowledgePreparation {
    var workspace: String, branch: String, revision: String, wikiTaskID: String
    var configuration: AgentWikiPlan.Snapshot
}

@MainActor final class AgentProjectKnowledgeGeneration {
    private weak var store: AgentStore?
    private var preparations: [String: Task<String, Error>] = [:]
    init(store: AgentStore) { self.store = store }
    private func key(_ sourceID: String, _ language: String) throws -> String {
        guard let store, let task = store.task(sourceID), ["zh", "en"].contains(language) else { throw PetError("请选择项目和生成语言") }
        let scope = try store.knowledgeCards.scope(task)
        return scope.root + "\n" + scope.branch + "\n" + language
    }
    func isPreparing(sourceID: String, language: String) -> Bool { (try? key(sourceID, language)).map { preparations[$0] != nil } ?? false }
    func cancelPreparations() { preparations.values.forEach { $0.cancel() } }
    private func refreshIndex(_ task: AgentTaskRecord) async throws -> AgentIndexResult {
        guard let store else { throw PetError("项目已关闭") }
        let tools = AgentTools(store: store, taskID: task.id), call = AgentToolCall(id: UUID().uuidString, name: "index_project", arguments: "{}"), metadata = try tools.gitDirectory(for: call)
        if let reason = try tools.approvalReason(for: call, gitDirectory: metadata) { throw PetError("请先在 Wiki 窗口连接项目：" + reason) }
        return try await store.knowledgeCards.refreshIndex(task)
    }
    func cancelPreparation(taskID: String) {
        guard let task = store?.task(taskID), task.wikiJob?.knowledgeGeneration != nil || task.knowledgeJob?.wikiTaskID != nil, let language = task.wikiJob?.language ?? task.knowledgeJob?.language, let scopeKey = try? key(taskID, language) else { return }
        preparations[scopeKey]?.cancel()
    }
    func start(sourceID: String, language: String, runtime: AgentRuntime) async throws -> String {
        guard let store, let source = store.task(sourceID), !source.archived, source.kind != "hook", try !store.agents.limits(source, store: store).readOnly else { throw PetError("请选择可写的项目任务") }
        let scopeKey = try key(sourceID, language)
        if let pending = preparations[scopeKey] { return try await pending.value }
        let state = try AgentWiki.generationState(store: store, runtime: runtime, sourceID: sourceID, language: language)
        if state.action == "resume", let id = state.taskID {
            if store.task(id)?.wikiJob?.knowledgeGeneration != nil { return try await resume(id, runtime: runtime) }
            return try AgentWiki.resumeGeneration(store: store, runtime: runtime, sourceID: sourceID, language: language, expectedID: id)
        }
        if ["pause", "publishing"].contains(state.action), let id = state.taskID { return id }
        if try !AgentWiki.view(store: store, taskID: sourceID, language: language).pages.isEmpty { return try AgentWiki.start(store: store, runtime: runtime, sourceID: sourceID, language: language) }
        return try await prepare(sourceID: sourceID, language: language, runtime: runtime)
    }
    private func prepare(sourceID: String, language: String, runtime: AgentRuntime) async throws -> String {
        guard let store else { throw PetError("项目已关闭") }
        let scopeKey = try key(sourceID, language)
        if let pending = preparations[scopeKey] { return try await pending.value }
        let operation = Task { @MainActor in
            guard let source = store.task(sourceID), !source.archived, source.kind != "hook", try !store.agents.limits(source, store: store).readOnly else { throw PetError("请选择可写的项目任务") }
            let scope = try store.knowledgeCards.scope(source), identity = try AgentKnowledgeCards.identity(scope.root), configuration = try AgentWikiPlan.load(files: AgentFiles(workspace: scope.root))
            if let reason = store.offices.unsavedReason(workspace: scope.root) { throw PetError(reason) }
            guard !store.tasks.contains(where: { $0.kind == AgentKnowledgeCards.kind && $0.workspace == scope.root && $0.knowledgeJob?.branch == scope.branch && $0.knowledgeJob?.language == language && !$0.archived && ([.ready, .running, .waiting].contains($0.status) || store.knowledgeCards.finalizing.contains($0.id)) }) else { throw PetError("已有活动卡片任务，请先暂停后生成 Wiki 与卡片") }
            let indexed = try await self.refreshIndex(source)
            try Task.checkCancellation()
            guard let current = store.task(sourceID), !current.archived, try !store.agents.limits(current, store: store).readOnly,
                  try store.knowledgeCards.scope(current).root == scope.root, try store.knowledgeCards.scope(current).branch == scope.branch, try AgentKnowledgeCards.identity(scope.root) == identity,
                  try AgentWiki.view(store: store, taskID: sourceID, language: language).pages.isEmpty else { throw PetError("准备期间项目、分支或 Wiki 已变化，请重新生成") }
            let id = try AgentWiki.startPlanned(store: store, runtime: runtime, sourceID: sourceID, language: language, configuration: configuration, revision: indexed.index.revision, knowledgeGeneration: AgentProjectKnowledgeJob(identity: identity, revision: indexed.index.revision), startImmediately: false)
            do {
                let preparation = AgentProjectKnowledgePreparation(workspace: scope.root, branch: scope.branch, revision: indexed.index.revision, wikiTaskID: id, configuration: configuration)
                let cardID = try await store.knowledgeCards.generate(sourceID: sourceID, language: language, preparation: preparation, startImmediately: false)
                store.update(id) { $0.wikiJob?.knowledgeGeneration?.cardTaskID = cardID }
                try Task.checkCancellation(); try self.checkTask(store.task(id)!)
                if let error = store.writeError { throw PetError(error) }
                store.update(id) { $0.events.append(AgentEvent(kind: "knowledge-generation", title: "Wiki 与卡片共用源码版本", detail: "知识卡片任务：" + cardID, status: "completed")) }
                runtime.start(id); runtime.start(cardID)
                guard runtime.isExecuting(id), runtime.isExecuting(cardID) else { throw PetError("项目知识任务未开始，请查看原任务记录") }
                return id
            } catch {
                let cardID = store.tasks.first { $0.knowledgeJob?.wikiTaskID == id }?.id
                runtime.cancel(id); if let cardID { runtime.cancel(cardID) }
                store.update(id) { $0.wikiJob?.knowledgeGeneration?.cardTaskID = cardID; $0.status = .failed; $0.events.append(AgentEvent(kind: "knowledge-generation", title: "项目知识准备未完成", detail: error.localizedDescription, status: "failed")) }
                throw error
            }
        }
        preparations[scopeKey] = operation; runtime.onChange?(sourceID)
        defer { preparations.removeValue(forKey: scopeKey); runtime.onChange?(sourceID) }
        return try await operation.value
    }
    private func members(_ task: AgentTaskRecord) throws -> (AgentTaskRecord, AgentTaskRecord, AgentProjectKnowledgeJob)? {
        guard let store else { throw PetError("项目已关闭") }
        let wiki: AgentTaskRecord
        if task.wikiJob?.knowledgeGeneration != nil { wiki = task }
        else if let id = task.knowledgeJob?.wikiTaskID { guard let owner = store.task(id) else { throw PetError("配套 Wiki 任务已不可读，原卡片任务保留") }; wiki = owner }
        else { return nil }
        guard wiki.kind == "wiki", let group = wiki.wikiJob?.knowledgeGeneration, let id = group.cardTaskID, let card = store.task(id), card.kind == AgentKnowledgeCards.kind, card.knowledgeJob?.wikiTaskID == wiki.id else { throw PetError("配套知识任务准备未完成，请重新生成；原记录保留") }
        return (wiki, card, group)
    }
    func checkTask(_ task: AgentTaskRecord) throws {
        guard let store, let (wiki, card, group) = try members(task), let job = wiki.wikiJob, let cardJob = card.knowledgeJob else { return }
        let scope = try store.knowledgeCards.scope(wiki)
        guard !wiki.archived, !card.archived, wiki.workspace == card.workspace, scope.root == cardJob.workspace, scope.branch == job.branch, scope.branch == cardJob.branch, job.language == cardJob.language,
              try AgentKnowledgeCards.identity(scope.root) == group.identity, wiki.wikiRevision == group.revision, cardJob.sourceRevision == group.revision, cardJob.writingNotes == (job.plan.knowledgeNotes ?? []),
              try AgentProjectIndex(workspace: scope.root, storage: store.directory).snapshot()?.revision == group.revision,
              wiki.messages.contains(where: \.isHumanInput), card.messages.contains(where: \.isHumanInput),
              try !store.agents.limits(wiki, store: store).readOnly, try !store.agents.limits(card, store: store).readOnly else { throw PetError("Wiki 与卡片的项目、源码版本、配置或权限已变化，请重新生成") }
    }
    func state(_ wiki: AgentTaskRecord, runtime: AgentRuntime) throws -> AgentWikiGenerationState {
        guard let store else { throw PetError("项目已关闭") }
        guard let cardID = wiki.wikiJob?.knowledgeGeneration?.cardTaskID, store.task(cardID) != nil, let (_, card, group) = try members(wiki), let language = wiki.wikiJob?.language else { return AgentWikiGenerationState(taskID: wiki.id, action: "resume", includesCards: true) }
        if AgentWiki.isFinalizing(wiki.id) || store.knowledgeCards.finalizing.contains(card.id) { return AgentWikiGenerationState(taskID: wiki.id, action: "publishing", includesCards: true) }
        if [wiki, card].contains(where: { runtime.isExecuting($0.id) || $0.status == .waiting }) { return AgentWikiGenerationState(taskID: wiki.id, action: "pause", includesCards: true) }
        let manifest = try AgentWiki.plannedManifest(store: store, taskID: wiki.id, language: language), book = try store.knowledgeCards.book(card, language: language).0
        let complete = manifest?.taskID == wiki.id && manifest?.revision == group.revision && book?.taskID == card.id && book?.sourceRevision == group.revision && wiki.status == .completed && card.status == .completed && wiki.hasConfirmedWikiCompletion && card.hasConfirmedKnowledgeCompletion
        return AgentWikiGenerationState(taskID: wiki.id, action: complete ? "generate" : "resume", includesCards: !complete)
    }
    func notice(wikiID: String) -> (signature: String, text: String)? {
        guard let store, let wiki = store.task(wikiID), let cardID = wiki.wikiJob?.knowledgeGeneration?.cardTaskID, let card = store.task(cardID), let language = wiki.wikiJob?.language else { return nil }
        let wikiPublished = (try? AgentWiki.plannedManifest(store: store, taskID: wikiID, language: language))?.taskID == wikiID
        let cardPublished = (try? store.knowledgeCards.book(card, language: language))?.0?.taskID == cardID
        func label(_ task: AgentTaskRecord, published: Bool) -> String { published ? "已发布" : task.status == .completed ? "待发布" : task.statusTitle }
        let signature = [wiki.id, wiki.status.rawValue, wiki.events.last?.id ?? "", card.id, card.status.rawValue, card.events.last?.id ?? "", String(wikiPublished), String(cardPublished)].joined(separator: "|")
        var text = "Wiki " + label(wiki, published: wikiPublished) + " · 卡片 " + label(card, published: cardPublished)
        if let error = [wiki, card].first(where: { $0.status == .failed })?.events.last(where: { $0.status == "failed" })?.detail, !error.isEmpty { text += "：" + error }
        return (signature, text)
    }
    func pause(_ wiki: AgentTaskRecord, runtime: AgentRuntime) throws {
        guard let store else { throw PetError("项目已关闭") }
        runtime.cancel(wiki.id)
        for id in [wiki.id, wiki.wikiJob?.knowledgeGeneration?.cardTaskID].compactMap({ $0 }) {
            if store.task(id)?.status == .ready { store.update(id) { $0.status = .stopped } }
        }
        store.update(wiki.id) { $0.events.append(AgentEvent(kind: "knowledge-generation", title: "项目知识生成已暂停", detail: "已完成内容保留；继续时仅启动未完成的任务。", status: "stopped")) }
        if let error = store.writeError { throw PetError(error) }
    }
    func resume(_ id: String, runtime: AgentRuntime) async throws -> String {
        guard let store, let wiki = store.task(id), let (_, card, group) = try members(wiki), let job = wiki.wikiJob else { throw PetError("项目知识任务不可读") }
        _ = try await refreshIndex(wiki); try Task.checkCancellation(); try checkTask(store.task(id)!)
        guard try AgentProjectIndex(workspace: wiki.workspace, storage: store.directory).snapshot()?.revision == group.revision else { throw PetError("源码已变化，请重新生成；原任务和文档保留") }
        let published = try AgentWiki.plannedManifest(store: store, taskID: id, language: job.language)?.taskID
        guard published == job.baseTaskID || published == id else { throw PetError("Wiki 已由其他操作更新，原任务保留") }
        let book = try store.knowledgeCards.book(card, language: job.language)
        guard book.0?.taskID == card.id || book.1 == card.knowledgeJob?.baseHash else { throw PetError("卡片已被编辑，原版本保留；请重新生成") }
        for record in [wiki, card] where record.status == .completed {
            if record.kind == "wiki", published != id {
                try await AgentWiki.finalize(store: store, taskID: id); await store.wikiMaintenance.published(taskID: id, language: job.language, expectedID: id)
            } else if record.kind == AgentKnowledgeCards.kind, book.0?.taskID != card.id { try await store.knowledgeCards.complete(card.id) }
        }
        for record in [wiki, card] where record.status != .completed { runtime.start(record.id); guard runtime.isExecuting(record.id) else { throw PetError("项目知识任务未继续，请查看记录") } }
        return id
    }
    func regenerate(_ preview: AgentWikiRegeneration, sourceID: String, runtime: AgentRuntime) async throws -> String {
        guard let store, try AgentWiki.previewRegeneration(store: store, runtime: runtime, sourceID: sourceID, language: preview.language) == preview else { throw PetError("项目、规划或 Wiki 已变化，请重新确认") }
        guard try AgentWiki.view(store: store, taskID: sourceID, language: preview.language).pages.isEmpty else { return try AgentWiki.regenerate(preview, store: store, runtime: runtime, sourceID: sourceID) }
        if let id = preview.generationID, let wiki = store.task(id) { if wiki.wikiJob?.knowledgeGeneration != nil { try pause(wiki, runtime: runtime) } else { runtime.cancel(id) } }
        return try await prepare(sourceID: sourceID, language: preview.language, runtime: runtime)
    }
}
