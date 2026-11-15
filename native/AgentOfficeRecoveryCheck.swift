import AppKit

@MainActor extension AppDelegate {
    struct OfficeRecoveryFixture: Codable {
        var taskID: String, windowID: String
        var paths: [String: String], hashes: [String: String], tabs: [String: String]
        var reviewer = "审阅人：恢复草稿二"
        var views: [String: String]? = nil
    }
    func runOfficeRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("办公恢复验收禁止模型请求") }
            let fixtureURL = output.appendingPathComponent("office-recovery-fixture.json"), journal = AgentWorkspaceRecovery(profile: store.directory)
            let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
            let keys = ["docx", "xlsx", "pptx", "missing"], first = "审阅人：恢复草稿一", second = "审阅人：恢复草稿二"
            let exports = output.appendingPathComponent("recovered-exports")
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func observed(_ editor: AgentOfficeWindow) async throws -> [String: Any] { try await editor.inspect(editor.file.pathExtension.lowercased() == "xlsx" ? ["sheet": "审阅", "range": "A1"] : [:]) }
            func contains(_ value: [String: Any], _ marker: String) -> Bool {
                (value["paragraphs"] as? [[String: Any]])?.contains { $0["text"] as? String == marker } == true ||
                (value["stories"] as? [[String: Any]])?.contains { $0["text"] as? String == marker } == true ||
                (value["cells"] as? [[String: Any]])?.contains { ($0["value"] as? [String: Any])?["value"] as? String == marker } == true
            }
            func viewText(_ value: [String: Any]) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
            func comparableView(_ text: String) throws -> String {
                var value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
                if value["format"] as? String == "docx", var selection = value["selection"] as? [String: Any] {
                    for key in ["anchor", "focus"] { if var point = selection[key] as? [String: Any] { for field in ["paragraphID", "storyKind", "itemID"] { point.removeValue(forKey: field) }; selection[key] = point } }
                    value["selection"] = selection
                }
                return try viewText(value)
            }
            func selectPosition(_ editor: AgentOfficeWindow, key: String) async throws -> [String: Any] {
                var value = try await editor.checkWorkspaceView(); value["scroll"] = []
                switch key {
                case "docx", "missing":
                    let point: [String: Any] = ["part": "/word/document.xml", "ordinal": 1, "paragraphID": NSNull(), "storyKind": NSNull(), "itemID": NSNull()]
                    var anchor = point, focus = point; anchor["offset"] = 4; focus["offset"] = 9
                    value["selection"] = ["anchor": anchor, "focus": focus]
                case "xlsx":
                    value["zoom"] = 1.25
                    value["selection"] = ["sheetIndex": 1, "sheetName": "审阅", "cells": ["anchor": ["row": 12, "col": 5], "focus": ["row": 10, "col": 3]]]
                default:
                    value["selection"] = ["slide": 2, "part": NSNull(), "target": ["kind": "text", "shapePath": [1], "sourceID": 0, "storyIndex": 0, "anchor": 3, "focus": 8]]
                }
                return try await editor.checkWorkspaceView(value)
            }
            func edit(_ editor: AgentOfficeWindow, from old: String, to text: String) async throws {
                let actual = try await observed(editor); guard let version = actual["version"] as? String else { throw PetError("办公文档实际版本不可读") }
                let step: [String: Any]
                switch editor.file.pathExtension.lowercased() {
                case "docx":
                    guard let paragraph = (actual["paragraphs"] as? [[String: Any]])?.first(where: { $0["text"] as? String == old }) else { throw PetError("Word 实际段落未找到") }
                    step = ["op": "replaceText", "target": ["kind": "paragraph", "story": paragraph["story"]!, "paraId": paragraph["id"]!], "text": text, "expect": ["text": old]]
                case "xlsx":
                    guard let sheet = actual["sheet"] as? String else { throw PetError("实际工作表未找到") }
                    step = ["op": "setCellInputs", "target": ["sheetId": sheet, "range": ["kind": "a1", "a1": "A1"]], "inputs": [[text]]]
                default:
                    guard let story = (actual["stories"] as? [[String: Any]])?.first(where: { $0["text"] as? String == old }) else { throw PetError("实际幻灯片文字未找到") }
                    step = ["op": "replaceText", "target": ["kind": "search", "within": ["slideId": story["slideId"]!, "shapeId": story["shapeId"]!, "storyId": story["id"]!], "text": old], "text": text, "expect": ["text": old]]
                }
                // Do not verify/flush after this edit: the real SDK change
                // notification must wake autosave while already dirty.
                try await editor.checkWorkspaceEdit(["expectVersion": version, "steps": [step]], verify: false)
            }
            func snapshot(window: String, tab: String, task: String, after revision: Int) async throws -> AgentWorkspaceRecovery.LoadedPage {
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    if let loaded = try? journal.loadPage(windowID: window, pageID: tab, taskID: task),
                       let state = try? AgentOfficeWindow.recoveryState(loaded.saved.value), state.dirty, state.editorRevision > revision, loaded.asset != nil { return loaded }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw PetError("逐次办公编辑未自动写入恢复附件")
            }
            func copy(_ loaded: AgentWorkspaceRecovery.LoadedPage, name: String) async throws {
                guard let asset = loaded.asset, let hash = loaded.saved.value.asset?.hash else { throw PetError("完整恢复附件缺失") }
                try await Task.detached {
                    let files = try AgentFiles(workspace: exports.path), source = try AgentFiles(workspace: asset.deletingLastPathComponent().path)
                    try files.copyFile(asset, from: source, to: exports.appendingPathComponent(name), permissions: 0o600, expectedHash: hash, maximum: AgentOffice.maximum)
                }.value
            }
            var fixture: OfficeRecoveryFixture
            if stage == "seed" {
                let project = output.appendingPathComponent("public-office-project")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let files = try AgentFiles(workspace: project.path), originals = try AgentFiles(workspace: output.appendingPathComponent("originals").path)
                var paths: [String: String] = [:], hashes: [String: String] = [:]
                for key in keys {
                    let format = key == "missing" ? "docx" : key, name = key == "missing" ? "missing.docx" : "sample." + format, target = try files.resolve(name)
                    hashes[key] = try files.copyFile(originals.resolve("sample." + format), from: originals, to: target, permissions: key == "xlsx" ? 0o444 : 0o644, expectedTarget: "missing", maximum: AgentOffice.maximum); paths[key] = target.path
                }
                let id = tasks.create(title: "办公未保存内容恢复", workspace: project.path)
                tasks.update(id) { $0.artifacts = keys.compactMap { paths[$0] }; $0.draft = "保留办公任务输入 PUBLIC_OFFICE_417" }
                control.showAgentTask(id); control.show(tab: "chat")
                guard let window = control.workspaceSession?.id else { throw PetError("办公工作区恢复未启用") }
                var tabs: [String: String] = [:], views: [String: String] = [:]
                for key in keys {
                    let editor = try await tasks.offices.show(paths[key]!, taskID: id)
                    guard let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == id })?.tabs.first(where: { $0.root == "document:" + editor.file.path }) else { throw PetError("办公标签没有持久编号") }; tabs[key] = tab.id
                    try await edit(editor, from: "审阅人：待填写", to: first)
                    let one = try await snapshot(window: window, tab: tab.id, task: id, after: -1), revision = try AgentOfficeWindow.recoveryState(one.saved.value).editorRevision
                    try await edit(editor, from: first, to: second)
                    let two = try await snapshot(window: window, tab: tab.id, task: id, after: revision)
                    checks[key + "RepeatedDirtyEditAutomaticallyUpdatesFullExport"] = two.saved.value.asset?.hash != one.saved.value.asset?.hash
                    checks[key + "AutosaveRetainsOriginalSourceVersion"] = try AgentOfficeWindow.recoveryState(two.saved.value).openedHash == hashes[key]
                    checks[key + "PrivateExportAndMetadataUse600"] = try [two.asset!, store.directory.appendingPathComponent("workspace-recovery/" + window + "/pages/" + tab.id + ".json")].allSatisfy { (try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 }
                    let positioned = try await selectPosition(editor, key: key)
                    guard await flushWorkspaceWindows(), let positionedPage = try journal.loadPage(windowID: window, pageID: tab.id, taskID: id) else { throw PetError("办公位置未持久保存") }
                    let stored = try AgentOfficeWindow.recoveryState(positionedPage.saved.value)
                    views[key] = stored.view
                    let bodyRevision = try AgentOfficeWindow.recoveryState(two.saved.value).editorRevision
                    checks[key + "MovingSelectionKeepsExactBodyAssetAndRevision"] = positionedPage.saved.value.asset == two.saved.value.asset && stored.editorRevision == bodyRevision
                    checks[key + "ActualSelectionIsWrittenWithItsBody"] = try stored.view == viewText(positioned)
                    if key == "docx" {
                        let readback = await editor.workspaceReadback()
                        checks["wordSelectionReadThroughSDKMatchesKnownOriginalText"] = (readback["selectionInfo"] as? [String: Any])?["selectedText"] as? String == "恢复草稿二"
                        var legacy = stored; legacy.view = nil
                        var legacyPage = positionedPage.saved.value; legacyPage.state = try JSONEncoder().encode(legacy)
                        checks["oldOfficeStateWithoutViewStillDecodes"] = try AgentOfficeWindow.recoveryState(legacyPage).view == nil
                        for (name, change) in [("futureViewVersion", ["version": 2] as [String: Any]), ("unknownViewField", ["future": true]), ("wrongViewFormat", ["format": "xlsx"])] {
                            var altered = positioned; for (key, value) in change { altered[key] = value }
                            var future = stored; future.view = try viewText(altered)
                            var futurePage = positionedPage.saved.value; futurePage.state = try JSONEncoder().encode(future)
                            do { _ = try AgentOfficeWindow.recoveryState(futurePage); checks[name + "RejectedWithoutDowngradingDraft"] = false }
                            catch { checks[name + "RejectedWithoutDowngradingDraft"] = true }
                        }
                    }
                    try await copy(two, name: key == "missing" ? "missing.docx" : "sample." + key)
                    guard await flushWorkspaceWindows() else { throw PetError("办公恢复附件未完成") }
                    if key == "xlsx" {
                        let changes = tasks.task(id)?.changes.count
                        do { try await editor.saveDocument(); checks["readOnlyOriginalWithMatchingSignatureRejectsAtomicReplacement"] = false }
                        catch { checks["readOnlyOriginalWithMatchingSignatureRejectsAtomicReplacement"] = try files.fileHash(editor.file) == hashes[key] && files.entryMetadata(editor.file).permissions == 0o444 && tasks.task(id)?.changes.count == changes }
                        guard await flushWorkspaceWindows() else { throw PetError("只读拒绝后恢复记录未保存") }
                    }
                }
                fixture = .init(taskID: id, windowID: window, paths: paths, hashes: hashes, tabs: tabs, views: views)
                _ = try await tasks.offices.show(paths["docx"]!, taskID: id)
                checks["autosaveDoesNotWriteOriginalOfficeFiles"] = try keys.allSatisfy { try files.fileHash(URL(fileURLWithPath: paths[$0]!)) == hashes[$0] }
                checks["allFourActualEditorsCanHotExitFromTheirPrivateExports"] = await flushWorkspaceWindows() && control.workspaceSession?.preservedEditors.count == 4
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                fixture = try JSONDecoder().decode(OfficeRecoveryFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); guard await flushWorkspaceWindows() else { throw PetError("初始办公草稿没有恢复") }
                checks["sameTaskWindowIdentityRestores"] = control.workspaceSession?.id == fixture.windowID
                let coldLabels = control.taskWorkspace.checkState()["tabLabels"] as? [String] ?? []
                checks["coldOfficeNamesAndDirtyMarkersRestoreWithoutEditors"] = ["xlsx", "pptx", "missing"].allSatisfy { key in
                    coldLabels.contains("• " + URL(fileURLWithPath: fixture.paths[key]!).lastPathComponent) && control.taskWorkspace.recoveryController(taskID: fixture.taskID, root: .document(fixture.paths[key]!)) == nil
                }
                report["initialColdTabLabels"] = coldLabels
                if !interactive {
                    let legacy = try journal.loadPage(windowID: fixture.windowID, pageID: fixture.tabs["missing"]!, taskID: fixture.taskID)!
                    checks["oldOfficePageWithoutViewIsReadBeforeMaterialization"] = try AgentOfficeWindow.recoveryState(legacy.saved.value).view == nil
                }
                for key in keys {
                    control.taskWorkspace.checkSelect(.document(fixture.paths[key]!))
                    guard await flushWorkspaceWindows(), let editor = control.taskWorkspace.currentController as? AgentOfficeWindow else { throw PetError("办公草稿标签未恢复：" + key) }
                    checks[key + "CompleteOfficeDraftRestoresThroughActualEditor"] = try await contains(observed(editor), fixture.reviewer) && editor.dirty && editor.openedHash == fixture.hashes[key]
                    let loaded = try journal.loadPage(windowID: fixture.windowID, pageID: fixture.tabs[key]!, taskID: fixture.taskID)!
                    let actualView = try await editor.checkWorkspaceView()
                    report[key + "RestoredView"] = actualView
                    if interactive || key != "missing" {
                        guard let expected = fixture.views?[key] else { throw PetError("缺少办公位置验收基线") }
                        checks[key + "SelectionSheetSlideZoomAndScrollRestoreInActualEditor"] = try comparableView(viewText(actualView)) == comparableView(expected)
                    }
                    else { checks["oldOfficePageRetainsFullBodyAndGainsCurrentView"] = try AgentOfficeWindow.recoveryState(loaded.saved.value).view != nil }
                    if key == "docx" {
                        let readback = await editor.workspaceReadback()
                        checks["reopenedWordSelectionStillNamesExactText"] = (readback["selectionInfo"] as? [String: Any])?["selectedText"] as? String == "恢复草稿二"
                    }
                    try await copy(loaded, name: key == "missing" ? "missing.docx" : "sample." + key)
                    if !interactive, key != "pptx" {
                        let files = editor.files, before = try files.entryMetadata(editor.file), beforeHash = before.kind == "file" ? try files.fileHash(editor.file) : nil, changes = tasks.task(fixture.taskID)?.changes.count
                        do { try await editor.saveDocument(); checks[key + "ChangedReadonlyOrMissingOriginalIsNotOverwritten"] = false }
                        catch { checks[key + "ChangedReadonlyOrMissingOriginalIsNotOverwritten"] = try files.entryMetadata(editor.file).signature == before.signature && (beforeHash == nil || files.fileHash(editor.file) == beforeHash) && tasks.task(fixture.taskID)?.changes.count == changes }
                    }
                }
                if !interactive {
                    control.taskWorkspace.checkSelect(.document(fixture.paths["pptx"]!)); guard await flushWorkspaceWindows(), let saved = control.taskWorkspace.currentController as? AgentOfficeWindow else { throw PetError("恢复的幻灯片不可用") }
                    try await saved.saveDocument(); try await saved.verifyClean()
                    checks["recoveredPresentationActuallySavesAndClearsUnsavedState"] = try await contains(observed(saved), fixture.reviewer) && !saved.dirty && saved.openedHash == saved.files.fileHash(saved.file) && saved.openedHash != fixture.hashes["pptx"]
                    checks["recoveredSaveCreatesActualBeforeAndAfterCheckpoint"] = tasks.task(fixture.taskID)?.changes.contains { $0.path == saved.file.path && $0.beforeHash == fixture.hashes["pptx"] && $0.afterHash == saved.openedHash && $0.backup != nil } == true
                    guard await flushWorkspaceWindows(), let clean = try journal.loadPage(windowID: fixture.windowID, pageID: fixture.tabs["pptx"]!, taskID: fixture.taskID) else { throw PetError("保存后的恢复状态不可用") }
                    checks["savedDocumentClearsPrivateDirtyPointer"] = !clean.saved.value.dirty && clean.saved.value.asset == nil
                }
                control.taskWorkspace.checkSelect(.document(fixture.paths["docx"]!)); guard await flushWorkspaceWindows() else { throw PetError("返回 Word 草稿失败") }
                checks["originalComposerDraftRemainsExact"] = tasks.task(fixture.taskID)?.draft == "保留办公任务输入 PUBLIC_OFFICE_417"
            }
            checks["noModelRequest"] = requests == 0; checks["finalWorkspaceCheckpointCurrent"] = await flushWorkspaceWindows()
            report["stage"] = stage; report["fixture"] = fixtureURL.path
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(interactive ? "office-recovery-ui-ready.json" : "office-recovery-report.json"))
    }
}
