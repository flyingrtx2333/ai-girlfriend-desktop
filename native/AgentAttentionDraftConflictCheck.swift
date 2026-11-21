import AppKit

@MainActor extension AppDelegate {
    func runAttentionDraftConflictCheck(_ output: URL) async {
        let original = "两扇窗口共同打开的公开草稿。"
        let saved = "第一扇窗口保存的新草稿。"
        let stale = "第二扇窗口基于旧稿的续写。"
        let newer = "第一扇窗口在审阅期间又保存了一次。"
        let combined = "合并两个窗口内容后的公开草稿。"
        let outside = "独立读取后保存的最新公开答复。"
        var checks: [String: Bool] = [:], report: [String: Any] = [:], requests = 0

        func find<T: NSView>(_ root: NSView, _ type: T.Type, where matches: (T) -> Bool) -> T? {
            if root.isHiddenOrHasHiddenAncestor { return nil }
            if let view = root as? T, matches(view) { return view }
            for child in root.subviews { if let view = find(child, type, where: matches) { return view } }
            return nil
        }
        func click(_ owner: ControlWindow, _ title: String) throws {
            guard let root = owner.window?.contentView, let button = find(root, NSButton.self, where: { $0.title == title && $0.isEnabled }) else {
                throw PetError("缺少操作 " + title)
            }
            button.performClick(nil)
        }
        func text(_ owner: ControlWindow, _ label: String) throws -> NSTextView {
            guard let root = owner.window?.contentView, let view = find(root, NSTextView.self, where: { $0.accessibilityLabel() == label }) else {
                throw PetError("缺少文本区域 " + label)
            }
            return view
        }
        func canSend(_ owner: ControlWindow) -> Bool {
            owner.window?.contentView.flatMap { find($0, NSButton.self, where: { $0.title == "回复并继续" && $0.isEnabled }) } != nil
        }
        func noticeBesideChoices(_ owner: ControlWindow) -> Bool {
            guard let root = owner.window?.contentView,
                  let notice = find(root, NSTextField.self, where: { $0.accessibilityLabel() == "答复草稿冲突" }),
                  let button = find(root, NSButton.self, where: { $0.title == "载入已保存稿" }) else { return false }
            root.layoutSubtreeIfNeeded()
            let noticeFrame = root.convert(notice.bounds, from: notice), buttonFrame = root.convert(button.bounds, from: button)
            return noticeFrame.width >= 130 && noticeFrame.maxX <= buttonFrame.minX && abs(noticeFrame.midY - buttonFrame.midY) < 2
        }
        func render(_ owner: ControlWindow, _ name: String) throws {
            guard let root = owner.window?.contentView else { throw PetError("缺少审阅窗口") }
            root.layoutSubtreeIfNeeded(); owner.window?.displayIfNeeded()
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw PetError("无法绘制审阅窗口") }
            bitmap.size = root.bounds.size; root.cacheDisplay(in: root.bounds, to: bitmap)
            guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw PetError("无法编码审阅窗口") }
            try bytes.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        func settled(_ tasks: AgentStore, runtime: AgentRuntime) async throws {
            let deadline = Date().addingTimeInterval(10)
            while tasks.attention.loading || tasks.tasks.contains(where: { runtime.isBusy($0.id) }) {
                guard Date() < deadline else { throw PetError("原生事项尚未就绪") }; await wait(0.05)
            }
        }
        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("答复草稿验收需要独立资料")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("草稿验收禁止模型请求") }
            let owner = try await prepareAttentionPageUI(output)
            try await settled(tasks, runtime: runtime)
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("attention-fixtures.json"))) as? [String: Any]
            guard let ids = fixture?["tasks"] as? [String: String],
                  let child = ids["childQuestion"], let parent = ids["question"],
                  let childItem = tasks.attention.items.first(where: { $0.taskID == child && $0.kind == .question && !$0.handled }),
                  let parentItem = tasks.attention.items.first(where: { $0.taskID == parent && $0.kind == .question && !$0.handled }) else {
                throw PetError("缺少两条原生问题")
            }
            try tasks.attention.saveReply(childItem, text: original, expected: "")
            try tasks.attention.saveReply(parentItem, text: original, expected: "")
            control.window?.appearance = NSAppearance(named: .aqua)
            control.window?.setContentSize(NSSize(width: 1320, height: 800)); control.showAttentionPage()
            openTaskWindow(owner, from: control)
            guard let other = additionalTaskWindows.last else { throw PetError("缺少第二扇工作窗口") }
            other.window?.appearance = NSAppearance(named: .darkAqua)
            other.window?.setContentSize(NSSize(width: 780, height: 540)); other.showAttentionPage()
            guard let first = control.attentionPageController, let second = other.attentionPageController,
                  first.checkChooseTask(child), second.checkChooseTask(child), second.checkOpenReading() else {
                throw PetError("两个窗口未打开同一条问题")
            }
            checks["bothWindowsStartAtSameDraft"] = first.checkState()["reply"] as? String == original &&
                second.checkState()["reply"] as? String == original
            first.checkSetReply(saved)
            guard first.prepareToClose() else { throw PetError("第一扇窗口未保存") }
            second.checkSetReply(stale)
            let local = try text(other, "答复此问题"), range = NSRange(location: 3, length: 4)
            other.window?.makeFirstResponder(local); local.setSelectedRange(range)
            let overwrote = second.prepareToClose()
            let afterSave = try tasks.attention.replyDraft(childItem)
            checks["staleSavePreservesNewerDraft"] = !overwrote && afterSave == saved
            let preview = try text(other, "已保存的答复草稿")
            checks["reviewKeepsBothTextsSelectionAndReadOnlyPreview"] = local.string == stale && local.selectedRange() == range &&
                preview.string == saved && !preview.isEditable && !canSend(other)
            try click(other, "返回列表")
            checks["unresolvedLocalChangesBlockLeavingWithoutDiscard"] = second.checkState()["reading"] as? Bool == true && local.string == stale
            let compactNotice = noticeBesideChoices(other)
            try render(other, "reply-conflict-compact")
            try click(other, "查看原问题")
            let originalQuestion = try text(other, "需要我事项详情")
            checks["reviewCanReturnToOriginalQuestionWithoutChangingLocalDraft"] = originalQuestion.string.contains("Markdown") && local.string == stale
            try click(other, "查看已保存稿")

            first.checkSetReply(newer)
            guard first.prepareToClose() else { throw PetError("第一扇窗口未保存第二次变更") }
            try click(other, "保存本窗口稿")
            checks["newUpdateWhileReviewingRequiresAnotherChoice"] = try preview.string == newer && local.string == stale &&
                tasks.attention.replyDraft(childItem) == newer && !canSend(other)
            second.checkSetReply(combined)
            try click(other, "保存本窗口稿")
            checks["explicitLocalSaveStoresOnlyReviewedDraft"] = try tasks.attention.replyDraft(childItem) == combined &&
                tasks.task(child)?.approvals.last?.decision == nil && canSend(other)

            guard first.checkChooseTask(parent), second.checkChooseTask(parent), second.checkOpenReading() else {
                throw PetError("两个窗口未打开另一条问题")
            }
            other.window?.appearance = NSAppearance(named: .aqua)
            other.window?.setContentSize(NSSize(width: 1320, height: 800)); other.window?.contentView?.layoutSubtreeIfNeeded()
            first.checkSetReply(saved)
            guard first.prepareToClose() else { throw PetError("第一扇窗口未保存待发送稿") }
            try click(other, "回复并继续")
            try await settled(tasks, runtime: runtime)
            let decision = tasks.task(parent)?.approvals.last?.decision
            checks["staleSendPreservesNewerDraft"] = try decision == nil && tasks.attention.replyDraft(parentItem) == saved
            checks["staleSendShowsSavedDraftWithoutReplacingVisibleInput"] = preview.string == saved && local.string == original && !canSend(other)
            checks["noticeStaysBesideTheDraftChoicesAtBothSizes"] = compactNotice && noticeBesideChoices(other)
            try render(other, "reply-conflict-wide")
            let otherStore = AgentAttention(store: tasks)
            try otherStore.saveReply(parentItem, text: outside, expected: saved)
            try click(other, "载入已保存稿")
            checks["reviewReadsFreshFileFromIndependentStore"] = try preview.string == outside && local.string == original &&
                tasks.attention.replyDraft(parentItem) == outside && !canSend(other)
            try click(other, "载入已保存稿")
            checks["explicitLoadRequiresUserToSendAgain"] = local.string == outside && canSend(other) &&
                tasks.task(parent)?.approvals.last?.decision == nil
            try click(other, "回复并继续")
            try await settled(tasks, runtime: runtime)
            checks["approvalRecordsOnlyTheExplicitlyReviewedText"] = tasks.task(parent)?.approvals.last?.decision == "answer:" + outside &&
                tasks.task(parent)?.approvals.filter { $0.decision != nil }.count == 1
            checks["sendingClearsItsDraftAndLeavesOtherQuestion"] = try tasks.attention.replyDraft(parentItem).isEmpty &&
                tasks.attention.replyDraft(childItem) == combined && tasks.task(child)?.status == .waiting
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["pid"] = getpid(); report["modelRequests"] = requests
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && requests == 0
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("attention-draft-conflict.json"), options: .atomic)
        }
    }
}
