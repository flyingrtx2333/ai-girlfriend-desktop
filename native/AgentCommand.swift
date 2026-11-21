import Foundation
import Darwin

// A separate supervisor owns the command process group and outlives an app crash.
final class AgentCommand: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xjs.bluefatfish.command.\(UUID().uuidString)", qos: .utility)
    private var pid: pid_t = 0, descriptor: Int32 = -1, errorDescriptor: Int32 = -1
    private var lifetimeDescriptor: Int32 = -1
    private var output = Data(), standardOutput = Data(), errorOutput = Data(), discarded = 0, maximumOutput = 100_000
    private var processSource: DispatchSourceProcess?, readSource: DispatchSourceRead?, errorSource: DispatchSourceRead?
    private var deadline: DispatchWorkItem?, killDeadline: DispatchWorkItem?
    private var cancelled = false, timedOut = false
    private var continuation: CheckedContinuation<AgentToolResult, Error>?

    func cancel() { queue.sync { self.cancelled = true; self.closeLifetime() } }
    func snapshot() -> (running: Bool, output: String) { queue.sync { (self.pid > 0, String(decoding: self.output, as: UTF8.self)) } }
    func run(command: String, workspace: URL, scratch: URL, network: Bool, timeout: Double, readOnly: Bool = false, gitDirectory: URL? = nil, gitWrite: Bool = false, gitConfiguration: Bool = false, maximumOutput: Int = 100_000, protectedData: URL? = nil, inputFile: URL? = nil, outputDescriptor: Int32? = nil, readRoots: [URL] = [], writeRoots: [URL] = [], protectedWrites: [URL] = [], gitTransportAuth: Bool = false, sshClient: Bool = false, listSnapshotParents: Bool = false, environment: [String: String] = [:], arguments: [String]? = nil, shell: String? = nil, inheritEnvironment: Bool = false, workspaceRoots: [URL] = [], leaseDescriptor: Int32? = nil) async throws -> AgentToolResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.maximumOutput = min(2_000_000, max(1000, maximumOutput))
                    do { try self.launch(command: command, workspace: workspace, scratch: scratch, network: network, timeout: timeout, readOnly: readOnly, gitDirectory: gitDirectory, gitWrite: gitWrite, gitConfiguration: gitConfiguration, protectedData: protectedData, inputFile: inputFile, outputDescriptor: outputDescriptor, readRoots: readRoots, writeRoots: writeRoots, protectedWrites: protectedWrites, gitTransportAuth: gitTransportAuth, sshClient: sshClient, listSnapshotParents: listSnapshotParents, extraEnvironment: environment, arguments: arguments, shell: shell, inheritEnvironment: inheritEnvironment, workspaceRoots: workspaceRoots, leaseDescriptor: leaseDescriptor) }
                    catch { self.continuation = nil; continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    private func launch(command: String, workspace: URL, scratch: URL, network: Bool, timeout: Double, readOnly: Bool, gitDirectory: URL?, gitWrite: Bool, gitConfiguration: Bool, protectedData: URL?, inputFile: URL?, outputDescriptor: Int32?, readRoots: [URL], writeRoots: [URL], protectedWrites: [URL], gitTransportAuth: Bool, sshClient: Bool, listSnapshotParents: Bool, extraEnvironment: [String: String], arguments: [String]?, shell: String?, inheritEnvironment: Bool, workspaceRoots: [URL], leaseDescriptor: Int32?) throws {
        if cancelled { throw CancellationError() }
        guard !command.contains("\0"), arguments?.contains(where: { $0.contains("\0") }) != true else { throw PetError("命令或参数不能包含空字符") }
        guard extraEnvironment.allSatisfy({ Self.validEnvironmentName($0.key) && !$0.value.contains("\0") && !Self.launcherEnvironment($0.key) }) else { throw PetError("环境变量名称无效或试图修改隔离启动器") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw PetError("当前系统不支持工作区隔离，终端未执行") }
        guard let supervisor = Bundle.main.url(forAuxiliaryExecutable: "BlueFatFishCommand"),
              FileManager.default.isExecutableFile(atPath: supervisor.path) else { throw PetError("终端进程监控不可用，未执行命令") }
        // Foundation keeps /var as an alias on macOS. Sandbox path filters
        // must instead match the kernel's /private/var path, including denies.
        func kernelPath(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }; return String(cString: resolved)
        }
        let workspacePath = kernelPath(workspace.path), scratchPath = kernelPath(scratch.path)
        let quote: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let systemPaths = ["/System", "/usr", "/bin", "/sbin", "/opt/homebrew", "/Library/Apple", "/Library/Developer", "/Applications/Xcode.app", "/private/etc"]
        // Credential access belongs only to a clean Git transport repository.
        // Project commands and hooks never request this capability.
        let credentialPaths = gitTransportAuth ? [".ssh", ".git-credentials", ".config/git", ".config/gh"].map { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0).path } : []
        let reads = (systemPaths + [workspacePath, scratchPath] + workspaceRoots.map(\.path) + readRoots.map(\.path) + credentialPaths + (gitDirectory.map { [$0.path] } ?? [])).map { "(subpath \(quote(kernelPath($0))))" }.joined(separator: " ")
        var parentDirectories = ""
        if listSnapshotParents && readOnly && !network && workspacePath.hasPrefix(scratchPath + "/") {
            // OSV opens each directory on the path to the snapshot from /.
            var parent = URL(fileURLWithPath: scratchPath, isDirectory: true).deletingLastPathComponent()
            while parent.path != "/" {
                parentDirectories += " (literal \(quote(parent.path)))"
                parent.deleteLastPathComponent()
            }
        }
        let gitConfig = gitConfiguration ? [".gitconfig", ".config/git/config", ".config/git/ignore"].map { "(literal \(quote(kernelPath(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0).path))))" }.joined(separator: " ") : ""
        let writes = ([scratchPath] + (readOnly ? [] : [workspacePath] + workspaceRoots.map(\.path)) + writeRoots.map(\.path) + (gitWrite ? gitDirectory.map { [$0.path] } ?? [] : [])).map { "(subpath \(quote(kernelPath($0))))" }.joined(separator: " ")
        let protectedGit = gitWrite ? "" : ([workspacePath] + workspaceRoots.map { kernelPath($0.path) }).map { "(deny file-write* (subpath \(quote($0 + "/.git"))))" }.joined(separator: " ")
        let extraProtectedWrites = protectedWrites.map { "(deny file-write* (subpath \(quote(kernelPath($0.path)))))" }.joined(separator: " ")
        let readExceptions = ([scratchPath] + readRoots.map { kernelPath($0.path) }).map { "(require-not (subpath \(quote($0))))" }.joined(separator: " ")
        let privateData = protectedData.map { "(deny file-read-data (require-all (subpath \(quote(kernelPath($0.path)))) \(readExceptions))) (deny file-write* (require-all (subpath \(quote(kernelPath($0.path)))) (require-not (subpath \(quote(scratchPath))))))" } ?? ""
        let profile = """
        (version 1)(deny default)
        (allow process*)(allow sysctl-read)(allow file-read-metadata)
        (allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.logd") (global-name "com.apple.cfprefsd.agent") (global-name "com.apple.cfprefsd.daemon"))
        \(gitTransportAuth ? "(allow mach-lookup (global-name \"com.apple.securityd\") (global-name \"com.apple.trustd\") (global-name \"com.apple.trustd.agent\"))" : "")
        \(gitTransportAuth || sshClient ? "(allow mach-lookup (global-name \"com.apple.system.opendirectoryd.libinfo\"))" : "")
        (allow file-read* \(reads) \(parentDirectories) \(gitConfig) (literal "/") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))
        (allow file-write* \(writes) (literal "/dev/null"))
        \(protectedGit)
        \(extraProtectedWrites)
        \(privateData)
        (deny file-write* (subpath \(quote(kernelPath(Bundle.main.bundleURL.path)))))
        \(network ? "(allow network*)" : "")
        """
        var descriptors: [Int32] = [0, 0], errors: [Int32] = [0, 0], lifetime: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw PetError("终端输出管道不可用") }
        guard pipe(&errors) == 0 else { descriptors.forEach { close($0) }; throw PetError("终端错误管道不可用") }
        guard pipe(&lifetime) == 0 else { (descriptors + errors).forEach { close($0) }; throw PetError("终端进程监控管道不可用") }
        var spawned = false
        defer { if !spawned { (descriptors + errors + lifetime).forEach { close($0) } } }
        guard fcntl(lifetime[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(lifetime[1], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(lifetime[1], F_SETNOSIGPIPE, 1) == 0 else { throw PetError("无法配置终端进程监控管道") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addchdir_np(&actions, workspacePath)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, inputFile?.path ?? "/dev/null", O_RDONLY, 0)
        guard posix_spawn_file_actions_adddup2(&actions, outputDescriptor ?? descriptors[1], STDOUT_FILENO) == 0 else {
            throw PetError("无法连接命令输出")
        }
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0]); posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addclose(&actions, errors[0]); posix_spawn_file_actions_addclose(&actions, errors[1])
        if let leaseDescriptor {
            let target = [Int32(9), 10, 11].first { $0 != leaseDescriptor && $0 != lifetime[0] }!
            guard posix_spawn_file_actions_adddup2(&actions, leaseDescriptor, target) == 0 else { throw PetError("无法为终端保留操作锁") }
        }
        guard posix_spawn_file_actions_addinherit_np(&actions, lifetime[0]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw PetError("无法配置终端进程监控") }
        let invocation = arguments.map { [command] + $0 } ?? [shell ?? "/bin/sh", "-c", command]
        let launchArguments = [supervisor.path, String(getpid()), String(lifetime[0]), "-p", profile] + invocation
        var environment = inheritEnvironment ? ProcessInfo.processInfo.environment.filter { Self.validEnvironmentName($0.key) && !Self.launcherEnvironment($0.key) && !$0.value.contains("\0") } : [:]
        // The system Git shim runs xcrun and needs a cache outside this command's
        // writable roots. Reuse the resolved executable without widening access.
        let gitBin = (try? AgentGit.executablePath()).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let toolPath = (["/opt/homebrew/bin", "/usr/local/bin"] + (gitBin.map { [$0] } ?? []) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        let baseEnvironment = ["PATH": toolPath, "HOME": NSHomeDirectory(), "TMPDIR": scratchPath, "LANG": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "XDG_CACHE_HOME": scratchPath + "/cache", "npm_config_cache": scratchPath + "/npm", "XDG_CONFIG_HOME": gitConfiguration ? NSHomeDirectory() + "/.config" : scratchPath + "/config"]
        environment.merge(baseEnvironment) { _, value in value }
        if !gitConfiguration { environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_SYSTEM"] = "/dev/null" }
        environment.merge(extraEnvironment) { _, value in value }
        let argv = launchArguments.map { strdup($0) } + [nil], env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var child: pid_t = 0
        let error = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&child, launchArguments[0], &actions, &attributes, a.baseAddress!, e.baseAddress!) } }
        guard error == 0 else { throw PetError("终端无法启动（\(error)）") }
        spawned = true
        close(descriptors[1]); close(errors[1]); close(lifetime[0])
        pid = child; descriptor = descriptors[0]; errorDescriptor = errors[0]; lifetimeDescriptor = lifetime[1]
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
    static func validEnvironmentName(_ name: String) -> Bool { name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
    static func launcherEnvironment(_ name: String) -> Bool { name.hasPrefix("DYLD_") || name.hasPrefix("__XPC_DYLD_") || name.hasPrefix("LD_") }
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
        guard pid > 0, lifetimeDescriptor >= 0 else { return }
        var request: UInt8 = 1
        guard write(lifetimeDescriptor, &request, 1) == 1 else { closeLifetime(); return }
        let work = DispatchWorkItem { [weak self] in self?.closeLifetime() }
        killDeadline = work; queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func closeLifetime() {
        guard lifetimeDescriptor >= 0 else { return }
        close(lifetimeDescriptor)
        lifetimeDescriptor = -1
    }
    private func finish() {
        guard pid > 0 else { return }
        let child = pid; var status: Int32 = 0; waitpid(child, &status, 0)
        closeLifetime()
        drain(descriptor); drain(errorDescriptor, isError: true); pid = 0; descriptor = -1; errorDescriptor = -1
        deadline?.cancel(); killDeadline?.cancel(); readSource?.cancel(); errorSource?.cancel(); processSource?.cancel()
        readSource = nil; errorSource = nil; processSource = nil
        let stdout = String(decoding: standardOutput, as: UTF8.self), stderr = String(decoding: errorOutput, as: UTF8.self); var text = String(decoding: output, as: UTF8.self)
        if discarded > 0 { text += "\n[输出已截断，省略 \(discarded) 字节]" }
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        text += "\n[exit=\(code)\(timedOut ? ", timeout" : "")]"
        let continuation = self.continuation; self.continuation = nil
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else { continuation?.resume(returning: AgentToolResult(text: text, failed: code != 0 || timedOut, stdout: stdout, stdoutData: standardOutput, stderr: stderr, exitCode: Int(code), truncated: discarded > 0, timedOut: timedOut)) }
    }
}
