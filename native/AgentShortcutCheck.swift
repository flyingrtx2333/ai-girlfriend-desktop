import AppKit

@MainActor extension AppDelegate {
    func runAgentShortcutCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], requests = 0
        let binary = Bundle.main.executableURL!, hash = (try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)) ?? ""
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            try write(["appPID": getpid(), "binaryHash": hash], "shortcut-started.json")
            ensureAgent(); agentRuntime?.modelRequestCheck = { requests += 1; throw PetError("快捷键验收不调用模型") }
            let root = output.appendingPathComponent("shortcut-store-check", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let value = AgentShortcuts(directory: root), config = root.appendingPathComponent("shortcuts.json")
            func bytes() throws -> Data { try Data(contentsOf: config) }
            func rejects(_ name: String, _ action: () throws -> Void) throws {
                let before = try bytes(); var rejected = false
                do { try action() } catch { rejected = true }
                let after = try bytes(); checks[name] = rejected && after == before
            }
            let defaults = AgentShortcutCommand.allCases.map { value.binding($0) }
            checks["elevenUniqueDefaultsWithoutCreatingConfig"] = value.error == nil && defaults.count == 11 && Set(defaults).count == 11 && !FileManager.default.fileExists(atPath: config.path)
            try value.set(.init("n", [.command, .option]), for: .newTask)
            checks["customBindingPersistsAndReopens"] = AgentShortcuts(directory: root).binding(.newTask) == .init("n", [.command, .option])
            checks["configOwnerOnly"] = (try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            try rejects("duplicateRejectedWithoutWrite") { try value.set(.init("k", .command), for: .newTask) }
            try rejects("textEditingReservedWithoutWrite") { try value.set(.init("c", .command), for: .newTask) }
            try rejects("unmodifiedTypingRejected") { try value.set(.init("n", []), for: .newTask) }
            try rejects("unknownModifierRejected") { try value.set(.init("n", [.command, .function]), for: .newTask) }
            try rejects("backtabReservedForComposer") { try value.set(.init("\t", .shift), for: .newTask) }
            try value.set(.cleared, for: .newTask)
            checks["clearPersistsRatherThanFallingBack"] = AgentShortcuts(directory: root).binding(.newTask) == .cleared
            try value.set(.init("n", .command), for: .searchTasks)
            try rejects("singleRestoreChecksConflicts") { try value.set(nil, for: .newTask) }
            try value.reset()
            checks["restoreAllIsAtomicAndSparse"] = value.overrides.isEmpty && AgentShortcuts(directory: root).binding(.searchTasks) == AgentShortcutCommand.searchTasks.defaultBinding
            let stale = AgentShortcuts(directory: root)
            try value.set(.init("j", [.command, .option]), for: .searchTasks)
            try rejects("externalChangePreservedByCAS") { try stale.set(.init("n", [.command, .option]), for: .newTask) }
            stale.reload(); checks["reloadAdoptsExternalChange"] = stale.error == nil && stale.binding(.searchTasks) == value.binding(.searchTasks)
            let good = try bytes(); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config.path)
            try rejects("readOnlyConfigPreserved") { try value.reset() }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            let target = root.appendingPathComponent("retained-original.json"); try good.write(to: target); try FileManager.default.removeItem(at: config); try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
            let linked = AgentShortcuts(directory: root)
            checks["symlinkLoadRejected"] = linked.error != nil
            do { try linked.reset(); checks["symlinkWriteRejectedTargetPreserved"] = false }
            catch { checks["symlinkWriteRejectedTargetPreserved"] = try Data(contentsOf: target) == good }
            try FileManager.default.removeItem(at: config); try Data("{\"version\":4,\"bindings\":{}}".utf8).write(to: config)
            let future = AgentShortcuts(directory: root)
            try rejects("unknownVersionPreserved") { try future.reset() }
            try Data("{\"version\":1,\"bindings\":{},\"future\":true}".utf8).write(to: config)
            checks["unknownFieldsRejected"] = AgentShortcuts(directory: root).error != nil
            try good.write(to: config); value.reload()
            checks["recoverAfterValidFileRestored"] = value.error == nil && value.binding(.searchTasks) == .init("j", [.command, .option])
            try shortcuts.set(.init("n", [.command, .option]), for: .newTask)
            checks["actualMenuUpdatesImmediately"] = shortcutMenuItems[.newTask]?.keyEquivalent == "n" && shortcutMenuItems[.newTask]?.keyEquivalentModifierMask == [.command, .option]
            try shortcuts.set(.cleared, for: .newTask)
            checks["clearedMenuHasNoKeyEquivalent"] = shortcutMenuItems[.newTask]?.keyEquivalent.isEmpty == true
            try shortcuts.reset()
            checks["actualMenuRestoresDefaults"] = shortcutMenuItems[.newTask]?.keyEquivalent == "n" && shortcutMenuItems[.newTask]?.keyEquivalentModifierMask == .command
            let legacyRoot = output.appendingPathComponent("legacy-shortcuts", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
            let legacyURL = legacyRoot.appendingPathComponent("shortcuts.json")
            let old = try JSONSerialization.data(withJSONObject: ["version": 1, "bindings": ["newTask": ["key": "g", "modifiers": NSEvent.ModifierFlags.command.rawValue], "searchTasks": ["key": "b", "modifiers": NSEvent.ModifierFlags.command.rawValue]]], options: [.sortedKeys])
            try old.write(to: legacyURL); try old.write(to: output.appendingPathComponent("legacy-original-shortcuts.json"))
            let legacy = AgentShortcuts(directory: legacyRoot)
            checks["legacyReadDoesNotRewriteOriginal"] = try Data(contentsOf: legacyURL) == old
            checks["newDefaultsDoNotStealLegacyCustomBindings"] = legacy.error == nil && legacy.binding(.newTask) == .init("g", .command) && legacy.binding(.searchTasks) == .init("b", .command) && legacy.binding(.switchTask) == .cleared && legacy.binding(.leftSidebar) == .cleared
            try legacy.set(.init("g", .command), for: .newTask)
            let migrated = try Data(contentsOf: legacyURL); try migrated.write(to: output.appendingPathComponent("legacy-migrated-shortcuts.json"))
            let reopened = AgentShortcuts(directory: legacyRoot)
            checks["legacyClearStatesPersistOnExplicitSaveAndReopen"] = reopened.error == nil && reopened.binding(.switchTask) == .cleared && reopened.binding(.leftSidebar) == .cleared
            do { try legacy.set(nil, for: .switchTask); checks["legacyConflictRestorePreservesBytes"] = false }
            catch { checks["legacyConflictRestorePreservesBytes"] = try Data(contentsOf: legacyURL) == migrated }
            try legacy.set(.init("n", [.command, .option]), for: .newTask); try legacy.set(nil, for: .switchTask)
            checks["explicitRebindCanEnableNewDefault"] = AgentShortcuts(directory: legacyRoot).binding(.switchTask) == .init("g", .command) && legacy.binding(.leftSidebar) == .cleared
            guard let tasks = agentStore else { throw PetError("任务系统未初始化") }
            let workspace = output.appendingPathComponent("workspace"), source = try String(contentsOf: workspace.appendingPathComponent("README.md"), encoding: .utf8)
            let first = tasks.create(title: source.components(separatedBy: "\n").first ?? "README.md", workspace: workspace.path, mode: .ask, workMode: .coding)
            tasks.update(first) { $0.draft = source }
            let second = tasks.create(title: "README.md", mode: .ask, workMode: .general)
            tasks.update(second) { $0.draft = "工作区外的公开 README 任务，保留草稿。" }
            let archived = tasks.create(title: "README.md · 归档", mode: .ask); try tasks.setArchived([archived], archived: true)
            let candidates = AgentTaskSwitcher.candidates(store: tasks, query: "")
            checks["quickSwitcherIncludesBothWorkModesAndExcludesArchived"] = candidates.contains { $0.id == first } && candidates.contains { $0.id == second } && !candidates.contains { $0.id == archived }
            checks["quickSwitcherFindsActualUnicodeTitle"] = AgentTaskSwitcher.candidates(store: tasks, query: "小鲸").contains { $0.id == first }
            checks["quickSwitcherFindsFileNameAcrossWorkModes"] = AgentTaskSwitcher.candidates(store: tasks, query: "readme.md").map(\.id) == [second]
            checks.merge(try await checkShortcutPanels(tasks: tasks, first: first, second: second, output: output), uniquingKeysWith: { _, new in new })
            try write(["publicTaskID": first, "generalTaskID": second, "archivedTaskID": archived, "sourceHash": AgentFiles.hash(Data(source.utf8))], "navigation-created.json")
            checks["zeroModelRepliesReceiptsAndJobs"] = requests == 0 && agentStore?.tasks.compactMap { agentStore?.task($0.id) }.allSatisfy { $0.messages.isEmpty && $0.modelReceipts?.isEmpty != false && agentRuntime?.isRunning($0.id) != true } == true
            try write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "blockedModelAttempts": requests, "success": checks.values.allSatisfy { $0 }], "shortcut-result.json")
        } catch { try? write(["appPID": getpid(), "binaryHash": hash, "checks": checks, "blockedModelAttempts": requests, "success": false, "error": error.localizedDescription], "shortcut-result.json") }
    }
}

@MainActor private func checkShortcutPanels(tasks: AgentStore, first: String, second: String, output: URL) async throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    func button(_ title: String, in root: NSView?) throws -> NSButton {
        guard let value = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title || $0.accessibilityLabel() == title }) else { throw PetError("缺少快捷操作：" + title) }; return value
    }
    func settle(_ host: NSWindow) async throws {
        let limit = Date().addingTimeInterval(5)
        while host.attachedSheet != nil, Date() < limit { try await Task.sleep(for: .milliseconds(20)) }
        guard host.attachedSheet == nil else { throw PetError("快捷操作窗口未关闭") }
    }
    let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 780, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false; host.contentView = AgentThemeView(fill: AgentWorkbenchTheme.surface); host.makeKeyAndOrderFront(nil)
    defer { if let sheet = host.attachedSheet { host.endSheet(sheet) }; host.orderOut(nil) }
    let root = output.appendingPathComponent("shortcut-panels", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let shortcuts = AgentShortcuts(directory: root), config = root.appendingPathComponent("shortcuts.json")
    try shortcuts.reset()
    let settings = AgentShortcutSettingsView(shortcuts: shortcuts), form = AgentSettingsStyle.form([settings], label: "快捷键")
    host.contentView = form
    let original = try Data(contentsOf: config)
    try button("搜索任务快捷键", in: form).performClick(nil)
    guard let sheet = host.attachedSheet else { throw PetError("快捷键录入未打开") }
    try await Task.sleep(for: .milliseconds(100))
    checks["recorderOwnedCompactSheetInMinimumWindow"] = sheet.contentView is AgentThemeView && sheet.frame.width == 384 && sheet.frame.height < host.frame.height && NSApp.modalWindow == nil
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path) }
    try button("清除快捷键", in: sheet.contentView).performClick(nil)
    let message = views(sheet.contentView).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "录入快捷键" }
    checks["recorderWriteFailureRetainsBindingBytesAndError"] = try host.attachedSheet === sheet && Data(contentsOf: config) == original && shortcuts.binding(.searchTasks) == AgentShortcutCommand.searchTasks.defaultBinding && message?.stringValue != "按下新的快捷键" && message?.stringValue.isEmpty == false
    if let message {
        let rect = message.alignmentRect(forFrame: message.bounds)
        checks["recorderFailureResizesWithoutClipping"] = try message.visibleRect.intersection(rect).height >= rect.height - 1 && button("取消", in: sheet.contentView).visibleRect.height >= 27
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    try button("清除快捷键", in: sheet.contentView).performClick(nil); try await settle(host)
    checks["recorderRetryClearsAndUpdatesActualKeycap"] = try shortcuts.binding(.searchTasks) == .cleared && button("搜索任务快捷键", in: form).title == AgentShortcutBinding.cleared.display
    try button("搜索任务恢复默认", in: form).performClick(nil)
    checks["recorderRestoreUpdatesActualKeycapAndConfig"] = shortcuts.binding(.searchTasks) == AgentShortcutCommand.searchTasks.defaultBinding && AgentShortcuts(directory: root).overrides.isEmpty
    let records = try [first, second].map { try Data(contentsOf: tasks.directory.appendingPathComponent($0 + ".json")) }
    for look in [NSAppearance.Name.aqua, .darkAqua] {
        host.appearance = NSAppearance(named: look)
        var selected: String?
        let switcher = AgentTaskSwitcher(store: tasks, selected: first, onSelect: { selected = $0 }, onClose: {})
        switcher.begin(in: host); try await Task.sleep(for: .milliseconds(100))
        guard let window = host.attachedSheet, let search = views(window.contentView).compactMap({ $0 as? NSSearchField }).first else { throw PetError("任务切换搜索未打开") }
        checks["switcherFitsAndFocusesSearch-" + look.rawValue] = window.contentView is AgentThemeView && window.frame.width == 560 && window.frame.height <= host.contentLayoutRect.height && search.currentEditor() != nil
        search.stringValue = "NO_MATCH_734582"; search.sendAction(search.action, to: search.target)
        let open = try button("打开", in: window.contentView)
        checks["switcherEmptyQueryDisablesOpening-" + look.rawValue] = !open.isEnabled && switcher.checkState()["selected"] as? String == ""
        search.stringValue = "readme.md"; search.sendAction(search.action, to: search.target)
        checks["switcherFilterRetainsKeyboardSelection-" + look.rawValue] = open.isEnabled && switcher.checkState()["selected"] as? String == second
        if look == .aqua { open.performClick(nil) } else { switcher.cancel() }
        try await settle(host)
        checks["switcherSelectOrCancelCallback-" + look.rawValue] = look == .aqua ? selected == second : selected == nil
    }
    checks["switcherLeavesBothTaskRecordsAndDraftsByteIdentical"] = try [first, second].enumerated().allSatisfy { try Data(contentsOf: tasks.directory.appendingPathComponent($0.element + ".json")) == records[$0.offset] }
    return checks
}
