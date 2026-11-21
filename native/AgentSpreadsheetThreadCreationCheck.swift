import AppKit

@MainActor extension AppDelegate {
    private struct ThreadCreationFixture: Codable {
        let task: String, window: String, tab: String, hash: String, firstID: String
    }

    func runSpreadsheetThreadCreationCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let mixed = args.contains("--spreadsheet-mixed-comments")
        let project = output.appendingPathComponent("project"), document = project.appendingPathComponent("sample.xlsx")
        let fixtureFile = output.appendingPathComponent("create-threads-fixture.json")
        let journal = AgentWorkspaceRecovery(profile: store.directory)
        let title = "保留原任务输入"
        let firstText = "核对合同 <公开> 🧭\n  字面 _x0041_ "
        let followText = "下一张表：核对合计"
        let replyText = "已经收到原件"
        typealias Position = (sheet: String, index: Int, cell: String, row: Int, column: Int)
        let sale: Position = ("销售", 0, "B6", 5, 1), chart: Position = ("首次备注", 2, "F45", 44, 5)
        let first = mixed ? sale : chart, follow = mixed ? chart : sale
        let firstAddress = first.sheet + " · " + first.cell, followAddress = follow.sheet + " · " + follow.cell
        let initialCount = mixed ? 2 : 0
        var checks: [String: Bool] = [:], failure: String?, modelRequests = 0

        func setCell(_ editor: AgentOfficeWindow, position: Position) async throws {
            var view = try await editor.checkWorkspaceView()
            let anchor = ["row": position.row, "col": position.column]
            view["selection"] = ["sheetName": position.sheet, "sheetIndex": position.index, "cells": ["anchor": anchor, "focus": anchor]]
            view["scroll"] = []
            _ = try await editor.checkWorkspaceView(view)
        }
        func isActive(_ editor: AgentOfficeWindow, position: Position) async throws -> Bool {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                let view = try await editor.checkWorkspaceView()
                if let selection = view["selection"] as? [String: Any], selection["sheetName"] as? String == position.sheet,
                   let cells = selection["cells"] as? [String: Any],
                   cells["anchor"] as? [String: Int] == ["row": position.row, "col": position.column],
                   cells["focus"] as? [String: Int] == ["row": position.row, "col": position.column] {
                    return try await editor.checkSpreadsheetNoteVisible(sheet: position.sheet, cell: position.cell)
                }
                try await Task.sleep(for: .milliseconds(70))
            }
            return false
        }
        func messages(_ result: [String: Any]) -> [[String: String]] { result["messages"] as? [[String: String]] ?? [] }
        func archiveCopy(_ file: URL, to name: String, from source: AgentFiles, hash: String) throws {
            let evidence = try AgentFiles(workspace: output.path)
            try evidence.copyFile(file, from: source, to: output.appendingPathComponent(name),
                                  permissions: 0o600, expectedHash: hash, maximum: AgentOffice.maximum)
        }

        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("新建评论需要独立验收资料")
            }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("新建评论验收禁止模型请求") }
            let files = try AgentFiles(workspace: project.path)
            if stage == "seed" {
                let hash = try files.fileHash(document)
                let task = tasks.create(title: "创建公开表格评论", workspace: project.path, draft: title)
                control.showAgentTask(task); control.show(tab: "chat")
                control.window?.appearance = NSAppearance(named: .aqua)
                control.window?.setContentSize(NSSize(width: 1320, height: 800))
                let editor = try await tasks.offices.show(document.path, taskID: task)
                guard let window = control.workspaceSession?.id,
                      let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "document:" + document.path }) else {
                    throw PetError("原工作簿没有恢复标签")
                }
                let panel = try await editor.checkSpreadsheetThread(show: true)
                checks["entryOpensOnWorkbookWithOrWithoutThreads"] = (panel["entries"] as? [String])?.count == initialCount &&
                    (mixed || panel["status"] as? String == "暂无评论")
                try await setCell(editor, position: ("销售", 0, "C3", 2, 2))
                let occupied = try await editor.checkSpreadsheetThread(newAddress: "销售 · C3", blocked: true)
                checks["existingNoteCannotBeOverwrittenByNewThread"] = occupied["status"] as? String == "此单元格已有备注" &&
                    (occupied["entries"] as? [String])?.count == initialCount && !editor.dirty
                if mixed {
                    try await setCell(editor, position: ("销售", 0, "F15", 14, 5))
                    let old = try await editor.checkSpreadsheetThread(newAddress: "销售 · F15")
                    checks["newOnOccupiedThreadOpensItsOwnComposer"] = old["selected"] as? String == "销售 · F15" &&
                        old["composerAction"] as? String == "添加回复" && messages(old).count == 3 && (old["entries"] as? [String])?.count == 2
                }
                try await setCell(editor, position: first)
                let begun = try await editor.checkSpreadsheetThread(newAddress: firstAddress)
                let cancelled = try await editor.checkSpreadsheetThread(action: "cancel")
                checks["emptyDraftHasNoFileChangeAndCanBeDismissed"] = begun["composerAction"] as? String == "添加评论" &&
                    begun["canSubmit"] as? Bool == false && begun["canResolve"] as? Bool == false &&
                    (cancelled["entries"] as? [String])?.count == initialCount && !editor.dirty
                let drafted = try await editor.checkSpreadsheetThread(text: firstText, newAddress: firstAddress)
                guard let firstID = drafted["threadID"] as? String, !firstID.isEmpty else { throw PetError("新评论没有编号") }
                let positioned = try await isActive(editor, position: first)
                checks["draftBindsToActiveCellAndFocus"] = drafted["draft"] as? String == firstText &&
                    drafted["canSubmit"] as? Bool == true && drafted["focused"] as? Bool == true && positioned
                try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("create-threads-wide.png"))
                guard await flushWorkspaceWindows(), let saved = try journal.loadPage(windowID: window, pageID: tab.id, taskID: task),
                      let asset = saved.asset else { throw PetError("新评论草稿未落盘") }
                let recovery = try AgentOfficeWindow.recoveryState(saved.saved.value)
                let source = try AgentFiles(workspace: asset.deletingLastPathComponent().path)
                checks["draftUsesUnchangedWorkbookAndWorkspaceJournal"] = try editor.dirty && recovery.documentDirty == false &&
                    recovery.view?.contains(firstID) == true && files.fileHash(document) == hash && source.fileHash(asset) == hash
                try archiveCopy(asset, to: "draft-workbook.xlsx", from: source, hash: hash)
                try JSONEncoder().encode(ThreadCreationFixture(task: task, window: window, tab: tab.id, hash: hash, firstID: firstID))
                    .write(to: fixtureFile, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(ThreadCreationFixture.self, from: Data(contentsOf: fixtureFile))
                control.window?.appearance = NSAppearance(named: .darkAqua)
                control.show(tab: "chat"); control.window?.setContentSize(NSSize(width: 780, height: 540))
                guard await flushWorkspaceWindows() else { throw PetError("工作簿未恢复") }
                if control.taskWorkspace.currentController as? AgentOfficeWindow == nil {
                    control.taskWorkspace.checkSelect(.document(document.path))
                    guard await flushWorkspaceWindows() else { throw PetError("评论标签未恢复") }
                }
                guard let editor = control.taskWorkspace.currentController as? AgentOfficeWindow, editor.file == document else { throw PetError("原表格窗口缺失") }
                let visible = try await editor.checkSpreadsheetThread()
                checks["sameTaskAndWindow"] = control.workspaceSession?.id == fixture.window && control.agentTaskID == fixture.task &&
                    tasks.task(fixture.task)?.draft == title
                checks["narrowGridAndCommentSidebarFit"] = (visible["grid"] as? Double ?? 0) > 230 &&
                    (visible["right"] as? Double ?? 0) - (visible["left"] as? Double ?? 0) >= 180
                if stage == "resume" {
                    let positioned = try await isActive(editor, position: first)
                    checks["draftRestoresOriginalIDCellTextAndSelection"] = try visible["draft"] as? String == firstText &&
                        visible["selection"] as? [Int] == [0, 4] && visible["focused"] as? Bool == true &&
                        visible["threadID"] as? String == fixture.firstID && positioned && files.fileHash(document) == fixture.hash
                    try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("create-threads-narrow.png"))
                    let opened = try await editor.checkSpreadsheetThread(action: "key")
                    checks["keyboardPublishesSameRootAndOffersReply"] = messages(opened).first?["id"] == fixture.firstID &&
                        messages(opened).first?["text"] == firstText && messages(opened).first?["parent"] == "" &&
                        messages(opened).first?["author"] == "小鲸" && opened["composerAction"] as? String == "添加回复"
                    let replied = try await editor.checkSpreadsheetThread(text: replyText, action: "submit")
                    checks["newThreadAcceptsReplyBeforeFirstSave"] = messages(replied).count == 2 &&
                        messages(replied).last?["parent"] == fixture.firstID && messages(replied).last?["text"] == replyText
                    try await editor.saveDocument()
                    try archiveCopy(document, to: "first-save.xlsx", from: files, hash: files.fileHash(document))
                    let saved = try await AgentSpreadsheetNotes.threadCatalog(document)
                    checks["firstExplicitSaveMaterializesRootAndReply"] = !editor.dirty && saved.threads.count == initialCount + 1 &&
                        saved.threads.contains { $0.id == fixture.firstID && $0.cell == first.cell && $0.messages.count == 2 }
                    try await setCell(editor, position: follow)
                    let second = try await editor.checkSpreadsheetThread(text: followText, action: "submit", newAddress: followAddress)
                    try await editor.saveDocument()
                    let all = try await AgentSpreadsheetNotes.threadCatalog(document)
                    checks["secondSheetAddsOneThreadWithoutRepeatingFirst"] = !editor.dirty && all.threads.count == initialCount + 2 &&
                        all.threads.contains { $0.id == fixture.firstID && $0.messages.count == 2 } &&
                        all.threads.contains { $0.id == second["threadID"] as? String && $0.cell == follow.cell && $0.messages.first?.text == followText }
                    let query = try await editor.inspect(["sheet": "销售", "range": "C4"])
                    guard let sheet = query["sheet"], let version = query["version"] else { throw PetError("原单元格无法读取") }
                    try await editor.checkWorkspaceEdit(["expectVersion": version, "steps": [
                        ["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "C4"]], "inputs": [["29.6"]]]
                    ]])
                    try await editor.saveDocument()
                    let ids = try await AgentSpreadsheetNotes.threadCatalog(document).threads.flatMap(\.messages).map(\.id)
                    checks["laterOrdinarySaveKeepsNewCommentIDs"] = ids == all.threads.flatMap(\.messages).map(\.id) && !editor.dirty
                } else {
                    checks["reopenReadsBothSavedThreads"] = visible["selected"] as? String == followAddress && !editor.dirty &&
                        (visible["entries"] as? [String])?.count == initialCount + 2 && messages(visible).first?["text"] == followText
                    let originalThread = try await editor.checkSpreadsheetThread(address: firstAddress)
                    checks["firstThreadRetainsItsRootAndReplyAfterReopen"] = messages(originalThread).first?["id"] == fixture.firstID &&
                        messages(originalThread).first?["text"] == firstText && messages(originalThread).last?["text"] == replyText
                    let notes = try await editor.checkSpreadsheetNotes(show: true, address: "销售 · C3")
                    checks["compatibilityRecordsStayOutOfNotesList"] = Set(notes["entries"] as? [String] ?? []) == ["销售 · C3", "审阅 · E35"] &&
                        notes["value"] as? String == "核对税前金额\n保留样例"
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
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: output.appendingPathComponent("create-spreadsheet-threads-" + stage + ".json"), options: .atomic)
        }
    }
}
