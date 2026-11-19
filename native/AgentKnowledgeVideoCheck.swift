import AppKit

@MainActor extension AppDelegate {
    struct KnowledgeVideoFixture { let video: VideoWorkspaceFixture, page: String }

    func prepareKnowledgeVideoUI(_ output: URL, existing: VideoWorkspaceFixture? = nil) async throws -> KnowledgeVideoFixture {
        guard !CommandLine.arguments.contains("--live-agent"), let tasks = agentStore else { throw PetError("知识视频验收不调用模型") }
        let f: VideoWorkspaceFixture
        if let existing { f = existing } else { f = try prepareVideoWorkspaceUI(output) }
        let files = try AgentFiles(workspace: f.workspace.path), index = try files.resolve(".bluefatfish/wiki/index.md")
        try files.writeData(Data("# 项目视频\n\n[播放 MP4](../../media/flower.mp4)\n\n[播放 WebM](../../media/flower.webm)\n\n[来源文档](../../docs/VIDEO.md)\n".utf8), to: index)
        try tasks.organization.register(f.workspace.path, mode: .coding)
        _ = try await AgentWiki.exportWiki(store: tasks, taskID: f.otherID, language: "zh")
        let imported = try await AgentWiki.previewWikiImport(store: tasks, taskID: f.otherID, language: "zh")
        try await AgentWiki.importWiki(imported, store: tasks, taskID: f.otherID)
        let view = try AgentWiki.view(store: tasks, taskID: f.otherID, language: "zh")
        guard let page = view.pages.first(where: { $0.path.hasSuffix("index.md") })?.path else { throw PetError("项目视频 Wiki 未导入") }
        let data: [String: Any] = ["taskID": f.taskID, "otherID": f.otherID, "workspace": f.workspace.path, "wikiPage": page]
        try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("knowledge-video-fixtures.json"))
        try await showKnowledgeVideoUI(taskID: f.taskID, workspace: f.workspace.path, page: page)
        return KnowledgeVideoFixture(video: f, page: page)
    }

    private func showKnowledgeVideoUI(taskID: String, workspace: String, page: String) async throws {
        control.showAgentTask(taskID); control.showAgentKnowledge()
        guard let catalog = control.knowledgePageHost.currentController as? AgentRepoWikiWindow else { throw PetError("项目目录未进入知识中心") }
        for _ in 0..<150 { if catalog.checkState["loading"] as? Bool == false { break }; await wait(0.05) }
        try catalog.checkOpen(workspace: workspace, action: "wiki")
        guard let reader = control.knowledgePageHost.currentController as? AgentRecordWindow else { throw PetError("视频 Wiki 未进入阅读页") }
        reader.selectItem(section: 6, value: page)
    }

    func reopenKnowledgeVideoUI(_ output: URL) async throws {
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("knowledge-video-fixtures.json"))) as? [String: String]
        guard let data, let id = data["taskID"], let workspace = data["workspace"], let page = data["wikiPage"], agentStore?.task(id) != nil else { throw PetError("知识视频验收资料不存在") }
        try await showKnowledgeVideoUI(taskID: id, workspace: workspace, page: page)
    }

    func runKnowledgeVideoPageCheck(_ output: URL, fixture f: VideoWorkspaceFixture) async throws -> [String: Bool] {
        let k = try await prepareKnowledgeVideoUI(output, existing: f), host = control.knowledgePageHost
        defer { host.finish() }
        guard let tasks = agentStore, let reader = host.currentController as? AgentRecordWindow else { throw PetError("知识视频阅读页不可用") }
        let files = try AgentFiles(workspace: f.workspace.path), original = try files.readData(files.resolve(k.page)), originalText = String(decoding: original, as: UTF8.self)
        let mp4Hash = try files.fileHash(f.mp4), webmHash = try files.fileHash(f.webm)
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        let askReader = await reader.markdownEditingReadback()
        checks["askWikiContextStaysReadonly"] = askReader["sourceEditable"] as? Bool == false && tasks.task(f.taskID)?.mode == .ask
        func ready(_ page: AgentVideoWindow) async -> [String: Any] {
            var value: [String: Any] = [:]
            for _ in 0..<100 {
                value = await page.preview.checkState(); let player = value["player"] as? [String: Any] ?? [:]
                if (player["readyState"] as? Int ?? 0) > 0 || (player["error"] as? Int ?? 0) > 0 || value["webPresent"] as? Bool == false { break }
                await wait(0.05)
            }; return value
        }
        _ = await reader.checkVideoWorkspace(link: f.mp4)
        guard let direct = host.currentController as? AgentVideoWindow else { throw PetError("Wiki 视频链接仍未进入页内") }
        let initial = await ready(direct), player = initial["player"] as? [String: Any] ?? [:], snapshot = initial["snapshotFolder"] as? String ?? ""
        checks["wikiVideoUsesExistingMainWindowAndChildPage"] = direct.presentingWindow === control.window && direct.window?.isVisible == false && host.checkState()["depth"] as? Int == 3
        checks["wikiMP4HasExactSourceBytesAndActualMetadata"] = initial["sourceHash"] as? String == mp4Hash && player["width"] as? Int == 960 && player["height"] as? Int == 540 && (player["duration"] as? Double ?? 0) > 5
        checks["wikiVideoStartsPausedWithNativeControls"] = player["paused"] as? Bool == true && player["controls"] as? Bool == true
        checks["firstVideoLoadFocusesVisiblePage"] = host.checkState()["focusInPage"] as? Bool == true
        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            control.window?.appearance = NSAppearance(named: name)
            for (sizeName, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                let state = host.checkState(), media = await ready(direct), visible = media["player"] as? [String: Any] ?? [:]
                for (key, pass) in state["checks"] as? [String: Bool] ?? [:] { checks[theme + "-" + sizeName + "-" + key] = pass }
                checks[theme + "-" + sizeName + "-visiblePlayerArea"] = (visible["clientWidth"] as? Int ?? 0) >= 300 && (visible["clientHeight"] as? Int ?? 0) >= 180
                report[theme + "-" + sizeName] = ["host": state, "video": media]
            }
        }
        checks["videoFocusSurvivesAllThemeAndSizeChanges"] = ["light-normal", "light-narrow", "dark-normal", "dark-narrow"].allSatisfy {
            guard let geometry = report[$0] as? [String: Any], let host = geometry["host"] as? [String: Any] else { return false }
            return host["focusInPage"] as? Bool == true
        }
        await direct.preview.checkWorkspace(time: 1.25)
        control.show(tab: "chat"); await wait(0.05)
        let hidden = await ready(direct), hiddenPlayer = hidden["player"] as? [String: Any] ?? [:]
        checks["hiddenKnowledgeVideoIsPausedAndKeepsSnapshot"] = !direct.isPageVisible && hiddenPlayer["paused"] as? Bool == true && hidden["snapshotFolder"] as? String == snapshot
        control.showAgentKnowledge()
        let returned = await ready(direct), returnedPlayer = returned["player"] as? [String: Any] ?? [:]
        checks["returnRestoresSameVideoAndSeekPosition"] = host.currentController === direct && direct.isPageVisible && returned["snapshotFolder"] as? String == snapshot && abs((returnedPlayer["time"] as? Double ?? 0) - 1.25) < 0.15
        checks["returnToVideoRestoresItsKeyboardFocus"] = host.checkState()["focusInPage"] as? Bool == true
        host.checkBack()
        let closed = await direct.preview.checkState(), afterBack = await reader.markdownEditingReadback()
        checks["backReleasesVideoAndPreservesOriginalWiki"] = host.currentController === reader && closed["webPresent"] as? Bool == false && !FileManager.default.fileExists(atPath: snapshot) && afterBack["draft"] as? String == originalText
        _ = await reader.checkVideoWorkspace(link: f.guide)
        guard let source = host.currentController as? AgentMarkdownSourceWindow else { throw PetError("视频来源文档未进入页内") }
        let sourceHash = source.encodingCheckState["textHash"] as? String
        source.checkVideoLink(f.webm)
        guard let nested = host.currentController as? AgentVideoWindow else { throw PetError("来源页视频仍另开窗口") }
        let webm = await ready(nested), webmPlayer = webm["player"] as? [String: Any] ?? [:], nestedSnapshot = webm["snapshotFolder"] as? String ?? ""
        checks["sourceVideoUsesNestedMainPageAndActualWebM"] = nested.presentingWindow === control.window && nested.window?.isVisible == false && host.checkState()["depth"] as? Int == 4 && webm["sourceHash"] as? String == webmHash && webmPlayer["width"] as? Int == 960 && (webmPlayer["duration"] as? Double ?? 0) > 5
        checks["nestedVideoLoadFocusesVisiblePage"] = host.checkState()["focusInPage"] as? Bool == true
        host.checkBack()
        checks["backKeepsSourceAndReleasesNestedVideo"] = host.currentController === source && source.encodingCheckState["textHash"] as? String == sourceHash && !FileManager.default.fileExists(atPath: nestedSnapshot)
        let alternateSource = try files.resolve("docs/SOURCE-TITLE.md")
        try files.writeData(Data("# 另一份来源\n\nPUBLIC_SOURCE_TITLE_417\n".utf8), to: alternateSource)
        source.checkVideoLink(alternateSource)
        checks["knowledgeSourceTitleFollowsLinkedDocument"] = host.checkState()["pageTitle"] as? String == "docs/SOURCE-TITLE.md"
        source.checkSourceAction("back")
        checks["knowledgeSourceHistoryBackRefreshesTitle"] = host.checkState()["pageTitle"] as? String == "docs/VIDEO.md" && source.encodingCheckState["textHash"] as? String == sourceHash
        host.checkBack()
        checks["sourceBackReturnsSameWikiReader"] = host.currentController === reader
        let outside = output.appendingPathComponent("knowledge-outside.mp4"), sensitive = try files.resolve(".env.video-check/flower.mp4"), mediaBytes = try files.readData(f.mp4)
        try mediaBytes.write(to: outside); try files.writeData(mediaBytes, to: sensitive)
        for (name, target) in [("outside", outside), ("sensitive", sensitive)] {
            _ = await reader.checkVideoWorkspace(link: target)
            let rejected = await reader.markdownEditingReadback()
            checks[name + "VideoLinkDoesNotOpenPageOrWindow"] = host.currentController === reader && !(rejected["state"] as? String ?? "").isEmpty
        }
        _ = await reader.checkVideoWorkspace(link: f.broken)
        guard let broken = host.currentController as? AgentVideoWindow else { throw PetError("损坏视频未进入可返回的错误页") }
        let failed = await ready(broken), failedPlayer = failed["player"] as? [String: Any] ?? [:], brokenSnapshot = failed["snapshotFolder"] as? String ?? ""
        checks["brokenVideoShowsActualPlaybackError"] = (failedPlayer["error"] as? Int ?? 0) > 0 && !(failedPlayer["status"] as? String ?? "").isEmpty
        host.checkBack()
        checks["brokenVideoCanReturnAndReleaseSnapshot"] = host.currentController === reader && !FileManager.default.fileExists(atPath: brokenSnapshot)
        try await showKnowledgeVideoUI(taskID: f.otherID, workspace: f.workspace.path, page: k.page)
        guard let editableReader = host.currentController as? AgentRecordWindow else { throw PetError("Agent Wiki 阅读页未打开") }
        let agentReader = await editableReader.markdownEditingReadback()
        checks["agentWikiContextAllowsDraftEditing"] = agentReader["sourceEditable"] as? Bool == true && tasks.task(f.otherID)?.mode == .agent
        let draft = originalText + "\n未保存的视频阅读批注。\n"
        await editableReader.checkTaskDocument(text: draft)
        _ = await editableReader.checkVideoWorkspace(link: f.mp4)
        guard let draftVideo = host.currentController as? AgentVideoWindow else { throw PetError("未保存 Wiki 的视频未进入页内") }
        _ = await ready(draftVideo); host.checkBack()
        let retained = await editableReader.markdownEditingReadback()
        checks["videoRoundTripKeepsUnsavedWikiAndOriginalDiskBytes"] = try retained["dirty"] as? Bool == true && retained["draft"] as? String == draft && files.readData(files.resolve(k.page)) == original
        await editableReader.checkTaskDocument(text: originalText, action: "save")
        checks["originalWikiAndTaskDraftsRemain"] = try files.readData(files.resolve(k.page)) == original && tasks.task(f.taskID)?.draft == "保留视频任务输入。" && tasks.task(f.otherID)?.draft == "保留另一视频任务输入。"
        checks.merge(try await checkLocalLibraryVideo(output, fixture: f, ready: ready)) { _, value in value }
        report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["workspace"] = f.workspace.path
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("knowledge-video-report.json"))
        return checks
    }

    private func checkLocalLibraryVideo(_ output: URL, fixture: VideoWorkspaceFixture,
                                       ready: (AgentVideoWindow) async -> [String: Any]) async throws -> [String: Bool] {
        guard let tasks = agentStore, let window = control.window else { throw PetError("知识库视频验收窗口不可用") }
        let manager = FileManager.default, directory = output.appendingPathComponent("知识库所选视频", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("公开样例 🎞.mp4"), link = directory.appendingPathComponent("链接.mp4")
        try manager.copyItem(at: fixture.mp4, to: file); try manager.createSymbolicLink(at: link, withDestinationURL: file)
        let original = try Data(contentsOf: file), mode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let id = tasks.create(title: "无工作区视频验收", mode: .ask, workMode: .general), draft = "保留知识库视频任务输入。"
        tasks.update(id) { $0.draft = draft }
        control.showAgentTask(id); control.showKnowledgeLibrary()
        let host = control.knowledgePageHost
        guard let library = host.currentController as? AgentKnowledgeLibraryWindow, let content = library.pageContentView else {
            throw PetError("知识库视频入口未打开")
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let children = views(content)
        guard let action = children.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "knowledge-open-local-video" }),
              let search = children.compactMap({ $0 as? NSSearchField }).first(where: { $0.accessibilityLabel() == "搜索知识库" }) else {
            throw PetError("知识库视频入口或筛选控件缺失")
        }
        let frame = window.frame
        window.setFrame(NSRect(origin: frame.origin, size: NSSize(width: 780, height: 540)), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        let buttons = content.convert(action.bounds, from: action)
        var checks = ["localVideoPickerFitsInMinimumWindow": window.frame.size == NSSize(width: 780, height: 540)
            && action.isEnabled && action.bounds.height == 28 && content.bounds.insetBy(dx: -1, dy: -1).contains(buttons)
            && search.placeholderString == "搜索"]
        let query = "公开录像"
        search.stringValue = query; search.sendAction(search.action, to: search.target)
        for (name, invalid) in [("nonVideo", fixture.guide), ("symbolicLink", link)] {
            do { try library.checkOpenLocalVideo(invalid); checks[name + "IsRejected"] = false }
            catch { checks[name + "IsRejected"] = host.currentController === library }
        }
        try library.checkOpenLocalVideo(file)
        guard let opened = host.currentController as? AgentVideoWindow else { throw PetError("本地视频未进入原知识库窗口") }
        let initial = await ready(opened), player = initial["player"] as? [String: Any] ?? [:]
        checks["outsideProjectVideoUsesReadOnlyChild"] = opened.presentingWindow === window && opened.window?.isVisible == false
            && host.checkState()["depth"] as? Int == 2 && tasks.task(id)?.workspace == nil && initial["file"] as? String == file.path
        checks["selectedMP4DecodesExactFileAndStartsPaused"] = initial["sourceHash"] as? String == AgentFiles.hash(original)
            && player["width"] as? Int == 960 && player["height"] as? Int == 540 && player["paused"] as? Bool == true
        await opened.preview.checkWorkspace(time: 1.25, rate: 1.5, volume: 0.35, muted: true)
        for _ in 0..<40 {
            if let value = await opened.preview.capturePlayback(), abs(value.time - 1.25) < 0.15 { break }
            await wait(0.05)
        }
        guard let saved = try await host.captureWorkspaceRecovery(active: true),
              let position = saved.libraryVideo?.video.playback else { throw PetError("未保存知识库视频播放位置") }
        checks["videoRecoveryStoresOriginalPathAndLibraryFilter"] = saved.active && saved.root == "library" && saved.readers.isEmpty
            && saved.libraryVideo?.video.file == file.path && saved.libraryVideo?.video.sourceRoot == directory.path
            && saved.libraryVideo?.query == query && abs(position.time - 1.25) < 0.15 && position.rate == 1.5 && position.muted
        let journal = AgentWorkspaceRecovery(profile: output), windowID = UUID().uuidString
        try journal.saveWindow(.init(id: windowID, number: 1, taskID: id, tasks: [], knowledge: saved), expected: nil)
        guard let savedOnDisk = try journal.loadWindow(windowID)?.value.knowledge else { throw PetError("知识库视频恢复记录读取失败") }
        checks["libraryVideoRoundTripsThroughStrictRecoveryStorage"] = savedOnDisk == saved
        let firstSnapshot = initial["snapshotFolder"] as? String ?? ""
        host.finish()
        checks["finishingOldWindowReleasesVideoSnapshot"] = !firstSnapshot.isEmpty && !manager.fileExists(atPath: firstSnapshot)
        let parked = directory.appendingPathComponent("暂时移出.mp4")
        try manager.moveItem(at: file, to: parked)
        defer { if !manager.fileExists(atPath: file.path) { try? manager.moveItem(at: parked, to: file) } }
        try control.materializeKnowledgeRecovery(savedOnDisk)
        guard let restored = host.currentController as? AgentVideoWindow else { throw PetError("缺少原知识库视频的恢复页面") }
        let unavailable = await ready(restored)
        checks["missingVideoKeepsRetryPageAndPosition"] = unavailable["webPresent"] as? Bool == false
            && unavailable["reloadEnabled"] as? Bool == true && unavailable["status"] as? String == "视频文件已移动或路径已变化"
        try manager.moveItem(at: parked, to: file)
        await restored.preview.checkWorkspace(action: "refresh")
        var resumed = await ready(restored)
        for _ in 0..<40 {
            if let player = resumed["player"] as? [String: Any], player["restoreReady"] as? Bool == true,
               abs((player["time"] as? Double ?? 0) - 1.25) < 0.15 { break }
            await wait(0.05); resumed = await ready(restored)
        }
        let resumedPlayer = resumed["player"] as? [String: Any] ?? [:]
        checks["retryResumesOriginalPositionWhilePaused"] = resumed["sourceHash"] as? String == AgentFiles.hash(original)
            && abs((resumedPlayer["time"] as? Double ?? 0) - 1.25) < 0.15 && resumedPlayer["paused"] as? Bool == true
            && resumedPlayer["rate"] as? Double == 1.5 && resumedPlayer["muted"] as? Bool == true
        host.checkBack()
        guard let parent = host.currentController as? AgentKnowledgeLibraryWindow, let parentContent = parent.pageContentView else {
            throw PetError("视频返回后未显示原知识库")
        }
        let searchAfter = views(parentContent).compactMap { $0 as? NSSearchField }.first { $0.accessibilityLabel() == "搜索知识库" }
        checks["backRestoresFilterAndVideoPickerFocus"] = searchAfter?.stringValue == query
            && (window.firstResponder as? NSView)?.identifier?.rawValue == "knowledge-open-local-video"
        checks["explicitBackClearsVideoRecovery"] = try await host.captureWorkspaceRecovery(active: true) == nil
        try parent.checkOpenLocalVideo(fixture.webm)
        guard let webm = host.currentController as? AgentVideoWindow else { throw PetError("所选 WebM 未进入知识库播放器") }
        let webmState = await ready(webm), webmPlayer = webmState["player"] as? [String: Any] ?? [:]
        checks["localPickerEntryAlsoPlaysWebM"] = try webmState["sourceHash"] as? String == AgentFiles.hash(Data(contentsOf: fixture.webm))
            && webmPlayer["width"] as? Int == 960 && webmPlayer["paused"] as? Bool == true
        host.checkBack()
        checks["originalReadOnlyVideoAndTaskDataRemain"] = try Data(contentsOf: file) == original
            && manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == mode
            && tasks.task(id)?.draft == draft && tasks.task(id)?.messages.isEmpty == true && tasks.task(id)?.artifacts.isEmpty == true
        window.setFrame(frame, display: true)
        return checks
    }
}
