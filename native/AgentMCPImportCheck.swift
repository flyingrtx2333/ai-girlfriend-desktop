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
}
