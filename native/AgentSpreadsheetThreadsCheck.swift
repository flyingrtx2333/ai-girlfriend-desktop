import AppKit

@MainActor extension AppDelegate {
    private struct SpreadsheetThreadFixture: Codable {
        let task: String, window: String, tab: String, hash: String
    }

    func runSpreadsheetThreadsCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let project = output.appendingPathComponent("project"), document = project.appendingPathComponent("sample.xlsx")
        let fixtureFile = output.appendingPathComponent("threads-fixture.json")
        let journal = AgentWorkspaceRecovery(profile: store.directory)
        let active = "销售 · F15", closed = "销售 · B10"
        let firstReply = "核查回复 <公开> 🧭\n  字面 _x0041_", secondReply = "已重新核验\n第二条证据"
        var checks: [String: Bool] = [:], failure: String?, modelRequests = 0

        func articles(_ result: [String: Any]) -> [[String: String]] { result["messages"] as? [[String: String]] ?? [] }
        func fits(_ result: [String: Any]) -> Bool {
            let grid = result["grid"] as? Double ?? 0, left = result["left"] as? Double ?? 0
            let right = result["right"] as? Double ?? 0, width = result["width"] as? Double ?? 0
            return grid > 230 && abs(left - grid) < 1 && abs(right - width) < 1 && right - left >= 180
        }
        func activeCommentCell(_ editor: AgentOfficeWindow) async throws -> Bool {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                let view = try await editor.checkWorkspaceView()
                if let selection = view["selection"] as? [String: Any], selection["sheetName"] as? String == "销售",
                   let cells = selection["cells"] as? [String: Any], cells["anchor"] as? [String: Int] == ["row": 14, "col": 5],
                   cells["focus"] as? [String: Int] == ["row": 14, "col": 5] {
                    return try await editor.checkSpreadsheetNoteVisible(sheet: "销售", cell: "F15")
                }
                try await Task.sleep(for: .milliseconds(70))
            }
            return false
        }
        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("评论验收需要独立资料")
            }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("评论验收禁止模型请求") }
            let files = try AgentFiles(workspace: project.path)
            if stage == "seed" {
                let hash = try files.fileHash(document)
                let task = tasks.create(title: "公开表格评论", workspace: project.path, draft: "保留原任务文字")
                control.showAgentTask(task); control.show(tab: "chat")
                control.window?.appearance = NSAppearance(named: .aqua)
                control.window?.setContentSize(NSSize(width: 1320, height: 800))
                let editor = try await tasks.offices.show(document.path, taskID: task)
                guard let window = control.workspaceSession?.id,
                      let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "document:" + document.path }) else {
                    throw PetError("原工作簿没有恢复标签")
                }
                let original = try await editor.checkSpreadsheetThread(show: true, address: active)
                let messages = articles(original)
                checks["commentsOpenAsSeparateCellThreads"] = original["entries"] as? [String] == [active, closed] &&
                    original["selected"] as? String == active && original["showingNotes"] as? Bool == false && fits(original)
                checks["readsOriginalPeopleTimesAndReplyChain"] = messages.count == 3 &&
                    messages.map { $0["author"] ?? "" } == ["陈工", "审阅小组", "陈工"] &&
                    messages[1]["parent"] == messages[0]["id"] && messages[2]["parent"] == messages[1]["id"] &&
                    messages[0]["text"] == "核对报价 <样例> 🧭" && messages[1]["text"] == "已查验第一项\n准备复核" &&
                    messages[0]["time"] == "2025-06-10T00:07:06.55"
                let resolved = try await editor.checkSpreadsheetThread(address: closed)
                checks["resolvedThreadIsReadableAndMustReopenBeforeReply"] = resolved["resolved"] as? [String] == [closed] &&
                    resolved["canReply"] as? Bool == false && resolved["canResolve"] as? Bool == true && articles(resolved).count == 1
                let drafted = try await editor.checkSpreadsheetThread(address: active, text: firstReply)
                let located = try await activeCommentCell(editor)
                checks["draftUsesMovedPlaceholderCell"] = drafted["draft"] as? String == firstReply &&
                    drafted["canSubmit"] as? Bool == true && located
                try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("threads-wide.png"))
                let rejected: Bool
                do { try await editor.saveDocument(); rejected = false }
                catch { rejected = error.localizedDescription.contains("先添加回复") }
                checks["savingAnUnsubmittedReplyKeepsTheSource"] = try rejected && editor.dirty && files.fileHash(document) == hash
                guard await flushWorkspaceWindows(), let saved = try journal.loadPage(windowID: window, pageID: tab.id, taskID: task), let asset = saved.asset,
                      let view = try AgentOfficeWindow.recoveryState(saved.saved.value).view else { throw PetError("未提交回复的恢复记录缺失") }
                let recovery = try AgentOfficeWindow.recoveryState(saved.saved.value)
                let source = try AgentFiles(workspace: asset.deletingLastPathComponent().path), evidence = try AgentFiles(workspace: output.path)
                checks["unsubmittedReplyStaysInTheRecoveryJournal"] = try recovery.dirty && recovery.documentDirty == false &&
                    view.contains("字面 _x0041_") && source.fileHash(asset) == hash
                try evidence.copyFile(asset, from: source, to: output.appendingPathComponent("draft-workbook.xlsx"),
                                      permissions: 0o600, expectedHash: saved.saved.value.asset?.hash, maximum: AgentOffice.maximum)
                try JSONEncoder().encode(SpreadsheetThreadFixture(task: task, window: window, tab: tab.id, hash: hash)).write(to: fixtureFile, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(SpreadsheetThreadFixture.self, from: Data(contentsOf: fixtureFile))
                control.window?.appearance = NSAppearance(named: .darkAqua)
                control.show(tab: "chat"); control.window?.setContentSize(NSSize(width: 780, height: 540))
                guard await flushWorkspaceWindows() else { throw PetError("工作簿未恢复") }
                if control.taskWorkspace.currentController as? AgentOfficeWindow == nil {
                    control.taskWorkspace.checkSelect(.document(document.path))
                    guard await flushWorkspaceWindows() else { throw PetError("原评论标签未恢复") }
                }
                guard let editor = control.taskWorkspace.currentController as? AgentOfficeWindow, editor.file == document else {
                    throw PetError("原评论窗口未恢复")
                }
                let visible = try await editor.checkSpreadsheetThread()
                checks["originalTaskWindowAndDraftRemain"] = control.workspaceSession?.id == fixture.window && control.agentTaskID == fixture.task &&
                    tasks.task(fixture.task)?.draft == "保留原任务文字"
                checks["narrowCommentPaneKeepsGridUsable"] = fits(visible)
                checks["reopenedCommentStillLocatesItsCell"] = try await activeCommentCell(editor)
                if stage == "resume" {
                    checks["unsentReplyRestoresSelectionAndFocus"] = try editor.dirty && visible["draft"] as? String == firstReply &&
                        visible["selection"] as? [Int] == [0, 4] && visible["focused"] as? Bool == true &&
                        visible["selected"] as? String == active && articles(visible).count == 3 && files.fileHash(document) == fixture.hash
                    try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("threads-narrow.png"))
                    let sent = try await editor.checkSpreadsheetThread(action: "submit")
                    let root = articles(sent).first
                    checks["replyIsAppendedWithLocalAuthorAndParent"] = articles(sent).count == 4 &&
                        articles(sent).last?["author"] == "小鲸" && articles(sent).last?["parent"] == root?["id"] &&
                        articles(sent).last?["text"] == firstReply && sent["draft"] as? String == ""
                    let resolved = try await editor.checkSpreadsheetThread(action: "resolve")
                    checks["resolveBlocksAdditionalReplyUntilReopened"] = (resolved["resolved"] as? [String])?.contains(active) == true &&
                        resolved["canReply"] as? Bool == false
                    let opened = try await editor.checkSpreadsheetThread(address: closed, action: "resolve")
                    checks["reopeningAllowsReplyOnTheOriginalCell"] = opened["canReply"] as? Bool == true &&
                        (opened["resolved"] as? [String])?.contains(closed) == false
                    _ = try await editor.checkSpreadsheetThread(text: secondReply, action: "submit")
                    let plain = try await editor.checkSpreadsheetNotes(show: true, address: "销售 · C3")
                    checks["legacyPlaceholdersAreHiddenButNotesRemainEditable"] = Set(plain["entries"] as? [String] ?? []) == ["销售 · C3", "审阅 · E35"] &&
                        plain["readOnly"] as? Bool == false && plain["value"] as? String == "核对税前金额\n保留样例"
                    _ = try await editor.checkSpreadsheetNotes(edit: "常规备注已核对")
                    _ = try await editor.checkSpreadsheetThread(show: true, address: active)
                    try await editor.saveDocument()
                    let catalog = try await AgentSpreadsheetNotes.threadCatalog(document)
                    checks["fileSaveAppliesBothThreadChanges"] = !editor.dirty && catalog.threads.count == 2 &&
                        catalog.threads.contains { $0.cell == "F15" && $0.resolved && $0.messages.last?.text == firstReply } &&
                        catalog.threads.contains { $0.cell == "B10" && !$0.resolved && $0.messages.last?.text == secondReply }
                    let query = try await editor.inspect(["sheet": "销售", "range": "C4"])
                    guard let sheet = query["sheet"], let version = query["version"] else { throw PetError("工作表不可读") }
                    try await editor.checkWorkspaceEdit(["expectVersion": version, "steps": [
                        ["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "C4"]], "inputs": [["29.6"]]]
                    ]])
                    try await editor.saveDocument()
                    let repeated = try await AgentSpreadsheetNotes.threadCatalog(document).threads.flatMap(\.messages)
                    checks["laterCellSaveKeepsReplyIDsAndDoesNotDuplicateThem"] = !editor.dirty &&
                        repeated.map(\.id) == catalog.threads.flatMap(\.messages).map(\.id) && repeated.count == 6
                } else {
                    checks["finalReopenReadsSavedThread"] = !editor.dirty && visible["selected"] as? String == active &&
                        visible["resolved"] as? [String] == [active] && articles(visible).last?["text"] == firstReply &&
                        articles(visible).last?["author"] == "小鲸"
                    let second = try await editor.checkSpreadsheetThread(address: closed)
                    checks["finalReopenReadsSecondThreadAndParticipant"] = second["canReply"] as? Bool == true &&
                        articles(second).count == 2 && articles(second).last?["text"] == secondReply
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
            try? bytes.write(to: output.appendingPathComponent("spreadsheet-threads-" + stage + ".json"), options: .atomic)
        }
    }
}
