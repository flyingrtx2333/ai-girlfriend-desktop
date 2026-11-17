import Foundation

struct AgentSkillCreationContext: Codable, Equatable {
    var taskID: String
    var workspaceScope: AgentWorkspaceScope?
    var workMode: AgentWorkMode
}

@MainActor enum AgentSkillCreation {
    static func create(store: AgentStore, sourceTaskID: String?, workspace: String?) throws -> String {
        let source = try AgentWorkspaceScope.settingsSourceTask(sourceTaskID, workspace: workspace, store: store)
        let sourceVersion = try source.map { try store.recordVersion($0.id) }
        let mode = source?.organizationMode ?? .coding
        let path = try workspace.map { try AgentFiles(workspace: $0).root.path } ?? source?.workspace
        var scope = source?.workspaceScope
        if let path { scope?.primary = path }
        var task = AgentTaskRecord(title: "创建 Skill", workspace: path, workspaceScope: scope, workMode: mode == .coding ? nil : mode, mode: .plan)
        task.permission = .review; task.kind = AgentSkillEvolution.kind
        task.modelOverride = source?.modelOverride
        task.skillEvolutionJob = .init(sourceTaskID: nil, sourceMessageID: nil, sourceTitle: "", sourceHash: nil,
            suggestionID: nil, title: task.title, goal: "按本会话要求创建 Skill", brief: "", workspace: path, target: nil,
            creation: .init(taskID: task.id, workspaceScope: scope, workMode: mode))
        try store.installSkillCreationRecord(task) {
            if let source, let sourceVersion {
                guard try store.recordVersion(source.id) == sourceVersion else { throw PetError("原任务已变化，请重新打开设置") }
            }
        }
        return task.id
    }
}
