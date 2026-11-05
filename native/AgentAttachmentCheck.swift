import Foundation

@MainActor extension AppDelegate {
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
