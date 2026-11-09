import Foundation

@MainActor enum AgentEditResend {
    struct Review {
        var taskID: String; var messageID: String; var taskHash: String; var rollback: AgentRoundRollback.Review?; var notice: String
        var canApply: Bool { rollback?.canApply ?? true }
        var fingerprint: String { rollback?.fingerprint ?? taskHash }
    }
    static func supported(_ task: AgentTaskRecord) -> Bool {
        !task.archived && !task.isProjectDocumentation && task.kind != "hook" && task.agent?.ownerID == nil && task.automation == nil
    }
    static func review(taskID: String, messageID: String, store: AgentStore) throws -> Review {
        guard let task = store.task(taskID), supported(task), ![.running, .waiting].contains(task.status), task.pendingFileCapture == nil, task.pendingFileRollback == nil, task.pendingCalls.isEmpty, task.queuedCount == 0, store.archiveIsBusy?(taskID) != true,
              store.organization.archiveID(task.workspace, mode: task.organizationMode) == nil,
              let start = task.messages.firstIndex(where: { $0.id == messageID && $0.isHumanInput }) else { throw PetError("请先停止任务并处理等待中的操作") }
        if let workspace = task.workspace {
            guard !store.projectChanges.isObserving(workspace), !store.hasFileRollback(in: workspace) else { throw PetError("此项目正在记录或恢复文件，请稍后重试") }
        }
        if let reason = store.offices.unsavedReason(workspace: task.workspace) { throw PetError(reason) }
        let hash = try store.recordVersion(taskID), ids = Set(task.messages[start...].filter(\.isHumanInput).map(\.id))
        let changed = (task.changeRounds ?? []).contains { ids.contains($0.id) && ($0.warning != nil || $0.changes.contains { $0.restoredAt == nil }) }
        let rollback = changed ? try AgentRoundRollback.review(taskID: taskID, from: messageID, store: store) : nil
        let incomplete = task.changeRounds == nil || task.changeTrackingFromID.flatMap { boundary in task.messages.firstIndex { $0.id == boundary } }.map { start < $0 } == true
        let files = rollback != nil ? "将撤回这轮及之后的项目文件。" : task.workspace == nil || incomplete ? "没有这轮的完整项目检查点，只替换对话；文件保持当前状态。" : "没有项目文件需要撤回。"
        return Review(taskID: taskID, messageID: messageID, taskHash: hash, rollback: rollback, notice: "将替换这条要求和后续对话，原对话保存在归档。" + files + "命令、服务及外部操作不能自动撤回。")
    }
    @discardableResult static func apply(_ expected: Review, text: String, store: AgentStore, runtime: AgentRuntime, startImmediately: Bool = true) throws -> String {
        let review = try self.review(taskID: expected.taskID, messageID: expected.messageID, store: store)
        guard review.canApply, review.fingerprint == expected.fingerprint, review.taskHash == expected.taskHash else { throw PetError("文件或任务已变化，请重新审阅") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 100_000, text != "/compact" else { throw PetError("请输入要重新发送的要求，最多100000字节；整理上下文请使用主输入框") }
        guard let original = store.task(review.taskID), let previous = original.messages.first(where: { $0.id == review.messageID }) else { throw PetError("原始要求已变化") }
        var restricted = original; try store.agents.detachForFork(&restricted, store: store)
        var next = try AgentReplyBranch.before(restricted, messageID: review.messageID)
        let message = try runtime.prepareInput(text, attachmentIDs: previous.attachmentIDs ?? [], task: next)
        next.messages.append(message); next.activateExtensions(message)
        let used = Set(next.messages.flatMap { ($0.attachmentIDs ?? []) + ($0.visuals ?? []).map(\.id) } + (original.draftAttachmentIDs ?? []))
        next.attachments = (original.attachments ?? []).filter { used.contains($0.id) }
        next.id = UUID().uuidString; next.parentID = original.id; next.agent?.ownerID = nil
        if next.sideTask != nil { try store.sideTasks.bindToSession(&next) }
        next.title = original.title; next.created = original.created; next.updated = Date(); next.activityAt = next.updated; next.pinned = original.pinned
        next.archived = false; next.workspaceArchiveID = nil; next.status = .ready; next.draft = original.draft; next.draftAttachmentIDs = original.draftAttachmentIDs
        next.changes = []; next.changeRounds = []; next.changeTrackingFromID = nil; next.pendingFileCapture = nil; next.pendingFileRollback = nil
        next.summary = ""; next.goalAccepted = nil; next.completionEvidence = nil; next.approvals = []; next.recap = nil; next.kind = nil
        next.gitReview = nil; next.gitTurn = nil; next.gitPushReview = nil; next.gitPushReceipt = nil; next.gitRemoteSnapshot = nil
        next.hookSession = nil; next.hookContexts = nil; next.hookContextIDs = nil; next.hookRewakePromptID = nil; next.hookRewakeCount = nil
        for i in next.events.indices where next.events[i].status == "running" && next.events[i].hook?.asynchronous == true {
            next.events[i].status = "stopped"; next.events[i].hook?.delivery = "edit-history"
        }
        next.events.append(AgentEvent(kind: "state", title: "已编辑并重新发送", detail: "编辑前对话：" + original.id, status: "completed"))
        do {
            try AgentAttachments.copyForFork(store: store, sourceID: original.id, targetID: next.id, files: next.attachments ?? [])
            try store.canvases.copyForFork(sourceID: original.id, targetID: next.id, records: next.canvases ?? [], historical: true)
            try store.extensions.copyForFork(store: store, sourceID: original.id, task: &next)
            if let rollback = review.rollback { try AgentRoundRollback.apply(rollback, store: store, continuation: next) }
            else { _ = try store.commitTaskRecord(original, expectedHash: review.taskHash, transaction: store.directory.deletingLastPathComponent().appendingPathComponent("edit-transactions/" + next.id), continuation: next, label: "编辑并重发") }
        } catch {
            if !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(next.id + ".json").path) { try? FileManager.default.removeItem(at: store.directory.appendingPathComponent(next.id)) }
            throw error
        }
        if startImmediately { runtime.start(next.id) }; return next.id
    }
}
