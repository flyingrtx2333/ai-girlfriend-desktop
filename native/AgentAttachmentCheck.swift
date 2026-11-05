import AppKit

@MainActor extension AppDelegate {
    func checkAttachmentVision(_ output: URL) async throws -> [String: Any] {
        ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
        let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
        var p = PreferencesStore(directory: profile).preferences
        guard p.visionSupported == true else { throw PetError("当前配置没有声明视觉能力，未发起视觉模型验证") }
        p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.replyTokens = 2048; p.contextTokens = max(32768, p.contextTokens); store.preferences = p
        func draw(_ context: CGContext, pdf: Bool) {
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            let x: CGFloat = pdf ? 480 : 70
            context.setFillColor(NSColor.systemBlue.cgColor); context.fillEllipse(in: CGRect(x: x, y: 200, width: 230, height: 230))
            context.setFillColor(NSColor.systemRed.cgColor)
            for i in 0..<(pdf ? 3 : 2) { context.fill(CGRect(x: (pdf ? 60 : 430) + CGFloat(i * 95), y: 300, width: 65, height: 65)) }
            let y: CGFloat = pdf ? 480 : 65
            context.setFillColor(NSColor.systemGreen.cgColor); context.beginPath(); context.move(to: CGPoint(x: x + 115, y: y + 70)); context.addLine(to: CGPoint(x: x + 65, y: y)); context.addLine(to: CGPoint(x: x + 165, y: y)); context.closePath(); context.fillPath()
        }
        guard let bitmap = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PetError("图形无法绘制") }
        draw(bitmap, pdf: false)
        guard let image = bitmap.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw PetError("图形无法保存") }
        let pngURL = output.appendingPathComponent("shapes.png"), pdfURL = output.appendingPathComponent("shapes.pdf"); try png.write(to: pngURL)
        var box = CGRect(x: 0, y: 0, width: 800, height: 600)
        guard let consumer = CGDataConsumer(url: pdfURL as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PetError("PDF 无法绘制") }
        pdf.beginPDFPage(nil); draw(pdf, pdf: true); pdf.endPDFPage(); pdf.closePDF()
        let id = tasks.create(title: "真实附件视觉理解", mode: .ask)
        let photo = try await AgentAttachments.importFile(pngURL, store: tasks, taskID: id), document = try await AgentAttachments.importFile(pdfURL, store: tasks, taskID: id)
        let extracted = try AgentAttachments.content(store: tasks, taskID: id, id: photo.id)
        var checks = ["visualFixtureDoesNotExposeAnswersAsOCR": extracted.parts.first?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true]
        runtime.submit("分别查看 shapes.png 与 shapes.pdf 第1页。每个文件中有几个红色方块？蓝色圆在左侧还是右侧？绿色三角在蓝色圆的上方还是下方？只依据实际图像，不能用 OCR 猜。最后严格用两行回答：PNG：红色X个，蓝圆在左/右，绿三角在上/下；PDF：红色X个，蓝圆在左/右，绿三角在上/下。", taskID: id, attachmentIDs: [photo.id, document.id])
        defer { if runtime.isRunning(id) { runtime.cancel(id) } }
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline, let task = tasks.task(id), [.ready, .running].contains(task.status) { await wait(0.1) }
        guard let task = tasks.task(id) else { throw PetError("视觉任务丢失") }
        let lines = task.summary.components(separatedBy: "\n"), pngLine = lines.first { $0.contains("PNG") } ?? "", pdfLine = lines.first { $0.contains("PDF") } ?? ""
        checks["realModelReadsNonTextPNGGeometry"] = task.status == .completed && pngLine.contains("2") && pngLine.contains("左") && pngLine.contains("下")
        checks["realModelReadsDifferentPDFGeometry"] = task.status == .completed && pdfLine.contains("3") && pdfLine.contains("右") && pdfLine.contains("上")
        checks["realRuntimeSentBothActualVisualInputs"] = task.events.contains { $0.kind == "vision" && $0.detail.contains("shapes.png") && $0.detail.contains("shapes.pdf") } && Set(task.messages.flatMap { $0.visuals ?? [] }.map(\.id)) == Set([photo.id, document.id])
        let inputs = try await AgentAttachmentVisuals.prepare(messages: task.messages, store: tasks, taskID: id, preferences: p)
        let savedHistory = String(decoding: try JSONEncoder().encode(task), as: UTF8.self)
        checks["imagesAreBoundedAndNotPersistedInHistory"] = inputs.values.flatMap { $0 }.allSatisfy { $0.image.width <= 1536 && $0.image.height <= 1536 && $0.image.jpeg.count <= 2_000_000 } && !savedHistory.contains("data:image/")
        var off = p; off.visionMode = "off"
        checks["visionOffDoesNotTransmitImages"] = try await AgentAttachmentVisuals.prepare(messages: task.messages, store: tasks, taskID: id, preferences: off).isEmpty
        let other = tasks.create(title: "无附件任务", mode: .ask)
        do { _ = try await AgentAttachmentVisuals.prepare(messages: task.messages, store: tasks, taskID: other, preferences: p); checks["visualReferencesCannotCrossTaskBoundary"] = false } catch { checks["visualReferencesCannotCrossTaskBoundary"] = true }
        let groundTruth = ["PNG": ["redSquares": "2", "blueCircle": "left", "greenTriangle": "below"], "PDF": ["redSquares": "3", "blueCircle": "right", "greenTriangle": "above"]]
        return ["success": checks.values.allSatisfy { $0 }, "checks": checks, "groundTruth": groundTruth, "result": task.summary, "status": task.status.rawValue, "model": p.model, "events": task.events.map { ["title": $0.title, "status": $0.status, "detail": $0.detail] }, "scope": "Actual configured visual model, two public native-drawn fixtures with different color/geometry layouts and no text answers. Production attachment tools, native rasterization, real image payloads and API reply; no microphone or TTS."]
    }
    func checkAttachmentConversation(_ output: URL) async throws -> [String: Any] {
        ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("Agent 未初始化") }
        let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
        var p = PreferencesStore(directory: profile).preferences; p.voiceEnabled = false; p.wakeEnabled = false; p.screenObservationEnabled = false; p.contextTokens = max(32_768, p.contextTokens); p.replyTokens = 2048; store.preferences = p
        let id = tasks.create(title: "真实模型附件连续对话", mode: .ask)
        var files: [String: AgentAttachment] = [:]
        for name in ["sample.docx", "cached.xlsx", "sample.pptx", "sample.pdf"] { files[name] = try await AgentAttachments.importFile(output.appendingPathComponent(name), store: tasks, taskID: id) }
        let word = files["sample.docx"]!, sheet = files["cached.xlsx"]!, slides = files["sample.pptx"]!, unsent = files["sample.pdf"]!
        let tools = AgentTools(store: tasks, taskID: id)
        func call(_ name: String, _ values: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)) }
        var checks: [String: Bool] = [:]
        let draftList = try await tools.execute(call("list_attachments", [:]))
        let object = try JSONSerialization.jsonObject(with: Data(draftList.text.utf8)) as? [String: Any]
        checks["draftAttachmentsAreNotExposedToModel"] = object?["count"] as? Int == 0
        do { _ = try await tools.execute(call("read_attachment", ["id": word.id])); checks["unsentAttachmentCannotBeRead"] = false } catch { checks["unsentAttachmentCannotBeRead"] = true }
        var injected = false, answers = 0
        let previous = runtime.onChange
        runtime.onChange = { changed in
            previous?(changed)
            guard changed == id, !injected, let task = tasks.task(id), task.status == .running, task.messages.filter(\.isHumanInput).count == 1 else { return }
            injected = true
            runtime.submit("补充收入表。请读取表内已保存的合计缓存，演示文稿暂未提供，需要时向我索取，不要读取草稿。", taskID: id, attachmentIDs: [sheet.id])
        }
        defer { runtime.onChange = previous; if runtime.isRunning(id) { runtime.cancel(id) } }
        runtime.submit("请结合 Word 与收入表回答订单金额、收入合计、二者差额、演示文稿第一张的文字，并引用实际来源。缺少的资料请只用 ask_user 向我索取；附件不需要项目文件夹，不修改文件。", taskID: id, attachmentIDs: [word.id])
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, let task = tasks.task(id), [.ready, .running, .waiting].contains(task.status) {
            if task.status == .waiting {
                guard let pending = task.pendingCalls.first, pending.name == "ask_user", answers == 0 else { throw PetError("附件流程请求了预期外操作") }
                let question = pending.object["question"] as? String ?? ""
                guard question.localizedCaseInsensitiveContains("ppt") || question.contains("演示") else { throw PetError("模型没有按已提供的附件继续处理：" + question) }
                answers += 1
                do { _ = try await tools.execute(call("read_attachment", ["id": slides.id])); checks["unsentFileStillBlockedWhileWaiting"] = false } catch { checks["unsentFileStillBlockedWhileWaiting"] = true }
                runtime.submit("演示文稿来了，请继续原任务。", taskID: id, attachmentIDs: [slides.id])
            }
            await wait(0.1)
        }
        guard let task = tasks.task(id) else { throw PetError("附件任务丢失") }
        checks["queuedInputKeepsAttachmentReferencesAndOrder"] = injected && task.messages.filter(\.isHumanInput).prefix(2).map { $0.attachmentIDs ?? [] } == [[word.id], [sheet.id]] && task.queuedCount == 0
        checks["askUserAnswerKeepsAttachmentReferences"] = answers == 1 && task.messages.contains { $0.isHumanInput && $0.attachmentIDs == [slides.id] } && task.approvals.contains { $0.answerAttachments == [slides.id] && $0.decision?.hasPrefix("answer:") == true }
        checks["realModelAnswersFromActualOfficeAttachments"] = task.status == .completed && task.summary.contains("1499") && task.summary.contains("49") && task.summary.contains("1450") && task.summary.contains("4086") && task.events.filter { $0.title == "read_attachment" && $0.status == "completed" }.count >= 3
        checks["sourceReferencesAreActualAttachmentReceipts"] = task.sources.contains { $0.hasPrefix("attachment://" + word.id) } && task.sources.contains { $0.hasPrefix("attachment://" + sheet.id) } && task.sources.contains { $0.hasPrefix("attachment://" + slides.id) }
        checks["remainingDraftIsNotConsumedOrRead"] = task.draftAttachmentIDs == [unsent.id] && !task.submittedAttachmentIDs.contains(unsent.id) && !task.events.contains { $0.kind == "tool" && $0.title == "read_attachment" && $0.detail.contains(unsent.id) }
        let success = checks.values.allSatisfy { $0 }
        return ["success": success, "checks": checks, "model": p.model, "status": task.status.rawValue, "result": task.summary, "events": success ? [] : task.events.map { ["title": $0.title, "status": $0.status, "detail": $0.detail] }, "scope": "Actual configured model reads public Word, Excel and PowerPoint attachments. Structured queued message and ask_user answer submit files; an unsent PDF remains inaccessible. Text extraction only; visual message and UI integration remain separate acceptance items."]
    }
}
