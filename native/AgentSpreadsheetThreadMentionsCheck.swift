import AppKit

@MainActor extension AppDelegate {
    private struct ThreadMentionFixture: Codable {
        let task: String, window: String, tab: String, hash: String, thread: String
    }

    func runSpreadsheetThreadMentionsCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let project = output.appendingPathComponent("project"), document = project.appendingPathComponent("sample.xlsx")
        let fixtureFile = output.appendingPathComponent("mentions-fixture.json")
        let journal = AgentWorkspaceRecovery(profile: store.directory)
        let taskInput = "保留原任务输入"
        let existingAddress = "销售 · F15", newAddress = "销售 · B6"
        let firstPerson = "{00000000-0000-4000-8000-000000000003}", secondPerson = "{00000000-0000-4000-8000-000000000004}"
        let firstEmail = "chen@review.example", secondEmail = "chen.alt@review.example"
        let authorEmail = "lin@review.example", explicitEmail = "nina@example.invalid"
        let rootPrefix = "🧭 _x0041_\n请 ", prepended = "核对🪙 "
        let draft = prepended + rootPrefix + "@陈工 "
        let rootText = draft + "\n选 @林晓 "
        let replyText = "字面 @陈工。\n再次 @林晓 和 @" + explicitEmail + " "
        let mentionStart = (prepended + rootPrefix).utf16.count
        var checks: [String: Bool] = [:], failure: String?, modelRequests = 0

        func draftMentions(_ editor: AgentOfficeWindow, thread: String) async throws -> [[String: Any]] {
            let view = try await editor.checkWorkspaceView()
            let threads = view["threads"] as? [String: Any]
            let drafts = threads?["drafts"] as? [[String: Any]]
            return drafts?.first { $0["id"] as? String == thread }?["mentions"] as? [[String: Any]] ?? []
        }
        func marks(_ check: [String: Any], by field: String) -> [String] {
            (check["marks"] as? [[String: String]] ?? []).compactMap { $0[field] }
        }
        func sameRecipient(_ mentions: [[String: Any]], at start: Int) -> Bool {
            mentions.count == 1 && mentions[0]["start"] as? Int == start && mentions[0]["length"] as? Int == 3 &&
                (mentions[0]["recipient"] as? [String: String])?["id"] == secondPerson
        }
        func checkPosted(_ editor: AgentOfficeWindow, thread: String) async throws {
            let visible = try await editor.checkSpreadsheetThread()
            let messages = visible["messages"] as? [[String: String]] ?? []
            let posted = try await editor.checkSpreadsheetMentions()
            let ids = marks(posted, by: "person")
            checks["postedBodyAndParentage"] = messages.count == 2 && messages.first?["id"] == thread &&
                messages.first?["text"] == rootText && messages.last?["parent"] == thread && messages.last?["text"] == replyText
            checks["postedLinksBindToChosenPeopleAndExcludeLiteralText"] = marks(posted, by: "recipient") ==
                [secondEmail, authorEmail, authorEmail, explicitEmail] &&
                marks(posted, by: "text") == ["@陈工", "@林晓", "@林晓", "@" + explicitEmail] &&
                ids.count == 4 && ids[0] == secondPerson && ids[1] == ids[2] && Set(ids).count == 3
        }

        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("评论提及需要独立验收资料")
            }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("评论提及验收禁止模型请求") }
            let files = try AgentFiles(workspace: project.path)
            if stage == "seed" {
                let hash = try files.fileHash(document)
                let task = tasks.create(title: "核对工作簿评论提及", workspace: project.path, draft: taskInput)
                control.showAgentTask(task); control.show(tab: "chat")
                control.window?.appearance = NSAppearance(named: .aqua)
                control.window?.setContentSize(NSSize(width: 1320, height: 800))
                let editor = try await tasks.offices.show(document.path, taskID: task)
                guard let window = control.workspaceSession?.id,
                      let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "document:" + document.path }) else {
                    throw PetError("原工作簿没有恢复标签")
                }
                _ = try await editor.checkSpreadsheetThread(show: true, address: existingAddress)
                let old = try await editor.checkSpreadsheetMentions()
                checks["existingMentionUsesItsOriginalPerson"] = marks(old, by: "person") == [firstPerson] && marks(old, by: "text") == ["@陈工"]

                var view = try await editor.checkWorkspaceView()
                let cell = ["row": 5, "col": 1]
                view["selection"] = ["sheetName": "销售", "sheetIndex": 0, "cells": ["anchor": cell, "focus": cell]]
                view["scroll"] = []
                _ = try await editor.checkWorkspaceView(view)
                let opened = try await editor.checkSpreadsheetThread(newAddress: newAddress)
                guard let thread = opened["threadID"] as? String, !thread.isEmpty else { throw PetError("新评论缺少编号") }
                checks["newCommentAnchoredAtActiveCell"] = try await editor.checkSpreadsheetNoteVisible(sheet: "销售", cell: "B6")
                let offered = try await editor.checkSpreadsheetMentions(insert: rootPrefix + "@陈")
                let names = offered["options"] as? [[String: Any]] ?? []
                checks["sameNameContactChoicesHaveDistinctAddresses"] = names.count == 2 &&
                    names.allSatisfy { $0["name"] as? String == "陈工" } &&
                    Set(names.compactMap { $0["email"] as? String }) == [firstEmail, secondEmail]
                try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("mentions-wide.png"))
                let dismissed = try await editor.checkSpreadsheetMentions(key: "Escape")
                checks["escapeClosesPickerAndKeepsDraft"] = dismissed["pickerOpen"] as? Bool == false &&
                    dismissed["value"] as? String == rootPrefix + "@陈" && dismissed["focused"] as? Bool == true
                let reopened = try await editor.checkSpreadsheetMentions(insert: "工")
                let items = reopened["options"] as? [[String: Any]] ?? []
                if items.first?["email"] as? String != secondEmail { _ = try await editor.checkSpreadsheetMentions(key: "ArrowDown") }
                let picked = try await editor.checkSpreadsheetMentions(key: "Enter")
                let firstMentions = try await draftMentions(editor, thread: thread)
                checks["keyboardBindsSelectedContact"] = picked["value"] as? String == rootPrefix + "@陈工 " &&
                    picked["pickerOpen"] as? Bool == false && sameRecipient(firstMentions, at: rootPrefix.utf16.count)
                let inside = rootPrefix.utf16.count + 1
                let changed = try await editor.checkSpreadsheetMentions(insert: "新", range: inside..<(inside + 1))
                let changedMentions = try await draftMentions(editor, thread: thread)
                checks["editingMentionTextClearsItsLink"] = changed["value"] as? String == rootPrefix + "@新工 " && changedMentions.isEmpty
                _ = try await editor.checkSpreadsheetMentions(insert: rootPrefix + "@陈", range: 0..<(rootPrefix + "@新工 ").utf16.count)
                _ = try await editor.checkSpreadsheetMentions(choose: secondEmail)
                let shifted = try await editor.checkSpreadsheetMentions(insert: prepended, range: 0..<0)
                _ = try await editor.checkSpreadsheetMentions(range: 1..<4)
                let shiftedMentions = try await draftMentions(editor, thread: thread)
                checks["prefixWithSurrogatePairMovesPosition"] = shifted["value"] as? String == draft &&
                    sameRecipient(shiftedMentions, at: mentionStart)

                guard await flushWorkspaceWindows(), let saved = try journal.loadPage(windowID: window, pageID: tab.id, taskID: task),
                      let asset = saved.asset else { throw PetError("提及草稿未落盘") }
                let recovery = try AgentOfficeWindow.recoveryState(saved.saved.value)
                let source = try AgentFiles(workspace: asset.deletingLastPathComponent().path)
                checks["journalPreservesDraftAndWorkbookBytes"] = try editor.dirty && recovery.documentDirty == false &&
                    recovery.view?.contains(secondPerson) == true && files.fileHash(document) == hash && source.fileHash(asset) == hash
                try AgentFiles(workspace: output.path).copyFile(asset, from: source, to: output.appendingPathComponent("draft-workbook.xlsx"),
                                                               permissions: 0o600, expectedHash: hash, maximum: AgentOffice.maximum)
                try JSONEncoder().encode(ThreadMentionFixture(task: task, window: window, tab: tab.id, hash: hash, thread: thread))
                    .write(to: fixtureFile, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(ThreadMentionFixture.self, from: Data(contentsOf: fixtureFile))
                control.window?.appearance = NSAppearance(named: .darkAqua)
                control.show(tab: "chat"); control.window?.setContentSize(NSSize(width: 780, height: 540))
                guard await flushWorkspaceWindows() else { throw PetError("工作簿未恢复") }
                if control.taskWorkspace.currentController as? AgentOfficeWindow == nil {
                    control.taskWorkspace.checkSelect(.document(document.path))
                    guard await flushWorkspaceWindows() else { throw PetError("评论标签未恢复") }
                }
                guard let editor = control.taskWorkspace.currentController as? AgentOfficeWindow, editor.file == document else { throw PetError("原表格窗口缺失") }
                let panel = try await editor.checkSpreadsheetThread(address: stage == "final" ? newAddress : nil)
                checks["sameTaskWindowAndTab"] = control.workspaceSession?.id == fixture.window && control.agentTaskID == fixture.task &&
                    tasks.task(fixture.task)?.draft == taskInput &&
                    control.taskWorkspace.recoveryLayouts.contains { $0.taskID == fixture.task && $0.tabs.contains { $0.id == fixture.tab } }
                checks["narrowWindowKeepsGridAndCommentsVisible"] = (panel["grid"] as? Double ?? 0) > 230 &&
                    (panel["right"] as? Double ?? 0) - (panel["left"] as? Double ?? 0) >= 180
                if stage == "resume" {
                    let recovered = try await draftMentions(editor, thread: fixture.thread)
                    let positioned = try await editor.checkSpreadsheetNoteVisible(sheet: "销售", cell: "B6")
                    checks["restoresTextSelectionFocusAndLink"] = try panel["draft"] as? String == draft &&
                        panel["selection"] as? [Int] == [1, 4] && panel["focused"] as? Bool == true && panel["selected"] as? String == newAddress &&
                        panel["threadID"] as? String == fixture.thread && positioned && sameRecipient(recovered, at: mentionStart) &&
                        files.fileHash(document) == fixture.hash
                    _ = try await editor.checkSpreadsheetMentions(insert: "\n选 ＠林")
                    let author = try await editor.checkSpreadsheetMentions(choose: authorEmail)
                    checks["fullWidthTriggerFindsWorkbookAuthor"] = author["value"] as? String == rootText
                    _ = try await editor.checkSpreadsheetThread(action: "key")
                    let beforePicker = try await editor.checkSpreadsheetMentions()
                    let inPicker = try await editor.checkSpreadsheetMentions(insert: "字面 @陈工。\n再次 @林")
                    let bodyHeight = beforePicker["bodyHeight"] as? Int ?? 0
                    checks["narrowPickerKeepsBodyHeightAndFitsAboveInput"] = bodyHeight >= 80 &&
                        inPicker["bodyHeight"] as? Int == bodyHeight && inPicker["pickerOpen"] as? Bool == true &&
                        (inPicker["pickerTop"] as? Double ?? -1) >= 0 &&
                        (inPicker["pickerBottom"] as? Double ?? .infinity) < (inPicker["inputTop"] as? Double ?? 0)
                    try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("mentions-narrow-picker.png"))
                    _ = try await editor.checkSpreadsheetMentions(key: "Tab")
                    _ = try await editor.checkSpreadsheetMentions(insert: "和 @" + explicitEmail)
                    let email = try await editor.checkSpreadsheetMentions(choose: explicitEmail)
                    checks["completeEmailCanBeSelectedInReply"] = email["value"] as? String == replyText
                    _ = try await editor.checkSpreadsheetThread(action: "submit")
                    try await checkPosted(editor, thread: fixture.thread)
                    try await editor.saveDocument()
                    let hash = try files.fileHash(document)
                    try AgentFiles(workspace: output.path).copyFile(document, from: files, to: output.appendingPathComponent("first-save.xlsx"),
                                                                   permissions: 0o600, expectedHash: hash, maximum: AgentOffice.maximum)
                    checks["firstSaveWritesLinkedComments"] = !editor.dirty && hash != fixture.hash
                    try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("mentions-narrow.png"))

                    let query = try await editor.inspect(["sheet": "销售", "range": "C4"])
                    guard let sheet = query["sheet"], let version = query["version"] else { throw PetError("原单元格无法读取") }
                    try await editor.checkWorkspaceEdit(["expectVersion": version, "steps": [
                        ["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "C4"]], "inputs": [["29.6"]]]
                    ]])
                    try await editor.saveDocument()
                    checks["ordinarySaveKeepsCommentPanelClean"] = !editor.dirty
                } else {
                    try await checkPosted(editor, thread: fixture.thread)
                    checks["reopenDoesNotDirtyWorkbook"] = !editor.dirty
                    let original = try await editor.checkSpreadsheetThread(address: existingAddress)
                    let prior = try await editor.checkSpreadsheetMentions()
                    checks["originalThreadAndMentionRemain"] = (original["messages"] as? [[String: String]])?.count == 3 &&
                        marks(prior, by: "person") == [firstPerson] && marks(prior, by: "recipient") == [firstEmail]
                    let notes = try await editor.checkSpreadsheetNotes(show: true, address: "销售 · C3")
                    checks["ordinaryNoteStillSeparateFromThread"] = notes["value"] as? String == "核对税前金额\n保留样例" &&
                        Set(notes["entries"] as? [String] ?? []) == ["销售 · C3", "审阅 · E35"]
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
            try? bytes.write(to: output.appendingPathComponent("spreadsheet-mentions-" + stage + ".json"), options: .atomic)
        }
    }
}
