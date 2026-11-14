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
        checks["memorySettingsChecksDoNotRequestModels"] = modelAttempts == 0
        return checks
    }
}
