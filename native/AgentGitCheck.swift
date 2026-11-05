import AppKit

@MainActor extension AppDelegate {
    func runAgentGitCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let fm = FileManager.default, repo = output.appendingPathComponent("repo", isDirectory: true), temporary = output.appendingPathComponent("tmp", isDirectory: true)
            try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            let odd = "space'文件\nline.txt"
            for (path, text) in [("target.txt", "before\n"), ("user.txt", "untouched\n"), (odd, "old unicode\n")] { try Data(text.utf8).write(to: repo.appendingPathComponent(path)) }
            func setup(_ args: [String]) async throws -> String {
                let result = try await AgentCommand().run(command: ([try AgentGit.executablePath(), "-C", repo.path] + args).map(AgentGit.quote).joined(separator: " "), workspace: output, scratch: temporary, network: false, timeout: 10, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory)
                guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
            }
            _ = try await setup(["init", "-b", "main"]); _ = try await setup(["config", "user.name", "Agent Fixture"]); _ = try await setup(["config", "user.email", "agent@example.invalid"])
            _ = try await setup(["config", "core.hooksPath", ".git/hooks"]); _ = try await setup(["config", "commit.gpgsign", "false"])
            _ = try await setup(["add", "--", "."]); _ = try await setup(["commit", "-m", "public fixture"])
            try Data("user staged\n".utf8).write(to: repo.appendingPathComponent("user.txt")); _ = try await setup(["add", "--", "user.txt"])
            try Data("after\n".utf8).write(to: repo.appendingPathComponent("target.txt")); try Data("new unicode\n".utf8).write(to: repo.appendingPathComponent(odd))
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let id = tasks.create(title: "Git 只读验证", workspace: repo.path, mode: .ask)
            let git = try AgentGit(store: tasks, taskID: id, directory: repo.appendingPathComponent(".git"))
            let state = try await git.status(), review = try await git.diff(["target.txt", odd])
            checks["nativeGitStatusUsesRealIndex"] = state.branch == "main" && state.changes.contains { $0.path == "user.txt" && $0.status.hasPrefix("M") }
            checks["nulPathsPreserveQuotesUnicodeNewline"] = state.changes.contains { $0.path == odd }
            checks["nativeDiffMatchesActualFiles"] = review.diff.contains("-before") && review.diff.contains("+after") && review.diff.contains("+new unicode")
            checks["reviewDoesNotAlterUserStaging"] = try await setup(["show", ":user.txt"]) == "user staged\n"
            let previous = review.hash
            try Data("after second edit\n".utf8).write(to: repo.appendingPathComponent("target.txt"))
            checks["reviewFingerprintChangesWithFile"] = try await git.diff(["target.txt", odd]).hash != previous
            try Data("after\n".utf8).write(to: repo.appendingPathComponent("target.txt"))
            let privateFile = store.directory.appendingPathComponent("authority-fixture.json")
            try Data("original authority".utf8).write(to: privateFile)
            let scratch = try tasks.backupDirectory(id).deletingLastPathComponent().appendingPathComponent("command-tmp", isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let blocked = try await AgentCommand().run(command: "printf changed > " + AgentGit.quote(privateFile.path), workspace: output, scratch: scratch, network: false, timeout: 5, protectedData: store.directory)
            let guarded = try String(contentsOf: privateFile, encoding: .utf8)
            checks["commandsCannotRewriteAgentAuthority"] = blocked.failed && guarded == "original authority"
            let readonly = try await AgentCommand().run(command: "printf bad > target.txt", workspace: repo, scratch: scratch, network: false, timeout: 5, readOnly: true)
            checks["readOnlyCommandsCannotModifyProject"] = readonly.failed && (try? String(contentsOf: repo.appendingPathComponent("target.txt"), encoding: .utf8)) == "after\n"
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Git 原生检查失败，未进行模型调用") }
            if CommandLine.arguments.contains("--git-ui-only") {
                let window = AgentGitWindow(store: tasks, taskID: id) { _ in }
                checks.merge(await window.checkLayout(output)) { _, value in value }; window.close()
                let report: [String: Any] = ["success": checks.values.allSatisfy { $0 }, "checks": checks, "scope": "Native Git public fixtures and layout only; no model calls."]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-report.json")); return
            }
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("真实 Git 流程验收需要 --live-agent") }
            let linked = output.appendingPathComponent("linked", isDirectory: true)
            _ = try await setup(["worktree", "add", "-b", "fixture-linked", linked.path, "HEAD"])
            try Data("worktree-only\n".utf8).write(to: linked.appendingPathComponent("target.txt"))
            let profile = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var p = PreferencesStore(directory: profile).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.contextTokens = max(32_768, p.contextTokens); p.replyTokens = 2048; store.preferences = p
            let liveID = tasks.create(title: "真实模型读取工作树", workspace: linked.path, mode: .ask)
            runtime.submit("只用 git_status 和 git_diff 查看 target.txt 的变化，告诉我当前分支以及内容从什么变成了什么。不要修改任何文件。", taskID: liveID)
            let deadline = Date().addingTimeInterval(100); var connected = false
            while Date() < deadline, let task = tasks.task(liveID), [.ready, .running, .waiting].contains(task.status) {
                if task.status == .waiting, let call = task.pendingCalls.first {
                    guard ["git_status", "git_diff"].contains(call.name), task.approvals.last?.gitDirectory == repo.appendingPathComponent(".git").path else { throw PetError("工作树要求了预期外授权") }
                    connected = true; runtime.decide(taskID: liveID, callID: call.id, decision: "allow")
                }
                await wait(0.1)
            }
            let task = tasks.task(liveID)!
            checks["linkedMetadataRequiresScopedApproval"] = connected && task.gitDirectory == repo.appendingPathComponent(".git").path
            checks["realModelReadsGitToolsIncludingEmptyArgs"] = task.status == .completed && task.events.contains { $0.title == "git_status" && $0.status == "completed" } && task.events.contains { $0.title == "git_diff" && $0.status == "completed" } && task.summary.contains("before") && task.summary.contains("worktree-only")
            let originalText = try String(contentsOf: repo.appendingPathComponent("target.txt"), encoding: .utf8), linkedText = try String(contentsOf: linked.appendingPathComponent("target.txt"), encoding: .utf8)
            checks["linkedWorktreeDoesNotModifyOriginal"] = originalText == "after\n" && linkedText == "worktree-only\n"
            report["live"] = ["model": p.model, "status": task.status.rawValue, "result": task.summary]
            let stale = try await git.diff(["target.txt"]), originalHead = try await setup(["rev-parse", "HEAD"])
            try Data("external edit\n".utf8).write(to: repo.appendingPathComponent("target.txt"))
            do { _ = try await git.commit(paths: stale.paths, message: "must not commit stale review", reviewHash: stale.hash); checks["staleReviewPreventsCommit"] = false }
            catch { checks["staleReviewPreventsCommit"] = try await setup(["rev-parse", "HEAD"]) == originalHead }
            try Data("after\n".utf8).write(to: repo.appendingPathComponent("target.txt"))
            let hooks = try AgentFiles(workspace: repo.path), hook = try hooks.resolve(".git/hooks/pre-commit")
            try hooks.writeData(Data("#!/bin/sh\nexit 17\n".utf8), to: hook, permissions: 0o755)
            let rejected = try await git.diff(["target.txt"])
            do { _ = try await git.commit(paths: rejected.paths, message: "must respect hook", reviewHash: rejected.hash); checks["failingHookPreventsCommit"] = false }
            catch { checks["failingHookPreventsCommit"] = try await setup(["rev-parse", "HEAD"]) == originalHead }
            try hooks.writeData(Data("#!/bin/sh\nprintf checked > hook-ran.txt\n".utf8), to: hook, permissions: 0o755)
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Git 审阅或 Hook 检查失败") }
            let commitID = tasks.create(title: "真实模型审阅并提交", workspace: repo.path, mode: .agent)
            runtime.submit("将 target.txt 改成一行 agent-committed，新增 notes.md 内容为一行 本地提交验证。先检查 Git 状态，只审阅并提交 target.txt 和 notes.md，提交说明 Agent fixture commit。使用 git_commit，不运行普通终端。不提交 user.txt 或其他文件。提交成功后，再用 git_create_worktree 创建分支 agent-proof，并用 git_status 确认原项目状态。", taskID: commitID)
            let commitDeadline = Date().addingTimeInterval(120); var approvals: [String] = [], heldBeforeCommit = false
            while Date() < commitDeadline, let current = tasks.task(commitID), [.ready, .running, .waiting].contains(current.status) {
                if current.status == .waiting, let call = current.pendingCalls.first {
                    guard ["git_commit", "git_create_worktree"].contains(call.name) else { runtime.cancel(commitID); throw PetError("真实 Git 提交流程要求了预期外授权：" + call.name) }
                    if call.name == "git_commit" {
                        guard let review = current.gitReview, Set(review.paths) == Set(["target.txt", "notes.md"]), review.hash == call.object["review_hash"] as? String, review.diff.contains("+agent-committed"), review.diff.contains("+本地提交验证") else { runtime.cancel(commitID); throw PetError("审批差异与实际目标不一致") }
                        heldBeforeCommit = try await setup(["rev-parse", "HEAD"]) == originalHead
                    }
                    approvals.append(call.name); runtime.decide(taskID: commitID, callID: call.id, decision: "allow")
                }
                await wait(0.1)
            }
            let committedTask = tasks.task(commitID)!
            if committedTask.status != .completed { runtime.cancel(commitID); report["commitEvents"] = committedTask.events.map { ["tool": $0.title, "status": $0.status, "detail": $0.detail] } }
            let changed = try await setup(["show", "--pretty=format:", "--name-only", "-z", "HEAD"]).components(separatedBy: "\0").filter { !$0.isEmpty }
            checks["realModelCommitWaitsForReviewApproval"] = heldBeforeCommit && approvals.contains("git_commit") && committedTask.events.contains { $0.title == "git_commit" && $0.status == "completed" }
            checks["commitContainsOnlySelectedFiles"] = Set(changed) == Set(["target.txt", "notes.md"])
            let stagedUser = try await setup(["show", ":user.txt"]), committedUser = try await setup(["show", "HEAD:user.txt"])
            checks["commitPreservesOtherStagedContent"] = stagedUser == "user staged\n" && committedUser == "untouched\n"
            checks["commitRunsConfiguredHook"] = (try? String(contentsOf: repo.appendingPathComponent("hook-ran.txt"), encoding: .utf8)) == "checked"
            let child = tasks.tasks.first { $0.parentID == commitID }
            if let child, let workspace = child.workspace {
                let childFiles = try AgentFiles(workspace: workspace), childText = try String(contentsOf: childFiles.resolve("target.txt"), encoding: .utf8)
                checks["realWorktreeCreatesIsolatedTask"] = approvals.contains("git_create_worktree") && child.gitDirectory == repo.appendingPathComponent(".git").path && childText == "agent-committed\n"
                try childFiles.writeData(Data("isolated edit\n".utf8), to: childFiles.resolve("target.txt"))
                checks["worktreeEditsPreserveOriginalBranchAndFiles"] = try await setup(["branch", "--show-current"]) == "main\n" && (try? String(contentsOf: repo.appendingPathComponent("target.txt"), encoding: .utf8)) == "agent-committed\n"
                checks["generatedWorktreesAreLocallyIgnored"] = try await setup(["check-ignore", "--", ".bluefatfish/worktrees/"]) == ".bluefatfish/worktrees/\n"
            } else { checks["realWorktreeCreatesIsolatedTask"] = false }
            checks["realModelCompletesCommitWorkflow"] = committedTask.status == .completed
            report["commit"] = ["model": p.model, "status": committedTask.status.rawValue, "result": committedTask.summary, "approvals": approvals]
            let gitWindow = AgentGitWindow(store: tasks, taskID: commitID) { _ in }
            checks.merge(await gitWindow.checkLayout(output)) { _, value in value }; gitWindow.window?.close()
            tasks.selectedID = commitID; control.show(tab: "chat")
            checks.merge(await control.checkAgentLayout(output, includeArtifacts: false)) { _, value in value }
            let fresh = output.appendingPathComponent("fresh", isDirectory: true); try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
            let freshID = tasks.create(title: "Git 初始化验证", workspace: fresh.path)
            let freshGit = try AgentGit(store: tasks, taskID: freshID, directory: fresh.appendingPathComponent(".git")), initialized = try await freshGit.initialize()
            checks["nativeGitInitializesEmptyRepository"] = initialized.branch == "main" && initialized.head == nil && initialized.changes.isEmpty
        } catch { report["error"] = error.localizedDescription }
        report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil; report["checks"] = checks
        report["scope"] = "Actual public Git fixtures; actual configured model reads, edits, reviews and commits only selected files after approval, then creates an isolated worktree task. Native checks cover stale reviews, hooks, other staging, initialization and layout. No production repository changes, microphone or TTS."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("git-report.json")) }
    }
}
