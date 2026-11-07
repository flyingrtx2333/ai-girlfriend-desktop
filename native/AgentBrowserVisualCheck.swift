import AppKit

@MainActor extension AppDelegate {
    func runAgentBrowserVisualCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:]
        func phase(_ value: String) { try? Data(value.utf8).write(to: output.appendingPathComponent("phase"), options: .atomic) }
        func call(_ name: String, _ args: [String: Any] = [:]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
        do {
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("截图视觉验收需要已配置的真实模型，请加 --live-agent") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
            let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var p = PreferencesStore(directory: profile).preferences
            guard p.visionSupported == true else { throw PetError("当前配置没有声明视觉能力，未发起视觉模型验收") }
            p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; store.preferences = p
            let screenAccessBefore = CGPreflightScreenCaptureAccess()
            let id = tasks.create(title: "真实浏览器截图视觉", mode: .ask), url = "http://127.0.0.1:4178/"
            defer { for task in tasks.tasks where runtime.isRunning(task.id) || task.status == .waiting { runtime.cancel(task.id) }; tasks.browser.closeAll() }
            tasks.update(id) { $0.permission = .review }
            phase("live-browser-image")
            runtime.submit("用内置浏览器打开 \(url)，然后必须用 browser_screenshot 查看实际页面图片。左上标题前的小圆点是什么颜色？人物的双手是什么姿势？只用两句简短中文回答。不要点击、读取源码或使用其他网页工具。", taskID: id)
            let deadline = Date().addingTimeInterval(140); var approvals = 0
            while Date() < deadline, let task = tasks.task(id), [.ready, .running, .waiting].contains(task.status) {
                if task.status == .waiting, let pending = task.pendingCalls.first {
                    guard pending.name == "browser_open", pending.object["url"] as? String == url, approvals < 2 else { throw PetError("视觉任务提出了预期外动作") }
                    approvals += 1; runtime.decide(taskID: id, callID: pending.id, decision: "allow")
                }
                await wait(0.1)
            }
            guard let task = tasks.task(id) else { throw PetError("截图任务丢失") }
            let tools = AgentTools(store: tasks, taskID: id)
            let captures = (task.attachments ?? []).filter { $0.browserCapture != nil && task.availableAttachmentIDs.contains($0.id) }
            checks["modelUsedActualBrowserScreenshotTool"] = task.events.contains { $0.title == "browser_screenshot" && $0.status == "completed" } && !captures.isEmpty
            checks["realRuntimeSentScreenshotToVisualModel"] = task.events.contains { $0.kind == "vision" && $0.detail.contains("网页截图-") }
            checks["modelDescribesRenderedColorAndPose"] = task.status == .completed && task.summary.contains("蓝") && task.summary.contains("手") && ["交", "叠", "握", "身前", "胸前", "腹"].contains { task.summary.contains($0) }
            report["live"] = ["success": checks.values.allSatisfy { $0 }, "checks": checks, "model": p.model, "status": task.status.rawValue, "result": task.summary, "approvalCount": approvals, "configuredContextLimit": p.contextLimit, "configuredOutputLimit": p.outputLimit, "events": task.events.map { ["title": $0.title, "detail": $0.detail, "status": $0.status] }]
            guard task.status == .completed, let captured = captures.last else { throw PetError(task.events.last(where: { $0.status == "failed" })?.detail ?? "真实截图任务未完成") }
            let browser = try tasks.browser.session(id)
            let shot: AgentBrowserShot
            do {
                guard let frame = browser.window?.frame else { throw PetError("浏览器窗口已关闭") }
                let sibling = NSWindow(contentRect: NSRect(x: frame.midX - 220, y: frame.midY - 60, width: 440, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
                sibling.isReleasedWhenClosed = false; sibling.level = .floating; sibling.title = "公开隔离验证窗口"
                sibling.contentView?.wantsLayer = true; sibling.contentView?.layer?.backgroundColor = NSColor.green.cgColor
                let marker = NSTextField(labelWithString: "PRIVATE WINDOW 7319"); marker.font = .systemFont(ofSize: 26); marker.frame = NSRect(x: 20, y: 30, width: 400, height: 50); sibling.contentView?.addSubview(marker)
                sibling.orderFrontRegardless(); defer { sibling.close() }
                shot = try await browser.screenshot()
                guard let image = NSBitmapImageRep(data: try shot.png())?.cgImage else { throw PetError("窗口裁切无法读取") }
                let pixels = try ScreenFrame.encode(image).thumbnail
                checks["viewportCaptureExcludesSiblingWindow"] = !stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] < 40 && pixels[$0 + 1] > 220 && pixels[$0 + 2] < 40 }
            }
            let geometry = try await browser.web.evaluateJavaScript("({color:getComputedStyle(document.querySelector('.brand-dot')).backgroundColor,targets:['appearance','background'].map(id=>{const el=document.getElementById(id),r=el.getBoundingClientRect();return {id,text:el.textContent,x:r.x,y:r.y,width:r.width,height:r.height};})})") as? [String: Any]
            guard let targets = geometry?["targets"] as? [[String: Any]], targets.count == 2 else { throw PetError("实际项目页面缺少待标注控件") }
            checks["colorGroundTruthReadIndependentlyFromActualPage"] = geometry?["color"] as? String == "rgb(83, 159, 224)"
            checks["captureStoresSourceAndViewport"] = captured.browserCapture?.url == url && (captured.browserCapture?.viewportWidth ?? 0) > 600 && (captured.width ?? 0) <= 1536 && (captured.height ?? 0) <= 1536
            checks["captureUsesOwnWindowSurface"] = captured.browserCapture?.method == "own-window" && shot.source.method == "own-window"
            checks["ownWindowCaptureDoesNotExpandRecordingAccess"] = screenAccessBefore == CGPreflightScreenCaptureAccess()
            report["recordingAccessBefore"] = screenAccessBefore; report["recordingAccessAfter"] = CGPreflightScreenCaptureAccess()
            checks["toolCaptureDoesNotEnterUserDraft"] = task.draftAttachmentIDs?.contains(captured.id) != true && task.submittedAttachmentIDs.isEmpty && task.availableAttachmentIDs.contains(captured.id)
            checks["captureDeliveryRecordedAfterActualModelReply"] = task.messages.contains { $0.role == "tool" && $0.visuals?.contains(where: { $0.id == captured.id }) == true && $0.visualsDelivered == true }
            let source = try AgentAttachments.source(store: tasks, taskID: id, id: captured.id)
            try FileManager.default.copyItem(at: source, to: output.appendingPathComponent("actual-model-screenshot.png"))
            let inputs = try await AgentAttachmentVisuals.prepare(messages: task.messages, store: tasks, taskID: id, preferences: p)
            let history = String(decoding: try JSONEncoder().encode(task), as: UTF8.self)
            checks["visualInputsAreBoundedAndHistoryStoresOnlyReferences"] = !inputs.isEmpty && inputs.values.flatMap { $0 }.allSatisfy { $0.image.width <= 1536 && $0.image.height <= 1536 && $0.image.jpeg.count <= 2_000_000 } && !history.contains("data:image/")
            var off = p; off.visionMode = "off"
            checks["disabledVisionDoesNotSendBrowserImage"] = try await AgentAttachmentVisuals.prepare(messages: task.messages, store: tasks, taskID: id, preferences: off).isEmpty
            let other = tasks.create(title: "无权引用截图的任务", mode: .ask)
            do { _ = try await AgentTools(store: tasks, taskID: other).execute(call("read_attachment", ["id": captured.id])); checks["captureCannotCrossTaskBoundary"] = false } catch { checks["captureCannotCrossTaskBoundary"] = true }
            let fork = tasks.fork(id)
            if let fork {
                let copied = try AgentAttachments.source(store: tasks, taskID: fork, id: captured.id)
                let originalData = try Data(contentsOf: source), copiedData = try Data(contentsOf: copied)
                checks["forkCopiesCaptureMetadataAndImage"] = tasks.task(fork)?.attachments?.first(where: { $0.id == captured.id })?.browserCapture?.url == url && copied != source && originalData == copiedData
            } else { checks["forkCopiesCaptureMetadataAndImage"] = false }
            tasks.browser.close(id)
            checks["captureRemainsReadableAfterBrowserCloses"] = (try await tools.execute(call("read_attachment", ["id": captured.id]))).visuals?.first?.id == captured.id
            do { _ = try await tools.execute(call("browser_screenshot")); checks["closedBrowserCannotCaptureAnotherPage"] = false } catch { checks["closedBrowserCannotCaptureAnotherPage"] = true }
            var answers: [[String: Any]] = []
            for (index, target) in targets.enumerated() {
                phase("live-annotation-\(index + 1)")
                guard let text = target["text"] as? String, let x = target["x"] as? Double, let y = target["y"] as? Double, let width = target["width"] as? Double, let height = target["height"] as? Double else { throw PetError("实际按钮位置无效") }
                let editor = AgentBrowserAnnotationWindow(shot: shot) { _, _ in }
                if index == 0 {
                    editor.canvas.kind = .arrow; editor.canvas.beginMark(at: CGPoint(x: 0.2, y: 0.2)); editor.canvas.continueMark(at: CGPoint(x: 0.4, y: 0.4)); editor.canvas.endMark()
                    editor.canvas.kind = .pen; editor.canvas.beginMark(at: CGPoint(x: 0.4, y: 0.4)); editor.canvas.continueMark(at: CGPoint(x: 0.5, y: 0.45)); editor.canvas.continueMark(at: CGPoint(x: 0.6, y: 0.4)); editor.canvas.endMark()
                    let two = editor.canvas.marks.count == 2; editor.canvas.undoMark(); let one = editor.canvas.marks.count == 1; editor.canvas.clearMarks()
                    checks["annotationArrowPenUndoAndClearUseNativeCanvas"] = two && one && editor.canvas.marks.isEmpty
                }
                editor.canvas.kind = .rectangle
                editor.canvas.beginMark(at: CGPoint(x: max(0, x - 3) / shot.source.viewportWidth, y: max(0, y - 3) / shot.source.viewportHeight))
                editor.canvas.continueMark(at: CGPoint(x: min(1, (x + width + 3) / shot.source.viewportWidth), y: min(1, (y + height + 3) / shot.source.viewportHeight))); editor.canvas.endMark()
                let directory = output.appendingPathComponent("annotation-\(index + 1)", isDirectory: true); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if index == 0 { checks.merge(editor.checkLayout(directory)) { _, latest in latest } }
                let marks = editor.canvas.marks; editor.close()
                let owner = tasks.create(title: "真实标注图片 \(index + 1)", mode: .ask)
                let question = "仅查看已附上的网页标注图片，用 read_attachment 获取实际图片。红框中按钮写着什么？只回答按钮文字。不要重新打开网页或读取项目文件。"
                let draftChecks = try await control.checkBrowserCaptureDraft(shot, marks: marks, note: question, taskID: owner)
                checks.merge(Dictionary(uniqueKeysWithValues: draftChecks.map { ($0.key + "-\(index + 1)", $0.value) })) { _, latest in latest }
                guard let draft = tasks.task(owner), let attachmentID = draft.draftAttachmentIDs?.first, let file = draft.attachments?.first(where: { $0.id == attachmentID }) else { throw PetError("标注未进入任务草稿") }
                checks["unsentAnnotationIsNotAvailable-\(index + 1)"] = draft.availableAttachmentIDs.isEmpty && file.browserCapture?.annotations == 1 && file.browserCapture?.url == url
                do { _ = try await AgentTools(store: tasks, taskID: owner).execute(call("read_attachment", ["id": attachmentID])); checks["unsentAnnotationCannotBeRead-\(index + 1)"] = false } catch { checks["unsentAnnotationCannotBeRead-\(index + 1)"] = true }
                try FileManager.default.copyItem(at: AgentAttachments.source(store: tasks, taskID: owner, id: attachmentID), to: directory.appendingPathComponent("actual-marked-image.png"))
                runtime.submit(draft.draft ?? question, taskID: owner, attachmentIDs: [attachmentID])
                let until = Date().addingTimeInterval(100)
                while Date() < until, let current = tasks.task(owner), [.ready, .running].contains(current.status) { await wait(0.1) }
                guard let result = tasks.task(owner) else { throw PetError("标注任务丢失") }
                let otherText = targets[index == 0 ? 1 : 0]["text"] as? String ?? ""
                checks["realModelReadsMarkedButton-\(index + 1)"] = result.status == .completed && result.summary.contains(text) && !result.summary.contains(otherText)
                checks["annotationSentAsActualImageAfterSubmission-\(index + 1)"] = result.events.contains { $0.kind == "vision" && $0.detail.contains(file.name) } && result.submittedAttachmentIDs.contains(attachmentID) && result.draftAttachmentIDs?.contains(attachmentID) != true
                answers.append(["expectedFromActualDOM": text, "result": result.summary, "status": result.status.rawValue, "image": "annotation-\(index + 1)/actual-marked-image.png", "events": result.events.map { ["title": $0.title, "detail": $0.detail, "status": $0.status] }])
                if runtime.isRunning(owner) { runtime.cancel(owner) }
            }
            report["annotations"] = answers; report["budgets"] = ["context": p.contextLimit, "output": p.outputLimit]
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && report["error"] == nil
        report["scope"] = "Actual project Vite page and native WKWebView screenshots. Real configured visual model, unchanged saved budgets, then two different native annotations of the same actual page; expected button text independently read from live DOM. Draft isolation, source retention, fork, image limits and native normal/narrow layouts checked. No simulated model/site replies, accounts, microphone or TTS."
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("browser-report.json")) }
    }
}
