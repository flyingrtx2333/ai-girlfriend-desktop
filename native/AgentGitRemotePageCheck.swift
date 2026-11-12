import AppKit

@MainActor extension AppDelegate {
    struct GitRemotePageFixture { let taskID: String, workspace: URL, receiver: URL }

    func prepareGitRemotePageFixture(_ output: URL) async throws -> GitRemotePageFixture {
        guard !CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--attention-live-ui") else { throw PetError("Git 远端页面验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务系统不可用") }
        let project = output.appendingPathComponent("workspace"), receiver = output.appendingPathComponent("receiver.git"), scratch = output.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("# Git 远端页面验收\n保留公开项目正文。\n".utf8).write(to: project.appendingPathComponent("README.md"))
        func setup(_ args: [String]) async throws {
            let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: scratch, network: false, timeout: 20, gitDirectory: project.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", project.path] + args)
            guard !result.failed else { throw PetError(result.text) }
        }
        try await setup(["init", "-b", "main"])
        for (key, value) in [("user.name", "Remote Page Acceptance"), ("user.email", "remote-page@example.invalid"), ("commit.gpgsign", "false")] { try await setup(["config", key, value]) }
        try await setup(["add", "--", "README.md"]); try await setup(["commit", "-m", "public remote page baseline"])
        try await setup(["init", "--bare", "--initial-branch=main", receiver.path]); try await setup(["remote", "add", "origin", receiver.path])
        let id = tasks.create(title: "Git 远端页面验收", workspace: project.path)
        tasks.update(id) { $0.draft = "保留 Git 远端页面验收草稿" }
        control.showAgentTask(id)
        let metadata: [String: Any] = ["taskID": id, "workspace": project.path, "receiver": receiver.path, "modelRequests": 0]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-remote-page-fixtures.json"))
        return GitRemotePageFixture(taskID: id, workspace: project, receiver: receiver)
    }

    func prepareGitRemotePageUI(_ output: URL, seed: Bool) async throws -> AgentGitPushWindow {
        if seed { _ = try await prepareGitRemotePageFixture(output) }
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("git-remote-page-fixtures.json"))) as? [String: Any]
        guard let tasks = agentStore, let id = metadata?["taskID"] as? String, let path = metadata?["workspace"] as? String, tasks.task(id)?.workspace == path else { throw PetError("未找到原 Git 远端验收任务") }
        control.showAgentTask(id)
        return try AgentGitPushWindow(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: path))
    }

    func runGitRemotePageCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        var standalone: AgentGitPushWindow?
        defer { standalone?.close(); agentRuntime?.stopAll() }
        func find<T: NSView>(_ type: T.Type, _ view: NSView?, where matches: (T) -> Bool) -> T? {
            guard let view else { return nil }; if let value = view as? T, matches(value) { return value }
            for child in view.subviews { if let value = find(type, child, where: matches) { return value } }; return nil
        }
        func field(_ label: String, in view: NSView?) throws -> NSTextField {
            guard let value = find(NSTextField.self, view, where: { $0.accessibilityLabel() == label }) else { throw PetError("缺少远端字段：" + label) }; return value
        }
        func button(_ title: String, in view: NSView?) throws -> NSButton {
            guard let value = find(NSButton.self, view, where: { $0.title == title && $0.isEnabled }) else { throw PetError("缺少远端操作：" + title) }; return value
        }
        func until(_ predicate: () -> Bool) async throws {
            let limit = Date().addingTimeInterval(20)
            while !predicate(), Date() < limit { await wait(0.05) }
            guard predicate() else { throw PetError("Git 远端页面未到达预期状态") }
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            checks["acceptanceUsesAgentWorkbenchAndIsolatedHome"] = usesAgent && tasks.extensions.sharedHome?.standardizedFileURL.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").standardizedFileURL.resolvingSymlinksInPath()
            guard checks["acceptanceUsesAgentWorkbenchAndIsolatedHome"] == true else { throw PetError("验收启动模式或独立目录未启用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("Git 远端页面验收禁止模型请求") }
            let fixture = try await prepareGitRemotePageFixture(output)
            let git = try AgentGit(store: tasks, taskID: fixture.taskID, directory: AgentGit.metadata(workspace: fixture.workspace.path))
            let wrongDirectory = try AgentGit(store: tasks, taskID: fixture.taskID, directory: fixture.workspace)
            do { try wrongDirectory.validateWorkspace(); checks["projectDirectoryIsNotAcceptedAsGitMetadata"] = false }
            catch { checks["projectDirectoryIsNotAcceptedAsGitMetadata"] = error.localizedDescription.contains("任务项目已变化") }
            let config = fixture.workspace.appendingPathComponent(".git/config"), readme = fixture.workspace.appendingPathComponent("README.md"), index = fixture.workspace.appendingPathComponent(".git/index")
            let originalConfig = try Data(contentsOf: config), originalReadme = try Data(contentsOf: readme), originalIndex = try Data(contentsOf: index)
            let configMode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
            let manager = try AgentGitPushWindow(store: tasks, taskID: fixture.taskID, directory: git.directory); standalone = manager
            guard let window = manager.window, let root = window.contentView else { throw PetError("缺少独立推送窗口") }
            manager.showWindow(nil); window.makeKeyAndOrderFront(nil)
            try await until { manager.workspaceReadback()["busy"] as? Bool == false }
            let visible = NSApp.windows.filter(\.isVisible).count
            try button("添加远端", in: root).performClick(nil)
            let address = try field("新远端地址", in: window.contentView), name = try field("新远端名称", in: window.contentView)
            let editor = address.currentEditor()
            checks["standaloneRemoteUsesSameWindowAndNoModal"] = window.contentView !== root && address.window === window && window.attachedSheet == nil && NSApp.modalWindow == nil && NSApp.windows.filter(\.isVisible).count == visible
            checks["standaloneRemoteStartsWithAddressFocus"] = window.firstResponder === address || (editor != nil && window.firstResponder === editor)
            checks["standaloneRemoteStartsWithCleanDefaults"] = name.stringValue == "origin" && address.stringValue.isEmpty && !manager.hasPendingOperation
            checks["remoteSaveSupportsCommandS"] = try button("添加远端", in: window.contentView).keyEquivalent == "s"
            for (key, size) in [("normal", NSSize(width: 860, height: 650)), ("narrow", NSSize(width: 640, height: 460))] {
                window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
                checks["standaloneRemoteLayout-" + key] = !address.hasAmbiguousLayout && address.bounds.width > 300 && address.bounds.height >= 20 && abs((window.contentView?.bounds.width ?? 0) - size.width) < 0.5 && abs((window.contentView?.bounds.height ?? 0) - size.height) < 0.5
            }
            try button("返回推送", in: window.contentView).performClick(nil)
            checks["cleanBackRestoresOriginalPushContentAndFocus"] = try window.contentView === root && window.firstResponder === button("添加远端", in: root)
            checks["cleanBackPreservesActualGitConfig"] = try Data(contentsOf: config) == originalConfig
            try button("添加远端", in: root).performClick(nil)
            let currentName = try field("新远端名称", in: window.contentView), currentAddress = try field("新远端地址", in: window.contentView)
            for (key, remote, url, errorText) in [("name", "bad name", fixture.receiver.path, "远端名称无效"), ("transport", "bad-transport", "ext::/bin/sh -c public-marker", "不支持的外部传输程序"), ("duplicate", "origin", fixture.receiver.path, "already exists")] {
                currentName.stringValue = remote; currentAddress.stringValue = url
                try button("添加远端", in: window.contentView).performClick(nil)
                checks["remoteSaveBlocksParentCloseWhilePending-" + key] = manager.hasPendingOperation && !manager.windowShouldClose(window)
                try await until { (try? button("添加远端", in: window.contentView).isEnabled) == true }
                checks["remoteFailureKeepsFieldsAndInlineError-" + key] = try window.contentView !== root && currentName.stringValue == remote && currentAddress.stringValue == url && field("远端保存状态", in: window.contentView).stringValue.contains(errorText) && Data(contentsOf: config) == originalConfig
            }
            currentName.stringValue = "page-review"; currentAddress.stringValue = fixture.receiver.path
            checks["remoteDraftMarksParentPending"] = manager.hasPendingOperation
            try button("添加远端", in: window.contentView).performClick(nil)
            try await until { window.contentView === root && manager.workspaceReadback()["busy"] as? Bool == false }
            let remotes = try await git.remotes()
            checks["remoteSaveWritesActualConfigAndPreservesOriginalRemote"] = remotes.count == 2 && remotes.contains { $0.name == "origin" && $0.urls == [fixture.receiver.path] } && remotes.contains { $0.name == "page-review" && $0.urls == [fixture.receiver.path] }
            checks["remoteSaveReturnsToOriginalWindowAndRemoteFocus"] = window.contentView === root && (window.firstResponder as? NSPopUpButton)?.accessibilityLabel() == "推送远端" && !manager.hasPendingOperation
            checks["remoteSavePreservesConfigPermissionsAndProjectBytes"] = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber == configMode && Data(contentsOf: readme) == originalReadme && Data(contentsOf: index) == originalIndex
            try button("添加远端", in: root).performClick(nil)
            checks["cleanChildAllowsNormalParentClose"] = manager.windowShouldClose(window)
            manager.close(); checks["closingParentReleasesChildAndRestoresContent"] = !window.isVisible && window.contentView === root
            control.showAgentTask(fixture.taskID); control.show(tab: "chat"); control.showAgentGit()
            guard let review = control.taskWorkspace.currentController as? AgentGitWindow else { throw PetError("任务 Git 页面未载入") }; await review.checkWorkspace(action: "push")
            guard let embedded = control.taskWorkspace.currentController as? AgentGitPushWindow, let host = control.window else { throw PetError("任务推送页面未载入") }
            try await until { embedded.workspaceReadback()["busy"] as? Bool == false }
            checks["taskRemoteUsesAnActuallyVisibleWindow"] = host.isVisible && embedded.isPageVisible
            try button("添加远端", in: embedded.pageContentView).performClick(nil)
            guard let page = control.taskWorkspace.currentController as? AgentGitRemotePage else { throw PetError("任务远端表单未载入") }
            checks["taskRemoteKeepsExistingTaskWorkspaceNavigation"] = page.presentingWindow === host && page.window?.isVisible == false && host.attachedSheet == nil
            control.taskWorkspace.checkBack()
            checks["taskRemoteBackRestoresPushAndFocus"] = try control.taskWorkspace.currentController === embedded && host.firstResponder === button("添加远端", in: embedded.pageContentView)
            try button("添加远端", in: embedded.pageContentView).performClick(nil)
            guard let savePage = control.taskWorkspace.currentController as? AgentGitRemotePage else { throw PetError("任务远端表单无法重开") }
            try field("新远端名称", in: savePage.pageContentView).stringValue = "task-review"; try field("新远端地址", in: savePage.pageContentView).stringValue = fixture.receiver.path
            try button("添加远端", in: savePage.pageContentView).performClick(nil)
            try await until { control.taskWorkspace.currentController === embedded && embedded.workspaceReadback()["busy"] as? Bool == false }
            let after = try await git.remotes()
            report["taskRemoteReturn"] = ["windowVisible": host.isVisible, "pageVisible": embedded.isPageVisible, "sameController": control.taskWorkspace.currentController === embedded, "firstResponder": host.firstResponder.map { String(describing: type(of: $0)) } ?? "nil", "focusLabel": (host.firstResponder as? NSView)?.accessibilityLabel() ?? "", "remotes": after.map(\.name)] as [String: Any]
            checks["taskRemoteSavePersistsAndReturnsToSamePushPage"] = after.count == 3 && after.contains { $0.name == "task-review" && $0.urls == [fixture.receiver.path] } && (host.firstResponder as? NSPopUpButton)?.accessibilityLabel() == "推送远端"
            checks["originalTaskDraftAndModelUsagePreserved"] = tasks.task(fixture.taskID)?.draft == "保留 Git 远端页面验收草稿" && requests == 0 && tasks.tasks.allSatisfy { $0.inputTokens == 0 && $0.outputTokens == 0 && $0.modelReceipts?.isEmpty != false }
            report["workspace"] = fixture.workspace.path; report["taskID"] = fixture.taskID; report["receiver"] = fixture.receiver.path
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["modelRequests"] = requests; report["appPID"] = ProcessInfo.processInfo.processIdentifier
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-remote-page-report.json"))
    }
}
