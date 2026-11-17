import AppKit

@MainActor extension AppDelegate {
    struct KnowledgeEditorFixture: Codable {
        var taskID: String, root: String, otherRoot: String, baseID: String, libraryWindow: String, wikiWindow: String
        var plan: AgentWikiPlanWindow.RecoveryState, library: AgentWorkspaceRecovery.KnowledgeLibrary, catalogHash: String, sourceHash: String, originalTaskIDs: Set<String>
    }
    func runKnowledgeEditorRecoveryCheck(_ output: URL, interactive: Bool = false) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        let stage = CommandLine.arguments.firstIndex(of: "--recovery-stage").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "seed"
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("知识编辑存储不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("知识编辑恢复验收不调用模型") }
            let fm = FileManager.default, fixtureURL = output.appendingPathComponent("knowledge-editor-fixture.json"), journal = AgentWorkspaceRecovery(profile: store.directory)
            func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
            func eventually(_ predicate: () -> Bool) async -> Bool { for _ in 0..<100 { if predicate() { return true }; await wait(0.03) }; return predicate() }
            func flush() async throws { guard await flushWorkspaceWindows() else { throw PetError("编辑草稿未保存到恢复记录") } }
            func other() throws -> ControlWindow { guard let window = taskControls.first(where: { $0.taskWindowNumber == 2 }) else { throw PetError("规划所属窗口未恢复") }; return window }
            func plan(_ owner: ControlWindow) throws -> AgentWikiPlanWindow { guard let plan = owner.knowledgePageHost.recoveryReaders.last?.recoveryWikiPlan else { throw PetError("规划草稿未恢复") }; return plan }
            func library() throws -> AgentKnowledgeLibraryWindow { guard let page = control.knowledgePageHost.currentController as? AgentKnowledgeLibraryWindow else { throw PetError("知识库命名页未恢复") }; return page }
            func planState(_ page: AgentWikiPlanWindow) throws -> AgentWikiPlanWindow.RecoveryState { guard let value = try page.captureWorkspaceRecovery() else { throw PetError("规划未保留") }; return value }
            func libraryState(_ page: AgentKnowledgeLibraryWindow) throws -> AgentWorkspaceRecovery.KnowledgeLibrary { guard let value = try page.captureWorkspaceRecovery() else { throw PetError("名称未保留") }; return value }
            let fixture: KnowledgeEditorFixture
            if stage == "seed" {
                guard !fm.fileExists(atPath: fixtureURL.path) else { throw PetError("此验收目录已经使用，保留原记录") }
                let root = output.appendingPathComponent("public-project"), otherRoot = output.appendingPathComponent("other-project")
                for url in [root, otherRoot] { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try Data("# PUBLIC_KNOWLEDGE_EDITOR_PROJECT 中文😀\n".utf8).write(to: url.appendingPathComponent("README.md")) }
                let files = try AgentFiles(workspace: root.path), source = AgentWikiPlan.initialYAML + (0..<160).map { "# 原始规划 \($0) 中文😀\n" }.joined()
                let sourceData = try AgentTextFormat(encoding: .utf16LE, bom: true).encode(source)
                try files.writeData(sourceData, to: files.literalURL(AgentWikiPlan.compatiblePath))
                let base = try tasks.knowledge.create(name: "PUBLIC_ORIGINAL_LIBRARY 中文", workspace: nil), catalogHash = try tasks.knowledge.document().1, taskIDs = Set(tasks.tasks.map(\.id))
                control.showKnowledgeLibrary()
                guard control.knowledgePageHost.show(root: "library", identity: "standalone", make: { _ in AgentKnowledgeLibraryWindow(store: tasks, taskID: nil) }) else { throw PetError("无任务知识库未进入正常知识承载区") }
                let library = try library()
                checks["tasklessLibraryUsesNoInventedTask"] = library.boundTaskID == nil && Set(tasks.tasks.map(\.id)) == taskIDs
                let name = String(repeating: "待恢复的名称中文😀", count: 18)
                try library.checkRecovery(action: "new", name: name, selection: NSRange(location: 3, length: 5)); try library.checkRecovery(action: "save")
                checks["invalidNameStaysEditableWithoutCatalogWrite"] = try library.hasPendingChanges && tasks.knowledge.document().1 == catalogHash
                let id = tasks.create(title: "公开 Wiki 规划恢复", workspace: root.path); tasks.update(id) { $0.draft = "PUBLIC_UNSENT_TASK_DRAFT 中文😀" }; try tasks.save(id)
                try tasks.organization.register(root.path, mode: .coding); openTaskWindow(id, from: control)
                let other = try other(); other.showAgentKnowledge()
                guard let catalog = other.knowledgePageHost.currentController as? AgentRepoWikiWindow else { throw PetError("项目知识目录未显示") }
                _ = await eventually { catalog.checkState["loading"] as? Bool == false }; try catalog.checkOpen(workspace: root.path, action: "wiki")
                guard let reader = other.knowledgePageHost.currentController as? AgentRecordWindow else { throw PetError("Wiki 记录页未显示") }; reader.checkOpenKnowledgePlan()
                let plan = try plan(other), draft = source + "\nrepowiki: [尚未完成 中文😀\n", range = (draft as NSString).range(of: "原始规划 95")
                try plan.checkRecovery(text: draft, selection: range, y: 260); try plan.checkRecovery(action: "save")
                checks["invalidYAMLDraftKeepsSourceVersionAndEncoding"] = try plan.hasUnsavedChanges && Data(contentsOf: files.literalURL(AgentWikiPlan.compatiblePath)) == sourceData && !fm.fileExists(atPath: root.appendingPathComponent(AgentWikiPlan.configurationPath).path)
                try await flush(); let savedPlan = try planState(plan), savedLibrary = try libraryState(library)
                guard let first = control.workspaceSession?.id, let second = other.workspaceSession?.id else { throw PetError("恢复窗口编号缺失") }
                fixture = .init(taskID: id, root: root.path, otherRoot: otherRoot.path, baseID: base.id, libraryWindow: first, wikiWindow: second, plan: savedPlan, library: savedLibrary, catalogHash: catalogHash, sourceHash: AgentFiles.hash(sourceData), originalTaskIDs: taskIDs)
                checks["journalStoresTasklessNameAndOwnedPlan"] = try journal.loadWindow(first)?.value.knowledge?.library == savedLibrary && journal.loadWindow(second)?.value.knowledge?.readers.contains(where: { (try? AgentRecordWindow.recoveryState($0).wikiPlan?.draft) == draft }) == true
                checks["quitProtectionRequiresSavedEditors"] = control.workspaceSession?.preservedEditors.contains(ObjectIdentifier(library)) == true && other.workspaceSession?.preservedEditors.contains(ObjectIdentifier(plan)) == true
                checks["planPositionIsNonzeroAndExactSelection"] = savedPlan.viewport?.selections.first?.range == range && (savedPlan.viewport?.y ?? 0) > 0
                checks["nameSelectionAndNoWorkspaceAreCaptured"] = try AgentKnowledgeLibraryWindow.RecoveryState.decode(savedLibrary.state).selection?.range == NSRange(location: 3, length: 5) && AgentKnowledgeLibraryWindow.RecoveryState.decode(savedLibrary.state).openedWorkspace == nil
                try encode(fixture).write(to: fixtureURL)
            } else {
                fixture = try JSONDecoder().decode(KnowledgeEditorFixture.self, from: Data(contentsOf: fixtureURL)); restoreAdditionalWorkspaceWindows(); try await flush()
                let other = try other(), sourceURL = URL(fileURLWithPath: fixture.root).appendingPathComponent(AgentWikiPlan.compatiblePath)
                if stage == "closed" {
                    checks["explicitlySavedAndClosedPlanDoesNotResurrect"] = try other.knowledgePageHost.recoveryReaders.isEmpty && journal.loadWindow(fixture.wikiWindow)?.value.knowledge == nil
                    checks["savedNameFormDoesNotResurrect"] = try journal.loadWindow(fixture.libraryWindow)?.value.knowledge == nil
                    let bases = try tasks.knowledge.document().0.bases
                    checks["explicitSavesRetainRealLibraryAndTask"] = bases.contains { $0.name == "PUBLIC_SAVED_USER_LIBRARY 中文😀" && $0.workspace == nil } && tasks.task(fixture.taskID)?.draft == "PUBLIC_UNSENT_TASK_DRAFT 中文😀"
                } else if stage == "observe", interactive {
                    let library = try library(), plan = try plan(other)
                    report["observedLibrary"] = try JSONSerialization.jsonObject(with: libraryState(library).state)
                    report["observedPlan"] = try JSONSerialization.jsonObject(with: encode(planState(plan)))
                    checks["observedEditorsKeepTheirOriginalWindows"] = control.workspaceSession?.id == fixture.libraryWindow && other.workspaceSession?.id == fixture.wikiWindow && plan.settingsHostWindow === other.window && library.boundTaskID == nil
                } else {
                    let library = try library(), plan = try plan(other), current = try planState(plan), name = try AgentKnowledgeLibraryWindow.RecoveryState.decode(libraryState(library).state), originalName = try AgentKnowledgeLibraryWindow.RecoveryState.decode(fixture.library.state)
                    checks["coldReopenRestoresCompleteInvalidYAMLAndSourceSnapshot"] = current.draft == fixture.plan.draft && current.source == fixture.plan.source && current.hash == fixture.plan.hash && current.encoding == fixture.plan.encoding && current.bom == fixture.plan.bom && current.dirty
                    checks["coldReopenRestoresOriginalPlanOwnerAndPosition"] = current.taskID == fixture.taskID && current.root == fixture.root && current.viewport == fixture.plan.viewport && plan.settingsHostWindow === other.window
                    checks["coldReopenRestoresTasklessNameAndScope"] = name.name == originalName.name && name.taskID == nil && name.openedWorkspace == nil && !name.project && library.hasPendingChanges && library.boundTaskID == nil
                    checks["coldReopenRestoresNameSelectionAndFocus"] = name.selection == originalName.selection && name.focus == originalName.focus
                    checks["reopeningDoesNotSaveProjectOrCatalog"] = try tasks.knowledge.document().1 == fixture.catalogHash && AgentFiles.hash(Data(contentsOf: sourceURL)) == fixture.sourceHash
                    checks["ownersAndWindowIdentitiesRemainSeparate"] = control.workspaceSession?.id == fixture.libraryWindow && other.workspaceSession?.id == fixture.wikiWindow && other.agentTaskID == fixture.taskID && Set(tasks.tasks.map(\.id)) == fixture.originalTaskIDs.union([fixture.taskID])
                    checks["tasklessNameAndOwnedPlanAreActuallyVisibleAfterReopen"] = library.isPageVisible && plan.isPageVisible
                    if stage == "reopen" && !interactive {
                        let originalData = try Data(contentsOf: sourceURL), validDraft = fixture.plan.source + "# PUBLIC_EXPLICIT_PLAN_SAVE 中文😀\n"
                        try plan.checkRecovery(text: validDraft)
                        let external = try AgentTextFormat(encoding: .utf16LE, bom: true).encode(fixture.plan.source + "# EXTERNAL_CHANGE\n"); try external.write(to: sourceURL, options: .atomic); try plan.checkRecovery(action: "save")
                        checks["externalSourceChangeCannotBeOverwritten"] = try Data(contentsOf: sourceURL) == external && plan.hasUnsavedChanges && planState(plan).draft == validDraft
                        try originalData.write(to: sourceURL, options: .atomic)
                        tasks.update(fixture.taskID) { $0.workspace = fixture.otherRoot }; try tasks.save(fixture.taskID)
                        let changedScope = try AgentWikiPlanWindow(store: tasks, taskID: fixture.taskID, restoring: fixture.plan); try changedScope.checkRecovery(action: "save")
                        checks["changedTaskScopeKeepsOriginalReadonlyDraft"] = changedScope.checkState["editable"] as? Bool == false && changedScope.hasUnsavedChanges && !fm.fileExists(atPath: URL(fileURLWithPath: fixture.otherRoot).appendingPathComponent(AgentWikiPlan.configurationPath).path)
                        changedScope.close(); tasks.update(fixture.taskID) { $0.workspace = fixture.root; $0.archived = true }; try tasks.save(fixture.taskID)
                        let readonly = try AgentWikiPlanWindow(store: tasks, taskID: fixture.taskID, restoring: fixture.plan); try readonly.checkRecovery(action: "save")
                        checks["readonlyOwnerDoesNotLoseOriginalDraft"] = try readonly.checkState["editable"] as? Bool == false && readonly.hasUnsavedChanges && Data(contentsOf: sourceURL) == originalData
                        readonly.close(); tasks.update(fixture.taskID) { $0.archived = false }; try tasks.save(fixture.taskID)
                        let projectName = AgentKnowledgeLibraryWindow(store: tasks, taskID: fixture.taskID); try projectName.checkRecovery(action: "new", name: "PUBLIC_ORIGINAL_PROJECT_LIBRARY", project: true)
                        let projectEnvelope = try libraryState(projectName); tasks.update(fixture.taskID) { $0.workspace = fixture.otherRoot }; try tasks.save(fixture.taskID)
                        let changedName = AgentKnowledgeLibraryWindow(store: tasks, taskID: fixture.taskID); try changedName.restoreWorkspaceRecovery(projectEnvelope); try changedName.checkRecovery(action: "save")
                        checks["projectNameCannotSilentlyMoveToNewWorkspace"] = try changedName.hasPendingChanges && tasks.knowledge.document().1 == fixture.catalogHash && AgentKnowledgeLibraryWindow.RecoveryState.decode(libraryState(changedName).state).destinationWorkspace == fixture.root
                        try changedName.checkRecovery(action: "cancel"); checks["explicitCancelClearsNameRecovery"] = try changedName.captureWorkspaceRecovery() == nil
                        projectName.close(); changedName.close(); tasks.update(fixture.taskID) { $0.workspace = fixture.root }; try tasks.save(fixture.taskID)
                        let rename = AgentKnowledgeLibraryWindow(store: tasks, taskID: nil); try rename.checkRecovery(action: "rename", name: "PUBLIC_STALE_RENAME", baseID: fixture.baseID); let renameEnvelope = try libraryState(rename)
                        _ = try tasks.knowledge.create(name: "PUBLIC_EXTERNAL_CATALOG_CHANGE", workspace: nil); let externalCatalog = try tasks.knowledge.document().1
                        let stale = AgentKnowledgeLibraryWindow(store: tasks, taskID: nil); try stale.restoreWorkspaceRecovery(renameEnvelope); try stale.checkRecovery(action: "save")
                        checks["restoredRenameUsesOriginalCatalogRevision"] = try stale.hasPendingChanges && tasks.knowledge.document().1 == externalCatalog && tasks.knowledge.document().0.bases.first(where: { $0.id == fixture.baseID })?.name == "PUBLIC_ORIGINAL_LIBRARY 中文"
                        try stale.checkRecovery(action: "cancel"); rename.close(); stale.close()
                        var future = try JSONSerialization.jsonObject(with: fixture.library.state) as! [String: Any]; future["futureScope"] = true
                        do { _ = try AgentKnowledgeLibraryWindow.RecoveryState.decode(JSONSerialization.data(withJSONObject: future)); checks["unknownNameStateRejectedWithoutMutation"] = false } catch { checks["unknownNameStateRejectedWithoutMutation"] = true }
                        var badPlan = fixture.plan; badPlan.taskID = UUID().uuidString
                        do { _ = try AgentWikiPlanWindow(store: tasks, taskID: fixture.taskID, restoring: badPlan); checks["planRejectsDifferentTaskIdentity"] = false } catch { checks["planRejectsDifferentTaskIdentity"] = true }
                        try plan.checkRecovery(action: "save"); let saved = try Data(contentsOf: URL(fileURLWithPath: fixture.root).appendingPathComponent(AgentWikiPlan.configurationPath))
                        checks["explicitPlanSavePreservesUTF16BOMAndCompatibleSource"] = try saved == AgentTextFormat(encoding: .utf16LE, bom: true).encode(validDraft) && Data(contentsOf: sourceURL) == originalData && !plan.hasUnsavedChanges
                        try library.checkRecovery(action: "save", name: "PUBLIC_SAVED_USER_LIBRARY 中文😀")
                        checks["explicitNameSaveCreatesOnlyRequestedUserLibrary"] = try !library.hasPendingChanges && tasks.knowledge.document().0.bases.filter { $0.name == "PUBLIC_SAVED_USER_LIBRARY 中文😀" && $0.workspace == nil }.count == 1
                        other.knowledgePageHost.checkBack(); other.knowledgePageHost.checkBack(); try await flush()
                        checks["savedPlanAndNameAreRemovedFromRecoveryJournal"] = try journal.loadWindow(fixture.libraryWindow)?.value.knowledge == nil && journal.loadWindow(fixture.wikiWindow)?.value.knowledge == nil
                        checks["originalTaskDraftAndModelHistoryRemainUntouched"] = tasks.task(fixture.taskID)?.draft == "PUBLIC_UNSENT_TASK_DRAFT 中文😀" && tasks.tasks.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty }
                    }
                }
            }
            checks["isolatedPublicExtensionHome"] = tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL
            checks["zeroModelRequests"] = requests == 0
            report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
            if interactive { control.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        report["checks"] = checks; report["stage"] = stage; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("knowledge-editor-" + stage + "-report.json"))
    }
}
