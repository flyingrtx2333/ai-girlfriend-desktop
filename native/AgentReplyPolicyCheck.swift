import AppKit

@MainActor extension AppDelegate {
    func runAgentReplyPolicyCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], effects: [[String: Any]] = [], requests = 0
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall {
            AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self))
        }
        func rejected(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
        var report: [String: Any] = [:]
        defer { agentRuntime?.stopAll(); agentStore?.automations.stop() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("分支权限检查未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("权限检查禁止模型请求") }
            let fm = FileManager.default, workspace = output.appendingPathComponent("workspace"), marker = workspace.appendingPathComponent("marker.txt"), bytes = Data("reply-policy-original\n".utf8)
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true); try bytes.write(to: marker)
            func execute(_ id: String, _ name: String, _ args: [String: Any]) async throws -> AgentToolResult {
                let result = try await AgentTools(store: tasks, taskID: id).execute(call(name, args))
                effects.append(["taskID": id, "tool": name, "failed": result.failed, "text": result.text]); return result
            }
            let control = tasks.create(title: "实际写入对照", workspace: workspace.path, mode: .agent)
            tasks.update(control) { $0.permission = .automatic }
            let written = try await execute(control, "write_file", ["path": "control-write.txt", "content": "actual-native-write"])
            let shell = try await execute(control, "run_command", ["command": "printf actual-shell-write > control-command.txt", "network": false])
            checks["actualWriteToolPositiveControl"] = try !written.failed && Data(contentsOf: workspace.appendingPathComponent("control-write.txt")) == Data("actual-native-write".utf8)
            checks["actualShellPositiveControl"] = try !shell.failed && Data(contentsOf: workspace.appendingPathComponent("control-command.txt")) == Data("actual-shell-write".utf8)
            var parentRole = AgentProfile(name: "分支所属角色", description: "分支权限核对", instructions: "只处理明确要求。")
            parentRole.enabled = true; parentRole.readOnly = false; parentRole.network = true; parentRole.permission = .automatic; parentRole.tools = ["read_file", "write_file", "run_command", "web_search", "fetch_url"]
            var childRole = parentRole; childRole.id = UUID().uuidString; childRole.name = "分支委派角色"
            try tasks.agents.save(tasks.agents.encode([parentRole, childRole]), expectedHash: nil)
            let parent = try tasks.agents.createTask(parentRole.id, store: tasks, workspace: workspace.path)
            let child = try tasks.agents.createTask(childRole.id, store: tasks, workspace: workspace.path, owner: tasks.task(parent))
            guard runtime.submit("读取 marker.txt，保留实际文件。", taskID: child, startImmediately: false) else { throw PetError(runtime.submissionError ?? "未保存原始要求") }
            parentRole.tools = ["read_file", "run_command"]; parentRole.network = false; parentRole.permission = .review
            let config = try tasks.agents.document(); try tasks.agents.save(tasks.agents.encode([parentRole, childRole]), expectedHash: config.1)
            guard let branch = tasks.fork(child), let detached = tasks.task(branch) else { throw PetError(tasks.writeError ?? "未创建委派分支") }
            checks["delegatedBranchDetachedAndHistoryRetained"] = detached.agent?.ownerID == nil && detached.parentID == child && detached.messages.map(\.content) == tasks.task(child)?.messages.map(\.content)
            checks["liveParentToolRestrictionCaptured"] = detached.agent?.tools.contains("write_file") == false
            checks["liveParentNetworkAndApprovalCaptured"] = try !tasks.agents.limits(detached, store: tasks).network && tasks.agents.executionPermission(detached, store: tasks) == .review
            let read = try await execute(branch, "read_file", ["path": "marker.txt"])
            checks["detachedBranchReadsActualFile"] = !read.failed && read.text.contains("reply-policy-original")
            rejected("detachedBranchRejectsRemovedWriteTool") { _ = try AgentTools(store: tasks, taskID: branch).approvalReason(for: call("write_file", ["path": "marker.txt", "content": "unexpected"])) }
            rejected("detachedBranchRejectsNetwork") { _ = try AgentTools(store: tasks, taskID: branch).approvalReason(for: call("run_command", ["command": "true", "network": true])) }
            checks["detachedBranchStillRequiresApproval"] = try AgentTools(store: tasks, taskID: branch).approvalReason(for: call("run_command", ["command": "cat marker.txt", "network": false])) != nil
            tasks.update(parent) { $0.mode = .ask }
            guard let readOnly = tasks.fork(child) else { throw PetError(tasks.writeError ?? "未创建只读分支") }
            tasks.update(readOnly) { $0.mode = .agent; $0.permission = .automatic }
            let denied = try await execute(readOnly, "run_command", ["command": "printf unexpected > marker.txt", "network": false])
            checks["detachedReadonlyShellEnforcedByKernel"] = try denied.failed && Data(contentsOf: marker) == bytes
            tasks.update(parent) { $0.archived = true }
            let afterArchive = try await execute(branch, "read_file", ["path": "marker.txt"])
            checks["detachedBranchSurvivesOwnerArchive"] = !afterArchive.failed && tasks.task(branch)?.archived == false && tasks.task(readOnly)?.archived == false
            tasks.automations.start(store: tasks, runtime: runtime)
            var automatic = AgentAutomation(name: "独立分支权限核对", prompt: "读取 marker.txt。", workspace: workspace.path)
            automatic.schedule.frequency = .once; automatic.schedule.date = Date().addingTimeInterval(3600); automatic.notify = false
            try tasks.automations.save(automatic, expected: nil); try tasks.automations.runNow(automatic.id)
            guard let automaticID = tasks.tasks.first(where: { tasks.task($0.id)?.automation?.automationID == automatic.id })?.id else { throw PetError("未创建实际自动化任务") }
            let deadline = Date().addingTimeInterval(8)
            while runtime.isRunning(automaticID), Date() < deadline { await wait(0.1) }
            if runtime.isRunning(automaticID) { runtime.cancel(automaticID) }
            guard let automationBranch = tasks.fork(automaticID), let automaticTask = tasks.task(automationBranch) else { throw PetError(tasks.writeError ?? "未创建自动化分支") }
            checks["automationBranchDetachedWithPersistentLimits"] = automaticTask.agent == nil && automaticTask.automation == nil && automaticTask.inheritedLimits?.readOnly == true && automaticTask.inheritedLimits?.network == false
            tasks.update(automationBranch) { $0.mode = .agent; $0.permission = .automatic }
            rejected("unassignedBranchWriteRejected") { _ = try AgentTools(store: tasks, taskID: automationBranch).approvalReason(for: call("write_file", ["path": "marker.txt", "content": "unexpected"])) }
            rejected("unassignedBranchNetworkRejected") { _ = try AgentTools(store: tasks, taskID: automationBranch).approvalReason(for: call("fetch_url", ["url": "https://example.com"])) }
            let automationShell = try await execute(automationBranch, "run_command", ["command": "printf unexpected > marker.txt", "network": false])
            checks["unassignedReadonlyShellEnforcedByKernel"] = try automationShell.failed && Data(contentsOf: marker) == bytes
            checks["unassignedPermissionCeilingPreserved"] = try tasks.agents.executionPermission(tasks.task(automationBranch)!, store: tasks) == .review
            let restored = AgentStore(directory: tasks.directory.deletingLastPathComponent(), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["limitsSurviveNativeReload"] = try restored.task(automationBranch)?.inheritedLimits?.readOnly == true && restored.agents.executionPermission(restored.task(automationBranch)!, store: restored) == .review && !restored.agents.limits(restored.task(branch)!, store: restored).network
            checks["noModelReceiptsCreated"] = tasks.tasks.allSatisfy { (tasks.task($0.id)?.modelReceipts ?? []).isEmpty }
            report["tasks"] = ["control": control, "parent": parent, "child": child, "branch": branch, "readonlyBranch": readOnly, "automatic": automaticID, "automationBranch": automationBranch]
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["effects"] = effects; report["blockedModelAttempts"] = requests
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("reply-policy-result.json"), options: .atomic)
    }
}
