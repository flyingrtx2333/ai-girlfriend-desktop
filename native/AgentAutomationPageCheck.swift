import AppKit

@MainActor extension AppDelegate {
    func prepareAutomationPageUI(_ output: URL) async throws -> (taskID: String, automationID: String) {
        ensureAgent()
        guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("自动化验收未初始化") }
        let project = output.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("# 公开项目核对\n自动化页面验收使用的公开文档。\n".utf8).write(to: project.appendingPathComponent("README.md"))
        // Exercise a real instruction-loading failure before any model transmission.
        try Data("@MISSING-NATIVE-CHECK-INSTRUCTIONS.md\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        let taskID = tasks.create(title: "自动化页面验收", workspace: project.path)
        guard runtime.submit("管理公开项目的本机计划。", taskID: taskID, startImmediately: false) else { throw PetError("公开用户输入未保存") }
        tasks.update(taskID) { $0.draft = "原任务尚未发送的自动化说明。" }
        control.showAgentTask(taskID)
        let service = tasks.automations; service.start(store: tasks, runtime: runtime)
        guard service.isStarted else { throw PetError(service.error ?? "独立调度器未启动") }
        var daily = AgentAutomation(name: "每日项目核对", prompt: "读取 README 并核对项目标题。", workspace: project.path); daily.notify = false
        var weekly = AgentAutomation(name: "每周摘要", prompt: "整理公开 README 的要点。", workspace: project.path); weekly.notify = false; weekly.schedule.frequency = .weekly; weekly.schedule.weekdays = [2, 6]
        var archived = AgentAutomation(name: "已归档的公开计划", prompt: "核对公开文档。", workspace: project.path); archived.archived = true; archived.notify = false
        for value in [daily, weekly, archived] { try service.save(value, expected: nil) }
        try service.runNow(daily.id)
        let deadline = Date().addingTimeInterval(20)
        while tasks.tasks.contains(where: { runtime.isBusy($0.id) }) || service.values.contains(where: { $0.current != nil }) {
            guard Date() < deadline else { throw PetError("实际指令错误尚未结束") }; await wait(0.05)
        }
        guard let run = try service.history(automationID: daily.id).runs.first, run.status == .failed, run.taskID != nil else { throw PetError("实际失败记录未保存") }
        try JSONSerialization.data(withJSONObject: ["taskID": taskID, "automationID": daily.id, "weeklyID": weekly.id, "archivedID": archived.id, "runID": run.id, "runTaskID": run.taskID!], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("automation-page-fixtures.json"))
        return (taskID, daily.id)
    }

    func runAutomationPageCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], blocked = 0
        defer { agentRuntime?.stopAll(); agentStore?.automations.stop() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { blocked += 1; throw PetError("自动化页面验收禁止模型传输") }
            let fixture = try await prepareAutomationPageUI(output)
            control.showAutomations(); guard let manager = control.automationWindow else { throw PetError("自动化未进入主窗口") }
            checks["initialCatalogUsesActualStoredPlans"] = manager.checkState()["editing"] as? Bool == false && manager.checkState()["definitions"] as? [[String: Any]] != nil && tasks.automations.values.count == 3
            let navigation = try control.checkAutomationNavigation(fixture.automationID)
            checks.merge(navigation["checks"] as? [String: Bool] ?? [:]) { _, new in new }; report["frames"] = navigation["frames"]
            openTaskWindow(fixture.taskID, from: control)
            guard let other = additionalTaskWindows.last else { throw PetError("第二任务窗口不可用") }
            other.showAutomations()
            checks["eachTaskWindowOwnsItsAutomationView"] = other.automationWindow !== manager && other.automationWindow?.presentingWindow === other.window && manager.presentingWindow === control.window
            other.window?.performClose(nil)
            checks["closingOtherWindowRetainsMainPage"] = manager.isVisible && other.window?.isVisible != true
            checks.merge(try manager.checkPageOperations(fixture.automationID)) { _, new in new }
            report["selectionContrasts"] = manager.checkState()["selectionContrasts"]
            let actualRunTask = try tasks.automations.history(automationID: fixture.automationID).runs.first?.taskID
            checks["historyOpensItsActualTaskInOwnerWindow"] = control.agentTaskID == actualRunTask
            control.showAgentTask(fixture.taskID); control.showAutomations()
            checks["originalTaskDraftSurvivesAllPageOperations"] = tasks.task(fixture.taskID)?.draft == "原任务尚未发送的自动化说明。"
            let stored = tasks.automations.values.map(\.id).sorted()
            tasks.automations.stop(); tasks.automations.start(store: tasks, runtime: runtime)
            let historyTotal = try tasks.automations.history(automationID: fixture.automationID).total
            checks["serviceRestartRetainsSavedDefinitionsAndActualHistory"] = tasks.automations.values.map(\.id).sorted() == stored && historyTotal == 1
            checks["noInventedAssistantOrCompletedModelReceipt"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { !$0.messages.contains { $0.role == "assistant" } && !($0.modelReceipts ?? []).contains { $0.completed } }
            checks["noPlanLeftEnabledByNativeChecks"] = tasks.automations.values.allSatisfy { !$0.enabled }
            report["success"] = checks.count >= 30 && checks.values.allSatisfy { $0 }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        report["checks"] = checks; report["blockedModelAttempts"] = blocked; report["modelTransmissions"] = 0; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("automation-page-report.json"))
    }
}
