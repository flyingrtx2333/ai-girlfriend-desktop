import AppKit

@MainActor extension AppDelegate {
    struct AttachmentWorkspaceFixture: Codable {
        let taskID: String
        let otherTaskID: String
        let draftFileID: String
        let pdfID: String
        let citation: String
    }

    func prepareAttachmentWorkspaceUI(_ output: URL) async throws -> AttachmentWorkspaceFixture {
        guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("附件阅读验收禁止模型请求") }
        ensureAgent(); guard let tasks = agentStore else { throw PetError("任务未初始化") }
        let text = output.appendingPathComponent("公开阅读样例.txt"), pdf = output.appendingPathComponent("公开双页样例.pdf")
        let lines = (1...175).map { "第 \($0) 行 · 公开附件阅读内容 WHALE-\($0)" }.joined(separator: "\n")
        try Data(lines.utf8).write(to: text)
        var box = CGRect(x: 0, y: 0, width: 600, height: 420)
        guard let consumer = CGDataConsumer(url: pdf as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PetError("公开 PDF 无法创建") }
        for lines in [["Page one WHALE-101", "Only the first page."], ["Page two WHALE-202", "Cited second line WHALE-203"]] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.enumerated() {
                NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black])
                    .draw(at: NSPoint(x: 56, y: 308 - CGFloat(index) * 56))
            }
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
        let id = tasks.create(title: "附件阅读公开样例", mode: .ask), other = tasks.create(title: "另一条问答任务", mode: .ask)
        let a = try await AgentAttachments.importFile(text, store: tasks, taskID: id)
        let b = try await AgentAttachments.importFile(pdf, store: tasks, taskID: id)
        let citation = "attachment://" + b.id + "/part/2#L2"
        tasks.update(id) {
            $0.draft = "保留附件阅读草稿。"; $0.draftAttachmentIDs = [a.id]
            $0.messages.append(AgentMessage(role: "user", content: "公开 PDF 附件历史", attachmentIDs: [b.id]))
            $0.sources = [citation]
        }
        tasks.update(other) { $0.draft = "另一条任务的独立草稿。" }
        let fixture = AttachmentWorkspaceFixture(taskID: id, otherTaskID: other, draftFileID: a.id, pdfID: b.id, citation: citation)
        try JSONEncoder().encode(fixture).write(to: output.appendingPathComponent("attachment-workspace-fixtures.json"))
        control.showAgentTask(id); control.show(tab: "chat")
        return fixture
    }

    func runAttachmentWorkspaceCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0
        do {
            let binary = Bundle.main.executableURL!
            report["appPID"] = getpid(); report["binaryHash"] = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime, let window = control.window else { throw PetError("附件验收窗口未初始化") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("附件验收禁止模型请求") }
            let f = try await prepareAttachmentWorkspaceUI(output), host = control.taskWorkspace
            let textRoot = AgentTaskWorkspace.Root.attachment(f.draftFileID), pdfRoot = AgentTaskWorkspace.Root.attachment(f.pdfID)
            let starting = try tasks.recordVersion(f.taskID)
            window.setContentSize(NSSize(width: 1200, height: 774)); window.contentView?.layoutSubtreeIfNeeded()
            control.checkOpenAttachment(taskID: f.taskID, id: f.draftFileID)
            guard let text = host.currentController as? AgentAttachmentWindow else { throw PetError("草稿附件没有打开") }
            let initial = await text.workspaceReadback()
            checks["draftAttachmentUsesSameTaskWindow"] = host.selectedRoot == textRoot && text.presentingWindow === window && text.window?.isVisible != true && initial["visible"] as? Bool == true
            checks["plainTextIsReadableWithoutAWorkspace"] = tasks.task(f.taskID)?.workspace == nil && tasks.task(f.taskID)?.mode == .ask && initial["readOnly"] as? Bool == true && (initial["text"] as? String)?.contains("WHALE-1") == true
            control.checkOpenAttachment(taskID: f.taskID, id: f.pdfID)
            guard let pdf = host.currentController as? AgentAttachmentWindow else { throw PetError("历史 PDF 没有打开") }
            let normal = await pdf.workspaceReadback()
            checks["pdfKeepsNativePreviewAndTextTabStaysOpen"] = host.selectedRoot == pdfRoot && normal["quickLook"] as? Bool == true && normal["mode"] as? String == "preview" && host.rootController(textRoot) === text
            control.presentAgentRecords(section: 2)
            guard let record = host.currentController as? AgentRecordWindow else { throw PetError("附件引用没有从记录打开") }
            record.checkOpenSource(f.citation)
            let cited = await pdf.workspaceReadback(); report["cited"] = cited
            checks["citationSelectsExactPartAndLineInSameAttachmentTab"] = host.currentController === pdf && cited["part"] as? Int == 2 && cited["selection"] as? String == "Cited second line WHALE-203" && host.rootController(.records) === record
            let state = try pdf.captureWorkspaceRecovery()
            do { try text.restoreWorkspaceRecovery(state); checks["savedPositionCannotMoveToAnotherAttachment"] = false }
            catch { checks["savedPositionCannotMoveToAnotherAttachment"] = true }
            control.showAgentTask(f.otherTaskID); control.checkOpenAttachment(taskID: f.otherTaskID, id: f.pdfID)
            checks["otherTaskCannotOpenFirstTaskAttachment"] = host.taskID == f.otherTaskID && host.rootController(pdfRoot) == nil
            control.showAgentTask(f.taskID); host.checkSelect(pdfRoot)
            let restored = await pdf.workspaceReadback()
            checks["taskSwitchKeepsSamePDFSelection"] = host.currentController === pdf && restored["selection"] as? String == cited["selection"] as? String
            window.appearance = NSAppearance(named: .aqua); window.setContentSize(NSSize(width: 780, height: 540))
            window.contentView?.layoutSubtreeIfNeeded()
            let compact = await pdf.workspaceReadback(); report["compact"] = compact
            checks["compactReaderHasUsableBodyAndControls"] = compact["visible"] as? Bool == true && (compact["readingWidth"] as? Double ?? 0) >= 400 && (compact["readingHeight"] as? Double ?? 0) >= 310
            checks["previewDoesNotRewriteTaskOrSourceFiles"] = try tasks.recordVersion(f.taskID) == starting && AgentFiles.hash(Data(contentsOf: AgentAttachments.source(store: tasks, taskID: f.taskID, id: f.pdfID))) == AgentFiles.hash(Data(contentsOf: output.appendingPathComponent("公开双页样例.pdf")))
            host.finish()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["modelRequests"] = requests
        report["success"] = report["error"] == nil && requests == 0 && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("attachment-workspace-report.json"))
    }
}
