import AppKit

@MainActor extension AppDelegate {
    struct TextViewportFixture: Codable {
        var first: String, second: String, window: String
        var plainFile: String, guide: String, plainTab: String, blockTab: String, cellTab: String
        var plain: AgentRecordWindow.RecoveryState, block: AgentRecordWindow.RecoveryState, cell: AgentRecordWindow.RecoveryState
        var sourceHashes: [String: String]
        var readingFile: String? = nil, readingTab: String? = nil
        var reading: AgentRecordWindow.RecoveryState? = nil
    }
    func runTextViewportRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("文本位置验收禁止模型请求") }
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("input.json"))) as! [String: String]
            func expected(_ name: String) throws -> String { guard let value = input[name] else { throw PetError("缺少独立预期正文") }; return value }
            let journal = AgentWorkspaceRecovery(profile: store.directory), fixtureURL = output.appendingPathComponent("text-viewport-fixture.json")
            func state(_ page: AgentRecordWindow) async throws -> AgentRecordWindow.RecoveryState { try AgentRecordWindow.recoveryState(await page.captureWorkspaceRecovery()) }
            func editor(_ task: String) throws -> AgentRecordWindow {
                guard let value = control.taskWorkspace.recoveryController(taskID: task, root: .document(output.appendingPathComponent("workspace/guide.md").path)) as? AgentRecordWindow else { throw PetError("Markdown 父页没有恢复") }; return value
            }
            func floating() throws -> AgentRecordWindow {
                guard let value = control.workspaceSession?.floatingControllers.compactMap({ $0 as? AgentRecordWindow }).first(where: { $0.workspaceDocumentURL?.lastPathComponent == "plain.txt" }) else { throw PetError("独立原文窗口没有恢复") }; return value
            }
            func eventually(_ predicate: () -> Bool) async -> Bool { for _ in 0..<150 { if predicate() { return true }; await wait(0.02) }; return predicate() }
            func inlineReady(_ page: AgentRecordWindow) -> Bool {
                guard let view = page.textViewportReadback["markdown"] as? [String: Any], let edit = view["editor"] as? [String: Any] else { return false }
                return view["pending"] as? Bool == false && edit["focused"] as? Bool == true
            }
            func same(_ a: AgentTextViewport?, _ b: AgentTextViewport?, reflowing: Bool = false) -> Bool {
                guard let a, let b else { return false }
                // A wrapped cell can keep the same reading line at a different pixel offset.
                let samePosition = reflowing ? a.anchor == b.anchor && abs(a.offset - b.offset) < 0.5 : abs(a.y - b.y) < 0.5
                return a.hash == b.hash && a.count == b.count && a.selections == b.selections && abs(a.x - b.x) < 0.5 && samePosition
            }
            let fixture: TextViewportFixture
            if stage == "seed" {
                let workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path), plainFile = try files.resolve("plain.txt"), guide = try files.resolve("guide.md")
                do {
                    let file = try files.resolve("preview-recovery.md"), image = try files.resolve("preview-recovery.png")
                    let original = "![预览图](preview-recovery.png)\n\n原段落。\n"
                    let replacement = "在原位续写这段文字"
                    let preview = AgentMarkdownReader(frame: NSRect(x: 0, y: 0, width: 400, height: 360)), restored = AgentMarkdownReader()
                    var draft = original
                    preview.canEdit = { true }; preview.onSourceChanged = { draft = $0 }
                    preview.show(original, file: file, workspace: workspace.path)
                    try preview.checkViewRecovery(action: "begin", target: "原段落。", input: replacement,
                        selection: (replacement as NSString).range(of: "续写"), y: nil, cell: false)
                    guard let saved = try preview.captureViewRecovery(source: draft), saved.editor != nil,
                          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                       bytesPerRow: 0, bitsPerPixel: 0) else { throw PetError("预览续编样例不完整") }
                    bitmap.setColor(.blue, atX: 0, y: 0)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("验收图片不可用") }
                    let previewText = preview.text.string
                    try preview.checkViewRecovery(action: "retry-images", target: "", input: nil, selection: nil, y: nil, cell: false)
                    checks["missingImageRemainsRetryableWithStableText"] = preview.document?.canRetryImages == true &&
                        preview.document?.images.isEmpty == true && preview.text.string == previewText
                    let reading = AgentMarkdownReader()
                    reading.show(original, file: file, workspace: workspace.path)
                    guard var oldReading = try reading.captureViewRecovery(source: original),
                          let firstBlock = reading.document?.regions.first?.display else { throw PetError("旧图片阅读位置样例不可用") }
                    let oldText = NSMutableString(string: reading.text.string)
                    oldText.replaceCharacters(in: firstBlock, with: "预览图 · " + POSIXError(.ENOENT).localizedDescription + "\n")
                    let oldSelection = oldText.range(of: "原段落。"), newSelection = (reading.text.string as NSString).range(of: "原段落。")
                    oldReading.viewport.hash = AgentFiles.hash(Data((oldText as String).utf8))
                    oldReading.viewport.count = oldText.length
                    oldReading.viewport.anchor = oldSelection.location
                    oldReading.viewport.selections = [.init(location: oldSelection.location, length: oldSelection.length)]
                    try reading.restoreViewRecovery(oldReading)
                    let migrated = try reading.captureViewRecovery(source: original)?.viewport
                    checks["previousImageErrorTextMigratesExactReadingAnchorAndSelection"] = newSelection.location != oldSelection.location &&
                        migrated?.anchor == newSelection.location && migrated?.selections.first?.range == newSelection &&
                        migrated?.hash == AgentFiles.hash(Data(reading.text.string.utf8))
                    try files.writeData(png, to: image)
                    let beforeRetry = draft
                    try preview.checkViewRecovery(action: "retry-images", target: "", input: nil, selection: nil, y: nil, cell: false)
                    let resumed = try preview.captureViewRecovery(source: draft)
                    checks["imageRetryKeepsInlineDraftSelectionAndRenderedRanges"] = preview.document?.images[image.path] != nil &&
                        preview.document?.canRetryImages == false && preview.text.string == previewText && draft == beforeRetry && resumed?.editor == saved.editor
                    restored.canEdit = { true }; restored.show(draft, file: file, workspace: workspace.path)
                    try restored.restoreViewRecovery(saved)
                    let position = try restored.captureViewRecovery(source: draft)
                    checks["presentImageRestoresTheSamePreviewAndInlineSelection"] = position?.editor == saved.editor &&
                        position?.sourceHash == saved.sourceHash && position?.viewport.hash == saved.viewport.hash && position?.viewport.valid == true
                    let legacyReader = AgentMarkdownReader()
                    legacyReader.canEdit = { true }; legacyReader.show(draft, file: file, workspace: workspace.path)
                    var legacy = saved
                    legacy.viewport.hash = AgentFiles.hash(Data("预览图 · The operation couldn’t be completed. No such file or directory\n\n原段落。\n".utf8))
                    try legacyReader.restoreViewRecovery(legacy)
                    let oldPosition = try legacyReader.captureViewRecovery(source: draft)
                    checks["changedImagePreviewKeepsVerifiedInlineEdit"] = oldPosition?.editor == legacy.editor &&
                        oldPosition?.sourceHash == legacy.sourceHash && oldPosition?.viewport.hash != legacy.viewport.hash && oldPosition?.viewport.valid == true
                    let escaped = try files.resolve("late-image.png"), outsideImage = output.appendingPathComponent("outside-image.png")
                    var protected = AgentMarkdownDocument.render("![工作区图片](late-image.png)\n![外部图片](https://example.invalid/image.png)",
                                                                document: file, files: files, width: 400)
                    try png.write(to: outsideImage)
                    try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outsideImage)
                    let protectedText = protected.body.string
                    let rejected = protected.retryImages(document: file, files: files)
                    checks["imageRetryRevalidatesChangedSymlinkAndKeepsRemoteOffline"] = rejected && protected.images.isEmpty &&
                        !protected.canRetryImages && protected.body.string == protectedText && protectedText.contains("远程图片未加载")
                }
                let first = tasks.create(title: "文本位置主任务", workspace: workspace.path), second = tasks.create(title: "文本位置另一任务", workspace: workspace.path)
                for id in [first, second] { tasks.update(id) { $0.draft = "保留输入 PUBLIC_VIEWPORT_DRAFT_417" } }
                control.window?.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 774), display: true)
                control.showAgentTask(first); control.show(tab: "chat"); control.showTaskDocument(plainFile.path)
                guard let plain = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("原文没有进入任务工作区") }
                try control.presentArtifactWindow(plain, taskID: first)
                plain.window?.setFrame(NSRect(x: 180, y: 160, width: 780, height: 540), display: true)
                let plainRange = (try expected("plainText") as NSString).range(of: "PUBLIC_PLAIN_CURSOR_518 中文😀")
                try plain.checkTextViewport(selection: plainRange, y: 460)
                plain.window?.makeFirstResponder(nil)
                let rawChromeState = try await state(plain)
                checks["windowChromeBeforeFirstAutosaveKeepsLastOriginalInputTarget"] = (plain.textViewportReadback["raw"] as? [String: Any])?["focused"] as? Bool == false && rawChromeState.textViewport?.focused == true
                guard await flushWorkspaceWindows(), let window = control.workspaceSession?.id, let saved = try journal.loadWindow(window)?.value,
                      let plainTab = saved.floating.first(where: { $0.tab.root == "document:" + plainFile.path })?.tab.id else { throw PetError("原文位置没有保存") }
                let path = store.directory.appendingPathComponent("workspace-recovery/" + window + "/pages/" + plainTab + ".json")
                let caret = NSRange(location: plainRange.location + 1, length: 0)
                try plain.checkTextViewport(selection: caret)
                checks["selectionOnlyEventAutosavesWithoutExplicitFlush"] = await eventually {
                    guard let data = try? Data(contentsOf: path), let page = try? JSONDecoder().decode(AgentWorkspaceRecovery.Page.self, from: data), let value = try? AgentRecordWindow.recoveryState(page) else { return false }
                    return value.textViewport?.selections.first?.location == caret.location && value.textViewport?.selections.first?.length == 0
                }
                let original = try Data(contentsOf: path), before = try await state(plain)
                try original.write(to: output.appendingPathComponent("read-only-original-page.json"))
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
                try plain.checkTextViewport(y: 490)
                let refused = !(await flushWorkspaceWindows()), current = try Data(contentsOf: path), live = try await state(plain)
                checks["readOnlyCheckpointRetainsBytesAndLatestLiveScroll"] = refused && current == original && (live.textViewport?.y ?? 0) > (before.textViewport?.y ?? 0) + 10
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                checks["scrollCheckpointRetriesWithoutAnotherEdit"] = await flushWorkspaceWindows()
                let readingFile = try files.resolve("reading.md")
                control.showTaskDocument(readingFile.path)
                guard let reading = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("阅读页未进入工作区") }
                try reading.checkTextViewport(selection: (try expected("guideText") as NSString).range(of: "PUBLIC_PARAGRAPH_50"), y: 520)
                guard await flushWorkspaceWindows() else { throw PetError("原文阅读位置未保存") }
                try reading.checkTextViewport(preview: true, target: "PUBLIC_PARAGRAPH_50", y: 700)
                guard await flushWorkspaceWindows() else { throw PetError("预览阅读位置未保存") }
                control.showTaskDocument(guide.path)
                let block = try editor(first), blockValue = try expected("blockValue")
                try block.checkTextViewport(preview: true, action: "begin", target: "PUBLIC_BLOCK_ORIGINAL_517", input: blockValue, selection: (blockValue as NSString).range(of: "中文😀"), y: 90)
                control.window?.makeFirstResponder(nil)
                let inlineChromeState = try await state(block)
                checks["sidebarBeforeFirstAutosaveKeepsLastInlineInputTarget"] = !inlineReady(block) && inlineChromeState.markdownViewport?.editor?.viewport.focused == true
                try block.checkTextViewport(preview: true, selection: (blockValue as NSString).range(of: "中文😀"), y: 90)
                guard await flushWorkspaceWindows() else { throw PetError("段落编辑没有保存") }
                await wait(0.7)
                checks["autosaveNeverFinishesActiveBlockEditor"] = (try await state(block)).markdownViewport?.editor != nil && inlineReady(block)
                control.showAgentTask(second); control.showTaskDocument(guide.path); control.window?.makeKeyAndOrderFront(nil)
                let cell = try editor(second), cellValue = try expected("cellValue")
                func cellGeometry() -> (height: Double, fittingHeight: Double) {
                    let view = cell.textViewportReadback["markdown"] as? [String: Any]
                    let edit = view?["editor"] as? [String: Any]
                    return (edit?["height"] as? Double ?? 0, edit?["fittingHeight"] as? Double ?? 0)
                }
                try cell.checkTextViewport(preview: true, action: "begin", target: "PUBLIC_CELL_ORIGINAL_628", cell: true)
                let initial = cellGeometry()
                try cell.checkTextViewport(preview: true, input: "第一行\n第二行😀\n")
                checks["cellRowExpandsToFitWrappedDraftAndTrailingLine"] = await eventually {
                    let geometry = cellGeometry()
                    return initial.height > 0 && geometry.height > initial.height && geometry.height >= geometry.fittingHeight &&
                        geometry.fittingHeight >= 50
                }
                let expanded = cellGeometry()
                try cell.checkTextViewport(preview: true, input: "原值")
                checks["cellRowShrinksWhenDraftIsShortened"] = await eventually {
                    let geometry = cellGeometry()
                    return geometry.height >= geometry.fittingHeight && geometry.height <= initial.height && geometry.height < expanded.height
                }
                try cell.checkTextViewport(preview: true, input: cellValue, selection: (cellValue as NSString).range(of: "中文😀"), y: 60, cell: true)
                checks["longCellEditorKeepsInternalScrollWithinHeightLimit"] = await eventually {
                    let geometry = cellGeometry()
                    return geometry.height > expanded.height && geometry.height <= 160 && geometry.fittingHeight > geometry.height
                }
                report["cellLayout"] = ["initial": [initial.height, initial.fittingHeight],
                    "expanded": [expanded.height, expanded.fittingHeight], "long": [cellGeometry().height, cellGeometry().fittingHeight]]
                guard await flushWorkspaceWindows(), let layout = try journal.loadWindow(window)?.value,
                      let blockTab = layout.tasks.first(where: { $0.taskID == first })?.tabs.first(where: { $0.root == "document:" + guide.path })?.id,
                      let cellTab = layout.tasks.first(where: { $0.taskID == second })?.tabs.first(where: { $0.root == "document:" + guide.path })?.id else { throw PetError("段落或表格位置没有保存") }
                let readingTab = layout.tasks.first(where: { $0.taskID == first })?.tabs.first(where: { $0.root == "document:" + readingFile.path })?.id
                fixture = .init(first: first, second: second, window: window, plainFile: plainFile.path, guide: guide.path, plainTab: plainTab, blockTab: blockTab, cellTab: cellTab,
                    plain: try await state(plain), block: try await state(block), cell: try await state(cell), sourceHashes: try Dictionary(uniqueKeysWithValues: [plainFile, guide, readingFile].map { ($0.path, try files.fileHash($0)) }),
                    readingFile: readingFile.path, readingTab: readingTab, reading: try await state(reading))
                checks["floatingUTF16SourceHasIndependentSelectionAndScroll"] = fixture.plain.encoding == AgentTextEncoding.utf16LE.rawValue && fixture.plain.bom && (fixture.plain.textViewport?.y ?? 0) > 400 && fixture.plain.textViewport?.selections.first?.location == caret.location
                checks["backgroundBlockRetainsEditorSelectionAndFocus"] = fixture.block.markdownViewport?.editor?.viewport.focused == true && fixture.block.markdownViewport?.editor?.value == blockValue
                checks["sameFileTasksHaveDistinctCompleteDrafts"] = try fixture.block.text == expected("expectedBlock") && fixture.cell.text == expected("expectedCell") && fixture.block.text != fixture.cell.text
                checks["activeCellHasItsOwnCursorAndScroll"] = fixture.cell.markdownViewport?.editor?.viewport.focused == true && (fixture.cell.markdownViewport?.editor?.viewport.y ?? 0) > 0 && fixture.cell.markdownViewport?.editor?.viewport.selections.first?.length == 4
                checks["readingKeepsSeparateOriginalAndPreviewViewports"] = (fixture.reading?.textViewport?.y ?? 0) > 400 && (fixture.reading?.markdownViewport?.viewport.y ?? 0) > 600 && fixture.reading?.textViewport?.selections.first?.location != fixture.reading?.markdownViewport?.viewport.selections.first?.location
                var page = try await cell.captureWorkspaceRecovery(), object = try JSONSerialization.jsonObject(with: page.state) as! [String: Any]
                object.removeValue(forKey: "textViewport"); object.removeValue(forKey: "markdownViewport"); page.state = try JSONSerialization.data(withJSONObject: object)
                checks["legacyV1RecordsWithoutViewStateStillDecode"] = try AgentRecordWindow.recoveryState(page).text == fixture.cell.text
                let valid = try await plain.captureWorkspaceRecovery()
                for key in ["version", "count", "selections", "offset", "unknown"] {
                    var bad = valid, raw = try JSONSerialization.jsonObject(with: valid.state) as! [String: Any], view = raw["textViewport"] as! [String: Any]
                    switch key { case "version": view[key] = 2; case "count": view[key] = -1; case "selections": view[key] = [["location": Int.max, "length": 1]]; case "offset": view[key] = 2_000_000_000; default: view[key] = true }
                    raw["textViewport"] = view; bad.state = try JSONSerialization.data(withJSONObject: raw)
                    do { _ = try AgentRecordWindow.recoveryState(bad); checks["rejectInvalidViewport-" + key] = false } catch { checks["rejectInvalidViewport-" + key] = true }
                }
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(TextViewportFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows(); guard await flushWorkspaceWindows() else { throw PetError("位置恢复尚未完成") }
                if interactive {
                    guard let current = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("原任务所选文本页未恢复") }
                    let currentState = try await state(current), plain = try floating()
                    checks["actualSelectedRootPreservedAndReady"] = await eventually {
                        let readback = current.textViewportReadback
                        let view = readback[currentState.markdownViewport != nil && currentState.mode == 0 ? "markdown" : "raw"] as? [String: Any]
                        return view?["pending"] as? Bool == false
                    }
                    report["activeActual"] = current.textViewportReadback; report["activeTask"] = control.agentTaskID
                    report["plainActual"] = plain.textViewportReadback
                } else if stage == "invalid" {
                    let path = store.directory.appendingPathComponent("workspace-recovery/" + fixture.window + "/pages/" + fixture.cellTab + ".json")
                    checks["unknownNestedViewKeepsWholeEditorCold"] = control.taskWorkspace.recoveryController(taskID: fixture.second, root: .document(fixture.guide)) == nil
                    checks["unknownViewOriginalBytesPreserved"] = try Data(contentsOf: path) == Data(contentsOf: output.appendingPathComponent("future-view-input.json"))
                } else if stage == "source" {
                    checks["changedCleanSourceKeepsFloatingViewCold"] = control.workspaceSession?.floatingControllers.compactMap({ $0 as? AgentRecordWindow }).contains(where: { $0.workspaceDocumentURL?.path == fixture.plainFile }) != true
                    let path = store.directory.appendingPathComponent("workspace-recovery/" + fixture.window + "/pages/" + fixture.plainTab + ".json")
                    checks["changedSourceRetainsOriginalViewBytes"] = try Data(contentsOf: path) == Data(contentsOf: output.appendingPathComponent("original-plain-page.json"))
                } else {
                    if stage == "retry" {
                        let path = store.directory.appendingPathComponent("workspace-recovery/" + fixture.window + "/pages/" + fixture.cellTab + ".json")
                        try Data(contentsOf: output.appendingPathComponent("original-cell-page.json")).write(to: path)
                        control.taskWorkspace.checkSelect(.document(fixture.guide)); guard await flushWorkspaceWindows() else { throw PetError("原位置重试未完成") }
                    }
                    let cell = try editor(fixture.second), plain = try floating()
                    checks["currentCellActualInputFocusRestores"] = await eventually { inlineReady(cell) }
                    let cellState = try await state(cell), plainState = try await state(plain)
                    if !interactive {
                        checks["cellCompleteDraftAndOriginalBaseRestore"] = cellState.text == fixture.cell.text && cellState.markdownViewport?.editor?.base == fixture.cell.markdownViewport?.editor?.base
                        checks["cellActualSelectionAndInternalScrollRestore"] = same(cellState.markdownViewport?.editor?.viewport, fixture.cell.markdownViewport?.editor?.viewport, reflowing: true)
                        checks["floatingSourceSelectionScrollEncodingRestore"] = same(plainState.textViewport, fixture.plain.textViewport) && plainState.encoding == fixture.plain.encoding && plainState.bom
                    }
                    report["cellActual"] = cell.textViewportReadback; report["plainActual"] = plain.textViewportReadback
                    if !interactive {
                        control.showAgentTask(fixture.first); guard await flushWorkspaceWindows() else { throw PetError("后台段落未恢复") }
                        let block = try editor(fixture.first)
                        checks["coldBackgroundBlockRestoresActualEditorFocus"] = await eventually { inlineReady(block) }
                        let blockState = try await state(block)
                        checks["backgroundBlockFullDraftAndViewportRestore"] = blockState.text == fixture.block.text && same(blockState.markdownViewport?.editor?.viewport, fixture.block.markdownViewport?.editor?.viewport)
                        if let file = fixture.readingFile, let saved = fixture.reading {
                            control.taskWorkspace.checkSelect(.document(file)); guard await flushWorkspaceWindows(), let reading = control.taskWorkspace.currentController as? AgentRecordWindow else { throw PetError("冷阅读标签未恢复") }
                            checks["readingKeepsModeFromPreviousProcess"] = try await state(reading).mode == (stage == "reopen" ? 1 : saved.mode)
                            try reading.checkTextViewport(preview: true)
                            checks["readingPreviewAppliesAfterItsFinalLayout"] = await eventually { (reading.textViewportReadback["markdown"] as? [String: Any])?["pending"] as? Bool == false }
                            let restored = try await state(reading)
                            checks["previewReadingSelectionAndScrollRestore"] = same(restored.markdownViewport?.viewport, saved.markdownViewport?.viewport)
                            try reading.checkTextViewport(preview: false)
                            checks["switchingToOriginalAppliesDeferredViewAndFocus"] = await eventually {
                                guard let raw = reading.textViewportReadback["raw"] as? [String: Any] else { return false }
                                return raw["pending"] as? Bool == false && raw["focused"] as? Bool == true && raw["location"] as? Int == saved.textViewport?.selections.first?.location
                            }
                            checks["originalReadingSelectionAndScrollStayIndependent"] = same(try await state(reading).textViewport, saved.textViewport)
                            if stage == "reopen" {
                                try reading.checkTextViewport(input: "RAW_RESUMED_953")
                                checks["originalTextContinuesAtItsOwnRestoredSelection"] = try await state(reading).text == expected("continuedReading")
                            }
                            control.taskWorkspace.checkSelect(.document(fixture.guide)); _ = await flushWorkspaceWindows()
                            checks["cachedBlockRegainsItsRememberedInputFocus"] = await eventually { inlineReady(block) }
                        }
                        if stage == "reopen" {
                            try block.checkTextViewport(preview: true, action: "insert", input: "BLOCK_RESUMED_739")
                            let continuedBlock = try await state(block)
                            checks["blockContinuesAtRestoredSelectionWithoutReopeningEditor"] = try continuedBlock.text == expected("continuedBlock") && continuedBlock.markdownViewport?.editor != nil
                            control.showAgentTask(fixture.second); guard await flushWorkspaceWindows() else { throw PetError("表格未返回") }
                            try cell.checkTextViewport(preview: true, action: "insert", input: "CELL_RESUMED_842")
                            checks["cellContinuesAtRestoredSelectionWithoutReopeningEditor"] = try await state(cell).text == expected("continuedCell")
                        }
                        if stage != "reopen" { control.showAgentTask(fixture.second); _ = await flushWorkspaceWindows() }
                    }
                }
            }
            let files = try AgentFiles(workspace: output.appendingPathComponent("workspace").path)
            if stage != "source" { checks["originalFilesAndEncodingsRemainExact"] = try fixture.sourceHashes.allSatisfy { try files.fileHash(URL(fileURLWithPath: $0.key)) == $0.value } }
            checks["bothTaskInputsAndNoRepliesRemainExact"] = [fixture.first, fixture.second].allSatisfy { tasks.task($0)?.draft == "保留输入 PUBLIC_VIEWPORT_DRAFT_417" && tasks.task($0)?.messages.isEmpty == true && (tasks.task($0)?.modelReceipts ?? []).isEmpty }
            checks["latestViewStatesCheckpointed"] = await flushWorkspaceWindows(); checks["noModels"] = requests == 0
            report["stage"] = stage
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "text-viewport-ui-ready.json" : "text-viewport-report.json"))
    }
}
