import AppKit

@MainActor extension AppDelegate {
    private struct MCPSettingsFixture: Codable {
        let windows: [String: String], tasks: [String: String]
        let http: String, program: String, registry: String
    }

    func runMCPSettingsRecoveryCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let fixtureFile = output.appendingPathComponent("mcp-settings-fixture.json")
        let invalidTimeout = "60000_PUBLIC_INVALID"
        let body = "{\n  \"name\": \"Local JSON Draft\",\n  \"type\": \"stdio\",\n  \"command\": \"/bin/echo\",\n  \"timeoutSeconds\": 0,\n  \"args\": [\n" +
            (0..<82).map { "    \"PUBLIC_RECOVERY_LINE_\($0) 中文\"" }.joined(separator: ",\n") + "\n  ],\n  \"env\": {}\n}\n"
        let marker = (body as NSString).range(of: "PUBLIC_RECOVERY_LINE_75")
        let dummy = "PUBLIC_FIXTURE_UNMASKED_045"
        var checks: [String: Bool] = [:], modelRequests = 0, failure = ""
        defer {
            let report: [String: Any] = ["stage": stage, "checks": checks, "error": failure, "appPID": getpid(), "modelRequests": modelRequests,
                                         "success": failure.isEmpty && !checks.isEmpty && checks.values.allSatisfy { $0 } && modelRequests == 0]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(stage + "-mcp-settings-report.json"))
        }

        func find<T: NSView>(_ type: T.Type, in root: NSView?, where predicate: (T) -> Bool) throws -> T {
            guard let root else { throw PetError("连接器验收缺少窗口") }
            if let node = root as? T, predicate(node) { return node }
            for child in root.subviews { if let match = try? find(type, in: child, where: predicate) { return match } }
            throw PetError("连接器验收缺少控件 \(type)")
        }
        func view<T: NSView>(_ type: T.Type, _ label: String, in window: ControlWindow) throws -> T {
            try find(type, in: window.window?.contentView) { $0.accessibilityLabel() == label && !$0.isHiddenOrHasHiddenAncestor }
        }
        func setField(_ field: NSTextField, _ value: String) {
            field.stringValue = value
            let notice = Notification(name: NSControl.textDidChangeNotification, object: field)
            field.delegate?.controlTextDidChange?(notice)
        }
        func choose(_ label: String, _ value: Int, in window: ControlWindow) throws {
            let control = try view(NSSegmentedControl.self, label, in: window)
            guard let action = control.action else { throw PetError("连接器验收缺少页签操作") }
            control.selectedSegment = value; NSApp.sendAction(action, to: control.target, from: control)
        }
        func click(_ title: String, in window: ControlWindow) throws {
            let button = try find(NSButton.self, in: window.window?.contentView) { $0.title == title && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
            button.performClick(nil)
        }
        func showCatalog(_ window: ControlWindow) throws -> AgentMCPWindow {
            guard window.showSettingsCategory("extensions") else { throw PetError("扩展设置未打开") }
            try window.checkSelectSettingsRecoveryPage("mcp")
            guard let manager = window.settingsRecoveryControllers.first as? AgentMCPWindow else { throw PetError("连接器目录未打开") }
            return manager
        }
        func resizeAndFocus(_ window: ControlWindow, wide: Bool) {
            window.window?.setContentSize(NSSize(width: wide ? 1200 : 780, height: wide ? 774 : 540))
            window.window?.makeKeyAndOrderFront(nil); window.window?.contentView?.layoutSubtreeIfNeeded()
            window.settingsRecoveryControllers.last?.settingsDidAppear()
        }
        func restoreWindow(_ key: String, of fixture: MCPSettingsFixture) throws -> ControlWindow {
            guard let window = taskControls.first(where: { $0.workspaceSession?.id == fixture.windows[key] }) else { throw PetError("原窗口未出现：" + key) }
            return window
        }
        func encoded(_ fields: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
        }

        do {
            ensureAgent()
            guard let store = agentStore, let runtime = agentRuntime else { throw PetError("连接器验收缺少任务服务") }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("连接器设置验收禁止模型请求") }
            NSApp.activate(ignoringOtherApps: true)
            if stage == "scoped-catalog" {
                let directory = output.appendingPathComponent("华东库存项目", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let service = store.mcp, plugins = store.extensions.plugins
                let name = "Public Inventory · 公开库存清单"
                var project = AgentMCPServer(name: name, type: "stdio", command: "/bin/echo", enabled: false)
                project.workspace = directory.path
                try service.addImported(project)
                func document(_ name: String, timeout: Double = 60) throws -> String {
                    try encoded(["name": name, "type": "stdio", "command": "/bin/echo", "args": [], "env": [:], "timeoutSeconds": timeout])
                }
                let user = try service.save(document(name)), controlServer = try service.save(document("其他用户连接器"))
                for pluginName in ["public-scope-fixture", "public-user-scope-fixture"] {
                    let package = output.appendingPathComponent(pluginName, isDirectory: true)
                    let manifest = package.appendingPathComponent(".qoder-plugin/plugin.json")
                    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(encoded(["name": pluginName, "version": "1.0.0",
                        "mcpServers": ["fixture": ["type": "stdio", "command": "/bin/echo"]]]).utf8).write(to: manifest)
                    let inspected = try await plugins.inspect(package)
                    _ = try plugins.install(inspected)
                    if pluginName == "public-scope-fixture" { _ = try plugins.install(inspected, workspace: directory.path) }
                }

                let task = store.create(title: "连接器列表范围核对", workspace: directory.path)
                store.update(task) { $0.draft = "连接器范围核对的原任务草稿。" }
                control.showAgentTask(task)
                let manager = try showCatalog(control)
                resizeAndFocus(control, wide: false)
                let catalog = try view(NSTableView.self, "MCP 连接器列表", in: control)
                let search = try view(NSSearchField.self, "搜索连接器", in: control)
                func filter(_ text: String) {
                    search.stringValue = text
                    if let action = search.action { NSApp.sendAction(action, to: search.target, from: search) }
                    control.window?.contentView?.layoutSubtreeIfNeeded()
                }
                func entry(_ identity: String) throws -> NSButton {
                    try find(NSButton.self, in: catalog) { $0.identifier?.rawValue == identity && $0.accessibilityLabel()?.hasPrefix("配置连接器 ") == true }
                }
                filter(name)
                let userEntry = try entry(user.id), projectEntry = try entry(project.id)
                checks["sameNameRowsAnnounceDifferentScopes"] = catalog.numberOfRows == 3 && userEntry.accessibilityLabel() == "配置连接器 用户 · " + name &&
                    projectEntry.accessibilityLabel() == "配置连接器 项目 · 华东库存项目 · " + name
                checks["projectRowShowsVisibleScopeAndExactLocation"] = try find(NSTextField.self, in: catalog, where: { $0.stringValue == "项目 · 华东库存项目 · 本机程序" }).visibleRect.width > 70 &&
                    projectEntry.superview?.toolTip?.contains(directory.path) == true
                filter("华东库存项目")
                guard let projectPlugin = service.availableServers(workspace: directory.path).first(where: {
                    $0.plugin != nil && AgentMCPSelection.sourceWorkspace($0) == directory.path
                }) else { throw PetError("缺少项目插件连接器") }
                checks["projectSearchFindsOnlyProjectConnectorAndPlugin"] = try catalog.numberOfRows == 4 && entry(project.id).isEnabled && entry(projectPlugin.id).isEnabled
                filter("用户插件")
                checks["pluginScopesAreSearchable"] = try catalog.numberOfRows == 2 && find(NSTextField.self, in: catalog, where: { $0.stringValue == "用户插件 · 本机程序 · public-user-scope-fixture" }).visibleRect.width > 70
                filter("public-scope-fixture")
                checks["projectPluginStillOverridesSameInstalledUserPlugin"] = try catalog.numberOfRows == 2 && entry(projectPlugin.id).isEnabled
                let otherProjects = (1...18).map { index in
                    var server = project
                    server.id = UUID().uuidString; server.revision = UUID().uuidString
                    server.name = "Public Archive \(index)"
                    return server
                }
                try service.addImportedBatch(otherProjects, checking: directory.path)
                filter("项目 · 华东库存项目")
                guard let scroll = catalog.enclosingScrollView else { throw PetError("缺少连接器列表滚动区域") }
                AgentSettingsRecovery.restoreScroll(10_000, to: scroll)
                let originalY = scroll.documentVisibleRect.minY
                try entry(project.id).performClick(nil)
                guard let detail = control.settingsRecoveryControllers.last, detail !== manager else { throw PetError("项目连接器未打开") }
                let timeout = try view(NSTextField.self, "MCP 超时毫秒", in: control)
                setField(timeout, "72500")
                let userFile = service.profile.appendingPathComponent("extensions/mcp.json")
                let projectFile = service.profile.appendingPathComponent("extensions/mcp-projects.json")
                let originalUser = try Data(contentsOf: userFile)
                try click("保存", in: control); await wait(0.10)
                let edited = try JSONDecoder().decode([AgentMCPServer].self, from: Data(contentsOf: projectFile))
                guard let original = edited.first(where: { $0.id == project.id }) else { throw PetError("找不到保存后的项目连接器") }
                checks["sameNameProjectSavesOnlyItsOriginalRecord"] = try edited.count == 19 && original.workspace == directory.path && original.name == name &&
                    original.revision != project.revision && original.timeoutSeconds == 72.5 && Data(contentsOf: userFile) == originalUser &&
                    edited.filter { $0.id != project.id }.map(\.id).sorted() == otherProjects.map(\.id).sorted()
                let savedProject = try Data(contentsOf: projectFile)
                do { _ = try service.save(document(name)); checks["duplicateCreationRemainsBlocked"] = false }
                catch { checks["duplicateCreationRemainsBlocked"] = error.localizedDescription.contains("同名") }
                do {
                    _ = try service.save(document(controlServer.name), id: project.id, expectedRevision: original.revision, workspace: directory.path)
                    checks["conflictingRenameRemainsBlocked"] = false
                } catch { checks["conflictingRenameRemainsBlocked"] = error.localizedDescription.contains("同名") }
                checks["rejectedChangesPreserveBothSources"] = try Data(contentsOf: projectFile) == savedProject && Data(contentsOf: userFile) == originalUser
                detail.close(); await wait(0.10)
                checks["catalogReturnsToExactProjectRowAndFilter"] = try control.settingsRecoveryControllers.last === manager && search.stringValue == "项目 · 华东库存项目" &&
                    catalog.selectedRow == 19 && catalog.row(for: entry(project.id)) == catalog.selectedRow && control.window?.firstResponder === catalog
                checks["catalogReturnsToItsPreviousScrollOffset"] = originalY > 600 && abs(scroll.documentVisibleRect.minY - originalY) < 1 &&
                    AgentSettingsRecovery.selectionIsVisible(in: catalog)
                checks["originalTaskDraftRemains"] = store.task(task)?.draft == "连接器范围核对的原任务草稿。"
                return
            }
            if stage == "removal" {
                let directory = output.appendingPathComponent("公开项目范围", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let service = store.mcp
                let oauth = try service.save(encoded(["name": "Public Inventory Connector · 公开库存长连接器名称", "type": "http", "url": "https://example.com/mcp", "oauthClientID": "public-registered"]))
                var project = AgentMCPServer(name: "公开项目连接器", type: "stdio", command: "/bin/echo", enabled: false)
                project.workspace = directory.path
                try service.addImported(project)
                let credentials = PetKeychain(service: "com.xjs.bluefatfish.mcp.review-check",
                    configurationFile: output.appendingPathComponent("mcp-credential-fixture.json"), migrateLegacy: false)
                let grant = "mcp-" + oauth.id + "-" + oauth.revision
                let receipt = "PUBLIC_OAUTH_GRANT_FOR_REMOVAL"
                try credentials.write(receipt, account: grant)
                let task = store.create(title: "连接器移除审阅", workspace: directory.path)
                store.update(task) { $0.draft = "原任务草稿" }
                control.showAgentTask(task)
                let manager = try showCatalog(control)
                resizeAndFocus(control, wide: false)
                let narrow = control.window?.frame.size
                manager.selectServer(oauth.id)
                await wait(0.1)
                checks["longConnectorOpensAtTheExistingMinimumWindowSize"] = narrow == NSSize(width: 780, height: 540) &&
                    control.window?.frame.size == narrow && control.settingsRecoveryControllers.last?.detailHeading?.title == oauth.name
                let host = control.window
                func review(_ title: String) throws -> AgentSettingsPageController {
                    let more = try view(NSPopUpButton.self, "连接器更多操作", in: control)
                    guard let item = more.menu?.item(withTitle: title), let action = item.action,
                          item.isEnabled, NSApp.sendAction(action, to: item.target, from: item),
                          let review = control.settingsRecoveryControllers.last as? AgentSettingsDetailPage,
                          review.isPageVisible else { throw PetError("连接器移除未进入设置右侧") }
                    return review
                }
                let stale = try review("移除本机授权")
                await wait(0.1)
                let impact = try view(NSTextField.self, "移除影响", in: control)
                checks["authorizationReviewKeepsSettingsAndNamesTheEffect"] = stale.presentingWindow === host && stale.window?.isVisible == false &&
                    host?.attachedSheet == nil && host?.agentDialog == nil && stale.detailHeading?.scope == "用户" && impact.stringValue.contains("重新授权")
                checks["authorizationReviewFocusesCancel"] = (host?.firstResponder as? NSButton)?.title == "取消"
                checks["longConnectorReviewKeepsWindowSize"] = host?.frame.size == narrow
                checks["reviewKeepsOriginalGrantUntilConfirmed"] = try credentials.read(grant) == receipt
                try service.setEnabled(oauth.id, false)
                try click("移除授权", in: control)
                let invalid = try view(NSTextField.self, "连接器移除状态", in: control)
                let disabled = try find(NSButton.self, in: host?.contentView) { $0.title == "移除授权" }
                checks["changedConnectorDisablesTheOldReviewAndKeepsGrant"] = try control.settingsRecoveryControllers.last === stale && !disabled.isEnabled &&
                    invalid.stringValue.contains("连接器已变化") && credentials.read(grant) == receipt
                try click("取消", in: control)
                await wait(0.1)
                checks["cancelRestoresLongConnectorAtOriginalWindowSize"] = host?.frame.size == narrow && control.settingsRecoveryControllers.last?.detailHeading?.title == oauth.name
                _ = try review("移除本机授权"); try click("移除授权", in: control)
                checks["confirmedAuthorizationClearsGrantAndReturnsToConnector"] = try credentials.read(grant).isEmpty &&
                    service.availableServers(workspace: nil).first { $0.id == oauth.id }?.name == oauth.name &&
                    control.settingsRecoveryControllers.last?.detailHeading?.title == oauth.name

                let detail = control.settingsRecoveryControllers.last
                detail?.close(); manager.selectServer(project.id)
                let timeout = try view(NSTextField.self, "MCP 超时毫秒", in: control)
                let pendingValue = "73000"; let range = NSRange(location: 1, length: 2)
                setField(timeout, pendingValue); host?.makeFirstResponder(timeout)
                (timeout.currentEditor() as? NSTextView)?.setSelectedRange(range)
                let userRegistry = service.profile.appendingPathComponent("extensions/mcp.json")
                let projectRegistry = service.profile.appendingPathComponent("extensions/mcp-projects.json")
                let originalUser = try Data(contentsOf: userRegistry), originalProject = try Data(contentsOf: projectRegistry)
                let removal = try review("移除")
                let path = try view(NSTextField.self, "项目路径", in: control)
                let consequence = try view(NSTextField.self, "移除影响", in: control)
                checks["projectReviewNamesExactScopeAndDraftEffect"] = removal.detailHeading?.scope == "项目 · 公开项目范围" &&
                    path.stringValue == directory.path && consequence.stringValue.contains("未保存的修改")
                let route = try control.captureSettingsRecovery()
                checks["restartKeepsParentDraftAndRequiresFreshRemovalReview"] = route?.pages.map(\.kind) == ["mcp", "mcp-detail"] &&
                    route?.pages.last.flatMap { String(data: $0.state, encoding: .utf8) }?.contains(pendingValue) == true
                try click("取消", in: control); await wait(0.1)
                checks["cancelRestoresOriginalDraftAndFieldSelection"] = timeout.stringValue == pendingValue &&
                    (timeout.currentEditor() as? NSTextView)?.selectedRange() == range && host?.firstResponder === timeout.currentEditor()
                checks["cancelKeepsBothRegistryFilesExact"] = try Data(contentsOf: userRegistry) == originalUser && Data(contentsOf: projectRegistry) == originalProject
                _ = try review("移除"); try click("移除配置", in: control)
                checks["confirmedRemovalChangesOnlyTheReviewedProjectRecord"] = try JSONDecoder().decode([AgentMCPServer].self, from: Data(contentsOf: projectRegistry)).isEmpty &&
                    Data(contentsOf: userRegistry) == originalUser && control.settingsRecoveryControllers.last === manager
                checks["removalLeavesTheOriginalTaskDraft"] = store.task(task)?.draft == "原任务草稿"
                checks["finalJournalsFlush"] = await flushWorkspaceWindows()
                return
            }
            let fixture: MCPSettingsFixture
            if stage == "seed" {
                let http = try store.mcp.save(encoded(["name": "Public OAuth Original", "type": "http", "url": "https://example.com/mcp", "oauthClientID": "public-registered", "timeoutSeconds": 60]))
                let program = try store.mcp.save(encoded(["name": "Public Program Original", "type": "stdio", "command": "/bin/echo", "args": [], "env": [:]]))
                for index in 0..<24 {
                    _ = try store.mcp.save(encoded(["name": "Public Catalog \(index)", "type": "stdio", "command": "/bin/echo", "args": [], "env": [:]]))
                }
                let tasks = Dictionary(uniqueKeysWithValues: ["form", "json", "catalog", "tools"].map { role in
                    (role, store.create(title: "连接器恢复 · " + role, workMode: .general))
                })
                for (role, id) in tasks { store.update(id) { $0.draft = "ORIGINAL_COMPOSER_" + role } }
                control.showAgentTask(tasks["form"]!); let manager = try showCatalog(control)
                manager.selectServer(http.id); resizeAndFocus(control, wide: true)
                let timeout = try view(NSTextField.self, "MCP 超时毫秒", in: control)
                setField(timeout, invalidTimeout); control.window?.makeFirstResponder(timeout)
                (timeout.currentEditor() as? NSTextView)?.setSelectedRange((invalidTimeout as NSString).range(of: "PUBLIC"))
                checks["invalidFormStateAndCaretAreCheckpointed"] = try control.captureSettingsRecovery()?.pages.map(\.kind) == ["mcp", "mcp-detail"]
                func newWindow(_ key: String) throws -> (ControlWindow, AgentMCPWindow) {
                    openTaskWindow(tasks[key]!, from: control)
                    guard let window = additionalTaskWindows.last else { throw PetError("连接器验收子窗口未打开") }
                    let manager = try showCatalog(window); resizeAndFocus(window, wide: true)
                    return (window, manager)
                }
                let (json, jsonManager) = try newWindow("json"); jsonManager.selectServer(program.id)
                try choose("MCP 配置方式", 1, in: json)
                let text = try view(NSTextView.self, "MCP 配置 JSON", in: json)
                text.string = "{\"name\":\"local\",\"bearerToken\":\"\(dummy)\"}"; text.didChangeText()
                checks["rawCredentialDraftGoesThroughExistingQuitProtection"] = try json.captureSettingsRecovery() == nil && !(json.workspaceSession?.preservedEditors.contains(ObjectIdentifier(json.settingsRecoveryControllers.last!)) ?? false)
                checks["duplicateAndEscapedCredentialKeysCannotEnterTheJournal"] = !AgentMCPConfigForm.canPreserveDocument(#"{"name":"local","bearerToken":""# + dummy + #"","bearerToken":"${KEYCHAIN}"}"#) &&
                    !AgentMCPConfigForm.canPreserveDocument(#"{"name":"local","\u0065nv":{"PUBLIC":""# + dummy + #"","PUBLIC":"${KEYCHAIN}"}}"#) &&
                    AgentMCPConfigForm.canPreserveDocument(#"{"name":"local","env":{"headers":"${KEYCHAIN}"},"bearerToken":"${INPUT_REQUIRED}"}"#)
                text.string = body; text.didChangeText(); json.window?.makeFirstResponder(text)
                json.window?.contentView?.layoutSubtreeIfNeeded()
                if let container = text.textContainer, let layout = text.layoutManager, let scroll = text.enclosingScrollView {
                    layout.ensureLayout(for: container)
                    text.setFrameSize(NSSize(width: text.frame.width, height: max(scroll.contentSize.height, layout.usedRect(for: container).maxY + text.textContainerInset.height * 2)))
                }
                text.setSelectedRange(marker); text.scrollRangeToVisible(marker)
                let (catalog, _) = try newWindow("catalog")
                let search = try view(NSSearchField.self, "搜索连接器", in: catalog)
                search.stringValue = "Public Catalog"
                if let action = search.action { NSApp.sendAction(action, to: search.target, from: search) }
                catalog.window?.makeFirstResponder(search); (search.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 7, length: 7))
                let table = try view(NSTableView.self, "MCP 连接器列表", in: catalog)
                guard let scroll = table.enclosingScrollView else { throw PetError("连接器目录没有滚动视图") }
                AgentSettingsRecovery.restoreScroll(600, to: scroll)
                checks["filteredCatalogAndLongScrollAreCheckpointed"] = table.numberOfRows == 25 && scroll.documentVisibleRect.minY > 500
                let (tools, toolManager) = try newWindow("tools"); toolManager.selectServer(http.id)
                try choose("连接器详情类型", 1, in: tools)
                guard await flushWorkspaceWindows() else { throw PetError("连接器设置未写入恢复记录") }
                let windows = ["form": control, "json": json, "catalog": catalog, "tools": tools].compactMapValues { $0.workspaceSession?.id }
                fixture = .init(windows: windows, tasks: tasks, http: http.id, program: program.id, registry: store.mcp.profile.appendingPathComponent("extensions/mcp.json").path)
                try JSONEncoder().encode(fixture).write(to: fixtureFile, options: .atomic)
                checks["fourWindowJournalsArePrivateAndPreserved"] = windows.count == 4 && taskControls.allSatisfy { $0.workspaceSession?.preservedEditors.isEmpty == false }
            } else {
                fixture = try JSONDecoder().decode(MCPSettingsFixture.self, from: Data(contentsOf: fixtureFile))
                restoreAdditionalWorkspaceWindows(); guard await flushWorkspaceWindows() else { throw PetError("连接器设置未恢复完成") }
                let form = try restoreWindow("form", of: fixture)
                if stage == "changed" {
                    checks["changedConnectorDoesNotAdoptTheSavedDraft"] = form.workspaceSession?.pendingSettingsCategory == "extensions" && form.settingsRecoveryControllers.isEmpty
                    checks["externalRevisionRemainsActive"] = try store.mcp.server(fixture.http).name == "Public OAuth External"
                } else {
                    resizeAndFocus(form, wide: false); await wait(0.10)
                    let timeout = try view(NSTextField.self, "MCP 超时毫秒", in: form)
                    checks["formKeepsInvalidValueSelectedInNarrowWindow"] = timeout.stringValue == invalidTimeout &&
                        (timeout.currentEditor() as? NSTextView)?.selectedRange() == (invalidTimeout as NSString).range(of: "PUBLIC")
                    checks["credentialsAndExistingIdentityStillMatch"] = try view(NSTextField.self, "MCP 客户端 ID", in: form).stringValue == "public-registered" &&
                        store.mcp.server(fixture.http).timeoutSeconds == 60
                    setField(timeout, "72000"); form.window?.makeFirstResponder(timeout)
                    let timeoutRange = NSRange(location: 1, length: 3)
                    (timeout.currentEditor() as? NSTextView)?.setSelectedRange(timeoutRange)
                    try click("保存", in: form); await wait(0.10)
                    let savedTimeout = try view(NSTextField.self, "MCP 超时毫秒", in: form)
                    checks["formSaveKeepsFieldFocusAndSelection"] = form.window?.firstResponder === savedTimeout.currentEditor() &&
                        (savedTimeout.currentEditor() as? NSTextView)?.selectedRange() == timeoutRange
                    checks["saveAfterContinuationUpdatesOnlyTheOriginalConnector"] = try store.mcp.server(fixture.http).timeoutSeconds == 72 && store.mcp.server(fixture.program).timeoutSeconds == 60

                    let json = try restoreWindow("json", of: fixture); resizeAndFocus(json, wide: false); await wait(0.10)
                    let text = try view(NSTextView.self, "MCP 配置 JSON", in: json)
                    checks["jsonKeepsExactDraftRangeFocusAndScroll"] = text.string == body && text.selectedRange() == marker && json.window?.firstResponder === text &&
                        (text.enclosingScrollView?.documentVisibleRect.minY ?? 0) > 300
                    let corrected = body.replacingOccurrences(of: "\"timeoutSeconds\": 0", with: "\"timeoutSeconds\": 85")
                    text.string = corrected; text.didChangeText()
                    let selection = (corrected as NSString).range(of: "PUBLIC_RECOVERY_LINE_75")
                    text.setSelectedRange(selection); text.scrollRangeToVisible(selection)
                    try click("保存", in: json); await wait(0.10)
                    checks["safeJsonSaveKeepsExactFormattingAndSelection"] = text.string == corrected && text.selectedRange() == selection &&
                        json.window?.firstResponder === text && (text.enclosingScrollView?.documentVisibleRect.minY ?? 0) > 300
                    checks["savedJsonReturnsCorrectServerAndLastArgument"] = try store.mcp.server(fixture.program).timeoutSeconds == 85 &&
                        store.mcp.server(fixture.program).args.last == "PUBLIC_RECOVERY_LINE_81 中文"
                    text.string = corrected.replacingOccurrences(of: "\"env\": {}", with: "\"env\": {\"PUBLIC_TEST\": \"\(dummy)\"}")
                    text.didChangeText(); try click("保存", in: json)
                    checks["savingCredentialsReplacesRawTextWithTheMaskedDocument"] = try text.string == store.mcp.document(store.mcp.server(fixture.program)) &&
                        text.string.contains(AgentMCP.placeholder) && !text.string.contains(dummy) && text.undoManager?.canUndo != true

                    let catalog = try restoreWindow("catalog", of: fixture); resizeAndFocus(catalog, wide: false); await wait(0.10)
                    let search = try view(NSSearchField.self, "搜索连接器", in: catalog)
                    let table = try view(NSTableView.self, "MCP 连接器列表", in: catalog)
                    checks["catalogKeepsFilterAndScrollAfterRestart"] = search.stringValue == "Public Catalog" && table.numberOfRows == 25 &&
                        abs((table.enclosingScrollView?.documentVisibleRect.minY ?? 0) - 600) < 4
                    let tools = try restoreWindow("tools", of: fixture); resizeAndFocus(tools, wide: false); await wait(0.10)
                    checks["toolTabDoesNotReconnectOnRestart"] = try view(NSSegmentedControl.self, "连接器详情类型", in: tools).selectedSegment == 1 &&
                        find(NSButton.self, in: tools.window?.contentView) { $0.title == "授权并连接" && !$0.isHiddenOrHasHiddenAncestor }.isEnabled
                }
            }
            checks["originalTaskMessagesAndDraftsRemainExact"] = fixture.tasks.allSatisfy { role, id in
                store.task(id)?.messages.isEmpty == true && store.task(id)?.draft == "ORIGINAL_COMPOSER_" + role
            }
            checks["finalJournalsFlush"] = await flushWorkspaceWindows()
        } catch { failure = error.localizedDescription }
    }
}
