import AppKit

@MainActor extension AppDelegate {
    func prepareAttentionPageUI(_ output: URL, childQuestion: String? = nil, extraQuestions: Int = 0) async throws -> String {
        ensureAgent()
        guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("需要我验收未初始化") }
        let project = output.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("# 需要我页面验收\n仅在本轮临时目录核对公开内容。\n".utf8).write(to: project.appendingPathComponent("README.md"))
        let id = tasks.create(title: "需要我页面验收", workspace: project.path)
        guard runtime.submit("核对收件箱、答复草稿和返回任务。", taskID: id, startImmediately: false) else { throw PetError("原生用户输入未保存") }
        tasks.update(id) { $0.draft = "原任务尚未发送的草稿。" }
        control.showAgentTask(id)
        try await prepareAttentionCheck(output, childQuestion: childQuestion, extraQuestions: extraQuestions)
        return id
    }

    func runAttentionPageCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], blockedAttempts = 0
        func settled() async throws {
            let deadline = Date().addingTimeInterval(20)
            while agentStore?.attention.loading == true || agentStore?.tasks.contains(where: { agentRuntime?.isBusy($0.id) == true }) == true {
                guard Date() < deadline else { throw PetError("实际请求仍未完成") }; await wait(0.05)
            }
        }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少任务存储") }
            runtime.modelRequestCheck = { blockedAttempts += 1; throw PetError("需要我页面验收禁止模型传输") }
            let id = try await prepareAttentionPageUI(output)
            try await settled(); control.showAttentionPage(); try await settled()
            guard let page = control.attentionPageController else { throw PetError("收件箱未进入主窗口") }
            checks.merge(try page.checkPageControls()) { _, new in new }
            let navigation = try control.checkAttentionNavigation()
            checks.merge(navigation["checks"] as? [String: Bool] ?? [:]) { _, new in new }; report["frames"] = navigation["frames"]
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("attention-fixtures.json"))) as! [String: Any]
            guard let ids = fixture["tasks"] as? [String: String], let child = ids["childQuestion"], let parent = ids["question"] else { throw PetError("缺少原生请求编号") }
            guard let window = control.window, let content = window.contentView else { throw PetError("收件箱缺少实际窗口") }
            let originalSize = content.bounds.size, originalAppearance = window.appearance
            func resize(_ size: NSSize, _ appearance: NSAppearance.Name) {
                window.appearance = NSAppearance(named: appearance); window.setContentSize(size); content.layoutSubtreeIfNeeded()
            }
            func render(_ name: String) throws {
                content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw PetError("无法绘制收件箱窗口") }
                bitmap.size = content.bounds.size; content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PetError("收件箱窗口图像无法编码") }
                try data.write(to: output.appendingPathComponent("attention-" + name + ".png"), options: .atomic)
            }
            resize(NSSize(width: 1320, height: 800), .aqua)
            let wide = page.checkPageGeometry()
            checks["wideWindowKeepsSideBySidePanes"] = content.bounds.size == NSSize(width: 1320, height: 800) &&
                wide["mode"] as? String == "split" && (wide["bodyWidth"] as? CGFloat ?? 0) >= 500 &&
                (wide["checks"] as? [String: Bool])?.values.allSatisfy { $0 } == true
            try render("wide")
            resize(NSSize(width: 780, height: 540), .darkAqua)
            checks["narrowWindowHasActualMinimumSize"] = content.bounds.size == NSSize(width: 780, height: 540)
            let reading = try page.checkCompactReading(capture: render)
            checks.merge(reading) { _, new in new }
            checks["minimumWindowDetailOpensAgain"] = page.checkOpenReading()
            let minimum = page.checkPageGeometry()
            resize(NSSize(width: 800, height: 550), .darkAqua)
            let comparison = page.checkPageGeometry()
            checks["sameSizeComparisonGivesBodyOverFiveHundredPoints"] = content.bounds.size == NSSize(width: 800, height: 550) &&
                comparison["mode"] as? String == "detail" && (comparison["bodyWidth"] as? CGFloat ?? 0) >= 510
            report["readingFrames"] = ["wide": wide, "minimum": minimum, "comparison": comparison]
            window.appearance = originalAppearance; window.setContentSize(originalSize); content.layoutSubtreeIfNeeded()
            openTaskWindow(id, from: control)
            guard let other = additionalTaskWindows.last else { throw PetError("第二个任务窗口未打开") }
            other.showAttentionPage()
            guard let otherPage = other.attentionPageController else { throw PetError("第二个收件箱未进入主窗口") }
            checks["eachTaskWindowOwnsItsInbox"] = otherPage !== page && otherPage.presentingWindow === other.window && page.presentingWindow === control.window
            checks["secondWindowLoadsSharedReplyWithoutMovingFirstView"] = otherPage.checkChooseTask(child) && otherPage.checkState()["reply"] as? String == "公开的需要我答复草稿。" && page.isVisible
            other.window?.performClose(nil)
            for _ in 0..<100 { if other.window?.isVisible != true { break }; await wait(0.01) }
            checks["closingOtherWindowKeepsMainInboxAndDraft"] = other.window?.isVisible != true && page.isVisible && tasks.task(id)?.draft == "原任务尚未发送的草稿。"
            control.showAttentionPage()
            resize(NSSize(width: 780, height: 540), .darkAqua)
            for (key, decision) in [("allow", "allow"), ("deny", "deny"), ("childQuestion", "公开的原生答复")] {
                guard let taskID = ids[key], page.checkChooseTask(taskID, decision: decision) else { throw PetError("实际请求未进入对应操作：" + key) }
                try await settled()
                let expected = decision == "allow" || decision == "deny" ? decision : "answer:" + decision
                checks["actualDecisionPreserved-" + key] = tasks.task(taskID)?.approvals.last?.decision == expected
                checks["completedDetailReturnsToList-" + key] = page.checkState()["reading"] as? Bool == false
            }
            window.appearance = originalAppearance; window.setContentSize(originalSize); content.layoutSubtreeIfNeeded()
            let project = try AgentFiles(workspace: output.appendingPathComponent("project").path)
            let source = try project.readData(project.resolve("README.md"), maximum: 100_000)
            checks["approvedWriteHasActualExpectedBytes"] = try project.readData(project.resolve("allowed.txt"), maximum: 100_000) == Data((AgentFiles.hash(source) + "\n").utf8)
            checks["refusedWriteDoesNotCreateFile"] = !FileManager.default.fileExists(atPath: project.root.appendingPathComponent("denied.txt").path)
            checks["inboxNavigationSelectionSurvivesRuntimeChanges"] = control.checkAttentionNavigationSelection()
            guard page.checkChooseTask(parent) else { throw PetError("缺少仍待答复的父请求") }
            page.checkSetReply("保留父任务的公开答复草稿。")
            guard page.prepareToClose() else { throw PetError("答复草稿未保存") }
            checks.merge(await control.checkAttentionSaveFailure()) { _, new in new }
            guard let record = tasks.task(parent), let item = AgentAttentionItem.project(record).first(where: { $0.kind == .question && !$0.handled }) else { throw PetError("问题原件丢失") }
            checks["savedReplyReopensFromOriginalProfile"] = try AgentAttention(store: tasks).replyDraft(item) == "保留父任务的公开答复草稿。"
            control.showAttentionPage(); guard page.checkChooseTask(parent) else { throw PetError("焦点检查需要可见的原问题") }
            checks["QuestionInteractionRefreshKeepsReplyFocusTextAndSelection"] = await page.checkQuestionInteractionFocus()
            checks["nativeRequestsContainNoInventedAssistantOrCompletedReceipt"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { !$0.messages.contains { $0.role == "assistant" } && !($0.modelReceipts ?? []).contains { $0.completed } }
            checks["originalChatDraftSurvivesAllInboxOperations"] = tasks.task(id)?.draft == "原任务尚未发送的草稿。"
            report["success"] = checks.count >= 30 && checks.values.allSatisfy { $0 }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        report["checks"] = checks; report["blockedModelAttempts"] = blockedAttempts; report["modelTransmissions"] = 0; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("attention-page-report.json"))
    }
}
