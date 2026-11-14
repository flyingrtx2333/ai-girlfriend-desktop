import Foundation
import MCP
import Logging
import EventSource

// Legacy HTTP+SSE uses a GET stream and a server-announced POST endpoint.
// Keep it separate from Streamable HTTP; never reconnect or replay an RPC.
actor SSETransport: Transport {
    nonisolated let logger = Logger(label: "com.xjs.bluefatfish.mcp.sse", factory: { _ in SwiftLogNoOpLogHandler() })
    private let endpoint: URL, session: URLSession, headers: [String: String], bearerToken: String
    private let timeout: Double
    private let onClose: @Sendable () -> Void
    private let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var streamTask: Task<Void, Never>?
    private var waiting: CheckedContinuation<Void, Error>?
    private var postEndpoint: URL?
    private var closed = false, started = false

    init(endpoint: URL, bearerToken: String, headers: [String: String], timeout: Double, onClose: @escaping @Sendable () -> Void) {
        self.endpoint = endpoint; self.bearerToken = bearerToken; self.headers = headers; self.timeout = timeout; self.onClose = onClose
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        // A connected event stream outlives individual RPC deadlines.
        configuration.timeoutIntervalForResource = 604_800
        session = URLSession(configuration: configuration, delegate: SSERedirectPolicy(), delegateQueue: nil)
        (messages, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }
    func connect() async throws {
        guard !started, !closed else { throw MCPConnectionError("SSE 连接已关闭，请重新连接") }
        guard let host = endpoint.host?.lowercased(), !host.isEmpty, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.scheme == "https" || (endpoint.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else { throw MCPConnectionError("SSE 需要 HTTPS 地址；本机可用 HTTP") }
        started = true
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { reply in
                waiting = reply
                streamTask = Task { await listen() }
            }
        }, onCancel: { Task { await self.disconnect() } })
    }
    func receive() -> AsyncThrowingStream<Data, Error> { messages }
    func disconnect() async { finish(MCPConnectionError("SSE 连接已关闭"), unexpected: false) }
    private func finish(_ error: Error, unexpected: Bool = true) {
        guard !closed else { return }; closed = true; postEndpoint = nil
        streamTask?.cancel(); streamTask = nil; session.invalidateAndCancel()
        waiting?.resume(throwing: error); waiting = nil; continuation.finish(throwing: error)
        if unexpected { onClose() }
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !bearerToken.isEmpty { request.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func listen() async {
        do {
            var request = request(endpoint); request.setValue("text/event-stream", forHTTPHeaderField: "Accept"); request.timeoutInterval = 604_800
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.mimeType?.lowercased() == "text/event-stream" else { throw MCPConnectionError("SSE 服务未返回有效事件流") }
            let parser = EventSource.Parser()
            var eventBytes = 0, lineBytes = 0, wasCR = false
            var pending = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard !closed else { return }
                eventBytes += 1
                guard eventBytes <= 8_000_000 else { throw MCPConnectionError("SSE 事件超过 8MB") }
                if byte == 13 || (byte == 10 && !wasCR) {
                    if lineBytes == 0 { eventBytes = 0 }; lineBytes = 0
                } else if byte != 10 || !wasCR { lineBytes += 1 }
                wasCR = byte == 13
                pending.append(byte)
                if byte == 10 || byte == 13 || pending.count >= 16_384 {
                    for event in await parser.events(from: pending) { try handle(event) }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            // An incomplete final event is discarded. A closed stream cannot
            // supply responses to pending RPCs, even if its POST was accepted.
            throw MCPConnectionError("SSE 服务已断开，请重新连接；未完成的调用不会重放")
        } catch { finish(error) }
    }
    private func handle(_ event: EventSource.Event) throws {
        guard !closed else { throw MCPConnectionError("SSE 连接已关闭") }
        switch event.event ?? "message" {
        case "endpoint":
            let address = event.data
            guard postEndpoint == nil, !address.isEmpty, address.utf8.count <= 4000,
                  !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                  let url = URL(string: address, relativeTo: endpoint)?.absoluteURL, url.user == nil, url.password == nil, url.fragment == nil,
                  url.scheme?.lowercased() == endpoint.scheme?.lowercased(), url.host?.lowercased() == endpoint.host?.lowercased(),
                  (url.port ?? (url.scheme == "https" ? 443 : 80)) == (endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)) else { throw MCPConnectionError("SSE 发送地址无效或与配置地址不同源") }
            postEndpoint = url; waiting?.resume(); waiting = nil
        case "message", "":
            guard !event.data.isEmpty else { return }
            guard postEndpoint != nil, let data = event.data.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["jsonrpc"] as? String == "2.0" else { throw MCPConnectionError("SSE 服务返回了无效的 MCP 消息") }
            if case .dropped = continuation.yield(data) { throw MCPConnectionError("SSE 消息过多，连接已关闭") }
        default: break
        }
    }
    func send(_ data: Data) async throws {
        guard !closed, let url = postEndpoint else { throw MCPConnectionError("SSE 尚未连接或已断开") }
        guard data.count <= 1_000_000 else { throw MCPConnectionError("MCP 请求超过 1MB") }
        do {
            var request = request(url); request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MCPConnectionError("SSE 服务未接受请求；操作可能已执行，请核对实际状态") }
            var count = 0
            for try await _ in bytes { count += 1; guard count <= 64_000 else { throw MCPConnectionError("SSE 发送回执超过 64KB") } }
            try Task.checkCancellation()
            guard !closed else { throw MCPConnectionError("SSE 连接已断开") }
        } catch { finish(error); throw error }
    }
}

private extension EventSource.Parser {
    // Feed a chunk on the parser's actor instead of crossing actors per byte.
    func events(from data: Data) -> [EventSource.Event] {
        var events: [EventSource.Event] = []
        for byte in data { consume(byte) }
        while let event = getNextEvent() { events.append(event) }
        return events
    }
}

// Refuse redirects on both channels so credentials and RPC bodies cannot be
// forwarded to an address the user never approved.
private final class SSERedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
