import Foundation

struct AgentSkillImportPlan: Codable {
    let workspace: String?
    let fileCount: Int
}

enum AgentSkillImport {
    private enum Status {
        case ready, installed, shared, conflict
        var issue: String? {
            switch self {
            case .ready: return nil
            case .installed: return "已经导入"
            case .shared: return "已由共享目录提供"
            case .conflict: return "同名 Skill 已存在，保留现有版本"
            }
        }
    }

    static func defaultDirectory(for source: AgentImportSource, home: URL) -> URL {
        let legacy = home.appendingPathComponent(source.homeName + "/skills")
        if source == .qoder { return legacy }
        let current = home.appendingPathComponent(".agents/skills")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return current
    }

    private static func sourceFiles(_ root: URL) throws -> AgentFiles {
        let files = try AgentFiles(workspace: root.path, followParentLinks: false)
        guard files.root.path != "/", files.root.path == root.standardizedFileURL.path else {
            throw PetError("Skill 来源位置已变化，请重新选择文件夹")
        }
        return files
    }

    private static func folders(_ files: AgentFiles, source: AgentImportSource) throws -> [URL] {
        let definition = try files.literalURL("SKILL.md")
        if try files.root.lastPathComponent == "skills" || files.entryMetadata(definition).kind != "missing" { return [files.root] }
        let folders = try containerPaths(for: source).map(files.literalURL).filter { try files.entryMetadata($0).kind == "directory" }
        if !folders.isEmpty { return folders }
        if [source.homeName, ".agents"].contains(files.root.lastPathComponent) { return [] }
        return [files.root]
    }

    static func containerPaths(for source: AgentImportSource) -> [String] {
        source == .codex ? ["skills", ".agents/skills", ".codex/skills"] : ["skills", ".qoder/skills"]
    }

    static func discover(_ source: AgentImportSource, root: URL, workspace: String?) throws -> [AgentImportCandidate] {
        let files = try sourceFiles(root)
        var result: [AgentImportCandidate] = []
        for folder in try folders(files, source: source) {
            let definition = folder.appendingPathComponent("SKILL.md")
            let direct = try files.entryMetadata(definition).kind != "missing"
            let definitions: [URL]
            if direct { definitions = [definition] }
            else {
                let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
                guard contents.count <= 5000 else { throw PetError("Skill 来源项目过多，请选择较小的目录") }
                definitions = try contents.filter { child in
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    return values.isDirectory == true && values.isSymbolicLink != true
                }.map { $0.appendingPathComponent("SKILL.md") }
            }
            for file in definitions.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                try Task.checkCancellation()
                let entry = try files.entryMetadata(file)
                guard entry.kind != "missing" else { continue }
                guard result.count < 5000 else { throw PetError("来源超过 5000 份 Skills，请分别导入") }
                result.append(preview(source, file: file.path, workspace: workspace, date: entry.modified ?? Date()) {
                    try readPackage(file, files: files)
                })
            }
        }
        return result
    }

    static func preview(_ source: AgentImportSource, file: String, workspace: String?, date: Date = Date(), sshHost: String? = nil,
                        package: () throws -> AgentSkillPackage) -> AgentImportCandidate {
        let name = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let sourceID = "skill:" + AgentFiles.hash(Data(file.utf8))
        var record = AgentImportCandidate(source: source, sourceID: sourceID, file: file, rawHash: "", sourceHash: "", title: name,
                                          created: date, updated: date, sshHost: sshHost)
        record.skill = AgentSkillImportPlan(workspace: workspace, fileCount: 0)
        do {
            let skill = try package()
            record.title = skill.name
            record.preview = String(skill.text.prefix(1000))
            record.rawHash = AgentFiles.hash(skill.resources["SKILL.md"]!)
            record.sourceHash = AgentExtensions.digest(skill.resources)
            record.skill = AgentSkillImportPlan(workspace: workspace, fileCount: skill.resources.count)
        } catch { record.issue = error.localizedDescription }
        return record
    }

    static func sourceURL(_ record: AgentImportCandidate, root: URL) throws -> URL {
        guard record.skill != nil, record.sshHost == nil else { throw PetError("缺少本机 Skill 来源") }
        let files = try sourceFiles(root), file = try files.literalURL(record.file)
        let folder = file.deletingLastPathComponent()
        guard file.lastPathComponent == "SKILL.md", try files.entryMetadata(file).kind == "file",
              try folders(files, source: record.source).contains(where: { directory in
                  folder.path == directory.path ||
                  (!folder.lastPathComponent.hasPrefix(".") && folder.deletingLastPathComponent().path == directory.path)
              }) else { throw PetError("Skill 来源已移除或离开检测目录") }
        return file
    }

    private static func readPackage(_ file: URL, files: AgentFiles) throws -> AgentSkillPackage {
        guard try files.entryMetadata(file).kind == "file" else { throw PetError("SKILL.md 需要是普通文件") }
        let folder = file.deletingLastPathComponent()
        let packageFiles = try AgentFiles(workspace: folder.path, followParentLinks: false)
        guard packageFiles.root.path == folder.path else { throw PetError("Skill 来源位置发生变化，请重新检测") }
        return try AgentSkillPackage(resources: AgentExtensions.resourceData(packageFiles), fallbackName: folder.lastPathComponent)
    }

    static func read(_ record: AgentImportCandidate, root: URL) throws -> AgentSkillPackage {
        try validated(readPackage(sourceURL(record, root: root), files: sourceFiles(root)), against: record)
    }

    private static func validated(_ package: AgentSkillPackage, against record: AgentImportCandidate) throws -> AgentSkillPackage {
        guard package.name == record.title, package.resources.count == record.skill?.fileCount,
              AgentExtensions.digest(package.resources) == record.sourceHash else {
            throw PetError("Skill 的说明或资源已变化，请重新检测")
        }
        return package
    }

    @MainActor private static func targetFiles(store: AgentStore, workspace: String?) throws -> AgentFiles {
        if let workspace {
            guard AgentMemory.projects(store: store, preferredTaskID: store.selectedID).contains(where: { $0.workspace == workspace }) else {
                throw PetError("导入目标已离开项目范围")
            }
            let files = try AgentFiles(workspace: workspace, followParentLinks: false)
            guard files.root.path == URL(fileURLWithPath: workspace).standardizedFileURL.path else {
                throw PetError("目标项目位置已变化，请重新选择")
            }
            return files
        }
        return try AgentFiles(workspace: store.extensions.profile.path, followParentLinks: false)
    }

    private static func status(_ record: AgentImportCandidate, target: URL, files: AgentFiles, visible: AgentExtensionItem?) throws -> Status {
        let definition = target.appendingPathComponent("SKILL.md"), entry = try files.entryMetadata(target)
        if entry.kind != "missing" {
            guard entry.kind == "directory", visible?.file.path == definition.path,
                  let packageFiles = try? AgentFiles(workspace: target.path, followParentLinks: false), packageFiles.root.path == target.path,
                  let resources = try? AgentExtensions.resourceData(packageFiles),
                  AgentExtensions.digest(resources) == record.sourceHash else { return .conflict }
            return .installed
        }
        if let visible { return record.sshHost == nil && !visible.managed && visible.pluginName == nil && visible.file.path == record.file ? .shared : .conflict }
        return .ready
    }

    @MainActor static func plan(_ records: [AgentImportCandidate], store: AgentStore, workspace: String?) throws -> [AgentImportCandidate] {
        let files = try targetFiles(store: store, workspace: workspace)
        let visible = try store.extensions.catalog(workspace: workspace).filter { $0.kind == .skill }
        let byName = Dictionary(uniqueKeysWithValues: visible.map { ($0.name.lowercased(), $0) })
        let duplicates = Dictionary(grouping: records.filter { $0.issue == nil }) { $0.title.lowercased() }
        return records.map { entry in
            var record = entry
            guard record.issue == nil else { return record }
            let key = record.title.lowercased()
            if duplicates[key, default: []].count > 1 {
                record.issue = "来源有多份同名 Skill，请分别选择文件夹"
                return record
            }
            do {
                let target = try AgentSkillPackage.target(record.title, files: files, project: workspace != nil)
                record.issue = try status(record, target: target, files: files, visible: byName[key]).issue
            } catch { record.issue = error.localizedDescription }
            return record
        }
    }

    @MainActor private static func pendingTarget(_ record: AgentImportCandidate, store: AgentStore) throws -> (AgentFiles, URL)? {
        guard let plan = record.skill else { throw PetError("缺少 Skill 导入目标") }
        let files = try targetFiles(store: store, workspace: plan.workspace)
        let target = try AgentSkillPackage.target(record.title, files: files, project: plan.workspace != nil)
        let match = try store.extensions.catalog(workspace: plan.workspace).first { $0.kind == .skill && $0.name.lowercased() == record.title.lowercased() }
        switch try status(record, target: target, files: files, visible: match) {
        case .installed: return nil
        case .shared: throw PetError("此 Skill 已由共享目录提供，请重新检测")
        case .conflict: throw PetError("同名 Skill 目标已变化，保留现有版本")
        case .ready: return (files, target)
        }
    }

    @MainActor static func install(_ record: AgentImportCandidate, root: URL, store: AgentStore) async throws {
        try await install(record, store: store) {
            try await Task.detached(priority: .utility) {
                try readPackage(sourceURL(record, root: root), files: sourceFiles(root))
            }.value
        }
    }

    @MainActor static func install(_ record: AgentImportCandidate, store: AgentStore, load: () async throws -> AgentSkillPackage) async throws {
        guard try pendingTarget(record, store: store) != nil else { return }
        let package = try validated(await load(), against: record)
        try Task.checkCancellation()
        guard let (files, target) = try pendingTarget(record, store: store) else { return }
        try package.publish(to: target, files: files)
        let definition = target.appendingPathComponent("SKILL.md")
        guard try store.extensions.catalog(workspace: record.targetWorkspace).contains(where: { $0.file.path == definition.path }) else {
            throw PetError("Skill 已复制，扩展目录未能载入，请检查同名或目录状态")
        }
    }

    @MainActor static func destinationURL(_ record: AgentImportCandidate, store: AgentStore) throws -> URL {
        guard let plan = record.skill else { throw PetError("缺少 Skill 导入目标") }
        let files = try targetFiles(store: store, workspace: plan.workspace)
        let folder = try AgentSkillPackage.target(record.title, files: files, project: plan.workspace != nil)
        guard try files.entryMetadata(folder.appendingPathComponent("SKILL.md")).kind == "file" else { throw PetError("目标 Skill 已移除") }
        return folder
    }
}
