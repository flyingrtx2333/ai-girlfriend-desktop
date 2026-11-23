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
                            let minControls = page["reviewing"] as? Bool == true ? 3 : 4
                            checks[name + "-" + appearance + "-" + kind + "-sharedControlProportions"] = controls.count >= minControls && controls.allSatisfy { let frame = $0["frame"] as? [CGFloat] ?? []; return frame.count == 4 && frame[3] == 28 } && page["rowHeight"] as? CGFloat == 56
                        }
                        let state = await control.taskWorkspaceReadback(); report[name + "-" + appearance + "-" + kind] = state
                        checks[name + "-" + appearance + "-" + kind + "-taskAndInputPreserved"] = state["selectedTask"] as? String == fixture.taskID && state["draft"] as? String == "保留工作树任务输入。" && state["conversationVisible"] as? Bool == (kind == "split" && !host.expanded)
                        if appearance == "dark", kind == "narrow", name == "recycle-review" || name == "restore-review" {
                            checks[name + "-nativeRender"] = renderWorktreeReview(output.appendingPathComponent(name + "-task-dark-narrow.png"))
                        }
                    }
                }
                control.window?.setContentSize(NSSize(width: 1200, height: 774)); control.window?.contentView?.layoutSubtreeIfNeeded()
            }
            control.createTaskWorktree()
            guard let creation = host.currentController as? AgentWorktreeCreationWindow else { throw PetError("输入区工作树入口未进入页内") }
            await creation.checkWorkspace(startPoint: "refs/heads/release", includeChanges: true)
            await wait(0.1)
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
            guard let content = creation.pageContentView, let branchField = views(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "新分支" }), let previewButton = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "预览" }), control.window?.makeFirstResponder(branchField) == true, let editor = branchField.currentEditor() as? NSTextView else { throw PetError("新分支实际输入编辑器不可用") }
            let longBranch = "acceptance/" + String(repeating: "worktree-", count: 30)
            editor.string = longBranch
            guard let layout = editor.layoutManager, let container = editor.textContainer else { throw PetError("新分支文字布局不可用") }
            layout.ensureLayout(for: container); var editingLines = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in editingLines += 1 }
            checks["longWorktreeBranchUsesOneVisibleEditingLine"] = editingLines == 1 && editor.string == longBranch
            let unfinished = " draft/蓝🐋 ", selection = NSRange(location: 8, length: 2)
            editor.string = unfinished; editor.setSelectedRange(selection)
            guard let checkpoint = try gitPage.captureWorkspaceRecovery(persistClean: false),
                  let form = try AgentGitDraftRecovery.decode(checkpoint).worktreeForm else { throw PetError("新建工作树草稿未写入 Git 会话") }
            checks["worktreeCheckpointKeepsUnfinishedTextAndSelection"] = form.branch == unfinished && form.branchSelection?.range == selection && form.focus == "branch"
            checks["worktreeCheckpointKeepsExactStartingRefAndCarry"] = checkpoint.dirty && form.sourceTaskID == fixture.taskID &&
                form.startPoints == [fixture.workspace.path: "refs/heads/release"] && form.includeChanges
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
            control.window?.setContentSize(NSSize(width: 780, height: 540)); control.window?.contentView?.layoutSubtreeIfNeeded()
            guard let managerView = manager.pageContentView,
                  let reader = views(managerView).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "工作树详情" }) else {
                throw PetError("工作树详情阅读区不可用")
            }
            let range = (reader.string as NSString).range(of: "关联任务")
            guard range.location != NSNotFound else { throw PetError("工作树详情缺少关联任务") }
            control.window?.makeFirstResponder(reader)
            reader.setSelectedRange(range); reader.scrollRangeToVisible(range)
            let browsing = try AgentTextViewport(reader)
            await manager.checkWorkspace(action: "prepare-recycle"); await inspectLayout("recycle-review")
            let recycle = manager.workspaceReadback(), reviewedText = recycle["detail"] as? String ?? ""
            checks["recycleReviewNamesActualTargetAndLocksSelection"] = !(recycle["recycleReviewHash"] as? String ?? "").isEmpty && recycle["selectionEnabled"] as? Bool == false && reviewedText.contains(fixture.child.path)
            checks["recycleReviewNamesAffectedTask"] = tasks.task(fixture.childID).map { reviewedText.contains($0.title) } == true && reviewedText.hasPrefix("备份包括忽略文件和暂存状态")
            control.window?.setContentSize(NSSize(width: 780, height: 540)); control.window?.contentView?.layoutSubtreeIfNeeded()
            await manager.checkWorkspace(action: "cancel")
            checks["cancelRecycleReviewKeepsCheckoutAndTask"] = FileManager.default.fileExists(atPath: fixture.child.path) && tasks.task(fixture.childID)?.archived == false && manager.workspaceReadback()["selectionEnabled"] as? Bool == true
            let returned = try AgentTextViewport(reader)
            report["readingRestored"] = ["beforeY": browsing.y, "afterY": returned.y, "beforeFocused": browsing.focused,
                "afterFocused": returned.focused, "sameContent": returned.hash == browsing.hash, "sameSelection": returned.selections == browsing.selections]
            checks["cancelReviewRestoresSelectedTextScrollAndFocus"] = browsing.focused && browsing.y > 0 && returned.focused &&
                returned.hash == browsing.hash && returned.selections == browsing.selections && abs(returned.y - browsing.y) < 2 &&
                manager.workspaceReadback()["selectedPath"] as? String == fixture.child.path
            await manager.checkWorkspace(action: "recycle")
            checks["managerRecyclesActualCheckoutAndArchivesOnlyItsTask"] = !FileManager.default.fileExists(atPath: fixture.child.path) && tasks.task(fixture.childID)?.archived == true && tasks.task(fixture.taskID)?.archived == false && FileManager.default.fileExists(atPath: fixture.foreign.path)
            await manager.checkWorkspace(scope: 1)
            guard let backupID = manager.workspaceReadback()["selectedBackupID"] as? String, !backupID.isEmpty else { throw PetError("真实回收记录不可见") }
            checks["actualBackupCanBeRestoredFromSamePage"] = manager.workspaceReadback()["restoreEnabled"] as? Bool == true
            await inspectLayout("backups"); await manager.checkWorkspace(action: "prepare-restore"); await inspectLayout("restore-review")
            checks["restoreReviewUsesSelectedActualBackup"] = manager.workspaceReadback()["restoreReviewID"] as? String == backupID && manager.workspaceReadback()["selectionEnabled"] as? Bool == false
            let restoredDetail = reader.string as NSString
            let taskName = tasks.task(fixture.childID)?.title ?? ""
            let taskNameRange = restoredDetail.range(of: taskName)
            let receiptRange = restoredDetail.range(of: "备份记录")
            checks["restoreReviewPrioritizesAffectedTaskOverReceipt"] = !taskName.isEmpty && taskNameRange.location != NSNotFound &&
                receiptRange.location != NSNotFound && taskNameRange.location < receiptRange.location
            await manager.checkWorkspace(action: "restore"); await manager.checkWorkspace(scope: 0)
            let restoredIndex = try await actualIndex(fixture.child)
            checks["managerRestoresExactFilesIndexAndTask"] = try FileManager.default.fileExists(atPath: fixture.child.path) && AgentWorktreeSnapshot.read(fixture.child).hash == tree.hash && restoredIndex == index && tasks.task(fixture.childID)?.archived == false
            await manager.checkWorkspace(action: "refresh")
            checks["refreshRetainsRestoredCheckoutSelection"] = manager.workspaceReadback()["selectedPath"] as? String == fixture.child.path
            let external = try await checkExternalWorktree(fixture, manager: manager, tasks: tasks, index: actualIndex)
            checks.merge(external.0) { _, next in next }; report["externalWorktree"] = external.1
            let missing = try await checkMissingWorktreeRegistration(fixture, manager: manager, tasks: tasks)
            checks.merge(missing.0) { _, next in next }; report["missingRegistration"] = missing.1
            let relink = try await checkMovedWorktreeRelink(fixture, manager: manager, tasks: tasks)
            checks.merge(relink.0) { _, next in next }; report["worktreeRelink"] = relink.1
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

    private func checkMovedWorktreeRelink(_ fixture: WorktreeWorkspaceFixture, manager: AgentWorktreeWindow,
                                        tasks: AgentStore) async throws -> ([String: Bool], [String: Any]) {
        var checks: [String: Bool] = [:]
        let source = fixture.eligibleExternal, base = source.deletingLastPathComponent(), fm = FileManager.default
        let newParent = base.appendingPathComponent("目标层级"), destination = newParent.appendingPathComponent("移动 工作树")
        let nested = source.appendingPathComponent("多源子目录"), untouched = base.appendingPathComponent("另一源文件夹")
        let different = base.appendingPathComponent("不同登记样例")
        for url in [newParent, nested, untouched, different] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let scoped = AgentWorkspaceScope(group: source.path, folders: [nested.path, untouched.path], primary: nested.path)
        let nestedID = tasks.create(title: "关联的多源公开任务", workspace: nested.path, workspaceScope: scoped)
        tasks.update(nestedID) { $0.draft = "保留多源任务输入。" }
        let common = try AgentGit.metadata(workspace: fixture.workspace.path)
        let manual = try AgentGit(store: tasks, taskID: fixture.taskID, directory: common, allowsExternalWorktrees: true)
        let ordinary = try AgentGit(store: tasks, taskID: fixture.taskID, directory: common)
        let gitDir = try await manual.run(["-C", source.path, "rev-parse", "--absolute-git-dir"], externalWorktree: source)
        guard !gitDir.failed, let raw = gitDir.stdout, raw.hasSuffix("\n") else { throw PetError("移动样例的 Git 登记不可用") }
        let metadata = URL(fileURLWithPath: String(raw.dropLast()), isDirectory: true)
        let index = try Data(contentsOf: metadata.appendingPathComponent("index")), before = try AgentWorktreeSnapshot.read(source)
        let backlink = metadata.appendingPathComponent("gitdir"), beforeBacklink = try Data(contentsOf: backlink)
        let peer = fixture.child.appendingPathComponent(".git"), peerBefore = try Data(contentsOf: peer)
        try peerBefore.write(to: different.appendingPathComponent(".git"))
        let lock = try await manual.run(["worktree", "lock", "--reason", "public portable checkout", source.path], write: true, externalWorktree: source)
        guard !lock.failed else { throw PetError(lock.text) }
        try fm.moveItem(at: source, to: destination)
        await manager.checkWorkspace(path: source.path, action: "refresh")
        checks["movedPortableWorktreeOffersRelinkDespitePreservedLock"] = manager.workspaceReadback()["relinkEnabled"] as? Bool == true && manager.workspaceReadback()["recycleEnabled"] as? Bool == false
        let beforeForward = try Data(contentsOf: destination.appendingPathComponent(".git"))
        do { _ = try await ordinary.prepareWorktreeRelink(from: source.path, to: destination.path); checks["relinkUnavailableToModel"] = false }
        catch { checks["relinkUnavailableToModel"] = true }
        await manager.checkWorkspace(relinkDestination: different.path)
        checks["checkoutForDifferentRegistryIsRejected"] = manager.workspaceReadback()["stateIsError"] as? Bool == true && manager.workspaceReadback()["relinkDestination"] as? String == ""
        await manager.checkWorkspace(relinkDestination: destination.path)
        let review = manager.workspaceReadback(), detail = review["detail"] as? String ?? ""
        checks["relinkReviewShowsBothPathsAndAffectedTasks"] = review["relinkDestination"] as? String == destination.path && review["selectionEnabled"] as? Bool == false && detail.contains(source.path) && detail.contains(destination.path) && detail.contains("关联的多源公开任务")
        await manager.checkWorkspace(action: "cancel")
        checks["relinkCancellationPreservesLinksAndTask"] = try Data(contentsOf: backlink) == beforeBacklink && Data(contentsOf: destination.appendingPathComponent(".git")) == beforeForward && tasks.task(nestedID)?.workspace == nested.path
        await manager.checkWorkspace(relinkDestination: destination.path)
        tasks.update(fixture.externalTaskID, persist: false) { $0.draft = "保留审阅后编辑的新输入。" }
        for task in tasks.tasks where task.id != fixture.externalTaskID { _ = tasks.task(task.id) }
        checks["draftVersionSurvivesCacheEvictionBeforeRelink"] = tasks.task(fixture.externalTaskID)?.draft == "保留审阅后编辑的新输入。"
        await manager.checkWorkspace(action: "relink")
        checks["relinkRequiresFreshTaskVersion"] = try manager.workspaceReadback()["stateIsError"] as? Bool == true && Data(contentsOf: backlink) == beforeBacklink && tasks.task(fixture.externalTaskID)?.workspace == source.path
        await manager.checkWorkspace(relinkDestination: destination.path)
        await manager.checkWorkspace(action: "relink")
        let list = try await manual.worktrees(), selected = list.first { $0.path == destination.path }
        checks["sameRegistryBranchAndLockAreLinkedToDestination"] = selected?.branch == "refs/heads/acceptance/manual-external" && selected?.locked == "public portable checkout" && !list.contains { $0.path == source.path } && manager.workspaceReadback()["selectedPath"] as? String == destination.path
        let staged = try await manual.run(["-C", destination.path, "show", ":public.txt"], externalWorktree: destination)
        checks["relinkPreservesMovedFilesIndexAndPeerPointer"] = try staged.stdout == "external-staged\n" && AgentWorktreeSnapshot.read(destination).hash == before.hash && Data(contentsOf: metadata.appendingPathComponent("index")) == index && Data(contentsOf: peer) == peerBefore
        let newNested = destination.appendingPathComponent(nested.lastPathComponent).path
        checks["relinkMigratesWorktreeTasksAndNestedRoots"] = tasks.task(fixture.externalTaskID)?.workspace == destination.path && tasks.task(fixture.externalTaskID)?.draft == "保留审阅后编辑的新输入。" && tasks.task(nestedID)?.workspacePaths == [newNested, untouched.path] && tasks.task(nestedID)?.workspace == newNested && tasks.task(nestedID)?.draft == "保留多源任务输入。" && tasks.task(fixture.taskID)?.workspace == fixture.workspace.path
        checks["relinkCommitsBothTaskRecords"] = try tasks.recordIsPersisted(nestedID) && tasks.recordIsPersisted(fixture.externalTaskID)
        return (checks, ["source": source.path, "destination": destination.path, "metadata": metadata.path, "indexSHA256": AgentFiles.hash(index), "nestedTaskID": nestedID])
    }

    private func checkMissingWorktreeRegistration(_ fixture: WorktreeWorkspaceFixture, manager: AgentWorktreeWindow,
                                                  tasks: AgentStore) async throws -> ([String: Bool], [String: Any]) {
        var checks: [String: Bool] = [:]
        let fm = FileManager.default, target = fixture.eligibleExternal, peer = fixture.foreign
        let parent = target.deletingLastPathComponent(), parked = parent.appendingPathComponent("保留工作树原文件")
        let parkedPeer = peer.deletingLastPathComponent().appendingPathComponent("保留另一工作树的文件")
        let common = try AgentGit.metadata(workspace: fixture.workspace.path)
        let manual = try AgentGit(store: tasks, taskID: fixture.taskID, directory: common, allowsExternalWorktrees: true)
        let ordinary = try AgentGit(store: tasks, taskID: fixture.taskID, directory: common)
        let gitDir = try await manual.run(["-C", target.path, "rev-parse", "--absolute-git-dir"], externalWorktree: target)
        guard !gitDir.failed, let path = gitDir.stdout?.trimmingCharacters(in: .newlines), !path.isEmpty else { throw PetError("缺失登记的验收元数据未找到") }
        let metadata = URL(fileURLWithPath: path, isDirectory: true), original = try AgentWorktreeSnapshot.read(metadata)
        let taskDraft = tasks.task(fixture.externalTaskID)?.draft
        try fm.moveItem(at: target, to: parked); try fm.moveItem(at: peer, to: parkedPeer)
        await manager.checkWorkspace(path: target.path, action: "refresh")
        checks["manualManagerOffersOneMissingRegistration"] = manager.workspaceReadback()["recycleEnabled"] as? Bool == true && (manager.workspaceReadback()["detail"] as? String)?.contains("原目录缺失") == true
        let locked = try await manual.run(["worktree", "lock", "--reason", "public missing fixture", target.path], write: true, metadataOnly: true)
        guard !locked.failed else { throw PetError(locked.text) }
        await manager.checkWorkspace(path: target.path, action: "refresh")
        checks["lockedMissingRegistrationIsProtected"] = manager.workspaceReadback()["recycleEnabled"] as? Bool == false
        let unlocked = try await manual.run(["worktree", "unlock", target.path], write: true, metadataOnly: true)
        guard !unlocked.failed else { throw PetError(unlocked.text) }
        let offline = parent.deletingLastPathComponent().appendingPathComponent(parent.lastPathComponent + "-temporarily-unavailable")
        try fm.moveItem(at: parent, to: offline)
        await manager.checkWorkspace(path: target.path, action: "refresh")
        checks["missingParentPreventsRegistrationCleanup"] = manager.workspaceReadback()["recycleEnabled"] as? Bool == false
        try fm.moveItem(at: offline, to: parent)
        await manager.checkWorkspace(path: target.path, action: "refresh")
        await manager.checkWorkspace(action: "prepare-recycle")
        let preview = manager.workspaceReadback()
        checks["missingReviewExplainsRegistrationOnly"] = (preview["detail"] as? String)?.contains("只清理这条 Git 登记") == true && preview["selectionEnabled"] as? Bool == false
        await manager.checkWorkspace(action: "cancel")
        checks["cancelPreservesGitRegistrationBytes"] = try AgentWorktreeSnapshot.read(metadata).hash == original.hash
        await manager.checkWorkspace(action: "prepare-recycle")
        try fm.moveItem(at: parked, to: target)
        await manager.checkWorkspace(action: "recycle")
        checks["returnedCheckoutBlocksConfirmedCleanup"] = try AgentWorktreeSnapshot.read(metadata).hash == original.hash && fm.fileExists(atPath: target.path) && manager.workspaceReadback()["stateIsError"] as? Bool == true
        try fm.moveItem(at: target, to: parked)
        await manager.checkWorkspace(path: target.path, action: "refresh")
        await manager.checkWorkspace(action: "recycle"); await manager.checkWorkspace(scope: 1)
        guard let id = manager.workspaceReadback()["selectedBackupID"] as? String, let record = try? manual.worktreeBackup(id), record.registration != nil else { throw PetError("缺失的工作树登记未进入回收记录") }
        let archive = manual.worktreeRegistrationBackupURL(id), remaining = try await manual.worktrees()
        checks["cleanupMovesOnlyTheSelectedGitRegistration"] = try !fm.fileExists(atPath: metadata.path) && AgentWorktreeSnapshot.read(archive).hash == original.hash && remaining.contains { $0.path == peer.path } && !remaining.contains { $0.path == target.path }
        checks["registrationBackupIsManualOnly"] = try ordinary.worktreeBackups().allSatisfy { $0.id != id }
        let displaced = parked.appendingPathComponent("public.txt")
        checks["registrationCleanupLeavesTaskAndDisplacedFiles"] = try tasks.task(fixture.externalTaskID)?.archived == false && tasks.task(fixture.externalTaskID)?.draft == taskDraft && Data(contentsOf: displaced) == Data("external-working\n".utf8)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let collision = target.appendingPathComponent("保留原件.txt")
        try Data("unrelated public file\n".utf8).write(to: collision)
        await manager.checkWorkspace(action: "restore")
        checks["differentContentsAtOriginalPathBlockRestore"] = try Data(contentsOf: collision) == Data("unrelated public file\n".utf8) && fm.fileExists(atPath: archive.path) && !fm.fileExists(atPath: metadata.path) && manager.workspaceReadback()["stateIsError"] as? Bool == true
        try fm.moveItem(at: target, to: parent.appendingPathComponent("原路径冲突样例"))
        try fm.moveItem(at: parked, to: target); try fm.moveItem(at: parkedPeer, to: peer)
        await manager.checkWorkspace(action: "prepare-restore")
        checks["missingRegistrationHasDistinctRestoreReview"] = (manager.workspaceReadback()["detail"] as? String)?.contains("恢复原 Git 登记") == true
        await manager.checkWorkspace(action: "restore"); await manager.checkWorkspace(scope: 0)
        let checkGit = try await manual.run(["-C", target.path, "show", ":public.txt"], externalWorktree: target)
        checks["restoredRegistrationReconnectsExactIndexAndTask"] = try manual.worktreeBackup(id).state == "restored" && AgentWorktreeSnapshot.read(metadata).hash == original.hash && checkGit.stdout == "external-staged\n" && tasks.task(fixture.externalTaskID)?.draft == taskDraft && manager.workspaceReadback()["selectedPath"] as? String == target.path
        // Leave a separate recoverable record for the manual window's restore flow.
        try fm.moveItem(at: peer, to: parkedPeer)
        let peerReview = try await manual.prepareMissingWorktreeRecycle(path: peer.path)
        let peerRecord = try await manual.recycleMissingWorktree(peerReview)
        try fm.moveItem(at: parkedPeer, to: peer)
        checks["manualWindowCanReattachReturnedCheckout"] = fm.fileExists(atPath: peer.path) && peerRecord.state == "recycled" && peerRecord.registration != nil
        return (checks, ["backupID": id, "checkout": target.path, "metadata": metadata.path, "metadataSHA256": original.hash, "peer": peer.path, "windowRestoreBackupID": peerRecord.id])
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
        let detail = reviewed["detail"] as? String ?? ""
        checks["externalReviewNamesActualTargetAndBackupSize"] = review.external != nil && review.path == path.path && review.branch == branch &&
            review.files == original.count && review.bytes == original.bytes && reviewed["heading"] as? String == "回收外部工作树" &&
            detail.contains(path.path) && detail.contains("备份\n\(original.count) 项")
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
            let review = label == "global-review"
            let sizes = review ? [("normal", NSSize(width: 1320, height: 800)), ("narrow", NSSize(width: 780, height: 540))] :
                [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))]
            for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: theme)
                for (kind, size) in sizes {
                    window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                    let state = await control.taskWorkspaceReadback(); report[label + "-" + appearance + "-" + kind] = state
                    let page = state[label == "global-policy" ? "settingsWorktrees" : "settingsWorktreeManager"] as? [String: Any] ?? [:]
                    for (key, value) in page["checks"] as? [String: Bool] ?? [:] { checks[label + "-" + appearance + "-" + kind + "-" + key] = value }
                    checks[label + "-" + appearance + "-" + kind + "-sameSettingsWindow"] = state["mainPage"] as? String == "settings" && settings.presentingWindow === window && settings.window?.isVisible == false
                    if review, (appearance == "dark" && kind == "narrow") || (appearance == "light" && kind == "normal") {
                        let output = fixture.workspace.deletingLastPathComponent()
                        let name = "recycle-review-settings-" + appearance + "-" + kind
                        checks[name + "-nativeRender"] = renderWorktreeReview(output.appendingPathComponent(name + ".png"))
                    }
                }
            }
        }
        await inspect("global-manager")
        await manager.checkWorkspace(action: "prepare-recycle"); await inspect("global-review")
        checks["settingsReviewKeepsPolicyDraftAndActualCheckout"] = manager.workspaceReadback()["reviewing"] as? Bool == true &&
            manager.workspaceReadback()["heading"] as? String == "回收工作树" && policy.hasPendingChanges && FileManager.default.fileExists(atPath: fixture.child.path)
        await manager.checkWorkspace(action: "cancel")
        checks["settingsCancelReturnsToSameManagerAndSelection"] = control.checkWorktreeSettingsPage(open: false) === manager &&
            manager.workspaceReadback()["reviewing"] as? Bool == false && manager.workspaceReadback()["selectedPath"] as? String == fixture.child.path
        // Closing a hosted child uses the same callback as the Settings back button.
        manager.close()
        checks["globalManagerBackRetainsExactPolicyDraftAndProject"] = control.checkWorktreeSettingsPage(open: false) === settings && policy.hasPendingChanges && policy.workspaceReadback()["idleSeconds"] as? Double == 7 * 86400 && policy.workspaceReadback()["selectedProject"] as? String == fixture.workspace.path && tasks.worktreeRetention.policy == original
        await inspect("global-policy")
        policy.checkWorkspace(action: "save")
        let savedFile = tasks.worktreeRetention.directory.appendingPathComponent("policy.json"), saved = try JSONDecoder().decode(AgentWorktreeRetentionPolicy.self, from: Data(contentsOf: savedFile))
        checks["globalPolicySavesActualDisabledSevenDayPolicy"] = !saved.enabled && saved.archivedOnly && saved.idleSeconds == 7 * 86400 && !policy.hasPendingChanges
        policy.refreshState()
        checks["globalPolicySaveFeedbackSurvivesServiceRefresh"] = (policy.workspaceReadback()["state"] as? String)?.hasPrefix("已保存 · ") == true
        checks.merge(try checkPolicyReview(settings, window: window, service: tasks.worktreeRetention)) { _, latest in latest }
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

    private func checkPolicyReview(_ settings: AgentWorktreeSettingsWindow, window: NSWindow, service: AgentWorktreeRetention) throws -> [String: Bool] {
        let policy = settings.policy, original = service.policy
        let file = service.directory.appendingPathComponent("policy.json"), before = try Data(contentsOf: file)
        let fm = FileManager.default
        var checks: [String: Bool] = [:]
        func find<T: NSView>(_ type: T.Type, in root: NSView?, matching match: (T) -> Bool) -> T? {
            guard let root, !root.isHiddenOrHasHiddenAncestor else { return nil }
            if let value = root as? T, match(value) { return value }
            for child in root.subviews {
                if let result = find(type, in: child, matching: match) { return result }
            }
            return nil
        }
        func open() throws -> (AgentSettingsReviewPage, NSButton) {
            policy.checkWorkspace(enable: true, action: "save")
            guard let review = control.checkWorktreeSettingsPage(open: false) as? AgentSettingsReviewPage,
                  let button = find(NSButton.self, in: window.contentView, matching: { $0.title == "应用" }) else {
                throw PetError("缺少回收策略的页内审阅")
            }
            return (review, button)
        }
        let (review, apply) = try open()
        let history = try control.captureSettingsRecovery()
        checks["policyReviewInSameWindowWithNoWrites"] = try review.presentingWindow === window && window.attachedSheet == nil &&
            apply.isEnabled && Data(contentsOf: file) == before && history?.pages.map(\.kind) == ["worktrees", "worktree-policy-review"]
        checks["policyReviewInitiallyFocusesCancel"] = (window.firstResponder as? NSButton)?.title == "取消"
        review.close()
        checks["policyReviewBackKeepsDraftAndReturnsFocus"] = control.checkWorktreeSettingsPage(open: false) === settings &&
            policy.hasPendingChanges && (window.firstResponder as? NSButton)?.title == "应用回收设置"

        let (stale, applyStale) = try open()
        var external = original; external.idleSeconds = 14 * 86400
        try service.save(external, expectedRevision: service.revision)
        let externalBytes = try Data(contentsOf: file)
        applyStale.performClick(nil)
        checks["policyReviewBlocksChangedRevision"] = try !applyStale.isEnabled && control.checkWorktreeSettingsPage(open: false) === stale &&
            Data(contentsOf: file) == externalBytes && service.policy == external
        stale.close()
        try service.save(original, expectedRevision: service.revision)
        policy.checkWorkspace(action: "reload")

        let (current, applyCurrent) = try open()
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        applyCurrent.performClick(nil)
        let issue = find(NSTextField.self, in: current.pageContentView, matching: { $0.accessibilityLabel() == "审阅操作错误" })
        checks["policyReviewReadOnlyRetryKeepsOriginalBytesAndMode"] = try issue?.stringValue.contains("只读") == true &&
            applyCurrent.isEnabled && Data(contentsOf: file) == before && fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o400
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        applyCurrent.performClick(nil)
        var accepted = original; accepted.enabled = true
        checks["policyReviewOnlyExplicitApplyWritesReviewedValue"] = try service.policy == accepted &&
            AgentWorktreeRetentionPolicy.read(Data(contentsOf: file)) == accepted && !policy.hasPendingChanges &&
            control.checkWorktreeSettingsPage(open: false) === settings
        try service.save(original, expectedRevision: service.revision)
        policy.checkWorkspace(action: "reload")
        return checks
    }

    private func renderWorktreeReview(_ output: URL) -> Bool {
        guard let view = control.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: output, options: .atomic); return true }
        catch { return false }
    }
}
