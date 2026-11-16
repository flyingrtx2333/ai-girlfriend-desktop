import AppKit

@MainActor extension AppDelegate {
    func runDependencyReportCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], result: [String: Any] = [:], requests = 0
        var cleanupReview: AgentGitWindow?
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        do {
            ensureAgent()
            guard let tasks = agentStore, let runtime = agentRuntime, let owner = control.window else { throw PetError("任务窗口不可用") }
            runtime.modelRequestCheck = { requests += 1; throw PetError("依赖报告界面验收不调用模型") }
            let git = try await prepareDependencyCheck(output, tasks: tasks, expanded: false)
            let cargoPath = "锁文件/Cargo.lock", cargo = git.files.root.appendingPathComponent(cargoPath)
            let original = try git.files.readData(cargo), index = try Data(contentsOf: git.directory.appendingPathComponent("index"))
            let head = try await git.output(["rev-parse", "HEAD"])
            let segment = String(repeating: "长目录", count: 10)
            let longPath = (0..<3).map { "\($0)-" + segment }.joined(separator: "/") + "/Cargo.lock"
            let vulnerable = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "0.3.47", with: "0.1.44").utf8)
            let longFile = git.files.root.appendingPathComponent(longPath)
            try git.files.writeData(vulnerable, to: longFile, permissions: 0o600)
            try git.files.writeData(Data("invalid Cargo lockfile\n".utf8), to: git.files.root.appendingPathComponent("无效/Cargo.lock"), permissions: 0o600)
            let gitState = try await git.output(["status", "--porcelain=v1", "-z"])
            tasks.update(git.taskID) { $0.draft = "保留依赖报告验收的任务草稿。" }
            control.showAgentTask(git.taskID); control.showAgentGit()
            guard let review = control.taskWorkspace.currentController as? AgentGitWindow else { throw PetError("依赖检查的 Git 未进入任务工作区") }
            cleanupReview = review
            await review.checkWorkspace(path: cargoPath, message: "")
            guard let reviewContent = review.pageContentView,
                  let commit = views(reviewContent).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Git 提交说明" }),
                  owner.makeFirstResponder(commit), let editor = commit.currentEditor() as? NSTextView else { throw PetError("提交说明编辑器不可用") }
            editor.string = "保留依赖报告验收的提交说明。"
            await review.checkWorkspace(action: "dependencies")
            guard let page = control.taskWorkspace.currentController as? AgentDependencyWindow, let content = page.pageContentView,
                  let table = views(content).compactMap({ $0 as? NSTableView }).first,
                  let source = views(content).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "依赖检查来源" }),
                  let scope = views(content).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "依赖检查范围" }) else { throw PetError("依赖报告控件不可用") }
            let reader = try AgentDependencySecurity(store: tasks, taskID: git.taskID, git: git)
            func button(_ title: String, in page: AgentSettingsPageController) throws -> NSButton {
                guard let content = page.pageContentView, let button = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw PetError("缺少依赖报告操作：" + title) }; return button
            }
            func settle() async {
                owner.contentView?.layoutSubtreeIfNeeded(); page.pageDidLayout(); owner.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(60))
            }
            func wait() async throws {
                let deadline = Date().addingTimeInterval(60)
                while page.hasPendingOperation && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                guard !page.hasPendingOperation else { throw PetError("依赖报告验收的本机扫描尚未完成") }
                await settle()
            }
            func scan() async throws { try button("开始检查", in: page).performClick(nil); try await wait() }
            checks["entryPreservesLiveCommitDraft"] = review.workspaceReadback()["draft"] as? String == "保留依赖报告验收的提交说明。"
            try await scan()
            guard let working = reader.previousReport(), let finding = working.findings.first(where: { $0.path == longPath }) else { throw PetError("实际依赖扫描没有产生公开样例发现") }
            checks["wholeWorkingScanShowsRealAdvisory"] = working.source == .working && !working.selectedOnly && working.scannedFiles == 2 && working.packages == 2 && finding.version == "0.1.44" && finding.aliases.contains("CVE-2020-26235") && finding.fixedVersions.contains("0.2.23")
            checks["realInvalidLockfileIsSkipped"] = working.skipped.count == 1 && working.skipped.first?.path == "无效/Cargo.lock"
            for (sizeName, size) in [("wide", NSSize(width: 1320, height: 800)), ("narrow", NSSize(width: 780, height: 540))] {
                owner.setContentSize(size)
                for look in [NSAppearance.Name.aqua, .darkAqua] {
                    owner.appearance = NSAppearance(named: look); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); await settle()
                    let r = page.workspaceReadback(), key = sizeName + "-" + look.rawValue
                    let widths = r["columnWidths"] as? [Double] ?? [], viewport = r["tableViewport"] as? [Double] ?? []
                    let controls = r["controls"] as? [[String: Any]] ?? [], popupFrames = [r["sourceFrame"], r["scopeFrame"]].compactMap { $0 as? [Double] }
                    checks[key + "-usesActualTaskWindow"] = r["usesTaskWindow"] as? Bool == true && r["nativeSheet"] as? Bool == false
                    checks[key + "-columnsFitWithoutHorizontalScrolling"] = widths.count == 3 && viewport.count == 2 && abs(widths.reduce(0, +) - viewport[0]) < 1 && table.enclosingScrollView?.hasHorizontalScroller == false
                    let cell = table.view(atColumn: 1, row: 0, makeIfNecessary: true)
                    let labels = cell.map(views)?.compactMap { $0 as? NSTextField } ?? []
                    let labelsFit = cell.map { cell in labels.allSatisfy { field in
                        guard let parent = field.superview else { return false }
                        let frame = parent.convert(field.alignmentRect(forFrame: field.frame), to: cell)
                        return !field.isEditable && cell.bounds.insetBy(dx: -1, dy: -1).contains(frame) && frame.height >= 12
                    } } ?? false
                    checks[key + "-rowShowsVersionAndAdvisory"] = labels.contains { $0.stringValue == finding.package + " " + finding.version } && labels.contains { $0.stringValue == "CVE-2020-26235" } && labelsFit
                    let detail = r["detail"] as? String ?? ""
                    checks[key + "-fullSelectedDetailsRetained"] = [longPath, "time 0.1.44", "RUSTSEC-2020-0071", "CVE-2020-26235", "CVSS 6.2", "0.2.23", "OSV 公告库"].allSatisfy { detail.contains($0) }
                    checks[key + "-controlsFitAndUseSharedPopupHeight"] = controls.count == 6 && controls.allSatisfy { $0["inside"] as? Bool == true } && popupFrames.count == 2 && popupFrames.allSatisfy { $0.count == 4 && abs($0[3] - 28) < 0.5 }
                    result[key] = r
                }
            }
            guard let detail = views(content).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "依赖漏洞详情" }) else { throw PetError("依赖详情未载入") }
            detail.scrollRangeToVisible(NSRange(location: max(0, detail.string.utf16.count - 1), length: 1)); await settle()
            checks["longDetailsActuallyScrollAndRemainSelectable"] = (page.workspaceReadback()["detailOrigin"] as? [Double])?.last ?? 0 > 0 && detail.isSelectable && !detail.isEditable
            table.selectRowIndexes(IndexSet(integer: working.findings.count), byExtendingSelection: false); await settle()
            checks["skippedReasonIsReadableAndCannotOpenAdvisory"] = try detail.string.contains("无效/Cargo.lock\n" + working.skipped[0].reason) && !button("查看公告", in: page).isEnabled
            scope.selectItem(at: 1); try await scan()
            let clean = page.workspaceReadback(), empty = views(content).first { $0.identifier?.rawValue == "dependency-list-empty" }
            checks["selectedWorkingScopeReturnsActualCleanResult"] = reader.previousReport()?.selectedOnly == true && reader.previousReport()?.source == .working && reader.previousReport()?.findings.isEmpty == true && clean["emptyText"] as? String == "未命中已知公告" && clean["emptyVisible"] as? Bool == true
            if let empty, let list = table.enclosingScrollView, let header = table.headerView {
                let frame = empty.convert(empty.bounds, to: list)
                checks["cleanResultFitsBelowHeaderAndKeepsDatabaseDate"] = list.contentView.frame.contains(frame) && !header.convert(header.bounds, to: list).intersects(frame) && detail.string.contains("检查时间") && detail.string.contains("OSV 公告库")
            } else { checks["cleanResultFitsBelowHeaderAndKeepsDatabaseDate"] = false }
            source.selectItem(at: 1); try await scan()
            checks["stagedSelectionReadsOwnVersionAndAdvisory"] = reader.previousReport()?.source == .staged && reader.previousReport()?.selectedOnly == true && detail.string.contains("time 0.1.44") && detail.string.contains("CVE-2020-26235")
            let start = try button("开始检查", in: page)
            start.performClick(nil)
            checks["busyScanDisablesScopesAndOffersStop"] = page.hasPendingOperation && !source.isEnabled && !scope.isEnabled && start.title == "停止"
            start.performClick(nil); try await wait()
            checks["stopCancelsAndRestoresControls"] = (page.workspaceReadback()["state"] as? String) == "已停止检查" && source.isEnabled && scope.isEnabled && start.title == "开始检查"
            let previous = reader.previousReport()?.created
            let moved = output.appendingPathComponent("dependency-project-moved"), fm = FileManager.default
            try fm.moveItem(at: git.files.root, to: moved)
            defer { if fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: git.files.root.path) { try? fm.moveItem(at: moved, to: git.files.root) } }
            try await scan()
            let status = views(content).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "依赖检查状态" }
            checks["actualWorkspaceErrorKeepsReadableReport"] = status?.textColor == AgentDialogStyle.error && status?.stringValue.isEmpty == false && reader.previousReport()?.created == previous && detail.string.contains("CVE-2020-26235")
            try fm.moveItem(at: moved, to: git.files.root); try await scan()
            checks["retryAfterSourceReturnsUsesActualScanner"] = reader.previousReport()?.created != previous && source.isEnabled && scope.isEnabled && status?.textColor != AgentDialogStyle.error && detail.string.contains("CVE-2020-26235")
            let saved = reader.previousReport()?.created
            try button("返回审阅", in: page).performClick(nil)
            checks["returnPreservesOriginalReviewAndBothDrafts"] = control.taskWorkspace.currentController === review && review.workspaceReadback()["draft"] as? String == "保留依赖报告验收的提交说明。" && control.gitWorkspaceReadback()["draft"] as? String == "保留依赖报告验收的任务草稿。"
            await review.checkWorkspace(action: "dependencies")
            guard let reopened = control.taskWorkspace.currentController as? AgentDependencyWindow else { throw PetError("依赖报告未重新打开") }
            let restored = reopened.workspaceReadback()
            checks["reopenReadsSavedReportWithActualScope"] = (restored["report"] as? [String: Any])?["created"] as? Double == saved?.timeIntervalSince1970 && (restored["state"] as? String)?.hasPrefix("上次 · 暂存区") == true
            try button("返回审阅", in: reopened).performClick(nil)
            let ordinary = output.appendingPathComponent("ordinary-dependency-project")
            try fm.createDirectory(at: ordinary, withIntermediateDirectories: false)
            let ordinaryID = tasks.create(title: "普通文件夹依赖报告", workspace: ordinary.path)
            control.showAgentTask(ordinaryID); control.showAgentGit()
            guard let ordinaryReview = control.taskWorkspace.currentController as? AgentGitWindow else { throw PetError("普通项目审阅不可用") }
            await ordinaryReview.checkWorkspace(action: "dependencies")
            guard let ordinaryPage = control.taskWorkspace.currentController as? AgentDependencyWindow else { throw PetError("普通项目依赖报告不可用") }
            let ordinaryState = ordinaryPage.workspaceReadback()
            checks["ordinaryFolderDisablesUnavailableScopes"] = ordinaryState["source"] as? String == "工作区" && ordinaryState["sourceEnabled"] as? Bool == false && ordinaryState["scope"] as? String == "整个项目" && ordinaryState["scopeEnabled"] as? Bool == false
            try button("返回审阅", in: ordinaryPage).performClick(nil)
            let actualHead = try await git.output(["rev-parse", "HEAD"]), actualState = try await git.output(["status", "--porcelain=v1", "-z"])
            checks["scanStopFailureAndRetryPreserveWorkspaceAndGit"] = try original == git.files.readData(cargo) && vulnerable == git.files.readData(longFile) && Data(contentsOf: git.directory.appendingPathComponent("index")) == index && actualHead == head && actualState == gitState
            checks["noModelRequestsOrReceipts"] = requests == 0 && tasks.tasks.allSatisfy { $0.modelReceipts?.isEmpty != false && $0.inputTokens == 0 && $0.outputTokens == 0 }
        } catch { result["error"] = error.localizedDescription }
        if let cleanupReview { await cleanupReview.checkWorkspace(message: "") }
        agentRuntime?.stopAll()
        result["checks"] = checks; result["modelRequests"] = requests; result["appPID"] = getpid()
        result["success"] = checks.count == 37 && checks.values.allSatisfy { $0 } && result["error"] == nil
        try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("dependency-report-ui-report.json"))
    }
}
