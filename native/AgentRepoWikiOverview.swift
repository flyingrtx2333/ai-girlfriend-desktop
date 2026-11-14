import Foundation

struct AgentRepoWikiProject: Identifiable, Sendable {
    var workspace: String, name: String, mode: AgentWorkMode
    var taskID: String? = nil, gitDirectory: String? = nil
    var id: String { workspace }
}

struct AgentRepoWikiSummary: Identifiable, Sendable {
    var project: AgentRepoWikiProject
    var status: String
    var branch: String? = nil, pages: Int? = nil, published: Bool? = nil, updated: Date? = nil, problem: String? = nil
    var id: String { project.id }
    var branchTitle: String {
        guard let branch else { return "" }
        if branch == "folder" { return "文件夹" }
        if branch.hasPrefix("refs/heads/") { return String(branch.dropFirst(11)) }
        if branch.hasPrefix("detached:") { return "分离 HEAD · " + String(branch.dropFirst(9).prefix(8)) }
        return branch
    }
}

enum AgentRepoWikiOverview {
    @MainActor static func projects(_ store: AgentStore) -> [AgentRepoWikiProject] {
        let tasks = store.tasks, selected = tasks.first { $0.id == store.selectedID }?.organizationMode ?? .coding
        var result: [AgentRepoWikiProject] = [], seen = Set<String>()
        for mode in [selected] + AgentWorkMode.allCases.filter({ $0 != selected }) {
            for entry in store.organization.directories(mode, tasks: tasks) {
                let path = URL(fileURLWithPath: entry.primary).standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                let candidates = tasks.filter { task in
                    task.workspace.map { URL(fileURLWithPath: $0).standardizedFileURL.path == path } == true && !task.archived && !task.isProjectDocumentation && task.kind != "hook" && task.agent == nil && task.team == nil && task.automation == nil
                }
                let source = candidates.first { $0.id == store.selectedID } ?? candidates.max { $0.updated < $1.updated }
                result.append(AgentRepoWikiProject(workspace: path, name: entry.title, mode: source?.organizationMode ?? mode, taskID: source?.id, gitDirectory: source?.gitDirectory))
            }
        }
        return result.sorted { a, b in let order = a.name.localizedStandardCompare(b.name); return order == .orderedSame ? a.workspace < b.workspace : order == .orderedAscending }
    }
    static func read(_ projects: [AgentRepoWikiProject], storage: URL, language: String) throws -> [AgentRepoWikiSummary] {
        guard ["zh", "en"].contains(language) else { throw PetError("请选择简体中文或 English") }
        var result: [AgentRepoWikiSummary] = [], seen = Set<String>()
        for var project in projects {
            try Task.checkCancellation()
            do {
                let scope = try AgentKnowledgeCards.scope(workspace: project.workspace, gitDirectory: project.gitDirectory, storage: storage)
                project.workspace = scope.root
                guard seen.insert(scope.root).inserted else { continue }
                let manifest = try AgentWiki.plannedManifest(scope: scope, language: language)
                let root = manifest?.root ?? ".bluefatfish/wiki"
                let pages = try manifest != nil || language == "zh" ? AgentWiki.pages(workspace: scope.root, root: root) : []
                let legacy = try manifest == nil && language == "zh" ? AgentWiki.legacyManifest(workspace: scope.root, storage: storage) : nil
                let publication = manifest ?? legacy
                let status: String
                if let manifest { status = try AgentWiki.publicationStatus(manifest, workspace: scope.root, storage: storage) }
                else if let legacy, !pages.isEmpty { status = try AgentWiki.legacyStatus(legacy, workspace: scope.root, storage: storage) }
                else { status = pages.isEmpty ? "未生成" : "未校验" }
                var updated = publication?.created
                if updated == nil, !pages.isEmpty {
                    let files = try AgentFiles(workspace: scope.root)
                    updated = pages.compactMap { path in (try? files.resolve(path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
                }
                result.append(AgentRepoWikiSummary(project: project, status: status, branch: scope.branch, pages: pages.count, published: publication != nil && !pages.isEmpty, updated: updated))
            } catch {
                try Task.checkCancellation()
                result.append(AgentRepoWikiSummary(project: project, status: "不可用", problem: error.localizedDescription))
            }
        }
        return result
    }
    @MainActor static func progress(_ rows: [AgentRepoWikiSummary], store: AgentStore, language: String) -> [AgentRepoWikiSummary] {
        rows.map { source in
            var row = source
            guard row.problem == nil else { return row }
            let jobs = store.tasks.filter { task in
                task.kind == "wiki" && !task.archived && task.workspace == row.project.workspace && [.ready, .running, .waiting].contains(task.status) &&
                (task.wikiJob.map { $0.branch == row.branch && $0.language == language } ?? (language == "zh"))
            }
            if let job = jobs.max(by: { $0.updated < $1.updated }) { row.status = job.status == .running ? "生成中" : job.status == .waiting ? "等待确认" : "待开始" }
            return row
        }
    }
}
