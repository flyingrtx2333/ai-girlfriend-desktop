import AppKit

@MainActor extension AppDelegate {
    struct TaskWorkspaceFixture { let taskID: String, secondID: String, standaloneID: String, workspace: URL, guide: URL, plain: URL, duplicate: URL }
    func prepareTaskWorkspaceUI(_ output: URL) async throws -> TaskWorkspaceFixture {
        guard !CommandLine.arguments.contains("--live-agent"), let argument = CommandLine.arguments.firstIndex(of: "--task-workspace-source"), CommandLine.arguments.indices.contains(argument + 1) else { throw PetError("任务工作区验收需要公开项目文档，不调用模型") }
        ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
        let origin = try AgentFiles(workspace: CommandLine.arguments[argument + 1]), project = output.appendingPathComponent("public-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try AgentFiles(workspace: project.path), guide = try files.resolve("docs/AGENT-READING.md"), plain = try files.resolve("runtime.txt"), duplicate = try files.resolve("mirror/AGENT-READING.md")
        let initialized = try await AgentCommand().run(command: try AgentGit.executablePath(), workspace: output, scratch: output.appendingPathComponent("tmp"), network: false, timeout: 10, gitDirectory: project.appendingPathComponent(".git"), gitWrite: true, protectedData: store.directory, arguments: ["-C", project.path, "init", "-b", "main"])
        guard !initialized.failed else { throw PetError(initialized.text) }
        let original = try origin.readData(origin.resolve("docs/AGENT-READING.md")), configuration = try origin.readData(origin.resolve("package.json"))
        guard let text = String(data: original, encoding: .utf8), !text.isEmpty else { throw PetError("公开文档不是 UTF-8") }
        let guideBytes = Data([0xEF, 0xBB, 0xBF]) + Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
        try files.writeData(guideBytes, to: guide); try files.writeData(configuration, to: plain); try files.writeData(original, to: duplicate)
        let first = tasks.create(title: "任务工作区与文件", workspace: project.path), second = tasks.create(title: "另一任务的文件草稿", workspace: project.path), standalone = tasks.create(title: "无工作区的任务详情", mode: .ask, workMode: .general)
        guard runtime.submit("核对公开项目文档和本机读取记录。", taskID: first, startImmediately: false) else { throw PetError("公开用户输入未保存") }
        let result = try await AgentCommand().run(command: "/usr/bin/shasum", workspace: project, scratch: output.appendingPathComponent("tmp"), network: false, timeout: 10, protectedData: store.directory, arguments: ["-a", "256", guide.path])
        guard !result.failed, result.text.contains(AgentFiles.hash(guideBytes)) else { throw PetError("实际文件校验失败") }
        for id in [first, second] { tasks.update(id) { $0.artifacts = [guide.path, plain.path, duplicate.path]; $0.sources = [guide.absoluteString]; $0.draft = id == first ? "保留项目任务的输入草稿。" : "保留另一任务的输入草稿。" } }
        tasks.update(first) { $0.events.append(AgentEvent(kind: "tool", title: "本机校验公开文档", detail: result.text, status: "completed")) }
        tasks.update(standalone) { $0.draft = "无工作区任务的原草稿。" }
        try tasks.organization.register(project.path, mode: .coding)
        let fixture = TaskWorkspaceFixture(taskID: first, secondID: second, standaloneID: standalone, workspace: project, guide: guide, plain: plain, duplicate: duplicate)
        let value: [String: Any] = ["taskID": first, "secondID": second, "standaloneID": standalone, "workspace": project.path, "guide": guide.path, "plain": plain.path, "duplicate": duplicate.path, "guideSHA256": AgentFiles.hash(guideBytes), "originalSourceSHA256": AgentFiles.hash(original), "configurationSHA256": AgentFiles.hash(configuration), "modelTransmissions": 0]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("task-workspace-fixtures.json"))
        control.showAgentTask(first); control.show(tab: "chat"); control.presentAgentRecords(section: 4); return fixture
    }
    func reopenTaskWorkspaceUI(_ output: URL) throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("task-workspace-fixtures.json"))) as? [String: Any]
        guard let id = value?["taskID"] as? String, let file = value?["guide"] as? String, agentStore?.task(id) != nil else { throw PetError("未找到保留的文件任务") }
        control.showAgentTask(id); control.showTaskDocument(file)
    }
    func runTaskWorkspaceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], attempts = 0
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务系统不可用") }
            runtime.modelRequestCheck = { attempts += 1; throw PetError("任务工作区验收禁止模型请求") }
            let fixture = try await prepareTaskWorkspaceUI(output), host = control.taskWorkspace
            let files = try AgentFiles(workspace: fixture.workspace.path), initial = try files.readData(fixture.guide), initialText = try AgentTextFile.decode(initial).text
            let plainBytes = try files.readData(fixture.plain), duplicateBytes = try files.readData(fixture.duplicate)
            var geometry: [String: Any] = [:]
            func inspect(_ name: String) async {
                for (kind, size) in [("split", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                    control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); await wait(0.1)
                    let value = await control.taskWorkspaceReadback(); geometry[name + "-" + kind] = value
                    for (key, pass) in host.checkState()["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + kind + "-" + key] = pass }
                    if let record = host.currentController as? AgentRecordWindow { for (key, pass) in await record.workspaceReadback()["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + kind + "-" + key] = pass } }
                    checks[name + "-" + kind + "-conversationRetained"] = value["draft"] as? String == "保留项目任务的输入草稿。" && (value["conversationWidth"] as? Double ?? 0) >= 430
                    checks[name + "-" + kind + "-responsiveWorkspace"] = value["conversationVisible"] as? Bool == (kind == "split" && !host.expanded)
                    checks[name + "-" + kind + "-windowSizeStable"] = value["windowSize"] as? [Double] == [Double(size.width), Double(size.height)]
                }
                control.window?.setContentSize(NSSize(width: 1200, height: 774)); control.window?.contentView?.layoutSubtreeIfNeeded()
            }
            guard let records = host.currentController as? AgentRecordWindow else { throw PetError("记录未进入任务工作区") }
            checks["logsContainActualLocalFileHash"] = await records.workspaceReadback()["draft"] as? String == tasks.task(fixture.taskID)?.events.map { $0.title + " · " + $0.statusTitle + "\n" + $0.detail }.joined(separator: "\n\n────────\n\n")
            await inspect("records"); await records.checkTaskDocument(action: "files"); await inspect("record-list"); await records.checkTaskDocument(action: "files")
            control.presentTaskContext(section: 0)
            guard let context = host.currentController as? AgentContextWindow else { throw PetError("上下文未进入任务工作区") }
            let estimate = try runtime.contextEstimate(fixture.taskID)
            checks["contextUsesActualEstimateWithoutRequest"] = (context.workspaceReadback()["text"] as? String)?.contains(estimate.estimatedTokens.formatted(.number)) == true && context.workspaceReadback()["mainWindow"] as? Bool == true && estimate.estimatedTokens > 0 && tasks.task(fixture.taskID)?.contextSnapshot == nil
            context.selectSection(1); checks["recapShowsActualTaskAndArtifactWithoutGenerating"] = (context.workspaceReadback()["text"] as? String)?.contains(fixture.guide.path) == true && tasks.task(fixture.taskID)?.recap == nil
            context.selectSection(2); checks["emptyReceiptsStayEmpty"] = (context.workspaceReadback()["text"] as? String)?.contains("暂无分次记录") == true && tasks.task(fixture.taskID)?.modelReceipts?.isEmpty != false
            await inspect("task-details")
            control.showTaskDocument(fixture.guide.path)
            guard let guide = host.currentController as? AgentRecordWindow else { throw PetError("文件未进入独立标签页") }
            checks["markdownOpensWithExactBOMCRLFBytes"] = await guide.workspaceReadback()["draftHash"] as? String == AgentFiles.hash(initial)
            await inspect("markdown")
            let draft = initialText + "\r\n<!-- 任务标签页保存核对 -->\r\n", expected = Data([0xEF, 0xBB, 0xBF]) + Data(draft.utf8)
            await guide.checkTaskDocument(text: draft)
            control.presentAgentRecords(section: 4); checks["recordsTabKeepsIndependentCatalog"] = host.currentController === records
            control.presentTaskContext(section: 2); checks["contextTabKeepsIndependentController"] = host.currentController === context
            control.showTaskDocument(fixture.plain.path)
            guard let plain = host.currentController as? AgentRecordWindow else { throw PetError("文本文件未进入独立标签页") }
            checks["plainTextUsesActualConfigurationBytes"] = await plain.workspaceReadback()["draftHash"] as? String == AgentFiles.hash(plainBytes)
            control.showTaskDocument(fixture.duplicate.path)
            checks["sameFilenameInDifferentDirectoriesHasIndependentTab"] = host.currentController !== guide && host.rootController(.document(fixture.duplicate.path)) != nil
            control.showTaskDocument("docs/AGENT-READING.md")
            let reopened = await guide.workspaceReadback()
            checks["canonicalReopenRetainsExistingDraft"] = host.currentController === guide && reopened["draftHash"] as? String == AgentFiles.hash(expected) && host.checkState()["roots"] as? [String] == ["records", "context", "document:" + fixture.guide.path, "document:" + fixture.plain.path, "document:" + fixture.duplicate.path]
            control.showAgentTask(fixture.secondID); control.showTaskDocument(fixture.guide.path)
            guard let second = host.currentController as? AgentRecordWindow else { throw PetError("另一任务的文件未载入") }
            let secondState = await second.workspaceReadback()
            checks["anotherTaskStartsFromActualDisk"] = second !== guide && secondState["draftHash"] as? String == AgentFiles.hash(initial)
            control.showAgentTask(fixture.taskID)
            let returned = await guide.workspaceReadback()
            checks["taskSwitchRetainsDocumentAndUnsavedBytes"] = host.currentController === guide && returned["draftHash"] as? String == AgentFiles.hash(expected)
            host.checkHide(); control.showTaskDocument(fixture.guide.path)
            let unhidden = await guide.workspaceReadback()
            checks["hideAndReopenRetainsDraft"] = host.currentController === guide && unhidden["dirty"] as? Bool == true
            do { try control.requireTaskDeletionAllowed([fixture.taskID]); checks["unsavedDocumentBlocksTaskDeletion"] = false } catch { checks["unsavedDocumentBlocksTaskDeletion"] = true }
            await guide.checkTaskDocument(action: "save")
            let saved = await guide.workspaceReadback()
            checks["saveUsesExactReviewedBOMCRLFBytes"] = try files.readData(fixture.guide) == expected && saved["dirty"] as? Bool == false
            let changes = tasks.task(fixture.taskID)?.changes.filter { $0.path == fixture.guide.path } ?? []
            checks["saveRetainsActualBeforeAndAfterCheckpoint"] = changes.count == 1 && changes.first?.beforeHash == AgentFiles.hash(initial) && changes.first?.afterHash == AgentFiles.hash(expected)
            let conflictDraft = draft + "\r\n<!-- 未保存的后续修改 -->\r\n", external = expected + Data("\r\n<!-- 外部文件操作 -->\r\n".utf8)
            await guide.checkTaskDocument(text: conflictDraft); try files.writeData(external, to: fixture.guide); await guide.checkTaskDocument(action: "save")
            guard let comparison = host.currentController as? AgentFileConflictWindow else { throw PetError("文件比较未进入原标签页") }
            for _ in 0..<100 { if comparison.checkState["loading"] as? Bool == false { break }; await wait(0.05) }
            checks["conflictComparisonUsesActualDiskAndUnsavedDraft"] = comparison.checkState["diskHash"] as? String == AgentFiles.hash(external) && comparison.checkState["draftHash"] as? String == AgentFiles.hash(Data([0xEF, 0xBB, 0xBF]) + Data(conflictDraft.utf8)) && comparison.checkState["overwriteEnabled"] as? Bool == true
            await inspect("file-comparison")
            host.checkSelect(.context); host.checkSelect(.document(fixture.guide.path))
            checks["switchingTabsRetainsComparisonChild"] = host.currentController === comparison
            host.checkBack(); let compared = await guide.workspaceReadback()
            checks["comparisonBackKeepsDraftWithoutWriting"] = try host.currentController === guide && compared["dirty"] as? Bool == true && files.readData(fixture.guide) == external
            report["retainedConflictDraft"] = await guide.workspaceReadback()
            // Reset only this test's simulated external write after recording the preserved conflict. Confirmation clicks are covered separately in real UI acceptance.
            try files.writeData(expected, to: fixture.guide); await guide.checkTaskDocument(action: "save")
            checks["fixtureEndsWithSavedDocumentWithoutDiscardingDraft"] = await guide.workspaceReadback()["dirty"] as? Bool == false
            checks["siblingFilesRemainByteIdentical"] = try files.readData(fixture.plain) == plainBytes && files.readData(fixture.duplicate) == duplicateBytes
            control.showAgentTask(fixture.standaloneID); control.presentTaskContext(section: 0)
            checks["taskDetailsWorkWithoutWorkspace"] = (host.currentController as? AgentContextWindow)?.boundTaskID == fixture.standaloneID && host.currentController?.presentingWindow === control.window
            control.presentAgentRecords(section: 4); checks["recordsWorkWithoutWorkspace"] = host.currentController is AgentRecordWindow && host.currentController?.presentingWindow === control.window
            let standaloneHeader = control.gitWorkspaceReadback()
            checks["workspaceShowsActualTitleForTaskWithoutMessages"] = standaloneHeader["taskTitleVisible"] as? Bool == true && standaloneHeader["taskTitle"] as? String == tasks.task(fixture.standaloneID)?.title
            checks["modelRequestsRemainZero"] = attempts == 0 && tasks.tasks.allSatisfy { ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            checks["composerDraftsRemainIndependent"] = tasks.task(fixture.taskID)?.draft == "保留项目任务的输入草稿。" && tasks.task(fixture.secondID)?.draft == "保留另一任务的输入草稿。" && tasks.task(fixture.standaloneID)?.draft == "无工作区任务的原草稿。"
            let binary = Bundle.main.executableURL!
            report["appPID"] = getpid(); report["binaryHash"] = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            report["geometry"] = geometry; report["taskID"] = fixture.taskID; report["modelRequests"] = attempts
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 }; report["scope"] = "Native task pages, public document copies, exact file bytes and actual local command/checkpoints; no generated recap, model answer or request receipt. Destructive conflict confirmations are validated separately in the real UI."
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-workspace-report.json"))
        } catch { report["checks"] = checks; report["success"] = false; report["error"] = error.localizedDescription; try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("task-workspace-report.json")) }
    }
}
