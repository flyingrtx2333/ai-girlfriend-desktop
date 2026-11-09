import AppKit

@MainActor extension AppDelegate {
    func runAgentProjectKnowledgeCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Actual native task creation, shared repository indexing, pause/resume, branch changes, source changes, draft writes and guarded regeneration. Every model transmission rejected before network. Draft inputs quote actual source; no fabricated model completions or published knowledge."]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("协同生成检查不得调用模型") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            var blocked = 0; runtime.modelRequestCheck = { blocked += 1; throw PetError("协同生成验收门禁：禁止发送模型请求") }
            let fm = FileManager.default, workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path), owner = tasks.create(title: "首次项目知识生成", workspace: workspace.path, mode: .agent)
            tasks.update(owner) { $0.draft = "保留的首次生成草稿" }
            let yaml = "version: 1\nrepowiki:\n  notes: [只用实际已读源码]\n  documents:\n    - title: 项目入口\n      goal: 核对实际 README\n    - title: 原生运行时\n      goal: 核对实际原生源码\n      parent: 项目入口\nknowledgecard:\n  notes: [区分实际模块职责，保留源码依据]\n"
            try files.writeData(Data(yaml.utf8), to: files.resolve(AgentWikiPlan.configurationPath))
            func group(_ id: String) throws -> (AgentTaskRecord, AgentTaskRecord) { guard let wiki = tasks.task(id), let cardID = wiki.wikiJob?.knowledgeGeneration?.cardTaskID, let card = tasks.task(cardID) else { throw PetError("实际配套任务不存在") }; return (wiki, card) }
            func call(_ id: String, _ name: String, _ args: [String: Any] = [:]) async throws -> AgentToolResult { let tool = AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)), tools = AgentTools(store: tasks, taskID: id); return try await tools.execute(tool, gitDirectory: tools.gitDirectory(for: tool)) }
            let initial = try AgentWiki.generationState(store: tasks, runtime: runtime, sourceID: owner, language: "zh")
            checks["firstGenerationExplicitlyIncludesWikiAndCards"] = initial.action == "generate" && initial.includesCards && initial.title == "生成 Wiki 与卡片"
            let firstID = try await tasks.projectKnowledge.start(sourceID: owner, language: "zh", runtime: runtime); runtime.cancel(firstID)
            let (wiki, card) = try group(firstID), revision = wiki.wikiRevision!, common = try AgentProjectIndex(workspace: workspace.path, storage: tasks.directory).snapshot()!
            checks["actualTasksShareOneIndexedSourceRevision"] = wiki.id != card.id && revision == common.revision && card.knowledgeJob?.sourceRevision == revision && wiki.wikiJob?.knowledgeGeneration?.revision == revision
            checks["actualGroupLinksAndFrozenNotesPersist"] = card.knowledgeJob?.wikiTaskID == wiki.id && wiki.wikiJob?.plan.knowledgeNotes == card.knowledgeJob?.writingNotes && wiki.wikiJob?.configurationHash == AgentFiles.hash(Data(yaml.utf8))
            checks["parentStopCancelsBothNativeExecutions"] = !runtime.isExecuting(wiki.id) && !runtime.isExecuting(card.id) && [.failed, .stopped].contains(tasks.task(wiki.id)!.status) && [.failed, .stopped].contains(tasks.task(card.id)!.status)
            checks["stoppedGroupOffersSameTaskResume"] = try AgentWiki.generationState(store: tasks, runtime: runtime, sourceID: owner, language: "zh").taskID == firstID && AgentWiki.generationState(store: tasks, runtime: runtime, sourceID: owner, language: "zh").action == "resume"
            try files.writeData(Data(yaml.replacingOccurrences(of: "区分实际模块职责，保留源码依据", with: "核对模块边界和真实约定").utf8), to: files.resolve(AgentWikiPlan.configurationPath))
            let resumed = try await tasks.projectKnowledge.start(sourceID: owner, language: "zh", runtime: runtime); runtime.cancel(resumed)
            checks["resumeRetainsBothIDsAndOriginalConfiguration"] = try resumed == firstID && group(resumed).1.id == card.id && tasks.task(firstID)?.wikiJob?.plan == wiki.wikiJob?.plan && tasks.task(card.id)?.knowledgeJob?.writingNotes == card.knowledgeJob?.writingNotes
            let beforeBranch = blocked, git = try AgentWiki.updateGit(store: tasks, taskID: owner)
            let switched = try await git.run(["checkout", "--quiet", "knowledge-other"], write: true); guard !switched.failed else { throw PetError(switched.text) }
            do { _ = try await tasks.projectKnowledge.resume(firstID, runtime: runtime); checks["otherBranchCannotResumeFrozenGroup"] = false } catch { checks["otherBranchCannotResumeFrozenGroup"] = blocked == beforeBranch && !runtime.isExecuting(firstID) }
            let back = try await git.run(["checkout", "--quiet", "project-knowledge"], write: true); guard !back.failed else { throw PetError(back.text) }
            let source = try files.readData(files.resolve("README.md")), changed = source + Data("\nActual source edit during project knowledge preparation\n".utf8)
            try files.writeData(changed, to: files.resolve("README.md")); let beforeSource = blocked
            do { _ = try await tasks.projectKnowledge.resume(firstID, runtime: runtime); checks["changedActualSourceCannotResumeEitherTask"] = false } catch { checks["changedActualSourceCannotResumeEitherTask"] = blocked == beforeSource && !runtime.isExecuting(card.id) }
            do { _ = try await call(firstID, "index_project"); checks["modelIndexCannotReplaceCommonFrozenRevision"] = false } catch { checks["modelIndexCannotReplaceCommonFrozenRevision"] = tasks.task(firstID)?.wikiRevision == revision }
            try files.writeData(source, to: files.resolve("README.md")); _ = try await tasks.knowledgeCards.refreshIndex(tasks.task(owner)!)
            _ = try await call(firstID, "read_file", ["path": "README.md", "offset": 1, "limit": 4])
            let page = try wiki.wikiJob!.plan.paths(root: wiki.wikiJob!.root)["项目入口"]!, excerpt = String(decoding: source, as: UTF8.self).components(separatedBy: "\n").prefix(4).joined(separator: "\n"), prefix = String(repeating: "../", count: wiki.wikiJob!.root.split(separator: "/").count)
            _ = try await call(firstID, "write_file", ["path": page, "content": "# 实际源码摘录\n\n" + excerpt + "\n\n[README 原文](" + prefix + "README.md#L1-L4)\n"])
            _ = try await call(card.id, "read_project_knowledge", ["configuration": true]); _ = try await call(card.id, "read_file", ["path": "README.md", "offset": 1, "limit": 4])
            _ = try await call(card.id, "save_knowledge_card", ["title": "README 原文", "kind": "architecture", "body": excerpt, "sources": [["path": "README.md", "line": 1, "end_line": 4]]])
            let wikiBytes = try files.readData(files.resolve(page)), draftURL = try tasks.knowledgeCards.draftURL(tasks.task(card.id)!), draftBytes = try Data(contentsOf: draftURL)
            let restarted = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["groupAndActualDraftsSurviveStoreReload"] = try restarted.task(firstID)?.wikiJob?.knowledgeGeneration?.cardTaskID == card.id && restarted.task(card.id)?.knowledgeJob?.wikiTaskID == firstID && restarted.knowledgeCards.drafts(restarted.task(card.id)!).count == 1
            let originalFolder = output.appendingPathComponent("identity-original"), copiedFolder = output.appendingPathComponent("identity-copy")
            try fm.moveItem(at: workspace, to: originalFolder); try fm.copyItem(at: originalFolder, to: workspace)
            do { _ = try tasks.knowledgeCards.validate(tasks.task(card.id)!); checks["replacementDirectoryCannotValidatePairedCards"] = false } catch { checks["replacementDirectoryCannotValidatePairedCards"] = error.localizedDescription.contains("Wiki 与卡片") }
            do { try await AgentWiki.finalizePlanned(store: tasks, taskID: firstID); checks["replacementDirectoryCannotPublishPairedWiki"] = false } catch { checks["replacementDirectoryCannotPublishPairedWiki"] = error.localizedDescription.contains("Wiki 与卡片") }
            try fm.moveItem(at: workspace, to: copiedFolder); try fm.moveItem(at: originalFolder, to: workspace)
            async let englishOne = tasks.projectKnowledge.start(sourceID: owner, language: "en", runtime: runtime)
            async let englishTwo = tasks.projectKnowledge.start(sourceID: owner, language: "en", runtime: runtime)
            let (enOne, enTwo) = try await (englishOne, englishTwo); runtime.cancel(enOne); let english = try group(enOne)
            checks["concurrentInitialClicksCreateOnlyOnePair"] = enOne == enTwo && tasks.tasks.filter { $0.wikiJob?.language == "en" }.count == 1 && tasks.tasks.filter { $0.knowledgeJob?.language == "en" }.count == 1
            checks["languagesHaveIndependentLinkedTasksAndRoots"] = english.0.id != firstID && english.1.id != card.id && english.0.wikiJob?.root != wiki.wikiJob?.root && english.1.knowledgeJob?.language == "en"
            for id in [enOne, english.1.id] { tasks.update(id) { $0.archived = true } }
            let preview = try AgentWiki.previewRegeneration(store: tasks, runtime: runtime, sourceID: owner, language: "zh"), regenerated = try await tasks.projectKnowledge.regenerate(preview, sourceID: owner, runtime: runtime); runtime.cancel(regenerated)
            let fresh = try group(regenerated)
            checks["initialRegenerationCreatesFreshPairWithCurrentNotes"] = fresh.0.id != firstID && fresh.1.id != card.id && fresh.0.wikiJob?.root != wiki.wikiJob?.root && fresh.1.knowledgeJob?.writingNotes == ["核对模块边界和真实约定"]
            checks["regenerationKeepsBothOriginalDraftBytes"] = try files.readData(files.resolve(page)) == wikiBytes && Data(contentsOf: draftURL) == draftBytes
            let stale = try AgentWiki.previewRegeneration(store: tasks, runtime: runtime, sourceID: owner, language: "zh"), beforeStale = tasks.tasks.count, configuration = try files.readData(files.resolve(AgentWikiPlan.configurationPath))
            try files.writeData(configuration + Data("# Actual external edit during confirmation\n".utf8), to: files.resolve(AgentWikiPlan.configurationPath))
            do { _ = try await tasks.projectKnowledge.regenerate(stale, sourceID: owner, runtime: runtime); checks["staleRegenerationConfirmationCreatesNeitherTask"] = false } catch { checks["staleRegenerationConfirmationCreatesNeitherTask"] = tasks.tasks.count == beforeStale }; try files.writeData(configuration, to: files.resolve(AgentWikiPlan.configurationPath))
            let cancellingOwner = tasks.create(title: "取消原生准备", workspace: output.appendingPathComponent("cancellation-workspace").path, mode: .agent), beforeCancellation = tasks.tasks.count, originalChange = runtime.onChange
            var cancelledPreparation = false
            runtime.onChange = { id in originalChange?(id); if id == cancellingOwner, tasks.projectKnowledge.isPreparing(sourceID: cancellingOwner, language: "zh"), !cancelledPreparation { cancelledPreparation = true; runtime.stopAll() } }
            do { _ = try await tasks.projectKnowledge.start(sourceID: cancellingOwner, language: "zh", runtime: runtime); checks["stopAllCancelsActualPendingNativePreparation"] = false } catch { checks["stopAllCancelsActualPendingNativePreparation"] = cancelledPreparation && tasks.tasks.count == beforeCancellation && !tasks.projectKnowledge.isPreparing(sourceID: cancellingOwner, language: "zh") }; runtime.onChange = originalChange
            let budgetOwner = tasks.create(title: "Wiki 单项额度边界", workspace: output.appendingPathComponent("budget-workspace").path, mode: .agent), beforeBudget = tasks.tasks.count
            let wikiOnly = try AgentWiki.start(store: tasks, runtime: runtime, sourceID: budgetOwner, language: "zh"); runtime.cancel(wikiOnly)
            checks["wikiOnlyAcceptanceDoesNotCreateCardOrSharedJob"] = tasks.tasks.count == beforeBudget + 1 && tasks.task(wikiOnly)?.wikiJob?.knowledgeGeneration == nil && !tasks.tasks.contains { $0.knowledgeJob?.sourceTaskID == budgetOwner }
            checks["bothTaskContextsFit8192With512Output"] = try [fresh.0.id, fresh.1.id].allSatisfy { try runtime.contextEstimate($0).parts.reduce(0) { $0 + $1.tokens } + 512 < 8192 }
            checks["nativeInputsDoNotPretendToBeModelOutput"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.messages.contains { $0.role == "assistant" } }
            checks["sourceAndOriginalComposerRemainUnchanged"] = try files.readData(files.resolve("README.md")) == source && tasks.task(owner)?.draft == "保留的首次生成草稿"
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("项目知识协同生成前置检查未通过") }
            guard let records = control.prepareMarkdownCheck(taskID: owner, section: 6) else { throw PetError("Wiki 记录窗口未打开") }
            let binary = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": binaryHash, "taskID": owner, "workspace": workspace.path, "wikiTaskID": regenerated, "cardTaskID": fresh.1.id, "originalWikiTaskID": firstID, "originalCardTaskID": card.id, "sourceRevision": revision, "checks": checks, "blockedRequests": blocked, "modelsCalled": false], "project-knowledge-ui-ready.json")
            var capture = ""; let deadline = Date().addingTimeInterval(3600)
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-project-knowledge-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-project-knowledge-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; records.refreshLiveRecords(owner); var state = await records.markdownEditingReadback(); state["appPID"] = getpid(); state["blockedRequests"] = blocked; state["tasks"] = tasks.tasks.filter(\.isProjectDocumentation).map { metadata -> [String: Any] in let task = tasks.task(metadata.id)!; return ["id": task.id, "kind": task.kind!, "status": task.status.rawValue, "archived": task.archived, "language": task.wikiJob?.language ?? task.knowledgeJob?.language ?? "", "cardTaskID": task.wikiJob?.knowledgeGeneration?.cardTaskID ?? "", "wikiTaskID": task.knowledgeJob?.wikiTaskID ?? "", "revision": task.wikiRevision ?? task.knowledgeJob?.sourceRevision ?? "", "receipts": task.modelReceipts?.count ?? 0] }; try write(state, "native-project-knowledge-" + name + ".json")
                }; await wait(0.25)
            }
            runtime.stopAll()
            if let data = try? Data(contentsOf: output.appendingPathComponent("project-knowledge-ui-acceptance.json")), let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], let observed = ui["checks"] as? [String: Bool] { report["uiValidated"] = ui["appPID"] as? Int == Int(getpid()) && ui["binaryHash"] as? String == binaryHash && !observed.isEmpty && observed.values.allSatisfy { $0 }; report["ui"] = ui }
            checks["finalOriginalDraftsAndSourceRemainIntact"] = try files.readData(files.resolve(page)) == wikiBytes && Data(contentsOf: draftURL) == draftBytes && files.readData(files.resolve("README.md")) == source
            checks["finalNoModelReceiptsOrFabricatedCompletion"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.hasConfirmedWikiCompletion && !$0.hasConfirmedKnowledgeCompletion }
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true; report["appPID"] = getpid(); report["binaryHash"] = binaryHash; report["blockedRequests"] = blocked
        } catch { report["success"] = false; report["error"] = error.localizedDescription; report["checks"] = checks }
        try? write(report, "project-knowledge-report.json")
    }
}
