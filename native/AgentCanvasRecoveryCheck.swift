import AppKit

@MainActor extension AppDelegate {
    struct CanvasRecoveryFixture: Codable {
        var first: String, second: String, windowID: String
        var ids: [String: String], tabs: [String: String], originals: [String: String], drafts: [String: String]
        var selectionLocation: Int, selectionLength: Int, sourceScrollY: Double
    }
    func runCanvasRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("画布恢复验收禁止模型请求") }
            let fixtureURL = output.appendingPathComponent("canvas-recovery-fixture.json"), journal = AgentWorkspaceRecovery(profile: store.directory)
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            func editor() throws -> AgentCanvasWindow {
                guard let editor = control.taskWorkspace.currentController as? AgentCanvasWindow else { throw PetError("画布没有进入实际任务工作区") }; return editor
            }
            func tab(_ id: String, task: String) throws -> AgentWorkspaceRecovery.Tab {
                guard let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "canvas:" + id }) else { throw PetError("画布标签没有持久编号") }; return tab
            }
            func snapshot(_ id: String, tab: String, task: String, window: String, text: String) async throws -> AgentWorkspaceRecovery.LoadedPage {
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    if let page = try? journal.loadPage(windowID: window, pageID: tab, taskID: task), page.saved.value.dirty,
                       (try? tasks.canvases.record(id, taskID: task).draft) == text { return page }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw PetError("画布原有草稿与窗口状态未自动保存")
            }
            let fixture: CanvasRecoveryFixture
            if stage == "seed" {
                let project = output.appendingPathComponent("public-canvas-project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data("PUBLIC_CANVAS_SOURCE_SENTINEL_263\n".utf8).write(to: project.appendingPathComponent("README.md"))
                let first = tasks.create(title: "画布草稿恢复 · 无工作区问答", mode: .ask, workMode: .general), second = tasks.create(title: "画布草稿恢复 · 项目任务", workspace: project.path)
                for id in [first, second] { tasks.update(id) { $0.draft = "保留原任务输入 PUBLIC_CANVAS_INPUT_184" } }
                var ids: [String: String] = [:], tabs: [String: String] = [:], originals: [String: String] = [:], drafts: [String: String] = [:]
                for key in ["a", "b", "c", "d"] {
                    let owner = key == "c" ? second : first
                    let source = "export default function Canvas(){return <main><h1>ORIGINAL_CANVAS_" + key.uppercased() + "_PUBLIC_314</h1><button>公开控件</button></main>}\n"
                    let record = try tasks.canvases.create(title: "公开画布 " + key.uppercased(), source: source, taskID: owner)
                    ids[key] = record.id; originals[key] = source
                    drafts[key] = source.replacingOccurrences(of: "ORIGINAL_CANVAS", with: "UNSAVED_CANVAS") + (key == "a" ? (1...400).map { "// 公开长文第 \($0) 行 PUBLIC_CANVAS_773\n" }.joined() : "// 已有画布草稿 PUBLIC_CANVAS_582\n")
                }
                guard tasks.canvases.saveDraft(drafts["c"], hash: AgentFiles.hash(Data(originals["c"]!.utf8)), id: ids["c"]!, taskID: second) else { throw PetError("预先存在的画布草稿未保存") }
                control.showAgentTask(first); control.show(tab: "chat")
                guard let window = control.workspaceSession?.id else { throw PetError("画布工作区恢复未启用") }
                let a = try await tasks.canvases.show(ids["a"]!, taskID: first); control.taskWorkspace.checkExpand()
                guard control.taskWorkspace.currentController === a, a.settingsHostWindow === control.window else { throw PetError("验收入口没有启用实际任务工作区") }
                tabs["a"] = try tab(ids["a"]!, task: first).id
                await a.checkWorkspaceSource(drafts["a"]! + "// 第一笔 PUBLIC_CANVAS_FIRST_408\n")
                _ = try await snapshot(ids["a"]!, tab: tabs["a"]!, task: first, window: window, text: drafts["a"]! + "// 第一笔 PUBLIC_CANVAS_FIRST_408\n")
                await a.checkWorkspaceSource(drafts["a"]!)
                let page = try await snapshot(ids["a"]!, tab: tabs["a"]!, task: first, window: window, text: drafts["a"]!)
                checks["repeatedDirtyEditsReuseActualDurableCanvasDraft"] = try tasks.canvases.record(ids["a"]!, taskID: first).draft == drafts["a"]
                checks["windowJournalDoesNotDuplicateCanvasSource"] = page.saved.value.asset == nil && !String(decoding: page.saved.value.state, as: UTF8.self).contains("UNSAVED_CANVAS")
                let selection = (drafts["a"]! as NSString).range(of: "UNSAVED_CANVAS_A_PUBLIC_314")
                a.checkWorkspaceSelection(selection, scrollY: 320)
                guard await flushWorkspaceWindows() else { throw PetError("画布视图未保存") }
                let selected = try AgentCanvasWindow.recoveryState(a.captureWorkspaceRecovery())
                checks["sourceSelectionAndScrollCaptureActualEditorState"] = selected.selectionLocation == selection.location && selected.selectionLength == selection.length && selected.sourceScrollY > 0
                let taskFile = tasks.directory.appendingPathComponent(first + ".json"), beforeTask = try Data(contentsOf: taskFile)
                if !interactive {
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: taskFile.path)
                    await a.checkWorkspaceSource(drafts["a"]! + "// 拒绝后保留 PUBLIC_CANVAS_RETRY_617\n")
                    let refused = !(await control.flushWorkspaceRecovery()), actualTask = try Data(contentsOf: taskFile)
                    checks["readonlyTaskRecordBlocksRecoveryAndQuitPreservation"] = refused && control.workspaceSession?.preservedEditors.isEmpty == true && actualTask == beforeTask
                    let otherSaved = tasks.canvases.saveDraft(drafts["c"], hash: AgentFiles.hash(Data(originals["c"]!.utf8)), id: ids["c"]!, taskID: second)
                    let stillRefused = !(await control.flushWorkspaceRecovery()), afterOtherSave = try Data(contentsOf: taskFile)
                    checks["otherTaskSaveCannotHideUnpersistedCanvasDraft"] = otherSaved && stillRefused && control.workspaceSession?.preservedEditors.isEmpty == true && afterOtherSave == beforeTask
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: taskFile.path)
                    let retried = await control.flushWorkspaceRecovery(), retriedDraft = try tasks.canvases.record(ids["a"]!, taskID: first).draft
                    checks["sameDraftRetriesAfterTaskRecordPermissionRestores"] = retried && retriedDraft == drafts["a"]! + "// 拒绝后保留 PUBLIC_CANVAS_RETRY_617\n"
                    await a.checkWorkspaceSource(drafts["a"]!); a.checkWorkspaceSelection(selection, scrollY: selected.sourceScrollY)
                }
                let b = try await tasks.canvases.show(ids["b"]!, taskID: first); b.checkWorkspaceSelection(NSRange(location: 0, length: 0), source: false); tabs["b"] = try tab(ids["b"]!, task: first).id
                let d = try await tasks.canvases.show(ids["d"]!, taskID: first); await d.checkWorkspaceSource(drafts["d"]!); tabs["d"] = try tab(ids["d"]!, task: first).id
                let c = try await tasks.canvases.show(ids["c"]!, taskID: second); tabs["c"] = try tab(ids["c"]!, task: second).id
                checks["existingCanvasDraftAndBaselineAreReused"] = c.workspaceReadback()["source"] as? String == drafts["c"] && c.workspaceReadback()["editorHash"] as? String == AgentFiles.hash(Data(originals["c"]!.utf8))
                control.showAgentTask(first); control.taskWorkspace.checkSelect(.canvas(ids["a"]!))
                guard await flushWorkspaceWindows() else { throw PetError("画布最后状态未保存") }
                fixture = .init(first: first, second: second, windowID: window, ids: ids, tabs: tabs, originals: originals, drafts: drafts, selectionLocation: selection.location, selectionLength: selection.length, sourceScrollY: selected.sourceScrollY)
                checks["allFourCanvasEditorsEligibleForDurableHotExit"] = control.workspaceSession?.preservedEditors.count == 4
                checks["canvasTitlesPersistInExistingLayoutField"] = try journal.loadWindow(window)?.value.tasks.first(where: { $0.taskID == first })?.tabs.filter { $0.root.hasPrefix("canvas:") }.allSatisfy { $0.title.hasPrefix("画布 · 公开画布 ") } == true
                checks["askWithoutWorkspaceKeepsCanvasDraftAndComposer"] = tasks.task(first)?.workspace == nil && tasks.task(first)?.mode == .ask && tasks.task(first)?.draft == "保留原任务输入 PUBLIC_CANVAS_INPUT_184"
                do { _ = try await tasks.canvases.restore(page.saved.value, taskID: first) { _ in }; checks["secondWindowCannotTakeOverOpenCanvasRecovery"] = false }
                catch { checks["secondWindowCannotTakeOverOpenCanvasRecovery"] = tasks.canvases.windows[first + ":" + ids["a"]!] === a }
                let bTab = try tab(ids["b"]!, task: first)
                do { try await control.materializeRecoveryRoot(task: first, tab: bTab, loaded: page); checks["canvasPageCannotRestoreIntoAnotherCanvasTab"] = false }
                catch { checks["canvasPageCannotRestoreIntoAnotherCanvasTab"] = true }
                let storedBeforeUnknown = try journal.loadPage(windowID: window, pageID: tabs["a"]!, taskID: first)!
                var unknown = storedBeforeUnknown.saved.value, object = try JSONSerialization.jsonObject(with: unknown.state) as! [String: Any]
                object["futureField"] = "preserve"; unknown.state = try JSONSerialization.data(withJSONObject: object)
                do { _ = try AgentCanvasWindow.recoveryState(unknown); checks["unknownCanvasStateRetainsOriginalStoredPage"] = false }
                catch { checks["unknownCanvasStateRetainsOriginalStoredPage"] = try journal.loadPage(windowID: window, pageID: tabs["a"]!, taskID: first)?.saved.hash == storedBeforeUnknown.saved.hash }
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(CanvasRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); guard await flushWorkspaceWindows() else { throw PetError("画布恢复未完成") }
                checks["sameCanvasTaskWindowIdentityRestores"] = control.workspaceSession?.id == fixture.windowID && control.agentTaskID == fixture.first
                let coldLabels = control.taskWorkspace.checkState()["tabLabels"] as? [String] ?? []
                checks["coldCanvasTitleAndDirtyMarkerRestoreBeforeEditorLoads"] = coldLabels.contains("• 画布 · 公开画布 D") && control.taskWorkspace.recoveryController(taskID: fixture.first, root: .canvas(fixture.ids["d"]!)) == nil
                checks["cleanColdCanvasHasExactNameWithoutDirtyMarker"] = coldLabels.contains("画布 · 公开画布 B") && control.taskWorkspace.recoveryController(taskID: fixture.first, root: .canvas(fixture.ids["b"]!)) == nil
                report["initialColdTabLabels"] = coldLabels
                for key in ["a", "b", "c"] {
                    let owner = key == "c" ? fixture.second : fixture.first
                    control.showAgentTask(owner); control.taskWorkspace.checkSelect(.canvas(fixture.ids[key]!))
                    guard await flushWorkspaceWindows() else { throw PetError("画布标签恢复失败：" + key) }
                    let current = try editor(), actual = current.workspaceReadback(), expected = key == "b" ? fixture.originals[key]! : fixture.drafts[key]!
                    checks[key + "ActualCanvasSourceAndDirtyStateRestore"] = (interactive ? (actual["source"] as? String)?.hasPrefix(expected) == true : actual["source"] as? String == expected) && actual["dirty"] as? Bool == (key != "b")
                    checks[key + "ActualCanvasViewModeRestores"] = actual["sourceVisible"] as? Bool == (key != "b")
                    if key == "a", !interactive {
                        report["restoredPrimaryView"] = ["selectionLocation": actual["selectionLocation"] ?? -1, "selectionLength": actual["selectionLength"] ?? -1, "sourceScrollY": actual["sourceScrollY"] ?? -1]
                        checks["sourceSelectionAndScrollRestoreWithoutNewEdit"] = actual["selectionLocation"] as? Int == fixture.selectionLocation && actual["selectionLength"] as? Int == fixture.selectionLength && abs((actual["sourceScrollY"] as? Double ?? -1000) - fixture.sourceScrollY) < 1
                        let before = try tasks.canvases.source(fixture.ids[key]!, taskID: owner)
                        let external = fixture.originals[key]!.replacingOccurrences(of: "ORIGINAL_CANVAS", with: "EXTERNAL_CANVAS")
                        let changed = try tasks.canvases.update(fixture.ids[key]!, source: external, expected: before.record.hash, taskID: owner)
                        await current.checkWorkspaceSource(action: "save")
                        checks["restoredOldDraftCannotOverwriteExternalCanvasVersion"] = try tasks.canvases.source(fixture.ids[key]!, taskID: owner).code == external && current.workspaceHasUnsavedChanges && current.workspaceReadback()["editorHash"] as? String == AgentFiles.hash(Data(fixture.originals[key]!.utf8))
                        _ = try tasks.canvases.update(fixture.ids[key]!, source: fixture.originals[key]!, expected: changed.hash, taskID: owner)
                    }
                    if key == "c", !interactive {
                        await current.checkWorkspaceSource(action: "save")
                        checks["restoredCanvasActuallySavesThroughOriginalVersionGuard"] = try tasks.canvases.source(fixture.ids[key]!, taskID: owner).code == fixture.drafts[key] && !current.workspaceHasUnsavedChanges && tasks.canvases.record(fixture.ids[key]!, taskID: owner).draft == nil
                        guard await flushWorkspaceWindows(), let clean = try journal.loadPage(windowID: fixture.windowID, pageID: fixture.tabs[key]!, taskID: owner) else { throw PetError("实际保存后的画布恢复状态缺失") }
                        checks["actualCanvasSaveClearsRecoveryDirtyState"] = !clean.saved.value.dirty
                    }
                }
                control.showAgentTask(fixture.first)
                if !interactive {
                    let before = try journal.loadPage(windowID: fixture.windowID, pageID: fixture.tabs["d"]!, taskID: fixture.first)!
                    control.taskWorkspace.checkSelect(.canvas(fixture.ids["d"]!)); guard await flushWorkspaceWindows() else { throw PetError("失联画布恢复检查未完成") }
                    checks["missingSourceKeepsColdTabPageAndExistingDraft"] = try control.taskWorkspace.currentController == nil && journal.loadPage(windowID: fixture.windowID, pageID: fixture.tabs["d"]!, taskID: fixture.first)?.saved.hash == before.saved.hash && tasks.canvases.record(fixture.ids["d"]!, taskID: fixture.first).draft == fixture.drafts["d"] && tasks.canvases.windows[fixture.first + ":" + fixture.ids["d"]!] == nil
                    checks["failedCanvasRestoreKeepsNamedUnsavedColdTab"] = (control.taskWorkspace.checkState()["tabLabels"] as? [String])?.contains("• 画布 · 公开画布 D") == true
                }
                control.taskWorkspace.checkSelect(.canvas(fixture.ids["a"]!)); guard await flushWorkspaceWindows() else { throw PetError("返回原画布失败") }
                checks["originalCanvasTaskComposersRemainExact"] = [fixture.first, fixture.second].allSatisfy { tasks.task($0)?.draft == "保留原任务输入 PUBLIC_CANVAS_INPUT_184" }
            }
            for key in ["a", "b", "c", "d"] where interactive || stage == "seed" || key != "d" {
                let owner = key == "c" ? fixture.second : fixture.first, expected = stage == "reopen" && key == "c" && !interactive ? fixture.drafts[key]! : fixture.originals[key]!
                checks[key + "SourceBytesMatchOnlyExplicitSaves"] = try tasks.canvases.source(fixture.ids[key]!, taskID: owner).code == expected
            }
            checks["noModelRequest"] = requests == 0; checks["allCanvasWorkspaceSnapshotsCurrent"] = await flushWorkspaceWindows()
            report["stage"] = stage; report["fixture"] = fixtureURL.path
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "canvas-recovery-ui-ready.json" : "canvas-recovery-report.json"))
    }
}
