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
            await git.checkWorkspace(path: "review.txt")
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
            await git.checkWorkspace(source: .staged, path: "review.txt", message: "Review task workspace snapshot", action: "commit")
            let head = try await rawGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            checks["inlineCommitUsesReviewedStagedVersion"] = try await rawGit(["show", "HEAD:review.txt"]) == "selected-staged\n" && String(contentsOf: fixture.workspace.appendingPathComponent("review.txt"), encoding: .utf8) == "selected-working-preserved\n"
            let otherIndex = try await rawGit(["show", ":other.txt"]), otherCommit = try await rawGit(["show", "HEAD:other.txt"])
            checks["inlineCommitPreservesOtherUserStaging"] = otherIndex == "other-staged-preserved\n" && otherCommit == "original-other\n"
            await git.checkWorkspace(action: "push")
            guard let push = host.currentController as? AgentGitPushWindow else { throw PetError("推送未进入同一工作区") }
            await push.checkPrepare()
            let pushState = push.workspaceReadback(); report["preparedPush"] = pushState
            checks["inlinePushPreparationReadsRealRemote"] = pushState["usesMainWindow"] as? Bool == true && pushState["pushEnabled"] as? Bool == true && (pushState["reviewHash"] as? String)?.isEmpty == false
            host.checkBack(); checks["pushBackReturnsToSameReview"] = host.currentController === git
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
            checks["modelTransmissionsRemainZero"] = requests == 0 && tasks.tasks.allSatisfy { $0.modelReceipts?.isEmpty != false && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["head"] = head; report["taskID"] = fixture.taskID; report["workspace"] = fixture.workspace.path; report["modelRequests"] = requests
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["scope"] = "Actual task window, independent Git repository/index/commit objects and loopback remote preparation; no model requests. Publishing remains an explicit UI confirmation."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-workspace-report.json"))
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-workspace-report.json")) }
    }
}
