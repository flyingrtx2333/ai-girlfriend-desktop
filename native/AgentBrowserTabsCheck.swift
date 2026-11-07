import AppKit
import WebKit

@MainActor extension AppDelegate {
    func checkBrowserTabs(_ output: URL) async throws -> [String: Bool] {
        guard let tasks = agentStore else { throw PetError("任务未初始化") }
        let id = tasks.create(title: "真实网页多标签"), tools = AgentTools(store: tasks, taskID: id)
        defer { tasks.browser.close(id) }
        func call(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        func object(_ result: AgentToolResult) throws -> [String: Any] { let start = result.text.firstIndex(of: "{")!; return try JSONSerialization.jsonObject(with: Data(result.text[start...].utf8)) as! [String: Any] }
        func toggle(_ value: [String: Any]) throws -> AgentToolCall {
            guard let target = (value["elements"] as? [[String: Any]])?.first(where: { $0["name"] as? String == "棋盘背景" }) else { throw PetError("预览未显示棋盘背景控件") }
            return try call("browser_action", ["action": "click", "tab_id": value["tab_id"]!, "revision": value["revision"]!, "ref": target["ref"]!])
        }
        func names(_ definitions: [[String: Any]]) -> Set<String> { Set(definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }) }
        let core = names(AgentTools.definitions(mode: .agent, groups: [])), browserTools = names(AgentTools.definitions(mode: .agent, groups: ["browser"]))
        var checks = ["coreToolMenuIsSmallAndDiscoverable": core.contains("load_tools") && !core.contains("browser_open") && !core.contains("run_command"),
                      "browserToolsLoadWithoutUnrelatedCapabilities": Set(AgentBrowser.tools).isSubset(of: browserTools) && !browserTools.contains("write_file") && !browserTools.contains("run_command"),
                      "toolLoadingPreservesReadOnlyMode": !names(AgentTools.definitions(mode: .ask, groups: ["files", "terminal"])).contains("write_file") && !names(AgentTools.definitions(mode: .ask, groups: ["files", "terminal"])).contains("run_command")]
        _ = try await tools.execute(call("load_tools", ["groups": ["browser"]]))
        checks["loadedToolsPersistWithTask"] = AgentStore(directory: store.directory, legacy: []).task(id)?.toolGroups == ["browser"]
        let first = try object(await tools.execute(call("browser_open", ["url": "http://127.0.0.1:4178/"])))
        let firstID = first["tab_id"] as! String, oldAction = try toggle(first)
        let second = try object(await tools.execute(call("browser_open", ["url": "http://127.0.0.1:4178/?tab=second", "new_tab": true])))
        let secondID = second["tab_id"] as! String, browser = try tasks.browser.session(id)
        guard let firstPage = browser.pages.first(where: { $0.id == firstID }), let secondPage = browser.pages.first(where: { $0.id == secondID }) else { throw PetError("缺少真实标签页") }
        checks["multipleActualWebViewsAndStableIDs"] = firstID != secondID && browser.pages.count == 2 && firstPage.web !== secondPage.web
        checks["tabsShareOnlyTheirTaskWebsiteData"] = firstPage.web.configuration.websiteDataStore === secondPage.web.configuration.websiteDataStore && !firstPage.web.configuration.websiteDataStore.isPersistent
        do { _ = try tools.approvalReason(for: oldAction); checks["switchedTabRejectsPriorApprovalTarget"] = false } catch { checks["switchedTabRejectsPriorApprovalTarget"] = true }
        do { _ = try await tools.execute(oldAction); checks["switchedTabRejectsPriorExecution"] = false } catch { checks["switchedTabRejectsPriorExecution"] = true }
        _ = try await tools.execute(toggle(second))
        let leftState = try await firstPage.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String
        let rightState = try await secondPage.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String
        checks["actionAffectsOnlySelectedTab"] = leftState == "false" && rightState == "true"
        let tabOutput = output.appendingPathComponent("tabs", isDirectory: true); try FileManager.default.createDirectory(at: tabOutput, withIntermediateDirectories: true)
        checks.merge(await browser.checkLayout(tabOutput)) { _, value in value }
        _ = try await tools.execute(call("browser_tabs", ["action": "switch", "tab_id": firstID]))
        do { _ = try await tools.execute(oldAction); checks["switchingBackRequiresFreshRevision"] = false } catch { checks["switchingBackRequiresFreshRevision"] = true }
        let restored = try object(await tools.execute(call("browser_read", [:])))
        checks["switchPreservesActualURLAndDOMState"] = restored["tab_id"] as? String == firstID && restored["url"] as? String == "http://127.0.0.1:4178/" && leftState == "false" && firstPage.web.url?.absoluteString == "http://127.0.0.1:4178/"
        let other = tasks.create(title: "无权引用标签的另一个任务"), otherTools = AgentTools(store: tasks, taskID: other)
        do { _ = try await otherTools.execute(call("browser_tabs", ["action": "switch", "tab_id": firstID])); checks["tabIDsCannotCrossTaskBoundary"] = false } catch { checks["tabIDsCannotCrossTaskBoundary"] = true }
        _ = try await tools.execute(call("browser_tabs", ["action": "close", "tab_id": secondID]))
        let remaining = try object(await tools.execute(call("browser_tabs", ["action": "list"])))
        checks["closeBackgroundTabPreservesSelectedPage"] = (remaining["tabs"] as? [[String: Any]])?.count == 1 && remaining["selected_tab_id"] as? String == firstID
        do { _ = try await tools.execute(call("browser_read", ["tab_id": secondID])); checks["closedTabDoesNotFallBackToAnotherPage"] = false } catch { checks["closedTabDoesNotFallBackToAnotherPage"] = true }
        return checks
    }

    func checkBrowserFormModel(_ output: URL) async throws -> [String: Any] {
        guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
        let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent("settings.json").path) else { throw PetError("没有已保存的真实模型配置") }
        var p = PreferencesStore(directory: profile).preferences
        let configuredContext = p.contextLimit, configuredOutput = p.outputLimit
        p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
        let id = tasks.create(title: "真实模型 · 多标签与公开计算器表单"), tools = AgentTools(store: tasks, taskID: id)
        tasks.update(id) { $0.permission = .review }
        let schema = String(decoding: try JSONSerialization.data(withJSONObject: AgentTools.definitions(mode: .agent, groups: [])), as: UTF8.self)
        let overhead = AgentContext.estimate(try runtime.systemContext(tasks.task(id)!)) + AgentContext.estimate(schema) + 200
        let browserSchema = String(decoding: try JSONSerialization.data(withJSONObject: AgentTools.definitions(mode: .agent, groups: ["browser"])), as: UTF8.self)
        let browserStarter = overhead - AgentContext.estimate(schema) + AgentContext.estimate(browserSchema) + configuredOutput + 512
        try JSONSerialization.data(withJSONObject: ["configured": configuredContext, "baseStarter": overhead + configuredOutput + 512, "browserStarter": browserStarter], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("budget-report.json"))
        defer { if runtime.isRunning(id) || tasks.task(id)?.status == .waiting { runtime.cancel(id) }; tasks.browser.close(id) }
        runtime.submit("只使用内置浏览器完成以下流程，不用终端或其他网页工具，不修改项目。先打开 http://127.0.0.1:4178/，保留这个标签和棋盘背景的初始关闭状态。另开新标签访问 https://www.calculator.net/loan-calculator.html，在最上面的 Amortized Loan 表单实际填写 Loan Amount=1000、Loan Term=1 年且 0 月、Interest Rate=12；实际选择 Compound=Annually (APY)、Pay Back=Every Quarter，然后点击这个表单的 Calculate。读取网站实际返回的每季度还款、总付款和总利息。不要登录、保存到账户或提交其他表单。再列出两个标签并切回第一个，重新读取确认网址与棋盘背景仍未改变，最后切回计算结果标签并读取，最终只简短列出三个金额与两页网址，不复述过程。只是公开计算器的演示数字，不是申请借款；只允许这一计算查询。", taskID: id)
        let deadline = Date().addingTimeInterval(280); var approvals = 0, denied = 0, heldOff = true, formStates: [[String: Any]] = []
        while Date() < deadline, let task = tasks.task(id) {
            if task.status == .waiting, let pending = task.pendingCalls.first {
                var allowed = false
                if pending.name == "browser_open", let url = pending.object["url"] as? String { allowed = ["http://127.0.0.1:4178/", "https://www.calculator.net/loan-calculator.html"].contains(url) }
                if pending.name == "browser_action", let browser = tasks.browser.sessions[id], let url = browser.web.url, url.host == "www.calculator.net", url.path == "/loan-calculator.html",
                   ["fill", "select", "click"].contains(pending.object["action"] as? String ?? "") {
                    let reason = try tools.approvalReason(for: pending) ?? ""
                    if pending.object["action"] as? String == "click" { allowed = reason.contains("Calculate") && reason.contains("#monthlyfixedr") || reason.contains("\nAmortized Loan:") && reason.hasSuffix("#monthlyfixed") }
                    else { allowed = ["cloanamount", "cloanterm", "cloantermmonth", "cinterestrate", "ccompound", "cpayback"].contains { reason.contains("\n" + $0 + "\n") } }
                    if allowed, let values = try await browser.web.evaluateJavaScript("Object.fromEntries([...document.forms.calform.elements].filter(x=>x.name && x.type!=='hidden').map(x=>[x.name,x.value]))") as? [String: Any] {
                        formStates.append(values)
                        if pending.object["action"] as? String == "click", reason.contains("Calculate") {
                            heldOff = heldOff && (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cloanamount" && $0.value == "1000" } != true)
                        }
                    }
                }
                if allowed { approvals += 1 } else { denied += 1 }
                guard approvals <= 16 && denied <= 3 else { throw PetError("模型偏离允许的公开计算流程，已停止") }
                runtime.decide(taskID: id, callID: pending.id, decision: allowed ? "allow" : "deny")
            }
            if [.completed, .failed, .stopped].contains(task.status) { break }; await wait(0.1)
        }
        guard let task = tasks.task(id), let browser = tasks.browser.sessions[id] else { throw PetError("缺少模型浏览器结果") }
        let originals = browser.pages.filter { $0.web.url?.host == "127.0.0.1" }, results = browser.pages.filter { $0.web.url?.host == "www.calculator.net" }
        guard originals.count == 1, results.count == 1 else { throw PetError("模型未保留两个实际标签") }
        let original = originals[0], result = results[0]
        let untouched = try await original.web.evaluateJavaScript("document.getElementById('background').getAttribute('aria-pressed')") as? String
        let body = try await result.web.evaluateJavaScript("document.body.innerText") as? String ?? ""
        let query = URLComponents(url: result.web.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let actual = Dictionary(query.filter { ["cloanamount", "cloanterm", "cloantermmonth", "cinterestrate", "ccompound", "cpayback", "type"].contains($0.name) }.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        // Independent amortization calculation, outside the model and website.
        let rate = pow(1.12, 0.25) - 1, quarterly = 1000 * rate / (1 - pow(1 + rate, -4)), total = quarterly * 4, interest = total - 1000
        let amounts = [quarterly, total, interest].map { String(format: "%.2f", $0) }
        let normalized = body.replacingOccurrences(of: ",", with: ""), answer = task.summary.replacingOccurrences(of: ",", with: "")
        let successful = task.events.filter { $0.kind == "tool" && $0.status == "completed" }, descriptions = successful.filter { $0.title == "browser_action" }.map(\.detail)
        func number(_ value: String?) -> Double? { value.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) } }
        let numeric: [String: Double] = ["cloanamount": 1000, "cloanterm": 1, "cloantermmonth": 0, "cinterestrate": 12]
        let submitted = numeric.allSatisfy { number(actual[$0.key]) == $0.value } && actual["ccompound"] == "annually" && actual["cpayback"] == "quarter" && actual["type"] == "1"
        let checks = ["modelActuallyFilledAndSelectedPublicForm": descriptions.filter { $0.contains("\"fill\"") }.count >= 3 && descriptions.filter { $0.contains("\"select\"") }.count >= 2 && descriptions.contains { $0.contains("\"click\"") },
                      "serverReceivedExactlyRequestedFormValues": submitted,
                      "actualFieldAndChoiceStateChanged": formStates.first?["ccompound"] as? String == "monthly" && formStates.first?["cpayback"] as? String == "month" && formStates.last?["ccompound"] as? String == "annually" && formStates.last?["cpayback"] as? String == "quarter" && number(formStates.last?["cloanamount"] as? String) == 1000,
                      "actualServerResultsAgreeWithIndependentMath": amounts.allSatisfy { normalized.contains("$" + $0) },
                      "modelReportsActualResults": task.status == .completed && amounts.allSatisfy { answer.contains($0) },
                      "submitHeldUntilApproved": heldOff && approvals >= 8,
                      "usesSavedBudgetsAndLoadsOnlyBrowserTools": configuredContext == p.contextLimit && configuredOutput == p.outputLimit && task.toolGroups == ["browser"] && successful.contains { $0.title == "load_tools" },
                      "modelSwitchedRetainedTabs": successful.filter { $0.title == "browser_tabs" && $0.detail.contains("switch") }.count >= 2 && browser.web === result.web && untouched == "false" && original.web.url?.absoluteString == "http://127.0.0.1:4178/",
                      "modelRetainsBothActualSources": task.sources.contains("http://127.0.0.1:4178/") && task.sources.contains { $0.hasPrefix("https://www.calculator.net/loan-calculator.html?") }]
        let images = output.appendingPathComponent("form", isDirectory: true); try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        _ = await browser.checkLayout(images)
        try Data(body.utf8).write(to: output.appendingPathComponent("actual-calculator-result.txt"))
        return ["success": checks.values.allSatisfy { $0 }, "checks": checks, "model": p.model, "status": task.status.rawValue, "result": task.summary, "approvalCount": approvals, "deniedCount": denied, "actualQuery": actual, "independentAmounts": amounts, "preApprovalFormStates": formStates, "configuredContextLimit": configuredContext, "validationContextLimit": p.contextLimit, "minimumStarterBudget": overhead + configuredOutput + 512, "browserStarterBudget": browserStarter, "compactions": task.events.filter { $0.kind == "context" && $0.status == "completed" }.count, "inputTokens": task.inputTokens, "outputTokens": task.outputTokens, "events": task.events.map { ["title": $0.title, "status": $0.status, "detail": $0.detail] }]
    }
}
