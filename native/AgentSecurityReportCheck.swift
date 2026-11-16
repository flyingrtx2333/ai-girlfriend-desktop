import AppKit

@MainActor extension AppDelegate {
    func runSecurityReportCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], result: [String: Any] = [:], requests = 0
        var cleanupReview: AgentGitWindow?
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime, let owner = control.window else { throw PetError("任务窗口不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("安全报告界面验收不调用模型") }
            let git = try await prepareCodeSecurityCheck(output, tasks: tasks)
            let segment = String(repeating: "长目录", count: 12)
            let longPath = (0..<3).map { "\($0)-" + segment }.joined(separator: "/") + "/" + String(repeating: "长文件", count: 12) + ".js"
            let longFile = git.files.root.appendingPathComponent(longPath)
            try FileManager.default.createDirectory(at: longFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try git.files.writeData(Data("const result = eval(input);\n".utf8), to: longFile, permissions: 0o600)
            let report = try await git.checkCodeSecurity(source: .uncommitted, requested: ["00-transport.js", longPath, "binary.bin", "alias.js"])
            guard let longRow = report.findings.firstIndex(where: { $0.path == longPath }), let skipped = report.skipped.first else { throw PetError("真实长路径或跳过结果缺失") }
            tasks.update(git.taskID) { $0.draft = "保留安全报告验收的任务草稿。" }
            control.showAgentTask(git.taskID); control.showAgentGit()
            guard let review = control.taskWorkspace.currentController as? AgentGitWindow else { throw PetError("Git 未进入任务工作区") }
            cleanupReview = review
            await review.checkWorkspace(path: "00-transport.js", message: "")
            guard let reviewContent = review.pageContentView,
                  let commit = views(reviewContent).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Git 提交说明" }),
                  owner.makeFirstResponder(commit), let editor = commit.currentEditor() as? NSTextView else { throw PetError("提交说明编辑器不可用") }
            editor.string = "保留安全报告验收的提交说明"
            await review.checkWorkspace(action: "refresh")
            checks["refreshPreservesLiveCommitFieldEditing"] = review.workspaceReadback()["draft"] as? String == "保留安全报告验收的提交说明"
            var located: AgentSecurityFinding?
            let page = AgentCodeSecurityWindow(report: report, onLocate: { located = $0 }, onFix: { _ in throw PetError("保留报告的公开写入失败") })
            review.presentSettingsChild(page)
            guard let content = page.pageContentView, let table = views(content).compactMap({ $0 as? NSTableView }).first else { throw PetError("安全报告未嵌入") }
            func settle() async {
                owner.contentView?.layoutSubtreeIfNeeded(); page.pageDidLayout(); owner.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(60))
            }
            func button(_ title: String, in page: AgentSettingsPageController) throws -> NSButton {
                guard let content = page.pageContentView, let button = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw PetError("缺少安全报告操作：" + title) }; return button
            }
            for (sizeName, size) in [("wide", NSSize(width: 1320, height: 800)), ("narrow", NSSize(width: 780, height: 540))] {
                owner.setContentSize(size)
                for look in [NSAppearance.Name.aqua, .darkAqua] {
                    owner.appearance = NSAppearance(named: look); table.selectRowIndexes(IndexSet(integer: longRow), byExtendingSelection: false); await settle()
                    let r = page.workspaceReadback(), key = sizeName + "-" + look.rawValue
                    let widths = r["columnWidths"] as? [Double] ?? [], viewport = r["tableViewport"] as? [Double] ?? []
                    let actions = r["actions"] as? [[String: Any]] ?? []
                    checks[key + "-usesActualTaskWindow"] = r["usesTaskWindow"] as? Bool == true && r["nativeSheet"] as? Bool == false
                    checks[key + "-columnsFitWithoutHorizontalScrolling"] = widths.count == 3 && viewport.count == 2 && abs(widths.reduce(0, +) - viewport[0]) < 1 && (r["tableWidth"] as? Double ?? 0) <= viewport[0] + 1
                    checks[key + "-allActionsRemainVisible"] = !actions.isEmpty && actions.allSatisfy { $0["inside"] as? Bool == true && ($0["visibleHeight"] as? Double ?? 0) >= 27 }
                    checks[key + "-fullFindingDetailsRetained"] = (r["detail"] as? String)?.contains(longPath + ":1") == true && (r["detail"] as? String)?.contains(report.findings[longRow].advice) == true
                    checks[key + "-taskAndCommitDraftsPreserved"] = control.gitWorkspaceReadback()["draft"] as? String == "保留安全报告验收的任务草稿。" && review.workspaceReadback()["draft"] as? String == "保留安全报告验收的提交说明"
                    result[key] = r
                }
            }
            guard let detail = views(content).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "处理建议" }) else { throw PetError("缺少可选择的报告详情") }
            detail.scrollRangeToVisible(NSRange(location: max(0, detail.string.utf16.count - 1), length: 1)); await settle()
            let scrolled = page.workspaceReadback(), origin = scrolled["detailOrigin"] as? [Double] ?? []
            checks["longDetailsActuallyScroll"] = origin.count == 2 && origin[1] > 0 && detail.isSelectable && !detail.isEditable
            table.selectRowIndexes(IndexSet(integer: report.findings.count), byExtendingSelection: false); await settle()
            let skippedState = page.workspaceReadback()
            checks["skippedPathAndFullReasonAreReadable"] = skippedState["detail"] as? String == skipped.path + "\n" + skipped.reason
            checks["changingSelectionResetsDetailScroll"] = (skippedState["detailOrigin"] as? [Double])?.last == 0
            checks["skippedResultCannotLocateOrFix"] = try !button("定位差异", in: page).isEnabled && button("启用证书校验…", in: page).isHidden
            let clipboard = NSPasteboard.general
            let previous = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy
            }
            defer { clipboard.clearContents(); clipboard.writeObjects(previous) }
            try button("复制位置", in: page).performClick(nil)
            checks["copySkippedResultUsesFullPath"] = clipboard.string(forType: .string) == skipped.path
            try button("返回审阅", in: page).performClick(nil)
            checks["returnKeepsSameReviewAndDraft"] = control.taskWorkspace.currentController === review && review.workspaceReadback()["draft"] as? String == "保留安全报告验收的提交说明"

            let semanticGit = try await prepareSemanticSecurityCheck(output, tasks: tasks)
            let semantic = try await semanticGit.checkCodeSecurity(source: .uncommitted, requested: ["api.ts"], mode: .semantic)
            guard let first = semantic.findings.first, let source = first.trace?.first else { throw PetError("真实语义数据流缺失") }
            control.showAgentTask(semanticGit.taskID); control.showAgentGit()
            guard let semanticReview = control.taskWorkspace.currentController as? AgentGitWindow else { throw PetError("语义报告的 Git 未载入") }
            let semanticPage = AgentCodeSecurityWindow(report: semantic, onLocate: { located = $0 }, onFix: nil)
            semanticReview.presentSettingsChild(semanticPage); owner.contentView?.layoutSubtreeIfNeeded(); semanticPage.pageDidLayout()
            guard let semanticContent = semanticPage.pageContentView, let flow = views(semanticContent).compactMap({ $0 as? NSPopUpButton }).first else { throw PetError("缺少真实数据流位置") }
            flow.selectItem(at: 0); if let action = flow.action { NSApp.sendAction(action, to: flow.target, from: flow) }
            checks["traceSelectionUpdatesFullReadableLocation"] = (semanticPage.workspaceReadback()["detail"] as? String)?.hasPrefix("\(source.path):\(source.line)\n") == true
            try button("复制位置", in: semanticPage).performClick(nil)
            checks["traceCopyMatchesSelectedSource"] = clipboard.string(forType: .string) == "\(source.path):\(source.line)"
            try button("定位差异", in: semanticPage).performClick(nil)
            checks["locateReturnsBeforeDeliveringSelectedTrace"] = located?.path == source.path && located?.line == source.line && control.taskWorkspace.currentController === semanticReview

            let clean = try await git.checkCodeSecurity(source: .uncommitted, requested: ["empty.md"])
            control.showAgentTask(git.taskID)
            let cleanPage = AgentCodeSecurityWindow(report: clean, onLocate: { _ in }, onFix: nil)
            review.presentSettingsChild(cleanPage); owner.contentView?.layoutSubtreeIfNeeded(); cleanPage.pageDidLayout()
            let empty = cleanPage.pageContentView.map(views)?.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "settings-list-empty" }
            checks["cleanReportHasVisibleResultInsteadOfBlankTable"] = clean.findings.isEmpty && clean.skipped.isEmpty && empty?.stringValue == "未发现匹配项" && empty?.isHidden == false
            if let empty, let root = cleanPage.pageContentView,
               let table = views(root).compactMap({ $0 as? NSTableView }).first,
               let list = table.enclosingScrollView, let header = table.headerView {
                root.layoutSubtreeIfNeeded()
                let frame = empty.convert(empty.bounds, to: list)
                checks["cleanResultFitsBelowTableHeader"] = list.contentView.frame.contains(frame) && !header.convert(header.bounds, to: list).intersects(frame)
            } else { checks["cleanResultFitsBelowTableHeader"] = false }
            checks["cleanReportDisablesLocationActions"] = try !button("定位差异", in: cleanPage).isEnabled && !button("复制位置", in: cleanPage).isEnabled
            checks["noModelRequestsOrReceipts"] = requests == 0 && tasks.tasks.allSatisfy { $0.modelReceipts?.isEmpty != false && $0.inputTokens == 0 && $0.outputTokens == 0 }
            try button("返回审阅", in: cleanPage).performClick(nil)
        } catch { result["error"] = error.localizedDescription }
        if let cleanupReview { await cleanupReview.checkWorkspace(message: "") }
        agentRuntime?.stopAll()
        result["checks"] = checks; result["modelRequests"] = requests; result["appPID"] = getpid()
        result["success"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && result["error"] == nil
        try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("security-report-ui-report.json"))
    }
}
