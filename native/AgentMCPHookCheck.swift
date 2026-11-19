import AppKit

@MainActor extension AppDelegate {
    func runMCPHookCheck(_ output: URL) async {
        var checks: [String: Bool] = [:]
        var errorText: String?
        do { try await checkMCPHooks(output, checks: &checks) }
        catch { errorText = error.localizedDescription }
        var report: [String: Any] = ["success": errorText == nil && !checks.isEmpty && checks.values.allSatisfy { $0 },
                                     "checks": checks, "modelRequests": 0, "appPID": getpid()]
        report["error"] = errorText
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent("mcp-hook-report.json"), options: .atomic)
    }

    private func checkMCPHooks(_ output: URL, checks: inout [String: Bool]) async throws {
        let fm = FileManager.default
        let profile = output.appendingPathComponent("profile"), home = output.appendingPathComponent("shared-home")
        let project = output.appendingPathComponent("Harbor"), other = output.appendingPathComponent("Other")
        let source = output.appendingPathComponent("Source"), userSource = home.appendingPathComponent(".codex")
        for folder in [project, other, source.appendingPathComponent(".codex"), userSource] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let readme = "PUBLIC HARBOR HOOK 5183"
        let secret = "SYNTHETIC\"\\MCP-FIXTURE-4182"
        let readmePath = project.appendingPathComponent("README.md")
        try Data((readme + "\n").utf8).write(to: readmePath)
        let command = output.appendingPathComponent("public-connector.mjs")
        let calls = output.appendingPathComponent("fixture-calls.jsonl"), launched = output.appendingPathComponent("fixture-started.txt")
        let program = #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        fs.writeFileSync(process.argv[3], String(process.pid));
        const input = readline.createInterface({input: process.stdin});
        input.on('line', line => {
          const request = JSON.parse(line);
          if (!Object.hasOwn(request, 'id')) return;
          let result = {};
          if (request.method === 'initialize') {
            result = {protocolVersion: request.params.protocolVersion, capabilities: {tools: {}}, serverInfo: {name: 'public-fixture', version: '1.0.0'}};
          } else if (request.method === 'tools/list') {
            result = {tools: [{name: 'inspect_public', inputSchema: {type: 'object', properties: {}}}]};
          } else if (request.method === 'tools/call') {
            fs.appendFileSync(process.argv[2], JSON.stringify(request.params) + '\n');
            const args = request.params.arguments;
            const specific = {hookEventName: args.event, additionalContext: '已核对公开资料 ' + (args.content ?? '')};
            if (args.path === 'blocked.txt') Object.assign(specific, {permissionDecision: 'deny', permissionDecisionReason: '公开样例由 Hook 拒绝'});
            result = {structuredContent: {hookSpecificOutput: specific}, content: []};
            if (args.event === 'Interrupt') result = {structuredContent: {systemMessage: '公开连接器收到停止'}, content: []};
            if (args.path === 'error.txt') result = {isError: true, content: [{type: 'text', text: '测试错误 ' + process.env.FIXTURE_SECRET}]};
          }
          process.stdout.write(JSON.stringify({jsonrpc: '2.0', id: request.id, result}) + '\n');
        });
        input.on('close', () => process.exit(0));
        """#
        try Data(program.utf8).write(to: command)
        let codex = source.appendingPathComponent(".codex/hooks.json"), inline = userSource.appendingPathComponent("config.toml")
        let json = #"""
        {"hooks":{
          "PreToolUse":[{"matcher":"Read", "hooks":[{"name":"核对公开读取", "type":"mcp_tool", "server":"harbor-fixture", "tool":"inspect_public", "input":{"event":"${hook_event_name}","request":"${tool_input}","path":"${tool_input.file_path}","values":["起始行=${tool_input.offset}","${tool_input.offset}"]}}]}],
          "PostToolUse":[{"matcher":"Read", "hooks":[{"name":"核对公开结果", "type":"mcp_tool", "server":"harbor-fixture", "tool":"inspect_public", "input":{"event":"${hook_event_name}","content":"${tool_response}","ok":"${is_error}"}}]}],
          "Interrupt":[{"hooks":[{"name":"公开连接器中断","type":"mcp_tool","server":"harbor-fixture","tool":"inspect_public","input":{"event":"${hook_event_name}","turn":"${turn_id}","session":"${session_id}"}}]}],
          "SessionEnd":[{"hooks":[{"type":"mcp_tool","server":"harbor-fixture","tool":"inspect_public"}]}],
          "Stop":[{"hooks":[{"name":"原有命令", "type":"command", "command":"/usr/bin/true"}]}]
        }}
        """#
        let toml = #"""
        [mcp_servers.ignored.env]
        API_KEY = "PUBLIC-FIXTURE-NOT-IMPORTED"
        [[hooks.SessionStart]]
        hooks = [{type = "mcp_tool", server = "harbor-fixture", tool = "inspect_public", input = {event = "${hook_event_name}", content = "${source}"}}]
        """#
        try Data(json.utf8).write(to: codex)
        try Data(toml.utf8).write(to: inline)
        let connectorVault = PetKeychain(service: "com.xjs.bluefatfish.mcp-hook-check",
                                          configurationFile: output.appendingPathComponent("fixture-mcp-vault.json"), migrateLegacy: false)
        let store = AgentStore(directory: profile, legacy: [], extensionHome: home, mcpKeychain: connectorVault)
        let importer = store.dataImport
        for folder in [project, other] { try store.organization.register(folder.path, mode: .coding) }
        let task = store.create(title: "公开文档", workspace: project.path)
        _ = try await AgentGit(store: store, taskID: task, directory: AgentGit.metadata(workspace: project.path, creating: true)).initialize()

        func encoded(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        }
        func recordedCalls() throws -> [[String: Any]] {
            guard fm.fileExists(atPath: calls.path) else { return [] }
            return try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map { line in
                try AgentConfigurationJSON.object(Data(line.utf8))
            }
        }
        func lastHook(_ taskID: String) -> AgentEvent? { store.task(taskID)?.events.last { $0.hook != nil } }
        func eventFields(_ path: String, includeLine: Bool = true) -> [String: Any] {
            let input: [String: Any] = includeLine ? ["file_path": path, "offset": 1] : ["file_path": path]
            return ["tool_name": "Read", "tool_input": input, "ignored": "UNREQUESTED DATA"]
        }

        await importer.detect(.codex, root: source, category: .configuration, workspace: project.path)
        guard let existing = importer.preview.first(where: { $0.title == "hooks.json" }),
              let incoming = importer.preview.first(where: { $0.standaloneMCPHooks == true }) else { throw PetError("缺少独立 MCP Hook 项目") }
        checks["separateJSONRowsAndUnsupportedEvent"] = existing.issue == nil && incoming.issue == nil && existing.targetID != incoming.targetID
            && incoming.preview.contains("harbor-fixture / inspect_public") && incoming.warnings.joined().contains("SessionEnd")
        try await AgentStandaloneDataImport.install(existing, root: source, store: store)
        guard let oldHook = try store.hooks.catalog(workspace: project.path).first(where: { $0.name == "原有命令" }) else { throw PetError("原命令未载入") }
        try store.hooks.setEnabled(oldHook, true, workspace: project.path)
        let settings = profile.appendingPathComponent("extensions/hook-settings.json"), approved = try Data(contentsOf: settings)
        try await AgentStandaloneDataImport.install(incoming, root: source, store: store)
        let imported = try AgentStandaloneDataImport.installedURL(incoming, store: store)
        let initial = try store.hooks.catalog(workspace: project.path)
        checks["companionKeepsExistingCommandApprovalAndScope"] = try Data(contentsOf: settings) == approved
            && initial.first(where: { $0.id == oldHook.id }).map(store.hooks.trusted) == true
            && store.hooks.catalog(workspace: other.path).allSatisfy { $0.source != imported.path }
        checks["unconfiguredConnectorHasActionableStatus"] = initial.filter { $0.source == imported.path }.count == 3
            && initial.filter { $0.source == imported.path }.allSatisfy { !store.hooks.enabled($0) && $0.diagnostic?.contains("配置连接器") == true }

        var config: [String: Any] = ["name": "harbor-fixture", "type": "stdio", "command": "/opt/homebrew/bin/node",
                                     "args": [command.path, calls.path, launched.path], "env": ["FIXTURE_SECRET": secret], "timeoutSeconds": 5]
        let connector = try store.mcp.save(encoded(config))
        let ready = try store.hooks.catalog(workspace: project.path)
        guard let pre = ready.first(where: { $0.name == "核对公开读取" }), let post = ready.first(where: { $0.name == "核对公开结果" }) else { throw PetError("MCP Hook 未载入") }
        let off = try await store.hooks.fire(.preTool, trigger: "off", store: store, taskID: task, value: "Read", fields: eventFields("README.md"))
        checks["resolvedTargetStillRequiresReview"] = pre.mcpHook?.target?.id == connector.id && pre.diagnostic == nil
            && off.context.isEmpty && lastHook(task) == nil && !fm.fileExists(atPath: launched.path)
        try store.hooks.setEnabled(pre, true, workspace: project.path)
        try store.hooks.setEnabled(post, true, workspace: project.path)
        let offline = try await store.hooks.fire(.preTool, trigger: "offline", store: store, taskID: task, value: "Read", fields: eventFields("README.md"))
        checks["approvedHookNeverStartsAConnection"] = offline.halt == nil && lastHook(task)?.status == "failed"
            && lastHook(task)?.detail.contains("尚未连接") == true && !fm.fileExists(atPath: launched.path)

        _ = try await store.mcp.connect(connector.id, revision: connector.revision, owner: task, workspace: project.path)
        defer { store.mcp.disconnect(owner: task) }
        let unrelated = store.create(title: "独立公开任务", workspace: project.path)
        _ = try await store.hooks.fire(.preTool, trigger: "other-owner", store: store, taskID: unrelated, value: "Read", fields: eventFields("README.md"))
        checks["anotherTaskCannotBorrowExistingConnection"] = try recordedCalls().isEmpty && lastHook(unrelated)?.detail.contains("尚未连接") == true
        store.update(task) { $0.permission = .review }
        _ = try await store.hooks.fire(.preTool, trigger: "review-policy", store: store, taskID: task, value: "Read", fields: eventFields("README.md"))
        checks["perCallApprovalIsNotBypassed"] = try recordedCalls().isEmpty && lastHook(task)?.detail.contains("逐次确认") == true
        store.update(task) { $0.permission = .workspace; $0.inheritedLimits = .init(readOnly: false, network: false, permission: .workspace) }
        _ = try await store.hooks.fire(.preTool, trigger: "network-policy", store: store, taskID: task, value: "Read", fields: eventFields("README.md"))
        let networkBlocked = lastHook(task)
        checks["networkDisabledTaskCannotSendArguments"] = try recordedCalls().isEmpty && networkBlocked?.status == "failed"
            && networkBlocked?.detail.contains("禁止外部连接") == true
        store.update(task) { $0.inheritedLimits = nil }
        let incomplete = try await store.hooks.fire(.preTool, trigger: "missing-field", store: store, taskID: task, value: "Read", fields: eventFields("README.md", includeLine: false))
        checks["missingTemplateFieldFailsOpenWithoutSend"] = try incomplete.halt == nil && incomplete.deny == nil
            && recordedCalls().isEmpty && lastHook(task)?.detail.contains("tool_input.offset") == true
        let denied = try await store.hooks.fire(.preTool, trigger: "blocked", store: store, taskID: task, value: "Read", fields: eventFields("blocked.txt"))
        let replay = try await store.hooks.fire(.preTool, trigger: "blocked", store: store, taskID: task, value: "Read", fields: eventFields("blocked.txt"))
        checks["structuredDenyIsRespectedAndNeverInvokedTwice"] = try denied.deny == "公开样例由 Hook 拒绝" && replay.deny == denied.deny
            && recordedCalls().count == 1 && lastHook(task)?.status == "blocked"
        let failed = try await store.hooks.fire(.preTool, trigger: "fixture-error", store: store, taskID: task, value: "Read", fields: eventFields("error.txt"))
        checks["serverErrorFailsOpenAndRedactsConnectorCredential"] = failed.halt == nil && failed.deny == nil && lastHook(task)?.status == "failed"
            && lastHook(task)?.detail.contains("[凭据已隐藏]") == true && lastHook(task)?.detail.contains(secret) == false

        let modelVault = PetKeychain(service: "com.xjs.bluefatfish.mcp-hook-model-check",
                                      configurationFile: output.appendingPathComponent("fixture-model-vault.json"), migrateLegacy: false)
        try modelVault.write("PUBLIC-FIXTURE-NO-MODEL", account: "chat")
        let runtime = AgentRuntime(store: store, keychain: modelVault) {
            var settings = PetPreferences(); settings.endpoint = "http://127.0.0.1:1"; return settings
        }
        var modelGate = 0
        runtime.modelRequestCheck = { modelGate += 1; throw PetError("本机验收拦截模型请求") }
        let operation = AgentToolCall(id: "public-read", name: "read_file", arguments: #"{"path":"README.md","offset":1}"#)
        store.update(task) {
            $0.messages = [.init(role: "user", content: "请核对公开 README。"), .init(role: "assistant", content: "", toolCalls: [operation])]
            $0.pendingCalls = [operation]
        }
        runtime.start(task)
        let deadline = Date().addingTimeInterval(15)
        while runtime.isRunning(task) && Date() < deadline { await wait(0.025) }
        guard !runtime.isRunning(task), let finished = store.task(task) else { runtime.cancel(task); throw PetError("普通任务未完成本机检查") }
        let sent = try recordedCalls().suffix(2)
        let sentPre = sent.first?["arguments"] as? [String: Any], sentPost = sent.last?["arguments"] as? [String: Any]
        let values = sentPre?["values"] as? [Any], request = sentPre?["request"] as? [String: Any]
        checks["realReadUsesTypedTemplateAndOnlySelectedFields"] = sentPre?["event"] as? String == "PreToolUse" && sentPre?["path"] as? String == "README.md"
            && values?.first as? String == "起始行=1" && values?.last as? Int == 1 && request?["path"] as? String == "README.md"
            && Set(sentPre?.keys.map { $0 } ?? []) == ["event", "request", "path", "values"]
        checks["realPostHookReceivesPublicResultWithoutNestedInvocation"] = try recordedCalls().count == 4 && sentPost?["event"] as? String == "PostToolUse"
            && (sentPost?["content"] as? String)?.contains(readme) == true && sentPost?["ok"] as? Bool == false
            && finished.messages.contains { $0.toolCallID == operation.id && $0.content.contains(readme) }
            && finished.events.last(where: { $0.hook?.hookID == post.id })?.hook?.effect?.context.contains(readme) == true
        checks["normalRuntimeReachesOnlyLocalModelGate"] = modelGate == 1 && finished.modelReceipts?.isEmpty != false

        guard let interrupt = ready.first(where: { $0.event == .interrupt }) else { throw PetError("缺少中断 MCP 处理器") }
        try store.hooks.setEnabled(interrupt, true, workspace: project.path)
        let interrupted = store.create(title: "公开实时中断", workspace: project.path, mode: .agent)
        _ = try await store.mcp.connect(connector.id, revision: connector.revision, owner: interrupted, workspace: project.path)
        defer { store.mcp.disconnect(owner: interrupted) }
        _ = try await startInterruptFixture(interrupted, label: "mcp-interrupt", runtime: runtime)
        let interruptedSession = store.task(interrupted)?.hookSession
        runtime.interrupt(interrupted)
        let detached = !runtime.isExecuting(interrupted) && store.task(interrupted)?.status == .stopped
        let interruptDeadline = Date().addingTimeInterval(5)
        while runtime.isBusy(interrupted) && Date() < interruptDeadline { await wait(0.025) }
        let interruptCalls = try recordedCalls(), interruptArguments = interruptCalls.last?["arguments"] as? [String: Any]
        checks["interruptUsesThenReleasesOnlyAlreadyApprovedConnection"] = detached && !runtime.isBusy(interrupted) && !store.mcp.connected(connector.id, owner: interrupted)
            && interrupt.timeout == 1 && modelGate == 1 && interruptCalls.count == 5
            && interruptArguments?["event"] as? String == "Interrupt" && interruptArguments?["turn"] as? String != nil
            && interruptedSession != nil && interruptArguments?["session"] as? String == interruptedSession
            && lastHook(interrupted)?.status == "completed" && lastHook(interrupted)?.detail.contains("公开连接器收到停止") == true

        config["timeoutSeconds"] = 6
        _ = try store.mcp.save(encoded(config), id: connector.id, expectedRevision: connector.revision)
        let revised = try store.hooks.catalog(workspace: project.path).first { $0.id == pre.id }
        let stale = try await store.hooks.fire(.preTool, trigger: "stale", store: store, taskID: task, value: "Read", fields: eventFields("README.md"))
        checks["changedConnectorRequiresNewReviewAndDoesNotSend"] = try revised.map(store.hooks.enabled) == true
            && revised.map(store.hooks.trusted) == false && lastHook(task)?.detail.contains("重新审核") == true
            && stale.halt == nil && recordedCalls().count == 5

        await importer.detect(.codex, root: userSource, category: .configuration)
        guard let userHook = importer.preview.first(where: { $0.standaloneMCPHooks == true && $0.issue == nil }) else { throw PetError("缺少全局内联 MCP Hook") }
        try await AgentStandaloneDataImport.install(userHook, root: userSource, store: store)
        let userInstalled = try AgentStandaloneDataImport.installedURL(userHook, store: store)
        let installed = try String(contentsOf: userInstalled, encoding: .utf8)
        let userCatalog = try store.hooks.catalog(workspace: nil)
        checks["inlineTOMLImportsOnlyHooksAndRequiresReview"] = importer.preview.count == 1
            && installed.contains("${source}") && !installed.contains("PUBLIC-FIXTURE-NOT-IMPORTED")
            && userCatalog.contains { $0.source == userInstalled.path && !store.hooks.enabled($0) }
        checks["sourceFilesAndReadmeAreUntouched"] = try Data(contentsOf: codex) == Data(json.utf8)
            && Data(contentsOf: inline) == Data(toml.utf8) && Data(contentsOf: readmePath) == Data((readme + "\n").utf8)
    }
}
