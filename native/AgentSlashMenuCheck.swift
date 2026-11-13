import AppKit

struct AgentSlashMenuFixture: Codable {
    var taskID: String, seedID: String, otherID: String, pluginID: String, skillID: String, projectID: String
    var commands: [String]
}
@MainActor extension AppDelegate {
    func prepareSlashMenuUI(_ output: URL, seed: Bool) async throws -> AgentSlashMenuFixture {
        guard checkDirectory != nil, let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少独立命令菜单环境") }
        let file = output.appendingPathComponent("slash-menu-fixtures.json")
        if !seed {
            let fixture = try JSONDecoder().decode(AgentSlashMenuFixture.self, from: Data(contentsOf: file))
            guard tasks.task(fixture.taskID) != nil else { throw PetError("原命令菜单任务不可用") }; control.showAgentTask(fixture.taskID); return fixture
        }
        let workspace = output.appendingPathComponent("project"), other = output.appendingPathComponent("other-project")
        for directory in [workspace, other] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var commands: [String] = []
        for index in 1...18 {
            let item = try tasks.extensions.create(.command, name: String(format: "slash-command-%02d", index), text: "---\ndescription: 公开菜单命令 \(index)\n---\n保留原始参数：$ARGUMENTS\n", project: false, workspace: workspace.path); commands.append(item.id)
        }
        let skill = try tasks.extensions.create(.skill, name: "slash-local", text: "---\nname: slash-local\ndescription: 公开本机技能\ndisable-model-invocation: true\n---\n只核对用户提供的公开文字。\n", project: false, workspace: workspace.path)
        let local = try tasks.extensions.create(.command, name: "project-palette", text: "---\ndescription: 当前项目的菜单检查\n---\n只使用当前项目。\n", project: true, workspace: workspace.path)
        let source = output.appendingPathComponent("slash-plugin-source")
        let manifest: [String: Any] = ["name": "slash-palette", "displayName": "菜单示例插件", "version": "1.0.0", "description": "公开文本的命令菜单检查"]
        var files = [".qoder-plugin/plugin.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])]
        for (name, text) in ["skills/inspect/SKILL.md": "---\nname: inspect\ndescription: 插件中的公开核对技能\ndisable-model-invocation: true\n---\n仅核对实际提供的公开文字。\n", "commands/report.md": "---\ndescription: 插件中的报告命令\n---\n按原始要求整理：$ARGUMENTS\n", "commands/verify.md": "---\ndescription: 插件中的校验命令\n---\n仅核对实际给出的内容。\n"] { files[name] = Data(text.utf8) }
        for (name, data) in files { let target = source.appendingPathComponent(name); try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: target) }
        let package = try await tasks.extensions.plugins.inspect(source), plugin = try tasks.extensions.plugins.install(package)
        try tasks.extensions.plugins.setEnabled(plugin, true)
        let id = tasks.create(title: "命令菜单", workspace: workspace.path), seedID = tasks.create(title: "菜单最近使用原始记录", workspace: workspace.path), otherID = tasks.create(title: "无工作区命令菜单", mode: .ask, workMode: .general)
        tasks.update(id) { $0.draft = "命令菜单原草稿 🧭" }; tasks.update(otherID) { $0.draft = "另一项原草稿" }
        guard runtime.submit("/command:slash-command-18 公开的最近使用参数", taskID: seedID, startImmediately: false) else { throw PetError("公开命令未被接受：" + (runtime.submissionError ?? "")) }
        let fixture = AgentSlashMenuFixture(taskID: id, seedID: seedID, otherID: otherID, pluginID: plugin.id, skillID: skill.id, projectID: local.id, commands: commands)
        try JSONEncoder().encode(fixture).write(to: file)
        control.showAgentTask(id); return fixture
    }
    func checkSlashMenu(_ output: URL) async throws -> [String: Bool] {
        let fixture = try await prepareSlashMenuUI(output, seed: true)
        var checks = try await control.checkSlashMenu(output, fixture: fixture)
        guard let tasks = agentStore else { throw PetError("缺少原命令入口验收环境") }
        let legacy = tasks.create(title: "原命令入口", workspace: tasks.task(fixture.taskID)?.workspace)
        let command = try tasks.extensions.create(.command, name: "audit:handoff", text: "---\ndescription: 公开交接命令\n---\n仅整理原始参数：$ARGUMENTS\n", project: false, workspace: tasks.task(legacy)?.workspace)
        for (key, value) in try await control.checkExtensionComposer(output, taskID: legacy, item: command) { checks["Existing-" + key] = value }
        return checks
    }
}
