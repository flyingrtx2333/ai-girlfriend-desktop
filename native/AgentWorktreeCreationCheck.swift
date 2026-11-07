import AppKit

@MainActor extension AppDelegate {
    func runAgentWorktreeCreationCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let fm = FileManager.default, repo = output.appendingPathComponent("repo"), tmp = output.appendingPathComponent("tmp")
            try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            func git(_ args: [String], at root: URL? = nil) async throws -> String {
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: tmp, network: false, timeout: 30,
                    gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", (root ?? repo).path] + args)
                guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
            }
            _ = try await git(["init", "-b", "main"])
            for (key, value) in [("user.name", "Worktree Creation Acceptance"), ("user.email", "creation@example.invalid"), ("commit.gpgsign", "false")] { _ = try await git(["config", key, value]) }
            for (name, value) in [("public.txt", "base-public\n"), ("delete.txt", "delete-original\n"), ("rename.txt", "rename-original\n"), (".gitignore", "local-only.txt\n")] { try Data(value.utf8).write(to: repo.appendingPathComponent(name)) }
            _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "public baseline"])
            let mainHead = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await git(["checkout", "-b", "release"]); try Data("release-marker\n".utf8).write(to: repo.appendingPathComponent("release-only.txt"))
            _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "release branch"])
            let releaseHead = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await git(["checkout", "-b", "conflict", mainHead]); try Data("conflicting-public\n".utf8).write(to: repo.appendingPathComponent("public.txt"))
            _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "conflicting branch"])
            let conflictHead = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await git(["checkout", "main"])
            try Data("staged-public\n".utf8).write(to: repo.appendingPathComponent("public.txt")); _ = try await git(["add", "public.txt"])
            try Data("working-public\n".utf8).write(to: repo.appendingPathComponent("public.txt")); try fm.removeItem(at: repo.appendingPathComponent("delete.txt"))
            let odd = "renamed'中文\nfile.txt"; _ = try await git(["mv", "rename.txt", odd])
            try Data("ignored-marker\n".utf8).write(to: repo.appendingPathComponent("local-only.txt")); try Data([0, 1, 200, 255]).write(to: repo.appendingPathComponent("untracked.bin"))
            try Data("#!/bin/sh\nprintf public\n".utf8).write(to: repo.appendingPathComponent("executable.sh")); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appendingPathComponent("executable.sh").path)
            try fm.createSymbolicLink(atPath: repo.appendingPathComponent("relative-link").path, withDestinationPath: "public.txt")
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务存储不可用") }
            var preferences = store.preferences; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; store.preferences = preferences
            let id = tasks.create(title: "创建工作树", workspace: repo.path), helper = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: repo.path))
            tasks.update(id) { $0.draft = "保留草稿 · 核对工作树"; $0.modelOverride = "deepseek-flash" }
            let attachment = try await AgentAttachments.importFile(repo.appendingPathComponent("public.txt"), store: tasks, taskID: id)
            let index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            let points = try await helper.worktreeStartingPoints()
            checks["actualBranchesExposeExactStartingCommits"] = points.contains { $0.ref == "refs/heads/release" && $0.commit == releaseHead } && points.contains { $0.ref == "HEAD" && $0.commit == mainHead }
            let clean = try await helper.createWorktree(branch: "clean-release", startPoint: "refs/heads/release"), cleanURL = URL(fileURLWithPath: clean.workspace)
            checks["selectedBranchCreatesExactCleanBase"] = try await git(["rev-parse", "HEAD"], at: cleanURL).trimmingCharacters(in: .whitespacesAndNewlines) == releaseHead && String(contentsOf: cleanURL.appendingPathComponent("public.txt"), encoding: .utf8) == "base-public\n" && fm.fileExists(atPath: cleanURL.appendingPathComponent("release-only.txt").path)
            checks["defaultCreationExcludesUncommittedAndIgnoredFiles"] = !fm.fileExists(atPath: cleanURL.appendingPathComponent("untracked.bin").path) && !fm.fileExists(atPath: cleanURL.appendingPathComponent("local-only.txt").path)
            let review = try await helper.prepareWorktreeCreation(branch: "carry-release", startPoint: "refs/heads/release", includeChanges: true)
            checks["previewContainsRealWorkingVersionAndSpecialPaths"] = review.patch.contains("working-public") && review.paths.contains(odd) && review.paths.contains("untracked.bin") && !review.paths.contains("local-only.txt")
            checks["previewDoesNotRewriteSourceIndex"] = try Data(contentsOf: repo.appendingPathComponent(".git/index")) == index
            let carried = try await helper.createWorktree(branch: review.branch, startPoint: review.startPoint, includeChanges: true, reviewHash: review.hash), carriedURL = URL(fileURLWithPath: carried.workspace)
            let carriedStaged = try await git(["show", ":public.txt"], at: carriedURL), carriedStagedPaths = try await git(["diff", "--cached", "--name-only"], at: carriedURL)
            checks["carriedChangesAreActuallyUnstagedOnSelectedBase"] = try carriedStaged == "base-public\n" && String(contentsOf: carriedURL.appendingPathComponent("public.txt"), encoding: .utf8) == "working-public\n" && carriedStagedPaths.isEmpty
            checks["binaryLinkModeRenameAndDeleteActuallyCarried"] = try Data(contentsOf: carriedURL.appendingPathComponent("untracked.bin")) == Data([0, 1, 200, 255]) && fm.destinationOfSymbolicLink(atPath: carriedURL.appendingPathComponent("relative-link").path) == "public.txt" && (fm.attributesOfItem(atPath: carriedURL.appendingPathComponent("executable.sh").path)[.posixPermissions] as? Int) == 0o755 && fm.fileExists(atPath: carriedURL.appendingPathComponent(odd).path) && !fm.fileExists(atPath: carriedURL.appendingPathComponent("rename.txt").path) && !fm.fileExists(atPath: carriedURL.appendingPathComponent("delete.txt").path)
            checks["carriedCreationExcludesIgnoredFiles"] = !fm.fileExists(atPath: carriedURL.appendingPathComponent("local-only.txt").path)
            try tasks.copyEnvironmentDraft(sourceID: id, targetID: carried.taskID)
            let copiedAttachment = try AgentAttachments.source(store: tasks, taskID: carried.taskID, id: attachment.id), originalAttachment = try AgentAttachments.source(store: tasks, taskID: id, id: attachment.id)
            checks["draftAttachmentAndModelCopyPreserveOriginal"] = tasks.task(carried.taskID)?.draft == tasks.task(id)?.draft && tasks.task(carried.taskID)?.modelOverride == "deepseek-flash" && tasks.task(id)?.draftAttachmentIDs == [attachment.id] && tasks.task(carried.taskID)?.draftAttachmentIDs == [attachment.id] && copiedAttachment != originalAttachment
            checks["newWorktreeCanChooseEnvironmentBeforeSending"] = tasks.task(carried.taskID)?.canChooseEnvironment == true
            do { _ = try await helper.createReviewedWorktree(review.hash); checks["consumedCreationReviewCannotReplay"] = false } catch { checks["consumedCreationReviewCannotReplay"] = true }
            let stale = try await helper.prepareWorktreeCreation(branch: "stale-files", includeChanges: true)
            try Data([1, 2, 3]).write(to: repo.appendingPathComponent("untracked.bin"))
            do { _ = try await helper.createReviewedWorktree(stale.hash); checks["changedActualUntrackedFileRejectsPreview"] = false } catch { checks["changedActualUntrackedFileRejectsPreview"] = true }
            try Data([0, 1, 200, 255]).write(to: repo.appendingPathComponent("untracked.bin"))
            let baseReview = try await helper.prepareWorktreeCreation(branch: "stale-base", startPoint: "refs/heads/release")
            _ = try await git(["update-ref", "refs/heads/release", conflictHead])
            do { _ = try await helper.createReviewedWorktree(baseReview.hash); checks["movedBaseBranchRejectsPreview"] = false } catch { checks["movedBaseBranchRejectsPreview"] = true }
            _ = try await git(["update-ref", "refs/heads/release", releaseHead])
            let scopeReview = try await helper.prepareWorktreeCreation(branch: "stale-scope")
            tasks.update(id) { $0.permission = .review }
            do { _ = try await helper.createReviewedWorktree(scopeReview.hash); checks["changedTaskPermissionRejectsPreview"] = false } catch { checks["changedTaskPermissionRejectsPreview"] = true }
            tasks.update(id) { $0.permission = .workspace }
            let beforeConflict = try await git(["worktree", "list", "--porcelain"])
            do { _ = try await helper.prepareWorktreeCreation(branch: "no-conflict-creation", startPoint: "refs/heads/conflict", includeChanges: true); checks["realThreeWayConflictStopsBeforeCreation"] = false }
            catch { checks["realThreeWayConflictStopsBeforeCreation"] = error.localizedDescription.contains("无法完整合并") }
            let afterConflict = try await git(["worktree", "list", "--porcelain"]), conflictPoints = try await helper.worktreeStartingPoints()
            checks["conflictCreatesNoCheckoutOrUserBranch"] = afterConflict == beforeConflict && !conflictPoints.contains { $0.ref == "refs/heads/no-conflict-creation" }
            let hook = repo.appendingPathComponent(".git/hooks/post-checkout")
            try Data(("#!/bin/sh\nset -e\nprintf forbidden > " + AgentGit.quote(repo.appendingPathComponent("public.txt").path) + "\n").utf8).write(to: hook); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            do { _ = try await helper.createWorktree(branch: "hook-rejected"); checks["actualHookCannotWriteSourceWorkspace"] = false } catch { checks["actualHookCannotWriteSourceWorkspace"] = try String(contentsOf: repo.appendingPathComponent("public.txt"), encoding: .utf8) == "working-public\n" }
            checks["failedCheckoutRetainsAssociatedTaskForInspection"] = tasks.tasks.contains { $0.parentID == id && $0.status == .failed && $0.worktreeOrigin != nil }
            try fm.removeItem(at: hook)
            let sourceHead = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), sourceRef = try await git(["symbolic-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), sourceStaged = try await git(["show", ":public.txt"])
            checks["sourceHeadBranchIndexAndWorkingVersionsPreserved"] = try sourceHead == mainHead && sourceRef == "refs/heads/main" && Data(contentsOf: repo.appendingPathComponent(".git/index")) == index && String(contentsOf: repo.appendingPathComponent("public.txt"), encoding: .utf8) == "working-public\n" && sourceStaged == "staged-public\n"
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("真实 Git 创建流程未通过") }
            report.merge(["taskID": id, "workspace": repo.path, "mainHead": mainHead, "releaseHead": releaseHead, "sourceIndexSHA256": AgentFiles.hash(index), "carriedWorkspace": carried.workspace, "carriedTaskID": carried.taskID, "oddPath": odd]) { _, value in value }
            if CommandLine.arguments.contains("--live-agent") {
                let production = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
                var real = PreferencesStore(directory: production).preferences; real.voiceEnabled = false; real.wakeEnabled = false; real.screenObservationEnabled = false; store.preferences = real
                guard let runtime = agentRuntime else { throw PetError("模型运行时不可用") }
                let liveID = tasks.create(title: "真实模型创建工作树", workspace: repo.path)
                runtime.submit("使用worktrees和files工具组。先git_worktree_branches核对，使用git_prepare_worktree审阅新分支model-from-release，start_point=refs/heads/release，include_changes=true；再git_create_worktree原样传相同选项和review_hash，只创建一次。审批由验收人员处理。创建后read_file读取返回工作树路径里的public.txt，当前项目写creation-result.json并回读，只含workspace、branch、baseCommit、workingText四字段；baseCommit来自实际创建回执，workingText去掉行尾换行。只修正报告，不重复创建。不执行命令、提交、推送或修改原文件。", taskID: liveID)
                var approvals: [String] = []; let deadline = Date().addingTimeInterval(180)
                while Date() < deadline, let task = tasks.task(liveID), [.ready, .running, .waiting].contains(task.status) {
                    if task.status == .waiting, let call = task.pendingCalls.first {
                        guard ["git_prepare_worktree", "git_create_worktree"].contains(call.name), !approvals.contains(call.name), call.object["branch"] as? String == "model-from-release", call.object["start_point"] as? String == "refs/heads/release", call.object["include_changes"] as? Bool == true else { runtime.cancel(liveID); throw PetError("模型提出预期外或重复动作") }
                        approvals.append(call.name); runtime.decide(taskID: liveID, callID: call.id, decision: "allow")
                    }
                    if task.events.filter({ $0.status == "failed" && $0.kind == "tool" }).count >= 2 { runtime.cancel(liveID); throw PetError("真实模型重复失败") }
                    await wait(0.1)
                }
                guard let task = tasks.task(liveID), task.status == .completed,
                      let child = tasks.tasks.first(where: { $0.parentID == liveID && $0.worktreeOrigin != nil }), let workspace = child.workspace else { runtime.cancel(liveID); throw PetError("真实模型未完成创建") }
                let result = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("creation-result.json"))) as? [String: Any]
                checks["realModelCreatesOnceAfterTwoScopedApprovals"] = approvals == ["git_prepare_worktree", "git_create_worktree"] && result?.count == 4 && result?["workspace"] as? String == workspace && result?["baseCommit"] as? String == releaseHead && result?["workingText"] as? String == "working-public"
                runtime.submit("只在当前工作树读取public.txt及release-only.txt，然后写child-result.json并回读，JSON只含workingText=实际public.txt去掉行尾、releaseText=实际release-only.txt去掉行尾两字段。不执行命令或修改其他文件。", taskID: child.id)
                let childDeadline = Date().addingTimeInterval(90)
                while Date() < childDeadline, let value = tasks.task(child.id), [.ready, .running].contains(value.status) { await wait(0.1) }
                guard let finished = tasks.task(child.id), finished.status == .completed else { runtime.cancel(child.id); throw PetError("新工作树模型任务未完成") }
                let childResult = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: workspace).appendingPathComponent("child-result.json"))) as? [String: String]
                checks["realModelExecutesInsideCreatedCheckout"] = childResult == ["workingText": "working-public", "releaseText": "release-marker"] && !fm.fileExists(atPath: repo.appendingPathComponent("child-result.json").path)
                checks["sentTaskCannotSwitchExecutionEnvironment"] = !finished.canChooseEnvironment
                checks["realModelKeptSourceRawIndex"] = try Data(contentsOf: repo.appendingPathComponent(".git/index")) == index
                report["live"] = ["taskID": liveID, "childTaskID": child.id, "workspace": workspace, "model": real.model, "contextLimit": real.contextLimit, "outputLimit": real.outputLimit, "inputTokens": task.inputTokens + finished.inputTokens, "outputTokens": task.outputTokens + finished.outputTokens]
            }
            tasks.selectedID = id; control.showAgentTask(id); control.show(tab: "chat")
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("creation-report.json"))
            if CommandLine.arguments.contains("--hold-ui") { let deadline = Date().addingTimeInterval(1200); while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-ui").path) { await wait(0.25) } }
        } catch {
            report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("creation-report.json"))
        }
    }
}
