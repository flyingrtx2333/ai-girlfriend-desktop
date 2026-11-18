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
        func buttonID(_ path: String) -> String { "memory-project-" + AgentFiles.hash(Data(path.utf8)) }
        guard let root = page.pageContentView else { throw PetError("缺少记忆设置页") }
        checks["memoryPageUsesGroupedBehaviorAndSourceCards"] = find(root, id: "settings-card-memory-behavior") != nil && find(root, id: "settings-card-memory-content") != nil && find(root, id: "settings-card-memory-instructions") != nil
        var child: AgentSettingsPageController?
        page.onSettingsPush = { child = $0 }
        (find(root, id: buttonID(workspace.path)) as? NSButton)?.performClick(nil)
        func containsText(_ view: NSView, _ text: String) -> Bool { (view as? NSTextView)?.string.contains(text) == true || view.subviews.contains { containsText($0, text) } }
        checks["memoryCardOpensExistingEditorAtRequestedScope"] = child is AgentRecordWindow && child?.pageContentView.map { containsText($0, "PROJECT_MEMORY_PUBLIC_692") } == true
        child?.window?.close(); page.window?.close()
        checks["memoryPreferencesPreserveProjectSourceAndTaskDraft"] = try AgentMemory.snapshot(.project, store: tasks, taskID: id).content == "PROJECT_MEMORY_PUBLIC_692" && tasks.task(id)?.draft == "MEMORY_TASK_DRAFT_PUBLIC"
        for scope in [AgentMemoryScope.global, .project, .instructions, .userInstructions, .localInstructions] {
            var original = try AgentMemory.snapshot(scope, store: tasks, taskID: id)
            if original.content.isEmpty { original = try AgentMemory.save(scope, content: "READONLY_MEMORY_PUBLIC_" + scope.rawValue, expectedHash: original.hash, store: tasks, taskID: id) }
            let url = scope == .global ? tasks.directory.appendingPathComponent("memory.md") : scope == .userInstructions ? profile.appendingPathComponent("AGENTS.md") : workspace.appendingPathComponent(scope == .project ? ".bluefatfish/memory.md" : scope == .instructions ? "AGENTS.md" : "AGENTS.local.md")
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
            let backups = tasks.directory.appendingPathComponent("memory-backups"), beforeBackups = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
            do { _ = try AgentMemory.save(scope, content: "READONLY_OVERWRITE_REJECTED_PUBLIC", expectedHash: original.hash, store: tasks, taskID: id); checks["readOnlyMemoryRejectsSave-" + scope.rawValue] = false }
            catch { checks["readOnlyMemoryRejectsSave-" + scope.rawValue] = try error.localizedDescription.contains("只读") && AgentMemory.snapshot(scope, store: tasks, taskID: id).hash == original.hash && FileManager.default.contentsOfDirectory(atPath: backups.path).sorted() == beforeBackups && (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o444 }
            if scope == .global {
                let arguments = try JSONSerialization.data(withJSONObject: ["scope": "global", "content": "TOOL_READONLY_OVERWRITE_REJECTED_PUBLIC", "expected_hash": original.hash])
                do { _ = try await tools.execute(AgentToolCall(id: UUID().uuidString, name: "write_memory", arguments: String(decoding: arguments, as: UTF8.self))); checks["actualWriteMemoryToolRejectsReadOnlyTarget"] = false }
                catch { checks["actualWriteMemoryToolRejectsReadOnlyTarget"] = try error.localizedDescription.contains("只读") && AgentMemory.snapshot(.global, store: tasks, taskID: id).hash == original.hash }
            }
        }
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
        let standalone = output.appendingPathComponent("memory-standalone-project"), standaloneSource = output.appendingPathComponent("memory-standalone-source")
        for folder in [standalone, standaloneSource] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try tasks.organization.register(standalone.path, mode: .coding)
        try tasks.organization.register(standaloneSource.path, mode: .general)
        guard let standaloneEntry = tasks.organization.entry(standalone.path, mode: .coding, tasks: []) else { throw PetError("未登记无任务项目") }
        try tasks.organization.editWorkspace(standaloneEntry, name: "云端服务", icon: .globe, color: .blue, folders: [standalone.path, standaloneSource.path], primary: standalone.path, tasks: [])
        let peerInitial = try AgentMemory.snapshot(.project, store: tasks, taskID: peerID)
        _ = try AgentMemory.save(.project, content: "PEER_MEMORY_PUBLIC_347", expectedHash: peerInitial.hash, store: tasks, taskID: peerID)
        let secondaryInitial = try AgentMemory.snapshot(.project, store: tasks, taskID: multiID, workspace: secondary.path)
        _ = try AgentMemory.save(.project, content: "SECONDARY_MEMORY_PUBLIC_529", expectedHash: secondaryInitial.hash, store: tasks, taskID: multiID, workspace: secondary.path)
        let selection = tasks.selectedID, originalTasks = [id, peerID, duplicateID, multiID, missingID, noWorkspace].compactMap { tasks.task($0) }
        let sources = AgentMemory.projects(store: tasks, preferredTaskID: noWorkspace)
        checks["memoryProjectInventoryDeduplicatesSharedDirectories"] = sources.filter { $0.workspace == second.path }.count == 1
        checks["memoryProjectInventoryIncludesSecondarySourceFolders"] = sources.contains { $0.workspace == secondary.path && $0.taskID == multiID }
        checks["memoryProjectInventoryRetainsUnavailableDirectories"] = sources.contains { $0.workspace == unavailable.path && $0.taskID == missingID }
        checks["registeredProjectsWithoutTasksIncludeAllSourceFoldersAcrossModes"] = sources.filter { $0.workspace == standaloneSource.path }.count == 1 && sources.contains { $0.workspace == standaloneSource.path && $0.taskID == nil } && sources.contains { $0.workspace == standalone.path && $0.taskID == nil && $0.title == "云端服务" }
        checks["memoryProjectInventoryPrefersCurrentTaskAsOwner"] = AgentMemory.projects(store: tasks, preferredTaskID: peerID).first { $0.workspace == second.path }?.taskID == peerID
        checks["memoryProjectInventoryKeepsUnrelatedFoldersOutsideScope"] = !sources.contains { $0.workspace == output.path }
        let projectPage = AgentMemorySettingsPage(store: tasks, taskID: noWorkspace, workspace: nil, service: service)
        guard let projectRoot = projectPage.pageContentView else { throw PetError("缺少跨项目记忆页") }
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
        let initial = try AgentMemory.snapshot(.project, store: tasks, taskID: nil, workspace: standalone.path)
        let standaloneFile = standalone.appendingPathComponent(".bluefatfish/memory.md")
        _ = try AgentMemory.save(.project, content: "STANDALONE_MEMORY_PUBLIC_493", expectedHash: initial.hash, store: tasks, taskID: nil, workspace: standalone.path)
        let createdMemory = try String(contentsOf: standaloneFile, encoding: .utf8)
        checks["registeredProjectCreatesItsOwnMemoryFile"] = initial.content.isEmpty && createdMemory == "STANDALONE_MEMORY_PUBLIC_493"
        do { _ = try AgentMemory.save(.project, content: "STALE_PUBLIC", expectedHash: initial.hash, store: tasks, taskID: nil, workspace: standalone.path); checks["registeredProjectRejectsAnOutdatedDraft"] = false }
        catch { checks["registeredProjectRejectsAnOutdatedDraft"] = error.localizedDescription.contains("已更改") }
        do { _ = try AgentMemory.snapshot(.project, store: tasks, taskID: nil, workspace: output.path); checks["unregisteredFolderCannotOpenTasklessMemory"] = false }
        catch { checks["unregisteredFolderCannotOpenTasklessMemory"] = error.localizedDescription.contains("登记范围") }
        let moved = standalone.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: standalone, to: moved)
        try FileManager.default.createSymbolicLink(at: standalone, withDestinationURL: second)
        do { _ = try AgentMemory.snapshot(.project, store: tasks, taskID: nil, workspace: standalone.path); checks["registeredMemoryRejectsRedirectedRoot"] = false }
        catch { checks["registeredMemoryRejectsRedirectedRoot"] = error.localizedDescription.contains("位置已变化") }
        let whileRedirected = AgentMemory.projects(store: tasks, preferredTaskID: nil)
        checks["registeredProjectRemainsListedWhenItsPathIsRedirected"] = whileRedirected.contains { $0.workspace == standalone.path && $0.taskID == nil } && whileRedirected.contains { $0.workspace == second.path }
        try FileManager.default.removeItem(at: standalone)
        try FileManager.default.moveItem(at: moved, to: standalone)
        let detachedPage = AgentMemorySettingsPage(store: tasks, taskID: nil, workspace: nil, service: service)
        guard let detachedRoot = detachedPage.pageContentView, let search = find(detachedRoot, id: "memory-project-search") as? NSSearchField,
              let action = search.action else { throw PetError("缺少独立项目搜索") }
        search.stringValue = "云端服务"; search.sendAction(action, to: search.target)
        checks["memoryOverviewSearchFiltersByRegisteredName"] = find(detachedRoot, id: buttonID(second.path)) == nil && (find(detachedRoot, id: buttonID(standalone.path)) as? NSButton)?.isEnabled == true
        search.stringValue = "STANDALONE-SOURCE"; search.sendAction(action, to: search.target)
        checks["memoryOverviewSearchFiltersByPath"] = find(detachedRoot, id: buttonID(standalone.path)) == nil && (find(detachedRoot, id: buttonID(standaloneSource.path)) as? NSButton)?.isEnabled == true
        search.stringValue = "NO_PROJECT_PUBLIC"; search.sendAction(action, to: search.target)
        checks["memoryOverviewSearchShowsEmptyResult"] = (find(detachedRoot, id: "memory-project-empty") as? NSTextField)?.stringValue == "未找到项目"
        search.stringValue = ""; search.sendAction(action, to: search.target)
        var detachedEditor: AgentSettingsPageController?
        detachedPage.onSettingsPush = { detachedEditor = $0 }
        (find(detachedRoot, id: buttonID(standalone.path)) as? NSButton)?.performClick(nil)
        checks["registeredProjectEditorOpensWithoutAnyTaskContext"] = detachedEditor is AgentRecordWindow && detachedEditor?.settingsContext?.location == standalone.path && detachedEditor?.pageContentView.map { containsText($0, "STANDALONE_MEMORY_PUBLIC_493") } == true
        detachedEditor?.window?.close(); detachedPage.window?.close()
        do { _ = try AgentMemory.snapshot(.project, store: tasks, taskID: peerID, workspace: secondary.path); checks["crossProjectInventoryDoesNotExpandOwnerScope"] = false }
        catch { checks["crossProjectInventoryDoesNotExpandOwnerScope"] = error.localizedDescription.contains("不属于当前任务") }
        let reloaded = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"), mcpKeychain: store.keychain, hookKeychain: store.keychain)
        checks["memoryProjectInventorySurvivesStoreReload"] = AgentMemory.projects(store: reloaded, preferredTaskID: noWorkspace) == sources
        checks["memoryProjectManagementDoesNotSelectAnotherTask"] = tasks.selectedID == selection
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        checks["memoryProjectManagementPreservesAllOriginalTaskRecords"] = try originalTasks.allSatisfy { task in try encoder.encode(tasks.task(task.id)) == encoder.encode(Optional(task)) }
        checks["memoryProjectManagementPreservesEachSourceMemory"] = try AgentMemory.snapshot(.project, store: tasks, taskID: peerID).content == "PEER_MEMORY_PUBLIC_347" && AgentMemory.snapshot(.project, store: tasks, taskID: multiID, workspace: secondary.path).content == "SECONDARY_MEMORY_PUBLIC_529" && AgentMemory.snapshot(.project, store: tasks, taskID: id).content == "PROJECT_MEMORY_PUBLIC_692"
        checks["memorySettingsChecksDoNotRequestModels"] = modelAttempts == 0
        let topics = try await checkMemoryTopics(output)
        checks.merge(topics) { _, later in later }
        return checks
    }

    private func checkMemoryTopics(_ output: URL) async throws -> [String: Bool] {
        let root = output.appendingPathComponent("memory-topic-fixture")
        let primary = root.appendingPathComponent("primary"), secondary = root.appendingPathComponent("secondary"), other = root.appendingPathComponent("other")
        for directory in [primary, secondary, other] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let profile = root.appendingPathComponent("profile")
        let tasks = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"), mcpKeychain: store.keychain, hookKeychain: store.keychain)
        let scope = AgentWorkspaceScope(group: primary.path, folders: [primary.path, secondary.path], primary: primary.path)
        let id = tasks.create(title: "主题来源验收", workspaceScope: scope)
        let unlinked = tasks.create(title: "无工作区", mode: .ask)
        let unrelated = tasks.create(title: "独立项目", workspace: other.path)
        for folder in [primary, secondary] {
            let git = try AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: folder.path, creating: true), workspace: folder.path)
            _ = try await git.initialize()
        }
        guard let task = tasks.task(id), let ask = tasks.task(unlinked) else { throw PetError("缺少记忆主题测试任务") }
        let runtime = AgentRuntime(store: tasks, keychain: store.keychain, preferences: { PetPreferences() })
        var modelRequests = 0, checks: [String: Bool] = [:]
        runtime.modelRequestCheck = { modelRequests += 1; throw PetError("主题验收禁止请求模型") }
        let tools = AgentTools(store: tasks, taskID: id), askTools = AgentTools(store: tasks, taskID: unlinked)
        func call(_ name: String, _ arguments: [String: Any]) throws -> AgentToolCall {
            let data = try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)
            return AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: data, as: UTF8.self))
        }
        func json(_ result: AgentToolResult) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any] else { throw PetError("无效的记忆工具结果") }
            return object
        }
        let old = try AgentMemory.snapshot(.project, store: tasks, taskID: id)
        let anchor = try AgentMemory.save(.project, content: "PUBLIC_DEFAULT_MEMORY", expectedHash: old.hash, store: tasks, taskID: id)
        let theme = try AgentMemory.createTopic("发布流程", scope: .project, store: tasks, taskID: id, workspace: secondary.path)
        let global = try AgentMemory.createTopic("沟通偏好.md", scope: .global, store: tasks, taskID: nil, workspace: nil)
        let opened = try AgentMemory.snapshot(.project, store: tasks, taskID: id, workspace: secondary.path, topic: theme.topic)
        let file = try AgentMemory.revealURL(theme, store: tasks, taskID: id, workspace: secondary.path)
        checks["memoryTopicCreationUsesNamedMarkdownFile"] = theme.topic == "发布流程.md" && opened.exists && opened.content.isEmpty && file.path == secondary.appendingPathComponent(".bluefatfish/memory/发布流程.md").path
        let globalFile = try AgentMemory.revealURL(global, store: tasks, taskID: nil, workspace: nil)
        checks["globalMemoryTopicIsPrivate"] = (try FileManager.default.attributesOfItem(atPath: globalFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
        checks["projectMemoryTopicRetainsProjectFilePermissions"] = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o644
        do { _ = try AgentMemory.createTopic("发布流程.md", scope: .project, store: tasks, taskID: id, workspace: secondary.path); checks["memoryTopicCreateRejectsDuplicate"] = false }
        catch { checks["memoryTopicCreateRejectsDuplicate"] = error.localizedDescription.contains("同名") }
        let absent = try AgentMemory.snapshot(.global, store: tasks, taskID: nil, topic: "并发.md")
        _ = try AgentMemory.createTopic("并发", scope: .global, store: tasks, taskID: nil, workspace: nil)
        do { _ = try AgentMemory.save(.global, content: "不得覆盖", expectedHash: absent.hash, store: tasks, taskID: nil, topic: "并发.md", expectedExists: absent.exists); checks["memoryTopicDoesNotMistakeNewEmptyFileForMissingFile"] = false }
        catch { checks["memoryTopicDoesNotMistakeNewEmptyFileForMissingFile"] = error.localizedDescription.contains("已更改") }
        let args: [String: Any] = ["scope": "project", "workspace": secondary.path, "topic": theme.topic!]
        let read = try json(await tools.execute(call("read_memory", args)))
        checks["memoryToolReadsExactTopicFromSecondaryFolder"] = read["sha256"] as? String == opened.hash && read["workspace"] as? String == secondary.path && read["topic"] as? String == theme.topic && read["exists"] as? Bool == true
        let edit = try call("write_memory", args.merging(["expected_exists": true, "expected_hash": opened.hash, "content": "PUBLIC_SECONDARY_RELEASE_TOPIC"]) { $1 })
        let reason = try tools.approvalReason(for: edit)
        checks["memoryTopicApprovalNamesExactTarget"] = reason?.contains(file.path) == true
        let changed = try json(await tools.execute(edit))
        checks["approvedTopicWriteSavesOnlyItsTarget"] = try changed["content"] as? String == "PUBLIC_SECONDARY_RELEASE_TOPIC" && AgentMemory.snapshot(.project, store: tasks, taskID: id).hash == anchor.hash
        do { _ = try await tools.execute(edit); checks["memoryTopicWriteRejectsStaleHash"] = false }
        catch { checks["memoryTopicWriteRejectsStaleHash"] = error.localizedDescription.contains("已更改") }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let currentHash = try AgentMemory.snapshot(.project, store: tasks, taskID: id, workspace: secondary.path, topic: theme.topic).hash
        do { _ = try AgentMemory.save(.project, content: "REJECT", expectedHash: currentHash, store: tasks, taskID: id, workspace: secondary.path, topic: theme.topic); checks["memoryTopicReadOnlyRejectsSave"] = false }
        catch { checks["memoryTopicReadOnlyRejectsSave"] = error.localizedDescription.contains("只读") }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let metadata = try AgentMemory.catalog(.project, store: tasks, taskID: id, workspace: secondary.path)
        checks["memoryTopicCatalogCountsFilesAndReadsUpdateTime"] = metadata.count == 1 && metadata.topics == [theme.topic!] && metadata.latest != nil
        let request = try call("read_memory", ["scope": "project", "workspace": secondary.path])
        let list = try json(await tools.execute(request))
        checks["memoryToolPublishesTopicCatalog"] = list["topics"] as? [String] == [theme.topic!] && list["topic_count"] as? Int == 1
        let globalRead = try json(await askTools.execute(call("read_memory", ["scope": "global", "topic": global.topic!])))
        checks["memoryGlobalTopicWorksInAskWithoutWorkspace"] = globalRead["exists"] as? Bool == true && globalRead["topic"] as? String == global.topic
        let context = try runtime.systemContext(task), askContext = try runtime.systemContext(ask)
        checks["memoryRuntimeAdvertisesScopedTopicsAndKeepsMainMemory"] = context.contains("发布流程.md") && context.contains("沟通偏好.md") && context.contains("PUBLIC_DEFAULT_MEMORY") && !context.contains("PUBLIC_SECONDARY_RELEASE_TOPIC")
        checks["memoryRuntimeDoesNotExposeProjectTopicsWithoutWorkspace"] = askContext.contains("沟通偏好.md") && !askContext.contains("发布流程.md")
        do { _ = try await AgentTools(store: tasks, taskID: unrelated).execute(request); checks["memoryToolRejectsAnotherProjectsSource"] = false }
        catch { checks["memoryToolRejectsAnotherProjectsSource"] = error.localizedDescription.contains("不属于当前任务") }
        for mode in [AgentMode.ask, .plan] {
            tasks.update(id) { $0.mode = mode }
            do { _ = try await tools.execute(edit); checks["memoryTopicExecutionRespectsMode-" + mode.rawValue] = false }
            catch { checks["memoryTopicExecutionRespectsMode-" + mode.rawValue] = error.localizedDescription.contains("不能修改项目记忆") }
        }
        tasks.update(id) { $0.mode = .agent }
        let service = AgentGeneralSettings(directory: profile)
        var settings = service.settings; settings.projectMemory = false; try service.save(settings)
        checks["memoryOffOmitsTopicNamesAndMainContents"] = try !runtime.systemContext(task).contains("发布流程.md") && !runtime.systemContext(task).contains("PUBLIC_DEFAULT_MEMORY")
        do { _ = try await tools.execute(request); checks["memoryOffBlocksTopicDirectoryTool"] = false }
        catch { checks["memoryOffBlocksTopicDirectoryTool"] = error.localizedDescription.contains("已关闭") }
        checks["disabledMemoryTopicsRemainManuallyAvailable"] = try AgentMemory.snapshot(.project, store: tasks, taskID: id, workspace: secondary.path, topic: theme.topic).content == "PUBLIC_SECONDARY_RELEASE_TOPIC"
        let directory = primary.appendingPathComponent(".bluefatfish/memory")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: file.deletingLastPathComponent())
        let redirected = try AgentMemory.catalog(.project, store: tasks, taskID: id)
        checks["memoryCatalogRejectsLinkedTopicDirectory"] = redirected.topicError != nil && redirected.topics.isEmpty
        do { _ = try AgentMemory.snapshot(.project, store: tasks, taskID: id, topic: theme.topic); checks["memoryTopicCannotReadThroughLinkedParent"] = false }
        catch { checks["memoryTopicCannotReadThroughLinkedParent"] = true }
        do { _ = try AgentMemory.createTopic("../越界.md", scope: .project, store: tasks, taskID: id, workspace: secondary.path); checks["memoryTopicRejectsNonlocalName"] = false }
        catch { checks["memoryTopicRejectsNonlocalName"] = error.localizedDescription.contains("有效的 Markdown") }
        checks["memoryTopicCheckDidNotRequestModels"] = modelRequests == 0
        return checks
    }
}
