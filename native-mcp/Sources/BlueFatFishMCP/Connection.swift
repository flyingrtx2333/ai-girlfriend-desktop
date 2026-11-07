import Foundation
import MCP

public struct MCPConnectionError: LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// Keep SDK types behind the library boundary so the AppKit executable can
// retain its existing Swift 5 build and Objective-C speech bridge.
public actor MCPConnection {
    private let client = Client(name: "BlueFatFish", version: "0.9.4", configuration: .strict)
    private var program: ProgramTransport?
    private var ready = false, closed = false
    private var supportsTools = false
    private var supportsResources = false, supportsPrompts = false, supportsSubscriptions = false
    private var changeHandler: (@Sendable (String, String?) -> Void)?

    public init() {}
    public func onChange(_ handler: @escaping @Sendable (String, String?) -> Void) { changeHandler = handler }
    public func connectProgram(command: String, arguments: [String], environment: [String: String], directory: String, timeout: Double) async throws -> Data {
        let transport = ProgramTransport(command: command, arguments: arguments, environment: environment, directory: directory)
        program = transport
        return try await initialize(transport, timeout: timeout)
    }
    public func connectHTTP(endpoint: URL, bearerToken: String, timeout: Double) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout + 5
        let transport = HTTPClientTransport(endpoint: endpoint, configuration: configuration, streaming: true, requestModifier: { request in
            var request = request
            if !bearerToken.isEmpty { request.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization") }
            return request
        })
        return try await initialize(transport, timeout: timeout)
    }
    private func initialize(_ transport: any Transport, timeout: Double) async throws -> Data {
        guard !closed else { throw MCPConnectionError("连接已关闭，请重新连接") }
        await client.onNotification(ResourceListChangedNotification.self) { [weak self] _ in await self?.changed("resources", uri: nil) }
        await client.onNotification(PromptListChangedNotification.self) { [weak self] _ in await self?.changed("prompts", uri: nil) }
        await client.onNotification(ResourceUpdatedNotification.self) { [weak self] message in await self?.changed("resource", uri: message.params.uri) }
        let deadline = Task { [client] in
            try await Task.sleep(for: .seconds(timeout))
            await client.disconnect()
        }
        defer { deadline.cancel() }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await client.connect(transport: transport) }, onCancel: { [client] in Task { await client.disconnect() } })
            try Task.checkCancellation()
            guard !closed else { throw MCPConnectionError("连接已关闭") }
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
        let result = try await request(ReadResource.request(try parameters(["uri": uri])), timeout: timeout, preserveProtocolErrors: true)
        return try contentData(result)
    }
    public func prompt(name: String, arguments: [String: String], timeout: Double) async throws -> Data {
        guard ready, !closed, supportsPrompts else { throw MCPConnectionError("连接器未连接或不提供提示词") }
        let result = try await request(GetPrompt.request(try parameters(["name": name, "arguments": arguments])), timeout: timeout, preserveProtocolErrors: true)
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
    public func tools(timeout: Double) async throws -> Data {
        guard ready, !closed else { throw MCPConnectionError("连接已断开，请重新连接") }
        guard supportsTools else { return Data("[]".utf8) }
        var tools: [Tool] = [], cursor: String?, cursors = Set<String>()
        repeat {
            guard cursors.count < 64 else { throw MCPConnectionError("工具目录分页超过 64 页") }
            let result = try await request(ListTools.request(cursor.map { .init(cursor: $0) } ?? .init()), timeout: timeout)
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
    public func call(name: String, arguments: Data, timeout: Double) async throws -> Data {
        guard ready, !closed, supportsTools else { throw MCPConnectionError("连接器尚未连接或不提供工具") }
        let values = try JSONDecoder().decode([String: Value].self, from: arguments)
        let result = try await request(CallTool.request(.init(name: name, arguments: values)), timeout: timeout)
        let data = try JSONEncoder().encode(result)
        guard data.count <= 8_000_000 else { throw MCPConnectionError("工具结果超过 8MB；操作可能已执行，请核对实际状态") }
        return data
    }
    private func request<M: MCP.Method>(_ request: Request<M>, timeout: Double, preserveProtocolErrors: Bool = false) async throws -> M.Result {
        let context = try await client.send(request)
        let deadline = Task { [client] in
            try await Task.sleep(for: .seconds(timeout))
            try? await client.cancelRequest(context.requestID, reason: "Client deadline reached")
            await client.disconnect()
        }
        defer { deadline.cancel() }
        do {
            return try await withTaskCancellationHandler(operation: { try await context.value }, onCancel: { [client] in
                Task { try? await client.cancelRequest(context.requestID, reason: "User stopped the task"); await client.disconnect() }
            })
        } catch {
            if preserveProtocolErrors, !Task.isCancelled, let protocolError = error as? MCPError, [-32601, -32602, -32002].contains(protocolError.code) { throw protocolError }
            await disconnect()
            throw MCPConnectionError("MCP 调用失败或超时，执行结果需核对：" + error.localizedDescription)
        }
    }
    public func disconnect() async {
        closed = true; ready = false
        program?.stop()
        await client.disconnect()
    }
    public func processID() -> Int32? { program?.processID }
    public func isReady() -> Bool { ready && !closed }
}
