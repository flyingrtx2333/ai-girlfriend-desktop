import Foundation
import Darwin

struct AgentSkillPackage: Sendable {
    let name: String
    let text: String
    let resources: [String: Data]

    init(resources: [String: Data], fallbackName: String) throws {
        guard let data = resources["SKILL.md"], let text = String(data: data, encoding: .utf8) else {
            throw PetError("Skill 缺少 UTF-8 的 SKILL.md")
        }
        let document = try AgentExtensionDocument(text)
        let name = document.metadata["name"] ?? fallbackName
        guard AgentExtensions.validName(name), !name.contains(":") else { throw PetError("请在 SKILL.md 的 frontmatter 中填写有效的 name") }
        self.name = name
        self.text = text
        self.resources = resources
    }

    static func target(_ name: String, files: AgentFiles, project: Bool) throws -> URL {
        guard AgentExtensions.validName(name), !name.contains(":") else { throw PetError("Skill 名称无效") }
        return try files.literalURL((project ? ".bluefatfish/skills/" : "extensions/skills/") + name)
    }

    func publish(to destination: URL, files: AgentFiles) throws {
        try files.publishDirectory(resources, to: destination, label: "Skill") { staging in
            guard try AgentExtensions.resourceData(staging) == resources else { throw PetError("目标磁盘未能完整保留 Skill 的资源路径或内容") }
        }
    }
}

extension AgentFiles {
    func publishDirectory(_ resources: [String: Data], to destination: URL, label: String,
                          executable: Set<String> = [], verify: (AgentFiles) throws -> Void) throws {
        let (parent, name) = try parentDescriptor(destination, create: true)
        defer { close(parent) }
        let temporary = "." + label.lowercased() + "-import-" + UUID().uuidString
        guard mkdirat(parent, temporary, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(temporary)
        defer {
            if let (current, _) = try? parentDescriptor(staging, create: false) {
                if Self.sameDirectory(parent, current) { try? FileManager.default.removeItem(at: staging) }
                close(current)
            }
        }
        let stagingFiles = try AgentFiles(workspace: staging.path, followParentLinks: false)
        guard stagingFiles.root.path == staging.path else { throw PetError(label + " 目标位置已变化，请重新检测") }
        for (path, bytes) in resources {
            try Task.checkCancellation()
            try stagingFiles.writeData(bytes, to: stagingFiles.literalURL(path), permissions: executable.contains(path) ? 0o700 : 0o600, expectedTarget: "missing")
        }
        try verify(stagingFiles)
        let (current, _) = try parentDescriptor(destination, create: false)
        defer { close(current) }
        guard Self.sameDirectory(parent, current) else { throw PetError(label + " 目标位置已变化，请重新检测") }
        // A complete package becomes discoverable in a single, non-replacing rename.
        var directory = stat()
        guard fstatat(parent, temporary, &directory, AT_SYMLINK_NOFOLLOW) == 0, directory.st_mode & S_IFMT == S_IFDIR else {
            throw PetError(label + " 临时目录已变化，请重新检测")
        }
        if renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) != 0 {
            if errno == EEXIST { throw PetError("同名 " + label + " 文件夹已出现，已保留现有文件") }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func sameDirectory(_ first: Int32, _ second: Int32) -> Bool {
        var a = stat(), b = stat()
        return fstat(first, &a) == 0 && fstat(second, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
}

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
        let package = try AgentSkillPackage(resources: resources, fallbackName: input.deletingPathExtension().lastPathComponent)
        guard try !catalog(workspace: workspace).contains(where: { $0.kind == .skill && $0.name.lowercased() == package.name.lowercased() }) else { throw PetError("同名 Skill 已存在，请先查看现有版本") }
        let destinationFiles = try AgentFiles(workspace: project ? workspace : profile.path, followParentLinks: false)
        let destination = try AgentSkillPackage.target(package.name, files: destinationFiles, project: project)
        guard try destinationFiles.entryMetadata(destination).kind == "missing" else { throw PetError("同名 Skill 文件夹已存在") }
        try package.publish(to: destination, files: destinationFiles)
        guard let imported = try catalog(workspace: workspace).first(where: { $0.file.path == destination.appendingPathComponent("SKILL.md").path }) else { throw PetError("Skill 已复制但未能载入，请查看扩展状态") }
        return imported
    }
    private func archiveResources(_ archive: URL) async throws -> [String: Data] {
        try await AgentArchive.resources(archive, scratchParent: profile, definitions: ["SKILL.md"])
    }
}
