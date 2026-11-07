import AppKit

@MainActor extension AppDelegate {
    func runAgentWorktreeCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let fm = FileManager.default, repo = output.appendingPathComponent("repo"), tmp = output.appendingPathComponent("tmp")
            try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            func setup(_ args: [String], at root: URL? = nil) async throws -> String {
                let value = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: tmp, network: false, timeout: 30, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", (root ?? repo).path] + args)
                guard !value.failed else { throw PetError(value.text) }; return value.stdout ?? ""
            }
            func initialize(_ root: URL) async throws {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                _ = try await setup(["init", "-b", "main"], at: root)
                for (key, value) in [("user.name", "Worktree Acceptance"), ("user.email", "worktrees@example.invalid"), ("commit.gpgsign", "false")] { _ = try await setup(["config", key, value], at: root) }
                try Data("base-public\n".utf8).write(to: root.appendingPathComponent("public.txt")); try Data("local-only.txt\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
                _ = try await setup(["add", "--", "."] , at: root); _ = try await setup(["commit", "-m", "public worktree baseline"], at: root)
            }
            try await initialize(repo); ensureAgent()
            guard let tasks = agentStore else { throw PetError("任务存储不可用") }
            var p = store.preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
            let id = tasks.create(title: "工作树回收与恢复", workspace: repo.path), git = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: repo.path))
            let child = try await git.createWorktree(branch: "acceptance/恢复"), childURL = URL(fileURLWithPath: child.workspace), childMetadata = URL(fileURLWithPath: try await setup(["rev-parse", "--absolute-git-dir"], at: childURL).trimmingCharacters(in: .whitespacesAndNewlines))
            let fork = tasks.fork(child.taskID); guard let fork else { throw PetError("工作树任务分支未创建") }; tasks.selectedID = id
            let odd = "notes'中文\nline.txt"
            func dirty(_ root: URL) async throws {
                try Data("staged-public\n".utf8).write(to: root.appendingPathComponent("public.txt")); _ = try await setup(["add", "--", "public.txt"], at: root)
                try Data("working-public\n".utf8).write(to: root.appendingPathComponent("public.txt")); try Data("ignored-public-marker\n".utf8).write(to: root.appendingPathComponent("local-only.txt"))
                try Data("未跟踪原文\n".utf8).write(to: root.appendingPathComponent(odd)); try Data([0, 1, 200, 255]).write(to: root.appendingPathComponent("untracked.bin"))
                try fm.createSymbolicLink(atPath: root.appendingPathComponent("relative-link").path, withDestinationPath: "public.txt")
                try Data("#!/bin/sh\nprintf public\n".utf8).write(to: root.appendingPathComponent("executable.sh")); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("executable.sh").path)
                try fm.createDirectory(at: root.appendingPathComponent("subproject"), withIntermediateDirectories: true)
            }
            try await dirty(childURL)
            let originalTree = try AgentWorktreeSnapshot.read(childURL), originalIndex = try Data(contentsOf: childMetadata.appendingPathComponent("index"))
            let stagedBlob = try await setup(["rev-parse", ":public.txt"], at: childURL).trimmingCharacters(in: .whitespacesAndNewlines)
            let mainHead = try await setup(["rev-parse", "HEAD"]), mainIndex = try Data(contentsOf: repo.appendingPathComponent(".git/index")), mainPublic = try Data(contentsOf: repo.appendingPathComponent("public.txt"))
            let entries = try await git.worktrees(), linked = entries.first { $0.path == child.workspace }
            checks["actualGitListLinksBothTasksAndOwnership"] = linked?.owned == true && Set(linked?.taskIDs ?? []) == Set([child.taskID, fork]) && linked?.unavailable == nil
            checks["mainWorktreeIsNeverRecyclable"] = entries.first { $0.path == repo.path }?.unavailable != nil
            checks["mainWorktreeDoesNotClaimLinkedCheckoutTasks"] = entries.first { $0.path == repo.path }?.taskIDs == [id]
            tasks.update(fork) { $0.status = .waiting }
            do { _ = try await git.prepareWorktreeRecycle(path: child.workspace); checks["waitingAssociatedTaskBlocksRecycle"] = false } catch { checks["waitingAssociatedTaskBlocksRecycle"] = true }
            tasks.update(fork) { $0.status = .ready }
            let nested = tasks.create(title: "子目录任务", workspace: childURL.appendingPathComponent("subproject").path)
            tasks.update(nested) { $0.status = .waiting }; tasks.selectedID = id
            do { _ = try await git.prepareWorktreeRecycle(path: child.workspace); checks["runningSubdirectoryTaskAlsoBlocksRecycle"] = false } catch { checks["runningSubdirectoryTaskAlsoBlocksRecycle"] = true }
            tasks.update(nested) { $0.status = .ready; $0.archived = true }
            _ = try await setup(["worktree", "lock", "--reason", "public acceptance lock", child.workspace])
            do { _ = try await git.prepareWorktreeRecycle(path: child.workspace); checks["actualGitLockBlocksRecycle"] = false } catch { checks["actualGitLockBlocksRecycle"] = true }
            _ = try await setup(["worktree", "unlock", child.workspace])
            let foreign = output.appendingPathComponent("foreign'中文\ncheckout")
            _ = try await setup(["worktree", "add", "-b", "external-native", foreign.path, "HEAD"])
            checks["realNewlineWorktreePathParsesVerbatim"] = try await git.worktrees().contains { $0.path == foreign.path && $0.unavailable == "外部工作树" }
            do { _ = try await git.prepareWorktreeRecycle(path: foreign.path); checks["externalCheckoutCannotAcquireRecycleAuthority"] = false } catch { checks["externalCheckoutCannotAcquireRecycleAuthority"] = true }
            let stale = try await git.prepareWorktreeRecycle(path: child.workspace)
            try Data("later-ignored-content\n".utf8).write(to: childURL.appendingPathComponent("local-only.txt"))
            do { _ = try await git.recycleWorktree(reviewHash: stale.hash); checks["ignoredFileChangeInvalidatesReview"] = false } catch { checks["ignoredFileChangeInvalidatesReview"] = fm.fileExists(atPath: child.workspace) }
            try Data("ignored-public-marker\n".utf8).write(to: childURL.appendingPathComponent("local-only.txt"))
            let scoped = try await git.prepareWorktreeRecycle(path: child.workspace)
            tasks.update(id) { $0.workspace = foreign.path }
            do { _ = try await git.recycleWorktree(reviewHash: scoped.hash); checks["changedProjectRejectsCachedRecycleHelper"] = false } catch { checks["changedProjectRejectsCachedRecycleHelper"] = fm.fileExists(atPath: child.workspace) }
            tasks.update(id) { $0.workspace = repo.path }
            let review = try await git.prepareWorktreeRecycle(path: child.workspace), backup = try await git.recycleWorktree(reviewHash: review.hash)
            report["nativeBackupID"] = backup.id
            checks["actualDirtyWorktreeRemovedAndBranchRetained"] = !fm.fileExists(atPath: child.workspace)
            let branchHead = try await setup(["rev-parse", "refs/heads/acceptance/恢复"])
            checks["actualDirtyWorktreeRemovedAndBranchRetained"] = checks["actualDirtyWorktreeRemovedAndBranchRetained"] == true && branchHead == mainHead
            checks["bothLinkedTasksArchivedWithoutLosingIdentity"] = tasks.task(child.taskID)?.archived == true && tasks.task(fork)?.archived == true
            checks["recycledCheckoutTasksRemainSeparateFromMainProject"] = try await git.worktrees().first { $0.path == repo.path }?.taskIDs == [id]
            _ = try await setup(["gc", "--prune=now"])
            let retainedBlob = try await setup(["cat-file", "blob", stagedBlob])
            checks["stagedContentRemainsRecoverableAfterActualGitGC"] = retainedBlob == "staged-public\n" && backup.objectRefs?.count == 2 && backup.indexTree != nil
            let saved = tasks.directory.appendingPathComponent("worktrees/" + backup.id + "/files")
            checks["backupIncludesActualIgnoredUntrackedBinaryAndLinks"] = try AgentWorktreeSnapshot.read(saved).hash == originalTree.hash && Data(contentsOf: saved.appendingPathComponent("local-only.txt")) == Data("ignored-public-marker\n".utf8) && Data(contentsOf: saved.appendingPathComponent("untracked.bin")) == Data([0, 1, 200, 255]) && fm.destinationOfSymbolicLink(atPath: saved.appendingPathComponent("relative-link").path) == "public.txt"
            let reloaded = try AgentGit(store: tasks, taskID: id, directory: git.directory)
            checks["recycleRecordSurvivesHelperReload"] = try reloaded.worktreeBackup(backup.id).state == "recycled"
            do { _ = try await git.recycleWorktree(reviewHash: review.hash); checks["consumedReviewCannotReplayRemoval"] = false } catch { checks["consumedReviewCannotReplayRemoval"] = true }
            try fm.createDirectory(at: childURL, withIntermediateDirectories: true); try Data("existing-path\n".utf8).write(to: childURL.appendingPathComponent("keep.txt"))
            do { _ = try await git.restoreWorktree(backupID: backup.id); checks["restoreRefusesExistingPathWithoutOverwriting"] = false } catch { checks["restoreRefusesExistingPathWithoutOverwriting"] = try Data(contentsOf: childURL.appendingPathComponent("keep.txt")) == Data("existing-path\n".utf8) }
            try fm.removeItem(at: childURL.appendingPathComponent("keep.txt")); try fm.removeItem(at: childURL)
            let restored = try await git.restoreWorktree(backupID: backup.id), metadata = URL(fileURLWithPath: try await setup(["rev-parse", "--absolute-git-dir"], at: childURL).trimmingCharacters(in: .whitespacesAndNewlines))
            checks["restoreRecreatesActualFilesModesAndRawIndex"] = try AgentWorktreeSnapshot.read(childURL).hash == originalTree.hash && Data(contentsOf: metadata.appendingPathComponent("index")) == originalIndex
            checks["restoreKeepsActualStagedAndWorkingVersionsDistinct"] = try await setup(["show", ":public.txt"], at: childURL) == "staged-public\n" && String(contentsOf: childURL.appendingPathComponent("public.txt"), encoding: .utf8) == "working-public\n"
            checks["restoredTasksReturnToPreviousArchiveState"] = tasks.task(child.taskID)?.archived == false && tasks.task(fork)?.archived == false && tasks.task(nested)?.archived == true && restored.restoredBranch == "refs/heads/acceptance/恢复"
            let actualRestoredRef = try await setup(["symbolic-ref", "HEAD"], at: childURL)
            checks["firstRestoreActuallyChecksOutOriginalBranch"] = actualRestoredRef.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/acceptance/恢复"
            do { _ = try await git.restoreWorktree(backupID: backup.id); checks["restoredBackupCannotReplayOverCurrentFiles"] = false } catch { checks["restoredBackupCannotReplayOverCurrentFiles"] = true }
            let second = try await git.prepareWorktreeRecycle(path: child.workspace), secondBackup = try await git.recycleWorktree(reviewHash: second.hash)
            let tree = try await setup(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let advanced = try await setup(["commit-tree", tree, "-p", mainHead.trimmingCharacters(in: .whitespacesAndNewlines), "-m", "public concurrent branch commit"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await setup(["update-ref", "refs/heads/acceptance/恢复", advanced])
            let recovered = try await git.restoreWorktree(backupID: secondBackup.id)
            let untouchedBranch = try await setup(["rev-parse", "refs/heads/acceptance/恢复"])
            let actualRecoveryRef = try await setup(["symbolic-ref", "HEAD"], at: childURL)
            checks["changedBranchRestoresOntoRecoveryBranchWithoutReset"] = recovered.restoredBranch?.hasPrefix("refs/heads/recovered/") == true && actualRecoveryRef.trimmingCharacters(in: .whitespacesAndNewlines) == recovered.restoredBranch && untouchedBranch.trimmingCharacters(in: .whitespacesAndNewlines) == advanced
            let recoveredStaged = try await setup(["show", ":public.txt"], at: childURL)
            checks["recoveryBranchStillHasExactFilesAndStagedVersion"] = try AgentWorktreeSnapshot.read(childURL).hash == originalTree.hash && recoveredStaged == "staged-public\n"
            let afterHead = try await setup(["rev-parse", "HEAD"])
            checks["originalProjectHeadIndexAndFilesRemainExact"] = try afterHead == mainHead && Data(contentsOf: repo.appendingPathComponent(".git/index")) == mainIndex && Data(contentsOf: repo.appendingPathComponent("public.txt")) == mainPublic
            checks["askModeHidesMutatingWorktreeTools"] = !AgentTools.definitions(mode: .ask, groups: ["worktrees"]).contains { ["git_recycle_worktree", "git_restore_worktree"].contains(($0["function"] as? [String: Any])?["name"] as? String ?? "") }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("工作树回收或恢复检查失败") }
            if CommandLine.arguments.contains("--live-agent") {
                let liveRepo = output.appendingPathComponent("live-repo"); try await initialize(liveRepo)
                let liveID = tasks.create(title: "真实模型回收与恢复", workspace: liveRepo.path), liveGit = try AgentGit(store: tasks, taskID: liveID, directory: AgentGit.metadata(workspace: liveRepo.path))
                let liveChild = try await liveGit.createWorktree(branch: "model-worktree"), liveURL = URL(fileURLWithPath: liveChild.workspace); try await dirty(liveURL)
                let liveTree = try AgentWorktreeSnapshot.read(liveURL), liveMetadata = URL(fileURLWithPath: try await setup(["rev-parse", "--absolute-git-dir"], at: liveURL).trimmingCharacters(in: .whitespacesAndNewlines)), liveIndex = try Data(contentsOf: liveMetadata.appendingPathComponent("index"))
                let profile = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var preferences = PreferencesStore(directory: profile).preferences; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
                guard let runtime = agentRuntime else { throw PetError("模型运行时不可用") }
                runtime.submit("使用worktrees和files工具组，回收工作树 \(liveChild.workspace)，再恢复它。先git_worktrees核对，git_prepare_worktree_recycle审阅，git_recycle_worktree原样传review_hash；审批由验收人员处理。回收后再git_worktrees核对，git_restore_worktree用实际backup_id恢复。最后read_file读取恢复目录的public.txt，只在当前项目写worktree-result.json并回读，JSON只含backup_id、state、path、workingText四字段，state=restored，path为实际工作树路径，workingText来自实际文件且不含行尾换行。报告不符时只修正该报告，不重复回收或恢复。禁止命令、修改原文件、切换项目、提交或推送。", taskID: liveID)
                let deadline = Date().addingTimeInterval(180); var approvals: [String] = []
                while Date() < deadline, let task = tasks.task(liveID), [.ready, .running, .waiting].contains(task.status) {
                    if task.status == .waiting, let call = task.pendingCalls.first {
                        guard ["git_prepare_worktree_recycle", "git_recycle_worktree", "git_restore_worktree"].contains(call.name), !approvals.contains(call.name) else { runtime.cancel(liveID); throw PetError("真实模型提出了预期外或重复动作") }
                        if call.name == "git_prepare_worktree_recycle" { guard call.object["path"] as? String == liveChild.workspace else { throw PetError("模型检查范围变化") } }
                        else if call.name == "git_recycle_worktree" { guard try liveGit.storedWorktreeReview(hash: call.object["review_hash"] as? String ?? "").path == liveChild.workspace else { throw PetError("模型回收范围变化") } }
                        else { guard let key = call.object["backup_id"] as? String, try liveGit.worktreeBackup(key).origin.path == liveChild.workspace else { throw PetError("模型恢复范围变化") } }
                        approvals.append(call.name); runtime.decide(taskID: liveID, callID: call.id, decision: "allow")
                    }
                    if task.events.filter({ $0.kind == "tool" && $0.status == "failed" }).count >= 2 { runtime.cancel(liveID); throw PetError("模型重复失败，验收已停止") }
                    await wait(0.1)
                }
                guard let task = tasks.task(liveID), task.status == .completed else { runtime.cancel(liveID); throw PetError("真实模型未完成回收与恢复") }
                let result = try JSONSerialization.jsonObject(with: Data(contentsOf: liveRepo.appendingPathComponent("worktree-result.json"))) as? [String: Any]
                let restoredMeta = URL(fileURLWithPath: try await setup(["rev-parse", "--absolute-git-dir"], at: liveURL).trimmingCharacters(in: .whitespacesAndNewlines))
                checks["realModelRecycledAndRestoredAfterScopedApprovals"] = approvals == ["git_prepare_worktree_recycle", "git_recycle_worktree", "git_restore_worktree"] && result?["state"] as? String == "restored"
                checks["realModelRestoredActualFilesAndRawStaging"] = try AgentWorktreeSnapshot.read(liveURL).hash == liveTree.hash && Data(contentsOf: restoredMeta.appendingPathComponent("index")) == liveIndex
                checks["realModelReportMatchesActualBackupAndWorktree"] = try result?.count == 4 && result?["path"] as? String == liveChild.workspace && result?["workingText"] as? String == "working-public" && liveGit.worktreeBackup(result?["backup_id"] as? String ?? "").state == "restored"
                var archived = task; archived.contextThroughID = task.messages.last?.id; archived.contextSummary = task.contextSummary ?? "历史工具回执校验"
                let window = AgentContext.window(archived, archivedFactBudget: 900), retained = window.filter { $0.nativeContext == true }.map(\.content).joined(separator: "\n")
                checks["actualReportWriteAndReadReceiptsSurviveCompaction"] = (retained.contains("write_file") || retained.contains("edit_file")) && retained.contains("read_file") && retained.contains("worktree-result.json")
                checks["humanRequirementsPrecedeHistoricalProgressWithoutReordering"] = window.filter(\.isHumanInput).map(\.id) == task.messages.filter(\.isHumanInput).map(\.id) && window.first?.isHumanInput == true
                report["live"] = ["taskID": liveID, "childTaskID": liveChild.taskID, "workspace": liveRepo.path, "worktree": liveChild.workspace, "backupID": result?["backup_id"] as? String ?? "", "model": preferences.model, "contextLimit": preferences.contextLimit, "outputLimit": preferences.outputLimit, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens]
            }
            tasks.selectedID = id
            let window = try AgentWorktreeWindow(store: tasks, taskID: id) { [weak self] next in self?.control.showAgentTask(next); self?.control.show(tab: "chat") }
            checks.merge(await window.checkLayout()) { _, value in value }; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            report["success"] = checks.values.allSatisfy { $0 }; report["checks"] = checks; report["taskID"] = id; report["childTaskID"] = child.taskID; report["forkTaskID"] = fork; report["workspace"] = repo.path; report["worktree"] = child.workspace; report["foreign"] = foreign.path; report["mainHead"] = mainHead.trimmingCharacters(in: .whitespacesAndNewlines)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("worktree-report.json"))
            if CommandLine.arguments.contains("--hold-ui") {
                let deadline = Date().addingTimeInterval(1200)
                while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) }
            }
            window.close()
        } catch {
            report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("worktree-report.json"))
        }
    }
}
