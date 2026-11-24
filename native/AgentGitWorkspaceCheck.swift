import AppKit

@MainActor extension AppDelegate {
    struct GitWorkspaceFixture { let taskID: String, secondID: String, standaloneID: String, workspace: URL, receiver: URL }
    func prepareGitWorkspaceUI(_ output: URL) async throws -> GitWorkspaceFixture {
        guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("Git 工作区验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
        let fm = FileManager.default, project = output.appendingPathComponent("workspace"), temporary = output.appendingPathComponent("tmp")
        let server = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("server.json"))) as? [String: Any]
        guard let endpoint = server?["url"] as? String, let path = server?["repository"] as? String else { throw PetError("缺少独立的本机 Git 服务") }
        let receiver = URL(fileURLWithPath: path)
        try fm.createDirectory(at: project, withIntermediateDirectories: true); try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws -> String {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: temporary, network: false, timeout: 20, gitDirectory: project.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", project.path] + args)
            guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
        }
        for (name, text) in [("review.txt", "original-review\n"), ("other.txt", "original-other\n"), ("stage-only.txt", "original-stage\n"), ("client.js", "const https = require('https');\nconst agent = new https.Agent({ rejectUnauthorized: true });\n")] { try Data(text.utf8).write(to: project.appendingPathComponent(name)) }
        _ = try await git(["init", "-b", "main"])
        for (key, value) in [("user.name", "Task Workspace Acceptance"), ("user.email", "workspace@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", ".git/hooks")] { _ = try await git(["config", key, value]) }
        _ = try await git(["add", "--", "."]); _ = try await git(["commit", "-m", "public workspace baseline"])
        _ = try await git(["push", "--", receiver.path, "HEAD:refs/heads/main"])
        for (name, text) in [("review.txt", "selected-staged\n"), ("other.txt", "other-staged-preserved\n")] { try Data(text.utf8).write(to: project.appendingPathComponent(name)) }
        _ = try await git(["add", "--", "review.txt", "other.txt"])
        for (name, text) in [("review.txt", "selected-working-preserved\n"), ("other.txt", "other-working-preserved\n"), ("stage-only.txt", "stage-this-file\n"), ("client.js", "const https = require('https');\nconst agent = new https.Agent({ rejectUnauthorized: false });\n")] { try Data(text.utf8).write(to: project.appendingPathComponent(name)) }
        _ = try await git(["remote", "add", "origin", endpoint])
        let first = tasks.create(title: "项目审阅与推送", workspace: project.path), second = tasks.create(title: "另一任务的 Git 审阅", workspace: project.path), standalone = tasks.create(title: "无工作区的任务", mode: .ask, workMode: .general)
        for (id, text) in [(first, "检查本次项目改动。"), (second, "另一任务的审阅。"), (standalone, "查询本机状态。" )] {
            guard runtime.submit(text, taskID: id, startImmediately: false) else { throw PetError("验收会话未保存") }
            tasks.update(id) { $0.draft = id == first ? "保留项目任务的输入草稿。" : "保留另一任务的输入草稿。" }
        }
        let fixture = GitWorkspaceFixture(taskID: first, secondID: second, standaloneID: standalone, workspace: project, receiver: receiver)
        try JSONSerialization.data(withJSONObject: ["taskID": first, "secondID": second, "standaloneID": standalone, "workspace": project.path, "receiver": receiver.path, "endpoint": endpoint, "modelTransmissions": 0], options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("git-workspace-fixtures.json"))
        control.showAgentTask(first); control.showAgentGit(); return fixture
    }
    func reopenGitWorkspaceUI(_ output: URL) throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("git-workspace-fixtures.json"))) as? [String: Any]
        guard let id = fixture?["taskID"] as? String, agentStore?.task(id) != nil else { throw PetError("未找到保留的 Git 任务") }
        control.showAgentTask(id); control.showAgentGit()
    }
    func runGitWorkspaceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("Git 工作区验收禁止模型请求") }
            let fixture = try await prepareGitWorkspaceUI(output), host = control.taskWorkspace
            guard let git = host.currentController as? AgentGitWindow else { throw PetError("Git 未进入任务工作区") }
            defer { git.discardPushDraft() }
            await git.checkWorkspace(path: "review.txt")
            checks.merge(try await checkGitReviewVisuals(git, workspace: fixture.workspace, output: output)) { _, value in value }
            func rawGit(_ args: [String]) async throws -> String {
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: output.appendingPathComponent("tmp"), network: false, timeout: 20, gitDirectory: fixture.workspace.appendingPathComponent(".git"), protectedData: store.directory, arguments: ["-C", fixture.workspace.path] + args)
                guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
            }
            func inspect(_ name: String) async {
                var frames: [String: Any] = [:]
                for (sizeName, size) in [("split", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                    control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); host.currentController?.pageDidLayout(); control.window?.contentView?.layoutSubtreeIfNeeded()
                    await wait(0.15)
                    let value = control.gitWorkspaceReadback(); frames[sizeName] = value
                    for (key, pass) in host.checkState()["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + sizeName + "-" + key] = pass }
                    for (key, pass) in (host.currentController as? AgentGitWindow)?.workspaceReadback()["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + sizeName + "-" + key] = pass }
                    checks[name + "-" + sizeName + "-conversationPreservedWithValidWidth"] = (value["conversationWidth"] as? Double ?? 0) >= 430 && (value["draft"] as? String) == "保留项目任务的输入草稿。"
                    checks[name + "-" + sizeName + "-expectedSplitOrFull"] = value["conversationVisible"] as? Bool == (sizeName == "split" && !host.expanded)
                    let actual = value["windowSize"] as? [Double] ?? []
                    checks[name + "-" + sizeName + "-actualWindowSizeRemainsStable"] = actual.count == 2 && abs(actual[0] - Double(size.width)) < 0.5 && abs(actual[1] - Double(size.height)) < 0.5
                    checks[name + "-" + sizeName + "-expandToggleMatchesAvailableSpace"] = value["expandVisible"] as? Bool == (sizeName == "split")
                }; report[name] = frames
                control.window?.setContentSize(NSSize(width: 1200, height: 774)); control.window?.contentView?.layoutSubtreeIfNeeded()
            }
            await inspect("review")
            await git.checkWorkspace(action: "files"); await inspect("file-list"); await git.checkWorkspace(action: "files")
            host.checkExpand(); await inspect("expanded"); host.checkExpand()
            await git.checkWorkspace(source: .staged, path: "review.txt", message: "保留的任务 A 提交说明")
            let before = git.workspaceReadback()
            control.showAgentTask(fixture.secondID); control.showAgentGit()
            guard let second = host.currentController as? AgentGitWindow else { throw PetError("第二任务 Git 未载入") }
            await second.checkWorkspace(message: "任务 B 的提交说明")
            control.showAgentTask(fixture.taskID)
            checks["switchingTasksRetainsIndependentControllerAndReview"] = host.currentController === git && git.workspaceReadback()["source"] as? String == before["source"] as? String && git.workspaceReadback()["draft"] as? String == "保留的任务 A 提交说明"
            host.checkHide(); checks["hidingReturnsToSameTaskConversation"] = control.gitWorkspaceReadback()["conversationVisible"] as? Bool == true && control.agentTaskID == fixture.taskID
            control.showAgentGit(); checks["reopeningKeepsSelectionAndCommitDraft"] = host.currentController === git && git.workspaceReadback()["paths"] as? [String] == ["review.txt"] && git.workspaceReadback()["draft"] as? String == "保留的任务 A 提交说明"
            do { try control.requireTaskDeletionAllowed([fixture.taskID]); checks["commitDraftBlocksTaskDeletion"] = false } catch { checks["commitDraftBlocksTaskDeletion"] = true }
            await second.checkWorkspace(message: ""); await git.checkWorkspace(message: "")
            await git.checkWorkspace(source: .unstaged, path: "stage-only.txt", action: "stage")
            checks["inlineStageUsesActualIndex"] = try await rawGit(["show", ":stage-only.txt"]) == "stage-this-file\n"
            await git.checkWorkspace(source: .staged, path: "stage-only.txt", action: "unstage")
            checks["inlineUnstagePreservesWorkingBytes"] = try await rawGit(["show", ":stage-only.txt"]) == "original-stage\n" && String(contentsOf: fixture.workspace.appendingPathComponent("stage-only.txt"), encoding: .utf8) == "stage-this-file\n"
            checks.merge(try await checkGitRestorePermissions(fixture, tasks: tasks)) { _, value in value }
            await git.checkWorkspace(source: .staged, path: "review.txt", message: "")
            guard let reviewContent = git.pageContentView,
                  let commitMessage = gitReviewSubviews(reviewContent).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Git 提交说明" }),
                  control.window?.makeFirstResponder(commitMessage) == true,
                  let editor = commitMessage.currentEditor() as? NSTextView,
                  let commitAction = gitReviewSubviews(reviewContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "提交已暂存" }) else { throw PetError("实际提交输入框或按钮不可用") }
            editor.string = "Review task workspace snapshot"
            commitAction.performClick(nil); await git.checkWorkspace()
            checks["inlineCommitReadsLiveEditorSubject"] = try await rawGit(["log", "-1", "--format=%s"]) == "Review task workspace snapshot\n"
            let head = try await rawGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            checks["inlineCommitUsesReviewedStagedVersion"] = try await rawGit(["show", "HEAD:review.txt"]) == "selected-staged\n" && String(contentsOf: fixture.workspace.appendingPathComponent("review.txt"), encoding: .utf8) == "selected-working-preserved\n"
            let otherIndex = try await rawGit(["show", ":other.txt"]), otherCommit = try await rawGit(["show", "HEAD:other.txt"])
            checks["inlineCommitPreservesOtherUserStaging"] = otherIndex == "other-staged-preserved\n" && otherCommit == "original-other\n"
            await git.checkWorkspace(action: "push")
            guard let push = host.currentController as? AgentGitPushWindow else { throw PetError("推送未进入同一工作区") }
            await push.checkPrepare()
            let pushState = push.workspaceReadback(); report["preparedPush"] = pushState
            checks["inlinePushPreparationReadsRealRemote"] = pushState["usesMainWindow"] as? Bool == true && pushState["pushEnabled"] as? Bool == true && (pushState["reviewHash"] as? String)?.isEmpty == false
            guard let pushContent = push.pageContentView,
                  let action = gitReviewSubviews(pushContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "推送…" }),
                  let diff = gitReviewSubviews(pushContent).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "待推送 实际差异" }) else {
                throw PetError("实际推送审阅入口或差异不可用")
            }
            let diffSelection = (diff.string as NSString).range(of: "selected-staged")
            guard diffSelection.location != NSNotFound else { throw PetError("待推送差异缺少实际提交内容") }
            diff.setSelectedRange(diffSelection); diff.scrollRangeToVisible(diffSelection)
            action.performClick(nil)
            guard let confirmation = host.currentController as? AgentSettingsReviewPage, let page = confirmation.pageContentView,
                  let cancel = gitReviewSubviews(page).compactMap({ $0 as? NSButton }).first(where: { $0.title == "取消" }),
                  let reader = gitReviewSubviews(page).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "设置审阅正文" }) else {
                throw PetError("确认推送未进入原工作区")
            }
            checks["pushConfirmationShowsFullDestinationAndHeadInSameWindow"] = confirmation.presentingWindow === control.window &&
                control.window?.hasBlockingDialog == false && reader.string.contains(head) &&
                (pushState["address"] as? String).map { !$0.isEmpty && reader.string.contains($0) } == true
            checks["pushConfirmationDefaultsToCancel"] = control.window?.firstResponder === cancel && tasks.task(fixture.taskID)?.gitPushReceipt == nil
            await inspect("push-confirmation")
            cancel.performClick(nil)
            let cancelled = push.workspaceReadback()
            checks["pushConfirmationCancelKeepsReviewAndSelection"] = host.currentController === push && diff.selectedRange() == diffSelection &&
                cancelled["diff"] as? String == pushState["diff"] as? String && cancelled["reviewHash"] as? String == pushState["reviewHash"] as? String &&
                control.window?.firstResponder === action && tasks.task(fixture.taskID)?.gitPushReceipt == nil
            guard let targetField = gitReviewSubviews(pushContent).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "推送目标分支" }),
                  control.window?.makeFirstResponder(targetField) == true,
                  let targetEditor = targetField.currentEditor() as? NSTextView else { throw PetError("推送目标分支输入框不可用") }
            let target = "release/中文😀", selection = (target as NSString).range(of: "中文😀")
            targetEditor.string = target; targetEditor.setSelectedRange(selection)
            push.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: targetField))
            if let page = try git.captureWorkspaceRecovery(persistClean: false), let draft = try AgentGitDraftRecovery.decode(page).push {
                let addressHash = (pushState["address"] as? String).map { AgentFiles.hash(Data($0.utf8)) }
                checks["pushDraftRecordsLiveBranchSelectionAndDestination"] = page.dirty && draft.opened && draft.branch == target && draft.selection?.range == selection && draft.focused && draft.remote == "origin" && addressHash != nil && draft.addressHash == addressHash
            } else { checks["pushDraftRecordsLiveBranchSelectionAndDestination"] = false }
            host.checkBack(); checks["pushBackReturnsToSameReview"] = host.currentController === git
            if let page = try git.captureWorkspaceRecovery(persistClean: false), let draft = try AgentGitDraftRecovery.decode(page).push {
                checks["pushBackParksTheDraftForReopening"] = page.dirty && !draft.opened && draft.branch == target
            } else { checks["pushBackParksTheDraftForReopening"] = false }
            await git.checkWorkspace(action: "push")
            guard let reopenedPush = host.currentController as? AgentGitPushWindow else { throw PetError("推送草稿未重新打开") }
            let deadline = Date().addingTimeInterval(15)
            while reopenedPush.workspaceReadback()["busy"] as? Bool == true && Date() < deadline { await wait(0.05) }
            let reopened = reopenedPush.workspaceReadback()
            checks["reopenedPushRequiresFreshReviewOfTheDraft"] = reopened["branch"] as? String == target && reopened["remote"] as? String == "origin" && reopened["address"] as? String == pushState["address"] as? String && reopened["reviewHash"] as? String == "" && reopened["pushEnabled"] as? Bool == false
            host.checkBack()
            await git.checkWorkspace(source: .unstaged, path: "client.js", action: "security")
            checks["actualSecurityReportUsesSameWorkspace"] = host.currentController is AgentCodeSecurityWindow && host.currentController?.presentingWindow === control.window
            host.checkBack(); await git.checkWorkspace(action: "dependencies")
            checks["dependencyReportUsesSameWorkspace"] = host.currentController is AgentDependencyWindow && host.currentController?.presentingWindow === control.window
            control.window?.setContentSize(NSSize(width: 800, height: 550)); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.1)
            host.checkBack()
            checks["narrowChildBackPreservesActualWorkspaceHeader"] = host.currentController === git && host.checkState()["expandVisible"] as? Bool == false && host.checkState()["expandLabel"] as? String == "还原工作区"
            control.showAgentTask(fixture.standaloneID); control.showAgentGit()
            guard let missing = host.currentController as? AgentGitWindow else { throw PetError("无工作区状态未载入") }
            await missing.checkWorkspace()
            checks["missingRepositoryIsActionableWithoutFloatingModal"] = missing.workspaceReadback()["busy"] as? Bool == false && (missing.workspaceReadback()["state"] as? String)?.isEmpty == false && missing.presentingWindow === control.window
            control.showAgentTask(fixture.taskID); await git.checkWorkspace(source: .uncommitted, path: "review.txt")
            checks.merge(try await checkGitWhitespaceReview(git, fixture: fixture, tasks: tasks, rawGit: rawGit)) { _, value in value }
            checks.merge(try await checkGitReadingJournal(git, output: output)) { _, value in value }
            checks.merge(try await checkExternalGitMetadata(fixture, output: output, tasks: tasks)) { _, value in value }
            checks["modelTransmissionsRemainZero"] = requests == 0 && tasks.tasks.allSatisfy { $0.modelReceipts?.isEmpty != false && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["head"] = try await rawGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            report["reviewedCommit"] = head; report["taskID"] = fixture.taskID; report["workspace"] = fixture.workspace.path; report["modelRequests"] = requests
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["scope"] = "Actual task window, independent Git repository/index/commit objects and loopback remote preparation; no model requests. Publishing remains an explicit UI confirmation."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-workspace-report.json"))
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-workspace-report.json")) }
    }

    private func gitReviewSubviews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(gitReviewSubviews) }

    private func checkExternalGitMetadata(_ fixture: GitWorkspaceFixture, output: URL, tasks: AgentStore) async throws -> [String: Bool] {
        let fm = FileManager.default, host = control.taskWorkspace
        let project = output.appendingPathComponent("separate-project", isDirectory: true)
        let metadata = output.appendingPathComponent("separate-metadata", isDirectory: true)
        let alternate = output.appendingPathComponent("separate-alternate", isDirectory: true)
        let parked = output.appendingPathComponent("separate-original", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: false)
        try fm.copyItem(at: fixture.workspace.appendingPathComponent(".git"), to: metadata)
        try fm.copyItem(at: metadata, to: alternate)
        let pointer = project.appendingPathComponent(".git"), file = project.appendingPathComponent("review.txt")
        try Data("gitdir: \(metadata.path)\n".utf8).write(to: pointer)
        let content = Data("public external workspace review\n".utf8)
        try content.write(to: file)
        let draft = "元数据连接时保留原草稿。"
        let first = tasks.create(title: "审阅项目外的 Git 元数据", workspace: project.path, mode: .ask, draft: draft)
        let second = tasks.create(title: "从输入区进入工作树", workspace: project.path, mode: .ask, draft: draft)
        func review(_ step: String) async throws -> (AgentSettingsReviewPage, NSButton, NSButton, NSTextView) {
            for _ in 0..<50 {
                if let page = host.currentController as? AgentSettingsReviewPage, let body = page.pageContentView {
                    let views = gitReviewSubviews(body)
                    let buttons = views.compactMap { $0 as? NSButton }
                    if let cancel = buttons.first(where: { $0.title == "取消" }), let connect = buttons.first(where: { $0.title == "连接" }),
                       let text = views.compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "设置审阅正文" }) {
                        return (page, cancel, connect, text)
                    }
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            let current = control.gitWorkspaceReadback()
            let state = (host.currentController as? AgentGitWindow)?.workspaceReadback()["state"] as? String ?? ""
            throw PetError("Git 元数据审阅未打开（\(step)）。当前：\(current["controller"] ?? "")，Git 状态：\(state)")
        }
        var checks: [String: Bool] = [:]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("external-git-metadata-checks.json"), options: .atomic)
            }
        }
        let wasVisible = control.window?.isVisible == true
        if !wasVisible { control.window?.orderFront(nil) }
        defer { if !wasVisible { control.window?.orderOut(nil) } }
        control.showAgentTask(second); control.createTaskWorktree()
        do {
            let (page, cancel, _, text) = try await review("工作树入口")
            checks["worktreeUsesSameWindowForExplicitMetadataScope"] = page.isPageVisible && page.presentingWindow === control.window && control.window?.hasBlockingDialog == false &&
                text.string.contains("操作：新建工作树") && text.string.contains(metadata.path) && text.string.contains(project.path) &&
                control.window?.firstResponder === cancel && tasks.task(second)?.gitDirectory == nil
            cancel.performClick(nil)
            try await Task.sleep(for: .milliseconds(30))
            checks["metadataCancelDoesNotGrantOrChangeDraft"] = host.currentController is AgentGitWindow && tasks.task(second)?.gitDirectory == nil && tasks.task(second)?.draft == draft
        }
        control.showAgentTask(first); control.showAgentGit()
        guard let git = host.rootController(.review) as? AgentGitWindow else { throw PetError("Git 根审阅缺失") }
        do {
            let (page, cancel, connect, text) = try await review("第一次 Git 阅读")
            checks["approvalIsRequiredBeforeGitReadsTheExternalCheckout"] = text.string.contains("操作：查看 Git 变更") &&
                (git.workspaceReadback()["files"] as? [String])?.isEmpty == true && tasks.task(first)?.gitDirectory == nil
            try fm.moveItem(at: metadata, to: parked); try fm.moveItem(at: alternate, to: metadata)
            connect.performClick(nil)
            checks["samePathMetadataReplacementInvalidatesPreviousApproval"] = !connect.isEnabled && host.currentController === page && tasks.task(first)?.gitDirectory == nil
            try fm.moveItem(at: metadata, to: alternate); try fm.moveItem(at: parked, to: metadata)
            cancel.performClick(nil)
        }
        await git.checkWorkspace(action: "refresh")
        do {
            let (page, _, connect, _) = try await review("刷新后的 Git 阅读")
            let record = tasks.directory.appendingPathComponent(first + ".json"), before = try Data(contentsOf: record)
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: record.path)
            connect.performClick(nil)
            checks["readOnlyTaskDoesNotGrantMetadataAndCanRetry"] = try host.currentController === page && connect.isEnabled && tasks.task(first)?.gitDirectory == nil && Data(contentsOf: record) == before
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
            connect.performClick(nil)
        }
        await git.checkWorkspace(path: "review.txt")
        checks["gitApprovalLoadsRealDiffAndOnlyConnectsItsOriginalTask"] = host.currentController === git &&
            (git.workspaceReadback()["diff"] as? String)?.contains("+public external workspace review") == true &&
            tasks.task(first)?.gitDirectory == metadata.path && tasks.task(second)?.gitDirectory == nil && tasks.task(first)?.draft == draft

        control.showAgentTask(second); control.createTaskWorktree()
        let (page, _, connect, text) = try await review("再次打开工作树")
        guard text.string.contains("操作：新建工作树") else { throw PetError("重新打开工作树时显示了别的 Git 操作") }
        connect.performClick(nil)
        for _ in 0..<100 {
            if let creation = host.currentController as? AgentWorktreeCreationWindow, creation.prepareWorkspaceNavigation() { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        checks["worktreeApprovalContinuesToOriginalCreationForm"] = (host.currentController as? AgentWorktreeCreationWindow)?.isPageVisible == true &&
            tasks.task(second)?.gitDirectory == metadata.path && tasks.task(second)?.draft == draft && control.window?.hasBlockingDialog == false
        checks["permissionReviewDoesNotChangePublicWorkingFileOrGitPointer"] = try Data(contentsOf: file) == content &&
            String(contentsOf: pointer, encoding: .utf8) == "gitdir: \(metadata.path)\n"
        if checks["worktreeApprovalContinuesToOriginalCreationForm"] != true {
            let current = control.gitWorkspaceReadback()
            let state = (host.rootController(.review) as? AgentGitWindow)?.workspaceReadback()["state"] as? String ?? ""
            throw PetError("工作树审阅未续接。当前：\(current["controller"] ?? "")，确认仍可见：\(page.isPageVisible)，已保存连接：\(tasks.task(second)?.gitDirectory == metadata.path)，Git 状态：\(state)")
        }
        host.checkBack()
        guard let worktreeGit = host.currentController as? AgentGitWindow, worktreeGit.boundTaskID == second else {
            throw PetError("无法从工作树配置返回原 Git 审阅")
        }
        await worktreeGit.checkWorkspace()
        control.showAgentTask(fixture.taskID)
        return checks
    }

    private func checkGitReadingJournal(_ page: AgentGitWindow, output: URL) async throws -> [String: Bool] {
        let path = "whitespace-review.txt", task = page.boundTaskID
        await page.checkWorkspace(source: .unstaged, path: path, action: "split")
        guard let reading = try page.captureReviewReading() else { throw PetError("未保存 Git 审阅位置") }
        let value = try AgentGitDraftRecovery.Reading.decode(reading)
        let profile = output.appendingPathComponent("git-reading-journal", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let journal = AgentWorkspaceRecovery(profile: profile), window = UUID().uuidString, tab = UUID().uuidString
        let saved = try journal.savePage(reading, asset: nil, windowID: window, pageID: tab, expected: nil)
        let cleanHasNoDraft = try journal.loadPage(windowID: window, pageID: tab, taskID: task) == nil &&
            journal.loadTabDirtyState(windowID: window, pageID: tab, taskID: task) == nil
        await page.checkWorkspace(message: "Original commit draft")
        guard let draft = try page.captureWorkspaceRecovery(persistClean: false) else { throw PetError("缺少原提交草稿") }
        _ = try journal.savePage(draft, asset: nil, windowID: window, pageID: tab, expected: nil)
        let loaded = try journal.loadPage(windowID: window, pageID: tab, taskID: task, reading: .git)?.saved
        let original = try journal.loadPage(windowID: window, pageID: tab, taskID: task)?.saved.value
        let draftRoundTrips = try original.map(AgentGitDraftRecovery.decode)?.message == "Original commit draft"
        await page.checkWorkspace(message: "")
        return ["gitReadingPreservesRealSelectedSourceAndSplitOptions": value.paths == [path] && value.source == .unstaged &&
                    value.split && value.ignoresWhitespace && value.sideBySide != nil && value.patchHash != nil,
                "gitReadingStoresNoDraftOrPatchText": cleanHasNoDraft && !String(decoding: reading.state, as: UTF8.self).contains("eligible ="),
                "gitReadingAndLegacyCommitDraftUseIndependentStorage": draftRoundTrips && loaded?.hash == saved.hash &&
                    loaded?.value == reading]
    }

    private func checkGitWhitespaceReview(_ page: AgentGitWindow, fixture: GitWorkspaceFixture, tasks: AgentStore, rawGit: ([String]) async throws -> String) async throws -> [String: Bool] {
        let git = try AgentGit(store: tasks, taskID: fixture.taskID, directory: AgentGit.metadata(workspace: fixture.workspace.path))
        let path = "whitespace-review.txt", url = fixture.workspace.appendingPathComponent(path)
        let context = (1...12).map { "context \($0)\n" }.joined()
        let base = "quantity = 1\n" + context + "eligible = true\n"
        let staged = "quantity  = 1\n" + context + "eligible = true\n\n"
        let working = staged.replacingOccurrences(of: "eligible = true", with: "eligible = false")
        try Data(base.utf8).write(to: url)
        for args in [["add", "--", path], ["commit", "--only", "-m", "Whitespace review fixture", "--", path]] {
            let result = try await git.run(args, write: true)
            guard !result.failed else { throw PetError(result.text) }
        }
        let originalHead = try await rawGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let backups = try AgentFiles(workspace: tasks.backupDirectory(fixture.taskID).path)
        let beforeTurn = try AgentCapturedFile.read(url.path, files: git.files, backups: backups)
        try Data(staged.utf8).write(to: url)
        let stage = try await git.run(["add", "--", path], write: true)
        guard !stage.failed else { throw PetError(stage.text) }
        try Data(working.utf8).write(to: url)
        let afterTurn = try AgentCapturedFile.read(url.path, files: git.files, backups: nil)
        guard let turn = tasks.task(fixture.taskID)?.messages.last(where: \.isHumanInput)?.id else { throw PetError("缺少差异验收的原任务轮次") }
        AgentChanges.record([AgentChange(path: url.path, existed: true, backup: beforeTurn.backup, beforeHash: beforeTurn.state.hash,
            afterHash: afterTurn.state.hash, permissions: beforeTurn.state.permissions, beforeKind: "file", afterKind: "file",
            afterPermissions: afterTurn.state.permissions)], taskID: fixture.taskID, turnID: turn, store: tasks)

        let diff = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--binary"]
        let filter = ["--ignore-all-space", "--ignore-blank-lines"]
        let raw = try await rawGit(diff + ["HEAD", "--", path])
        let filtered = try await rawGit(diff + filter + ["HEAD", "--", path])
        let index = try await rawGit(["ls-files", "--stage", "-z"])
        var checks: [String: Bool] = [:]
        await page.checkWorkspace(source: .uncommitted, path: path)
        let originalReview = tasks.task(fixture.taskID)?.gitReview
        checks["whitespaceReviewInitiallyShowsExactRawPatch"] = page.workspaceReadback()["diff"] as? String == raw && raw.contains("+quantity  = 1")
        await page.checkWorkspace(action: "whitespace")
        let mixed = page.workspaceReadback(), keptReview = tasks.task(fixture.taskID)?.gitReview
        checks["whitespaceReviewHidesWhitespaceHunkAndKeepsContentHunk"] = mixed["diff"] as? String == filtered && !filtered.contains("+quantity") && filtered.contains("+eligible = false")
        checks["whitespaceReviewKeepsSelectedFileAndRawReview"] = mixed["paths"] as? [String] == [path] &&
            keptReview?.hash == originalReview?.hash && keptReview?.diff == raw && (mixed["state"] as? String)?.contains("已忽略空白") == true
        await page.checkWorkspace(source: .lastTurn, path: path)
        checks["whitespaceReviewSupportsTaskSnapshotDiff"] = (page.workspaceReadback()["diff"] as? String)?.contains("+eligible = false") == true &&
            (page.workspaceReadback()["diff"] as? String)?.contains("+quantity") == false
        await page.checkWorkspace(source: .unstaged, path: path)
        let unstaged = try await rawGit(diff + filter + ["--", path])
        checks["whitespaceReviewUsesIndexToWorktreeForUnstaged"] = page.workspaceReadback()["diff"] as? String == unstaged && unstaged.contains("+eligible = false")
        await page.checkWorkspace(source: .staged, path: path)
        let stagedPatch = try await rawGit(diff + ["--cached", "--", path])
        checks["whitespaceReviewIdentifiesOnlyWhitespaceInStagedSource"] = page.workspaceReadback()["diff"] as? String == "所选文件仅有空白变更" &&
            tasks.task(fixture.taskID)?.gitReview?.diff == stagedPatch && !stagedPatch.contains("+eligible = false")
        await page.checkWorkspace(action: "whitespace")
        checks["whitespaceReviewCanRestoreExactRawStagedPatch"] = page.workspaceReadback()["diff"] as? String == stagedPatch
        await page.checkWorkspace(action: "whitespace")
        checks["whitespaceReviewDoesNotWriteIndexOrWorkingFile"] = try await rawGit(["ls-files", "--stage", "-z"]) == index &&
            String(contentsOf: url, encoding: .utf8) == working
        let otherIndex = try await rawGit(["show", ":other.txt"])
        await page.checkWorkspace(message: "Commit selected whitespace", action: "commit")
        let committed = try await rawGit(["show", "HEAD:" + path])
        let committedPaths = try await rawGit(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
        let finalOtherIndex = try await rawGit(["show", ":other.txt"])
        checks["whitespaceReviewCommitsOriginalStagedBytesOnly"] = try committed == staged && committedPaths == path + "\n" &&
            String(contentsOf: url, encoding: .utf8) == working && finalOtherIndex == otherIndex
        let committedReview = try await git.inspect(source: .committed, revision: "HEAD", requested: [path], ignoringWhitespace: true)
        let branchReview = try await git.inspect(source: .branch, revision: originalHead, requested: [path], ignoringWhitespace: true)
        checks["whitespaceReviewSupportsCommitAndBranchSources"] = committedReview.diff == stagedPatch && committedReview.whitespaceFilteredDiff == "" &&
            branchReview.diff == stagedPatch && branchReview.whitespaceFilteredDiff == ""
        return checks
    }

    private func checkGitRestorePermissions(_ fixture: GitWorkspaceFixture, tasks: AgentStore) async throws -> [String: Bool] {
        let git = try AgentGit(store: tasks, taskID: fixture.taskID, directory: AgentGit.metadata(workspace: fixture.workspace.path))
        let path = "stage-only.txt", file = fixture.workspace.appendingPathComponent(path)
        let original = try git.files.readData(file), originalMode = try git.files.entryMetadata(file).permissions
        let index = try await git.output(["ls-files", "--stage", "-z", "--", path])
        var checks: [String: Bool] = [:]
        func undo(_ result: AgentGitFileResult) throws {
            guard let checkpoint = tasks.task(fixture.taskID)?.changes.first(where: { $0.id == result.checkpointID }) else { throw PetError("权限恢复检查点不存在") }
            try AgentChanges.restore(checkpoint, taskID: fixture.taskID, store: tasks)
        }
        for mode in [0o600, 0o700] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            let result = try await git.apply(.restore, inspection: git.inspect(source: .unstaged, revision: "", requested: [path]))
            let restoredMode = try git.files.entryMetadata(file).permissions
            let actualIndex = try await git.output(["ls-files", "--stage", "-z", "--", path])
            checks["restoreMode\(mode)KeepsPrivacyAndIndexExecutableState"] = try restoredMode == 0o600 && git.files.readData(file) == Data("original-stage\n".utf8) && actualIndex == index
            try undo(result)
            checks["undoRestoreMode\(mode)RecoversOriginalBytesAndPermissions"] = try git.files.readData(file) == original && git.files.entryMetadata(file).permissions == mode
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        _ = try await git.apply(.stage, inspection: git.inspect(source: .unstaged, revision: "", requested: [path]))
        let privateWorking = Data("private executable working version\n".utf8)
        try git.files.writeData(privateWorking, to: file, permissions: 0o600)
        let executable = try await git.apply(.restore, inspection: git.inspect(source: .unstaged, revision: "", requested: [path]))
        checks["restoreExecutableIndexAddsOnlyPrivateExecuteBit"] = try git.files.entryMetadata(file).permissions == 0o700 && git.files.readData(file) == original
        try undo(executable)
        checks["undoExecutableRestoreRecoversPrivateNonExecutableVersion"] = try git.files.entryMetadata(file).permissions == 0o600 && git.files.readData(file) == privateWorking
        _ = try await git.apply(.unstage, inspection: git.inspect(source: .staged, revision: "", requested: [path]))
        try git.files.writeData(original, to: file, permissions: originalMode ?? 0o644)
        let finalIndex = try await git.output(["ls-files", "--stage", "-z", "--", path])
        checks["permissionCasesPreserveOriginalIndexAndWorkingFile"] = try finalIndex == index && git.files.readData(file) == original && git.files.entryMetadata(file).permissions == originalMode
        return checks
    }

    private func checkGitReviewVisuals(_ page: AgentGitWindow, workspace: URL, output: URL) async throws -> [String: Bool] {
        guard let owner = control.window, let content = page.pageContentView else { throw PetError("Git 实际任务窗口不可用") }
        var checks: [String: Bool] = [:], frames: [String: Any] = [:]
        let all = gitReviewSubviews(content)
        guard let source = all.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "Git 改动来源" }),
              let picker = all.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "Git 所选文件" }),
              let message = all.compactMap({ $0 as? AgentDialogTextField }).first(where: { $0.accessibilityLabel() == "Git 提交说明" }),
              let revision = all.compactMap({ $0 as? AgentDialogTextField }).first(where: { $0.accessibilityLabel() == "Git 比较修订" }),
              let display = all.compactMap({ $0 as? NSSegmentedControl }).first,
              let wrap = all.compactMap({ $0 as? NSButton }).first(where: { $0.title == "换行" }),
              let viewer = all.compactMap({ $0 as? AgentGitDiffView }).first,
              let fileList = all.compactMap({ $0 as? NSTableView }).first(where: { $0.accessibilityLabel() == "Git 变更文件" }) else { throw PetError("Git 统一控件未载入") }
        func settle() async {
            owner.contentView?.layoutSubtreeIfNeeded(); page.pageDidLayout(); owner.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(60))
        }
        checks["visualSourceMenuRetainsAllSixChoices"] = source.itemTitles == ["本轮修改", "未提交", "未暂存", "已暂存", "已提交", "分支"]
        for (name, size) in [("wide", NSSize(width: 1320, height: 800)), ("narrow", NSSize(width: 780, height: 540))] {
            owner.setContentSize(size)
            for look in [NSAppearance.Name.aqua, .darkAqua] {
                owner.appearance = NSAppearance(named: look)
                await page.checkWorkspace(source: .uncommitted, path: "review.txt")
                if page.workspaceReadback()["fileListVisible"] as? Bool != true { await page.checkWorkspace(action: "files") }
                await settle()
                let r = page.workspaceReadback(), key = "visual-" + name + "-" + look.rawValue
                let sourceRect = r["sourceFrame"] as? [Double] ?? [], fileRect = r["fileFrame"] as? [Double] ?? []
                let actions = gitReviewSubviews(content).compactMap { $0 as? AgentDialogButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
                checks[key + "-sharedPopupsAndFullFileWidth"] = source.superview is AgentSettingsPopupFrame && picker.superview is AgentSettingsPopupFrame && sourceRect.count == 4 && fileRect.count == 4 && sourceRect[3] == 28 && fileRect[3] == 28 && abs(fileRect[2] - Double(content.bounds.width - 68)) < 1 && source.font?.pointSize == 13 && picker.font?.pointSize == 13
                checks[key + "-sharedActionsFitAt28Points"] = actions.count == 7
                    && actions.contains { $0.accessibilityLabel() == "生成提交说明" }
                    && actions.allSatisfy { $0.bounds.height == 28 && $0.font?.pointSize == 13 }
                    && (r["checks"] as? [String: Bool])?["gitActionsFitWorkspace"] == true
                let visibleLabel = fileList.view(atColumn: 0, row: fileList.selectedRow, makeIfNecessary: true) as? NSTextField
                checks[key + "-readableDiffAndVisibleFileList"] = viewer.bounds.height >= 80 && viewer.bounds.width >= 230 && fileList.enclosingScrollView?.bounds.height ?? 0 >= 32 && viewer.patch.contains("+selected-working-preserved") && visibleLabel?.font?.pointSize == 13
                checks[key + "-outlinedCommitInputFits"] = message.outlined && message.bounds.height == 32 && !message.hasAmbiguousLayout
                let patch = viewer.patch
                let actualReader = viewer.readingReadback()
                checks[key + "-unifiedNumbersMatchActualGitPatch"] = actualReader["gutterVisible"] as? Bool == true && viewer.text.records.contains { $0.old == 1 && $0.kind == .removed } && viewer.text.records.contains { $0.new == 1 && $0.kind == .added }
                do {
                    let ruler = viewer.lineNumberGutter
                    let width = Int(ceil(ruler.bounds.width)) + 40, height = Int(ceil(ruler.bounds.height)) + 40
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    NSColor.magenta.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
                    let byteCount = bitmap.bytesPerRow * height
                    let beforePaint = Data(bytes: bitmap.bitmapData!, count: byteCount)
                    let offset = NSAffineTransform(); offset.translateX(by: 20 - ruler.bounds.minX, yBy: 20 - ruler.bounds.minY); offset.concat()
                    ruler.draw(ruler.bounds.insetBy(dx: -20, dy: -20))
                    let afterPaint = Data(bytes: bitmap.bitmapData!, count: byteCount)
                    NSGraphicsContext.restoreGraphicsState()
                    var outsideUnchanged = true, insidePainted = false
                    for y in 0..<height {
                        for x in 0..<width {
                            let byte = y * bitmap.bytesPerRow + x * 4
                            let changed = (0..<4).contains { beforePaint[byte + $0] != afterPaint[byte + $0] }
                            if x < 20 || x >= width - 20 || y < 20 || y >= height - 20 { outsideUnchanged = outsideUnchanged && !changed }
                            else { insidePainted = insidePainted || changed }
                        }
                    }
                    checks[key + "-actualGutterDrawingCannotPaintOutsideItsBounds"] = outsideUnchanged && insidePainted
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(key + "-gutter-paint-bounds.png"))
                }
                let longText = String(repeating: "完整中文 🐋 and public content ", count: 16)
                let readerPatch = "diff --git a/public.txt b/public.txt\n--- a/public.txt\n+++ b/public.txt\n@@ -99999,3 +100001,4 @@\n unchanged 🐋\r\n-old value\r\n+" + longText + "\r\n+extra value\r\n last value\r\n\\ No newline at end of file\n"
                viewer.show(readerPatch, oldTitle: "原版本", newTitle: "新版本"); await settle()
                let records = viewer.text.records, reading = viewer.readingReadback(), fragments = viewer.text.fragments(in: viewer.text.bounds)
                var glyphsFit = true
                if let manager = viewer.text.layoutManager {
                    manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, used, _, _, _ in
                        let right = used.maxX + viewer.text.textContainerOrigin.x
                        glyphsFit = glyphsFit && right <= viewer.text.visibleRect.maxX + 0.5
                    }
                } else { glyphsFit = false }
                let gutterFrame = viewer.lineNumberGutter.frame, scrollFrame = viewer.text.enclosingScrollView!.frame
                checks[key + "-wrappedGlyphsUseActualViewportAfterGutter"] = glyphsFit && gutterFrame.maxX <= scrollFrame.minX + 0.5 && abs(viewer.text.enclosingScrollView!.contentView.bounds.minX) < 0.5
                let longRange = (readerPatch as NSString).range(of: "+" + longText + "\r")
                let longFragments = fragments.filter { $0.record.range.location == longRange.location }
                checks[key + "-unifiedLargeNumbersAndUTF16ContentStayExact"] = viewer.patch == readerPatch && records.contains { $0.old == 100000 && $0.new == nil && $0.kind == .removed } && records.contains { $0.new == 100002 && $0.old == nil && $0.kind == .added } && records.contains { $0.old == 100001 && $0.new == 100004 } && (reading["gutterWidth"] as? CGFloat ?? 0) > 64
                checks[key + "-wrappedFragmentsKeepOneNumberPerSourceLine"] = longFragments.count > 1 && longFragments.filter(\.first).count == 1 && longFragments.allSatisfy { $0.record.new == 100002 } && zip(longFragments, longFragments.dropFirst()).allSatisfy { $0.0.rect.maxY <= $0.1.rect.minY + 0.5 }
                let focused = viewer.focusNewLine(100002)
                checks[key + "-newLineFocusKeepsFullOriginalUnicodeAndCR"] = focused && viewer.text.selectedRange() == longRange && (viewer.text.string as NSString).substring(with: viewer.text.selectedRange()) == "+" + longText + "\r"
                viewer.wraps = false; await settle()
                let scroll = viewer.text.enclosingScrollView!
                scroll.contentView.scroll(to: NSPoint(x: 120, y: scroll.contentView.bounds.minY)); scroll.reflectScrolledClipView(scroll.contentView)
                let unwrapped = viewer.readingReadback()
                checks[key + "-unwrappedContentScrollsWithNumberGutter"] = unwrapped["horizontalScroller"] as? Bool == true && (unwrapped["textWidth"] as? CGFloat ?? 0) > (unwrapped["viewportWidth"] as? CGFloat ?? 0) && scroll.contentView.bounds.minX > 0 && viewer.text.fragments(in: viewer.text.visibleRect).contains { $0.first && $0.record.new == 100002 }
                viewer.splitMode = true; viewer.wraps = true; await settle()
                checks[key + "-largeSplitNumbersFitAndRowsStayAligned"] = (viewer.readingReadback()["splitNumberWidth"] as? CGFloat ?? 0) >= ceil(("100004" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width) + 12 && viewer.checkSplitLayout().values.allSatisfy { $0 }
                viewer.splitMode = false; viewer.show("此来源没有变更", oldTitle: "HEAD", newTitle: "工作区"); await settle()
                checks[key + "-plainStatusDoesNotShowPhantomLineNumbers"] = viewer.readingReadback()["gutterVisible"] as? Bool == false && viewer.patch == "此来源没有变更"
                viewer.effectiveAppearance.performAsCurrentDrawingAppearance {
                    viewer.updateLayer()
                    checks[key + "-shortDiffCanvasUsesEditorSurface"] =
                        viewer.layer?.backgroundColor == AgentThemeContext.resolve(AgentWorkbenchTheme.surface, in: viewer).cgColor
                }
                viewer.show(patch, oldTitle: "HEAD", newTitle: "工作区"); await settle()
                display.selectedSegment = 1; display.sendAction(display.action, to: display.target)
                wrap.performClick(nil); await settle()
                checks[key + "-actualSplitAndWrapActionsWork"] = viewer.splitMode && !viewer.wraps && viewer.patch == patch && viewer.checkSplitLayout().values.allSatisfy { $0 }
                display.selectedSegment = 0; display.sendAction(display.action, to: display.target); wrap.performClick(nil)
                await page.checkWorkspace(source: .committed, path: "review.txt"); await settle()
                let committed = page.workspaceReadback()
                checks[key + "-revisionControlsAndDiffFit"] = !revision.isHidden && revision.outlined && revision.bounds.height == 28 && (committed["checks"] as? [String: Bool])?.values.allSatisfy { $0 } == true && viewer.patch.contains("+original-review")
                frames[key] = ["working": r, "committed": committed]
            }
        }
        await page.checkWorkspace(source: .uncommitted, path: "review.txt")
        guard owner.makeFirstResponder(message), let editor = message.currentEditor() as? NSTextView else { throw PetError("Git 草稿实际编辑器不可用") }
        editor.string = "保留正在输入的提交说明。"
        await page.checkWorkspace(source: .staged, path: "review.txt")
        checks["visualSourceChangePreservesLiveCommitEditor"] = page.workspaceReadback()["draft"] as? String == "保留正在输入的提交说明。"
        guard owner.makeFirstResponder(message), let clearingEditor = message.currentEditor() as? NSTextView else { throw PetError("清空提交说明时无法打开实际输入框") }
        clearingEditor.selectAll(nil); clearingEditor.deleteBackward(nil); message.validateEditing()
        checks["visualCommitInputActuallyCleared"] = clearingEditor.string.isEmpty && message.stringValue.isEmpty
        guard let commit = gitReviewSubviews(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "提交已暂存" }),
              let refresh = gitReviewSubviews(content).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "刷新 Git" }) else { throw PetError("Git 原生动作不可用") }
        commit.performClick(nil); await settle()
        checks["visualEmptyCommitErrorKeepsReadableReview"] = page.workspaceReadback()["state"] as? String == "请填写提交说明" && page.workspaceReadback()["stateIsError"] as? Bool == true && viewer.patch.contains("+selected-staged")
        refresh.performClick(nil)
        checks["visualBusyScopesDisableAndRestore"] = page.workspaceReadback()["busy"] as? Bool == true && !source.isEnabled && !picker.isEnabled
        await page.checkWorkspace()
        checks["visualReadyScopesRestoreAfterRealRefresh"] = source.isEnabled && picker.isEnabled && page.workspaceReadback()["stateIsError"] as? Bool == false
        let longPath = (0..<3).map { String($0) + "-" + String(repeating: "长目录", count: 10) }.joined(separator: "/") + "/review-change.txt"
        let longFile = workspace.appendingPathComponent(longPath)
        try FileManager.default.createDirectory(at: longFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("公开长路径 Git 审阅样例\n".utf8).write(to: longFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: longFile.path)
        await page.checkWorkspace(source: .uncommitted, path: longPath)
        checks["visualLongFileMenuKeepsFullPathAndActualDiff"] = picker.selectedItem?.toolTip == longPath && page.workspaceReadback()["paths"] as? [String] == [longPath] && viewer.patch.contains("+公开长路径 Git 审阅样例")
        await page.checkWorkspace(source: .lastTurn)
        checks["visualEmptySourceDisablesFilePicker"] = !picker.isEnabled && picker.titleOfSelectedItem == "暂无变更" && viewer.patch == "本轮尚无文件修改记录"
        await page.checkWorkspace(source: .branch)
        checks["visualInvalidRevisionErrorKeepsControlsAndDraft"] = page.workspaceReadback()["stateIsError"] as? Bool == true && source.isEnabled && !picker.isEnabled && !revision.isHidden && message.stringValue.isEmpty
        owner.makeFirstResponder(nil); revision.stringValue = "HEAD"; revision.sendAction(revision.action, to: revision.target)
        await page.checkWorkspace()
        checks["visualValidRevisionRetryUsesRealGit"] = page.workspaceReadback()["stateIsError"] as? Bool == false && viewer.patch == "此来源没有变更" && revision.stringValue == "HEAD"
        await page.checkWorkspace(source: .uncommitted, path: "review.txt", message: "")
        if page.workspaceReadback()["fileListVisible"] as? Bool == true { await page.checkWorkspace(action: "files") }
        owner.setContentSize(NSSize(width: 1200, height: 774)); await settle()
        try JSONSerialization.data(withJSONObject: ["checks": checks, "frames": frames, "longPath": longPath], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-review-visual-details.json"))
        return checks
    }
}
