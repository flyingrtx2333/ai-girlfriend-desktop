import AppKit

@MainActor extension AppDelegate {
    struct KnowledgeSourceRecoveryFixture: Codable {
        var window: String, first: String, other: String, source: String
        var saved: AgentWorkspaceRecovery.Knowledge
        var drafts: [String: String], hashes: [String: String]
    }
    func runKnowledgeSourceRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("知识阅读恢复验收禁止模型请求") }
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let fixtureURL = output.appendingPathComponent("knowledge-source-recovery-fixture.json"), journal = AgentWorkspaceRecovery(profile: store.directory)
            let host = control.knowledgePageHost
            func saved() throws -> AgentWorkspaceRecovery.Window {
                guard let id = control.workspaceSession?.id, let value = try journal.loadWindow(id)?.value else { throw PetError("知识阅读窗口未保存") }; return value
            }
            func flush() async throws {
                guard await control.flushWorkspaceRecovery() else { throw PetError("知识阅读记录未保存") }
            }
            func source() throws -> AgentMarkdownSourceWindow {
                guard let reader = host.recoveryReaders.last, let source = reader.sourceForRecoveryCheck() else { throw PetError("知识来源阅读器未恢复") }; return source
            }
            func readyVideo(_ video: AgentVideoWindow) async throws -> [String: Any] {
                var value: [String: Any] = [:]
                for _ in 0..<160 {
                    value = await video.preview.checkState()
                    if let player = value["player"] as? [String: Any], player["restoreReady"] as? Bool == true,
                       (player["readyState"] as? Int ?? 0) >= ((player["time"] as? Double ?? 0) > 0 ? 2 : 1), player["seeking"] as? Bool == false,
                       (player["error"] as? Int ?? 0) == 0 { return value }
                    await wait(0.05)
                }
                report["decoderFailure"] = value; throw PetError("知识来源视频未实际解码就绪")
            }
            func ready(_ source: AgentMarkdownSourceWindow) async throws -> [String: Any] {
                guard let video = source.recoveryVideoForCheck else { throw PetError("知识来源视频未恢复") }; return try await readyVideo(video)
            }
            func viewport(_ a: AgentTextViewport?, _ b: AgentTextViewport?) -> Bool {
                guard let a, let b else { return false }
                return a.hash == b.hash && a.count == b.count && a.selections == b.selections && abs(a.y - b.y) < 1 && abs(a.x - b.x) < 1
            }
            let fixture: KnowledgeSourceRecoveryFixture
            if stage == "seed" {
                let f = try await prepareKnowledgeVideoUI(output), files = try AgentFiles(workspace: f.video.workspace.path)
                guard let reader = host.currentController as? AgentRecordWindow,
                      let view = reader.sourceForRecoveryCheck(open: f.video.guide) else { throw PetError("Wiki 来源链接未进入来源页") }
                let second = try files.resolve("docs/SOURCE.md"); view.checkSourceLink(second)
                try view.checkSourceView(preview: true, target: "PUBLIC_KNOWLEDGE_SOURCE_90 中文😀", y: 700)
                try view.checkSourceView(preview: false, target: "PUBLIC_KNOWLEDGE_SOURCE_37 中文😀", y: 560)
                view.checkSourceLink(f.video.mp4); _ = try await ready(view)
                await view.recoveryVideoForCheck?.preview.checkWorkspace(time: 1.65, rate: 1.25, volume: 0.37, muted: true)
                let video = try await ready(view), player = video["player"] as? [String: Any] ?? [:]
                checks["wikiSourceAndVideoUseOriginalKnowledgePageChain"] = host.checkState()["depth"] as? Int == 4 && host.currentController is AgentVideoWindow && view.settingsHostWindow === control.window
                checks["videoHasActualDecodedMetadataAndNonzeroPausedPosition"] = player["paused"] as? Bool == true && abs((player["time"] as? Double ?? -1) - 1.65) < 0.12 && player["width"] as? Int == 960 && player["height"] as? Int == 540
                try await flush(); let layout = try saved()
                guard let knowledge = layout.knowledge, let page = knowledge.readers.first, let state = try AgentRecordWindow.recoveryState(page).sourceWindow else { throw PetError("知识来源链未写入窗口记录") }
                checks["optionalKnowledgeStateKeepsOriginalTaskAndReadonlyReader"] = knowledge.active && knowledge.identity == f.video.taskID && knowledge.root == "wiki" && knowledge.readers.count == 1 && !page.dirty
                checks["sourceHistoryRawPreviewAndEncodingPersisted"] = state.history.count == 1 && state.target == second.absoluteString && state.encoding == "utf-16le" && state.raw?.selections.isEmpty == false && state.preview?.viewport.selections.isEmpty == false && (state.raw?.y ?? 0) > 0 && (state.preview?.viewport.y ?? 0) > 0
                checks["nestedVideoSavedWithOriginalSourceHash"] = state.video?.playback?.hash == (try files.fileHash(f.video.mp4)) && state.video?.frame == nil
                let hashes = try Dictionary(uniqueKeysWithValues: [f.video.guide, second, f.video.mp4].map { ($0.path, try files.fileHash($0)) })
                fixture = .init(window: layout.id, first: f.video.taskID, other: f.video.otherID, source: second.path, saved: knowledge,
                                drafts: [f.video.taskID: tasks.task(f.video.taskID)?.draft ?? "", f.video.otherID: tasks.task(f.video.otherID)?.draft ?? ""], hashes: hashes)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; try encoder.encode(fixture).write(to: fixtureURL)
            } else {
                fixture = try JSONDecoder().decode(KnowledgeSourceRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                try await flush()
                if stage == "future" {
                    let before = try saved().knowledge
                    checks["unknownNestedSourceVersionLeavesKnowledgeCold"] = control.workspaceSession?.hasPendingKnowledge == true && host.controllers.isEmpty
                    control.showAgentKnowledge(); try await flush()
                    checks["retryKeepsUnsupportedSourceStateExactly"] = before == (try saved().knowledge) && control.workspaceSession?.hasPendingKnowledge == true
                    checks["unsupportedKnowledgeDoesNotChangeSelectedTask"] = control.agentTaskID == fixture.first
                } else if stage == "direct-seed" {
                    guard let page = fixture.saved.readers.first, let selection = try AgentRecordWindow.recoveryState(page).selection else { throw PetError("缺少 Wiki 原页") }
                    control.showAgentTask(fixture.first); control.openAgentRecordItem(section: 6, value: selection)
                    guard let reader = host.recoveryReaders.last else { throw PetError("Wiki 阅读器未打开") }
                    _ = await reader.checkVideoWorkspace(link: output.appendingPathComponent("workspace/media/flower.mp4"))
                    guard let video = host.currentController as? AgentVideoWindow else { throw PetError("Wiki 直接视频未进入页面") }
                    _ = try await readyVideo(video); await video.preview.checkWorkspace(time: 2.25, rate: 0.75, volume: 0.41, muted: false); _ = try await readyVideo(video)
                    try await flush(); let value = try saved().knowledge
                    guard let page = value?.readers.first, let child = try AgentRecordWindow.recoveryState(page).videoWindow else { throw PetError("Wiki 直接视频未保存") }
                    checks["directWikiVideoRetainsHostedPresentationAndNonzeroPosition"] = child.frame == nil && abs((child.playback?.time ?? -1) - 2.25) < 0.12 && host.checkState()["depth"] as? Int == 3
                    checks["directWikiVideoHasNoUnrelatedSourceChain"] = try AgentRecordWindow.recoveryState(page).sourceWindow == nil
                    try JSONEncoder().encode(value).write(to: output.appendingPathComponent("direct-knowledge-expected.json"))
                } else if stage == "direct-resume" {
                    let value = try JSONDecoder().decode(AgentWorkspaceRecovery.Knowledge.self, from: Data(contentsOf: output.appendingPathComponent("direct-knowledge-expected.json")))
                    guard let video = host.currentController as? AgentVideoWindow, let page = value.readers.first,
                          let expected = try AgentRecordWindow.recoveryState(page).videoWindow?.playback else { throw PetError("Wiki 直接视频未恢复") }
                    let actual = try await readyVideo(video), player = actual["player"] as? [String: Any] ?? [:]
                    checks["directWikiVideoRestoresInOriginalKnowledgePage"] = control.isShowingKnowledge && control.agentTaskID == fixture.first && video.settingsHostWindow === control.window && video.window?.isVisible == false && host.checkState()["depth"] as? Int == 3
                    checks["directWikiVideoRestoresPausedWithExactSourceAndParameters"] = actual["sourceHash"] as? String == expected.hash && player["paused"] as? Bool == true && abs((player["time"] as? Double ?? -1) - expected.time) < 0.12 && player["rate"] as? Double == expected.rate && player["volume"] as? Double == expected.volume && player["muted"] as? Bool == expected.muted
                    host.checkBack(); try await flush()
                    checks["explicitVideoBackClearsOnlyDirectVideo"] = try AgentRecordWindow.recoveryState(saved().knowledge!.readers[0]).videoWindow == nil && host.recoveryReaders.count == 1
                    host.checkBack(); try await flush()
                    checks["explicitDirectReaderBackClearsRecovery"] = try saved().knowledge == nil
                    report["video"] = actual
                } else if stage == "closed" {
                    checks["explicitBackDoesNotResurrectWikiSourceOrVideo"] = try saved().knowledge == nil && host.recoveryReaders.isEmpty
                    checks["closingKnowledgeKeepsOriginalTask"] = control.agentTaskID == fixture.first
                } else {
                    let view = try source(), actual = try await view.captureWorkspaceRecovery()
                    guard let actual, let page = fixture.saved.readers.first, let expected = try AgentRecordWindow.recoveryState(page).sourceWindow else { throw PetError("缺少来源预期") }
                    let media = try await ready(view), player = media["player"] as? [String: Any] ?? [:]
                    checks["sourceURLHistoryHashAndEncodingRestored"] = actual.target == expected.target && actual.history == expected.history && actual.hash == expected.hash && actual.encoding == expected.encoding && actual.encodings == expected.encodings
                    checks["independentRawAndPreviewSelectionsAndScrollRestored"] = viewport(actual.raw, expected.raw) && viewport(actual.preview?.viewport, expected.preview?.viewport)
                    checks["nestedVideoRestoresPausedWithAllPlaybackParameters"] = player["paused"] as? Bool == true && abs((player["time"] as? Double ?? -1) - (expected.video?.playback?.time ?? -10)) < 0.12 && player["rate"] as? Double == expected.video?.playback?.rate && player["volume"] as? Double == expected.video?.playback?.volume && player["muted"] as? Bool == expected.video?.playback?.muted
                    checks["restoredSourceAndVideoStayInKnowledgeHost"] = view.settingsHostWindow === control.window && view.recoveryVideoForCheck?.settingsHostWindow === control.window && host.checkState()["depth"] as? Int == 4
                    if stage == "resume" {
                        checks["activeKnowledgePageRestoresWithoutSelectingReaderTask"] = control.isShowingKnowledge && control.agentTaskID == fixture.first && tasks.task(page.taskID) != nil
                        control.showAgentTask(fixture.other); control.show(tab: "chat"); try await flush()
                        checks["backgroundKnowledgeKeepsItsOwnerAndSavesInactive"] = try saved().knowledge?.identity == fixture.first && saved().knowledge?.active == false && control.agentTaskID == fixture.other
                    } else if stage == "hidden" {
                        checks["backgroundKnowledgeDoesNotStealCurrentTaskOrPage"] = !control.isShowingKnowledge && control.agentTaskID == fixture.other
                        control.showAgentTask(fixture.first); control.showAgentKnowledge()
                        checks["returningToOriginalKnowledgeReusesSourceChain"] = try control.isShowingKnowledge && source() === view && host.currentController is AgentVideoWindow
                        host.checkBack(); view.checkSourceAction("back")
                        checks["sourceHistoryBackUpdatesVisibleKnowledgeTitle"] = (host.checkState()["pageTitle"] as? String)?.contains("VIDEO.md") == true && host.currentController === view
                        host.checkBack(); try await flush()
                        checks["explicitSourceBackClearsOnlyOwnedSourceChain"] = try AgentRecordWindow.recoveryState(saved().knowledge!.readers[0]).sourceWindow == nil && host.recoveryReaders.count == 1
                        host.checkBack(); try await flush()
                        checks["explicitReaderBackClearsKnowledgeRecovery"] = try saved().knowledge == nil && host.checkState()["depth"] as? Int == 1
                    } else if stage != "observe" { throw PetError("未知知识恢复阶段") }
                    report["video"] = media
                }
            }
            checks["originalUnsentDraftsRetainTheirTaskOwners"] = fixture.drafts.allSatisfy { tasks.task($0.key)?.draft == $0.value }
            checks["allPublicSourceBytesStayExact"] = fixture.hashes.allSatisfy { path, hash in (try? AgentFiles(workspace: URL(fileURLWithPath: path).deletingLastPathComponent().path).fileHash(URL(fileURLWithPath: path))) == hash }
            try await flush(); report["knowledge"] = host.checkState(); report["stage"] = stage
            report["window"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved()))
            report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        let binary = Bundle.main.executableURL!
        report["appPID"] = getpid(); report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
        report["checks"] = checks; report["modelRequests"] = requests
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "knowledge-source-recovery-ui-ready.json" : "knowledge-source-recovery-report.json"))
    }
}
