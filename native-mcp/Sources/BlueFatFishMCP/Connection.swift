import Foundation
import MCP

public struct MCPConnectionError: LocalizedError, Sendable {
    public let errorDescription: String?
    public let keepConnection: Bool
    init(_ message: String, keepConnection: Bool = false) { errorDescription = message; self.keepConnection = keepConnection }

    static func authenticationRejected(_ status: Int) -> Self? {
        switch status {
        case 401: return Self("认证失败（HTTP 401）。请检查 Bearer Token 或认证请求头")
        case 403: return Self("连接器拒绝访问（HTTP 403）。请核对凭据的权限范围")
        default: return nil
        }
    }

    fileprivate static func localizeAuthentication(_ error: Error) -> Error {
        // The pinned SDK represents HTTP authorization failures as internal errors.
        guard case .internalError(let message) = error as? MCPError else { return error }
        switch message {
        case "Authentication required": return authenticationRejected(401) ?? error
        case "Access forbidden": return authenticationRejected(403) ?? error
        default: return error
        }
    }
}

// Keep SDK types behind the library boundary so the AppKit executable can
// retain its existing Swift 5 build and Objective-C speech bridge.
public actor MCPConnection {
    private let client: Client
    private var program: ProgramTransport?
    private var oauth: ManagedOAuth?
    private var ready = false, closed = false
    private var supportsTools = false
    private var supportsResources = false, supportsPrompts = false, supportsSubscriptions = false
    private var changeHandler: (@Sendable (String, String?) -> Void)?
    private var elicitationHandler: (@Sendable (Data) async throws -> Data)?
    private struct Operation {
        let interactive: Bool
        var waited: Duration = .zero
        var waitingSince: ContinuousClock.Instant?
        var question: Task<Data, Error>?
    }
    private var operations: [UUID: Operation] = [:]
    private var pendingURLs: [String: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()

    public init(elicitation: Bool = false) {
        client = Client(name: "BlueFatFish", version: "0.9.4", capabilities: .init(elicitation: elicitation ? .init(url: .init()) : nil), configuration: .strict)
    }
    public func onChange(_ handler: @escaping @Sendable (String, String?) -> Void) { changeHandler = handler }
    public func onElicitation(_ handler: @escaping @Sendable (Data) async throws -> Data) { elicitationHandler = handler }
    public func connectProgram(command: String, arguments: [String], environment: [String: String], directory: String, timeout: Double) async throws -> Data {
        let transport = ProgramTransport(command: command, arguments: arguments, environment: environment, directory: directory) { [weak self] in
            Task { await self?.transportClosed() }
        }
        program = transport
        return try await initialize(transport, timeout: timeout)
    }
    public func connectHTTP(endpoint: URL, bearerToken: String, headers: [String: String] = [:], timeout: Double) async throws -> Data {
        try await connectHTTP(endpoint: endpoint, bearerToken: bearerToken, headers: headers, timeout: timeout, authorization: nil, interactiveAuthorization: false)
    }
    public static let oauthLoopbackRedirectURI = OAuthCallback.redirectBase.absoluteString
    public static func validateOAuthClientID(_ clientID: String) throws { try ManagedOAuth.validateClientID(clientID) }
    public static func validateOAuthRegisteredIssuer(_ issuer: String, clientID: String) throws -> URL {
        try ManagedOAuth.validateRegisteredIssuer(issuer, clientID: clientID)
    }

    public func connectOAuth(endpoint: URL, clientID: String, clientAuthentication: MCPOAuthClientAuthentication? = nil, grant: Data?, timeout: Double,
                             browser: (@Sendable (URL) async throws -> Void)? = nil,
                             authorizationNetwork: URLSession? = nil,
                             persist: @escaping @Sendable (Data) async throws -> Void) async throws -> Data {
        let authorization = try ManagedOAuth(endpoint: endpoint, clientID: clientID, clientAuthentication: clientAuthentication, grant: grant,
                                             timeout: timeout, browser: browser, persist: persist, network: authorizationNetwork)
        oauth = authorization
        return try await connectHTTP(endpoint: endpoint, bearerToken: "", headers: [:], timeout: timeout,
                                     authorization: authorization, interactiveAuthorization: browser != nil)
    }
    public func oauthCredentialValues() -> [String] { oauth?.credentialValues() ?? [] }

    private func connectHTTP(endpoint: URL, bearerToken: String, headers: [String: String], timeout: Double,
                             authorization: ManagedOAuth?, interactiveAuthorization: Bool) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let inputTime = elicitationHandler == nil ? 0.0 : 610.0
        configuration.timeoutIntervalForRequest = max(timeout, inputTime); configuration.timeoutIntervalForResource = timeout + max(5, inputTime)
        let transport = HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: true, authorizer: authorization, requestModifier: { request in
            var request = request
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if !bearerToken.isEmpty { request.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization") }
            return request
        })
        let initializeTimeout = timeout + (interactiveAuthorization ? 300 : authorization == nil ? 0 : timeout)
        do { return try await initialize(transport, timeout: initializeTimeout) }
        catch {
            if authorization != nil, case .internalError(let message) = error as? MCPError, let message,
               message.hasPrefix("Authorization flow failed: ") {
                throw MCPConnectionError(String(message.dropFirst("Authorization flow failed: ".count)))
            }
            throw MCPConnectionError.localizeAuthentication(error)
        }
    }
    public func connectSSE(endpoint: URL, bearerToken: String, headers: [String: String] = [:], timeout: Double) async throws -> Data {
        let transport = SSETransport(endpoint: endpoint, bearerToken: bearerToken, headers: headers, timeout: timeout) { [weak self] in Task { await self?.transportClosed() } }
        return try await initialize(transport, timeout: timeout)
    }
    private func transportClosed() async {
        guard !closed else { return }
        await disconnect()
        changeHandler?("disconnected", nil)
    }
    private func initialize(_ transport: any Transport, timeout: Double) async throws -> Data {
        guard !closed else { throw MCPConnectionError("连接已关闭，请重新连接") }
        await client.onNotification(ResourceListChangedNotification.self) { [weak self] _ in await self?.changed("resources", uri: nil) }
        await client.onNotification(PromptListChangedNotification.self) { [weak self] _ in await self?.changed("prompts", uri: nil) }
        await client.onNotification(ResourceUpdatedNotification.self) { [weak self] message in await self?.changed("resource", uri: message.params.uri) }
        if elicitationHandler != nil {
            await client.withElicitationHandler { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                return try await self.elicit(params)
            }
            await client.onNotification(ElicitationCompleteNotification.self) { [weak self] message in await self?.completeURL(message.params.elicitationId) }
        }
        let deadline = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await self?.disconnect()
        }
        defer { deadline.cancel() }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await client.connect(transport: transport) }, onCancel: { Task { await self.disconnect() } })
            try Task.checkCancellation()
            guard !closed else { throw MCPConnectionError("连接已关闭") }
            guard Version.supported.contains(result.protocolVersion) else { throw MCPConnectionError("连接器返回了不支持的 MCP 协议版本") }
            ready = true; supportsTools = result.capabilities.tools != nil
            supportsResources = result.capabilities.resources != nil; supportsPrompts = result.capabilities.prompts != nil
            supportsSubscriptions = result.capabilities.resources?.subscribe == true
            return try JSONEncoder().encode(result)
        } catch { await disconnect(); throw error }
    }
    private func changed(_ kind: String, uri: String?) {
        guard !closed else { return }
        changeHandler?(kind, uri.map { String($0.prefix(4000)) })
    }
    private func completeURL(_ id: String) {
        guard let until = pendingURLs.removeValue(forKey: id), until >= clock.now else { return }
        changed("elicitation-complete", uri: id)
    }
    private func elicit(_ params: CreateElicitation.Parameters) async throws -> CreateElicitation.Result {
        guard ready, !closed, let handler = elicitationHandler, operations.count == 1,
              let (id, operation) = operations.first, operation.interactive, operation.waitingSince == nil else {
            throw MCPError.invalidRequest("User input requires one active tool, resource, or prompt request")
        }
        let data = try JSONEncoder().encode(params)
        guard data.count <= 64_000 else { throw MCPError.invalidParams("Elicitation request exceeds 64KB") }
        if case .url(let url) = params {
            pendingURLs = pendingURLs.filter { $0.value > clock.now }
            if pendingURLs[url.elicitationId] != nil || pendingURLs.count >= 32 { return .init(action: .cancel) }
        }
        let start = clock.now, work = Task { try await handler(data) }
        operations[id]?.waitingSince = start; operations[id]?.question = work
        defer { operations[id]?.waited += start.duration(to: clock.now); operations[id]?.waitingSince = nil; operations[id]?.question = nil }
        let bytes = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        let response = try JSONDecoder().decode(CreateElicitation.Result.self, from: bytes)
        try Task.checkCancellation()
        guard !closed, operations[id] != nil else { throw MCPError.connectionClosed }
        if case .url(let url) = params, response.action == .accept { pendingURLs[url.elicitationId] = clock.now.advanced(by: .seconds(600)) }
        return response
    }
    public func contentCatalog(kind: String, timeout: Double) async throws -> Data {
        guard ready, !closed else { throw MCPConnectionError("连接已断开，请重新连接") }
        guard ["resources", "templates", "prompts"].contains(kind) else { throw MCPConnectionError("未知目录类型") }
        guard kind == "prompts" ? supportsPrompts : supportsResources else { return Data("[]".utf8) }
        var entries: [Data] = [], cursor: String?, seen = Set<String>()
        repeat {
            guard seen.count < 64 else { throw MCPConnectionError("MCP 目录超过 64 页") }
            switch kind {
            case "resources":
                let result = try await request(ListResources.request(try parameters(cursor.map { ["cursor": $0] } ?? [:])), timeout: timeout, preserveProtocolErrors: true)
                entries += try result.resources.map { try JSONEncoder().encode($0) }; cursor = result.nextCursor
            case "templates":
                do {
                    let result = try await request(ListResourceTemplates.request(try parameters(cursor.map { ["cursor": $0] } ?? [:])), timeout: timeout, preserveProtocolErrors: true)
                    entries += try result.templates.map { try JSONEncoder().encode($0) }; cursor = result.nextCursor
                } catch MCPError.methodNotFound { return Data("[]".utf8) }
            default:
                let result = try await request(ListPrompts.request(try parameters(cursor.map { ["cursor": $0] } ?? [:])), timeout: timeout, preserveProtocolErrors: true)
                entries += try result.prompts.map { try JSONEncoder().encode($0) }; cursor = result.nextCursor
            }
            guard entries.count <= 2000 else { throw MCPConnectionError("MCP 目录超过 2000 项") }
            if let cursor, !seen.insert(cursor).inserted { throw MCPConnectionError("连接器返回重复的分页游标") }
        } while cursor != nil
        let objects = try entries.map { try JSONSerialization.jsonObject(with: $0) }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        guard data.count <= 2_000_000 else { throw MCPConnectionError("MCP 目录超过 2MB") }
        return data
    }
    public func readResource(uri: String, timeout: Double) async throws -> Data {
        guard ready, !closed, supportsResources else { throw MCPConnectionError("连接器未连接或不提供资源") }
        let result = try await request(ReadResource.request(try parameters(["uri": uri])), timeout: timeout, preserveProtocolErrors: true, interactive: true)
        return try contentData(result)
    }
    public func prompt(name: String, arguments: [String: String], timeout: Double) async throws -> Data {
        guard ready, !closed, supportsPrompts else { throw MCPConnectionError("连接器未连接或不提供提示词") }
        let result = try await request(GetPrompt.request(try parameters(["name": name, "arguments": arguments])), timeout: timeout, preserveProtocolErrors: true, interactive: true)
        return try contentData(result)
    }
    public func subscribe(uri: String, enabled: Bool, timeout: Double) async throws -> Bool {
        guard ready, !closed, supportsSubscriptions else { return false }
        if enabled { _ = try await request(ResourceSubscribe.request(try parameters(["uri": uri])), timeout: timeout, preserveProtocolErrors: true) }
        else { _ = try await request(ResourceUnsubscribe.request(try parameters(["uri": uri])), timeout: timeout, preserveProtocolErrors: true) }
        return true
    }
    private func contentData<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8_000_000 else { throw MCPConnectionError("MCP 内容超过 8MB，请缩小请求范围") }
        return data
    }
    private func parameters<T: Decodable>(_ values: [String: Any]) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: values)) }
    public func tools(timeout: Double, totalBudget: Bool = false) async throws -> Data {
        guard ready, !closed else { throw MCPConnectionError("连接已断开，请重新连接") }
        guard supportsTools else { return Data("[]".utf8) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var tools: [Tool] = [], cursor: String?, cursors = Set<String>()
        repeat {
            guard cursors.count < 64 else { throw MCPConnectionError("工具目录分页超过 64 页") }
            let remaining = totalBudget ? deadline - ProcessInfo.processInfo.systemUptime : timeout
            guard remaining > 0 else { throw MCPConnectionError("读取工具目录超时") }
            let result = try await request(ListTools.request(cursor.map { .init(cursor: $0) } ?? .init()), timeout: remaining)
            tools += result.tools
            guard tools.count <= 256 else { throw MCPConnectionError("连接器工具数量超过 256") }
            cursor = result.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw MCPConnectionError("连接器返回了重复分页游标") }
        } while cursor != nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tools.sorted { $0.name < $1.name })
        guard data.count <= 1_000_000 else { throw MCPConnectionError("工具目录超过 1MB") }
        return data
    }
    public func call(name: String, arguments: Data, timeout: Double, interactive: Bool = true) async throws -> Data {
        guard ready, !closed, supportsTools else { throw MCPConnectionError("连接器尚未连接或不提供工具") }
        let values = try JSONDecoder().decode([String: Value].self, from: arguments)
        let result = try await request(CallTool.request(.init(name: name, arguments: values)), timeout: timeout, interactive: interactive)
        let data = try JSONEncoder().encode(result)
        guard data.count <= 8_000_000 else { throw MCPConnectionError("工具结果超过 8MB；操作可能已执行，请核对实际状态") }
        return data
    }
    private func request<M: MCP.Method>(_ request: Request<M>, timeout: Double, preserveProtocolErrors: Bool = false, interactive: Bool = false) async throws -> M.Result {
        let id = UUID(), expires = clock.now.advanced(by: .seconds(timeout))
        operations[id] = Operation(interactive: interactive)
        defer { operations[id]?.question?.cancel(); operations[id] = nil }
        let context = try await client.send(request)
        let deadline = Task { [self] in
            try await clock.sleep(until: expires)
            while let operation = operations[id], !closed {
                let now = clock.now, adjusted = expires.advanced(by: operation.waited)
                if operation.waitingSince != nil { try await clock.sleep(until: now.advanced(by: .seconds(1))); continue }
                if adjusted > now { try await clock.sleep(until: adjusted); continue }
                try? await client.cancelRequest(context.requestID, reason: "Client deadline reached")
                await disconnect(); break
            }
        }
        defer { deadline.cancel() }
        do {
            return try await withTaskCancellationHandler(operation: { try await context.value }, onCancel: { [client] in
                Task { try? await client.cancelRequest(context.requestID, reason: "User stopped the task"); await client.disconnect() }
            })
        } catch {
            if interactive, !Task.isCancelled, let protocolError = error as? MCPError,
               case .urlElicitationRequired(_, let urls) = protocolError, !urls.isEmpty, urls.count <= 4, elicitationHandler != nil {
                for url in urls {
                    guard url.mode == "url" else { throw MCPConnectionError("连接器返回了无效的网页确认请求", keepConnection: true) }
                    let choice = try await elicit(.url(.init(message: url.message, url: url.url, elicitationId: url.elicitationId)))
                    guard choice.action == .accept else { throw MCPConnectionError("未完成连接器的网页确认", keepConnection: true) }
                }
                throw MCPConnectionError("已打开确认网页；完成后请重新批准原操作。未自动重试。", keepConnection: true)
            }
            if preserveProtocolErrors, !Task.isCancelled, let protocolError = error as? MCPError, [-32601, -32602, -32002].contains(protocolError.code) { throw protocolError }
            await disconnect()
            let reason = MCPConnectionError.localizeAuthentication(error).localizedDescription
            throw MCPConnectionError("MCP 调用失败或超时，执行结果需核对：" + reason)
        }
    }
    public func disconnect() async {
        closed = true; ready = false
        oauth?.stop()
        pendingURLs = [:]
        for operation in operations.values { operation.question?.cancel() }
        program?.stop()
        await client.disconnect()
    }
    public func processID() -> Int32? { program?.processID }
    public func isReady() -> Bool { ready && !closed }
}
