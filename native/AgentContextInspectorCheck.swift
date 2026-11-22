import AppKit

@MainActor extension AppDelegate {
    private struct ContextInspectorFixture: Codable {
        var detailed: String
        var standalone: String
        var mainWindow: String?
        var childWindow: String?
        var receiptAnchor: String?
        var receiptOffset: Double?
        var recapScroll: Double?
    }

    func runContextInspectorCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "before"
        let fixtureURL = output.appendingPathComponent("context-fixture.json")
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0

        func find<T: NSView>(_ root: NSView, _ type: T.Type, _ matches: (T) -> Bool) -> T? {
            if let candidate = root as? T, matches(candidate), !candidate.isHiddenOrHasHiddenAncestor { return candidate }
            for view in root.subviews {
                if let candidate = find(view, type, matches) { return candidate }
            }
            return nil
        }
        func contextPage(_ owner: ControlWindow) throws -> AgentContextWindow {
            guard let page = owner.taskWorkspace.currentController as? AgentContextWindow else { throw PetError("任务详情没有进入工作区") }
            return page
        }
        func scrollView(_ page: AgentContextWindow) throws -> NSScrollView {
            guard let content = page.pageContentView, let scroll = find(content, NSScrollView.self, { $0.hasVerticalScroller }) else {
                throw PetError("任务详情滚动区不可用")
            }
            return scroll
        }
        func picture(_ owner: ControlWindow, _ name: String) throws {
            guard let host = owner.window, let content = host.contentView else { throw PetError("任务详情窗口不可用") }
            content.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw PetError("任务详情截图不可用") }
            bitmap.size = content.bounds.size; content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("任务详情截图编码失败") }
            try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
            report["size-" + name] = [content.bounds.width, content.bounds.height]
        }
        func selectSent(_ page: AgentContextWindow) throws {
            page.selectSection(0)
            guard let content = page.pageContentView, let picker = find(content, NSPopUpButton.self, { $0.accessibilityLabel() == "上下文来源" }),
                  let action = picker.action else { throw PetError("缺少上下文来源选择") }
            picker.selectItem(at: 1)
            guard NSApp.sendAction(action, to: picker.target, from: picker) else { throw PetError("无法切换到上次请求") }
        }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("任务详情验收只允许独立资料")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("任务详情验收禁止模型请求") }
            if stage == "before" || stage == "seed" {
                let project = output.appendingPathComponent("公开项目")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
                let readme = project.appendingPathComponent("README.md")
                try Data("# Public context fixture\n".utf8).write(to: readme)
                let detailed = tasks.create(title: "公开项目的上下文与回顾", workspace: project.path, mode: .ask, draft: "保留原输入 PUBLIC_CONTEXT")
                let standalone = tasks.create(title: "无工作区的问答", mode: .ask, workMode: .general, draft: "保留原输入 PUBLIC_EMPTY")
                let now = Date(timeIntervalSince1970: 1_776_123_456)
                let model = "public/models/" + String(repeating: "context-receipt-", count: 7) + "示例"
                let snapshot = AgentContextSnapshot(created: now, model: model, limit: 8192, outputReserve: 512,
                    parts: [.init(title: "系统指令", tokens: 480), .init(title: "消息", tokens: 3106), .init(title: "工具定义", tokens: 880)], loadedSkills: 0)
                tasks.update(detailed) { task in
                    let message = AgentMessage(role: "user", content: "核对公开 README。")
                    task.messages = [message]
                    task.artifacts = [readme.path]; task.sources = [readme.absoluteString]
                    task.contextSnapshot = snapshot
                    task.recap = .init(created: now, model: "public-recap", throughMessageID: message.id,
                        text: (1...40).map { "第 \($0) 行回顾。只包含公开目录和可核对的来源。" }.joined(separator: "\n"))
                    task.modelReceipts = (0..<30).map { index in
                        .init(created: now.addingTimeInterval(Double(index) * 90), purpose: index % 2 == 0 ? "conversation" : "recap",
                            requestedModel: index == 29 ? model : "public-model-\(index)",
                            returnedModel: index % 4 == 0 ? nil : "public-response-\(index)",
                            inputTokens: index % 5 == 0 ? nil : 981 + index, outputTokens: 51 + index,
                            finishReason: index == 29 ? "length" : "stop", duration: 1.8, completed: index != 29)
                    }
                    task.inputTokens = (task.modelReceipts ?? []).reduce(37) { $0 + ($1.inputTokens ?? 0) }
                    task.outputTokens = (task.modelReceipts ?? []).reduce(11) { $0 + ($1.outputTokens ?? 0) }
                }
                tasks.update(standalone) { $0.contextSnapshot = snapshot }
                control.showAgentTask(detailed); control.show(tab: "chat")
                guard let host = control.window else { throw PetError("任务主窗口不可用") }
                host.appearance = NSAppearance(named: .darkAqua)
                host.setContentSize(NSSize(width: 780, height: 540))
                control.presentTaskContext(section: 2)
                let page = try contextPage(control), scroll = try scrollView(page)
                host.contentView?.layoutSubtreeIfNeeded()
                try picture(control, "receipts-dark")
                AgentSettingsRecovery.restoreScroll(760, to: scroll)
                let current = scroll.contentView.bounds.minY
                page.selectSection(1); page.selectSection(2)
                report["tabScrollBefore"] = current; report["tabScrollAfter"] = scroll.contentView.bounds.minY
                checks["fixtureHasLongRequestHistory"] = current > 400
                let details = page.workspaceReadback()
                let text = details["text"] as? String ?? ""
                checks["nativeRequestHistoryOnOriginalTask"] = text.contains("public-response-27") &&
                    text.contains("响应未完成") && text.contains("未分模型的历史用量")
                var fixture = ContextInspectorFixture(detailed: detailed, standalone: standalone)
                if stage == "seed" {
                    report["requestGeometry"] = ["height": details["readingHeight"], "footer": details["footerVisible"],
                                                 "controlsFit": details["controlsFit"]].compactMapValues { $0 }
                    checks["receiptsKeepScrollOnSectionRoundTrip"] = abs(current - scroll.contentView.bounds.minY) < 1
                    checks["requestHistoryUsesFullReadingArea"] = details["footerVisible"] as? Bool == false &&
                        details["controlsFit"] as? Bool == true && (details["readingHeight"] as? Double ?? 0) > 340
                    let originalAnchor = details["anchor"] as? String
                    tasks.recordUsage(detailed, .init(created: now.addingTimeInterval(10_000), purpose: "conversation",
                        requestedModel: "public-appended", returnedModel: "public-appended", inputTokens: 73, outputTokens: 17,
                        finishReason: "stop", duration: 0.5, completed: true))
                    page.refresh()
                    let appended = page.workspaceReadback()
                    checks["newReceiptKeepsOriginalRecordAtSameOffset"] = originalAnchor?.isEmpty == false &&
                        appended["anchor"] as? String == originalAnchor && appended["anchorOffset"] as? Double == details["anchorOffset"] as? Double &&
                        (appended["scroll"] as? Double ?? 0) > current && (appended["text"] as? String)?.contains("public-appended") == true
                }
                try selectSent(page)
                host.appearance = NSAppearance(named: .aqua)
                host.setContentSize(NSSize(width: 1320, height: 800))
                try picture(control, "context-light")
                checks["fixtureShowsLastRequestAndActualTask"] = page.workspaceReadback()["source"] as? Int == 1 && page.boundTaskID == detailed
                if stage == "seed" {
                    let usage = page.workspaceReadback()
                    checks["contextShowsExactSavedBudgetAndFixedDisabledAction"] = (usage["text"] as? String)?.contains("4,466 / 8,192") == true &&
                        (usage["text"] as? String)?.contains("回复预留 512") == true && usage["actionEnabled"] as? Bool == false &&
                        usage["controlsFit"] as? Bool == true && usage["footerVisible"] as? Bool == true
                    host.appearance = NSAppearance(named: .darkAqua); host.setContentSize(NSSize(width: 780, height: 540))
                    page.selectSection(1); host.contentView?.layoutSubtreeIfNeeded()
                    AgentSettingsRecovery.restoreScroll(380, to: scroll)
                    let recap = page.workspaceReadback()
                    fixture.recapScroll = recap["scroll"] as? Double
                    checks["actualRecapAndArtifactsRemainReachable"] = (recap["text"] as? String)?.contains(readme.path) == true &&
                        (recap["text"] as? String)?.contains("第 40 行回顾") == true && (fixture.recapScroll ?? 0) > 280
                    page.selectSection(2)
                    AgentSettingsRecovery.restoreScroll(920, to: scroll)
                    fixture.receiptAnchor = page.workspaceReadback()["anchor"] as? String
                    fixture.receiptOffset = page.workspaceReadback()["anchorOffset"] as? Double
                    control.showAgentTask(standalone); control.showAgentTask(detailed)
                    checks["switchingTasksRetainsTheActualContextPage"] = try contextPage(control) === page &&
                        page.workspaceReadback()["anchor"] as? String == fixture.receiptAnchor
                    openTaskWindow(standalone, from: control)
                    guard let other = additionalTaskWindows.last, let otherHost = other.window else { throw PetError("独立问答窗口不可用") }
                    otherHost.setContentSize(NSSize(width: 1320, height: 800))
                    other.presentTaskContext(section: 1)
                    let otherPage = try contextPage(other), empty = otherPage.workspaceReadback()
                    checks["noWorkspaceShowsDisabledRecapWithCause"] = empty["actionEnabled"] as? Bool == false &&
                        (empty["state"] as? String)?.contains("尚无对话") == true && empty["controlsFit"] as? Bool == true
                    try selectSent(otherPage)
                    guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let otherID = other.workspaceSession?.id else {
                        throw PetError("窗口阅读位置未写入")
                    }
                    fixture.mainWindow = mainID; fixture.childWindow = otherID
                }
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(ContextInspectorFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows()
                guard await flushWorkspaceWindows(), let other = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.childWindow }) else {
                    throw PetError("原任务详情窗口未恢复")
                }
                checks["normalRestartUsesOriginalOwners"] = control.workspaceSession?.id == fixture.mainWindow &&
                    control.agentTaskID == fixture.detailed && other.agentTaskID == fixture.standalone
                checks["originalComposerDraftsRetained"] = tasks.task(fixture.detailed)?.draft == "保留原输入 PUBLIC_CONTEXT" &&
                    tasks.task(fixture.standalone)?.draft == "保留原输入 PUBLIC_EMPTY"
                if stage == "resume" {
                    let main = try contextPage(control), child = try contextPage(other)
                    let receipt = main.workspaceReadback(), savedSource = child.workspaceReadback()
                    checks["longReceiptRestoresInTheRightTaskAndWindow"] = receipt["section"] as? Int == 2 &&
                        receipt["anchor"] as? String == fixture.receiptAnchor && receipt["anchorOffset"] as? Double == fixture.receiptOffset &&
                        (receipt["scroll"] as? Double ?? 0) > 800 && receipt["controlsFit"] as? Bool == true
                    checks["otherWindowRestoresOwnSource"] = savedSource["section"] as? Int == 0 && savedSource["source"] as? Int == 1 &&
                        savedSource["mainWindow"] as? Bool == true
                    main.selectSection(1)
                    let read = main.workspaceReadback()
                    checks["otherSectionRetainsItsOwnReadOffset"] = abs((read["scroll"] as? Double ?? 0) - (fixture.recapScroll ?? 0)) < 1
                    main.selectSection(0)
                    checks["mainWindowRemembersItsLastContextSource"] = main.workspaceReadback()["source"] as? Int == 1
                    main.selectSection(2)
                    control.window?.appearance = NSAppearance(named: .darkAqua)
                    try picture(control, "restored-receipt")
                    control.taskWorkspace.checkClose(.context)
                    for _ in 0..<50 {
                        if control.taskWorkspace.recoveryController(taskID: fixture.detailed, root: .context) == nil { break }
                        await wait(0.02)
                    }
                    checks["explicitCloseRemovesOnlyTheOwnedTab"] = control.taskWorkspace.recoveryController(taskID: fixture.detailed, root: .context) == nil &&
                        other.taskWorkspace.recoveryController(taskID: fixture.standalone, root: .context) === child
                } else {
                    guard stage == "closed" else { throw PetError("未知的任务详情验收阶段") }
                    checks["closedDetailsDoNotReopen"] = !control.taskWorkspace.recoveryLayouts.contains { $0.tabs.contains { $0.root == "context" } }
                    control.presentTaskContext(section: 0)
                    let fresh = try contextPage(control)
                    checks["freshTabStartsAtDefaultAndRealHistoryRemains"] = fresh.workspaceReadback()["source"] as? Int == 0 &&
                        fresh.workspaceReadback()["scroll"] as? Double == 0 && tasks.task(fixture.detailed)?.modelReceipts?.count == 31
                }
                checks["finalCheckpointAfterOperations"] = await flushWorkspaceWindows()
            }
        } catch { report["error"] = error.localizedDescription }
        checks["zeroModelRequests"] = requests == 0
        report["checks"] = checks; report["modelRequests"] = requests; report["pid"] = getpid()
        if let binary = Bundle.main.executableURL {
            report["binarySHA256"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
        }
        report["success"] = report["error"] == nil && checks.values.allSatisfy { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: output.appendingPathComponent("context-inspector-" + stage + ".json"), options: .atomic)
        }
    }
}
