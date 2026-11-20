import Foundation
import Darwin

enum AgentArchive {
    static func resources(_ archive: URL, scratchParent: URL, definitions: [String], hiddenRoots: Set<String> = [], repositoryPath: String? = nil) async throws -> [String: Data] {
        let scratch = scratchParent.appendingPathComponent(".extension-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let parent = try AgentFiles(workspace: archive.deletingLastPathComponent().path), data = try parent.readData(parent.literalURL(archive.lastPathComponent), maximum: 20_000_000)
        let pinned = scratch.appendingPathComponent("input.zip"); try data.write(to: pinned)
        func unzip(_ args: [String], maximum: Int) async throws -> Data {
            let result = try await AgentCommand().run(command: "/usr/bin/unzip", workspace: scratch, scratch: scratch, network: false, timeout: 8, readOnly: true, maximumOutput: maximum, arguments: args)
            guard !result.failed, result.truncated != true, let data = result.stdoutData else { throw PetError("扩展包读取失败（exit=\(result.exitCode ?? -1)\(result.truncated == true ? "，输出超过上限" : "")）：" + String((result.stderr ?? result.text).prefix(500))) }; return data
        }
        let listingLimit = repositoryPath == nil ? 200_000 : 2_000_000
        let entryLimit = repositoryPath == nil ? 2000 : 20_000
        let listing = try await unzip(["-Z1", pinned.path], maximum: listingLimit)
        let names: [String]
        if let text = String(data: listing, encoding: .utf8), !text.contains("?") {
            names = text.split(separator: "\n").map(String.init)
        } else {
            // ZipInfo can replace parts of UTF-8 names when printing. Use the
            // directory's exact bytes so unzip receives the original spelling.
            let count = listing.split(separator: 0x0a).count
            guard (1...entryLimit).contains(count) else { throw PetError("扩展包为空或资源数量超过上限") }
            names = try zipDirectoryNames(data, expectedCount: count, limit: listingLimit)
        }
        guard !names.isEmpty, names.count <= entryLimit,
              Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == names.count else { throw PetError("扩展包为空、路径重复或资源数量超过上限") }
        for name in names { guard validPath(name) else { throw PetError("扩展包包含不安全或不支持的路径：" + String(name.prefix(160))) } }
        let prefix = try rootPrefix(in: names, definitions: definitions, repositoryPath: repositoryPath)
        let members = names.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("/") }
        guard members.count <= 2000 else { throw PetError("插件目录资源超过 2000 项") }
        var result: [String: Data] = [:], total = 0
        for name in members {
            let path = String(name.dropFirst(prefix.count))
            if !included(path, hiddenRoots: hiddenRoots) { continue }
            guard !AgentFiles.sensitive(path), !path.isEmpty else { throw PetError("扩展包包含受保护文件：" + path) }
            let bytes = try await unzip(["-p", pinned.path, name], maximum: 2_000_000); total += bytes.count
            guard total <= 20_000_000 else { throw PetError("扩展包展开后超过 20MB") }; result[path] = bytes
        }
        // Read members as bytes only. Archive links never become filesystem links.
        return result
    }

    // ZIP APPNOTE §§4.3.12–4.3.16. Only the directory is read here. The
    // existing isolated unzip command still reads and verifies member data.
    private static func zipDirectoryNames(_ data: Data, expectedCount: Int, limit: Int) throws -> [String] {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func word(_ offset: Int) -> Int { Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
            func long(_ offset: Int) -> Int { Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            func wide(_ offset: Int) -> UInt64 { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
            let invalid = PetError("扩展包的 ZIP 路径目录无效")
            guard bytes.count >= 22 else { throw invalid }
            let last = bytes.count - 22, earliest = max(0, last - 65_535)
            guard let end = (earliest...last).reversed().first(where: { offset in
                long(offset) == 0x06054b50 && word(offset + 20) == last - offset
            }) else { throw invalid }

            var start = long(end + 16), length = long(end + 12), count = word(end + 10), directoryEnd = end
            let locator = end - 20
            if locator >= 0, long(locator) == 0x07064b50 {
                guard long(locator + 4) == 0, long(locator + 16) == 1, let extendedEnd = Int(exactly: wide(locator + 8)),
                      extendedEnd <= locator - 56, long(extendedEnd) == 0x06064b50,
                      wide(extendedEnd + 4) == UInt64(locator - extendedEnd - 12), long(extendedEnd + 16) == 0, long(extendedEnd + 20) == 0,
                      wide(extendedEnd + 24) == UInt64(expectedCount), wide(extendedEnd + 32) == UInt64(expectedCount),
                      let offset = Int(exactly: wide(extendedEnd + 48)), let size = Int(exactly: wide(extendedEnd + 40)) else { throw invalid }
                start = offset; length = size; count = expectedCount; directoryEnd = extendedEnd
            } else {
                guard word(end + 4) == 0, word(end + 6) == 0, word(end + 8) == count else { throw invalid }
            }
            guard count == expectedCount, length <= directoryEnd, start == directoryEnd - length else { throw invalid }

            var cursor = start, nameBytes = 0, result: [String] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                guard directoryEnd - cursor >= 46, long(cursor) == 0x02014b50, word(cursor + 34) == 0 else { throw invalid }
                let size = word(cursor + 28), next = cursor + 46 + size + word(cursor + 30) + word(cursor + 32)
                guard size > 0, next <= directoryEnd else { throw invalid }
                nameBytes += size + 1
                guard nameBytes <= limit else { throw PetError("扩展包的路径清单超过上限") }
                let raw = bytes[(cursor + 46)..<(cursor + 46 + size)]
                guard !raw.contains(where: { $0 < 32 || $0 == 127 }), let name = String(bytes: raw, encoding: .utf8) else {
                    throw PetError("扩展包包含无效的 UTF-8 路径或控制字符")
                }
                result.append(name); cursor = next
            }
            if cursor != directoryEnd {
                guard directoryEnd - cursor >= 6, long(cursor) == 0x05054b50, word(cursor + 4) == directoryEnd - cursor - 6 else { throw invalid }
            }
            return result
        }
    }

    private static func rootPrefix(in names: [String], definitions: [String], repositoryPath: String?) throws -> String {
        if let repositoryPath {
            let roots = Set(names.compactMap { $0.split(separator: "/").first.map(String.init) })
            guard roots.count == 1, let root = roots.first, repositoryPath.isEmpty || validPath(repositoryPath) else {
                throw PetError("仓库归档的目录结构无效")
            }
            let prefix = root + "/" + (repositoryPath.isEmpty ? "" : repositoryPath + "/")
            let candidates = Set(definitions.map { prefix + $0 })
            guard names.contains(where: candidates.contains) else { throw PetError("所选仓库目录缺少插件清单") }
            return prefix
        }
        var prefixes = Set<String>()
        for name in names {
            for definition in definitions where name == definition || name.hasSuffix("/" + definition) {
                let prefix = String(name.dropLast(definition.count))
                if !prefix.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) { prefixes.insert(prefix) }
            }
        }
        let roots = definitions.contains("plugin.json")
            ? prefixes.filter { candidate in !prefixes.contains(where: { $0 != candidate && candidate.hasPrefix($0) }) }
            : prefixes
        guard roots.count == 1, let prefix = roots.first else { throw PetError("扩展包必须只包含一个完整扩展目录") }
        return prefix
    }
    private static func included(_ path: String, hiddenRoots: Set<String>) -> Bool {
        let segments = path.split(separator: "/")
        return !segments.contains(where: { ["__MACOSX", "node_modules", "__pycache__"].contains(String($0)) }) && !segments.enumerated().contains(where: { $0.element.hasPrefix(".") && !($0.offset == 0 && hiddenRoots.contains(String($0.element))) })
    }
    static func directoryResources(_ directory: URL, hiddenRoots: Set<String>, onListed: (() throws -> Void)? = nil) throws -> [String: Data] {
        var original = stat()
        guard lstat(directory.standardizedFileURL.path, &original) == 0, original.st_mode & S_IFMT == S_IFDIR else { throw PetError("请选择插件原文件夹，不支持链接") }
        let files = try AgentFiles(workspace: directory.path)
        func rootSignature() throws -> String {
            var info = stat()
            guard lstat(files.root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw PetError("插件文件夹已变化") }
            return AgentFiles.signature(info)
        }
        func inventory() throws -> [String: String] {
            var failure: Error?
            guard let iterator = FileManager.default.enumerator(at: files.root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in failure = error; return false }) else { throw PetError("插件文件夹无法读取") }
            var result: [String: String] = [:], names = Set<String>(), visited = 0
            result["."] = try rootSignature()
            while let url = iterator.nextObject() as? URL {
                try Task.checkCancellation(); visited += 1
                guard visited <= 5000 else { throw PetError("插件文件夹扫描超过5000项") }
                let literal = try files.literalURL(url.path), path = String(literal.path.dropFirst(files.root.path.count + 1))
                if !included(path, hiddenRoots: hiddenRoots) {
                    var ignored = stat()
                    if lstat(literal.path, &ignored) == 0, ignored.st_mode & S_IFMT == S_IFDIR { iterator.skipDescendants() }
                    continue
                }
                guard validPath(path), !AgentFiles.sensitive(path) else { throw PetError("插件文件夹包含受保护或不支持的路径：" + String(path.prefix(160))) }
                guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted, result.count <= 2000 else { throw PetError("插件文件夹路径重复或资源超过2000项") }
                let metadata = try files.entryMetadata(files.literalURL(path))
                guard ["directory", "file"].contains(metadata.kind) else { throw PetError("插件文件夹不支持链接或特殊文件：" + path) }
                result[path] = metadata.kind + ":" + metadata.signature
            }
            if let failure { throw failure }; return result
        }
        let before = try inventory()
        guard before["."] == AgentFiles.signature(original) else { throw PetError("插件文件夹在读取前已变化") }
        try onListed?()
        var result: [String: Data] = [:], total = 0
        for path in before.keys.sorted() where before[path]!.hasPrefix("file:") {
            try Task.checkCancellation()
            let data = try files.readData(files.literalURL(path), maximum: 2_000_000); total += data.count
            guard total <= 20_000_000 else { throw PetError("插件文件夹资源超过20MB") }; result[path] = data
        }
        guard try inventory() == before else { throw PetError("插件文件夹在读取期间已变化，请重新选择") }
        return result
    }
    static func validPath(_ path: String) -> Bool {
        let value = path.hasSuffix("/") ? String(path.dropLast()) : path
        return !value.isEmpty && path.utf8.count <= 1000 && !path.hasPrefix("/") && !path.hasPrefix("-") && !path.contains("\\") && !path.contains(where: { "\r\n\0*?[]".contains($0) }) && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
