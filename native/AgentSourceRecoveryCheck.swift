import AppKit

@MainActor extension AppDelegate {
    struct SourceRecoveryFixture: Codable {
        var first: String, second: String, window: String
        var parentA: String, parentB: String, parentFloat: String, source1: String, source2: String, video: String
        var firstTab: String, secondTab: String, floatTab: String
        var a: AgentMarkdownSourceWindow.RecoveryState, b: AgentMarkdownSourceWindow.RecoveryState, independent: AgentMarkdownSourceWindow.RecoveryState
        var parentDraft: String, hashes: [String: String]
    }
    func runSourceRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("来源阅读验收禁止模型请求") }
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("source-input.json"))) as! [String: String]
            let journal = AgentWorkspaceRecovery(profile: store.directory), fixtureURL = output.appendingPathComponent("source-recovery-fixture.json")
            func record(_ task: String, _ path: String) throws -> AgentRecordWindow {
                guard let value = control.taskWorkspace.recoveryController(taskID: task, root: .document(path)) as? AgentRecordWindow else { throw PetError("来源父标签未恢复") }; return value
            }
            func source(_ page: AgentRecordWindow) throws -> AgentMarkdownSourceWindow { guard let value = page.sourceForRecoveryCheck() else { throw PetError("来源阅读器未恢复") }; return value }
            func pageState(_ page: AgentRecordWindow) async throws -> AgentRecordWindow.RecoveryState { try AgentRecordWindow.recoveryState(await page.captureWorkspaceRecovery()) }
            func state(_ view: AgentMarkdownSourceWindow) async throws -> AgentMarkdownSourceWindow.RecoveryState { guard let value = try await view.captureWorkspaceRecovery() else { throw PetError("来源阅读器已关闭") }; return value }
            func layout() throws -> AgentWorkspaceRecovery.Window { guard let id = control.workspaceSession?.id, let value = try journal.loadWindow(id)?.value else { throw PetError("来源窗口布局未保存") }; return value }
            func eventually(_ test: () -> Bool) async -> Bool { for _ in 0..<150 { if test() { return true }; await wait(0.03) }; return test() }
            func decoded(_ view: AgentMarkdownSourceWindow) async throws -> [String: Any] {
                var actual: [String: Any] = [:]
                for _ in 0..<150 {
                    guard let video = view.recoveryVideoForCheck else { throw PetError("来源视频未恢复") }; actual = await video.preview.checkState()
                    if let player = actual["player"] as? [String: Any], player["restoreReady"] as? Bool == true,
                       (player["readyState"] as? Int ?? 0) >= ((player["time"] as? Double ?? 0) > 0 ? 2 : 1),
                       player["seeking"] as? Bool == false, (player["error"] as? Int ?? 0) == 0 { return actual }
                    await wait(0.05)
                }
                report["decoderFailure"] = actual; throw PetError("来源视频未实际解码就绪")
            }
            func paused(_ actual: [String: Any], _ expected: AgentVideoWindow.RecoveryState?) -> Bool {
                guard let expected = expected?.playback, let player = actual["player"] as? [String: Any] else { return false }
                return actual["sourceHash"] as? String == expected.hash && player["paused"] as? Bool == true && abs((player["time"] as? Double ?? -1) - expected.time) < 0.12 && player["rate"] as? Double == expected.rate && player["volume"] as? Double == expected.volume && player["muted"] as? Bool == expected.muted
            }
            func same(_ a: AgentTextViewport?, _ b: AgentTextViewport?) -> Bool {
                guard let a, let b else { return false }; return a.hash == b.hash && a.count == b.count && a.selections == b.selections && abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1
            }
            func sameSource(_ a: AgentMarkdownSourceWindow.RecoveryState, _ b: AgentMarkdownSourceWindow.RecoveryState) -> Bool {
                a.root == b.root && a.target == b.target && a.hash == b.hash && a.history == b.history && a.encodings == b.encodings && a.encoding == b.encoding && a.mode == b.mode && a.presentation == b.presentation && a.frame == b.frame && same(a.raw, b.raw) && same(a.preview?.viewport, b.preview?.viewport) && a.preview?.heading == b.preview?.heading
            }
            func prepareSource(_ page: AgentRecordWindow, first: URL, second: URL, marker: String, y: Double, raw: Bool, encoding: AgentTextEncoding? = nil) async throws -> AgentMarkdownSourceWindow {
                guard let view = page.sourceForRecoveryCheck(open: first) else { throw PetError("公开文档链接未打开来源") }; view.checkSourceLink(second)
                try view.checkSourceView(preview: true, encoding: encoding, heading: "章节二"); await wait(0.04)
                try view.checkSourceView(preview: true, target: marker, y: y)
                try view.checkSourceView(preview: false, target: marker + " 中文😀", y: y + 80)
                if !raw { try view.checkSourceView(preview: true) }; return view
            }
            let fixture: SourceRecoveryFixture
            if stage == "seed" {
                let workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path)
                let parentA = try files.resolve("parent-a.md"), parentB = try files.resolve("parent-b.md"), parentFloat = try files.resolve("parent-independent.md"), firstFile = try files.resolve("sources/source1.md"), secondFile = try files.resolve("sources/source2.md"), videoFile = try files.resolve("media/flower.mp4")
                var firstURL = URLComponents(url: firstFile, resolvingAgainstBaseURL: false)!; firstURL.fragment = "来源一"
                var secondURL = URLComponents(url: secondFile, resolvingAgainstBaseURL: false)!; secondURL.fragment = "章节二"
                let first = tasks.create(title: "来源链主任务", workspace: workspace.path), second = tasks.create(title: "来源链另一任务", workspace: workspace.path)
                for id in [first, second] { tasks.update(id) { $0.draft = "保留输入 PUBLIC_SOURCE_DRAFT_417" } }
                control.window?.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 774), display: true)
                control.showAgentTask(first); control.show(tab: "chat"); control.showTaskDocument(parentA.path)
                let pageA = try record(first, parentA.path), a = try await prepareSource(pageA, first: firstURL.url!, second: secondURL.url!, marker: "PUBLIC_SOURCE_45", y: 360, raw: false)
                a.checkSourceLink(videoFile); _ = try await decoded(a)
                await a.recoveryVideoForCheck?.preview.checkWorkspace(action: "", time: 1.8, rate: 1.25, volume: 0.35, muted: true); _ = try await decoded(a)
                checks["sourceAndVideoUseOriginalTaskPageChain"] = a.settingsHostWindow === control.window && a.recoveryVideoForCheck?.settingsHostWindow === control.window && control.taskWorkspace.currentController is AgentVideoWindow
                control.showAgentTask(second); control.showTaskDocument(parentB.path)
                let pageB = try record(second, parentB.path), b = try await prepareSource(pageB, first: firstURL.url!, second: secondURL.url!, marker: "PUBLIC_SOURCE_87", y: 620, raw: true, encoding: .utf16LE)
                control.showAgentTask(first); control.showTaskDocument(parentFloat.path)
                let floating = try record(first, parentFloat.path); guard let parentDraft = input["parentDraft"] else { throw PetError("缺少独立父文档预期") }
                await floating.checkTaskDocument(text: parentDraft); await floating.checkTaskDocument(action: "preview"); try control.presentArtifactWindow(floating, taskID: first)
                let independent = try await prepareSource(floating, first: firstURL.url!, second: secondURL.url!, marker: "PUBLIC_SOURCE_125", y: 740, raw: false)
                independent.window?.setFrame(NSRect(x: 100, y: 160, width: 620, height: 420), display: true)
                independent.checkSourceLink(videoFile); independent.recoveryVideoForCheck?.window?.setFrame(NSRect(x: 450, y: 150, width: 560, height: 400), display: true)
                _ = try await decoded(independent); await independent.recoveryVideoForCheck?.preview.checkWorkspace(action: "", time: 2.65, rate: 0.75, volume: 0.42, muted: false); _ = try await decoded(independent)
                control.showTaskDocument(parentFloat.path)
                checks["rehostingParentKeepsSourceAndVideoIndependent"] = floating.settingsHostWindow === control.window && independent.hasIndependentWindow && independent.hasIndependentVideoWindow
                control.showAgentTask(second); control.window?.makeKeyAndOrderFront(nil)
                guard await flushWorkspaceWindows(), let window = control.workspaceSession?.id else { throw PetError("来源链未持久保存") }
                let saved = try layout(), firstTab = saved.tasks.first(where: { $0.taskID == first })!.tabs.first(where: { $0.root == "document:" + parentA.path })!, secondTab = saved.tasks.first(where: { $0.taskID == second })!.tabs.first(where: { $0.root == "document:" + parentB.path })!, floatTab = saved.tasks.first(where: { $0.taskID == first })!.tabs.first(where: { $0.root == "document:" + parentFloat.path })!
                let recordPath = store.directory.appendingPathComponent("workspace-recovery/" + window + "/pages/" + floatTab.id + ".json"), original = try Data(contentsOf: recordPath)
                try original.write(to: output.appendingPathComponent("readonly-source-page.json")); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: recordPath.path)
                try independent.checkSourceView(preview: false, target: "PUBLIC_SOURCE_125 中文😀", y: 860)
                let refused = !(await flushWorkspaceWindows()); checks["readonlyCheckpointRetainsOriginalBytesAndLiveSourcePosition"] = try refused && Data(contentsOf: recordPath) == original
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordPath.path)
                checks["sourcePositionRetriesWithoutAnotherInteraction"] = await flushWorkspaceWindows()
                try independent.checkSourceView(preview: true); guard await flushWorkspaceWindows() else { throw PetError("来源预览位置未保存") }
                fixture = .init(first: first, second: second, window: window, parentA: parentA.path, parentB: parentB.path, parentFloat: parentFloat.path, source1: firstFile.path, source2: secondFile.path, video: videoFile.path, firstTab: firstTab.id, secondTab: secondTab.id, floatTab: floatTab.id,
                    a: try await state(a), b: try await state(b), independent: try await state(independent), parentDraft: parentDraft, hashes: try Dictionary(uniqueKeysWithValues: [parentA, parentB, parentFloat, firstFile, secondFile, videoFile].map { ($0.path, try files.fileHash($0)) }))
                checks["backgroundSourceChildHasEagerHintWithoutChangingCurrentTask"] = floatTab.hasIndependentChild == true && saved.taskID == second && saved.tasks.first(where: { $0.taskID == second })?.selected == "document:" + parentB.path && saved.floating.isEmpty
                checks["sameSourceHasIndependentModesPositionsAndEncodingChoices"] = fixture.a.mode == 0 && fixture.b.mode == 1 && fixture.independent.mode == 0 && fixture.b.encodings[secondFile.path] == AgentTextEncoding.utf16LE.rawValue && fixture.a.raw?.selections != fixture.b.raw?.selections && fixture.b.raw?.selections != fixture.independent.raw?.selections
                checks["sourceHistoryHeadingAndReadonlyStateAreComplete"] = fixture.a.history.count == 1 && fixture.b.history.count == 1 && fixture.independent.preview?.heading == 2 && independent.sourceRecoveryReadback["editable"] as? Bool == false && (fixture.independent.raw?.y ?? 0) > 400 && (fixture.independent.preview?.viewport.y ?? 0) > 400
                checks["hostedAndIndependentVideosHaveDistinctCompleteState"] = fixture.a.video?.frame == nil && fixture.independent.video?.frame?.width == 560 && abs((fixture.a.video?.playback?.time ?? -1) - 1.8) < 0.12 && abs((fixture.independent.video?.playback?.time ?? -1) - 2.65) < 0.12
                var legacy = try await floating.captureWorkspaceRecovery(), object = try JSONSerialization.jsonObject(with: legacy.state) as! [String: Any]; object.removeValue(forKey: "sourceWindow"); legacy.state = try JSONSerialization.data(withJSONObject: object)
                checks["legacyRecordWithoutLinkedSourceStillDecodes"] = try AgentRecordWindow.recoveryState(legacy).sourceWindow == nil
                let page = try await floating.captureWorkspaceRecovery()
                for key in ["version", "history", "raw", "preview", "video", "unknown"] {
                    var bad = page, raw = try JSONSerialization.jsonObject(with: page.state) as! [String: Any], value = raw["sourceWindow"] as! [String: Any]
                    switch key {
                    case "version": value[key] = 2
                    case "history": value[key] = ["https://example.com/"]
                    case "raw": var data = value[key] as! [String: Any]; data["selections"] = [["location": Int.max, "length": 1]]; value[key] = data
                    case "preview": var data = value[key] as! [String: Any]; data["heading"] = Int.max; value[key] = data
                    case "video": var data = value[key] as! [String: Any]; data["unknown"] = true; value[key] = data
                    default: value[key] = true
                    }
                    raw["sourceWindow"] = value; bad.state = try JSONSerialization.data(withJSONObject: raw)
                    do { _ = try AgentRecordWindow.recoveryState(bad); checks["rejectInvalidNestedSource-" + key] = false } catch { checks["rejectInvalidNestedSource-" + key] = true }
                }
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(SourceRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows(); guard await flushWorkspaceWindows() else { throw PetError("来源恢复未完成") }
                if interactive {
                    checks["restoredCurrentTaskHasItsOriginalIdentity"] = [fixture.first, fixture.second].contains(control.agentTaskID ?? "")
                    report["currentTask"] = control.agentTaskID; report["currentController"] = String(describing: control.taskWorkspace.currentController.map { type(of: $0) })
                    if let page = try? record(fixture.first, fixture.parentFloat), let view = page.sourceForRecoveryCheck() { report["independentActual"] = view.sourceRecoveryReadback; if view.recoveryVideoForCheck != nil { report["videoActual"] = try await decoded(view) } }
                    if let page = try? record(fixture.second, fixture.parentB), let view = page.sourceForRecoveryCheck() { report["otherActual"] = view.sourceRecoveryReadback }
                } else if stage == "invalid" {
                    checks["unknownSourceKeepsWholeBackgroundParentCold"] = control.taskWorkspace.recoveryController(taskID: fixture.first, root: .document(fixture.parentFloat)) == nil
                    let page = store.directory.appendingPathComponent("workspace-recovery/" + fixture.window + "/pages/" + fixture.floatTab + ".json")
                    checks["unknownNestedSourceOriginalBytesPreserved"] = try Data(contentsOf: page) == Data(contentsOf: output.appendingPathComponent("future-source-input.json"))
                    let b = try source(record(fixture.second, fixture.parentB)); checks["otherTaskSourcePageRestoresWithoutBeingReplaced"] = b.settingsHostWindow === control.window && b.sourceRecoveryReadback["pending"] as? Bool == false && control.agentTaskID == fixture.second
                } else if stage == "closed" {
                    checks["closedSourceDoesNotForceBackgroundParentOpen"] = control.taskWorkspace.recoveryController(taskID: fixture.first, root: .document(fixture.parentFloat)) == nil
                    checks["closedSourceAndNestedVideoDoNotResurrect"] = !NSApp.windows.contains { window in
                        guard window.isVisible else { return false }
                        if let source = window.windowController as? AgentMarkdownSourceWindow { return source.hasIndependentWindow }
                        return window.windowController is AgentVideoWindow
                    }
                    control.showAgentTask(fixture.first); control.taskWorkspace.checkSelect(.document(fixture.parentFloat)); guard await flushWorkspaceWindows() else { throw PetError("关闭后的父文档未恢复") }
                    let parent = try await pageState(record(fixture.first, fixture.parentFloat)); checks["closedChildKeepsCompleteParentDraftAndSourceVersion"] = parent.text == fixture.parentDraft && parent.openedHash == fixture.hashes[fixture.parentFloat] && parent.sourceWindow == nil
                } else {
                    if stage == "retry" {
                        let page = store.directory.appendingPathComponent("workspace-recovery/" + fixture.window + "/pages/" + fixture.floatTab + ".json")
                        try Data(contentsOf: output.appendingPathComponent("original-source-page.json")).write(to: page)
                        restoreFloatingWorkspaceWindows(); guard await flushWorkspaceWindows() else { throw PetError("来源窗口菜单重试未完成") }
                    }
                    let parent = try record(fixture.first, fixture.parentFloat), independent = try source(parent), b = try source(record(fixture.second, fixture.parentB))
                    let parentState = try await pageState(parent), independentState = try await state(independent), savedLayout = try layout()
                    checks["backgroundParentAndSourceRetainOriginalTaskAndTab"] = parentState.taskID == fixture.first && parentState.text == fixture.parentDraft && independent.hasIndependentWindow && savedLayout.taskID == fixture.second && savedLayout.tasks.first(where: { $0.taskID == fixture.first })?.tabs.contains(where: { $0.id == fixture.floatTab && $0.hasIndependentChild == true }) == true
                    checks["nestedIndependentVideoRestoresPausedAndComplete"] = paused(try await decoded(independent), fixture.independent.video)
                    if ["missing", "changed"].contains(stage) {
                        checks["unavailableSourcePreservesCompleteReadingProgress"] = independent.sourceRecoveryReadback["pending"] as? Bool == true && sameSource(independentState, fixture.independent)
                        checks["unavailableSourceNeverAppliesStaleBodyOrSelection"] = independent.sourceRecoveryReadback["bodyHash"] as? String == AgentFiles.hash(Data()) && independent.sourceRecoveryReadback["editable"] as? Bool == false
                        if stage == "changed" {
                            b.checkSourceAction("latest"); let current = try await state(b)
                            checks["explicitLatestOpensChangedReadonlySourceOnlyForItsOwner"] = b.sourceRecoveryReadback["pending"] as? Bool == false && current.hash == input["changedSourceHash"] && b.sourceRecoveryReadback["bodyHash"] as? String == input["changedBodyHash"] && b.sourceRecoveryReadback["editable"] as? Bool == false
                            checks["otherSourceStillRetainsOriginalProgressAfterLatestAction"] = sameSource(try await state(independent), fixture.independent)
                        }
                    } else {
                        checks["independentSourceRestoresHistoryEncodingHeadingAndBothPositions"] = sameSource(independentState, fixture.independent) && independent.sourceRecoveryReadback["pending"] as? Bool == false
                        checks["independentVisiblePreviewAppliedAfterFinalGeometry"] = await eventually { (independent.sourceRecoveryReadback["preview"] as? [String: Any])?["pending"] as? Bool == false }
                        if stage == "retry" {
                            checks["otherSourceRestoresItsOwnRawPositionAndEncoding"] = sameSource(try await state(b), fixture.b)
                            control.showAgentTask(fixture.first); control.taskWorkspace.checkSelect(.document(fixture.parentA)); guard await flushWorkspaceWindows() else { throw PetError("页内来源视频链未恢复") }
                            let a = try source(record(fixture.first, fixture.parentA)), actual = try await decoded(a)
                            checks["pageSourceAndVideoRestoreAsPageChain"] = a.settingsHostWindow === control.window && a.recoveryVideoForCheck?.settingsHostWindow === control.window && control.taskWorkspace.currentController is AgentVideoWindow && paused(actual, fixture.a.video)
                            control.taskWorkspace.checkBack(); guard await flushWorkspaceWindows() else { throw PetError("返回来源页面未保存") }
                            checks["explicitVideoBackKeepsSourceAndDropsOnlyVideo"] = a.recoveryVideoForCheck == nil && control.taskWorkspace.currentController === a
                            checks["sourcePreviewAppliesWhenVideoPageReturns"] = await eventually { (a.sourceRecoveryReadback["preview"] as? [String: Any])?["pending"] as? Bool == false }
                            a.checkSourceAction("back"); let current = try await state(a)
                            checks["historyBackAfterRestartOpensOriginalReadonlySource"] = URL(string: current.target)?.path == fixture.source1 && current.history.isEmpty && current.hash == fixture.hashes[fixture.source1] && a.sourceRecoveryReadback["editable"] as? Bool == false
                            checks["historyBackRefreshesVisibleNavigationTitle"] = control.taskWorkspace.checkState()["pageTitle"] as? String == "sources/source1.md"
                            control.showAgentTask(fixture.second)
                        } else if stage == "reopen" {
                            checks["explicitLatestVersionChoiceIsProtectedOnFollowingSourceChange"] = b.sourceRecoveryReadback["pending"] as? Bool == true
                            b.checkSourceAction("latest"); let current = try await state(b)
                            checks["explicitLatestCanAdoptOriginalAgainWithoutWritingSource"] = b.sourceRecoveryReadback["pending"] as? Bool == false && current.hash == fixture.hashes[fixture.source2]
                            independent.checkSourceAction("close"); guard await flushWorkspaceWindows() else { throw PetError("明确关闭来源窗口未保存") }
                            let remainingParent = try await pageState(parent)
                            checks["closingSourceReleasesNestedVideoAndRetainsParentDraft"] = independent.workspaceIsClosed && independent.recoveryVideoForCheck == nil && parent.sourceForRecoveryCheck() == nil && remainingParent.text == fixture.parentDraft
                        }
                    }
                    report["independentActual"] = independent.sourceRecoveryReadback; report["otherActual"] = b.sourceRecoveryReadback
                }
            }
            if !interactive { checks["bothTaskInputsRemainExact"] = [fixture.first, fixture.second].allSatisfy { tasks.task($0)?.draft == "保留输入 PUBLIC_SOURCE_DRAFT_417" } }
            checks["taskRepliesAndModelsRemainEmpty"] = [fixture.first, fixture.second].allSatisfy { tasks.task($0)?.messages.isEmpty == true && (tasks.task($0)?.modelReceipts ?? []).isEmpty }
            checks["originalParentSourcesAndVideoUnchanged"] = try fixture.hashes.filter { !["missing", "changed"].contains(stage) || $0.key != fixture.source2 }.allSatisfy { let file = URL(fileURLWithPath: $0.key); return try AgentFiles(workspace: file.deletingLastPathComponent().path).fileHash(file) == $0.value }
            checks["latestSourceChainsCheckpointed"] = await flushWorkspaceWindows(); checks["noModels"] = requests == 0
            report["stage"] = stage; report["workspace"] = control.taskWorkspace.checkState()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "source-recovery-ui-ready.json" : "source-recovery-report.json"))
    }
}
