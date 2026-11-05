import Foundation
import Darwin

// Each command owns a process group. Dispatch sources sleep until output,
// termination or the deadline; cancelling never leaves shell children behind.
final class AgentCommand: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xjs.bluefatfish.command.\(UUID().uuidString)", qos: .utility)
    private var pid: pid_t = 0, descriptor: Int32 = -1, errorDescriptor: Int32 = -1
    private var output = Data(), standardOutput = Data(), errorOutput = Data(), discarded = 0, maximumOutput = 100_000
    private var processSource: DispatchSourceProcess?, readSource: DispatchSourceRead?, errorSource: DispatchSourceRead?
    private var deadline: DispatchWorkItem?, killDeadline: DispatchWorkItem?
    private var cancelled = false, timedOut = false
    private var continuation: CheckedContinuation<AgentToolResult, Error>?

    func cancel() { queue.sync { self.cancelled = true; if self.pid > 0 { kill(-self.pid, SIGKILL) } } }
    func snapshot() -> (running: Bool, output: String) { queue.sync { (self.pid > 0, String(decoding: self.output, as: UTF8.self)) } }
    func run(command: String, workspace: URL, scratch: URL, network: Bool, timeout: Double, readOnly: Bool = false, gitDirectory: URL? = nil, gitWrite: Bool = false, gitConfiguration: Bool = false, maximumOutput: Int = 100_000, protectedData: URL? = nil) async throws -> AgentToolResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.maximumOutput = min(2_000_000, max(1000, maximumOutput))
                    do { try self.launch(command: command, workspace: workspace, scratch: scratch, network: network, timeout: timeout, readOnly: readOnly, gitDirectory: gitDirectory, gitWrite: gitWrite, gitConfiguration: gitConfiguration, protectedData: protectedData) }
                    catch { self.continuation = nil; continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    private func launch(command: String, workspace: URL, scratch: URL, network: Bool, timeout: Double, readOnly: Bool, gitDirectory: URL?, gitWrite: Bool, gitConfiguration: Bool, protectedData: URL?) throws {
        if cancelled { throw CancellationError() }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw PetError("当前系统不支持工作区隔离，终端未执行") }
        let quote: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let systemPaths = ["/System", "/usr", "/bin", "/sbin", "/opt/homebrew", "/Library/Apple", "/Library/Developer", "/Applications/Xcode.app", "/private/etc"]
        let reads = (systemPaths + [workspace.path, scratch.path] + (gitDirectory.map { [$0.path] } ?? [])).map { "(subpath \(quote($0)))" }.joined(separator: " ")
        let gitConfig = gitConfiguration ? [".gitconfig", ".config/git/config", ".config/git/ignore"].map { "(literal \(quote(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0).resolvingSymlinksInPath().path)))" }.joined(separator: " ") : ""
        let writes = ([scratch.path] + (readOnly ? [] : [workspace.path]) + (gitWrite ? gitDirectory.map { [$0.path] } ?? [] : [])).map { "(subpath \(quote($0)))" }.joined(separator: " ")
        let protectedGit = gitWrite ? "" : "(deny file-write* (subpath \(quote(workspace.appendingPathComponent(".git").path))))"
        let privateData = protectedData.map { "(deny file-read-data file-write* (require-all (subpath \(quote($0.path))) (require-not (subpath \(quote(scratch.path))))))" } ?? ""
        let profile = """
        (version 1)(deny default)
        (allow process*)(allow sysctl-read)(allow file-read-metadata)
        (allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.logd") (global-name "com.apple.cfprefsd.agent") (global-name "com.apple.cfprefsd.daemon"))
        (allow file-read* \(reads) \(gitConfig) (literal "/") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))
        (allow file-write* \(writes) (literal "/dev/null"))
        \(protectedGit)
        \(privateData)
        (deny file-write* (subpath \(quote(Bundle.main.bundleURL.path))))
        \(network ? "(allow network*)" : "")
        """
        var descriptors: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw PetError("终端输出管道不可用") }
        guard pipe(&errors) == 0 else { descriptors.forEach { close($0) }; throw PetError("终端错误管道不可用") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addchdir_np(&actions, workspace.path)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0]); posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addclose(&actions, errors[0]); posix_spawn_file_actions_addclose(&actions, errors[1])
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)); posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ["/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", command]
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME=\(NSHomeDirectory())", "TMPDIR=\(scratch.path)", "LANG=en_US.UTF-8", "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0", "XDG_CACHE_HOME=\(scratch.path)/cache", "npm_config_cache=\(scratch.path)/npm"] + (gitConfiguration ? ["XDG_CONFIG_HOME=\(NSHomeDirectory())/.config"] : ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null", "XDG_CONFIG_HOME=\(scratch.path)/config"])
        let argv = arguments.map { strdup($0) } + [nil], env = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var child: pid_t = 0
        let error = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&child, arguments[0], &actions, &attributes, a.baseAddress!, e.baseAddress!) } }
        close(descriptors[1]); close(errors[1])
        guard error == 0 else { close(descriptors[0]); close(errors[0]); throw PetError("终端无法启动（\(error)）") }
        pid = child; descriptor = descriptors[0]; errorDescriptor = errors[0]
        for fd in [descriptor, errorDescriptor] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self] in guard let self else { return }; self.drain(self.descriptor) }
        let fd = descriptor; reader.setCancelHandler { close(fd) }; readSource = reader; reader.resume()
        let errorReader = DispatchSource.makeReadSource(fileDescriptor: errorDescriptor, queue: queue)
        errorReader.setEventHandler { [weak self] in guard let self else { return }; self.drain(self.errorDescriptor, isError: true) }
        let errorFD = errorDescriptor; errorReader.setCancelHandler { close(errorFD) }; errorSource = errorReader; errorReader.resume()
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.finish() }; processSource = source; source.resume()
        let timer = DispatchWorkItem { [weak self] in self?.timedOut = true; self?.terminate() }
        deadline = timer; queue.asyncAfter(deadline: .now() + min(1800, max(1, timeout)), execute: timer)
    }
    private func drain(_ descriptor: Int32, isError: Bool = false) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            guard descriptor >= 0 else { return }
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { return }
            let remaining = max(0, maximumOutput - output.count), kept = min(remaining, count)
            let bytes = buffer.prefix(kept); output.append(contentsOf: bytes)
            if isError { errorOutput.append(contentsOf: bytes) } else { standardOutput.append(contentsOf: bytes) }
            discarded += count - kept
        }
    }
    private func terminate() {
        guard pid > 0 else { return }; kill(-pid, SIGTERM)
        let child = pid, work = DispatchWorkItem { kill(-child, SIGKILL) }
        killDeadline = work; queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func finish() {
        guard pid > 0 else { return }
        let child = pid; var status: Int32 = 0; waitpid(child, &status, 0); kill(-child, SIGKILL)
        drain(descriptor); drain(errorDescriptor, isError: true); pid = 0; descriptor = -1; errorDescriptor = -1
        deadline?.cancel(); killDeadline?.cancel(); readSource?.cancel(); errorSource?.cancel(); processSource?.cancel()
        readSource = nil; errorSource = nil; processSource = nil
        let stdout = String(decoding: standardOutput, as: UTF8.self), stderr = String(decoding: errorOutput, as: UTF8.self); var text = String(decoding: output, as: UTF8.self)
        if discarded > 0 { text += "\n[输出已截断，省略 \(discarded) 字节]" }
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        text += "\n[exit=\(code)\(timedOut ? ", timeout" : "")]"
        let continuation = self.continuation; self.continuation = nil
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else { continuation?.resume(returning: AgentToolResult(text: text, failed: code != 0 || timedOut, stdout: stdout, stdoutData: standardOutput, stderr: stderr, exitCode: Int(code), truncated: discarded > 0)) }
    }
}
