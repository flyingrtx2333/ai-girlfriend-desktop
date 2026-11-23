import AppKit
import WebKit

@MainActor extension AppDelegate {
    func runBrowserAuthRecoveryCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "--browser-auth-recovery"), arguments.indices.contains(flag + 1),
                  let base = URL(string: arguments[flag + 1]), base.scheme == "http", base.host == "127.0.0.1", base.port != nil,
                  let executable = Bundle.main.executableURL else { throw PetError("缺少库存登录样例地址") }
            report["binaryHash"] = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少任务工作台") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("浏览器登录验收禁止模型请求") }
            let task = tasks.create(title: "库存登录验收", mode: .ask, workMode: .general)
            let other = tasks.create(title: "隔离的库存任务", mode: .ask, workMode: .general)
            defer { tasks.browser.close(other); tasks.browser.close(task) }
            let stock = base.appendingPathComponent("stock/417"), order = base.appendingPathComponent("orders/417")
            let memo = "公开库存备注 · B-17", password = "WarehouseSample_417_demo"

            func waitFor(_ label: String, _ condition: () -> Bool) async throws {
                for _ in 0..<100 {
                    if condition() { return }
                    await wait(0.05)
                }
                throw PetError("未达到网页状态：" + label)
            }
            func signIn(_ browser: AgentBrowserWindow, approve: Bool) async throws {
                let web = browser.web
                guard web.url?.path == "/sign-in", web.url?.host == "127.0.0.1", let owner = browser.presentingWindow else {
                    throw PetError("未找到本机登录页")
                }
                owner.makeKeyAndOrderFront(nil)
                _ = try await web.callAsyncJavaScript("document.getElementById('username').value='public-warehouse'; document.getElementById('password').value=value;",
                                                     arguments: ["value": password], in: nil, contentWorld: .page)
                let request = Task { try await web.evaluateJavaScript("document.querySelector('form').requestSubmit()") }
                try await waitFor("登录确认") { owner.agentDialog is AgentConfirmation }
                guard let dialog = owner.agentDialog as? AgentConfirmation else { throw PetError("登录确认已关闭") }
                if approve { dialog.buttons.first?.performClick(nil) } else { dialog.cancel() }
                _ = try? await request.value
                try await waitFor(approve ? "库存工作台" : "登录页") { web.url?.path == (approve ? "/account" : "/sign-in") && !web.isLoading }
            }
            func action(_ title: String, in browser: AgentBrowserWindow) throws -> NSButton {
                func find(_ view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == title, !button.isHiddenOrHasHiddenAncestor { return button }
                    return view.subviews.lazy.compactMap(find).first
                }
                guard let root = browser.pageContentView, let button = find(root), button.isEnabled else { throw PetError("找不到网页恢复操作：" + title) }
                return button
            }
            func decoded(_ browser: AgentBrowserWindow) async throws -> AgentBrowserRecoveryState {
                try await AgentBrowserRecoveryState.decode(browser.captureWorkspaceRecovery())
            }

            control.showAgentTask(task); control.show(tab: "chat")
            let original = try tasks.browser.show(taskID: task, title: "库存登录验收")
            _ = try await original.open(stock); try await signIn(original, approve: true)
            _ = try await original.open(stock)
            _ = try await original.web.callAsyncJavaScript("document.getElementById('memo').value=value;", arguments: ["value": memo], in: nil, contentWorld: .page)
            _ = try await original.open(order, newTab: true)
            let cookies = await original.web.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard let cookie = cookies.first(where: { $0.name == "warehouse_session" }) else { throw PetError("登录没有建立网站会话") }
            checks["tabsShareOneTaskSession"] = original.pages[0].web.configuration.websiteDataStore === original.web.configuration.websiteDataStore &&
                original.web.url == order && !original.web.configuration.websiteDataStore.isPersistent
            let savedPage = try await original.captureWorkspaceRecovery(), saved = try AgentBrowserRecoveryState.decode(savedPage)
            checks["savedTabsAndOrdinaryFormHaveExactTargets"] = saved.pages.map(\.url) == [stock.absoluteString, order.absoluteString] &&
                saved.selected == 1 && saved.pages[0].forms?.values.first?.value == memo
            let bytes = [savedPage.state] + saved.pages.compactMap(\.interaction)
            checks["passwordAndSessionAreAbsentFromSavedPages"] = [password, cookie.value].allSatisfy { secret in
                bytes.allSatisfy { $0.range(of: Data(secret.utf8)) == nil && $0.range(of: secret.data(using: .utf16LittleEndian)!) == nil }
            }

            tasks.browser.close(task)
            let reopened = try tasks.browser.restore(savedPage, taskID: task, title: "库存登录验收", present: { try $0.present() })
            try await waitFor("两个登录标签") {
                reopened.pages.count == 2 && reopened.pages.allSatisfy { $0.recoveryWaiting && $0.web.url?.path == "/sign-in" }
            }
            let reopenedCookies = await reopened.web.configuration.websiteDataStore.httpCookieStore.allCookies()
            checks["reopenedTabsHaveDistinctOriginalLabelsAndNoCookie"] = reopened.pages.map(\.recoveryTitle) == ["库存明细 A-417", "出库复核 A-417"] &&
                reopenedCookies.isEmpty && reopened.web === reopened.pages[1].web
            let waiting = try await decoded(reopened)
            checks["loginRedirectKeepsOriginalState"] = waiting.pages == saved.pages && reopened.tabReferences.isEmpty
            try await signIn(reopened, approve: false)
            checks["cancelledLoginKeepsBothRecoveries"] = reopened.pages.allSatisfy(\.recoveryWaiting)
            try await signIn(reopened, approve: true)
            let afterLogin = try await decoded(reopened)
            checks["confirmedLoginPreservesBothOriginalPages"] = afterLogin.pages == saved.pages
            try action("恢复原网页", in: reopened).performClick(nil)
            try await waitFor("恢复出库复核") { reopened.web.url == order && !reopened.pages[1].recoveryWaiting && !reopened.web.isLoading }
            checks["retryReloadsOnlySelectedTab"] = reopened.pages[0].recoveryWaiting && reopened.pages[0].web.url?.path == "/sign-in"
            _ = try reopened.manageTabs(["action": "switch", "tab_id": reopened.pages[0].id])
            try action("恢复原网页", in: reopened).performClick(nil)
            try await waitFor("恢复库存明细") { reopened.web.url == stock && !reopened.pages[0].recoveryWaiting && !reopened.web.isLoading }
            let restored = try await decoded(reopened)
            let restoredMemo = try await reopened.web.evaluateJavaScript("document.getElementById('memo').value") as? String
            checks["bothPagesAndOriginalMemoRestoreAfterOneLogin"] = restored.pages.map(\.url) == saved.pages.map(\.url) && restoredMemo == memo &&
                reopened.tabReferences.count == 2 && restored.pages[0].forms?.values.first?.value == memo

            control.showAgentTask(other)
            let isolated = try tasks.browser.show(taskID: other, title: "隔离的库存任务")
            _ = try await isolated.open(order)
            let isolatedCookies = await isolated.web.configuration.websiteDataStore.httpCookieStore.allCookies()
            checks["otherTaskRemainsSignedOut"] = isolated.web.url?.path == "/sign-in" && isolatedCookies.isEmpty && reopened.web.url == stock
            tasks.browser.close(other)
            control.showAgentTask(task)
            tasks.browser.close(task)
            let retained = try tasks.browser.restore(savedPage, taskID: task, title: "库存登录验收", present: { try $0.present() })
            try await waitFor("等待恢复原网页") { retained.pages.allSatisfy(\.recoveryWaiting) }
            try action("保留当前页", in: retained).performClick(nil)
            let retainedState = try await decoded(retained)
            checks["keepCurrentOnlyDropsRecoveryForThatTab"] = retainedState.pages[0] == saved.pages[0] &&
                retainedState.pages[1].url == base.appendingPathComponent("sign-in").absoluteString && !retained.pages[1].recoveryWaiting
        } catch { report["error"] = error.localizedDescription }
        report["appPID"] = getpid(); report["checks"] = checks; report["modelRequests"] = requests
        report["success"] = report["error"] == nil && requests == 0 && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("browser-report.json"))
    }
}
