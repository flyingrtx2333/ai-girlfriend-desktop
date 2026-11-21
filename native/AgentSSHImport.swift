import Foundation
import BlueFatFishTerminal
import Darwin

/// Fetches only session JSONL. Remote paths are arguments to a fixed read-only
/// script, and the response is decoded as bytes without extracting an archive.
struct AgentSSHImport: Sendable {
    let profile: URL
    let home: URL?
    private static let scanLimit = 256 * 1024 * 1024

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
        let bytes = try await fetch(route, script: Self.scan, arguments: [String(AgentImportReaders.maximumBytes), pattern] + directories,
                                    maximum: Self.scanLimit, timeout: 90)
        return try await Task.detached(priority: .utility) {
            try Self.parseScan(bytes, route: route)
        }.value
    }

    func read(_ record: AgentImportCandidate, route: AgentImportRoute) async throws -> AgentImportDocument {
        let prefix = route.root.hasSuffix("/") ? route.root : route.root + "/"
        let file = String(record.file.dropFirst(prefix.count))
        guard record.sshHost == route.sshHost, record.source == route.source, record.category == .tasks,
              record.file.hasPrefix(prefix), Self.validFile(file, source: route.source) else { throw PetError("SSH 记录与原来源不符，请重新检测") }
        let maximum = AgentImportReaders.maximumBytes
        let bytes = try await fetch(route, script: Self.readFile, arguments: [file, String(maximum + 1)], maximum: maximum + 1, timeout: 60)
        guard bytes.count <= maximum else { throw PetError("来源超过64 MB，请选择较小的记录") }
        return try await Task.detached(priority: .utility) { try Self.decode(bytes, file: file, route: route) }.value
    }

    private static func decode(_ bytes: Data, file: String, route: AgentImportRoute) throws -> AgentImportDocument {
        let prefix = route.root.hasSuffix("/") ? route.root : route.root + "/"
        return try AgentImportReaders.decode(route.source, file: prefix + file, raw: bytes,
            sshHost: route.sshHost, archived: file.hasPrefix("archived_sessions/"))
    }

    private static func parseScan(_ bytes: Data, route: AgentImportRoute) throws -> [AgentImportCandidate] {
        let invalid = PetError("SSH 会话目录在传输中变化，请重新检测")
        var index = bytes.startIndex
        func field(limit: Int) throws -> String {
            let end = index + min(limit + 1, bytes.endIndex - index)
            guard let stop = bytes[index..<end].firstIndex(of: 0),
                  let value = String(data: bytes[index..<stop], encoding: .utf8) else { throw invalid }
            index = stop + 1
            return value
        }
        guard try field(limit: 16) == "BFF-SESSIONS-1" else { throw invalid }
        var result: [AgentImportCandidate] = [], count = 0
        while true {
            let path = try field(limit: 16_384)
            if path.isEmpty { break }
            count += 1
            guard count <= AgentImportReaders.maximumRecords else { throw PetError("来源超过5000份记录，请选择较小的来源副本") }
            let length = try field(limit: 10)
            let contents: Data?
            if length == "-" || length == "?" { contents = nil }
            else {
                guard let size = Int(length), (0...AgentImportReaders.maximumBytes).contains(size),
                      size <= bytes.endIndex - index else { throw invalid }
                contents = bytes.subdata(in: index..<(index + size))
                index += size
            }
            guard validFile(path, source: route.source) else { continue }
            do {
                guard let contents else { throw PetError(length == "-" ? "来源超过64 MB" : "无法读取远端文件") }
                result.append(try decode(contents, file: path, route: route).candidate)
            } catch {
                let file = (path as NSString).lastPathComponent
                let prefix = route.root.hasSuffix("/") ? route.root : route.root + "/"
                let id = "invalid-" + AgentFiles.hash(Data(path.utf8))
                result.append(.init(source: route.source, sourceID: id, file: prefix + path, rawHash: "", sourceHash: "",
                    title: file, created: Date(), updated: Date(), issue: error.localizedDescription, sshHost: route.sshHost))
            }
        }
        guard index == bytes.endIndex else { throw invalid }
        return result.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id < $1.id }
    }

    private func fetch(_ route: AgentImportRoute, script: String, arguments: [String], maximum: Int, timeout: Double) async throws -> Data {
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
        let output = scratch.appendingPathComponent("response").path
        let fd = open(output, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PetError("无法打开 SSH 传输的临时输出") }
        let response = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? response.close() }
        // No unpublished session data remains on disk if the application exits mid-transfer.
        guard unlink(output) == 0 else { throw PetError("无法准备 SSH 传输的临时输出") }
        let systemHome = fm.homeDirectoryForCurrentUser
        let privateHome = home.flatMap { $0.standardizedFileURL == systemHome.standardizedFileURL ? nil : $0 }
        let sshDirectory = (privateHome ?? systemHome).appendingPathComponent(".ssh", isDirectory: true)
        var ssh = ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
                   "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no",
                   "-o", "ControlPath=none", "-o", "ForkAfterAuthentication=no", "-o", "StdinNull=no", "-o", "PermitLocalCommand=no",
                   "-o", "RemoteCommand=none", "-o", "SessionType=default", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        if privateHome != nil { ssh += ["-F", sshDirectory.appendingPathComponent("config").path] }
        let remote = "/bin/sh -s -- " + ([route.root] + arguments).map(Self.shellQuote).joined(separator: " ")
        ssh += ["--", host, remote]
        var environment = ["SSH_ASKPASS_REQUIRE": "never"]
        if privateHome == nil { environment["SSH_AUTH_SOCK"] = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] }
        let command = "ulimit -f \"$1\" || exit 45; shift; exec \"$@\""
        let result = try await AgentCommand().run(command: "/bin/sh", workspace: scratch, scratch: scratch, network: true,
            timeout: timeout, readOnly: true, maximumOutput: 8192, protectedData: profile, inputFile: input, outputDescriptor: fd,
            readRoots: [sshDirectory], sshClient: true, environment: environment,
            arguments: ["-c", command, "ssh-import", String((maximum + 511) / 512)] + ssh)
        if result.timedOut == true { throw PetError("读取 SSH 会话超时，请重新检测") }
        if result.failed {
            let diagnostic = result.stderr?.lowercased() ?? ""
            if diagnostic.contains("host identification has changed") { throw PetError("SSH 主机密钥已变化，请核对主机身份") }
            if diagnostic.contains("host key verification failed") { throw PetError("SSH 主机尚未验证，请先核对已知主机密钥") }
            if diagnostic.contains("permission denied") && result.exitCode == 255 { throw PetError("SSH 无法使用当前密钥登录，请检查本机配置") }
            if result.exitCode == 42 { throw PetError("找不到远程会话目录，或目录不可读取") }
            if result.exitCode == 43 { throw PetError("远端来源文件已移动、不可读取或是链接，请重新检测") }
            if result.exitCode == 128 + Int(SIGXFSZ) { throw PetError("SSH 传输超过读取上限，请选择较小的来源目录") }
            throw PetError("无法读取 SSH 来源，请检查连接与远端目录后重试")
        }
        let size = try response.seekToEnd()
        guard size <= maximum else { throw PetError("SSH 传输超过读取上限，请选择较小的来源目录") }
        try response.seek(toOffset: 0)
        return try response.readToEnd() ?? Data()
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
