import Foundation
import MCP
import os

final class ManagedOAuth: HTTPClientAuthorizer, Sendable {
    private struct Grant: Codable, Sendable {
        var endpoint: URL, issuer: URL, tokenEndpoint: URL
        var resource: URL?
        var token: OAuthAccessToken
    }
    private struct Service: Sendable {
        let issuer: URL, token: URL, resource: URL
    }
    private struct State {
        var grant: Grant?, callback: OAuthCallback?
        var attempted = false, stopped = false
    }
    typealias Browser = @Sendable (URL) async throws -> Void
    typealias SaveGrant = @Sendable (Data) async throws -> Void

    let maxAuthorizationAttempts = 2
    private let endpoint: URL, clientID: String
    private let state: OSAllocatedUnfairLock<State>
    private let browser: Browser?, persist: SaveGrant
    private let network: URLSession, ownsNetwork: Bool

    init(endpoint: URL, clientID: String, grant: Data?, timeout: Double, browser: Browser?, persist: @escaping SaveGrant, network: URLSession?) throws {
        try Self.validateClientID(clientID)
        self.endpoint = endpoint; self.clientID = clientID
        self.browser = browser; self.persist = persist
        let saved = try grant.flatMap { data -> Grant? in
            guard data.count <= 64_000, let saved = try? JSONDecoder().decode(Grant.self, from: data),
                  saved.endpoint == endpoint, Self.secureURL(saved.issuer), Self.secureURL(saved.tokenEndpoint),
                  Self.validBearer(saved.token.value), saved.token.clientID?.isEmpty == false else {
                throw MCPConnectionError("本机 OAuth 授权记录无效，请在设置中移除后重新授权")
            }
            // Older versions could dynamically register even with a configured client ID.
            guard clientID.isEmpty || saved.token.clientID == clientID else { return nil }
            return saved
        }
        state = OSAllocatedUnfairLock(initialState: State(grant: saved))
        ownsNetwork = network == nil
        if let network { self.network = network }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
            self.network = URLSession(configuration: configuration, delegate: OAuthNoRedirect(), delegateQueue: nil)
        }
    }

    func validateEndpointSecurity(for endpoint: URL) throws {
        guard endpoint == self.endpoint, endpoint.user == nil, endpoint.password == nil else { throw MCPConnectionError("OAuth 连接器地址已变化") }
        try OAuthURLValidator().validateHTTPSOrLoopback(endpoint, context: "MCP")
    }

    func authorizationHeader(for endpoint: URL) -> String? {
        guard endpoint == self.endpoint else { return nil }
        return state.withLock { state in
            guard !state.stopped, let token = state.grant?.token, !token.isExpired() else { return nil }
            return "Bearer " + token.value
        }
    }

    func handleChallenge(statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?, session: URLSession) async throws -> Bool {
        try validateEndpointSecurity(for: endpoint)
        // Only initialization is retried. A protected tool call never opens a
        // browser or replays an operation after a challenge.
        guard operationKey == "initialize", statusCode == 401 || statusCode == 403 else { return false }
        let saved = try state.withLock { state -> Grant? in
            guard !state.stopped else { throw CancellationError() }
            guard !state.attempted else { throw MCPConnectionError("连接器拒绝当前 OAuth 授权，请核对权限") }
            state.attempted = true; return state.grant
        }
        if statusCode == 401, let saved, let refreshed = try await refresh(saved) {
            try await retain(refreshed); return true
        }
        guard let browser else { throw MCPConnectionError("请在设置的连接器详情中授权并连接") }
        try await retain(try await login(saved: saved, browser: browser, status: statusCode, headers: headers))
        return true
    }

    private func login(saved: Grant?, browser: @escaping Browser, status: Int, headers: [String: String]) async throws -> Grant {
        let callback = try OAuthCallback { url in
            guard Self.secureURL(url) else { throw MCPConnectionError("浏览器授权地址需要 HTTPS") }
            try await browser(url)
        }
        try state.withLock { state in
            guard !state.stopped else { throw CancellationError() }
            state.callback = callback
        }
        defer { callback.stop(); state.withLock { $0.callback = nil } }
        let redirect = try await callback.start()
        let result = OSAllocatedUnfairLock<(service: Service?, token: OAuthAccessToken?)>(initialState: (nil, nil))
        let store = InMemoryTokenStorage()
        let config = OAuthConfiguration(grantType: .authorizationCode, authentication: .none(clientID: clientID),
            endpointOverrides: .init(authorizationServerURL: saved?.issuer, tokenEndpoint: saved?.tokenEndpoint),
            authorizationRedirectURI: redirect, clientName: "BlueFatFish",
            accessTokenProvider: { [self] context, session in
                guard let issuer = context.authorizationServer, let token = context.tokenEndpoint,
                      Self.secureURL(issuer), Self.secureURL(token),
                      !clientID.isEmpty || (context.registrationEndpoint.map(Self.secureURL) ?? true) else {
                    throw MCPConnectionError("授权服务地址无效")
                }
                let service = Service(issuer: issuer, token: token, resource: context.resource)
                result.withLock { $0.service = service }
                guard !clientID.isEmpty else { return nil }

                // The SDK's public-client flow uses dynamic registration whenever it is offered.
                // Use its discovery, scope selection and browser flow with the configured identity.
                let issued = try await loginWithClientID(context, service: service, callback: callback, redirect: redirect, session: session)
                result.withLock { $0.token = issued }
                return issued.value
            }, authorizationDelegate: callback, proactiveRefreshWindowSeconds: 0)
        let authorizer = OAuthAuthorizer(configuration: config, tokenStorage: store)
        do {
            let accepted = try await authorizer.handleChallenge(statusCode: status, headers: headers, endpoint: endpoint, operationKey: "initialize", session: network)
            let (service, configuredToken) = result.withLock { $0 }
            guard accepted, let token = configuredToken ?? store.load(), let service,
                  Self.validBearer(token.value), token.clientID?.isEmpty == false else {
                throw MCPConnectionError("连接器没有返回有效的 OAuth 授权")
            }
            return Grant(endpoint: endpoint, issuer: service.issuer, tokenEndpoint: service.token, resource: service.resource, token: token)
        } catch is CancellationError { throw CancellationError() }
        catch let error as MCPConnectionError { throw error }
        catch { throw MCPConnectionError("浏览器授权未完成。请核对服务配置或重新授权") }
    }

    private struct AuthorizationMetadata: Decodable {
        let issuer: URL?, authorization_endpoint: URL?, token_endpoint: URL?
        let code_challenge_methods_supported: [String]?, client_id_metadata_document_supported: Bool?
    }

    private func loginWithClientID(_ context: OAuthConfiguration.AccessTokenProviderContext, service: Service,
                                   callback: OAuthCallback, redirect: URL, session: URLSession) async throws -> OAuthAccessToken {
        let validator = OAuthURLValidator()
        guard let authorization = context.authorizationEndpoint, Self.secureURL(authorization),
              [service.issuer, service.token, authorization].allSatisfy({ !validator.isPrivateIPHost($0.host ?? "") }) else {
            throw MCPConnectionError("授权服务地址无效")
        }
        // The provider context omits the PKCE and client metadata capabilities from discovery.
        let metadata = try await authorizationMetadata(service, authorization: authorization, session: session)
        guard metadata.code_challenge_methods_supported?.contains(where: { $0.caseInsensitiveCompare("S256") == .orderedSame }) == true else {
            throw MCPConnectionError("授权服务未声明支持 PKCE S256")
        }
        if Self.looksLikeMetadataURL(clientID), metadata.client_id_metadata_document_supported != true {
            throw MCPConnectionError("授权服务不支持客户端元数据地址，请更改客户端 ID 或留空使用自动注册")
        }
        let verifier = PKCE.makeVerifier(), nonce = UUID().uuidString
        let challenge = try PKCE.makeChallenge(from: verifier), flow = OAuthAuthorizationCodeFlow()
        let scopeSelector = DefaultOAuthScopeSelector()
        let url = try flow.buildURL(authorizationEndpoint: authorization, resource: service.resource, redirectURI: redirect,
                                    clientID: clientID, codeChallenge: challenge, scopes: context.requestedScopes,
                                    state: nonce, scopeSerializer: scopeSelector)
        let code = try await flow.perform(authorizationURL: url, redirectURI: redirect, state: nonce, delegate: callback, session: session)
        var fields = ["grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": redirect.absoluteString,
                      "client_id": clientID, "resource": service.resource.absoluteString]
        fields["scope"] = context.requestedScopes.flatMap(scopeSelector.serialize)
        guard let reply = try await tokenReply(fields, endpoint: service.token, session: session) else {
            throw MCPConnectionError("授权服务拒绝当前客户端，请核对客户端 ID 和回调地址")
        }
        return OAuthAccessToken(value: reply.access_token, tokenType: "Bearer",
            expiresAt: reply.expires_in.map { Date().addingTimeInterval($0) },
            scopes: reply.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? context.requestedScopes ?? [],
            authorizationServer: service.issuer, refreshToken: reply.refresh_token, clientID: clientID)
    }

    private func authorizationMetadata(_ service: Service, authorization: URL, session: URLSession) async throws -> AuthorizationMetadata {
        for url in DefaultOAuthMetadataDiscovery().authorizationServerMetadataURLs(for: service.issuer) {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 64_000,
                  let metadata = try? JSONDecoder().decode(AuthorizationMetadata.self, from: data),
                  metadata.issuer == nil || metadata.issuer == service.issuer,
                  metadata.authorization_endpoint == authorization, metadata.token_endpoint == service.token else { continue }
            return metadata
        }
        try Task.checkCancellation()
        throw MCPConnectionError("无法核对授权服务的客户端配置，请重试")
    }

    private struct TokenReply: Decodable {
        let access_token: String, token_type: String, expires_in: Double?, refresh_token: String?, scope: String?
    }

    private func refresh(_ saved: Grant) async throws -> Grant? {
        guard let refresh = saved.token.refreshToken, !refresh.isEmpty, let client = saved.token.clientID else { return nil }
        let resource = try saved.resource ?? DefaultOAuthMetadataDiscovery().canonicalResourceURI(from: endpoint)
        let values = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client, "resource": resource.absoluteString]
        do {
            guard let answer = try await tokenReply(values, endpoint: saved.tokenEndpoint, session: network) else { return nil }
            var replacement = saved
            replacement.token = OAuthAccessToken(value: answer.access_token, tokenType: "Bearer",
                expiresAt: answer.expires_in.map { Date().addingTimeInterval($0) }, scopes: saved.token.scopes,
                authorizationServer: saved.issuer, refreshToken: answer.refresh_token ?? refresh, clientID: client)
            return replacement
        } catch is CancellationError { throw CancellationError() }
        catch { throw MCPConnectionError("OAuth 授权续期失败，请在设置中重试") }
    }

    private func tokenReply(_ values: [String: String], endpoint: URL, session: URLSession) async throws -> TokenReply? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = values.sorted { $0.key < $1.key }.map { key, value in key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MCPConnectionError("授权服务没有响应") }
        if response.statusCode == 400 || response.statusCode == 401 { return nil }
        guard (200..<300).contains(response.statusCode), data.count <= 64_000,
              let answer = try? JSONDecoder().decode(TokenReply.self, from: data),
              answer.token_type.caseInsensitiveCompare("Bearer") == .orderedSame, Self.validBearer(answer.access_token),
              answer.expires_in.map({ $0.isFinite && $0 > 0 }) ?? true else { throw MCPConnectionError("授权服务返回无效的 OAuth 凭据") }
        return answer
    }

    private func retain(_ grant: Grant) async throws {
        try Task.checkCancellation()
        guard state.withLock({ !$0.stopped }) else { throw CancellationError() }
        let bytes = try JSONEncoder().encode(grant)
        guard bytes.count <= 64_000 else { throw MCPConnectionError("OAuth 授权记录过大") }
        try await persist(bytes)
        state.withLock { if !$0.stopped { $0.grant = grant } }
    }

    func credentialValues() -> [String] {
        state.withLock { state in [state.grant?.token.value, state.grant?.token.refreshToken].compactMap { $0 } }
    }

    func stop() {
        let callback = state.withLock { state in state.stopped = true; return state.callback }
        callback?.stop()
        if ownsNetwork { network.invalidateAndCancel() }
    }

    private static func secureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }

    private static func looksLikeMetadataURL(_ value: String) -> Bool {
        value.contains("://") || value.lowercased().hasPrefix("https:") || value.lowercased().hasPrefix("http:")
    }

    static func validateClientID(_ clientID: String) throws {
        guard clientID.utf8.count <= 2048, !clientID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MCPConnectionError("OAuth 客户端 ID 无效")
        }
        if looksLikeMetadataURL(clientID) {
            guard let url = URL(string: clientID, encodingInvalidCharacters: false), secureURL(url),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.percentEncodedPath.count > 1 else {
                throw MCPConnectionError("客户端元数据需要带路径的 HTTPS 地址")
            }
        }
    }

    private static func validBearer(_ value: String) -> Bool {
        value.utf8.count <= 16_000 && value.range(of: #"^[A-Za-z0-9._~+/\-]+=*\z"#, options: .regularExpression) != nil
    }
}

private final class OAuthNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
