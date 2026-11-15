import AppKit

@MainActor extension AppDelegate {
    struct ChildRecoveryFixture: Codable {
        var taskID: String, otherID: String, windowID: String
        var file: String, secondFile: String, guide: String, base: String
        var firstTab: String, otherTab: String, floatingTab: String, browserTab: String
        var first: AgentVideoWindow.RecoveryState, other: AgentVideoWindow.RecoveryState, floating: AgentVideoWindow.RecoveryState
        var firstInline: AgentVideoPlayback, otherInline: AgentVideoPlayback
        var annotation: AgentBrowserRecoveryState.Annotation
        var sourceHashes: [String: String]
    }
    func runChildRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("子窗口恢复验收禁止模型请求") }
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let fixtureURL = output.appendingPathComponent("child-recovery-fixture.json"), journal = AgentWorkspaceRecovery(profile: store.directory)
            func layout() throws -> AgentWorkspaceRecovery.Window {
                guard let id = control.workspaceSession?.id, let value = try journal.loadWindow(id) else { throw PetError("子窗口布局未保存") }; return value.value
            }
            func record(_ id: String, _ file: String) throws -> AgentRecordWindow {
                if let page = control.taskWorkspace.recoveryController(taskID: id, root: .document(file)) as? AgentRecordWindow { return page }
                guard let page = control.workspaceSession?.floatingControllers.compactMap({ $0 as? AgentRecordWindow }).first(where: { $0.belongsToTasks([id]) && $0.workspaceDocumentURL?.path == file }) else { throw PetError("子窗口父文档未恢复") }; return page
            }
            func child(_ record: AgentRecordWindow) async throws -> AgentVideoWindow.RecoveryState {
                guard let value = try AgentRecordWindow.recoveryState(await record.captureWorkspaceRecovery()).videoWindow else { throw PetError("独立视频缺少恢复记录") }; return value
            }
            func decodedChild(_ record: AgentRecordWindow) async throws -> [String: Any] {
                var state: [String: Any] = [:]
                for _ in 0..<150 {
                    state = await record.videoPreviewReadback()
                    if let value = (state["separatePlayer"] as? [String: Any])?["player"] as? [String: Any], value["restoreReady"] as? Bool == true,
                       (value["readyState"] as? Int ?? 0) >= ((value["time"] as? Double ?? 0) > 0 ? 2 : 1), value["seeking"] as? Bool == false, (value["error"] as? Int ?? 0) == 0 { return state }
                    await wait(0.05)
                }
                report["decoderFailure"] = state; throw PetError("独立视频未实际解码就绪")
            }
            func matches(_ actual: [String: Any], _ expected: AgentVideoWindow.RecoveryState) -> Bool {
                guard let source = actual["separatePlayer"] as? [String: Any], let player = source["player"] as? [String: Any], let saved = expected.playback else { return false }
                return source["sourceHash"] as? String == saved.hash && player["paused"] as? Bool == true &&
                    abs((player["time"] as? Double ?? -1) - saved.time) < 0.12 && player["rate"] as? Double == saved.rate && player["volume"] as? Double == saved.volume && player["muted"] as? Bool == saved.muted
            }
            func eventually(_ test: () -> Bool) async -> Bool { for _ in 0..<100 { if test() { return true }; await wait(0.05) }; return test() }
            let fixture: ChildRecoveryFixture
            if stage == "seed" {
                let workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path)
                let file = try files.resolve("media/flower.mp4"), secondFile = try files.resolve("media/flower.webm"), guide = try files.resolve("README.md")
                let input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("browser-input.json"))) as! [String: String]
                guard let base = input["url"], URL(string: base)?.host == "127.0.0.1" else { throw PetError("仅使用本机公开验收页面") }
                let firstID = tasks.create(title: "主任务子窗口", workspace: workspace.path, mode: .ask), otherID = tasks.create(title: "另一任务子窗口", workspace: workspace.path)
                for id in [firstID, otherID] { tasks.update(id) { $0.draft = "保留任务输入 PUBLIC_CHILD_DRAFT_417" } }
                control.showAgentTask(firstID); control.show(tab: "chat"); control.showTaskDocument(file.path)
                let first = try record(firstID, file.path)
                _ = await first.checkVideoWorkspace(time: 0.85)
                _ = await first.checkVideoWorkspace(action: "new-window", childFrame: NSRect(x: 120, y: 180, width: 780, height: 540))
                _ = try await decodedChild(first)
                _ = await first.checkVideoWorkspace(action: "separate", time: 2.35, rate: 1.5, volume: 0.35, muted: true)
                control.showTaskDocument(secondFile.path)
                let floating = try record(firstID, secondFile.path); try control.presentArtifactWindow(floating, taskID: firstID)
                _ = await floating.checkVideoWorkspace(time: 1.1)
                _ = await floating.checkVideoWorkspace(action: "new-window", childFrame: NSRect(x: 260, y: 220, width: 640, height: 480))
                _ = try await decodedChild(floating)
                _ = await floating.checkVideoWorkspace(action: "separate", time: 3.15, rate: 0.75, volume: 0.6, muted: false)
                let browser = try tasks.browser.show(taskID: firstID, title: "子窗口标注")
                _ = try await browser.open(URL(string: base + "form")!)
                await browser.checkWorkspace("separate"); await browser.checkWorkspace("annotate")
                guard let annotation = browser.checkAnnotation else { throw PetError("实际网页截图标注未打开") }
                await annotation.checkWorkspace(note: "保留标注 PUBLIC_CHILD_NOTE_618 中文😀", mark: true, selection: NSRange(location: 5, length: 3))
                annotation.window?.setFrame(NSRect(x: 340, y: 160, width: 800, height: 560), display: true)
                await browser.checkWorkspace("separate")
                checks["rehostingBrowserKeepsAnnotationIndependent"] = browser.settingsHostWindow != nil && annotation.hasIndependentWindow && annotation.window?.isVisible == true
                control.showAgentTask(otherID); control.showTaskDocument(file.path)
                let other = try record(otherID, file.path)
                _ = await other.checkVideoWorkspace(time: 1.25)
                _ = await other.checkVideoWorkspace(action: "new-window", childFrame: NSRect(x: 500, y: 150, width: 720, height: 500))
                _ = try await decodedChild(other)
                _ = await other.checkVideoWorkspace(action: "separate", time: 4.1, rate: 1.25, volume: 0.8, muted: false)
                control.showTaskDocument(guide.path)
                guard await flushWorkspaceWindows(), let windowID = control.workspaceSession?.id else { throw PetError("子窗口初始状态未保存") }
                let saved = try layout(), firstTab = saved.tasks.first(where: { $0.taskID == firstID })!.tabs.first(where: { $0.root == "document:" + file.path })!, otherTab = saved.tasks.first(where: { $0.taskID == otherID })!.tabs.first(where: { $0.root == "document:" + file.path })!, floatingTab = saved.floating.first(where: { $0.taskID == firstID && $0.tab.root == "document:" + secondFile.path })!, browserTab = saved.tasks.first(where: { $0.taskID == firstID })!.tabs.first(where: { $0.root == "browser" })!
                let firstPage = try AgentRecordWindow.recoveryState(await first.captureWorkspaceRecovery()), otherPage = try AgentRecordWindow.recoveryState(await other.captureWorkspaceRecovery())
                guard let firstInline = firstPage.video, let otherInline = otherPage.video else { throw PetError("父页与独立视频没有分别记录位置") }
                fixture = .init(taskID: firstID, otherID: otherID, windowID: windowID, file: file.path, secondFile: secondFile.path, guide: guide.path, base: base,
                    firstTab: firstTab.id, otherTab: otherTab.id, floatingTab: floatingTab.tab.id, browserTab: browserTab.id,
                    first: try await child(first), other: try await child(other), floating: try await child(floating), firstInline: firstInline, otherInline: otherInline,
                    annotation: try annotation.captureWorkspaceRecovery(), sourceHashes: try Dictionary(uniqueKeysWithValues: [file, secondFile, guide].map { ($0.path, try files.fileHash($0)) }))
                checks["inactiveTaskAndUnselectedParentKeepEagerHints"] = firstTab.hasIndependentChild == true && otherTab.hasIndependentChild == true && browserTab.hasIndependentChild == true && saved.taskID == otherID && saved.tasks.first(where: { $0.taskID == otherID })?.selected == "document:" + guide.path
                checks["inlineAndChildPositionsRemainIndependent"] = abs(firstInline.time - 0.85) < 0.12 && abs((fixture.first.playback?.time ?? -1) - 2.35) < 0.12 && abs(otherInline.time - 1.25) < 0.12 && abs((fixture.other.playback?.time ?? -1) - 4.1) < 0.12
                checks["floatingParentRetainsOwnChildAndIdentity"] = fixture.floating.frame?.width == 640 && floatingTab.tab.hasIndependentChild == true
                checks["annotationIncludesOriginalPixelsMarksNoteSelectionAndFrame"] = !fixture.annotation.image.isEmpty && fixture.annotation.marks.count == 1 && fixture.annotation.note.contains("PUBLIC_CHILD_NOTE_618") && fixture.annotation.selection?.location == 5 && fixture.annotation.frame?.width == 800
                _ = await first.checkVideoWorkspace(action: "separate", time: 2.55)
                checks["childSeekAutosavesWithoutExplicitFlush"] = await eventually {
                    let path = store.directory.appendingPathComponent("workspace-recovery/" + windowID + "/pages/" + firstTab.id + ".json")
                    guard let data = try? Data(contentsOf: path), let page = try? JSONDecoder().decode(AgentWorkspaceRecovery.Page.self, from: data), let state = try? AgentRecordWindow.recoveryState(page) else { return false }
                    return abs((state.videoWindow?.playback?.time ?? -1) - 2.55) < 0.02
                }
                let path = store.directory.appendingPathComponent("workspace-recovery/" + windowID + "/pages/" + firstTab.id + ".json"), original = try Data(contentsOf: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
                _ = await first.checkVideoWorkspace(action: "separate", time: 2.75)
                let refused = !(await flushWorkspaceWindows()), retained = try Data(contentsOf: path), live = try await child(first)
                checks["readOnlyChildFailureRetainsOldBytesAndLivePosition"] = refused && retained == original && abs((live.playback?.time ?? -1) - 2.75) < 0.02
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                checks["childCheckpointRetrySavesWithoutAnotherEdit"] = await flushWorkspaceWindows()
                let valid = try await first.captureWorkspaceRecovery()
                var legacy = valid, object = try JSONSerialization.jsonObject(with: valid.state) as! [String: Any]; object.removeValue(forKey: "videoWindow"); legacy.state = try JSONSerialization.data(withJSONObject: object)
                checks["legacyRecordWithoutChildStillDecodes"] = try AgentRecordWindow.recoveryState(legacy).videoWindow == nil
                for key in ["version", "frame", "file", "playback", "unknown"] {
                    var raw = try JSONSerialization.jsonObject(with: valid.state) as! [String: Any], child = raw["videoWindow"] as! [String: Any]
                    switch key {
                    case "version": child[key] = 2
                    case "frame": child[key] = ["x": 0, "y": 0, "width": 0, "height": 500]
                    case "file": child[key] = fixture.guide
                    case "playback": var playback = child[key] as! [String: Any]; playback["rate"] = 0; child[key] = playback
                    default: child[key] = true
                    }
                    raw["videoWindow"] = child; var bad = valid; bad.state = try JSONSerialization.data(withJSONObject: raw)
                    do { _ = try AgentRecordWindow.recoveryState(bad); checks["rejectInvalidChild-" + key] = false } catch { checks["rejectInvalidChild-" + key] = true }
                }
                var latest = fixture; latest.first = try await child(first)
                try JSONEncoder().encode(latest).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(ChildRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows(); guard await flushWorkspaceWindows() else { throw PetError("子窗口恢复未完成") }
                if stage == "invalid" || stage == "retry" {
                    let path = store.directory.appendingPathComponent("workspace-recovery/" + fixture.windowID + "/pages/" + fixture.firstTab + ".json")
                    checks["unsupportedChildKeepsParentCold"] = control.taskWorkspace.recoveryController(taskID: fixture.taskID, root: .document(fixture.file)) == nil
                    checks["unsupportedChildOriginalBytesRetained"] = try Data(contentsOf: path) == Data(contentsOf: output.appendingPathComponent("future-child-input.json"))
                    if stage == "retry" {
                        try Data(contentsOf: output.appendingPathComponent("original-child-page.json")).write(to: path)
                        restoreFloatingWorkspaceWindows(); guard await flushWorkspaceWindows() else { throw PetError("子窗口菜单重试未完成") }
                        let retried = try await decodedChild(record(fixture.taskID, fixture.file))
                        checks["menuRetryRestoresChildWithoutSelectingItsParent"] = matches(retried, fixture.first) && control.agentTaskID == fixture.otherID
                    }
                } else if stage == "closed" {
                    let saved = try layout()
                    checks["explicitlyClosedChildrenNeverResurrect"] = saved.floating.isEmpty && saved.tasks.flatMap(\.tabs).allSatisfy { $0.hasIndependentChild != true } && tasks.browser.sessions[fixture.taskID] == nil
                    let first = try record(fixture.taskID, fixture.file)
                    checks["inlineParentRemainsAfterItsChildWasClosed"] = !first.hasIndependentVideoWindow
                } else {
                    let first = try record(fixture.taskID, fixture.file), other = try record(fixture.otherID, fixture.file), floating = try record(fixture.taskID, fixture.secondFile)
                    guard let browser = tasks.browser.sessions[fixture.taskID], let annotation = browser.recoveryAnnotation else { throw PetError("标注父页或独立子窗口未恢复") }
                    let a = try await decodedChild(first), b = try await decodedChild(other), c = try await decodedChild(floating), saved = try layout()
                    if !interactive {
                        checks["eagerChildrenDoNotChangeSelectedTaskOrTab"] = control.agentTaskID == fixture.otherID && control.taskWorkspace.selectedRoot == .document(fixture.guide) && saved.tasks.first(where: { $0.taskID == fixture.otherID })?.selected == "document:" + fixture.guide
                        checks["sameFileChildrenRestoreToCorrectTasks"] = matches(a, fixture.first) && matches(b, fixture.other)
                        checks["floatingParentChildRestoresPausedPlayback"] = matches(c, fixture.floating)
                        let firstChild = try await child(first), otherChild = try await child(other), floatingChild = try await child(floating)
                        checks["allChildGeometryRestores"] = firstChild.frame == fixture.first.frame && otherChild.frame == fixture.other.frame && floatingChild.frame == fixture.floating.frame
                    } else {
                        checks["observerHasAllIndependentChildrenReady"] = first.hasIndependentVideoWindow && other.hasIndependentVideoWindow && floating.hasIndependentVideoWindow && annotation.hasIndependentWindow
                    }
                    let restored = try annotation.captureWorkspaceRecovery()
                    if !interactive {
                        checks["annotationPixelsMarksAndNoteRemainExact"] = restored.image == fixture.annotation.image && restored.marks == fixture.annotation.marks && restored.note == fixture.annotation.note && restored.selection == fixture.annotation.selection
                        checks["rehostedAnnotationRestoresAsSeparateWindow"] = browser.settingsHostWindow != nil && annotation.hasIndependentWindow && annotation.window?.isVisible == true && restored.frame == fixture.annotation.frame
                    }
                    let firstState = try AgentRecordWindow.recoveryState(await first.captureWorkspaceRecovery()), otherState = try AgentRecordWindow.recoveryState(await other.captureWorkspaceRecovery())
                    checks["inlinePositionsAreNotReplacedByChildPositions"] = abs((firstState.video?.time ?? -1) - fixture.firstInline.time) < 0.12 && abs((otherState.video?.time ?? -1) - fixture.otherInline.time) < 0.12
                    report["first"] = a; report["other"] = b; report["floating"] = c; report["annotation"] = annotation.workspaceReadback()
                    if stage == "close" {
                        _ = await first.checkVideoWorkspace(action: "close-child")
                        checks["explicitChildCloseAutosavesWithoutClosingParent"] = await eventually {
                            let path = store.directory.appendingPathComponent("workspace-recovery/" + fixture.windowID + "/pages/" + fixture.firstTab + ".json")
                            guard let data = try? Data(contentsOf: path), let page = try? JSONDecoder().decode(AgentWorkspaceRecovery.Page.self, from: data), let value = try? AgentRecordWindow.recoveryState(page) else { return false }; return value.videoWindow == nil && !first.hasIndependentVideoWindow
                        }
                        browser.close(); control.showAgentTask(fixture.taskID); control.taskWorkspace.checkClose(.browser)
                        checks["parentBrowserCloseClosesActualAnnotationWindow"] = annotation.workspaceIsClosed && annotation.window?.isVisible != true
                        let floatingSnapshot = (c["separatePlayer"] as? [String: Any])?["snapshotFolder"] as? String ?? ""
                        floating.window?.performClose(nil)
                        let floatingClosed = await floating.videoPreviewReadback()
                        checks["floatingParentCloseReleasesChildWindowAndSnapshot"] = !floating.hasIndependentVideoWindow && floatingClosed["separateWindowVisible"] as? Bool != true && !floatingSnapshot.isEmpty && !FileManager.default.fileExists(atPath: floatingSnapshot)
                        let otherSnapshot = (b["separatePlayer"] as? [String: Any])?["snapshotFolder"] as? String ?? ""
                        control.showAgentTask(fixture.otherID); control.taskWorkspace.checkClose(.document(fixture.file))
                        checks["taskParentCloseReleasesItsChildWindow"] = await eventually { control.taskWorkspace.recoveryController(taskID: fixture.otherID, root: .document(fixture.file)) == nil && !other.hasIndependentVideoWindow && !otherSnapshot.isEmpty && !FileManager.default.fileExists(atPath: otherSnapshot) }
                        guard await flushWorkspaceWindows() else { throw PetError("明确关闭子窗口尚未保存") }
                    }
                }
            }
            let files = try AgentFiles(workspace: URL(fileURLWithPath: fixture.file).deletingLastPathComponent().deletingLastPathComponent().path)
            checks["originalProjectFilesRemainExact"] = try fixture.sourceHashes.allSatisfy { try files.fileHash(URL(fileURLWithPath: $0.key)) == $0.value }
            checks["bothTaskDraftsAndNoRepliesRemainExact"] = [fixture.taskID, fixture.otherID].allSatisfy { tasks.task($0)?.draft == "保留任务输入 PUBLIC_CHILD_DRAFT_417" && tasks.task($0)?.messages.isEmpty == true && (tasks.task($0)?.modelReceipts ?? []).isEmpty }
            checks["allLatestChildStatesHaveCheckpoints"] = await flushWorkspaceWindows(); checks["noModels"] = requests == 0
            report["stage"] = stage
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "child-recovery-ui-ready.json" : "child-recovery-report.json"))
    }
}
