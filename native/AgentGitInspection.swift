import Foundation

struct AgentGitTurn: Codable { var id: String; var changes: [AgentChange] }
enum AgentGitSource: String, CaseIterable, Codable {
    case lastTurn, uncommitted, unstaged, staged, committed, branch
    var title: String { [.lastTurn: "本轮修改", .uncommitted: "未提交", .unstaged: "未暂存", .staged: "已暂存", .committed: "已提交", .branch: "分支"][self]! }
    var usesRevision: Bool { self == .committed || self == .branch }
}
struct AgentGitInspection {
    var source: AgentGitSource; var revision: String; var paths: [String]; var changes: [AgentGitChange]
    var head: String?; var hash: String; var diff: String; var additions: Int; var deletions: Int; var binaryFiles: Int
}
enum AgentGitFileAction: Equatable { case stage, unstage, restore }
struct AgentGitFileResult { var checkpointID: String?; var trashedPath: String? }

@MainActor extension AgentGit {
    private func resolvedCommit(_ revision: String) async throws -> String {
        guard !revision.isEmpty, revision.utf8.count <= 512, !revision.contains("\0"), !revision.hasPrefix("-") else { throw PetError("请选择有效的提交或分支") }
        let value = try await output(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"])
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func diffArguments(_ source: AgentGitSource, revision: String) async throws -> (arguments: [String], identity: String) {
        switch source {
        case .unstaged: return (["diff"], "index")
        case .staged: return (["diff", "--cached"], "index")
        case .committed:
            let commit = try await resolvedCommit(revision.isEmpty ? "HEAD" : revision)
            let parents = try await output(["rev-list", "--parents", "-n", "1", commit]).split(whereSeparator: \.isWhitespace).map(String.init)
            return parents.count > 1 ? (["diff", parents[1], commit], commit) : (["diff-tree", "--root", "--no-commit-id", "-r", commit], commit)
        case .branch:
            let target = try await resolvedCommit(revision)
            let base = try await output(["merge-base", "HEAD", target]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (["diff", base, "HEAD"], target + ":" + base)
        default: throw PetError("此来源不使用 Git 修订范围")
        }
    }
    func inspectionChanges(source: AgentGitSource, revision: String) async throws -> [AgentGitChange] {
        if source == .uncommitted { return try await status().changes }
        if source == .lastTurn {
            guard let task = store.task(taskID), let turn = task.gitTurn, turn.id == (task.messages.last(where: \.isHumanInput)?.id ?? task.id) else { return [] }
            return try turn.changes.filter { $0.afterHash != nil }.map { AgentGitChange(status: $0.existed ? "M" : "A", path: try paths([$0.path])[0]) }
        }
        let range = try await diffArguments(source, revision: revision)
        let raw = try await output(range.arguments + ["--no-renames", "--name-status", "-z", "--"])
        let parts = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard parts.count % 2 == 0 else { throw PetError("Git 文件列表不完整") }
        var changes = stride(from: 0, to: parts.count, by: 2).map { AgentGitChange(status: parts[$0], path: parts[$0 + 1]) }
        if source == .unstaged { changes += try await status().changes.filter { $0.status == "??" } }
        return changes
    }
    func inspect(source: AgentGitSource, revision: String, requested: [String]) async throws -> AgentGitInspection {
        let state = try await status(), selected = try paths(requested)
        let changes = try await inspectionChanges(source: source, revision: revision)
        guard selected.allSatisfy({ path in changes.contains { $0.path == path || $0.previousPath == path } }) else { throw PetError("所选文件或来源已变化，请刷新后重新审阅") }
        let options = ["--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--binary"]
        var diff = "", identity = "", fingerprint = "", additions = 0, deletions = 0
        if source == .lastTurn {
            guard let turn = store.task(taskID)?.gitTurn else { throw PetError("本轮尚无文件修改记录") }
            identity = turn.id
            let backups = try AgentFiles(workspace: store.backupDirectory(taskID).path)
            let scratch = try store.backupDirectory(taskID).deletingLastPathComponent().appendingPathComponent("git", isDirectory: true)
            for path in selected {
                guard let change = turn.changes.first(where: { $0.path == files.root.appendingPathComponent(path).path }), let expected = change.afterHash else { throw PetError("本轮检查点不存在") }
                let current = try files.readData(files.resolve(path))
                guard AgentFiles.hash(current) == expected else { throw PetError("文件在本轮修改后又有变化，请改选“未提交”查看当前内容") }
                let before: Data
                if change.existed {
                    guard let backup = change.backup else { throw PetError("本轮检查点不存在") }
                    before = try backups.readData(backups.resolve(backup))
                    guard AgentFiles.hash(before) == change.beforeHash else { throw PetError("本轮检查点校验失败") }
                } else { before = Data() }
                let left = scratch.appendingPathComponent("review-before-" + change.id), right = scratch.appendingPathComponent("review-after-" + change.id)
                try before.write(to: left, options: .atomic); try current.write(to: right, options: .atomic)
                let result = try await run(["diff", "--no-index"] + options + ["--", left.path, right.path])
                guard [0, 1].contains(result.exitCode ?? -1), result.truncated != true else { throw PetError("本轮差异较大或不可读取，请选择较小的文件") }
                func label(_ value: String) -> String { value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("\"") || value.contains("\\") ? value.debugDescription : value }
                let old = label("a/" + path), new = label("b/" + path)
                var header = true
                diff += (result.stdout ?? "").components(separatedBy: "\n").map { line in
                    if line.hasPrefix("@@") || line == "GIT binary patch" { header = false }
                    guard header else { return line }
                    if line.hasPrefix("diff --git ") { return "diff --git " + old + " " + new }
                    if line.hasPrefix("--- ") { return "--- " + old }
                    if line.hasPrefix("+++ ") { return "+++ " + new }
                    return line
                }.joined(separator: "\n"); fingerprint += change.id + expected
            }
        } else if source == .uncommitted {
            let value = try await self.diff(selected); diff = value.diff
        } else {
            let range = try await diffArguments(source, revision: revision); identity = range.identity
            for path in selected {
                let untracked = source == .unstaged && state.changes.contains { $0.path == path && $0.status == "??" }
                let result = try await run(untracked ? ["diff", "--no-index"] + options + ["--", "/dev/null", path] : range.arguments + options + ["-p", "--", path])
                guard result.exitCode == 0 || untracked && result.exitCode == 1 else { throw PetError(result.text) }
                guard result.truncated != true else { throw PetError("差异较大，请选择更小的文件") }; diff += result.stdout ?? ""
            }
        }
        guard diff.utf8.count <= 100_000 else { throw PetError("差异较多，请分批审阅") }
        var inHunk = false
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("diff --git ") { inHunk = false }
            if line.hasPrefix("@@") { inHunk = true }
            if inHunk && line.hasPrefix("+") { additions += 1 }
            if inHunk && line.hasPrefix("-") { deletions += 1 }
        }
        if !source.usesRevision {
            fingerprint += try await output(["ls-files", "--stage", "-z", "--"] + selected)
            for path in selected where source != .staged {
                let url = try files.resolve(path)
                if FileManager.default.fileExists(atPath: url.path) { fingerprint += path + AgentFiles.hash(try files.readData(url)) }
                else { fingerprint += path + "<deleted>" }
            }
        }
        var branchRef: String?
        if source == .staged {
            let symbolic = try await run(["symbolic-ref", "--quiet", "HEAD"])
            branchRef = symbolic.failed ? "HEAD" : symbolic.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
            identity += "\0" + (branchRef ?? "")
        }
        let hash = AgentFiles.hash(Data(([source.rawValue, revision, identity, state.head ?? "unborn", selected.joined(separator: "\0"), fingerprint, diff].joined(separator: "\0")).utf8))
        if source == .staged {
            store.update(taskID) { $0.gitReview = AgentGitReview(paths: selected, head: state.head, hash: hash, diff: diff, source: .staged, branchRef: branchRef) }
        }
        return AgentGitInspection(source: source, revision: revision, paths: selected, changes: changes, head: state.head, hash: hash, diff: diff, additions: additions, deletions: deletions, binaryFiles: diff.components(separatedBy: "GIT binary patch").count - 1)
    }
    func apply(_ action: AgentGitFileAction, inspection: AgentGitInspection) async throws -> AgentGitFileResult {
        try validateWorkspace()
        guard let task = store.task(taskID), !task.archived, ![.running, .waiting].contains(task.status) else { throw PetError("请先停止或处理当前任务") }
        guard inspection.paths.count == 1, !inspection.source.usesRevision else { throw PetError("请选择一个当前文件") }
        let current = try await inspect(source: inspection.source, revision: inspection.revision, requested: inspection.paths)
        guard current.hash == inspection.hash else { throw PetError("文件、暂存区或 HEAD 已变化，请重新审阅") }
        let path = current.paths[0], state = try await status()
        guard let change = state.changes.first(where: { $0.path == path || $0.previousPath == path }) else { throw PetError("文件状态已变化，请刷新后重新审阅") }
        guard !change.status.contains("U"), !["AA", "DD"].contains(change.status) else { throw PetError("请先处理文件冲突") }
        let selected = try paths(current.source == .uncommitted ? [change.path] + (change.previousPath.map { [$0] } ?? []) : [path])
        let result: AgentToolResult
        switch action {
        case .stage:
            guard [.uncommitted, .unstaged, .lastTurn].contains(current.source) else { throw PetError("请从未暂存来源选择文件") }
            result = try await run(["add", "--"] + selected, write: true)
        case .unstage:
            guard [.uncommitted, .staged].contains(current.source), change.status != "??" else { throw PetError("请选择已暂存文件") }
            result = try await run(state.head == nil ? ["update-index", "--force-remove", "--"] + selected : ["reset", "--quiet", "HEAD", "--"] + selected, write: true)
        case .restore:
            guard [.uncommitted, .unstaged].contains(current.source) else { throw PetError("请从未暂存来源恢复文件") }
            let url = try files.resolve(path)
            if change.status == "??" {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                return AgentGitFileResult(trashedPath: trashed?.path)
            }
            let exists = FileManager.default.fileExists(atPath: url.path)
            let before = exists ? try files.readData(url) : nil
            var checkpoint = AgentChange(path: url.path, existed: exists, beforeHash: before.map(AgentFiles.hash))
            checkpoint.permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
            if let before {
                let backup = try store.backupDirectory(taskID).appendingPathComponent(checkpoint.id)
                try before.write(to: backup, options: .atomic); checkpoint.backup = backup.path
            }
            store.update(taskID) { $0.changes.append(checkpoint) }
            guard store.writeError == nil else { throw PetError("检查点保存失败，未恢复文件：" + (store.writeError ?? "")) }
            do { result = try await run(["restore", "--worktree", "--", path], write: true) }
            catch {
                if let after = try? files.readData(url), AgentFiles.hash(after) != checkpoint.beforeHash {
                    store.update(taskID) { record in if let i = record.changes.firstIndex(where: { $0.id == checkpoint.id }) { record.changes[i].afterHash = AgentFiles.hash(after) } }
                }
                throw error
            }
            guard !result.failed else { throw PetError(result.text) }
            checkpoint.afterHash = AgentFiles.hash(try files.readData(url))
            store.update(taskID) { record in if let i = record.changes.firstIndex(where: { $0.id == checkpoint.id }) { record.changes[i] = checkpoint } }
            guard store.writeError == nil else { throw PetError("文件已恢复，检查点保存失败：" + (store.writeError ?? "")) }
            return AgentGitFileResult(checkpointID: checkpoint.id)
        }
        guard !result.failed else { throw PetError(result.text) }
        return AgentGitFileResult()
    }
}
