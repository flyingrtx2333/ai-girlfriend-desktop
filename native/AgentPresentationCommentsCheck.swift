import AppKit

@MainActor extension AppDelegate {
    private struct PresentationFixture: Codable {
        let task: String, window: String, tab: String, hash: String
    }

    func runPresentationCommentsCheck(_ output: URL) async {
        let args = CommandLine.arguments
        let stage = args.firstIndex(of: "--recovery-stage").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "seed"
        let project = output.appendingPathComponent("project")
        let file = project.appendingPathComponent(stage == "legacy" ? "legacy.pptx" : stage == "blank" ? "blank.pptx" : "sample.pptx")
        let marker = output.appendingPathComponent("presentation-fixture.json")
        let old = "核对交付日期", reply = "负责同事已复核 🐋\n下周确认最终日期", new = "核对图表标题 🧭\n补上统计口径"
        let draft = "保留另一条未发送回复"
        var checks: [String: Bool] = [:], observed: [String: Any] = [:], error: String?, requests = 0

        func open(_ path: URL) async throws -> AgentOfficeWindow {
            let deadline = Date().addingTimeInterval(35)
            while Date() < deadline {
                if let editor = control.taskWorkspace.currentController as? AgentOfficeWindow, editor.file == path {
                    let state = await editor.workspaceReadback()
                    if state["ready"] as? Bool == true, state["working"] as? Bool == false { return editor }
                }
                await wait(0.05)
            }
            throw PetError("未从任务工作区打开演示文稿")
        }
        func poll(_ editor: AgentOfficeWindow, _ label: String, matches: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(12)
            var state: [String: Any] = [:]
            while Date() < deadline {
                state = try await editor.checkPresentationComments()
                if matches(state) { return state }
                await wait(0.04)
            }
            observed[label] = state
            let notice = state["notice"] as? String ?? ""
            throw PetError(label + " 未达到预期" + (notice.isEmpty ? "" : " ／ " + notice))
        }
        func texts(_ value: [String: Any]) -> [String] {
            (value["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        }
        func select(_ editor: AgentOfficeWindow, _ text: String) async throws -> [String: Any] {
            _ = try await editor.checkPresentationComments(action: "select", text: text)
            return try await poll(editor, "select") { texts($0).first?.hasPrefix(text) == true && $0["newEnabled"] as? Bool == true }
        }
        func fits(_ value: [String: Any], dark: Bool) -> Bool {
            (value["bodyHeight"] as? Int ?? 0) > 68 && (value["panelWidth"] as? Double ?? 0) >= 190 &&
                (value["viewportWidth"] as? Double ?? 0) - (value["panelWidth"] as? Double ?? 0) >= 300 &&
                (value["submitBottom"] as? Double ?? .infinity) < (value["viewportHeight"] as? Double ?? 0) &&
                value["dark"] as? Bool == dark && value["slideLabelsStayOnOneLine"] as? Bool == true
        }
        func measure(_ key: String, _ pane: [String: Any], width: CGFloat, height: CGFloat) -> Bool {
            let size = control.window?.contentView?.bounds.size ?? .zero
            observed[key] = ["windowWidth": size.width, "windowHeight": size.height, "pane": pane]
            return abs(size.width - width) < 1 && abs(size.height - height) < 1
        }
        func findButton(_ view: NSView, label: String) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityLabel() == label { return button }
            return view.subviews.lazy.compactMap { findButton($0, label: label) }.first
        }

        do {
            ensureAgent()
            guard checkDirectory == output, let tasks = agentStore, let runtime = agentRuntime,
                  tasks.extensions.sharedHome?.standardizedFileURL == output.appendingPathComponent("shared-home").standardizedFileURL else {
                throw PetError("演示文稿批注需要独立验收资料")
            }
            runtime.modelRequestCheck = { requests += 1; throw PetError("演示文稿批注验收禁止模型请求") }
            let files = try AgentFiles(workspace: project.path), journal = AgentWorkspaceRecovery(profile: store.directory)
            let dark = stage == "apply" || stage == "legacy"
            control.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            control.show(tab: "chat")
            control.window?.setContentSize(NSSize(width: dark ? 780 : 1320, height: dark ? 540 : 800))
            if stage == "seed" || stage == "blank" || stage == "legacy" {
                let hash = try files.fileHash(file)
                let task = tasks.create(title: "核对演示文稿批注", workspace: project.path, draft: "保留任务原输入")
                control.showAgentTask(task); control.showTaskDocument(file.path)
                let editor = try await open(file)
                let before = await editor.workspaceReadback()
                checks.merge(before["checks"] as? [String: Bool] ?? [:]) { a, _ in a }
                let pane = try await editor.checkPresentationComments(action: "toggle")
                checks["actualToolbarOpensReview"] = pane["visible"] as? Bool == true
                if stage == "seed" {
                    guard let expand = findButton(control.taskWorkspace, label: "放大工作区"), !expand.isHiddenOrHasHiddenAncestor else {
                        throw PetError("工作区没有展开入口")
                    }
                    expand.performClick(nil)
                    control.window?.contentView?.layoutSubtreeIfNeeded()
                    let selected = try await select(editor, old)
                    let view = try await editor.checkWorkspaceView()
                    checks["locatesOriginalSlide"] = selected["slide"] as? String == "第 2 张" && (view["selection"] as? [String: Any])?["slide"] as? Int == 2
                    let typed = try await editor.checkPresentationComments(action: "draft", text: reply)
                    let range = typed["range"] as? [Any]
                    checks["draftRetainsUnicodeLineBreakAndSelection"] = typed["draft"] as? String == reply &&
                        range?.first as? Int == 2 && range?.dropFirst().first as? Int == 6 && range?.last as? String == "backward"
                    checks["wideLightReviewFits"] = fits(typed, dark: false)
                    checks["wideWindowUsesExpandedDocumentArea"] = measure("wide", typed, width: 1320, height: 800) &&
                        (typed["viewportWidth"] as? Double ?? 0) > 900 && control.taskWorkspace.expanded
                    _ = try await editor.checkPresentationComments(image: output.appendingPathComponent("review-light.png"))
                    guard await flushWorkspaceWindows(), let window = control.workspaceSession?.id,
                          let tab = control.taskWorkspace.recoveryLayouts.first(where: { $0.taskID == task })?.tabs.first(where: { $0.root == "document:" + file.path }),
                          let saved = try journal.loadPage(windowID: window, pageID: tab.id, taskID: task), let asset = saved.asset else {
                        throw PetError("未发送批注未持久保存")
                    }
                    let state = try AgentOfficeWindow.recoveryState(saved.saved.value)
                    checks["draftOnlyKeepsExactOriginalAndPrivateBytes"] = try state.documentDirty == false && state.dirty &&
                        files.fileHash(file) == hash && AgentFiles(workspace: asset.deletingLastPathComponent().path).fileHash(asset) == hash
                    try JSONEncoder().encode(PresentationFixture(task: task, window: window, tab: tab.id, hash: hash)).write(to: marker, options: .atomic)
                } else {
                    if stage == "legacy" {
                        let selected = try await select(editor, "旧版交付批注")
                        checks["legacyReviewKeepsExistingReplyAndAllowsNewComment"] = texts(selected) == ["旧版交付批注", "旧版答复验收"] &&
                            selected["status"] as? String == "" && selected["readOnly"] as? Bool == true && selected["newEnabled"] as? Bool == true
                    } else {
                        checks["blankDeckHasEmptyReview"] = pane["notice"] as? String == "暂无批注"
                    }
                    _ = try await editor.checkPresentationComments(action: "new")
                    let entry = try await poll(editor, "new") { $0["focused"] as? Bool == true && $0["newEnabled"] as? Bool == true }
                    checks["newCommentUsesActiveSlide"] = entry["slide"] as? String == (stage == "legacy" ? "第 2 张" : "第 1 张")
                    _ = try await editor.checkPresentationComments(action: "draft", text: new)
                    _ = try await editor.checkPresentationComments(action: "submit")
                    let posted = try await poll(editor, "posted") { texts($0) == [new] }
                    checks["newCommentHasCorrectFormatControls"] = posted["status"] as? String == (stage == "legacy" ? "" : "解决")
                    try await editor.saveDocument()
                    checks["savedFileChangedAndReviewIsClean"] = try files.fileHash(file) != hash && !editor.dirty
                }
            } else {
                let fixture = try JSONDecoder().decode(PresentationFixture.self, from: Data(contentsOf: marker))
                guard await flushWorkspaceWindows() else { throw PetError("演示文稿工作区没有恢复") }
                control.taskWorkspace.checkSelect(.document(file.path))
                let editor = try await open(file)
                let restored = try await editor.checkPresentationComments()
                let view = try await editor.checkWorkspaceView()
                checks["sameTaskWindowAndComposerSurviveRestart"] = control.workspaceSession?.id == fixture.window &&
                    tasks.task(fixture.task)?.draft == "保留任务原输入"
                if stage == "apply" {
                    let range = restored["range"] as? [Any]
                    checks["restoresUnsentReplyAtOriginalSlideAndSelection"] = restored["visible"] as? Bool == true &&
                        restored["draft"] as? String == reply && texts(restored).first == old &&
                        range?.first as? Int == 2 && range?.dropFirst().first as? Int == 6 && range?.last as? String == "backward" &&
                        (view["selection"] as? [String: Any])?["slide"] as? Int == 2
                    checks["reopenedDraftReceivesFocus"] = restored["focused"] as? Bool == true
                    checks["narrowDarkReviewFits"] = fits(restored, dark: true)
                    checks["narrowWindowRemainsAtRequestedSize"] = measure("narrow", restored, width: 780, height: 540)
                    _ = try await editor.checkPresentationComments(image: output.appendingPathComponent("review-dark.png"))
                    _ = try await editor.checkPresentationComments(action: "key")
                    let replied = try await poll(editor, "reply") { texts($0) == [old, reply] && $0["newEnabled"] as? Bool == true }
                    let messages = replied["messages"] as? [[String: Any]] ?? []
                    checks["keyboardSubmitsReplyWithAuthorAndParent"] = messages.last?["author"] as? String == "小鲸" && messages.last?["reply"] as? Bool == true
                    _ = try await editor.checkPresentationComments(action: "status")
                    let resolved = try await poll(editor, "resolve") { $0["status"] as? String == "重新打开" && $0["newEnabled"] as? Bool == true }
                    checks["resolvedThreadKeepsMessagesAndDisablesReplies"] = texts(resolved) == [old, reply] && resolved["readOnly"] as? Bool == true
                    _ = try await editor.checkPresentationComments(action: "status")
                    let reopened = try await poll(editor, "reopen") { $0["status"] as? String == "解决" && $0["newEnabled"] as? Bool == true }
                    checks["reopeningEnablesReplies"] = reopened["readOnly"] as? Bool == false
                    _ = try await editor.checkPresentationComments(action: "status")
                    _ = try await poll(editor, "resolveForSave") { $0["status"] as? String == "重新打开" && $0["newEnabled"] as? Bool == true }
                    var firstSlide = try await editor.checkWorkspaceView()
                    firstSlide["selection"] = ["slide": 1, "part": NSNull(), "target": NSNull()]
                    firstSlide["scroll"] = []
                    _ = try await editor.checkWorkspaceView(firstSlide)
                    _ = try await editor.checkPresentationComments(action: "new")
                    _ = try await poll(editor, "newOnFirstSlide") { $0["slide"] as? String == "第 1 张" && $0["focused"] as? Bool == true }
                    _ = try await editor.checkPresentationComments(action: "draft", text: new)
                    _ = try await editor.checkPresentationComments(action: "submit")
                    _ = try await poll(editor, "firstSlidePosted") { texts($0) == [new] && $0["newEnabled"] as? Bool == true }
                    _ = try await editor.checkPresentationComments(action: "draft", text: draft)
                    try await editor.saveDocument()
                    let hash = try files.fileHash(file)
                    checks["actualSaveRecordsBeforeAndAfterCheckpoint"] = tasks.task(fixture.task)?.changes.contains {
                        $0.path == file.path && $0.beforeHash == fixture.hash && $0.afterHash == hash && $0.backup != nil
                    } == true
                    guard await flushWorkspaceWindows(),
                          let saved = try journal.loadPage(windowID: fixture.window, pageID: fixture.tab, taskID: fixture.task),
                          let asset = saved.asset else { throw PetError("保存文件后未保留另一条回复草稿") }
                    let state = try AgentOfficeWindow.recoveryState(saved.saved.value)
                    checks["saveKeepsOtherDraftAgainstSavedBytes"] = try state.documentDirty == false && state.openedHash == hash &&
                        AgentFiles(workspace: asset.deletingLastPathComponent().path).fileHash(asset) == hash
                } else {
                    checks["restoresUnsavedReplyOnNewlySavedThread"] = restored["draft"] as? String == draft &&
                        texts(restored) == [new] && restored["slide"] as? String == "第 1 张"
                    let read = try await select(editor, old)
                    checks["savedReplyAndResolutionReopenOnOriginalSlide"] = texts(read) == [old, reply] &&
                        read["status"] as? String == "重新打开" && read["slide"] as? String == "第 2 张"
                    let same = try await select(editor, "核对图表标题")
                    checks["switchingThreadsPreservesOtherDraft"] = same["draft"] as? String == draft
                    _ = try await editor.checkPresentationComments(action: "cancel")
                    checks["cancelLeavesSavedDocumentClean"] = !(await editor.workspaceReadback()["dirty"] as? Bool ?? true)
                }
            }
            checks["finalWorkspaceCheckpointCurrent"] = await flushWorkspaceWindows()
        } catch let failure { error = failure.localizedDescription }
        checks["noModelRequests"] = requests == 0
        var report: [String: Any] = ["stage": stage, "checks": checks, "observed": observed, "appPID": getpid(),
                                     "modelRequests": requests, "success": error == nil && checks.values.allSatisfy { $0 }]
        if let error { report["error"] = error }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("presentation-" + stage + ".json"), options: .atomic)
    }
}
