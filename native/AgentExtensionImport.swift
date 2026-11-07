import Foundation

@MainActor extension AgentExtensions {
    func importItem(_ url: URL, kind: AgentExtensionKind, project: Bool, workspace: String?) async throws -> AgentExtensionItem {
        let parent = try AgentFiles(workspace: url.deletingLastPathComponent().path), input = try parent.resolve(url.path)
        let values = try input.resourceValues(forKeys: [.isDirectoryKey])
        var resources: [String: Data]
        if kind == .command {
            guard values.isDirectory != true, input.pathExtension.lowercased() == "md" else { throw PetError("命令请选择 Markdown 文件") }
            let data = try parent.readData(input, maximum: 65_536)
            guard let text = String(data: data, encoding: .utf8) else { throw PetError("命令不是 UTF-8 文本") }
            return try create(.command, name: input.deletingPathExtension().lastPathComponent, text: text, project: project, workspace: workspace)
        }
        if values.isDirectory == true { resources = try Self.resourceData(AgentFiles(workspace: input.path)) }
        else if ["zip", "skill"].contains(input.pathExtension.lowercased()) { resources = try await archiveResources(input) }
        else {
            guard input.lastPathComponent == "SKILL.md" else { throw PetError("请选择 SKILL.md、Skill 文件夹、ZIP 或 .skill 文件") }
            resources = ["SKILL.md": try parent.readData(input, maximum: 65_536)]
        }
        try Task.checkCancellation()
        guard let data = resources["SKILL.md"], let text = String(data: data, encoding: .utf8) else { throw PetError("Skill 缺少 UTF-8 的 SKILL.md") }
        let document = try AgentExtensionDocument(text), name = document.metadata["name"] ?? input.deletingPathExtension().lastPathComponent
        guard Self.validName(name), !name.contains(":") else { throw PetError("请在 SKILL.md 的 frontmatter 中填写有效的 name") }
        guard try !catalog(workspace: workspace).contains(where: { $0.kind == .skill && $0.name.lowercased() == name.lowercased() }) else { throw PetError("同名 Skill 已存在，请先查看现有版本") }
        let destinationFiles = try AgentFiles(workspace: project ? workspace : profile.path)
        let base = project ? ".bluefatfish/skills/" : "extensions/skills/"
        let destination = try destinationFiles.resolve(base + name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PetError("同名 Skill 文件夹已存在") }
        // Publish SKILL.md last: incomplete copies are never discoverable.
        var written: [URL] = []
        do {
            for path in resources.keys.sorted() where path != "SKILL.md" {
                try Task.checkCancellation()
                let file = try destinationFiles.resolve(base + name + "/" + path)
                try destinationFiles.writeData(resources[path]!, to: file, permissions: 0o600); written.append(file)
            }
            let definition = try destinationFiles.resolve(base + name + "/SKILL.md")
            try destinationFiles.writeData(data, to: definition, permissions: 0o600); written.append(definition)
        } catch {
            for file in written.reversed() { try? destinationFiles.remove(file) }
            var directories = Set([base + name])
            for path in resources.keys {
                let segments = path.split(separator: "/")
                for count in 0..<max(0, segments.count - 1) { directories.insert(base + name + "/" + segments.prefix(count + 1).joined(separator: "/")) }
            }
            for path in directories.sorted(by: { $0.count > $1.count }) { if let directory = try? destinationFiles.resolve(path) { try? destinationFiles.removeEmptyDirectory(directory) } }
            throw error
        }
        guard let imported = try catalog(workspace: workspace).first(where: { $0.file.path == destination.appendingPathComponent("SKILL.md").path }) else { throw PetError("Skill 已复制但未能载入，请查看扩展状态") }
        return imported
    }
    private func archiveResources(_ archive: URL) async throws -> [String: Data] {
        let scratch = profile.appendingPathComponent(".skill-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? Int ?? Int.max) <= 20_000_000 else { throw PetError("Skill 包必须是 20MB 以内的普通文件") }
        func command(_ args: [String], maximum: Int) async throws -> Data {
            let result = try await AgentCommand().run(command: args.map(AgentGit.quote).joined(separator: " "), workspace: archive.deletingLastPathComponent(), scratch: scratch, network: false, timeout: 8, readOnly: true, maximumOutput: maximum)
            guard !result.failed, result.truncated != true, let data = result.stdoutData else { throw PetError("Skill 包读取失败（exit=\(result.exitCode ?? -1)\(result.truncated == true ? "，输出超过上限" : "")）：" + String((result.stderr ?? result.text).prefix(500))) }; return data
        }
        let listing = try await command(["/usr/bin/unzip", "-Z1", archive.path], maximum: 200_000)
        guard let text = String(data: listing, encoding: .utf8) else { throw PetError("Skill 包中的路径不是 UTF-8") }
        let names = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !names.isEmpty, names.count <= 2000, Set(names).count == names.count else { throw PetError("Skill 包为空、路径重复或资源超过 2000 项") }
        for name in names {
            guard !name.hasPrefix("/"), !name.hasPrefix("-"), !name.contains("\\"), !name.contains("\r"), !name.contains("\0"), !name.contains(where: { "*?[]".contains($0) }),
                  name.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw PetError("Skill 包含不安全或不支持的路径：" + String(name.prefix(160))) }
        }
        let definitions = names.filter { $0 == "SKILL.md" || $0.hasSuffix("/SKILL.md") }.filter { !$0.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) }
        guard definitions.count == 1, let definition = definitions.first else { throw PetError("每次导入的包必须只有一个 SKILL.md") }
        let prefix = String(definition.dropLast("SKILL.md".count)); var result: [String: Data] = [:], total = 0
        for name in names where name.hasPrefix(prefix) && !name.hasSuffix("/") {
            let path = String(name.dropFirst(prefix.count))
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") || ["__MACOSX", "node_modules", "__pycache__"].contains(String($0)) }) { continue }
            guard !AgentFiles.sensitive(path), !path.isEmpty else { throw PetError("Skill 包含受保护文件：" + path) }
            let data = try await command(["/usr/bin/unzip", "-p", archive.path, name], maximum: 2_000_000); total += data.count
            guard total <= 20_000_000 else { throw PetError("Skill 解压资源超过 20MB") }; result[path] = data
        }
        // Each member is read as bytes and written as a regular file; archive
        // symlinks are never created or followed, and unzip never extracts paths.
        return result
    }
}
