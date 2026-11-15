import AppKit

@MainActor extension AppDelegate {
    struct FloatingRecoveryFixture: Codable {
        var taskID: String, otherID: String, windowID: String, otherWindowID: String
        var file: String, office: String, canvasID: String, base: String
        var main: [AgentWorkspaceRecovery.FloatingPage], other: [AgentWorkspaceRecovery.FloatingPage]
        var sourceHash: String, officeHash: String
        var officeView: String? = nil
        var browserDraft: String? = nil
    }
    func runFloatingRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("独立窗口恢复验收禁止模型请求") }
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let fixtureURL = output.appendingPathComponent("floating-recovery-fixture.json"), journal = AgentWorkspaceRecovery(profile: store.directory)
            let mainDraft = "# 独立文档\nPUBLIC_FLOATING_MAIN_417 中文😀\n", otherDraft = "# 另一任务\nPUBLIC_FLOATING_OTHER_618\n"
            let canvasDraft = "export default function Canvas(){return <main>PUBLIC_FLOATING_CANVAS_DRAFT_512</main>}\n"
            func layout(_ owner: ControlWindow) throws -> AgentWorkspaceRecovery.Window {
                guard let id = owner.workspaceSession?.id, let value = try journal.loadWindow(id) else { throw PetError("独立窗口布局尚未保存") }; return value.value
            }
            func record(_ owner: ControlWindow, file: String) throws -> AgentRecordWindow {
                guard let value = owner.workspaceSession?.floatingControllers.compactMap({ $0 as? AgentRecordWindow }).first(where: { $0.workspaceDocumentURL?.path == file }) else { throw PetError("独立文档未打开") }; return value
            }
            func form(_ browser: AgentBrowserWindow) async throws -> String {
                for _ in 0..<100 {
                    if let value = try? await browser.web.evaluateJavaScript("document.getElementById('note')?.value") as? String { return value }
                    await wait(0.05)
                }; throw PetError("独立网页尚未就绪")
            }
            func comparableOfficeView(_ text: String) throws -> String {
                var value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
                if var selection = value["selection"] as? [String: Any] {
                    for key in ["anchor", "focus"] {
                        if var point = selection[key] as? [String: Any] {
                            for field in ["paragraphID", "storyKind", "itemID"] { point.removeValue(forKey: field) }
                            selection[key] = point
                        }
                    }
                    value["selection"] = selection
                }
                return String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
            }
            func officeViewText(_ editor: AgentOfficeWindow) async throws -> String {
                let view = try await editor.checkWorkspaceView()
                return String(data: try JSONSerialization.data(withJSONObject: view, options: [.sortedKeys]), encoding: .utf8)!
            }
            let fixture: FloatingRecoveryFixture
            if stage == "seed" {
                let project = output.appendingPathComponent("workspace"), file = project.appendingPathComponent("draft.md"), officeFile = project.appendingPathComponent("sample.docx")
                let input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("browser-input.json"))) as! [String: String]
                guard let base = input["url"], URL(string: base)?.host == "127.0.0.1" else { throw PetError("只使用独立本机公开网页") }
                let id = tasks.create(title: "独立窗口恢复", workspace: project.path), other = tasks.create(title: "另一窗口的独立文档", workspace: project.path)
                for id in [id, other] { tasks.update(id) { $0.draft = "保留任务输入 PUBLIC_FLOATING_COMPOSER_273" } }
                control.showAgentTask(id); control.show(tab: "chat"); control.showTaskDocument(file.path)
                guard let first = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("主文档未打开") }
                await first.checkTaskDocument(text: mainDraft)
                let inlineID = control.taskWorkspace.recoveryEditors.first(where: { $0.2 === first })?.1.id
                try control.presentArtifactWindow(first, taskID: id)
                first.window?.setFrame(NSRect(x: 80, y: 130, width: 780, height: 540), display: true)
                let browser = try tasks.browser.show(taskID: id, title: "独立网页")
                _ = try await browser.open(URL(string: base + "form")!); await browser.checkWorkspace("separate")
                _ = try await browser.web.evaluateJavaScript("document.getElementById('note').value='PUBLIC_FLOATING_FORM_941';document.dispatchEvent(new Event('change',{bubbles:true}));")
                browser.window?.setFrame(NSRect(x: 120, y: 150, width: 800, height: 560), display: true)
                let office = try await tasks.offices.show(officeFile.path, taskID: id, location: .window)
                let actual = try await office.inspect([:])
                guard let version = actual["version"] as? String, let paragraph = (actual["paragraphs"] as? [[String: Any]])?.first(where: { $0["text"] as? String == "审阅人：待填写" }) else { throw PetError("真实 Word 段落不可读") }
                try await office.checkWorkspaceEdit(["expectVersion": version, "steps": [["op": "replaceText", "target": ["kind": "paragraph", "story": paragraph["story"]!, "paraId": paragraph["id"]!], "text": "审阅人：独立窗口草稿", "expect": ["text": "审阅人：待填写"]]]])
                office.window?.setFrame(NSRect(x: 80, y: 130, width: 780, height: 540), display: true)
                await wait(0.1)
                var officeView = try await office.checkWorkspaceView(); officeView["zoom"] = 2.0
                officeView["scroll"] = (officeView["scroll"] as? [[String: Any]] ?? []).map { entry in var entry = entry; entry["x"] = 30; entry["y"] = 180; return entry }
                let actualView = try await office.checkWorkspaceView(officeView)
                checks["narrowOfficeHasNondefaultZoomAndNonzeroScroll"] = actualView["zoom"] as? Double == 2.0 && (actualView["scroll"] as? [[String: Any]])?.contains { ($0["y"] as? Double ?? 0) > 0 } == true
                let canvasRecord = try tasks.canvases.create(title: "独立画布", source: "export default function Canvas(){return <main>PUBLIC_FLOATING_CANVAS_ORIGINAL</main>}\n", taskID: id)
                let canvas = try await tasks.canvases.show(canvasRecord.id, taskID: id, location: .window)
                await canvas.checkWorkspaceSource(canvasDraft)
                openTaskWindow(other, from: control)
                guard let child = additionalTaskWindows.first(where: { $0.agentTaskID == other }) else { throw PetError("另一任务窗口不可用") }
                child.showTaskDocument(file.path)
                guard let second = child.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("另一任务的同名文档未打开") }
                await second.checkTaskDocument(text: otherDraft); try child.presentArtifactWindow(second, taskID: other)
                guard await flushWorkspaceWindows() else { throw PetError("独立窗口初始状态未保存") }
                var main = try layout(control)
                checks["detachedDocumentKeepsItsOriginalTabIdentity"] = main.floating.contains { $0.tab.id == inlineID && $0.tab.root == "document:" + file.path }
                checks["allIndependentTypesPersistWithoutTaskTabDuplicates"] = Set(main.floating.map(\.tab.root)) == ["document:" + file.path, "document:" + officeFile.path, "browser", "canvas:" + canvasRecord.id] && main.tasks.allSatisfy { $0.tabs.isEmpty }
                let firstDraft = try AgentRecordWindow.recoveryState(await first.captureWorkspaceRecovery()), secondDraft = try AgentRecordWindow.recoveryState(await second.captureWorkspaceRecovery())
                checks["bothSameFileDraftsRemainIndependent"] = firstDraft.text == mainDraft && secondDraft.text == otherDraft
                let cleanFile = project.appendingPathComponent("closed.txt")
                control.showTaskDocument(cleanFile.path, location: .window)
                let clean = try record(control, file: cleanFile.path); clean.window?.performClose(nil)
                guard await flushWorkspaceWindows() else { throw PetError("明确关闭未保存") }
                checks["explicitCleanWindowCloseRemovesItsLayoutEntry"] = try !layout(control).floating.contains { $0.tab.root == "document:" + cleanFile.path }
                await browser.checkWorkspace("separate")
                checks["browserRehostReusesIdentityWithoutDuplicateFloatingOwner"] = control.taskWorkspace.recoveryEditors.first(where: { $0.2 === browser })?.1.id == main.floating.first(where: { $0.tab.root == "browser" })?.tab.id && control.workspaceSession?.ownsFloating(browser) == false
                await browser.checkWorkspace("separate")
                try child.presentArtifactWindow(first, taskID: id)
                guard await flushWorkspaceWindows() else { throw PetError("跨任务窗口移交未保存") }
                checks["transferHasExactlyOneDurableWindowOwner"] = try !layout(control).floating.contains { $0.tab.id == inlineID } && layout(child).floating.contains { $0.tab.id == inlineID && $0.taskID == id }
                try control.presentArtifactWindow(first, taskID: id)
                guard await flushWorkspaceWindows() else { throw PetError("原窗口移交未保存") }
                main = try layout(control)
                let firstMeta = main.floating.first(where: { $0.tab.root == "document:" + file.path })!
                let pagePath = store.directory.appendingPathComponent("workspace-recovery/" + main.id + "/pages/" + firstMeta.tab.id + ".json"), before = try Data(contentsOf: pagePath)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pagePath.path)
                await first.checkTaskDocument(text: mainDraft + "最后一笔 PUBLIC_FLOATING_LAST_832\n")
                let refused = !(await flushWorkspaceWindows()), retained = try Data(contentsOf: pagePath)
                checks["readOnlyFloatingCheckpointRetainsOldBytesAndLiveDraft"] = refused && retained == before && first.workspaceHasUnsavedChanges && control.workspaceSession?.preservedEditors.isEmpty == true
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pagePath.path)
                checks["floatingRetrySavesLatestDraftWithoutAnotherEdit"] = await flushWorkspaceWindows()
                checks["quitPreparationPreservesEveryIndependentEditor"] = await control.prepareOwnedTaskPanels(preservingRecovery: true) && control.workspaceSession?.floatingControllers.count == 4 && child.workspaceSession?.floatingControllers.count == 1
                let browserDraft = "PUBLIC_FLOATING_FORM_LAST_582"
                _ = try await browser.web.callAsyncJavaScript("document.getElementById('note').value=value;document.getElementById('details').value='PUBLIC_DETAILS_729 中文';document.getElementById('approved').checked=true;document.getElementById('choice').selectedIndex=1;document.getElementById('note').dispatchEvent(new Event('input',{bubbles:true}));", arguments: ["value": browserDraft], in: nil, contentWorld: .page)
                guard await flushWorkspaceWindows() else { throw PetError("网页最后填写尚未保存") }
                let formState = try AgentBrowserRecoveryState.decode(await browser.captureWorkspaceRecovery())
                checks["lastFormInputHasExplicitRecoveryWithoutNavigation"] = formState.pages.first?.forms?.values.first?.value == browserDraft && formState.pages.first?.url == base + "form" && formState.pages.first?.y == 0
                let forms = formState.pages.first?.forms
                checks["ordinaryTextCheckboxAndSelectionHaveCompleteDrafts"] = forms?.values.count == 4 && forms?.values[1].value == "PUBLIC_DETAILS_729 中文" && forms?.values[2].checked == true && forms?.values[3].selected == [1]
                checks["explicitFormDraftExcludesPasswordHiddenAndAutocompleteOff"] = forms?.signature.contains("credential") == false && forms?.signature.contains("hidden") == false && forms?.signature.contains("excluded") == false
                if let forms {
                    let refusal = "const note=document.getElementById('note'),name=note.name,value=note.value,before=window.recoveryInputEvents;note.name='PUBLIC_CHANGED_FORM';note.value='PUBLIC_KEEP_CURRENT';try{const restored=await(async()=>{" + AgentBrowserFormRecovery.restoreScript + "})();return restored===false&&note.value==='PUBLIC_KEEP_CURRENT'&&window.recoveryInputEvents===before;}finally{note.name=name;note.value=value;}"
                    checks["changedFormStructureKeepsCurrentFieldsAndSavedDraft"] = try await browser.web.callAsyncJavaScript(refusal, arguments: ["state": try forms.object()], in: nil, contentWorld: .page) as? Bool == true
                }
                fixture = .init(taskID: id, otherID: other, windowID: main.id, otherWindowID: try layout(child).id, file: file.path, office: officeFile.path, canvasID: canvasRecord.id, base: base,
                                main: try layout(control).floating, other: try layout(child).floating, sourceHash: try AgentFiles(workspace: project.path).fileHash(file), officeHash: try AgentFiles(workspace: project.path).fileHash(officeFile),
                                officeView: try await officeViewText(office), browserDraft: browserDraft)
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(FloatingRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows(); guard await flushWorkspaceWindows(), let child = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.otherWindowID }) else { throw PetError("原任务窗口未恢复") }
                let main = try layout(control), other = try layout(child)
                checks["sameWindowTaskAndFloatingIdentitiesRestore"] = main.id == fixture.windowID && main.floating.map(\.tab.id).sorted() == fixture.main.map(\.tab.id).sorted() && other.floating.map(\.tab.id).sorted() == fixture.other.map(\.tab.id).sorted()
                checks["explicitlyClosedWindowNeverResurrects"] = !main.floating.contains { $0.tab.root.hasSuffix("closed.txt") }
                if stage == "invalid" || stage == "retry" {
                    let metadata = fixture.main.first(where: { $0.tab.root == "document:" + fixture.file })!, page = store.directory.appendingPathComponent("workspace-recovery/" + fixture.windowID + "/pages/" + metadata.tab.id + ".json")
                    checks["unsupportedFloatingPageRemainsCold"] = control.workspaceSession?.floatingControllers.compactMap { $0 as? AgentRecordWindow }.isEmpty == true
                    checks["unsupportedFloatingPageOriginalBytesRetained"] = try Data(contentsOf: page) == Data(contentsOf: output.appendingPathComponent("invalid-page-input.json"))
                    if stage == "invalid" {
                        control.showTaskDocument(fixture.file, location: .window)
                        checks["normalOpenCannotOverwritePendingFloatingDraft"] = try Data(contentsOf: page) == Data(contentsOf: output.appendingPathComponent("invalid-page-input.json")) && control.workspaceSession?.floatingControllers.compactMap { $0 as? AgentRecordWindow }.isEmpty == true
                    }
                    if stage == "retry" {
                        try Data(contentsOf: output.appendingPathComponent("original-page.json")).write(to: page)
                        restoreFloatingWorkspaceWindows()
                        guard await flushWorkspaceWindows() else { throw PetError("菜单恢复重试未保存") }
                        let restored = try AgentRecordWindow.recoveryState(await record(control, file: fixture.file).captureWorkspaceRecovery())
                        checks["windowMenuRetryRecoversOriginalColdDraft"] = restored.text == mainDraft + "最后一笔 PUBLIC_FLOATING_LAST_832\n"
                        let status = await control.taskWorkspaceReadback()["status"] as? String ?? ""
                        checks["successfulFloatingRetryClearsOnlyItsOldError"] = status.isEmpty
                    }
                } else if stage != "observe" || !interactive {
                    let first = try record(control, file: fixture.file), second = try record(child, file: fixture.file)
                    let firstState = try AgentRecordWindow.recoveryState(await first.captureWorkspaceRecovery()), secondState = try AgentRecordWindow.recoveryState(await second.captureWorkspaceRecovery())
                    checks["distinctSameFileDirtyDraftsRestoreToOriginalTasks"] = firstState.text == mainDraft + "最后一笔 PUBLIC_FLOATING_LAST_832\n" && secondState.text == otherDraft && firstState.taskID == fixture.taskID && secondState.taskID == fixture.otherID
                    checks["originalIndependentDocumentGeometryRestores"] = main.floating.first(where: { $0.tab.root == "document:" + fixture.file })?.frame == fixture.main.first(where: { $0.tab.root == "document:" + fixture.file })?.frame
                    control.showTaskDocument(fixture.file)
                    checks["recordCanReturnToTaskWithSameRecoveryIdentity"] = control.taskWorkspace.recoveryEditors.first(where: { $0.2 === first })?.1.id == fixture.main.first(where: { $0.tab.root == "document:" + fixture.file })?.tab.id && control.workspaceSession?.ownsFloating(first) == false
                    try control.presentArtifactWindow(first, taskID: fixture.taskID)
                    await first.checkTaskDocument(text: firstState.text! + "继续编辑 PUBLIC_FLOATING_CONTINUE_951\n")
                    checks["restoredIndependentDocumentCanContinueEditing"] = try AgentRecordWindow.recoveryState(await first.captureWorkspaceRecovery()).text?.hasSuffix("继续编辑 PUBLIC_FLOATING_CONTINUE_951\n") == true
                }
                report["restoration"] = taskControls.map { $0.workspaceSession?.floatingRecoveryReadback ?? [:] }
                report["serviceAvailability"] = ["browser": tasks.browser.sessions[fixture.taskID] != nil, "office": tasks.offices.windows[fixture.office] != nil, "canvas": tasks.canvases.windows[fixture.taskID + ":" + fixture.canvasID] != nil]
                guard let browser = tasks.browser.sessions[fixture.taskID], let office = tasks.offices.windows[fixture.office], let canvas = tasks.canvases.windows[fixture.taskID + ":" + fixture.canvasID] else { throw PetError("浏览器／Office／Canvas 独立窗口未恢复") }
                if !interactive, let expected = fixture.officeView {
                    let actual = try await officeViewText(office)
                    checks["narrowOfficeRestoresSelectionZoomAndScroll"] = try comparableOfficeView(actual) == comparableOfficeView(expected)
                    checks["narrowOfficeRestoresOriginalViewport"] = office.window.map { AgentWorkspaceRecovery.Frame(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) } == fixture.main.first(where: { $0.tab.root == "document:" + fixture.office })?.frame
                }
                if stage == "observe", interactive {
                    // The CUA run owns every edit after reopening. Only read the
                    // restored state here; the native test's continuation is separate.
                    let first = try record(control, file: fixture.file)
                    report["document"] = await first.workspaceReadback()
                    report["browser"] = browser.workspaceReadback(); report["office"] = await office.workspaceReadback(); report["canvas"] = canvas.workspaceReadback()
                    let controllers = taskControls.flatMap { $0.workspaceSession?.floatingControllers ?? [] }
                    checks["allExpectedIndependentWindowsAreReady"] = controllers.count == fixture.main.count + fixture.other.count && controllers.allSatisfy { $0.settingsHostWindow == nil && $0.window?.isVisible == true }
                    checks["observerHasNoColdPagesOrRecoveryErrors"] = taskControls.allSatisfy {
                        let state = $0.workspaceSession?.floatingRecoveryReadback ?? [:]
                        return (state["coldRoots"] as? [String])?.isEmpty == true && (state["errors"] as? [String: String])?.isEmpty == true
                    }
                } else {
                    checks["browserRestoresAsIndependentWindowAndExactForm"] = try await form(browser) == (fixture.browserDraft ?? "PUBLIC_FLOATING_FORM_941") && browser.workspaceReadback()["detached"] as? Bool == true && browser.settingsHostWindow == nil && browser.window?.isVisible == true
                    if fixture.browserDraft != nil {
                        checks["ordinaryFormFieldsRestoreWithoutReplayingInputEvents"] = try await browser.web.evaluateJavaScript("document.getElementById('details').value==='PUBLIC_DETAILS_729 中文'&&document.getElementById('approved').checked&&document.getElementById('choice').selectedIndex===1&&window.recoveryInputEvents===0") as? Bool == true
                    }
                    let actual = try await office.inspect([:])
                    checks["fullDirtyOfficeDraftRestoresInIndependentEditor"] = office.dirty && (actual["paragraphs"] as? [[String: Any]])?.contains { $0["text"] as? String == "审阅人：独立窗口草稿" } == true && office.settingsHostWindow == nil && office.window?.isVisible == true
                    checks["canvasSourceDraftRestoresInIndependentEditor"] = canvas.workspaceReadback()["source"] as? String == canvasDraft && canvas.settingsHostWindow == nil && canvas.window?.isVisible == true
                }
                let metadata = main.floating.first(where: { $0.tab.root == "document:" + fixture.office })!
                if let saved = try journal.loadPage(windowID: fixture.windowID, pageID: metadata.tab.id, taskID: fixture.taskID), let asset = saved.asset {
                    try FileManager.default.copyItem(at: asset, to: output.appendingPathComponent(stage + "-recovered.docx"))
                }
            }
            let files = try AgentFiles(workspace: URL(fileURLWithPath: fixture.file).deletingLastPathComponent().path)
            checks["originalMarkdownAndOfficeFilesStayExact"] = try files.fileHash(URL(fileURLWithPath: fixture.file)) == fixture.sourceHash && files.fileHash(URL(fileURLWithPath: fixture.office)) == fixture.officeHash
            checks["bothComposerDraftsAndNoRepliesRemainExact"] = [fixture.taskID, fixture.otherID].allSatisfy { tasks.task($0)?.draft == "保留任务输入 PUBLIC_FLOATING_COMPOSER_273" && tasks.task($0)?.messages.isEmpty == true }
            checks["allChangesHaveCurrentCheckpoints"] = await flushWorkspaceWindows()
            checks["noModelRequests"] = requests == 0
            report["stage"] = stage
        } catch { report["error"] = error.localizedDescription }
        report["restoration"] = taskControls.map { $0.workspaceSession?.floatingRecoveryReadback ?? [:] }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "floating-recovery-ui-ready.json" : "floating-recovery-report.json"))
    }
}
