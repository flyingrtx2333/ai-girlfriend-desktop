import AppKit

@MainActor extension AppDelegate {
    func prepareAttentionCheck(_ output: URL) async throws {
        guard (CommandLine.arguments.contains("--manual-ui") || CommandLine.arguments.contains("--attention-page-check")), let tasks = agentStore, let runtime = agentRuntime else { throw PetError("需要我窗口检查未初始化") }
        let primary = tasks.selectedID, project = output.appendingPathComponent("project").resolvingSymlinksInPath()
        let bytes = try Data(contentsOf: project.appendingPathComponent("README.md")), hash = AgentFiles.hash(bytes)
        var ids: [String: String] = [:], calls: [String: String] = [:]
        func request(_ key: String, title: String, name: String, arguments: [String: Any], taskID: String? = nil) async throws {
            let id = taskID ?? tasks.create(title: title, workspace: project.path)
            guard runtime.submit("原生收件箱验收：" + title, taskID: id, startImmediately: false) else { throw PetError("原生用户请求未保存") }
            let call = AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self))
            // These are native requests, not model replies. The normal runtime produces the actual approval and waiting state.
            tasks.update(id) { $0.title = title; $0.permission = .review; $0.pendingCalls = [call] }
            runtime.start(id)
            let deadline = Date().addingTimeInterval(20)
            while tasks.task(id)?.status == .running || tasks.task(id)?.status == .ready {
                guard Date() < deadline else { throw PetError("实际请求尚未进入等待状态") }; await wait(0.05)
            }
            guard let task = tasks.task(id), task.status == .waiting, task.approvals.last?.call.id == call.id, task.messages.allSatisfy({ $0.role != "assistant" }) else { throw PetError("正式执行层未生成等待请求") }
            ids[key] = id; calls[key] = call.id
        }
        try await request("question", title: "确认临时报告标题", name: "ask_user", arguments: ["question": "这份临时报告使用什么标题？"])
        try await request("allow", title: "保存已审阅的核对结果", name: "write_file", arguments: ["path": "allowed.txt", "content": hash + "\n"])
        try await request("deny", title: "拒绝另一项写入", name: "write_file", arguments: ["path": "denied.txt", "content": hash + "\n"])
        var role = AgentProfile(name: "文档核对员", description: "本轮独立临时目录中的原生问答", instructions: "仅处理当前明确要求，不扩大权限。")
        role.enabled = true; role.tools = ["read_file", "ask_user"]
        try tasks.agents.save(tasks.agents.encode([role]), expectedHash: tasks.agents.document().1)
        guard let owner = primary.flatMap(tasks.task) else { throw PetError("原任务不可用") }
        let child = try tasks.agents.createTask(role.id, store: tasks, workspace: project.path, owner: owner)
        try await request("childQuestion", title: "子任务确认输出格式", name: "ask_user", arguments: ["question": "子任务的输出使用 Markdown 还是纯文本？"], taskID: child)
        tasks.automations.start(store: tasks, runtime: runtime)
        let automation = AgentAutomation(name: "收件箱验收自动化", prompt: "读取 README.md 并报告真实文件哈希。", workspace: project.path)
        try tasks.automations.save(automation, expected: nil); try tasks.automations.runNow(automation.id)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let actual = try tasks.automations.history(automationID: automation.id).runs.first, actual.status == .failed, let id = actual.taskID { ids["automation"] = id; break }
            await wait(0.05)
        }
        guard ids["automation"] != nil else { throw PetError("实际自动化未产生受阻模型请求记录") }
        tasks.automations.stop()
        if let primary { control.showAgentTask(primary) }
        tasks.attention.refresh(force: true)
        let value: [String: Any] = ["appPID": getpid(), "tasks": ids, "calls": calls, "sourceHash": hash, "nativeRequests": true, "assistantRepliesCreated": false, "automationID": automation.id]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("attention-fixtures.json"), options: .atomic)
    }
}
