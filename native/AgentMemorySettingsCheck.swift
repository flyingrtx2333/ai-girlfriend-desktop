import AppKit

@MainActor extension AppDelegate {
    func checkMemorySettings(_ output: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let profile = output.appendingPathComponent("memory-settings-profile"), workspace = output.appendingPathComponent("memory-settings-project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("MEMORY_INSTRUCTIONS_REMAIN_PUBLIC\n".utf8).write(to: workspace.appendingPathComponent("AGENTS.md"))
        let tasks = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"), mcpKeychain: store.keychain, hookKeychain: store.keychain)
        let id = tasks.create(title: "记忆开关检查", workspace: workspace.path)
        let git = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: workspace.path, creating: true))
        _ = try await git.initialize()
        tasks.update(id) { $0.toolGroups = ["knowledge"]; $0.draft = "MEMORY_TASK_DRAFT_PUBLIC" }
        guard let task = tasks.task(id) else { throw PetError("缺少记忆检查任务") }
        for (scope, content) in [(AgentMemoryScope.global, "GLOBAL_MEMORY_PUBLIC_841"), (.project, "PROJECT_MEMORY_PUBLIC_692")] {
            let before = try AgentMemory.snapshot(scope, store: tasks, taskID: id)
            _ = try AgentMemory.save(scope, content: content, expectedHash: before.hash, store: tasks, taskID: id)
        }
        let service = AgentGeneralSettings(directory: profile), configuration = profile.appendingPathComponent("general.json")
        checks["memoryDefaultsPreserveExistingEnabledBehavior"] = service.error == nil && service.settings.globalMemory && service.settings.projectMemory
        let legacy = Data(#"{"version":1,"completionNotifications":"unfocused","approvalNotifications":true,"questionNotifications":true,"menuBarIcon":true}"#.utf8)
        try legacy.write(to: configuration); service.reload()
        checks["legacyGeneralSettingsDefaultBothMemoriesToEnabled"] = service.error == nil && service.settings.globalMemory && service.settings.projectMemory
        let runtime = AgentRuntime(store: tasks, keychain: store.keychain, preferences: { PetPreferences() }), tools = AgentTools(store: tasks, taskID: id)
        var modelAttempts = 0
        runtime.modelRequestCheck = { modelAttempts += 1; throw PetError("本机记忆检查不调用模型") }
        func context() throws -> String { try runtime.systemContext(task) }
        func call(_ name: String, _ scope: AgentMemoryScope) -> AgentToolCall {
            AgentToolCall(id: UUID().uuidString, name: name, arguments: "{\"scope\":\"" + scope.rawValue + "\",\"content\":\"MODEL_WRITE_REJECTED_PUBLIC\",\"expected_hash\":\"unused\"}")
        }
        func denied(_ call: AgentToolCall) async -> Bool {
            do { _ = try await tools.execute(call); return false } catch { return error.localizedDescription.contains("已关闭") }
        }
        func save(global: Bool, project: Bool) throws {
            var value = service.settings; value.globalMemory = global; value.projectMemory = project; try service.save(value)
        }
        checks["enabledMemoriesEnterActualRuntimeContext"] = try context().contains("GLOBAL_MEMORY_PUBLIC_841") && context().contains("PROJECT_MEMORY_PUBLIC_692")
        try save(global: false, project: true)
        checks["globalOffKeepsProjectMemoryInActualContext"] = try !context().contains("GLOBAL_MEMORY_PUBLIC_841") && context().contains("PROJECT_MEMORY_PUBLIC_692")
        checks["globalOffBlocksActualReadMemoryTool"] = await denied(call("read_memory", .global))
        checks["globalOffBlocksActualWriteMemoryTool"] = await denied(call("write_memory", .global))
        do { _ = try tools.approvalReason(for: call("write_memory", .global)); checks["globalOffRejectsWriteBeforeApproval"] = false }
        catch { checks["globalOffRejectsWriteBeforeApproval"] = error.localizedDescription.contains("已关闭") }
        checks["globalOffDoesNotBlockProjectMemoryTool"] = try await tools.execute(call("read_memory", .project)).text.contains("PROJECT_MEMORY_PUBLIC_692")
        let noWorkspace = tasks.create(title: "无工作区记忆检查")
        tasks.update(noWorkspace) { $0.mode = .ask }
        checks["globalOffAppliesToAskWithoutWorkspace"] = try tasks.task(noWorkspace).map { try !runtime.systemContext($0).contains("GLOBAL_MEMORY_PUBLIC_841") } == true
        try save(global: true, project: false)
        checks["projectOffKeepsGlobalMemoryInActualContext"] = try context().contains("GLOBAL_MEMORY_PUBLIC_841") && !context().contains("PROJECT_MEMORY_PUBLIC_692")
        checks["projectOffBlocksActualReadMemoryTool"] = await denied(call("read_memory", .project))
        checks["projectOffBlocksActualWriteMemoryTool"] = await denied(call("write_memory", .project))
        try save(global: false, project: false)
        let disabled = try context()
        checks["bothOffKeepInstructionsAndOmitBothMemories"] = !disabled.contains("GLOBAL_MEMORY_PUBLIC_841") && !disabled.contains("PROJECT_MEMORY_PUBLIC_692") && disabled.contains("MEMORY_INSTRUCTIONS_REMAIN_PUBLIC")
        let beforeManual = try AgentMemory.snapshot(.global, store: tasks, taskID: id)
        let manual = try AgentMemory.save(.global, content: beforeManual.content + "\nMANUAL_MEMORY_EDIT_PUBLIC", expectedHash: beforeManual.hash, store: tasks, taskID: id)
        checks["disabledMemoryRemainsManuallyEditable"] = manual.content.contains("MANUAL_MEMORY_EDIT_PUBLIC")
        checks["manualEditDoesNotReenableAgentMemory"] = try !context().contains("MANUAL_MEMORY_EDIT_PUBLIC") && AgentMemory.agentSettings(store: tasks).globalMemory == false
        checks["disabledPreferencesSurviveReload"] = !AgentGeneralSettings(directory: profile).settings.globalMemory && !AgentGeneralSettings(directory: profile).settings.projectMemory
        try save(global: true, project: true)
        checks["reenableRestoresCurrentManualContentAndTools"] = try context().contains("MANUAL_MEMORY_EDIT_PUBLIC") && tools.approvalReason(for: call("write_memory", .global)) != nil
        let saved = try Data(contentsOf: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: configuration.path)
        do { try save(global: false, project: true); checks["readOnlyPreferenceDoesNotChangeMemoryPolicy"] = false }
        catch { checks["readOnlyPreferenceDoesNotChangeMemoryPolicy"] = try Data(contentsOf: configuration) == saved && context().contains("GLOBAL_MEMORY_PUBLIC_841") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        var malformed = try JSONSerialization.jsonObject(with: saved) as! [String: Any]; malformed["globalMemory"] = "false"
        try JSONSerialization.data(withJSONObject: malformed).write(to: configuration)
        do { _ = try context(); checks["invalidMemoryPreferenceFailsClosed"] = false }
        catch { checks["invalidMemoryPreferenceFailsClosed"] = error.localizedDescription.contains("常规配置") }
        try saved.write(to: configuration); service.reload()
        let page = AgentMemorySettingsPage(store: tasks, taskID: id, workspace: workspace.path, service: service)
        func find(_ view: NSView, id: String) -> NSView? { if view.identifier?.rawValue == id { return view }; return view.subviews.lazy.compactMap { find($0, id: id) }.first }
        guard let root = page.pageContentView else { throw PetError("缺少记忆设置页") }
        checks["memoryPageUsesGroupedBehaviorAndSourceCards"] = find(root, id: "settings-card-memory-behavior") != nil && find(root, id: "settings-card-memory-content") != nil && find(root, id: "settings-card-memory-instructions") != nil
        var child: AgentSettingsPageController?
        page.onSettingsPush = { child = $0 }
        (find(root, id: "memory-manage-project") as? NSButton)?.performClick(nil)
        func containsText(_ view: NSView, _ text: String) -> Bool { (view as? NSTextView)?.string.contains(text) == true || view.subviews.contains { containsText($0, text) } }
        checks["memoryCardOpensExistingEditorAtRequestedScope"] = child is AgentRecordWindow && child?.pageContentView.map { containsText($0, "PROJECT_MEMORY_PUBLIC_692") } == true
        child?.window?.close(); page.window?.close()
        checks["memoryPreferencesPreserveProjectSourceAndTaskDraft"] = try AgentMemory.snapshot(.project, store: tasks, taskID: id).content == "PROJECT_MEMORY_PUBLIC_692" && tasks.task(id)?.draft == "MEMORY_TASK_DRAFT_PUBLIC"
        let second = output.appendingPathComponent("memory-second-project"), secondary = output.appendingPathComponent("memory-secondary-source"), unavailable = output.appendingPathComponent("memory-unavailable-project")
        for url in [second, secondary, unavailable] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let peerID = tasks.create(title: "其他项目原任务", workspace: second.path)
        tasks.update(peerID) { $0.draft = "PEER_DRAFT_PUBLIC_385" }
        let duplicateID = tasks.create(title: "同目录已归档任务", workspace: second.path)
        tasks.update(duplicateID) { $0.archived = true }
        let multiID = tasks.create(title: "多源文件夹任务", workspace: second.path)
        tasks.update(multiID) { $0.workspaceScope = AgentWorkspaceScope(group: output.appendingPathComponent("memory-source-group").path, folders: [second.path, secondary.path], primary: second.path) }
        let missingID = tasks.create(title: "暂不可用项目", workspace: unavailable.path)
        try FileManager.default.moveItem(at: unavailable, to: unavailable.appendingPathExtension("offline"))
        let peerInitial = try AgentMemory.snapshot(.project, store: tasks, taskID: peerID)
        _ = try AgentMemory.save(.project, content: "PEER_MEMORY_PUBLIC_347", expectedHash: peerInitial.hash, store: tasks, taskID: peerID)
        let secondaryInitial = try AgentMemory.snapshot(.project, store: tasks, taskID: multiID, workspace: secondary.path)
        _ = try AgentMemory.save(.project, content: "SECONDARY_MEMORY_PUBLIC_529", expectedHash: secondaryInitial.hash, store: tasks, taskID: multiID, workspace: secondary.path)
        let selection = tasks.selectedID, originalTasks = [id, peerID, duplicateID, multiID, missingID, noWorkspace].compactMap { tasks.task($0) }
        let sources = AgentMemory.projects(store: tasks, preferredTaskID: noWorkspace)
        checks["memoryProjectInventoryDeduplicatesSharedDirectories"] = sources.filter { $0.workspace == second.path }.count == 1
        checks["memoryProjectInventoryIncludesSecondarySourceFolders"] = sources.contains { $0.workspace == secondary.path && $0.taskID == multiID }
        checks["memoryProjectInventoryRetainsUnavailableDirectories"] = sources.contains { $0.workspace == unavailable.path && $0.taskID == missingID }
        checks["memoryProjectInventoryPrefersCurrentTaskAsOwner"] = AgentMemory.projects(store: tasks, preferredTaskID: peerID).first { $0.workspace == second.path }?.taskID == peerID
        checks["memoryProjectInventoryKeepsUnrelatedFoldersOutsideScope"] = !sources.contains { $0.workspace == output.path }
        let projectPage = AgentMemorySettingsPage(store: tasks, taskID: noWorkspace, workspace: nil, service: service)
        guard let projectRoot = projectPage.pageContentView else { throw PetError("缺少跨项目记忆页") }
        let buttonID = { (path: String) in "memory-project-" + AgentFiles.hash(Data(path.utf8)) }
        checks["noWorkspaceMemoryPageListsExistingProjects"] = find(projectRoot, id: "settings-card-memory-projects") != nil && (find(projectRoot, id: buttonID(second.path)) as? NSButton)?.isEnabled == true
        checks["unavailableMemoryProjectDoesNotBlockOtherProjects"] = (find(projectRoot, id: buttonID(unavailable.path)) as? NSButton)?.isEnabled == false && (find(projectRoot, id: buttonID(secondary.path)) as? NSButton)?.isEnabled == true
        projectPage.window?.close()
        let hostedPage = AgentMemorySettingsPage(store: tasks, taskID: multiID, workspace: second.path, service: service)
        let projectHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        projectHost.isReleasedWhenClosed = false
        let projectPane = AgentSettingsPageHost(); projectHost.contentView = projectPane; projectHost.orderFront(nil)
        guard projectPane.show(category: "memory", identity: multiID, scope: "项目 · " + second.lastPathComponent, make: { _ in hostedPage }) else { throw PetError("缺少实际承载的项目记忆页") }
        projectPane.setSourceFolders([second.path, secondary.path], selected: second.path, primary: second.path, onSelect: { _ in false })
        guard let hostedRoot = hostedPage.pageContentView else { throw PetError("跨项目列表未承载") }
        (find(hostedRoot, id: buttonID(secondary.path)) as? NSButton)?.performClick(nil)
        let projectChild = projectPane.currentController
        checks["otherProjectMemoryOpensOriginalScopedEditor"] = projectChild is AgentRecordWindow && projectChild?.pageContentView.map { containsText($0, "SECONDARY_MEMORY_PUBLIC_529") } == true
        projectPane.layoutSubtreeIfNeeded()
        let editing = find(projectPane, id: "settings-editing-context") as? NSTextField, sourcePicker = find(projectPane, id: "settings-source-folder") as? NSPopUpButton
        checks["otherProjectMemoryNamesItsVisibleEditingContext"] = editing?.stringValue == "项目 · " + secondary.lastPathComponent && editing?.toolTip == secondary.path && editing?.isHiddenOrHasHiddenAncestor == false && editing?.window === projectHost && projectHost.isVisible && (editing?.visibleRect.width ?? 0) > 100
        checks["otherProjectMemoryHidesTheOriginalSourcePicker"] = sourcePicker?.isHiddenOrHasHiddenAncestor == true
        projectChild?.close(); projectPane.layoutSubtreeIfNeeded()
        checks["returnFromOtherProjectRestoresOriginalSourcePicker"] = projectPane.currentController === hostedPage && sourcePicker?.isHiddenOrHasHiddenAncestor == false && sourcePicker?.selectedItem?.representedObject as? String == second.path && editing?.stringValue == "项目 · " + second.lastPathComponent
        projectPane.finish(); projectHost.close()
        do { _ = try AgentMemory.snapshot(.project, store: tasks, taskID: peerID, workspace: secondary.path); checks["crossProjectInventoryDoesNotExpandOwnerScope"] = false }
        catch { checks["crossProjectInventoryDoesNotExpandOwnerScope"] = error.localizedDescription.contains("不属于当前任务") }
        let reloaded = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"), mcpKeychain: store.keychain, hookKeychain: store.keychain)
        checks["memoryProjectInventorySurvivesStoreReload"] = AgentMemory.projects(store: reloaded, preferredTaskID: noWorkspace) == sources
        checks["memoryProjectManagementDoesNotSelectAnotherTask"] = tasks.selectedID == selection
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        checks["memoryProjectManagementPreservesAllOriginalTaskRecords"] = try originalTasks.allSatisfy { task in try encoder.encode(tasks.task(task.id)) == encoder.encode(Optional(task)) }
        checks["memoryProjectManagementPreservesEachSourceMemory"] = try AgentMemory.snapshot(.project, store: tasks, taskID: peerID).content == "PEER_MEMORY_PUBLIC_347" && AgentMemory.snapshot(.project, store: tasks, taskID: multiID, workspace: secondary.path).content == "SECONDARY_MEMORY_PUBLIC_529" && AgentMemory.snapshot(.project, store: tasks, taskID: id).content == "PROJECT_MEMORY_PUBLIC_692"
        checks["memorySettingsChecksDoNotRequestModels"] = modelAttempts == 0
        return checks
    }
}
