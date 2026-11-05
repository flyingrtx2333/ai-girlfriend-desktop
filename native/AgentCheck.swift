import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runAgentCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        let fm = FileManager.default, workspace = output.appendingPathComponent("workspace", isDirectory: true), scratch = output.appendingPathComponent("scratch", isDirectory: true)
        func progress(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        func capture(_ name: String) {
            guard let view = control.window?.contentView else { return }; view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png")) }
        }
        do {
            progress("native-tools")
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true); try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let files = try AgentFiles(workspace: workspace.path)
            let outside = output.appendingPathComponent("outside.txt"); try Data("outside".utf8).write(to: outside)
            let link = workspace.appendingPathComponent("outside-link"); try? fm.removeItem(at: link); try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            checks["outsidePathBlocked"] = (try? files.resolve("../outside.txt")) == nil
            checks["outsideSymlinkBlocked"] = (try? files.resolve("outside-link")) == nil
            let ok = try await AgentCommand().run(command: "printf native-ok > command.txt; cat command.txt", workspace: workspace, scratch: scratch, network: false, timeout: 5)
            checks["realSandboxCommand"] = !ok.failed && ok.text.contains("native-ok")
            let escape = try await AgentCommand().run(command: "printf escaped > ../outside.txt", workspace: workspace, scratch: scratch, network: false, timeout: 5)
            let unchanged = try String(contentsOf: outside, encoding: .utf8)
            checks["kernelBlocksOutsideWrite"] = escape.failed && unchanged == "outside"
            let process = AgentCommand()
            let job = Task { try await process.run(command: "sleep 30 & child=$!; echo \"$child\" > child.pid; wait", workspace: workspace, scratch: scratch, network: false, timeout: 40) }
            for _ in 0..<40 { if fm.fileExists(atPath: workspace.appendingPathComponent("child.pid").path) { break }; await wait(0.05) }
            let child = Int32((try? String(contentsOf: workspace.appendingPathComponent("child.pid"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            job.cancel(); _ = try? await job.value; await wait(0.3)
            checks["cancelKillsChildProcess"] = child > 0 && kill(child, 0) != 0 && !process.snapshot().running
            let timeout = try await AgentCommand().run(command: "sleep 30", workspace: workspace, scratch: scratch, network: false, timeout: 1)
            checks["commandTimeout"] = timeout.failed && timeout.text.contains("timeout")
            report["terminalProbes"] = ["normal": ok.text, "outside": escape.text, "timeout": timeout.text, "childPID": Int(child)]
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let localID = tasks.create(title: "检查点校验", workspace: workspace.path)
            let original = Data("original\n".utf8); try original.write(to: workspace.appendingPathComponent("restore.txt"))
            _ = try await AgentTools(store: tasks, taskID: localID).execute(call("write_file", ["path": "restore.txt", "content": "agent edit\n"]))
            guard let change = tasks.task(localID)?.changes.first else { throw PetError("缺少检查点") }
            try Data("user edit\n".utf8).write(to: workspace.appendingPathComponent("restore.txt"))
            do { try AgentChanges.restore(change, taskID: localID, store: tasks); checks["restoreProtectsUserEdits"] = false } catch { checks["restoreProtectsUserEdits"] = true }
            try Data("agent edit\n".utf8).write(to: workspace.appendingPathComponent("restore.txt")); try AgentChanges.restore(change, taskID: localID, store: tasks)
            checks["restoreUsesRealCheckpoint"] = try files.readData(files.resolve("restore.txt")) == original
            let readOnly = tasks.create(title: "问答权限", workspace: workspace.path, mode: .ask)
            do { _ = try AgentTools(store: tasks, taskID: readOnly).approvalReason(for: call("write_file", ["path": "forbidden.txt", "content": "no"])); checks["askCannotWrite"] = false } catch { checks["askCannotWrite"] = true }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("原生工具检查失败，尚未进行模型验收") }
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("原生工具已检查；真实模型验收请加 --live-agent") }
            let productionDirectory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish", isDirectory: true)
            var p = PreferencesStore(directory: productionDirectory).preferences
            p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.replyTokens = min(4096, max(2048, p.replyTokens)); p.contextTokens = max(32_768, p.contextTokens)
            store.preferences = p
            let csv = Data("item,quantity,unit_price\ntea,2,12.50\ncake,3,8.00\n".utf8); try csv.write(to: workspace.appendingPathComponent("sales.csv"))
            let id = tasks.create(title: "真实 Agent · 销售汇总", workspace: workspace.path, mode: .goal)
            tasks.update(id) { $0.permission = .review; $0.model = p.model }
            control.show(tab: "chat"); progress("live-model")
            runtime.submit("读取 sales.csv，按 quantity × unit_price 计算销售总额，在项目根目录写 result.md，列出每件商品的小计和总计，使用 awk 命令独立验证 sales.csv 的总计。先用 update_plan 列计划，做完更新全部步骤并用 finish_task 引用实际证据。只读 sales.csv，只写 result.md，只执行这个无网络验证命令，不需要别的文件或联网。", taskID: id)
            let end = Date().addingTimeInterval(180); var approvalCount = 0, checkedPendingWrite = false
            while Date() < end, let task = tasks.task(id) {
                if task.status == .waiting, let call = task.pendingCalls.first {
                    approvalCount += 1; control.renderMessages(); capture("approval-\(approvalCount)")
                    if call.name == "write_file", let path = call.object["path"] as? String, (try? files.resolve(path)) == workspace.appendingPathComponent("result.md") {
                        checkedPendingWrite = !fm.fileExists(atPath: workspace.appendingPathComponent("result.md").path)
                        runtime.decide(taskID: id, callID: call.id, decision: "allow")
                    } else if call.name == "run_command", let command = call.object["command"] as? String, command.contains("awk"), command.contains("sales.csv"), call.object["network"] as? Bool != true {
                        runtime.decide(taskID: id, callID: call.id, decision: "allow")
                    } else { runtime.decide(taskID: id, callID: call.id, decision: "deny") }
                }
                if [.completed, .failed, .stopped].contains(task.status) { break }; await wait(0.1)
            }
            let task = tasks.task(id)!
            if runtime.isRunning(id) { runtime.cancel(id) }
            let result = (try? files.readData(files.resolve("result.md"))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            checks["liveModelCompletesGoal"] = task.status == .completed && task.goalAccepted == true
            checks["modelUsesReadWriteCommand"] = Set(task.events.filter { $0.kind == "tool" && $0.status == "completed" }.map(\.title)).isSuperset(of: ["read_file", "write_file", "run_command", "finish_task"])
            checks["approvalPreventsPrematureWrite"] = checkedPendingWrite && approvalCount >= 2
            checks["actualFileTotalIs49"] = result.contains("49") && (result.contains("25") && result.contains("24"))
            checks["originalInputUnchanged"] = try files.readData(files.resolve("sales.csv")) == csv
            checks["independentCommandAgrees"] = task.events.contains { $0.title == "run_command" && $0.status == "completed" && $0.detail.contains("49") }
            checks["completePlanAndEvidence"] = !task.plan.isEmpty && task.plan.allSatisfy { $0.status == "completed" } && !(task.completionEvidence ?? []).isEmpty
            checks["evidenceDoesNotLoopOrAskUser"] = task.events.filter { $0.title == "finish_task" && $0.status == "failed" }.count <= 1 && !task.events.contains { $0.title == "ask_user" }
            let recovered = AgentStore(directory: store.directory, legacy: [])
            checks["tasksPersistAcrossReload"] = recovered.task(id)?.messages.count == task.messages.count && recovered.task(id)?.status == task.status
            let forkID = tasks.fork(id), fork = forkID.flatMap { tasks.task($0) }
            checks["forkPreservesContextWithoutApprovals"] = fork?.parentID == id && fork?.messages.count == task.messages.count && fork?.approvals.isEmpty == true
            tasks.selectedID = id; control.renderMessages(); capture("agent-complete")
            let layout = await control.checkAgentLayout(output); checks.merge(layout) { _, new in new }
            report["live"] = ["model": p.model, "status": task.status.rawValue, "approvalCount": approvalCount, "toolCalls": task.events.filter { $0.kind == "tool" }.map { ["name": $0.title, "status": $0.status] }, "result": result, "reply": task.summary, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens]
        } catch { report["error"] = error.localizedDescription }
        progress("finished")
        report["success"] = checks.values.allSatisfy { $0 } && checks["liveModelCompletesGoal"] == true && report["error"] == nil
        report["checks"] = checks; report["scope"] = "Independent profile and public CSV; actual configured model, native tools, kernel sandbox, approvals, checkpoint restore and native UI. No production configuration writes, microphone or TTS."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("agent-report.json")) }
    }
}
