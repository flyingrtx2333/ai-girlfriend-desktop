import AppKit

@MainActor extension AppDelegate {
    private struct SpreadsheetNotesFixture: Codable {
        let task: String, window: String, tab: String, hash: String
    }

    func runSpreadsheetNotesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], failure: String?, modelRequests = 0
        let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
        let project = output.appendingPathComponent("project")
        let document = project.appendingPathComponent("sample.xlsx")
        let fixtureFile = output.appendingPathComponent("notes-fixture.json")
        let before = "跨表备注 <公开> 🧭"
        let draft = "核对后备注 🧭\n <校验&通过> "
        let finalNote = "复核后备注 🧭\n <校验&通过> "
        let journal = AgentWorkspaceRecovery(profile: store.directory)
        func waitForSelection(_ editor: AgentOfficeWindow) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let view = try await editor.checkWorkspaceView()
                let selection = view["selection"] as? [String: Any]
                let cells = selection?["cells"] as? [String: Any]
                let anchor = cells?["anchor"] as? [String: Int]
                if selection?["sheetName"] as? String == "审阅", anchor == ["row": 34, "col": 4] { return view }
                try await Task.sleep(for: .milliseconds(70))
            }
            throw PetError("未定位至审阅表 E35")
        }
        func fits(_ view: [String: Any]) -> Bool {
            let width = view["width"] as? Double ?? 0, right = view["right"] as? Double ?? -1
            let left = view["left"] as? Double ?? 0, grid = view["grid"] as? Double ?? 0
            return width > 400 && abs(right - width) < 1 && abs(grid - left) < 1 && grid > 230 && right - left >= 180
        }
        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("备注验收需要独立资料")
            }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("备注验收禁止模型请求") }
            let files = try AgentFiles(workspace: project.path)
            if stage == "seed" {
                let original = try files.fileHash(document)
                let task = tasks.create(title: "公开表格备注", workspace: project.path, draft: "原任务待发送文字")
                control.showAgentTask(task); control.show(tab: "chat")
                control.window?.appearance = NSAppearance(named: .aqua)
                control.window?.setContentSize(NSSize(width: 1320, height: 800))
                guard let window = control.workspaceSession?.id else { throw PetError("原工作区恢复会话缺失") }
                let editor = try await tasks.offices.show(document.path, taskID: task)
                guard let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "document:" + document.path }) else {
                    throw PetError("备注文件没有原标签")
                }
                let opened = try await editor.checkSpreadsheetNotes(show: true, address: "审阅 · E35")
                _ = try await waitForSelection(editor)
                checks["existingNotesOpenInTheTwoOriginalSheets"] = Set(opened["entries"] as? [String] ?? []) == ["销售 · C3", "审阅 · E35"] && opened["value"] as? String == before
                checks["notesPanePreservesUsableGridAtWideSize"] = fits(opened)
                checks["noteAnchorPaintedAfterCrossSheetNavigation"] = try await editor.checkSpreadsheetNoteVisible(sheet: "审阅", cell: "E35")
                try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("spreadsheet-notes-wide.png"))
                _ = try await editor.checkSpreadsheetNotes(edit: draft)
                let positioned = try await waitForSelection(editor)
                let location = (positioned["notes"] as? [String: Any])?["selected"] as? [String: Any]
                checks["editableNoteTracksOriginalAddressSelectionAndDirtyState"] = location?["sheet"] as? String == "审阅" &&
                    location?["cell"] as? String == "E35" && location?["end"] as? Int == 2 && location?["focused"] as? Bool == true
                guard await flushWorkspaceWindows(), let loaded = try journal.loadPage(windowID: window, pageID: tab.id, taskID: task),
                      let asset = loaded.asset else { throw PetError("备注草稿未写入恢复文件") }
                let notes = try await AgentSpreadsheetNotes.read(asset)
                checks["workspaceCheckpointContainsActualEditedNote"] = loaded.saved.value.dirty && notes.contains { $0.sheet == "审阅" && $0.cell == "E35" && $0.text == draft }
                checks["checkpointDoesNotWriteOriginalSpreadsheet"] = try editor.dirty && files.fileHash(document) == original
                let source = try AgentFiles(workspace: asset.deletingLastPathComponent().path)
                let evidence = try AgentFiles(workspace: output.path)
                try evidence.copyFile(asset, from: source, to: output.appendingPathComponent("note-checkpoint.xlsx"), permissions: 0o600, expectedHash: loaded.saved.value.asset?.hash, maximum: AgentOffice.maximum)
                try JSONEncoder().encode(SpreadsheetNotesFixture(task: task, window: window, tab: tab.id, hash: original)).write(to: fixtureFile, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(SpreadsheetNotesFixture.self, from: Data(contentsOf: fixtureFile))
                control.window?.appearance = NSAppearance(named: .darkAqua)
                control.show(tab: "chat")
                control.window?.setContentSize(NSSize(width: 780, height: 540))
                guard await flushWorkspaceWindows() else { throw PetError("办公标签尚未恢复") }
                if control.taskWorkspace.currentController as? AgentOfficeWindow == nil {
                    control.taskWorkspace.checkSelect(.document(document.path))
                    guard await flushWorkspaceWindows() else { throw PetError("原办公标签未打开") }
                }
                guard let editor = control.taskWorkspace.currentController as? AgentOfficeWindow, editor.file == document else {
                    throw PetError("原备注编辑器未恢复")
                }
                checks["windowAndTaskDraftRestore"] = control.workspaceSession?.id == fixture.window && control.agentTaskID == fixture.task &&
                    tasks.task(fixture.task)?.draft == "原任务待发送文字"
                let actual = try await editor.checkSpreadsheetNotes()
                let positioned = try await waitForSelection(editor)
                let location = (positioned["notes"] as? [String: Any])?["selected"] as? [String: Any]
                let expected = stage == "resume" ? draft : finalNote
                checks["narrowRestoresEditedNoteAndSheetCell"] = actual["value"] as? String == expected && fits(actual) && location?["cell"] as? String == "E35"
                checks["restoredNoteAnchorPaintedAtNarrowSize"] = try await editor.checkSpreadsheetNoteVisible(sheet: "审阅", cell: "E35")
                if stage == "resume" {
                    checks["reopensOriginalNoteDraftWithSelection"] = try editor.dirty && editor.openedHash == fixture.hash && files.fileHash(document) == fixture.hash &&
                        location?["start"] as? Int == 0 && location?["end"] as? Int == 2 && location?["focused"] as? Bool == true
                    try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("spreadsheet-notes-narrow.png"))
                    _ = try await editor.checkSpreadsheetNotes(edit: finalNote)
                    try await editor.saveDocument()
                    checks["saveUsesOriginalWorkbookAndClearsDirtyMark"] = try !editor.dirty && files.fileHash(document) != fixture.hash
                    let current = try await editor.inspect(["sheet": "销售", "range": "C4"])
                    guard let sheet = current["sheet"], let version = current["version"] else { throw PetError("单元格版本不可读") }
                    try await editor.checkWorkspaceEdit(["expectVersion": version,
                        "steps": [["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "C4"]], "inputs": [["29.6"]]]]])
                    try await editor.saveDocument()
                    let savedNotes = try await AgentSpreadsheetNotes.read(document)
                    checks["laterCellSavePreservesSavedNote"] = !editor.dirty && savedNotes.contains { $0.cell == "E35" && $0.text == finalNote }
                } else {
                    checks["savedNotesRetainTheirPositionsOnCleanOpen"] = !editor.dirty && actual["value"] as? String == finalNote
                }
            }
            checks["workspaceStateFlushed"] = await flushWorkspaceWindows()
        } catch {
            failure = error.localizedDescription
            for editor in agentStore?.offices.windows.values.map({ $0 }) ?? [] { editor.finishClose() }
        }
        checks["zeroModelRequests"] = modelRequests == 0
        var report: [String: Any] = ["stage": stage, "pid": getpid(), "checks": checks, "modelRequests": modelRequests,
                                     "success": failure == nil && checks.values.allSatisfy { $0 }]
        report["error"] = failure
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? bytes.write(to: output.appendingPathComponent("spreadsheet-notes-" + stage + ".json"), options: .atomic)
        }
    }
}
