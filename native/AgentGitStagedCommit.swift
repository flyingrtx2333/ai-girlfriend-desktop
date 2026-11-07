import Foundation

@MainActor extension AgentGit {
    // Git's alternate index lets selected staged blobs become a commit without
    // ever rewriting the user's index or reading their later working versions.
    func commitStaged(_ reviewed: AgentGitReview, message: String) async throws -> AgentGitCommit {
        let current = try await diff(reviewed.paths, source: .staged)
        guard current.hash == reviewed.hash, !current.diff.isEmpty, let expectedRef = reviewed.branchRef else { throw PetError("暂存区、分支或 HEAD 已变化，请重新审阅后提交") }
        try await validateHooks()
        let pending = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"]
        var pendingPaths: [URL] = []
        for name in pending {
            let raw = try await output(["rev-parse", "--git-path", name]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: raw, relativeTo: files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: url.path) else { throw PetError("请先完成当前合并、变基或拣选，再提交所选暂存内容") }
            pendingPaths.append(url)
        }
        let state = try await status()
        guard !state.changes.contains(where: { reviewed.paths.contains($0.path) && ($0.status.contains("U") || ["AA", "DD"].contains($0.status)) }) else { throw PetError("请先处理所选文件的合并冲突") }
        let entries = try await run(["ls-files", "--stage", "-z", "--"] + reviewed.paths)
        guard !entries.failed, entries.truncated != true, let entryData = entries.stdoutData else { throw PetError("无法读取所选文件的暂存条目") }
        let session = scratch.appendingPathComponent("commit-" + UUID().uuidString), hooks = session.appendingPathComponent("hooks"), emptyHooks = session.appendingPathComponent("empty-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: emptyHooks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: session) }
        let environment = ["GIT_INDEX_FILE": session.appendingPathComponent("index").path]
        func temporary(_ args: [String], input: URL? = nil) async throws -> String {
            let result = try await run(["-c", "core.hooksPath=" + emptyHooks.path] + args, write: true, environment: environment, inputFile: input)
            guard !result.failed, result.truncated != true else { throw PetError(result.text) }
            return result.stdout ?? ""
        }
        _ = try await temporary(["read-tree", reviewed.head ?? "--empty"])
        _ = try await temporary(["update-index", "--force-remove", "--"] + reviewed.paths)
        if !entryData.isEmpty {
            let input = session.appendingPathComponent("entries"); try entryData.write(to: input, options: .atomic)
            _ = try await temporary(["update-index", "-z", "--index-info"], input: input)
        }
        let tree = try await temporary(["write-tree"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil else { throw PetError("无法核对暂存快照") }
        let git = Self.quote(try Self.executablePath()), expectedHead = reviewed.head ?? "unborn"
        let guardScript = """
        actual_ref=$(\(git) symbolic-ref --quiet HEAD 2>/dev/null) || actual_ref=HEAD
        if [ "$actual_ref" != \(Self.quote(expectedRef)) ]; then
          printf '%s\\n' '当前分支已变化，未提交暂存快照' >&2; exit 1
        fi
        actual_head=$(\(git) rev-parse --verify HEAD 2>/dev/null) || actual_head=unborn
        if [ "$actual_head" != \(Self.quote(expectedHead)) ]; then
          printf '%s\\n' 'HEAD 已变化，未提交暂存快照' >&2; exit 1
        fi
        actual_tree=$(\(git) write-tree) || exit $?
        if [ "$actual_tree" != \(Self.quote(tree)) ]; then
          printf '%s\\n' 'Git Hook 改变了已审阅的暂存快照，请重新审阅' >&2; exit 1
        fi
        """ + pendingPaths.map { "\nif [ -e " + Self.quote($0.path) + " ]; then printf '%s\\n' 'Git 操作状态已变化，未提交快照' >&2; exit 1; fi" }.joined()
        for name in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "post-index-change"] {
            let raw = try await output(["rev-parse", "--git-path", "hooks/" + name]).trimmingCharacters(in: .whitespacesAndNewlines)
            let original = URL(fileURLWithPath: raw, relativeTo: files.root.appendingPathComponent("", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
            let executable = FileManager.default.isExecutableFile(atPath: original.path)
            if executable {
                guard original.path.hasPrefix(files.root.path + "/") || original.path.hasPrefix(directory.path + "/") else { throw PetError("Git Hook 位于当前隔离范围之外") }
            }
            var script = "#!/bin/sh\n"
            if executable { script += Self.quote(original.path) + " \"$@\" || exit $?\n" }
            if !["post-commit", "post-index-change"].contains(name) { script += guardScript + "\n" }
            let destination = hooks.appendingPathComponent(name)
            try Data(script.utf8).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        }
        let finalReview = try await diff(reviewed.paths, source: .staged)
        guard finalReview.hash == reviewed.hash else { throw PetError("暂存区或 HEAD 已变化，请重新审阅") }
        try validateWorkspace()
        if let task = store.task(taskID) { try store.agents.check(AgentToolCall(id: "git-commit-final", name: "git_commit", arguments: "{}"), task: task, store: store) }
        try Task.checkCancellation()
        store.update(taskID) { $0.gitReview = nil }
        guard store.writeError == nil else { throw PetError("无法保存提交状态，未执行提交") }
        let result = try await run(["-c", "core.hooksPath=" + hooks.path, "commit", "-m", message], write: true, environment: environment)
        guard !result.failed else { throw PetError("暂存提交未完成，请核对实际 Git 状态：\n" + result.text) }
        let after = try await status()
        guard let head = after.head, head != reviewed.head else { throw PetError("Git 未生成新的提交，请核对实际状态") }
        let actualTree = try await output(["rev-parse", head + "^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = try await run(["symbolic-ref", "--quiet", "HEAD"])
        let actualRef = reference.failed ? "HEAD" : reference.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineage = try await output(["rev-list", "--parents", "-n", "1", head]).split(whereSeparator: \.isWhitespace).map(String.init)
        guard actualRef == expectedRef, actualTree == tree, Array(lineage.dropFirst()) == (reviewed.head.map { [$0] } ?? []) else { throw PetError("提交后 HEAD 与已审阅快照不一致，请核对实际提交 " + head) }
        return AgentGitCommit(commit: head, branch: after.branch, output: result.text)
    }
}
