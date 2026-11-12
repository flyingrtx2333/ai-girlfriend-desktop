import AppKit

@MainActor extension AppDelegate {
    func prepareWikiLifecycleUI(_ output: URL) async throws {
        let original = try await prepareKnowledgePageUI(output)
        guard let tasks = agentStore, let source = tasks.task(original.taskID) else { throw PetError("Wiki 维护项目未初始化") }
        tasks.update(source.id) { $0.permission = .automatic }
        let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("source-input.json"))) as! [String: Any]
        let files = try AgentFiles(workspace: original.workspace.path), git = try AgentWiki.updateGit(store: tasks, taskID: source.id)
        let base = try await AgentWiki.cleanCommit(store: tasks, taskID: source.id)
        guard base == inputs["baseCommit"] as? String else { throw PetError("真实基线提交不一致") }
        _ = try await AgentWiki.exportWiki(store: tasks, taskID: source.id, language: "zh")
        let metadata = try AgentWiki.sharingPath("zh") + "/" + AgentWiki.transferMetadata
        var transfer = try JSONDecoder().decode(AgentWikiTransfer.self, from: files.readData(files.resolve(metadata), maximum: 4_000_000))
        transfer.sourceCommit = base
        try files.writeData(JSONEncoder().encode(transfer), to: files.resolve(metadata))
        try await AgentWiki.importWiki(AgentWiki.previewWikiImport(store: tasks, taskID: source.id, language: "zh"), store: tasks, taskID: source.id)
        for name in ["README.md", "docs/REPO-WIKI.md"] {
            let bytes = try Data(contentsOf: output.appendingPathComponent("next-snapshot/" + name))
            try files.writeData(bytes, to: files.resolve(name))
        }
        for args in [["add", "--", "README.md", "docs/REPO-WIKI.md"], ["commit", "--quiet", "-m", "Actual current public documentation"]] {
            let result = try await git.run(args, write: true); guard !result.failed else { throw PetError(result.text) }
        }
        let head = try await AgentWiki.cleanCommit(store: tasks, taskID: source.id)
        let preview = try await AgentWiki.previewUpdate(store: tasks, runtime: agentRuntime!, sourceID: source.id, language: "zh")
        guard preview.baseCommit == base, preview.commit == head, preview.changedPaths == ["README.md", "docs/REPO-WIKI.md"], preview.diff.count > 500 else { throw PetError("真实公开文档差异不符合验收范围") }
        try Data(preview.diff.utf8).write(to: output.appendingPathComponent("initial-actual-diff.patch"))
        let published = try AgentWiki.plannedManifest(store: tasks, taskID: source.id, language: "zh")!
        let value: [String: Any] = ["taskID": source.id, "standaloneID": original.standaloneID, "workspace": original.workspace.path, "baseCommit": base, "head": head, "publishedID": published.taskID, "initialDiffSHA256": AgentFiles.hash(Data(preview.diff.utf8)), "origin": "Actual historical and current public Git source snapshots; manually imported Wiki", "modelTransmissions": 0]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-lifecycle-fixtures.json"))
        control.showAgentTask(source.id)
    }
    func reopenWikiLifecycleUI(_ output: URL) throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("wiki-lifecycle-fixtures.json"))) as! [String: Any]
        guard let id = value["taskID"] as? String, agentStore?.task(id) != nil else { throw PetError("原 Wiki 维护任务不存在") }; control.showAgentTask(id)
    }
    func runWikiLifecycleCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = [:], blocked = 0
        defer { agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }
            runtime.modelRequestCheck = { blocked += 1; throw PetError("Wiki 页面验收禁止模型传输") }
            try await prepareWikiLifecycleUI(output)
            let f = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("wiki-lifecycle-fixtures.json"))) as! [String: Any]
            let id = f["taskID"] as! String, workspace = f["workspace"] as! String, files = try AgentFiles(workspace: workspace), host = control.knowledgePageHost
            let before = try await AgentWiki.snapshot(tasks, id, "zh"), originalDraft = tasks.task(id)?.draft
            control.showAgentKnowledge(); guard let catalog = host.currentController as? AgentRepoWikiWindow else { throw PetError("知识目录未打开") }
            for _ in 0..<200 { if catalog.checkState["loading"] as? Bool == false { break }; await wait(0.02) }
            checks["catalogTakesKeyboardFocusFromTaskSidebar"] = host.checkState()["focusInPage"] as? Bool == true
            try catalog.checkOpen(workspace: workspace, action: "wiki")
            guard let reader = host.currentController as? AgentRecordWindow else { throw PetError("Wiki 正文未打开") }
            checks["readerTakesKeyboardFocusFromTaskSidebar"] = host.checkState()["focusInPage"] as? Bool == true
            var created: [String] = []
            reader.configureWikiRuntime(runtime) { next in created.append(next); runtime.cancel(next) }
            func inspect(_ name: String, _ review: AgentKnowledgeReviewWindow) {
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    control.window?.appearance = NSAppearance(named: appearance)
                    for (sizeName, size) in [("normal", NSSize(width: 1200, height: 774)), ("narrow", NSSize(width: 800, height: 550))] {
                        control.window?.setContentSize(size); control.window?.contentView?.layoutSubtreeIfNeeded(); let value = host.checkState(); report[name + "-" + theme + "-" + sizeName] = value
                        for (key, value) in value["checks"] as? [String: Bool] ?? [:] { checks[name + "-" + theme + "-" + sizeName + "-" + key] = value }
                    }
                }
                checks[name + "-hostedWithoutFloatingWindow"] = review.window?.isVisible == false && review.presentingWindow === control.window
            }
            guard let update = await reader.checkKnowledgeReview("update") else { throw PetError("增量审阅页未打开") }
            checks["actualPreviewReadBlocksNavigationAndClose"] = update.hasPendingOperation && !host.prepareToLeave() && !reader.prepareWorkspaceNavigation()
            do { try control.requireTaskDeletionAllowed([id]); checks["actualPreviewReadProtectsTaskDeletion"] = false } catch { checks["actualPreviewReadProtectsTaskDeletion"] = true }
            update.close(); checks["closeDuringActualReadKeepsReview"] = host.currentController === update
            await update.checkLoad()
            let actualDiff = try String(contentsOf: output.appendingPathComponent("initial-actual-diff.patch"), encoding: .utf8)
            checks["coloredDiffShowsCompleteActualCommittedPatch"] = update.checkState["showingDiff"] as? Bool == true && update.checkState["text"] as? String == actualDiff
            checks["updateTakesKeyboardFocusFromTaskSidebar"] = update.checkState["focusInReview"] as? Bool == true
            control.show(tab: "chat")
            checks["hiddenReviewFailsVisibilityCheckWithoutLosingPreview"] = (host.checkState()["checks"] as? [String: Bool])?["currentPageIsVisible"] == false && host.currentController === update && update.checkState["text"] as? String == actualDiff
            control.showAgentKnowledge()
            checks["returnToRetainedReviewRestoresVisibilityAndFocus"] = (host.checkState()["checks"] as? [String: Bool])?["currentPageIsVisible"] == true && host.currentController === update && update.checkState["focusInReview"] as? Bool == true
            checks["updateNamesBothActualCommitIDs"] = (update.checkState["items"] as? [[String: Any]])?.first?["detail"] as? String == String((f["baseCommit"] as! String).prefix(8)) + " → " + String((f["head"] as! String).prefix(8))
            inspect("update", update); update.checkSelectItem(1)
            checks["fileListShowsExactCommittedPaths"] = update.checkState["text"] as? String == "README.md\ndocs/REPO-WIKI.md" && update.checkState["showingDiff"] as? Bool == false
            await update.checkReload()
            checks["repreviewRestoresCompleteFirstDiff"] = update.checkState["text"] as? String == actualDiff && update.checkState["showingDiff"] as? Bool == true
            update.checkFocusBody()
            checks["actualDiffBodyCanTakeKeyboardFocus"] = update.checkState["bodyFocused"] as? Bool == true
            await update.checkReload()
            checks["repreviewFromActualDiffBodyKeepsKeyboardFocus"] = update.checkState["focusInReview"] as? Bool == true && update.checkState["text"] as? String == actualDiff && (host.checkState()["checks"] as? [String: Bool])?["currentPageIsVisible"] == true
            update.close(); let canceled = await reader.markdownEditingReadback()
            checks["cancelLeavesPublicationAndOriginalInputUntouched"] = try await AgentWiki.snapshot(tasks, id, "zh").pointer == before.pointer && tasks.task(id)?.draft == originalDraft && created.isEmpty && (canceled["state"] as? String)?.hasPrefix("正在") == false
            guard let stale = await reader.checkKnowledgeReview("update") else { throw PetError("过期审阅页未打开") }; await stale.checkLoad()
            let third = try Data(contentsOf: output.appendingPathComponent("third-snapshot/native/AgentWiki.swift")); try files.writeData(third, to: files.resolve("native/AgentWiki.swift"))
            let git = try AgentWiki.updateGit(store: tasks, taskID: id)
            for args in [["add", "--", "native/AgentWiki.swift"], ["commit", "--quiet", "-m", "Actual public Wiki implementation snapshot"]] {
                let result = try await git.run(args, write: true); guard !result.failed else { throw PetError(result.text) }
            }
            let count = tasks.tasks.count; await stale.checkApply()
            checks["newActualCommitRejectsStaleApplyWithoutCreatingTask"] = created.isEmpty && tasks.tasks.count == count && stale.checkState["applyEnabled"] as? Bool == false && stale.checkState["text"] as? String == ""
            await stale.checkReload(); let reviewedDiff = stale.checkState["text"] as? String
            stale.checkBeginApply()
            checks["actualApplyBlocksNavigationAndClose"] = stale.hasPendingOperation && !host.prepareToLeave() && !reader.prepareWorkspaceNavigation()
            do { try control.requireTaskDeletionAllowed([id]); checks["actualApplyProtectsTaskDeletion"] = false } catch { checks["actualApplyProtectsTaskDeletion"] = true }
            await stale.checkApply()
            let updated = created.last.flatMap(tasks.task)
            checks["applyCreatesActualFrozenUpdateAndReturnsToReader"] = updated?.wikiJob?.update?.diff == reviewedDiff && updated?.wikiJob?.update?.baseCommit == f["baseCommit"] as? String && host.currentController === reader
            checks["updateDraftDoesNotPublishOrReplaceOriginalWiki"] = try await AgentWiki.snapshot(tasks, id, "zh").pointer == before.pointer && updated?.wikiJob?.root != before.root
            guard let regenerate = await reader.checkKnowledgeReview("regenerate") else { throw PetError("重新生成审阅页未打开") }; await regenerate.checkLoad()
            checks["defaultRegenerationPreviewUsesActualDefaultPlan"] = regenerate.checkState["text"] as? String == AgentWikiPlan.initialYAML && (regenerate.checkState["impact"] as? String)?.contains("自动规划") == true
            checks["regenerationTakesKeyboardFocusFromTaskSidebar"] = regenerate.checkState["focusInReview"] as? Bool == true
            regenerate.close()
            let plan = "version: 1\nrepowiki:\n  template: architecture\n  documents:\n    - title: 项目文档\n      goal: 核对公开 README 的实际入口\n    - title: 公开来源\n      goal: 标明实际源码与阅读范围\nknowledgecard:\n  notes: []\n"
            let planURL = try files.literalURL(AgentWikiPlan.configurationPath); try files.writeData(Data(plan.utf8), to: planURL)
            guard let planned = await reader.checkKnowledgeReview("regenerate") else { throw PetError("明确规划的审阅页未打开") }; await planned.checkLoad()
            checks["regenerationShowsCompleteActualConfiguration"] = planned.checkState["text"] as? String == plan && (planned.checkState["impact"] as? String)?.contains("Wiki · 2 页") == true
            inspect("regenerate", planned); planned.checkSelectItem(1)
            checks["regenerationListsActualCurrentDocuments"] = (planned.checkState["text"] as? String)?.components(separatedBy: "\n").count == 2
            let modified = plan + "# 实际确认后的规划变化\n"; try files.writeData(Data(modified.utf8), to: planURL); let beforeRegeneration = created.count
            await planned.checkApply()
            checks["changedConfigurationRejectsRegenerationBeforeNewTask"] = created.count == beforeRegeneration && planned.checkState["applyEnabled"] as? Bool == false && planned.checkState["text"] as? String == ""
            await planned.checkReload(); await planned.checkApply()
            let regenerated = created.last.flatMap(tasks.task)
            checks["regenerationCreatesActualFrozenPlanAndReturns"] = created.count == beforeRegeneration + 1 && regenerated?.wikiJob?.plan.documents?.count == 2 && regenerated?.wikiJob?.configurationHash == AgentFiles.hash(Data(modified.utf8)) && host.currentController === reader
            guard let english = await reader.checkKnowledgeReview("regenerate", language: "en") else { throw PetError("英文未发布审阅页未打开") }; await english.checkLoad()
            checks["unpublishedLanguageClearlyIncludesWikiAndCards"] = (english.checkState["scope"] as? String)?.hasSuffix("English") == true && (english.checkState["impact"] as? String)?.hasPrefix("Wiki 与卡片") == true
            english.close()
            checks["allOriginalWikiAndTaskInputsRemain"] = try await AgentWiki.snapshot(tasks, id, "zh").pointer == before.pointer && before.data.allSatisfy { try files.readData(files.resolve(before.root + "/" + $0.key), maximum: 20_000_000) == $0.value } && tasks.task(id)?.draft == originalDraft && tasks.task(f["standaloneID"] as! String)?.draft == "无工作区任务未发送的草稿。"
            checks["actualJobsHaveNoModelUsageOrPublishedCompletion"] = created.count == 2 && created.compactMap(tasks.task).allSatisfy { !$0.hasConfirmedWikiCompletion && ($0.modelReceipts ?? []).isEmpty && $0.inputTokens == 0 && $0.outputTokens == 0 }
            report["createdTaskIDs"] = created; report["fixture"] = f; host.finish()
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["blockedBeforeTransmission"] = blocked; report["modelTransmissions"] = 0; report["appPID"] = getpid()
        if let binary = Bundle.main.executableURL { report["binaryHash"] = try? AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary) }
        report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("wiki-lifecycle-report.json"))
    }
}
