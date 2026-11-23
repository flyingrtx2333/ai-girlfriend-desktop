import AppKit
import Darwin

@MainActor extension AppDelegate {
    func prepareSettingsPagesCheck(_ output: URL, tasks: AgentStore) async throws -> String {
        let fm = FileManager.default, project = output.appendingPathComponent("设置项目")
        try fm.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("# 设置页面验收\n公开的本机配置示例。\n".utf8).write(to: project.appendingPathComponent("README.md"))
        try Data("保留当前项目文件。\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        let id = tasks.create(title: "设置页面验收", workspace: project.path)
        let role = AgentProfile(name: "设置审阅员", description: "核对公开文档", instructions: "设置角色原文：只读公开文档。", tools: ["read_file", "list_agents", "delegate_task"], readOnly: true, network: false, enabled: false)
        let member = AgentProfile(name: "设置助手", description: "核对引用", instructions: "只读核对来源。", tools: ["read_file"], readOnly: true, network: false, enabled: false)
        try tasks.agents.save(tasks.agents.encode([role, member]), expectedHash: tasks.agents.document().1)
        let team = AgentTeam(name: "设置协作组", description: "公开文档核对", instructions: "设置团队原文。", leaderID: role.id, memberIDs: [member.id], enabled: false)
        try tasks.teams.save(tasks.teams.encode([team]), expectedHash: tasks.teams.document().1, store: tasks, workspace: project.path)
        let memory = try AgentMemory.snapshot(.global, store: tasks, taskID: id)
        _ = try AgentMemory.save(.global, content: "设置记忆原文：公开配置。\n", expectedHash: memory.hash, store: tasks, taskID: id)
        guard let task = tasks.task(id) else { throw PetError("设置任务未创建") }
        _ = try tasks.rules.create(name: "settings-rule", text: AgentRuleDocument.text(name: "settings-rule", trigger: .always, description: "", patterns: [], body: "设置规则正文。"), project: false, task: task)
        let hook = try tasks.hooks.document(project: false, workspace: project.path)
        try tasks.hooks.save(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#, project: false, workspace: project.path, expectedHash: hook.1)
        let source = output.appendingPathComponent("公开扩展"), skill = source.appendingPathComponent("settings-skill")
        try fm.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: settings-skill\ndescription: 设置示例技能\n---\n本地技能原文。\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        _ = try await tasks.extensions.importItem(skill, kind: .skill, project: false, workspace: project.path)
        let command = source.appendingPathComponent("settings-command.md")
        try Data("---\nname: settings-command\ndescription: 设置示例指令\n---\n本地指令原文。\n".utf8).write(to: command)
        _ = try await tasks.extensions.importItem(command, kind: .command, project: false, workspace: project.path)
        let package = source.appendingPathComponent("zz-settings-demo"), metadata = package.appendingPathComponent(".qoder-plugin")
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        try fm.createDirectory(at: package.appendingPathComponent("skills/demo"), withIntermediateDirectories: true)
        try Data(#"{"name":"zz-settings-demo","version":"1.0.0","description":"设置插件示例"}"#.utf8).write(to: metadata.appendingPathComponent("plugin.json"))
        try Data("---\nname: demo\ndescription: 设置插件技能\n---\n设置插件原文。\n".utf8).write(to: package.appendingPathComponent("skills/demo/SKILL.md"))
        try Data("设置插件原文。\n".utf8).write(to: package.appendingPathComponent("README.md"))
        _ = try tasks.extensions.plugins.install(await tasks.extensions.plugins.inspect(package))
        let server = output.appendingPathComponent("settings-echo.mjs"), pidFile = output.appendingPathComponent("settings-mcp.pid")
        let program = #"""
        import readline from 'node:readline';
        import fs from 'node:fs';
        fs.writeFileSync(process.argv[2], String(process.pid));
        const input = readline.createInterface({input: process.stdin});
        input.on('line', line => {
          const request = JSON.parse(line);
          if (!Object.hasOwn(request, 'id')) return;
          let result = {};
          if (request.method === 'initialize') result = {protocolVersion: request.params.protocolVersion, capabilities: {tools: {}}, serverInfo: {name: 'settings-local-echo', version: '1.0.0'}};
          if (request.method === 'tools/list') result = {tools: [{name: 'echo', description: 'Read a public value', inputSchema: {type: 'object', properties: {value: {type: 'string'}}}}, {name: 'public_details', description: '完整公开说明。'.repeat(400), inputSchema: {type: 'object', properties: {}}}]};
          if (request.method === 'tools/call') result = {content: [{type: 'text', text: String(request.params.arguments?.value ?? '')}]};
          process.stdout.write(JSON.stringify({jsonrpc: '2.0', id: request.id, result}) + '\n');
        });
        input.on('close', () => process.exit(0));
        """#
        try Data(program.utf8).write(to: server)
        let config: [String: Any] = ["name": "设置连接器", "type": "stdio", "command": "/opt/homebrew/bin/node", "args": [server.path, pidFile.path], "env": [:], "timeoutSeconds": 10]
        let connector = try tasks.mcp.save(String(decoding: JSONSerialization.data(withJSONObject: config), as: UTF8.self))
        let fixture: [String: Any] = ["taskID": id, "workspace": project.path, "connectorID": connector.id, "roleID": role.id, "teamID": team.id, "modelRequests": 0]
        try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("settings-fixtures.json"))
        return id
    }

    func prepareSettingsPluginHistory(_ output: URL, tasks: AgentStore) async throws -> AgentPluginInstallation {
        let service = tasks.extensions.plugins
        let source = output.appendingPathComponent("公开扩展/zz-settings-demo")
        let manifest = source.appendingPathComponent(".qoder-plugin/plugin.json")
        var installed = try service.installation("zz-settings-demo")
        for index in 1...8 {
            let metadata = ["name": "zz-settings-demo", "description": "设置插件示例", "version": "1.0.\(index)"]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: manifest)
            try Data("设置插件原文。公开版本 1.0.\(index)\n".utf8).write(to: source.appendingPathComponent("README.md"))
            installed = try service.update(try await service.inspect(source), replacing: installed)
        }
        return installed
    }

    private func checkSettingsPluginHistory(_ output: URL, tasks: AgentStore, workspace: String?, pane: AgentSettingsPageHost, host: NSWindow) async throws -> [String: Bool] {
        let service = tasks.extensions.plugins
        var checks: [String: Bool] = [:]
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func open(_ identity: String) throws -> AgentSettingsPageController {
            let manager = AgentPluginWindow(store: tasks, workspace: workspace)
            guard pane.show(category: "extensions", identity: identity, scope: "用户设置", make: { _ in manager }),
                  let root = manager.pageContentView,
                  let catalog = descendants(root).compactMap({ $0 as? AgentSettingsCatalogTable }).first else { throw PetError("没有插件目录") }
            root.layoutSubtreeIfNeeded()
            let row = (0..<catalog.numberOfRows).compactMap { catalog.view(atColumn: 0, row: $0, makeIfNecessary: true) }.first { ($0 as? NSTableCellView)?.textField?.stringValue == "zz-settings-demo" }
            guard let row, let open = descendants(row).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "配置 zz-settings-demo" }) else { throw PetError("没有示例插件的详情动作") }
            open.performClick(nil)
            guard let detail = pane.currentController, detail !== manager, let content = detail.pageContentView,
                  let more = descendants(content).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "插件更多操作" }),
                  let history = more.itemArray.first(where: { $0.title == "历史版本" && $0.isEnabled }), let action = history.action else { throw PetError("没有可用的历史版本入口") }
            NSApp.sendAction(action, to: history.target, from: history)
            guard let page = pane.currentController, page !== detail else { throw PetError("历史版本未打开") }
            return page
        }
        func list(_ page: AgentSettingsPageController) throws -> AgentSettingsCatalogTable {
            guard let content = page.pageContentView, let table = descendants(content).compactMap({ $0 as? AgentSettingsCatalogTable }).first else { throw PetError("缺少历史版本表格") }
            return table
        }
        let empty = try open("history-empty"), table = try list(empty)
        let countVisible = empty.pageContentView.map { descendants($0).contains { $0.identifier?.rawValue == "settings-catalog-count" && !$0.isHiddenOrHasHiddenAncestor } } ?? true
        checks["pluginHistoryEmptyHasCurrentVersionAndNoRedundantCount"] = table.numberOfRows == 0 && table.emptyCard?.isHidden == false && empty.detailHeading?.title == "历史版本 · zz-settings-demo" && empty.detailHeading?.scope == "当前 1.0.0" && empty.settingsHostWindow === host && !countVisible
        empty.close()
        let installed = try await prepareSettingsPluginHistory(output, tasks: tasks)
        let page = try open("history-filled"), rows = try list(page)
        let before = installed.receiptHash
        checks["pluginHistoryListsActualBackupsNewestFirst"] = rows.numberOfRows == 8 && page.detailHeading?.scope == "当前 1.0.8" && (rows.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "1.0.7"
        rows.selectRowIndexes(IndexSet(integer: 7), byExtendingSelection: false); rows.scrollRowToVisible(7); rows.onOpen?()
        guard let preview = pane.currentController as? AgentPluginReviewPage, let content = preview.pageContentView,
              let cancel = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "取消" }) else { throw PetError("缺少历史版本恢复审阅") }
        checks["openingHistoryReviewKeepsActualPluginBytes"] = try service.installation(installed.id).receiptHash == before && preview.settingsHostWindow === host
        cancel.performClick(nil)
        checks["cancelHistoryReviewReturnsToSameRevision"] = try pane.currentController === page && rows.selectedRow == 7 && service.installation(installed.id).receiptHash == before
        rows.onOpen?()
        guard let review = pane.currentController as? AgentPluginReviewPage, let reviewContent = review.pageContentView,
              let restore = descendants(reviewContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "恢复并停用" && $0.isEnabled }) else { throw PetError("缺少恢复并停用动作") }
        restore.performClick(nil)
        let restored = try service.installation(installed.id)
        checks["historyReviewRestoresActualVersionAndRefreshesHistory"] = pane.currentController === page && restored.metadata.version == "1.0.0" && !restored.enabled && restored.receiptHash != before && page.detailHeading?.scope == "当前 1.0.0" && rows.numberOfRows == 9
        return checks
    }

    func runSettingsPagesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], modelRequests = 0
        do {
            ensureAgent()
            guard let tasks = agentStore, let agentRuntime else { throw PetError("缺少原生设置工作台") }
            agentRuntime.modelRequestCheck = { modelRequests += 1; throw PetError("设置审阅验收禁止模型请求") }
            let id = try await prepareSettingsPagesCheck(output, tasks: tasks), workspace = tasks.task(id)?.workspace
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let pane = AgentSettingsPageHost(); host.contentView = pane
            host.makeKeyAndOrderFront(nil)
            func visibleContentWindows() -> Set<ObjectIdentifier> {
                Set(NSApp.windows.filter { $0.isVisible && $0 !== pet && $0 !== statusItem?.button?.window }.map(ObjectIdentifier.init))
            }
            let visible = visibleContentWindows()
            func windows() -> [[String: Any]] {
                NSApp.windows.filter(\.isVisible).map { ["number": $0.windowNumber, "title": $0.title, "class": String(describing: type(of: $0)), "pet": $0 === pet, "bubble": $0 === bubble, "statusItem": $0 === statusItem?.button?.window, "fixtureHost": $0 === host] }
            }
            report["visibleWindowsBefore"] = windows()
            var windowStages: [[String: Any]] = []
            let profile = tasks.directory.deletingLastPathComponent()
            let memoryChecks = try await checkMemorySettings(output)
            func fingerprints() throws -> [String: String] {
                let entries = FileManager.default.enumerator(at: profile, includingPropertiesForKeys: [.isRegularFileKey])
                var result: [String: String] = [:]
                while let url = entries?.nextObject() as? URL {
                    if ["json", "md"].contains(url.pathExtension), (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true { result[url.path] = AgentFiles.hash(try Data(contentsOf: url)) }
                }
                return result
            }
            let before = try fingerprints()
            let skill = AgentExtensionWindow(store: tasks, taskID: id); skill.prepareSettings(kind: .skill)
            let command = AgentExtensionWindow(store: tasks, taskID: id); command.prepareSettings(kind: .command)
            let mcp = AgentMCPWindow(service: tasks.mcp, workspace: workspace)
            let managers: [(String, AgentSettingsPageController, String)] = [
                ("plugins", AgentPluginWindow(store: tasks, workspace: workspace), "设置插件原文"),
                ("skills", skill, "本地技能原文"), ("commands", command, "本地指令原文"),
                ("mcp", mcp, "设置连接器"), ("hooks", AgentHookWindow(service: tasks.hooks, workspace: workspace), "/usr/bin/true"),
                ("agents", AgentProfileWindow(store: tasks, workspace: workspace), "只读"),
                ("teams", AgentTeamWindow(store: tasks, workspace: workspace), "设置团队原文"),
                ("memory", AgentRecordWindow(store: tasks, taskID: id, section: 5, memoryOnly: true), "设置记忆原文"),
                ("memory-overview", AgentMemorySettingsPage(store: tasks, taskID: id, workspace: workspace, service: AgentGeneralSettings(directory: profile)), "记忆行为"),
                ("rules", AgentRuleWindow(store: tasks, taskID: id), "设置规则正文")
            ]
            func text(_ view: NSView) -> String {
                (view as? NSTextView)?.string ?? (view as? NSTextField)?.stringValue ?? view.subviews.map(text).joined(separator: "\n")
            }
            func settingsViewport(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, scroll.accessibilityLabel() == "设置内容" { return scroll }
                for child in view.subviews { if let scroll = settingsViewport(child) { return scroll } }; return nil
            }
            func catalog(_ view: NSView?) -> AgentSettingsCatalogTable? {
                guard let view else { return nil }
                return (view as? AgentSettingsCatalogTable) ?? view.subviews.lazy.compactMap(catalog).first
            }
            func labelsFit(_ view: NSView) -> Bool {
                if let label = view as? NSTextField, !label.isHidden { return label.bounds.width + 1 >= min(360, label.intrinsicContentSize.width) }
                return view.subviews.allSatisfy(labelsFit)
            }
            var catalogChecks: [String: Bool] = [:]
            var actualTexts = true, narrowPagesStartAtTop = true, childPID: pid_t?
            for (key, manager, expected) in managers {
                guard pane.show(category: key, identity: key, scope: "设置项目", make: { _ in manager }) else { throw PetError("设置页未载入：" + key) }
                pane.layoutSubtreeIfNeeded()
                let viewport = settingsViewport(pane)
                narrowPagesStartAtTop = narrowPagesStartAtTop && viewport?.documentView?.isFlipped == true && abs(viewport?.contentView.bounds.minY ?? -1) < 0.5
                checks["embedded-" + key] = manager.presentingWindow === host && manager.pageContentView?.window === host && manager.window?.isVisible == false
                let list = catalog(manager.pageContentView)
                if let list {
                    catalogChecks[key + "CatalogOpensWithoutConfigurationForm"] = !text(manager.pageContentView!).contains(expected) && list.numberOfRows > 0 && list.bounds.width >= (manager.pageContentView?.bounds.width ?? 0) - 2
                    if let cell = list.view(atColumn: 0, row: list.selectedRow, makeIfNecessary: true) { cell.layoutSubtreeIfNeeded(); catalogChecks[key + "CatalogPublicTitlesAndDescriptionsFitAvailableSpace"] = cell.bounds.width >= 500 && labelsFit(cell) }
                    if let action = list.action { NSApp.sendAction(action, to: list.target, from: list) }; pane.layoutSubtreeIfNeeded()
                    catalogChecks[key + "CatalogActionOpensHostedDetail"] = list.selectedRow >= 0 && pane.currentController is AgentSettingsDetailPage && pane.currentController?.presentingWindow === host && pane.currentController?.pageContentView?.window === host
                }
                if let hooks = manager as? AgentHookWindow, let first = try tasks.hooks.catalog(workspace: workspace).first { hooks.selectHook(first.id) }
                for _ in 0..<30 {
                    if pane.currentController?.pageContentView.map({ text($0).contains(expected) }) == true { break }
                    await wait(0.05)
                }
                actualTexts = actualTexts && pane.currentController?.pageContentView.map { text($0).contains(expected) } == true
                if let list {
                    pane.currentController?.close(); pane.layoutSubtreeIfNeeded()
                    catalogChecks[key + "DetailBackRestoresCatalogSelectionAndFocus"] = pane.currentController === manager && list.selectedRow >= 0 && host.firstResponder === list
                }
                if key == "mcp" {
                    childPID = try await mcp.connectForSettingsCheck()
                    checks["localMCPConnectsFromHostedManager"] = childPID.map { kill($0, 0) == 0 } == true
                    do {
                        let configuration = tasks.mcp.profile.appendingPathComponent("extensions/mcp.json"), before = try Data(contentsOf: configuration)
                        guard let current = tasks.mcp.servers.first(where: { $0.name == "设置连接器" }) else { throw PetError("缺少只读保存检查的原连接器") }
                        let document = try tasks.mcp.document(current), mode = (try FileManager.default.attributesOfItem(atPath: configuration.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
                        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: configuration.path)
                        defer { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: configuration.path) }
                        func denied(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return error.localizedDescription.contains("只读") } }
                        checks["readOnlyMCPMetadataRejectsSave"] = denied { _ = try tasks.mcp.save(document, id: current.id, expectedRevision: current.revision) }
                        checks["readOnlyMCPMetadataRejectsEnableChanges"] = denied { try tasks.mcp.setEnabled(current.id, false) }
                        checks["readOnlyMCPMetadataRejectsRemoval"] = denied { try tasks.mcp.remove(current.id, revision: current.revision) }
                        checks["readOnlyMCPWritesPreserveConfigModeRevisionAndLiveSession"] = try Data(contentsOf: configuration) == before && (FileManager.default.attributesOfItem(atPath: configuration.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400 && tasks.mcp.server(current.id).revision == current.revision && childPID.map { kill($0, 0) == 0 } == true
                    }
                    pane.currentController?.close()
                    checks["returningFromMCPDetailKeepsTheOwnedConnectionAndActualStatus"] = pane.currentController === mcp && childPID.map { kill($0, 0) == 0 } == true && mcp.pageContentView.map { text($0).contains("已连接") } == true
                }
                guard pane.leave() else { throw PetError("设置页未退出：" + key) }
                windowStages.append(["page": key, "windows": windows()])
                if key == "mcp", let childPID {
                    for _ in 0..<30 { if kill(childPID, 0) != 0 { break }; await wait(0.1) }
                    checks["leavingHostedMCPStopsActualProcess"] = kill(childPID, 0) != 0
                }
            }
            checks["pagesLoadActualStoredContent"] = actualTexts
            checks["openingPagesPreservesActualConfiguration"] = try fingerprints() == before
            checks["hostingDoesNotCreateVisibleManagementWindows"] = visibleContentWindows() == visible && managers.allSatisfy { $0.1.window?.isVisible == false }
            report["visibleWindowsAfter"] = windows(); report["visibleWindowStages"] = windowStages
            checks["narrowPagesInitiallyShowTopFields"] = narrowPagesStartAtTop
            if let childPID { report["localMCPProcess"] = childPID }
            guard checks.count == managers.count + 11 else { throw PetError("设置页面基础检查缺失") }
            guard catalogChecks.count == 24 else { throw PetError("设置列表与详情检查缺失") }
            checks.merge(catalogChecks) { _, next in next }
            checks.merge(memoryChecks) { _, value in value }
            checks.merge(try AgentSaveFailureCheck.run(tasks: tasks, taskID: id, pane: pane, host: host, output: output)) { _, next in next }
            checks.merge(try AgentSettingsFormCheck.run(tasks: tasks, taskID: id, pane: pane, host: host)) { _, next in next }
            checks.merge(try await AgentPluginReviewCheck.run(tasks: tasks, taskID: id, pane: pane, host: host, output: output)) { _, next in next }
            checks.merge(try AgentMCPImportCheck.run(tasks: tasks, taskID: id, pane: pane, host: host, output: output)) { _, next in next }
            checks.merge(try await AgentMCPImportCheck.recovery(tasks: tasks, taskID: id, pane: pane, host: host, output: output)) { _, next in next }
            checks.merge(try await AgentMCPFormCheck.run(tasks: tasks, taskID: id, pane: pane, host: host, output: output)) { _, next in next }
            checks.merge(try await AgentManagementReviewCheck.run(tasks: tasks, taskID: id, pane: pane, host: host, output: output)) { _, next in next }
            checks.merge(try await checkSettingsPluginHistory(output, tasks: tasks, workspace: workspace, pane: pane, host: host)) { _, next in next }
            host.orderOut(nil)
            checks.merge(try await AgentManagementReviewCheck.runWindow(owner: control, tasks: tasks, taskID: id, output: output)) { _, next in next }
            checks["reviewWorkbenchMakesNoModelRequests"] = modelRequests == 0
            report["success"] = checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = modelRequests; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("settings-pages-report.json"))
    }
}
@MainActor extension AppDelegate {
    func runAgentImportReviewCheck(_ output: URL) {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            let binary = Bundle.main.executableURL!
            report["appPID"] = getpid()
            report["binaryHash"] = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少智能体验收工作台") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("智能体导入检查禁止模型请求") }
            let service = tasks.agents
            let existing = AgentProfile(name: "现有角色", description: "", instructions: "保留原有配置")
            try service.save(service.encode([existing]), expectedHash: service.document().1)
            let before = try service.document()
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let pane = AgentSettingsPageHost(); host.contentView = pane; host.makeKeyAndOrderFront(nil)
            defer { host.close() }
            let manager = AgentProfileWindow(store: tasks, workspace: nil)
            let context = AgentSettingsRecovery.Context(task: nil, workspace: nil)
            guard pane.show(category: "agents", identity: "agent-import-check", scope: "用户", recoveryContext: context, make: { _ in manager }) else {
                throw PetError("无法打开智能体设置")
            }
            let file = output.appendingPathComponent("角色样例.json")
            func fixture(_ names: [String]) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["agents": names.map {
                    ["name": $0, "description": "公开角色", "instructions": "工作内容 · " + $0, "enabled": true, "tools": ["read_file"]] as [String: Any]
                }], options: [.sortedKeys])
            }
            func button(_ title: String) throws -> NSButton {
                func find(_ view: NSView) -> NSButton? {
                    if let item = view as? NSButton, item.title == title, !item.isHiddenOrHasHiddenAncestor { return item }
                    return view.subviews.lazy.compactMap(find).first
                }
                guard let item = find(pane) else { throw PetError("缺少导入操作 " + title) }
                return item
            }
            func review(_ data: Data) throws -> AgentProfileImportReview {
                try data.write(to: file); try manager.reviewImportFile(file)
                guard let page = pane.currentController as? AgentProfileImportReview else { throw PetError("缺少页内智能体导入审阅") }
                return page
            }
            let original = try fixture(["甲", "乙", "丙"])
            let first = try review(original)
            checks["reviewUsesSettingsHostWithoutWriting"] = try first.presentingWindow === host && first.count == 3 && service.document().1 == before.1
            guard let windowState = try pane.captureRecovery(active: true), let saved = windowState.pages.last else {
                throw PetError("导入审阅未写入窗口恢复记录")
            }
            checks["reviewUsesValidWindowRecoveryRoute"] = windowState.active && windowState.context == context && windowState.pages.map(\.kind) == ["agents", "agent-import-review"]
            let replacement = try fixture(["替换文件", "另一角色"])
            try replacement.write(to: file)
            try button("导入 3 项").performClick(nil)
            checks["changedFileCannotBeImportedFromAnOldReview"] = try pane.currentController === first && service.document().1 == before.1
            first.close()
            guard let restored = try manager.makeSettingsRecoveryChild(saved) as? AgentProfileImportReview else { throw PetError("无法恢复导入审阅") }
            try restored.restoreSettingsRecovery(saved); manager.presentSettingsChild(restored)
            checks["changedSourceRecoveryDisablesWriting"] = try !button("导入").isEnabled && !button("载入草稿").isEnabled && service.document().1 == before.1
            try original.write(to: file)
            let other = AgentProfile(name: "审阅期间新增", description: "", instructions: "另一窗口保存")
            try service.save(service.encode([existing, other]), expectedHash: before.1)
            let beforeSingle = try service.document().1
            try button("重新读取").performClick(nil)
            checks["reloadReadsExactOriginalSource"] = try restored.count == 3 && button("导入 3 项").isEnabled
            try button("载入草稿").performClick(nil)
            checks["loadingOneRoleStillDoesNotWrite"] = try pane.currentController is AgentSettingsDetailPage && service.document().1 == beforeSingle
            try button("保存").performClick(nil)
            let afterSingle = try service.list()
            checks["savingOneDraftKeepsConcurrentRoleAndLeavesOtherImportsUnwritten"] = afterSingle.map(\.name) == ["现有角色", "审阅期间新增", "甲"] && afterSingle.last?.enabled == false
            pane.currentController?.close()
            let duplicate = try review(fixture(["甲", "合法但同批"]))
            checks["duplicateBlocksWholeBatch"] = try !button("导入 2 项").isEnabled && service.list().map(\.name) == afterSingle.map(\.name)
            duplicate.close()
            let batch = try review(fixture(["乙", "丙"]))
            let current = try service.document().1
            try service.save(service.encode(afterSingle + [AgentProfile(name: "外部更新", description: "", instructions: "保留另一处写入")]), expectedHash: current)
            let changed = try service.document().1
            try button("导入 2 项").performClick(nil)
            checks["changedDestinationIsNotOverwritten"] = try pane.currentController === batch && service.document().1 == changed
            try button("重新读取").performClick(nil)
            try button("导入 2 项").performClick(nil)
            let imported = try service.list()
            checks["batchWritesOnlyReviewedRolesDisabled"] = imported.map(\.name) == ["现有角色", "审阅期间新增", "甲", "外部更新", "乙", "丙"]
                && imported.allSatisfy { !$0.enabled } && pane.currentController === manager
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests
        report["success"] = report["error"] == nil && requests == 0 && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("settings-pages-report.json"))
    }
}
