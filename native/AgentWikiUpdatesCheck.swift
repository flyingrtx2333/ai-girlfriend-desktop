import AppKit

@MainActor extension AppDelegate {
    func runAgentWikiUpdatesCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Actual committed repository snapshots, manually imported source-excerpt Wiki pages, actual Git commits and filesystem events. Model requests always rejected before transmission. No AI generation-quality claim."]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("增量维护检查不调用模型") }
            let origin = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("updates-origin.json"))) as! [String: Any], stages = origin["stages"] as! [String: [String: String]]
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            var blocked = 0; runtime.modelRequestCheck = { blocked += 1; throw PetError("Wiki 维护检查禁止发送模型请求") }
            let workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path), fm = FileManager.default
            let owner = tasks.create(title: "Wiki 增量维护", workspace: workspace.path, mode: .agent); tasks.update(owner) { $0.draft = "保留的项目任务草稿" }
            let git = try AgentWiki.updateGit(store: tasks, taskID: owner), base = try await AgentWiki.cleanCommit(store: tasks, taskID: owner), initial = try await tasks.knowledgeCards.refreshIndex(tasks.task(owner)!)
            func apply(_ stage: String) async throws -> String {
                guard let entries = stages[stage] else { throw PetError("实际源码阶段缺失") }
                let source = try AgentFiles(workspace: output.appendingPathComponent("stages/" + stage).path)
                for (name, hash) in entries { let data = try source.readData(source.resolve(name), maximum: 512_000); guard AgentFiles.hash(data) == hash else { throw PetError("实际源码副本已变化") }; try files.writeData(data, to: files.resolve(name)) }
                let added = try await git.run(["add", "--"] + entries.keys.sorted(), write: true); guard !added.failed else { throw PetError(added.text) }
                let committed = try await git.run(["commit", "--quiet", "-m", "Actual source snapshot: " + stage], write: true); guard !committed.failed else { throw PetError(committed.text) }
                return try await AgentWiki.cleanCommit(store: tasks, taskID: owner)
            }
            func call(_ id: String, _ name: String, _ args: [String: Any]) async throws -> AgentToolResult { try await AgentTools(store: tasks, taskID: id).execute(AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self)), gitDirectory: git.directory.path) }
            func setOptions(_ options: AgentWikiMaintenanceOptions, language: String = "zh") throws { let snapshot = try AgentWiki.maintenance(store: tasks, workspace: workspace.path, language: language); try AgentWiki.setMaintenance(store: tasks, sourceID: owner, language: language, options: options, expected: snapshot.signature) }
            let defaults = try AgentWiki.maintenance(store: tasks, workspace: workspace.path, language: "zh")
            checks["automationDefaultsOffAndRealCommitPresent"] = !defaults.options.autoUpdate && !defaults.options.autoExport && base == origin["baseCommit"] as? String && AgentWiki.validCommit(base)
            checks["original8192And512ConfigurationRetained"] = store.preferences.contextLimit == 8192 && store.preferences.outputLimit == 512
            let shared = try AgentWiki.sharingPath("zh"), root = shared + "/content"
            var sourceHashes: [String: String] = [:], documents: [AgentWikiTransfer.Document] = []
            for (name, title, source) in [("overview.md", "项目入口", "README.md"), ("native.md", "原生模型", "native/AgentWiki.swift")] {
                let data = try files.readData(files.resolve(source), maximum: 512_000), excerpt = String(decoding: data, as: UTF8.self).components(separatedBy: "\n").prefix(4).joined(separator: "\n")
                let prefix = "../../../../", text = "# " + title + "\n\n```text\n" + excerpt + "\n```\n\n[实际源码:1-4](" + prefix + source + "#L1-L4)\n" + (name == "overview.md" ? "\n[原生模型](native.md)\n" : "")
                let bytes = Data(text.utf8); try files.writeData(bytes, to: files.resolve(root + "/" + name)); sourceHashes[source] = AgentFiles.hash(data); documents.append(.init(file: name, title: title, sha256: AgentFiles.hash(bytes), parent: name == "overview.md" ? nil : "overview.md"))
            }
            var transfer = AgentWikiTransfer(branch: try tasks.knowledgeCards.scope(tasks.task(owner)!).branch, language: "zh", sourceRevision: initial.index.revision, sourceHashes: sourceHashes, documents: documents, origin: "manual"); transfer.sourceCommit = base
            try files.writeData(JSONEncoder().encode(transfer), to: files.resolve(shared + "/" + AgentWiki.transferMetadata))
            let imported = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh"); try await AgentWiki.importWiki(imported, store: tasks, taskID: owner)
            let published = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")!, originalPages = try AgentWiki.view(store: tasks, taskID: owner, language: "zh").pages
            let originalData = try Dictionary(uniqueKeysWithValues: originalPages.map { ($0.path, try files.readData(files.resolve($0.path), maximum: 512_000)) })
            checks["manualImportRetainsActualGitBaseline"] = published.sourceCommit == base && published.origin == "import" && originalPages.count == 2
            do { _ = try await AgentWiki.previewUpdate(store: tasks, runtime: runtime, sourceID: owner, language: "zh"); checks["sameCommitDoesNotCreateUpdate"] = false } catch { checks["sameCommitDoesNotCreateUpdate"] = error.localizedDescription.contains("无需重复") }
            let head = try await apply("next"), preview = try await AgentWiki.previewUpdate(store: tasks, runtime: runtime, sourceID: owner, language: "zh")
            checks["actualCommittedSourceDiffIsFrozen"] = head != base && preview.baseCommit == base && preview.commit == head && preview.diff.contains("sourceCommit") && preview.changedPaths.contains("native/AgentWiki.swift")
            let readme = try files.resolve("README.md"), readmeData = try files.readData(readme, maximum: 512_000)
            try files.writeData(readmeData + Data("\nUncommitted acceptance edit\n".utf8), to: readme)
            let beforeStale = tasks.tasks.count
            do { _ = try await AgentWiki.startUpdate(preview, store: tasks, runtime: runtime, sourceID: owner); checks["dirtyConfirmationCannotCreateTask"] = false } catch { checks["dirtyConfirmationCannotCreateTask"] = tasks.tasks.count == beforeStale }
            try files.writeData(readmeData, to: readme)
            let id = try await AgentWiki.startUpdate(preview, store: tasks, runtime: runtime, sourceID: owner); runtime.cancel(id)
            let task = tasks.task(id)!, job = task.wikiJob!, paths = try job.plan.paths(root: job.root), overview = paths["项目入口"]!, native = paths["原生模型"]!
            checks["updateCreatesIndependentFrozenDraft"] = job.update?.commit == head && job.update?.baseCommit == base && job.plan == preview.plan && job.root != published.root && task.wikiRevision == preview.revision
            checks["unaffectedPageRetainsWithoutFabricatedModelReadOrWrite"] = try AgentWiki.retainedPage(task, path: overview, hash: files.fileHash(files.resolve(overview), maximum: 256_000)) && task.changes.isEmpty && (task.knowledgeReads ?? [:]).isEmpty
            checks["changedSourcePageCannotBeSilentlyRetained"] = try !AgentWiki.retainedPage(task, path: native, hash: files.fileHash(files.resolve(native), maximum: 256_000))
            do { _ = try AgentWiki.validatePlanned(task); checks["unreadCommitDiffBlocksCompletion"] = false } catch { checks["unreadCommitDiffBlocksCompletion"] = error.localizedDescription.contains("读完本次提交差异") }
            var offset = 0
            while offset < job.update!.diff.count {
                let result = try await call(id, "plan_wiki", ["changes": true, "content_offset": offset, "content_limit": 1600]), body = result.text.components(separatedBy: "\n").dropFirst(2).dropLast().joined(separator: "\n")
                guard !body.isEmpty, body == String(job.update!.diff.dropFirst(offset).prefix(body.count)), AgentContext.estimate(body) <= 400 else { throw PetError("实际提交差异分页与原件或上下文预算不一致") }; offset += body.count
            }
            let copiedHash = try files.fileHash(files.resolve(native), maximum: 256_000)
            do { _ = try await call(id, "plan_wiki", ["confirm_page": native, "expected_hash": copiedHash]); checks["confirmRetainedPageRequiresActualReadback"] = false } catch { checks["confirmRetainedPageRequiresActualReadback"] = true }
            _ = try await call(id, "read_file", ["path": "native/AgentWiki.swift", "offset": 1, "limit": 4]); _ = try await call(id, "read_file", ["path": native, "limit": 200])
            _ = try await call(id, "plan_wiki", ["confirm_page": native, "expected_hash": copiedHash])
            checks["unchangedFactsCanBeReconfirmedFromActualReadsWithoutFakeWrite"] = try AgentWiki.validatePlanned(tasks.task(id)!).hashes.count == 2 && tasks.task(id)!.changes.isEmpty && (tasks.task(id)!.modelReceipts ?? []).isEmpty
            let oldPage = originalPages.first!.path, oldBytes = originalData[oldPage]!
            try files.writeData(oldBytes + Data("\nActual manual edit during update\n".utf8), to: files.resolve(oldPage))
            do { try AgentWiki.requireUpdateBase(tasks.task(id)!); checks["concurrentManualWikiEditBlocksReplacement"] = false } catch { checks["concurrentManualWikiEditBlocksReplacement"] = error.localizedDescription.contains("原 Wiki") }
            try files.writeData(oldBytes, to: files.resolve(oldPage)); try AgentWiki.requireUpdateBase(tasks.task(id)!)
            try await AgentWiki.finalizePlanned(store: tasks, taskID: id)
            checks["noPublicationWithoutRealModelCompletion"] = try AgentWiki.plannedManifest(store: tasks, taskID: owner, language: "zh")?.taskID == published.taskID && !tasks.task(id)!.hasConfirmedWikiCompletion
            var options = defaults.options; options.autoUpdate = true; try setOptions(options)
            await tasks.wikiMaintenance.updateIfNeeded(workspace: files.root.path)
            checks["pausedOrFailedCommitIsNotAutomaticallyRetried"] = tasks.tasks.filter { $0.kind == "wiki" }.count == 1
            let third = try await apply("third"), deadline = Date().addingTimeInterval(12)
            while Date() < deadline && !tasks.tasks.contains(where: { $0.wikiJob?.update?.commit == third }) { await wait(0.1) }
            let automatic = tasks.tasks.first { $0.wikiJob?.update?.commit == third }
            if let automatic { runtime.cancel(automatic.id) }
            checks["actualFilesystemCommitStartsOneAutomaticUpdate"] = automatic != nil && tasks.tasks.filter { $0.wikiJob?.update?.commit == third }.count == 1
            await tasks.wikiMaintenance.updateIfNeeded(workspace: files.root.path)
            checks["automaticCommitDoesNotDuplicateOnRepeatedEvents"] = tasks.tasks.filter { $0.wikiJob?.update?.commit == third }.count == 1
            options.autoUpdate = false; try setOptions(options); _ = try await apply("fourth"); let stoppedCount = tasks.tasks.filter { $0.kind == "wiki" }.count
            await wait(2.3)
            checks["disableRemovesWatcherAndStopsFutureAutomaticTasks"] = tasks.tasks.filter { $0.kind == "wiki" }.count == stoppedCount && (tasks.wikiMaintenance.checkState["watching"] as? [String])?.isEmpty == true
            let longPreview = try await AgentWiki.previewUpdate(store: tasks, runtime: runtime, sourceID: owner, language: "zh"), boundedID = try await AgentWiki.startUpdate(longPreview, store: tasks, runtime: runtime, sourceID: owner); runtime.cancel(boundedID)
            guard let cjkStart = longPreview.diff.range(of: "在「记录")?.lowerBound else { throw PetError("真实提交差异缺少已保留的中文项目文档") }
            let cjkOffset = longPreview.diff.distance(from: longPreview.diff.startIndex, to: cjkStart), result = try await call(boundedID, "plan_wiki", ["changes": true, "content_offset": cjkOffset, "content_limit": 1600]), body = result.text.components(separatedBy: "\n").dropFirst(2).dropLast().joined(separator: "\n")
            checks["actualChineseCommitDiffFitsBoundedContextWithExactNextOffset"] = !body.isEmpty && body == String(longPreview.diff.dropFirst(cjkOffset).prefix(body.count)) && AgentContext.estimate(body) <= 400 && result.text.contains("next_offset=\(cjkOffset + body.count)")
            let stale = try AgentWiki.maintenance(store: tasks, workspace: workspace.path, language: "zh"); options.autoExport = true; try setOptions(options)
            do { try AgentWiki.setMaintenance(store: tasks, sourceID: owner, language: "zh", options: stale.options, expected: stale.signature); checks["staleSettingsCannotOverwriteNewOptions"] = false } catch { checks["staleSettingsCannotOverwriteNewOptions"] = try AgentWiki.maintenance(store: tasks, workspace: workspace.path, language: "zh").options.autoExport }
            let citation = try AgentWiki.citation(store: tasks, workspace: workspace.path); try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: false, expected: citation.signature)
            checks["citationSavePreservesAutomationAndOtherLanguageDefaults"] = try AgentWiki.maintenance(store: tasks, workspace: workspace.path, language: "zh").options.autoExport && !AgentWiki.maintenance(store: tasks, workspace: workspace.path, language: "en").options.autoExport
            let restoreCitation = try AgentWiki.citation(store: tasks, workspace: workspace.path); try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: true, expected: restoreCitation.signature)
            await tasks.wikiMaintenance.published(taskID: owner, language: "zh", expectedID: published.taskID)
            let exported = try await AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: "zh")
            checks["automaticExportWritesActualPagesAndRetainsBaseline"] = exported.metadata.documents.count == 2 && exported.metadata.sourceCommit == base && tasks.task(owner)!.events.contains { $0.title == "Wiki 已自动导出" && $0.status == "completed" }
            let exportedPage = try files.resolve(root + "/overview.md"), exportedBytes = try files.readData(exportedPage, maximum: 512_000), edited = exportedBytes + Data("\nActual external edit\n".utf8)
            try files.writeData(edited, to: exportedPage); await tasks.wikiMaintenance.published(taskID: owner, language: "zh", expectedID: published.taskID)
            checks["automaticExportPreservesExternalFileEdits"] = try files.readData(exportedPage, maximum: 512_000) == edited && tasks.wikiMaintenance.notice(workspace: files.root.path, language: "zh").contains("未完成")
            try files.writeData(exportedBytes, to: exportedPage)
            options.autoExport = false; try setOptions(options); tasks.wikiMaintenance.stop()
            checks["allOriginalPublishedPagesAndComposerDraftRemainIntact"] = try originalData.allSatisfy { try files.readData(files.resolve($0.key), maximum: 512_000) == $0.value } && tasks.task(owner)?.draft == "保留的项目任务草稿"
            checks["noModelReceiptsFromNativeOperations"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("Wiki 增量维护前置检查未通过") }
            guard let records = control.prepareMarkdownCheck(taskID: owner, section: 6, value: originalPages.first!.path) else { throw PetError("Wiki 窗口未打开") }
            let binary = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": binaryHash, "taskID": owner, "workspace": files.root.path, "baseCommit": base, "head": try await AgentWiki.cleanCommit(store: tasks, taskID: owner), "publishedID": published.taskID, "checks": checks, "modelsCalled": false], "wiki-updates-ui-ready.json")
            var capture = "", advanced = false; let uiDeadline = Date().addingTimeInterval(3600)
            while Date() < uiDeadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-wiki-updates-ui").path) {
                if !advanced && fm.fileExists(atPath: output.appendingPathComponent("advance-wiki-commit").path) { advanced = true; let commit = try await apply("fifth"); try write(["commit": commit, "modelsCalled": false], "advanced-wiki-commit.json") }
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-wiki-updates-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil {
                    capture = name; records.refreshLiveRecords(owner); var state = await records.markdownEditingReadback(); state["appPID"] = getpid(); state["service"] = tasks.wikiMaintenance.checkState; state["tasks"] = tasks.tasks.filter { $0.kind == "wiki" }.map { ["id": $0.id, "status": $0.status.rawValue, "commit": $0.wikiJob?.update?.commit ?? ""] }; state["blockedBeforeTransmission"] = blocked; try write(state, "native-wiki-updates-" + name + ".json")
                }; await wait(0.25)
            }
            tasks.wikiMaintenance.stop(); runtime.stopAll()
            if let data = try? Data(contentsOf: output.appendingPathComponent("wiki-updates-ui-acceptance.json")), let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], let observed = ui["checks"] as? [String: Bool] { report["uiValidated"] = ui["appPID"] as? Int == Int(getpid()) && ui["binaryHash"] as? String == binaryHash && !observed.isEmpty && observed.values.allSatisfy { $0 }; report["ui"] = ui }
            checks["finalPublishedPagesAndOriginalDraftUnchanged"] = try originalData.allSatisfy { try files.readData(files.resolve($0.key), maximum: 512_000) == $0.value } && tasks.task(owner)?.draft == "保留的项目任务草稿"
            checks["allRequestsBlockedWithoutAnyModelReceipts"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty }
            report["appPID"] = getpid(); report["binaryHash"] = binaryHash; report["blockedBeforeTransmission"] = blocked
        } catch { report["error"] = error.localizedDescription }
        report["checks"] = checks; report["success"] = report["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true
        try? write(report, "wiki-updates-report.json")
    }
}
