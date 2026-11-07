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
        try await AgentArchive.resources(archive, scratchParent: profile, definitions: ["SKILL.md"])
    }
}
