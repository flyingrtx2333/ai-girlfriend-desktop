import Foundation
import Network

// A read-only loopback origin lets WebKit use module workers and WASM. Each
// window publishes only its bundled assets and one pinned document snapshot.
final class AgentOfficeHTTP: @unchecked Sendable {
    private let listener: NWListener, queue = DispatchQueue(label: "com.bluefatfish.office-assets")
    private let token = UUID().uuidString + UUID().uuidString
    private let routes: [String: URL]
    private var connections: [ObjectIdentifier: NWConnection] = [:], pending: CheckedContinuation<URL, Error>?
    private var origin = "", stopped = false
    init(assets: URL, document: URL) throws {
        var routes = ["document": document]
        let enumerator = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        while let file = enumerator?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw PetError("办公资源不能包含链接") }
            if values.isRegularFile == true { routes[String(file.path.dropFirst(assets.path.count + 1))] = file }
            guard routes.count <= 2000 else { throw PetError("办公资源数量过多") }
        }
        guard routes["index.html"] != nil else { throw PetError("办公编辑器资源缺失，请重新构建应用") }; self.routes = routes
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                    pending = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        if case .ready = state, let port = listener.port {
                            origin = "http://127.0.0.1:\(port.rawValue)"; finish(.success(URL(string: origin + "/" + token + "/")!))
                        } else if case .failed(let error) = state { finish(.failure(error)); stop() }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, !stopped, connections.count < 32 else { connection.cancel(); return }
                        connections[ObjectIdentifier(connection)] = connection; connection.start(queue: queue)
                        receive(connection, Data())
                        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in if let connection { self?.close(connection) } }
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 5) { [weak self] in guard let self, pending != nil else { return }; finish(.failure(PetError("办公编辑器本机服务未就绪"))); stop() }
                }
            }
        } onCancel: { self.stop() }
    }
    private func finish(_ result: Result<URL, Error>) { guard let pending else { return }; self.pending = nil; pending.resume(with: result) }
    private func close(_ connection: NWConnection) { connections[ObjectIdentifier(connection)] = nil; connection.cancel() }
    func stop() {
        queue.async { [self] in
            guard !stopped else { return }; stopped = true; finish(.failure(CancellationError())); listener.cancel()
            for connection in connections.values { connection.cancel() }; connections.removeAll()
        }
    }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        guard previous.count < 8192 else { send(connection, status: 431); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - previous.count) { [weak self] data, _, complete, error in
            guard let self, !stopped else { connection.cancel(); return }
            var buffer = previous; if let data { buffer.append(data) }
            if let end = buffer.range(of: Data([13, 10, 13, 10])) { handle(connection, Data(buffer[..<end.lowerBound])); return }
            if complete || error != nil { close(connection) } else { receive(connection, buffer) }
        }
    }
    private func handle(_ connection: NWConnection, _ data: Data) {
        guard let text = String(data: data, encoding: .ascii) else { send(connection, status: 400); return }
        let lines = text.components(separatedBy: "\r\n"), parts = (lines.first ?? "").split(separator: " ")
        #if OFFICE_ENGINE_PROBE
        FileHandle.standardError.write(Data(("Office request " + (lines.first ?? "") + "\n").utf8))
        #endif
        guard parts.count == 3, parts[0] == "GET", ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])) else { send(connection, status: 405); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { send(connection, status: 400); return }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { send(connection, status: 400); return }; headers[key] = value
        }
        let raw = String(parts[1]), prefix = "/" + token + "/"
        guard headers["host"] == String(origin.dropFirst(7)), headers["origin"] == nil || headers["origin"] == origin,
              headers["sec-fetch-site"] == nil || ["same-origin", "none"].contains(headers["sec-fetch-site"]!),
              raw.hasPrefix(prefix), !raw.contains("?"), let path = String(raw.dropFirst(prefix.count)).removingPercentEncoding,
              let file = routes[path.isEmpty ? "index.html" : path] else { send(connection, status: 404); return }
        do {
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard bytes.count <= 500 * 1024 * 1024 else { send(connection, status: 413); return }
            let type = file.pathExtension.lowercased(), mime = ["html": "text/html; charset=utf-8", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css", "wasm": "application/wasm", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "png": "image/png", "svg": "image/svg+xml"][type] ?? "application/octet-stream"
            send(connection, status: 200, data: bytes, mime: path == "document" ? "application/octet-stream" : mime)
        } catch { send(connection, status: 404) }
    }
    private func send(_ connection: NWConnection, status: Int, data: Data = Data(), mime: String = "text/plain") {
        #if OFFICE_ENGINE_PROBE
        FileHandle.standardError.write(Data("Office response \(status) bytes \(data.count)\n".utf8))
        #endif
        // The document worker fetches embedded image data URLs before decoding.
        let policy = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data: blob:; connect-src 'self' data: blob:; worker-src 'self' blob:; frame-src 'none'; object-src 'none'; media-src 'none'; form-action 'none'; base-uri 'none'"
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unavailable")\r\nContent-Length: \(data.count)\r\nContent-Type: \(mime)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: \(policy)\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { self?.close(connection); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        })
    }
}
