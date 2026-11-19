import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runInterruptHookCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], errorText: String?
        do { try await checkInterruptHooks(output, checks: &checks) }
        catch { errorText = error.localizedDescription }
        var report: [String: Any] = ["checks": checks, "modelRequests": 0,
                                     "success": errorText == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }]
        report["error"] = errorText
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(
            to: output.appendingPathComponent("interrupt-hook-report.json"), options: .atomic)
    }

    private func checkInterruptHooks(_ output: URL, checks: inout [String: Bool]) async throws {
        let profile = output.appendingPathComponent("profile"), workspace = output.appendingPathComponent("Harbor")
        let source = output.appendingPathComponent("Source"), codex = source.appendingPathComponent(".codex"), scripts = codex.appendingPathComponent("hooks")
        for folder in [workspace, scripts] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let key = "PUBLIC-LOCAL-INTERRUPT-KEY"
        let vault = PetKeychain(service: "com.xjs.bluefatfish.interrupt-check", configurationFile: output.appendingPathComponent("fixture-key.json"), migrateLegacy: false)
        try vault.write(key, account: "chat")
        let tasks = AgentStore(directory: profile, legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
        let runtime = AgentRuntime(store: tasks, keychain: vault) {
            var preferences = PetPreferences(); preferences.model = "interrupt-fixture"; preferences.endpoint = "http://127.0.0.1:1"; return preferences
        }
        var modelAttempts = 0
        runtime.modelRequestCheck = { modelAttempts += 1; throw PetError("本地中断验收禁止模型请求") }
        defer { runtime.stopAll() }
        try tasks.organization.register(workspace.path, mode: .coding)
        let root = tasks.create(title: "公开中断主任务", workspace: workspace.path, mode: .agent)
        _ = try await AgentGit(store: tasks, taskID: root, directory: AgentGit.metadata(workspace: workspace.path, creating: true)).initialize()
        let script = #"""
        #!/bin/sh
        case "$1" in
          invalid) printf '%s\n' '{"continue":true,"hookSpecificOutput":{"additionalContext":"不得进入任务"}}' ;;
          slow) printf '%s' "$$" > "$QODER_PROJECT_DIR/slow-hook.pid"; exec /bin/sleep 20 ;;
          *) IFS= read -r payload
             printf '%s\n' "$payload" >> "$QODER_PROJECT_DIR/interrupt-payload.jsonl"
             printf '%s\n' '{"systemMessage":"公开中断记录已写入 PUBLIC-LOCAL-INTERRUPT-KEY"}' ;;
        esac
        """#
        try Data(script.utf8).write(to: scripts.appendingPathComponent("interrupt.sh"))
        let content = #"""
        [[hooks.Interrupt]]
        matcher = "[ignored"
        [[hooks.Interrupt.hooks]]
        name = "无效的公开控制输出"
        command = '/bin/sh "$QODER_HOOK_ROOT/interrupt.sh" invalid'
        [[hooks.Interrupt.hooks]]
        name = "记录公开停止"
        command = '/bin/sh "$QODER_HOOK_ROOT/interrupt.sh" warning'
        [[hooks.Interrupt.hooks]]
        name = "有界后台停止"
        command = '/bin/sh "$QODER_HOOK_ROOT/interrupt.sh" slow'
        timeout = 40
        async = true
        """#
        try Data(content.utf8).write(to: codex.appendingPathComponent("config.toml"))
        await tasks.dataImport.detect(.codex, root: source, category: .configuration, workspace: workspace.path)
        guard let item = tasks.dataImport.preview.first(where: { $0.title == "config.toml" && $0.issue == nil }) else { throw PetError("缺少合法中断导入预览") }
        try await AgentStandaloneDataImport.install(item, root: source, store: tasks)
        let imported = try tasks.hooks.catalog(workspace: workspace.path).filter { $0.event == .interrupt }
        checks["tomlImportsInterruptDisabledWithBoundedTimingAndNoMatcher"] = imported.count == 3 && item.preview.contains("Interrupt")
            && imported.allSatisfy { $0.matcher.isEmpty && !tasks.hooks.enabled($0) }
            && imported.first(where: { $0.name == "记录公开停止" })?.timeout == 1 && imported.first(where: \.runsInBackground)?.timeout == 3
        for hook in imported { try tasks.hooks.setEnabled(hook, true, workspace: workspace.path) }
        let pid = try await startInterruptFixture(root, label: "root", runtime: runtime)
        let session = tasks.task(root)?.hookSession, stoppedAt = Date()
        runtime.interrupt(root); runtime.interrupt(root)
        checks["explicitStopDetachesTurnImmediately"] = !runtime.isExecuting(root) && tasks.task(root)?.status == .stopped && modelAttempts == 0
        let deadline = Date().addingTimeInterval(7)
        while (runtime.isBusy(root) || kill(pid, 0) == 0), Date() < deadline { await wait(0.025) }
        let events = tasks.task(root)?.events.filter { $0.hook?.event == .interrupt } ?? []
        let warning = events.first { $0.title == "记录公开停止" }, timeout = events.first { $0.title == "有界后台停止" }
        let slowPID = Int32((try? String(contentsOf: workspace.appendingPathComponent("slow-hook.pid"), encoding: .utf8)) ?? "")
        let payload = workspace.appendingPathComponent("interrupt-payload.jsonl")
        let messages = try String(contentsOf: payload, encoding: .utf8).split(separator: "\n")
        guard let line = messages.first else { throw PetError("公开中断记录为空") }
        let delivered = try AgentConfigurationJSON.object(Data(line.utf8))
        checks["singleStopUsesOriginalSessionTurnModelAndScope"] = messages.count == 1 && events.count == 3
            && session != nil && delivered["session_id"] as? String == session && delivered["turn_id"] as? String != nil
            && delivered["model"] as? String == "interrupt-fixture" && delivered["cwd"] as? String == workspace.path
            && delivered["permission_mode"] as? String == AgentPermissionMode.automatic.rawValue
            && delivered["hook_event_name"] as? String == "Interrupt" && delivered["transcript_path"] as? String != nil
        checks["onlyWarningIsRenderedAndCredentialIsRedacted"] = warning?.status == "completed"
            && warning?.detail.contains("公开中断记录已写入 [凭据已隐藏]") == true && warning?.detail.contains(key) == false
            && events.contains { $0.title == "无效的公开控制输出" && $0.status == "failed" && $0.detail.contains("systemMessage") }
        checks["stoppedCommandAndTimedOutHookProcessesAreReaped"] = kill(pid, 0) != 0 && slowPID.map { $0 > 1 && kill($0, 0) != 0 } == true
            && timeout?.status == "failed" && timeout?.detail.contains("超时") == true && Date().timeIntervalSince(stoppedAt) < 6
        checks["noControlOrContextAndNoModelRestart"] = tasks.task(root)?.status == .stopped && tasks.task(root)?.hookContexts?.isEmpty != false
            && tasks.task(root)?.messages.contains { $0.content.contains("不得进入任务") } == false && modelAttempts == 0

        for hook in imported where hook.name != "记录公开停止" { try tasks.hooks.setEnabled(hook, false, workspace: workspace.path) }
        let internalStop = tasks.create(title: "公开后台取消", workspace: workspace.path, mode: .agent)
        let otherPID = try await startInterruptFixture(internalStop, label: "internal", runtime: runtime)
        runtime.cancel(internalStop); runtime.interrupt(root)
        let finishedBy = Date().addingTimeInterval(3)
        while kill(otherPID, 0) == 0, Date() < finishedBy { await wait(0.025) }
        checks["internalCancellationAndIdleStopDoNotRunHook"] = kill(otherPID, 0) != 0 && tasks.task(internalStop)?.status == .stopped
            && tasks.task(internalStop)?.events.contains { $0.hook?.event == .interrupt } == false
            && (try? String(contentsOf: payload, encoding: .utf8).split(separator: "\n").count) == 1
        let typed = tasks.create(title: "公开文字停止", workspace: workspace.path, mode: .agent)
        _ = try await startInterruptFixture(typed, label: "typed", runtime: runtime)
        let accepted = runtime.submit("停止任务", taskID: typed)
        let typedBy = Date().addingTimeInterval(5)
        while runtime.isBusy(typed), Date() < typedBy { await wait(0.025) }
        checks["typedStopUsesSameEntryPointAndPreservesMessage"] = accepted && tasks.task(typed)?.status == .stopped
            && tasks.task(typed)?.messages.filter { $0.isHumanInput && $0.content == "停止任务" }.count == 1
            && tasks.task(typed)?.events.filter { $0.hook?.event == .interrupt && $0.status == "completed" }.count == 1 && modelAttempts == 0

        let side = try tasks.sideTasks.create(parentID: root)
        let sidePID = try await startInterruptFixture(side, label: "side", runtime: runtime)
        runtime.interrupt(side)
        let sideDeadline = Date().addingTimeInterval(3)
        while kill(sidePID, 0) == 0, Date() < sideDeadline { await wait(0.025) }
        checks["explicitStopInLiveSideThreadDoesNotRunMainThreadHook"] = kill(sidePID, 0) != 0 && tasks.task(side)?.status == .stopped
            && tasks.task(side)?.events.contains { $0.hook?.event == .interrupt } == false
            && (try? String(contentsOf: payload, encoding: .utf8).split(separator: "\n").count) == 2
    }

    func startInterruptFixture(_ id: String, label: String, runtime: AgentRuntime) async throws -> pid_t {
        let tasks = runtime.store
        guard let path = tasks.task(id)?.workspace else { throw PetError("缺少独立中断工作区") }
        let marker = label + ".pid", url = URL(fileURLWithPath: path).appendingPathComponent(marker)
        let arguments = try JSONSerialization.data(withJSONObject: ["command": "printf '%s' $$ > " + AgentGit.quote(marker) + "\nexec /bin/sleep 120", "network": false, "timeout_seconds": 125])
        let call = AgentToolCall(id: UUID().uuidString, name: "run_command", arguments: String(decoding: arguments, as: UTF8.self))
        tasks.update(id) { record in
            record.permission = .automatic
            record.messages = [AgentMessage(role: "user", content: "核对公开任务的中断记录。"), AgentMessage(role: "assistant", content: "", toolCalls: [call])]
            record.pendingCalls = [call]
            var approval = AgentApproval(call: call, reason: "独立验收中的本机等待命令", workspace: path)
            approval.decision = "allow"; approval.decidedAt = Date()
            record.approvals.append(approval)
        }
        runtime.start(id)
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text), pid > 1, kill(pid, 0) == 0 { return pid }
            if !runtime.isExecuting(id) { break }
            await wait(0.025)
        }
        throw PetError("验收中的本机命令未运行：" + (tasks.task(id)?.events.last?.detail ?? "无记录"))
    }

    func prepareInterruptWindow(_ output: URL, tasks: AgentStore, runtime: AgentRuntime) async throws {
        let workspace = output.appendingPathComponent("InterruptWindow")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let id = tasks.create(title: "公开停止任务验收", workspace: workspace.path, mode: .agent)
        _ = try await AgentGit(store: tasks, taskID: id, directory: AgentGit.metadata(workspace: workspace.path, creating: true)).initialize()
        let config = #"{"hooks":{"Interrupt":[{"hooks":[{"name":"公开中断提示","type":"command","command":"/usr/bin/printf","args":["%s","{\"systemMessage\":\"本机验收已收到停止信号\"}"]}]}]}}"#
        try tasks.hooks.save(config, project: true, workspace: workspace.path, expectedHash: nil)
        guard let hook = try tasks.hooks.catalog(workspace: workspace.path).first(where: { $0.name == "公开中断提示" }) else { throw PetError("缺少窗口中断处理器") }
        try tasks.hooks.setEnabled(hook, true, workspace: workspace.path)
        control.showAgentTask(id)
        let process = try await startInterruptFixture(id, label: "window", runtime: runtime)
        try JSONSerialization.data(withJSONObject: ["taskID": id, "processID": process, "hookID": hook.id], options: [.sortedKeys]).write(
            to: output.appendingPathComponent("interrupt-window-fixture.json"), options: .atomic)
    }
}
