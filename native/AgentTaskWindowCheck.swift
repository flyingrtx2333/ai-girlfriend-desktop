import AppKit

@MainActor extension AppDelegate {
    func prepareTaskWindowCheck(_ output: URL) async throws {
        guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
        let project = output.appendingPathComponent("project"), source = project.appendingPathComponent("README.md")
        let bytes = try Data(contentsOf: source), a = tasks.create(title: "核对项目说明", workspace: project.path)
        guard runtime.submit("只读取项目说明，不修改文件。", taskID: a, startImmediately: false) else { throw PetError("原生用户输入未保存") }
        tasks.update(a) { $0.draft = "项目说明任务的未发送草稿" }
        let b = tasks.create(title: "检查后台记录", workspace: project.path)
        tasks.update(b) { $0.draft = "后台记录任务的未发送草稿" }
        let general = tasks.create(title: "整理通用资料", workMode: .general); tasks.update(general) { $0.draft = "通用任务的未发送草稿" }
        try tasks.organization.register(project.path, mode: .coding)
        let release = project.appendingPathComponent("finish-window-hook"), pidFile = project.appendingPathComponent("window-hook.pid")
        let command = "umask 077; echo $$ > \"$2\"; while [ ! -f \"$1\" ]; do /bin/sleep 0.1; done; /usr/bin/shasum -a 256 \"$3\"; /bin/echo window-hook-completed"
        let definition: [String: Any] = ["hooks": ["Notification": [["matcher": "WindowLifecycle", "hooks": [["name": "窗口后台核对", "type": "command", "command": "/bin/sh", "args": ["-c", command, "window-check", release.path, pidFile.path, source.path], "async": true, "timeout": 600]]]]]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: definition), as: UTF8.self)
        try tasks.hooks.save(text, project: true, workspace: project.path, expectedHash: nil)
        guard let hook = try tasks.hooks.catalog(workspace: project.path).first(where: { $0.name == "窗口后台核对" }) else { throw PetError("实际后台命令不可用") }
        try tasks.hooks.setEnabled(hook, true, workspace: project.path)
        _ = try await tasks.hooks.fire(.notification, trigger: "window-lifecycle", store: tasks, taskID: b, value: "WindowLifecycle")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidFile.path), tasks.hooks.isRunning(b), Date() < deadline { await wait(0.05) }
        guard let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 else { throw PetError("实际后台进程未启动") }
        control.showAgentTask(a)
        let value: [String: Any] = ["tasks": ["primary": a, "background": b, "general": general], "backgroundPID": pid, "backgroundRelease": release.path, "source": source.path, "sourceHash": AgentFiles.hash(bytes), "appPID": getpid()]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-window-fixtures.json"), options: .atomic)
    }
}
