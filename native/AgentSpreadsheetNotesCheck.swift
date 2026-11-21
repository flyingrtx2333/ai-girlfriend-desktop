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

    func runSpreadsheetNoteCreationCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], failure: String?, modelRequests = 0
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let project = output.appendingPathComponent("project")
        let document = project.appendingPathComponent("sample.xlsx")
        let fixtureFile = output.appendingPathComponent("notes-create-fixture.json")
        let salesNote = "新销售备注\n  核对 C3 和公式 🧭"
        let firstNote = "首次备注 <原值&保留>\n 第二行 "
        let appendedNote = "再次新增后继续保存单元格"
        let journal = AgentWorkspaceRecovery(profile: store.directory)

        func selectCell(_ editor: AgentOfficeWindow, sheet: String, index: Int, row: Int, column: Int) async throws {
            var view = try await editor.checkWorkspaceView()
            let cell = ["row": row, "col": column]
            view["selection"] = ["sheetIndex": index, "sheetName": sheet, "cells": ["anchor": cell, "focus": cell]]
            view["scroll"] = []
            _ = try await editor.checkWorkspaceView(view)
        }
        func byCell(_ source: URL) async throws -> [String: String] {
            let notes = try await AgentSpreadsheetNotes.read(source)
            return Dictionary(uniqueKeysWithValues: notes.map { ($0.sheet + " · " + $0.cell, $0.text) })
        }

        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("新建备注验收需要独立资料")
            }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("新建备注验收禁止模型请求") }
            let files = try AgentFiles(workspace: project.path)
            if stage == "seed" {
                let original = try files.fileHash(document)
                let task = tasks.create(title: "公开备注创建", workspace: project.path, draft: "保留当前任务输入")
                control.showAgentTask(task); control.show(tab: "chat")
                control.window?.appearance = NSAppearance(named: .aqua)
                control.window?.setContentSize(NSSize(width: 1320, height: 800))
                let editor = try await tasks.offices.show(document.path, taskID: task)
                guard let window = control.workspaceSession?.id,
                      let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "document:" + document.path }) else {
                    throw PetError("原备注文件标签缺失")
                }
                _ = try await editor.checkSpreadsheetNotes(show: true)
                try await selectCell(editor, sheet: "销售", index: 0, row: 2, column: 2)
                let existing = try await editor.checkSpreadsheetNotes(newAddress: "销售 · C3")
                checks["newOnExistingCellOpensOriginalWithoutDuplicate"] = existing["value"] as? String == "核对税前金额\n保留样例" &&
                    existing["author"] as? String == "会计小组" && (existing["entries"] as? [String])?.count == 2 && !editor.dirty
                try await selectCell(editor, sheet: "销售", index: 0, row: 5, column: 1)
                let blank = try await editor.checkSpreadsheetNotes(newAddress: "销售 · B6")
                checks["newNoteStartsOnTheActiveCellWithoutWritingAnEmptyNote"] = try blank["value"] as? String == "" &&
                    blank["author"] as? String == "小鲸" && blank["focused"] as? Bool == true && !editor.dirty && files.fileHash(document) == original
                _ = try await editor.checkSpreadsheetNotes(edit: salesNote)
                try await selectCell(editor, sheet: "首次备注", index: 2, row: 44, column: 5)
                _ = try await editor.checkSpreadsheetNotes(newAddress: "首次备注 · F45", edit: firstNote)
                checks["creationRevealsTheActualCellInTheOtherSheet"] = try await editor.checkSpreadsheetNoteVisible(sheet: "首次备注", cell: "F45")
                try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("create-notes-wide.png"))
                guard await flushWorkspaceWindows(), let loaded = try journal.loadPage(windowID: window, pageID: tab.id, taskID: task),
                      let asset = loaded.asset else { throw PetError("新建备注未保存到工作区草稿") }
                let drafts = try await byCell(asset)
                checks["newNotesCheckpointIncludesBothSheetsWithoutTouchingTheOriginal"] = try loaded.saved.value.dirty &&
                    drafts["销售 · B6"] == salesNote && drafts["首次备注 · F45"] == firstNote && files.fileHash(document) == original
                let source = try AgentFiles(workspace: asset.deletingLastPathComponent().path)
                let evidence = try AgentFiles(workspace: output.path)
                try evidence.copyFile(asset, from: source, to: output.appendingPathComponent("create-checkpoint.xlsx"),
                                      permissions: 0o600, expectedHash: loaded.saved.value.asset?.hash, maximum: AgentOffice.maximum)
                try JSONEncoder().encode(SpreadsheetNotesFixture(task: task, window: window, tab: tab.id, hash: original)).write(to: fixtureFile, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(SpreadsheetNotesFixture.self, from: Data(contentsOf: fixtureFile))
                control.window?.appearance = NSAppearance(named: .darkAqua)
                control.show(tab: "chat"); control.window?.setContentSize(NSSize(width: 780, height: 540))
                guard await flushWorkspaceWindows() else { throw PetError("工作区备注未恢复") }
                if control.taskWorkspace.currentController as? AgentOfficeWindow == nil {
                    control.taskWorkspace.checkSelect(.document(document.path))
                    guard await flushWorkspaceWindows() else { throw PetError("原备注标签未恢复") }
                }
                guard let editor = control.taskWorkspace.currentController as? AgentOfficeWindow, editor.file == document else {
                    throw PetError("原备注窗口缺失")
                }
                checks["taskDraftAndWindowRestore"] = control.workspaceSession?.id == fixture.window && control.agentTaskID == fixture.task &&
                    tasks.task(fixture.task)?.draft == "保留当前任务输入"
                let visible = try await editor.checkSpreadsheetNotes()
                let location = (try await editor.checkWorkspaceView()["notes"] as? [String: Any])?["selected"] as? [String: Any]
                if stage == "resume" {
                    checks["bothNewNotesSurviveRestartAndRestoreFocus"] = try visible["value"] as? String == firstNote &&
                        location?["cell"] as? String == "F45" && location?["end"] as? Int == 2 && location?["focused"] as? Bool == true &&
                        (visible["entries"] as? [String])?.contains("销售 · B6") == true && editor.dirty && files.fileHash(document) == fixture.hash
                    checks["narrowRestoredDraftAnchorIsPainted"] = try await editor.checkSpreadsheetNoteVisible(sheet: "首次备注", cell: "F45")
                    try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("create-notes-narrow.png"))
                    try await selectCell(editor, sheet: "首次备注", index: 2, row: 199, column: 3)
                    _ = try await editor.checkSpreadsheetNotes(newAddress: "首次备注 · D200", edit: appendedNote)
                    try await editor.saveDocument()
                    let firstSave = try await byCell(document)
                    checks["explicitSaveCreatesTheNewPartsForBothSheets"] = !editor.dirty && firstSave["销售 · B6"] == salesNote &&
                        firstSave["首次备注 · F45"] == firstNote && firstSave["首次备注 · D200"] == appendedNote
                    let query = try await editor.inspect(["sheet": "销售", "range": "C4"])
                    guard let sheet = query["sheet"], let version = query["version"] else { throw PetError("无法读取原工作表") }
                    try await editor.checkWorkspaceEdit(["expectVersion": version, "steps": [
                        ["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "C4"]], "inputs": [["29.6"]]]
                    ]])
                    try await editor.saveDocument()
                    let secondSave = try await byCell(document)
                    checks["savingACellAgainDoesNotRecreateOrLosePriorNotes"] = !editor.dirty && secondSave == firstSave
                } else {
                    checks["savedNoteListAndFocusOpenCleanly"] = !editor.dirty && visible["value"] as? String == appendedNote &&
                        location?["cell"] as? String == "D200" && (visible["entries"] as? [String])?.count == 5
                    checks["savedNoteStillLocatesItsCell"] = try await editor.checkSpreadsheetNoteVisible(sheet: "首次备注", cell: "D200")
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
            try? bytes.write(to: output.appendingPathComponent("spreadsheet-notes-created-" + stage + ".json"), options: .atomic)
        }
    }
}
