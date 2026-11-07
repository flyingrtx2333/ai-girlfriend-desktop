import AppKit
import WebKit

@MainActor extension AppDelegate {
    func runAgentBrowserCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func progress(_ name: String) { try? Data(name.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        func object(_ result: AgentToolResult) throws -> [String: Any] {
            guard let start = result.text.firstIndex(of: "{"), let value = try JSONSerialization.jsonObject(with: Data(result.text[start...].utf8)) as? [String: Any] else { throw PetError("浏览器未返回页面记录") }; return value
        }
        func element(_ snapshot: [String: Any], named name: String) throws -> String {
            guard let item = (snapshot["elements"] as? [[String: Any]])?.first(where: { ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(name) && $0["disabled"] as? Bool != true }), let ref = item["ref"] as? String else { throw PetError("实际页面没有找到控件：" + name) }; return ref
        }
        do {
            ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
            defer { tasks.browser.closeAll() }
            let id = tasks.create(title: "真实原生浏览器验证"), tools = AgentTools(store: tasks, taskID: id)
            progress("public-documents")
            let opening = try call("browser_open", ["url": "https://docs.qoder.com/qoder/overview"])
            checks["openRequiresNetworkApproval"] = try tools.approvalReason(for: opening) != nil && tasks.browser.sessions.isEmpty
            let initial = try await tools.execute(opening)
            checks["actualRenderedPublicDocument"] = initial.text.contains("Qoder") && initial.sources == ["https://docs.qoder.com/qoder/overview"]
            try Data(initial.text.utf8).write(to: output.appendingPathComponent("public-page.txt"))
            let linkPage = try object(await tools.execute(call("browser_read", ["query": "Task management"])))
            let click = try call("browser_action", ["action": "click", "tab_id": linkPage["tab_id"]!, "revision": linkPage["revision"]!, "ref": element(linkPage, named: "Task management")])
            checks["clickApprovalNamesActualDestination"] = try tools.approvalReason(for: click)?.contains("task-management") == true
            tasks.update(id) { $0.permission = .automatic }
            checks["automaticModeUsesSelectedApprovalPolicy"] = try tools.approvalReason(for: click) == nil
            tasks.update(id) { $0.permission = .review }
            let navigated = try await tools.execute(click)
            checks["realPublicLinkNavigation"] = navigated.sources.contains { $0.contains("/qoder/task-management") }
            try Data(navigated.text.utf8).write(to: output.appendingPathComponent("public-navigation.txt"))
            do { _ = try await tools.execute(click); checks["stalePageRevisionRejected"] = false } catch { checks["stalePageRevisionRejected"] = true }
            let other = tasks.create(title: "独立浏览器任务")
            do { _ = try await AgentTools(store: tasks, taskID: other).execute(call("browser_read")); checks["taskCannotReadOtherBrowser"] = false } catch { checks["taskCannotReadOtherBrowser"] = true }
            let first = try tasks.browser.session(id), second = try tasks.browser.show(taskID: other, title: "独立浏览器任务")
            let firstCookies = await first.web.configuration.websiteDataStore.httpCookieStore.allCookies()
            let secondCookies = await second.web.configuration.websiteDataStore.httpCookieStore.allCookies()
            checks["ephemeralWebsiteDataSeparated"] = !first.web.configuration.websiteDataStore.isPersistent && !second.web.configuration.websiteDataStore.isPersistent && first.web.configuration.websiteDataStore !== second.web.configuration.websiteDataStore && secondCookies.isEmpty
            report["publicCookieCount"] = firstCookies.count
            tasks.browser.close(other)
            progress("actual-project-preview")
            _ = try await tools.execute(call("browser_open", ["url": "http://127.0.0.1:4178/"]))
            let before = try object(await tools.execute(call("browser_read", ["query": "棋盘背景"])))
            let toggle = try call("browser_action", ["action": "click", "tab_id": before["tab_id"]!, "revision": before["revision"]!, "ref": element(before, named: "棋盘背景")])
            let target = try tasks.browser.session(id)
            let pressedBefore = try await target.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String
            _ = try await tools.execute(toggle)
            let pressedAfter = try await target.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String
            checks["realDevelopmentPreviewActionChangesActualControl"] = pressedBefore == "false" && pressedAfter == "true"
            let current = try object(await tools.execute(call("browser_read", ["query": "棋盘背景"])))
            let changing = try call("browser_action", ["action": "click", "tab_id": current["tab_id"]!, "revision": current["revision"]!, "ref": element(current, named: "棋盘背景")])
            _ = try await target.web.evaluateJavaScript("document.getElementById('background').textContent = '页面已变化'")
            do { _ = try await tools.execute(changing); checks["changedDOMRejectedBeforeAction"] = false } catch { checks["changedDOMRejectedBeforeAction"] = true }
            checks["changedDOMDidNotTriggerAction"] = try await target.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String == "true"
            _ = try await tools.execute(call("browser_open", ["url": "http://127.0.0.1:4178/"]))
            let readOnly = try object(await tools.execute(call("browser_read", ["query": "棋盘背景"])))
            let readOnlyCall = try call("browser_action", ["action": "click", "tab_id": readOnly["tab_id"]!, "revision": readOnly["revision"]!, "ref": element(readOnly, named: "棋盘背景")])
            tasks.update(id) { $0.mode = .ask }
            do { _ = try tools.approvalReason(for: readOnlyCall); checks["askModeRejectsInteractiveApproval"] = false } catch { checks["askModeRejectsInteractiveApproval"] = true }
            do { _ = try await tools.execute(readOnlyCall); checks["askModeRejectsInteractiveExecution"] = false } catch { checks["askModeRejectsInteractiveExecution"] = true }
            tasks.update(id) { $0.mode = .agent }
            checks.merge(await target.checkLayout(output)) { _, value in value }
            control.show(tab: "chat"); checks.merge(await control.checkAgentBrowserEntry(output, taskID: id)) { _, value in value }
            let stopped = try object(await tools.execute(call("browser_read")))
            tools.cancel()
            do { _ = try await tools.execute(call("browser_action", ["action": "scroll", "tab_id": stopped["tab_id"]!, "revision": stopped["revision"]!])); checks["stopInvalidatesPageReferences"] = false } catch { checks["stopInvalidatesPageReferences"] = true }
            _ = try await tools.execute(call("browser_close"))
            do { _ = try await tools.execute(call("browser_read")); checks["closedBrowserCannotReusePage"] = false } catch { checks["closedBrowserCannotReusePage"] = true }
            for invalid in ["file:///etc/passwd", "javascript:alert(1)", "https://user:password@example.com/", "data:text/html,hello"] {
                if (try? AgentBrowser.url(invalid)) != nil { throw PetError("不应支持的网址：" + invalid) }
            }
            checks["onlyHTTPWithoutEmbeddedCredentials"] = true
            if CommandLine.arguments.contains("--browser-extended") {
                progress("native-multiple-tabs"); checks.merge(try await checkBrowserTabs(output)) { _, value in value }
                if CommandLine.arguments.contains("--live-agent") {
                    progress("live-public-form"); report["live"] = try await checkBrowserFormModel(output)
                    checks["realModelBrowserFormWorkflow"] = (report["live"] as? [String: Any])?["success"] as? Bool == true
                }
            } else if CommandLine.arguments.contains("--live-agent") {
                progress("live-model")
                report["live"] = try await checkBrowserModel(output)
                checks["realModelBrowserWorkflow"] = (report["live"] as? [String: Any])?["success"] as? Bool == true
            }
        } catch { report["error"] = error.localizedDescription; checks["browserWorkflow"] = false }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["liveModelVerified"] = (report["live"] as? [String: Any])?["success"] as? Bool == true
        report["scope"] = "Actual native WKWebView, live public Qoder documentation and this repository's running Vite preview. Real navigation and UI state, task isolation, revision/DOM conflicts, mode limits, stop and close. No synthetic website or model responses. Model acceptance only when explicitly present in live section; no microphone or TTS."
        if CommandLine.arguments.contains("--browser-extended") { report["scope"] = "Actual native WKWebView tabs and running project preview, including state retention, active-tab binding, closed references, same-task website data and task isolation. Live section uses the configured real model to fill/select/submit Calculator.net's public loan form with artificial non-personal numbers, compare independent amortization math, and switch retained tabs. Real website, real server results; no fake model/site responses, accounts, microphone or TTS." }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("browser-report.json"), options: .atomic)
    }
    private func checkBrowserModel(_ output: URL) async throws -> [String: Any] {
        guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
        let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
        guard FileManager.default.fileExists(atPath: production.appendingPathComponent("settings.json").path) else { throw PetError("没有已保存的真实模型配置，未执行模型验收") }
        var p = PreferencesStore(directory: production).preferences
        p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.contextTokens = max(32_768, p.contextTokens); p.replyTokens = 2048; store.preferences = p
        let id = tasks.create(title: "真实模型浏览器任务")
        tasks.update(id) { $0.permission = .review }
        defer { if runtime.isRunning(id) || tasks.task(id)?.status == .waiting { runtime.cancel(id) } }
        runtime.submit("用内置浏览器打开 http://127.0.0.1:4178/ ，读取实际页面，点击一次「棋盘背景」，再读取页面核对，并报告实际操作与网址。不使用终端、fetch_url 或 web_search，不修改项目文件，不做其他操作。", taskID: id)
        let deadline = Date().addingTimeInterval(180); var approvals = 0, protected = true
        while Date() < deadline, let task = tasks.task(id) {
            if task.status == .waiting, let pending = task.pendingCalls.first {
                let allowed = pending.name == "browser_open" && pending.object["url"] as? String == "http://127.0.0.1:4178/" || pending.name == "browser_action" && pending.object["action"] as? String == "click" && task.approvals.last?.reason.contains("棋盘背景") == true
                if allowed {
                    if pending.name == "browser_action", let session = tasks.browser.sessions[id] {
                        let before = try await session.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String
                        protected = protected && before == "false"
                    }
                    approvals += 1
                }
                runtime.decide(taskID: id, callID: pending.id, decision: allowed ? "allow" : "deny")
            }
            if [.completed, .failed, .stopped].contains(task.status) { break }; await wait(0.1)
        }
        guard let task = tasks.task(id), let browser = tasks.browser.sessions[id] else { throw PetError("模型没有打开任务浏览器") }
        let pressed = try await browser.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String
        let calls = Set(task.events.filter { $0.kind == "tool" && $0.status == "completed" }.map(\.title))
        let successfulActions = task.events.filter { $0.kind == "tool" && $0.title == "browser_action" && $0.status == "completed" }.count
        let checks = ["modelUsesRealBrowserTools": calls.isSuperset(of: ["browser_open", "browser_action"]), "actualControlChangedAfterApproval": protected && pressed == "true" && (2...6).contains(approvals) && successfulActions == 1, "completedWithActualSource": task.status == .completed && task.sources.contains("http://127.0.0.1:4178/")]
        return ["success": checks.values.allSatisfy { $0 }, "checks": checks, "model": p.model, "status": task.status.rawValue, "result": task.summary, "approvalCount": approvals, "allPreApprovalStatesOff": protected, "finalPressed": pressed ?? "missing", "successfulActions": successfulActions, "events": task.events.map { ["title": $0.title, "status": $0.status, "detail": $0.detail] }]
    }
}

@MainActor private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] { await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } } }
}

@MainActor extension AgentBrowserWindow {
    func checkLayout(_ output: URL) async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for (name, size) in [("normal", NSSize(width: 1000, height: 720)), ("narrow", NSSize(width: 620, height: 440))] {
            window?.setContentSize(size); window?.contentView?.layoutSubtreeIfNeeded()
            checks["nativeBrowserLayout-" + name] = web.bounds.width > 560 && web.bounds.height > 300 && !web.hasAmbiguousLayout
            if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("browser-" + name + ".png")) }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                web.takeSnapshot(with: nil) { image, _ in
                    if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) { try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("browser-page-" + name + ".png")) }
                    continuation.resume()
                }
            }
        }
        return checks
    }
}
