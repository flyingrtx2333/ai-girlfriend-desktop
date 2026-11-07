import AppKit

@MainActor extension AppDelegate {
    func runAgentGitInspectionCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            var preferences = store.preferences; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
            let fm = FileManager.default, repo = output.appendingPathComponent("repo"), temporary = output.appendingPathComponent("tmp")
            try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: repo.appendingPathComponent(path)) }
            func read(_ path: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) }
            func setup(_ args: [String]) async throws -> String {
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: temporary, network: false, timeout: 10, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", repo.path] + args)
                guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
            }
            let odd = "space'文件\nline.txt"
            for path in ["base.txt", "layered.txt", "other.txt", "turn.txt", odd] { try write(path, "base\n") }
            _ = try await setup(["init", "-b", "main"])
            for pair in [("user.name", "Git Review Acceptance"), ("user.email", "review@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", ".git/hooks")] { _ = try await setup(["config", pair.0, pair.1]) }
            _ = try await setup(["add", "--", "."]); _ = try await setup(["commit", "-m", "initial public files"])
            let rootCommit = try await setup(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await setup(["switch", "-c", "review-feature"])
            try write("committed.txt", "branch-only\n"); try write("base.txt", "committed-version\n")
            _ = try await setup(["add", "--", "committed.txt", "base.txt"]); _ = try await setup(["commit", "-m", "branch changes"])
            let head = try await setup(["rev-parse", "HEAD"])
            try write("layered.txt", "staged-version\n"); try write("other.txt", "other-user-staged\n")
            _ = try await setup(["add", "--", "layered.txt", "other.txt"])
            try write("layered.txt", "working-version\n"); try write("base.txt", "unstaged-version\n"); try write(odd, "+++ content\n--- content\n")
            try write("fresh.txt", "新文件\n")
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务存储不可用") }
            let id = tasks.create(title: "Git 改动来源验收", workspace: repo.path)
            tasks.update(id) { $0.messages.append(AgentMessage(role: "user", content: "第一轮文件修改")) }
            let tools = AgentTools(store: tasks, taskID: id), git = try AgentGit(store: tasks, taskID: id, directory: repo.appendingPathComponent(".git"))
            func turnWrite(_ value: String) async throws {
                let arguments = try JSONSerialization.data(withJSONObject: ["path": "turn.txt", "content": value])
                _ = try await tools.execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: arguments, as: UTF8.self)))
            }
            try await turnWrite("turn-one\n"); try await turnWrite("turn-one-final\n-- body\n++ body\n")
            let first = try await git.inspect(source: .lastTurn, revision: "", requested: ["turn.txt"])
            checks["lastTurnUsesFirstSnapshotAndLatestWrite"] = first.diff.contains("-base") && first.diff.contains("+turn-one-final") && !first.diff.contains("+turn-one\n")
            tasks.update(id) { $0.messages.append(AgentMessage(role: "user", content: "第二轮文件修改")) }
            checks["newHumanTurnDoesNotReusePriorChanges"] = try await git.inspectionChanges(source: .lastTurn, revision: "").isEmpty
            try await turnWrite("turn-two\n")
            let second = try await git.inspect(source: .lastTurn, revision: "", requested: ["turn.txt"])
            checks["newTurnHasIndependentBeforeVersion"] = second.diff.contains("-turn-one-final") && second.diff.contains("+turn-two") && !second.diff.contains("-base")
            checks["lastTurnHeadersHideScratchPathsAndPreserveHunks"] = second.diff.contains("diff --git a/turn.txt b/turn.txt") && second.diff.contains("--- a/turn.txt") && !second.diff.contains("review-before-") && second.diff.contains("--- body") && second.diff.contains("-++ body")
            let persisted = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["turnReviewSurvivesReload"] = persisted.task(id)?.gitTurn?.id == tasks.task(id)?.messages.last?.id && persisted.task(id)?.gitTurn?.changes.first?.afterHash == AgentFiles.hash(Data("turn-two\n".utf8))
            if let fork = tasks.fork(id) { checks["forkDoesNotReuseOriginalTurnCheckpoints"] = tasks.task(fork)?.gitTurn == nil }
            else { checks["forkDoesNotReuseOriginalTurnCheckpoints"] = false }
            try write("turn.txt", "external\n")
            do { _ = try await git.inspect(source: .lastTurn, revision: "", requested: ["turn.txt"]); checks["externalEditCannotMasqueradeAsLastTurn"] = false }
            catch { checks["externalEditCannotMasqueradeAsLastTurn"] = try read("turn.txt") == "external\n" }
            try write("turn.txt", "turn-two\n")
            let unstaged = try await git.inspect(source: .unstaged, revision: "", requested: ["layered.txt"])
            let staged = try await git.inspect(source: .staged, revision: "", requested: ["layered.txt"])
            let all = try await git.inspect(source: .uncommitted, revision: "", requested: ["layered.txt"])
            checks["unstagedComparesIndexToWorkingFile"] = unstaged.diff.contains("-staged-version") && unstaged.diff.contains("+working-version")
            checks["stagedComparesHeadToIndexOnly"] = staged.diff.contains("-base") && staged.diff.contains("+staged-version") && !staged.diff.contains("working-version")
            checks["uncommittedComparesHeadToWorkingFile"] = all.diff.contains("-base") && all.diff.contains("+working-version") && !all.diff.contains("staged-version")
            let committed = try await git.inspect(source: .committed, revision: "HEAD", requested: ["base.txt"])
            let branch = try await git.inspect(source: .branch, revision: "main", requested: ["base.txt"])
            checks["committedAndBranchExcludeWorkingChanges"] = committed.diff.contains("+committed-version") && branch.diff == committed.diff && !branch.diff.contains("unstaged-version")
            checks["rootCommitShowsAddedFiles"] = try await git.inspect(source: .committed, revision: rootCommit, requested: ["base.txt"]).diff.contains("+base")
            let oddReview = try await git.inspect(source: .unstaged, revision: "", requested: [odd])
            checks["quotedUnicodeNewlinePathsAndStatsAreExact"] = oddReview.paths == [odd] && oddReview.additions == 2 && oddReview.deletions == 1
            checks["untrackedFilesAppearInUnstaged"] = try await git.inspectionChanges(source: .unstaged, revision: "").contains { $0.path == "fresh.txt" && $0.status == "??" }
            _ = try await git.apply(.stage, inspection: unstaged)
            checks["stageWritesActualIndexOnly"] = try await setup(["show", ":layered.txt"]) == "working-version\n" && read("layered.txt") == "working-version\n"
            _ = try await git.apply(.unstage, inspection: git.inspect(source: .staged, revision: "", requested: ["layered.txt"]))
            let unstagedIndex = try await setup(["show", ":layered.txt"]), otherIndex = try await setup(["show", ":other.txt"])
            checks["unstagePreservesWorkingFileAndOtherIndexEntries"] = try unstagedIndex == "base\n" && otherIndex == "other-user-staged\n" && read("layered.txt") == "working-version\n"
            let staleFile = try await git.inspect(source: .unstaged, revision: "", requested: ["base.txt"])
            try write("base.txt", "external-after-review\n")
            do { _ = try await git.apply(.stage, inspection: staleFile); checks["staleFilePreventsIndexMutation"] = false }
            catch { checks["staleFilePreventsIndexMutation"] = try await setup(["show", ":base.txt"]) == "committed-version\n" }
            try write("base.txt", "unstaged-version\n")
            let staleIndex = try await git.inspect(source: .unstaged, revision: "", requested: ["layered.txt"])
            try write("layered.txt", "index-changed\n"); _ = try await setup(["add", "--", "layered.txt"]); try write("layered.txt", "working-version\n")
            do { _ = try await git.apply(.restore, inspection: staleIndex); checks["staleIndexPreventsRestore"] = false }
            catch { checks["staleIndexPreventsRestore"] = try read("layered.txt") == "working-version\n" }
            let restore = try await git.apply(.restore, inspection: git.inspect(source: .unstaged, revision: "", requested: ["layered.txt"]))
            checks["restoreUsesIndexAndSavesRecoverableCheckpoint"] = try read("layered.txt") == "index-changed\n" && restore.checkpointID != nil
            guard let checkpoint = tasks.task(id)?.changes.first(where: { $0.id == restore.checkpointID }) else { throw PetError("恢复检查点丢失") }
            try AgentChanges.restore(checkpoint, taskID: id, store: tasks)
            let restoredIndex = try await setup(["show", ":layered.txt"])
            checks["undoRestoreRecoversActualBytesWithoutChangingIndex"] = try read("layered.txt") == "working-version\n" && restoredIndex == "index-changed\n"
            let trash = try await git.apply(.restore, inspection: git.inspect(source: .unstaged, revision: "", requested: ["fresh.txt"]))
            checks["untrackedRestoreUsesRecoverableSystemTrash"] = !fm.fileExists(atPath: repo.appendingPathComponent("fresh.txt").path) && trash.trashedPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } == "新文件\n"
            if let trashed = trash.trashedPath { try fm.moveItem(atPath: trashed, toPath: repo.appendingPathComponent("fresh.txt").path) }
            let staleHead = try await git.inspect(source: .unstaged, revision: "", requested: ["base.txt"])
            _ = try await setup(["commit", "--allow-empty", "-m", "head changes after review"])
            do { _ = try await git.apply(.stage, inspection: staleHead); checks["staleHeadPreventsStage"] = false }
            catch { checks["staleHeadPreventsStage"] = try await setup(["diff", "--cached", "--", "base.txt"]).isEmpty }
            _ = try await setup(["reset", "--soft", head.trimmingCharacters(in: .whitespacesAndNewlines)])
            try fm.createSymbolicLink(at: repo.appendingPathComponent("alias.txt"), withDestinationURL: repo.appendingPathComponent("base.txt"))
            do { _ = try await git.inspect(source: .unstaged, revision: "", requested: ["alias.txt"]); checks["symlinkCannotRedirectFileActions"] = false }
            catch { checks["symlinkCannotRedirectFileActions"] = try read("base.txt") == "unstaged-version\n" }
            try fm.removeItem(at: repo.appendingPathComponent("alias.txt"))
            _ = try await setup(["mv", "--", "committed.txt", "renamed.txt"])
            let oldName = try await git.inspect(source: .staged, revision: "", requested: ["committed.txt"])
            _ = try await git.apply(.unstage, inspection: oldName)
            let originalIndex = try await setup(["show", ":committed.txt"]), renamedIndex = try await setup(["show", ":renamed.txt"])
            checks["stagedRenameActionsOnlyAffectReviewedPath"] = originalIndex == "branch-only\n" && renamedIndex == "branch-only\n"
            _ = try await setup(["reset", "--quiet", "HEAD", "--", "committed.txt", "renamed.txt"])
            try fm.moveItem(at: repo.appendingPathComponent("renamed.txt"), to: repo.appendingPathComponent("committed.txt"))
            try fm.removeItem(at: repo.appendingPathComponent("committed.txt"))
            let missing = try await git.inspect(source: .unstaged, revision: "", requested: ["committed.txt"])
            let recreated = try await git.apply(.restore, inspection: missing)
            checks["deletedTrackedFileRestoresFromIndex"] = try read("committed.txt") == "branch-only\n"
            guard let deletedCheckpoint = tasks.task(id)?.changes.first(where: { $0.id == recreated.checkpointID }) else { throw PetError("缺少删除文件恢复检查点") }
            try AgentChanges.restore(deletedCheckpoint, taskID: id, store: tasks)
            checks["undoRestoreReturnsDeletedFileToPriorState"] = !fm.fileExists(atPath: repo.appendingPathComponent("committed.txt").path)
            _ = try await setup(["restore", "--worktree", "--", "committed.txt"])
            let fresh = output.appendingPathComponent("unborn")
            try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
            _ = try await setup(["-C", fresh.path, "init", "-b", "main"])
            try Data("first staged file\n".utf8).write(to: fresh.appendingPathComponent("first.txt"))
            _ = try await setup(["-C", fresh.path, "add", "--", "first.txt"])
            let freshID = tasks.create(title: "首次提交前暂存", workspace: fresh.path), freshGit = try AgentGit(store: tasks, taskID: freshID, directory: fresh.appendingPathComponent(".git"))
            let freshReview = try await freshGit.inspect(source: .staged, revision: "", requested: ["first.txt"])
            _ = try await freshGit.apply(.unstage, inspection: freshReview)
            checks["unbornUnstageKeepsActualUntrackedFile"] = try await setup(["-C", fresh.path, "ls-files"]).isEmpty && String(contentsOf: fresh.appendingPathComponent("first.txt"), encoding: .utf8) == "first staged file\n"
            let finalOther = try await setup(["show", ":other.txt"]), finalHead = try await setup(["rev-parse", "HEAD"])
            checks["allActionsPreserveOtherUserStagingAndHead"] = finalOther == "other-user-staged\n" && finalHead == head
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Git 来源或逐文件操作验收未通过") }
            let window = AgentGitWindow(store: tasks, taskID: id) { _ in }
            checks.merge(await window.checkLayout(output)) { _, value in value }
            window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            report["taskID"] = id; report["rootCommit"] = rootCommit; report["head"] = head.trimmingCharacters(in: .whitespacesAndNewlines); report["workspace"] = repo.path
            report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks
            report["scope"] = "Real Git repository, index, commits and merge-base; actual native file tools create per-turn snapshots. No mocked Git responses or model calls. Production workspace and profile untouched."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-inspection-report.json"))
            if CommandLine.arguments.contains("--hold-ui") {
                try Data("ui-ready".utf8).write(to: output.appendingPathComponent("phase"))
                let limit = Date().addingTimeInterval(900)
                while Date() < limit, !fm.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
            window.close()
        } catch {
            report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-inspection-report.json"))
        }
    }
}
