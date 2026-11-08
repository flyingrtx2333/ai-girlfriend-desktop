import AppKit

@MainActor extension AppDelegate {
    func checkKnowledgeCardServices(_ output: URL, source: URL, hash: String) async throws -> [String: Bool] {
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
        for (kind, name) in [(AgentKnowledgeCardKind.architecture, "native/AgentKnowledgeLibrary.swift"), (.spec, "native/AgentDocument.swift"), (.tech_stack, "package.json")] {
            _ = try await call(docID, "read_file", ["path": name, "offset": 1, "limit": 12])
            let original = try String(contentsOf: workspace.appendingPathComponent(name), encoding: .utf8), body = original.components(separatedBy: "\n").prefix(8).joined(separator: "\n")
            _ = try await call(docID, "save_knowledge_card", ["title": "原文片段 · " + kind.title, "kind": kind.rawValue, "body": body, "sources": [["path": name, "line": 1, "end_line": 8]]])
        }
        do { _ = try cards.sources([["path": "native/AgentDocument.swift", "line": 200]], task: isolated.task(docID)!); checks["unreadLinesCannotBeCited"] = false } catch { checks["unreadLinesCannotBeCited"] = true }
        let draft = try cards.validate(isolated.task(docID)!)
        checks["draftsArePrivateUntilPublish"] = try cards.book(isolated.task(sourceID)!).0 == nil && draft.cards.count == 3 && Set(draft.cards.map(\.kind)).count == 3
        let changed = workspace.appendingPathComponent("native/AgentDocument.swift"), original = try Data(contentsOf: changed)
        try (original + Data("\n".utf8)).write(to: changed, options: .atomic)
        do { _ = try cards.validate(isolated.task(docID)!); checks["sourceChangesPreventPublishing"] = false } catch { checks["sourceChangesPreventPublishing"] = true }
        try original.write(to: changed, options: .atomic)
        try cards.publish(draft, task: isolated.task(sourceID)!, expected: emptyHash)
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
        return checks
    }
    func runAgentKnowledgeCardCheck(_ output: URL) async {
        let fm = FileManager.default
        func write(_ value: [String: Any], _ name: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
        var report: [String: Any] = [:]
        defer { agentStore?.knowledgeCards.stop(); agentRuntime?.stopAll() }
        do {
            ensureAgent(); guard let tasks = agentStore, let runtime = agentRuntime else { throw PetError("知识卡片运行时未初始化") }
            let binary = Bundle.main.executableURL!, hash = try AgentFiles(workspace: binary.deletingLastPathComponent().path).fileHash(binary)
            try write(["appPID": getpid(), "binaryHash": hash], "cards-process.json")
            guard let index = CommandLine.arguments.firstIndex(of: "--cards-source"), CommandLine.arguments.indices.contains(index + 1) else { throw PetError("缺少实际项目快照") }
            let source = URL(fileURLWithPath: CommandLine.arguments[index + 1]), nativeURL = output.appendingPathComponent("cards-native-" + String(hash.prefix(12)) + ".json")
            if !fm.fileExists(atPath: nativeURL.path) { let checks = try await checkKnowledgeCardServices(output, source: source, hash: hash); try write(["success": checks.values.allSatisfy { $0 }, "checks": checks, "binaryHash": hash], nativeURL.lastPathComponent) }
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
            try write(["appPID": getpid(), "binaryHash": hash, "taskID": id, "workspace": source.path, "model": preferences.model, "context": preferences.contextLimit, "output": preferences.outputLimit], "cards-ui-ready.json")
            while !fm.fileExists(atPath: output.appendingPathComponent("finish-cards-ui").path) {
                if tasks.tasks.reduce(0, { $0 + ($1.modelReceipts?.count ?? 0) }) > 90 { throw PetError("知识卡片验收达到90份实际请求上限，原任务保留") }
                await wait(0.2)
            }
            guard !tasks.tasks.contains(where: { runtime.isExecuting($0.id) || $0.status == .waiting }) else { throw PetError("仍有任务运行或等待批准") }
            let ui = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("cards-ui-acceptance.json"))) as! [String: Any]
            guard ui["appPID"] as? Int == Int(getpid()), ui["binaryHash"] as? String == hash, let checks = ui["checks"] as? [String: Bool], !checks.isEmpty, checks.values.allSatisfy({ $0 }) else { throw PetError("实际窗口验收记录不匹配") }
            report = ["success": true, "binaryHash": hash, "native": native, "ui": ui, "tasks": tasks.tasks.map { ["id": $0.id, "kind": $0.kind ?? "task", "status": $0.status.rawValue, "requests": $0.modelReceipts?.count ?? 0, "inputTokens": $0.inputTokens, "outputTokens": $0.outputTokens] as [String: Any] }]
        } catch { report["success"] = false; report["error"] = error.localizedDescription }
        try? write(report, "cards-report.json")
    }
}
