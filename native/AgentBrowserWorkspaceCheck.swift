import AppKit

@MainActor extension AppDelegate {
    struct BrowserWorkspaceFixture { let taskID: String, otherID: String, url: URL }
    func prepareBrowserWorkspaceUI(_ output: URL) async throws -> BrowserWorkspaceFixture {
        guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("浏览器工作区验收不调用模型") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("browser-input.json"))) as? [String: String]
        guard let value = input?["url"], let url = URL(string: value), url.host == "127.0.0.1" else { throw PetError("缺少实际项目预览地址") }
        let id = tasks.create(title: "浏览器工作区", workspace: output.appendingPathComponent("workspace").path), other = tasks.create(title: "另一个浏览器任务", mode: .ask)
        tasks.update(id) { $0.draft = "保留浏览器任务输入。" }; tasks.update(other) { $0.draft = "保留另一浏览器任务输入。" }
        let data = ["taskID": id, "otherID": other, "url": url.absoluteString]
        try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("browser-workspace-fixtures.json"))
        control.showAgentTask(id); control.show(tab: "chat")
        let browser = try tasks.browser.show(taskID: id, title: "浏览器工作区"); _ = try await browser.open(url); try await waitForBrowserProjectPreview(browser)
        return BrowserWorkspaceFixture(taskID: id, otherID: other, url: url)
    }
    func reopenBrowserWorkspaceUI(_ output: URL) async throws {
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("browser-workspace-fixtures.json"))) as? [String: String]
        guard let data, let id = data["taskID"], let value = data["url"], let url = URL(string: value), let task = agentStore?.task(id) else { throw PetError("原浏览器验收任务不存在") }
        control.showAgentTask(id); control.show(tab: "chat")
        let browser = try agentStore!.browser.show(taskID: id, title: task.title); _ = try await browser.open(url); try await waitForBrowserProjectPreview(browser)
    }
    func runBrowserWorkspaceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        func object(_ result: AgentToolResult) throws -> [String: Any] {
            guard let start = result.text.firstIndex(of: "{") else { throw PetError("没有浏览器记录") }
            return try JSONSerialization.jsonObject(with: Data(result.text[start...].utf8)) as! [String: Any]
        }
        func toggle(_ value: [String: Any]) throws -> AgentToolCall {
            guard let item = (value["elements"] as? [[String: Any]])?.first(where: { $0["name"] as? String == "棋盘背景" }) else { throw PetError("真实项目缺少背景控件") }
            return try call("browser_action", ["action": "click", "tab_id": value["tab_id"]!, "revision": value["revision"]!, "ref": item["ref"]!])
        }
        do {
            let executable = Bundle.main.executableURL!; report["appPID"] = getpid(); report["binaryHash"] = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("浏览器工作区验收禁止模型请求") }
            let f = try await prepareBrowserWorkspaceUI(output), host = control.taskWorkspace, browser = try tasks.browser.session(f.taskID), tools = AgentTools(store: tasks, taskID: f.taskID)
            checks["browserUsesTaskRootAndNoFloatingWindow"] = host.selectedRoot == .browser && host.currentController === browser && browser.window?.isVisible == false
            let originalWeb = browser.web
            for (appearance, theme) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                control.window?.appearance = NSAppearance(named: theme)
                for (kind, size) in [("split", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                    control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); browser.pageDidLayout(); await wait(0.05)
                    let state = browser.workspaceReadback(); report[appearance + "-" + kind] = state
                    for (name, pass) in state["checks"] as? [String: Bool] ?? [:] { checks[appearance + "-" + kind + "-" + name] = pass }
                }
            }
            control.window?.setContentSize(NSSize(width: 1200, height: 774)); control.window?.contentView?.layoutSubtreeIfNeeded()
            let before = try object(await tools.execute(call("browser_read", ["query": "棋盘背景"]))), action = try toggle(before), firstPageID = before["tab_id"] as! String
            checks["interactiveActionKeepsOriginalApproval"] = try tools.approvalReason(for: action) != nil
            _ = try await tools.execute(action)
            checks["actualProjectControlChanged"] = try await browser.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String == "true"
            _ = try await tools.execute(call("browser_open", ["url": f.url.absoluteString + "?tab=second", "new_tab": true])); try await waitForBrowserProjectPreview(browser)
            let secondWeb = browser.web
            checks["internalTabsShareOnlyTaskWebsiteData"] = browser.pages.count == 2 && secondWeb !== originalWeb && secondWeb.configuration.websiteDataStore === originalWeb.configuration.websiteDataStore && !secondWeb.configuration.websiteDataStore.isPersistent
            do { _ = try await tools.execute(action); checks["oldTabApprovalCannotRunAfterSwitch"] = false } catch { checks["oldTabApprovalCannotRunAfterSwitch"] = true }
            _ = try browser.manageTabs(["action": "switch", "tab_id": firstPageID])
            let retainedControl = try await browser.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String
            checks["internalTabReturnKeepsActualDOM"] = browser.web === originalWeb && retainedControl == "true"
            control.showAgentTask(f.otherID)
            let other = try tasks.browser.show(taskID: f.otherID, title: "另一个浏览器任务"); _ = try await other.open(f.url); try await waitForBrowserProjectPreview(other)
            checks["askAndNoWorkspaceCanOpenBrowser"] = host.currentController === other && tasks.task(f.otherID)?.workspace == nil && tasks.task(f.otherID)?.mode == .ask
            checks["taskWebsiteDataIsIsolated"] = other.web.configuration.websiteDataStore !== originalWeb.configuration.websiteDataStore && !other.web.configuration.websiteDataStore.isPersistent
            let otherTools = AgentTools(store: tasks, taskID: f.otherID), readOnly = try object(await otherTools.execute(call("browser_read", ["query": "棋盘背景"]))), blocked = try toggle(readOnly)
            do { _ = try otherTools.approvalReason(for: blocked); checks["askStillRejectsWebInteractionApproval"] = false } catch { checks["askStillRejectsWebInteractionApproval"] = true }
            do { _ = try await otherTools.execute(blocked); checks["askStillRejectsWebInteractionExecution"] = false } catch { checks["askStillRejectsWebInteractionExecution"] = true }
            control.showAgentTask(f.taskID)
            checks["taskReturnRetainsSameBrowserAndPages"] = host.currentController === browser && browser.web === originalWeb && browser.pages.count == 2 && tasks.task(f.otherID)?.draft == "保留另一浏览器任务输入。"
            await browser.checkWorkspace("separate")
            checks["explicitNewWindowMovesSameWebViewAndSession"] = browser.settingsHostWindow == nil && browser.window?.isVisible == true && browser.web === originalWeb && browser.web.window === browser.window && host.rootController(.browser) == nil && tasks.browser.sessions[f.taskID] === browser
            await browser.checkWorkspace("separate")
            checks["returnToTaskRehostsSameWebView"] = browser.settingsHostWindow === control.window && browser.web === originalWeb && host.currentController === browser && browser.window?.isVisible == false
            control.showTaskDocument(output.appendingPathComponent("workspace/README.md").path); host.checkSelect(.browser)
            checks["fileTabRoundTripPreservesBrowserDOMAndOwner"] = host.currentController === browser && browser.web === originalWeb && browser.pages.count == 2
            let loading = Task { try await browser.open(f.url, newTab: true) }; await wait(0.01)
            let wasLoading = browser.workspaceReadback()["busy"] as? Bool == true
            control.showAgentTask(f.otherID)
            checks["backgroundPageLoadDoesNotLockTaskNavigation"] = wasLoading && host.taskID == f.otherID
            _ = try await loading.value; control.showAgentTask(f.taskID)
            let third = browser.pages.last!.id; _ = try browser.manageTabs(["action": "close", "tab_id": third]); _ = try browser.manageTabs(["action": "switch", "tab_id": firstPageID])
            let capturing = Task { try await browser.screenshot() }; await wait(0.01); control.showAgentTask(f.otherID)
            checks["actualCapturePinsTheOriginalTaskUntilItFinishes"] = host.taskID == f.taskID && host.currentController === browser
            let shot = try await capturing.value; try shot.png().write(to: output.appendingPathComponent("actual-task-browser.png"))
            checks["realCaptureKeepsURLTabAndViewport"] = shot.source.url == f.url.absoluteString && shot.source.tabID == firstPageID && shot.source.viewportWidth > 430 && shot.source.method == "own-window"
            await browser.checkWorkspace("annotate")
            guard let annotation = browser.checkAnnotation else { throw PetError("标注未创建") }
            checks["annotationUsesChildPageWithoutFloatingWindow"] = host.currentController === annotation && annotation.settingsHostWindow === control.window && annotation.window?.isVisible == false
            await annotation.checkWorkspace(note: "核对实际网页中的背景控件。", mark: true)
            let markState = annotation.workspaceReadback(); report["annotationDraft"] = markState
            checks["actualAnnotationKeepsCapturedSourceAndDraft"] = markState["marks"] as? Int == 1 && markState["note"] as? String == "核对实际网页中的背景控件。" && markState["sourceTab"] as? String == firstPageID && browser.workspaceHasUnsavedChanges
            do { try tasks.setArchived([f.taskID], archived: true); checks["archiveCannotDiscardAnnotationDraft"] = false } catch { checks["archiveCannotDiscardAnnotationDraft"] = tasks.task(f.taskID)?.archived == false && error.localizedDescription.contains("标注") }
            do { _ = try tasks.prepareDeletion([f.taskID], workspaceIDs: []); checks["deleteCannotDiscardAnnotationDraft"] = false } catch { checks["deleteCannotDiscardAnnotationDraft"] = tasks.task(f.taskID) != nil && error.localizedDescription.contains("标注") }
            do { _ = try await tools.execute(call("browser_close")); checks["modelCannotCloseUnsavedAnnotation"] = false } catch { checks["modelCannotCloseUnsavedAnnotation"] = tasks.browser.sessions[f.taskID] === browser && error.localizedDescription.contains("标注") }
            control.showAgentTask(f.otherID); control.showAgentTask(f.taskID)
            checks["taskRoundTripRetainsAnnotationDraft"] = host.currentController === annotation && annotation.workspaceReadback()["note"] as? String == "核对实际网页中的背景控件。"
            do { _ = try await browser.screenshot(); checks["captureCannotReplaceVisibleAnnotation"] = false } catch { checks["captureCannotReplaceVisibleAnnotation"] = host.currentController === annotation && annotation.hasPendingChanges }
            await annotation.checkWorkspace(submit: true)
            guard let attached = tasks.task(f.taskID)?.attachments?.last else { throw PetError("实际标注未写入任务草稿") }
            checks["annotationAddsActualImageAndTextToOriginalUnsentTask"] = tasks.task(f.taskID)?.draft == "保留浏览器任务输入。\n核对实际网页中的背景控件。" && tasks.task(f.taskID)?.draftAttachmentIDs == [attached.id] && attached.browserCapture?.annotations == 1 && attached.browserCapture?.url == f.url.absoluteString && tasks.task(f.taskID)?.messages.isEmpty == true
            let source = try AgentAttachments.source(store: tasks, taskID: f.taskID, id: attached.id)
            checks["attachmentMatchesActualStoredBytes"] = try AgentFiles.hash(Data(contentsOf: source)) == attached.sha256
            checks["submittedAnnotationReturnsToSameBrowser"] = annotation.workspaceIsClosed && host.currentController === browser && !browser.workspaceHasUnsavedChanges && browser.web === originalWeb
            checks["newWindowIsEnabledAfterAnnotationCapture"] = browser.workspaceReadback()["newWindowEnabled"] as? Bool == true
            let stale = try object(await tools.execute(call("browser_read", ["query": "棋盘背景"]))), staleAction = try toggle(stale)
            tasks.browser.close(f.taskID)
            checks["closeReleasesSessionAndTaskRoot"] = tasks.browser.sessions[f.taskID] == nil && browser.workspaceIsClosed && host.rootController(.browser) == nil && originalWeb.superview == nil
            let fresh = try tasks.browser.show(taskID: f.taskID, title: "浏览器工作区")
            checks["reopenCreatesFreshWebsiteDataAndController"] = fresh !== browser && fresh.web.configuration.websiteDataStore !== originalWeb.configuration.websiteDataStore && host.currentController === fresh
            do { _ = try await tools.execute(staleAction); checks["closedSessionReferencesStayInvalid"] = false } catch { checks["closedSessionReferencesStayInvalid"] = true }
            checks["noModelRequestsOrFabricatedMessages"] = requests == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { $0.messages.isEmpty && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["attachment"] = ["path": source.path, "sha256": attached.sha256, "id": attached.id]; report["fixture"] = ["taskID": f.taskID, "otherID": f.otherID, "url": f.url.absoluteString]
            host.finish(); tasks.browser.closeAll()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }; report["modelRequests"] = requests
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("browser-workspace-report.json"))
    }
}
