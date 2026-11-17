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

    private func gitReviewSubviews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(gitReviewSubviews) }

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
                checks[key + "-sharedActionsFitAt28Points"] = actions.count == 6 && actions.allSatisfy { $0.bounds.height == 28 && $0.font?.pointSize == 13 } && (r["checks"] as? [String: Bool])?["gitActionsFitWorkspace"] == true
                let visibleLabel = fileList.view(atColumn: 0, row: fileList.selectedRow, makeIfNecessary: true) as? NSTextField
                checks[key + "-readableDiffAndVisibleFileList"] = viewer.bounds.height >= 80 && viewer.bounds.width >= 230 && fileList.enclosingScrollView?.bounds.height ?? 0 >= 32 && viewer.patch.contains("+selected-working-preserved") && visibleLabel?.font?.pointSize == 13
                checks[key + "-outlinedCommitInputFits"] = message.outlined && message.bounds.height == 32 && !message.hasAmbiguousLayout
                let patch = viewer.patch
                let actualReader = viewer.readingReadback()
                checks[key + "-unifiedNumbersMatchActualGitPatch"] = actualReader["rulerVisible"] as? Bool == true && viewer.text.records.contains { $0.old == 1 && $0.kind == .removed } && viewer.text.records.contains { $0.new == 1 && $0.kind == .added }
                if let ruler = viewer.text.enclosingScrollView?.verticalRulerView {
                    let width = Int(ceil(ruler.bounds.width)) + 40
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    NSColor.magenta.setFill(); NSRect(x: 0, y: 0, width: width, height: 80).fill()
                    let offset = NSAffineTransform(); offset.translateX(by: 20, yBy: 20); offset.concat()
                    ruler.drawHashMarksAndLabels(in: ruler.bounds.insetBy(dx: -20, dy: -20))
                    NSGraphicsContext.restoreGraphicsState()
                    func sentinel(_ x: Int) -> Bool {
                        guard let color = bitmap.colorAt(x: x, y: 40)?.usingColorSpace(.deviceRGB) else { return false }
                        return color.redComponent > 0.99 && color.greenComponent < 0.01 && color.blueComponent > 0.99
                    }
                    checks[key + "-actualRulerDrawingCannotPaintOutsideItsBounds"] = sentinel(8) && sentinel(width - 8) && !sentinel(24)
                } else { checks[key + "-actualRulerDrawingCannotPaintOutsideItsBounds"] = false }
                let longText = String(repeating: "完整中文 🐋 and public content ", count: 16)
                let readerPatch = "diff --git a/public.txt b/public.txt\n--- a/public.txt\n+++ b/public.txt\n@@ -99999,3 +100001,4 @@\n unchanged 🐋\r\n-old value\r\n+" + longText + "\r\n+extra value\r\n last value\r\n\\ No newline at end of file\n"
                viewer.show(readerPatch, oldTitle: "原版本", newTitle: "新版本"); await settle()
                let records = viewer.text.records, reading = viewer.readingReadback(), fragments = viewer.text.fragments(in: viewer.text.bounds)
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
                checks[key + "-plainStatusDoesNotShowPhantomLineNumbers"] = viewer.readingReadback()["rulerVisible"] as? Bool == false && viewer.patch == "此来源没有变更"
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
        owner.makeFirstResponder(nil); message.stringValue = ""
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
