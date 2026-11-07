import Foundation

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
            let path = String(name.dropFirst(prefix.count)), segments = path.split(separator: "/")
            if segments.contains(where: { ["__MACOSX", "node_modules", "__pycache__"].contains(String($0)) }) { continue }
            if segments.enumerated().contains(where: { $0.element.hasPrefix(".") && !($0.offset == 0 && hiddenRoots.contains(String($0.element))) }) { continue }
            guard !AgentFiles.sensitive(path), !path.isEmpty else { throw PetError("扩展包包含受保护文件：" + path) }
            let bytes = try await command(["/usr/bin/unzip", "-p", pinned.path, name], maximum: 2_000_000); total += bytes.count
            guard total <= 20_000_000 else { throw PetError("扩展包展开后超过 20MB") }; result[path] = bytes
        }
        // Read members as bytes only. Archive links never become filesystem links.
        return result
    }
    static func validPath(_ path: String) -> Bool {
        let value = path.hasSuffix("/") ? String(path.dropLast()) : path
        return !value.isEmpty && path.utf8.count <= 1000 && !path.hasPrefix("/") && !path.hasPrefix("-") && !path.contains("\\") && !path.contains(where: { "\r\n\0*?[]".contains($0) }) && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
