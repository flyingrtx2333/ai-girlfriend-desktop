import AppKit

@MainActor extension AppDelegate {
    func runAgentTerminalCheck(_ output: URL) async {
        let fm = FileManager.default
        var report: [String: Any] = [:]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("终端运行时未初始化") }
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash], "terminal-process.json")
            let nativeURL = output.appendingPathComponent("terminal-native-" + String(hash.prefix(12)) + ".json")
            if !fm.fileExists(atPath: nativeURL.path) {
                let isolated = AgentStore(directory: output.appendingPathComponent("native-profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
                let workspace = output.appendingPathComponent("workspace"), outside = output.appendingPathComponent("outside.txt")
                try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
                let canary = workspace.appendingPathComponent("canary.txt"), keep = Data("terminal-canary-2086".utf8)
                try keep.write(to: canary); try keep.write(to: outside)
                var checks: [String: Bool] = [:], commands: [[String: Any]] = []
                func invoke(_ id: String, _ command: String) async throws -> AgentToolResult {
                    let call = AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["command": command, "network": false, "timeout_seconds": 15]), as: UTF8.self))
                    let executor = AgentTools(store: isolated, taskID: id)
                    _ = try executor.approvalReason(for: call)
                    let value = try await executor.execute(call)
                    commands.append(["taskID": id, "command": command, "text": value.text, "failed": value.failed, "exitCode": value.exitCode ?? -1])
                    return value
                }
                func names(_ mode: AgentMode, kind: String? = nil) -> Set<String> { Set(AgentTools.definitions(mode: mode, kind: kind, groups: ["files", "terminal"]).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }) }
                checks["askAndPlanExposeReadOnlyTerminal"] = [.ask, .plan].allSatisfy { names($0).contains("run_command") && !names($0).contains("write_file") }
                checks["wikiTerminalBoundaryPreserved"] = !names(.agent, kind: "wiki").contains("run_command")
                let asking = isolated.create(title: "只读终端", workspace: workspace.path, mode: .ask)
                let mac = try await invoke(asking, "/usr/bin/uname -s && /bin/pwd && /usr/sbin/sysctl -n hw.memsize && /usr/bin/vm_stat && /bin/df -kP /")
                checks["askRunsRealMacCommandsInWorkspace"] = !mac.failed && mac.text.contains("Darwin") && mac.text.contains(String(ProcessInfo.processInfo.physicalMemory)) && mac.text.contains("Mach Virtual Memory Statistics") && mac.text.contains(workspace.path)
                let denied = try await invoke(asking, "printf changed > canary.txt")
                checks["askCannotWriteWorkspaceEvenThroughShell"] = try denied.failed && Data(contentsOf: canary) == keep
                checks["readOnlyCommandDoesNotCaptureProjectChanges"] = isolated.task(asking)?.pendingFileCapture == nil && (isolated.task(asking)?.changes ?? []).isEmpty
                let planning = isolated.create(title: "计划终端", workspace: workspace.path, mode: .plan)
                let plan = try await invoke(planning, "cat canary.txt && printf changed > canary.txt")
                checks["planTerminalRemainsReadOnly"] = try plan.failed && plan.text.contains("terminal-canary-2086") && Data(contentsOf: canary) == keep
                let standalone = isolated.create(title: "无工作区终端", workspace: nil, mode: .agent)
                let saved = try await invoke(standalone, "printf terminal-saved-2086 > terminal-saved.txt && cat terminal-saved.txt && /bin/pwd")
                let directory = try isolated.backupDirectory(standalone).deletingLastPathComponent().appendingPathComponent("tmp")
                checks["agentWithoutWorkspaceUsesOwnWritableDirectory"] = try !saved.failed && isolated.task(standalone)?.workspace == nil && Data(contentsOf: directory.appendingPathComponent("terminal-saved.txt")) == Data("terminal-saved-2086".utf8)
                let reopened = AgentStore(directory: output.appendingPathComponent("native-profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
                let readBack = try await AgentTools(store: reopened, taskID: standalone).execute(AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: "{\"command\":\"cat terminal-saved.txt\"}"))
                checks["taskWorkingDirectorySurvivesStoreReload"] = !readBack.failed && readBack.text.contains("terminal-saved-2086") && reopened.task(standalone)?.workspace == nil
                let without = isolated.create(title: "无工作区问答", workspace: nil, mode: .ask)
                let physical = try await invoke(without, "/usr/sbin/sysctl -n hw.memsize")
                checks["askWithoutWorkspaceRunsTerminal"] = !physical.failed && physical.text.contains(String(ProcessInfo.processInfo.physicalMemory)) && isolated.task(without)?.workspace == nil
                let escape = try await invoke(standalone, "printf changed > " + AgentGit.quote(outside.path))
                checks["noWorkspaceDoesNotPermitUnrelatedWrites"] = try escape.failed && Data(contentsOf: outside) == keep
                let protected = output.appendingPathComponent("native-profile/protected-canary.txt"); try keep.write(to: protected)
                let privateRead = try await invoke(without, "cat " + AgentGit.quote(protected.path))
                checks["applicationDataRemainsUnreadable"] = privateRead.failed
                var role = AgentProfile(name: "终端核对", description: "本机只读终端权限核对", instructions: "只完成当前核对。")
                role.enabled = true; role.readOnly = false; role.permission = .automatic; role.tools = ["run_command"]
                let previous = try isolated.agents.document(); try isolated.agents.save(try isolated.agents.encode([role]), expectedHash: previous.1)
                let parent = isolated.create(title: "父任务", workspace: workspace.path, mode: .agent)
                let child = try isolated.agents.createTask(role.id, store: isolated, workspace: workspace.path, owner: isolated.task(parent))
                isolated.update(parent) { $0.mode = .ask }
                let tightened = try await invoke(child, "printf changed > canary.txt")
                checks["parentSwitchToAskKeepsChildTerminalReadOnly"] = try tightened.failed && isolated.agents.limits(isolated.task(child)!, store: isolated).readOnly && Data(contentsOf: canary) == keep
                let inherited = try isolated.agents.createTask(role.id, store: isolated, workspace: workspace.path, owner: isolated.task(parent))
                isolated.update(parent) { $0.mode = .agent }; isolated.update(inherited) { $0.mode = .agent }
                let ceiling = try await invoke(inherited, "printf changed > canary.txt")
                checks["delegatedAskCeilingCannotBecomeWritableTerminal"] = try ceiling.failed && Data(contentsOf: canary) == keep
                let invalid = isolated.create(title: "无效目录", workspace: output.appendingPathComponent("missing-workspace").path, mode: .agent)
                do { _ = try await invoke(invalid, "pwd"); checks["invalidChosenWorkspaceDoesNotSilentlyFallback"] = false } catch { checks["invalidChosenWorkspaceDoesNotSilentlyFallback"] = true }
                let success = checks.values.allSatisfy { $0 }
                try write(["success": success, "binaryHash": hash, "checks": checks, "commands": commands], nativeURL.lastPathComponent)
                guard success else { throw PetError("终端原生检查失败：" + checks.filter { !$0.value }.map(\.key).joined(separator: ", ")) }
            }
            let native = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeURL)) as! [String: Any]
            guard native["success"] as? Bool == true else { throw PetError("此候选的原生终端检查尚未通过，保留失败记录") }
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("需要真实模型验收终端") }
            let production = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var preferences = PreferencesStore(directory: production).preferences
            preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false
            store.preferences = preferences; try store.savePreferences()
            let ownerURL = output.appendingPathComponent("terminal-live-task.json"), id: String
            if let bytes = try? Data(contentsOf: ownerURL), let owner = try JSONSerialization.jsonObject(with: bytes) as? [String: String], let existing = owner["id"], tasks.task(existing) != nil { id = existing }
            else { id = tasks.create(title: "终端系统查询", workspace: nil, mode: .ask); try write(["id": id], ownerURL.lastPathComponent) }
            control.showAgentTask(id); control.show(tab: "chat")
            try write(["appPID": getpid(), "binaryHash": hash, "taskID": id, "model": preferences.model, "context": preferences.contextLimit, "output": preferences.outputLimit], "terminal-ui-ready.json")
            let deadline = Date().addingTimeInterval(1200)
            while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-terminal-ui").path) {
                if let task = tasks.task(id), (task.modelReceipts?.count ?? 0) > 12, task.status != .completed { runtime.cancel(id); throw PetError("终端验收超过12份实际请求，原任务保留") }
                await wait(0.2)
            }
            guard fm.fileExists(atPath: output.appendingPathComponent("finish-terminal-ui").path), let task = tasks.task(id), task.mode == .ask, task.workspace == nil, task.status == .completed, !runtime.isExecuting(id) else { throw PetError("原终端任务尚未完成，保留记录") }
            let calls = Dictionary(task.messages.flatMap { ($0.toolCalls ?? []).map { ($0.id, $0) } }, uniquingKeysWith: { _, last in last })
            let commands = task.messages.compactMap { message -> [String: Any]? in
                guard message.role == "tool", let call = calls[message.toolCallID ?? ""], call.name == "run_command" else { return nil }
                let event = task.events.last { $0.toolCallID == call.id }
                return ["id": call.id, "command": call.object["command"] as? String ?? "", "text": message.content, "successful": event?.status == "completed"]
            }
            guard commands.contains(where: { $0["successful"] as? Bool == true }), task.messages.contains(where: { $0.isHumanInput && $0.content == "当前磁盘内存多少" }) else { throw PetError("没有实际终端执行或原问题") }
            let ui = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("terminal-ui-acceptance.json"))) as! [String: Any]
            guard ui["appPID"] as? Int == Int(getpid()), ui["binaryHash"] as? String == hash, let checks = ui["checks"] as? [String: Bool], ["askModeAndNoWorkspace", "realTerminalApproval", "macOSResultVisible"].allSatisfy({ checks[$0] == true }) else { throw PetError("实际终端窗口验收记录不匹配") }
            report = ["success": true, "taskID": id, "binaryHash": hash, "commands": commands, "reply": task.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty })?.content ?? "", "requests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "native": native, "ui": ui]
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        try? write(report, "terminal-report.json")
    }
}
