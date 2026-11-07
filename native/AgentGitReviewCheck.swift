import AppKit

@MainActor extension AppDelegate {
    func runAgentGitReviewCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let fm = FileManager.default, repo = output.appendingPathComponent("repo"), temporary = output.appendingPathComponent("tmp"), receiver = output.appendingPathComponent("receiver.git")
            try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            func setup(_ args: [String], at directory: URL? = nil) async throws -> String {
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: temporary, network: false, timeout: 20, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", (directory ?? repo).path] + args)
                guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
            }
            func write(_ path: String, _ value: String) throws { try Data(value.utf8).write(to: repo.appendingPathComponent(path)) }
            func read(_ path: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) }
            let odd = "space'文件\nline.txt"
            for path in ["layered.txt", "other.txt", "delete.txt", "rename.txt", "live.txt", "ui.txt", odd] { try write(path, "base-" + path.replacingOccurrences(of: "\n", with: "-") + "\n") }
            try write("mode.sh", "#!/bin/sh\nprintf 'public'\n"); try Data([0, 1, 2, 3]).write(to: repo.appendingPathComponent("binary.dat"))
            let longBefore = (1...70).map { $0 == 20 ? "old " + String(repeating: "old-wide-", count: 12) : "context-\($0)" }.joined(separator: "\n") + "\n"
            try write("long.txt", longBefore)
            _ = try await setup(["init", "-b", "main"])
            for (key, value) in [("user.name", "Staged Review Acceptance"), ("user.email", "review@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", ".git/hooks")] { _ = try await setup(["config", key, value]) }
            _ = try await setup(["add", "--", "."]); _ = try await setup(["commit", "-m", "public review baseline"])
            let base = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try write("layered.txt", "staged-selected\n"); try write("other.txt", "other-user-staged\n"); try write(odd, "已暂存的中文\n"); try write("staged-add.txt", "staged-file-with-missing-worktree\n")
            try fm.removeItem(at: repo.appendingPathComponent("delete.txt")); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appendingPathComponent("mode.sh").path)
            try Data([0, 8, 9, 10, 11]).write(to: repo.appendingPathComponent("binary.dat"))
            _ = try await setup(["add", "--", "layered.txt", "other.txt", odd, "staged-add.txt", "delete.txt", "mode.sh", "binary.dat"]); _ = try await setup(["mv", "--", "rename.txt", "renamed.txt"])
            try write("layered.txt", "working-selected-preserved\n"); try write("other.txt", "other-user-working\n"); try write(odd, "工作区中文保持\n"); try fm.removeItem(at: repo.appendingPathComponent("staged-add.txt"))
            try write("long.txt", longBefore.replacingOccurrences(of: "old " + String(repeating: "old-wide-", count: 12), with: "new " + String(repeating: "new-wide-", count: 34)))
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务存储不可用") }
            var preferences = store.preferences; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
            let id = tasks.create(title: "暂存提交与并排差异", workspace: repo.path), git = try AgentGit(store: tasks, taskID: id, directory: repo.appendingPathComponent(".git"))
            let selected = ["layered.txt", odd, "delete.txt", "mode.sh", "binary.dat", "staged-add.txt", "rename.txt", "renamed.txt"]
            let first = try await git.diff(selected, source: .staged)
            checks["stagedReviewReadsActualIndexNotWorkingVersion"] = first.commitSource == .staged && first.diff.contains("+staged-selected") && !first.diff.contains("+working-selected-preserved") && first.branchRef == "refs/heads/main"
            let invalidSource = AgentToolCall(id: "invalid-source", name: "git_diff", arguments: "{\"paths\":[\"layered.txt\"],\"source\":17}")
            do { _ = try await AgentTools(store: tasks, taskID: id).execute(invalidSource, gitDirectory: git.directory.path); checks["invalidSourceTypeCannotFallBackToWorkingVersion"] = false }
            catch { checks["invalidSourceTypeCannotFallBackToWorkingVersion"] = error.localizedDescription.contains("来源必须") }
            let firstChanges = try await git.inspectionChanges(source: .staged, revision: ""), firstStatistics = try await git.statistics(source: .staged, revision: "", changes: firstChanges)
            checks["sourceStatisticsCountRealBinaryChanges"] = firstStatistics.binaryFiles == 1
            let binaryRows = AgentGitDiffRows.parse(first.diff)
            checks["splitBinaryDiffDoesNotRenderEncodedPayloadAsCode"] = binaryRows.contains { $0.old.text == "二进制文件已更改" } && !binaryRows.contains { $0.old.text.hasPrefix("literal ") || $0.new.text.hasPrefix("literal ") }
            let reloaded = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["stagedReviewSourceSurvivesStorageReload"] = reloaded.task(id)?.gitReview?.commitSource == .staged && reloaded.task(id)?.gitReview?.hash == first.hash
            try write("layered.txt", "working-edited-after-review\n")
            let changedWork = try await git.diff(selected, source: .staged)
            checks["laterUnstagedEditDoesNotChangeStagedReview"] = changedWork.hash == first.hash
            let indexBefore = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            let hooks = repo.appendingPathComponent(".git/hooks")
            func hook(_ name: String, _ script: String) throws {
                let file = hooks.appendingPathComponent(name); try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: file, options: .atomic); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            for name in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"] { try hook(name, "printf '%s\\n' " + AgentGit.quote(name) + " >> commit-hooks.txt") }
            let committed = try await git.commit(paths: first.paths, message: "commit reviewed staged subset", reviewHash: first.hash)
            let committedLayer = try await setup(["show", "HEAD:layered.txt"]), originalOther = try await setup(["show", "HEAD:other.txt"]), indexOther = try await setup(["show", ":other.txt"])
            checks["actualCommitContainsReviewedStagedBlob"] = committedLayer == "staged-selected\n" && committed.commit != base
            checks["stagedCommitLeavesOriginalIndexBytesUntouched"] = try Data(contentsOf: repo.appendingPathComponent(".git/index")) == indexBefore
            checks["stagedSubsetPreservesOtherUserStagingAndWorktree"] = try originalOther == "base-other.txt\n" && indexOther == "other-user-staged\n" && read("other.txt") == "other-user-working\n" && read("layered.txt") == "working-edited-after-review\n" && read(odd) == "工作区中文保持\n"
            checks["stagedDeletionRenameModeAndBinaryCommitActuallyMatch"] = try await setup(["ls-tree", "HEAD", "--", "delete.txt", "rename.txt"]).isEmpty
            let mode = try await setup(["ls-tree", "HEAD", "--", "mode.sh"]), addition = try await setup(["show", "HEAD:staged-add.txt"]), renamed = try await setup(["show", "HEAD:renamed.txt"]), binary = try await setup(["show", "HEAD:binary.dat"])
            checks["stagedDeletionRenameModeAndBinaryCommitActuallyMatch"] = checks["stagedDeletionRenameModeAndBinaryCommitActuallyMatch"] == true && mode.hasPrefix("100755") && addition == "staged-file-with-missing-worktree\n" && renamed == "base-rename.txt\n" && Data(binary.utf8) == Data([0, 8, 9, 10, 11])
            checks["allNativeCommitHooksActuallyRunOnce"] = try read("commit-hooks.txt") == "pre-commit\nprepare-commit-msg\ncommit-msg\npost-commit\n"
            for name in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"] { try fm.removeItem(at: hooks.appendingPathComponent(name)) }
            let nativeHead = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try write("layered.txt", "next-staged\n"); _ = try await setup(["add", "--", "layered.txt"]); try write("layered.txt", "working-final-preserved\n")
            let stale = try await git.diff(["layered.txt"], source: .staged)
            try write("layered.txt", "changed-staged\n"); _ = try await setup(["add", "--", "layered.txt"]); try write("layered.txt", "working-final-preserved\n")
            do { _ = try await git.commit(paths: stale.paths, message: "reject stale index", reviewHash: stale.hash); checks["changedStagingRejectsOldReview"] = false } catch { checks["changedStagingRejectsOldReview"] = true }
            try write("layered.txt", "next-staged\n"); _ = try await setup(["add", "--", "layered.txt"]); try write("layered.txt", "working-final-preserved\n")
            let beforeBranch = try await git.diff(["layered.txt"], source: .staged)
            _ = try await setup(["update-ref", "refs/heads/other-branch", nativeHead]); _ = try await setup(["symbolic-ref", "HEAD", "refs/heads/other-branch"])
            do { _ = try await git.commit(paths: beforeBranch.paths, message: "reject changed branch", reviewHash: beforeBranch.hash); checks["sameHeadOnDifferentBranchRejectsOldReview"] = false } catch { checks["sameHeadOnDifferentBranchRejectsOldReview"] = true }
            _ = try await setup(["symbolic-ref", "HEAD", "refs/heads/main"])
            let beforeHeadChange = try await git.diff(["layered.txt"], source: .staged), nativeTree = try await setup(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let advanced = try await setup(["commit-tree", nativeTree, "-p", nativeHead, "-m", "concurrent public commit"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await setup(["update-ref", "HEAD", advanced, nativeHead])
            do { _ = try await git.commit(paths: beforeHeadChange.paths, message: "reject changed head", reviewHash: beforeHeadChange.hash); checks["changedHeadRejectsOldStagedReview"] = false } catch { checks["changedHeadRejectsOldStagedReview"] = true }
            _ = try await setup(["update-ref", "HEAD", nativeHead, advanced])
            try hook("pre-commit", "exit 19")
            let denied = try await git.diff(["layered.txt"], source: .staged)
            do { _ = try await git.commit(paths: denied.paths, message: "respect hook rejection", reviewHash: denied.hash); checks["failedNativeHookPreventsStagedCommit"] = false } catch { checks["failedNativeHookPreventsStagedCommit"] = true }
            let otherBlob = try await setup(["rev-parse", ":other.txt"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try hook("pre-commit", AgentGit.quote(try AgentGit.executablePath()) + " update-index --add --cacheinfo 100644," + otherBlob + ",other.txt")
            let widened = try await git.diff(["layered.txt"], source: .staged), beforeWidenedIndex = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            do { _ = try await git.commit(paths: widened.paths, message: "reject hook adding unreviewed file", reviewHash: widened.hash); checks["hookCannotSilentlyExpandReviewedSnapshot"] = false } catch { checks["hookCannotSilentlyExpandReviewedSnapshot"] = true }
            checks["rejectedHookKeepsOriginalIndexAndHead"] = try Data(contentsOf: repo.appendingPathComponent(".git/index")) == beforeWidenedIndex
            let afterRejections = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            checks["rejectedHookKeepsOriginalIndexAndHead"] = checks["rejectedHookKeepsOriginalIndexAndHead"] == true && afterRejections == nativeHead
            try fm.removeItem(at: hooks.appendingPathComponent("pre-commit"))
            _ = try await setup(["config", "gpg.format", "openpgp"]); _ = try await setup(["config", "gpg.program", "/usr/bin/false"]); _ = try await setup(["config", "commit.gpgsign", "true"])
            let signingReview = try await git.diff(["layered.txt"], source: .staged)
            do { _ = try await git.commit(paths: signingReview.paths, message: "respect configured signing failure", reviewHash: signingReview.hash); checks["configuredSigningFailureIsNotSilentlyBypassed"] = false } catch { checks["configuredSigningFailureIsNotSilentlyBypassed"] = true }
            let afterSigning = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            checks["signingFailureLeavesHeadAndOriginalIndexUntouched"] = try afterSigning == nativeHead && Data(contentsOf: repo.appendingPathComponent(".git/index")) == beforeWidenedIndex
            _ = try await setup(["config", "commit.gpgsign", "false"]); _ = try await setup(["config", "--unset", "gpg.program"]); _ = try await setup(["config", "--unset", "gpg.format"])
            let stagedChanges = try await git.inspectionChanges(source: .staged, revision: ""), stagedTotal = try await git.statistics(source: .staged, revision: "", changes: stagedChanges)
            let actualNumstat = try await setup(["diff", "--cached", "--no-renames", "--numstat", "-z"]); var independentTotal = AgentGitStatistics(); try independentTotal.append(actualNumstat)
            checks["wholeSourceStatisticsIncludeUnselectedStagedFiles"] = stagedChanges.count == 2 && stagedTotal.additions == 2 && stagedTotal.deletions == 2 && stagedTotal.additions == independentTotal.additions && stagedTotal.deletions == independentTotal.deletions
            let longDiff = try await git.inspect(source: .uncommitted, revision: "", requested: ["long.txt"]), parsed = AgentGitDiffRows.parse(longDiff.diff)
            checks["splitRowsUseActualGitLineNumbersAndPairedReplacement"] = parsed.contains { $0.old.number == 20 && $0.new.number == 20 && $0.old.text.hasPrefix("old ") && $0.new.text.hasPrefix("new ") }
            try write("no-newline.txt", "old-no-newline"); _ = try await setup(["add", "--", "no-newline.txt"]); _ = try await setup(["commit", "--only", "-m", "public no-newline baseline", "--", "no-newline.txt"])
            try write("no-newline.txt", "new-no-newline")
            let noNewline = try await git.inspect(source: .uncommitted, revision: "", requested: ["no-newline.txt"]), noNewlineRows = AgentGitDiffRows.parse(noNewline.diff)
            checks["splitRowsPreserveNoNewlineMarkersWithoutMisalignment"] = noNewlineRows.contains { $0.old.text == "old-no-newline" && $0.new.text == "new-no-newline" && $0.old.noNewline && $0.new.noNewline }
            try write("live.txt", "live-staged-selected\n"); _ = try await setup(["add", "--", "live.txt"]); try write("live.txt", "live-working-preserved\n")
            let beforeExtraChanges = try await git.inspectionChanges(source: .uncommitted, revision: ""), beforeExtra = try await git.statistics(source: .uncommitted, revision: "", changes: beforeExtraChanges)
            try write("statistics-untracked.txt", "stat-one\nstat-two\nstat-three\n"); try Data([0, 17, 34]).write(to: repo.appendingPathComponent("statistics-untracked.bin"))
            let afterExtraChanges = try await git.inspectionChanges(source: .uncommitted, revision: ""), afterExtra = try await git.statistics(source: .uncommitted, revision: "", changes: afterExtraChanges)
            checks["sourceStatisticsIncludeActualUntrackedTextAndBinaryFiles"] = afterExtra.additions == beforeExtra.additions + 3 && afterExtra.deletions == beforeExtra.deletions && afterExtra.binaryFiles == beforeExtra.binaryFiles + 1
            try fm.removeItem(at: repo.appendingPathComponent("statistics-untracked.txt")); try fm.removeItem(at: repo.appendingPathComponent("statistics-untracked.bin"))
            let fresh = output.appendingPathComponent("unborn")
            try fm.createDirectory(at: fresh, withIntermediateDirectories: true); _ = try await setup(["init", "-b", "main"], at: fresh)
            for (key, value) in [("user.name", "Staged Review Acceptance"), ("user.email", "review@example.invalid"), ("commit.gpgsign", "false")] { _ = try await setup(["config", key, value], at: fresh) }
            try Data("first-staged\n".utf8).write(to: fresh.appendingPathComponent("first.txt")); try Data("other-first-staged\n".utf8).write(to: fresh.appendingPathComponent("other.txt")); _ = try await setup(["add", "--", "."], at: fresh)
            try Data("first-working\n".utf8).write(to: fresh.appendingPathComponent("first.txt"))
            let freshID = tasks.create(title: "首次提交的暂存版本", workspace: fresh.path), freshGit = try AgentGit(store: tasks, taskID: freshID, directory: fresh.appendingPathComponent(".git")), freshIndex = try Data(contentsOf: fresh.appendingPathComponent(".git/index"))
            let freshReview = try await freshGit.diff(["first.txt"], source: .staged), firstCommit = try await freshGit.commit(paths: freshReview.paths, message: "first selected staged commit", reviewHash: freshReview.hash)
            let firstValue = try await setup(["show", "HEAD:first.txt"], at: fresh), firstPaths = try await setup(["ls-tree", "--name-only", "HEAD"], at: fresh), firstOther = try await setup(["show", ":other.txt"], at: fresh)
            checks["unbornRepositoryCommitsOnlySelectedStagedFile"] = freshReview.head == nil && !firstCommit.commit.isEmpty && firstValue == "first-staged\n" && firstPaths == "first.txt\n" && firstOther == "other-first-staged\n"
            checks["unbornStagedCommitPreservesIndexAndWorkingVersion"] = try Data(contentsOf: fresh.appendingPathComponent(".git/index")) == freshIndex && String(contentsOf: fresh.appendingPathComponent("first.txt"), encoding: .utf8) == "first-working\n"
            let linked = output.appendingPathComponent("linked"), mainBeforeLinked = try await setup(["rev-parse", "HEAD"]), mainIndexBeforeLinked = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            _ = try await setup(["worktree", "add", "-b", "staged-linked", linked.path, "HEAD"])
            try Data("linked-staged\n".utf8).write(to: linked.appendingPathComponent("layered.txt")); _ = try await setup(["add", "--", "layered.txt"], at: linked); try Data("linked-working\n".utf8).write(to: linked.appendingPathComponent("layered.txt"))
            let linkedID = tasks.create(title: "独立工作树的暂存版本", workspace: linked.path), linkedGit = try AgentGit(store: tasks, taskID: linkedID, directory: AgentGit.metadata(workspace: linked.path))
            let linkedIndexPath = try await setup(["rev-parse", "--git-path", "index"], at: linked).trimmingCharacters(in: .whitespacesAndNewlines), linkedIndex = try Data(contentsOf: URL(fileURLWithPath: linkedIndexPath))
            let linkedReview = try await linkedGit.diff(["layered.txt"], source: .staged); _ = try await linkedGit.commit(paths: linkedReview.paths, message: "linked staged subset", reviewHash: linkedReview.hash)
            let linkedValue = try await setup(["show", "HEAD:layered.txt"], at: linked), mainAfterLinked = try await setup(["rev-parse", "HEAD"])
            checks["linkedWorktreeCommitsItsOwnStagedVersion"] = try linkedValue == "linked-staged\n" && String(contentsOf: linked.appendingPathComponent("layered.txt"), encoding: .utf8) == "linked-working\n" && Data(contentsOf: URL(fileURLWithPath: linkedIndexPath)) == linkedIndex
            checks["linkedStagedCommitPreservesOriginalHeadAndIndex"] = try mainBeforeLinked == mainAfterLinked && Data(contentsOf: repo.appendingPathComponent(".git/index")) == mainIndexBeforeLinked
            report["unbornWorkspace"] = fresh.path; report["linkedWorkspace"] = linked.path
            let scopeReview = try await git.diff(["layered.txt"], source: .staged), scopeInspection = try await git.inspect(source: .staged, revision: "", requested: ["layered.txt"])
            let scopeHead = try await setup(["rev-parse", "HEAD"]), scopeIndex = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            tasks.update(id) { $0.workspace = fresh.path }
            do { _ = try await git.commit(paths: scopeReview.paths, message: "reject old project authority", reviewHash: scopeReview.hash); checks["changedTaskProjectRejectsCachedCommitHelper"] = false } catch { checks["changedTaskProjectRejectsCachedCommitHelper"] = true }
            do { _ = try await git.apply(.unstage, inspection: scopeInspection); checks["changedTaskProjectRejectsCachedIndexAction"] = false } catch { checks["changedTaskProjectRejectsCachedIndexAction"] = true }
            tasks.update(id) { $0.workspace = repo.path; $0.gitReview = nil }
            let scopeAfter = try await setup(["rev-parse", "HEAD"])
            checks["rejectedProjectChangeLeavesOriginalHeadAndIndexUntouched"] = try scopeAfter == scopeHead && Data(contentsOf: repo.appendingPathComponent(".git/index")) == scopeIndex
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("暂存快照或差异检查失败") }
            var uiID = id
            if CommandLine.arguments.contains("--live-agent") {
                let profile = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var p = PreferencesStore(directory: profile).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
                guard let runtime = agentRuntime else { throw PetError("真实模型不可用") }
                let liveID = tasks.create(title: "真实模型只提交暂存版本", workspace: repo.path, mode: .agent), before = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
                runtime.submit("只提交live.txt已有的暂存版本，提交说明 Staged source proof。禁止编辑或暂存任何原有文件，不使用run_command。先git_status，再git_diff(paths=[live.txt],source=staged)，git_commit沿用该review_hash；审批由验收人员处理。提交后git_status，并git_diff(paths=[live.txt],source=uncommitted)核对未暂存版本还在。最后只新增review-result.json，合法JSON只含commit、source、committedText、workingText四字段，source=staged，两个Text取已审阅的实际提交内容和保留工作区内容，不含行尾换行；用read_file回读。", taskID: liveID)
                let deadline = Date().addingTimeInterval(240); var approved = false, approvals = 0
                while Date() < deadline, let task = tasks.task(liveID), [.ready, .running, .waiting].contains(task.status) {
                    if task.events.filter({ $0.kind == "tool" && $0.title == "git_diff" && $0.status == "failed" }).count >= 2 {
                        runtime.cancel(liveID); throw PetError("真实模型重复失败的差异读取，已停止验收")
                    }
                    if task.status == .waiting, let call = task.pendingCalls.first {
                        guard call.name == "git_commit", approvals < 2, let review = task.gitReview, review.commitSource == .staged, review.paths == ["live.txt"], review.hash == call.object["review_hash"] as? String, review.diff.contains("+live-staged-selected"), !review.diff.contains("+live-working-preserved") else { runtime.cancel(liveID); throw PetError("真实模型要求了预期外操作或审阅来源") }
                        approved = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) == before
                        approvals += 1; runtime.decide(taskID: liveID, callID: call.id, decision: "allow")
                    }
                    await wait(0.1)
                }
                guard let task = tasks.task(liveID), task.status == .completed else { runtime.cancel(liveID); throw PetError("真实模型暂存提交流程未完成") }
                let commit = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), committedText = try await setup(["show", "HEAD:live.txt"])
                let result = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("review-result.json"))) as? [String: Any]
                checks["realModelWaitedForReviewedStagedCommitApproval"] = approved && approvals == 1
                checks["realModelCommitAndReportMatchActualIndexAndWorkingVersions"] = try committedText == "live-staged-selected\n" && read("live.txt") == "live-working-preserved\n" && result?.count == 4 && result?["commit"] as? String == commit && result?["source"] as? String == "staged" && result?["committedText"] as? String == "live-staged-selected" && result?["workingText"] as? String == "live-working-preserved"
                var archived = task
                archived.contextThroughID = task.messages.last?.id
                archived.contextSummary = task.contextSummary ?? "历史工具回执校验"
                let retained = AgentContext.window(archived, archivedFactBudget: 900).filter { $0.nativeContext == true }.map(\.content).joined(separator: "\n")
                checks["actualCommitReceiptRemainsAfterFurtherCompaction"] = retained.contains("git_commit") && retained.contains(commit)
                report["live"] = ["taskID": liveID, "commit": commit, "model": p.model, "contextLimit": p.contextLimit, "outputLimit": p.outputLimit, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "summary": task.summary]
                uiID = liveID
            }
            _ = try await setup(["init", "--bare", "--initial-branch=main", receiver.path]); _ = try await setup(["remote", "add", "origin", receiver.path])
            try write("ui.txt", "ui-staged-selected\n"); _ = try await setup(["add", "--", "ui.txt"]); try write("ui.txt", "ui-working-preserved\n")
            let beforeUI = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let window = AgentGitWindow(store: tasks, taskID: uiID) { _ in }
            checks.merge(await window.checkLayout(output)) { _, value in value }; checks.merge(await window.checkReviewViews(output, path: "long.txt")) { _, value in value }
            window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks; report["taskID"] = uiID; report["workspace"] = repo.path; report["receiver"] = receiver.path; report["nativeCommit"] = committed.commit; report["beforeUIHead"] = beforeUI
            report["scope"] = "Actual Git index, hooks, commit objects, source statistics and native diff rows. Live model uses saved budgets only with --live-agent. Production data untouched."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-review-report.json"))
            if CommandLine.arguments.contains("--hold-ui") {
                try Data("ui-ready".utf8).write(to: output.appendingPathComponent("phase"))
                let limit = Date().addingTimeInterval(1200)
                while Date() < limit, !fm.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
            window.close()
        } catch {
            report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-review-report.json"))
        }
    }
}
