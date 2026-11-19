import Foundation
import MCP
import os

final class ManagedOAuth: HTTPClientAuthorizer, Sendable {
    private struct Grant: Codable, Sendable {
        var endpoint: URL, issuer: URL, tokenEndpoint: URL
        var token: OAuthAccessToken
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
        self.endpoint = endpoint; self.clientID = clientID
        self.browser = browser; self.persist = persist
        let saved = try grant.map { data -> Grant in
            guard data.count <= 64_000, let saved = try? JSONDecoder().decode(Grant.self, from: data),
                  saved.endpoint == endpoint, Self.secureURL(saved.issuer), Self.secureURL(saved.tokenEndpoint),
                  Self.validBearer(saved.token.value), saved.token.clientID?.isEmpty == false else {
                throw MCPConnectionError("本机 OAuth 授权记录无效，请在设置中移除后重新授权")
            }
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
        let metadata = OSAllocatedUnfairLock<(issuer: URL, token: URL)?>(initialState: nil)
        let store = InMemoryTokenStorage()
        let config = OAuthConfiguration(grantType: .authorizationCode, authentication: .none(clientID: clientID),
            endpointOverrides: .init(authorizationServerURL: saved?.issuer, tokenEndpoint: saved?.tokenEndpoint),
            authorizationRedirectURI: redirect, clientName: "BlueFatFish",
            accessTokenProvider: { context, _ in
                guard let issuer = context.authorizationServer, let token = context.tokenEndpoint,
                      Self.secureURL(issuer), Self.secureURL(token),
                      context.registrationEndpoint.map(Self.secureURL) ?? true else {
                    throw MCPConnectionError("授权服务地址无效")
                }
                metadata.withLock { $0 = (issuer, token) }
                return nil
            }, authorizationDelegate: callback, proactiveRefreshWindowSeconds: 0)
        let authorizer = OAuthAuthorizer(configuration: config, tokenStorage: store)
        do {
            let accepted = try await authorizer.handleChallenge(statusCode: status, headers: headers, endpoint: endpoint, operationKey: "initialize", session: network)
            guard accepted, let token = store.load(), let service = metadata.withLock({ $0 }),
                  Self.validBearer(token.value), token.clientID?.isEmpty == false else {
                throw MCPConnectionError("连接器没有返回有效的 OAuth 授权")
            }
            return Grant(endpoint: endpoint, issuer: service.issuer, tokenEndpoint: service.token, token: token)
        } catch is CancellationError { throw CancellationError() }
        catch let error as MCPConnectionError { throw error }
        catch { throw MCPConnectionError("浏览器授权未完成。请核对服务配置或重新授权") }
    }

    private struct RefreshReply: Decodable {
        let access_token: String, token_type: String, expires_in: Double?, refresh_token: String?
    }

    private func refresh(_ saved: Grant) async throws -> Grant? {
        guard let refresh = saved.token.refreshToken, !refresh.isEmpty, let client = saved.token.clientID else { return nil }
        let resource = try DefaultOAuthMetadataDiscovery().canonicalResourceURI(from: endpoint)
        let values = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client, "resource": resource.absoluteString]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = values.sorted { $0.key < $1.key }.map { key, value in key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
        var request = URLRequest(url: saved.tokenEndpoint)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await network.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw MCPConnectionError("OAuth 授权续期没有响应") }
            if response.statusCode == 400 || response.statusCode == 401 { return nil }
            guard (200..<300).contains(response.statusCode), data.count <= 64_000,
                  let answer = try? JSONDecoder().decode(RefreshReply.self, from: data),
                  answer.token_type.caseInsensitiveCompare("Bearer") == .orderedSame, Self.validBearer(answer.access_token),
                  answer.expires_in.map({ $0.isFinite && $0 > 0 }) ?? true else { throw MCPConnectionError("OAuth 授权续期失败，请在设置中重试") }
            var replacement = saved
            replacement.token = OAuthAccessToken(value: answer.access_token, tokenType: "Bearer",
                expiresAt: answer.expires_in.map { Date().addingTimeInterval($0) }, scopes: saved.token.scopes,
                authorizationServer: saved.issuer, refreshToken: answer.refresh_token ?? refresh, clientID: client)
            return replacement
        } catch is CancellationError { throw CancellationError() }
        catch let error as MCPConnectionError { throw error }
        catch { throw MCPConnectionError("OAuth 授权续期连接失败，请稍后重试") }
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
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }

    private static func validBearer(_ value: String) -> Bool {
        value.utf8.count <= 16_000 && value.range(of: #"^[A-Za-z0-9._~+/\-]+=*\z"#, options: .regularExpression) != nil
    }
}

private final class OAuthNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
