import AppKit

@MainActor extension AppDelegate {
    private struct AttentionFixture: Codable {
        let main: String, other: String, owner: String, parent: String, child: String, handled: String, item: String
        let list: AgentAttentionRecovery.Position
    }

    func runAttentionRecoveryCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let fixtureURL = output.appendingPathComponent("attention-recovery-fixture.json")
        let bodyMarker = "原问题标记 🧭", replyMarker = "原答复选区 🪙", insertion = "继续核对 🪙"
        let bodyText = (0..<62).map { $0 == 42 ? bodyMarker : "第 \($0 + 1) 行公开问题，请逐项核对附件。" }.joined(separator: "\n")
        let draft = (0..<37).map { $0 == 28 ? replyMarker : "第 \($0 + 1) 行本地答复草稿。" }.joined(separator: "\n")
        let changedDraft = "另一窗口已更新这条公开答复。"
        let originalDraft = "原任务尚未发送的草稿。"
        var checks: [String: Bool] = [:], failure: String?, modelRequests = 0

        func find<T: NSView>(_ root: NSView, _ type: T.Type, where matches: (T) -> Bool) -> T? {
            if root.isHiddenOrHasHiddenAncestor { return nil }
            if let view = root as? T, matches(view) { return view }
            for child in root.subviews { if let view = find(child, type, where: matches) { return view } }
            return nil
        }
        func input<T: NSView>(_ owner: ControlWindow, _ type: T.Type, _ label: String) throws -> T {
            guard let root = owner.window?.contentView, let view = find(root, type, where: { $0.accessibilityLabel() == label }) else {
                throw PetError("缺少需要我控件 " + label)
            }
            return view
        }
        func click(_ owner: ControlWindow, _ title: String) throws {
            guard let root = owner.window?.contentView, let button = find(root, NSButton.self, where: { $0.title == title && $0.isEnabled }) else {
                throw PetError("缺少需要我操作 " + title)
            }
            button.performClick(nil)
        }
        func size(_ owner: ControlWindow, _ value: NSSize, _ appearance: NSAppearance.Name) {
            owner.window?.appearance = NSAppearance(named: appearance); owner.window?.setContentSize(value)
            owner.window?.contentView?.layoutSubtreeIfNeeded()
        }
        func render(_ owner: ControlWindow, _ name: String) throws {
            guard let root = owner.window?.contentView else { throw PetError("缺少渲染窗口") }
            root.layoutSubtreeIfNeeded(); owner.window?.displayIfNeeded()
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw PetError("无法绘制需要我窗口") }
            bitmap.size = root.bounds.size; root.cacheDisplay(in: root.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError("需要我窗口无法编码") }
            try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        func waitUntil(_ label: String, _ ready: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(12)
            while !ready() {
                guard Date() < deadline else { throw PetError(label) }; await wait(0.05)
            }
        }
        func page(_ owner: ControlWindow) throws -> AgentAttentionWindow {
            guard let inbox = owner.attentionPageController else { throw PetError("原需要我页面未恢复") }; return inbox
        }
        func filter(_ owner: ControlWindow, _ label: String, _ title: String) throws {
            let menu = try input(owner, NSPopUpButton.self, label)
            menu.selectItem(withTitle: title)
            guard menu.titleOfSelectedItem == title, let action = menu.action, NSApp.sendAction(action, to: menu.target, from: menu) else {
                throw PetError("无法选择需要我筛选 " + title)
            }
        }
        func query(_ owner: ControlWindow, _ value: String, range: NSRange? = nil) throws {
            let field = try input(owner, NSSearchField.self, "搜索需要我当前列表")
            field.stringValue = value
            try page(owner).controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
            if let range {
                owner.window?.makeFirstResponder(field); (field.currentEditor() as? NSTextView)?.setSelectedRange(range)
            }
        }
        func tab(_ owner: ControlWindow, _ index: Int) throws {
            let tabs = try input(owner, NSSegmentedControl.self, "需要我列表")
            tabs.selectedSegment = index
            guard let action = tabs.action, NSApp.sendAction(action, to: tabs.target, from: tabs) else { throw PetError("需要我页签不可用") }
        }
        func select(_ owner: ControlWindow, _ taskID: String) throws -> NSTableView {
            let table = try input(owner, NSTableView.self, "需要我事项列表")
            let rows = try page(owner).checkState()["rows"] as? [[String: Any]] ?? []
            guard let row = rows.firstIndex(where: { $0["taskID"] as? String == taskID }) else { throw PetError("需要我找不到指定事项") }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); return table
        }
        func selectText(_ text: NSTextView, _ marker: String) {
            text.window?.makeFirstResponder(text)
            if let scroll = text.enclosingScrollView, let layout = text.layoutManager, let container = text.textContainer {
                layout.ensureLayout(for: container)
                text.setFrameSize(NSSize(width: text.frame.width, height: max(scroll.contentSize.height, layout.usedRect(for: container).maxY + text.textContainerInset.height * 2)))
            }
            let range = (text.string as NSString).range(of: marker)
            if range.location != NSNotFound { text.setSelectedRange(range); text.scrollRangeToVisible(range) }
        }
        func picked(_ view: NSTextView) -> String {
            let value = view.string as NSString, range = view.selectedRange()
            return NSMaxRange(range) <= value.length ? value.substring(with: range) : ""
        }

        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("需要我恢复验收必须使用独立资料")
            }
            runtime.modelRequestCheck = { modelRequests += 1; throw PetError("需要我恢复验收禁止模型请求") }
            let journal = AgentWorkspaceRecovery(profile: store.directory)
            if stage == "seed" {
                let owner = try await prepareAttentionPageUI(output, childQuestion: bodyText, extraQuestions: 7)
                control.showAttentionPage()
                let mainPage = try page(control)
                let original = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("attention-fixtures.json"))) as? [String: Any]
                guard let ids = original?["tasks"] as? [String: String], let parent = ids["question"], let child = ids["childQuestion"],
                      let denied = ids["deny"] else { throw PetError("原生请求样例缺失") }
                try await waitUntil("等待原生事项载入") { !tasks.attention.loading && tasks.attention.items.contains { $0.taskID == child } }
                guard mainPage.checkChooseTask(denied, decision: "deny") else { throw PetError("未能通过原生按钮建立一条历史记录") }
                try await waitUntil("等待历史记录保存") { !tasks.attention.loading && tasks.attention.items.contains { $0.taskID == denied && $0.handled } }
                try tab(control, 1); try filter(control, "筛选待办类型", "审批"); try query(control, "拒绝")
                try tab(control, 0)
                size(control, NSSize(width: 780, height: 540), .darkAqua)
                try filter(control, "筛选待办类型", "问题"); try query(control, "确认")
                let table = try select(control, child)
                table.scrollRowToVisible(table.selectedRow)
                guard mainPage.checkOpenReading() else { throw PetError("窄窗未打开待答复事项") }
                let body = try input(control, NSTextView.self, "需要我事项详情"), reply = try input(control, NSTextView.self, "答复此问题")
                selectText(body, bodyMarker)
                mainPage.checkSetReply(draft); selectText(reply, replyMarker)
                checks["seedHasSelectedBodyAndReplyAtScrolledPositions"] = picked(body) == bodyMarker && picked(reply) == replyMarker &&
                    (body.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0 && (reply.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0
                try render(control, "attention-recovery-before-quit")

                openTaskWindow(parent, from: control)
                guard let other = additionalTaskWindows.last else { throw PetError("缺少第二窗口") }
                size(other, NSSize(width: 1320, height: 800), .aqua)
                other.showAttentionPage(); try tab(other, 1)
                try filter(other, "筛选待办类型", "审批"); try filter(other, "筛选待办来源", "本机会话")
                try filter(other, "筛选处理时间", "最近7天"); try filter(other, "筛选发起者", "我")
                _ = try select(other, denied); try query(other, "另一项", range: NSRange(location: 1, length: 2))
                try page(other).showSettings()
                guard await flushWorkspaceWindows(), let mainID = control.workspaceSession?.id, let otherID = other.workspaceSession?.id,
                      let primary = try journal.loadWindow(mainID)?.value.attention, let secondary = try journal.loadWindow(otherID)?.value.attention,
                      let detail = primary.detail, let position = primary.lists[0].position else { throw PetError("两扇窗口的恢复记录未保存") }
                checks["windowJournalStoresPositionsNotReplyText"] = primary.active && primary.tab == 0 &&
                    primary.lists[1].query == "拒绝" && position.y > 0 && detail.reply?.hash == AgentFiles.hash(Data(draft.utf8))
                checks["backgroundWindowKeepsIndependentHistoryAndDirection"] = !secondary.active && secondary.tab == 1 &&
                    secondary.lists[1].query == "另一项" && secondary.lists[1].days == 7 && secondary.lists[1].sender == "我" &&
                    secondary.lists[1].selection?.range == NSRange(location: 1, length: 2)
                let fixture = AttentionFixture(main: mainID, other: otherID, owner: owner, parent: parent, child: child, handled: denied, item: detail.item, list: position)
                try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
            } else {
                let fixture = try JSONDecoder().decode(AttentionFixture.self, from: Data(contentsOf: fixtureURL))
                control.show(tab: "chat"); restoreAdditionalWorkspaceWindows()
                try await waitUntil("正式恢复流程未显示原事项页") {
                    !tasks.attention.loading && control.attentionPageController?.isVisible == true &&
                    control.attentionPageController?.checkState()["status"] as? String != "正在载入…"
                }
                let mainPage = try page(control)
                let state = mainPage.checkState()
                checks["sameWindowTaskAndOriginalComposer"] = control.workspaceSession?.id == fixture.main &&
                    control.agentTaskID == fixture.owner && tasks.task(fixture.owner)?.draft == originalDraft
                if stage == "unavailable" {
                    let rows = state["rows"] as? [[String: Any]] ?? []
                    checks["unavailableItemReturnsToListWithoutTargetingAnotherRequest"] = state["reading"] as? Bool == false &&
                        state["selected"] as? String == nil && state["query"] as? String == "确认" &&
                        state["status"] as? String == "原事项已变化，请从列表选择" && rows.contains { $0["taskID"] as? String == fixture.parent }
                    try render(control, "attention-original-unavailable")
                    _ = try select(control, fixture.parent)
                    let opened = mainPage.checkOpenReading(), reply = try input(control, NSTextView.self, "答复此问题")
                    checks["explicitSelectionOnlyOpensCurrentDifferentItem"] = opened &&
                        mainPage.checkState()["selected"] as? String != fixture.item && reply.string.isEmpty
                } else {
                    let reply = try input(control, NSTextView.self, "答复此问题")
                    let body = try input(control, NSTextView.self, "需要我事项详情")
                    checks["originalFiltersAndNarrowReaderOpenWithoutNavigation"] = state["reading"] as? Bool == true &&
                        state["selected"] as? String == fixture.item && state["query"] as? String == "确认" &&
                        state["kind"] as? String == "question" && control.window?.contentView?.bounds.size == NSSize(width: 780, height: 540)
                    if stage == "changed" {
                        checks["updatedDraftReadFromDiskWithoutOldSelection"] = reply.string == changedDraft && picked(reply) != replyMarker &&
                            state["status"] as? String == "答复草稿已更新，请核对后继续"
                    } else {
                        checks["bodyAndReplyRecoverSelectionScrollAndFocus"] = picked(body) == bodyMarker && picked(reply) == replyMarker &&
                            control.window?.firstResponder === reply && reply.string == draft &&
                            (body.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0 &&
                            (reply.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0
                        try render(control, "attention-recovery-after-reopen")
                        let range = reply.selectedRange()
                        reply.insertText(insertion, replacementRange: range)
                        let expected = draft.replacingOccurrences(of: replyMarker, with: insertion)
                        checks["typingContinuesThroughOriginalSelection"] = reply.string == expected && mainPage.prepareToClose()
                        try click(control, "返回列表")
                        let table = try input(control, NSTableView.self, "需要我事项列表")
                        let restoredY = table.enclosingScrollView?.contentView.bounds.minY ?? 0
                        checks["backRecoversOriginalVisibleListAnchor"] = abs(restoredY - fixture.list.y) < 1 &&
                            mainPage.checkState()["selected"] as? String == fixture.item
                        try tab(control, 1)
                        checks["otherTabKeepsItsOwnFilterAndSelection"] = mainPage.checkState()["query"] as? String == "拒绝" &&
                            mainPage.checkState()["kind"] as? String == "approval"
                        try tab(control, 0); _ = try select(control, fixture.child)
                        checks["canReopenOriginalAfterTabSwitch"] = mainPage.checkOpenReading()

                        guard let other = additionalTaskWindows.first(where: { $0.workspaceSession?.id == fixture.other }),
                              other.attentionPageController?.isVisible == false else { throw PetError("另一扇窗口未保留设置页") }
                        try click(other, "返回需要我")
                        try await waitUntil("设置返回未恢复历史页") { other.attentionPageController?.isVisible == true }
                        let otherState = try page(other).checkState()
                        let field = try input(other, NSSearchField.self, "搜索需要我当前列表")
                        checks["settingsReturnRestoresSeparateHistoryAndSearchSelection"] = otherState["tab"] as? Int == 1 &&
                            otherState["query"] as? String == "另一项" && otherState["source"] as? String == "local" &&
                            otherState["days"] as? Int == 7 && otherState["sender"] as? String == "我" &&
                            (field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 1, length: 2)
                        try render(other, "attention-recovery-settings-return")
                    }
                }
                checks["independentTaskStillHasNoApprovalByRecovery"] = tasks.task(fixture.parent)?.approvals.last?.decision == nil
            }
            checks["layoutsFlushed"] = await flushWorkspaceWindows()
        } catch { failure = error.localizedDescription }
        checks["zeroModelRequests"] = modelRequests == 0
        var result: [String: Any] = ["stage": stage, "pid": getpid(), "checks": checks, "modelRequests": modelRequests,
                                     "success": failure == nil && checks.values.allSatisfy { $0 }]
        result["error"] = failure
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("attention-recovery-" + stage + ".json"), options: .atomic)
        }
    }
}
