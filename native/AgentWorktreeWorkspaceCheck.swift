import AppKit

@MainActor extension AppDelegate {
    struct WorktreeWorkspaceFixture { let taskID: String, secondID: String, standaloneID: String, childID: String, workspace: URL, child: URL, foreign: URL, releaseHead: String, indexHash: String }
    func prepareWorktreeWorkspaceUI(_ output: URL) async throws -> WorktreeWorkspaceFixture {
        guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("工作树页面验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
        guard !tasks.worktreeRetention.policy.enabled else { throw PetError("页面验收需要关闭独立资料的自动回收") }
        tasks.worktreeRetention.start(store: tasks)
        let fm = FileManager.default, repo = output.appendingPathComponent("public-project"), tmp = output.appendingPathComponent("tmp")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        func git(_ args: [String], at root: URL? = nil) async throws -> String {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: tmp, network: false, timeout: 20, gitDirectory: repo.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", (root ?? repo).path] + args)
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
        let indexHash = AgentFiles.hash(try Data(contentsOf: repo.appendingPathComponent(".git/index")))
        let fixture = WorktreeWorkspaceFixture(taskID: first, secondID: second, standaloneID: standalone, childID: child.taskID, workspace: repo, child: childURL, foreign: foreign, releaseHead: releaseHead, indexHash: indexHash)
        try JSONSerialization.data(withJSONObject: ["taskID": first, "secondID": second, "standaloneID": standalone, "childID": child.taskID, "workspace": repo.path, "child": childURL.path, "foreign": foreign.path, "releaseHead": releaseHead, "sourceIndexSHA256": indexHash, "modelTransmissions": 0], options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("worktree-workspace-fixtures.json"))
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
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: output.appendingPathComponent("tmp"), network: false, timeout: 10, gitDirectory: AgentGit.metadata(workspace: root.path), protectedData: store.directory, arguments: ["-C", root.path, "rev-parse", "--absolute-git-dir"])
                guard !result.failed, let path = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { throw PetError(result.text) }
                return try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("index"))
            }
            guard let gitPage = host.currentController as? AgentGitWindow else { throw PetError("Git 未进入工作区") }
            await gitPage.checkWorkspace(message: "保留原任务的 Git 提交说明")
            func inspectLayout(_ name: String) async {
                for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    control.window?.appearance = NSAppearance(named: theme)
                    for (kind, size) in [("split", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                        control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                        let page = (host.currentController as? AgentWorktreeCreationWindow)?.workspaceReadback() ?? (host.currentController as? AgentWorktreeWindow)?.workspaceReadback() ?? [:]
                        for (key, pass) in page["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + appearance + "-" + kind + "-" + key] = pass }
                        let state = await control.taskWorkspaceReadback(); report[name + "-" + appearance + "-" + kind] = state
                        checks[name + "-" + appearance + "-" + kind + "-taskAndInputPreserved"] = state["selectedTask"] as? String == fixture.taskID && state["draft"] as? String == "保留工作树任务输入。" && state["conversationVisible"] as? Bool == (kind == "split" && !host.expanded)
                    }
                }
                control.window?.setContentSize(NSSize(width: 1200, height: 774)); control.window?.contentView?.layoutSubtreeIfNeeded()
            }
            control.createTaskWorktree()
            guard let creation = host.currentController as? AgentWorktreeCreationWindow else { throw PetError("输入区工作树入口未进入页内") }
            await creation.checkWorkspace(branch: "acceptance/page-carry", startPoint: "refs/heads/release", includeChanges: true, action: "preview")
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
            checks["externalCheckoutRemainsVisibleAndNotRecyclable"] = manager.workspaceReadback()["selectedPath"] as? String == fixture.foreign.path && manager.workspaceReadback()["recycleEnabled"] as? Bool == false
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
        window.appearance = nil; window.setContentSize(NSSize(width: 1200, height: 774))
        return (checks, report)
    }
}
