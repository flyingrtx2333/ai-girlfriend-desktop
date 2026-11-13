import AppKit

@MainActor extension ControlWindow {
    func checkArtifactOpening(_ fixture: AppDelegate.ArtifactWorkspaceFixture, output: URL, app: AppDelegate) async throws -> [String: Bool] {
        guard app.checkDirectory != nil, let tasks = app.agentStore else { throw PetError("产物打开位置仅使用独立验收资料") }
        var checks: [String: Bool] = [:], states: [String: Any] = [:]
        let originalSettings = app.generalSettings.settings, host = taskWorkspace
        defer {
            try? app.generalSettings.save(originalSettings); showAgentTask(fixture.taskID)
            let report: [String: Any] = ["checks": checks, "states": states, "modelRequests": 0, "boundary": "Actual public local files, native artifact buttons and menus, existing editors and video player. No model output."]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("artifact-opening-report.json"))
        }
        func setDefault(_ location: AgentArtifactLocation) throws { var value = app.generalSettings.settings; value.artifactLocation = location; try app.generalSettings.save(value) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func fileButton(_ path: String) throws -> AgentInspectorFileButton {
            guard let root = window?.contentView, let row = descendants(root).compactMap({ $0 as? AgentInspectorFileButton }).first(where: { $0.section == 1 && $0.value == path && $0.menu != nil }) else { throw PetError("缺少实际产物菜单") }; return row
        }
        func menuItem(_ menu: NSMenu?, _ location: AgentArtifactLocation) throws -> NSMenuItem {
            guard let item = menu?.items.first(where: { $0.representedObject as? String == location.rawValue }), item.action != nil else { throw PetError("产物菜单缺少打开位置") }; return item
        }
        func invoke(_ item: NSMenuItem) { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
        func canvas(_ id: String, taskID: String, location: AgentArtifactLocation) async throws -> AgentCanvasWindow {
            for _ in 0..<300 {
                if let editor = tasks.canvases.windows[taskID + ":" + id], editor.workspaceReadback()["rendering"] as? Bool == false,
                   (editor.settingsHostWindow == nil) == (location == .window), editor.workspaceReadback()["loadedHash"] as? String == (try tasks.canvases.record(id, taskID: taskID)).hash { return editor }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw PetError("画布打开位置或实际渲染未就绪")
        }
        let files = try AgentFiles(workspace: fixture.workspace.path), guide = fixture.workspace.appendingPathComponent("成果说明.md"), video = fixture.workspace.appendingPathComponent("opening.mp4")
        let original = try files.readData(guide), originalHash = AgentFiles.hash(original), draft = "# 公开产物\n\n切换位置时保留的人工编辑。\n"
        showAgentTask(fixture.taskID); show(tab: "chat"); try setDefault(.workspace)
        openAgentRecordItem(section: 1, value: guide.path)
        guard let record = checkArtifactDocument(guide, taskID: fixture.taskID) else { throw PetError("正文未进入原任务工作区") }
        await record.waitForDocumentCheck()
        checks["DefaultWorkspaceUsesActualTaskTab"] = host.currentController === record && record.settingsHostWindow === window && record.window?.isVisible != true
        try setDefault(.window)
        checks["ChangingDefaultDoesNotMoveAnOpenEditor"] = host.currentController === record && record.settingsHostWindow === window
        openAgentRecordItem(section: 1, value: guide.path)
        checks["DefaultWindowReusesDocumentWithoutDuplicateTab"] = checkArtifactDocument(guide, taskID: fixture.taskID) === record && record.settingsHostWindow == nil && record.window?.isVisible == true && host.rootController(.document(guide.path)) == nil
        await record.checkTaskDocument(text: draft)
        checks["DirtyFloatingTextHasNotWrittenToDisk"] = try record.workspaceHasUnsavedChanges && files.fileHash(guide) == originalHash
        do { try requireTaskDeletionAllowed([fixture.taskID]); checks["DirtyFloatingTextBlocksTaskDeletion"] = false } catch { checks["DirtyFloatingTextBlocksTaskDeletion"] = true }
        let row = try fileButton(guide.path), inline = try menuItem(row.menu, .workspace), detached = try menuItem(row.menu, .window)
        let settingsFile = app.generalSettings.directory.appendingPathComponent("general.json"), settingsBytes = try Data(contentsOf: settingsFile)
        invoke(inline)
        let inlineState = await record.workspaceReadback()
        checks["FileMenuMovesSameDirtyTextIntoTaskWorkspace"] = host.currentController === record && record.settingsHostWindow === window && record.window?.isVisible != true && inlineState["draft"] as? String == draft && record.workspaceHasUnsavedChanges
        invoke(detached)
        let windowState = await record.workspaceReadback()
        checks["FileMenuMovesSameDirtyTextBackToWindow"] = record.settingsHostWindow == nil && record.window?.isVisible == true && windowState["draft"] as? String == draft && record.workspaceHasUnsavedChanges
        checks["OneOffMenuKeepsDefaultAndConfigurationBytes"] = try app.generalSettings.settings.artifactLocation == .window && Data(contentsOf: settingsFile) == settingsBytes
        showAgentTask(fixture.secondID); invoke(detached)
        checks["StaleArtifactMenuCannotOpenInAnotherTask"] = checkArtifactDocument(guide, taskID: fixture.secondID) == nil && checkArtifactDocument(guide, taskID: fixture.taskID) === record
        showAgentTask(fixture.taskID)
        await record.checkTaskDocument(action: "save")
        checks["MovedTextSavesActualDraftWithOriginalTaskCheckpoint"] = try !record.workspaceHasUnsavedChanges && files.readData(guide) == Data(draft.utf8) && tasks.task(fixture.taskID)?.changes.contains(where: { $0.path == guide.path && $0.beforeHash == originalHash }) == true
        await record.checkTaskDocument(text: String(decoding: original, as: UTF8.self), action: "save")
        checks["TextRestoreUsesSameEncodingAndOriginalBytes"] = try !record.workspaceHasUnsavedChanges && files.fileHash(guide) == originalHash
        record.window?.performClose(nil)
        checks["ClosingStandaloneTextRemovesItsOwnerRegistration"] = checkArtifactDocument(guide, taskID: fixture.taskID) == nil && record.window?.isVisible != true

        openAgentRecordItem(section: 1, value: video.path)
        guard let player = checkArtifactDocument(video, taskID: fixture.taskID) else { throw PetError("视频新窗口未创建") }
        await player.waitForDocumentCheck()
        var before: [String: Any] = [:]
        for _ in 0..<100 {
            before = await player.videoPreviewReadback()
            if let media = before["player"] as? [String: Any], (media["duration"] as? Double ?? 0) > 5, (media["error"] as? Int ?? -1) == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let media = before["player"] as? [String: Any] ?? [:]
        checks["DefaultVideoWindowHasActualPublicVideoMetadata"] = try player.settingsHostWindow == nil && player.window?.isVisible == true && before["sourceHash"] as? String == files.fileHash(video) && (media["duration"] as? Double ?? 0) > 5 && media["width"] as? Int == 960 && media["height"] as? Int == 540 && media["error"] as? Int == 0
        let videoRow = try fileButton(video.path)
        invoke(try menuItem(videoRow.menu, .workspace))
        let after = await player.videoPreviewReadback()
        checks["VideoMenuMovesExistingPlayerWithoutReplacingSnapshot"] = player.settingsHostWindow === window && host.currentController === player && after["snapshotFolder"] as? String == before["snapshotFolder"] as? String && after["sourceHash"] as? String == before["sourceHash"] as? String
        invoke(try menuItem(videoRow.menu, .window))
        checks["VideoMenuCanReturnToStandaloneWindow"] = player.settingsHostWindow == nil && player.window?.isVisible == true && host.rootController(.document(video.path)) == nil
        player.window?.performClose(nil)
        checks["ClosingVideoDisposesPrivateSnapshotAndRegistration"] = (before["snapshotFolder"] as? String).map { !$0.isEmpty && !FileManager.default.fileExists(atPath: $0) } == true && checkArtifactDocument(video, taskID: fixture.taskID) == nil
        states["videoBeforeMove"] = before; states["videoAfterMove"] = after; states["textInline"] = inlineState; states["textWindow"] = windowState

        let officeFile = fixture.workspace.appendingPathComponent("sample.docx")
        openAgentRecordItem(section: 1, value: officeFile.path)
        for _ in 0..<300 {
            if let editor = tasks.offices.windows[officeFile.path], editor.settingsHostWindow == nil, editor.window?.isVisible == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let office = tasks.offices.windows[officeFile.path] else { throw PetError("默认位置未打开办公文件") }
        checks["DefaultOfficeWindowUsesExistingWorkerAndTask"] = office.settingsHostWindow == nil && office.window?.isVisible == true && office.taskID == fixture.taskID
        _ = try await tasks.offices.show(officeFile.path, taskID: fixture.taskID, location: .workspace)
        openAgentRecordItem(section: 1, value: "canvas://" + fixture.firstCanvas)
        let first = try await canvas(fixture.firstCanvas, taskID: fixture.taskID, location: .window)
        let rendering = try await first.inspect()
        checks["DefaultCanvasWindowUsesActualTaskAndRenderedSource"] = first.window?.isVisible == true && first.taskID == fixture.taskID && (rendering["text"] as? String)?.contains("项目核对") == true
        guard let root = window?.contentView, let canvasRow = descendants(root).compactMap({ $0 as? AgentCanvasPreviewRow }).first(where: { $0.menu != nil }) else { throw PetError("缺少实际画布菜单") }
        invoke(try menuItem(canvasRow.menu, .workspace))
        checks["CanvasMenuUsesOriginalEditorAndTaskTab"] = try await canvas(fixture.firstCanvas, taskID: fixture.taskID, location: .workspace) === first && host.currentController === first
        invoke(try menuItem(canvasRow.menu, .window))
        checks["CanvasMenuReturnsSameEditorToWindow"] = try await canvas(fixture.firstCanvas, taskID: fixture.taskID, location: .window) === first && first.window?.isVisible == true
        showAgentTask(fixture.standaloneID)
        openAgentRecordItem(section: 1, value: "canvas://" + fixture.standaloneCanvas)
        let standalone = try await canvas(fixture.standaloneCanvas, taskID: fixture.standaloneID, location: .window)
        checks["AskWithoutWorkspaceCanUseDefaultCanvasWindow"] = tasks.task(fixture.standaloneID)?.workspace == nil && tasks.task(fixture.standaloneID)?.mode == .ask && standalone.window?.isVisible == true
        first.window?.performClose(nil); standalone.window?.performClose(nil)
        checks["CleanStandaloneCanvasWindowsCloseAndReleaseOwners"] = tasks.canvases.windows.isEmpty
        checks["MenusAndDefaultHaveNotChangedTaskDrafts"] = tasks.task(fixture.taskID)?.draft == "保留办公任务输入草稿。" && tasks.task(fixture.secondID)?.draft == "保留另一任务输入草稿。" && tasks.task(fixture.standaloneID)?.draft == "保留无工作区输入草稿。"
        checks["NoModelResponsesOrReceipts"] = tasks.tasks.allSatisfy { $0.messages.allSatisfy { !$0.isReply } && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
        return checks
    }
}
