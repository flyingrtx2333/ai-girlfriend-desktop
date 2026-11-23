import AppKit
import WebKit

@MainActor extension AppDelegate {
    func runBrowserDialogCheck(_ output: URL) async {
        var report: [String: Any] = [:], checks: [String: Bool] = [:], requests = 0
        do {
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "--browser-dialogs"), arguments.indices.contains(flag + 1),
                  let base = URL(string: arguments[flag + 1]), base.scheme == "http", base.host == "127.0.0.1", base.port != nil,
                  let executable = Bundle.main.executableURL else { throw PetError("缺少本机浏览器对话验收地址") }
            report["binaryHash"] = try AgentFiles(workspace: executable.deletingLastPathComponent().path).fileHash(executable)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("缺少任务工作台") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("浏览器对话检查禁止模型请求") }
            let id = tasks.create(title: "本机领料验收", mode: .ask, workMode: .general)
            control.showAgentTask(id); control.show(tab: "chat")
            let browser = try tasks.browser.show(taskID: id, title: "本机领料验收")
            defer { tasks.browser.close(id) }
            guard let owner = browser.presentingWindow else { throw PetError("浏览器没有窗口") }
            owner.makeKeyAndOrderFront(nil)
            let order = base.appendingPathComponent("order"), web = browser.web
            _ = try await browser.open(order)

            func trigger(_ selector: String, in page: WKWebView) -> Task<Void, Error> {
                Task {
                    _ = try await page.callAsyncJavaScript("document.getElementById(id).click();", arguments: ["id": selector], in: nil, contentWorld: .page)
                }
            }
            func visibleDialog(input: Bool = false) async throws -> AgentConfirmation {
                for _ in 0..<65 {
                    if let dialog = owner.agentDialog as? AgentConfirmation, (dialog.textInput != nil) == input { return dialog }
                    await wait(0.05)
                }
                throw PetError("网页对话框未显示")
            }
            func step(_ selector: String, input: Bool = false) async throws -> (AgentConfirmation, Task<Void, Error>) {
                let action = trigger(selector, in: web)
                do { return (try await visibleDialog(input: input), action) }
                catch { action.cancel(); throw error }
            }
            func resultText(in page: WKWebView) async throws -> String {
                try await page.evaluateJavaScript("document.getElementById('result').textContent") as? String ?? ""
            }
            func enter(_ text: String, into dialog: AgentConfirmation) throws {
                guard let editor = dialog.textInput?.currentEditor() as? NSTextView else { throw PetError("网页输入框未聚焦") }
                editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
            }

            let (prompt, openPrompt) = try await step("batch-button", input: true)
            let editor = prompt.textInput?.currentEditor() as? NSTextView
            checks["inputHasVerifiedOriginAndNativeFocus"] = prompt.messageText.contains(AgentBrowser.origin(order)) && prompt.isVisible &&
                prompt.presentingWindow === owner && owner.attachedSheet == nil && prompt.textInput?.stringValue == "样例批次 A-417" &&
                editor?.selectedRange().length == "样例批次 A-417".utf16.count
            checks["pageDialogKeepsTaskNavigationAndQuitInPlace"] = !browser.prepareWorkspaceNavigation() && !browser.canPreserveForQuit
            do { _ = try await browser.read(offset: 1, query: ""); checks["toolReadDoesNotWaitOnPageDialog"] = false }
            catch { checks["toolReadDoesNotWaitOnPageDialog"] = error.localizedDescription.contains("等待输入") }
            do { _ = try await browser.captureWorkspaceRecovery(); checks["workspaceRecoveryDoesNotReadModalInput"] = false }
            catch { checks["workspaceRecoveryDoesNotReadModalInput"] = error.localizedDescription.contains("恢复记录") }
            try enter("原生批次 417 中文", into: prompt)
            prompt.buttons.first?.performClick(nil)
            try await openPrompt.value
            checks["submittedUnicodeReachesActualWebsite"] = try await resultText(in: web) == "已填写批次：原生批次 417 中文"

            let (cancelled, cancelPrompt) = try await step("batch-button", input: true)
            try enter("取消输入不提交", into: cancelled); cancelled.cancel()
            try await cancelPrompt.value
            let cancelText = try await resultText(in: web)
            let keptBatch = try await web.evaluateJavaScript("document.getElementById('batch').value") as? String
            checks["cancelReturnsNullAndPreservesPreviousValue"] = cancelText == "已取消批次录入" && keptBatch == "原生批次 417 中文"
            let (empty, emptyPrompt) = try await step("batch-button", input: true)
            try enter("", into: empty); empty.buttons.first?.performClick(nil)
            try await emptyPrompt.value
            checks["emptySubmissionIsDistinctFromCancel"] = try await resultText(in: web) == "已提交空批次"

            let (alert, readAlert) = try await step("notice")
            checks["alertUsesSameCardAndCompletesOnce"] = alert.buttons.count == 1 && alert.textInput == nil
            alert.buttons.first?.performClick(nil)
            try await readAlert.value
            checks["alertReturnsToOriginalWebsite"] = try await resultText(in: web) == "领料说明已查阅"
            _ = try await browser.open(order, newTab: true)
            try await trigger("batch-button", in: web).value
            checks["inactiveTabCannotCoverActivePage"] = try await resultText(in: web) == "已取消批次录入" && owner.agentDialog == nil
            let original = browser.pages[0]
            _ = try browser.manageTabs(["action": "switch", "tab_id": original.id])
            let (_, stoppedPrompt) = try await step("batch-button", input: true); browser.stop()
            _ = try? await stoppedPrompt.value
            checks["stopDismissesDialogAndReturnsCancel"] = try await resultText(in: web) == "已取消批次录入" && owner.agentDialog == nil && !original.hasPageDialog

            let (filled, fillPrompt) = try await step("batch-button", input: true)
            try enter("原生批次 417 中文", into: filled); filled.buttons.first?.performClick(nil)
            try await fillPrompt.value
            let (confirm, cancelConfirm) = try await step("submit")
            checks["confirmationDefaultsToCancel"] = confirm.defaultButton?.title == "取消"
            confirm.defaultButton?.performClick(nil)
            try await cancelConfirm.value
            checks["cancelledConfirmationDoesNotNavigate"] = try await resultText(in: web) == "已取消提交" && web.url == order
            let (approved, submit) = try await step("submit")
            approved.buttons.first?.performClick(nil)
            try await submit.value
            for _ in 0..<80 {
                if web.url?.path.hasPrefix("/receipts/") == true && !web.isLoading { break }
                await wait(0.05)
            }
            let receipt = try await web.evaluateJavaScript("document.querySelector('main').innerText") as? String ?? ""
            checks["explicitConfirmationShowsActualReceipt"] = web.url?.path.hasPrefix("/receipts/") == true && receipt.contains("原生批次 417 中文") && owner.agentDialog == nil
            report["receipt"] = web.url?.lastPathComponent
            let recovery = try await browser.captureWorkspaceRecovery()
            checks["captureResumesAfterWebsiteFinishes"] = try AgentBrowserRecoveryState.decode(recovery).pages.first?.url == web.url?.absoluteString
        } catch { report["error"] = error.localizedDescription }
        report["appPID"] = getpid(); report["checks"] = checks; report["modelRequests"] = requests
        report["success"] = report["error"] == nil && requests == 0 && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("browser-report.json"))
    }
}
