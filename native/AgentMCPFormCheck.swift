import AppKit
import Darwin

@MainActor enum AgentMCPFormCheck {
    private static func find<T: NSView>(_ type: T.Type, in view: NSView?, matching: (T) -> Bool) -> T? {
        guard let view else { return nil }; if let value = view as? T, matching(value) { return value }
        for child in view.subviews { if let value = find(type, in: child, matching: matching) { return value } }; return nil
    }
    private static func control<T: NSView>(_ type: T.Type, _ label: String, page: AgentSettingsPageController) throws -> T {
        guard let value = find(type, in: page.pageContentView, matching: { $0.accessibilityLabel() == label }) else { throw PetError("缺少连接器表单控件：" + label) }; return value
    }
    private static func press(_ label: String, page: AgentSettingsPageController) throws {
        guard let button = find(NSButton.self, in: page.pageContentView, matching: { $0.isEnabled && ($0.title == label || $0.accessibilityLabel() == label) }) else { throw PetError("缺少连接器表单操作：" + label) }; button.performClick(nil)
    }
    private static func edit(_ label: String, _ value: String, page: AgentSettingsPageController) throws {
        let field = try control(NSTextField.self, label, page: page); field.stringValue = value; field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    private static func mode(_ index: Int, page: AgentSettingsPageController) throws {
        let control = try control(NSSegmentedControl.self, "MCP 配置方式", page: page); control.selectedSegment = index; NSApp.sendAction(control.action!, to: control.target, from: control)
    }
    private static func object(_ text: String) throws -> [String: Any] { guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw PetError("缺少表单 JSON") }; return value }
    private static func encode(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
    static func run(tasks: AgentStore, taskID: String, pane: AgentSettingsPageHost, host: NSWindow, output: URL) async throws -> [String: Bool] {
        let service = tasks.mcp, workspace = tasks.task(taskID)?.workspace, manager = AgentMCPWindow(service: tasks.mcp, workspace: tasks.task(taskID)?.workspace)
        let file = service.profile.appendingPathComponent("extensions/mcp.json"), initial = try Data(contentsOf: file)
        guard pane.show(category: "mcp", identity: "mcp-form-check", scope: "设置项目", make: { _ in manager }) else { throw PetError("无法进入连接器表单") }
        let add = try control(NSPopUpButton.self, "新建 MCP 连接器", page: manager), item = add.menu!.items.first { $0.representedObject as? String == "stdio" }!
        NSApp.sendAction(item.action!, to: item.target, from: item)
        guard let detail = pane.currentController, detail !== manager else { throw PetError("未进入表单子页") }
        let editor = try control(NSTextView.self, "MCP 配置 JSON", page: detail), kinds = try control(NSSegmentedControl.self, "MCP 配置方式", page: detail)
        var checks: [String: Bool] = [:]
        checks["mcpFormIsDefaultAndJSONRemainsAvailable"] = try kinds.selectedSegment == 0 && !control(NSScrollView.self, "MCP 配置表单", page: detail).isHiddenOrHasHiddenAncestor && editor.isHiddenOrHasHiddenAncestor
        let formScroll = try control(NSScrollView.self, "MCP 配置表单", page: detail), originalSize = host.contentView!.frame.size
        host.setContentSize(NSSize(width: 420, height: 360)); pane.layoutSubtreeIfNeeded()
        guard let formDocument = formScroll.documentView, let saveButton = find(NSButton.self, in: detail.pageContentView, matching: { $0.title == "保存" }), let outer = find(NSScrollView.self, in: pane, matching: { $0.accessibilityLabel() == "设置内容" }) else { throw PetError("缺少表单滚动或保存区域") }
        checks["mcpLongFormScrollsInsideTheNarrowSettingsViewport"] = formDocument.bounds.height > formScroll.contentView.bounds.height + 1 && (outer.documentView?.bounds.height ?? -1) <= outer.contentView.bounds.height + 1
        formScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, formDocument.bounds.height - formScroll.contentView.bounds.height))); formScroll.reflectScrolledClipView(formScroll.contentView); pane.layoutSubtreeIfNeeded()
        checks["mcpLongFormKeepsSaveVisibleAfterScrollingToTheLastField"] = formScroll.documentVisibleRect.maxY >= formDocument.bounds.maxY - 1 && saveButton.visibleRect.height >= saveButton.bounds.height - 1 && outer.contentView.bounds.minY < 1
        formScroll.contentView.scroll(to: .zero); host.setContentSize(originalSize); pane.layoutSubtreeIfNeeded()
        try edit("MCP 名称", "表单公开连接器", page: detail); try edit("MCP 命令", "true", page: detail); try edit("MCP 工作目录", workspace!, page: detail); try edit("MCP 超时毫秒", "1250", page: detail)
        for value in ["第一项 🧭", ""] { try press("添加 MCP 参数", page: detail); let index = value.isEmpty ? 2 : 1; try edit("MCP 参数 \(index) 值", value, page: detail) }
        try press("添加 MCP 环境变量", page: detail); try edit("MCP 环境变量 1 名称", "PUBLIC_VALUE", page: detail); try edit("MCP 环境变量 1 值", "公开值", page: detail)
        checks["mcpFormMasksEnvironmentValues"] = try control(NSTextField.self, "MCP 环境变量 1 值", page: detail) is NSSecureTextField
        try mode(1, page: detail); let configured = try object(editor.string)
        checks["mcpFormJSONRoundTripKeepsArgumentsEnvironmentDirectoryAndMilliseconds"] = configured["args"] as? [String] == ["第一项 🧭", ""] && configured["env"] as? [String: String] == ["PUBLIC_VALUE": "公开值"] && configured["cwd"] as? String == workspace && configured["timeoutSeconds"] as? Double == 1.25
        checks["mcpFormEditingAndModeSwitchesDoNotSave"] = try Data(contentsOf: file) == initial
        checks["mcpFormUsesTheSameBareCommandResolutionAsImportAndPlugins"] = configured["command"] as? String == "/usr/bin/true" && AgentMCP.configurationCommand("node") == "/opt/homebrew/bin/node" && AgentMCP.configurationCommand("") == "" && AgentMCP.configurationCommand("relative/program") == "relative/program"
        let locked = try AgentMCPConfigForm(document: service.document(nil), pluginLocked: true)
        checks["mcpPluginFormKeepsNameAndTransportFixed"] = find(NSTextField.self, in: locked.view, matching: { $0.accessibilityLabel() == "MCP 名称" && !$0.isEnabled }) != nil && find(NSPopUpButton.self, in: locked.view, matching: { $0.accessibilityLabel() == "MCP 传输方式" && !$0.isEnabled }) != nil
        editor.string = "{ invalid JSON"; manager.textDidChange(Notification(name: NSText.didChangeNotification, object: editor)); try mode(1, page: detail)
        checks["mcpRepeatedJSONSelectionDoesNotReplaceTheDraft"] = editor.string == "{ invalid JSON"
        try mode(0, page: detail)
        checks["mcpInvalidJSONCannotLoseDraftBySwitchingToForm"] = kinds.selectedSegment == 1 && editor.string == "{ invalid JSON" && !editor.isHiddenOrHasHiddenAncestor
        var fixed = configured; fixed["env"] = [String: String](); editor.string = try encode(fixed); manager.textDidChange(Notification(name: NSText.didChangeNotification, object: editor)); try mode(0, page: detail)
        checks["mcpCorrectedJSONReturnsToTheActualForm"] = try kinds.selectedSegment == 0 && control(NSTextField.self, "MCP 名称", page: detail).stringValue == "表单公开连接器"
        for index in 1...2 { try press("添加 MCP 环境变量", page: detail); try edit("MCP 环境变量 \(index) 名称", "SAME", page: detail); try edit("MCP 环境变量 \(index) 值", "public", page: detail) }
        try press("保存", page: detail)
        checks["mcpDuplicateEnvironmentRowsRejectSaveWithoutChangingStoredBytes"] = try Data(contentsOf: file) == initial && control(AgentSettingsStatusField.self, "MCP 保存与连接状态", page: detail).stringValue.contains("名称重复")
        try press("移除 MCP 环境变量行", page: detail); try press("移除 MCP 环境变量行", page: detail)
        try edit("MCP 超时毫秒", "999", page: detail); try press("保存", page: detail)
        checks["mcpSubSecondTimeoutRejectsSaveAndPreservesTheForm"] = try Data(contentsOf: file) == initial && control(NSTextField.self, "MCP 超时毫秒", page: detail).stringValue == "999"
        try edit("MCP 超时毫秒", "1000", page: detail); try press("保存", page: detail)
        let saved = service.availableServers(workspace: workspace).first { $0.name == "表单公开连接器" }
        checks["mcpFormSavesThroughTheServiceWithOneSecondTimeout"] = saved?.timeoutSeconds == 1 && saved?.args == ["第一项 🧭", ""] && saved?.workingDirectory == workspace && saved?.environmentKeys == []
        checks["mcpFormSavedConnectorPassesRuntimeValidation"] = saved.map { (try? service.server($0.id, workspace: workspace)) != nil } == true
        guard let saved else { throw PetError("表单配置未保存") }
        var updated = try object(service.document(saved)); updated["args"] = ["外部更新的公开参数"]
        _ = try service.save(encode(updated), id: saved.id, expectedRevision: saved.revision, workspace: workspace)
        checks["mcpCleanFormRefreshesChangedRevisionBeforeEditing"] = try control(NSTextField.self, "MCP 参数 1 值", page: detail).stringValue == "外部更新的公开参数" && find(NSTextField.self, in: detail.pageContentView, matching: { $0.accessibilityLabel() == "MCP 参数 2 值" }) == nil
        let beforePaste = try Data(contentsOf: file)
        try mode(1, page: detail)
        let standard: [String: Any] = ["mcpServers": ["粘贴本机": ["command": "true", "args": []], "粘贴 HTTP": ["url": "https://example.com/mcp", "headers": [:], "timeout": 1250]]]
        editor.string = try encode(standard); manager.textDidChange(Notification(name: NSText.didChangeNotification, object: editor)); try press("保存", page: detail)
        guard let review = pane.currentController as? AgentMCPImportPage else { throw PetError("标准 JSON 未进入审阅") }
        let list = try control(NSTableView.self, "待导入 MCP 连接器", page: review), preview = try control(NSTextView.self, "MCP 导入配置预览", page: review)
        checks["mcpPastedStandardJSONIsReviewedBeforeAnySave"] = try list.numberOfRows == 2 && Data(contentsOf: file) == beforePaste && host.attachedSheet == nil
        for i in 0..<2 { list.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false); if try object(preview.string)["name"] as? String == "粘贴 HTTP" { break } }
        checks["mcpStandardTimeoutNormalizesMillisecondsWithoutRounding"] = try object(preview.string)["timeoutSeconds"] as? Double == 1.25
        try press("载入草稿", page: review)
        checks["mcpPastedDefinitionLoadsIntoFormWithoutSaving"] = try pane.currentController === detail && kinds.selectedSegment == 0 && control(NSTextField.self, "MCP 名称", page: detail).stringValue == "粘贴 HTTP" && Data(contentsOf: file) == beforePaste
        try press("添加 MCP 请求头", page: detail); try edit("MCP 请求头 1 名称", "X-Public", page: detail); try edit("MCP 请求头 1 值", "first", page: detail)
        try press("添加 MCP 请求头", page: detail); try edit("MCP 请求头 2 名称", "x-public", page: detail); try edit("MCP 请求头 2 值", "second", page: detail); try press("保存", page: detail)
        checks["mcpDuplicateHeadersRejectCaseInsensitivelyBeforeCredentialWrites"] = try Data(contentsOf: file) == beforePaste && control(AgentSettingsStatusField.self, "MCP 保存与连接状态", page: detail).stringValue.contains("名称重复")
        try press("移除 MCP 请求头行", page: detail); try press("移除 MCP 请求头行", page: detail)
        try edit("MCP 超时毫秒", "", page: detail); try press("保存", page: detail)
        checks["mcpOptionalTimeoutUsesTheExistingDefault"] = service.availableServers(workspace: workspace).first { $0.name == "粘贴 HTTP" }?.timeoutSeconds == 60
        let beforeInvalid = try Data(contentsOf: file)
        for raw in ["true", #""not a number""#] {
            let invalid = "{\"name\":\"无效超时\",\"type\":\"stdio\",\"command\":\"/usr/bin/true\",\"args\":[],\"env\":{},\"timeoutSeconds\":" + raw + "}"
            do { _ = try service.save(invalid); checks["mcpJSONRejectsInvalidSeconds-" + raw] = false }
            catch { checks["mcpJSONRejectsInvalidSeconds-" + raw] = try Data(contentsOf: file) == beforeInvalid }
        }
        for (name, json) in [("empty", #"{"mcpServers":{}}"#), ("booleanTimeout", #"{"mcpServers":{"test":{"command":"true","timeout":true}}}"#), ("conflictingTimeout", #"{"mcpServers":{"test":{"command":"true","timeout":1000,"timeoutSeconds":2}}}"#), ("oversized", String(repeating: " ", count: 64_001))] {
            do { try manager.reviewImport(document: json); checks["mcpPastedJSONRejects-" + name] = false }
            catch { checks["mcpPastedJSONRejects-" + name] = try pane.currentController === detail && Data(contentsOf: file) == beforeInvalid }
        }
        let explicit = try AgentMCPImportPage(document: #"{"mcpServers":{"unsupported":{"type":"sse","url":"https://example.com/sse"}}}"#)
        checks["mcpImportNeverSilentlyConvertsAnExplicitTransport"] = try object(control(NSTextView.self, "MCP 导入配置预览", page: explicit).string)["type"] as? String == "sse"
        guard let original = service.availableServers(workspace: workspace).first(where: { $0.name == "设置连接器" }) else { throw PetError("缺少实际工具目录连接器") }
        manager.selectServer(original.id); let childPID = try await manager.connectForSettingsCheck()
        let tabs = try control(NSTabView.self, "连接器详情标签", page: detail); tabs.selectTabViewItem(at: 1)
        let tools = try control(AgentMCPToolCatalog.self, "MCP 实际工具目录", page: detail)
        guard let disclosure = find(NSButton.self, in: tools, matching: { $0.accessibilityLabel() == "展开 MCP 工具 echo" }) else { throw PetError("实际工具未显示名称") }
        disclosure.performClick(nil)
        let schema = find(NSTextField.self, in: tools, matching: { $0.accessibilityLabel() == "MCP 工具参数 echo" })
        checks["mcpActualToolCatalogExpandsNameDescriptionAndFullSchema"] = childPID.map { kill($0, 0) == 0 } == true && disclosure.state == .on && schema.map { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains("properties") } == true && find(NSTextField.self, in: tools, matching: { $0.stringValue == "Read a public value" && !$0.isHiddenOrHasHiddenAncestor }) != nil
        disclosure.performClick(nil)
        checks["mcpActualToolCatalogCollapsesWithoutExecutingTheTool"] = disclosure.state == .off && schema?.isHiddenOrHasHiddenAncestor == true
        guard let long = find(NSButton.self, in: tools, matching: { $0.accessibilityLabel() == "展开 MCP 工具 public_details" }) else { throw PetError("实际完整说明工具未显示") }; long.performClick(nil)
        checks["mcpActualToolDescriptionIsNotCutByModelCatalogLimits"] = find(NSTextField.self, in: tools, matching: { $0.stringValue == String(repeating: "完整公开说明。", count: 400) && !$0.isHiddenOrHasHiddenAncestor }) != nil
        checks["mcpFormCheckLeavesTheManagerNormally"] = pane.leave()
        if let childPID { for _ in 0..<30 { if kill(childPID, 0) != 0 { break }; try await Task.sleep(for: .milliseconds(50)) } }
        checks["mcpToolCatalogCheckReleasesItsActualOwnedProcess"] = childPID.map { kill($0, 0) != 0 } == true
        try JSONSerialization.data(withJSONObject: ["modelRequests": 0, "actualProcess": childPID.map { Int($0) } ?? -1, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mcp-form-check.json"))
        return checks
    }
}
