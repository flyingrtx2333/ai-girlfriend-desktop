import AppKit

@MainActor extension AppDelegate {
    struct VideoWorkspaceFixture { let taskID: String, otherID: String, workspace: URL, mp4: URL, webm: URL, large: URL, broken: URL, guide: URL }
    func prepareVideoWorkspaceUI(_ output: URL) throws -> VideoWorkspaceFixture {
        guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("视频工作区验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
        let root = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: root.path)
        let mp4 = try files.resolve("media/flower.mp4"), webm = try files.resolve("media/flower.webm"), large = try files.resolve("media/flower-large.mp4"), broken = try files.resolve("media/broken.mp4"), guide = try files.resolve("docs/VIDEO.md")
        let first = tasks.create(title: "视频文件标签页", workspace: root.path, mode: .ask), other = tasks.create(title: "另一视频任务", workspace: root.path)
        tasks.update(first) { $0.artifacts = [mp4.path, webm.path, large.path, broken.path, guide.path]; $0.sources = [webm.absoluteString]; $0.draft = "保留视频任务输入。" }
        tasks.update(other) { $0.artifacts = [mp4.path]; $0.draft = "保留另一视频任务输入。" }
        let fixture = VideoWorkspaceFixture(taskID: first, otherID: other, workspace: root, mp4: mp4, webm: webm, large: large, broken: broken, guide: guide)
        let data: [String: Any] = ["taskID": first, "otherID": other, "workspace": root.path, "mp4": mp4.path, "webm": webm.path, "large": large.path, "broken": broken.path, "guide": guide.path]
        try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("video-workspace-fixtures.json"))
        control.showAgentTask(first); control.show(tab: "chat"); control.showTaskDocument(mp4.path); return fixture
    }
    func reopenVideoWorkspaceUI(_ output: URL) throws {
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("video-workspace-fixtures.json"))) as? [String: String]
        guard let data, let id = data["taskID"], let mp4 = data["mp4"], agentStore?.task(id) != nil else { throw PetError("保留的视频验收资料不存在") }
        control.showAgentTask(id); control.show(tab: "chat"); control.showTaskDocument(mp4)
    }
    func runVideoWorkspaceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            let binary = Bundle.main.executableURL!; report["appPID"] = getpid(); report["binaryHash"] = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("视频工作区验收禁止模型请求") }
            let f = try prepareVideoWorkspaceUI(output), host = control.taskWorkspace, files = try AgentFiles(workspace: f.workspace.path)
            let sourceHashes = try Dictionary(uniqueKeysWithValues: [f.mp4, f.webm, f.large, f.broken, f.guide].map { ($0.path, try files.fileHash($0)) })
            func video(_ record: AgentRecordWindow) async -> [String: Any] {
                var result: [String: Any] = [:]
                for _ in 0..<100 {
                    result = await record.videoPreviewReadback()
                    let player = result["player"] as? [String: Any] ?? [:]
                    if (player["readyState"] as? Int ?? 0) > 0 || (player["error"] as? Int ?? 0) > 0 || result["webPresent"] as? Bool == false { break }
                    await wait(0.05)
                }; return result
            }
            guard let first = host.currentController as? AgentRecordWindow else { throw PetError("视频未进入文件标签页") }
            let initial = await video(first), initialPlayer = initial["player"] as? [String: Any] ?? [:]
            checks["mp4UsesActualDecodedMediaAndReadonlyTaskTab"] = (initialPlayer["duration"] as? Double ?? 0) > 5 && initialPlayer["width"] as? Int == 960 && initialPlayer["height"] as? Int == 540 && initialPlayer["paused"] as? Bool == true && initial["saveVisible"] as? Bool == false && initial["textEditable"] as? Bool == false
            checks["firstVideoHasOwnFileTabAndExactSnapshot"] = host.selectedRoot == .document(f.mp4.path) && initial["sourceHash"] as? String == sourceHashes[f.mp4.path] && first.window?.isVisible == false
            let firstSnapshot = initial["snapshotFolder"] as? String ?? ""
            checks["actualSnapshotUsesIndependentExternalTemporaryStorage"] = URL(fileURLWithPath: firstSnapshot).resolvingSymlinksInPath().path.hasPrefix(output.appendingPathComponent("tmp").resolvingSymlinksInPath().path + "/")
            for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                control.window?.appearance = NSAppearance(named: theme)
                for (kind, size) in [("split", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                    control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                    let state = await first.workspaceReadback(), v = await video(first), player = v["player"] as? [String: Any] ?? [:]
                    for (key, value) in state["checks"] as? [String: Bool] ?? [:] { checks[appearance + "-" + kind + "-" + key] = value }
                    checks[appearance + "-" + kind + "-actualPlayerFits"] = (player["clientWidth"] as? Int ?? 0) >= 400 && (player["clientHeight"] as? Int ?? 0) >= 200
                    let workspace = await control.taskWorkspaceReadback(); report[appearance + "-" + kind] = workspace
                    checks[appearance + "-" + kind + "-taskInputRemains"] = workspace["draft"] as? String == "保留视频任务输入。" && workspace["selectedTask"] as? String == f.taskID
                }
            }
            _ = await first.checkVideoWorkspace(time: 1.25); await wait(0.15)
            control.showTaskDocument(f.webm.path)
            guard let secondVideo = host.currentController as? AgentRecordWindow else { throw PetError("WebM 未打开") }
            let webm = await video(secondVideo), webmPlayer = webm["player"] as? [String: Any] ?? [:]
            checks["webmUsesSeparateTabAndActualDecoder"] = secondVideo !== first && host.selectedRoot == .document(f.webm.path) && (webmPlayer["duration"] as? Double ?? 0) > 5 && webmPlayer["width"] as? Int == 960 && webm["sourceHash"] as? String == sourceHashes[f.webm.path]
            host.checkSelect(.document(f.mp4.path)); let retained = await video(first), retainedPlayer = retained["player"] as? [String: Any] ?? [:]
            checks["switchingTabsPreservesPausedPositionAndSnapshot"] = host.currentController === first && retained["snapshotFolder"] as? String == firstSnapshot && abs((retainedPlayer["time"] as? Double ?? 0) - 1.25) < 0.15 && retainedPlayer["paused"] as? Bool == true
            control.showAgentTask(f.otherID); control.showTaskDocument(f.mp4.path)
            guard let other = host.currentController as? AgentRecordWindow else { throw PetError("另一任务视频未打开") }
            let otherState = await video(other)
            checks["sameVideoInTwoTasksHasIndependentPlayerAndSnapshot"] = other !== first && otherState["snapshotFolder"] as? String != firstSnapshot
            _ = await other.checkVideoWorkspace(time: 2.5); await wait(0.1); control.showAgentTask(f.taskID)
            let original = await video(first)
            checks["taskReturnRestoresOriginalVideoPosition"] = host.currentController === first && abs(((original["player"] as? [String: Any])?["time"] as? Double ?? 0) - 1.25) < 0.15
            control.openAgentRecordItem(section: 1, value: f.large.path)
            guard let large = host.currentController as? AgentRecordWindow else { throw PetError("大视频未打开") }
            let largeState = await video(large)
            let largeBytes = try Data(contentsOf: f.large).count
            checks["artifactEntryOpensRealVideoLargerThanTextLimit"] = host.selectedRoot == .document(f.large.path) && largeBytes > 2_000_000 && largeState["sourceHash"] as? String == sourceHashes[f.large.path] && ((largeState["player"] as? [String: Any])?["width"] as? Int) == 960
            control.presentAgentRecords(section: 1)
            guard let records = host.rootController(.records) as? AgentRecordWindow else { throw PetError("产物记录未打开") }
            let inline = await video(records)
            checks["recordActionNamesTheFileTabInsteadOfNewWindow"] = inline["openTitle"] as? String == "打开标签页"
            _ = await records.checkVideoWorkspace(action: "open")
            checks["recordOpenActionUsesExistingVideoFileTab"] = host.currentController === first && host.selectedRoot == .document(f.mp4.path)
            control.presentAgentRecords(section: 1)
            records.selectItem(section: 1, value: f.webm.path)
            checks["recordSelectionUsesVideoFileTab"] = host.selectedRoot == .document(f.webm.path) && host.currentController === secondVideo
            host.checkSelect(.records); records.selectItem(section: 1, value: f.guide.path)
            let pickedGuide = await records.workspaceReadback()
            checks["recordFilePickerSelectsRequestedDocumentWithoutOpeningFirstVideo"] = host.currentController === records && pickedGuide["selection"] as? String == f.guide.path
            records.selectSection(2); host.checkSelect(.records); records.selectItem(section: 1, value: f.guide.path)
            let pickedSectionGuide = await records.workspaceReadback()
            checks["recordSectionChangeSelectsRequestedDocumentWithoutOpeningFirstVideo"] = host.currentController === records && pickedSectionGuide["selection"] as? String == f.guide.path
            control.showTaskDocument(f.guide.path)
            guard let guide = host.currentController as? AgentRecordWindow else { throw PetError("视频说明未打开") }
            let guideSource = try String(contentsOf: f.guide, encoding: .utf8), draft = guideSource + "\n视频导航时保留的草稿。\n"
            await guide.checkTaskDocument(text: draft)
            let readonlyGuide = await guide.workspaceReadback(); report["readonlyGuide"] = readonlyGuide
            checks["askModeKeepsMarkdownSourceReadOnly"] = readonlyGuide["sourceEditable"] as? Bool == false && readonlyGuide["draft"] as? String == guideSource
            _ = await guide.checkVideoWorkspace(link: URL(string: "../media/flower.mp4")!)
            checks["readonlyMarkdownVideoLinkOpensFileTab"] = host.selectedRoot == .document(f.mp4.path) && host.currentController === first
            control.showAgentTask(f.otherID); control.showTaskDocument(f.guide.path)
            guard let editableGuide = host.currentController as? AgentRecordWindow else { throw PetError("可编辑的视频说明未打开") }
            await editableGuide.checkTaskDocument(text: draft)
            _ = await editableGuide.checkVideoWorkspace(link: URL(string: "../media/flower.mp4")!)
            let guideDraft = await editableGuide.workspaceReadback(); report["editableGuideAfterVideoLink"] = guideDraft
            checks["markdownVideoLinkOpensFileTabWithoutDiscardingSourceDraft"] = host.selectedRoot == .document(f.mp4.path) && host.currentController === other && guideDraft["draft"] as? String == draft
            host.checkSelect(.document(f.guide.path)); await editableGuide.checkTaskDocument(text: guideSource, action: "save")
            control.showAgentTask(f.taskID)
            host.checkSelect(.document(f.mp4.path)); _ = await first.checkVideoWorkspace(action: "new-window")
            let detached = await first.videoPreviewReadback()
            checks["newWindowRemainsExplicitAndTaskOwned"] = detached["separateWindowVisible"] as? Bool == true && host.currentController === first && detached["openTitle"] as? String == "新窗口"
            host.checkSelect(.document(f.webm.path)); await wait(0.1)
            let inactive = await first.videoPreviewReadback()
            checks["navigationPausesExplicitSeparatePlayer"] = ((inactive["separatePlayer"] as? [String: Any])?["player"] as? [String: Any])?["paused"] as? Bool == true
            host.checkSelect(.document(f.mp4.path)); host.checkHide(); await wait(0.1)
            let hidden = await video(first)
            checks["hideRetainsVideoAndPausesPlayback"] = !host.requested && hidden["snapshotFolder"] as? String == firstSnapshot
            control.showTaskDocument(f.mp4.path)
            let oldBytes = try Data(contentsOf: f.mp4), changedBytes = oldBytes + Data([0, 0, 0, 8, 102, 114, 101, 101])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.mp4.path); try changedBytes.write(to: f.mp4)
            _ = await first.checkVideoWorkspace(action: "refresh"); let refreshed = await video(first)
            checks["refreshUsesNewSnapshotOfActualCurrentFile"] = refreshed["sourceHash"] as? String == AgentFiles.hash(changedBytes) && refreshed["snapshotFolder"] as? String != firstSnapshot && !FileManager.default.fileExists(atPath: firstSnapshot)
            try oldBytes.write(to: f.mp4); try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: f.mp4.path)
            _ = await first.checkVideoWorkspace(action: "refresh"); let restored = await video(first), finalSnapshot = restored["snapshotFolder"] as? String ?? ""
            checks["refreshCanReturnToOriginalBytes"] = restored["sourceHash"] as? String == sourceHashes[f.mp4.path]
            host.checkClose(.document(f.mp4.path)); for _ in 0..<40 { if host.rootController(.document(f.mp4.path)) == nil { break }; await wait(0.05) }
            let closed = await first.videoPreviewReadback()
            checks["closingVideoReleasesItsSnapshotAndSeparateWindow"] = host.rootController(.document(f.mp4.path)) == nil && !FileManager.default.fileExists(atPath: finalSnapshot) && closed["separateWindowVisible"] as? Bool != true
            control.showTaskDocument(f.broken.path); guard let broken = host.currentController as? AgentRecordWindow else { throw PetError("损坏文件未显示错误页") }
            let brokenState = await video(broken)
            checks["malformedVideoHasActualDecoderErrorWithoutEditableText"] = ((brokenState["player"] as? [String: Any])?["error"] as? Int ?? 0) > 0 && brokenState["saveVisible"] as? Bool == false
            let before = host.currentController
            control.showTaskDocument(output.appendingPathComponent("outside.mp4").path)
            checks["outsideWorkspaceDoesNotCreateVideoTab"] = host.currentController === before
            checks["allSourceFileBytesRemainOriginal"] = try sourceHashes.allSatisfy { try files.fileHash(URL(fileURLWithPath: $0.key)) == $0.value }
            checks["bothTaskInputDraftsRemainExact"] = tasks.task(f.taskID)?.draft == "保留视频任务输入。" && tasks.task(f.otherID)?.draft == "保留另一视频任务输入。"
            checks["noModelsOrAssistantMessages"] = requests == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.messages.isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["sourceHashes"] = sourceHashes; report["workspace"] = f.workspace.path; host.finish()
            if CommandLine.arguments.contains("--knowledge-video-check") { checks.merge(try await runKnowledgeVideoPageCheck(output, fixture: f)) { _, new in new } }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["modelRequests"] = requests
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("video-workspace-report.json"))
    }
}
