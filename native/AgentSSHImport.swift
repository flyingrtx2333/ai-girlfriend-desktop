import Foundation
import BlueFatFishTerminal
import Darwin

/// Fetches only session JSONL. Remote paths are arguments to a fixed read-only
/// script, and the response is decoded as bytes without extracting an archive.
struct AgentSSHImport: Sendable {
    let profile: URL
    let home: URL?

    static func valid(host: String, root: String) -> Bool {
        guard TerminalSurface.validSSHDestination(host), root.utf8.count <= 4096,
              root.rangeOfCharacter(from: .controlCharacters) == nil,
              root == "~" || root.hasPrefix("~/") || root.hasPrefix("/") else { return false }
        return !root.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    private static func validFile(_ path: String, source: AgentImportSource) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, path.utf8.count <= 16_384,
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              AgentImportReaders.sessionDirectories(source).contains(String(components[0])),
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
              let file = components.last, file.hasSuffix(".jsonl") else { return false }
        return source == .codex || UUID(uuidString: String(file.dropLast(6))) != nil
    }

    func discover(_ route: AgentImportRoute) async throws -> [AgentImportCandidate] {
        let directories = AgentImportReaders.sessionDirectories(route.source)
        let pattern = route.source == .codex ? "*.jsonl" : "????????-????-????-????-????????????.jsonl"
        return try await response(route, script: Self.scan, arguments: [String(AgentImportReaders.maximumBytes), pattern] + directories,
                                  timeout: 1800) { input in
            try Self.parseScan(input, route: route)
        }
    }

    func read(_ record: AgentImportCandidate, route: AgentImportRoute) async throws -> AgentImportDocument {
        let prefix = route.root.hasSuffix("/") ? route.root : route.root + "/"
        let file = String(record.file.dropFirst(prefix.count))
        guard record.sshHost == route.sshHost, record.source == route.source, record.category == .tasks,
              record.file.hasPrefix(prefix), Self.validFile(file, source: route.source) else { throw PetError("SSH 记录与原来源不符，请重新检测") }
        let maximum = AgentImportReaders.maximumBytes
        let bytes = try await response(route, script: Self.readFile, arguments: [file, String(maximum + 1)], timeout: 60) { input in
            var reader = ResponseReader(input: input)
            return try reader.record(maximum: maximum)
        }
        return try await Task.detached(priority: .utility) { try Self.decode(bytes, file: file, route: route) }.value
    }

    private static func decode(_ bytes: Data, file: String, route: AgentImportRoute) throws -> AgentImportDocument {
        let prefix = route.root.hasSuffix("/") ? route.root : route.root + "/"
        return try AgentImportReaders.decode(route.source, file: prefix + file, raw: bytes,
            sshHost: route.sshHost, archived: file.hasPrefix("archived_sessions/"))
    }

    private static func parseScan(_ input: FileHandle, route: AgentImportRoute) throws -> [AgentImportCandidate] {
        var reader = ResponseReader(input: input)
        guard try reader.field(limit: 16) == "BFF-SESSIONS-1" else { throw FrameError.invalid }
        var result: [AgentImportCandidate] = [], count = 0
        while true {
            let path = try reader.field(limit: 16_384)
            if path.isEmpty { break }
            count += 1
            guard count <= AgentImportReaders.maximumRecords else { throw PetError("来源超过5000份记录，请选择较小的来源副本") }
            let length = try reader.field(limit: 10)
            let contents: Data?
            if length == "-" || length == "?" { contents = nil }
            else {
                guard let size = Int(length), (0...AgentImportReaders.maximumBytes).contains(size) else { throw FrameError.invalid }
                contents = try reader.body(count: size)
            }
            guard validFile(path, source: route.source) else { continue }
            do {
                guard let contents else { throw PetError(length == "-" ? "来源超过64 MB" : "无法读取远端文件") }
                let candidate = try autoreleasepool { try decode(contents, file: path, route: route).candidate }
                result.append(candidate)
            } catch {
                let file = (path as NSString).lastPathComponent
                let prefix = route.root.hasSuffix("/") ? route.root : route.root + "/"
                let id = "invalid-" + AgentFiles.hash(Data(path.utf8))
                result.append(.init(source: route.source, sourceID: id, file: prefix + path, rawHash: "", sourceHash: "",
                    title: file, created: Date(), updated: Date(), issue: error.localizedDescription, sshHost: route.sshHost))
            }
        }
        guard try !reader.hasByte() else { throw FrameError.invalid }
        return result.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id < $1.id }
    }

    private enum FrameError: LocalizedError, Equatable {
        case incomplete, invalid

        var errorDescription: String? { "SSH 会话目录传输不完整或格式异常，请重新检测" }
    }

    private struct ResponseReader {
        let input: FileHandle
        private var buffer = Data(), offset = 0

        init(input: FileHandle) { self.input = input }

        mutating func hasByte() throws -> Bool {
            if offset < buffer.count { return true }
            buffer = try autoreleasepool { try input.read(upToCount: 64 * 1024) ?? Data() }
            offset = 0
            return !buffer.isEmpty
        }

        mutating func field(limit: Int) throws -> String {
            var bytes = Data()
            while try hasByte() {
                let end = buffer[offset...].firstIndex(of: 0)
                let next = end ?? buffer.count
                guard bytes.count + next - offset <= limit else { throw FrameError.invalid }
                bytes.append(buffer[offset..<next])
                offset = next
                if end != nil {
                    offset += 1
                    guard let field = String(data: bytes, encoding: .utf8) else { throw FrameError.invalid }
                    return field
                }
            }
            throw FrameError.incomplete
        }

        mutating func body(count: Int) throws -> Data {
            var bytes = Data()
            bytes.reserveCapacity(count)
            while bytes.count < count {
                guard try hasByte() else { throw FrameError.incomplete }
                let next = min(buffer.count, offset + count - bytes.count)
                bytes.append(buffer[offset..<next])
                offset = next
            }
            return bytes
        }

        mutating func record(maximum: Int) throws -> Data {
            var bytes = Data()
            while try hasByte() {
                let chunk = buffer[offset...]
                guard chunk.count <= maximum - bytes.count else { throw PetError("来源超过64 MB，请选择较小的记录") }
                bytes.append(chunk)
                offset = buffer.count
            }
            return bytes
        }
    }

    private func response<Value>(_ route: AgentImportRoute, script: String, arguments: [String], timeout: Double,
                                 decode: @escaping @Sendable (FileHandle) throws -> Value) async throws -> Value {
        guard let host = route.sshHost, Self.valid(host: host, root: route.root), route.category == .tasks, route.workspace == nil else {
            throw PetError("请填写有效的 SSH 主机与远程目录")
        }
        try Task.checkCancellation()
        let scratch = profile.appendingPathComponent("ssh-import-transfer-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("read-session.sh")
        try Data((Self.enterDirectory + script).utf8).write(to: input)
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw PetError("无法打开 SSH 传输管道") }
        let reader = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        guard descriptors.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else { throw PetError("无法配置 SSH 传输管道") }
        let command = AgentCommand()
        async let transfer: Void = run(command, host: host, root: route.root, arguments: arguments, scratch: scratch,
                                       input: input, output: writer, timeout: timeout)
        let parsed: Result<Value, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try decode(reader) }
                try? reader.close()
                continuation.resume(returning: result)
            }
        }
        switch parsed {
        case .success(let value):
            try await transfer
            try Task.checkCancellation()
            return value
        case .failure(let error as FrameError) where error == .incomplete:
            try await transfer
            throw error
        case .failure(let error):
            command.cancel()
            _ = try? await transfer
            try Task.checkCancellation()
            throw error
        }
    }

    private func run(_ command: AgentCommand, host: String, root: String, arguments: [String], scratch: URL,
                     input: URL, output: FileHandle, timeout: Double) async throws {
        defer { try? output.close() }
        let fm = FileManager.default
        let systemHome = fm.homeDirectoryForCurrentUser
        let privateHome = home.flatMap { $0.standardizedFileURL == systemHome.standardizedFileURL ? nil : $0 }
        let sshDirectory = (privateHome ?? systemHome).appendingPathComponent(".ssh", isDirectory: true)
        var ssh = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
                   "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no",
                   "-o", "ControlPath=none", "-o", "ForkAfterAuthentication=no", "-o", "StdinNull=no", "-o", "PermitLocalCommand=no",
                   "-o", "RemoteCommand=none", "-o", "SessionType=default", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        if privateHome != nil { ssh += ["-F", sshDirectory.appendingPathComponent("config").path] }
        let remote = "/bin/sh -s -- " + ([root] + arguments).map(Self.shellQuote).joined(separator: " ")
        ssh += ["--", host, remote]
        var environment = ["SSH_ASKPASS_REQUIRE": "never"]
        if privateHome == nil { environment["SSH_AUTH_SOCK"] = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] }
        let result = try await command.run(command: "/usr/bin/ssh", workspace: scratch, scratch: scratch, network: true,
            timeout: timeout, readOnly: true, maximumOutput: 8192, protectedData: profile, inputFile: input, outputDescriptor: output.fileDescriptor,
            readRoots: [sshDirectory], sshClient: true, environment: environment,
            arguments: ssh)
        if result.timedOut == true { throw PetError("读取 SSH 会话超时，请重新检测") }
        if result.failed {
            let diagnostic = result.stderr?.lowercased() ?? ""
            if diagnostic.contains("host identification has changed") { throw PetError("SSH 主机密钥已变化，请核对主机身份") }
            if diagnostic.contains("host key verification failed") { throw PetError("SSH 主机尚未验证，请先核对已知主机密钥") }
            if diagnostic.contains("permission denied") && result.exitCode == 255 { throw PetError("SSH 无法使用当前密钥登录，请检查本机配置") }
            if result.exitCode == 42 { throw PetError("找不到远程会话目录，或目录不可读取") }
            if result.exitCode == 43 { throw PetError("远端来源文件已移动、不可读取或是链接，请重新检测") }
            throw PetError("无法读取 SSH 来源，请检查连接与远端目录后重试")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let enterDirectory = #"""
    export PATH=/usr/bin:/bin LC_ALL=C
    root=$1
    shift
    case "$root" in
        '~') root="$HOME" ;;
        '~/'*) root="$HOME/${root#??}" ;;
    esac
    cd -P "$root" || exit 42
    """# + "\n"

    private static let scan = #"""
    limit=$1
    pattern=$2
    shift 2
    found=no
    printf 'BFF-SESSIONS-1\0'
    for directory do
        [ -d "$directory" ] && [ ! -L "$directory" ] || continue
        found=yes
        find "$directory" -name '.*' -prune -o -type f -name "$pattern" -exec /bin/sh -c '
            limit=$1
            shift
            for file do
                if ! size=$(wc -c 2>/dev/null < "$file"); then
                    printf "%s\0?\0" "$file"
                    continue
                fi
                size=$((size + 0))
                if [ "$size" -gt "$limit" ]; then
                    printf "%s\0-\0" "$file"
                else
                    printf "%s\0%s\0" "$file" "$size"
                    head -c "$size" "$file" || exit 43
                fi
            done
        ' read-sessions "$limit" {} + || exit 43
    done
    [ "$found" = yes ] || exit 42
    printf '\0'
    """#

    private static let readFile = #"""
    file=$1
    parent=${file%/*}
    here=$(pwd -P)
    target=$(cd -P "$parent" && pwd -P) || exit 43
    [ "$target" = "${here%/}/$parent" ] && [ -f "$file" ] && [ ! -L "$file" ] || exit 43
    head -c "$2" "$file" || exit 43
    """#
}
