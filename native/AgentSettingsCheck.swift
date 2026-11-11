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
          if (request.method === 'tools/list') result = {tools: [{name: 'echo', description: 'Read a public value', inputSchema: {type: 'object', properties: {value: {type: 'string'}}}}]};
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

    func runSettingsPagesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        do {
            let tasks = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            let id = try await prepareSettingsPagesCheck(output, tasks: tasks), workspace = tasks.task(id)?.workspace
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let pane = AgentSettingsPageHost(); host.contentView = pane
            let visible = NSApp.windows.filter(\.isVisible).count
            let profile = tasks.directory.deletingLastPathComponent()
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
                ("rules", AgentRuleWindow(store: tasks, taskID: id), "设置规则正文")
            ]
            func text(_ view: NSView) -> String {
                (view as? NSTextView)?.string ?? (view as? NSTextField)?.stringValue ?? view.subviews.map(text).joined(separator: "\n")
            }
            var actualTexts = true, narrowPagesStartAtTop = true, childPID: pid_t?
            for (key, manager, expected) in managers {
                guard pane.show(category: key, identity: key, scope: "设置项目", make: { _ in manager }) else { throw PetError("设置页未载入：" + key) }
                pane.layoutSubtreeIfNeeded()
                let viewport = pane.subviews.compactMap { $0 as? NSScrollView }.first
                narrowPagesStartAtTop = narrowPagesStartAtTop && viewport?.documentView?.isFlipped == true && abs(viewport?.contentView.bounds.minY ?? -1) < 0.5
                checks["embedded-" + key] = manager.presentingWindow === host && manager.pageContentView?.window === host && manager.window?.isVisible == false
                for _ in 0..<30 {
                    if manager.pageContentView.map({ text($0).contains(expected) }) == true { break }
                    await wait(0.05)
                }
                actualTexts = actualTexts && manager.pageContentView.map { text($0).contains(expected) } == true
                if key == "mcp" {
                    childPID = try await mcp.connectForSettingsCheck()
                    checks["localMCPConnectsFromHostedManager"] = childPID.map { kill($0, 0) == 0 } == true
                }
                guard pane.leave() else { throw PetError("设置页未退出：" + key) }
                if key == "mcp", let childPID {
                    for _ in 0..<30 { if kill(childPID, 0) != 0 { break }; await wait(0.1) }
                    checks["leavingHostedMCPStopsActualProcess"] = kill(childPID, 0) != 0
                }
            }
            checks["pagesLoadActualStoredContent"] = actualTexts
            checks["openingPagesPreservesActualConfiguration"] = try fingerprints() == before
            checks["hostingDoesNotCreateVisibleManagementWindows"] = NSApp.windows.filter(\.isVisible).count == visible
            checks["narrowPagesInitiallyShowTopFields"] = narrowPagesStartAtTop
            if let childPID { report["localMCPProcess"] = childPID }
            report["success"] = checks.count == 15 && checks.values.allSatisfy { $0 }
        } catch { report["error"] = error.localizedDescription; report["success"] = false }
        report["checks"] = checks; report["modelRequests"] = 0; report["appPID"] = getpid()
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("settings-pages-report.json"))
    }
}
