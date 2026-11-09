import AppKit

@MainActor extension AppDelegate {
    func runAgentKnowledgeEditingCheck(_ output: URL) async {
        var checks: [String: Bool] = [:], report: [String: Any] = ["modelsCalled": false, "uiValidated": false, "boundary": "Actual native YAML parsing, frozen task records, source reads, manual source-excerpt Wiki imports, guarded page edits and version archives. No fabricated model messages or generated-content quality claim."]
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        do {
            guard !CommandLine.arguments.contains("--live-agent") else { throw PetError("项目知识编辑检查不调用模型") }
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("任务未初始化") }; _ = control
            var blocked = 0; runtime.modelRequestCheck = { blocked += 1; throw PetError("知识编辑检查禁止发送模型请求") }
            let fm = FileManager.default, workspace = output.appendingPathComponent("workspace"), files = try AgentFiles(workspace: workspace.path)
            let owner = tasks.create(title: "项目知识配置与编辑", workspace: workspace.path, mode: .agent); tasks.update(owner) { $0.draft = "保留的项目知识草稿" }
            let notes = ["按实际源码区分 Wiki、知识卡片与原生运行时；保留独立职责。", String(repeating: "说明是组织要求，源码才是事实依据。👩🏽‍💻\n", count: 40)]
            let noteYAML = try notes.map { "    - text: " + String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self) }.joined(separator: "\n")
            let yaml = "version: 1\nrepowiki:\n  notes:\n    - 保留真实源码引用\nknowledgecard:\n  notes:\n" + noteYAML + "\n"
            try files.writeData(Data(yaml.utf8), to: files.resolve(AgentWikiPlan.compatiblePath))
            let config = try AgentWikiPlan.load(files: files)
            checks["bothKindsReadFromCompatibleYAMLWithoutWritingIt"] = config.plan.notes == ["保留真实源码引用"] && config.plan.knowledgeNotes == notes && config.path == AgentWikiPlan.compatiblePath && !fm.fileExists(atPath: files.root.appendingPathComponent(AgentWikiPlan.configurationPath).path)
            checks["cardOnlyYAMLAndStringNotesAreAccepted"] = try AgentWikiPlan.parse("version: 1\nknowledgecard:\n  notes: [只核对实际源码]\n").knowledgeNotes == ["只核对实际源码"]
            for (name, value) in [("unknownCardConfigurationRejected", "version: 1\nknowledgecard:\n  command: run\n"), ("oversizedCardNoteRejected", "version: 1\nknowledgecard:\n  notes: [" + String(repeating: "x", count: 4001) + "]\n")] {
                do { _ = try AgentWikiPlan.parse(value); checks[name] = false } catch { checks[name] = true }
            }
            let beforeInvalid = tasks.tasks.count
            try files.writeData(Data("version: 1\nknowledgecard: invalid\n".utf8), to: files.resolve(AgentWikiPlan.configurationPath))
            do { _ = try await tasks.knowledgeCards.generate(sourceID: owner, language: "zh"); checks["invalidConfigDoesNotCreateTaskOrRequest"] = false } catch { checks["invalidConfigDoesNotCreateTaskOrRequest"] = tasks.tasks.count == beforeInvalid && blocked == 0 }
            try fm.removeItem(at: files.resolve(AgentWikiPlan.configurationPath))
            let cardID = try await tasks.knowledgeCards.generate(sourceID: owner, language: "zh"); runtime.cancel(cardID)
            checks["newCardTaskFreezesNotesBeforeModelStartup"] = tasks.task(cardID)?.knowledgeJob?.writingNotes == notes && blocked == 0
            try files.writeData(Data((yaml + "\n# Shared file changed after task creation\n").utf8), to: files.resolve(AgentWikiPlan.configurationPath))
            checks["configChangesCannotRewriteRunningNotes"] = tasks.task(cardID)?.knowledgeJob?.writingNotes == notes
            func makeCall(_ name: String, _ args: [String: Any]) throws -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)) }
            func call(_ id: String, _ name: String, _ args: [String: Any] = [:]) async throws -> AgentToolResult { try await AgentTools(store: tasks, taskID: id).execute(makeCall(name, args)) }
            do { _ = try await call(cardID, "save_knowledge_card"); checks["unreadNotesBlockSaving"] = false } catch { checks["unreadNotesBlockSaving"] = error.localizedDescription.contains("读完本次冻结") }
            do { _ = try await call(cardID, "read_project_knowledge", ["configuration": true, "content_offset": 200]); checks["notesCannotSkipUnreadPages"] = false } catch { checks["notesCannotSkipUnreadPages"] = true }
            var offset = 0, collected = "", notePages = 0
            while true {
                let result = try await call(cardID, "read_project_knowledge", ["configuration": true, "content_offset": offset]), payload = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as! [String: Any], content = payload["content"] as! String
                guard AgentContext.estimate(content) <= 400, content == String((try tasks.knowledgeCards.writingNotesText(tasks.task(cardID)!)).dropFirst(offset).prefix(content.count)) else { throw PetError("说明分页与冻结原文不一致") }
                collected += content; notePages += 1
                guard let next = payload["next_content_offset"] as? Int else { break }; guard next > offset else { throw PetError("说明分页未前进") }; offset = next
            }
            checks["boundedNotesPreserveAllChineseAndEmojiBytes"] = try notePages > 1 && collected == tasks.knowledgeCards.writingNotesText(tasks.task(cardID)!) && tasks.knowledgeCards.writingNotesComplete(tasks.task(cardID)!)
            let guidance = try tasks.knowledgeCards.writingNotesContext(tasks.task(cardID)!)
            checks["boundedFrozenGuidanceSurvivesRecentMessageWindow"] = guidance.contains(notes[0]) && guidance.contains("[节选]") && AgentContext.estimate(guidance) <= 600
            checks["cardNotesContextFits8192With512Output"] = try runtime.contextEstimate(cardID).parts.reduce(0) { $0 + $1.tokens } + 512 < 8192
            let reloaded = AgentStore(directory: output.appendingPathComponent("profile"), legacy: [], extensionHome: output.appendingPathComponent("shared-home"))
            checks["frozenNotesAndReadCursorSurviveStoreReload"] = try reloaded.task(cardID)?.knowledgeJob?.writingNotes == notes && reloaded.knowledgeCards.writingNotesComplete(reloaded.task(cardID)!)
            let wikiID = try AgentWiki.start(store: tasks, runtime: runtime, sourceID: owner, language: "zh"); runtime.cancel(wikiID)
            let wikiPlan = try await call(wikiID, "plan_wiki", ["source": true])
            checks["wikiOnlyReadsItsOwnFrozenWritingNotes"] = wikiPlan.text.contains("保留真实源码引用") && !wikiPlan.text.contains("knowledgeNotes") && !wikiPlan.text.contains(notes[0]) && AgentContext.estimate(wikiPlan.text) <= 450
            tasks.update(wikiID) { $0.archived = true }
            let index = try await tasks.knowledgeCards.refreshIndex(tasks.task(owner)!), branch = try tasks.knowledgeCards.scope(tasks.task(owner)!).branch
            for language in ["zh", "en"] {
                let shared = try AgentWiki.sharingPath(language), root = shared + "/content"; var documents: [AgentWikiTransfer.Document] = [], hashes: [String: String] = [:]
                for (name, source) in [("index.md", "README.md"), ("native.md", "native/AgentWiki.swift")] {
                    let bytes = try files.readData(files.resolve(source), maximum: 512_000), excerpt = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n").prefix(4).joined(separator: "\n")
                    let text = "# " + source + " 原文\r\n\r\n```text\r\n" + excerpt.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n```\r\n\r\n[实际源码](../../../../" + source + "#L1-L4)\r\n"
                    let data = try AgentTextFormat(encoding: .utf16LE, bom: true).encode(text); try files.writeData(data, to: files.resolve(root + "/" + name)); hashes[source] = AgentFiles.hash(bytes); documents.append(.init(file: name, title: source + " 原文", sha256: AgentFiles.hash(data), parent: name == "index.md" ? nil : "index.md"))
                }
                let metadata = AgentWikiTransfer(branch: branch, language: language, sourceRevision: index.index.revision, sourceHashes: hashes, documents: documents, origin: "manual")
                try files.writeData(JSONEncoder().encode(metadata), to: files.resolve(shared + "/" + AgentWiki.transferMetadata))
                try await AgentWiki.importWiki(AgentWiki.previewWikiImport(store: tasks, taskID: owner, language: language), store: tasks, taskID: owner)
            }
            let zh = try AgentWiki.view(store: tasks, taskID: owner, language: "zh"), en = try AgentWiki.view(store: tasks, taskID: owner, language: "en"), path = zh.pages.first { $0.path.hasSuffix("/index.md") }!.path
            let original = try files.readData(files.resolve(path), maximum: 512_000), originalText = try AgentTextFile.decode(original), old = "# README.md 原文", replacement = "# README.md 源码摘录", hash = AgentFiles.hash(original)
            let protected = try Dictionary(uniqueKeysWithValues: (zh.pages.filter { $0.path != path } + en.pages).map { ($0.path, try files.fileHash(files.resolve($0.path), maximum: 512_000)) })
            do { _ = try await call(owner, "read_project_wiki"); checks["ordinaryTaskCannotUseExplicitWikiEditor"] = false } catch { checks["ordinaryTaskCannotUseExplicitWikiEditor"] = true }
            let command = AgentMessage(role: "user", content: "/knowledge-edit 将中文 Wiki 的 README 原文标题改为源码摘录。", extensionInstructions: "[用户明确选择内置项目知识编辑命令。]")
            tasks.update(owner) { $0.messages.append(command); $0.activateExtensions(command) }
            checks["explicitCommandLoadsBothKnowledgeEditors"] = tasks.task(owner)!.isKnowledgeEditing && Set(AgentTools.definitions(mode: .agent, groups: tasks.task(owner)!.toolGroups).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }).isSuperset(of: ["read_project_wiki", "edit_project_wiki", "read_project_knowledge", "edit_project_knowledge"])
            let citation = try AgentWiki.citation(store: tasks, workspace: workspace.path); try AgentWiki.setCitation(store: tasks, workspace: workspace.path, enabled: false, expected: citation.signature)
            let listed = try await call(owner, "read_project_wiki", ["language": "zh"])
            checks["explicitWikiReadWorksWithoutEnablingAutomaticCitation"] = try listed.text.contains(path) && !AgentWiki.citation(store: tasks, workspace: workspace.path).enabled
            let edit: [String: Any] = ["path": path, "language": "zh", "expected_hash": hash, "old_text": old, "new_text": replacement, "sources": [["path": "README.md", "line": 1, "end_line": 4]]]
            do { _ = try await call(owner, "edit_project_wiki", edit); checks["editRequiresActualPageRead"] = false } catch { checks["editRequiresActualPageRead"] = true }
            _ = try await call(owner, "read_project_wiki", ["path": path, "language": "zh", "content_limit": 3])
            do { _ = try await call(owner, "edit_project_wiki", edit); checks["partialPageReadCannotReplaceUnreadText"] = false } catch { checks["partialPageReadCannotReplaceUnreadText"] = error.localizedDescription.contains("片段尚未完整读取") }
            _ = try await call(owner, "read_project_wiki", ["path": path, "language": "zh"])
            let tools = AgentTools(store: tasks, taskID: owner), approval = try tools.approvalReason(for: makeCall("edit_project_wiki", edit))
            checks["wikiEditAlwaysReturnsConcreteSingleApproval"] = approval?.contains(old) == true && approval?.contains(replacement) == true
            do { _ = try await call(owner, "edit_project_wiki", edit); checks["unreadSourceCannotSupportWikiEdit"] = false } catch { checks["unreadSourceCannotSupportWikiEdit"] = error.localizedDescription.contains("先用 read_file") }
            _ = try await call(owner, "read_file", ["path": "README.md", "offset": 1, "limit": 4])
            var wrong = edit; wrong["language"] = "en"
            do { _ = try await call(owner, "edit_project_wiki", wrong); checks["otherLanguagePathRejected"] = false } catch { checks["otherLanguagePathRejected"] = true }
            tasks.update(owner) { $0.mode = .ask }
            do { _ = try await call(owner, "edit_project_wiki", edit); checks["askModeCannotEditWiki"] = false } catch { checks["askModeCannotEditWiki"] = true }; tasks.update(owner) { $0.mode = .agent }
            let changed = try originalText.format.encode(originalText.text + "\r\n外部修改\r\n"); try files.writeData(changed, to: files.resolve(path))
            do { _ = try await call(owner, "edit_project_wiki", edit); checks["externalPageEditCannotBeOverwritten"] = false } catch { checks["externalPageEditCannotBeOverwritten"] = try files.readData(files.resolve(path)) == changed }; try files.writeData(original, to: files.resolve(path))
            let source = try files.readData(files.resolve("README.md")); try files.writeData(source + Data("\nActual source change during editing\n".utf8), to: files.resolve("README.md"))
            do { _ = try await call(owner, "edit_project_wiki", edit); checks["changedSourceInvalidatesEarlierCitationRead"] = false } catch { checks["changedSourceInvalidatesEarlierCitationRead"] = try files.readData(files.resolve(path)) == original }; try files.writeData(source, to: files.resolve("README.md"))
            let saved = try await call(owner, "edit_project_wiki", edit), actual = try files.readData(files.resolve(path)), expected = try originalText.format.encode(originalText.text.replacingOccurrences(of: old, with: replacement))
            checks["actualWikiEditPreservesUTF16BOMAndCRLF"] = actual == expected && saved.text.contains("history_saved")
            checks["otherPageAndOtherLanguageRemainByteIdentical"] = try protected.allSatisfy { try files.fileHash(files.resolve($0.key), maximum: 512_000) == $0.value }
            checks["oldWikiVersionIsArchivedBeforeEditing"] = try AgentWiki.wikiHistory(store: tasks, taskID: owner, language: "zh").contains { $0.originalRoot == zh.root && $0.metadata.documents.contains { $0.file == "index.md" && $0.sha256 == hash } }
            checks["manualEditIsVisibleAndCannotReuseOldReadHash"] = try AgentWiki.status(store: tasks, taskID: owner, language: "zh") == "已编辑" && tasks.task(owner)?.wikiEditReads?[path] == nil
            do { _ = try await call(owner, "edit_project_wiki", edit); checks["secondEditRequiresFreshReadAndApproval"] = false } catch { checks["secondEditRequiresFreshReadAndApproval"] = true }
            let back = try await call(owner, "read_project_wiki", ["path": path, "language": "zh"])
            checks["actualReadbackShowsUpdatedTextAndHash"] = back.text.contains(replacement) && back.text.contains(AgentFiles.hash(expected))
            checks["editingContextFits8192With512Output"] = try runtime.contextEstimate(owner).parts.reduce(0) { $0 + $1.tokens } + 512 < 8192
            checks["originalComposerAndCompatibleConfigurationPreserved"] = try tasks.task(owner)?.draft == "保留的项目知识草稿" && files.readData(files.resolve(AgentWikiPlan.compatiblePath)) == Data(yaml.utf8)
            checks["noModelMessagesReceiptsOrNetworkAttempt"] = blocked == 0 && tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty && !$0.messages.contains { $0.role == "assistant" || $0.role == "tool" } }
            guard checks.values.allSatisfy({ $0 }) else { throw PetError("项目知识编辑前置检查未通过") }
            guard let records = control.prepareMarkdownCheck(taskID: owner, section: 6, value: path) else { throw PetError("Wiki 窗口未打开") }
            let binary = Bundle.main.executableURL!, binaryHash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": binaryHash, "taskID": owner, "cardTaskID": cardID, "workspace": workspace.path, "editedPage": path, "expectedPageHash": AgentFiles.hash(expected), "configuration": AgentWikiPlan.configurationPath, "checks": checks, "modelsCalled": false], "knowledge-editing-ui-ready.json")
            let deadline = Date().addingTimeInterval(3600); var capture = ""
            while Date() < deadline && !fm.fileExists(atPath: output.appendingPathComponent("finish-knowledge-editing-ui").path) {
                if let name = try? String(contentsOf: output.appendingPathComponent("capture-knowledge-editing-state"), encoding: .utf8), name != capture, name.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil { capture = name; var state = await records.markdownEditingReadback(); state["appPID"] = getpid(); try write(state, "native-knowledge-editing-" + name + ".json") }; await wait(0.25)
            }
            runtime.stopAll()
            if let data = try? Data(contentsOf: output.appendingPathComponent("knowledge-editing-ui-acceptance.json")), let ui = try JSONSerialization.jsonObject(with: data) as? [String: Any], let observed = ui["checks"] as? [String: Bool] { report["uiValidated"] = ui["appPID"] as? Int == Int(getpid()) && ui["binaryHash"] as? String == binaryHash && !observed.isEmpty && observed.values.allSatisfy { $0 }; report["ui"] = ui }
            checks["finalEditedPageAndSourceBytesPreserved"] = try files.readData(files.resolve(path)) == expected && files.readData(files.resolve("README.md")) == source
            checks["finalFrozenCardNotesRetained"] = tasks.task(cardID)?.knowledgeJob?.writingNotes == notes
            checks["finalZeroModelReceipts"] = tasks.tasks.compactMap { tasks.task($0.id) }.allSatisfy { ($0.modelReceipts ?? []).isEmpty }
            report["checks"] = checks; report["success"] = checks.values.allSatisfy { $0 } && report["uiValidated"] as? Bool == true; report["appPID"] = getpid(); report["binaryHash"] = binaryHash; report["blockedRequests"] = blocked; report["notePages"] = notePages
        } catch { report["success"] = false; report["error"] = error.localizedDescription; report["checks"] = checks }
        try? write(report, "knowledge-editing-report.json")
    }
}
