import AppKit

@MainActor extension AppDelegate {
    func runMCPDataImportCheck(_ output: URL) async {
        let profile = output.appendingPathComponent("profile"), credentials = output.appendingPathComponent("fixture-credentials.json")
        let store = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"),
                               mcpKeychain: PetKeychain(service: "com.xjs.bluefatfish.import-fixture", configurationFile: credentials, migrateLegacy: false))
        let service = store.dataImport, mcp = store.mcp, fm = FileManager.default
        let paused = output.appendingPathComponent("mcp-data-import-paused.json"), report = output.appendingPathComponent("mcp-data-import-report.json")
        let harbor = output.appendingPathComponent("harbor"), other = output.appendingPathComponent("other-project")
        let export = output.appendingPathComponent("qoder-export"), qoder = export.appendingPathComponent(".mcp.json")
        let codex = output.appendingPathComponent("codex-export/config.toml")
        let global = profile.appendingPathComponent("extensions/mcp.json"), project = profile.appendingPathComponent("extensions/mcp-projects.json")
        let journal = profile.appendingPathComponent("imports/batch.json")
        let sourceSecret = "PUBLIC-FIXTURE-SOURCE-SECRET", freshSecret = "PUBLIC-FIXTURE-FRESH-VALUE", marker = output.appendingPathComponent("server-started")
        let textFile = output.appendingPathComponent("public-record.txt"), program = output.appendingPathComponent("public-stdio.mjs")
        let publicFact = "MCP PUBLIC HARBOR RECORD 2026"
        var checks: [String: Bool] = [:]

        func encode(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func write(_ data: Data, to file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        func save(_ value: [String: Any], to file: URL) throws { try write(encode(value), to: file) }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try encode(value), as: UTF8.self) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: try json(args)) }
        func idle() async throws {
            let deadline = Date().addingTimeInterval(30)
            while service.active && Date() < deadline { await wait(0.04) }
            guard !service.active else { throw PetError("连接器迁移仍在运行") }
        }
        func matches(_ label: String, action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return error.localizedDescription.contains(label) }
        }

        do {
            if !fm.fileExists(atPath: paused.path) {
                for root in [harbor, other, export] { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
                try store.organization.register(harbor.path, mode: .coding)
                try store.organization.register(other.path, mode: .general)
                let legacy = try mcp.save(json(["name": "legacy", "type": "stdio", "command": "/usr/bin/true", "args": [], "env": [:]]))
                let globalHash = AgentFiles.hash(try Data(contentsOf: global))
                try write(Data(publicFact.utf8), to: textFile)
                let server = """
                import readline from 'node:readline';
                import fs from 'node:fs';
                const [marker, file] = process.argv.slice(2);
                fs.writeFileSync(marker, String(process.pid));
                for await (const line of readline.createInterface({input: process.stdin})) {
                  const request = JSON.parse(line);
                  if (request.id === undefined) continue;
                  let result;
                  if (request.method === 'initialize') result = {protocolVersion: request.params.protocolVersion, serverInfo:{name:'public-mcp-data-fixture',version:'1.0'},capabilities:{tools:{}}};
                  if (request.method === 'tools/list') result = {tools:[{name:'read_public_record',inputSchema:{type:'object',properties:{}}}]};
                  if (request.method === 'tools/call') result = {content:[{type:'text',text:process.env.BFF_FIXTURE_TOKEN === '\(freshSecret)' ? fs.readFileSync(file,'utf8') : 'WRONG-FIXTURE-KEY'}]};
                  process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result})+'\\n');
                }
                """
                try write(Data(server.utf8), to: program)
                try save(["mcpServers": [
                    "a-primary": ["command": "/opt/homebrew/bin/node", "args": [program.path, marker.path, textFile.path], "env": ["BFF_FIXTURE_TOKEN": sourceSecret], "timeout": 1800],
                    "b-published": ["type": "sse", "url": "https://example.com/events"],
                    "c-redacted": ["url": "https://example.com/mcp?token=" + sourceSecret, "headers": ["X-API-Key": sourceSecret], "oauth": ["client_secret": sourceSecret]],
                    "d-command": ["command": "true", "args": ["--token", sourceSecret, "--url=https://example.com/?secret=" + sourceSecret]],
                    "e-invalid": ["type": "sse", "command": "true"],
                    "legacy": ["url": "https://example.org/mcp"]
                ]], to: qoder)
                await service.detect(.qoder, root: qoder, category: .connectors)
                checks["projectFileCannotBecomeGlobal"] = service.preview.filter { $0.issue?.contains("目标项目") == true }.count == 5
                await service.detect(.qoder, root: export, category: .connectors, workspace: harbor.path)
                let rows = service.preview
                checks["qoderPreviewPreservesEligibleAndSkippedRows"] = rows.filter { $0.issue == nil }.count == 4
                    && rows.first { $0.title == "legacy" }?.issue?.contains("同名") == true
                    && rows.first { $0.title == "e-invalid" }?.issue != nil
                checks["queryHeadersAndArgumentsAreRedactedAtPreview"] = !rows.contains { $0.preview.contains(sourceSecret) }
                    && rows.first { $0.title == "c-redacted" }?.preview.contains("X-API-Key") == true
                    && rows.first { $0.title == "d-command" }?.preview.contains("待填写") == true
                let selected = Set(rows.filter { ["a-primary", "b-published"].contains($0.title) }.map(\.id))
                checks["selectionCannotChangeScope"] = matches("重新检测") {
                    try service.begin(.qoder, root: export, ids: selected, category: .connectors, workspace: other.path)
                }
                service.onChange = { [weak service] in
                    if service?.batch?.state == "running", service?.batch?.items.filter({ $0.state == "imported" }).count == 1 { service?.pause() }
                }
                try service.begin(.qoder, root: export, ids: selected, category: .connectors, workspace: harbor.path)
                try await idle(); service.onChange = nil
                guard let batch = service.batch, let done = batch.items.first(where: { $0.state == "imported" }),
                      let pending = batch.items.first(where: { $0.state == "pending" }) else { throw PetError("实际暂停的导入记录缺失") }
                let staged = mcp.availableServers(workspace: harbor.path).first { $0.id == done.record.targetID }
                let preview = try mcp.document(staged)
                checks["pendingFieldsNeverContainSourceCredential"] = staged?.configured == false && staged?.enabled == false
                    && preview.contains("BFF_FIXTURE_TOKEN") && preview.contains(AgentMCP.importPlaceholder) && !preview.contains(sourceSecret)
                checks["noSourceCredentialsOrExecutionDuringImport"] = try !fm.fileExists(atPath: credentials.path)
                    && !fm.fileExists(atPath: marker.path) && !String(contentsOf: journal, encoding: .utf8).contains(sourceSecret)
                    && !String(contentsOf: project, encoding: .utf8).contains(sourceSecret)
                checks["projectImportDoesNotWriteLegacyGlobalStore"] = try AgentFiles.hash(Data(contentsOf: global)) == globalHash
                    && mcp.servers.map(\.id) == [legacy.id] && mcp.availableServers(workspace: other.path).map(\.id) == [legacy.id]
                try await AgentMCPDataImport.install(pending.record, root: export, store: store)
                let publishedHash = AgentFiles.hash(try Data(contentsOf: project))
                let qoderHash = AgentFiles.hash(try Data(contentsOf: qoder))
                try fm.moveItem(at: qoder, to: output.appendingPathComponent("temporarily-unavailable.json"))
                try save(["checks": checks, "pid": getpid(), "batch": batch.id, "global": globalHash, "project": publishedHash, "qoder": qoderHash,
                          "server": done.record.targetID], to: paused)
                return
            }

            let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: paused)) as! [String: Any]
            checks = seed["checks"] as! [String: Bool]
            checks["restartRestoresBatchAndScope"] = seed["pid"] as? Int != Int(getpid()) && service.batch?.id == seed["batch"] as? String
                && service.batch?.state == "paused" && service.batch?.targetWorkspace == harbor.path
            service.resume(); try await idle()
            checks["resumeReusesPublishedRecordWithSourceUnavailable"] = try service.batch?.items.allSatisfy { $0.state == "imported" } == true
                && AgentFiles.hash(Data(contentsOf: project)) == seed["project"] as? String
            try fm.moveItem(at: output.appendingPathComponent("temporarily-unavailable.json"), to: qoder)
            checks["externalSourceAndGlobalCohortStillExact"] = try AgentFiles.hash(Data(contentsOf: qoder)) == seed["qoder"] as? String
                && AgentFiles.hash(Data(contentsOf: global)) == seed["global"] as? String
            guard let primary = mcp.availableServers(workspace: harbor.path).first(where: { $0.id == seed["server"] as? String }) else { throw PetError("重开后缺少项目连接器") }
            let form = try AgentMCPConfigForm(document: mcp.document(primary), pluginLocked: false)
            checks["formPreservesMissingCredentialMarker"] = try form.document().contains(AgentMCP.importPlaceholder)
            checks["missingCredentialBlocksSaveAndEnable"] = matches("请填写凭据") {
                _ = try mcp.save(form.document(), id: primary.id, expectedRevision: primary.revision, workspace: harbor.path)
            } && matches("请先保存") { try mcp.setEnabled(primary.id, true, workspace: harbor.path) }
            var document = try AgentConfigurationJSON.object(Data(mcp.document(primary).utf8))
            document["env"] = ["BFF_FIXTURE_TOKEN": freshSecret]
            let completed = try mcp.save(json(document), id: primary.id, expectedRevision: primary.revision, workspace: harbor.path)
            checks["explicitCredentialSaveKeepsScopeAndDisabledState"] = completed.workspace == harbor.path && !completed.enabled
                && !((try? String(contentsOf: project, encoding: .utf8)) ?? "").contains(freshSecret)
            try mcp.setEnabled(completed.id, true, workspace: harbor.path)
            let task = store.create(title: "项目连接器核对", workspace: harbor.path, mode: .agent)
            store.update(task) { $0.permission = .review }
            let foreign = store.create(title: "其他项目", workspace: other.path, mode: .agent)
            let enabled = try mcp.server(completed.id, workspace: harbor.path), tools = AgentTools(store: store, taskID: task)
            let connect = try call("connect_mcp", ["server_id": enabled.id, "configuration": enabled.revision])
            let targetScope = try store.mcp.availableServers(task: store.task(foreign)!)
            checks["runtimeEnforcesProjectScopeAndApproval"] = try !targetScope.contains { $0.id == enabled.id } && tools.approvalReason(for: connect) != nil
            let handshake = try await tools.execute(connect)
            guard !handshake.failed, let token = mcp.token(enabled.id, owner: task) else { throw PetError("手动启用后的 MCP 握手失败") }
            _ = try mcp.catalog(enabled.id, owner: task, token: token, offset: 0, query: "read_public_record")
            let result = try await mcp.call(enabled.id, owner: task, token: token, name: "read_public_record", arguments: [:])
            checks["savedConnectorReadsActualPublicFile"] = !result.failed && result.text.contains(publicFact) && fm.fileExists(atPath: marker.path)
            mcp.disconnect()

            let toml = """
            model = "unused"
            [mcp_servers."public.remote"]
            url = "https://example.com/mcp?token=\(sourceSecret)"
            bearer_token_env_var = "PUBLIC_EXTERNAL_KEY"
            env_http_headers = { "X-Public" = "EXTERNAL_HEADER" }
            tool_timeout_sec = 2
            enabled_tools = ["notes"]
            [mcp_servers."public.remote".oauth]
            client_secret = "\(sourceSecret)"
            [mcp_servers.updated]
            command = "true"
            args = ["first",]
            """
            try write(Data(toml.utf8), to: codex)
            await service.detect(.codex, root: codex.deletingLastPathComponent(), category: .connectors)
            let codexRecords = service.preview
            checks["codexTomlSupportsQuotedTablesAndCredentialReferences"] = codexRecords.count == 2 && codexRecords.allSatisfy { $0.issue == nil }
                && codexRecords.contains { $0.title == "public.remote" && $0.preview.contains("X-Public") && $0.preview.contains("2 秒") && !$0.preview.contains(sourceSecret) }
            try write(Data(toml.replacingOccurrences(of: "first", with: "revised").utf8), to: codex)
            try service.begin(.codex, root: codex.deletingLastPathComponent(), ids: Set(codexRecords.map(\.id)), category: .connectors)
            try await idle()
            checks["sourceChangesAreIsolatedFromOtherSelectedRows"] = service.batch?.items.contains { $0.record.title == "updated" && $0.state == "failed" }
                == true && service.batch?.items.contains { $0.record.title == "public.remote" && $0.state == "imported" } == true
            let remote = mcp.servers.first { $0.name == "public.remote" }
            checks["codexTokenIsPendingAndNeverCopied"] = remote?.hasBearerToken == true && remote?.configured == false && remote?.enabled == false
                && remote?.headerKeys == ["X-Public"] && !((try? String(contentsOf: global, encoding: .utf8)) ?? "").contains(sourceSecret)
            let shared = AgentMCP(profile: profile)
            _ = try mcp.save(json(["name": "new-global", "type": "stdio", "command": "/usr/bin/true", "args": [], "env": [:]]))
            checks["concurrentLegacyMetadataIsNotOverwritten"] = matches("已变化") {
                _ = try shared.save(json(["name": "stale", "type": "stdio", "command": "/usr/bin/true", "args": [], "env": [:]]))
            } && mcp.servers.contains { $0.name == "new-global" }
            try save(["success": checks.values.allSatisfy { $0 }, "checks": checks, "pid": getpid(), "modelRequests": 0], to: report)
        } catch {
            try? save(["success": false, "checks": checks, "pid": getpid(), "error": error.localizedDescription, "modelRequests": 0], to: report)
        }
    }
}
