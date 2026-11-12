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
        report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["workspace"] = f.workspace.path
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("knowledge-video-report.json"))
        return checks
    }
}
