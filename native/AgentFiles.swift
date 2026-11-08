import Foundation
import CryptoKit
import Darwin

struct AgentFiles: Sendable {
    let root: URL
    init(workspace: String?) throws {
        guard let workspace, !workspace.isEmpty else { throw PetError("请先选择项目文件夹") }
        root = URL(fileURLWithPath: workspace, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw PetError("项目文件夹不可用") }
    }
    func resolve(_ path: String) throws -> URL {
        guard !path.contains("\0"), path.utf8.count < 8192 else { throw PetError("文件路径无效") }
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path.isEmpty ? "." : path)).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate == root || candidate.path.hasPrefix(root.path + "/") else { throw PetError("路径超出项目范围，请在界面选择对应项目") }
        return candidate
    }
    func relative(_ url: URL) -> String {
        // Directory enumeration returns /private/var while Foundation roots
        // retain /var. Compare both in the same Foundation path form.
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        return normalized.path == root.path ? "." : String(normalized.path.dropFirst(root.path.count + 1))
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sensitive(_ path: String) -> Bool {
        path.split(separator: "/").contains { part in
            let name = part.lowercased()
            return name == ".env" || name.hasPrefix(".env.") || name == ".ssh" || name == ".gnupg" || name == ".git" || ["credentials.py", "credentials.json"].contains(name)
                || ["pem", "p12", "pfx", "key", "keychain-db"].contains((name as NSString).pathExtension)
        }
    }
    func literalURL(_ path: String) throws -> URL {
        guard !path.contains("\0"), path.utf8.count < 8192 else { throw PetError("文件路径无效") }
        let raw = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        let candidate = raw.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(raw.lastPathComponent)
        guard candidate.path.hasPrefix(root.path + "/") else { throw PetError("路径超出项目范围") }
        return candidate
    }
    func parentDescriptor(_ url: URL, create: Bool) throws -> (Int32, String) {
        let candidate = try literalURL(url.path)
        let parts = String(candidate.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
        guard let name = parts.last, name != ".", parts.allSatisfy({ $0 != ".." }) else { throw PetError("请选择项目中的文件") }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for part in parts.dropLast() {
            var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0 && errno == ENOENT && create {
                if mkdirat(fd, part, 0o755) != 0 && errno != EEXIST { let error = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
                next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard next >= 0 else { let error = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
            close(fd); fd = next
        }
        return (fd, name)
    }
    static func signature(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
    func entryMetadata(_ url: URL) throws -> (kind: String, permissions: Int?, signature: String) {
        do {
            let (parent, name) = try parentDescriptor(url, create: false); defer { close(parent) }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let kind: String
            switch info.st_mode & S_IFMT { case S_IFREG: kind = "file"; case S_IFLNK: kind = "link"; case S_IFDIR: kind = "directory"; default: kind = "special" }
            return (kind, kind == "file" ? Int(info.st_mode & 0o7777) : nil, Self.signature(info))
        } catch let error as POSIXError where error.code == .ENOENT { return ("missing", nil, "missing") }
    }
    private func streamFile(_ url: URL, copyingTo output: Int32? = nil, maximum: Int? = nil) throws -> String {
        let (parent, name) = try parentDescriptor(url, create: false); defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw PetError("不是普通文件") }
        if let maximum, before.st_size > maximum { throw PetError("文件超过大小上限") }
        var total = 0
        var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            total += count
            if let maximum, total > maximum { throw PetError("文件超过大小上限") }
            digest.update(data: Data(buffer.prefix(count)))
            if let output {
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; offset += written
                    }
                }
            }
        }
        var after = stat(); guard fstat(fd, &after) == 0, Self.signature(before) == Self.signature(after) else { throw PetError("读取期间文件已变化，请重新核对") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func fileHash(_ url: URL, maximum: Int? = nil) throws -> String { try streamFile(url, maximum: maximum) }
    @discardableResult func copyFile(_ source: URL, from sourceFiles: AgentFiles, to url: URL, permissions: Int = 0o600, expectedHash: String? = nil, expectedTarget: String? = nil, maximum: Int? = nil) throws -> String {
        let (parent, name) = try parentDescriptor(url, create: true); defer { close(parent) }
        let temporary = ".bluefatfish-\(UUID().uuidString).tmp", fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; defer { close(fd); unlinkat(parent, temporary, 0) }
        let hash = try sourceFiles.streamFile(source, copyingTo: fd, maximum: maximum)
        guard expectedHash == nil || expectedHash == hash else { throw PetError("检查点校验失败") }
        guard fchmod(fd, mode_t(permissions)) == 0, fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if let expectedTarget { guard try entryMetadata(url).signature == expectedTarget else { throw PetError("文件已被其他操作修改，未覆盖你的改动") } }
        guard renameat(parent, temporary, parent, name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return hash
    }
    func symbolicLink(_ url: URL) throws -> String {
        let (parent, name) = try parentDescriptor(url, create: false); defer { close(parent) }
        var bytes = [CChar](repeating: 0, count: 8192)
        let count = readlinkat(parent, name, &bytes, bytes.count)
        guard count >= 0, count < bytes.count else { throw PetError("符号链接不可读取") }
        guard let value = String(data: Data(bytes.prefix(count).map { UInt8(bitPattern: $0) }), encoding: .utf8) else { throw PetError("符号链接不是 UTF-8 路径") }; return value
    }
    func writeSymbolicLink(_ value: String, to url: URL, expectedTarget: String) throws {
        guard !value.contains("\0") else { throw PetError("符号链接无效") }
        let (parent, name) = try parentDescriptor(url, create: true); defer { close(parent) }
        let temporary = ".bluefatfish-\(UUID().uuidString).tmp"; defer { unlinkat(parent, temporary, 0) }
        guard symlinkat(value, parent, temporary) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard try entryMetadata(url).signature == expectedTarget else { throw PetError("文件已被其他操作修改，未覆盖你的改动") }
        guard renameat(parent, temporary, parent, name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func readData(_ url: URL, maximum: Int = 4_000_000) throws -> Data {
        let (parent, name) = try parentDescriptor(url, create: false); defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat(); guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= maximum else { throw PetError("文件不是普通文件或超过大小上限") }
        var data = Data()
        while let chunk = try file.read(upToCount: min(65_536, maximum + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk); guard data.count <= maximum else { throw PetError("文件超过大小上限") }
        }
        return data
    }
    func readPrefix(_ url: URL, maximum: Int) throws -> (data: Data, partial: Bool) {
        let (parent, name) = try parentDescriptor(url, create: false); defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, maximum > 0 else { throw PetError("不是普通文件") }
        var data = Data()
        while data.count < maximum, let chunk = try file.read(upToCount: min(65_536, maximum - data.count)), !chunk.isEmpty {
            try Task.checkCancellation(); data.append(chunk)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Self.signature(before) == Self.signature(after) else { throw PetError("读取期间文件已变化") }
        return (data, before.st_size > data.count)
    }
    func writeData(_ data: Data, to url: URL, permissions: Int = 0o644, expectedTarget: String? = nil) throws {
        let (parent, name) = try parentDescriptor(url, create: true); defer { close(parent) }
        let temporary = ".bluefatfish-\(UUID().uuidString).tmp", fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; offset += count
            }
        }
        guard fchmod(fd, mode_t(permissions)) == 0, fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if let expectedTarget { guard try entryMetadata(url).signature == expectedTarget else { throw PetError("文件已被其他操作修改，未覆盖你的改动") } }
        guard renameat(parent, temporary, parent, name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func remove(_ url: URL) throws {
        let (parent, name) = try parentDescriptor(url, create: false); defer { close(parent) }
        guard unlinkat(parent, name, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func removeEmptyDirectory(_ url: URL) throws {
        let (parent, name) = try parentDescriptor(url, create: false); defer { close(parent) }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func read(_ path: String, offset: Int, limit: Int) throws -> String {
        try readResolved(resolve(path), offset: offset, limit: limit)
    }
    func readResolved(_ url: URL, offset: Int, limit: Int, encoding: AgentTextEncoding? = nil) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? Int ?? 0) <= 4_000_000 else { throw PetError("文件较大，请用搜索定位内容或通过终端分段读取") }
        let data = try readData(url)
        let text = try AgentTextFile.decode(data, encoding: encoding).text
        let lines = text.components(separatedBy: "\n"), start = min(max(1, offset) - 1, lines.count), end = min(lines.count, start + min(500, max(1, limit)))
        var result = "\(relative(url)) · \(lines.count) 行\n"
        for i in start..<end {
            let line = "\(i + 1): \(lines[i])\n"
            if result.utf8.count + line.utf8.count > 40_000 { result += "[内容已截断，请继续分段读取]"; break }; result += line
        }
        return result
    }
    func list(_ path: String) throws -> String {
        try listResolved(resolve(path))
    }
    func listResolved(_ directory: URL) throws -> String {
        let (fd, _) = try parentDescriptor(directory.appendingPathComponent(".directory"), create: false)
        guard let iterator = fdopendir(fd) else { close(fd); throw PetError("目录无法读取") }; defer { closedir(iterator) }
        var entries: [String] = [], count = 0
        while let entry = readdir(iterator) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name == "." || name == ".." { continue }; count += 1
            if count > 20_000 { break }
            entries.append(name + (entry.pointee.d_type == DT_LNK ? " → [符号链接]" : entry.pointee.d_type == DT_DIR ? "/" : ""))
        }
        return entries.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(300).joined(separator: "\n") + (count > 300 ? "\n[仅显示前 300 项]" : "")
    }
    func search(path: String, pattern: String, namesOnly: Bool, excluding: [String] = []) async throws -> String {
        let directory = try resolve(path)
        guard !pattern.isEmpty, pattern.count <= 1000 else { throw PetError("请输入有效搜索内容") }
        let job = Task.detached(priority: .utility) { () throws -> String in
            let ignored = Set([".git", "node_modules", ".build", "build", "dist", ".next", ".venv", "vendor"])
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { throw PetError("目录无法搜索") }
            var output: [String] = [], visited = 0, bytes = 0
            while let url = iterator.nextObject() as? URL {
                try Task.checkCancellation(); visited += 1
                if excluding.contains(where: { url.path.lowercased() == $0 || url.path.lowercased().hasPrefix($0 + "/") }) { iterator.skipDescendants(); continue }
                if Self.sensitive(self.relative(url)) { iterator.skipDescendants(); continue }
                if visited > 20_000 { output.append("[达到扫描上限，请缩小目录]"); break }
                let value = try url.resourceValues(forKeys: Set(keys))
                if value.isSymbolicLink == true || ignored.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
                if value.isDirectory == true { continue }
                let relative = self.relative(url)
                if namesOnly {
                    if relative.localizedCaseInsensitiveContains(pattern) { output.append(relative) }
                } else if !Self.sensitive(relative), (value.fileSize ?? 0) < 1_000_000,
                          let data = try? self.readData(url, maximum: 1_000_000), !data.contains(0), let text = String(data: data, encoding: .utf8) {
                    for (line, content) in text.components(separatedBy: "\n").enumerated() where content.localizedCaseInsensitiveContains(pattern) {
                        let match = "\(relative):\(line + 1): \(String(content.prefix(500)))"; output.append(match); bytes += match.utf8.count
                        if output.count >= 100 || bytes >= 30_000 { break }
                    }
                }
                if output.count >= 100 || bytes >= 30_000 { output.append("[结果已截断，请缩小搜索范围]"); break }
            }
            return output.isEmpty ? "未找到匹配内容" : output.joined(separator: "\n")
        }
        return try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
    }
}
