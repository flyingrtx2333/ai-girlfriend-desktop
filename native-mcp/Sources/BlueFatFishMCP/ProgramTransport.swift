import Foundation
import Darwin
import MCP
import Logging

// The SDK's stdio transport wakes every 10ms. Use dispatch I/O for this
// desktop app; the SDK still owns framing-independent MCP/session semantics.
actor ProgramTransport: Transport {
    nonisolated let logger = Logger(label: "com.xjs.bluefatfish.mcp", factory: { _ in SwiftLogNoOpLogHandler() })
    private nonisolated let io: ProgramIO
    init(command: String, arguments: [String], environment: [String: String], directory: String) { io = ProgramIO(command: command, arguments: arguments, environment: environment, directory: directory) }
    nonisolated var processID: Int32? { io.processID }
    nonisolated func stop() { io.stop() }
    func connect() async throws { try await io.connect() }
    func disconnect() async { io.stop() }
    func receive() -> AsyncThrowingStream<Data, Error> { io.receive() }
    func send(_ data: Data) async throws { try await io.send(data) }
}

private final class ProgramIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xjs.bluefatfish.mcp.program", qos: .utility)
    private let command: String, arguments: [String], environment: [String: String], directory: String
    private var pid: pid_t = 0, closed = false
    private var reader: DispatchSourceRead?, process: DispatchSourceProcess?, writer: DispatchIO?
    private var pending = Data()
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var processID: Int32? { queue.sync { pid > 0 ? pid : nil } }

    init(command: String, arguments: [String], environment: [String: String], directory: String) {
        self.command = command; self.arguments = arguments; self.environment = environment; self.directory = directory
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }
    func connect() async throws { try queue.sync { try launch() } }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }
    func disconnect() async { stop() }
    func stop() { queue.sync { finish() } }
    private func finish(_ error: Error? = nil) {
        guard !closed else { return }; closed = true
        if pid > 0 { kill(-pid, SIGKILL) }
        writer?.close(flags: .stop); writer = nil; reader?.cancel(); reader = nil
        continuation.finish(throwing: error)
    }
    func send(_ data: Data) async throws {
        guard data.count <= 1_000_000 else { throw MCPConnectionError("MCP 请求超过 1MB") }
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed, let writer = self.writer else { reply.resume(throwing: MCPConnectionError("本机连接已关闭")); return }
                var bytes = data; bytes.append(10)
                let payload = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
                writer.write(offset: 0, data: payload, queue: self.queue) { done, _, error in
                    if done { if error == 0 { reply.resume() } else { reply.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)) } }
                }
            }
        }
    }
    private func launch() throws {
        guard pid == 0, !closed else { throw MCPConnectionError("本机连接不能重复启动") }
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { throw MCPConnectionError("无法创建 MCP 输入管道") }
        guard pipe(&output) == 0 else { input.forEach { close($0) }; throw MCPConnectionError("无法创建 MCP 输出管道") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        // stderr is never protocol data and may contain credentials.
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        for fd in input + output { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([command] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var child: pid_t = 0
        let error = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&child, command, &actions, &attributes, a.baseAddress!, e.baseAddress!) } }
        close(input[0]); close(output[1])
        guard error == 0 else { close(input[1]); close(output[0]); throw MCPConnectionError("本机 MCP 程序无法启动（\(error)）") }
        pid = child
        let inputFD = input[1], outputFD = output[0]
        writer = DispatchIO(type: .stream, fileDescriptor: inputFD, queue: queue) { _ in close(inputFD) }
        _ = fcntl(outputFD, F_SETFL, fcntl(outputFD, F_GETFL) | O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: outputFD, queue: queue)
        reader.setEventHandler { [weak self] in self?.drain(outputFD) }; reader.setCancelHandler { close(outputFD) }
        self.reader = reader; reader.resume()
        let process = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        process.setEventHandler { [self] in
            self.drain(outputFD); var status: Int32 = 0; waitpid(child, &status, 0)
            kill(-child, SIGKILL); self.pid = 0; self.finish(MCPConnectionError("MCP 程序已退出")); self.process?.cancel(); self.process = nil
        }
        self.process = process; process.resume()
    }
    private func drain(_ fd: Int32) {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<32 {
            let count = read(fd, &bytes, bytes.count)
            if count == 0 { finish(MCPConnectionError("MCP 程序关闭了输出")); return }
            if count < 0 { if errno != EAGAIN && errno != EINTR { finish(POSIXError(.EIO)) }; return }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= 8_000_000 else { finish(MCPConnectionError("MCP 消息超过 8MB")); return }
            while let end = pending.firstIndex(of: 10) {
                let message = Data(pending[..<end]); pending = Data(pending[(end + 1)...])
                if message.isEmpty { continue }
                if case .dropped = continuation.yield(message) { finish(MCPConnectionError("MCP 消息过多，连接已关闭")); return }
            }
        }
    }
}
