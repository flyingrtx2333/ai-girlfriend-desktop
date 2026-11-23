import AppKit

@MainActor enum AgentMCPImportCheck {
    private static func find<T: NSView>(_ type: T.Type, in view: NSView?, matching: (T) -> Bool) -> T? {
        guard let view else { return nil }; if let value = view as? T, matching(value) { return value }
        for child in view.subviews { if let value = find(type, in: child, matching: matching) { return value } }; return nil
    }
    private static func control<T: NSView>(_ type: T.Type, _ label: String, page: AgentSettingsPageController) throws -> T {
        guard let value = find(type, in: page.pageContentView, matching: { $0.accessibilityLabel() == label }) else { throw PetError("缺少 MCP 导入控件：" + label) }; return value
    }
    private static func press(_ title: String, page: AgentSettingsPageController) throws {
        guard let value = find(NSButton.self, in: page.pageContentView, matching: { $0.title == title && $0.isEnabled }) else { throw PetError("缺少 MCP 操作：" + title) }; value.performClick(nil)
    }
    private static func text(_ view: NSView?) -> String {
        guard let view else { return "" }; return (view as? NSTextField)?.stringValue ?? (view as? NSTextView)?.string ?? view.subviews.map { text($0) }.joined(separator: "\n")
    }
    private static func encode(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
    private static func selectJSON(page: AgentSettingsPageController) throws {
        let kinds = try control(NSSegmentedControl.self, "MCP 配置方式", page: page)
        if kinds.selectedSegment != 1 { kinds.selectedSegment = 1; NSApp.sendAction(kinds.action!, to: kinds.target, from: kinds) }
    }
    static func prepareCardsUI(_ output: URL, tasks: AgentStore) async throws {
        let source = output.appendingPathComponent("MCP public plugin"), metadata = source.appendingPathComponent(".qoder-plugin")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data(encode(["name": "mcp-cards-public", "version": "1.0.0", "description": "公开连接器卡片验收"]).utf8).write(to: metadata.appendingPathComponent("plugin.json"))
        try Data(encode(["mcpServers": ["public-card": ["command": "/usr/bin/true", "args": []]]]).utf8).write(to: source.appendingPathComponent(".mcp.json"))
        _ = try tasks.extensions.plugins.install(await tasks.extensions.plugins.inspect(source))
    }
    static func prepareSources(_ output: URL) throws -> [URL] {
        let root = output.appendingPathComponent("MCP 导入来源"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let multiple = root.appendingPathComponent("MCP公开配置.json"), single = root.appendingPathComponent("MCP单连接器.json")
        let definitions: [String: [String: Any]] = [
            "A 公开本机": ["command": "/opt/homebrew/bin/node", "args": [output.appendingPathComponent("settings-echo.mjs").path, output.appendingPathComponent("settings-import-started.pid").path], "env": [:], "timeoutSeconds": 10],
            "B 公开 HTTP": ["url": "https://example.com/mcp", "headers": [:]],
            "C 路径补全": ["command": "true"],
            "Z 待修正": ["command": "/usr/bin/true", "unknown": "保留待修正字段"]
        ]
        try Data(encode(["mcpServers": definitions]).utf8).write(to: multiple)
        try Data(encode(["name": "单份公开配置", "type": "stdio", "command": "/usr/bin/true", "args": ["single"], "env": [:]]).utf8).write(to: single)
        return [multiple, single]
    }
    static func run(tasks: AgentStore, taskID: String, pane: AgentSettingsPageHost, host: NSWindow, output: URL) throws -> [String: Bool] {
        let service = tasks.mcp, workspace = tasks.task(taskID)?.workspace, sources = try prepareSources(output)
        let sourceBytes = try sources.map { try Data(contentsOf: $0) }, configuration = tasks.extensions.profile.appendingPathComponent("extensions/mcp.json")
        let priorDocuments = try Dictionary(uniqueKeysWithValues: service.availableServers(workspace: workspace).map { ($0.id, try service.document($0)) })
        let visible = NSApp.windows.filter(\.isVisible).count, manager = AgentMCPWindow(service: service, workspace: workspace)
        guard pane.show(category: "mcp", identity: "inline-mcp-import", scope: "设置项目", make: { _ in manager }) else { throw PetError("无法进入 MCP 导入检查") }
        var checks: [String: Bool] = [:]
        let add = try control(NSPopUpButton.self, "新建 MCP 连接器", page: manager)
        let catalog = try control(NSTableView.self, "MCP 连接器列表", page: manager), search = try control(NSSearchField.self, "搜索连接器", page: manager)
        let rowCount = catalog.numberOfRows
        checks["mcpCatalogUsesGroupedFullWidthCardsWithoutAnInlineEditor"] = text(manager.pageContentView).contains("自定义连接器") && catalog.bounds.width >= 600 && find(NSTextView.self, in: manager.pageContentView, matching: { _ in true }) == nil
        search.stringValue = "no-connector-983"; NSApp.sendAction(search.action!, to: search.target, from: search)
        checks["mcpCatalogSearchShowsAnActualEmptyResult"] = catalog.numberOfRows == 0 && text(manager.pageContentView).contains("没有匹配的连接器")
        search.stringValue = ""; NSApp.sendAction(search.action!, to: search.target, from: search)
        checks["mcpCatalogSearchRestoresEveryOriginalRow"] = catalog.numberOfRows == rowCount
        guard let first = service.availableServers(workspace: workspace).first else { throw PetError("缺少原连接器") }; manager.selectServer(first.id)
        guard let detail = pane.currentController, detail !== manager else { throw PetError("连接器配置未进入右侧子页面") }
        let editor = try control(NSTextView.self, "MCP 配置 JSON", page: detail)
        let details = try control(NSTabView.self, "连接器详情标签", page: detail), kinds = try control(NSSegmentedControl.self, "连接器详情类型", page: detail)
        checks["mcpDetailUsesThemedSegmentsAndKeepsItsActualEditor"] = details.tabViewType == .noTabsNoBorder && kinds.segmentCount == 2 && editor.window === host && host.attachedSheet == nil && detail.window?.isVisible == false
        let state = try control(AgentSettingsStatusField.self, "MCP 保存与连接状态", page: detail), previous = state.stringValue
        state.stringValue = "配置目标只读，请检查权限后重试。\n/Volumes/Public connector/settings/mcp.json\n原文件与未保存填写保持。"
        let size = host.contentView?.frame.size ?? .zero; host.setContentSize(NSSize(width: 420, height: 360)); pane.layoutSubtreeIfNeeded()
        guard let save = find(NSButton.self, in: detail.pageContentView, matching: { $0.title == "保存" }) else { throw PetError("缺少连接器保存操作") }
        checks["mcpNarrowDetailKeepsSaveVisibleAndFullErrorAccessible"] = state.bounds.height >= 36 && state.accessibilityValue() == state.stringValue && state.isSelectable && save.visibleRect.height >= save.bounds.height - 1 && details.bounds.height >= 100
        state.stringValue = previous; host.setContentSize(size); pane.layoutSubtreeIfNeeded()
        checks["mcpCreationMenuContainsAllThreeTransports"] = add.pullsDown && add.menu?.items.compactMap { $0.representedObject as? String } == ["stdio", "http", "sse"]
        for type in ["stdio", "http", "sse"] {
            let before = try Data(contentsOf: configuration), item = add.menu!.items.first { ($0.representedObject as? String) == type }!
            details.selectTabViewItem(at: 1); detail.close()
            checks["mcpDetailReturnsToItsOriginalKeyboardList-" + type] = pane.currentController === manager && host.firstResponder === catalog && kinds.selectedSegment == 1
            NSApp.sendAction(item.action!, to: item.target, from: item)
            checks["mcpNewDraftOpensStructuredForm-" + type] = try control(NSSegmentedControl.self, "MCP 配置方式", page: detail).selectedSegment == 0 && !control(NSScrollView.self, "MCP 配置表单", page: detail).isHiddenOrHasHiddenAncestor
            try selectJSON(page: detail)
            let draft = try JSONSerialization.jsonObject(with: Data(editor.string.utf8)) as! [String: Any]
            checks["mcpNewDraftWithoutModal-" + type] = try pane.currentController === detail && host.attachedSheet == nil && draft["type"] as? String == type && editor.isEditable && Data(contentsOf: configuration) == before && host.firstResponder === editor
            checks["mcpNewDraftRevealsEditorFromTools-" + type] = details.selectedTabViewItem?.identifier as? String == "配置" && editor.window === host && !editor.isHiddenOrHasHiddenAncestor
            checks["mcpNewDraftShowsCurrentTransportHint-" + type] = text(detail.pageContentView).contains(type == "stdio" ? "本机程序使用当前账户权限" : "凭据保存在钥匙串")
            var value = draft; value["name"] = "页内新建-" + type
            if type == "stdio" { value["command"] = "/usr/bin/true" }
            editor.string = try encode(value); manager.textDidChange(Notification(name: NSText.didChangeNotification, object: editor)); try press("保存", page: detail)
            checks["mcpNewDraftSavesThroughOriginalService-" + type] = service.availableServers(workspace: workspace).contains { $0.name == "页内新建-" + type && $0.type == type }
        }
        details.selectTabViewItem(at: 1)
        let tools = try control(AgentMCPToolCatalog.self, "MCP 实际工具目录", page: detail)
        let parentText = editor.string, beforeCancel = try Data(contentsOf: configuration)
        try manager.reviewImport(sources[0])
        guard let cancelled = pane.currentController as? AgentMCPImportPage else { throw PetError("MCP 导入未进入子页面") }
        let list = try control(NSTableView.self, "待导入 MCP 连接器", page: cancelled), preview = try control(NSTextView.self, "MCP 导入配置预览", page: cancelled)
        checks["mcpImportHostedWithoutSheet"] = cancelled.presentingWindow === host && cancelled.window?.isVisible == false && host.attachedSheet == nil
        checks["mcpImportListsEveryDefinitionAndFocusesList"] = list.numberOfRows == 4 && host.firstResponder === list && !preview.isEditable
        var measurements: [String: Any] = [:]
        for (label, size) in [("normal", NSSize(width: 800, height: 540)), ("narrow", NSSize(width: 420, height: 360))] {
            host.setContentSize(size); pane.layoutSubtreeIfNeeded()
            checks["mcpImportLayout-" + label] = !list.hasAmbiguousLayout && !preview.hasAmbiguousLayout && preview.bounds.width >= 140 && preview.bounds.height >= 100
            measurements[label] = ["previewSize": [preview.bounds.width, preview.bounds.height], "listAmbiguous": list.hasAmbiguousLayout, "previewAmbiguous": preview.hasAmbiguousLayout]
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mcp-import-layout.json"))
        host.setContentSize(NSSize(width: 800, height: 540)); try press("取消", page: cancelled)
        checks["mcpImportCancelPreservesEditorAndStoredBytes"] = try pane.currentController === detail && editor.string == parentText && Data(contentsOf: configuration) == beforeCancel && host.firstResponder === tools
        checks["mcpImportCancelReturnsToVisibleToolsTab"] = details.selectedTabViewItem?.identifier as? String == "工具" && tools.window === host && !tools.isHiddenOrHasHiddenAncestor
        for index in 0..<4 {
            let before = try Data(contentsOf: configuration); details.selectTabViewItem(at: 1); try manager.reviewImport(sources[0])
            guard let page = pane.currentController as? AgentMCPImportPage else { throw PetError("缺少 MCP 审阅页") }
            let rows = try control(NSTableView.self, "待导入 MCP 连接器", page: page), importPreview = try control(NSTextView.self, "MCP 导入配置预览", page: page)
            rows.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let document = importPreview.string, definition = try JSONSerialization.jsonObject(with: Data(document.utf8)) as! [String: Any]
            let name = ["A 公开本机", "B 公开 HTTP", "C 路径补全", "Z 待修正"][index]
            checks["mcpImportFullPreview-\(index)"] = definition["name"] as? String == name && (index == 0 ? document.contains("settings-import-started.pid") : index == 1 ? document.contains("https://example.com/mcp") : index == 2 ? (definition["command"] as? String)?.hasPrefix("/") == true && definition["args"] as? [String] == [] && (definition["env"] as? [String: String])?.isEmpty == true : document.contains("保留待修正字段"))
            try press("载入草稿", page: page)
            checks["mcpImportLoadDoesNotSave-\(index)"] = try pane.currentController === detail && editor.string == document && Data(contentsOf: configuration) == before
            try selectJSON(page: detail)
            checks["mcpImportLoadRevealsEditorFromTools-\(index)"] = details.selectedTabViewItem?.identifier as? String == "配置" && editor.window === host && !editor.isHiddenOrHasHiddenAncestor
            try press("保存", page: detail)
            if index == 3 {
                checks["mcpImportInvalidSaveKeepsDraftAndOriginalData"] = try pane.currentController === detail && editor.string == document && text(detail.pageContentView).contains("未知配置字段") && Data(contentsOf: configuration) == before
                var fixed = definition; fixed.removeValue(forKey: "unknown"); editor.string = try encode(fixed); manager.textDidChange(Notification(name: NSText.didChangeNotification, object: editor)); try press("保存", page: detail)
            }
            checks["mcpImportSavePublishesSelectedDefinition-\(index)"] = service.availableServers(workspace: workspace).contains { $0.name == name && $0.command == (definition["command"] as? String) && $0.url == (definition["url"] as? String) }
        }
        try manager.reviewImport(sources[1])
        guard let single = pane.currentController as? AgentMCPImportPage else { throw PetError("单连接器未进入审阅页") }
        checks["mcpSingleImportPreservesExactSourceText"] = try control(NSTableView.self, "待导入 MCP 连接器", page: single).numberOfRows == 1 && control(NSTextView.self, "MCP 导入配置预览", page: single).string == String(decoding: sourceBytes[1], as: UTF8.self)
        try press("载入草稿", page: single); try press("保存", page: detail)
        checks["mcpSingleImportUsesOriginalSave"] = service.availableServers(workspace: workspace).contains { $0.name == "单份公开配置" && $0.args == ["single"] }
        for (name, data) in [("invalid", Data("[]".utf8)), ("empty", Data(#"{"mcpServers":{}}"#.utf8)), ("oversized", Data(repeating: 32, count: 64_001))] {
            let file = output.appendingPathComponent("mcp-import-" + name + ".json"), before = try Data(contentsOf: configuration), previous = editor.string
            try data.write(to: file)
            do { try manager.reviewImport(file); checks["mcpImportRejects-" + name] = false }
            catch { checks["mcpImportRejects-" + name] = try pane.currentController === detail && editor.string == previous && Data(contentsOf: configuration) == before }
        }
        checks["mcpImportNeverReplacesExistingConnectors"] = try priorDocuments.allSatisfy { id, document in guard let value = service.availableServers(workspace: workspace).first(where: { $0.id == id }) else { return false }; return try service.document(value) == document }
        checks["mcpImportKeepsBothSourceFilesUnchanged"] = try sources.enumerated().allSatisfy { try Data(contentsOf: $0.element) == sourceBytes[$0.offset] }
        checks["mcpImportNeverStartsSourceProgram"] = !FileManager.default.fileExists(atPath: output.appendingPathComponent("settings-import-started.pid").path)
        checks["mcpImportCreatesNoVisibleManagementWindows"] = NSApp.windows.filter(\.isVisible).count == visible
        checks["mcpImportLeavesNormallyAfterSave"] = pane.leave()
        return checks
    }

    static func recovery(tasks: AgentStore, taskID: String, pane: AgentSettingsPageHost, host: NSWindow, output: URL) async throws -> [String: Bool] {
        let task = tasks.task(taskID), workspace = task?.workspace, service = tasks.mcp
        let context = AgentSettingsRecovery.Context(task: task, workspace: workspace)
        let registry = service.profile.appendingPathComponent("extensions/mcp.json")
        let originalRegistry = try Data(contentsOf: registry)
        let source = output.appendingPathComponent("mcp-review-recovery.json"), secret = "PUBLIC_FIXTURE_IMPORT_SECRET_251"
        let marker = "PUBLIC_IMPORT_LINE_71 中文😀"
        var entries: [String: [String: Any]] = [:]
        for index in 0..<23 { entries[String(format: "Review %02d", index)] = ["command": "/usr/bin/true"] }
        entries["Review 19"] = ["command": "/usr/bin/true", "args": (0..<79).map { "PUBLIC_IMPORT_LINE_\($0) 中文😀" }]
        entries["Review 22"] = ["command": "/usr/bin/true", "env": ["PUBLIC": secret]]
        let bytes = Data(try encode(["mcpServers": entries]).utf8)
        let edited = Data(try encode(["mcpServers": ["Updated review": ["url": "https://example.com/updated"]]]).utf8)
        try bytes.write(to: source, options: .atomic)
        func make(_ kind: String) -> AgentSettingsPageController? { kind == "mcp" ? AgentMCPWindow(service: service, workspace: workspace) : nil }
        func root() throws -> AgentMCPWindow {
            guard pane.show(category: "extensions", identity: context.identity, scope: "设置项目", recoveryContext: context, make: make) else {
                throw PetError("连接器审阅恢复缺少设置入口")
            }
            pane.selectPage("mcp")
            guard let manager = pane.currentController as? AgentMCPWindow else { throw PetError("连接器审阅恢复缺少目录") }
            return manager
        }
        func current() throws -> AgentMCPImportPage {
            guard let page = pane.currentController as? AgentMCPImportPage else { throw PetError("连接器审阅未恢复到原页面") }
            return page
        }
        func capture() throws -> AgentSettingsRecovery.State {
            guard let value = try pane.captureRecovery(active: true) else { throw PetError("缺少连接器审阅恢复记录") }
            return value
        }
        func reopen(_ value: AgentSettingsRecovery.State) async throws -> AgentMCPImportPage {
            pane.finish(); try pane.restoreRecovery(value, make: make)
            try await Task.sleep(nanoseconds: 80_000_000)
            return try current()
        }
        func loadEnabled(_ page: AgentMCPImportPage) -> Bool {
            find(NSButton.self, in: page.pageContentView) { $0.title == "载入草稿" }?.isEnabled == true
        }

        var checks: [String: Bool] = [:]
        host.setContentSize(NSSize(width: 1200, height: 774))
        try root().reviewImport(source)
        let attached = try current(), list = try control(NSTableView.self, "待导入 MCP 连接器", page: attached)
        list.selectRowIndexes(IndexSet(integer: 19), byExtendingSelection: false); list.scrollRowToVisible(19)
        let view = try control(NSTextView.self, "MCP 导入配置预览", page: attached)
        host.contentView?.layoutSubtreeIfNeeded()
        let range = (view.string as NSString).range(of: marker)
        guard range.location != NSNotFound, host.makeFirstResponder(view), let layout = view.layoutManager, let container = view.textContainer else {
            throw PetError("缺少长连接器预览与选区")
        }
        layout.ensureLayout(for: container); view.setFrameSize(NSSize(width: view.frame.width, height: layout.usedRect(for: container).maxY + 24))
        view.setSelectedRange(range); view.scrollRangeToVisible(range)
        let saved = try capture()
        checks["mcpImportFileCheckpointRetainsScopeAndNeverCopiesPreview"] = saved.context == context && saved.pages.map(\.kind) == ["mcp", "mcp-import"] &&
            saved.pages.last.map { !String(decoding: $0.state, as: UTF8.self).contains(secret) && !String(decoding: $0.state, as: UTF8.self).contains(marker) } == true
        host.setContentSize(NSSize(width: 780, height: 540))
        let returned = try await reopen(saved)
        let restoredList = try control(NSTableView.self, "待导入 MCP 连接器", page: returned)
        let restoredText = try control(NSTextView.self, "MCP 导入配置预览", page: returned)
        checks["mcpImportReopensSelectedRowAndLongPreviewSelection"] = restoredList.selectedRow == 19 && AgentSettingsRecovery.selectionIsVisible(in: restoredList) &&
            restoredText.selectedRange() == range && host.firstResponder === restoredText && (restoredText.enclosingScrollView?.documentVisibleRect.minY ?? 0) > 200

        try edited.write(to: source, options: .atomic)
        try press("导入 23 项", page: returned)
        checks["mcpImportRejectsSourceChangedWhileReading"] = try !loadEnabled(returned) && pane.currentController === returned &&
            text(returned.pageContentView).contains("来源文件已变化") && Data(contentsOf: registry) == originalRegistry
        let changed = try await reopen(saved)
        checks["mcpImportChangedSourceKeepsReviewAndCheckpoint"] = try !loadEnabled(changed) && text(changed.pageContentView).contains("来源文件已变化") && capture().pages.last == saved.pages.last
        let held = source.deletingLastPathComponent().appendingPathComponent("mcp-review-recovery-held.json")
        try FileManager.default.moveItem(at: source, to: held)
        let missing = try await reopen(saved)
        checks["mcpImportMissingFileOffersRetryWithoutAdoptingAnotherSource"] = try !loadEnabled(missing) && text(missing.pageContentView).contains("来源文件暂不可读") && capture().pages.last == saved.pages.last
        try FileManager.default.moveItem(at: held, to: source)
        try bytes.write(to: source, options: .atomic); try press("重新读取", page: missing)
        try await Task.sleep(nanoseconds: 80_000_000)
        checks["mcpImportOriginalFileReturnsToSameReviewPosition"] = try loadEnabled(missing) && control(NSTableView.self, "待导入 MCP 连接器", page: missing).selectedRow == 19 &&
            control(NSTextView.self, "MCP 导入配置预览", page: missing).selectedRange() == range
        try edited.write(to: source, options: .atomic); try press("载入草稿", page: missing); try press("重新读取", page: missing)
        checks["mcpImportExplicitReloadReviewsNewContentBeforeLoad"] = try loadEnabled(missing) && control(NSTextView.self, "MCP 导入配置预览", page: missing).string.contains("https://example.com/updated")
        try press("载入草稿", page: missing)
        guard let draft = pane.currentController else { throw PetError("重新读取的连接器草稿未显示") }
        try selectJSON(page: draft)
        checks["mcpImportRecoveredLoadKeepsRegistryAndOriginalSourceBytes"] = try control(NSTextView.self, "MCP 配置 JSON", page: draft).string.contains("https://example.com/updated") &&
            Data(contentsOf: registry) == originalRegistry && Data(contentsOf: source) == edited

        pane.finish()
        let manager = try root()
        guard let existing = service.availableServers(workspace: workspace).first else { throw PetError("粘贴审阅缺少样例连接器") }
        manager.selectServer(existing.id)
        guard let detail = pane.currentController else { throw PetError("粘贴审阅缺少 JSON 编辑器") }
        try selectJSON(page: detail)
        let pasted = #"{"mcpServers":{"env":{"command":"/usr/bin/true","timeout":3500},"headers":{"url":"https://example.com/second","bearerToken":"${INPUT_REQUIRED}"}}}"#
        let editor = try control(NSTextView.self, "MCP 配置 JSON", page: detail)
        editor.string = pasted; manager.textDidChange(.init(name: NSText.didChangeNotification, object: editor))
        try press("预览导入", page: detail)
        let pastePage = try current()
        try control(NSTableView.self, "待导入 MCP 连接器", page: pastePage).selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let pasteState = try capture(), pasteRestored = try await reopen(pasteState)
        checks["mcpImportPastedContainerRecoversChosenDefinitionAndEditor"] = try pasteState.pages.map(\.kind) == ["mcp", "mcp-detail", "mcp-import"] &&
            control(NSTextView.self, "MCP 导入配置预览", page: pasteRestored).string.contains("https://example.com/second")
        try press("取消", page: pasteRestored)
        guard let parent = pane.currentController else { throw PetError("粘贴审阅返回时缺少原编辑器") }
        checks["mcpImportPastedCancelRestoresExactUnsavedJSON"] = try control(NSTextView.self, "MCP 配置 JSON", page: parent).string == pasted && Data(contentsOf: registry) == originalRegistry
        let concealed = #"{"mcpServers":{"duplicated":{"bearerToken":""# + secret + #""},"duplicated":{"bearerToken":"${KEYCHAIN}"}}}"#
        checks["mcpImportPastedDuplicateKeysCannotConcealUnmaskedCredentials"] = !AgentMCPConfigForm.canPreserveDocument(concealed, allowingImport: true)
        pane.finish()

        let batchManager = try root()
        let creation = try control(NSPopUpButton.self, "新建 MCP 连接器", page: batchManager)
        guard let entry = creation.menu?.items.first(where: { $0.title == "粘贴 JSON…" }), let action = entry.action else {
            throw PetError("缺少粘贴 JSON 入口")
        }
        NSApp.sendAction(action, to: entry.target, from: entry)
        guard let batchDetail = pane.currentController, batchDetail !== batchManager else { throw PetError("粘贴未进入设置详情") }
        let batchEditor = try control(NSTextView.self, "MCP 配置 JSON", page: batchDetail)
        checks["mcpDirectPasteOpensTheEmptyJSONEditorWithoutWriting"] = try batchEditor.string.isEmpty && batchEditor.isEditable &&
            !batchEditor.isHiddenOrHasHiddenAncestor && find(NSButton.self, in: batchDetail.pageContentView, matching: { $0.title == "预览导入" })?.isEnabled == false &&
            Data(contentsOf: registry) == originalRegistry
        func pasteBatch(_ documents: [String: [String: String]]) throws -> AgentMCPImportPage {
            batchEditor.string = try encode(["mcpServers": documents])
            batchManager.textDidChange(.init(name: NSText.didChangeNotification, object: batchEditor))
            try press("预览导入", page: batchDetail)
            return try current()
        }
        let conflicting = try pasteBatch([existing.name.lowercased(): ["command": "/usr/bin/true"], "public-batch-http": ["url": "http://127.0.0.1:55999/mcp"]])
        try press("导入 2 项", page: conflicting)
        checks["mcpBatchConflictKeepsTheReviewAndWritesNoEntries"] = try pane.currentController === conflicting &&
            text(conflicting.pageContentView).contains("同名连接器") && Data(contentsOf: registry) == originalRegistry
        try press("取消", page: conflicting)
        batchEditor.string = try encode(["mcpServers": [
            "public-batch-http": ["type": "http", "url": "http://127.0.0.1:55999/mcp"],
            "public-batch-stdio": ["command": "/usr/bin/true", "env": ["PUBLIC_BATCH_TOKEN": secret]]
        ]])
        batchManager.textDidChange(.init(name: NSText.didChangeNotification, object: batchEditor))
        try press("预览导入", page: batchDetail)
        let ready = try current()
        try press("导入 2 项", page: ready)
        let savedRegistry = try Data(contentsOf: registry)
        let servers = try JSONDecoder().decode([AgentMCPServer].self, from: savedRegistry)
        let added = servers.filter { ["public-batch-http", "public-batch-stdio"].contains($0.name) }
        checks["mcpBatchSavesBothDisabledInTheUserScopeAndReturnsToTheList"] = pane.currentController === batchManager && host.attachedSheet == nil &&
            added.count == 2 && added.allSatisfy { !$0.enabled && $0.workspace == nil } &&
            added.contains { $0.name == "public-batch-http" && $0.url == "http://127.0.0.1:55999/mcp" && $0.configured == true }
        checks["mcpBatchKeepsCredentialNamesWithoutPersistingImportedValues"] = !String(decoding: savedRegistry, as: UTF8.self).contains(secret) &&
            added.contains { $0.name == "public-batch-stdio" && $0.command == "/usr/bin/true" && $0.environmentKeys == ["PUBLIC_BATCH_TOKEN"] && $0.configured == false }
        pane.finish()
        return checks
    }
}
