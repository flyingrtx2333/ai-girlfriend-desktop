import AppKit

@MainActor extension AppDelegate {
    func prepareTaskSearchCheck(_ output: URL) throws {
        guard CommandLine.arguments.contains("--manual-ui"), let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务搜索检查未初始化") }
        let alpha = output.appendingPathComponent("projects/alpha").resolvingSymlinksInPath(), beta = output.appendingPathComponent("projects/beta").resolvingSymlinksInPath()
        let bytes = try Data(contentsOf: alpha.appendingPathComponent("README.md"))
        guard try Data(contentsOf: beta.appendingPathComponent("README.md")) == bytes else { throw PetError("两份实际项目说明不一致") }
        var ids: [String: String] = [:]
        func create(_ key: String, title: String, workspace: String?, mode: AgentWorkMode = .coding, existing: String? = nil) throws {
            let id = existing ?? tasks.create(title: title, workspace: workspace, workMode: mode)
            tasks.update(id) { $0.title = title }
            guard runtime.submit("请保留这条文档核对要求：稍后对照 README.md 核对小鲸说明原文，不要现在执行。", taskID: id, startImmediately: false) else { throw PetError("实际用户输入未保存") }
            tasks.update(id) { $0.draft = title + "尚未发送的草稿" }; ids[key] = id
        }
        try create("alpha", title: "项目说明核对", workspace: alpha.path)
        try create("beta", title: "另一份说明核对", workspace: beta.path)
        let current = tasks.create(title: "待写的说明", workspace: alpha.path)
        tasks.update(current) { $0.draft = "当前窗口尚未发送的草稿" }; ids["current"] = current
        try create("general", title: "通用资料核对", workspace: nil, mode: .general)
        var role = AgentProfile(name: "资料核对员", description: "核对当前项目说明", instructions: "只读取明确要求的资料。")
        role.enabled = true
        try tasks.agents.save(tasks.agents.encode([role]), expectedHash: tasks.agents.document().1)
        guard let parent = ids["alpha"].flatMap(tasks.task) else { throw PetError("原任务不可用") }
        let child = try tasks.agents.createTask(role.id, store: tasks, workspace: alpha.path, owner: parent)
        try create("child", title: "附属资料核对", workspace: alpha.path, existing: child)
        try tasks.organization.register(alpha.path, mode: .coding); try tasks.organization.register(beta.path, mode: .coding)
        control.showAgentTask(current)
        let value: [String: Any] = ["appPID": getpid(), "tasks": ids, "projects": ["alpha": alpha.path, "beta": beta.path], "userQuery": "小鲸说明原文", "literalQuery": "README.md", "literalNegativeQuery": "README[.]md", "sourceHash": AgentFiles.hash(bytes), "nativeHumanInputsOnly": true, "assistantRepliesCreated": false]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-search-fixtures.json"), options: .atomic)
    }
}
