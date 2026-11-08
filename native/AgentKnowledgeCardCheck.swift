import AppKit

@MainActor enum AgentKnowledgeCardBudget {
    static func limit(_ output: URL) throws -> Int {
        guard let index = CommandLine.arguments.firstIndex(of: "--cards-extra-requests") else { return 90 }
        guard CommandLine.arguments.indices.contains(index + 1), CommandLine.arguments[index + 1] == "30" else { throw PetError("本次追加额度须为已授权的30次") }
        let files = try AgentFiles(workspace: output.path), data = try files.readData(files.resolve("cards-budget-authorization.json"), maximum: 8192)
        guard let grant = try JSONSerialization.jsonObject(with: data) as? [String: Any], grant["kind"] as? String == "explicit-user-authorization", grant["originalRequestLimit"] as? Int == 90, grant["additionalRequests"] as? Int == 30, grant["requestLimit"] as? Int == 120, grant["context"] as? Int == 8192, grant["output"] as? Int == 512 else { throw PetError("缺少本轮追加额度的用户授权记录") }
        return 120
    }
}

@MainActor enum AgentKnowledgeCardServiceCheck {
    static func run(_ output: URL, source: URL, hash: String) async throws -> [String: Bool] {
        let fm = FileManager.default, root = output.appendingPathComponent("native-" + String(hash.prefix(12))), workspace = root.appendingPathComponent("source")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        for name in ["native/AgentKnowledgeLibrary.swift", "native/AgentDocument.swift", "package.json"] {
            let target = workspace.appendingPathComponent(name); try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try fm.copyItem(at: source.appendingPathComponent(name), to: target)
        }
        let isolated = AgentStore(directory: root.appendingPathComponent("profile"), legacy: [], extensionHome: root.appendingPathComponent("shared-home")), cards = isolated.knowledgeCards
        let sourceID = isolated.create(workspace: workspace.path, mode: .agent), docID = isolated.create(workspace: workspace.path, mode: .goal)
        let scope = try cards.scope(isolated.task(sourceID)!), emptyHash = AgentFiles.hash(Data())
        var checks: [String: Bool] = [:]
        checks["emptyReadDoesNotCreateBook"] = try cards.book(isolated.task(sourceID)!).0 == nil && !fm.fileExists(atPath: scope.directory.path)
        isolated.update(docID) { $0.kind = AgentKnowledgeCards.kind; $0.knowledgeJob = AgentKnowledgeCardJob(workspace: workspace.path, branch: scope.branch, language: "zh", baseHash: emptyHash, sourceTaskID: sourceID) }
        func call(_ id: String, _ name: String, _ args: [String: Any] = [:]) async throws -> AgentToolResult {
            let call = AgentToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)), tools = AgentTools(store: isolated, taskID: id)
            _ = try tools.approvalReason(for: call); return try await tools.execute(call)
        }
        let definitionsRuntime = AgentRuntime(store: isolated, keychain: PetKeychain(service: "com.xjs.bluefatfish.credentials")) { PetPreferences() }
        let initialDefinitions = try definitionsRuntime.toolDefinitions(isolated.task(docID)!, preferences: PetPreferences())
        let finishDefinition = initialDefinitions.first { ($0["function"] as? [String: Any])?["name"] as? String == "finish_task" }!["function"] as! [String: Any]
        let evidenceItems = (((finishDefinition["parameters"] as! [String: Any])["properties"] as! [String: Any])["evidence"] as! [String: Any])["items"] as! [String: Any]
        checks["firstGenerationDoesNotAdvertiseEmptyEvidenceEnum"] = (evidenceItems["enum"] as? [String])?.isEmpty != true
        _ = try await call(docID, "index_project")
        let sourceLines = try String(contentsOf: workspace.appendingPathComponent("native/AgentKnowledgeLibrary.swift"), encoding: .utf8).components(separatedBy: "\n")
        let limitLine = sourceLines.firstIndex(where: { $0.contains("static func limit(") })!, page = try await call(docID, "read_file", ["path": "native/AgentKnowledgeLibrary.swift", "offset": max(1, limitLine - 6), "limit": 100])
        checks["knowledgeSourcePagesKeepWholeLinesAndNextOffset"] = page.text.contains(sourceLines[limitLine]) && page.text.contains("[next_offset=") && AgentContext.estimate(page.text) < 1150
        do { _ = try await call(docID, "run_command", ["command": "pwd"]); checks["generatorRejectsTerminalAndProjectWrites"] = false } catch {
            do { _ = try await call(docID, "write_file", ["path": "changed.txt", "content": "no"]); checks["generatorRejectsTerminalAndProjectWrites"] = false } catch { checks["generatorRejectsTerminalAndProjectWrites"] = true }
        }
        let definitionNames = Set(AgentTools.definitions(mode: .goal, kind: AgentKnowledgeCards.kind).compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        checks["generatorToolSchemaIsRestricted"] = definitionNames == AgentKnowledgeCards.generationTools
        do { _ = try cards.sources([["path": "native/AgentDocument.swift", "line": 1]], task: isolated.task(docID)!); checks["unreadSourcesCannotBeCited"] = false } catch { checks["unreadSourcesCannotBeCited"] = true }
        for line in [31, 61, 91, 121, 151, 181, 211, 241] { _ = try await call(docID, "read_file", ["path": "native/AgentKnowledgeLibrary.swift", "offset": line, "limit": 30]) }
        for line in [31, 61, 91] { _ = try await call(docID, "read_file", ["path": "native/AgentDocument.swift", "offset": line, "limit": 30]) }
        checks["nativeGenerationMovesFromReadsToSpecificCard"] = try cards.stage(isolated.task(docID)!)?.tool == "save_knowledge_card" && cards.stage(isolated.task(docID)!)?.kind == .architecture
        checks["retainedEvidenceComesFromActualReadLines"] = try cards.sourceEvidence(isolated.task(docID)!).contains(sourceLines[limitLine])
        for (kind, name) in [(AgentKnowledgeCardKind.architecture, "native/AgentKnowledgeLibrary.swift"), (.spec, "native/AgentDocument.swift"), (.tech_stack, "package.json")] {
            _ = try await call(docID, "read_file", ["path": name, "offset": 1, "limit": 12])
            let original = try String(contentsOf: workspace.appendingPathComponent(name), encoding: .utf8), body = original.components(separatedBy: "\n").prefix(8).joined(separator: "\n")
            _ = try await call(docID, "save_knowledge_card", ["title": "原文片段 · " + kind.title, "kind": kind.rawValue, "body": body, "sources": [["path": name, "line": 1, "end_line": 8]]])
        }
        do { _ = try cards.sources([["path": "native/AgentDocument.swift", "line": 200]], task: isolated.task(docID)!); checks["unreadLinesCannotBeCited"] = false } catch { checks["unreadLinesCannotBeCited"] = true }
        do { _ = try cards.sources([["path": "native/AgentKnowledgeLibrary.swift", "line": 1, "end_line": 57]], task: isolated.task(docID)!); checks["unreadPageGapCannotBeCited"] = false } catch { checks["unreadPageGapCannotBeCited"] = true }
        _ = try await call(docID, "read_file", ["path": "native/AgentKnowledgeLibrary.swift", "offset": 13, "limit": 18])
        checks["actuallyReadAdjacentPagesSupportCrossPageCitation"] = try cards.sources([["path": "native/AgentKnowledgeLibrary.swift", "line": 1, "end_line": 57]], task: isolated.task(docID)!).count == 1
        let existingDraft = try cards.drafts(isolated.task(docID)!)[0]
        do { _ = try await call(docID, "save_knowledge_card", ["title": existingDraft.title, "kind": existingDraft.kind.rawValue, "body": existingDraft.body, "sources": [["path": existingDraft.sources[0].path, "line": existingDraft.sources[0].line, "end_line": existingDraft.sources[0].endLine]]]); checks["duplicateDraftNeedsOriginalIDAndHash"] = false } catch { checks["duplicateDraftNeedsOriginalIDAndHash"] = try cards.drafts(isolated.task(docID)!).count == 3 }
        checks["draftsRequireActualReadbackBeforePlanFinish"] = try cards.stage(isolated.task(docID)!)?.tool == "read_project_knowledge"
        _ = try await call(docID, "read_project_knowledge", ["limit": 1])
        checks["partialReadbackCannotCompleteReview"] = try cards.stage(isolated.task(docID)!)?.tool == "read_project_knowledge"
        for offset in [1, 2] { _ = try await call(docID, "read_project_knowledge", ["offset": offset, "limit": 1]) }
        checks["readbackAdvancesToPlanCompletion"] = try cards.stage(isolated.task(docID)!)?.tool == "update_plan"
        _ = try await call(docID, "update_plan", ["steps": [["title": "核对真实源码", "status": "completed"], ["title": "保存卡片", "status": "completed"], ["title": "核对引用", "status": "completed"]]])
        checks["completedPlanAdvancesToActualFinishTool"] = try cards.stage(isolated.task(docID)!)?.tool == "finish_task"
        let draft = try cards.validate(isolated.task(docID)!)
        checks["draftsArePrivateUntilPublish"] = try cards.book(isolated.task(sourceID)!).0 == nil && draft.cards.count == 3 && Set(draft.cards.map(\.kind)).count == 3
        let changed = workspace.appendingPathComponent("native/AgentDocument.swift"), original = try Data(contentsOf: changed)
        try (original + Data("\n".utf8)).write(to: changed, options: .atomic)
        do { _ = try cards.validate(isolated.task(docID)!); checks["sourceChangesPreventPublishing"] = false } catch { checks["sourceChangesPreventPublishing"] = true }
        try original.write(to: changed, options: .atomic)
        let seeded = isolated.create(workspace: workspace.path, mode: .goal)
        isolated.update(seeded) { $0.kind = AgentKnowledgeCards.kind; $0.knowledgeJob = AgentKnowledgeCardJob(workspace: workspace.path, branch: scope.branch, language: "zh", baseHash: emptyHash, sourceTaskID: sourceID) }
        try await cards.seedSources(taskID: seeded, original: draft)
        checks["nativeSourceReuseReadsCurrentFilesWithoutModelMessages"] = isolated.task(seeded)!.messages.isEmpty && isolated.task(seeded)!.knowledgeJob?.nativeSourcesReady == true && !(isolated.task(seeded)!.knowledgeReads ?? [:]).isEmpty && isolated.task(seeded)!.events.contains { $0.kind == "knowledge-source" && $0.status == "completed" }
        try cards.publish(draft, task: isolated.task(sourceID)!, expected: emptyHash)
        let originalNeedsRead = try cards.stage(isolated.task(seeded)!)?.tool == "read_project_knowledge"
        _ = try await call(seeded, "read_project_knowledge")
        checks["existingCardsMustBeReadBeforeReplacingDrafts"] = try originalNeedsRead && cards.stage(isolated.task(seeded)!)?.tool == "save_knowledge_card"
        let translated = isolated.create(workspace: workspace.path, mode: .goal)
        isolated.update(translated) { $0.kind = AgentKnowledgeCards.kind; $0.knowledgeJob = AgentKnowledgeCardJob(workspace: workspace.path, branch: scope.branch, language: "en", baseHash: emptyHash, sourceTaskID: sourceID) }
        try await cards.seedSources(taskID: translated, original: draft)
        checks["languageSourceReuseDoesNotCopyCardsOrModelMessages"] = try isolated.task(translated)!.messages.isEmpty && cards.drafts(isolated.task(translated)!).isEmpty && cards.book(isolated.task(translated)!, language: "en").0 == nil && isolated.task(translated)!.knowledgeJob?.nativeSourcesReady == true
        let previous = try cards.book(isolated.task(sourceID)!), first = previous.0!.cards[0]
        checks["citationDefaultsOnAndUsesActualSource"] = cards.context(isolated.task(sourceID)!).contains(first.title) && first.sources.allSatisfy { (try? AgentFiles(workspace: workspace.path).fileHash(workspace.appendingPathComponent($0.path), maximum: 512_000)) == $0.sha256 }
        var options = try cards.options(workspace: workspace.path); options.citation = false
        try cards.setOptions(options, workspace: workspace.path, expected: cards.settings().1)
        checks["citationCanBeDisabled"] = cards.context(isolated.task(sourceID)!).isEmpty
        options.citation = true; options.language = "en"; try cards.setOptions(options, workspace: workspace.path, expected: cards.settings().1)
        checks["languagesHaveSeparateBooksAndCitation"] = try cards.book(isolated.task(sourceID)!).0 == nil && cards.context(isolated.task(sourceID)!).isEmpty
        options.language = "zh"; try cards.setOptions(options, workspace: workspace.path, expected: cards.settings().1)
        let edited = try cards.replaceCard(task: isolated.task(sourceID)!, id: first.id, body: first.body + "\n\n人工核对原文。", title: nil, expectedCard: first.hash, citations: nil, expectedBook: previous.1)
        do { _ = try cards.replaceCard(task: isolated.task(sourceID)!, id: first.id, body: "过期覆盖", title: nil, expectedCard: first.hash, citations: nil); checks["staleEditorCannotOverwriteChanges"] = false } catch { checks["staleEditorCannotOverwriteChanges"] = true }
        checks["manualEditRetainsOtherCardsAndHistory"] = try cards.book(isolated.task(sourceID)!).0!.cards.filter { $0.id != first.id }.map(\.hash) == previous.0!.cards.filter { $0.id != first.id }.map(\.hash) && cards.history(isolated.task(sourceID)!, language: "zh").contains(where: { $0.id == draft.id }) && edited.manual
        _ = try cards.exportBook(isolated.task(sourceID)!, language: "zh")
        let roundTrip = try cards.previewImport(isolated.task(sourceID)!, language: "zh"); try cards.importBook(roundTrip, task: isolated.task(sourceID)!)
        checks["exportAndImportRetainManualEditProtection"] = try cards.book(isolated.task(sourceID)!).0!.cards.first(where: { $0.id == first.id })!.manual
        let exported = workspace.appendingPathComponent(try cards.sharingPath(language: "zh")).appendingPathComponent(first.id + ".md"), external = try Data(contentsOf: exported) + Data("\n外部编辑原文。\n".utf8)
        try external.write(to: exported, options: .atomic)
        do { _ = try cards.exportBook(isolated.task(sourceID)!, language: "zh"); checks["exportProtectsExternalMarkdownEdits"] = false } catch { checks["exportProtectsExternalMarkdownEdits"] = try Data(contentsOf: exported) == external }
        let imported = try cards.previewImport(isolated.task(sourceID)!, language: "zh"); try cards.importBook(imported, task: isolated.task(sourceID)!)
        checks["importPreservesExternalTextAndVersions"] = try cards.book(isolated.task(sourceID)!).0!.cards.first(where: { $0.id == first.id })!.body.contains("外部编辑原文。") && cards.history(isolated.task(sourceID)!, language: "zh").count >= 3
        _ = try cards.exportBook(isolated.task(sourceID)!, language: "zh")
        let pending = try cards.previewImport(isolated.task(sourceID)!, language: "zh"), good = try Data(contentsOf: exported)
        try (good + Data("\n".utf8)).write(to: exported, options: .atomic)
        do { try cards.importBook(pending, task: isolated.task(sourceID)!); checks["importRechecksPreviewBeforeReplacement"] = false } catch { checks["importRechecksPreviewBeforeReplacement"] = true }
        try good.write(to: exported, options: .atomic)
        try cards.restore(draft, task: isolated.task(sourceID)!, expected: cards.book(isolated.task(sourceID)!).1)
        checks["restoreKeepsOriginalTextAndMarksManual"] = try cards.book(isolated.task(sourceID)!).0!.cards.map(\.body) == draft.cards.map(\.body) && cards.book(isolated.task(sourceID)!).0!.cards.allSatisfy(\.manual)
        let asking = isolated.create(workspace: workspace.path, mode: .ask)
        checks["askCanReadCards"] = try await !call(asking, "read_project_knowledge").failed
        do { _ = try await call(asking, "edit_project_knowledge", ["id": first.id, "body": "no", "sources": [], "expected_hash": first.hash]); checks["askCannotEditCards"] = false } catch { checks["askCannotEditCards"] = true }
        var role = AgentProfile(name: "只读知识核对", description: "核对当前项目卡片", instructions: "只读取项目资料。")
        role.enabled = true; role.readOnly = true; role.tools = ["read_project_knowledge", "edit_project_knowledge"]
        let catalog = try isolated.agents.document(); try isolated.agents.save(isolated.agents.encode([role]), expectedHash: catalog.1)
        let readOnly = try isolated.agents.createTask(role.id, store: isolated, workspace: workspace.path)
        do { _ = try await call(readOnly, "edit_project_knowledge", ["id": first.id, "body": "no", "sources": [], "expected_hash": first.hash]); checks["readOnlyRoleCannotEditCards"] = false } catch { checks["readOnlyRoleCannotEditCards"] = true }
        let unrelated = root.appendingPathComponent("other"); try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let other = isolated.create(workspace: unrelated.path, mode: .ask), unscoped = isolated.create(workspace: nil, mode: .ask)
        checks["otherProjectsAndUnscopedTasksDoNotReceiveCards"] = try cards.book(isolated.task(other)!).0 == nil && cards.context(isolated.task(other)!).isEmpty && cards.context(isolated.task(unscoped)!).isEmpty
        let reloaded = AgentStore(directory: root.appendingPathComponent("profile"), legacy: [], extensionHome: root.appendingPathComponent("shared-home"))
        checks["cardsAndSettingsSurviveReload"] = try reloaded.knowledgeCards.book(reloaded.task(sourceID)!).0?.cards.map(\.body) == draft.cards.map(\.body) && reloaded.knowledgeCards.options(workspace: workspace.path).citation
        let spec = draft.cards.first(where: { $0.kind == .spec })!, beforeChange = cards.context(isolated.task(sourceID)!).contains(spec.title)
        try (original + Data("\n".utf8)).write(to: changed, options: .atomic)
        checks["staleSourcesAreExcludedFromAutomaticCitation"] = beforeChange && !cards.context(isolated.task(sourceID)!).contains(spec.title) && cards.context(isolated.task(sourceID)!).contains(first.title)
        try original.write(to: changed, options: .atomic)
        if let index = CommandLine.arguments.firstIndex(of: "--cards-context-source"), CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]), data = try AgentFiles(workspace: url.deletingLastPathComponent().path).readData(url, maximum: 4_000_000)
            let actual = try JSONDecoder().decode(AgentTaskRecord.self, from: data), messages = try cards.modelMessages(actual, maximum: 6000)
            let positions = Dictionary(uniqueKeysWithValues: actual.messages.enumerated().map { ($0.element.id, $0.offset) }), observed = messages.compactMap { positions[$0.id] }
            checks["recordedConversationKeepsHumanInputsAndOrder"] = actual.messages.filter(\.isHumanInput).count >= 2 && messages.filter(\.isHumanInput).map(\.id) == actual.messages.filter(\.isHumanInput).map(\.id) && observed == observed.sorted() && messages.allSatisfy { value in actual.messages.contains(where: { $0.id == value.id && $0.content == value.content }) }
            try Data(AgentFiles.hash(data).utf8).write(to: output.appendingPathComponent("recorded-context-source.sha256"), options: .atomic)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--cards-search-source"), CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]), data = try AgentFiles(workspace: url.deletingLastPathComponent().path).readData(url, maximum: 4_000_000)
            let actual = try JSONDecoder().decode(AgentTaskRecord.self, from: data)
            let names = Dictionary(actual.messages.flatMap { $0.toolCalls ?? [] }.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
            let original = actual.messages.filter { $0.role == "tool" && names[$0.toolCallID ?? ""] == "search_project" }
            let projected = original.map(cards.searchExcerpt)
            checks["recordedSearchKeepsIdentifiersAndBoundedExcerpt"] = !original.isEmpty && zip(original, projected).allSatisfy { pair in pair.0.id == pair.1.id && pair.0.toolCallID == pair.1.toolCallID && AgentContext.estimate(pair.1.content) <= 1024 } && zip(original, projected).contains { pair in pair.0.content != pair.1.content }
            let maximum = 8192 - 512 - 832 - 1688 - 200 - 256, messages = try cards.modelMessages(actual, maximum: maximum)
            let retainedHash = AgentFiles.hash(try Data(contentsOf: url))
            checks["recordedOversizedExchangeFitsOriginalBudget"] = messages.contains { $0.role == "tool" && names[$0.toolCallID ?? ""] == "search_project" } && messages.filter(\.isHumanInput).map(\.id) == actual.messages.filter(\.isHumanInput).map(\.id) && retainedHash == AgentFiles.hash(data)
        }
        let editInput = AgentMessage(role: "user", content: "/knowledge-edit 核对当前卡片", extensionInstructions: "[用户选择内置 /knowledge-edit。]")
        isolated.update(sourceID) { $0.activateExtensions(editInput) }
        checks["knowledgeEditCommandLoadsNarrowToolsOnAdmission"] = isolated.task(sourceID)!.toolGroups == ["project_knowledge"]
        var queued = isolated.task(sourceID)!, askingRecord = isolated.task(asking)!
        queued.toolGroups = nil; queued.queuedMessages = [editInput]; queued.flushQueuedInputs(); askingRecord.activateExtensions(editInput)
        checks["queuedCommandLoadsToolsButAskDoesNot"] = queued.toolGroups == ["project_knowledge"] && askingRecord.toolGroups == nil
        let current = try cards.book(isolated.task(sourceID)!).0!, target = current.cards[0], reference = target.sources[0]
        _ = try await call(sourceID, "read_file", ["path": reference.path, "offset": reference.line, "limit": reference.endLine - reference.line + 1])
        let arguments: [String: Any] = ["id": target.id, "body": target.body + "\n原生读取与来源核对。", "expected_hash": target.hash, "sources": [["path": reference.path, "line": reference.line, "end_line": reference.endLine]]]
        let editCall = AgentToolCall(id: UUID().uuidString, name: "edit_project_knowledge", arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
        let approval = try AgentTools(store: isolated, taskID: sourceID).approvalReason(for: editCall)
        _ = try await AgentTools(store: isolated, taskID: sourceID).execute(editCall)
        let afterEdit = try cards.book(isolated.task(sourceID)!).0!
        checks["narrowKnowledgeToolsRecordSourcesAndKeepEditApproval"] = approval != nil && isolated.task(sourceID)!.knowledgeReads?[reference.path] != nil && afterEdit.cards.first(where: { $0.id == target.id })!.body.hasSuffix("原生读取与来源核对。") && afterEdit.cards.filter { $0.id != target.id }.map(\.hash) == current.cards.filter { $0.id != target.id }.map(\.hash)
        let existingBook = try cards.book(isolated.task(sourceID)!), repairing = isolated.create(workspace: workspace.path, mode: .goal)
        isolated.update(repairing) { $0.kind = AgentKnowledgeCards.kind; $0.knowledgeJob = AgentKnowledgeCardJob(workspace: workspace.path, branch: scope.branch, language: "zh", baseHash: existingBook.1, sourceTaskID: sourceID) }
        try await cards.seedSources(taskID: repairing, original: existingBook.0)
        _ = try await call(repairing, "read_project_knowledge")
        let originalCard = existingBook.0!.cards[0]; var orphan = originalCard; orphan.id = UUID().uuidString
        try cards.write([orphan], cards.draftURL(isolated.task(repairing)!))
        let phase = try cards.stage(isolated.task(repairing)!), next = try definitionsRuntime.toolDefinitions(isolated.task(repairing)!, preferences: PetPreferences())
        let nextFunction = next[0]["function"] as! [String: Any], nextProperties = (nextFunction["parameters"] as! [String: Any])["properties"] as! [String: Any]
        checks["unfinishedOriginalIdentityRemainsRequired"] = phase?.kind == originalCard.kind && (nextProperties["id"] as? [String: Any])?["enum"] as? [String] == [originalCard.id]
        let ref = originalCard.sources[0]
        _ = try await call(repairing, "save_knowledge_card", ["title": "重新核对的原文", "kind": originalCard.kind.rawValue, "body": originalCard.body, "sources": [["path": ref.path, "line": ref.line, "end_line": ref.endLine]]])
        let repaired = try cards.drafts(isolated.task(repairing)!)
        let originalBookUnchanged = try cards.book(isolated.task(sourceID)!).1 == existingBook.1
        checks["reviewedUniqueCategoryKeepsStableIDAndReplacesUnboundDraft"] = repaired.count == 1 && repaired[0].id == originalCard.id && repaired[0].body == originalCard.body && originalBookUnchanged
        try cards.write([orphan], cards.draftURL(isolated.task(repairing)!))
        _ = try await call(repairing, "save_knowledge_card", ["id": originalCard.id, "expected_hash": originalCard.hash, "title": orphan.title, "kind": originalCard.kind.rawValue, "body": originalCard.body, "sources": [["path": ref.path, "line": ref.line, "end_line": ref.endLine]]])
        let explicitlyRepaired = try cards.drafts(isolated.task(repairing)!)
        checks["explicitStableIDAlsoReplacesUnboundSameTitleDraft"] = explicitlyRepaired.count == 1 && explicitlyRepaired[0].id == originalCard.id
        do { _ = try await call(repairing, "save_knowledge_card", ["id": originalCard.id, "expected_hash": originalCard.hash, "title": "过期覆盖", "kind": originalCard.kind.rawValue, "body": originalCard.body, "sources": [["path": ref.path, "line": ref.line]]]); checks["implicitIdentityDoesNotAcceptStaleExplicitHash"] = false } catch { checks["implicitIdentityDoesNotAcceptStaleExplicitHash"] = true }
        let one = initialDefinitions.filter { ($0["function"] as? [String: Any])?["name"] as? String == "read_project_knowledge" }
        let named = try AgentModel.requestBody(preferences: PetPreferences(), system: "", messages: [], tools: one, requiredTool: "read_project_knowledge"), ordinary = try AgentModel.requestBody(preferences: PetPreferences(), system: "", messages: [], tools: one)
        checks["stagedRequestNamesActualToolAndKeepsOriginalBudget"] = ((named["tool_choice"] as? [String: Any])?["function"] as? [String: String])?["name"] == "read_project_knowledge" && named["max_tokens"] as? Int == 512 && ordinary["tool_choice"] as? String == "auto"
        var thinkingPreferences = PetPreferences(); thinkingPreferences.reasoningEffort = "high"
        let thinking = try AgentModel.requestBody(preferences: thinkingPreferences, system: "", messages: [], tools: one, requiredTool: "read_project_knowledge")
        checks["stagedChoicePreservesDeepSeekThinkingMode"] = (thinking["thinking"] as? [String: String])?["type"] == "enabled" && thinking["tool_choice"] as? String == "auto"
        do { _ = try AgentModel.requestBody(preferences: PetPreferences(), system: "", messages: [], tools: one, requiredTool: "not_loaded"); checks["stagedChoiceRejectsUnloadedTool"] = false } catch { checks["stagedChoiceRejectsUnloadedTool"] = true }
        checks["draftsAndCompletedPlanDoNotImplyModelFinish"] = !isolated.task(docID)!.hasConfirmedKnowledgeCompletion
        if let index = CommandLine.arguments.firstIndex(of: "--cards-finish-source"), CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]), data = try AgentFiles(workspace: url.deletingLastPathComponent().path).readData(url, maximum: 4_000_000)
            let actual = try JSONDecoder().decode(AgentTaskRecord.self, from: data); var unconfirmed = actual; unconfirmed.goalAccepted = nil
            checks["recordedCappedTaskHasActualConfirmedModelFinish"] = (actual.modelReceipts?.count ?? 0) == 30 && actual.hasConfirmedKnowledgeCompletion && !unconfirmed.hasConfirmedKnowledgeCompletion
            try Data(AgentFiles.hash(data).utf8).write(to: output.appendingPathComponent("recorded-finish-source.sha256"), options: .atomic)
        }
        return checks
    }
    static func commandLine() async -> Int32 {
        func option(_ name: String) -> URL? { guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }; return URL(fileURLWithPath: CommandLine.arguments[index + 1]) }
        guard let output = option("--check"), let source = option("--cards-source") else { print("需要 --check 检查目录及 --cards-source 实际项目目录"); return 1 }
        let reportURL = output.appendingPathComponent("cards-services-report.json")
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { print("该检查目录已有记录，请保留原记录并使用新的检查目录"); return 1 }
        var report: [String: Any] = ["modelsCalled": false, "uiValidated": false]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            let checks = try await run(output, source: source, hash: hash)
            report.merge(["success": checks.values.allSatisfy { $0 }, "checks": checks, "binaryHash": hash, "source": source.path]) { _, new in new }
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic) }
        catch { print(error.localizedDescription); return 1 }
        print(reportURL.path)
        return report["success"] as? Bool == true ? 0 : 1
    }
}

@MainActor extension AppDelegate {
    func runAgentKnowledgeCardCheck(_ output: URL) async {
        let fm = FileManager.default
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        var report: [String: Any] = [:]
        defer { agentStore?.knowledgeCards.stop(); agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("知识卡片运行时未初始化") }
            let maximumRequests = try AgentKnowledgeCardBudget.limit(output)
            runtime.modelRequestCheck = { guard tasks.tasks.reduce(0, { $0 + (tasks.task($1.id)?.modelReceipts?.count ?? 0) }) < maximumRequests else { throw PetError("整轮验收已达到\(maximumRequests)份回执上限，原记录保留") } }
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash], "cards-process.json")
            guard let index = CommandLine.arguments.firstIndex(of: "--cards-source"), CommandLine.arguments.indices.contains(index + 1) else { throw PetError("缺少实际项目快照") }
            let source = URL(fileURLWithPath: CommandLine.arguments[index + 1]), nativeURL = output.appendingPathComponent("cards-native-" + String(hash.prefix(12)) + ".json")
            if !fm.fileExists(atPath: nativeURL.path) { let checks = try await AgentKnowledgeCardServiceCheck.run(output, source: source, hash: hash); try write(["success": checks.values.allSatisfy { $0 }, "checks": checks, "binaryHash": hash], nativeURL.lastPathComponent) }
            let native = try JSONSerialization.jsonObject(with: Data(contentsOf: nativeURL)) as! [String: Any]
            guard native["success"] as? Bool == true else { throw PetError("知识卡片相关检查未通过，原记录保留") }
            guard CommandLine.arguments.contains("--live-agent") else { throw PetError("需要真实模型和窗口验收") }
            let production = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BlueFatFish")
            var preferences = PreferencesStore(directory: production).preferences; preferences.voiceEnabled = false; preferences.wakeEnabled = false; preferences.screenObservationEnabled = false
            store.preferences = preferences; try store.savePreferences()
            let ownerURL = output.appendingPathComponent("cards-source-task.json"), id: String
            if let bytes = try? Data(contentsOf: ownerURL), let owner = try JSONSerialization.jsonObject(with: bytes) as? [String: String], let existing = owner["id"], tasks.task(existing) != nil { id = existing }
            else { id = tasks.create(title: "项目知识卡片验收", workspace: source.path, mode: .agent); try write(["id": id], ownerURL.lastPathComponent) }
            control.showAgentTask(id); control.show(tab: "chat")
            tasks.knowledgeCards.resume()
            try write(["appPID": getpid(), "binaryHash": hash, "taskID": id, "workspace": source.path, "model": preferences.model, "context": preferences.contextLimit, "output": preferences.outputLimit, "requestLimit": maximumRequests], "cards-ui-ready.json")
            while !fm.fileExists(atPath: output.appendingPathComponent("finish-cards-ui").path) {
                if tasks.tasks.reduce(0, { $0 + (tasks.task($1.id)?.modelReceipts?.count ?? 0) }) > maximumRequests { throw PetError("知识卡片验收达到\(maximumRequests)份实际请求上限，原任务保留") }
                await wait(0.2)
            }
            guard !tasks.tasks.contains(where: { runtime.isExecuting($0.id) || $0.status == .waiting }) else { throw PetError("仍有任务运行或等待批准") }
            let ui = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("cards-ui-acceptance.json"))) as! [String: Any]
            guard ui["appPID"] as? Int == Int(getpid()), ui["binaryHash"] as? String == hash, let checks = ui["checks"] as? [String: Bool], !checks.isEmpty, checks.values.allSatisfy({ $0 }) else { throw PetError("实际窗口验收记录不匹配") }
            report = ["success": true, "binaryHash": hash, "requestLimit": maximumRequests, "native": native, "ui": ui, "tasks": tasks.tasks.map { ["id": $0.id, "kind": $0.kind ?? "task", "status": $0.status.rawValue, "requests": $0.modelReceipts?.count ?? 0, "inputTokens": $0.inputTokens, "outputTokens": $0.outputTokens] as [String: Any] }]
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        try? write(report, "cards-report.json")
    }
}
