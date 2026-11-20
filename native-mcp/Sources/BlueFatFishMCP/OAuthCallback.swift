import Foundation
import Network
import MCP

// The browser returns to an ephemeral listener bound to the IPv4 loopback.
final class OAuthCallback: OAuthAuthorizationDelegate, @unchecked Sendable {
    static let redirectBase = URL(string: "http://127.0.0.1/oauth/callback")!
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.xjs.bluefatfish.mcp-oauth-callback")
    private let open: @Sendable (URL) async throws -> Void
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: AsyncThrowingStream<URL, Error>.Continuation?
    private var redirectURI: URL?, nonce: String?
    private var requests: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    init(open: @escaping @Sendable (URL) async throws -> Void) throws {
        self.open = open
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                    ready = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self, !stopped else { return }
                        if case .ready = state, let port = listener.port {
                            var parts = URLComponents(url: Self.redirectBase, resolvingAgainstBaseURL: false)!
                            parts.port = Int(port.rawValue)
                            redirectURI = parts.url; ready?.resume(returning: parts.url!); ready = nil
                        } else if case .failed = state { finish(MCPConnectionError("无法接收浏览器授权，请重试")) }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, !stopped, callback != nil, requests.count < 8 else { connection.cancel(); return }
                        requests[ObjectIdentifier(connection)] = connection
                        connection.start(queue: queue); receive(connection, Data())
                        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
                            if let connection { self?.close(connection) }
                        }
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        if self?.ready != nil { self?.finish(MCPConnectionError("本机授权回调未就绪")) }
                    }
                }
            }
        } onCancel: { stop() }
    }

    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let value = query.first(where: { $0.name == "state" })?.value, !value.isEmpty else { throw MCPConnectionError("授权请求缺少会话编号") }
        let (stream, callback) = AsyncThrowingStream<URL, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        return try await withTaskCancellationHandler {
            // Register the expected state before the browser can navigate back.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !stopped, self.callback == nil else { continuation.resume(throwing: CancellationError()); return }
                    nonce = value; self.callback = callback; continuation.resume()
                }
            }
            try Task.checkCancellation()
            try await open(url)
            for try await address in stream { return address }
            throw CancellationError()
        } onCancel: { stop() }
    }

    func stop() { queue.async { [self] in finish(CancellationError()) } }

    private func finish(_ error: Error) {
        guard !stopped else { return }; stopped = true
        ready?.resume(throwing: error); ready = nil
        callback?.finish(throwing: error); callback = nil; nonce = nil
        listener.cancel()
        for connection in requests.values { connection.cancel() }
        requests.removeAll()
    }

    private func close(_ connection: NWConnection) {
        requests.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
    }

    private func receive(_ connection: NWConnection, _ partial: Data) {
        guard partial.count < 8192 else { reply(connection, callbackURL: nil); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - partial.count) { [weak self] data, _, ended, error in
            guard let self, !stopped else { return }
            var bytes = partial; if let data { bytes.append(data) }
            if let end = bytes.range(of: Data([13, 10, 13, 10])) {
                let url = parse(Data(bytes[..<end.lowerBound]))
                reply(connection, callbackURL: url)
            } else if ended || error != nil { close(connection) }
            else { receive(connection, bytes) }
        }
    }

    private func parse(_ bytes: Data) -> URL? {
        guard let redirectURI, let port = redirectURI.port, let nonce, let text = String(data: bytes, encoding: .ascii) else { return nil }
        let lines = text.components(separatedBy: "\r\n"), request = (lines.first ?? "").split(separator: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        let host = "127.0.0.1:\(port)"
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0",
              hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == host,
              request[1].hasPrefix(Self.redirectBase.path + "?"),
              let url = URLComponents(string: "http://" + host + String(request[1])), url.fragment == nil,
              let fields = url.queryItems, fields.filter({ $0.name == "state" }).map(\.value) == [nonce] else { return nil }
        let codes = fields.filter { $0.name == "code" || $0.name == "error" }
        guard codes.count == 1, codes[0].value?.isEmpty == false else { return nil }
        return url.url
    }

    private func reply(_ connection: NWConnection, callbackURL: URL?) {
        let result = callbackURL == nil ? "400 Bad Request" : "200 OK"
        let message = callbackURL == nil ? "此请求与当前小鲸授权不符。" : "已收到授权响应，请返回小鲸。"
        let headers = "HTTP/1.1 \(result)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n\r\n"
        // Reserve the callback before writing the response so a duplicate cannot replace it.
        let resolved = callbackURL.flatMap { url -> (URL, AsyncThrowingStream<URL, Error>.Continuation)? in
            guard let callback else { return nil }; self.callback = nil; nonce = nil; return (url, callback)
        }
        connection.send(content: Data((headers + message).utf8), completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
            if let (url, callback) = resolved { callback.yield(url); callback.finish() }
        })
    }
}
