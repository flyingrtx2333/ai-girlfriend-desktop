import AppKit

@MainActor extension AppDelegate {
    func runAgentWikiGenerationCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Actual retained failed Wiki history and real native start/cancel/restart operations. Native preflight runs cancelled before startup; window actions blocked before model transmission. No generated-content quality claim."]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("生成管理检查不调用模型") }
            let origin = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("generation-origin.json"))) as! [String: Any]
            let sourceURL = URL(fileURLWithPath: origin["source"] as! String), sourceBytes = try Data(contentsOf: sourceURL), historical = try JSONDecoder().decode(AgentTaskRecord.self, from: sourceBytes)
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime, let copied = tasks.task(historical.id), let job = copied.wikiJob else { throw PetError("真实 Wiki 会话副本不存在") }; _ = control
            var rejectedRequests = 0; runtime.modelRequestCheck = { rejectedRequests += 1; throw PetError("生成管理检查不得发送模型请求") }
            let fm = FileManager.default, files = try AgentFiles(workspace: copied.workspace), index = try AgentProjectIndex(workspace: copied.workspace, storage: tasks.directory)
            let indexed = try await index.run(paths: nil)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let originalMessages = try encoder.encode(historical.messages), originalReceipts = try encoder.encode(historical.modelReceipts), originalPlan = job.plan
            checks["actualFailedHistoryAndReceiptsCopiedIntact"] = try encoder.encode(copied.messages) == originalMessages && encoder.encode(copied.modelReceipts) == originalReceipts && historical.messages.count == 51 && historical.modelReceipts?.count == 30
            checks["actualCopiedSourcesMatchFrozenRevision"] = indexed.index.revision == copied.wikiRevision
            let initial = try AgentWiki.generationState(store: tasks, runtime: runtime, sourceID: copied.id, language: job.language)
            checks["failedRealTaskOffersResumeInSameScope"] = initial.taskID == copied.id && initial.action == "resume"
            checks["otherLanguageCannotResumeThisTask"] = try AgentWiki.generationState(store: tasks, runtime: runtime, sourceID: copied.id, language: "en").action == "generate"
            let configFile = try files.resolve(AgentWikiPlan.configurationPath), config = try files.readData(configFile, maximum: 128_000)
            try files.writeData(config + Data("\n# Actual local configuration edit after original task started\n".utf8), to: configFile)
            let resumed = try AgentWiki.resumeGeneration(store: tasks, runtime: runtime, sourceID: copied.id, language: job.language, expectedID: copied.id)
            checks["resumeStartsSameNativeTaskWithFrozenPlan"] = resumed == copied.id && runtime.isExecuting(copied.id) && tasks.task(copied.id)?.status == .running && tasks.task(copied.id)?.wikiJob?.plan == originalPlan && tasks.task(copied.id)?.wikiJob?.configurationHash == job.configurationHash
            try AgentWiki.pauseGeneration(store: tasks, runtime: runtime, sourceID: copied.id, language: job.language, expectedID: copied.id)
            checks["pauseCancelsActualRuntimeAndRetainsProgress"] = try !runtime.isRunning(copied.id) && tasks.task(copied.id)?.status == .stopped && tasks.task(copied.id)?.wikiJob?.root == job.root && encoder.encode(tasks.task(copied.id)?.knowledgeReads) == encoder.encode(copied.knowledgeReads)
            await wait(0.02)
            let paused = tasks.task(copied.id)!
            checks["originalMessagesAndReceiptsSurviveResumePause"] = try encoder.encode(Array(paused.messages.prefix(historical.messages.count))) == originalMessages && encoder.encode(paused.modelReceipts) == originalReceipts && paused.messages.count == historical.messages.count + 1
            checks["cancelBeforeStartupMakesNoModelAttempt"] = rejectedRequests == 0
            do { _ = try AgentWiki.resumeGeneration(store: tasks, runtime: runtime, sourceID: copied.id, language: "en", expectedID: copied.id); checks["wrongLanguageResumeRejected"] = false } catch { checks["wrongLanguageResumeRejected"] = !runtime.isRunning(copied.id) }
            let sourceFile = try files.resolve("README.md"), beforeSource = try files.readData(sourceFile, maximum: 512_000)
            try files.writeData(beforeSource + Data("\nActual source edit for resume conflict check\n".utf8), to: sourceFile)
            do { _ = try AgentWiki.resumeGeneration(store: tasks, runtime: runtime, sourceID: copied.id, language: job.language, expectedID: copied.id); checks["changedReadSourceCannotResumeOldEvidence"] = false } catch { checks["changedReadSourceCannotResumeOldEvidence"] = error.localizedDescription.contains("源码或索引已变化") && !runtime.isRunning(copied.id) }
            try files.writeData(beforeSource, to: sourceFile)
            let preview = try AgentWiki.previewRegeneration(store: tasks, runtime: runtime, sourceID: copied.id, language: job.language), count = tasks.tasks.count
            let head = try files.resolve(".git/HEAD"), headBytes = try files.readData(head, maximum: 4096)
            try files.writeData(Data("ref: refs/heads/wiki-management-other\n".utf8), to: head)
            do { _ = try AgentWiki.regenerate(preview, store: tasks, runtime: runtime, sourceID: copied.id); checks["changedBranchCannotRegenerateOldPreview"] = false } catch { checks["changedBranchCannotRegenerateOldPreview"] = tasks.tasks.count == count && !runtime.isRunning(copied.id) }
            try files.writeData(headBytes, to: head)
            let previewConfig = try files.readData(configFile, maximum: 128_000); try files.writeData(previewConfig + Data("# Configuration changed during confirmation\n".utf8), to: configFile)
            do { _ = try AgentWiki.regenerate(preview, store: tasks, runtime: runtime, sourceID: copied.id); checks["staleRegenerationPreviewCannotCreateOrStopTask"] = false } catch { checks["staleRegenerationPreviewCannotCreateOrStopTask"] = tasks.tasks.count == count && tasks.task(copied.id)?.status == .stopped }
            try files.writeData(previewConfig, to: configFile)
            let next = try AgentWiki.regenerate(preview, store: tasks, runtime: runtime, sourceID: copied.id)
            let newTask = tasks.task(next)!
            checks["regenerateUsesNewTaskRootAndCurrentConfiguration"] = try next != copied.id && newTask.wikiJob?.root != job.root && newTask.wikiJob?.configurationHash == preview.configurationHash && newTask.wikiJob?.plan == AgentWikiPlan.load(files: files).plan
            try AgentWiki.pauseGeneration(store: tasks, runtime: runtime, sourceID: copied.id, language: job.language, expectedID: next)
            tasks.update(next) { $0.archived = true }
            await wait(0.02)
            checks["regenerationKeepsPriorHistoryAndPublishedView"] = try encoder.encode(tasks.task(copied.id)!.modelReceipts) == originalReceipts && AgentWiki.plannedManifest(store: tasks, taskID: copied.id, language: job.language) == nil && AgentWiki.pages(workspace: copied.workspace, root: job.root).isEmpty
            checks["newNativeTaskCancelledBeforeModelAttempt"] = rejectedRequests == 0 && !runtime.isWorking
            checks["originalRetainedFailureIsUntouched"] = try Data(contentsOf: sourceURL) == sourceBytes
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 生成管理前置检查未通过") }
            guard let records = control.prepareMarkdownCheck(taskID: copied.id, section: 6, value: ".bluefatfish/wiki/index.md") else { throw PetError("Wiki 窗口未打开") }
            let binary = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": binaryHash, "taskID": copied.id, "workspace": files.root.path, "configuration": configFile.path, "originalMessages": historical.messages.count, "originalReceipts": historical.modelReceipts?.count ?? 0, "checks": checks, "modelsCalled": false], "wiki-generation-ui-ready.json")
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-wiki-generation-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-wiki-generation-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; records.refreshLiveRecords(copied.id); var state = await records.markdownEditingReadback(); state["appPID"] = getpid(); state["tasks"] = tasks.tasks.filter { $0.kind == "wiki" }.map { ["id": $0.id, "archived": $0.archived, "status": $0.status.rawValue, "root": $0.wikiJob?.root ?? "", "language": $0.wikiJob?.language ?? ""] }; try write(state, "native-wiki-generation-" + name + ".json")
                }; await wait(0.25)
            }
            runtime.stopAll()
            if let data = try? Data(contentsOf: output.appendingPathComponent("wiki-generation-ui-acceptance.json")), let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], let observed = ui["checks"] as? [String: Bool] { report["uiValidated"] = ui["appPID"] as? Int == Int(getpid()) && ui["binaryHash"] as? String == binaryHash && !observed.isEmpty && observed.values.allSatisfy { $0 }; report["ui"] = ui }
            let after = tasks.task(copied.id)!
            checks["finalOriginalHistoryReceiptsAndSourceRetained"] = try encoder.encode(Array(after.messages.prefix(historical.messages.count))) == originalMessages && encoder.encode(after.modelReceipts) == originalReceipts && Data(contentsOf: sourceURL) == sourceBytes
            checks["noModelReceiptAddedToAnyTask"] = tasks.tasks.compactMap { tasks.task($0.id) }.filter { $0.id != copied.id }.allSatisfy { ($0.modelReceipts ?? []).isEmpty }
            report["appPID"] = getpid(); report["binaryHash"] = binaryHash; report["rejectedRequestAttempts"] = rejectedRequests
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "wiki-generation-report.json")
    }
}
