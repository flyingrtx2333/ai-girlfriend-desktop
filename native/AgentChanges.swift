import Foundation

@MainActor enum AgentChanges {
    static func restore(_ change: AgentChange, taskID: String, store: AgentStore) throws {
        guard let task = store.task(taskID), task.status != .running, change.restoredAt == nil else { throw PetError("请先停止任务") }
        let files = try AgentFiles(workspace: task.workspace), url = try files.resolve(change.path)
        let current = try files.readData(url)
        guard let expected = change.afterHash, AgentFiles.hash(current) == expected else { throw PetError("文件已被其他操作修改，未覆盖你的改动") }
        if change.existed {
            guard let backup = change.backup else { throw PetError("检查点不存在") }
            let backups = try AgentFiles(workspace: store.backupDirectory(taskID).path)
            let data = try backups.readData(backups.resolve(backup))
            guard AgentFiles.hash(data) == change.beforeHash else { throw PetError("检查点校验失败") }
            try files.writeData(data, to: url, permissions: change.permissions ?? 0o644)
        } else { try files.remove(url) }
        store.update(taskID) { record in
            if let i = record.changes.firstIndex(where: { $0.id == change.id }) { record.changes[i].restoredAt = Date() }
            record.events.append(AgentEvent(kind: "change", title: "已撤回 " + files.relative(url), status: "completed"))
        }
    }
    static func diff(_ change: AgentChange, taskID: String, store: AgentStore) async throws -> String {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        let files = try AgentFiles(workspace: task.workspace), current = try files.resolve(change.path)
        _ = try files.readData(current)
        let scratch = try store.backupDirectory(taskID).deletingLastPathComponent()
        let before: String
        if change.existed {
            guard let backup = change.backup else { throw PetError("检查点不存在") }
            let backups = try AgentFiles(workspace: scratch.path); _ = try backups.readData(backups.resolve(backup)); before = backup
        } else {
            let empty = scratch.appendingPathComponent("empty-before")
            try Data().write(to: empty, options: .atomic); before = empty.path
        }
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let result = try await AgentCommand().run(command: "/usr/bin/diff -u -- " + quote(before) + " " + quote(current.path), workspace: files.root, scratch: scratch, network: false, timeout: 10, protectedData: store.directory.deletingLastPathComponent())
        return result.text
    }
}
