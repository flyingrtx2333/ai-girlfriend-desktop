import Foundation

@MainActor enum AgentRoundRollback {
    struct Entry: Codable { var path: String; var current: AgentCapturedFile; var desired: AgentCapturedFile; var temporaryName: String? = nil; var temporarySignature: String? = nil }
    private struct Journal: Codable { var id: String; var taskID: String; var messageID: String; var workspace: String; var entries: [Entry] }
    struct Review {
        var taskID: String; var messageID: String; var taskHash: String; var workspace: String
        var roundIDs: Set<String>; var changeIDs: Set<String>; var paths: [String]; var entries: [Entry]; var issues: [String]
        var recovery: Bool
        var canApply: Bool { issues.isEmpty && !entries.isEmpty }
        var fingerprint: String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(entries)) ?? Data()
            return AgentFiles.hash(Data((taskHash + "|" + messageID + "|" + String(recovery)).utf8) + data)
        }
    }
    static func available(_ task: AgentTaskRecord, from messageID: String) -> Bool {
        availableMessages(task).contains(messageID)
    }
    static func availableMessages(_ task: AgentTaskRecord) -> Set<String> {
        if let pending = task.pendingFileRollback { return [pending.messageID] }
        guard !task.isProjectDocumentation, task.kind != "hook" else { return [] }
        let changed = Set((task.changeRounds ?? []).filter { $0.warning != nil || $0.changes.contains { $0.restoredAt == nil } }.map(\.id))
        var result = Set<String>(), hasChanges = false
        for message in task.messages.reversed() where message.isHumanInput {
            hasChanges = hasChanges || changed.contains(message.id); if hasChanges { result.insert(message.id) }
        }; return result
    }
    private static func validateTask(_ taskID: String, store: AgentStore) throws -> AgentTaskRecord {
        guard let task = store.task(taskID), !task.archived, !task.isProjectDocumentation, task.kind != "hook", task.status != .running, task.pendingFileCapture == nil,
              task.pendingCalls.isEmpty, task.queuedCount == 0, store.archiveIsBusy?(taskID) != true, let workspace = task.workspace else { throw PetError("请先停止任务并处理等待中的操作") }
        guard !store.projectChanges.isObserving(workspace) else { throw PetError("此项目正在记录其他文件操作，请稍后重试") }; return task
    }
    private static func directory(_ id: String, taskID: String, store: AgentStore) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw PetError("撤回记录编号无效") }
        return try store.backupDirectory(taskID).appendingPathComponent("round-restores/" + id, isDirectory: true)
    }
    private static func verify(_ value: AgentCapturedFile, backups: AgentFiles) throws {
        guard ["file", "link", "missing"].contains(value.state.kind) else { throw PetError("目录或特殊文件不能自动撤回") }
        if value.state.kind == "missing" { return }
        guard let path = value.backup, let hash = value.state.hash, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw PetError("缺少完整检查点") }
        guard try backups.fileHash(backups.literalURL(path), maximum: value.state.kind == "link" ? 8192 : nil) == hash else { throw PetError("检查点校验失败") }
    }
    static func review(taskID: String, from messageID: String, store: AgentStore) throws -> Review {
        let task = try validateTask(taskID, store: store), version = try store.recordVersion(taskID), files = try AgentFiles(workspace: task.workspace)
        guard !store.hasFileRollback(in: files.root.path, except: taskID) else { throw PetError("此项目有其他未完成的文件撤回，请先恢复") }
        let backups = try AgentFiles(workspace: store.backupDirectory(taskID).path)
        var review = Review(taskID: taskID, messageID: messageID, taskHash: version, workspace: files.root.path, roundIDs: [], changeIDs: [], paths: [], entries: [], issues: [], recovery: task.pendingFileRollback != nil)
        if let pending = task.pendingFileRollback {
            guard pending.messageID == messageID else { throw PetError("请先恢复未完成的文件撤回") }
            let folder = try AgentFiles(workspace: directory(pending.id, taskID: taskID, store: store).path)
            let journal = try JSONDecoder().decode(Journal.self, from: folder.readData(folder.literalURL("manifest.json"), maximum: 4_000_000))
            guard journal.id == pending.id, journal.taskID == taskID, journal.messageID == messageID, journal.workspace == files.root.path, Set(journal.entries.map(\.path)).count == journal.entries.count else { throw PetError("撤回记录与当前任务或项目不一致") }
            review.paths = journal.entries.map(\.path)
            for (i, entry) in journal.entries.enumerated() {
                do {
                    try verify(entry.current, backups: folder)
                    let current = try AgentCapturedFile.read(files.literalURL(entry.path).path, files: files, backups: nil)
                    guard current.state == entry.current.state || current.state == entry.desired.state else { throw PetError("文件又被修改，未覆盖后来的内容") }
                    var signature: String?
                    if let name = entry.temporaryName {
                        guard name == ".bluefatfish-rollback-" + pending.id + "-" + String(i) + ".tmp" else { throw PetError("撤回暂存记录无效") }
                        let temporary = try files.literalURL(URL(fileURLWithPath: entry.path).deletingLastPathComponent().appendingPathComponent(name).path), metadata = try files.entryMetadata(temporary)
                        guard ["missing", "file", "link"].contains(metadata.kind) else { throw PetError("暂存路径类型已变化，未移除") }; signature = metadata.signature
                    }
                    review.entries.append(Entry(path: entry.path, current: current, desired: entry.current, temporaryName: entry.temporaryName, temporarySignature: signature))
                } catch { review.issues.append(files.relative(URL(fileURLWithPath: entry.path)) + "：" + error.localizedDescription) }
            }
            return review
        }
        guard let start = task.messages.firstIndex(where: { $0.id == messageID && $0.isHumanInput }) else { throw PetError("原始要求已变化") }
        let ids = task.messages[start...].filter(\.isHumanInput).map(\.id); review.roundIDs = Set(ids)
        if task.changeRounds == nil { review.issues.append("此任务没有按回合保存的文件检查点") }
        if let boundary = task.changeTrackingFromID, task.messages.firstIndex(where: { $0.id == boundary }).map({ start < $0 }) != false { review.issues.append("所选要求早于按回合记录的起点，不能完整撤回") }
        let rounds = (task.changeRounds ?? []).filter { review.roundIDs.contains($0.id) }.sorted { (ids.firstIndex(of: $0.id) ?? 0) < (ids.firstIndex(of: $1.id) ?? 0) }
        for round in rounds { if let warning = round.warning { review.issues.append(warning) } }
        let changes = rounds.flatMap(\.changes).filter { $0.restoredAt == nil }; review.changeIDs = Set(changes.map(\.id))
        let grouped = Dictionary(grouping: changes, by: \.path); review.paths = grouped.keys.sorted()
        for path in review.paths {
            do {
                let chain = grouped[path]!, first = chain[0], last = chain[chain.count - 1], url = try files.literalURL(path)
                guard !AgentFiles.sensitive(files.relative(url)), chain.allSatisfy({ $0.reviewOnly != true }), let after = last.afterState else { throw PetError("文件不具备独占且完整的检查点") }
                for pair in zip(chain, chain.dropFirst()) { guard pair.0.afterState?.matches(pair.1.beforeState) == true else { throw PetError("回合之间有其他文件修改，未覆盖这些内容") } }
                let current = try AgentCapturedFile.read(url.path, files: files, backups: nil)
                guard after.matches(current.state), ["file", "link", "missing"].contains(current.state.kind) else { throw PetError("文件又被修改或类型已变化，未覆盖后来的内容") }
                let desired = AgentCapturedFile(state: first.beforeState, signature: "", backup: first.backup)
                try verify(desired, backups: backups); review.entries.append(Entry(path: path, current: current, desired: desired))
            } catch { review.issues.append(files.relative(URL(fileURLWithPath: path)) + "：" + error.localizedDescription) }
        }
        if review.paths.isEmpty { review.issues.append("这些回合没有可撤回的文件修改") }; return review
    }
    private static func write(_ desired: AgentCapturedFile, path: String, expected: String, files: AgentFiles, backups: AgentFiles, temporaryName: String? = nil) throws -> String {
        let url = try files.literalURL(path)
        switch desired.state.kind {
        case "file":
            guard let backup = desired.backup else { throw PetError("检查点不存在") }
            try files.copyFile(backups.literalURL(backup), from: backups, to: url, permissions: desired.state.permissions ?? 0o644, expectedHash: desired.state.hash, expectedTarget: expected, temporaryName: temporaryName)
        case "link":
            guard let backup = desired.backup else { throw PetError("检查点不存在") }
            let data = try backups.readData(backups.literalURL(backup), maximum: 8192)
            guard AgentFiles.hash(data) == desired.state.hash, let target = String(data: data, encoding: .utf8) else { throw PetError("检查点校验失败") }
            try files.writeSymbolicLink(target, to: url, expectedTarget: expected, temporaryName: temporaryName)
        case "missing":
            let actual = try files.entryMetadata(url); guard actual.signature == expected else { throw PetError("文件已变化，未覆盖") }
            if actual.kind != "missing" { try files.remove(url) }
        default: throw PetError("路径类型不能自动撤回")
        }
        return try files.entryMetadata(url).signature
    }
    static func apply(_ expected: Review, store: AgentStore, continuation: AgentTaskRecord? = nil) throws {
        let review = try self.review(taskID: expected.taskID, from: expected.messageID, store: store)
        guard review.canApply else { throw PetError(review.issues.joined(separator: "\n")) }
        guard review.fingerprint == expected.fingerprint else { throw PetError("文件或任务已变化，请重新审阅") }
        let original = try validateTask(review.taskID, store: store), files = try AgentFiles(workspace: review.workspace)
        let backups = try AgentFiles(workspace: store.backupDirectory(review.taskID).path)
        if let pending = original.pendingFileRollback {
            guard continuation == nil else { throw PetError("请先恢复未完成的文件撤回") }
            let folder = try directory(pending.id, taskID: review.taskID, store: store), journal = try AgentFiles(workspace: folder.path)
            for entry in review.entries { guard try files.entryMetadata(files.literalURL(entry.path)).signature == entry.current.signature else { throw PetError("文件已变化，请重新审阅") } }
            for entry in review.entries {
                if let name = entry.temporaryName, let signature = entry.temporarySignature {
                    let temporary = try files.literalURL(URL(fileURLWithPath: entry.path).deletingLastPathComponent().appendingPathComponent(name).path)
                    guard try files.entryMetadata(temporary).signature == signature else { throw PetError("撤回暂存文件已变化，请重新审阅") }
                    if signature != "missing" { try files.remove(temporary) }
                }
                _ = try write(entry.desired, path: entry.path, expected: entry.current.signature, files: files, backups: journal, temporaryName: entry.temporaryName)
            }
            var recovered = original; recovered.pendingFileRollback = nil; recovered.updated = Date(); recovered.activityAt = recovered.updated
            recovered.events.append(AgentEvent(kind: "change", title: "已恢复撤回前文件", detail: "\(review.entries.count) 个文件；对话记录保留", status: "completed"))
            _ = try store.commitFileRollbackRecord(recovered, expectedHash: review.taskHash, transaction: folder.appendingPathComponent("recovery-" + UUID().uuidString))
            try? journal.writeData(Data("completed".utf8), to: journal.literalURL("outcome"), permissions: 0o600); return
        }
        let id = UUID().uuidString, folder = try directory(id, taskID: review.taskID, store: store)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("objects"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journal = try AgentFiles(workspace: folder.path), objects = try AgentFiles(workspace: folder.appendingPathComponent("objects").path)
        var entries = review.entries
        for i in entries.indices {
            let current = try AgentCapturedFile.read(entries[i].path, files: files, backups: objects)
            guard current.state == entries[i].current.state, current.signature == entries[i].current.signature else { throw PetError("备份期间文件已变化，请重新审阅") }; entries[i].current = current
            entries[i].temporaryName = ".bluefatfish-rollback-" + id + "-" + String(i) + ".tmp"
        }
        let manifest = Journal(id: id, taskID: review.taskID, messageID: review.messageID, workspace: review.workspace, entries: entries)
        let manifestData = try JSONEncoder().encode(manifest); guard manifestData.count <= 4_000_000 else { throw PetError("文件数量过多，请分回合撤回") }
        try journal.writeData(manifestData, to: journal.literalURL("manifest.json"), permissions: 0o600)
        let records = try AgentFiles(workspace: store.directory.path)
        try journal.copyFile(records.literalURL(review.taskID + ".json"), from: records, to: journal.literalURL("task-before.json"), expectedHash: review.taskHash, maximum: 20_000_000)
        var pending = original; pending.pendingFileRollback = AgentPendingFileRollback(id: id, messageID: review.messageID)
        let pendingHash = try store.commitFileRollbackRecord(pending, expectedHash: review.taskHash, transaction: folder.appendingPathComponent("pending-record"))
        var attempted: [Int] = [], written: [Int: String] = [:]
        do {
            for entry in entries { guard try files.entryMetadata(files.literalURL(entry.path)).signature == entry.current.signature else { throw PetError("文件已变化，请重新审阅") } }
            for (i, entry) in entries.enumerated() { attempted.append(i); written[i] = try write(entry.desired, path: entry.path, expected: entry.current.signature, files: files, backups: backups, temporaryName: entry.temporaryName) }
            var restored = original; let now = Date()
            for r in (restored.changeRounds ?? []).indices { for i in restored.changeRounds![r].changes.indices where review.changeIDs.contains(restored.changeRounds![r].changes[i].id) { restored.changeRounds?[r].changes[i].restoredAt = now } }
            for entry in entries {
                if let i = restored.changes.lastIndex(where: { $0.path == entry.path && $0.restoredAt == nil && $0.afterState?.matches(entry.current.state) == true }) {
                    restored.changes[i].afterHash = entry.desired.state.hash; restored.changes[i].afterKind = entry.desired.state.kind; restored.changes[i].afterPermissions = entry.desired.state.permissions
                    if restored.changes[i].beforeState.matches(entry.desired.state) { restored.changes[i].restoredAt = now }
                }
            }
            if let turn = restored.gitTurn?.id, review.roundIDs.contains(turn), let count = restored.gitTurn?.changes.count { for i in 0..<count { restored.gitTurn?.changes[i].restoredAt = now } }
            restored.pendingFileRollback = nil; restored.updated = now; restored.activityAt = now; restored.goalAccepted = nil; restored.completionEvidence = nil; restored.gitReview = nil; restored.gitPushReview = nil
            restored.events.append(AgentEvent(kind: "change", title: "已撤回所选回合及以后的文件", detail: "\(entries.count) 个文件；对话记录保留", status: "completed"))
            _ = try store.commitFileRollbackRecord(restored, expectedHash: pendingHash, transaction: folder.appendingPathComponent("completed-record"), continuation: continuation)
            try? journal.writeData(Data("completed".utf8), to: journal.literalURL("outcome"), permissions: 0o600)
        } catch {
            var retained: [String] = []
            for i in attempted.reversed() {
                do {
                    if let signature = written[i] { _ = try write(entries[i].current, path: entries[i].path, expected: signature, files: files, backups: journal, temporaryName: entries[i].temporaryName) }
                    else if try AgentCapturedFile.read(entries[i].path, files: files, backups: nil).state != entries[i].current.state { retained.append(entries[i].path) }
                } catch { retained.append(entries[i].path) }
            }
            if retained.isEmpty { do { _ = try store.commitFileRollbackRecord(original, expectedHash: pendingHash, transaction: folder.appendingPathComponent("cancelled-record")) } catch { retained.append("任务记录") } }
            try? journal.writeData(Data((retained.isEmpty ? "cancelled" : "needs-recovery").utf8), to: journal.literalURL("outcome"), permissions: 0o600)
            throw PetError(error.localizedDescription + (retained.isEmpty ? "；本次撤回未保存，文件已恢复" : "；请恢复未完成的文件撤回：" + retained.joined(separator: "、")))
        }
    }
}
