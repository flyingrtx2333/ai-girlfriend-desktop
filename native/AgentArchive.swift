import Foundation
import Darwin

enum AgentArchive {
    static func resources(_ archive: URL, scratchParent: URL, definitions: [String], hiddenRoots: Set<String> = []) async throws -> [String: Data] {
        let scratch = scratchParent.appendingPathComponent(".extension-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let parent = try AgentFiles(workspace: archive.deletingLastPathComponent().path), data = try parent.readData(parent.literalURL(archive.lastPathComponent), maximum: 20_000_000)
        let pinned = scratch.appendingPathComponent("input.zip"); try data.write(to: pinned)
        func command(_ args: [String], maximum: Int) async throws -> Data {
            let result = try await AgentCommand().run(command: args.map(AgentGit.quote).joined(separator: " "), workspace: scratch, scratch: scratch, network: false, timeout: 8, readOnly: true, maximumOutput: maximum)
            guard !result.failed, result.truncated != true, let data = result.stdoutData else { throw PetError("扩展包读取失败（exit=\(result.exitCode ?? -1)\(result.truncated == true ? "，输出超过上限" : "")）：" + String((result.stderr ?? result.text).prefix(500))) }; return data
        }
        let listing = try await command(["/usr/bin/unzip", "-Z1", pinned.path], maximum: 200_000)
        guard let text = String(data: listing, encoding: .utf8) else { throw PetError("扩展包中的路径不是 UTF-8") }
        let names = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !names.isEmpty, names.count <= 2000, Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == names.count else { throw PetError("扩展包为空、路径重复或资源超过 2000 项") }
        for name in names { guard validPath(name) else { throw PetError("扩展包包含不安全或不支持的路径：" + String(name.prefix(160))) } }
        var prefixes = Set<String>()
        for name in names {
            for definition in definitions where name == definition || name.hasSuffix("/" + definition) {
                let prefix = String(name.dropLast(definition.count))
                if !prefix.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) { prefixes.insert(prefix) }
            }
        }
        guard prefixes.count == 1, let prefix = prefixes.first else { throw PetError("扩展包必须只包含一个完整扩展目录") }
        var result: [String: Data] = [:], total = 0
        for name in names where name.hasPrefix(prefix) && !name.hasSuffix("/") {
            let path = String(name.dropFirst(prefix.count))
            if !included(path, hiddenRoots: hiddenRoots) { continue }
            guard !AgentFiles.sensitive(path), !path.isEmpty else { throw PetError("扩展包包含受保护文件：" + path) }
            let bytes = try await command(["/usr/bin/unzip", "-p", pinned.path, name], maximum: 2_000_000); total += bytes.count
            guard total <= 20_000_000 else { throw PetError("扩展包展开后超过 20MB") }; result[path] = bytes
        }
        // Read members as bytes only. Archive links never become filesystem links.
        return result
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
