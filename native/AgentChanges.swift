import Foundation

@MainActor enum AgentChanges {
    static func warn(_ message: String, turnID: String, record: inout AgentTaskRecord) {
        if record.changeRounds == nil { record.changeRounds = []; record.changeTrackingFromID = turnID }
        if record.changeRounds?.contains(where: { $0.id == turnID }) != true { record.changeRounds?.append(AgentChangeRound(id: turnID)) }
        if let i = record.changeRounds?.firstIndex(where: { $0.id == turnID }) { record.changeRounds?[i].warning = message }
        if record.gitTurn?.id != turnID { record.gitTurn = AgentGitTurn(id: turnID, changes: []) }
        record.gitTurn?.warning = message; record.sideTask?.needsReview = true
    }
    static func record(_ changes: [AgentChange], taskID: String, turnID: String, store: AgentStore) {
        store.update(taskID) { record in
            if record.changeRounds == nil { record.changeRounds = []; record.changeTrackingFromID = turnID }
            if record.changeRounds?.contains(where: { $0.id == turnID }) != true { record.changeRounds?.append(AgentChangeRound(id: turnID)) }
            if record.gitTurn?.id != turnID { record.gitTurn = AgentGitTurn(id: turnID, changes: []) }
            for change in changes {
                func merged(_ previous: AgentChange) -> AgentChange {
                    var value = previous; value.afterHash = change.afterHash; value.afterKind = change.afterKind; value.afterPermissions = change.afterPermissions
                    if value.origin != change.origin { value.origin = "多项工具" }; return value
                }
                if let round = record.changeRounds?.firstIndex(where: { $0.id == turnID }) {
                    if let i = record.changeRounds?[round].changes.lastIndex(where: { $0.path == change.path && $0.restoredAt == nil }), let previous = record.changeRounds?[round].changes[i], previous.afterState?.matches(change.beforeState) == true, previous.reviewOnly != true, change.reviewOnly != true { record.changeRounds?[round].changes[i] = merged(previous) }
                    else { record.changeRounds?[round].changes.append(change) }
                }
                if let i = record.changes.lastIndex(where: { $0.path == change.path && $0.restoredAt == nil }), let last = record.changes[i].afterState, last.matches(change.beforeState), record.changes[i].reviewOnly != true, change.reviewOnly != true { record.changes[i] = merged(record.changes[i]) }
                else { record.changes.append(change) }
                if let i = record.gitTurn?.changes.firstIndex(where: { $0.path == change.path }) {
                    let previous = record.gitTurn!.changes[i]
                    if let last = previous.afterState, last.matches(change.beforeState), previous.reviewOnly != true, change.reviewOnly != true { let value = merged(previous); record.gitTurn?.changes[i] = value }
                    else { record.gitTurn?.changes[i] = change }
                } else { record.gitTurn?.changes.append(change) }
                if change.afterState?.kind == "file", !record.artifacts.contains(change.path) { record.artifacts.append(change.path) }
            }
        }
    }
    static func restore(_ change: AgentChange, taskID: String, store: AgentStore) throws {
        guard let task = store.task(taskID), task.status != .running, task.pendingFileCapture == nil, task.pendingFileRollback == nil, change.restoredAt == nil else { throw PetError("请先停止任务并等待变更记录完成") }
        guard change.reviewOnly != true else { throw PetError("执行期间有其他任务操作此项目，请审阅文件后手动处理") }
        let files = try AgentFiles(workspace: task.workspace), url = try files.literalURL(change.path)
        let current = try AgentCapturedFile.read(url.path, files: files, backups: nil)
        guard let expected = change.afterState, expected.matches(current.state) else { throw PetError("文件已被其他操作修改，未覆盖你的改动") }
        guard ["file", "link", "missing"].contains(current.state.kind), ["file", "link", "missing"].contains(change.beforeState.kind) else { throw PetError("路径类型已改变，请先处理目录内容；未覆盖任何文件") }
        if change.beforeState.kind != "missing" {
            guard let backup = change.backup, change.beforeHash != nil else { throw PetError("检查点不存在") }
            let backups = try AgentFiles(workspace: store.backupDirectory(taskID).path)
            let source = try backups.literalURL(backup)
            if change.beforeState.kind == "link" {
                let data = try backups.readData(source, maximum: 8192)
                guard AgentFiles.hash(data) == change.beforeHash, let target = String(data: data, encoding: .utf8) else { throw PetError("检查点校验失败") }
                try files.writeSymbolicLink(target, to: url, expectedTarget: current.signature)
            } else { try files.copyFile(source, from: backups, to: url, permissions: change.permissions ?? 0o644, expectedHash: change.beforeHash, expectedTarget: current.signature) }
        } else {
            guard try files.entryMetadata(url).signature == current.signature else { throw PetError("文件已被其他操作修改，未覆盖你的改动") }
            if current.state.kind != "missing" { try files.remove(url) }
        }
        store.update(taskID) { record in
            markRoundChangesRestored(change, record: &record)
            if let i = record.changes.firstIndex(where: { $0.id == change.id }) { record.changes[i].restoredAt = Date() }
            if let i = record.gitTurn?.changes.firstIndex(where: { $0.path == change.path }) { record.gitTurn?.changes[i].restoredAt = Date() }
            record.events.append(AgentEvent(kind: "change", title: "已撤回 " + String(url.path.dropFirst(files.root.path.count + 1)), status: "completed"))
        }
    }
    static func markRoundChangesRestored(_ change: AgentChange, record: inout AgentTaskRecord) {
        guard let rounds = record.changeRounds, var state = change.afterState else { return }
        for r in rounds.indices.reversed() {
            for i in rounds[r].changes.indices.reversed() {
                let value = rounds[r].changes[i]
                guard value.path == change.path, value.restoredAt == nil else { continue }
                guard value.afterState?.matches(state) == true else { return }
                record.changeRounds?[r].changes[i].restoredAt = Date(); state = value.beforeState
                if state.matches(change.beforeState) { return }
            }
        }
    }
    struct Comparison {
        var directory: URL; var left: URL; var right: URL; var state: AgentFileState; var changedAgain: Bool
        var fingerprint: String { state.kind + ":" + (state.hash ?? "") + ":" + String(state.permissions ?? -1) }
    }
    static func comparison(_ change: AgentChange, taskID: String, store: AgentStore, strict: Bool) throws -> Comparison {
        guard let task = store.task(taskID) else { throw PetError("任务不存在") }
        let files = try AgentFiles(workspace: task.workspace), current = try files.literalURL(change.path)
        let actual = try AgentCapturedFile.read(current.path, files: files, backups: nil)
        if strict, change.reviewOnly == true { throw PetError("执行期间有其他任务操作此项目，请核对未提交修改") }
        let changedAgain = change.afterState?.matches(actual.state) != true
        if strict && changedAgain { throw PetError("文件在本轮修改后又有变化，请改选“未提交”查看当前内容") }
        guard ["file", "link", "missing"].contains(actual.state.kind), ["file", "link", "missing"].contains(change.beforeState.kind) else { throw PetError("路径类型已改变，请在未提交修改中核对目录内容") }
        let backups = try AgentFiles(workspace: store.backupDirectory(taskID).path), directory = backups.root.appendingPathComponent("compare-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let targets = try AgentFiles(workspace: directory.path)
        func materialize(_ state: AgentFileState, source: URL?, sourceFiles: AgentFiles, name: String) throws -> URL {
            if state.kind == "missing" { return URL(fileURLWithPath: "/dev/null") }
            guard let source, let expected = state.hash else { throw PetError("检查点不存在") }
            let destination = directory.appendingPathComponent(name)
            if state.kind == "link" {
                let data = sourceFiles.root == files.root ? Data(try sourceFiles.symbolicLink(source).utf8) : try sourceFiles.readData(source, maximum: 8192)
                guard AgentFiles.hash(data) == expected, let value = String(data: data, encoding: .utf8) else { throw PetError("检查点校验失败") }
                try targets.writeSymbolicLink(value, to: destination, expectedTarget: "missing")
            } else { try targets.copyFile(source, from: sourceFiles, to: destination, permissions: state.permissions ?? 0o644, expectedHash: expected) }
            return destination
        }
        do {
            let beforeSource = try change.backup.map { try backups.literalURL($0) }
            let left = try materialize(change.beforeState, source: beforeSource, sourceFiles: backups, name: "before")
            let right = try materialize(actual.state, source: current, sourceFiles: files, name: "after")
            guard try files.entryMetadata(current).signature == actual.signature else { throw PetError("文件已变化，请重新审阅") }
            return Comparison(directory: directory, left: left, right: right, state: actual.state, changedAgain: changedAgain)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    static func labels(_ text: String, path: String) -> String {
        func label(_ value: String) -> String { value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("\"") || value.contains("\\") ? value.debugDescription : value }
        let old = label("a/" + path), new = label("b/" + path); var header = true
        return text.components(separatedBy: "\n").map { line in
            if line.hasPrefix("diff --git ") { header = true }
            if line.hasPrefix("@@") || line == "GIT binary patch" { header = false }
            guard header else { return line }
            if line.hasPrefix("diff --git ") { return "diff --git " + old + " " + new }
            if line.hasPrefix("--- "), !line.hasSuffix("/dev/null") { return "--- " + old }
            if line.hasPrefix("+++ "), !line.hasSuffix("/dev/null") { return "+++ " + new }
            return line
        }.joined(separator: "\n")
    }
    static func diff(_ change: AgentChange, taskID: String, store: AgentStore) async throws -> String {
        let value = try comparison(change, taskID: taskID, store: store, strict: false)
        defer { try? FileManager.default.removeItem(at: value.directory) }
        let patch = try await fileDiff(left: value.left, right: value.right, directory: value.directory, protectedData: store.directory.deletingLastPathComponent())
        return (value.changedAgain ? "文件在工具修改后又有变化；撤回不会覆盖后续修改。\n\n" : "") + labels(patch, path: URL(fileURLWithPath: change.path).lastPathComponent)
    }
    static func fileDiff(left: URL, right: URL, directory: URL, protectedData: URL, maximumOutput: Int = 100_000) async throws -> String {
        let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: directory, scratch: directory, network: false, timeout: 15, readOnly: true, maximumOutput: maximumOutput, protectedData: protectedData, arguments: ["--no-pager", "-c", "core.fsmonitor=false", "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--binary", "--", left.path, right.path])
        guard [0, 1].contains(result.exitCode ?? -1), result.truncated != true else { throw PetError("差异较大或不可读取，请分批审阅") }
        return result.stdout ?? ""
    }
}
