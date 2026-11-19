import AppKit

@MainActor extension AppDelegate {
    func runMCPSSECheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        func call(_ name: String, _ arguments: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: try json(arguments)) }
        defer { agentStore?.mcp.disconnect(); agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("SSE 本机验收禁止模型请求") }
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("server/ready.json"))) as! [String: Any]
            let base = fixture["base"] as! String, library = tasks.mcp
            let id = try await prepareSettingsPagesCheck(output, tasks: tasks), workspace = tasks.task(id)?.workspace
            tasks.update(id) { $0.mode = .agent; $0.permission = .review }
            let tools = AgentTools(store: tasks, taskID: id)
            let prior = try Dictionary(uniqueKeysWithValues: library.servers.map { ($0.id, try library.document($0)) })
            let endpoint = base + "/events/split"
            let config: [String: Any] = ["name": "公开 SSE 连接器", "type": "sse", "url": endpoint, "timeoutSeconds": 2]
            let form = try AgentMCPConfigForm(document: json(config), pluginLocked: false), document = try form.document()
            checks["sseFormPreservesItsOwnTransportAndAddress"] = form.type == "sse" && document.contains(endpoint) && !document.contains("command")
            let locked = try AgentMCPConfigForm(document: json(config), pluginLocked: true)
            checks["ssePluginFormPreservesLockedTransport"] = locked.type == "sse" && locked.firstInput.accessibilityLabel() == "MCP 地址"
            var server = try library.save(document)
            checks["sseSavesAndPassesRuntimeValidation"] = try library.server(server.id, workspace: workspace).type == "sse"
            let reopened = AgentMCP(profile: library.profile)
            checks["sseReopenPreservesTypeURLTimeoutAndID"] = reopened.servers.first(where: { $0.id == server.id }).map { $0.type == "sse" && $0.url == endpoint && $0.timeoutSeconds == 2 } == true
            let definitions = try AgentPlugins.mcpDefinitions(["mcpServers": ["legacy": ["type": "sse", "url": endpoint]]], paths: [], read: { _ in Data() })
            checks["ssePluginDeclarationStaysSSE"] = definitions.count == 1 && definitions[0].value["type"] as? String == "sse"
            for transport in ["sse", "http"] {
                let value = try AgentMCPImportPage(document: json(["mcpServers": ["legacy": ["type": transport, "url": endpoint, "timeout": 1250]]]))
                func preview(_ view: NSView?) -> String? { guard let view else { return nil }; if let text = view as? NSTextView, text.accessibilityLabel() == "MCP 导入配置预览" { return text.string }; return view.subviews.compactMap { preview($0) }.first }
                let parsed = try JSONSerialization.jsonObject(with: Data((preview(value.pageContentView) ?? "").utf8)) as? [String: Any]
                checks["sseImportKeepsExplicitTransport-" + transport] = parsed?["type"] as? String == transport && parsed?["timeoutSeconds"] as? Double == 1.25
            }
            let connect = try call("connect_mcp", ["server_id": server.id, "configuration": server.revision])
            checks["sseConnectKeepsExistingApproval"] = try tools.approvalReason(for: connect) != nil
            let initialized = try await tools.execute(connect)
            guard let token = library.token(server.id, owner: id) else { throw PetError("SSE 未取得连接") }
            checks["sseActuallyNegotiatesAndListsTools"] = !initialized.failed && initialized.text.contains("public-legacy-sse")
            do { _ = try library.validateCall(server.id, owner: id, token: token, name: "public_echo"); checks["sseCallStillRequiresActualSchema"] = false } catch { checks["sseCallStillRequiresActualSchema"] = true }
            let catalog = try library.catalog(server.id, owner: id, token: token, offset: 0, query: "public_echo")
            checks["sseActualSchemaIncludesPublicValue"] = (catalog["tools"] as? [[String: Any]])?.first?["inputSchema"] is [String: Any]
            let invoke = try call("call_mcp_tool", ["server_id": server.id, "connection": token, "tool": "public_echo", "arguments": ["value": "应用实际 SSE 原文 🧭"]])
            checks["sseToolKeepsExistingApproval"] = try tools.approvalReason(for: invoke) != nil
            let result = try await tools.execute(invoke)
            checks["sseToolReturnsActualPublicUnicodeValue"] = !result.failed && result.text.contains("应用实际 SSE 原文 🧭")
            report["actualResult"] = result.text
            let other = tasks.create(title: "独立 SSE 验收任务", workspace: workspace)
            do { _ = try library.catalog(server.id, owner: other, token: token, offset: 0); checks["sseConnectionCannotCrossTasks"] = false } catch { checks["sseConnectionCannotCrossTasks"] = true }
            _ = try await library.connect(server.id, revision: server.revision, owner: id, workspace: workspace)
            checks["sseRepeatedConnectReusesCurrentConnection"] = library.token(server.id, owner: id) == token
            library.disconnect(owner: id, serverID: server.id)
            do { _ = try library.validateCall(server.id, owner: id, token: token, name: "public_echo"); checks["sseDisconnectedTokenCannotBeCalled"] = false } catch { checks["sseDisconnectedTokenCannotBeCalled"] = true }
            _ = try await library.connect(server.id, revision: server.revision, owner: id, workspace: workspace)
            checks["sseExplicitReconnectIssuesNewToken"] = library.token(server.id, owner: id) != token
            let oldRevision = server.revision
            try library.setEnabled(server.id, false)
            checks["sseDisablingClosesOwnedConnection"] = library.token(server.id, owner: id) == nil
            try library.setEnabled(server.id, true); server = try library.server(server.id)
            checks["sseEnableRequiresNewConfigurationApproval"] = server.revision != oldRevision
            // Exercise the existing Streamable HTTP path with a separate endpoint.
            let http = try library.save(json(["name": "公开 HTTP 回归", "type": "http", "url": base + "/http", "timeoutSeconds": 2]))
            _ = try await library.connect(http.id, revision: http.revision, owner: id, workspace: workspace)
            guard let httpToken = library.token(http.id, owner: id) else { throw PetError("HTTP 回归未连接") }
            _ = try library.catalog(http.id, owner: id, token: httpToken, offset: 0, query: "public_echo")
            let httpResult = try await library.call(http.id, owner: id, token: httpToken, name: "public_echo", arguments: ["value": "HTTP 公开回归"])
            checks["streamableHTTPStillUsesItsOwnProtocol"] = !httpResult.failed && httpResult.text.contains("HTTP 公开回归")
            library.disconnect(owner: id, serverID: http.id)
            let authentication = try await checkAuthenticatedMCP(output, tasks: tasks, base: base, owner: id)
            checks.merge(authentication.checks) { _, latest in latest }
            report["authenticatedInventory"] = authentication.inventory
            let idle = try library.save(json(["name": "SSE 空闲断线验收", "type": "sse", "url": base + "/events/idle-disconnect", "timeoutSeconds": 2]))
            _ = try await library.connect(idle.id, revision: idle.revision, owner: id, workspace: workspace)
            try await Task.sleep(for: .milliseconds(350))
            checks["sseIdleDisconnectClearsTokenAndVisibleState"] = library.token(idle.id, owner: id) == nil && library.status(idle.id, owner: id) == "已断开"
            for mode in ["no-endpoint", "foreign-endpoint", "redirect-get", "redirect-post", "version"] {
                let failed = try library.save(json(["name": "SSE 失败验收 " + mode, "type": "sse", "url": base + "/events/" + mode, "timeoutSeconds": 1]))
                let start = Date()
                do { _ = try await library.connect(failed.id, revision: failed.revision, owner: id, workspace: workspace); checks["sseFailureClosesSession-" + mode] = false }
                catch { checks["sseFailureClosesSession-" + mode] = Date().timeIntervalSince(start) < 3 && library.token(failed.id, owner: id) == nil }
            }
            checks["sseDoesNotChangePriorConnectorDefinitions"] = try library.servers.filter { prior[$0.id] != nil }.allSatisfy { try library.document($0) == prior[$0.id] }
            report["fixtureServerPID"] = fixture["pid"]; report["taskID"] = id; report["connectorID"] = server.id
            library.disconnect()
        } catch { report["error"] = error.localizedDescription; checks["completed"] = false }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }; report["appPID"] = Int(getpid()); report["modelRequests"] = requests
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("mcp-sse-report.json"))
    }

    private func checkAuthenticatedMCP(_ output: URL, tasks: AgentStore, base: String, owner: String) async throws -> (checks: [String: Bool], inventory: [String: String]) {
        let library = tasks.mcp
        let vault = output.appendingPathComponent("mcp-credential-fixture.json")
        let metadata = library.profile.appendingPathComponent("extensions/mcp.json")
        let credentials = PetKeychain(service: "com.xjs.bluefatfish.fixture", configurationFile: vault, migrateLegacy: false)
        var checks: [String: Bool] = [:], inventory: [String: String] = [:]
        func document(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
        }
        func save(_ value: [String: Any], previous: AgentMCPServer? = nil) throws -> AgentMCPServer {
            try library.save(document(value), id: previous?.id, expectedRevision: previous?.revision)
        }
        func rejection(_ server: AgentMCPServer, status: Int) async -> Bool {
            do { _ = try await library.connect(server.id, revision: server.revision, owner: owner, workspace: nil); return false }
            catch {
                let state = library.status(server.id, owner: owner)
                return state.contains("HTTP \(status)") && error.localizedDescription.contains("请") && library.token(server.id, owner: owner) == nil
            }
        }
        func lookup(_ server: AgentMCPServer, using service: AgentMCP, sku: String) async throws -> String {
            _ = try await service.connect(server.id, revision: server.revision, owner: owner, workspace: nil)
            defer { service.disconnect(owner: owner, serverID: server.id) }
            guard let token = service.token(server.id, owner: owner) else { throw PetError("未连接库存服务") }
            _ = try service.catalog(server.id, owner: owner, token: token, offset: 0, query: "lookup_stock")
            let result = try await service.call(server.id, owner: owner, token: token, name: "lookup_stock", arguments: ["sku": sku])
            guard !result.failed else { throw PetError("库存查询失败") }
            return result.text
        }
        for type in ["http", "sse"] {
            let prefix = base + (type == "http" ? "/http" : "/events")
            var form: [String: Any] = ["name": "库存验收 " + type, "type": type, "url": prefix + "/auth", "timeoutSeconds": 4]
            var server = try save(form)
            checks[type + "NeedsAuthentication"] = await rejection(server, status: 401)
            form["bearerToken"] = "public-fixture-token-initial"
            server = try save(form, previous: server)
            checks[type + "DistinguishesPermissionFailure"] = await rejection(server, status: 403)
            form["headers"] = ["X-Fixture-Access": "public-fixture-header-initial"]
            server = try save(form, previous: server)
            let originalRevision = server.revision
            let initialDocument = try library.document(server)
            let secureForm = try AgentMCPConfigForm(document: initialDocument, pluginLocked: false)
            var draft = try AgentConfigurationJSON.object(Data(secureForm.document().utf8))
            let storedConfiguration = try String(contentsOf: metadata, encoding: .utf8)
            checks[type + "SecretsOnlyAppearAsPlaceholders"] = draft["bearerToken"] as? String == AgentMCP.placeholder
                && draft["headers"] as? [String: String] == ["X-Fixture-Access": AgentMCP.placeholder]
                && !storedConfiguration.contains("public-fixture-")

            let before = try Data(contentsOf: vault)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: vault.path)
            draft["name"] = "库存验收已重命名 " + type; draft["timeoutSeconds"] = 5
            do { server = try save(draft, previous: server) }
            catch { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vault.path); throw error }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vault.path)
            checks[type + "SettingsSaveKeepsReadOnlyCredentials"] = try Data(contentsOf: vault) == before && server.revision != originalRevision
            try library.setEnabled(server.id, false)
            try library.setEnabled(server.id, true)
            server = try library.server(server.id)
            checks[type + "ReenableKeepsCredentialReference"] = try Data(contentsOf: vault) == before && server.credentialRevision == originalRevision
            let reopened = AgentMCP(profile: library.profile, keychain: credentials)
            inventory[type + "Initial"] = try await lookup(try reopened.server(server.id), using: reopened, sku: "WHALE-7")

            let savedMetadata = try Data(contentsOf: metadata)
            draft["url"] = prefix + "/auth-next"
            do { _ = try save(draft, previous: server); checks[type + "AddressChangeRejectsOldCredentials"] = false }
            catch {
                checks[type + "AddressChangeRejectsOldCredentials"] = try error.localizedDescription.contains("请重新填写")
                    && Data(contentsOf: metadata) == savedMetadata && Data(contentsOf: vault) == before
            }
            draft["bearerToken"] = "public-fixture-token-replacement"
            draft["headers"] = ["X-Fixture-Access": "public-fixture-header-replacement"]
            server = try save(draft, previous: server)
            inventory[type + "Replacement"] = try await lookup(server, using: library, sku: "WHALE-9")
            checks[type + "ActualInventoryResults"] = inventory[type + "Initial"]?.contains("小鲸马克杯") == true
                && inventory[type + "Replacement"]?.contains("小鲸帆布袋") == true
            draft["bearerToken"] = ""; draft["headers"] = [String: String]()
            server = try save(draft, previous: server)
            checks[type + "RemovedCredentialsAreNoLongerUsed"] = await rejection(server, status: 401)
        }
        return (checks, inventory)
    }
}
