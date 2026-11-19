import AppKit

@MainActor extension AppDelegate {
    struct WorktreeWorkspaceFixture {
        let taskID: String, secondID: String, standaloneID: String, childID: String, externalTaskID: String
        let workspace: URL, child: URL, foreign: URL, eligibleExternal: URL
        let releaseHead: String, indexHash: String
    }
    func prepareWorktreeWorkspaceUI(_ output: URL) async throws -> WorktreeWorkspaceFixture {
        guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("工作树页面验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
        guard !tasks.worktreeRetention.policy.enabled else { throw PetError("页面验收需要关闭独立资料的自动回收") }
        tasks.worktreeRetention.start(store: tasks)
        let fm = FileManager.default, repo = output.appendingPathComponent("public-project"), tmp = output.appendingPathComponent("tmp")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let externalParent = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + "-external-fixture", isDirectory: true)
        try fm.createDirectory(at: externalParent, withIntermediateDirectories: false)
        func git(_ args: [String], at root: URL? = nil) async throws -> String {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: tmp, network: false, timeout: 20, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, readRoots: [externalParent], writeRoots: [externalParent], arguments: ["-C", (root ?? repo).path] + args)
            guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
        }
        _ = try await git(["init", "-b", "main"])
        for (key, value) in [("user.name", "Worktree Workspace Acceptance"), ("user.email", "workspace@example.invalid"), ("commit.gpgsign", "false")] { _ = try await git(["config", key, value]) }
        try Data("base-public\n".utf8).write(to: repo.appendingPathComponent("public.txt")); try Data("local-only.txt\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "public worktree baseline"])
        _ = try await git(["checkout", "-b", "release"]); try Data("release-marker\n".utf8).write(to: repo.appendingPathComponent("release-only.txt"))
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "public release baseline"])
        let releaseHead = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines); _ = try await git(["checkout", "main"])
        try Data("staged-public\n".utf8).write(to: repo.appendingPathComponent("public.txt")); _ = try await git(["add", "public.txt"])
        try Data("working-public\n".utf8).write(to: repo.appendingPathComponent("public.txt")); try Data("source-ignored\n".utf8).write(to: repo.appendingPathComponent("local-only.txt"))
        try Data("public note\n".utf8).write(to: repo.appendingPathComponent("notes.txt"))
        let first = tasks.create(title: "工作树创建与管理", workspace: repo.path), second = tasks.create(title: "另一任务的工作树配置", workspace: repo.path), standalone = tasks.create(title: "无工作区任务", mode: .ask, workMode: .general)
        tasks.update(first) { $0.draft = "保留工作树任务输入。" }; tasks.update(second) { $0.draft = "保留另一任务输入。" }
        let helper = try AgentGit(store: tasks, taskID: first, directory: AgentGit.metadata(workspace: repo.path)), child = try await helper.createWorktree(branch: "acceptance/retained"), childURL = URL(fileURLWithPath: child.workspace)
        try Data("child-staged\n".utf8).write(to: childURL.appendingPathComponent("public.txt")); _ = try await git(["add", "public.txt"], at: childURL)
        try Data("child-working\n".utf8).write(to: childURL.appendingPathComponent("public.txt")); try Data("child-ignored\n".utf8).write(to: childURL.appendingPathComponent("local-only.txt"))
        try Data([0, 1, 200, 255]).write(to: childURL.appendingPathComponent("untracked.bin"))
        let foreign = output.appendingPathComponent("external-checkout"); _ = try await git(["worktree", "add", "-b", "acceptance/external", foreign.path, "HEAD"])
        let eligible = externalParent.appendingPathComponent("外部 检出", isDirectory: true)
        try Data("independent public file\n".utf8).write(to: externalParent.appendingPathComponent("keep.txt"))
        _ = try await git(["worktree", "add", "-b", "acceptance/manual-external", eligible.path, "HEAD"])
        try Data("external-staged\n".utf8).write(to: eligible.appendingPathComponent("public.txt")); _ = try await git(["add", "public.txt"], at: eligible)
        try Data("external-working\n".utf8).write(to: eligible.appendingPathComponent("public.txt"))
        try Data("external-ignored\n".utf8).write(to: eligible.appendingPathComponent("local-only.txt"))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eligible.appendingPathComponent("local-only.txt").path)
        let externalTask = tasks.create(title: "外部工作树公开任务", workspace: eligible.path)
        tasks.update(externalTask) { $0.draft = "外部工作树原输入。" }
        let indexHash = AgentFiles.hash(try Data(contentsOf: repo.appendingPathComponent(".git/index")))
        let fixture = WorktreeWorkspaceFixture(taskID: first, secondID: second, standaloneID: standalone, childID: child.taskID, externalTaskID: externalTask, workspace: repo, child: childURL, foreign: foreign, eligibleExternal: eligible, releaseHead: releaseHead, indexHash: indexHash)
        try JSONSerialization.data(withJSONObject: ["taskID": first, "secondID": second, "standaloneID": standalone, "childID": child.taskID, "workspace": repo.path, "child": childURL.path, "foreign": foreign.path, "eligibleExternal": eligible.path, "externalTaskID": externalTask, "releaseHead": releaseHead, "sourceIndexSHA256": indexHash, "modelTransmissions": 0], options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("worktree-workspace-fixtures.json"))
        control.showAgentTask(first); control.show(tab: "chat"); control.showAgentGit(); return fixture
    }
    func reopenWorktreeWorkspaceUI(_ output: URL) throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("worktree-workspace-fixtures.json"))) as? [String: Any]
        guard let id = fixture?["taskID"] as? String, agentStore?.task(id) != nil else { throw PetError("保留的工作树任务不存在") }
        guard let tasks = agentStore, !tasks.worktreeRetention.policy.enabled else { throw PetError("页面验收需要关闭独立资料的自动回收") }
        tasks.worktreeRetention.start(store: tasks)
        control.showAgentTask(id); control.show(tab: "chat"); control.showAgentGit()
    }
    func runWorktreeWorkspaceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        defer { agentRuntime?.stopAll() }
        do {
            let binary = Bundle.main.executableURL!; report["appPID"] = getpid(); report["binaryHash"] = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("工作树页面验收禁止模型请求") }
            let fixture = try await prepareWorktreeWorkspaceUI(output), host = control.taskWorkspace
            func actualIndex(_ root: URL) async throws -> Data {
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: output.appendingPathComponent("tmp"), network: false, timeout: 10, gitDirectory: AgentGit.metadata(workspace: root.path), protectedData: store.directory, readRoots: [root], arguments: ["-C", root.path, "rev-parse", "--absolute-git-dir"])
                guard !result.failed, let path = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { throw PetError(result.text) }
                return try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("index"))
            }
            guard let gitPage = host.currentController as? AgentGitWindow else { throw PetError("Git 未进入工作区") }
            await gitPage.checkWorkspace(message: "保留原任务的 Git 提交说明")
            func inspectLayout(_ name: String) async {
                for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    control.window?.appearance = NSAppearance(named: theme)
                    for (kind, size) in [("split", NSSize(width: 1320, height: 800)), ("narrow", NSSize(width: 780, height: 540))] {
                        control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                        let page = (host.currentController as? AgentWorktreeCreationWindow)?.workspaceReadback() ?? (host.currentController as? AgentWorktreeWindow)?.workspaceReadback() ?? [:]
                        for (key, pass) in page["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + appearance + "-" + kind + "-" + key] = pass }
                        if host.currentController is AgentWorktreeCreationWindow {
                            let inputs = page["inputFrames"] as? [[CGFloat]] ?? [], actions = page["actionFrames"] as? [[CGFloat]] ?? []
                            checks[name + "-" + appearance + "-" + kind + "-sharedControlProportions"] = inputs.count == 2 && inputs[0].count == 4 && inputs[0][3] == 28 && inputs[1].count == 4 && inputs[1][3] == 32 && actions.count == 2 && actions.allSatisfy { $0.count == 4 && $0[3] == 28 }
                        } else {
                            let controls = page["controls"] as? [[String: Any]] ?? []
                            checks[name + "-" + appearance + "-" + kind + "-sharedControlProportions"] = controls.count >= 4 && controls.allSatisfy { let frame = $0["frame"] as? [CGFloat] ?? []; return frame.count == 4 && frame[3] == 28 } && page["rowHeight"] as? CGFloat == 56
                        }
                        let state = await control.taskWorkspaceReadback(); report[name + "-" + appearance + "-" + kind] = state
                        checks[name + "-" + appearance + "-" + kind + "-taskAndInputPreserved"] = state["selectedTask"] as? String == fixture.taskID && state["draft"] as? String == "保留工作树任务输入。" && state["conversationVisible"] as? Bool == (kind == "split" && !host.expanded)
                    }
                }
                control.window?.setContentSize(NSSize(width: 1200, height: 774)); control.window?.contentView?.layoutSubtreeIfNeeded()
            }
            control.createTaskWorktree()
            guard let creation = host.currentController as? AgentWorktreeCreationWindow else { throw PetError("输入区工作树入口未进入页内") }
            await creation.checkWorkspace(startPoint: "refs/heads/release", includeChanges: true)
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
            guard let content = creation.pageContentView, let branchField = views(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "新分支" }), let previewButton = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "预览" }), control.window?.makeFirstResponder(branchField) == true, let editor = branchField.currentEditor() as? NSTextView else { throw PetError("新分支实际输入编辑器不可用") }
            let longBranch = "acceptance/" + String(repeating: "worktree-", count: 30)
            editor.string = longBranch
            guard let layout = editor.layoutManager, let container = editor.textContainer else { throw PetError("新分支文字布局不可用") }
            layout.ensureLayout(for: container); var editingLines = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in editingLines += 1 }
            checks["longWorktreeBranchUsesOneVisibleEditingLine"] = editingLines == 1 && editor.string == longBranch
            editor.string = "acceptance/page-carry"; previewButton.performClick(nil); await creation.checkWorkspace()
            checks["previewReadsActualBranchFieldEditor"] = creation.workspaceReadback()["branch"] as? String == "acceptance/page-carry" && creation.workspaceReadback()["createEnabled"] as? Bool == true
            await inspectLayout("creation")
            checks["previewUsesActualWorkingBytes"] = (creation.workspaceReadback()["patch"] as? String)?.contains("working-public") == true && creation.workspaceReadback()["createEnabled"] as? Bool == true
            do { try control.requireTaskDeletionAllowed([fixture.taskID]); checks["creationDraftBlocksTaskDeletion"] = false } catch { checks["creationDraftBlocksTaskDeletion"] = true }
            control.showAgentTask(fixture.secondID); control.showAgentGit()
            guard let second = host.currentController as? AgentGitWindow else { throw PetError("另一任务工作区未载入") }; await second.checkWorkspace(message: "另一任务的提交说明")
            control.showAgentTask(fixture.taskID)
            checks["taskSwitchRetainsOriginalFormAndPreview"] = host.currentController === creation && creation.workspaceReadback()["branch"] as? String == "acceptance/page-carry" && creation.workspaceReadback()["includeChanges"] as? Bool == true
            let beforeStaleTaskIDs = Set(tasks.tasks.map(\.id))
            try Data("changed after preview\n".utf8).write(to: fixture.workspace.appendingPathComponent("notes.txt")); await creation.checkWorkspace(action: "create")
            checks["stalePreviewKeepsFormAndRequiresNewPreview"] = host.currentController === creation && creation.workspaceReadback()["createEnabled"] as? Bool == false && !(creation.workspaceReadback()["state"] as? String ?? "").isEmpty && Set(tasks.tasks.map(\.id)) == beforeStaleTaskIDs
            try Data("public note\n".utf8).write(to: fixture.workspace.appendingPathComponent("notes.txt")); await creation.checkWorkspace(action: "preview"); await creation.checkWorkspace(action: "create")
            guard let createdID = tasks.tasks.first(where: { $0.id != fixture.childID && $0.parentID == fixture.taskID && $0.worktreeOrigin != nil })?.id, let created = tasks.task(createdID), let createdPath = created.workspace else { throw PetError("页内创建未产生真实工作树任务") }
            let target = URL(fileURLWithPath: createdPath)
            report["creationImmediate"] = ["selected": control.agentTaskID ?? "", "createdID": created.id, "pendingConfiguration": creation.hasPendingChanges, "stillHosted": creation.settingsHostWindow != nil]
            checks["createdTaskSelectedAfterCreation"] = control.agentTaskID == created.id
            checks["createdTaskDraftCopiedExactly"] = created.draft == "保留工作树任务输入。"
            checks["completedCreationPageClosesWithoutPendingConfiguration"] = !creation.hasPendingChanges && creation.settingsHostWindow == nil
            checks["creationUsesSelectedBaseAndActualCarry"] = try String(contentsOf: target.appendingPathComponent("release-only.txt"), encoding: .utf8) == "release-marker\n" && String(contentsOf: target.appendingPathComponent("public.txt"), encoding: .utf8) == "working-public\n" && !FileManager.default.fileExists(atPath: target.appendingPathComponent("local-only.txt").path)
            control.showAgentTask(fixture.taskID)
            checks["creationReturnsToOriginalGitAndCommitDraft"] = host.currentController === gitPage && gitPage.workspaceReadback()["draft"] as? String == "保留原任务的 Git 提交说明"
            await gitPage.checkWorkspace(action: "worktrees")
            guard let manager = host.currentController as? AgentWorktreeWindow else { throw PetError("工作树管理未进入页内") }
            await manager.checkWorkspace(path: fixture.child.path)
            checks["managerFirstAttachmentAlreadyUsesActualWidth"] = (manager.workspaceReadback()["checks"] as? [String: Bool])?["managerLayoutMatchesAvailableWidth"] == true
            await inspectLayout("manager")
            host.checkExpand(); await inspectLayout("manager-expanded"); host.checkExpand()
            await manager.checkWorkspace(path: fixture.foreign.path)
            checks["unmanagedCheckoutRemainsVisibleForManualRecycle"] = manager.workspaceReadback()["selectedPath"] as? String == fixture.foreign.path && manager.workspaceReadback()["recycleEnabled"] as? Bool == true
            await manager.checkWorkspace(path: fixture.child.path, action: "open"); let openedTask = control.agentTaskID; control.showAgentTask(fixture.taskID)
            checks["openAssociatedTaskAndReturnKeepsManagerSelection"] = openedTask == fixture.childID && host.currentController === manager && manager.workspaceReadback()["selectedPath"] as? String == fixture.child.path
            let tree = try AgentWorktreeSnapshot.read(fixture.child), index = try await actualIndex(fixture.child)
            report["childIndexBeforeSHA256"] = AgentFiles.hash(index)
            await manager.checkWorkspace(action: "prepare-recycle"); await inspectLayout("recycle-review")
            checks["recycleReviewNamesActualTargetAndLocksSelection"] = !(manager.workspaceReadback()["recycleReviewHash"] as? String ?? "").isEmpty && manager.workspaceReadback()["selectionEnabled"] as? Bool == false && (manager.workspaceReadback()["detail"] as? String)?.contains(fixture.child.path) == true
            await manager.checkWorkspace(action: "cancel")
            checks["cancelRecycleReviewKeepsCheckoutAndTask"] = FileManager.default.fileExists(atPath: fixture.child.path) && tasks.task(fixture.childID)?.archived == false && manager.workspaceReadback()["selectionEnabled"] as? Bool == true
            await manager.checkWorkspace(action: "recycle")
            checks["managerRecyclesActualCheckoutAndArchivesOnlyItsTask"] = !FileManager.default.fileExists(atPath: fixture.child.path) && tasks.task(fixture.childID)?.archived == true && tasks.task(fixture.taskID)?.archived == false && FileManager.default.fileExists(atPath: fixture.foreign.path)
            await manager.checkWorkspace(scope: 1)
            guard let backupID = manager.workspaceReadback()["selectedBackupID"] as? String, !backupID.isEmpty else { throw PetError("真实回收记录不可见") }
            checks["actualBackupCanBeRestoredFromSamePage"] = manager.workspaceReadback()["restoreEnabled"] as? Bool == true
            await inspectLayout("backups"); await manager.checkWorkspace(action: "prepare-restore"); await inspectLayout("restore-review")
            checks["restoreReviewUsesSelectedActualBackup"] = manager.workspaceReadback()["restoreReviewID"] as? String == backupID && manager.workspaceReadback()["selectionEnabled"] as? Bool == false
            await manager.checkWorkspace(action: "restore"); await manager.checkWorkspace(scope: 0)
            let restoredIndex = try await actualIndex(fixture.child)
            checks["managerRestoresExactFilesIndexAndTask"] = try FileManager.default.fileExists(atPath: fixture.child.path) && AgentWorktreeSnapshot.read(fixture.child).hash == tree.hash && restoredIndex == index && tasks.task(fixture.childID)?.archived == false
            await manager.checkWorkspace(action: "refresh")
            checks["refreshRetainsRestoredCheckoutSelection"] = manager.workspaceReadback()["selectedPath"] as? String == fixture.child.path
            let external = try await checkExternalWorktree(fixture, manager: manager, tasks: tasks, index: actualIndex)
            checks.merge(external.0) { _, next in next }; report["externalWorktree"] = external.1
            host.checkBack(); checks["managerBackReturnsToOriginalGitDraft"] = host.currentController === gitPage && gitPage.workspaceReadback()["draft"] as? String == "保留原任务的 Git 提交说明"
            control.showAgentTask(fixture.standaloneID); control.createTaskWorktree()
            checks["noWorkspaceDoesNotOpenInvalidCreationPage"] = !(host.currentController is AgentWorktreeCreationWindow)
            checks["sourceIndexAndUserWorkingBytesRemainExact"] = try AgentFiles.hash(Data(contentsOf: fixture.workspace.appendingPathComponent(".git/index"))) == fixture.indexHash && String(contentsOf: fixture.workspace.appendingPathComponent("public.txt"), encoding: .utf8) == "working-public\n"
            checks["allModelUsageRemainsEmpty"] = requests == 0 && tasks.tasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["workspace"] = fixture.workspace.path; report["createdWorkspace"] = createdPath; report["createdTaskID"] = created.id; report["backupID"] = backupID
            await gitPage.checkWorkspace(message: ""); await second.checkWorkspace(message: ""); host.finish()
            let global = try await checkGlobalWorktreeSettings(fixture)
            checks.merge(global.0) { _, next in next }; report.merge(global.1) { _, next in next }
            checks["allModelUsageRemainsEmpty"] = requests == 0 && tasks.tasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("worktree-workspace-report.json"))
    }

    private func checkExternalWorktree(_ fixture: WorktreeWorkspaceFixture, manager: AgentWorktreeWindow, tasks: AgentStore,
                                       index: (URL) async throws -> Data) async throws -> ([String: Bool], [String: Any]) {
        let fm = FileManager.default, path = fixture.eligibleExternal, parent = path.deletingLastPathComponent()
        let repo = try AgentGit.metadata(workspace: fixture.workspace.path)
        let ordinary = try AgentGit(store: tasks, taskID: fixture.taskID, directory: repo)
        var checks: [String: Bool] = [:]
        var report: [String: Any] = [:]
        let beforeIndex = try await index(path), original = try AgentWorktreeSnapshot.read(path)
        let branch = "refs/heads/acceptance/manual-external"
        let initialHead = try await ordinary.output(["rev-parse", branch])
        let restoreHelper = try AgentGit(store: tasks, taskID: fixture.taskID, directory: repo, allowsExternalWorktrees: true)
        let helperOnExternal = try AgentGit(store: tasks, taskID: fixture.externalTaskID, directory: repo, allowsExternalWorktrees: true)
        checks["externalManagerProtectsPrimaryAndCurrentFromLinkedCheckout"] = try await helperOnExternal.worktrees().filter { $0.path == fixture.workspace.path || $0.path == path.path }.compactMap(\.unavailable).sorted() == ["主工作树", "当前工作树"].sorted()
        checks["modelAndRetentionHelpersStillSeeExternalAsReadOnly"] = try await ordinary.worktrees().contains { $0.path == path.path && !$0.owned && $0.unavailable == "外部工作树" }
        tasks.update(fixture.externalTaskID) { $0.status = .running }
        await manager.checkWorkspace(path: path.path, action: "refresh")
        checks["runningExternalWorktreeTaskPreventsManualRecycle"] = manager.workspaceReadback()["recycleEnabled"] as? Bool == false
        tasks.update(fixture.externalTaskID) { $0.status = .ready }
        let locked = try await restoreHelper.run(["worktree", "lock", "--reason", "public fixture", path.path], write: true, externalWorktree: path)
        guard !locked.failed else { throw PetError(locked.text) }
        await manager.checkWorkspace(path: path.path, action: "refresh")
        checks["lockedExternalWorktreeDisablesManualRecycle"] = manager.workspaceReadback()["recycleEnabled"] as? Bool == false
        let unlocked = try await restoreHelper.run(["worktree", "unlock", path.path], write: true, externalWorktree: path)
        guard !unlocked.failed else { throw PetError(unlocked.text) }
        await manager.checkWorkspace(path: path.path, action: "refresh")
        await manager.checkWorkspace(action: "prepare-recycle")
        let reviewed = manager.workspaceReadback()
        guard let reviewHash = reviewed["recycleReviewHash"] as? String, !reviewHash.isEmpty else { throw PetError("外部工作树未进入审阅：" + (reviewed["state"] as? String ?? "")) }
        let review = try restoreHelper.storedWorktreeReview(hash: reviewHash)
        checks["externalReviewNamesActualTargetAndBackupSize"] = review.external != nil && review.path == path.path && review.branch == branch && review.files == original.count && review.bytes == original.bytes && (reviewed["detail"] as? String)?.contains("回收外部工作树") == true
        do { _ = try ordinary.storedWorktreeReview(hash: reviewHash); checks["ordinaryHelperCannotUseManualReview"] = false }
        catch { checks["ordinaryHelperCannotUseManualReview"] = true }
        await manager.checkWorkspace(action: "cancel")
        let afterCancelIndex = try await index(path)
        checks["cancelKeepsExternalTreeAndOriginalIndex"] = try AgentWorktreeSnapshot.read(path).hash == original.hash && afterCancelIndex == beforeIndex
        await manager.checkWorkspace(action: "prepare-recycle")
        let workingFile = path.appendingPathComponent("public.txt")
        try Data("edited after review\n".utf8).write(to: workingFile)
        await manager.checkWorkspace(action: "recycle")
        checks["externalReviewRejectsEditsMadeAfterReview"] = try Data(contentsOf: workingFile) == Data("edited after review\n".utf8) && manager.workspaceReadback()["stateIsError"] as? Bool == true
        try Data("external-working\n".utf8).write(to: workingFile)
        await manager.checkWorkspace(path: path.path, action: "recycle")
        await manager.checkWorkspace(scope: 1)
        guard let backupID = manager.workspaceReadback()["selectedBackupID"] as? String, !backupID.isEmpty else { throw PetError("外部工作树回收记录不可用") }
        let backup = try restoreHelper.worktreeBackup(backupID)
        report["backupID"] = backupID; report["path"] = path.path
        checks["externalRecycleKeepsBranchAndArchivesOnlyItsTask"] = try await ordinary.output(["rev-parse", branch]) == initialHead && !fm.fileExists(atPath: path.path) && backup.state == "recycled" && backup.external == review.external && tasks.task(fixture.externalTaskID)?.archived == true && tasks.task(fixture.taskID)?.archived == false
        checks["externalBackupUnavailableToModelTools"] = try ordinary.worktreeBackups().allSatisfy { $0.id != backupID }
        do { _ = try await ordinary.restoreWorktree(backupID: backupID); checks["ordinaryHelperCannotRestoreExternalPath"] = false }
        catch { checks["ordinaryHelperCannotRestoreExternalPath"] = !fm.fileExists(atPath: path.path) }
        // An occupied path and a replacement parent must both leave the backup available.
        try fm.createDirectory(at: path, withIntermediateDirectories: false)
        let occupied = path.appendingPathComponent("keep.txt")
        try Data("occupied public path\n".utf8).write(to: occupied)
        do { _ = try await restoreHelper.restoreWorktree(backupID: backupID); checks["occupiedExternalPathIsNeverOverwritten"] = false }
        catch { checks["occupiedExternalPathIsNeverOverwritten"] = try Data(contentsOf: occupied) == Data("occupied public path\n".utf8) }
        try fm.moveItem(at: path, to: parent.appendingPathComponent("occupied-fixture-saved"))
        let relocated = parent.deletingLastPathComponent().appendingPathComponent(parent.lastPathComponent + "-moved", isDirectory: true)
        try fm.moveItem(at: parent, to: relocated); try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        do { _ = try await restoreHelper.restoreWorktree(backupID: backupID); checks["replacementExternalParentRequiresOriginalDirectory"] = false }
        catch { checks["replacementExternalParentRequiresOriginalDirectory"] = try !fm.fileExists(atPath: path.path) && restoreHelper.worktreeBackup(backupID).state == "recycled" }
        try fm.moveItem(at: parent, to: parent.deletingLastPathComponent().appendingPathComponent(parent.lastPathComponent + "-replacement"))
        try fm.moveItem(at: relocated, to: parent)
        await manager.checkWorkspace(action: "prepare-restore"); await manager.checkWorkspace(action: "cancel")
        checks["cancellingExternalRestorePreservesArchivedTask"] = !fm.fileExists(atPath: path.path) && tasks.task(fixture.externalTaskID)?.archived == true
        await manager.checkWorkspace(action: "restore"); await manager.checkWorkspace(scope: 0)
        let afterIndex = try await index(path)
        checks["externalRestoreKeepsExactFilesIndexAndTaskDraft"] = try AgentWorktreeSnapshot.read(path).hash == original.hash && afterIndex == beforeIndex && tasks.task(fixture.externalTaskID)?.archived == false && tasks.task(fixture.externalTaskID)?.draft == "外部工作树原输入。"
        let ref = try await restoreHelper.run(["-C", path.path, "symbolic-ref", "HEAD"], externalWorktree: path)
        checks["externalRestoreKeepsOriginalCheckoutAndReturnSelection"] = try !ref.failed && ref.stdout?.trimmingCharacters(in: .newlines) == branch && restoreHelper.worktreeBackup(backupID).state == "restored" && manager.workspaceReadback()["selectedPath"] as? String == path.path
        checks["externalLifecyclePreservesSiblingFilesAndProtectedCheckout"] = try Data(contentsOf: parent.appendingPathComponent("keep.txt")) == Data("independent public file\n".utf8) && fm.fileExists(atPath: fixture.foreign.path)
        report["treeSHA256"] = original.hash; report["indexSHA256"] = AgentFiles.hash(afterIndex)
        return (checks, report)
    }

    private func checkGlobalWorktreeSettings(_ fixture: WorktreeWorkspaceFixture) async throws -> ([String: Bool], [String: Any]) {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        guard let tasks = agentStore, let window = control.window else { throw PetError("设置验收缺少任务窗口") }
        control.showAgentTask(fixture.standaloneID)
        guard let settings = control.checkWorktreeSettingsPage() as? AgentWorktreeSettingsWindow else { throw PetError("工作树设置未进入右侧页面") }
        let policy = settings.policy, original = tasks.worktreeRetention.policy
        checks["globalSettingsWorkWithoutSelectedWorkspace"] = tasks.task(fixture.standaloneID)?.workspace == nil && policy.workspaceReadback()["manageEnabled"] as? Bool == true
        policy.checkWorkspace(project: fixture.workspace.path, idleSeconds: 7 * 86400)
        checks["globalPolicyDraftDoesNotChangeSavedPolicy"] = policy.hasPendingChanges && tasks.worktreeRetention.policy == original
        policy.checkWorkspace(action: "manage")
        guard let manager = control.checkWorktreeSettingsPage(open: false) as? AgentWorktreeWindow else { throw PetError("全局管理未进入同一设置页") }
        await manager.checkWorkspace(path: fixture.child.path)
        func inspect(_ label: String) async {
            for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: theme)
                for (kind, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                    window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                    let state = await control.taskWorkspaceReadback(); report[label + "-" + appearance + "-" + kind] = state
                    let page = state[label == "global-manager" ? "settingsWorktreeManager" : "settingsWorktrees"] as? [String: Any] ?? [:]
                    for (key, value) in page["checks"] as? [String: Bool] ?? [:] { checks[label + "-" + appearance + "-" + kind + "-" + key] = value }
                    checks[label + "-" + appearance + "-" + kind + "-sameSettingsWindow"] = state["mainPage"] as? String == "settings" && settings.presentingWindow === window && settings.window?.isVisible == false
                }
            }
        }
        await inspect("global-manager")
        // Closing a hosted child uses the same callback as the Settings back button.
        manager.close()
        checks["globalManagerBackRetainsExactPolicyDraftAndProject"] = control.checkWorktreeSettingsPage(open: false) === settings && policy.hasPendingChanges && policy.workspaceReadback()["idleSeconds"] as? Double == 7 * 86400 && policy.workspaceReadback()["selectedProject"] as? String == fixture.workspace.path && tasks.worktreeRetention.policy == original
        await inspect("global-policy")
        policy.checkWorkspace(action: "save")
        let savedFile = tasks.worktreeRetention.directory.appendingPathComponent("policy.json"), saved = try JSONDecoder().decode(AgentWorktreeRetentionPolicy.self, from: Data(contentsOf: savedFile))
        checks["globalPolicySavesActualDisabledSevenDayPolicy"] = !saved.enabled && saved.archivedOnly && saved.idleSeconds == 7 * 86400 && !policy.hasPendingChanges
        policy.refreshState()
        checks["globalPolicySaveFeedbackSurvivesServiceRefresh"] = (policy.workspaceReadback()["state"] as? String)?.hasPrefix("已保存 · ") == true
        control.show(tab: "chat")
        guard let reopened = control.checkWorktreeSettingsPage() as? AgentWorktreeSettingsWindow else { throw PetError("工作树设置无法重新进入") }
        checks["globalPolicyReentryReadsSavedPolicy"] = reopened !== settings && reopened.policy.workspaceReadback()["idleSeconds"] as? Double == 7 * 86400 && !reopened.policy.hasPendingChanges
        reopened.policy.checkWorkspace(project: fixture.workspace.path, action: "manage")
        guard let nextManager = control.checkWorktreeSettingsPage(open: false) as? AgentWorktreeWindow else { throw PetError("再次打开全局管理失败") }
        await nextManager.checkWorkspace(path: fixture.child.path, action: "open")
        let selected = await control.taskWorkspaceReadback()
        checks["globalManagerOpensAssociatedTaskAndLeavesSettings"] = control.agentTaskID == fixture.childID && selected["mainPage"] as? String == "chat" && reopened.settingsHostWindow == nil && nextManager.settingsHostWindow == nil
        checks["globalSettingsPreserveOriginalTaskInput"] = tasks.task(fixture.taskID)?.draft == "保留工作树任务输入。" && tasks.task(fixture.secondID)?.draft == "保留另一任务输入。"
        checks["globalSettingsKeepAutomaticRecycleDisabled"] = !tasks.worktreeRetention.policy.enabled
        let service = tasks.worktreeRetention, beforeHistoryPolicy = service.policy
        defer { if service.policy != beforeHistoryPolicy { try? service.save(beforeHistoryPolicy, expectedRevision: service.revision) } }
        let helper = try AgentGit(store: tasks, taskID: fixture.taskID, directory: AgentGit.metadata(workspace: fixture.workspace.path))
        let historyChild = try await helper.createWorktree(branch: "acceptance/history-record"), historyPath = URL(fileURLWithPath: historyChild.workspace)
        let historyTree = try AgentWorktreeSnapshot.read(historyPath)
        func historyIndex() async throws -> Data {
            let output = fixture.workspace.deletingLastPathComponent()
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: output.appendingPathComponent("tmp"), network: false, timeout: 10, gitDirectory: AgentGit.metadata(workspace: historyChild.workspace), protectedData: store.directory, arguments: ["-C", historyChild.workspace, "rev-parse", "--absolute-git-dir"])
            guard !result.failed, let path = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { throw PetError(result.text) }
            return try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("index"))
        }
        let historyOriginalIndex = try await historyIndex()
        tasks.update(historyChild.taskID) { $0.archived = true }; tasks.selectedID = fixture.childID
        var historyPolicy = beforeHistoryPolicy; historyPolicy.enabled = true; historyPolicy.idleSeconds = 1; historyPolicy.archivedOnly = true
        try service.save(historyPolicy, expectedRevision: service.revision, consent: true)
        let historyDeadline = Date().addingTimeInterval(15)
        while Date() < historyDeadline {
            if try service.receipts().contains(where: { $0.path == historyChild.workspace && $0.backupID != nil }), !FileManager.default.fileExists(atPath: historyChild.workspace) { break }
            await wait(0.05)
        }
        try service.save(beforeHistoryPolicy, expectedRevision: service.revision)
        guard let receipt = try service.receipts().first(where: { $0.path == historyChild.workspace && $0.backupID != nil }), let backupID = receipt.backupID else { throw PetError("历史布局验收未产生真实回收记录：" + service.status) }
        checks["historyUsesActualAutomaticRecycleReceipt"] = !FileManager.default.fileExists(atPath: historyChild.workspace) && tasks.task(historyChild.taskID)?.archived == true
        _ = try await helper.restoreWorktree(backupID: backupID)
        let historyRestoredIndex = try await historyIndex()
        checks["historyReceiptBackupRestoresActualFilesAndIndex"] = try AgentWorktreeSnapshot.read(historyPath).hash == historyTree.hash && historyRestoredIndex == historyOriginalIndex
        guard let recordsSettings = control.checkWorktreeSettingsPage() as? AgentWorktreeSettingsWindow else { throw PetError("回收记录设置页未显示") }
        recordsSettings.policy.refreshState()
        for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: theme)
            for (kind, size) in [("normal", NSSize(width: 1320, height: 800)), ("narrow", NSSize(width: 780, height: 540))] {
                window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                let value = recordsSettings.policy.workspaceReadback(), historySize = value["historySize"] as? [CGFloat] ?? []
                checks["actualHistory-" + appearance + "-" + kind] = (value["historyCount"] as? Int ?? 0) > 0 && historySize.count == 2 && historySize[1] >= 150 && (value["history"] as? String)?.contains("已备份并回收") == true && (value["checks"] as? [String: Bool])?.values.allSatisfy({ $0 }) == true
                report["actualHistory-" + appearance + "-" + kind] = value
            }
        }
        checks["historyCheckRestoresDisabledPolicyAndOriginalTaskInput"] = service.policy == beforeHistoryPolicy && !service.policy.enabled && tasks.task(fixture.taskID)?.draft == "保留工作树任务输入。"
        report["actualHistoryReceipt"] = ["id": receipt.id, "workspace": historyChild.workspace, "backupID": backupID, "restoredExactIndexSHA256": AgentFiles.hash(historyRestoredIndex), "automaticPolicyFinallyDisabled": !service.policy.enabled]
        window.appearance = nil; window.setContentSize(NSSize(width: 1200, height: 774))
        return (checks, report)
    }
}
