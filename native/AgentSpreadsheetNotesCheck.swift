import AppKit

@MainActor extension AppDelegate {
    private struct SpreadsheetNotesFixture: Codable {
        let task: String, window: String, tab: String, hash: String
    }
    private struct SpreadsheetNoteColors: Decodable {
        let editor: [String]
        let palette: [String?], unavailable: [String?]
    }

    func runSpreadsheetRichNoteCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let project = output.appendingPathComponent("project")
        let document = project.appendingPathComponent("sample.xlsx")
        let fixtureFile = output.appendingPathComponent("rich-notes-fixture.json")
        let journal = AgentWorkspaceRecovery(profile: store.directory)
        let original = "核对合同 🌊，复查日期"
        let draft = "核对订单 🌊，复查日期"
        let finished = "核对订单 🌊，复核\n  对齐日期"
        let plain = "核对税前金额\n保留样例"
        let newNote = "补充凭据"
        var checks: [String: Bool] = [:], failure: String?, modelRequests = 0, preview: [String: Any] = [:]

        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("备注验收需要独立资料")
            }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("备注验收禁止模型请求") }
            let files = try AgentFiles(workspace: project.path)
            let colorsFile = output.appendingPathComponent("note-colors.json")
            let colors: SpreadsheetNoteColors? = FileManager.default.fileExists(atPath: colorsFile.path)
                ? try JSONDecoder().decode(SpreadsheetNoteColors.self, from: Data(contentsOf: colorsFile)) : nil
            if stage == "seed" {
                let hash = try files.fileHash(document)
                let task = tasks.create(title: "公开富文本备注", workspace: project.path, draft: "保留原任务输入")
                control.showAgentTask(task); control.show(tab: "chat")
                control.window?.appearance = NSAppearance(named: .aqua)
                control.window?.setContentSize(NSSize(width: 1320, height: 800))
                let editor = try await tasks.offices.show(document.path, taskID: task)
                guard let window = control.workspaceSession?.id,
                      let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "document:" + document.path }) else {
                    throw PetError("原备注文件标签缺失")
                }
                let opened = try await editor.checkSpreadsheetNotes(show: true, address: "审阅 · E35")
                checks["originalNoteShowsItsOwnInlineFormatting"] = opened["value"] as? String == original && opened["readOnly"] as? Bool == false &&
                    opened["bold"] as? [String] == ["核对合同 🌊"] && opened["italic"] as? [String] == ["，复查日期"] &&
                    opened["doubleUnderline"] as? [String] == ["，复查日期"]
                if let colors {
                    let resolved = colors.editor.compactMap { value -> String? in
                        guard let rgb = UInt32(value, radix: 16) else { return nil }
                        return "rgb(\((rgb >> 16) & 255), \((rgb >> 8) & 255), \(rgb & 255))"
                    }
                    checks["customThemeTintAndExplicitColorRenderInLightWindow"] = opened["runColors"] as? [String] == colors.editor.map { "#" + $0 } &&
                        opened["resolvedRunColors"] as? [String] == resolved && opened["dark"] as? Bool == false
                    for (name, expected) in [("theme-palette", colors.palette), ("theme-unavailable", colors.unavailable)] {
                        let file = output.appendingPathComponent(name + ".xlsx")
                        let note = try await AgentSpreadsheetNotes.read(file).first { $0.sheet == "审阅" && $0.cell == "E35" }
                        checks[name] = note?.editable == true && note?.runs?.map(\.rgb) == expected
                    }
                    preview = opened.filter { ["runColors", "resolvedRunColors", "dark"].contains($0.key) }
                }
                let typed = try await editor.checkSpreadsheetNotes(edit: "订单", range: 2..<4)
                checks["typingInsideBoldRunKeepsTheOtherRuns"] = typed["value"] as? String == draft &&
                    typed["bold"] as? [String] == ["核对订单 🌊"] && typed["italic"] as? [String] == ["，复查日期"]
                let formatted = try await editor.checkSpreadsheetNotes(range: 0..<2, action: "underline")
                checks["toolbarFormatsOnlyTheSelectedCharacters"] = formatted["underline"] as? [String] == ["核对", "，复查日期"]
                let undone = try await editor.checkSpreadsheetNotes(action: "undo")
                let redone = try await editor.checkSpreadsheetNotes(action: "redo")
                checks["formatCanBeUndoneAndRedone"] = undone["underline"] as? [String] == ["，复查日期"] &&
                    redone["underline"] as? [String] == ["核对", "，复查日期"]
                let at = (draft as NSString).range(of: "复查").location
                let split = try await editor.checkSpreadsheetNotes(range: at..<at, action: "enter")
                let unsplit = try await editor.checkSpreadsheetNotes(action: "undo")
                checks["enterInsertsOneLineBreakWithoutDroppingTheStyle"] = split["value"] as? String == "核对订单 🌊，\n复查日期" &&
                    split["doubleUnderline"] as? [String] == ["，\n复查日期"] && unsplit["value"] as? String == draft
                _ = try await editor.checkSpreadsheetNotes(range: 0..<2)
                checks["positionedAtOriginalCell"] = try await editor.checkSpreadsheetNoteVisible(sheet: "审阅", cell: "E35")
                try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("rich-notes-wide.png"))
                guard await flushWorkspaceWindows(), let entry = try journal.loadPage(windowID: window, pageID: tab.id, taskID: task),
                      let asset = entry.asset else { throw PetError("富文本备注草稿未写入恢复文件") }
                let note = try await AgentSpreadsheetNotes.read(asset).first { $0.cell == "E35" }
                checks["checkpointContainsStyledDraftOnly"] = try entry.saved.value.dirty && note?.text == draft &&
                    note?.runs?.map(\.underline) == [true, false, true] && files.fileHash(document) == hash
                let assets = try AgentFiles(workspace: asset.deletingLastPathComponent().path)
                let evidence = try AgentFiles(workspace: output.path)
                try evidence.copyFile(asset, from: assets, to: output.appendingPathComponent("rich-note-checkpoint.xlsx"),
                                      permissions: 0o600, expectedHash: entry.saved.value.asset?.hash, maximum: AgentOffice.maximum)
                try JSONEncoder().encode(SpreadsheetNotesFixture(task: task, window: window, tab: tab.id, hash: hash)).write(to: fixtureFile, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(SpreadsheetNotesFixture.self, from: Data(contentsOf: fixtureFile))
                control.window?.appearance = NSAppearance(named: .darkAqua)
                control.show(tab: "chat"); control.window?.setContentSize(NSSize(width: 780, height: 540))
                guard await flushWorkspaceWindows() else { throw PetError("办公标签尚未恢复") }
                if control.taskWorkspace.currentController as? AgentOfficeWindow == nil {
                    control.taskWorkspace.checkSelect(.document(document.path))
                    guard await flushWorkspaceWindows() else { throw PetError("原备注标签未恢复") }
                }
                guard let editor = control.taskWorkspace.currentController as? AgentOfficeWindow, editor.file == document else { throw PetError("原备注窗口缺失") }
                let visible = try await editor.checkSpreadsheetNotes()
                let noteView = try await editor.checkWorkspaceView()["notes"] as? [String: Any]
                let selection = noteView?["selected"] as? [String: Any]
                checks["windowAndTaskDraftRestore"] = control.workspaceSession?.id == fixture.window && control.agentTaskID == fixture.task &&
                    tasks.task(fixture.task)?.draft == "保留原任务输入"
                checks["narrowWindowShowsNoteAndGrid"] = (visible["grid"] as? Double ?? 0) > 230 &&
                    (visible["right"] as? Double ?? 0) - (visible["left"] as? Double ?? 0) >= 180
                checks["restoredNoteStillLocatesItsCell"] = try await editor.checkSpreadsheetNoteVisible(sheet: "审阅", cell: "E35")
                if let colors {
                    let inks = visible["resolvedRunColors"] as? [String] ?? []
                    checks["reopenedNoteDisplaysBothOriginalColorsInDarkWindow"] = visible["dark"] as? Bool == true &&
                        Set(visible["runColors"] as? [String] ?? []) == Set(colors.editor.map { "#" + $0 }) && Set(inks).count == 2
                    preview = visible.filter { ["runColors", "resolvedRunColors", "dark"].contains($0.key) }
                }
                if stage == "resume" {
                    checks["styledDraftReopensWithOriginalSelection"] = try editor.dirty && visible["value"] as? String == draft &&
                        visible["underline"] as? [String] == ["核对", "，复查日期"] && visible["selection"] as? String == "核对" &&
                        selection?["cell"] as? String == "E35" && selection?["focused"] as? Bool == true && files.fileHash(document) == fixture.hash
                    try await editor.checkSpreadsheetNotesImage(output.appendingPathComponent("rich-notes-narrow.png"))
                    let replace = (draft as NSString).range(of: "复查")
                    let pasted = try await editor.checkSpreadsheetNotes(edit: "复核\n  对齐", range: replace.location..<(replace.location + replace.length))
                    checks["multilinePasteRetainsInlineStyleAndSpaces"] = pasted["value"] as? String == finished &&
                        pasted["doubleUnderline"] as? [String] == ["，复核\n  对齐日期"]
                    let end = (finished as NSString).length
                    let restyled = try await editor.checkSpreadsheetNotes(range: (end - 2)..<end, action: "italic")
                    checks["removingItalicRetainsDoubleUnderline"] = restyled["italic"] as? [String] == ["，复核\n  对齐"] &&
                        (restyled["doubleUnderline"] as? [String])?.joined() == "，复核\n  对齐日期"
                    _ = try await editor.checkSpreadsheetNotes(address: "销售 · C3")
                    let promoted = try await editor.checkSpreadsheetNotes(range: 0..<2, action: "boldKey")
                    checks["keyboardCanStyleAnExistingPlainNote"] = promoted["bold"] as? [String] == ["核对"] && promoted["value"] as? String == plain
                    var view = try await editor.checkWorkspaceView()
                    let cell = ["row": 5, "col": 1]
                    view["selection"] = ["sheetIndex": 0, "sheetName": "销售", "cells": ["anchor": cell, "focus": cell]]
                    view["scroll"] = []
                    _ = try await editor.checkWorkspaceView(view)
                    _ = try await editor.checkSpreadsheetNotes(newAddress: "销售 · B6", edit: newNote)
                    let created = try await editor.checkSpreadsheetNotes(range: 0..<2, action: "bold")
                    checks["newNoteCanContainFormattedText"] = created["value"] as? String == newNote && created["bold"] as? [String] == ["补充"]
                    _ = try await editor.checkSpreadsheetNotes(address: "审阅 · E35")
                    try await editor.saveDocument()
                    let query = try await editor.inspect(["sheet": "销售", "range": "C4"])
                    guard let sheet = query["sheet"], let version = query["version"] else { throw PetError("原工作表不可读") }
                    try await editor.checkWorkspaceEdit(["expectVersion": version, "steps": [
                        ["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "C4"]], "inputs": [["29.6"]]]
                    ]])
                    try await editor.saveDocument()
                    let notes = try await AgentSpreadsheetNotes.read(document)
                    checks["cellSaveKeepsAllThreeNotes"] = !editor.dirty && notes.count == 3 &&
                        notes.contains { $0.cell == "E35" && $0.text == finished && $0.runs?.count == 4 } &&
                        notes.contains { $0.cell == "B6" && $0.runs?.first?.bold == true } &&
                        notes.contains { $0.cell == "C3" && $0.runs?.first?.bold == true }
                } else {
                    checks["finalReopenRendersSavedRichText"] = !editor.dirty && visible["value"] as? String == finished &&
                        visible["italic"] as? [String] == ["，复核\n  对齐"] && visible["underline"] as? [String] == ["核对", "，复核\n  对齐", "日期"]
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
        if !preview.isEmpty { report["preview"] = preview }
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: output.appendingPathComponent("spreadsheet-rich-notes-" + stage + ".json"), options: .atomic)
        }
    }

    private func runSpreadsheetAppearanceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], observed: [String: Any] = [:], failure: String?, requests = 0
        let project = output.appendingPathComponent("project")
        let document = project.appendingPathComponent("sample.xlsx")
        let draft = "保留跨主题的备注草稿"
        func surface(_ state: [String: Any], _ name: String) -> [String: Any] {
            (state["surfaces"] as? [String: [String: Any]])?[name] ?? [:]
        }
        func palette(_ state: [String: Any], dark: Bool) -> Bool {
            let keys = ["formatting", "formula", "name", "tabs", "selected", "note", "scroll"]
            return keys.allSatisfy { key in
                let value = surface(state, key), lightness = value["lightness"] as? Double ?? -1
                return dark ? (0..<0.16).contains(lightness) : lightness > 0.62
            }
        }
        func sameSheet(_ first: [String: Any], _ second: [String: Any]) -> Bool {
            guard let colors = first["authoredPixels"] as? [Int], colors.count == 2, colors.allSatisfy({ $0 > 180 }),
                  let hash = first["paintHash"] as? String, hash.count == 64 else { return false }
            return hash == second["paintHash"] as? String && first["gridPixels"] as? [Int] == second["gridPixels"] as? [Int] &&
                first["selected"] as? String == second["selected"] as? String && first["address"] as? String == second["address"] as? String &&
                first["scroll"] as? [Double] == second["scroll"] as? [Double]
        }
        func findExpand(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityLabel() == "放大工作区" { return button }
            return view.subviews.lazy.compactMap(findExpand).first
        }
        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime, let host = control.window,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("工作簿外观验收需要独立资料")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("工作簿外观验收禁止模型请求") }
            let files = try AgentFiles(workspace: project.path), hash = try files.fileHash(document)
            let task = tasks.create(title: "公开工作簿外观验收", workspace: project.path, draft: "保留工作台原草稿")
            control.showAgentTask(task); control.show(tab: "chat")
            host.appearance = NSAppearance(named: .aqua); host.setContentSize(NSSize(width: 780, height: 540))
            let editor = try await tasks.offices.show(document.path, taskID: task)
            _ = try await editor.checkSpreadsheetNotes(show: true, address: "预算概览 · B3", edit: draft)
            _ = try await editor.checkSpreadsheetNotes(range: 0..<2)
            checks["actualNoteOpensOnOriginalSheet"] = try await editor.checkSpreadsheetNoteVisible(sheet: "预算概览", cell: "B3")
            func sample(_ name: String, dark: Bool, minimumWidth: Double = 0, action: String = "") async throws -> [String: Any] {
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let deadline = Date().addingTimeInterval(6)
                while Date() < deadline {
                    let state = try await editor.checkSpreadsheetAppearance()
                    if state["dark"] as? Bool == dark, (state["width"] as? Double ?? 0) >= minimumWidth {
                        let captured = try await editor.checkSpreadsheetAppearance(action: action, image: output.appendingPathComponent(name + ".png"))
                        observed[name] = captured
                        return captured
                    }
                    await wait(0.05)
                }
                throw PetError("工作簿外观未随原窗口更新")
            }
            let light = try await sample("narrow-light", dark: false)
            let dark = try await sample("narrow-dark", dark: true)
            checks["darkToolbarFormulaTabsAndReview"] = palette(dark, dark: true)
            checks["lightToolbarFormulaTabsAndReview"] = palette(light, dark: false)
            checks["narrowRetainsSheetPixelsPositionAndPalette"] = sameSheet(light, dark)
            let retained = try await editor.checkSpreadsheetNotes()
            checks["switchRetainsUnsavedNoteSelectionAndFocus"] = retained["value"] as? String == draft &&
                retained["selection"] as? String == "保留" && retained["focused"] as? Bool == true
            let focus = try await editor.checkSpreadsheetAppearance(action: "formula")
            let otherFocus = try await sample("narrow-light-formula", dark: false)
            checks["formulaFocusAndValueFollowTheme"] = focus["formulaFocus"] as? Bool == true && otherFocus["formulaFocused"] as? Bool == true &&
                focus["formulaValue"] as? String == otherFocus["formulaValue"] as? String && focus["address"] as? String == "B3"
            let lightMenu = try await sample("menu-light", dark: false, action: "menu")
            _ = try await editor.checkSpreadsheetAppearance(action: "menu")
            let darkMenu = try await sample("menu-dark", dark: true, action: "menu")
            _ = try await editor.checkSpreadsheetAppearance(action: "menu")
            let firstMenu = lightMenu["menu"] as? [String: Any] ?? [:], secondMenu = darkMenu["menu"] as? [String: Any] ?? [:]
            checks["overflowStaysReadableAndBoundedInBothPalettes"] = (firstMenu["lightness"] as? Double ?? -1) > 0.62 &&
                (0..<0.16).contains(secondMenu["lightness"] as? Double ?? -1) && [firstMenu, secondMenu].allSatisfy {
                    $0["inside"] as? Bool == true && $0["endReachable"] as? Bool == true && ($0["contrast"] as? Double ?? 0) >= 4.5
                }
            _ = try await editor.checkSpreadsheetAppearance(action: "edit-cell")
            let cellDark = try await sample("cell-editor-dark", dark: true)["cellEditor"] as? [String: Any] ?? [:]
            let cellLight = try await sample("cell-editor-light", dark: false)["cellEditor"] as? [String: Any] ?? [:]
            let cancelled = try await sample("cell-editor-cancelled", dark: true, action: "cancel-cell")
            checks["activeCellKeepsItsFormulaAndFocusAcrossThemeSwitch"] = (0..<0.16).contains(cellDark["lightness"] as? Double ?? -1) &&
                (cellLight["lightness"] as? Double ?? -1) > 0.62 && [cellDark, cellLight].allSatisfy {
                    $0["value"] as? String == "=SUM(B4:B7)" && $0["focused"] as? Bool == true && ($0["contrast"] as? Double ?? 0) >= 4.5
                } && cancelled["cellEditor"] as? [String: Any] == nil && cancelled["formulaValue"] as? String == "=SUM(B4:B7)"
            let locked = try await editor.checkSpreadsheetAppearance(action: "lock")
            let lockNote = try await editor.checkSpreadsheetNotes()
            checks["lockedFormulaAndReviewStayReadable"] = locked["locked"] as? Bool == true && lockNote["readOnly"] as? Bool == true &&
                surface(locked, "formula")["color"] as? String != surface(dark, "formula")["color"] as? String &&
                (surface(locked, "formula")["contrast"] as? Double ?? 0) >= 4.5
            _ = try await editor.checkSpreadsheetAppearance(action: "unlock")
            let compact = host.contentView?.bounds.size
            host.setContentSize(NSSize(width: 1320, height: 800)); host.contentView?.layoutSubtreeIfNeeded()
            if let expand = findExpand(control.taskWorkspace), !expand.isHiddenOrHasHiddenAncestor { expand.performClick(nil) }
            let darkWide = try await sample("wide-dark", dark: true, minimumWidth: 900)
            let lightWide = try await sample("wide-light", dark: false, minimumWidth: 900)
            checks["widePalettesPreserveThePaintedWorkbook"] = palette(darkWide, dark: true) && palette(lightWide, dark: false) && sameSheet(darkWide, lightWide)
            checks["exactCompactAndWideWindows"] = compact == NSSize(width: 780, height: 540) && host.contentView?.bounds.size == NSSize(width: 1320, height: 800)
            checks["originalWorkbookAndTaskUnchanged"] = try files.fileHash(document) == hash && tasks.task(task)?.draft == "保留工作台原草稿"
            checks["viewChangesRetainDraftUntilExit"] = await flushWorkspaceWindows() && editor.dirty
        } catch { failure = error.localizedDescription }
        checks["zeroModelRequests"] = requests == 0
        var report: [String: Any] = ["appPID": getpid(), "checks": checks, "observed": observed, "modelRequests": requests,
                                     "success": failure == nil && checks.values.allSatisfy { $0 }]
        report["error"] = failure
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: output.appendingPathComponent("spreadsheet-appearance.json"), options: .atomic)
        }
    }

    func runSpreadsheetNotesCheck(_ output: URL) async {
        if CommandLine.arguments.contains("--spreadsheet-editor-appearance") {
            await runSpreadsheetAppearanceCheck(output)
            return
        }
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
