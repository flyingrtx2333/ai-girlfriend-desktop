import AppKit

@MainActor extension AppDelegate {
    struct WorkspaceRecoveryFixture: Codable {
        var first: String, second: String, standalone: String
        var guide: String, plain: String, mainWindow: String, childWindow: String
        var guideHash: String, plainHash: String
        var firstDraft: String, secondDraft: String, childDraft: String, memoryDraft: String, globalDraft: String
        var mode = 0
    }
    func runWorkspaceRecoveryLifecycleCheck(_ output: URL, interactive: Bool = false) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("恢复验收禁止模型请求") }
            let fixtureURL = output.appendingPathComponent("workspace-recovery-fixture.json")
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            func editor(_ window: ControlWindow) throws -> AgentRecordWindow {
                guard let record = window.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("文本编辑器未进入实际工作区") }; return record
            }
            let fixture: WorkspaceRecoveryFixture
            if stage == "seed" {
                let project = output.appendingPathComponent("public-recovery-project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let files = try AgentFiles(workspace: project.path), guide = try files.resolve("公开文档.md"), plain = try files.resolve("original-utf16.txt")
                let guideBytes = Data([0xEF, 0xBB, 0xBF]) + Data("# 公开恢复文档\r\n\r\nORIGINAL_GUIDE_PUBLIC_138\r\n".utf8)
                let plainBytes = try AgentTextFormat(encoding: .utf16LE, bom: true).encode("ORIGINAL_UTF16_PUBLIC_295\r\n")
                try files.writeData(guideBytes, to: guide); try files.writeData(plainBytes, to: plain)
                let first = tasks.create(title: "恢复验收 · 第一任务", workspace: project.path), second = tasks.create(title: "恢复验收 · 第二任务", workspace: project.path), standalone = tasks.create(title: "恢复验收 · 无工作区问答", mode: .ask, workMode: .general)
                for id in [first, second, standalone] { tasks.update(id) { $0.draft = "保留原任务输入 PUBLIC_482" } }
                control.showAgentTask(first); control.show(tab: "chat"); control.showTaskDocument(guide.path)
                let firstDraft = "# 恢复的 Markdown\r\n\r\nFIRST_UNSAVED_PUBLIC_937\r\n", secondDraft = "SECOND_UNSAVED_UTF16_PUBLIC_624\r\n", childDraft = "CHILD_WINDOW_UNSAVED_PUBLIC_853\r\n"
                let memoryDraft = "PROJECT_MEMORY_UNSAVED_PUBLIC_176\n", globalDraft = "GLOBAL_MEMORY_UNSAVED_PUBLIC_943\n"
                await (try editor(control)).checkTaskDocument(text: firstDraft)
                control.presentAgentRecords(section: 5); let memory = try editor(control); memory.selectItem(section: 5, value: AgentMemoryScope.project.rawValue); await memory.checkTaskDocument(text: memoryDraft)
                control.showAgentTask(second); control.showTaskDocument(plain.path); await (try editor(control)).checkTaskDocument(text: secondDraft)
                control.showAgentTask(standalone); control.presentAgentRecords(section: 5); let global = try editor(control); global.selectItem(section: 5, value: AgentMemoryScope.global.rawValue); await global.checkTaskDocument(text: globalDraft)
                control.showAgentTask(first); control.taskWorkspace.checkSelect(.document(guide.path))
                openTaskWindow(first, from: control)
                guard let child = additionalTaskWindows.last else { throw PetError("独立任务窗口未创建") }
                child.showTaskDocument(plain.path); await (try editor(child)).checkTaskDocument(text: childDraft)
                child.taskWorkspace.checkExpand()
                await (try editor(control)).checkTaskDocument(action: "preview")
                guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let childID = child.workspaceSession?.id else { throw PetError("实际工作区未保存") }
                fixture = .init(first: first, second: second, standalone: standalone, guide: guide.path, plain: plain.path, mainWindow: mainID, childWindow: childID,
                    guideHash: AgentFiles.hash(guideBytes), plainHash: AgentFiles.hash(plainBytes), firstDraft: firstDraft, secondDraft: secondDraft, childDraft: childDraft, memoryDraft: memoryDraft, globalDraft: globalDraft)
                let encoded = try JSONEncoder().encode(fixture); try encoded.write(to: fixtureURL, options: .atomic)
                checks["multipleTasksKeepIndependentPrivateDrafts"] = control.taskWorkspace.recoveryLayouts.count == 3 && child.taskWorkspace.recoveryLayouts.count == 1
                checks["multipleWindowsUseDistinctPersistentIdentity"] = mainID != childID
                checks["originalMarkdownAndUTF16BytesRemainExact"] = try files.fileHash(guide) == fixture.guideHash && files.fileHash(plain) == fixture.plainHash
                checks["memoryAutosaveDoesNotWriteProjectOrGlobalMemory"] = !FileManager.default.fileExists(atPath: project.appendingPathComponent(".bluefatfish/memory.md").path) && !FileManager.default.fileExists(atPath: tasks.directory.appendingPathComponent("memory.md").path)
                checks["actualRootRecordsEligibleForHotExit"] = control.workspaceSession?.preservedEditors.count == 4 && child.workspaceSession?.preservedEditors.count == 1
                let journal = AgentWorkspaceRecovery(profile: store.directory), saved = try journal.loadWindow(mainID)
                checks["layoutPersistsSelectionAndCachedTaskTabs"] = saved?.value.tasks.first(where: { $0.taskID == first })?.selected == "document:" + guide.path && saved?.value.closed == false
                checks["childExpandedStatePersists"] = try journal.loadWindow(childID)?.value.tasks.first?.expanded == true
                if let tab = saved?.value.tasks.first(where: { $0.taskID == first })?.tabs.first(where: { $0.root == "document:" + guide.path }), let page = try journal.loadPage(windowID: mainID, pageID: tab.id, taskID: first) {
                    checks["previewModeChangePersistsWithoutAnotherTextEdit"] = try AgentRecordWindow.recoveryState(page.saved.value).mode == 0
                } else { checks["previewModeChangePersistsWithoutAnotherTextEdit"] = false }
            } else {
                fixture = try JSONDecoder().decode(WorkspaceRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(), let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.childWindow }) else { throw PetError("持久窗口未恢复") }
                checks["sameMainAndChildWindowIdentitiesRestore"] = control.workspaceSession?.id == fixture.mainWindow && child.taskWindowNumber == 2
                checks["selectedMarkdownRestoresWithUnsavedText"] = try editor(control).captureWorkspaceRecovery().dirty && AgentRecordWindow.recoveryState(editor(control).captureWorkspaceRecovery()).text == fixture.firstDraft
                checks["sourceVersionAndBOMCRLFRetained"] = try AgentRecordWindow.recoveryState(editor(control).captureWorkspaceRecovery()).openedHash == fixture.guideHash && AgentRecordWindow.recoveryState(editor(control).captureWorkspaceRecovery()).bom
                checks["previewModeRestoresAcrossProcessRestart"] = try AgentRecordWindow.recoveryState(editor(control).captureWorkspaceRecovery()).mode == fixture.mode
                checks["childWindowRestoresItsOwnDraftAndExpansion"] = try AgentRecordWindow.recoveryState(editor(child).captureWorkspaceRecovery()).text == fixture.childDraft && child.taskWorkspace.expanded
                control.showAgentTask(fixture.second); control.show(tab: "chat"); guard await flushWorkspaceWindows() else { throw PetError("第二任务恢复失败") }
                var value = try AgentRecordWindow.recoveryState(editor(control).captureWorkspaceRecovery())
                checks["secondTaskRestoresUTF16DraftAndOriginalVersion"] = value.text == fixture.secondDraft && value.encoding == AgentTextEncoding.utf16LE.rawValue && value.bom && value.openedHash == fixture.plainHash
                control.showAgentTask(fixture.standalone); control.show(tab: "chat"); guard await flushWorkspaceWindows() else { throw PetError("无工作区草稿恢复失败") }
                value = try AgentRecordWindow.recoveryState(editor(control).captureWorkspaceRecovery())
                checks["noWorkspaceAskRestoresGlobalMemoryDraft"] = value.text == fixture.globalDraft && value.section == 5 && value.selection == AgentMemoryScope.global.rawValue
                control.showAgentTask(fixture.first); control.show(tab: "chat"); control.taskWorkspace.checkSelect(.records); guard await flushWorkspaceWindows() else { throw PetError("项目记忆草稿恢复失败") }
                value = try AgentRecordWindow.recoveryState(editor(control).captureWorkspaceRecovery())
                checks["projectMemoryRestoresOriginalSourceAndDraft"] = value.text == fixture.memoryDraft && value.memoryWorkspace == URL(fileURLWithPath: fixture.guide).deletingLastPathComponent().path && value.openedHash == AgentFiles.hash(Data())
                control.taskWorkspace.checkSelect(.document(fixture.guide)); guard await flushWorkspaceWindows() else { throw PetError("文件标签恢复失败") }
                let original = try editor(control), layout = store.directory.appendingPathComponent("workspace-recovery/" + fixture.mainWindow + "/layout.json")
                if !interactive {
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: layout.path)
                    await original.checkTaskDocument(text: fixture.firstDraft + "LATEST_EDIT_PUBLIC_529\r\n")
                    checks["readOnlyRecoveryLayoutRejectsCloseCheckpoint"] = !(await control.flushWorkspaceRecovery())
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.path)
                    checks["partialPageWriteCanRetryAfterLayoutPermissionRestores"] = await control.flushWorkspaceRecovery()
                    await original.checkTaskDocument(text: fixture.firstDraft); guard await flushWorkspaceWindows() else { throw PetError("最后编辑未保存到恢复区") }
                    let file = URL(fileURLWithPath: fixture.guide), files = try AgentFiles(workspace: file.deletingLastPathComponent().path), before = try files.readData(file)
                    let external = Data("EXTERNAL_CHANGE_PUBLIC_740\n".utf8); try files.writeData(external, to: file)
                    await original.checkTaskDocument(action: "save")
                    checks["restoredOldVersionCannotOverwriteExternalFileChange"] = try files.readData(file) == external && control.taskWorkspace.currentController is AgentFileConflictWindow && AgentRecordWindow.recoveryState(original.captureWorkspaceRecovery()).openedHash == fixture.guideHash
                    control.taskWorkspace.checkBack(); try files.writeData(before, to: file)
                    await original.checkTaskDocument(action: "preview")
                }
                checks["taskComposerDraftsRemainExact"] = [fixture.first, fixture.second, fixture.standalone].allSatisfy { tasks.task($0)?.draft == "保留原任务输入 PUBLIC_482" }
                let files = try AgentFiles(workspace: URL(fileURLWithPath: fixture.guide).deletingLastPathComponent().path)
                checks["sourceFilesRemainExactAfterRestartAndConflict"] = try files.fileHash(URL(fileURLWithPath: fixture.guide)) == fixture.guideHash && files.fileHash(URL(fileURLWithPath: fixture.plain)) == fixture.plainHash
            }
            report["stage"] = stage; report["fixture"] = fixtureURL.path
            report["mainWorkspace"] = control.taskWorkspace.checkState()
            checks["modelRuntimeMakesNoRequest"] = requests == 0
            checks["allWorkspaceSnapshotsCurrent"] = await flushWorkspaceWindows()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["scope"] = "Window/tab layouts and Record text/Markdown/memory drafts; Office, Canvas selection, browser/annotation, MCP parameters and detached editors remain in the full recovery scope."
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "workspace-recovery-ui-ready.json" : "workspace-recovery-lifecycle-report.json"))
    }
}
