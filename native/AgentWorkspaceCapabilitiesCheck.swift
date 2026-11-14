import AppKit
import Darwin

@MainActor extension AppDelegate {
    @discardableResult func prepareWorkspaceCapabilitiesUI(_ output: URL, seed: Bool) async throws -> [String: String] {
        ensureAgent(); guard checkDirectory != nil, let tasks = agentStore else { throw PetError("缺少独立多源能力环境") }
        let file = output.appendingPathComponent("workspace-capabilities-fixtures.json")
        if !seed {
            let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            guard let id = ids["task"], tasks.task(id) != nil else { throw PetError("原多源能力样例不可用") }
            control.showAgentTask(id); return ids
        }
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PetError("公开样例已存在，请重开原目录") }
        var ids = try await prepareWorkspaceExtensionsUI(output, seed: true)
        let alpha = ids["alpha"]!, beta = ids["beta"]!, id = ids["task"]!, node = "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: node) else { throw PetError("缺少现有本机 Node") }
        let program = #"""
        import readline from 'node:readline';
        import fs from 'node:fs';
        import path from 'node:path';
        const root = () => path.resolve(process.argv[2] || process.cwd());
        const read = () => fs.readFileSync(path.join(root(), 'README.md'), 'utf8');
        const uri = 'public://source/readme';
        const input = readline.createInterface({input: process.stdin});
        input.on('line', line => {
          let request;
          try {
            request = JSON.parse(line);
            if (!Object.hasOwn(request, 'id')) return;
            let result = {};
            if (request.method === 'initialize') result = {protocolVersion: request.params.protocolVersion, capabilities: {tools: {}, resources: {}, prompts: {}}, serverInfo: {name: 'public-source-probe', version: '1.0.0'}};
            if (request.method === 'tools/list') result = {tools: [
              {name: 'inspect_source', description: 'Read the actual public README and current directory', inputSchema: {type: 'object', properties: {}, additionalProperties: false}},
              {name: 'write_public_note', description: 'Write the fixed public notes/public.txt fixture', inputSchema: {type: 'object', properties: {content: {type: 'string'}}, required: ['content'], additionalProperties: false}}
            ]};
            if (request.method === 'tools/call') {
              if (request.params.name === 'inspect_source') result = {content: [{type: 'text', text: JSON.stringify({root: fs.realpathSync(root()), cwd: fs.realpathSync('.'), readme: read(), pid: process.pid})}]};
              else if (request.params.name === 'write_public_note') {
                const content = request.params.arguments.content;
                if (typeof content !== 'string' || Buffer.byteLength(content) > 4096) throw Error('Invalid public fixture content');
                fs.writeFileSync(path.join(root(), 'notes/public.txt'), content);
                result = {content: [{type: 'text', text: 'Saved actual public note in ' + fs.realpathSync(root())}]};
              } else throw Error('Unknown public fixture tool');
            }
            if (request.method === 'resources/list') result = {resources: [{uri, name: '公开源目录 README', mimeType: 'text/plain'}]};
            if (request.method === 'resources/templates/list') result = {resourceTemplates: []};
            if (request.method === 'resources/read') {
              if (request.params.uri !== uri) throw Error('Unknown public fixture URI');
              result = {contents: [{uri, mimeType: 'text/plain', text: read()}]};
            }
            if (request.method === 'prompts/list') result = {prompts: [{name: 'source-review', description: 'Public README review template', arguments: [{name: 'question', required: true}]}]};
            if (request.method === 'prompts/get') result = {messages: [{role: 'user', content: {type: 'text', text: String(request.params.arguments.question || '') + '\n' + read()}}]};
            process.stdout.write(JSON.stringify({jsonrpc: '2.0', id: request.id, result}) + '\n');
          } catch (error) {
            if (request && Object.hasOwn(request, 'id')) process.stdout.write(JSON.stringify({jsonrpc: '2.0', id: request.id, error: {code: -32603, message: error.message}}) + '\n');
          }
        });
        input.on('close', () => process.exit(0));
        """#
        let script = "import fs from 'node:fs';\nconsole.log(JSON.stringify({cwd:fs.realpathSync('.'),source:fs.readFileSync(new URL('../references/source.txt',import.meta.url),'utf8').trim()}));\n"
        for (path, marker) in [(alpha, "ALPHA"), (beta, "BETA")] {
            let all = try tasks.extensions.catalog(workspace: path)
            let skill = all.first { $0.kind == .skill && $0.name == "source-probe" }!, command = all.first { $0.kind == .command && $0.name == "source-probe" }!
            let resources = try AgentFiles(workspace: skill.root.path)
            try resources.writeData(Data((marker + "_LOCAL_SKILL_RESOURCE\n").utf8), to: resources.resolve("references/source.txt"), permissions: 0o600)
            try resources.writeData(Data(script.utf8), to: resources.resolve("scripts/read-source.mjs"), permissions: 0o600)
            _ = try tasks.extensions.save(command, text: tasks.extensions.document(command).0 + "\nUser arguments: $ARGUMENTS\n", expectedHash: command.sha256, workspace: path)
            ids[marker.lowercased() + "Skill"] = skill.id; ids[marker.lowercased() + "Command"] = command.id
        }
        let manual = try tasks.extensions.create(.skill, name: "manual-source", text: "---\nname: manual-source\ndescription: Explicit public source selection\ndisable-model-invocation: true\n---\nMANUAL_ALPHA_PUBLIC\n", project: true, workspace: alpha)
        ids["manualSkill"] = manual.id
        _ = try tasks.extensions.create(.skill, name: "public-global", text: "---\nname: public-global\ndescription: Public global compatibility fixture\n---\nGLOBAL_SKILL_PUBLIC\n", project: false, workspace: nil)
        _ = try tasks.extensions.create(.command, name: "public-short", text: "GLOBAL_COMMAND_PUBLIC $ARGUMENTS\n", project: false, workspace: nil)
        let source = output.appendingPathComponent("public-capabilities-plugin"), files = try AgentFiles(workspace: output.path)
        let pluginRoot = "$" + "{PLUGIN_ROOT}"
        let manifest: [String: Any] = ["name": "source-capabilities", "version": "1.0.0", "displayName": "公开源能力", "mcpServers": ["public": ["command": node, "args": [pluginRoot + "/server.mjs"], "env": [:]]]]
        try files.writeData(JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]), to: files.resolve("public-capabilities-plugin/.qoder-plugin/plugin.json"))
        try files.writeData(Data(program.utf8), to: files.resolve("public-capabilities-plugin/server.mjs"))
        try files.writeData(Data("---\nname: plugin-source\ndescription: Public packaged source workflow\n---\nPLUGIN_SKILL_PUBLIC\n".utf8), to: files.resolve("public-capabilities-plugin/skills/plugin-source/SKILL.md"))
        try files.writeData(Data("PLUGIN_RESOURCE_PUBLIC\n".utf8), to: files.resolve("public-capabilities-plugin/skills/plugin-source/references/source.txt"))
        try files.writeData(Data("PLUGIN_COMMAND_PUBLIC $ARGUMENTS\n".utf8), to: files.resolve("public-capabilities-plugin/commands/plugin-source.md"))
        let package = try await tasks.extensions.plugins.inspect(source)
        for (path, key) in [(alpha, "alpha"), (beta, "beta")] {
            let installed = try tasks.extensions.plugins.install(package, workspace: path)
            try tasks.extensions.plugins.setEnabled(tasks.extensions.plugins.installation(installed.id), true)
            let server = tasks.mcp.availableServers(workspace: path).first { $0.plugin?.name == installed.id && $0.plugin?.key == "public" }!
            let configured = try tasks.mcp.save(tasks.mcp.document(server), id: server.id, expectedRevision: server.revision, workspace: path)
            try tasks.mcp.setEnabled(configured.id, true, workspace: path)
            ids[key + "Server"] = configured.id; ids[key + "CapabilitiesPlugin"] = installed.id
        }
        let globalConfig: [String: Any] = ["name": "Public global source", "type": "stdio", "command": node, "args": [source.appendingPathComponent("server.mjs").path, alpha], "env": [:], "timeoutSeconds": 15]
        let global = try tasks.mcp.save(String(decoding: JSONSerialization.data(withJSONObject: globalConfig), as: UTF8.self))
        ids["globalServer"] = global.id; ids["node"] = node
        tasks.update(id) { $0.title = "多源能力公开验收"; $0.draft = "保留多源能力核对要求 🧭" }
        try JSONEncoder().encode(ids).write(to: file); control.showAgentTask(id); control.show(tab: "chat"); return ids
    }

    func workspaceCapabilitiesReadback() -> [String: Any] {
        guard let output = checkDirectory, let tasks = agentStore, FileManager.default.fileExists(atPath: output.appendingPathComponent("workspace-capabilities-fixtures.json").path) else { return [:] }
        return ["records": tasks.tasks.compactMap { tasks.task($0.id) }.map { task in
            ["id": task.id, "primary": task.workspace ?? "", "folders": task.workspacePaths, "draft": task.draft ?? "", "skills": (try? tasks.extensions.catalog(task: task).filter { $0.kind == .skill }.map(\.id)) ?? [], "connectors": (try? tasks.mcp.availableServers(task: task).map(\.id)) ?? [], "activeSkills": task.activeSkills?.map(\.id) ?? []] as [String: Any]
        }]
    }

    func runWorkspaceCapabilitiesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0, pids: [Int32] = []
        func refused(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        func call(_ name: String, _ object: [String: Any]) throws -> AgentToolCall { .init(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("多源能力原生验收禁止模型请求") }
            defer { runtime.stopAll(); tasks.mcp.disconnect() }
            let ids = try await prepareWorkspaceCapabilitiesUI(output, seed: true), id = ids["task"]!, alpha = ids["alpha"]!, beta = ids["beta"]!, outside = ids["outside"]!, node = ids["node"]!
            let original = tasks.task(id)!, scope = original.workspaceScope!, tools = AgentTools(store: tasks, taskID: id)
            let otherFiles = try Dictionary(uniqueKeysWithValues: tasks.tasks.filter { $0.id != id }.map { record in (record.id, try Data(contentsOf: tasks.directory.appendingPathComponent(record.id + ".json"))) })
            checks["independentProfileAndFrozenSources"] = usesAgent && tasks.extensions.sharedHome?.resolvingSymlinksInPath() == output.appendingPathComponent("shared-home").resolvingSymlinksInPath() && scope.primary == beta && scope.folders == [alpha, beta]
            try tasks.mcp.setEnabled(ids["betaServer"]!, false, workspace: beta)
            try tasks.mcp.setEnabled(ids["globalServer"]!, false)
            control.showAgentTask(id); control.show(tab: "chat"); await wait(0.05)
            func mcpEntry(_ view: NSView?) -> NSButton? {
                guard let view else { return nil }; if let button = view as? NSButton, button.toolTip == "MCP 资料与提示词" { return button }
                for child in view.subviews { if let button = mcpEntry(child) { return button } }; return nil
            }
            checks["secondaryOnlyConnectorRemainsVisibleInComposer"] = !tasks.mcp.availableServers(workspace: beta).contains(where: \.enabled) && mcpEntry(control.window?.contentView)?.isHiddenOrHasHiddenAncestor == false && mcpEntry(control.window?.contentView)?.isEnabled == true
            try tasks.mcp.setEnabled(ids["globalServer"]!, true)
            try tasks.mcp.setEnabled(ids["betaServer"]!, true, workspace: beta)
            let catalog = try tasks.extensions.catalog(task: original), local = catalog.filter { $0.name == "source-probe" }
            checks["allSourcesExposeDistinctSameNamedSkillsAndCommands"] = local.count == 4 && Set(local.map(\.id)).count == 4 && local.contains { $0.scope.contains("Alpha workspace") } && local.contains { $0.scope.contains("Beta source") }
            checks["globalExtensionsDeduplicateAcrossSources"] = catalog.filter { $0.name == "public-global" }.count == 1 && catalog.filter { $0.name == "public-short" }.count == 1
            checks["packagedExtensionsFromBothSourcesRemainDistinct"] = catalog.filter { $0.pluginName == ids["alphaCapabilitiesPlugin"] }.count == 2 && catalog.filter { $0.pluginName == ids["betaCapabilitiesPlugin"] }.count == 2
            let picker = AgentExtensionPicker()
            picker.setEntries(tasks.slashMenu.entries(catalog, task: original, idle: true, canChangeMode: false), service: tasks.slashMenu, presentation: .expanded, query: "source-probe", reset: true)
            let paintedSources = picker.entries.indices.compactMap { row -> String? in
                guard let view = picker.tableView(NSTableView(), viewFor: nil, row: row) as? NSStackView else { return nil }
                return view.arrangedSubviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "slash-entry-source" && !$0.isHidden }?.stringValue
            }
            checks["actualSlashRowsDisplayBothSourcesForSameNamedItems"] = paintedSources.count == 4 && paintedSources.contains { $0.contains("Alpha workspace") } && paintedSources.contains { $0.contains("Beta source") }
            let listed = try await tools.execute(call("list_skills", ["query": "source-probe"]))
            checks["actualSkillDirectoryListsBothFrozenSourceIDs"] = listed.text.contains(ids["alphaSkill"]!) && listed.text.contains(ids["betaSkill"]!)
            for key in ["alphaCommand", "betaCommand"] {
                let item = try tasks.extensions.item(ids[key]!, task: original), text = "/" + (try AgentExtensionSelection.invocation(item)) + " public args 🧭"
                let prepared = try runtime.prepareInput(text, attachmentIDs: [], task: original)
                checks["explicitCommandUsesActualSourceAndCompleteArguments-" + key] = prepared.content == text && prepared.extensionReferences?.first?.id == item.id && prepared.extensionInstructions?.contains(key == "alphaCommand" ? "ALPHA_COMMAND_PUBLIC" : "BETA_COMMAND_PUBLIC") == true && prepared.extensionInstructions?.contains("public args 🧭") == true
            }
            checks["ambiguousLegacyShortNamesRefuseFirstMatch"] = refused { _ = try runtime.prepareInput("/command:source-probe public args", attachmentIDs: [], task: original) } && refused { _ = try runtime.prepareInput("/skill:source-probe", attachmentIDs: [], task: original) }
            let global = try runtime.prepareInput("/public-short \"keep quoted args\" 🧭", attachmentIDs: [], task: original)
            checks["ordinaryShortCommandRetainsQuotedArguments"] = global.extensionInstructions?.contains("GLOBAL_COMMAND_PUBLIC \"keep quoted args\" 🧭") == true
            let escapedItem = try tasks.extensions.item(ids["alphaCommand"]!, task: original), encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let escapedTitle = String(decoding: try encoder.encode(AgentExtensionSelection.title(escapedItem)), as: UTF8.self).replacingOccurrences(of: "/", with: "\\/")
            let escapedText = "/command " + escapedTitle + " 保留参数 🧭", escapedInput = try runtime.prepareInput(escapedText, attachmentIDs: [], task: original)
            checks["escapedJSONSourceStillSelectsExactCommandAndArguments"] = escapedInput.extensionReferences?.first?.id == escapedItem.id && escapedInput.content == escapedText && escapedInput.extensionInstructions?.contains("保留参数 🧭") == true
            checks["malformedExplicitSelectionCannotSelectOutsideFile"] = refused { _ = try AgentExtensionSelection.command("/skill \"name · /unfinished") } && refused { _ = try runtime.prepareInput("/skill \"source-probe · " + outside + "/SKILL.md\"", attachmentIDs: [], task: original) }
            let alphaSkill = try tasks.extensions.item(ids["alphaSkill"]!, task: original)
            guard try runtime.submit("/" + AgentExtensionSelection.invocation(alphaSkill) + " 核对真实资源", taskID: id, startImmediately: false) else { throw PetError(runtime.submissionError ?? "来源 Skill 未载入") }
            guard let reference = tasks.task(id)?.activeSkills?.last, let snapshot = reference.snapshot else { throw PetError("Skill 资源副本未建立") }
            checks["explicitSecondarySkillKeepsTaskPrimaryAndSourceReference"] = reference.id == alphaSkill.id && reference.source == alphaSkill.file.path && tasks.task(id)?.workspace == beta && tasks.task(id)?.workspaceScope == scope && tasks.task(id)?.permission == original.permission
            let resource = try tasks.extensions.readResource(reference.id, path: "references/source.txt", offset: 1, store: tasks, taskID: id)
            checks["secondaryResourceReadsTheSelectedSnapshot"] = resource.contains("ALPHA_LOCAL_SKILL_RESOURCE") && !resource.contains("BETA_LOCAL_SKILL_RESOURCE")
            let actualScript = try await tools.execute(call("run_command", ["command": AgentGit.quote(node) + " " + AgentGit.quote(snapshot + "/scripts/read-source.mjs"), "timeout_seconds": 15]))
            checks["actualCopiedSkillScriptUsesAlphaResourceInOriginalBetaWorkingDirectory"] = !actualScript.failed && actualScript.text.contains("ALPHA_LOCAL_SKILL_RESOURCE") && actualScript.text.contains(beta)
            report["actualSkillScript"] = actualScript.text
            let forbidden = try await tools.execute(call("run_command", ["command": "cat " + AgentGit.quote(outside + "/README.md"), "timeout_seconds": 10]))
            checks["activeSecondarySkillDoesNotGrantUnselectedDirectory"] = forbidden.failed && !forbidden.text.contains("OUTSIDE_PUBLIC_9264")
            let privateFile = tasks.directory.appendingPathComponent("private-public-marker.txt"); try Data("PRIVATE_FIXTURE_6592".utf8).write(to: privateFile)
            let privateRead = try await tools.execute(call("run_command", ["command": "cat " + AgentGit.quote(privateFile.path), "timeout_seconds": 10]))
            checks["skillScratchDoesNotGrantOtherApplicationData"] = privateRead.failed && !privateRead.text.contains("PRIVATE_FIXTURE_6592")
            checks["manualOnlySkillStillRequiresExplicitSelection"] = refused { _ = try tasks.extensions.activate(ids["manualSkill"]!, store: tasks, taskID: id) }
            let manual = try tasks.extensions.item(ids["manualSkill"]!, task: original)
            checks["explicitManualSkillSelectionUsesCurrentSource"] = try runtime.prepareInput("/" + AgentExtensionSelection.invocation(manual), attachmentIDs: [], task: original).extensionInstructions?.contains("MANUAL_ALPHA_PUBLIC") == true
            let narrowID = tasks.create(title: "独立单目录能力范围", workspace: beta)
            let narrow = tasks.task(narrowID)!
            checks["narrowTaskCannotLoadOtherSourceSkillOrCommand"] = refused { _ = try tasks.extensions.item(alphaSkill.id, task: narrow) } && refused { _ = try runtime.prepareInput("/" + AgentExtensionSelection.invocation(alphaSkill), attachmentIDs: [], task: narrow) }
            let fork = tasks.fork(id)!
            checks["forkPreservesFrozenSourcesWithIndependentResourceCopy"] = try tasks.task(fork)?.workspaceScope == scope && tasks.task(fork)?.activeSkills?.last?.snapshot != snapshot && tasks.extensions.readResource(reference.id, path: "references/source.txt", offset: 1, store: tasks, taskID: fork).contains("ALPHA_LOCAL_SKILL_RESOURCE")
            let allServers = try tasks.mcp.availableServers(task: original), alphaServer = try tasks.mcp.server(ids["alphaServer"]!, task: original), betaServer = try tasks.mcp.server(ids["betaServer"]!, task: original)
            checks["connectorDirectoryIncludesBothProjectSourcesAndOneGlobal"] = allServers.count == 3 && allServers.filter { $0.id == ids["globalServer"] }.count == 1
            checks["connectorWorkingDirectoryResolvesFromItsOwnSource"] = try tasks.mcp.workspaceForServer(alphaServer.id, task: original) == alpha && tasks.mcp.workspaceForServer(betaServer.id, task: original) == beta
            checks["sameNamedConnectorChoicesHaveDistinctReadableSources"] = alphaServer.name == betaServer.name && AgentMCPSelection.title(alphaServer) != AgentMCPSelection.title(betaServer) && AgentMCPSelection.selectionTitle(alphaServer).contains(alpha)
            for server in [alphaServer, betaServer] {
                let text = "/" + (try AgentMCPSelection.invocation(server)) + " 核对实际公开文件"
                let prepared = try runtime.prepareInput(text, attachmentIDs: [], task: original)
                checks["explicitConnectorSelectsExactSource-" + (server.id == alphaServer.id ? "alpha" : "beta")] = try prepared.mcpSelection == AgentMCPSelection.reference(server) && prepared.content == text
            }
            checks["ambiguousLegacyConnectorNamesAreRejected"] = refused { _ = try runtime.prepareInput("/mcp \"项目插件 · " + alphaServer.name + "\"", attachmentIDs: [], task: original) }
            checks["oneRootLegacyConnectorChoiceStillResolvesUniquely"] = try runtime.prepareInput("/mcp \"项目插件 · " + betaServer.name + "\"", attachmentIDs: [], task: narrow).mcpSelection?.id == betaServer.id
            checks["connectorScopeCannotExpandNarrowTask"] = refused { _ = try tasks.mcp.server(alphaServer.id, task: narrow) }
            tasks.update(id) { $0.permission = .automatic; $0.toolGroups = ["mcp", "extensions", "terminal"] }
            var connections: [String: String] = [:], responses: [[String: Any]] = []
            for server in [alphaServer, betaServer] {
                let connect = try call("connect_mcp", ["server_id": server.id, "configuration": server.revision])
                checks["connectorStillRequiresOriginalApproval-" + server.id] = try tools.approvalReason(for: connect) != nil && tasks.mcp.token(server.id, owner: id) == nil
                _ = try await tools.execute(connect)
                guard let token = tasks.mcp.token(server.id, owner: id), let pid = await tasks.mcp.processID(server.id, owner: id) else { throw PetError("实际源连接器未启动") }
                pids.append(pid); connections[server.id] = token
                let directory = try tasks.mcp.catalog(server.id, owner: id, token: token, offset: 0, query: "inspect_source")
                guard (directory["tools"] as? [[String: Any]])?.contains(where: { $0["name"] as? String == "inspect_source" }) == true else { throw PetError("未取得真实工具定义") }
                let operation = try call("call_mcp_tool", ["server_id": server.id, "connection": token, "tool": "inspect_source", "arguments": [:]])
                let result = try await tools.execute(operation), marker = server.id == alphaServer.id ? "ALPHA_PUBLIC_7319" : "BETA_PUBLIC_4086", root = server.id == alphaServer.id ? alpha : beta
                checks["actualConnectorReadsItsOwnSource-" + server.id] = !result.failed && result.text.contains(marker) && result.text.contains(root) && kill(pid, 0) == 0
                responses.append(["serverID": server.id, "source": root, "pid": pid, "readmeSHA256": AgentFiles.hash(try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("README.md"))), "result": result.text])
            }
            report["actualConnectors"] = responses
            let definitions = try runtime.toolDefinitions(tasks.task(id)!, preferences: store.preferences), aliases = definitions.filter { AgentMCP.isModelToolName(($0["function"] as? [String: Any])?["name"] as? String ?? "") }
            checks["actualModelSchemaIncludesToolsFromBothSources"] = aliases.count == 2
            for definition in aliases {
                let name = (definition["function"] as! [String: Any])["name"] as! String, alias = AgentToolCall(id: UUID().uuidString, name: name, arguments: "{}")
                let routed = try tasks.mcp.routedCall(alias, owner: id, task: tasks.task(id)!)!
                let result = try await tools.execute(alias), expected = routed.object["server_id"] as? String == alphaServer.id ? "ALPHA_PUBLIC_7319" : "BETA_PUBLIC_4086"
                checks["actualAliasRoutesToItsSelectedSource-" + name] = !result.failed && result.text.contains(expected)
            }
            let context = try runtime.systemContext(tasks.task(id)!)
            checks["liveConnectionContextIncludesBothActualConnections"] = context.contains(connections[alphaServer.id]!) && context.contains(connections[betaServer.id]!)
            let notes = [alpha, beta].map { URL(fileURLWithPath: $0).appendingPathComponent("notes/public.txt") }, beforeNotes = try notes.map { try Data(contentsOf: $0) }
            let turn = AgentMessage(role: "user", content: "原生多源 MCP 实际写入与撤回验收，不请求模型。")
            tasks.update(id) { $0.messages.append(turn); $0.status = .completed }
            for server in [alphaServer, betaServer] {
                _ = try tasks.mcp.catalog(server.id, owner: id, token: connections[server.id]!, offset: 0, query: "write_public_note")
                let write = try await tools.execute(call("call_mcp_tool", ["server_id": server.id, "connection": connections[server.id]!, "tool": "write_public_note", "arguments": ["content": "MCP_WRITE_PUBLIC_" + server.id + "\n"]]))
                guard !write.failed else { throw PetError(write.text) }
            }
            let review = try AgentRoundRollback.review(taskID: id, from: turn.id, store: tasks)
            let writtenNotes = try notes.map { try Data(contentsOf: $0) }
            checks["actualMCPWritesInBothSourcesHaveCheckpoints"] = review.canApply && Set(review.paths) == Set(notes.map(\.path)) && writtenNotes[0] != beforeNotes[0] && writtenNotes[1] != beforeNotes[1]
            try AgentRoundRollback.apply(review, store: tasks)
            checks["actualMCPRollbackRestoresBothSourceBytesAndPermissions"] = try notes.enumerated().allSatisfy { try Data(contentsOf: $0.element) == beforeNotes[$0.offset] && (FileManager.default.attributesOfItem(atPath: $0.element.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640 }
            let listedResources = try await tasks.mcp.contentCatalog(alphaServer.id, owner: id, connection: connections[alphaServer.id]!, kind: "resources", offset: 0)
            let resourceCatalog = listedResources["catalog"] as! String, uri = ((listedResources["items"] as! [[String: Any]]).first!)["uri"] as! String
            let read = try call("read_mcp_resource", ["server_id": alphaServer.id, "connection": connections[alphaServer.id]!, "catalog": resourceCatalog, "uri": uri])
            checks["secondaryResourceReadStillRequiresApproval"] = try tools.approvalReason(for: read) != nil
            let imported = try await tools.execute(read)
            guard let attachment = imported.attachmentIDs?.first else { throw PetError("实际源资源未导入任务附件") }
            let part = try await AgentAttachments.part(store: tasks, taskID: id, id: attachment, number: 1)
            checks["actualSecondaryResourceImportsCorrectPublicBytes"] = !imported.failed && part.text.contains("ALPHA_PUBLIC_7319") && !part.text.contains("BETA_PUBLIC_4086")
            checks["connectionTokensCannotCrossTaskOrSource"] = refused { _ = try tasks.mcp.catalog(alphaServer.id, owner: fork, token: connections[alphaServer.id]!, offset: 0) } && refused { _ = try tasks.mcp.catalog(betaServer.id, owner: id, token: connections[alphaServer.id]!, offset: 0) }
            let noWorkspace = tasks.create(title: "无工作区全局能力兼容", mode: .agent, workMode: .general)
            let noTask = tasks.task(noWorkspace)!, noTools = AgentTools(store: tasks, taskID: noWorkspace), globalServer = try tasks.mcp.server(ids["globalServer"]!, task: noTask)
            checks["noWorkspaceOnlySeesExplicitGlobalCapabilities"] = try tasks.mcp.availableServers(task: noTask).map(\.id) == [globalServer.id] && tasks.extensions.catalog(task: noTask).allSatisfy { $0.scope != "项目" }
            _ = try await noTools.execute(call("connect_mcp", ["server_id": globalServer.id, "configuration": globalServer.revision]))
            guard let globalToken = tasks.mcp.token(globalServer.id, owner: noWorkspace), let globalPID = await tasks.mcp.processID(globalServer.id, owner: noWorkspace) else { throw PetError("无工作区实际全局连接未建立") }
            pids.append(globalPID); _ = try tasks.mcp.catalog(globalServer.id, owner: noWorkspace, token: globalToken, offset: 0, query: "inspect_source")
            let globalRead = try await noTools.execute(call("call_mcp_tool", ["server_id": globalServer.id, "connection": globalToken, "tool": "inspect_source", "arguments": [:]]))
            checks["noWorkspaceActuallyUsesConfiguredGlobalServiceWithoutChangingTaskScope"] = !globalRead.failed && globalRead.text.contains("ALPHA_PUBLIC_7319") && tasks.task(noWorkspace)?.workspace == nil && tasks.task(noWorkspace)?.workspaceScope == nil
            var ask = original; ask.mode = .ask
            checks["askModeCannotAcquireOrConnectSecondaryMCP"] = AgentMCPSelection.candidates(task: ask, store: tasks).isEmpty && refused { _ = try tasks.mcp.approvalReason(call("connect_mcp", ["server_id": alphaServer.id, "configuration": alphaServer.revision]), task: ask) }
            let betaSkill = try tasks.extensions.item(ids["betaSkill"]!, task: original)
            let role = AgentProfile(name: "仅主目录能力", description: "公开范围核对", instructions: "只使用明确分配的能力。", tools: ["list_skills"], readOnly: false, network: true, enabled: true, skills: [betaSkill.id], mcpServers: [betaServer.id])
            try tasks.agents.save(tasks.agents.encode([role]), expectedHash: tasks.agents.document().1)
            let roleTask = try tasks.createWorkspaceTask(scope.group, mode: .coding, title: "角色能力范围验收")
            try tasks.agents.configureDraft(role.id, taskID: roleTask, store: tasks)
            checks["broaderWorkspaceDoesNotExpandRoleSkillOrConnectorAllowlist"] = refused { _ = try tasks.extensions.activate(alphaSkill.id, store: tasks, taskID: roleTask, explicit: true) } && AgentMCPSelection.candidates(task: tasks.task(roleTask)!, store: tasks).map(\.id) == [betaServer.id]
            let roleEntries = tasks.slashMenu.entries(try tasks.extensions.catalog(task: tasks.task(roleTask)!), task: tasks.task(roleTask)!, idle: true, canChangeMode: false)
            checks["roleSlashMenuOnlyOffersAssignedSkills"] = !roleEntries.contains { $0.extensionItem?.id == alphaSkill.id } && roleEntries.contains { $0.extensionItem?.id == betaSkill.id }
            let skillManager = AgentExtensionWindow(store: tasks, taskID: roleTask, managementWorkspace: alpha)
            skillManager.prepareSettings(kind: .skill); skillManager.onInsert = { _ in }; skillManager.selectItem(alphaSkill.id)
            func useButton(_ view: NSView?) -> NSButton? {
                guard let view else { return nil }; if let button = view as? NSButton, button.title == "在任务中使用" { return button }
                for child in view.subviews { if let button = useButton(child) { return button } }; return nil
            }
            checks["sourceManagerDisablesSkillsOutsideRoleAllowlist"] = useButton(skillManager.pageContentView)?.isEnabled == false
            skillManager.close()
            let content = AgentMCPContentWindow(store: tasks, taskID: id, serverID: alphaServer.id) { _, _ in }
            content.showWindow(nil); defer { content.settingsWillLeave(); content.close() }
            content.checkAction("connect")
            for _ in 0..<200 { if content.workspaceReadback()["connected"] as? Bool == true && (content.workspaceReadback()["rows"] as? [[String: Any]])?.isEmpty == false && !content.hasPendingOperation { break }; await wait(0.025) }
            content.checkAction("read")
            for _ in 0..<200 { if (content.workspaceReadback()["previewText"] as? String)?.contains("ALPHA_PUBLIC_7319") == true && !content.hasPendingOperation { break }; await wait(0.025) }
            let visible = content.workspaceReadback()
            checks["actualContentPageConnectsAndPreviewsSelectedSecondarySource"] = visible["serverID"] as? String == alphaServer.id && (visible["previewText"] as? String)?.contains("ALPHA_PUBLIC_7319") == true && visible["connected"] as? Bool == true
            if let owner = visible["sessionOwner"] as? String, let pid = await tasks.mcp.processID(alphaServer.id, owner: owner) { pids.append(pid) }
            report["contentPage"] = visible
            content.settingsWillLeave(); content.close()
            let reopened = AgentStore(directory: store.directory, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["frozenScopeSelectedSkillAndSourceConfigurationSurviveReopen"] = try reopened.task(id)?.workspaceScope == scope && reopened.extensions.readResource(reference.id, path: "references/source.txt", offset: 1, store: reopened, taskID: id).contains("ALPHA_LOCAL_SKILL_RESOURCE") && reopened.mcp.server(alphaServer.id, task: reopened.task(id)!).id == alphaServer.id
            checks["unrelatedOriginalTasksKeepEveryByte"] = try otherFiles.allSatisfy { try Data(contentsOf: tasks.directory.appendingPathComponent($0.key + ".json")) == $0.value }
            let sourcePlugin = try tasks.extensions.plugins.installation(ids["alphaCapabilitiesPlugin"]!)
            try tasks.extensions.plugins.setEnabled(sourcePlugin, false)
            for _ in 0..<120 { if await tasks.mcp.processID(alphaServer.id, owner: id) == nil { break }; await wait(0.025) }
            checks["disablingSecondaryPluginStopsItsActualConnectionAndRejectsSelection"] = await tasks.mcp.processID(alphaServer.id, owner: id) == nil && refused { _ = try AgentMCPSelection.current(AgentMCPSelection.reference(alphaServer), task: tasks.task(id)!, store: tasks) }
            tasks.mcp.disconnect()
            for _ in 0..<200 { if pids.allSatisfy({ kill($0, 0) != 0 }) { break }; await wait(0.025) }
            checks["allActualSourceServiceProcessesExit"] = pids.count == 4 && pids.allSatisfy { kill($0, 0) != 0 }
            checks["noModelsOrFabricatedUsage"] = attempts == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 && !$0.messages.contains { $0.role == "assistant" } }
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["appPID"] = getpid(); report["actualServicePIDs"] = pids; report["modelRequests"] = 0; report["blockedModelAttempts"] = attempts
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workspace-capabilities-report.json"), options: .atomic) } catch { diagnostics.append(error.localizedDescription) }
    }
}
