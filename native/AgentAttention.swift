import Foundation

enum AgentAttentionKind: String, Codable, CaseIterable, Sendable {
    case question, approval, plan, result
    var title: String { switch self { case .question: return "问题"; case .approval: return "审批"; case .plan: return "计划"; case .result: return "结果" } }
}
enum AgentAttentionSource: String, Codable, CaseIterable, Sendable {
    case local, automation, agent
    var title: String { switch self { case .local: return "本机会话"; case .automation: return "自动化"; case .agent: return "子任务" } }
}
struct AgentAttentionItem: Identifiable, Equatable, Sendable {
    var id: String, taskID: String, title: String, summary: String, body: String, sender: String
    var kind: AgentAttentionKind, source: AgentAttentionSource
    var created: Date, handledAt: Date?, decision: String?
    var callID: String?, requestSignature: String?
    var canExecutePlan = false
    var handled: Bool { decision != nil || handledAt != nil }
    var date: Date { handledAt ?? created }
    var searchable: String { title + "\n" + summary + "\n" + sender }
    static func requestSignature(_ approval: AgentApproval) -> String {
        AgentFiles.hash(Data([approval.id, approval.call.id, approval.call.name, approval.call.arguments, approval.workspace ?? "", approval.gitDirectory ?? ""].joined(separator: "\0").utf8))
    }
    static func approvalBody(_ approval: AgentApproval, task: AgentTaskRecord) -> String {
        let call = approval.call
        if call.name == "ask_user" { return call.object["question"] as? String ?? approval.reason }
        let args = AgentMCP.tools.contains(call.name) ? call.object["arguments"] as? [String: Any] ?? [:] : call.object
        let text = (try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? call.arguments
        var body = approval.reason + "\n\n" + text
        if call.name == "git_commit", let diff = task.gitReview, diff.hash == call.object["review_hash"] as? String { body += "\n\n" + diff.diff }
        return body
    }
    static func project(_ task: AgentTaskRecord) -> [Self] {
        guard !task.archived, task.kind != "hook" else { return [] }
        let source: AgentAttentionSource = task.automation != nil ? .automation : task.agent?.ownerID != nil ? .agent : .local
        let sender = task.automation?.name ?? task.agent?.profile.name ?? "我"
        var items: [Self] = []
        for approval in task.approvals {
            let call = approval.call, question = call.name == "ask_user"
            let pending = approval.decision == nil && task.status == .waiting && task.pendingCalls.first?.id == call.id && task.pendingCalls.first?.arguments == call.arguments && approval.workspace == task.workspace
            let ended = task.events.last { $0.toolCallID == call.id && ["completed", "failed", "stopped"].contains($0.status) }
            guard pending || approval.decision != nil || ended != nil else { continue }
            let body = approvalBody(approval, task: task)
            items.append(Self(id: "request:" + task.id + ":" + approval.id, taskID: task.id, title: task.title, summary: String(body.prefix(240)), body: body, sender: sender, kind: question ? .question : .approval, source: source, created: approval.created, handledAt: approval.decidedAt, decision: pending ? nil : approval.decision ?? "ended", callID: call.id, requestSignature: requestSignature(approval)))
        }
        guard task.messages.contains(where: \.isHumanInput) || task.agent?.ownerID != nil || task.automation != nil else { return items }
        var results = task.resultHistory ?? []
        if let current = AgentTaskResult.capture(task, at: task.activityAt ?? task.updated), !results.contains(where: { $0.id == current.id }) { results.append(current) }
        for event in task.events where event.kind == "state" && ["failed", "stopped"].contains(event.status) && !results.contains(where: { $0.eventID == event.id }) {
            results.append(AgentTaskResult(id: event.status + ":" + event.id, eventID: event.id, summary: "", status: AgentTaskStatus(rawValue: event.status)!, created: event.created))
        }
        for result in results {
            let response = task.messages.first { $0.id == result.messageID }, event = task.events.first { $0.id == result.eventID }
            var body = result.status == .completed ? response?.content ?? result.summary : event?.detail ?? result.summary
            if let plan = result.plan { body = plan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n\n" + body }
            let executable = result.plan != nil && task.mode == .plan && task.status == .completed && result.plan == task.plan.map(\.title) && result.messageID == task.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty })?.id
            items.append(Self(id: "result:" + task.id + ":" + result.id, taskID: task.id, title: task.title, summary: String(body.prefix(240)), body: body, sender: sender, kind: result.plan == nil ? .result : .plan, source: source, created: result.created, handledAt: nil, decision: nil, canExecutePlan: executable))
        }
        return items
    }
}

@MainActor final class AgentAttention {
    struct Settings: Codable, Equatable {
        var enabled = true
        var sources = AgentAttentionSource.allCases.map(\.rawValue)
        var kinds = AgentAttentionKind.allCases.map(\.rawValue)
        var automationNotifications = true
    }
    private struct Document: Codable { var version = 1; var settings = Settings(); var handled: [String: Date] = [:] }
    private struct Cached: Sendable { var signature: String; var items: [AgentAttentionItem] }
    private struct ReplyDocument: Codable { var version = 1; var drafts: [String: String] = [:] }
    private weak var store: AgentStore?
    private let file: URL
    private var document = Document(), opened = "missing", loadIssue: String?
    private var cache: [String: Cached] = [:], signature = ""
    private var replyDocuments: [String: ReplyDocument] = [:], replySignatures: [String: String] = [:]
    private var refreshTask: Task<Void, Never>?, generation = 0
    private(set) var items: [AgentAttentionItem] = []
    private(set) var issue: String?, revision = 0, loading = false
    var onChange: (() -> Void)?
    var settings: Settings { document.settings }
    var pendingCount: Int { items.filter { !$0.handled }.count }
    init(store: AgentStore) {
        self.store = store; file = store.directory.deletingLastPathComponent().appendingPathComponent("attention.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let files = try AgentFiles(workspace: file.deletingLastPathComponent().path), before = try files.entryMetadata(file).signature
            let data = try files.readData(file, maximum: 4_000_000)
            guard try files.entryMetadata(file).signature == before else { throw PetError("需要我设置正在变化") }
            let value = try JSONDecoder().decode(Document.self, from: data)
            guard value.version == 1, value.settings.sources.allSatisfy({ AgentAttentionSource(rawValue: $0) != nil }), value.settings.kinds.allSatisfy({ AgentAttentionKind(rawValue: $0) != nil }) else { throw PetError("需要我设置格式无效") }
            document = value; opened = before
        } catch { loadIssue = error.localizedDescription; issue = "需要我设置无法读取，原文件已保留：" + error.localizedDescription }
    }
    private func save(_ value: Document) throws {
        if let loadIssue { throw PetError(loadIssue) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value); guard data.count <= 4_000_000 else { throw PetError("需要我记录超过4MB") }
        let files = try AgentFiles(workspace: file.deletingLastPathComponent().path)
        try files.writeData(data, to: file, permissions: 0o600, expectedTarget: opened)
        opened = try files.entryMetadata(file).signature; document = value
    }
    func setSettings(_ value: Settings) throws {
        var next = document; next.settings = value; try save(next); refresh(force: true)
    }
    func mark(_ item: AgentAttentionItem, handled: Bool) throws {
        guard let task = store?.task(item.taskID), let current = AgentAttentionItem.project(task).first(where: { $0.id == item.id }), current.callID == nil else { throw PetError("此项目已变化，请刷新后重试") }
        var next = document; next.handled[item.id] = handled ? Date() : nil; try save(next); signature = ""; refresh()
    }
    func replyDraft(_ item: AgentAttentionItem) throws -> String {
        guard let store, UUID(uuidString: item.taskID) != nil, store.task(item.taskID) != nil else { throw PetError("任务已不可用") }
        if replyDocuments[item.taskID] == nil {
            let files = try AgentFiles(workspace: store.directory.path), file = try files.literalURL(item.taskID + "/attention-drafts.json")
            if FileManager.default.fileExists(atPath: file.path) || (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                let signature = try files.entryMetadata(file).signature
                let document = try JSONDecoder().decode(ReplyDocument.self, from: files.readData(file, maximum: 1_000_000))
                guard document.version == 1, try files.entryMetadata(file).signature == signature else { throw PetError("答复草稿正在变化，请重新打开需要我") }
                replyDocuments[item.taskID] = document; replySignatures[item.taskID] = signature
            } else { replyDocuments[item.taskID] = ReplyDocument(); replySignatures[item.taskID] = "missing" }
        }
        return replyDocuments[item.taskID]?.drafts[item.id] ?? ""
    }
    func saveReply(_ item: AgentAttentionItem, text: String) throws {
        _ = try replyDraft(item)
        guard text.utf8.count <= 65_536, let store, var next = replyDocuments[item.taskID] else { throw PetError("答复草稿不能超过64KB") }
        if (next.drafts[item.id] ?? "") == text { return }
        next.drafts[item.id] = text.isEmpty ? nil : text
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(next)
        guard data.count <= 1_000_000 else { throw PetError("此任务的答复草稿超过1MB") }
        let files = try AgentFiles(workspace: store.directory.path), file = try files.literalURL(item.taskID + "/attention-drafts.json")
        try files.writeData(data, to: file, permissions: 0o600, expectedTarget: replySignatures[item.taskID] ?? "missing")
        replySignatures[item.taskID] = try files.entryMetadata(file).signature; replyDocuments[item.taskID] = next
    }
    @discardableResult func decide(_ item: AgentAttentionItem, decision: String, runtime: AgentRuntime) throws -> String? {
        guard settings.enabled, items.contains(where: { $0.id == item.id && $0.requestSignature == item.requestSignature }), let task = store?.task(item.taskID), !task.archived, task.status == .waiting,
              let call = task.pendingCalls.first, call.id == item.callID,
              let approval = task.approvals.last(where: { $0.call.id == call.id && $0.decision == nil }), AgentAttentionItem.requestSignature(approval) == item.requestSignature,
              call.name == approval.call.name, call.arguments == approval.call.arguments, task.workspace == approval.workspace,
              item.kind == .question ? decision.hasPrefix("answer:") && !decision.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : ["allow", "deny"].contains(decision) else { throw PetError("请求已变化，请刷新后核对") }
        runtime.decide(taskID: item.taskID, callID: call.id, decision: decision)
        if let error = store?.writeError { throw PetError("处理结果未保存：" + error) }
        var warning: String?
        if item.kind == .question { do { try saveReply(item, text: "") } catch { warning = "答复已提交；草稿清理未完成：" + error.localizedDescription } }
        refresh(force: true)
        return warning
    }
    func executePlan(_ item: AgentAttentionItem, runtime: AgentRuntime) throws {
        guard settings.enabled, let store, let task = store.task(item.taskID), !task.archived, task.mode == .plan, task.status == .completed,
              AgentAttentionItem.project(task).contains(where: { $0.id == item.id && $0.body == item.body && $0.canExecutePlan }) else { throw PetError("计划已变化，请重新审阅") }
        store.update(task.id) { $0.mode = .agent }
        if let error = store.writeError { throw PetError("任务模式未保存：" + error) }
        guard runtime.submit("按刚才审阅的计划执行，保留此前的约束。", taskID: task.id) else { throw PetError(runtime.submissionError ?? "计划尚未开始执行") }
        refresh(force: true)
    }
    func refresh(force: Bool = false) {
        guard let store else { return }
        if !settings.enabled || loadIssue != nil {
            let changed = signature != "disabled" || !items.isEmpty || loading
            refreshTask?.cancel(); refreshTask = nil; generation += 1; items = []; loading = false; signature = "disabled"
            if changed { revision += 1; onChange?() }; return
        }
        let records = store.tasks.filter { !$0.archived && $0.kind != "hook" }
        // Streaming text does not change handled requests; refresh it at the next execution state transition.
        let keys = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.status.rawValue + ":" + $0.title + ":" + ($0.status == .running ? "streaming" : $0.updated.description)) })
        let next = keys.keys.sorted().map { $0 + ":" + keys[$0]! }.joined(separator: "\n")
        guard force || next != signature else { return }; signature = next
        refreshTask?.cancel(); generation += 1; let ticket = generation, directory = store.directory, previous = force ? [:] : cache
        loading = true
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let worker = Task.detached(priority: .utility) { () -> ([String: Cached], [String]) in
                    var updated: [String: Cached] = [:], errors: [String] = []
                    for id in keys.keys.sorted() {
                        if Task.isCancelled { break }
                        if let old = previous[id], old.signature == keys[id] { updated[id] = old; continue }
                        do {
                            guard UUID(uuidString: id) != nil else { continue }
                            let files = try AgentFiles(workspace: directory.path), file = try files.literalURL(id + ".json")
                            let record = try JSONDecoder().decode(AgentTaskRecord.self, from: files.readData(file, maximum: 20_000_000))
                            guard record.id == id else { throw PetError("任务编号不匹配") }
                            updated[id] = Cached(signature: keys[id]!, items: AgentAttentionItem.project(record))
                        } catch { errors.append(id + "：" + error.localizedDescription) }
                    }
                    return (updated, errors)
                }
                let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, generation == ticket, settings.enabled, let store = self.store else { return }
                guard store.refreshDeletedRecords() else { throw PetError(store.deletions.issue ?? "任务删除记录不可用") }
                let live = Set(store.tasks.filter { !$0.archived }.map(\.id)); cache = result.0.filter { live.contains($0.key) }
                items = cache.values.flatMap(\.items).filter { settings.sources.contains($0.source.rawValue) && settings.kinds.contains($0.kind.rawValue) }.map { value in
                    var item = value; if item.callID == nil { item.handledAt = document.handled[item.id] }; return item
                }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
                issue = result.1.isEmpty ? nil : "\(result.1.count) 项记录未载入：" + result.1.prefix(2).joined(separator: "；")
                loading = false; refreshTask = nil; revision += 1; onChange?()
            } catch {
                guard let self, !Task.isCancelled, generation == ticket else { return }; issue = error.localizedDescription; loading = false; refreshTask = nil; revision += 1; onChange?()
            }
        }
    }
}
