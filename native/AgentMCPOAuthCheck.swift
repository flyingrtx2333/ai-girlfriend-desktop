import AppKit
import Security

final class AgentCheckLocalTLS: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let certificate: Data, port: Int
    init(certificate: Data, port: Int) { self.certificate = certificate; self.port = port }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == "localhost", space.port == port,
              let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificate else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

private struct MCPOAuthFixture: Decodable, Sendable {
    struct RegisteredClient: Decodable, Sendable { let id: String, secret: String, method: String }
    let browser: URL, issuer: URL, resource: URL
    let registeredClientID: String, metadataClientID: String
    let secretClients: [String: RegisteredClient]?

    func localBrowserURL(_ authorization: URL) throws -> URL {
        guard authorization.scheme == "https", authorization.host == issuer.host, authorization.port == issuer.port,
              authorization.path == "/authorize", var local = URLComponents(url: browser, resolvingAgainstBaseURL: false) else { throw PetError("授权验收地址无效") }
        local.path = authorization.path
        local.percentEncodedQuery = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        guard let address = local.url else { throw PetError("授权验收地址无效") }; return address
    }
}

@MainActor extension AppDelegate {
    func configureMCPOAuthFixture(_ output: URL, service: AgentMCP, opensBrowser: Bool) throws {
        guard checkDirectory == output, Bundle.main.object(forInfoDictionaryKey: "BlueFatFishAcceptanceOnly") as? Bool == true else {
            throw PetError("OAuth 样例只可在独立验收包中使用")
        }
        let fixture = try JSONDecoder().decode(MCPOAuthFixture.self, from: Data(contentsOf: output.appendingPathComponent("server/ready.json")))
        guard fixture.issuer.scheme == "https", fixture.issuer.host == "localhost", let port = fixture.issuer.port,
              fixture.browser.scheme == "http", fixture.browser.host == "127.0.0.1",
              fixture.resource.absoluteString == fixture.browser.absoluteString + "/mcp" else { throw PetError("OAuth 样例必须使用本机地址") }
        let cert = try Data(contentsOf: output.appendingPathComponent("server/test-cert.der"))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7; config.timeoutIntervalForResource = 10
        let network = URLSession(configuration: config, delegate: AgentCheckLocalTLS(certificate: cert, port: port), delegateQueue: nil)
        service.oauthFixture = (network, { authorization in
            let address = try fixture.localBrowserURL(authorization)
            if opensBrowser {
                guard await MainActor.run(body: { NSWorkspace.shared.open(address) }) else { throw PetError("无法打开浏览器验收页") }
            } else {
                let fields = URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let raw = fields.first(where: { $0.name == "redirect_uri" })?.value, var callback = URLComponents(string: raw),
                      callback.host == "127.0.0.1" else { throw PetError("本机回调地址无效") }
                callback.queryItems = [.init(name: "state", value: "different-session"), .init(name: "code", value: "public-fixture-invalid")]
                let (_, rejection) = try await URLSession.shared.data(from: callback.url!)
                guard (rejection as? HTTPURLResponse)?.statusCode == 400 else { throw PetError("应拒绝不匹配的授权会话") }
                try Data("true\n".utf8).write(to: output.appendingPathComponent("mismatched-state-rejected"), options: .atomic)
                var approval = URLComponents(url: address, resolvingAgainstBaseURL: false)!
                approval.queryItems = fields + [.init(name: "fixture_decision", value: "allow")]
                let (_, accepted) = try await URLSession.shared.data(from: approval.url!)
                guard (accepted as? HTTPURLResponse)?.statusCode == 200 else { throw PetError("本机授权回调未接收") }
            }
        })
    }

    func runMCPOAuthCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], inventory: [String: String] = [:], issue: String?, requests = 0
        defer { agentStore?.mcp.disconnect(); agentRuntime?.stopAll() }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("OAuth 验收禁止模型请求") }
            let service = tasks.mcp
            try configureMCPOAuthFixture(output, service: service, opensBrowser: false)
            let fixture = try JSONDecoder().decode(MCPOAuthFixture.self, from: Data(contentsOf: output.appendingPathComponent("server/ready.json")))
            let owner = tasks.create(title: "MCP 公开授权检验", workMode: .general)
            let original: [String: Any] = ["name": "公开库存 OAuth", "type": "http", "url": fixture.resource.absoluteString, "oauthClientID": "", "timeoutSeconds": 7]
            func encoded(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
            func fixtureAction(_ action: String) async throws {
                var request = URLRequest(url: fixture.browser.appendingPathComponent("fixture/" + action)); request.httpMethod = "POST"
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PetError("本机 OAuth 验收样例未就绪") }
            }
            func lookup(_ server: AgentMCPServer, on library: AgentMCP, phase: String, opensBrowser: Bool = false) async throws {
                _ = try await library.connect(server.id, revision: server.revision, owner: owner, workspace: nil, browserAuthorization: opensBrowser)
                defer { library.disconnect(owner: owner, serverID: server.id) }
                guard let token = library.token(server.id, owner: owner) else { throw PetError("库存连接未就绪") }
                _ = try library.catalog(server.id, owner: owner, token: token, offset: 0, query: "lookup_inventory")
                let response = try await library.call(server.id, owner: owner, token: token, name: "lookup_inventory", arguments: ["sku": "LOCAL-17"])
                guard !response.failed else { throw PetError("库存查询失败") }; inventory[phase] = response.text
            }
            var server = try service.save(encoded(original))
            var changed = original; changed["bearerToken"] = "public-fixture-conflicting"
            do { _ = try service.save(encoded(changed), id: server.id, expectedRevision: server.revision); checks["mixedCredentialsRejected"] = false }
            catch { checks["mixedCredentialsRejected"] = error.localizedDescription.contains("清除手动") }
            let webForm = try AgentMCPConfigForm(document: service.document(server), pluginLocked: false)
            let reconstructed = try AgentConfigurationJSON.object(Data(webForm.document().utf8))
            checks["formRoundTripsOAuthWithoutManualCredentials"] = reconstructed["oauthClientID"] as? String == "" && reconstructed["headers"] == nil
            do { _ = try await service.connect(server.id, revision: server.revision, owner: owner, workspace: nil); checks["backgroundCannotOpenBrowser"] = false }
            catch { checks["backgroundCannotOpenBrowser"] = error.localizedDescription.contains("设置") }
            try await lookup(server, on: service, phase: "login", opensBrowser: true)
            checks["wrongStateDoesNotConsumeAuthorization"] = FileManager.default.fileExists(atPath: output.appendingPathComponent("mismatched-state-rejected").path)
            let vault = output.appendingPathComponent("mcp-credential-fixture.json"), registry = service.profile.appendingPathComponent("extensions/mcp.json")
            let signedIn = try Data(contentsOf: vault)
            let firstRevision = server.revision
            changed = original; changed["name"] = "重命名后的公开库存 OAuth"
            server = try service.save(encoded(changed), id: server.id, expectedRevision: server.revision)
            checks["authorizationReferencedAcrossMetadataEdits"] = try Data(contentsOf: vault) == signedIn && server.credentialRevision == firstRevision
            let permissions = PetKeychain(service: "com.xjs.bluefatfish.oauth-check", configurationFile: vault, migrateLegacy: false)
            let originalAccount = "mcp-\(server.id)-\(firstRevision)"
            guard let grantData = Data(base64Encoded: try permissions.read(originalAccount)),
                  var oldGrant = try JSONSerialization.jsonObject(with: grantData) as? [String: Any],
                  oldGrant.removeValue(forKey: "resource") != nil else { throw PetError("无法构造旧版 OAuth 授权记录") }
            let legacyGrant = try JSONSerialization.data(withJSONObject: oldGrant).base64EncodedString()
            try permissions.write(legacyGrant, account: originalAccount)
            let reopened = AgentMCP(profile: service.profile, keychain: permissions)
            reopened.oauthFixture = service.oauthFixture
            try await lookup(try reopened.server(server.id), on: reopened, phase: "reopen")
            checks["oldGrantWithoutResourceReopens"] = inventory["reopen"] != nil
            try await fixtureAction("expire")
            try await lookup(try reopened.server(server.id), on: reopened, phase: "refresh")
            checks["refreshRotationUpdatedStoredGrant"] = try permissions.read(originalAccount) != legacyGrant
            try await fixtureAction("fail-initialize")
            do { _ = try await reopened.connect(server.id, revision: server.revision, owner: owner, workspace: nil); checks["credentialsRedactedFromConnectionFailure"] = false }
            catch {
                let status = reopened.status(server.id, owner: owner)
                checks["credentialsRedactedFromConnectionFailure"] = status.contains("凭据已隐藏") && !status.contains("public-fixture-")
                    && !error.localizedDescription.contains("public-fixture-")
            }
            let publicConfiguration = try String(contentsOf: registry, encoding: .utf8)
            checks["credentialsStayOutsideConnectorConfig"] = !publicConfiguration.contains("public-fixture-") && !publicConfiguration.contains("refreshToken") && !publicConfiguration.contains("local-client-")
            try reopened.clearOAuth(server.id, revision: server.revision, workspace: nil)
            let signedOut = try reopened.server(server.id)
            checks["clearInvalidatesOldApproval"] = signedOut.oauthClientID == "" && signedOut.revision != server.revision && (try? reopened.server(server.id, revision: server.revision)) == nil
            do { _ = try await reopened.connect(server.id, revision: signedOut.revision, owner: owner, workspace: nil); checks["clearedConnectorRequiresNewConsent"] = false }
            catch { checks["clearedConnectorRequiresNewConsent"] = error.localizedDescription.contains("设置") }
            try await lookup(signedOut, on: reopened, phase: "reauthorize", opensBrowser: true)
            let oldDynamicGrant = try permissions.read("mcp-\(signedOut.id)-\(signedOut.revision)")
            changed["url"] = fixture.resource.absoluteString + "-next"
            let retargeted = try reopened.save(encoded(changed), id: signedOut.id, expectedRevision: signedOut.revision)
            do { _ = try await reopened.connect(retargeted.id, revision: retargeted.revision, owner: owner, workspace: nil); checks["changedEndpointCannotReuseOAuthGrant"] = false }
            catch { checks["changedEndpointCannotReuseOAuthGrant"] = error.localizedDescription.contains("设置") }
            checks["actualInventoryAtLoginReopenRefreshAndReauthorization"] = inventory.count == 4 && inventory.values.allSatisfy { $0.contains("公开读盘样例") }

            var configured = original; configured["name"] = "预注册库存连接器"; configured["oauthClientID"] = fixture.registeredClientID
            let registered = try reopened.save(encoded(configured))
            let registeredAccount = "mcp-\(registered.id)-\(registered.revision)"
            try permissions.write(oldDynamicGrant, account: registeredAccount)
            do { _ = try await reopened.connect(registered.id, revision: registered.revision, owner: owner, workspace: nil); checks["configuredClientDiscardsLegacyDynamicGrant"] = false }
            catch { checks["configuredClientDiscardsLegacyDynamicGrant"] = !oldDynamicGrant.isEmpty && error.localizedDescription.contains("设置") }
            try await lookup(registered, on: reopened, phase: "pre-registered", opensBrowser: true)
            let registeredGrant = try permissions.read(registeredAccount)
            try await fixtureAction("expire")
            try await lookup(registered, on: reopened, phase: "pre-registered-refresh")
            checks["configuredClientRefreshedWithoutNewConsent"] = try permissions.read(registeredAccount) != registeredGrant

            configured["oauthClientID"] = fixture.metadataClientID
            let metadata = try reopened.save(encoded(configured), id: registered.id, expectedRevision: registered.revision)
            do { _ = try await reopened.connect(metadata.id, revision: metadata.revision, owner: owner, workspace: nil); checks["changedClientCannotReuseOAuthGrant"] = false }
            catch { checks["changedClientCannotReuseOAuthGrant"] = metadata.credentialRevision == nil && error.localizedDescription.contains("设置") }
            let metadataForm = try AgentMCPConfigForm(document: reopened.document(metadata), pluginLocked: false)
            checks["formRoundTripsMetadataAddress"] = try AgentConfigurationJSON.object(Data(metadataForm.document().utf8))["oauthClientID"] as? String == fixture.metadataClientID
            try await lookup(metadata, on: reopened, phase: "metadata", opensBrowser: true)
            let reloaded = AgentMCP(profile: service.profile, keychain: permissions)
            reloaded.oauthFixture = service.oauthFixture
            try await fixtureAction("expire")
            try await lookup(try reloaded.server(metadata.id), on: reloaded, phase: "metadata-refresh")
            checks["metadataClientReopensAndRefreshes"] = inventory["metadata-refresh"] != nil

            checks["invalidClientMetadataAddressesRejected"] = ["http://example.com/client.json", "https://example.com/", "https://example.com/client.json#anchor"].allSatisfy { address in
                var invalid = configured; invalid["oauthClientID"] = address
                do { _ = try reloaded.save(encoded(invalid), id: metadata.id, expectedRevision: metadata.revision); return false }
                catch { return error.localizedDescription.contains("带路径的 HTTPS 地址") }
            }

            guard let basic = fixture.secretClients?["basic"], let post = fixture.secretClients?["post"] else { throw PetError("缺少预注册密钥样例") }
            func registration(_ name: String, _ client: MCPOAuthFixture.RegisteredClient) -> [String: Any] {
                ["name": name, "type": "http", "url": fixture.resource.absoluteString, "timeoutSeconds": 7,
                 "oauthClientID": client.id, "oauthIssuer": fixture.issuer.absoluteString, "oauthClientAuthMethod": client.method]
            }
            func failure(_ server: AgentMCPServer, on library: AgentMCP, opensBrowser: Bool, message: String) async -> Bool {
                do {
                    _ = try await library.connect(server.id, revision: server.revision, owner: owner, workspace: nil, browserAuthorization: opensBrowser)
                    library.disconnect(owner: owner, serverID: server.id); return false
                } catch { return error.localizedDescription.contains(message) && !error.localizedDescription.contains("public-fixture-") }
            }
            var basicConfig = registration("预注册 Basic 库存", basic)
            let invalidOptions = ["oauthClientID": "", "oauthIssuer": "http://localhost/issuer", "oauthClientAuthMethod": "none"]
            checks["secretRequiresFixedClientHTTPSIssuerAndKnownMethod"] = invalidOptions.allSatisfy { key, value in
                var invalid = basicConfig; invalid[key] = value
                return (try? reloaded.save(encoded(invalid), enteredOAuthClientSecret: basic.secret)) == nil
            }
            let wrongSecret = "public-fixture-wrong-secret"
            var unsafeJSON = basicConfig; unsafeJSON[AgentMCP.oauthSecretKey] = wrongSecret
            let raw = try encoded(unsafeJSON)
            checks["clientSecretCannotEnterJSONSaveOrRecovery"] = !AgentMCPConfigForm.canPreserveDocument(raw) && (try? reloaded.save(raw)) == nil

            let otherIssuer = basicConfig.merging(["name": "签发者不符", "oauthIssuer": "https://issuer.invalid"], uniquingKeysWith: { _, new in new })
            let wrongIssuerServer = try reloaded.save(encoded(otherIssuer), enteredOAuthClientSecret: basic.secret)
            checks["differentIssuerRejectsBeforeClientAuthorization"] = await failure(wrongIssuerServer, on: reloaded, opensBrowser: true, message: "签发者不一致")
            let rejected = try reloaded.save(encoded(basicConfig.merging(["name": "密钥不符"], uniquingKeysWith: { _, new in new })), enteredOAuthClientSecret: wrongSecret)
            checks["incorrectClientSecretIsRejectedAndRedacted"] = await failure(rejected, on: reloaded, opensBrowser: true, message: "核对客户端 ID、密钥")

            var basicServer = try reloaded.save(encoded(basicConfig), enteredOAuthClientSecret: basic.secret)
            let basicAccount = "mcp-\(basicServer.id)-\(basicServer.revision)"
            let basicDocument = try reloaded.document(basicServer)
            let basicForm = try AgentMCPConfigForm(document: basicDocument, pluginLocked: false)
            let fields = try AgentConfigurationJSON.object(Data(basicForm.document().utf8))
            checks["clientSecretMaskedInFormAndRecoverableDocument"] = fields[AgentMCP.oauthSecretKey] as? String == AgentMCP.placeholder &&
                fields["oauthClientAuthMethod"] as? String == basic.method && fields["oauthIssuer"] as? String == fixture.issuer.absoluteString &&
                basicForm.captureDraft() != nil && !basicDocument.contains(basic.secret)
            basicConfig[AgentMCP.oauthSecretKey] = AgentMCP.placeholder
            let changes = ["url": fixture.resource.absoluteString + "-next", "oauthClientID": post.id,
                           "oauthIssuer": "https://issuer.invalid", "oauthClientAuthMethod": post.method]
            checks["savedSecretCannotFollowAddressIssuerIDOrMethodChange"] = changes.allSatisfy { key, new in
                var edit = basicConfig; edit[key] = new
                do { _ = try reloaded.save(encoded(edit), id: basicServer.id, expectedRevision: basicServer.revision); return false }
                catch { return error.localizedDescription.contains("重新填写客户端密钥") }
            }
            try await lookup(basicServer, on: reloaded, phase: "basic", opensBrowser: true)
            let basicGrant = try permissions.read(basicAccount)
            basicConfig["name"] = "更名后的 Basic 库存"
            basicServer = try reloaded.save(encoded(basicConfig), id: basicServer.id, expectedRevision: basicServer.revision)
            checks["nameChangeRetainsClientSecretAndGrant"] = try permissions.read(basicAccount) == basicGrant && basicServer.credentialRevision != nil

            let confidential = AgentMCP(profile: service.profile, keychain: permissions)
            confidential.oauthFixture = service.oauthFixture
            basicServer = try confidential.server(basicServer.id)
            try await lookup(basicServer, on: confidential, phase: "basic-reopen")
            try await fixtureAction("expire")
            try await lookup(basicServer, on: confidential, phase: "basic-refresh")
            checks["basicGrantReopensAndRefreshes"] = try permissions.read(basicAccount) != basicGrant && inventory["basic-refresh"] != nil

            try confidential.clearOAuth(basicServer.id, revision: basicServer.revision, workspace: nil)
            basicServer = try confidential.server(basicServer.id)
            let keptSecret = try AgentConfigurationJSON.object(Data(permissions.read(basicAccount).utf8))
            let requiresConsent = await failure(basicServer, on: confidential, opensBrowser: false, message: "设置")
            checks["clearAuthorizationKeepsRegistrationAndRequiresConsent"] = keptSecret[AgentMCP.oauthSecretKey] as? String == basic.secret && keptSecret.count == 1 && requiresConsent

            let postConfig = registration("预注册表单库存", post)
            var postServer = try confidential.save(encoded(postConfig), enteredOAuthClientSecret: post.secret)
            try await lookup(postServer, on: confidential, phase: "post", opensBrowser: true)
            let postAccount = "mcp-\(postServer.id)-\(postServer.revision)"
            let postGrant = try permissions.read(postAccount)
            try await fixtureAction("expire")
            try await lookup(postServer, on: confidential, phase: "post-refresh")
            checks["postAuthenticatesAtLoginAndRefresh"] = try permissions.read(postAccount) != postGrant && inventory["post-refresh"] != nil
            postServer = try confidential.save(encoded(postConfig), id: postServer.id, expectedRevision: postServer.revision, enteredOAuthClientSecret: post.secret)
            let replacementRequiresConsent = await failure(postServer, on: confidential, opensBrowser: false, message: "设置")
            checks["reenteringSecretClearsPriorGrantAndApproval"] = try permissions.read(postAccount).isEmpty && replacementRequiresConsent

            try await fixtureAction("omit-client-methods")
            checks["postRequiresAdvertisedAuthenticationMethod"] = await failure(postServer, on: confidential, opensBrowser: true, message: "未声明当前客户端认证方式")
            try await lookup(basicServer, on: confidential, phase: "basic-default", opensBrowser: true)
            checks["basicUsesStandardDefaultWhenMethodsOmitted"] = inventory["basic-default"] != nil
            try confidential.clearOAuth(basicServer.id, revision: basicServer.revision, workspace: nil)
            try await fixtureAction("redirect-token")
            checks["tokenEndpointRedirectDoesNotCompleteAuthorization"] = await failure(try confidential.server(basicServer.id), on: confidential, opensBrowser: true, message: "无效的 OAuth 凭据")
            let registryText = try String(contentsOf: registry, encoding: .utf8)
            checks["registeredSecretsAndTokensStayOutsideConnectorRegistry"] = !registryText.contains("public-fixture-") && !registryText.contains("oauthClientSecret") && !registryText.contains("oauthGrant")

            try confidential.clearOAuth(metadata.id, revision: metadata.revision, workspace: nil)
            try await fixtureAction("disable-client-metadata")
            let unsupported = try confidential.server(metadata.id)
            do { _ = try await confidential.connect(unsupported.id, revision: unsupported.revision, owner: owner, workspace: nil, browserAuthorization: true); checks["unsupportedMetadataDoesNotRequestBrowser"] = false }
            catch { checks["unsupportedMetadataDoesNotRequestBrowser"] = error.localizedDescription.contains("授权服务不支持客户端元数据地址") }
            confidential.disconnect()
            reloaded.disconnect()
            reopened.disconnect()
        } catch { issue = error.localizedDescription }
        let report: [String: Any] = ["checks": checks, "success": issue == nil && checks.count == 35 && checks.values.allSatisfy { $0 },
            "modelRequests": requests, "inventory": inventory, "error": issue ?? "", "appPID": getpid()]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mcp-oauth-report.json"))
    }
}
