import AppKit

@MainActor extension AppDelegate {
    func runSidebarLayoutCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        var stage = 0
        func checkpoint(_ name: String) throws {
            stage += 1
            let value: [String: Any] = ["stage": name, "checks": checks, "appPID": getpid(), "modelRequests": requests]
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent("sidebar-stage-\(stage)-\(name).json"), options: .atomic)
        }
        do {
            try checkpoint("start")
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少独立任务存储") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("侧栏验收禁止模型请求") }
            let id = tasks.create(title: "侧栏布局验收")
            guard runtime.submit("侧栏布局检查的公开用户消息。", taskID: id, startImmediately: false) else { throw PetError("公开消息未保存") }
            tasks.update(id) { $0.draft = "保留侧栏布局的原任务草稿。" }
            control.showAgentTask(id)
            guard usesAgent, control.sidebarLayoutReadback()["actualLower"] as? [String] == ["sidebar-automation", "sidebar-extensions"] else { throw PetError("验收未进入实际 Agent 工作台或初始配置不独立") }
            let second = ControlWindow(companion: self, taskID: id, windowNumber: 2); additionalTaskWindows.append(second)
            let service = sidebarLayout, file = store.directory.appendingPathComponent("sidebar.json")
            let taskBytes = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json"))
            let preferenceEncoder = JSONEncoder(); preferenceEncoder.outputFormatting = [.sortedKeys]
            let preferences = try preferenceEncoder.encode(store.preferences)
            checks["missingLayoutUsesDefaultsWithoutWritingFile"] = service.error == nil && service.settings == AgentSidebarLayout.Settings() && !FileManager.default.fileExists(atPath: file.path)
            var frames: [[String: Any]] = []
            let all = AgentSidebarItem.allCases
            for section in AgentSidebarSection.allCases {
                try checkpoint("before-group-\(section.rawValue)")
                var value = AgentSidebarLayout.Settings(); value.upper = []; value.lower = []; value.more = []; value[section] = all
                try service.save(value)
                for size in [NSSize(width: 1200, height: 774), NSSize(width: 780, height: 540)] {
                    for window in [control, second] { window.window?.setFrame(NSRect(origin: .zero, size: size), display: false); window.window?.contentView?.layoutSubtreeIfNeeded() }
                    let state = [control, second].map { $0.sidebarLayoutReadback() }
                    let exact = state.allSatisfy { ($0["actualUpper"] as? [String]) == value.upper.map { "sidebar-" + $0.rawValue } && ($0["actualLower"] as? [String]) == value.lower.map { "sidebar-" + $0.rawValue } && ($0["moreMenu"] as? [String]) == value.more.map(\.rawValue) && ($0["moreVisible"] as? Bool) == !value.more.isEmpty }
                    let fits = state.allSatisfy { ($0["newTaskFixed"] as? Bool) == true && ($0["settingsFixed"] as? Bool) == true && ($0["taskListHeight"] as? CGFloat ?? 0) >= 39.5 && (value.upper.isEmpty || ($0["upperHeight"] as? CGFloat ?? 0) >= 31.5) && (value.lower.isEmpty || ($0["lowerHeight"] as? CGFloat ?? 0) >= 31.5) }
                    checks["\(section.rawValue)-\(Int(size.width))BothWindowsUseExactOrderAndFixedEntries"] = exact && fits
                    frames.append(["section": section.title, "width": size.width, "states": state])
                    try checkpoint("after-layout-\(section.rawValue)-\(Int(size.width))")
                }
            }
            try service.save(AgentSidebarLayout.Settings())
            try checkpoint("before-editor")
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 544, height: 620), styleMask: [.titled], backing: .buffered, defer: false); host.isReleasedWhenClosed = false
            let editor = AgentSidebarLayoutSettingsView(service: service); try checkpoint("editor-created")
            host.contentView = editor; try checkpoint("editor-attached")
            host.contentView?.layoutSubtreeIfNeeded(); try checkpoint("editor-laid-out")
            func table(_ section: AgentSidebarSection) throws -> NSTableView {
                func find(_ view: NSView) -> NSTableView? {
                    if let table = view as? NSTableView, table.accessibilityLabel() == section.title { return table }
                    return view.subviews.lazy.compactMap(find).first
                }
                guard let value = find(editor) else { throw PetError("缺少实际侧栏预览列表") }; return value
            }
            let more = try table(.more), lower = try table(.lower), upper = try table(.upper)
            try checkpoint("tables-found")
            more.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try checkpoint("before-keyboard-left")
            _ = editor.moveSelection(in: more, key: 123)
            try checkpoint("after-keyboard-left")
            checks["KeyboardLeftMovesItemToPreviousGroupAndKeepsSelection"] = service.settings.lower == [.automation, .extensions, .library] && service.settings.more == [.wiki] && lower.selectedRow == 2 && host.firstResponder === lower
            checks["KeyboardMoveKeepsEveryPreviewRowWithinItsClip"] = [upper, lower, more].allSatisfy { table in
                let count = table.numberOfRows
                guard let clip = table.enclosingScrollView?.documentVisibleRect, count > 0 else { return false }
                return table.rect(ofRow: 0).minY >= clip.minY - 0.5 && table.rect(ofRow: count - 1).maxY <= clip.maxY + 0.5
            }
            _ = editor.moveSelection(in: lower, key: 126)
            checks["KeyboardUpReordersWithinGroup"] = service.settings.lower == [.automation, .library, .extensions] && lower.selectedRow == 1
            _ = editor.moveSelection(in: lower, key: 125)
            checks["KeyboardDownReordersWithinGroup"] = service.settings.lower == [.automation, .extensions, .library] && lower.selectedRow == 2
            _ = editor.moveSelection(in: lower, key: 124)
            try checkpoint("after-keyboard-moves")
            checks["KeyboardRightMovesToMoreInExactOrder"] = service.settings.more == [.wiki, .library] && more.selectedRow == 1
            let unchanged = try Data(contentsOf: file)
            upper.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); _ = editor.moveSelection(in: upper, key: 123)
            checks["KeyboardAtFirstGroupBoundaryDoesNotRewriteFile"] = try Data(contentsOf: file) == unchanged
            let loaded = AgentSidebarLayout(directory: store.directory)
            checks["LayoutReloadPreservesExactOrder"] = loaded.error == nil && loaded.settings == service.settings
            checks["LayoutFileIsPrivate"] = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            var next = service.settings; try next.move(.attention, to: .more)
            var refused = false; do { try service.save(next) } catch { refused = true }
            checks["ReadOnlyLayoutRefusesSaveWithoutChangingMemoryOrBytes"] = try refused && Data(contentsOf: file) == unchanged && service.settings == loaded.settings
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var external = service.settings; try external.move(.search, to: .lower)
            let bytes = try JSONEncoder().encode(external); try bytes.write(to: file)
            refused = false; do { try service.save(next) } catch { refused = true }
            checks["ExternalEditRefusesOverwriteAndPreservesBothStates"] = try refused && Data(contentsOf: file) == bytes && service.settings == loaded.settings
            service.reload(); service.publish()
            try checkpoint("after-io-guards")
            checks["ExplicitReloadAcceptsExternalLayout"] = service.error == nil && service.settings == external && control.sidebarLayoutReadback()["moreMenu"] as? [String] == external.more.map(\.rawValue)
            let invalid: [(String, String)] = [
                ("version", "{\"version\":2,\"upper\":[\"attention\",\"search\"],\"lower\":[\"automation\",\"extensions\"],\"more\":[\"library\",\"wiki\"]}"),
                ("duplicate", "{\"version\":1,\"upper\":[\"attention\",\"attention\"],\"lower\":[\"automation\",\"extensions\"],\"more\":[\"library\",\"wiki\"]}"),
                ("missing", "{\"version\":1,\"upper\":[],\"lower\":[],\"more\":[]}"),
                ("fixed", "{\"version\":1,\"upper\":[\"newTask\",\"search\"],\"lower\":[\"automation\",\"extensions\"],\"more\":[\"library\",\"wiki\"]}"),
                ("field", "{\"version\":1,\"upper\":[\"attention\",\"search\"],\"lower\":[\"automation\",\"extensions\"],\"more\":[\"library\",\"wiki\"],\"extra\":true}")]
            for (label, text) in invalid {
                let directory = output.appendingPathComponent("invalid-" + label); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("sidebar.json"), data = Data(text.utf8); try data.write(to: target)
                let guarded = AgentSidebarLayout(directory: directory); refused = false; do { try guarded.save(AgentSidebarLayout.Settings()) } catch { refused = true }
                checks["Invalid-" + label + "IsPreservedAndCannotSave"] = try refused && guarded.error != nil && Data(contentsOf: target) == data
            }
            let linked = output.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false); try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("sidebar.json"), withDestinationURL: file)
            checks["LinkedLayoutIsRejected"] = AgentSidebarLayout(directory: linked).error != nil
            let compatibility = output.appendingPathComponent("compatibility"); try FileManager.default.createDirectory(at: compatibility, withIntermediateDirectories: false)
            let appearanceFile = compatibility.appendingPathComponent("appearance.json"), appearanceBytes = Data("{\"version\":1,\"theme\":\"dark\",\"textSize\":16}".utf8); try appearanceBytes.write(to: appearanceFile)
            let separate = AgentSidebarLayout(directory: compatibility); try separate.save(external)
            checks["ExistingAppearanceSchemaAndBytesRemainCompatible"] = try Data(contentsOf: appearanceFile) == appearanceBytes && AgentAppearance(directory: compatibility).error == nil
            checks["OriginalTaskFieldsAndModelPreferencesRemainUnchanged"] = try Data(contentsOf: tasks.directory.appendingPathComponent(id + ".json")) == taskBytes && preferenceEncoder.encode(store.preferences) == preferences
            try checkpoint("completed")
            host.close(); report["frames"] = frames; report["success"] = checks.count == 26 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = requests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("sidebar-layout-report.json"))
    }
}
