import AppKit

@MainActor extension AppDelegate {
    struct ArtifactWorkspaceFixture { let taskID: String, secondID: String, standaloneID: String, workspace: URL, firstCanvas: String, secondCanvas: String, standaloneCanvas: String }
    func prepareArtifactWorkspaceUI(_ output: URL) async throws -> ArtifactWorkspaceFixture {
        guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("产物工作区验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
        let project = output.appendingPathComponent("public-project"), originals = output.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let initialized = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: output.appendingPathComponent("tmp"), network: false, timeout: 10, gitDirectory: project.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", project.path, "init", "-b", "main"])
        guard !initialized.failed else { throw PetError(initialized.text) }
        for format in AgentOffice.formats { try FileManager.default.copyItem(at: originals.appendingPathComponent("sample." + format), to: project.appendingPathComponent("sample." + format)) }
        let first = tasks.create(title: "办公与画布工作区", workspace: project.path), second = tasks.create(title: "另一任务的产物", workspace: project.path), standalone = tasks.create(title: "无工作区的画布", mode: .ask, workMode: .general)
        let code = "import React from 'react'; export default function Canvas(){const [n,setN]=React.useState(0);return <main style={{padding:24,color:'#173d42',background:'#f6fbfa',minHeight:'100vh'}}><h1>项目核对</h1><p>工作区画布 · 原始版本</p><button onClick={()=>setN(n+1)}>已核对 {n} 项</button></main>}"
        let a = try tasks.canvases.create(title: "项目核对", source: code, taskID: first), b = try tasks.canvases.create(title: "交付记录", source: code.replacingOccurrences(of: "项目核对", with: "交付记录"), taskID: first), c = try tasks.canvases.create(title: "无工作区画布", source: code.replacingOccurrences(of: "项目核对", with: "无工作区画布"), taskID: standalone)
        tasks.update(first) { $0.artifacts = AgentOffice.formats.map { project.appendingPathComponent("sample." + $0).path }; $0.draft = "保留办公任务输入草稿。" }
        tasks.update(second) { $0.draft = "保留另一任务输入草稿。" }; tasks.update(standalone) { $0.draft = "保留无工作区输入草稿。" }
        try tasks.organization.register(project.path, mode: .coding)
        let fixture = ArtifactWorkspaceFixture(taskID: first, secondID: second, standaloneID: standalone, workspace: project, firstCanvas: a.id, secondCanvas: b.id, standaloneCanvas: c.id)
        let value: [String: Any] = ["taskID": first, "secondID": second, "standaloneID": standalone, "workspace": project.path, "firstCanvas": a.id, "secondCanvas": b.id, "standaloneCanvas": c.id, "canvasSourceHash": a.hash, "modelTransmissions": 0]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("artifact-workspace-fixtures.json"))
        control.showAgentTask(first); control.show(tab: "chat"); _ = try await tasks.offices.show(project.appendingPathComponent("sample.docx").path, taskID: first)
        return fixture
    }
    func reopenArtifactWorkspaceUI(_ output: URL) async throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("artifact-workspace-fixtures.json"))) as? [String: Any]
        guard let id = value?["taskID"] as? String, let root = value?["workspace"] as? String, let tasks = agentStore, tasks.task(id) != nil else { throw PetError("保留的产物任务不存在") }
        control.showAgentTask(id); control.show(tab: "chat"); _ = try await tasks.offices.show(URL(fileURLWithPath: root).appendingPathComponent("sample.docx").path, taskID: id)
    }
    func runArtifactWorkspaceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        defer { agentRuntime?.stopAll() }
        do {
            let binary = Bundle.main.executableURL!; report["appPID"] = getpid(); report["binaryHash"] = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("产物工作区验收禁止模型请求") }
            let fixture = try await prepareArtifactWorkspaceUI(output), host = control.taskWorkspace, files = try AgentFiles(workspace: fixture.workspace.path)
            var geometry: [String: Any] = [:], saved: [String: String] = [:]
            func inspectLayout(_ name: String) async {
                for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    control.window?.appearance = NSAppearance(named: theme)
                    for (kind, size) in [("split", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                        control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.05)
                        let state = await control.taskWorkspaceReadback(); geometry[name + "-" + appearance + "-" + kind] = state
                        for (key, pass) in host.checkState()["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + appearance + "-" + kind + "-" + key] = pass }
                        let page: [String: Any]
                        if let office = host.currentController as? AgentOfficeWindow { page = await office.workspaceReadback() }
                        else { page = (host.currentController as? AgentCanvasWindow)?.workspaceReadback() ?? [:] }
                        for (key, pass) in page["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + appearance + "-" + kind + "-" + key] = pass }
                        checks[name + "-" + appearance + "-" + kind + "-conversationPreserved"] = state["draft"] as? String == tasks.task(control.agentTaskID ?? "")?.draft && state["conversationVisible"] as? Bool == (kind == "split" && !host.expanded)
                    }
                }
                control.window?.setContentSize(NSSize(width: 1200, height: 774)); control.window?.contentView?.layoutSubtreeIfNeeded()
            }
            for format in AgentOffice.formats {
                let file = fixture.workspace.appendingPathComponent("sample." + format), original = try files.fileHash(file), editor = try await tasks.offices.show(file.path, taskID: fixture.taskID)
                let actual = try await editor.inspect(format == "xlsx" ? ["sheet": "审阅", "range": "A1"] : [:]), version = actual["version"] as? String ?? ""
                await inspectLayout(format)
                var step: [String: Any]
                if format == "docx" {
                    guard let paragraph = (actual["paragraphs"] as? [[String: Any]])?.first(where: { $0["text"] as? String == "审阅人：待填写" }) else { throw PetError("Word 公开输入不存在") }
                    step = ["op": "replaceText", "target": ["kind": "paragraph", "story": paragraph["story"]!, "paraId": paragraph["id"]!], "text": "审阅人：工作区验收", "expect": ["text": "审阅人：待填写"]]
                } else if format == "xlsx" {
                    guard let sheet = actual["sheet"] as? String else { throw PetError("Excel 公开输入不存在") }
                    step = ["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "A1"]], "inputs": [["审阅人：工作区验收"]]]
                } else {
                    guard let story = (actual["stories"] as? [[String: Any]])?.first(where: { $0["text"] as? String == "审阅人：待填写" }) else { throw PetError("幻灯片公开输入不存在") }
                    step = ["op": "replaceText", "target": ["kind": "search", "within": ["slideId": story["slideId"]!, "shapeId": story["shapeId"]!, "storyId": story["id"]!], "text": "审阅人：待填写"], "text": "审阅人：工作区验收", "expect": ["text": "审阅人：待填写"]]
                }
                try await editor.checkWorkspaceEdit(["expectVersion": version, "steps": [step]])
                checks[format + "UnsavedEditHasNoDiskWrite"] = try editor.dirty && files.fileHash(file) == original
                control.presentTaskContext(section: 0); control.showAgentTask(fixture.secondID); control.showAgentTask(fixture.taskID)
                let returned = try await tasks.offices.show(file.path, taskID: fixture.taskID)
                checks[format + "TaskAndTabSwitchRetainsActualEditor"] = returned === editor && returned.dirty && host.currentController === editor
                host.checkHide(); _ = try await tasks.offices.show(file.path, taskID: fixture.taskID)
                let hiddenState = await editor.workspaceReadback()
                checks[format + "HiddenEditorRetainsDraftAndWorker"] = host.requested && editor.dirty && !(hiddenState["snapshot"] as? String ?? "").isEmpty
                do { try tasks.offices.requireDeletionAllowed([fixture.taskID]); checks[format + "UnsavedOfficeBlocksTaskDeletion"] = false } catch { checks[format + "UnsavedOfficeBlocksTaskDeletion"] = true }
                try await editor.saveDocument(); let after = try files.fileHash(file); saved[format] = after
                checks[format + "ManualSaveCreatesActualCheckpoint"] = !editor.dirty && after != original && tasks.task(fixture.taskID)?.changes.contains { $0.path == file.path && $0.beforeHash == original && $0.afterHash == after } == true
                let state = await editor.workspaceReadback()
                if format == "docx" {
                    do { _ = try await tasks.offices.show(file.path, taskID: fixture.secondID); checks["officeOwnershipCannotMoveToAnotherTask"] = false } catch { checks["officeOwnershipCannotMoveToAnotherTask"] = editor.taskID == fixture.taskID && tasks.offices.windows[file.path] === editor }
                    report["closedOfficeState"] = state
                }
            }
            let a = try await tasks.canvases.show(fixture.firstCanvas, taskID: fixture.taskID), initial = try tasks.canvases.source(fixture.firstCanvas, taskID: fixture.taskID)
            await inspectLayout("canvas")
            let draft = initial.code.replacingOccurrences(of: "原始版本", with: "保留在标签页的草稿")
            await a.checkWorkspaceSource(draft)
            let b = try await tasks.canvases.show(fixture.secondCanvas, taskID: fixture.taskID)
            let reloaded = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let diskSource = try tasks.canvases.source(fixture.firstCanvas, taskID: fixture.taskID).code
            checks["canvasTabsHaveIndependentEditors"] = a !== b && host.rootController(.canvas(fixture.firstCanvas)) === a && host.rootController(.canvas(fixture.secondCanvas)) === b
            checks["canvasNavigationFlushesPendingDraftToDisk"] = reloaded.task(fixture.taskID)?.canvases?.first(where: { $0.id == fixture.firstCanvas })?.draft == draft && diskSource == initial.code
            let existing = try await tasks.canvases.show(fixture.firstCanvas, taskID: fixture.taskID)
            checks["canvasReopenRetainsUnsavedBytes"] = existing === a && a.workspaceReadback()["source"] as? String == draft && a.workspaceHasUnsavedChanges
            let presenter = tasks.canvases.onPresent; tasks.canvases.onPresent = { _, _ in throw PetError("验收：当前页面暂不能离开") }
            do { _ = try await tasks.canvases.show(fixture.firstCanvas, taskID: fixture.taskID); checks["failedPresentationKeepsExistingCanvasDraft"] = false } catch { checks["failedPresentationKeepsExistingCanvasDraft"] = tasks.canvases.windows.values.contains(where: { $0 === a }) && a.workspaceReadback()["source"] as? String == draft }
            tasks.canvases.onPresent = presenter
            await a.checkWorkspaceSource(action: "save")
            let savedCanvas = try tasks.canvases.source(fixture.firstCanvas, taskID: fixture.taskID)
            let savedRendering = try await a.inspect()
            checks["canvasSaveUsesExactDraftAndPreservesHistory"] = savedCanvas.code == draft && savedCanvas.record.versions.contains { $0.hash == initial.record.hash } && !a.workspaceHasUnsavedChanges && (savedRendering["text"] as? String)?.contains("保留在标签页的草稿") == true
            await a.checkWorkspaceSource(draft + "\n// 临时修改后恢复已保存内容\n")
            await a.checkWorkspaceSource(draft, action: "save")
            let unchangedCanvas = try tasks.canvases.source(fixture.firstCanvas, taskID: fixture.taskID)
            checks["canvasSavingRestoredContentClearsUnsavedStatus"] = !a.workspaceHasUnsavedChanges && a.workspaceReadback()["state"] as? String == ""
            checks["canvasSavingRestoredContentKeepsVersionsAndClearsDraft"] = unchangedCanvas.code == draft && unchangedCanvas.record.versions.map(\.hash) == savedCanvas.record.versions.map(\.hash) && unchangedCanvas.record.draft == nil
            await a.checkWorkspaceSource(action: "skill")
            checks["skillPackagingIsChildOfItsCanvasTab"] = host.currentController is AgentCanvasSkillWindow && host.currentController?.presentingWindow === control.window && host.checkState()["depth"] as? Int == 2 && host.currentController?.window?.isVisible != true
            host.checkBack(); checks["skillBackRetainsItsCanvasEditor"] = host.currentController === a
            let docx = fixture.workspace.appendingPathComponent("sample.docx"), office = tasks.offices.windows[docx.path]!, officeState = await office.workspaceReadback(), selected = host.selectedRoot
            office.finishClose()
            checks["closingInactiveOfficeKeepsSelectedCanvas"] = host.selectedRoot == selected && host.currentController === a && host.rootController(.document(docx.path)) == nil
            checks["closedOfficeRemovesPrivateSnapshot"] = (officeState["snapshot"] as? String).map { !$0.isEmpty && !FileManager.default.fileExists(atPath: $0) } == true
            if let url = URL(string: officeState["loopbackURL"] as? String ?? "") {
                do { _ = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)); checks["closedOfficeStopsItsLoopbackService"] = false } catch { checks["closedOfficeStopsItsLoopbackService"] = true }
            }
            let xlsx = fixture.workspace.appendingPathComponent("sample.xlsx"); host.checkClose(.document(xlsx.path))
            do { try host.requireDeletionAllowed([fixture.taskID]); checks["asyncCloseBlocksReentrantDeletion"] = false } catch { checks["asyncCloseBlocksReentrantDeletion"] = true }
            for _ in 0..<100 { if host.checkState()["closing"] as? Bool == false { break }; await wait(0.05) }
            checks["asyncTabCloseWaitsForWorkerAndDisposesEditor"] = host.rootController(.document(xlsx.path)) == nil && tasks.offices.windows[xlsx.path] == nil
            control.showAgentTask(fixture.standaloneID); let standalone = try await tasks.canvases.show(fixture.standaloneCanvas, taskID: fixture.standaloneID)
            let standaloneRendering = try await standalone.inspect()
            checks["askTaskWithoutWorkspaceCanUseCanvasTab"] = tasks.task(fixture.standaloneID)?.workspace == nil && tasks.task(fixture.standaloneID)?.mode == .ask && host.currentController === standalone && (standaloneRendering["text"] as? String)?.contains("无工作区画布") == true
            control.showAgentTask(fixture.taskID); _ = try await tasks.canvases.show(fixture.firstCanvas, taskID: fixture.taskID)
            let archivedDraft = draft + "\n// 归档保留的未保存草稿\n"; await a.checkWorkspaceSource(archivedDraft)
            _ = try await tasks.canvases.show(fixture.secondCanvas, taskID: fixture.taskID); await b.checkWorkspaceSource(action: "skill")
            tasks.update(fixture.taskID) { $0.archived = true }
            checks["archiveClosesAllTaskCanvasEditorsAndKeepsDraft"] = !tasks.canvases.windows.values.contains { $0.taskID == fixture.taskID } && tasks.task(fixture.taskID)?.canvases?.first(where: { $0.id == fixture.firstCanvas })?.draft == archivedDraft && a.workspaceIsClosed && b.workspaceIsClosed && !host.controllers.contains { $0 === a || $0 === b || $0 is AgentCanvasSkillWindow }
            checks["composerDraftsRemainIndependent"] = tasks.task(fixture.taskID)?.draft == "保留办公任务输入草稿。" && tasks.task(fixture.secondID)?.draft == "保留另一任务输入草稿。" && tasks.task(fixture.standaloneID)?.draft == "保留无工作区输入草稿。"
            checks["noModelRequestsOrReceipts"] = requests == 0 && tasks.tasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            checks["allRemainingPagesAcceptAsyncClose"] = await host.canFinish()
            host.finish(); checks["finishedWorkspaceDisposesWorkersAndCanvasCache"] = tasks.offices.windows.isEmpty && tasks.canvases.windows.isEmpty && host.controllers.isEmpty
            report["geometry"] = geometry; report["savedOfficeHashes"] = saved; report["workspace"] = fixture.workspace.path; report["modelRequests"] = requests
        } catch { report["error"] = error.localizedDescription }
        report["modelRequests"] = requests; report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("artifact-workspace-report.json"))
    }
}
