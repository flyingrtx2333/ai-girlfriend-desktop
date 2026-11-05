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
    func relative(_ url: URL) -> String { url == root ? "." : String(url.path.dropFirst(root.path.count + 1)) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sensitive(_ path: String) -> Bool {
        path.split(separator: "/").contains { part in
            let name = part.lowercased()
            return name == ".env" || name.hasPrefix(".env.") || name == ".ssh" || name == ".gnupg" || name == ".git" || ["credentials.py", "credentials.json"].contains(name)
                || ["pem", "p12", "pfx", "key", "keychain-db"].contains((name as NSString).pathExtension)
        }
    }
    private func parentDescriptor(_ url: URL, create: Bool) throws -> (Int32, String) {
        let parts = relative(url).split(separator: "/").map(String.init)
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
    func writeData(_ data: Data, to url: URL, permissions: Int = 0o644) throws {
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
        guard fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func remove(_ url: URL) throws {
        let (parent, name) = try parentDescriptor(url, create: false); defer { close(parent) }
        guard unlinkat(parent, name, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func read(_ path: String, offset: Int, limit: Int) throws -> String {
        try readResolved(resolve(path), offset: offset, limit: limit)
    }
    func readResolved(_ url: URL, offset: Int, limit: Int) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? Int ?? 0) <= 4_000_000 else { throw PetError("文件较大，请用搜索定位内容或通过终端分段读取") }
        let data = try readData(url)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw PetError("这是二进制或非 UTF-8 文件，请使用对应文档工具") }
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
        let directory = try resolve(path), root = self.root
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
                let relative = String(url.path.dropFirst(root.path.count + 1))
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
