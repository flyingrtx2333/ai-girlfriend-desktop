import AppKit

@MainActor extension AppDelegate {
    func workspaceWorktreeGit(_ args: [String], root: URL, output: URL) async throws -> String {
        let temporary = output.appendingPathComponent("git-fixture-tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: temporary, network: false, timeout: 30,
            gitDirectory: root.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory,
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_OPTIONAL_LOCKS": "0"], arguments: ["-C", root.path] + args)
        guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
    }
    func prepareWorkspaceWorktreeFixtures(_ output: URL, tasks: AgentStore) async throws -> String {
        let fm = FileManager.default, alpha = output.appendingPathComponent("Alpha 公开项目"), beta = output.appendingPathComponent("Beta 公开项目"), plain = output.appendingPathComponent("普通资料")
        var sources: [[String: Any]] = []
        for (index, root) in [alpha, beta].enumerated() {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            _ = try await workspaceWorktreeGit(["init", "-b", index == 0 ? "main" : "trunk"], root: root, output: output)
            for (key, value) in [("user.name", "Public Multi-source Acceptance"), ("user.email", "acceptance@example.invalid"), ("commit.gpgsign", "false")] { _ = try await workspaceWorktreeGit(["config", key, value], root: root, output: output) }
            for (name, text) in [("README.md", "# " + root.lastPathComponent + "\n公开验收资料。\n"), ("public.txt", "base-\(index)\n"), (".gitignore", "local-only.txt\n")] { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
            _ = try await workspaceWorktreeGit(["add", "."], root: root, output: output); _ = try await workspaceWorktreeGit(["commit", "-m", "public baseline"], root: root, output: output)
            let head = try await workspaceWorktreeGit(["rev-parse", "HEAD"], root: root, output: output).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await workspaceWorktreeGit(["checkout", "-b", "release"], root: root, output: output)
            try Data("release-\(index)\n".utf8).write(to: root.appendingPathComponent("release-only.txt"))
            _ = try await workspaceWorktreeGit(["add", "."], root: root, output: output); _ = try await workspaceWorktreeGit(["commit", "-m", "public release"], root: root, output: output)
            let release = try await workspaceWorktreeGit(["rev-parse", "HEAD"], root: root, output: output).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await workspaceWorktreeGit(["checkout", index == 0 ? "main" : "trunk"], root: root, output: output)
            try Data("staged-\(index)\n".utf8).write(to: root.appendingPathComponent("public.txt")); _ = try await workspaceWorktreeGit(["add", "public.txt"], root: root, output: output)
            try Data("working-\(index)\n".utf8).write(to: root.appendingPathComponent("public.txt"))
            try Data("ignored-public-\(index)\n".utf8).write(to: root.appendingPathComponent("local-only.txt"))
            sources.append(["root": root.path, "head": head, "release": release, "indexSHA256": AgentFiles.hash(try Data(contentsOf: root.appendingPathComponent(".git/index")))])
        }
        try fm.createDirectory(at: plain, withIntermediateDirectories: false); try Data("公开非 Git 资料。\n".utf8).write(to: plain.appendingPathComponent("README.md"))
        let id = tasks.create(title: "多源工作树验收", workspaceScope: AgentWorkspaceScope(group: beta.path, folders: [alpha.path, beta.path], primary: beta.path))
        tasks.update(id) { $0.draft = "保留多源工作树原草稿 🧭"; $0.gitDirectory = beta.appendingPathComponent(".git").path; $0.inheritedLimits = AgentInheritedLimits(readOnly: false, network: false, permission: .workspace) }
        let negative = tasks.create(title: "非 Git 源工作树验收", workspaceScope: AgentWorkspaceScope(group: alpha.path, folders: [alpha.path, plain.path], primary: alpha.path))
        tasks.update(negative) { $0.draft = "保留非 Git 源验收草稿"; $0.gitDirectory = alpha.appendingPathComponent(".git").path }
        tasks.selectedID = id
        tasks.worktreeRetention.start(store: tasks)
        let fixture: [String: Any] = ["taskID": id, "nonGitTaskID": negative, "primary": beta.path, "folders": [alpha.path, beta.path], "sources": sources, "modelRequests": 0]
        try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("workspace-worktrees-fixtures.json"))
        return id
    }
    func runWorkspaceWorktreeCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少独立任务运行时") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("多源工作树检查禁止模型请求") }
            let id = try await prepareWorkspaceWorktreeFixtures(output, tasks: tasks)
            defer { tasks.worktreeRetention.stop() }
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("workspace-worktrees-fixtures.json"))) as! [String: Any]
            let roots = (fixture["folders"] as! [String]).map { URL(fileURLWithPath: $0) }, alpha = roots[0], beta = roots[1]
            let helper = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: beta.path))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let original = try encoder.encode(tasks.task(id)!), indexes = try roots.map { try Data(contentsOf: $0.appendingPathComponent(".git/index")) }
            let starts = try await helper.workspaceWorktreeStartingPoints()
            checks["allSourcesExposeIndependentStartingPointsWithPrimaryFirst"] = starts.map(\.root) == [beta.path, alpha.path] && starts.allSatisfy { $0.points.contains { $0.ref == "refs/heads/release" } }
            let branchTool = try await AgentTools(store: tasks, taskID: id).execute(AgentToolCall(id: UUID().uuidString, name: "git_worktree_branches", arguments: "{}"), gitDirectory: helper.directory.path)
            let branchValue = try JSONSerialization.jsonObject(with: Data(branchTool.text.utf8)) as? [String: Any]
            checks["modelToolReturnsBothSourceCatalogsWithoutCallingModel"] = branchValue?["primary"] as? String == beta.path && (branchValue?["sources"] as? [[String: Any]])?.count == 2
            let secondary = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: alpha.path), workspace: alpha.path)
            do { _ = try await helper.createWorktree(branch: "unreviewed-group"); checks["multiSourceCreationRequiresExplicitPreparedReview"] = false } catch { checks["multiSourceCreationRequiresExplicitPreparedReview"] = error.localizedDescription.contains("review_hash") }
            checks["selectedGitContextUsesSecondaryRepository"] = try await secondary.status().branch == "main"
            do { _ = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: alpha.path), workspace: output.path); checks["unselectedGitRootRejected"] = false } catch { checks["unselectedGitRootRejected"] = true }
            let review = try await helper.prepareWorktreeCreation(branch: "multi-carry", startPoint: "refs/heads/release", includeChanges: true, sourceStartPoints: [alpha.path: "refs/heads/release"])
            checks["previewListsEveryRootBranchAndActualPatch"] = review.sources?.count == 2 && review.sources?.map(\.branch) == ["multi-carry", "multi-carry-2"] && review.patch.contains(alpha.path) && review.patch.contains(beta.path) && review.paths.contains(alpha.path + "/public.txt") && review.paths.contains(beta.path + "/public.txt")
            let created = try await helper.createReviewedWorktree(review.hash)
            guard let child = tasks.task(created.taskID), let scope = child.workspaceScope else { throw PetError("多源任务未保留完整范围") }
            let origins = child.managedWorktreeOrigins, childRoots = scope.folders.map { URL(fileURLWithPath: $0) }
            checks["oneTaskOwnsAllCheckoutsAndOriginalFolderOrder"] = origins.count == 2 && created.sources?.count == 2 && childRoots.map(\.path) == [origins.first { $0.root == alpha.path }!.path, origins.first { $0.root == beta.path }!.path] && scope.primary == origins.first { $0.root == beta.path }!.path && scope.group == beta.path && child.worktreeSetup == nil && child.status == .ready
            checks["createdTaskRetainsInheritedNetworkAndPermissionLimits"] = child.inheritedLimits?.network == false && child.inheritedLimits?.readOnly == false && child.inheritedLimits?.permission == .workspace
            checks["sourceContextsUseOriginalRepositoryNames"] = try AgentWorkspaceScope.contexts(child).map(\.workspaceDisplayName) == ["Beta 公开项目 · 工作树", "Alpha 公开项目 · 工作树"]
            var carried = true
            for (index, root) in roots.enumerated() {
                let destination = URL(fileURLWithPath: origins.first { $0.root == root.path }!.path)
                let head = try await workspaceWorktreeGit(["rev-parse", "HEAD"], root: destination, output: output).trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = try await workspaceWorktreeGit(["rev-parse", "release"], root: root, output: output).trimmingCharacters(in: .whitespacesAndNewlines)
                let staged = try await workspaceWorktreeGit(["diff", "--cached", "--name-only"], root: destination, output: output)
                carried = try carried && head == expected && String(contentsOf: destination.appendingPathComponent("public.txt"), encoding: .utf8) == "working-\(index)\n" && staged.isEmpty && !FileManager.default.fileExists(atPath: destination.appendingPathComponent("local-only.txt").path)
            }
            checks["bothSelectedCommitsAndUnstagedVersionsActuallyCarried"] = carried
            try tasks.copyEnvironmentDraft(sourceID: id, targetID: created.taskID)
            checks["draftAndTaskPermissionCopiedWithoutChangingOriginal"] = tasks.task(created.taskID)?.draft == tasks.task(id)?.draft && tasks.task(created.taskID)?.permission == tasks.task(id)?.permission
            let localID = tasks.create(workspace: beta.path, mode: child.mode, workspaceScope: AgentWorkspaceScope(group: beta.path, folders: roots.map(\.path), primary: beta.path))
            try tasks.copyEnvironmentDraft(sourceID: created.taskID, targetID: localID)
            checks["returningToLocalRetainsLimitsAndAllSources"] = try encoder.encode(tasks.task(localID)?.inheritedLimits) == encoder.encode(child.inheritedLimits) && tasks.task(localID)?.workspacePaths == roots.map(\.path) && tasks.task(localID)?.workspace == beta.path && tasks.task(localID)?.worktreeOrigins == nil
            let sidebar = AgentTaskSidebar(frame: NSRect(x: 0, y: 0, width: 232, height: 700))
            sidebar.refresh(tasks.tasks, selected: localID, organization: tasks.organization)
            let directoryNames = sidebar.organizationSnapshot()["directories"] as? [String] ?? []
            checks["mixedLocalAndWorktreeTasksKeepOriginalWorkspaceGroupTitle"] = directoryNames.contains("Beta 公开项目") && !directoryNames.contains("Beta 公开项目 · 工作树 · 2 个源")
            var inputTaskID: String?
            let inputController = try AgentWorktreeCreationWindow(store: tasks, taskID: id, directory: helper.directory) { inputTaskID = $0 }
            func popup(_ view: NSView, label: String) -> NSPopUpButton? {
                if let value = view as? NSPopUpButton, value.accessibilityLabel() == label { return value }
                return view.subviews.lazy.compactMap { popup($0, label: label) }.first
            }
            await inputController.checkWorkspace(branch: "late-control-input", action: "preview")
            guard let content = inputController.window?.contentView,
                  let primaryPopup = popup(content, label: "起点分支"), let secondaryPopup = popup(content, label: "起点分支 · " + alpha.path),
                  let primaryRelease = primaryPopup.itemArray.first(where: { $0.representedObject as? String == "refs/heads/release" }),
                  let secondaryRelease = secondaryPopup.itemArray.first(where: { $0.representedObject as? String == "refs/heads/release" }) else { throw PetError("未找到实际起点控件") }
            let beforeLatePrimary = try await helper.worktrees().count, beforeLateSecondary = try await secondary.worktrees().count
            secondaryPopup.select(secondaryRelease)
            await inputController.checkWorkspace(action: "create")
            let afterLatePrimary = try await helper.worktrees().count, afterLateSecondary = try await secondary.worktrees().count
            checks["lateSecondarySelectionRejectsStalePreviewBeforeAnyCheckout"] = inputTaskID == nil && beforeLatePrimary == afterLatePrimary && beforeLateSecondary == afterLateSecondary && inputController.workspaceReadback()["createEnabled"] as? Bool == false
            await inputController.checkWorkspace(action: "preview")
            primaryPopup.select(primaryRelease)
            await inputController.checkWorkspace(action: "create")
            checks["latePrimarySelectionRejectsStalePreviewBeforeAnyTask"] = inputTaskID == nil && inputController.workspaceReadback()["createEnabled"] as? Bool == false
            await inputController.checkWorkspace(action: "preview"); await inputController.checkWorkspace(action: "create")
            guard let inputTaskID, let inputTask = tasks.task(inputTaskID) else { throw PetError("起点变化后重新预览未能创建") }
            var correctInputs = true
            for origin in inputTask.managedWorktreeOrigins {
                let actual = try await workspaceWorktreeGit(["rev-parse", "HEAD"], root: URL(fileURLWithPath: origin.path), output: output).trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = try await workspaceWorktreeGit(["rev-parse", "release"], root: URL(fileURLWithPath: origin.root), output: output).trimmingCharacters(in: .whitespacesAndNewlines)
                correctInputs = correctInputs && actual == expected
            }
            checks["repreviewUsesActualSelectedCommitsAfterLateChanges"] = correctInputs && inputTask.managedWorktreeOrigins.count == 2
            let tools = AgentTools(store: tasks, taskID: created.taskID)
            for root in childRoots {
                let value = try String(decoding: JSONSerialization.data(withJSONObject: ["path": root.appendingPathComponent("native-created.txt").path, "content": "isolated write\n"]), as: UTF8.self)
                let result = try await tools.execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: value))
                checks["actualFileWriteAllowedIn-" + root.lastPathComponent] = !result.failed && FileManager.default.fileExists(atPath: root.appendingPathComponent("native-created.txt").path)
            }
            do { let result = try await tools.execute(AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: JSONSerialization.data(withJSONObject: ["path": alpha.appendingPathComponent("forbidden.txt").path, "content": "no"]), as: UTF8.self))); checks["originalSourceWriteRejectedAfterIsolation"] = result.failed && !FileManager.default.fileExists(atPath: alpha.appendingPathComponent("forbidden.txt").path) } catch { checks["originalSourceWriteRejectedAfterIsolation"] = !FileManager.default.fileExists(atPath: alpha.appendingPathComponent("forbidden.txt").path) }
            let owner = UUID(); tasks.worktreeRetention.setNativeOperation(owner, taskID: created.taskID, busy: true)
            checks["nativeOperationProtectsEverySourceCheckout"] = childRoots.allSatisfy { tasks.worktreeRetention.hasNativeOperation($0.path) }
            tasks.worktreeRetention.setNativeOperation(owner, taskID: created.taskID, busy: false)
            checks["retentionListsBothOriginalRepositories"] = Set(tasks.worktreeRetention.roots().map(\.path)) == Set(roots.map(\.path))
            let entries = try await secondary.worktrees()
            checks["secondaryManagerFindsOwnedCheckoutAndSharedTask"] = entries.contains { $0.path == childRoots[0].path && $0.owned && $0.taskIDs.contains(created.taskID) }
            let betaEntry = origins.first { $0.root == beta.path }!, alphaEntry = origins.first { $0.root == alpha.path }!
            try Data("ignored child payload\n".utf8).write(to: URL(fileURLWithPath: alphaEntry.path).appendingPathComponent("local-only.txt"))
            let primaryReview = try await helper.prepareWorktreeRecycle(path: betaEntry.path), first = try await helper.recycleWorktree(reviewHash: primaryReview.hash)
            checks["recyclingOneSourceArchivesSharedTaskAndRetainsOtherSource"] = tasks.task(created.taskID)?.archived == true && FileManager.default.fileExists(atPath: alphaEntry.path) && tasks.task(created.taskID)?.worktreeRecycleArchived == false
            let otherReview = try await secondary.prepareWorktreeRecycle(path: alphaEntry.path), second = try await secondary.recycleWorktree(reviewHash: otherReview.hash)
            _ = try await helper.restoreWorktree(backupID: first.id)
            checks["partialRestoreKeepsTaskArchivedUntilAllSourcesAvailable"] = tasks.task(created.taskID)?.archived == true && tasks.task(created.taskID)?.worktreeRecycleArchived == false
            _ = try await secondary.restoreWorktree(backupID: second.id)
            checks["fullRestoreRecoversOriginalArchiveStateAndBothScopes"] = try tasks.task(created.taskID)?.archived == false && tasks.task(created.taskID)?.worktreeRecycleArchived == nil && AgentWorkspaceScope.roots(tasks.task(created.taskID)!).count == 2 && String(contentsOf: URL(fileURLWithPath: alphaEntry.path).appendingPathComponent("local-only.txt"), encoding: .utf8) == "ignored child payload\n"
            let before = try await helper.worktrees().count, secondaryBefore = try await secondary.worktrees().count
            let nongitID = fixture["nonGitTaskID"] as! String, nongit = try AgentGit(store: tasks, taskID: nongitID, directory: AgentGit.metadata(workspace: alpha.path))
            do { _ = try await nongit.prepareWorktreeCreation(branch: "nongit-rejected"); checks["nonGitSourceStopsWholePreviewBeforeCreation"] = false } catch { checks["nonGitSourceStopsWholePreviewBeforeCreation"] = error.localizedDescription.contains("普通资料") }
            let nonGitPrimaryCount = try await helper.worktrees().count, nonGitSecondaryCount = try await secondary.worktrees().count
            checks["nonGitRejectionCreatesNoCheckoutInEitherRepository"] = nonGitPrimaryCount == before && nonGitSecondaryCount == secondaryBefore
            let stale = try await helper.prepareWorktreeCreation(branch: "stale-secondary", sourceStartPoints: [alpha.path: "refs/heads/release"])
            let oldRelease = try await workspaceWorktreeGit(["rev-parse", "release"], root: alpha, output: output).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await workspaceWorktreeGit(["update-ref", "refs/heads/release", "main"], root: alpha, output: output)
            do { _ = try await helper.createReviewedWorktree(stale.hash); checks["secondaryChangedAfterPreviewRejectsBeforePrimaryCreation"] = false } catch { checks["secondaryChangedAfterPreviewRejectsBeforePrimaryCreation"] = try await helper.worktrees().count == before }
            _ = try await workspaceWorktreeGit(["update-ref", "refs/heads/release", oldRelease], root: alpha, output: output)
            let blockedParent = alpha.appendingPathComponent(".bluefatfish/worktrees"), parentMode = try FileManager.default.attributesOfItem(atPath: alpha.appendingPathComponent(".bluefatfish/worktrees").path)[.posixPermissions] as! NSNumber
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blockedParent.path)
            do { let value = try await helper.prepareWorktreeCreation(branch: "missing-source"); _ = try await helper.createReviewedWorktree(value.hash); checks["missingSecondCheckoutRetainsFirstAndPendingScope"] = false }
            catch { checks["missingSecondCheckoutRetainsFirstAndPendingScope"] = helper.lastCreatedWorktreeTaskID.flatMap { tasks.task($0) }.map { $0.worktreeSetup != nil && $0.managedWorktreeOrigins.count == 1 && $0.workspacePaths.count == 1 } == true }
            try FileManager.default.setAttributes([.posixPermissions: parentMode], ofItemAtPath: blockedParent.path)
            guard let missingID = helper.lastCreatedWorktreeTaskID, let firstPath = tasks.task(missingID)?.workspace else { throw PetError("未保留首个实际检出") }
            let originalBranchExists = try await secondary.run(["show-ref", "--verify", "--quiet", "refs/heads/missing-source-2"]).exitCode == 0
            let pending = try AgentWorktreeCreationWindow(store: tasks, taskID: id, directory: helper.directory, resumeTaskID: missingID) { _ in }
            await pending.checkWorkspace(includeChanges: true)
            guard let form = pending.captureDraft() else { throw PetError("未保存待续建任务的选项") }
            pending.endSettingsHosting()
            let reopened = try AgentWorktreeCreationWindow(store: tasks, taskID: id, directory: helper.directory, resumeTaskID: missingID, recovery: form) { _ in }
            await reopened.checkWorkspace()
            let readback = reopened.workspaceReadback()
            checks["partialCreationDraftRetainsTaskAndExistingCheckout"] = readback["resumeTaskID"] as? String == missingID &&
                readback["retainedRoots"] as? [String] == [beta.path] && readback["branch"] as? String == "missing-source" &&
                readback["includeChanges"] as? Bool == true && readback["createEnabled"] as? Bool == false &&
                tasks.task(missingID)?.worktreeSetup?.includeChanges == false
            reopened.endSettingsHosting()
            let remaining = try await helper.prepareWorktreeCreation(branch: "missing-source", resumeTaskID: missingID)
            checks["remainingSourceIsRepreviewedWithRetainedFirstCheckout"] = remaining.sources?.count == 1 && remaining.retained?.count == 1 && remaining.sources?.first?.root == alpha.path
            checks["leftoverBranchIsPreservedAndNewNameExplicitInPreview"] = !originalBranchExists || (remaining.sources?.first?.branch.hasPrefix("missing-source-2-retry-") == true && remaining.patch.contains(remaining.sources!.first!.branch))
            let missingResumed = try await helper.createReviewedWorktree(remaining.hash)
            checks["resumeCreatesOnlyMissingSourceInOriginalTask"] = missingResumed.taskID == missingID && tasks.task(missingID)?.managedWorktreeOrigins.count == 2 && tasks.task(missingID)?.workspace == firstPath && tasks.task(missingID)?.worktreeSetup == nil
            let hook = alpha.appendingPathComponent(".git/hooks/post-checkout")
            try Data("#!/bin/sh\nexit 7\n".utf8).write(to: hook); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            do { let value = try await helper.prepareWorktreeCreation(branch: "partial-resume"); _ = try await helper.createReviewedWorktree(value.hash); checks["failedSecondCheckoutRetainsSinglePendingTask"] = false }
            catch { checks["failedSecondCheckoutRetainsSinglePendingTask"] = helper.lastCreatedWorktreeTaskID.flatMap { tasks.task($0) }.map { $0.worktreeSetup != nil && $0.managedWorktreeOrigins.count == 2 && $0.status == .failed } == true }
            try FileManager.default.removeItem(at: hook)
            guard let partialID = helper.lastCreatedWorktreeTaskID, let partial = tasks.task(partialID) else { throw PetError("未保留部分创建的任务") }
            let partialTasks = tasks.tasks.filter { $0.parentID == id && $0.worktreeSetup != nil }
            let beforeForkCount = tasks.tasks.count
            do { _ = try tasks.sideTasks.create(parentID: partialID); checks["pendingTaskCannotForkAroundIncompleteSetup"] = false }
            catch { checks["pendingTaskCannotForkAroundIncompleteSetup"] = tasks.tasks.count == beforeForkCount }
            checks["pendingTaskDoesNotSubmitOrAnalyzeOrStartModel"] = !runtime.submit("不得发出请求", taskID: partialID) && !runtime.analyze(partialID, recap: true) && requests == 0
            runtime.start(partialID); checks["pendingTaskDirectResumeMakesNoModelRequest"] = !runtime.isBusy(partialID) && requests == 0
            do { _ = try await AgentTools(store: tasks, taskID: partialID).execute(AgentToolCall(id: UUID().uuidString, name: "read_file", arguments: #"{"path":"public.txt"}"#)); checks["pendingTaskCannotExecuteModelTools"] = false } catch { checks["pendingTaskCannotExecuteModelTools"] = true }
            let resume = try await helper.prepareWorktreeCreation(branch: "partial-resume", resumeTaskID: partialID)
            checks["resumePreviewIncludesBothRetainedCheckouts"] = resume.sources?.isEmpty == true && resume.retained?.count == 2 && resume.patch.contains(partial.workspace!)
            try tasks.copyEnvironmentDraft(sourceID: id, targetID: partialID)
            tasks.update(partialID) { $0.draft = "续建期间新草稿 🧭"; $0.modelOverride = "deepseek-flash" }
            var resumedID: String?
            let taskCountBeforeResume = tasks.tasks.count
            let controller = try AgentWorktreeCreationWindow(store: tasks, taskID: id, directory: helper.directory, resumeTaskID: partialID) { resumedID = $0 }
            await controller.checkWorkspace(action: "preview"); await controller.checkWorkspace(action: "create")
            guard let resumedID else { throw PetError("实际续建控制器未完成创建") }
            let resumed = AgentGitWorktree(taskID: resumedID, workspace: tasks.task(resumedID)!.workspace!, branch: "partial-resume")
            let expectedResumedFolders = roots.map { root in partial.managedWorktreeOrigins.first { $0.root == root.path }!.path }
            checks["resumeReusesSameTaskAndCheckoutsWithoutDuplicates"] = resumed.taskID == partialID && tasks.task(partialID)?.worktreeSetup == nil && tasks.task(partialID)?.status == .ready && tasks.tasks.count == taskCountBeforeResume && tasks.tasks.filter { partialTasks.map(\.id).contains($0.id) }.count == 1 && tasks.task(partialID)?.workspacePaths == expectedResumedFolders && tasks.task(partialID)?.workspace == partial.workspace
            checks["resumingControllerPreservesOwnDraftAndModelSelection"] = tasks.task(partialID)?.draft == "续建期间新草稿 🧭" && tasks.task(partialID)?.modelOverride == "deepseek-flash"
            let originalAfter = try encoder.encode(tasks.task(id)!)
            checks["originalTaskRemainsExact"] = originalAfter == original
            checks["originalIndexesAndWorkingVersionsRemainExact"] = try roots.enumerated().allSatisfy { index, root in try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexes[index] && String(contentsOf: root.appendingPathComponent("public.txt"), encoding: .utf8) == "working-\(index)\n" }
            let reloaded = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["allSourceMappingsSurviveActualStoreReopen"] = reloaded.task(created.taskID)?.managedWorktreeOrigins == tasks.task(created.taskID)?.managedWorktreeOrigins && reloaded.task(partialID)?.workspaceScope == tasks.task(partialID)?.workspaceScope
            var legacy = try JSONSerialization.jsonObject(with: encoder.encode(child)) as! [String: Any]
            for field in ["worktreeOrigins", "worktreeSetup", "worktreeRecycleArchived"] { legacy.removeValue(forKey: field) }
            let old = try JSONDecoder().decode(AgentTaskRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
            checks["legacySingleOriginStillDecodesAndRemainsManaged"] = old.worktreeOrigins == nil && old.managedWorktreeOrigins.count == 1 && old.managedWorktreeOrigins.first == old.worktreeOrigin
            report["taskID"] = id; report["createdTaskID"] = created.taskID; report["resumedTaskID"] = resumed.taskID; report["origins"] = try JSONSerialization.jsonObject(with: encoder.encode(origins))
            report["success"] = checks.values.allSatisfy { $0 }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workspace-worktrees-report.json"))
    }
}
