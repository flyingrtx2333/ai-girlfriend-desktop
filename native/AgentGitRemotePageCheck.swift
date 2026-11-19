import AppKit

@MainActor extension AppDelegate {
    struct GitRemotePageFixture { let taskID: String, workspace: URL, receiver: URL }

    func prepareGitRemotePageFixture(_ output: URL) async throws -> GitRemotePageFixture {
        guard !CommandLine.arguments.contains("--live-agent"), !CommandLine.arguments.contains("--attention-live-ui") else { throw PetError("Git 远端页面验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务系统不可用") }
        let project = output.appendingPathComponent("workspace"), receiver = output.appendingPathComponent(String(repeating: "公开接收目录", count: 10)).appendingPathComponent("receiver.git"), scratch = output.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiver.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        func editingLines(_ editor: NSTextView) -> Int {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return -1 }
            layout.ensureLayout(for: container); var lines = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
            return lines
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
                let saveAction = try button("添加远端", in: window.contentView)
                checks["standaloneRemoteLayout-" + key] = !address.hasAmbiguousLayout && address.bounds.width > 300 && address.bounds.height == 32 && name.bounds.height == 32 && saveAction.bounds.height == 28 && abs((window.contentView?.bounds.width ?? 0) - size.width) < 0.5 && abs((window.contentView?.bounds.height ?? 0) - size.height) < 0.5
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
            currentName.stringValue = "page-review"
            guard window.makeFirstResponder(currentAddress), let liveAddress = currentAddress.currentEditor() as? NSTextView else { throw PetError("远端实际输入编辑器不可用") }
            liveAddress.string = fixture.receiver.path
            checks["longRemoteAddressUsesOneVisibleEditingLine"] = fixture.receiver.path.utf8.count > 250 && editingLines(liveAddress) == 1 && liveAddress.string == fixture.receiver.path
            checks["remoteDraftMarksParentPending"] = manager.hasPendingOperation
            try button("添加远端", in: window.contentView).performClick(nil)
            try await until { window.contentView === root && manager.workspaceReadback()["busy"] as? Bool == false }
            let remotes = try await git.remotes()
            checks["remoteSaveWritesActualConfigAndPreservesOriginalRemote"] = remotes.count == 2 && remotes.contains { $0.name == "origin" && $0.urls == [fixture.receiver.path] } && remotes.contains { $0.name == "page-review" && $0.urls == [fixture.receiver.path] }
            checks["remoteSaveReadsActualAddressFieldEditor"] = remotes.contains { $0.name == "page-review" && $0.urls == [fixture.receiver.path] }
            checks["remoteSaveReturnsToOriginalWindowAndRemoteFocus"] = window.contentView === root && (window.firstResponder as? NSPopUpButton)?.accessibilityLabel() == "推送远端" && !manager.hasPendingOperation
            checks["remoteSavePreservesConfigPermissionsAndProjectBytes"] = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber == configMode && Data(contentsOf: readme) == originalReadme && Data(contentsOf: index) == originalIndex
            try button("添加远端", in: root).performClick(nil)
            checks["cleanChildAllowsNormalParentClose"] = manager.windowShouldClose(window)
            manager.close(); checks["closingParentReleasesChildAndRestoresContent"] = !window.isVisible && window.contentView === root
            control.showAgentTask(fixture.taskID); control.show(tab: "chat"); control.showAgentGit()
            guard let review = control.taskWorkspace.currentController as? AgentGitWindow else { throw PetError("任务 Git 页面未载入") }; await review.checkWorkspace(action: "push")
            guard let embedded = control.taskWorkspace.currentController as? AgentGitPushWindow, let host = control.window else { throw PetError("任务推送页面未载入") }
            defer { embedded.discardDraft() }
            try await until { embedded.workspaceReadback()["busy"] as? Bool == false }
            checks["taskRemoteUsesAnActuallyVisibleWindow"] = host.isVisible && embedded.isPageVisible
            for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                host.appearance = NSAppearance(named: theme)
                for (kind, size) in [("normal", NSSize(width: 1320, height: 800)), ("narrow", NSSize(width: 780, height: 540))] {
                    host.setContentSize(size); host.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                    let state = embedded.workspaceReadback(), frames = state["popupFrames"] as? [[CGFloat]] ?? [], branchFrame = state["branchFrame"] as? [CGFloat] ?? [], diffFrame = state["diffFrame"] as? [CGFloat] ?? []
                    let controls = state["controls"] as? [[String: Any]] ?? []
                    checks["pushActualControlsFit-" + appearance + "-" + kind] = controls.count >= 8 && controls.allSatisfy { $0["inside"] as? Bool == true } && frames.count == 3 && frames.allSatisfy { $0.count == 4 && $0[3] == 28 } && branchFrame.count == 4 && branchFrame[2] >= 100 && branchFrame[3] == 32 && diffFrame.count == 4 && diffFrame[3] >= 80
                    report["push-" + appearance + "-" + kind] = state
                }
            }
            host.appearance = nil; host.setContentSize(NSSize(width: 1320, height: 800)); host.contentView?.layoutSubtreeIfNeeded()
            let targetBranch = try field("推送目标分支", in: embedded.pageContentView)
            guard host.makeFirstResponder(targetBranch), let invalidEditor = targetBranch.currentEditor() as? NSTextView else { throw PetError("推送分支编辑器不可用") }
            let longBranch = "acceptance/" + String(repeating: "review-", count: 30)
            invalidEditor.string = longBranch
            checks["longPushBranchUsesOneVisibleEditingLine"] = editingLines(invalidEditor) == 1 && invalidEditor.string == longBranch
            invalidEditor.string = "bad branch"
            try button("检查远端", in: embedded.pageContentView).performClick(nil)
            checks["pushPreparingDisablesPublication"] = embedded.workspaceReadback()["busy"] as? Bool == true && embedded.workspaceReadback()["pushEnabled"] as? Bool == false
            try await until { embedded.workspaceReadback()["busy"] as? Bool == false }
            checks["invalidLiveBranchKeepsEditorAndInlineError"] = targetBranch.stringValue == "bad branch" && embedded.workspaceReadback()["stateIsError"] as? Bool == true && embedded.workspaceReadback()["reviewHash"] as? String == "" && embedded.workspaceReadback()["pushEnabled"] as? Bool == false
            guard host.makeFirstResponder(targetBranch), let validEditor = targetBranch.currentEditor() as? NSTextView else { throw PetError("推送重试编辑器不可用") }
            validEditor.string = "main"
            try button("检查远端", in: embedded.pageContentView).performClick(nil)
            try await until { embedded.workspaceReadback()["busy"] as? Bool == false }
            let prepared = embedded.workspaceReadback()
            checks["validLiveBranchRetryReadsActualLocalRemote"] = prepared["branch"] as? String == "main" && prepared["pushEnabled"] as? Bool == true && prepared["stateIsError"] as? Bool == false && (prepared["diff"] as? String)?.contains("保留公开项目正文") == true && !FileManager.default.fileExists(atPath: fixture.receiver.appendingPathComponent("refs/heads/main").path)
            guard let commits = find(NSPopUpButton.self, embedded.pageContentView, where: { $0.accessibilityLabel() == "待推送提交" }), commits.numberOfItems == 2, let selectCommit = commits.action else { throw PetError("实际待推送提交列表不可用") }
            commits.selectItem(at: 1); NSApp.sendAction(selectCommit, to: commits.target, from: commits)
            try await until { embedded.workspaceReadback()["busy"] as? Bool == false }
            checks["selectPendingCommitReadsActualCommitDiff"] = (embedded.workspaceReadback()["diff"] as? String)?.contains("public remote page baseline") == true && (embedded.workspaceReadback()["diff"] as? String)?.contains("README.md") == true
            report["actualPreparedPush"] = embedded.workspaceReadback()
            try button("添加远端", in: embedded.pageContentView).performClick(nil)
            guard let page = control.taskWorkspace.currentController as? AgentGitRemotePage else { throw PetError("任务远端表单未载入") }
            checks["taskRemoteKeepsExistingTaskWorkspaceNavigation"] = page.presentingWindow === host && page.window?.isVisible == false && host.attachedSheet == nil
            control.taskWorkspace.checkBack()
            checks["taskRemoteBackRestoresPushAndFocus"] = try control.taskWorkspace.currentController === embedded && host.firstResponder === button("添加远端", in: embedded.pageContentView)
            try button("添加远端", in: embedded.pageContentView).performClick(nil)
            guard let savePage = control.taskWorkspace.currentController as? AgentGitRemotePage else { throw PetError("任务远端表单无法重开") }
            let draftName = try field("新远端名称", in: savePage.pageContentView), draftAddress = try field("新远端地址", in: savePage.pageContentView)
            let beforeDraft = try Data(contentsOf: config)
            guard host.makeFirstResponder(draftAddress), let addressEditor = draftAddress.currentEditor() as? NSTextView else { throw PetError("实际远端草稿编辑器不可用") }
            let selection = (fixture.receiver.path as NSString).range(of: "公开接收目录", options: .backwards)
            draftName.stringValue = "bad name 🐋"; addressEditor.string = fixture.receiver.path; addressEditor.setSelectedRange(selection)
            savePage.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: draftAddress))
            let saved = try review.captureWorkspaceRecovery(persistClean: true).flatMap { try AgentGitDraftRecovery.decode($0).remoteForm }
            checks["remoteDraftReadsLiveAddressInvalidNameAndSelection"] = saved?.name == "bad name 🐋" && saved?.address == fixture.receiver.path && saved?.focus == .address && saved?.addressSelection?.range == selection && saved?.scope.checkout?.head == "ref: refs/heads/main" && savePage.canPreserveForQuit
            let unusableAddress = "https://git:PUBLIC-FIXTURE-ONLY@example.invalid/repository"
            addressEditor.string = unusableAddress
            savePage.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: draftAddress))
            let excluded = try review.captureWorkspaceRecovery(persistClean: true).map(AgentGitDraftRecovery.decode)
            checks["remoteDraftOmitsEmbeddedCredentialsButRetainsLiveInput"] = excluded?.remoteForm == nil && !savePage.canPreserveForQuit && savePage.hasPendingChanges && addressEditor.string == unusableAddress
            checks["editingOrCheckpointingRemoteDraftNeverChangesConfig"] = try Data(contentsOf: config) == beforeDraft
            typealias RemoteDraft = AgentGitDraftRecovery.RemoteForm
            checks["remoteDraftSupportsLocalSSHAndIncompletePublicURLs"] = ["https://", "https://example.invalid", "ssh://git@[::1]:22/repo", "git@example.invalid:repo", "./公开 路径#样例.git"].allSatisfy { RemoteDraft.canPreserve(name: "draft", address: $0) }
            checks["remoteDraftRejectsCredentialAndQueryShapes"] = [unusableAddress, "https://PUBLIC-FIXTURE-ONLY@example.invalid/repo", "ssh://git%3APUBLIC@example.invalid/repo", "https://example.invalid/repo?token=PUBLIC", "git:PUBLIC@example.invalid:repo"].allSatisfy { !RemoteDraft.canPreserve(name: "draft", address: $0) }
            draftName.stringValue = "task-review"; addressEditor.string = fixture.receiver.path
            try button("添加远端", in: savePage.pageContentView).performClick(nil)
            try await until { control.taskWorkspace.currentController === embedded && embedded.workspaceReadback()["busy"] as? Bool == false }
            let after = try await git.remotes()
            report["taskRemoteReturn"] = ["windowVisible": host.isVisible, "pageVisible": embedded.isPageVisible, "sameController": control.taskWorkspace.currentController === embedded, "firstResponder": host.firstResponder.map { String(describing: type(of: $0)) } ?? "nil", "focusLabel": (host.firstResponder as? NSView)?.accessibilityLabel() ?? "", "remotes": after.map(\.name)] as [String: Any]
            checks["taskRemoteSavePersistsAndReturnsToSamePushPage"] = after.count == 3 && after.contains { $0.name == "task-review" && $0.urls == [fixture.receiver.path] } && (host.firstResponder as? NSPopUpButton)?.accessibilityLabel() == "推送远端"
            if let saved {
                let recovered = AgentGitRemotePage(git: git, store: tasks, taskID: fixture.taskID, scope: saved.scope, recovery: saved) {}
                guard let resumedWindow = recovered.window else { throw PetError("恢复的远端窗口不可用") }
                defer { resumedWindow.close(); host.makeKeyAndOrderFront(nil) }
                recovered.showWindow(nil); resumedWindow.makeKeyAndOrderFront(nil)
                let field = try field("新远端地址", in: recovered.pageContentView)
                guard resumedWindow.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw PetError("恢复远端的地址编辑器不可用") }
                let defaultSelection = NSRange(location: 0, length: editor.string.utf16.count)
                editor.setSelectedRange(defaultSelection)
                recovered.settingsDidAppear()
                try await until { editor.selectedRange() == selection }
                checks["restoredAddressOverridesAppKitDefaultSelection"] = selection != defaultSelection && resumedWindow.firstResponder === editor && editor.string == fixture.receiver.path
            } else { checks["restoredAddressOverridesAppKitDefaultSelection"] = false }
            func readerGit(_ arguments: [String], write: Bool = false) async throws -> String {
                let result = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: output.appendingPathComponent("tmp"), network: false, timeout: 20, gitDirectory: git.directory, gitWrite: write, protectedData: store.directory, arguments: ["-C", fixture.workspace.path] + arguments)
                guard !result.failed else { throw PetError(result.text) }; return result.stdout ?? ""
            }
            let readingFile = fixture.workspace.appendingPathComponent("reading.swift")
            let originalReading = "struct PublicReading {\n    let title = \"原始公开示例\"\n" + (1...90).map { "    let item\($0) = \($0)\n" }.joined() + "}\n"
            try Data(originalReading.utf8).write(to: readingFile)
            _ = try await readerGit(["add", "--", "reading.swift"], write: true); _ = try await readerGit(["commit", "-m", "Public reader baseline"], write: true)
            let changedReading = originalReading.replacingOccurrences(of: "原始公开示例", with: "新的公开示例 🐋").replacingOccurrences(of: "    let item23 = 23", with: "    let 中文说明 = \"" + String(repeating: "完整中文与表情 🐋 / public-reading-content ", count: 8) + "\"")
            try Data(changedReading.dropLast().utf8).write(to: readingFile)
            _ = try await readerGit(["add", "--", "reading.swift"], write: true); _ = try await readerGit(["commit", "-m", "Public reader Unicode 🐋"], write: true)
            await embedded.checkPrepare()
            guard let picker = find(NSPopUpButton.self, embedded.pageContentView, where: { $0.accessibilityLabel() == "待推送提交" }), let choose = picker.action,
                  let reader = find(AgentGitDiffView.self, embedded.pageContentView, where: { _ in true }),
                  let mode = find(NSSegmentedControl.self, embedded.pageContentView, where: { $0.accessibilityLabel() == "待推送差异视图" }),
                  let wrap = find(NSButton.self, embedded.pageContentView, where: { $0.title == "换行" }), let display = mode.action, let wrapping = wrap.action,
                  let oid = picker.item(at: 1)?.representedObject as? String else { throw PetError("推送共享阅读控件不可用") }
            let overall = reader.patch
            picker.selectItem(at: 1); NSApp.sendAction(choose, to: picker.target, from: picker)
            try await until { embedded.workspaceReadback()["busy"] as? Bool == false }
            let expected = try await readerGit(["show", "--no-ext-diff", "--no-textconv", "--no-color", "--format=medium", "--stat", "-p", oid, "--"])
            checks["pushReaderKeepsActualCommitMetadataAndPatch"] = reader.patch == expected && expected.hasPrefix("commit " + oid) && expected.contains("Public reader Unicode 🐋") && expected.contains("\\ No newline at end of file")
            for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                host.appearance = NSAppearance(named: theme)
                for (kind, size) in [("normal", NSSize(width: 1320, height: 800)), ("narrow", NSSize(width: 780, height: 540))] {
                    host.setContentSize(size); host.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                    let key = appearance + "-" + kind
                    let state = embedded.workspaceReadback(), controls = state["controls"] as? [[String: Any]] ?? [], frames = state["popupFrames"] as? [[CGFloat]] ?? [], diff = state["diffFrame"] as? [CGFloat] ?? []
                    let read = reader.readingReadback()
                    let wrapFrame = controls.first { $0["label"] as? String == "换行" }?["frame"] as? [CGFloat] ?? [], contentSize = state["contentSize"] as? [CGFloat] ?? []
                    let alignedRight = wrapFrame.count == 4 && contentSize.count == 2 && abs(wrapFrame[0] + wrapFrame[2] - contentSize[0] + 16) < 0.5
                    checks["pushNumberedReaderAndControlsFit-" + key] = controls.allSatisfy { $0["inside"] as? Bool == true } && alignedRight && frames.count == 3 && frames[2][2] > 160 && frames[2][3] == 28 && diff.count == 4 && diff[3] >= 80 && read["gutterVisible"] as? Bool == true && abs((read["textWidth"] as? CGFloat ?? 0) - (read["viewportWidth"] as? CGFloat ?? 1)) < 0.5 && reader.patch == expected
                    mode.selectedSegment = 1; NSApp.sendAction(display, to: mode.target, from: mode); host.contentView?.layoutSubtreeIfNeeded()
                    checks["pushSplitUsesSameActualCommit-" + key] = reader.splitMode && reader.patch == expected && !mode.isHidden && mode.isEnabled && wrap.isEnabled
                    mode.selectedSegment = 0; NSApp.sendAction(display, to: mode.target, from: mode)
                    let selection = (expected as NSString).range(of: "新的公开示例 🐋"); reader.text.setSelectedRange(selection)
                    wrap.state = .off; NSApp.sendAction(wrapping, to: wrap.target, from: wrap); host.contentView?.layoutSubtreeIfNeeded()
                    checks["pushWrapTogglePreservesUnicodeSelection-" + key] = !reader.wraps && reader.text.selectedRange() == selection && selection.location != NSNotFound && reader.patch == expected
                    wrap.state = .on; NSApp.sendAction(wrapping, to: wrap.target, from: wrap); host.contentView?.layoutSubtreeIfNeeded()
                    report["numbered-push-" + key] = embedded.workspaceReadback()
                }
            }
            let modeOrigin = mode.convert(NSPoint.zero, to: embedded.pageContentView)
            picker.selectItem(at: 0); NSApp.sendAction(choose, to: picker.target, from: picker); host.contentView?.layoutSubtreeIfNeeded()
            checks["pushOverallSelectionRestoresExactPreparedPatch"] = reader.patch == overall && abs(mode.convert(NSPoint.zero, to: embedded.pageContentView).x - modeOrigin.x) < 0.5
            host.appearance = nil; host.setContentSize(NSSize(width: 1320, height: 800)); host.contentView?.layoutSubtreeIfNeeded()
            let largeFile = fixture.workspace.appendingPathComponent("large-public.txt")
            try Data((1...3000).map { "公开截取验收行 \($0) " + String(repeating: "public-content ", count: 8) + "\n" }.joined().utf8).write(to: largeFile)
            _ = try await readerGit(["add", "--", "large-public.txt"], write: true); _ = try await readerGit(["commit", "-m", "Public truncated patch check"], write: true)
            await embedded.checkPrepare()
            let truncatedOverall = reader.patch
            checks["actualLargeOverallPatchKeepsTruncationNotice"] = truncatedOverall.utf8.count >= 199_900 && truncatedOverall.hasSuffix("[差异已截取；可选择具体提交查看]")
            picker.selectItem(at: 1); NSApp.sendAction(choose, to: picker.target, from: picker)
            try await until { embedded.workspaceReadback()["busy"] as? Bool == false }
            checks["actualLargeSingleCommitKeepsTruncationNotice"] = reader.patch.utf8.count >= 199_900 && reader.patch.contains("Public truncated patch check") && reader.patch.hasSuffix("[此提交差异已截取]")
            picker.selectItem(at: 0); NSApp.sendAction(choose, to: picker.target, from: picker)
            checks["returningToActualTruncatedOverallRetainsNoticeAndBytes"] = reader.patch == truncatedOverall
            let finalBranch = try field("推送目标分支", in: embedded.pageContentView)
            finalBranch.stringValue = "bad branch"; finalBranch.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: finalBranch))
            checks["changingTargetClearsOldPatchAndNumberGutter"] = reader.patch.isEmpty && reader.readingReadback()["gutterVisible"] as? Bool == false && mode.isHidden && wrap.isHidden && embedded.workspaceReadback()["pushEnabled"] as? Bool == false
            checks["originalTaskDraftAndModelUsagePreserved"] = tasks.task(fixture.taskID)?.draft == "保留 Git 远端页面验收草稿" && requests == 0 && tasks.tasks.allSatisfy { $0.inputTokens == 0 && $0.outputTokens == 0 && $0.modelReceipts?.isEmpty != false }
            report["workspace"] = fixture.workspace.path; report["taskID"] = fixture.taskID; report["receiver"] = fixture.receiver.path
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["modelRequests"] = requests; report["appPID"] = ProcessInfo.processInfo.processIdentifier
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("git-remote-page-report.json"))
    }
}
