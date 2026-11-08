import AppKit

@MainActor extension AppDelegate {
    func runAgentOrganizationCheck(_ output: URL) async {
        let fm = FileManager.default
        var report: [String: Any] = [:], checks: [String: Bool] = [:]
        func write(_ object: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务运行时未初始化") }
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash, "arguments": CommandLine.arguments], "organization-process.json")
            let nativeName = "organization-native-" + String(hash.prefix(12)) + ".json"
            if fm.fileExists(atPath: output.appendingPathComponent(nativeName).path) {
                let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent(nativeName))) as! [String: Any]
                guard previous["success"] as? Bool == true, let values = previous["checks"] as? [String: Bool] else { throw PetError("保留原候选的失败检查，不覆盖") }; checks = values
            } else {
                let coding = tasks.create(title: "编程归属检查", workspace: output.appendingPathComponent("coding").path)
                let general = tasks.create(title: "通用归属检查", workspace: output.appendingPathComponent("general").path, workMode: .general)
                let original = try Data(contentsOf: tasks.directory.appendingPathComponent(coding + ".json"))
                checks["codingOmitsOptionalFieldForExistingSchema"] = (try JSONSerialization.jsonObject(with: original) as? [String: Any])?["workMode"] == nil
                let branchRead = try await AgentCommand().run(command: "git symbolic-ref --short HEAD", workspace: output.appendingPathComponent("coding"), scratch: tasks.backupDirectory(coding), network: false, timeout: 5, readOnly: true, protectedData: tasks.directory.deletingLastPathComponent())
                checks["actualTerminalGitReadsBranchInsideExistingIsolation"] = !branchRead.failed && branchRead.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "codex/work-mode-check"
                try tasks.organization.register(output.appendingPathComponent("coding").path, mode: .coding)
                try tasks.organization.register(output.appendingPathComponent("general").path, mode: .general)
                try tasks.organization.register(output.appendingPathComponent("coding").path, mode: .general)
                try tasks.organization.rename(output.appendingPathComponent("coding").path, mode: .general, name: "通用资料", tasks: tasks.tasks)
                try tasks.organization.rename(output.appendingPathComponent("general").path, mode: .general, name: "财务资料", tasks: tasks.tasks)
                if tasks.organization.directories(.general, tasks: tasks.tasks).first(where: { $0.path == output.appendingPathComponent("general").path })?.pinned != true {
                    try tasks.organization.togglePinned(output.appendingPathComponent("general").path, mode: .general, tasks: tasks.tasks)
                }
                try tasks.organization.sort(.name, mode: .general)
                checks["namesPinsSortingDoNotModifyTaskOrDirectory"] = try Data(contentsOf: tasks.directory.appendingPathComponent(coding + ".json")) == original && fm.fileExists(atPath: output.appendingPathComponent("coding/calculator.py").path)
                checks["samePhysicalDirectoryHasIndependentModeNames"] = tasks.organization.name(output.appendingPathComponent("coding").path, mode: .coding) == "coding" && tasks.organization.name(output.appendingPathComponent("coding").path, mode: .general) == "通用资料"
                checks["pinnedFolderLeadsItsActualNameSort"] = tasks.organization.directories(.general, tasks: tasks.tasks).first?.path == output.appendingPathComponent("general").path
                checks["sortIsIndependentPerMode"] = tasks.organization.sorting(.coding) == .recent && tasks.organization.sorting(.general) == .name
                control.showAgentTask(coding); control.keepVoiceDraft("CODING-DRAFT-2086"); control.persistAgentDraft()
                control.showAgentTask(general); control.keepVoiceDraft("GENERAL-DRAFT-2086"); control.persistAgentDraft()
                control.switchWorkMode(.coding)
                checks["switchRestoresCodingTaskAndDraft"] = tasks.selectedID == coding && control.organizationSnapshot()["draft"] as? String == "CODING-DRAFT-2086"
                control.switchWorkMode(.general)
                checks["switchRestoresGeneralTaskAndDraft"] = tasks.selectedID == general && control.organizationSnapshot()["draft"] as? String == "GENERAL-DRAFT-2086"
                control.switchWorkMode(.coding)
                let restored = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
                checks["actualFilesReopenWithModesAndDrafts"] = restored.task(coding)?.organizationMode == .coding && restored.task(general)?.organizationMode == .general && restored.task(coding)?.draft == "CODING-DRAFT-2086" && restored.task(general)?.draft == "GENERAL-DRAFT-2086" && restored.organization.lastTask(.coding, tasks: restored.tasks) == coding && restored.organization.lastTask(.general, tasks: restored.tasks) == general
                checks["directoryPreferencesPersistOnReopen"] = restored.organization.name(output.appendingPathComponent("general").path, mode: .general) == "财务资料" && restored.organization.sorting(.general) == .name && restored.organization.directories(.general, tasks: restored.tasks).first?.pinned == true
                let fork = tasks.fork(general)
                checks["forkKeepsModeFolderAndDraft"] = fork.flatMap(tasks.task)?.organizationMode == .general && fork.flatMap(tasks.task)?.workspace == tasks.task(general)?.workspace && fork.flatMap(tasks.task)?.draft == "GENERAL-DRAFT-2086"
                if let fork { tasks.update(fork) { $0.archived = true } }
                tasks.update(general) { $0.mode = .ask }
                let blocked = "blocked-" + UUID().uuidString + ".txt"
                let denied = AgentToolCall(id: UUID().uuidString, name: "write_file", arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["path": blocked, "content": "blocked"]), as: UTF8.self))
                do { _ = try AgentTools(store: tasks, taskID: general).approvalReason(for: denied); checks["generalDoesNotBypassAskWriteLimit"] = false } catch { checks["generalDoesNotBypassAskWriteLimit"] = !fm.fileExists(atPath: output.appendingPathComponent("general/" + blocked).path) }
                let workspace = tasks.task(coding)?.workspace, permission = tasks.task(coding)?.permission
                control.showAgentTask(coding); control.checkOrganizationMove(coding)
                checks["movingModePreservesExecutionScope"] = tasks.task(coding)?.organizationMode == .general && tasks.task(coding)?.workspace == workspace && tasks.task(coding)?.permission == permission
                control.checkOrganizationMove(coding)
                tasks.update(coding) { $0.archived = true }; tasks.update(general) { $0.archived = true }
                guard checks.values.allSatisfy({ $0 }) else { try write(["success": false, "checks": checks], nativeName); throw PetError("工作模式原生检查未通过") }
                try write(["success": true, "checks": checks, "binaryHash": hash], nativeName)
            }
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("需要真实模型流程验收") }
            let production = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var preferences = PreferencesStore(directory: production).preferences
            let productionOutput = preferences.outputLimit
            preferences.replyTokens = 2048; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false; try preferences.validateModel(); store.preferences = preferences
            report["preferences"] = ["model": preferences.model, "context": preferences.contextLimit, "output": preferences.outputLimit, "productionOutput": productionOutput, "productionSettingsWritten": false]
            report["limits"] = ["requestsPerOriginalTask": 40, "approvalsPerOriginalTask": 12]
            let intents = [
                "general": "读取expenses.csv，按十进制金额核算三笔支出的总额，把每项与总额写入summary.md。保留原CSV，不读取其他目录，不用Git，只用文件和终端工具。完成后简短说明实际结果。",
                "coding": "检查calculator.py处理金额的小数问题，修复实际程序。用data.csv运行程序，把格式化为两位小数的金额写入result.txt。保留CSV，不提交Git，只用文件和终端工具。完成后简短说明实际运行结果。"
            ]
            let ownerURL = output.appendingPathComponent("organization-live-tasks.json")
            var owners = fm.fileExists(atPath: ownerURL.path) ? try JSONSerialization.jsonObject(with: Data(contentsOf: ownerURL)) as! [String: String] : [:]
            for key in ["general", "coding"] {
                let mode: AgentWorkMode = key == "general" ? .general : .coding, id: String
                if let old = owners[key] {
                    guard tasks.task(old)?.messages.first(where: \.isHumanInput)?.content == intents[key] else { throw PetError("原真实任务不可替换") }; id = old
                    if tasks.task(id)?.status != .completed { runtime.start(id) }
                } else {
                    id = tasks.create(title: mode.title + "真实文件任务", workspace: output.appendingPathComponent(key).path, workMode: mode)
                    tasks.update(id) { $0.permission = .review; $0.toolGroups = ["files", "terminal"] }
                    guard runtime.submit(intents[key]!, taskID: id) else { throw PetError(runtime.submissionError ?? "真实任务未开始") }
                    owners[key] = id; try write(owners, ownerURL.lastPathComponent)
                }
                control.showAgentTask(id)
                let deadline = Date().addingTimeInterval(900)
                while Date() < deadline {
                    guard let task = tasks.task(id) else { throw PetError("真实任务已丢失") }
                    if (task.modelReceipts?.count ?? 0) > 40 { runtime.cancel(id); throw PetError("真实任务超过40次请求上限，保留原记录") }
                    if task.status == .waiting, let call = task.pendingCalls.first {
                        guard ["read_file", "list_directory", "search_files", "write_file", "edit_file", "run_command"].contains(call.name), call.object["network"] as? Bool != true else { throw PetError("模型提出预期外审批：" + call.name) }
                        guard task.approvals.filter({ $0.decision == "allow" }).count < 12 else { throw PetError("真实任务超过12次审批上限，保留原记录") }
                        runtime.decide(taskID: id, callID: call.id, decision: "allow")
                    }
                    if task.status == .completed && !runtime.isExecuting(id) { break }
                    if [.failed, .stopped].contains(task.status), !runtime.isExecuting(id) { throw PetError("原真实任务已停止：" + (task.events.last?.detail ?? "")) }
                    await wait(0.2)
                }
                guard let task = tasks.task(id), task.status == .completed else { throw PetError("真实任务尚未完成，保留原始记录") }
                report[key] = ["taskID": id, "status": task.status.rawValue, "requests": task.modelReceipts?.count ?? 0, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "model": task.model, "artifacts": task.artifacts]
            }
            guard let general = owners["general"], let coding = owners["coding"] else { throw PetError("真实任务编号缺失") }
            control.showAgentTask(coding); control.switchWorkMode(.general); control.show(tab: "chat")
            try write(["appPID": getpid(), "binaryHash": hash, "tasks": owners, "snapshot": control.organizationSnapshot()], "organization-ui-ready.json")
            let deadline = Date().addingTimeInterval(1200)
            while Date() < deadline, !fm.fileExists(atPath: output.appendingPathComponent("finish-organization-ui").path) { await wait(0.2) }
            let ui = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("organization-ui-acceptance.json"))) as! [String: Any]
            let required = ["switchKeepsTaskDraftsAndFolders", "namesPinsSortingWorkInUI", "codingShowsActualBranch", "generalHidesEngineeringControls", "normalAndNarrowLayout"]
            guard ui["binaryHash"] as? String == hash, ui["appPID"] as? Int == Int(getpid()), let values = ui["checks"] as? [String: Bool], required.allSatisfy({ values[$0] == true }) else { throw PetError("真实工作模式窗口验收未通过") }
            checks["actualGeneralTaskUsesGeneralMode"] = tasks.task(general)?.organizationMode == .general
            checks["actualCodingTaskUsesCodingMode"] = tasks.task(coding)?.organizationMode == .coding
            report["ui"] = ui; report["checks"] = checks; report["binaryHash"] = hash; report["success"] = checks.values.allSatisfy { $0 }
            try write(report, "organization-report.json")
        } catch { report["success"] = false; report["checks"] = checks; report["error"] = error.localizedDescription; try? write(report, "organization-report.json") }
    }
}
