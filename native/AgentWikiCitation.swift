import Foundation

struct AgentWikiCitationSettings: Codable {
    var version = 1
    var projects: [String: Bool] = [:]
}

@MainActor extension AgentWiki {
    private static func citationDirectory(_ store: AgentStore) throws -> URL {
        let files = try AgentFiles(workspace: store.directory.deletingLastPathComponent().path), parent = files.root
        let folder = parent.appendingPathComponent("wiki", isDirectory: true)
        let kind = try files.entryMetadata(folder).kind
        guard ["missing", "directory"].contains(kind), folder.standardizedFileURL.path == folder.resolvingSymlinksInPath().path else { throw PetError("Wiki 引用设置目录不能是符号链接或其他文件") }
        return folder
    }
    private static func citationSettings(_ store: AgentStore) throws -> (AgentWikiCitationSettings, String) {
        let directory = try citationDirectory(store), file = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: directory.path) else { return (AgentWikiCitationSettings(), AgentFiles.hash(Data())) }
        let files = try AgentFiles(workspace: directory.path), entry = try files.entryMetadata(file)
        if entry.kind == "missing" { return (AgentWikiCitationSettings(), AgentFiles.hash(Data())) }
        guard entry.kind == "file" else { throw PetError("Wiki 引用设置必须是普通文件") }
        let data = try files.readData(file, maximum: 1_000_000)
        let value = try JSONDecoder().decode(AgentWikiCitationSettings.self, from: data)
        guard value.version == 1, value.projects.count <= 500, value.projects.keys.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }) else { throw PetError("Wiki 引用设置无效，原配置已保留") }
        return (value, AgentFiles.hash(data))
    }
    static func citation(store: AgentStore, workspace: String) throws -> (enabled: Bool, signature: String, workspace: String) {
        let root = try AgentFiles(workspace: workspace).root.path, (value, hash) = try citationSettings(store)
        return (value.projects[root] ?? true, hash, root)
    }
    static func setCitation(store: AgentStore, workspace: String, enabled: Bool, expected: String) throws {
        let root = try AgentFiles(workspace: workspace).root.path, directory = try citationDirectory(store)
        try store.knowledgeCards.locked(directory, label: "Wiki 引用设置") {
            var (value, signature) = try citationSettings(store)
            guard signature == expected else { throw PetError("Wiki 引用设置已变化，请刷新后重试") }
            value.projects[root] = enabled
            guard value.projects.count <= 500 else { throw PetError("Wiki 工作区设置已达上限") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(value); guard data.count <= 1_000_000 else { throw PetError("Wiki 引用设置超过1MB") }
            try AgentFiles(workspace: directory.path).writeData(data, to: directory.appendingPathComponent("settings.json"), permissions: 0o600)
        }
    }
    static func citationAllowed(store: AgentStore, task: AgentTaskRecord) -> Bool {
        if task.kind == "wiki" { return true }
        guard let workspace = task.workspace else { return false }
        return (try? citation(store: store, workspace: workspace).enabled) == true
    }
}
