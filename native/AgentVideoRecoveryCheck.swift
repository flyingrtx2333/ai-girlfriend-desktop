import AppKit

@MainActor extension AppDelegate {
    struct VideoRecoveryFixture: Codable {
        var taskID: String, otherID: String, windowID: String, tabID: String, secondTabID: String, otherWindowID: String, otherTabID: String
        var file: String, secondFile: String, sourceFolders: [String]
        var first: AgentVideoPlayback, second: AgentVideoPlayback, other: AgentVideoPlayback
    }
    func runVideoRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("视频恢复验收禁止模型请求") }
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let fixtureURL = output.appendingPathComponent("video-recovery-fixture.json"), journal = AgentWorkspaceRecovery(profile: store.directory)
            let workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path)
            func decoded(_ record: AgentRecordWindow) async throws -> [String: Any] {
                var value: [String: Any] = [:]
                for _ in 0..<100 {
                    value = await record.videoPreviewReadback()
                    if let player = value["player"] as? [String: Any], (player["readyState"] as? Int ?? 0) > 0, (player["error"] as? Int ?? 0) == 0 { return value }
                    await wait(0.05)
                }
                throw PetError("实际视频未完成解码：" + (value["status"] as? String ?? ""))
            }
            func playback(_ record: AgentRecordWindow) async throws -> AgentVideoPlayback {
                let state = try AgentRecordWindow.recoveryState(await record.captureWorkspaceRecovery())
                guard let video = state.video else { throw PetError("实际播放器缺少位置检查点") }; return video
            }
            func saved(_ window: String, _ tab: String, _ task: String) throws -> AgentWorkspaceRecovery.LoadedPage {
                guard let value = try journal.loadPage(windowID: window, pageID: tab, taskID: task) else { throw PetError("视频检查点不存在") }; return value
            }
            func eventually(_ predicate: () -> Bool) async -> Bool {
                for _ in 0..<100 { if predicate() { return true }; await wait(0.05) }; return predicate()
            }
            func matches(_ state: [String: Any], _ expected: AgentVideoPlayback) -> Bool {
                guard let player = state["player"] as? [String: Any] else { return false }
                return state["sourceHash"] as? String == expected.hash && player["paused"] as? Bool == true &&
                    abs((player["time"] as? Double ?? -1) - expected.time) < 0.12 &&
                    (player["rate"] as? Double) == expected.rate && (player["volume"] as? Double) == expected.volume && player["muted"] as? Bool == expected.muted
            }
            let fixture: VideoRecoveryFixture
            if stage == "seed" {
                let file = try files.resolve("media/flower.mp4"), secondFile = try files.resolve("media/flower.webm")
                let id = tasks.create(title: "视频播放位置恢复", workspace: workspace.path, mode: .ask), other = tasks.create(title: "另一窗口的视频位置", workspace: workspace.path)
                tasks.update(id) { $0.artifacts = [file.path, secondFile.path]; $0.draft = "保留视频主任务 PUBLIC_VIDEO_DRAFT_417" }
                tasks.update(other) { $0.artifacts = [file.path]; $0.draft = "保留另一视频任务 PUBLIC_VIDEO_OTHER_618" }
                control.showAgentTask(id); control.show(tab: "chat"); control.showTaskDocument(file.path)
                guard let first = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("第一个视频未进入任务标签") }
                let initial = try await decoded(first)
                _ = await first.checkVideoWorkspace(time: 1.25, rate: 1.5, volume: 0.35, muted: true)
                control.showTaskDocument(secondFile.path)
                guard let second = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("第二个视频未打开") }
                let secondInitial = try await decoded(second)
                _ = await second.checkVideoWorkspace(time: 2.45, rate: 0.75, volume: 0.6, muted: false)
                openTaskWindow(other, from: control)
                guard let child = additionalTaskWindows.first(where: { $0.agentTaskID == other }) else { throw PetError("第二任务窗口未打开") }
                child.showTaskDocument(file.path)
                guard let otherVideo = child.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("独立任务视频未打开") }
                let otherInitial = try await decoded(otherVideo)
                _ = await otherVideo.checkVideoWorkspace(time: 3.25, rate: 1.25, volume: 0.8, muted: false)
                control.window?.makeKeyAndOrderFront(nil); control.taskWorkspace.checkSelect(.document(file.path))
                guard await flushWorkspaceWindows(), let windowID = control.workspaceSession?.id, let otherWindowID = child.workspaceSession?.id,
                      let layout = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == id }),
                      let tab = layout.tabs.first(where: { $0.root == "document:" + file.path }),
                      let secondTab = layout.tabs.first(where: { $0.root == "document:" + secondFile.path }),
                      let otherTab = child.taskWorkspace.recoveryLayouts.first?.tabs.first else { throw PetError("视频窗口检查点未保存") }
                let before = try saved(windowID, tab.id, id).saved.value
                _ = await first.checkVideoWorkspace(time: 1.65)
                checks["seekEventAutosavesWithoutExplicitFlush"] = await eventually {
                    guard let page = try? saved(windowID, tab.id, id), let state = try? AgentRecordWindow.recoveryState(page.saved.value) else { return false }
                    return abs((state.video?.time ?? -1) - 1.65) < 0.01
                }
                let path = store.directory.appendingPathComponent("workspace-recovery/" + windowID + "/pages/" + tab.id + ".json"), original = try Data(contentsOf: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
                _ = await first.checkVideoWorkspace(time: 1.85)
                let rejected = !(await flushWorkspaceWindows()), rejectedBytes = try Data(contentsOf: path), latest = try await playback(first)
                checks["readOnlyFailureRetainsOriginalAndLatestPlayerPosition"] = rejected && rejectedBytes == original && abs(latest.time - 1.85) < 0.01
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                checks["retryReadsLatestPlayerWithoutAnotherEdit"] = await flushWorkspaceWindows()
                let current = try AgentRecordWindow.recoveryState(saved(windowID, tab.id, id).saved.value)
                guard let firstPlayback = current.video else { throw PetError("视频位置重试后未保存") }
                fixture = .init(taskID: id, otherID: other, windowID: windowID, tabID: tab.id, secondTabID: secondTab.id, otherWindowID: otherWindowID, otherTabID: otherTab.id,
                    file: file.path, secondFile: secondFile.path, sourceFolders: [initial, secondInitial, otherInitial].compactMap { $0["snapshotFolder"] as? String },
                    first: firstPlayback, second: try await playback(second), other: try await playback(otherVideo))
                checks["twoTasksAndThreePlayersKeepIndependentPositions"] = abs(fixture.first.time - 1.85) < 0.01 && abs(fixture.second.time - 2.45) < 0.01 && abs(fixture.other.time - 3.25) < 0.01 && Set(fixture.sourceFolders).count == 3
                checks["positionsPinActualVideoHashes"] = try fixture.first.hash == files.fileHash(file) && fixture.second.hash == files.fileHash(secondFile) && fixture.other.hash == fixture.first.hash
                checks["videoRemainsReadOnlyInAskTask"] = initial["saveVisible"] as? Bool == false && initial["textEditable"] as? Bool == false && tasks.task(id)?.mode == .ask
                checks["allPlayersEligibleForHotExit"] = control.workspaceSession?.preservedEditors.count == 2 && child.workspaceSession?.preservedEditors.count == 1
                var legacy = before, object = try JSONSerialization.jsonObject(with: before.state) as! [String: Any]; object.removeValue(forKey: "video"); legacy.state = try JSONSerialization.data(withJSONObject: object)
                checks["legacyRecordWithoutPlaybackStillDecodes"] = try AgentRecordWindow.recoveryState(legacy).video == nil
                for (key, invalid) in [("version", 2 as Any), ("time", -1), ("duration", 0), ("rate", 0), ("volume", 2), ("hash", "not-a-hash"), ("unknown", true)] {
                    var bad = before, raw = try JSONSerialization.jsonObject(with: bad.state) as! [String: Any], video = raw["video"] as! [String: Any]
                    video[key] = invalid; raw["video"] = video; bad.state = try JSONSerialization.data(withJSONObject: raw)
                    do { _ = try AgentRecordWindow.recoveryState(bad); checks["rejectInvalidPlayback-" + key] = false } catch { checks["rejectInvalidPlayback-" + key] = true }
                }
                var wrong = before; wrong.taskID = other
                do { _ = try AgentRecordWindow.recoveryState(wrong); checks["wrongTaskCannotAdoptPlayback"] = false } catch { checks["wrongTaskCannotAdoptPlayback"] = true }
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(VideoRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows(); _ = await flushWorkspaceWindows()
                if ["invalid", "scope", "mismatch"].contains(stage) {
                    let original = try Data(contentsOf: output.appendingPathComponent(stage + "-video-input.json")), path = store.directory.appendingPathComponent("workspace-recovery/" + fixture.windowID + "/pages/" + fixture.tabID + ".json")
                    checks["unavailableOrUnsupportedPageStaysCold"] = control.taskWorkspace.recoveryController(taskID: fixture.taskID, root: .document(fixture.file)) == nil
                    checks["rejectedPageBytesRemainExact"] = try Data(contentsOf: path) == original
                } else if stage == "closed" {
                    checks["explicitlyClosedVideoRootsDoNotResurrect"] = taskControls.allSatisfy { $0.taskWorkspace.recoveryLayouts.allSatisfy { $0.tabs.isEmpty } }
                } else {
                    guard let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.otherWindowID }),
                          let first = control.taskWorkspace.currentController as? AgentRecordWindow, let otherVideo = child.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("两项视频窗口未恢复") }
                    let expected = stage == "legacy" ? AgentVideoPlayback(hash: fixture.first.hash, time: 0, duration: fixture.first.duration, rate: 1, volume: 1, muted: false) : fixture.first
                    let firstState = try await decoded(first), otherState = try await decoded(otherVideo)
                    checks["mainPlayerRestoresExpectedPausedPositionAndControls"] = matches(firstState, expected)
                    checks["otherWindowRestoresItsOwnPausedPositionAndControls"] = matches(otherState, fixture.other)
                    checks["persistentWindowAndTabIdentitiesRemainOwned"] = control.workspaceSession?.id == fixture.windowID && control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == fixture.taskID })?.tabs.map(\.id).contains(fixture.tabID) == true && child.agentTaskID == fixture.otherID
                    checks["newProcessUsesFreshPrivateSnapshot"] = !fixture.sourceFolders.contains(firstState["snapshotFolder"] as? String ?? "") && fixture.sourceFolders.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
                    control.taskWorkspace.checkSelect(.document(fixture.secondFile)); guard await flushWorkspaceWindows(), let second = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("未载入的第二视频标签未恢复") }
                    checks["coldSecondFormatRestoresItsOwnPosition"] = matches(try await decoded(second), fixture.second)
                    control.taskWorkspace.checkSelect(.document(fixture.file)); await wait(0.2)
                    let remainedFirst = try await decoded(first), remainedOther = try await decoded(otherVideo)
                    checks["restoredPlayersNeverAutoplay"] = matches(remainedFirst, expected) && matches(remainedOther, fixture.other)
                    if stage == "reopen", !interactive {
                        let file = URL(fileURLWithPath: fixture.file), original = try Data(contentsOf: file), changed = original + Data([0, 0, 0, 8, 102, 114, 101, 101])
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); try changed.write(to: file)
                        _ = await first.checkVideoWorkspace(action: "refresh"); let current = try await decoded(first)
                        checks["changedVideoDoesNotInheritOldPosition"] = current["sourceHash"] as? String == AgentFiles.hash(changed) && abs(((current["player"] as? [String: Any])?["time"] as? Double ?? -1)) < 0.01 && current["status"] as? String == "视频已变化，未恢复播放位置"
                        try original.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
                        _ = await first.checkVideoWorkspace(action: "refresh"); _ = try await decoded(first)
                        _ = await first.checkVideoWorkspace(time: fixture.first.time, rate: fixture.first.rate, volume: fixture.first.volume, muted: fixture.first.muted)
                        guard await flushWorkspaceWindows() else { throw PetError("原视频控制状态未恢复") }
                        let unavailable = output.appendingPathComponent("temporarily-unavailable.mp4"); try FileManager.default.moveItem(at: file, to: unavailable)
                        _ = await first.checkVideoWorkspace(action: "refresh"); let retained = try await playback(first)
                        let missingState = await first.videoPreviewReadback()
                        checks["missingSourceKeepsExactPlaybackForRetry"] = retained == fixture.first && missingState["webPresent"] as? Bool == false
                        checks["unavailablePlaybackCanStillCheckpoint"] = await flushWorkspaceWindows()
                        try FileManager.default.moveItem(at: unavailable, to: file)
                        _ = await first.checkVideoWorkspace(action: "refresh")
                        checks["returnedSourceResumesPausedWithoutReenteringPosition"] = matches(try await decoded(first), fixture.first)
                        for (owner, root) in [(control, AgentTaskWorkspace.Root.document(fixture.file)), (control, .document(fixture.secondFile)), (child, .document(fixture.file))] {
                            owner.taskWorkspace.checkClose(root)
                            guard await eventually({ owner.taskWorkspace.rootController(root) == nil }) else { throw PetError("视频标签未明确关闭") }
                        }
                        checks["explicitClosePersistsWithoutTouchingSource"] = await flushWorkspaceWindows()
                    }
                }
            }
            checks["sourceVideoBytesAndReadOnlyModesRemainOriginal"] = try files.fileHash(URL(fileURLWithPath: fixture.file)) == fixture.first.hash && files.fileHash(URL(fileURLWithPath: fixture.secondFile)) == fixture.second.hash && [fixture.file, fixture.secondFile].allSatisfy { (try FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? NSNumber)?.intValue == 0o444 }
            checks["bothOriginalTaskDraftsRemainExact"] = tasks.task(fixture.taskID)?.draft == "保留视频主任务 PUBLIC_VIDEO_DRAFT_417" && tasks.task(fixture.otherID)?.draft == "保留另一视频任务 PUBLIC_VIDEO_OTHER_618"
            checks["noModelsOrFabricatedReplies"] = requests == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["stage"] = stage
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "video-recovery-ui-ready.json" : "video-recovery-report.json"))
    }
}
